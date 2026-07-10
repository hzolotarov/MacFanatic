# Mac Fanatic

Fan control for Intel Macs with a PD control loop, throttle guard, and
Power Gadget-style live graphs. Born as a Macs Fan Control clone, ended up
doing a few things the original doesn't.

![macOS 12+](https://img.shields.io/badge/macOS-12%2B-blue) ![Intel only](https://img.shields.io/badge/arch-Intel-lightgrey)

## Features

- **Fan control** per fan: SMC automatic, constant RPM, or **sensor-based** —
  RPM linearly interpolated between min/max over a configurable temperature
  range of any SMC sensor.
- **PD control loop** for sensor-based rules:
  - *Spike boost* (D term): extra RPM per °C/s of temperature rise —
    fans spin up ahead of the heat instead of chasing it;
  - *Release speed*: asymmetric attack/decay — RPM rises instantly but falls
    slowly, so airflow keeps working after the load (and the throttle) is gone.
- **Throttle guard**: detects VRM/BD PROCHOT-style throttling (frequency
  pinned low while the CPU is busy — the core may be *cold*, temperature
  rules can't see it) and runs fans at maximum until frequency recovers.
  Shows a red THROTTLE badge while active.
- **Full sensor list**: keys are enumerated from SMC (`#KEY` +
  `SMC_CMD_READ_INDEX`), not hardcoded — per-core CPU temps, heatsinks,
  SSD, Thunderbolt, and whatever else your machine exposes. Known keys get
  friendly names; unknown ones show as raw four-char codes (hideable).
  Sortable by name or by temperature.
- **Live graphs**, all time-aligned: temperatures, fan RPM (gradient-filled),
  CPU power (PKG/CORE/DRAM), core frequency, utilization (total or per-core).
- **Data sources**: SMC via IOKit (no root for reading);
  `host_processor_info` for utilization; Intel Power Gadget's framework
  (via `dlopen`, optional) for power/frequency, with an SMC fallback
  (`PCPT`/`PCPC`) for power when Power Gadget is absent.
- **Menu bar**: live `°C + rpm`, quick actions (show window, all auto,
  full blast, quit). Closing the window keeps the app running.
- **Localization** picked up dynamically from `*.lproj` folders — adding a
  language is one `.strings` file, zero code changes. In-app language picker.
- Rules persist across launches; on quit the app hands fans back to SMC
  automatics without touching saved rules.

## Architecture

Two components:

1. **`smcfan`** — a ~350-line C CLI talking to AppleSMC through IOKit.
   Reads fan state and temperatures, writes fan mode/target. Handles both
   key generations (`F0Md`+`flt ` on ~2016+, `FS! `+`fpe2` on older).
   Useful standalone: `status`, `set <fan> <rpm>`, `max`, `auto`, `watch`.
2. **`MacFanatic.app`** — a single-file SwiftUI app. Reads SMC natively
   (no privileges needed); all *writes* go through the `smcfan` binary,
   which gets setuid root once (the smcFanControl approach). The GUI never
   runs as root.

The setuid helper is a deliberate trade-off: any local user can spin your
fans. Fine for a personal machine; if that bothers you, skip `make helper`
and drive the CLI with `sudo` yourself.

## Requirements

- Intel Mac, macOS 12+
- Xcode Command Line Tools (`xcode-select --install`) — build only
- **[Intel Power Gadget](https://www.intel.com/content/www/us/en/developer/articles/tool/power-gadget.html)** — *optional but strongly recommended.*
  Core frequency and per-rail power (RAPL) live in MSRs, which are not
  readable from userspace; Power Gadget ships the kext that exposes them,
  and Mac Fanatic loads its framework at runtime via `dlopen`
  (`/Library/Frameworks/IntelPowerGadget.framework`). No SDK or linking
  involved — just install the app.

| Feature                          | Without Power Gadget | With Power Gadget |
|----------------------------------|----------------------|-------------------|
| Fan control (all modes)          | ✅                   | ✅                |
| Temperatures, RPM, utilization   | ✅                   | ✅                |
| Power graph (PKG/CORE)           | ✅ via SMC fallback  | ✅ RAPL           |
| Power graph (DRAM)               | ❌                   | ✅                |
| Frequency graph                  | ❌ (hidden)          | ✅                |
| **Throttle guard**               | ❌ (needs frequency) | ✅                |

The throttle guard is the headline feature for 2018 i9 owners — it detects
VRM/BD PROCHOT throttling by watching frequency, which no temperature
sensor can see. Without Power Gadget it is silently unavailable.

## Build

```bash
make app                     # builds the CLI, the GUI, and MacFanatic.app
make helper                  # one-time: setuid for the helper (asks for sudo)
make icon SRC=icon.png  # optional: generate AppIcon.icns (before make app)
open MacFanatic.app
```

## Adding a language

```bash
mkdir de.lproj
cp ru.lproj/Localizable.strings de.lproj/   # translate the values
make app
```

The language picker discovers `*.lproj` folders automatically.

## Notes

- Manual fan settings do not survive a reboot or SMC reset — the machine
  falls back to automatic on its own. The app also restores automatics
  on normal exit. If it's killed with `kill -9`, run `./smcfan auto`.
- RPM is clamped to the SMC-reported min/max per fan; you can't set values
  outside the hardware envelope.
- Apple Silicon is not supported (different SMC keys and write path).

