/*
 * smcfan.c — a minimalist Macs Fan Control analog for Intel Macs (CLI)
 *
 * Talks to AppleSMC directly via IOKit.
 * Supports both generations of fan keys:
 *   - newer (~2016+): F0Md (mode) + F0Tg (target, type "flt ")
 *   - older: the "FS! " bitmask + F0Tg/F0Mn (type "fpe2")
 *
 * Build:   make            (or: cc -O2 -framework IOKit -framework CoreFoundation -o smcfan smcfan.c)
 * Writing to SMC requires root: sudo ./smcfan set 0 4200
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_WRITE_BYTES   6
#define SMC_CMD_READ_KEYINFO  9

typedef uint8_t SMCBytes_t[32];

typedef struct {
    uint8_t  major;
    uint8_t  minor;
    uint8_t  build;
    uint8_t  reserved;
    uint16_t release;
} SMCVers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimit_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;   /* fourcc: 'fpe2', 'flt ', 'ui8 ', ... */
    char     dataAttributes;
} SMCKeyInfo_t;

typedef struct {
    uint32_t     key;    /* fourcc: 'F0Ac', 'TC0P', ... */
    SMCVers_t    vers;
    SMCPLimit_t  pLimitData;
    SMCKeyInfo_t keyInfo;
    char         result;
    char         status;
    char         data8;  /* command */
    uint32_t     data32;
    SMCBytes_t   bytes;
} SMCKeyData_t;

typedef struct {
    uint32_t   dataSize;
    uint32_t   dataType;
    SMCBytes_t bytes;
} SMCVal_t;

static io_connect_t g_conn = 0;

/* ---------- low level ---------- */

static uint32_t fourcc(const char *s)
{
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) |
           ((uint32_t)s[2] << 8)  |  (uint32_t)s[3];
}

static void fourcc_str(uint32_t v, char out[5])
{
    out[0] = (v >> 24) & 0xff;
    out[1] = (v >> 16) & 0xff;
    out[2] = (v >> 8)  & 0xff;
    out[3] =  v        & 0xff;
    out[4] = 0;
}

static kern_return_t smc_open(void)
{
    io_service_t dev = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                   IOServiceMatching("AppleSMC"));
    if (!dev) {
        fprintf(stderr, "AppleSMC not found (is this really a Mac?)\n");
        return kIOReturnError;
    }
    kern_return_t kr = IOServiceOpen(dev, mach_task_self(), 0, &g_conn);
    IOObjectRelease(dev);
    return kr;
}

static void smc_close(void)
{
    if (g_conn) IOServiceClose(g_conn);
}

static kern_return_t smc_call(SMCKeyData_t *in, SMCKeyData_t *out)
{
    size_t out_sz = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC,
                                     in, sizeof(SMCKeyData_t),
                                     out, &out_sz);
}

/* reads keyinfo + bytes; returns 0 on success */
static int smc_read(const char *key, SMCVal_t *val)
{
    SMCKeyData_t in, out;

    memset(val, 0, sizeof(*val));
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));

    in.key   = fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0)
        return -1;

    val->dataSize = out.keyInfo.dataSize;
    val->dataType = out.keyInfo.dataType;

    in.keyInfo.dataSize = out.keyInfo.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0)
        return -1;

    memcpy(val->bytes, out.bytes, sizeof(out.bytes));
    return 0;
}

static int smc_write(const char *key, const SMCVal_t *val)
{
    SMCKeyData_t in, out;

    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));

    in.key = fourcc(key);
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = val->dataSize;
    memcpy(in.bytes, val->bytes, sizeof(in.bytes));

    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0)
        return -1;
    return 0;
}

/* ---------- SMC type decoding ---------- */

static double decode_val(const SMCVal_t *v)
{
    char t[5];
    fourcc_str(v->dataType, t);

    if (strcmp(t, "flt ") == 0 && v->dataSize == 4) {
        float f;
        memcpy(&f, v->bytes, 4);           /* little-endian on Intel */
        return (double)f;
    }
    if (strcmp(t, "fpe2") == 0 && v->dataSize == 2)
        return (double)(((uint16_t)v->bytes[0] << 8 | v->bytes[1]) >> 2);
    if (strcmp(t, "sp78") == 0 && v->dataSize == 2)
        return (double)((int16_t)((v->bytes[0] << 8) | v->bytes[1])) / 256.0;
    if (strcmp(t, "ui8 ") == 0)
        return (double)v->bytes[0];
    if (strcmp(t, "ui16") == 0)
        return (double)(((uint16_t)v->bytes[0] << 8) | v->bytes[1]);
    if (strcmp(t, "ui32") == 0)
        return (double)(((uint32_t)v->bytes[0] << 24) | ((uint32_t)v->bytes[1] << 16) |
                        ((uint32_t)v->bytes[2] << 8)  |  (uint32_t)v->bytes[3]);
    return -1.0;
}

/* encode RPM into whatever type this machine's key uses */
static int encode_rpm(const char *key, double rpm, SMCVal_t *out)
{
    SMCVal_t cur;
    if (smc_read(key, &cur) != 0) return -1;   /* also learns type/size */

    char t[5];
    fourcc_str(cur.dataType, t);

    memset(out, 0, sizeof(*out));
    out->dataType = cur.dataType;
    out->dataSize = cur.dataSize;

    if (strcmp(t, "flt ") == 0 && cur.dataSize == 4) {
        float f = (float)rpm;
        memcpy(out->bytes, &f, 4);
        return 0;
    }
    if (strcmp(t, "fpe2") == 0 && cur.dataSize == 2) {
        uint16_t v = (uint16_t)rpm << 2;
        out->bytes[0] = v >> 8;
        out->bytes[1] = v & 0xff;
        return 0;
    }
    return -1;
}

/* ---------- fans ---------- */

static int fan_count(void)
{
    SMCVal_t v;
    if (smc_read("FNum", &v) != 0) return -1;
    return (int)decode_val(&v);
}

static double fan_key(int fan, const char *suffix)
{
    char key[5];
    SMCVal_t v;
    snprintf(key, sizeof(key), "F%d%s", fan, suffix);
    if (smc_read(key, &v) != 0) return -1.0;
    return decode_val(&v);
}

/* mode: 1 = manual, 0 = auto. Try F%dMd, else fall back to FS! */
static int fan_set_mode(int fan, int manual)
{
    char key[5];
    SMCVal_t v;

    snprintf(key, sizeof(key), "F%dMd", fan);
    if (smc_read(key, &v) == 0) {           /* newer method */
        memset(v.bytes, 0, sizeof(v.bytes));
        v.bytes[0] = manual ? 1 : 0;
        return smc_write(key, &v);
    }

    if (smc_read("FS! ", &v) == 0) {        /* older method: bitmask */
        uint16_t mask = ((uint16_t)v.bytes[0] << 8) | v.bytes[1];
        if (manual) mask |=  (1 << fan);
        else        mask &= ~(1 << fan);
        v.bytes[0] = mask >> 8;
        v.bytes[1] = mask & 0xff;
        return smc_write("FS! ", &v);
    }
    return -1;
}

static int fan_set_target(int fan, double rpm)
{
    char key[5];
    SMCVal_t v;
    snprintf(key, sizeof(key), "F%dTg", fan);
    if (encode_rpm(key, rpm, &v) != 0) return -1;
    return smc_write(key, &v);
}

/* ---------- output ---------- */

static void print_temp(const char *key, const char *label)
{
    SMCVal_t v;
    if (smc_read(key, &v) != 0) return;
    double t = decode_val(&v);
    if (t > 0.0 && t < 128.0)
        printf("  %-24s %6.1f °C   [%s]\n", label, t, key);
}

static void cmd_status(void)
{
    int n = fan_count();
    if (n <= 0) {
        fprintf(stderr, "Failed to read FNum\n");
        return;
    }
    printf("Fans: %d\n", n);
    for (int i = 0; i < n; i++) {
        double ac = fan_key(i, "Ac");
        double mn = fan_key(i, "Mn");
        double mx = fan_key(i, "Mx");
        double tg = fan_key(i, "Tg");
        double md = fan_key(i, "Md");
        printf("  Fan %d: %5.0f RPM  (min %.0f / max %.0f, target %.0f)  mode: %s\n",
               i, ac, mn, mx, tg,
               md < 0 ? "?" : (md > 0.5 ? "MANUAL" : "auto"));
    }
    printf("Temperatures:\n");
    print_temp("TC0P", "CPU proximity");
    print_temp("TC0D", "CPU die");
    print_temp("TC0E", "CPU die (E)");
    print_temp("TC0F", "CPU die (F)");
    print_temp("TCXC", "CPU PECI");
    print_temp("TG0P", "GPU proximity");
    print_temp("TA0P", "Ambient");
    print_temp("Ts0P", "Palm rest");
    print_temp("TB0T", "Battery");
}

static void usage(const char *argv0)
{
    fprintf(stderr,
        "Usage:\n"
        "  %s status              — fan speeds, limits, temperatures\n"
        "  %s set <fan> <rpm>     — manual mode, set RPM (sudo)\n"
        "  %s max [fan]           — fan(s) to maximum (sudo)\n"
        "  %s auto [fan]          — back to SMC automatics, all or one (sudo)\n"
        "  %s freq                — average CPU frequency, MHz (needs setuid helper)\n"
        "  %s watch [sec]         — status in a loop (default 2 s)\n",
        argv0, argv0, argv0, argv0, argv0, argv0);
}

int main(int argc, char **argv)
{
    if (argc < 2) { usage(argv[0]); return 1; }

    if (smc_open() != kIOReturnSuccess) {
        fprintf(stderr, "Failed to open AppleSMC\n");
        return 1;
    }

    int rc = 0;

    if (strcmp(argv[1], "status") == 0) {
        cmd_status();

    } else if (strcmp(argv[1], "watch") == 0) {
        int sec = (argc > 2) ? atoi(argv[2]) : 2;
        if (sec < 1) sec = 1;
        for (;;) {
            printf("\033[2J\033[H");   /* clear screen */
            cmd_status();
            sleep((unsigned)sec);
        }

    } else if (strcmp(argv[1], "set") == 0 && argc == 4) {
        int fan = atoi(argv[2]);
        double rpm = atof(argv[3]);
        double mn = fan_key(fan, "Mn"), mx = fan_key(fan, "Mx");
        if (mn > 0 && rpm < mn) { printf("Raising to minimum: %.0f\n", mn); rpm = mn; }
        if (mx > 0 && rpm > mx) { printf("Capping at maximum: %.0f\n", mx); rpm = mx; }
        if (fan_set_mode(fan, 1) != 0 || fan_set_target(fan, rpm) != 0) {
            fprintf(stderr, "Write failed. Running under sudo?\n");
            rc = 1;
        } else {
            printf("Fan %d -> %.0f RPM (manual mode)\n", fan, rpm);
        }

    } else if (strcmp(argv[1], "max") == 0) {
        int n = fan_count();
        int from = 0, to = n - 1;
        if (argc == 3) from = to = atoi(argv[2]);
        for (int i = from; i <= to && rc == 0; i++) {
            double mx = fan_key(i, "Mx");
            if (mx <= 0) { rc = 1; break; }
            if (fan_set_mode(i, 1) != 0 || fan_set_target(i, mx) != 0) rc = 1;
            else printf("Fan %d -> %.0f RPM (maximum)\n", i, mx);
        }
        if (rc) fprintf(stderr, "Write failed. Running under sudo?\n");

    } else if (strcmp(argv[1], "auto") == 0) {
        int n = fan_count();
        int from = 0, to = n - 1;
        if (argc == 3) from = to = atoi(argv[2]);
        for (int i = from; i <= to; i++)
            if (fan_set_mode(i, 0) != 0) rc = 1;
        if (rc) fprintf(stderr, "Write failed. Running under sudo?\n");
        else printf("Fan(s) returned to automatic mode.\n");

    } else if (strcmp(argv[1], "freq") == 0) {
        /* Average CPU frequency in MHz via Apple's powermetrics (needs root —
         * that's us, we're setuid). powermetrics derives it from APERF/MPERF
         * internally, so this is the real effective frequency. */
        if (setuid(0) != 0) {
            fprintf(stderr, "freq needs the setuid helper (make helper)\n");
            smc_close();
            return 1;
        }
        FILE *pm = popen("/usr/bin/powermetrics -n 1 -i 300 "
                         "--samplers cpu_power 2>/dev/null", "r");
        if (!pm) {
            fprintf(stderr, "failed to run powermetrics\n");
            smc_close();
            return 1;
        }
        char line[512];
        double mhz = -1, v;
        while (fgets(line, sizeof line, pm)) {
            if (strstr(line, "frequency")) {
                char *paren = strchr(line, '(');
                if (paren && sscanf(paren, "(%lf", &v) == 1 && v > 50 && v < 10000) {
                    mhz = v;
                    break;
                }
            }
        }
        pclose(pm);
        if (mhz < 0) {
            fprintf(stderr, "no frequency in powermetrics output\n");
            rc = 1;
        } else {
            printf("%.0f\n", mhz);
        }

    } else {
        usage(argv[0]);
        rc = 1;
    }

    smc_close();
    return rc;
}
