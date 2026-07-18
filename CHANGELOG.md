# Changelog

## Unreleased

### Added
- **Process list**: per-process CPU % and Apple's Energy Impact via
  `powermetrics --samplers tasks` (plist) through the setuid helper.
  Panel under the sensor table, top 20, sortable by either column,
  toggleable and persisted; sampling runs only while the panel is shown.
  New CLI command: `smcfan tasks`.
- **Cumulative Energy Impact** (Σ column): impact integrated over wall
  time per process name since launch/reset — surfaces the quiet
  always-on hogs that never top an instantaneous list. Third sort mode,
  reset button, sleep gaps excluded from integration.
- **Resizable splitter** between the graph column and the sensor/process
  column (drag the divider; right pane 240–480 px).

### Changed
- powermetrics' `DEAD_TASKS` aggregate is kept (short-lived processes
  carry real energy during builds and scripts) but shown as a human
  label, italic, with an explanatory tooltip.
- Process table polish: full process name on hover (truncation-proof),
  the active sort column is highlighted, and the CPU % header explains
  the 100%-per-core convention.
- **Resizable splitter** between the graph stack and the side panels
  (sensors/processes) — drag to trade graph width for name width.

### Changed
- Panel polish: full process names in hover tooltips, the active sort
  column highlighted in both tables, and a hint on the CPU % header
  (100% = one core, Activity Monitor style).

## 1.0.1

### Added
- **Throttle history bands**: every throttle episode is recorded and drawn
  as a pink band across all graphs, from onset to recovery — a lasting
  visual record instead of a momentary alarm. Bands survive as long as the
  sample history covers them and scroll away with it.
- **Shared X axis**: clock-aligned vertical gridlines running continuously
  through the whole graph stack, plus a time strip (HH:mm) at the bottom.
  Tick step adapts to the window (15 s at 1 min … 30 min at 2 h).
- **Persistence**: the set of sensors plotted on the temperature graph and
  the last non-auto rule per fan now survive restarts. Switching a fan to
  Auto no longer wipes its custom setup — the editor restores it.
- **Single-source versioning**: a `VERSION` file injected by `make` into
  Info.plist, the CLI binary (`-DSMCFAN_VERSION`), the window title, the
  README badge, and the DMG volume name. `make bump V=x.y.z`.
- **`smcfan freq`**: average CPU frequency in MHz via Apple's
  `powermetrics` through the setuid helper — real APERF/MPERF-based
  frequency with no Intel Power Gadget installed. The throttle guard works
  either way; only the DRAM power line still requires Power Gadget.
- **Icon pipeline**: `make icon` builds AppIcon.icns from `icon.png`
  (auto-invoked by `make app` when the PNG is present).
- **`make dmg`**: distributable image with the drag-to-Applications layout.
- Sensor table sortable by temperature (click the column headers).

### Changed
- **Throttle guard drives every fan** while active — auto, constant, and
  sensor-based alike — and restores each fan's own rule on release.
  Previously only sensor-based rules were overridden.
- Guard entry threshold for "CPU busy" lowered from 40% to 15%:
  GPU-heavy renders throttle the CPU while keeping its utilization modest.
- Guard entry debounced to 2 consecutive below-threshold samples.
- Menu bar shows a template fan icon + temperature only; RPM, per-fan
  modes, and reaction settings moved to the hover tooltip. The icon turns
  red while the guard is active.
- Frequency graph shows/hides itself based on actual data availability
  rather than "framework loaded".

### Fixed
- **Phantom throttle detections**: the powermetrics frequency fallback no
  longer kicks in on a transient Power Gadget hiccup — the two sources
  average differently (a light-load powermetrics sample legitimately reads
  ~1.2 GHz), and per-sample source mixing faked throttle episodes.
  The fallback now engages only when Power Gadget is considered dead, and
  missing data holds detector state instead of resetting it.
- **Sleep/wake handling**: a gap detector resets all interval-based state
  (derivative EMA, commanded RPM, CPU ticks, PG sample anchor), closes an
  open throttle span at the last pre-sleep moment instead of smearing a
  giant pink band across the nap, and all graphs break their lines at gaps
  instead of bridging them.
- **Stale Power Gadget sessions self-heal**: a session yielding empty
  samples (framework alive, data dead — happens when the PG app has never
  run) is shut down and re-initialized in place after 3 empty reads.
- SMC power fallback probes a list of candidate keys per model
  (PCPT/PSTR/PCTR/PDTR, PCPC/PC0C/PC0R) instead of assuming two.

### Notes
- Intel Power Gadget's background agent is known to hold a
  `PreventUserIdleSystemSleep` power assertion indefinitely (observed:
  209+ hours), keeping the machine from ever sleeping. With the setuid
  helper installed you can uninstall Power Gadget entirely and lose only
  the DRAM power line.

## 1.0.0 — initial release

Born in one very long day as "write me a Macs Fan Control analog";
shipped as something the original doesn't do.

### Fan control
- Per-fan modes: **SMC automatic**, **constant RPM**, **sensor-based**
  (RPM linearly interpolated between hardware min/max over a configurable
  temperature range of any SMC sensor).
- **PD control loop** for sensor-based rules:
  - *Spike boost* (D term) — extra RPM per °C/s of temperature rise;
    fans spin up ahead of the heat (0–2000, default 800);
  - *Release speed* — asymmetric attack/decay: RPM rises instantly, falls
    no faster than the configured rate (50–1000 RPM/s, default 150), so
    airflow keeps working after the load drops.
- **Throttle guard**: detects VRM/BD PROCHOT-style throttling — core
  frequency pinned low while the CPU is busy, possibly with a *cold* core,
  invisible to any temperature rule — and runs fans at maximum until the
  frequency actually recovers. No "load is gone" early exit: a stuck state
  persists at idle and max airflow is what cures it. Red THROTTLE badge in
  the window, red-tinted menu bar icon while active. Configurable threshold
  (default 1.6 GHz).
- **Full Blast** and **All fans to auto** one-click actions (window +
  status-bar menu).
- Rules persist across launches (`~/Library/Application Support/`);
  on quit the app returns fans to SMC automatics without touching saved
  rules — they re-engage on next launch.

### Sensors
- Sensor list is **enumerated from SMC** (`#KEY` + `SMC_CMD_READ_INDEX`),
  not hardcoded: per-core CPU temps, heatsinks, SSD, Thunderbolt, and
  whatever else the machine exposes.
- Friendly names for known keys; unknown ones shown as raw four-char codes
  with a "Hide raw keys" toggle.
- Sortable by name or by temperature (click the column headers).

### Graphs
- Six time-aligned live graphs: temperatures, fan RPM (gradient-filled,
  per-fan colors), CPU power (PKG/CORE/DRAM), core frequency, utilization
  (total or per-logical-core, 12 lines on HT six-cores).
- Selectable time window: 1 min / 5 min / 15 min / 1 h / 2 h;
  ~2 h of history kept in memory.
- Shared X axis: clock-aligned vertical gridlines across every graph and a
  time strip (HH:mm) under the stack.
- Power Gadget-style crisp dashed grid with value labels on every graph.
- Click a sensor row to add/remove its line on the temperature graph.

### Metrics & data sources
- SMC via IOKit for temperatures, fans, and power fallback — reading needs
  no privileges.
- `host_processor_info` (Mach) for total and per-core CPU utilization.
- **Intel Power Gadget framework via `dlopen`** (optional) for RAPL power
  (PKG/CORE/DRAM) and core frequency; every symbol resolved with `dlsym`,
  missing symbols degrade gracefully.
- **Self-healing PG session**: a stale session that yields empty samples
  (framework alive, data dead — happens when the PG app hasn't run) is
  detected after 3 empty reads and re-initialized in place.
- **`powermetrics` frequency fallback** through the setuid helper — real
  APERF/MPERF-based effective frequency with no Power Gadget installed at
  all. The throttle guard works either way; only the DRAM power line
  strictly requires Power Gadget.
- Frequency graph shows/hides itself based on actual data availability.

### App & UX
- Menu bar: template fan icon + average CPU core temperature; hover
  tooltip with per-fan RPM and mode, reaction settings, and throttle-guard
  state; menu with Show window / All auto / Full Blast / Quit.
- Window survives the red close button (hidden, not destroyed) and state
  restoration quirks; "Show window" always works, recreating the window if
  macOS restored a windowless session.
- Dynamic localization: languages discovered from `*.lproj` bundles at
  runtime, in-app picker with instant switching (English base + Russian
  included; adding a language is one `.strings` file).
- Reaction settings live in their own popover — they are global for all
  sensor-based rules, and the UI now says so honestly.

### CLI (`smcfan`)
- Standalone tool: `status`, `set <fan> <rpm>`, `max [fan]`, `auto [fan]`,
  `watch [sec]`, `freq` (average CPU MHz via `powermetrics`).
- Handles both SMC fan-key generations: `F0Md` + `flt ` (~2016+) and
  `FS! ` bitmask + `fpe2` (older).
- RPM clamped to hardware min/max; per-fan auto restore.
- Ships inside the bundle as `smcfan-cli` (APFS is case-insensitive;
  `smcfan` would collide with the app binary — found out the hard way).

### Build & packaging
- No Xcode project: single Swift file + single C file, built with
  Command Line Tools (`make app`).
- `make helper` — one-time setuid for the write helper (the GUI itself
  never runs as root); also available as an in-app button.
- `make icon` — AppIcon.icns from a PNG (auto-invoked by `make app` when
  `icon.png` is present).
- `make dmg` — distributable image with the drag-to-Applications layout.
- README documents Gatekeeper quirks for unsigned DMG installs and why the
  helper must be re-granted after copying.

### Notable bugs fixed along the way
- Swift/C struct layout mismatch: Swift adds no tail padding to nested
  structs, shifting every SMC field by 3 bytes — the kernel silently read
  garbage and every SMC call returned nothing.
- APFS case-insensitivity: `smcfan` overwrote `SMCFan` inside the bundle,
  replacing the GUI with the CLI.
- SwiftUI released the main window on close; state restoration could
  launch the app windowless.
- Status-bar "Quit" was disabled (wrong target for `terminate:`).
- Throttle guard originally released when load dropped — exactly when a
  stuck VRM still needed airflow. It now releases only on frequency
  recovery.
- Quitting no longer wipes saved rules while returning fans to automatic.
