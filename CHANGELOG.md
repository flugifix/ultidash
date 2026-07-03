# Changelog

All notable changes to UltiDash are documented here.

## v0.5.1 — 2026-07-03

Bugfix release.

### Fixed
- **Crash on first placement without a config file** (`ERROR create(): attempt to get
  length of a nil value (local 'items')`): the one-time migration snapshot that seeds
  `cfg_m_<slot>.cfg` still iterated the settings groups directly and tripped over the
  new *Alerts* submenu (which has sub-pages instead of a flat item list). It now uses
  the submenu-aware iterator, so the per-alert settings are included in the snapshot
  too.
- **Hardening against EdgeTX's 20 000-instruction "CPU limit"**: the migration
  snapshot + cfg file write no longer run inside the same `create()`/`update()` call
  as the full UI build — they are deferred to a `refresh()` cycle of their own (one
  skipped 20 Hz frame, invisible).

## v0.5 — 2026-07-03

Major feature release on top of v0.4: per-alert configuration, master-volume control,
the ESC-load monitor, the Toolbox (RF adjustment map/editor), a main-power-lost flight
mode and a native-picker settings overhaul. **Experimental — still under testing in the
field.**

### ⚠️ Breaking / upgrade notes
- **Switch selections must be re-picked once** (*Settings ▸ Switch voice* and the Toolbox
  activation switch): the rows now use EdgeTX's **native switch picker** and new storage
  keys; old selections are ignored (no auto-migration — an in-widget migration tripped
  the CPU limit on SD remount).
- **Thresholds regrouped:** the ESC-load thresholds moved to the new **ESC load** group
  (with new keys — re-check them if you used the v0.4 ESC-load preview), *TPWR bar max*
  moved to **Display**, and the global *Callout interval* is gone — repeat cadence is now
  **per alert** (Fuel/Voltage default to the historical 6 s continuous cadence).
- The global *Vibrate on critical* switch was replaced by a **per-alert Vibrate** switch
  (defaults reproduce the old behaviour).

### Added
- **Per-alert configuration** (*Settings ▸ Alerts* is now a submenu with one page per
  alert): **Active / Repeat / Repeat count (0 = until cleared) / Repeat interval /
  Escalation volume / Vibrate / Overlay (prep)** for each of the 11 alerts.
- **Volume group** with two loudness worlds: the per-WAV **Callout volume** (moved from
  Alerts) and an optional **master-volume bridge via GVAR** — UltiDash drives the radio's
  master volume to **Normal volume (%)** while connected and boosts it to **Escalation
  volume (%)** while an alert with *Escalation volume* is active (sentinel −1024 releases
  the volume back to the pot). Real LVGL sliders for the two percentages.
- **BEC voltage alert** (relative, self-calibrating): warns when the live BEC drops a
  configurable % below the flight's own reference voltage — works for any 5/6/8.4 V BEC
  without configuration. New sounds `bec_low` / `bec_crit` (en + de).
- **ESC load monitor** (new *ESC load* settings group): a model GVAR holds the ESC's
  continuous-current limit (A); UltiDash computes load % = current/limit, shows a
  green/yellow/red **utilization bar** under the dashboard's Current row plus a new
  **ESC Load (calc)** telemetry slot, and (separate opt-in alert, sustained-load gated
  with a hold time) warns at configurable warn/critical %. One clear **ESC load
  monitoring** master switch; off = feature fully off. New sounds `escl_warn` /
  `escl_crit` (en + de).
- **Main-power-lost mode** (buffer takeover): a collapsed main pack with live telemetry
  flips the dashboard into a dedicated state — status line **MAIN POWER LOST**, main
  voltage `--`, fuel/voltage callouts suppressed; the power callout speaks the **live BEC
  voltage** with every repeat (an audible buffer countdown) and **`pwr_ok`** (new sound,
  en + de) announces recovery if the pack comes back mid-flight.
- **Toolbox** (main-menu entry + activation switch): the **RF Adjustment Map** and
  **RF Adjustment Editor** tool pages integrated as UltiDash tool pages (matching
  palette, sunlight mode, voice bank announce (`bank` sound), configurable
  config/value channels, GVAR pulse editor). Setup guide in `docs/TOOLBOX.md`.
- **Fuel-callout density settings** (*Battery*): announce-below level, coarse step,
  dense-below level and fine step (defaults = the historical cadence).
- **Raw telemetry sensors** in the value slots: each Tele Main / Tele Details row is now
  a **two-field hybrid** — the curated dropdown plus EdgeTX's **native telemetry source
  picker**, so *any* sensor on the radio can be shown (persisted with its source index so
  it survives restarts).
- **Status detail page redesign:** bordered status card (arm/gov/throttle, ESC status,
  arming status with the **full arming-disable reason list**), **scrollable** timestamped
  ESC event log (▲/▼ paging, position readout), footer with free-heap readout.
- **Status/config overview** (menu ▸ Status and the passive *Status info* view): grouped
  sections covering thresholds & their source, per-alert switches with a repeat summary,
  ESC-load state and the volume setup.

### Changed
- **Settings menu:** groups reorganized (Display / Tele Main / Tele Details / Battery /
  Thresholds / **ESC load** / **Volume** / **Alerts** / Switch voice / General /
  **Toolbox**); Thresholds page now has section headers (*Link & signal*, *Power & BEC*).
- **Telemetry detail page shows raw sensor data** (live EdgeTX readings, not the
  dashboard's latched values).
- **BEC value is live** (the latch is gone); it is held through a supply collapse so the
  buffer rail stays readable.
- **Performance:** disconnected idle throttle (2 Hz instead of 5), memoized per-frame
  allocators, deduplicated 5 Hz reads (ARM/settings/model info cached), repeat summary
  rebuilt only when settings change.
- **Debug log:** flushes **in flight** now — incremental appends (only new lines) at a
  conservative 10 s cadence while armed (3 s disarmed), so a crash loses at most the last
  few seconds; per-session file cap (~5000 lines) with a marker line.

### Fixed
- **Raw-sensor slots showed `-`**: raw picks are now read via their verified source
  index (the stored display name doesn't round-trip through EdgeTX's name lookup),
  including the detail page's min/max.
- **Stats page reappearing after dismiss** in the main-power-lost aftermath (an armed
  flicker reset the dismiss flag): arm-clear is debounced and reconnects no longer reset
  the dismissal.
- **ESC-load GVAR hygiene:** the limit GVAR is only probed/zeroed while the feature is
  actually enabled — a stale config value can no longer touch an unrelated GVAR.

## v0.4 — 2026-06-29

Feature + polish + performance release on top of v0.3. **Experimental — still under
testing in the field.**

### Added
- **Voice language option** (*Alerts ▸ Voice language*: English / Deutsch) with a full
  **German voice pack** in `/SOUNDS/de/ultidash/`. Spoken numbers/units still come from the
  EdgeTX voice pack (the radio's system language).
- **"UltiDash dark" color scheme** — a third *Display ▸ Color scheme* option: high-contrast
  **white text on black** with **vivid neon accents** (focus, warning, "tap to close") and
  neon green/yellow/red bars (link bars, ELRS detail, battery gauge) for strong contrast on
  the dark panel.
- **Readable battery-gauge values:** the cell-count and used-mAh now sit on **translucent
  rounded "pills"** so they stay legible over any segment color.
- **Per-page settings reset:** every settings group page has a **Reset <page> to defaults**
  button (with confirmation) that resets only that page — alongside the existing menu-level
  *Reset to defaults* (whole model).
- **New "General" settings group** holding *Config file per craft* (moved from Display) plus
  the new **Debug log** options.
- **Debug log to SD card** (*General ▸ Debug log*, default off): writes rotating session
  files `/WIDGETS/UltiDash/debug_NN.log` for diagnosing runtime issues. **Sessions kept** is
  configurable (1–50). RAM-buffered and throttled (no per-frame IO); not written while armed
  (flushed on disarm/disconnect). ~zero cost when off.

### Changed
- **Connection-state default tuning** (new installs / models without a cfg): clock = *Time
  only*, *Fill background* on, stats page *On disconnected*, *Top bar: TX voltage* off,
  *Link bars: color only on warning* on, *Sound: skipped packets* on, default Telemetry
  detail slots 6–8 now empty.
- **Setting renamed for clarity:** *"Quiet link bars (color only on warn)"* →
  **"Link bars: color only on warning"** (storage key `BarsQuiet` unchanged).

### Fixed
- **Per-model config not reloaded on model switch:** the module-wide settings cache was only
  invalidated in per-craft mode, so switching between two models with UltiDash kept the first
  model's configuration. The cache now also reloads when the model **slot** changes.
- **Performance / GC churn:** the arming-disable-flags status-bar path rebuilt a 27-entry
  name table up to twice per frame; the value formatters re-ran `string.format` every frame;
  the clock re-read `getDateTime()` (a table alloc) every frame. All are now memoized so a
  steady display produces ~zero per-frame garbage.
- **Connect "burst":** the RFTool bounces through several states during the connect
  handshake, which fired the 3-request MSP read **repeatedly**. The read is now **debounced**
  (fired once the state has settled), collapsing the burst into a single read — still
  read-only and only while disarmed/connected.

## v0.3 — 2026-06-26

Feature release on top of v0.2. **Experimental — still under testing in the field.**

### Added
- **Configurable value slots.** The 5 right-hand dashboard values **and** the Telemetry
  detail page are now freely assignable to any model sensor, configured in
  **Settings ▸ Tele Main** (the panel) and **Tele Details** (the detail page). A smart
  **Voltage (auto)** slot keeps the warn-colored cell/battery voltage.
- **Telemetry detail page** (tap the right value panel): a **3-column grid of up to 12**
  freely chosen sensors, each with its **unit** and the EdgeTX session **low/high
  (`min .. max`)** read from the sensor's `-`/`+` variants — uniform for *every* sensor
  (the per-flight/per-profile statistics on the stats page are unchanged). Tap-to-close
  like the other detail pages.
- **Battery-profile picker** (tap the **B-Profile** field, **disarmed only**): pick from
  the 6 Rotorflight battery profiles with their per-profile capacity ("1800 mAh" /
  "undefined") and switch the **active** profile through the RFTool MSP API, persisting
  **without an FC reboot**. This is the **first place the widget writes to the FC** —
  disarmed only (the FC also blocks config writes while armed); everything else stays
  read/announce-only.
- **Per-sensor units** on the Telemetry detail (V, A, °C, mAh, %, rpm, dB, mW).

### Changed
- **Settings menu restructured:** the configuration groups moved one level down under a
  **Settings** submenu; the hub and submenu now use a centered button **grid** (named
  entries instead of ‹ › tab-cycling — and no more stretched full-width buttons on the
  800×480 TX16S).
- The **"Values" group is split** into **Tele Main** (5 panel slots) and **Tele Details**
  (now **12** detail slots).
- **Settings dropdowns flattened** (sized to the font height, not the full row); the
  sensor picker is **wider** on the TX15.
- **Battery-profile field label** `B. Profile` → `B-Profile` (falls back to `B-Prof` when
  the column is too narrow).
- Neutral UI chrome made **theme-aware** for consistent colors across the UltiDash and
  EdgeTX-theme palettes; the menu hub scales to the display size.

### Fixed
- **Battery-profile capacity off by one:** the dashboard B-Profile field showed the
  *previous* profile's mAh for profiles 2–6 (`sync_active_battery_capacity` applied a
  spurious −1 while the picker was already correct). It now indexes the 0-based capacity
  table directly and follows the FC's current profile.
- **Active-profile detection** is re-read fresh when the picker opens (disarmed) instead
  of a value cached at connect — it now tracks external profile switches.
- **Divide-by-zero guard** in the TX-battery percentage when the radio's General-Settings
  battery limits (`battMin`/`battMax`) are equal.

### Notes
- The **EdgeTX-theme color scheme is not the maintainer's personal focus** and relies on
  community feedback — the built-in **UltiDash** palette is the primary, best-tested path.

## v0.2 — 2026-06-11

A large feature release. **Experimental — still under testing in the field.**

### Added
- **In-widget settings menu.** All configuration moved out of the EdgeTX widget-option
  list (which now holds only `ViewMode`) into a full-screen menu: long-press → full
  screen → tap the ☰ menu glyph (top-left, disarmed only). The menu offers **Settings**,
  **Status** and **Reset settings to defaults** (with confirmation). The Settings page has
  five groups (Display / Battery / Thresholds / Alerts / Switch voice) navigated with ‹ ›,
  using real toggle switches, dropdowns and −/+ steppers (long-press = big step). Edits
  **autosave** on exit.
- **Per-model settings storage.** Settings persist on the SD card in
  `/WIDGETS/UltiDash/cfg_m_<slot>.cfg`, keyed by the model **slot** so they survive
  Rotorflight's "set model name on TX" renaming. Optional **per-craft** files
  (*Config file per craft*). Legacy name-keyed files are adopted once.
- **Tap-to-open detail pages** (full-screen):
  - **ELRS link** (tap the top-bar bars): six labelled bars — RQ, TQ, 1RSS, 2RSS, **SNR**
    and **TPWR** — with thresholds and values, rate/mode header, and a footer with SNR /
    active antenna / session RQ-min. New **`TxPwrMax`** sets the TPWR bar's 100 % reference.
  - **Status & events** (tap the ESC/status line): arm/governor/throttle summary, the live
    status line, and a **timestamped ESC event log** (every status change, RESTART,
    arm/disarm). A dev-metrics footer (Lua heap / UI loop Hz / pass ms).
  - **Battery** (tap the gauge): a cell-voltage scale with the active crit/low/full
    thresholds marked, plus the battery in the dashboard look with values inside it.
- **`ViewMode` — second-screen views.** Place UltiDash again on another screen set to
  **ELRS details** or **Status info**; these passive instances mirror the Dashboard
  instance's data (and inherit its palette). They show a notice when no Dashboard runs.
- **Switch voice announcements** (new *Switch voice* settings group): speak motor on/off,
  rescue, governor and profile (1-3) from a configurable TX switch — **physical SA…SH (+
  inverted) or any logical switch** defined in the model. Read-only; independent of the
  model's mixer/arming logic. New voice files `motor_on/off`, `rescue_on/off`, `gov_on/off`,
  `profile`.
- **Callout volume override** (`Volume` 1–5 + *Widget volume applies*): play callouts at a
  fixed level regardless of the radio setting; spoken numbers now honor the master mute.
- **Per-PID-profile headspeed statistics**: min/max tracked per `PID#` profile, shown as
  three fixed rows (P1–P3) so every profile stays visible after disconnect.
- **First-run hint** overlay pointing to the full-screen settings menu (shown until the
  menu is opened once; per model).
- **Detail/stats touch controls**: *Tap zones for detail pages* (on/off), *Close detail
  pages on arm*, manual stats dismiss by tap.
- **Display options** `ClockMode` (date+time / time-only) and `BarsQuiet` (link bars stay
  neutral until warn/crit).
- *(from the prior ELRS round)* ELRS link bars (RQ/TQ/1RSS/2RSS) in the top bar; RSSI/signal
  warning (`rssi_warn`/`rssi_crit`) with `RssWarn`/`RssCrit`/`RssHold`; main-power-loss
  (`pwr_backup`, `PwrWarnV`) and skipped-packet (`skp_high`, `SkpLimit`) warnings; cell
  thresholds from FC or manual.

### Changed
- **Configuration model:** the EdgeTX widget option list is reduced to a single `ViewMode`
  choice; everything else is the in-widget menu (per-event sound switches, `Mute` master,
  `Haptic`, thresholds, etc.).
- **Statistics page restructured:** the three info cards (Flight Time / mAh Used / Batt
  Profile) are replaced by one slim line; the battery-profile card is dropped; headspeed is
  now three per-profile rows; "Actual" → "Latest".
- **Top-bar link bars redesigned** to an outline look matching the battery icon, centered on
  the bar midline, with an optional quiet mode.
- **Default thresholds tuned from real logs:** link `RQlyWarn/Crit` 50/30 → **80/50**; RSSI
  `RssWarn/Crit` default **15/8** (% headroom).
- **All voice WAVs peak-normalized** to match the EdgeTX voice-pack loudness; sounds live in
  `/SOUNDS/en/ultidash/`. Telemetry-lost/link/RSSI now use spoken WAVs, announced once per
  episode.

### Fixed
- **Full-screen touch / widget-menu regression:** after a full-screen cycle the long-press
  menu and taps stopped working — root-caused (EdgeTX keeps `lvgl.box` containers clickable
  when built in full-screen and doesn't rebuild on exit) and fixed by rebuilding once on
  exit. The model image can stay in full-screen.
- **No "battery critical 0 V" on power loss**, and **stats Min/Latest no longer polluted by
  the buffer decay** on unplug: voltages are armed-only, latched against ≤ 1 V readings;
  the BEC value is held through a supply collapse; a collapsing `Vbat` is reported as
  main-power-loss instead.
- **Stats page scoped per connection** (`ever_armed` resets on connect) and **manually
  dismissable**.
- **Touch robustness:** uniform tap cooldown so a late bounce tap can't "click through" onto
  the new view; multi-tap reports ignored.
- **Performance:** bottom-bar getters (Skp/RQly/TQly/TPWR) and the armed state no longer do
  per-frame sensor name lookups; the telemetry pass is throttled to 5 Hz.
- **TX16S (800×480) layout:** adaptive settings row height for the taller toggle switches;
  font-metric (not hardcoded) heights on the battery and event-log pages.
- Earlier fixes: spurious stats 0s, ESC-temp Min ignoring the startup 0.

### Licensing
- **UltiDash is cleanly GPLv3.** The HeliDash base (gismo2004 / HeliWidget) is licensed
  **GPL-3.0 (or later)**; `LICENSE`, `NOTICE.md`, `README.md` and the `main.lua` header
  reflect that the combined work is distributable under GPLv3.

## v0.1 — 2026-05-30

First release. **Experimental — still under testing in the field.**

### Added
- Full-screen LVGL flight dashboard built on **HeliDash** (base) with:
  - In-widget **top bar**: date/time + radio (TX) battery icon (voltage + %, red below
    warning threshold) — replaces the EdgeTX top bar.
  - **Center battery gauge** with the **ePowerbar** reserve/fuel model: reserve-adjusted
    fuel %, discrete green/yellow/red colors, cell count (`NS`), big % and used mAh,
    startup cell-check (grey progress + warning if not full).
  - **Left status panel**: model image (**eBitmap** style), total flights & flight time,
    Governor + Throttle, **eStatus** ESC fault decoder (YGE/OpenYGE, Scorpion, HobbyWing,
    FLYROTOR, OMP, BLHeli_32) + arming-disable reasons, Profile / Rate / Battery-Profile.
  - **Right values panel**: cell/battery voltage, headspeed, current, ESC temp, BEC.
  - **Statistics view** (auto on disarmed/disconnected): Actual/Min/Max table, total
    flights & total flight time (Rotorflight MSP), capacity used.
  - Compact radio-battery icon style adapted from **BattAnalog**.
- **Callouts**: fuel %, low/critical cell voltage, armed/disarm, and ELRS
  link-quality / telemetry-lost warnings.
- Flight-time tracking made governor-independent (headspeed-based) and run in the
  background so it counts off-screen too.
- `Skp` (skipped-telemetry-packet counter) shown in the bottom status bars.

### Notes
- MSP is only read on connect/disarm — never during armed flight.
- No external libraries (no eLib); UltiDash loads only its own files.
