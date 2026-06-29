# Changelog

All notable changes to UltiDash are documented here.

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
