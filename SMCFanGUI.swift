//
//  SMCFanGUI.swift — a Macs Fan Control-style GUI (Intel Mac)
//
//  Localization: NSLocalizedString-style lookup, base language is English,
//  Russian lives in Resources/ru.lproj/Localizable.strings (copied by the Makefile).
//
//  Build:  make app  (see Makefile)
//

import SwiftUI
import AppKit
import IOKit
import Combine

// MARK: - Localization with in-app language picker
//
// The language list is NOT hardcoded: we scan *.lproj in the bundle Resources.
// Adding a language = drop in xx.lproj/Localizable.strings and rebuild the app,
// no code changes required.

struct AppLanguage: Identifiable, Hashable {
    let code: String            // "system", "en", "ru", "de", ...
    var id: String { code }

    var label: String {
        switch code {
        case "system": return "System"
        case "en":     return "English"
        default:
            // the language's own name for itself: "ru" → "Русский", "de" → "Deutsch"
            let name = Locale(identifier: code)
                .localizedString(forLanguageCode: code) ?? code
            return name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    static let system = AppLanguage(code: "system")

    /// system + English (base strings in code) + every *.lproj found in the bundle.
    static func available() -> [AppLanguage] {
        var langs = [AppLanguage.system, AppLanguage(code: "en")]
        let found = Bundle.main.paths(forResourcesOfType: "lproj", inDirectory: nil)
            .map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            .filter { $0 != "en" && $0 != "Base" }
            .sorted()
        langs += found.map { AppLanguage(code: $0) }
        return langs
    }
}

enum Lang {
    static var mode: AppLanguage = .system
    private static var bundles: [String: Bundle] = [:]

    private static func bundle(for code: String) -> Bundle? {
        if let b = bundles[code] { return b }
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let b = Bundle(path: path) else { return nil }
        bundles[code] = b
        return b
    }

    static func localize(_ key: String) -> String {
        switch mode.code {
        case "en":
            return key   // base strings in code are English
        case "system":
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        default:
            return bundle(for: mode.code)?
                .localizedString(forKey: key, value: key, table: nil) ?? key
        }
    }
}

@inline(__always) func L(_ key: String) -> String {
    Lang.localize(key)
}

// MARK: - SMC (reading + key enumeration)

final class SMCReader {

    private var conn: io_connect_t = 0

    private struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        // The C compiler pads this struct to 12 bytes; Swift adds NO tail
        // padding to nested structs — without these bytes every field below
        // shifts and the kernel reads garbage.
        var pad0: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0
    }

    private struct ParamStruct {
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
                   (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
    }

    init?() {
        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard kr == kIOReturnSuccess else { return nil }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func fourcc(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for c in s.utf8.prefix(4) { v = (v << 8) | UInt32(c) }
        return v
    }

    private func fourccString(_ v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                 UInt8((v >> 8) & 0xff),  UInt8(v & 0xff)]
        return String(bytes: b, encoding: .ascii) ?? "????"
    }

    private func call(_ input: inout ParamStruct) -> ParamStruct? {
        var output = ParamStruct()
        var outSize = MemoryLayout<ParamStruct>.stride
        let kr = IOConnectCallStructMethod(conn, 2, &input,
                                           MemoryLayout<ParamStruct>.stride,
                                           &output, &outSize)
        guard kr == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        var input = ParamStruct()
        input.key = fourcc(key)
        input.data8 = 9 // SMC_CMD_READ_KEYINFO
        guard let info = call(&input) else { return nil }

        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = 5 // SMC_CMD_READ_BYTES
        guard let out = call(&input) else { return nil }

        let arr = withUnsafeBytes(of: out.bytes) { Array($0) }
        let size = Int(info.keyInfo.dataSize)
        return (fourccString(info.keyInfo.dataType), Array(arr.prefix(max(size, 1))))
    }

    func readDouble(_ key: String) -> Double? {
        guard let (type, b) = read(key) else { return nil }
        switch type {
        case "flt " where b.count >= 4:
            let f = b.withUnsafeBytes { $0.load(as: Float.self) }
            return Double(f)
        case "fpe2" where b.count >= 2:
            return Double((UInt16(b[0]) << 8 | UInt16(b[1])) >> 2)
        case "sp78" where b.count >= 2:
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
        case "ui8 ":
            return Double(b[0])
        case "ui16" where b.count >= 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32" where b.count >= 4:
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default:
            return nil
        }
    }

    /// Full list of SMC keys (#KEY + SMC_CMD_READ_INDEX).
    func allKeys() -> [String] {
        guard let total = readDouble("#KEY") else { return [] }
        var keys: [String] = []
        keys.reserveCapacity(Int(total))
        for i in 0..<UInt32(total) {
            var input = ParamStruct()
            input.data8 = 8 // SMC_CMD_READ_INDEX
            input.data32 = i
            if let out = call(&input) {
                keys.append(fourccString(out.key))
            }
        }
        return keys
    }
}

// MARK: - Data

enum FanRule: Codable, Equatable {
    case auto
    case constant(Double)
    case sensor(String, Double, Double)
}

struct FanState: Identifiable, Equatable {
    let id: Int
    var name: String = ""
    var rpm: Double = 0
    var minRPM: Double = 0
    var maxRPM: Double = 0
    var target: Double = 0
    var manual: Bool = false
}

struct SensorReading: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let name: String
    var value: Double
    var isRaw: Bool { name == key }
}

struct Sample {
    let time: Date
    let values: [String: Double]     // temperatures: SMC key → °C
    var fanRPM: [Int: Double] = [:]  // fan speeds: fan id → RPM
    var power: [String: Double] = [:]   // "PKG"/"CORE"/"DRAM" → watts
    var freqGHz: Double? = nil          // average core frequency
    var utilTotal: Double? = nil        // total CPU utilization, %
    var utilCores: [Double] = []        // per logical core, %
}

let sensorNames: [String: String] = [
    "TC0P": "CPU Proximity",    "TCXC": "CPU PECI",
    "TC0D": "CPU Die",          "TC0E": "CPU Die (E)",   "TC0F": "CPU Die (F)",
    "TCAD": "CPU Package",      "TCSA": "CPU System Agent",
    "TCGC": "GPU Intel Graphics",
    "TG0P": "GPU Proximity",    "TG0D": "GPU Die",       "TGDD": "GPU Radeon Die",
    "TW0P": "Airport Proximity",
    "TB0T": "Battery Max",      "TB1T": "Battery Sensor 1", "TB2T": "Battery Sensor 2",
    "Th1H": "Heatsink 1",       "Th2H": "Heatsink 2",    "Th0H": "Heatsink",
    "TM0P": "Memory Proximity", "TPCD": "Platform Controller Hub Die",
    "TA0P": "Ambient",          "Ts0P": "Palm Rest",     "Ts1P": "Trackpad",
    "TH0P": "Drive Bay",        "TN0D": "Northbridge Die",
    "TTLD": "Thunderbolt Left", "TTRD": "Thunderbolt Right",
    "TH0F": "SSD Sensor 1",     "TH0X": "SSD Sensor 2",
    "TH0a": "SSD Sensor A",     "TH0b": "SSD Sensor B",
    "Tm0P": "Mainboard Proximity",
]

func sensorName(_ key: String) -> String {
    if let n = sensorNames[key] { return n }
    if key.count == 4, key.hasPrefix("TC"), key.hasSuffix("C"),
       let n = Int(String(Array(key)[2])) {
        return "CPU Core \(n)"
    }
    return key
}

// MARK: - Intel Power Gadget (dlopen, optional)
//
// RAPL counters (watts) and frequency live in MSRs — unreachable from userspace.
// If Intel Power Gadget is installed we piggyback on its framework and kext.
// Every symbol is resolved via dlsym; whatever is missing, that metric is skipped.

final class PowerGadget {
    private typealias PGInit       = @convention(c) () -> Bool
    private typealias PGReadSample = @convention(c) (Int32, UnsafeMutablePointer<UInt64>) -> Bool
    private typealias PGFreq       = @convention(c) (UInt64, UInt64,
                                                     UnsafeMutablePointer<Double>,
                                                     UnsafeMutablePointer<Double>,
                                                     UnsafeMutablePointer<Double>) -> Bool
    private typealias PGPower      = @convention(c) (UInt64, UInt64,
                                                     UnsafeMutablePointer<Double>,
                                                     UnsafeMutablePointer<Double>) -> Bool
    private typealias PGRelease    = @convention(c) (UInt64) -> Bool

    private var readSampleFn: PGReadSample?
    private var freqFn: PGFreq?
    private var pkgPowerFn: PGPower?
    private var iaPowerFn: PGPower?
    private var dramPowerFn: PGPower?
    private var releaseFn: PGRelease?
    private var initFn: PGInit?
    private var shutdownFn: PGInit?
    private var prev: UInt64 = 0
    private var emptyReads = 0        // consecutive reads that yielded nothing

    struct Reading {
        var pkgW: Double?
        var coreW: Double?
        var dramW: Double?
        var freqGHz: Double?
    }

    init?() {
        let path = "/Library/Frameworks/IntelPowerGadget.framework/IntelPowerGadget"
        guard let h = dlopen(path, RTLD_LAZY) else { return nil }
        guard let initSym = dlsym(h, "PG_Initialize"),
              unsafeBitCast(initSym, to: PGInit.self)()
        else { dlclose(h); return nil }
        initFn = unsafeBitCast(initSym, to: PGInit.self)
        shutdownFn = dlsym(h, "PG_Shutdown").map { unsafeBitCast($0, to: PGInit.self) }

        readSampleFn = dlsym(h, "PG_ReadSample").map { unsafeBitCast($0, to: PGReadSample.self) }
        freqFn       = dlsym(h, "PGSample_GetIAFrequency").map { unsafeBitCast($0, to: PGFreq.self) }
        pkgPowerFn   = dlsym(h, "PGSample_GetPackagePower").map { unsafeBitCast($0, to: PGPower.self) }
        iaPowerFn    = dlsym(h, "PGSample_GetIAPower").map { unsafeBitCast($0, to: PGPower.self) }
        dramPowerFn  = dlsym(h, "PGSample_GetDRAMPower").map { unsafeBitCast($0, to: PGPower.self) }
        releaseFn    = dlsym(h, "PGSample_Release").map { unsafeBitCast($0, to: PGRelease.self) }

        guard readSampleFn != nil else { return nil }
        _ = readSampleFn?(0, &prev)   // first sample anchors the measurement interval
    }

    /// Metrics over the interval between the previous and current sample.
    /// Self-healing: a stale PG session can produce endless empty samples
    /// (framework alive, data dead) — after a few of those, shutdown and
    /// re-initialize the session. A restart of the host app fixes it, so
    /// re-init from within does the same without the restart.
    func read() -> Reading {
        var r = Reading()
        guard let readSample = readSampleFn, prev != 0 else { return r }
        var cur: UInt64 = 0
        guard readSample(0, &cur), cur != 0 else {
            noteEmptyRead()
            return r
        }
        var a = 0.0, b = 0.0, c = 0.0
        if let f = freqFn, f(prev, cur, &a, &b, &c) { r.freqGHz = a / 1000.0 }  // MHz → GHz
        if let f = pkgPowerFn,  f(prev, cur, &a, &b) { r.pkgW  = a }
        if let f = iaPowerFn,   f(prev, cur, &a, &b) { r.coreW = a }
        if let f = dramPowerFn, f(prev, cur, &a, &b) { r.dramW = a }
        _ = releaseFn?(prev)
        prev = cur

        if r.freqGHz == nil && r.pkgW == nil && r.coreW == nil && r.dramW == nil {
            noteEmptyRead()
        } else {
            emptyReads = 0
        }
        return r
    }

    private func noteEmptyRead() {
        emptyReads += 1
        guard emptyReads >= 3 else { return }
        emptyReads = 0
        _ = shutdownFn?()
        if initFn?() == true {
            prev = 0
            _ = readSampleFn?(0, &prev)   // fresh anchor sample
        }
    }
}

// MARK: - Model

final class Model: ObservableObject {

    static let shared = Model()

    @Published var fans: [FanState] = []
    @Published var sensors: [SensorReading] = []
    @Published var rules: [Int: FanRule] = [:]
    @Published var plotted: Set<String> = []
    @Published var samples: [Sample] = []
    @Published var window: TimeInterval = 300
    @Published var alertMessage: String? = nil
    @Published var helperOK: Bool = false
    @Published var hideRawKeys: Bool = UserDefaults.standard.bool(forKey: "hideRawKeys") {
        didSet { UserDefaults.standard.set(hideRawKeys, forKey: "hideRawKeys") }
    }
    // sensor table sort: by name (stable) or by temperature (hottest first)
    @Published var sortByTemp: Bool = UserDefaults.standard.bool(forKey: "sortByTemp") {
        didSet { UserDefaults.standard.set(sortByTemp, forKey: "sortByTemp") }
    }
    @Published var language: AppLanguage =
        AppLanguage(code: UserDefaults.standard.string(forKey: "appLanguage") ?? "system") {
        didSet {
            UserDefaults.standard.set(language.code, forKey: "appLanguage")
            Lang.mode = language
        }
    }
    // Sensor-based loop settings, shared by all rules:
    // extra RPM per 1 °C/s of temperature rise (the D term)
    @Published var boostPerDeg: Double =
        (UserDefaults.standard.object(forKey: "boostPerDeg") as? Double) ?? 800 {
        didSet { UserDefaults.standard.set(boostPerDeg, forKey: "boostPerDeg") }
    }
    // maximum rate of RPM DECREASE, RPM/s (increase is instant)
    @Published var releaseRPMps: Double =
        (UserDefaults.standard.object(forKey: "releaseRPMps") as? Double) ?? 150 {
        didSet { UserDefaults.standard.set(releaseRPMps, forKey: "releaseRPMps") }
    }
    // Throttle guard: throttling (BD PROCHOT/VRM) can hit even with a COLD
    // core, so temperature rules never see it. If frequency drops below the
    // threshold while the CPU is busy — run fans at max until it lets go.
    @Published var throttleGuard: Bool =
        (UserDefaults.standard.object(forKey: "throttleGuard") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(throttleGuard, forKey: "throttleGuard") }
    }
    @Published var throttleGHz: Double =
        (UserDefaults.standard.object(forKey: "throttleGHz") as? Double) ?? 1.6 {
        didSet { UserDefaults.standard.set(throttleGHz, forKey: "throttleGHz") }
    }
    @Published var throttleActive: Bool = false

    @Published var utilPerCore: Bool = UserDefaults.standard.bool(forKey: "utilPerCore") {
        didSet { UserDefaults.standard.set(utilPerCore, forKey: "utilPerCore") }
    }
    @Published var hasFreq: Bool = false

    var statusHandler: ((_ title: String, _ tooltip: String) -> Void)?
    var hwModel: String = ""

    private let smc: SMCReader?
    private var powerGadget: PowerGadget?
    private var prevTicks: [[UInt32]] = []
    private var freqMissCount = 0          // consecutive polls with no frequency data
    private var smcPkgKey: String?         // discovered SMC power keys (fallback)
    private var smcCoreKey: String?
    private var helperFreq: Double?        // last frequency from `smcfan-cli freq`, GHz
    private var helperFreqInFlight = false
    private var timer: Timer?
    private var tempKeys: [String] = []
    private var commanded: [Int: Double] = [:]                            // last commanded RPM
    private var derivState: [Int: (temp: Double, time: Date, ema: Double)] = [:]
    private var lastLoop: Date?
    private let maxSamples = 7200

    private init() {
        // Can't touch self.language before all stored properties are
        // initialized, so read the saved language straight from UserDefaults.
        Lang.mode = AppLanguage(
            code: UserDefaults.standard.string(forKey: "appLanguage") ?? "system")
        smc = SMCReader()
        powerGadget = PowerGadget()
        // hasFreq stays false until frequency data actually arrives (see poll)
        hwModel = Self.sysctlString("hw.model")
        discoverSensors()
        loadRules()
        checkHelper()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private func discoverSensors() {
        guard let smc = smc else { return }
        var found: [String] = []
        for key in smc.allKeys() where key.hasPrefix("T") {
            guard let v = smc.readDouble(key), v > 5, v < 110 else { continue }
            found.append(key)
        }
        tempKeys = found.sorted { sensorName($0) < sensorName($1) }

        for k in ["TC0P", "TG0P"] where tempKeys.contains(k) { plotted.insert(k) }
        if plotted.isEmpty, let first = tempKeys.first { plotted.insert(first) }

        // SMC power keys vary between models — probe candidates once.
        for k in ["PCPT", "PSTR", "PCTR", "PDTR"] {
            if let v = smc.readDouble(k), v > 0, v < 300 { smcPkgKey = k; break }
        }
        for k in ["PCPC", "PC0C", "PC0R"] {
            if let v = smc.readDouble(k), v > 0, v < 300 { smcCoreKey = k; break }
        }
    }

    private func fanName(_ i: Int, total: Int) -> String {
        if let (type, b) = smc?.read("F\(i)ID"), type == "{fds", b.count >= 16 {
            let strBytes = b[4..<16].filter { $0 >= 32 && $0 < 127 }
            if let s = String(bytes: strBytes, encoding: .ascii)?
                        .trimmingCharacters(in: .whitespaces), s.count > 2 {
                return s
            }
        }
        if total == 2 { return i == 0 ? L("Left side") : L("Right side") }
        return String(format: L("Fan %d"), i)
    }

    // MARK: polling + control loop

    func poll() {
        guard let smc = smc else { return }

        let count = Int(smc.readDouble("FNum") ?? 0)
        var newFans: [FanState] = []
        for i in 0..<count {
            var f = FanState(id: i)
            f.name   = fans.indices.contains(i) && !fans[i].name.isEmpty
                       ? fans[i].name : fanName(i, total: count)
            f.rpm    = smc.readDouble("F\(i)Ac") ?? 0
            f.minRPM = smc.readDouble("F\(i)Mn") ?? 0
            f.maxRPM = smc.readDouble("F\(i)Mx") ?? 0
            f.target = smc.readDouble("F\(i)Tg") ?? 0
            if let md = smc.readDouble("F\(i)Md") {
                f.manual = md > 0.5
            } else if let mask = smc.readDouble("FS! ") {
                f.manual = (Int(mask) & (1 << i)) != 0
            }
            newFans.append(f)
        }

        var newSensors: [SensorReading] = []
        var sampleVals: [String: Double] = [:]
        for k in tempKeys {
            if let v = smc.readDouble(k), v > 0, v < 128 {
                newSensors.append(SensorReading(key: k, name: sensorName(k), value: v))
                sampleVals[k] = v
            }
        }

        // --- CPU metrics: power, frequency, utilization ---
        var power: [String: Double] = [:]
        var freq: Double? = nil
        if let r = powerGadget?.read() {
            if let v = r.pkgW  { power["PKG"]  = v }
            if let v = r.coreW { power["CORE"] = v }
            if let v = r.dramW { power["DRAM"] = v }
            freq = r.freqGHz
        }
        // Frequency fallback: no Power Gadget data → Apple's powermetrics via
        // the setuid helper (it computes APERF/MPERF-based effective frequency).
        // Async with a one-poll lag: use the last fetched value, kick a new fetch.
        if freq == nil, helperOK {
            freq = helperFreq
            fetchFreqViaHelper()
        }
        // hasFreq reflects actual DATA, not just "framework loaded": Power
        // Gadget's driver may be dormant until its app runs, returning nils.
        if freq != nil {
            freqMissCount = 0
            if !hasFreq { hasFreq = true }
        } else {
            freqMissCount += 1
            if hasFreq && freqMissCount >= 3 { hasFreq = false }
        }
        // fallback: SMC exposes watts via model-specific keys probed at startup
        if power["PKG"] == nil, let k = smcPkgKey,
           let v = smc.readDouble(k), v > 0, v < 300 { power["PKG"] = v }
        if power["CORE"] == nil, let k = smcCoreKey,
           let v = smc.readDouble(k), v > 0, v < 300 { power["CORE"] = v }
        let (utilTotal, utilCores) = cpuUtilization()

        fans = newFans
        sensors = newSensors
        var fanVals: [Int: Double] = [:]
        for f in newFans { fanVals[f.id] = f.rpm }
        samples.append(Sample(time: Date(), values: sampleVals, fanRPM: fanVals,
                              power: power, freqGHz: freq,
                              utilTotal: utilTotal, utilCores: utilCores))
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }

        updateThrottleState(freq: freq, util: utilTotal)
        runControlLoop()

        // menu bar: temperature only in the title; everything else in a hover hint
        let coreTemps = newSensors.filter { $0.name.hasPrefix("CPU Core") }.map { $0.value }
        let cpu = coreTemps.isEmpty ? (sampleVals["TC0P"] ?? 0)
                                    : coreTemps.reduce(0, +) / Double(coreTemps.count)

        var tip = ""
        for f in newFans {
            let mode: String
            switch rules[f.id] ?? .auto {
            case .auto:
                mode = L("Auto")
            case .constant:
                mode = L("Constant RPM")
            case .sensor(let key, let from, let to):
                mode = String(format: L("by %@"), sensorName(key))
                     + String(format: " (%d–%d°)", Int(from), Int(to))
            }
            tip += "\(f.name): \(Int(f.rpm)) RPM — \(mode)\n"
        }
        tip += "\n"
        tip += L("Spike boost") + ": \(Int(boostPerDeg)) RPM/(°C/s)\n"
        tip += L("Release speed") + ": \(Int(releaseRPMps)) RPM/s\n"
        tip += L("Throttle guard") + ": "
        if throttleGuard {
            tip += String(format: "< %.1f GHz", throttleGHz)
            if throttleActive { tip += " — " + L("THROTTLE") + "!" }
        } else {
            tip += L("off")
        }

        statusHandler?(String(format: "%.0f°", cpu), tip)
    }

    /// Throttle detector: frequency below the threshold while the CPU is busy.
    /// Exit ONLY on frequency recovery (with hysteresis).
    /// No "load is gone" exit: a stuck state (VRM/BD PROCHOT) persists even
    /// at idle, and max airflow is exactly what cures it.
    /// On genuine idle the frequency pops above the threshold on the first
    /// background burst (turbo spikes), so the guard releases on its own.
    private func updateThrottleState(freq: Double?, util: Double?) {
        guard throttleGuard, let f = freq else {
            throttleActive = false
            return
        }
        if throttleActive {
            if f > throttleGHz + 0.4 {
                throttleActive = false
            }
        } else if f < throttleGHz && (util ?? 0) > 40 {
            throttleActive = true
        }
    }

    /// Sensor-based loop: P (linear interpolation) + D (reaction to rise)
    /// + asymmetry: up instantly, down no faster than releaseRPMps.
    private func runControlLoop() {
        let now = Date()
        let loopDT = lastLoop.map { now.timeIntervalSince($0) } ?? 2.0
        lastLoop = now

        for fan in fans {
            guard case let .sensor(key, from, to) = rules[fan.id] ?? .auto,
                  to > from,
                  let t = sensors.first(where: { $0.key == key })?.value
            else {
                derivState[fan.id] = nil
                continue
            }

            // P: linear interpolation min→max between from and to
            let frac = max(0.0, min(1.0, (t - from) / (to - from)))
            var target = fan.minRPM + frac * (fan.maxRPM - fan.minRPM)

            // D: smoothed derivative in °C/s; boost only while RISING
            var ema = 0.0
            if let prev = derivState[fan.id] {
                let dt = now.timeIntervalSince(prev.time)
                if dt > 0.1 {
                    let raw = (t - prev.temp) / dt
                    ema = prev.ema * 0.6 + raw * 0.4
                    derivState[fan.id] = (t, now, ema)
                } else {
                    ema = prev.ema
                }
            } else {
                derivState[fan.id] = (t, now, 0)
            }
            if ema > 0 { target += ema * boostPerDeg }
            // Throttle guard: temperature lies here (core is cold, VRM burns) —
            // ignore it and blow at full speed until frequency recovers.
            if throttleActive { target = fan.maxRPM }
            target = min(max(target, fan.minRPM), fan.maxRPM)

            // attack/decay asymmetry
            let cur = commanded[fan.id] ?? fan.rpm
            let newCmd: Double
            if target >= cur {
                newCmd = target                                    // up — instantly
            } else {
                newCmd = max(target, cur - releaseRPMps * loopDT)  // down — gently
            }

            if abs(newCmd - cur) >= 50 || commanded[fan.id] == nil {
                if setRPMQuiet(fan: fan.id, rpm: newCmd) {
                    commanded[fan.id] = newCmd
                } else {
                    rules[fan.id] = .auto
                    saveRules()
                }
            }
        }
    }

    // MARK: CPU utilization (Mach, no root needed)

    private static func cpuTicks() -> [[UInt32]] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info = info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var out: [[UInt32]] = []
        out.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * i
            var t: [UInt32] = []
            for s in 0..<Int(CPU_STATE_MAX) {
                t.append(UInt32(bitPattern: info[base + s]))
            }
            out.append(t)
        }
        return out
    }

    /// (total %, per logical core %) — tick delta between polls.
    private func cpuUtilization() -> (Double?, [Double]) {
        let cur = Self.cpuTicks()
        defer { prevTicks = cur }
        guard !cur.isEmpty, prevTicks.count == cur.count else { return (nil, []) }
        var per: [Double] = []
        var busySum = 0.0, totalSum = 0.0
        for (i, t) in cur.enumerated() {
            let p = prevTicks[i]
            // CPU_STATE: 0 user, 1 system, 2 idle, 3 nice
            let busy = Double((t[0] &- p[0]) &+ (t[1] &- p[1]) &+ (t[3] &- p[3]))
            let idle = Double(t[2] &- p[2])
            let total = busy + idle
            per.append(total > 0 ? busy / total * 100 : 0)
            busySum += busy
            totalSum += total
        }
        return (totalSum > 0 ? busySum / totalSum * 100 : nil, per)
    }

    // MARK: applying rules

    func apply(rule: FanRule, to fan: Int) {
        rules[fan] = rule
        saveRules()
        commanded[fan] = nil
        derivState[fan] = nil
        switch rule {
        case .auto:
            _ = runCLI(["auto", "\(fan)"])
        case .constant(let rpm):
            _ = runCLI(["set", "\(fan)", "\(Int(rpm))"])
        case .sensor:
            runControlLoop()
        }
        poll()
    }

    func allAuto() {
        for f in fans { rules[f.id] = .auto }
        saveRules()
        _ = runCLI(["auto"])
        poll()
    }

    /// Full Blast: every fan to max (a constant rule at maxRPM, so the speed
    /// survives polling and shows up in the "Custom…" buttons).
    func fullBlast() {
        for f in fans {
            rules[f.id] = .constant(f.maxRPM)
            commanded[f.id] = nil
            derivState[f.id] = nil
        }
        saveRules()
        _ = runCLI(["max"])
        poll()
    }

    /// For app exit: hand the hardware back to SMC automatics WITHOUT
    /// touching saved rules — they re-engage on next launch.
    func releaseControlOnExit() {
        _ = runCLI(["auto"])
    }

    // MARK: persistence

    private var rulesURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SMCFan-rules.json")
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: rulesURL)
        }
    }

    private func loadRules() {
        guard let data = try? Data(contentsOf: rulesURL),
              let r = try? JSONDecoder().decode([Int: FanRule].self, from: data)
        else { return }
        rules = r
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, self.helperOK else { return }
            for (fan, rule) in self.rules {
                if case .constant(let rpm) = rule { _ = self.setRPMQuiet(fan: fan, rpm: rpm) }
            }
        }
    }

    // MARK: writing via the setuid helper

    private var cliPath: String? {
        var candidates: [String] = []
        if let exe = Bundle.main.executableURL {
            let dir = exe.deletingLastPathComponent()
            candidates.append(dir.appendingPathComponent("smcfan-cli").path)
            candidates.append(dir.appendingPathComponent("smcfan").path)
        }
        candidates.append("/usr/local/bin/smcfan")
        candidates.append(FileManager.default.currentDirectoryPath + "/smcfan")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func checkHelper() {
        guard let path = cliPath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let perms = attrs[.posixPermissions] as? NSNumber,
              let owner = attrs[.ownerAccountID] as? NSNumber
        else { helperOK = false; return }
        helperOK = owner.intValue == 0 && (perms.intValue & 0o4000) != 0
    }

    @discardableResult
    private func runCLI(_ args: [String]) -> Bool {
        guard let path = cliPath else {
            alertMessage = L("Helper smcfan-cli not found (rebuild: make app).")
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            alertMessage = String(format: L("Failed to launch helper: %@"),
                                  error.localizedDescription)
            return false
        }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            alertMessage = String(format: L("Helper failed.\n%@\nMost likely missing privileges — press “Grant helper privileges”."), out)
            return false
        }
        return true
    }

    /// As runCLI(set...) but silent — for the control loop.
    @discardableResult
    private func setRPMQuiet(fan: Int, rpm: Double) -> Bool {
        guard let path = cliPath else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["set", "\(fan)", "\(Int(rpm))"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Frequency via `smcfan-cli freq` (powermetrics under the hood, ~0.5 s
    /// per sample) — off the main thread, result lands in helperFreq for the
    /// next poll. Never more than one fetch in flight.
    private func fetchFreqViaHelper() {
        guard !helperFreqInFlight, let path = cliPath else { return }
        helperFreqInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var ghz: Double? = nil
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["freq"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            if (try? p.run()) != nil {
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8) ?? ""
                    if let mhz = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        ghz = mhz / 1000.0
                    }
                }
            }
            DispatchQueue.main.async {
                self?.helperFreq = ghz
                self?.helperFreqInFlight = false
            }
        }
    }

    func installHelper() {
        guard let path = cliPath else {
            alertMessage = L("Helper not found next to the app.")
            return
        }
        let script = "do shell script \"chown root:wheel '\(path)' && chmod 4755 '\(path)'\" " +
                     "with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err = err {
            alertMessage = String(format: L("Failed to grant privileges: %@"),
                                  "\(err[NSAppleScript.errorMessage] ?? "?")")
        }
        checkHelper()
    }
}

// MARK: - Graph colors

/// Graph background: calm gray normally, a blush of red while the CPU is
/// throttled — the color of user posteriors ignited by Apple's thermal design.
func graphBackground(hot: Bool) -> Color {
    hot ? Color.red.opacity(0.10) : Color.primary.opacity(0.04)
}

/// Nice X-axis tick times for a given window: round steps, aligned to the clock.
func xTicks(start: Date, span: TimeInterval) -> (dates: [Date], step: TimeInterval) {
    let step: TimeInterval
    switch span {
    case ..<90:    step = 15      // 1 min window  → every 15 s
    case ..<420:   step = 60      // 5 min         → every minute
    case ..<1200:  step = 180     // 15 min        → every 3 min
    case ..<4000:  step = 600     // 1 h           → every 10 min
    default:       step = 1800    // 2 h           → every 30 min
    }
    var t = (start.timeIntervalSinceReferenceDate / step).rounded(.up) * step
    let end = start.timeIntervalSinceReferenceDate + span
    var out: [Date] = []
    while t < end {
        out.append(Date(timeIntervalSinceReferenceDate: t))
        t += step
    }
    return (out, step)
}

/// Thin shared time axis under the graph stack. All graphs use the same
/// samples + window, so their X coordinates are identical to this strip's.
struct TimeAxis: View {
    let samples: [Sample]
    let window: TimeInterval

    private static let fmtHM: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let fmtHMS: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        GeometryReader { geo in
            let now = samples.last?.time ?? Date()
            let dataStart = samples.first?.time ?? now
            let span = min(window, max(now.timeIntervalSince(dataStart), 10))
            let start = now.addingTimeInterval(-span)
            let (ticks, step) = xTicks(start: start, span: span)
            let fmt = step < 60 ? Self.fmtHMS : Self.fmtHM
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.self) { t in
                    let x = 42 + CGFloat(t.timeIntervalSince(start) / span)
                               * (geo.size.width - 42)
                    Text(fmt.string(from: t))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .position(x: min(max(x, 24), geo.size.width - 24), y: 7)
                }
            }
        }
    }
}

/// Full-stack overlay: one continuous set of vertical time lines running
/// through every graph, the gaps, the legends — the whole column.
struct StackXGrid: View {
    let samples: [Sample]
    let window: TimeInterval

    var body: some View {
        GeometryReader { geo in
            let now = samples.last?.time ?? Date()
            let dataStart = samples.first?.time ?? now
            let span = min(window, max(now.timeIntervalSince(dataStart), 10))
            let start = now.addingTimeInterval(-span)
            XGrid(start: start, span: span, size: geo.size)
        }
        .allowsHitTesting(false)
    }
}

/// Vertical gridlines at the shared X ticks.
struct XGrid: View {
    let start: Date
    let span: TimeInterval
    let size: CGSize

    var body: some View {
        ForEach(xTicks(start: start, span: span).dates, id: \.self) { t in
            let x = 42 + CGFloat(t.timeIntervalSince(start) / span) * (size.width - 42)
            Path { p in
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
            }
            .stroke(Color.primary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
        }
    }
}

let sensorPalette: [Color] = [.red, .orange, .green, .blue, .purple, .pink,
                              .yellow, .gray, .cyan, .brown]

func plotColor(_ key: String, in sensors: [SensorReading]) -> Color {
    let idx = sensors.firstIndex { $0.key == key } ?? 0
    return sensorPalette[idx % sensorPalette.count]
}

// MARK: - "Custom…" popover

struct RuleEditor: View {
    @ObservedObject var model: Model
    let fan: FanState
    @Binding var isShown: Bool

    @State private var mode = 0
    @State private var rpm: Double = 2000
    @State private var sensorKey: String = "TCXC"   // CPU PECI is the best default
    @State private var from: Double = 50
    @State private var to: Double = 85

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: L("Fan control: %@"), fan.name)).font(.headline)

            Picker("", selection: $mode) {
                Text(L("Automatic (SMC)")).tag(0)
                Text(L("Constant RPM")).tag(1)
                Text(L("Sensor-based")).tag(2)
            }
            .pickerStyle(RadioGroupPickerStyle())
            .labelsHidden()

            if mode == 1 {
                HStack {
                    Slider(value: $rpm, in: fan.minRPM...max(fan.maxRPM, fan.minRPM + 1))
                    Text("\(String(Int(rpm))) RPM")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 80, alignment: .trailing)
                }
            }

            if mode == 2 {
                // Respect "Hide raw keys" here as well; keep the key already
                // selected in the rule so the selection never "vanishes".
                let pickable = model.sensors.filter {
                    !model.hideRawKeys || !$0.isRaw || $0.key == sensorKey
                }
                Picker(L("Sensor:"), selection: $sensorKey) {
                    ForEach(pickable) { s in
                        Text("\(s.name)  (\(String(format: "%.0f°", s.value)))").tag(s.key)
                    }
                }
                HStack {
                    Text(L("from"))
                    TextField("", value: $from, formatter: NumberFormatter())
                        .frame(width: 50)
                    Text(L("°C — min RPM, to"))
                    TextField("", value: $to, formatter: NumberFormatter())
                        .frame(width: 50)
                    Text(L("°C — max RPM"))
                }
                Text(String(format: L("RPM interpolates linearly between %@ and %@ RPM."),
                            String(Int(fan.minRPM)), String(Int(fan.maxRPM))))
                    .font(.caption).foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button(L("Cancel")) { isShown = false }
                Button(L("Apply")) {
                    let rule: FanRule
                    switch mode {
                    case 1:  rule = .constant(rpm)
                    case 2:  rule = .sensor(sensorKey, from, min(to, 110))
                    default: rule = .auto
                    }
                    model.apply(rule: rule, to: fan.id)
                    isShown = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            switch model.rules[fan.id] ?? .auto {
            case .auto:
                mode = 0
                rpm = fan.target > 0 ? fan.target : fan.minRPM
            case .constant(let r):
                mode = 1; rpm = r
            case .sensor(let k, let f, let t):
                mode = 2; sensorKey = k; from = f; to = t
            }
            if !model.sensors.contains(where: { $0.key == sensorKey }) {
                sensorKey = model.sensors.first(where: { $0.key == "TCXC" })?.key
                         ?? model.sensors.first(where: { $0.key == "TC0P" })?.key
                         ?? model.sensors.first?.key ?? "TCXC"
            }
        }
    }
}

// MARK: - Fan row

struct FanRowMFC: View {
    @ObservedObject var model: Model
    let fan: FanState
    @State private var showEditor = false

    private var ruleLabel: String {
        switch model.rules[fan.id] ?? .auto {
        case .auto:                 return L("Custom…")
        case .constant(let r):      return "\(String(Int(r))) RPM"
        case .sensor(let k, _, _):  return String(format: L("by %@"), sensorName(k))
        }
    }

    private var isAuto: Bool {
        if case .auto = model.rules[fan.id] ?? .auto { return !fan.manual }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "fanblades")
                .font(.title2)
                .foregroundColor(.secondary)
            Text(fan.name)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 90, alignment: .leading)

            HStack(spacing: 4) {
                Text(String(Int(fan.minRPM))).foregroundColor(.secondary)
                Text("—")
                Text(String(Int(fan.rpm)))
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(fan.rpm > fan.maxRPM * 0.85 ? .red : .primary)
                Text("—")
                Text(String(Int(fan.maxRPM))).foregroundColor(.secondary)
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 170)

            Spacer()

            Button(L("Auto")) { model.apply(rule: .auto, to: fan.id) }
                .disabled(isAuto)
            Button(ruleLabel) { showEditor = true }
                .popover(isPresented: $showEditor, arrowEdge: .bottom) {
                    RuleEditor(model: model, fan: fan, isShown: $showEditor)
                }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(graphBackground(hot: hot)))
    }
}

// MARK: - Sensor table

struct SensorTable: View {
    @ObservedObject var model: Model

    private var visibleSensors: [SensorReading] {
        let base = model.hideRawKeys ? model.sensors.filter { !$0.isRaw } : model.sensors
        return model.sortByTemp ? base.sorted { $0.value > $1.value } : base
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { model.sortByTemp = false }) {
                    Text(L("Sensor") + (model.sortByTemp ? "" : " ▼"))
                        .font(.caption).foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help(L("Sort by name"))
                Spacer()
                Button(action: { model.sortByTemp = true }) {
                    Text((model.sortByTemp ? "▼ " : "") + "°C")
                        .font(.caption).foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help(L("Sort by temperature"))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleSensors.enumerated()), id: \.element.key) { idx, s in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(plotColor(s.key, in: model.sensors))
                                .frame(width: 7, height: 7)
                                .opacity(model.plotted.contains(s.key) ? 1 : 0.15)
                            Text(s.name).font(.system(size: 12))
                            if s.isRaw {
                                Text(L("(raw key)")).font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.1f", s.value))
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(idx % 2 == 1 ? Color.primary.opacity(0.03) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if model.plotted.contains(s.key) { model.plotted.remove(s.key) }
                            else { model.plotted.insert(s.key) }
                        }
                        .help(L("Click to toggle this sensor on the graph"))
                    }
                }
            }
            Divider()
            Toggle(L("Hide raw keys"), isOn: $model.hideRawKeys)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
    }
}

// MARK: - RPM graph

let fanPalette: [Color] = [
    Color(red: 0.15, green: 0.55, blue: 0.90),   // Left — blue
    Color(red: 0.95, green: 0.55, blue: 0.10),   // Right — orange
    Color(red: 0.30, green: 0.75, blue: 0.45),
    Color(red: 0.70, green: 0.40, blue: 0.85),
]

func fanColor(_ id: Int) -> Color { fanPalette[id % fanPalette.count] }

struct RPMGraph: View {
    let samples: [Sample]
    let fans: [FanState]
    let window: TimeInterval
    var hot: Bool = false

    private func linePoints(fan: Int, pts: [Sample], start: Date, span: TimeInterval,
                            lo: Double, range: Double, size: CGSize) -> [CGPoint] {
        var out: [CGPoint] = []
        out.reserveCapacity(pts.count)
        for sm in pts {
            guard let v = sm.fanRPM[fan] else { continue }
            let x = 42 + CGFloat(sm.time.timeIntervalSince(start) / span) * (size.width - 42)
            let y = size.height * CGFloat(1 - (v - lo) / range)
            out.append(CGPoint(x: x, y: y))
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let now = samples.last?.time ?? Date()
            let dataStart = samples.first?.time ?? now
            let span = min(window, max(now.timeIntervalSince(dataStart), 10))
            let start = now.addingTimeInterval(-span)
            let pts = samples.filter { $0.time >= start }
            // fixed scale from spec min/max — the graph doesn't jump around
            let lo = (fans.map(\.minRPM).min() ?? 1000) * 0.92
            let hi = (fans.map(\.maxRPM).max() ?? 6000) * 1.03
            let range = max(hi - lo, 1)

            ZStack(alignment: .topLeading) {
                ForEach(0..<3, id: \.self) { i in
                    let frac = CGFloat(i) / 2
                    let y = geo.size.height * frac
                    Path { p in
                        p.move(to: CGPoint(x: 42, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.primary.opacity(0.25),
                            style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
                    Text(String(Int(hi - Double(frac) * range)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .position(x: 20, y: min(max(y, 7), geo.size.height - 7))
                }
                ForEach(fans) { f in
                    let line = linePoints(fan: f.id, pts: pts, start: start, span: span,
                                          lo: lo, range: range, size: geo.size)
                    if line.count > 1 {
                        // gradient fill under the curve
                        Path { p in
                            p.move(to: CGPoint(x: line[0].x, y: geo.size.height))
                            for pt in line { p.addLine(to: pt) }
                            p.addLine(to: CGPoint(x: line[line.count - 1].x,
                                                  y: geo.size.height))
                            p.closeSubpath()
                        }
                        .fill(LinearGradient(
                            gradient: Gradient(colors: [fanColor(f.id).opacity(0.30),
                                                        fanColor(f.id).opacity(0.02)]),
                            startPoint: .top, endPoint: .bottom))
                        // the line itself
                        Path { p in
                            p.move(to: line[0])
                            for pt in line.dropFirst() { p.addLine(to: pt) }
                        }
                        .stroke(fanColor(f.id),
                                style: StrokeStyle(lineWidth: 1.8,
                                                   lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(graphBackground(hot: hot)))
    }
}

// MARK: - Temperature graph

struct TempGraph: View {
    let samples: [Sample]
    let sensors: [SensorReading]
    let plotted: Set<String>
    let window: TimeInterval
    var hot: Bool = false

    var body: some View {
        GeometryReader { geo in
            let now = samples.last?.time ?? Date()
            let dataStart = samples.first?.time ?? now
            let span = min(window, max(now.timeIntervalSince(dataStart), 10))
            let start = now.addingTimeInterval(-span)
            let pts = samples.filter { $0.time >= start }
            let all = pts.flatMap { s in plotted.compactMap { s.values[$0] } }
            let lo = floor((all.min() ?? 30) - 3)
            let hi = ceil((all.max() ?? 90) + 3)
            let range = max(hi - lo, 1)

            ZStack(alignment: .topLeading) {
                ForEach(0..<5, id: \.self) { i in
                    let frac = CGFloat(i) / 4
                    let y = geo.size.height * frac
                    Path { p in
                        p.move(to: CGPoint(x: 42, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.primary.opacity(0.25),
                            style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
                    Text(String(format: "%.0f°", hi - Double(frac) * range))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .position(x: 20, y: min(max(y, 7), geo.size.height - 7))
                }
                ForEach(sensors.filter { plotted.contains($0.key) }) { s in
                    Path { p in
                        var started = false
                        for sm in pts {
                            guard let v = sm.values[s.key] else { continue }
                            let x = 42 + CGFloat(sm.time.timeIntervalSince(start) / span)
                                       * (geo.size.width - 42)
                            let y = geo.size.height * CGFloat(1 - (v - lo) / range)
                            if started { p.addLine(to: CGPoint(x: x, y: y)) }
                            else { p.move(to: CGPoint(x: x, y: y)); started = true }
                        }
                    }
                    .stroke(plotColor(s.key, in: sensors), lineWidth: 1.5)
                }
                if plotted.isEmpty {
                    Text(L("Click a sensor in the table on the right to plot it"))
                        .font(.caption).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if pts.count < 2 {
                    Text(L("Collecting data…"))
                        .font(.caption).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(graphBackground(hot: hot)))
    }
}

// MARK: - Metric mini-graphs (Power / Frequency / Utilization)

struct MetricLine {
    let label: String
    let color: Color
    let value: (Sample) -> Double?
}

struct MiniGraph: View {
    let title: String
    let unit: String
    let lines: [MetricLine]
    let samples: [Sample]
    let window: TimeInterval
    var fixedMax: Double? = nil
    var perCoreToggle: Binding<Bool>? = nil
    var hot: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title).font(.caption).bold()
                if lines.count <= 4 {   // a 12-core legend is mush, hide it
                    ForEach(lines.indices, id: \.self) { i in
                        let cur = samples.last.flatMap { lines[i].value($0) }
                        HStack(spacing: 3) {
                            Circle().fill(lines[i].color).frame(width: 6, height: 6)
                            Text(lines[i].label).font(.system(size: 9))
                            Text(cur.map { String(format: "%.1f", $0) } ?? "—")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
                if let toggle = perCoreToggle {
                    Picker("", selection: toggle) {
                        Text(L("Total")).tag(false)
                        Text(L("Per core")).tag(true)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .labelsHidden()
                    .frame(width: 150)
                }
                Text(unit).font(.system(size: 9)).foregroundColor(.secondary)
            }
            GeometryReader { geo in
                let now = samples.last?.time ?? Date()
                let dataStart = samples.first?.time ?? now
                let span = min(window, max(now.timeIntervalSince(dataStart), 10))
                let start = now.addingTimeInterval(-span)
                let pts = samples.filter { $0.time >= start }
                let allVals = pts.flatMap { s in lines.compactMap { $0.value(s) } }
                let hi = fixedMax ?? max((allVals.max() ?? 1) * 1.15, 1)

                ZStack(alignment: .topLeading) {
                        // Power Gadget-style grid: dense crisp dashes + labels
                    ForEach(0..<5, id: \.self) { i in
                        let frac = CGFloat(i) / 4
                        let y = geo.size.height * frac
                        Path { p in
                            p.move(to: CGPoint(x: 42, y: y))
                            p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(Color.primary.opacity(0.25),
                                style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
                        let v = hi - Double(frac) * hi
                        Text(String(format: hi < 10 ? "%.1f" : "%.0f", v))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .position(x: 20, y: min(max(y, 7), geo.size.height - 7))
                    }
                    ForEach(lines.indices, id: \.self) { i in
                        Path { p in
                            var started = false
                            for sm in pts {
                                guard let v = lines[i].value(sm) else { continue }
                                let x = 42 + CGFloat(sm.time.timeIntervalSince(start) / span)
                                           * (geo.size.width - 42)
                                let y = geo.size.height * CGFloat(1 - min(v, hi) / hi)
                                if started { p.addLine(to: CGPoint(x: x, y: y)) }
                                else { p.move(to: CGPoint(x: x, y: y)); started = true }
                            }
                        }
                        .stroke(lines[i].color, lineWidth: lines.count > 4 ? 0.9 : 1.4)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 5).fill(graphBackground(hot: hot)))
        }
    }
}

// MARK: - Reaction settings (global for all sensor-based rules)

struct ReactionEditor: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Reaction settings")).font(.headline)
            Text(L("Shared by all sensor-based rules."))
                .font(.caption).foregroundColor(.secondary)

            Divider()

            HStack {
                Text(L("Spike boost")).frame(width: 110, alignment: .leading)
                Slider(value: $model.boostPerDeg, in: 0...2000, step: 50)
                Text(String(Int(model.boostPerDeg)))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
            }
            Text(L("Extra RPM per 1 °C/s of temperature rise. 0 = off."))
                .font(.caption2).foregroundColor(.secondary)

            HStack {
                Text(L("Release speed")).frame(width: 110, alignment: .leading)
                Slider(value: $model.releaseRPMps, in: 50...1000, step: 25)
                Text(String(Int(model.releaseRPMps)))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 40, alignment: .trailing)
            }
            Text(L("How fast RPM may fall, per second. Lower = holds longer."))
                .font(.caption2).foregroundColor(.secondary)

            Divider()

            if model.hasFreq {
                Toggle(L("Throttle guard"), isOn: $model.throttleGuard)
                if model.throttleGuard {
                    HStack {
                        Text(L("Throttled below")).frame(width: 110, alignment: .leading)
                        Slider(value: $model.throttleGHz, in: 0.8...3.0, step: 0.1)
                        Text(String(format: "%.1f GHz", model.throttleGHz))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 55, alignment: .trailing)
                    }
                }
                Text(L("If core frequency drops below this while the CPU is busy, sensor-based fans go to maximum until it recovers. Catches VRM/BD PROCHOT throttling that temperature rules can't see."))
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                Text(L("Throttle guard needs Intel Power Gadget for frequency data."))
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

// MARK: - Main window

struct ContentView: View {
    @ObservedObject var model = Model.shared
    @State private var showReaction = false

    private var windows: [(String, TimeInterval)] {
        [(L("1 min"), 60), (L("5 min"), 300), (L("15 min"), 900),
         (L("1 h"), 3600), (L("2 h"), 7200)]
    }

    private var utilLines: [MetricLine] {
        if model.utilPerCore {
            let n = model.samples.last?.utilCores.count ?? 0
            return (0..<n).map { i in
                MetricLine(label: "\(i)",
                           color: Color(hue: Double(i) / Double(max(n, 1)),
                                        saturation: 0.65, brightness: 0.80),
                           value: { s in
                               s.utilCores.indices.contains(i) ? s.utilCores[i] : nil
                           })
            }
        }
        return [MetricLine(label: L("Total"), color: .blue, value: { $0.utilTotal })]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {

            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.fans) { fan in
                    FanRowMFC(model: model, fan: fan)
                }

                HStack {
                    Button(L("All fans to auto")) { model.allAuto() }
                    Button(L("Full Blast")) { model.fullBlast() }
                    Button(L("Reaction…")) { showReaction = true }
                        .popover(isPresented: $showReaction, arrowEdge: .bottom) {
                            ReactionEditor(model: model)
                        }
                    if model.throttleActive {
                        Text(L("THROTTLE"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.red))
                    }
                    Text(L("Language"))
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.leading, 8)
                    Picker("", selection: $model.language) {
                        ForEach(AppLanguage.available()) { l in Text(l.label).tag(l) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    Spacer()
                    if !model.helperOK {
                        Button(L("Grant helper privileges…")) { model.installHelper() }
                    }
                    Picker("", selection: $model.window) {
                        ForEach(windows, id: \.1) { w in Text(w.0).tag(w.1) }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 300)
                }

                VStack(alignment: .leading, spacing: 10) {
                TempGraph(samples: model.samples,
                          sensors: model.sensors,
                          plotted: model.plotted,
                          window: model.window,
                          hot: model.throttleActive)
                    .frame(minHeight: 140)

                // chips: line color + live RPM
                HStack(spacing: 14) {
                    ForEach(model.fans) { f in
                        HStack(spacing: 5) {
                            Circle().fill(fanColor(f.id)).frame(width: 8, height: 8)
                            Text(f.name).font(.caption)
                            Text("\(String(Int(f.rpm))) RPM")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.leading, 42)

                RPMGraph(samples: model.samples,
                         fans: model.fans,
                         window: model.window,
                         hot: model.throttleActive)
                    .frame(height: 100)

                // --- Power / Frequency / Utilization, Power Gadget-style ---
                MiniGraph(title: L("Power"), unit: "W",
                          lines: [
                            MetricLine(label: "PKG",  color: .blue,
                                       value: { $0.power["PKG"] }),
                            MetricLine(label: "CORE", color: .teal,
                                       value: { $0.power["CORE"] }),
                            MetricLine(label: "DRAM", color: .orange,
                                       value: { $0.power["DRAM"] }),
                          ],
                          samples: model.samples, window: model.window,
                          hot: model.throttleActive)
                    .frame(height: 116)
                if model.hasFreq {
                    MiniGraph(title: L("Frequency"), unit: "GHz",
                              lines: [MetricLine(label: "CORE", color: .purple,
                                                 value: { $0.freqGHz })],
                              samples: model.samples, window: model.window,
                              fixedMax: 5, hot: model.throttleActive)
                        .frame(height: 116)
                }
                MiniGraph(title: L("Utilization"), unit: "%",
                          lines: utilLines,
                          samples: model.samples, window: model.window,
                          fixedMax: 100,
                          perCoreToggle: $model.utilPerCore,
                          hot: model.throttleActive)
                    .frame(height: 116)

                TimeAxis(samples: model.samples, window: model.window)
                    .frame(height: 14)
                }
                .overlay(StackXGrid(samples: model.samples, window: model.window))
                .animation(.easeInOut(duration: 0.6), value: model.throttleActive)
            }
            .frame(minWidth: 480)

            SensorTable(model: model)
                .frame(width: 280)
        }
        .padding(12)
        .frame(minWidth: 820, minHeight: 840)
        .alert(item: Binding(
            get: { model.alertMessage.map { AlertBox(text: $0) } },
            set: { _ in model.alertMessage = nil })) { box in
            Alert(title: Text("Mac Fanatic"), message: Text(box.text))
        }
    }
}

struct AlertBox: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - Menu bar + App

// Intercept window closing: hide instead of destroying, otherwise SwiftUI
// may release the window and "Show window" would be poking a corpse.
// Every other delegate call is forwarded to SwiftUI's original delegate.
final class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if original?.responds(to: aSelector) == true { return original }
        return super.forwardingTarget(for: aSelector)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private weak var mainWindow: NSWindow?
    private let interceptor = WindowCloseInterceptor()
    private var showItem: NSMenuItem?
    private var autoItem: NSMenuItem?
    private var blastItem: NSMenuItem?
    private var quitItem: NSMenuItem?
    private var langWatcher: AnyCancellable?
    private var throttleWatcher: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        item.button?.title = "--°"
        // template fan icon: adapts to light/dark menu bar automatically
        if let img = NSImage(systemSymbolName: "fanblades",
                             accessibilityDescription: "Mac Fanatic") {
            img.isTemplate = true
            item.button?.image = img
            item.button?.imagePosition = .imageLeft
        }

        let menu = NSMenu()
        let show = NSMenuItem(title: L("Show window"), action: #selector(showWindow),
                              keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let auto = NSMenuItem(title: L("All fans to auto"), action: #selector(allAuto),
                              keyEquivalent: "")
        auto.target = self
        menu.addItem(auto)
        let blast = NSMenuItem(title: L("Full Blast"), action: #selector(fullBlast),
                               keyEquivalent: "")
        blast.target = self
        menu.addItem(blast)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit"), action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        showItem = show; autoItem = auto; blastItem = blast; quitItem = quit

        Model.shared.statusHandler = { [weak item] title, tooltip in
            item?.button?.title = title
            item?.button?.toolTip = tooltip
        }

        // language change → refresh status-bar menu item titles
        langWatcher = Model.shared.$language
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.showItem?.title = L("Show window")
                self?.autoItem?.title = L("All fans to auto")
                self?.blastItem?.title = L("Full Blast")
                self?.quitItem?.title = L("Quit")
            }

        // throttle guard active → tint the menu bar item red
        throttleWatcher = Model.shared.$throttleActive
            .receive(on: DispatchQueue.main)
            .sink { [weak item] active in
                item?.button?.contentTintColor = active ? .systemRed : nil
            }

        // Grab the main window with retries: a single async shot isn't
        // enough, SwiftUI may create the window later.
        grabWindow(attempt: 0)
    }

    private func grabWindow(attempt: Int) {
        if let w = findMainWindow() {
            captureWindow(w)
            return
        }
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * Double(attempt + 1)) {
            [weak self] in self?.grabWindow(attempt: attempt + 1)
        }
    }

    private func findMainWindow() -> NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
    }

    private func captureWindow(_ w: NSWindow) {
        mainWindow = w
        w.isReleasedWhenClosed = false
        // Otherwise quitting with the window hidden → state restoration
        // "restores" a windowless state on next launch and the app starts bare.
        w.isRestorable = false
        if w.delegate !== interceptor {
            interceptor.original = w.delegate
            w.delegate = interceptor
        }
    }

    /// Programmatically trigger File → New Window (⌘N) without depending
    /// on the localized menu title.
    private func triggerNewWindow() {
        for top in NSApp.mainMenu?.items ?? [] {
            for item in top.submenu?.items ?? []
            where item.keyEquivalent == "n" && item.keyEquivalentModifierMask == [.command] {
                if let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: nil)
                }
                return
            }
        }
    }

    @objc private func showWindow() {
        if mainWindow == nil { mainWindow = findMainWindow() }
        if let w = mainWindow {
            captureWindow(w)
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // No window at all (restoration launched the app windowless) —
        // create one the way File → New Window does, then bring it to front.
        triggerNewWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, let w = self.findMainWindow() else { return }
            self.captureWindow(w)
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func allAuto() { Model.shared.allAuto() }
    @objc private func fullBlast() { Model.shared.fullBlast() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Safety net: return SMC automatics on exit so fans aren't stuck forever
    // at the last commanded RPM with no control loop running.
    // Saved rules are untouched — they re-engage on next launch.
    func applicationWillTerminate(_ notification: Notification) {
        Model.shared.releaseControlOnExit()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }
}

@main
struct SMCFanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Mac Fanatic  (\(Model.shared.hwModel))") {
            ContentView()
        }
    }
}
