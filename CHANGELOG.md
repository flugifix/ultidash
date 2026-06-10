# Changelog

All notable changes to UltiDash are documented here.

## Unreleased

### Added
- **`CellSource`** option (FC config / Manual): cell-voltage thresholds default to the
  Rotorflight FC (`mspBatteryConfig`) but can be overridden manually via the re-added
  **`CellFull` / `CellLow` / `CellCritical`** options (centivolts).
- Per-element bar toggles: **`ShowRQly`** / **`ShowTQly`** (top-bar RQ/TQ link quality),
  **`ShowTxV`** (top-bar TX voltage) and **`ShowTPWR`** (bottom-bar TX power).
- **Main-power-loss warning:** new event that speaks `pwr_backup` once when, while armed,
  `Vbat` falls below a configurable threshold (likely running on backup power). New options
  **`PwrWarn`** (on/off) and **`PwrWarnV`** (threshold in 0.1 V, default 9.0 V).
- **Skipped-packet warning:** new event that speaks `skp_high` once when, while armed, the
  cumulative `*Skp` counter reaches a configurable limit. New options **`SkpWarn`** (on/off,
  default off) and **`SkpLimit`** (default 50).
- Dedicated voice files for all events, shipped with the widget: `armed`, `disarm`,
  `battry`, `batlow`, `batcrt`, `telem_lost`, `telem_ok`, `link_warn`, `link_crit`,
  `rssi_warn`, `rssi_crit`, `pwr_backup`, `skp_high`.
- **ELRS link bars in the top bar:** the center now shows up to four thin stacked bars —
  `RQ`/`TQ` link quality and `1RSS`/`2RSS` signal headroom (rate-aware, derived from
  `RFMD`/`1RSS`/`2RSS` via a per-rate sensitivity floor), color-by-zone with threshold
  ticks (2RSS only with antenna diversity). New **`ShowRSSI`** toggle for the RSSI bars
  (RQ/TQ keep `ShowRQly`/`ShowTQly`).
- **RSSI / signal warning:** speaks `rssi_warn`/`rssi_crit` once per episode (armed only)
  when the best-antenna RSSI headroom drops below **`RssWarn`/`RssCrit`** (% headroom),
  with a configurable hold time **`RssHold`** (seconds, default 2) so brief antenna nulls
  don't trigger. New **`SndRssi`** on/off.

### Changed
- **Per-event alert switches:** every callout/announcement now has its own on/off —
  `SndCellChk`, `SndFuel`, `SndVolt`, `SndArm`, `SndTelem`, `SndLink` (plus existing
  `PwrWarn`/`SkpWarn`). Each switch disables that event's voice **and** its vibration.
  **Replaces** the former `Mute` levels (fuel/voltage) and the combined `LinkWarn`
  (telemetry + link). The options list is regrouped (display / battery / thresholds /
  alerts). ⚠️ Re-place the widget / re-check options after updating.
- **`Mute` is now a master kill-switch** (`None` / `All`): `All` silences every alert
  (voice + vibration), overriding all per-event switches. `Haptic` remains the vibration master.
- **Sound files moved to `/SOUNDS/en/ultidash/`** (own subfolder, `AUDIO_PATH`) so they no
  longer clash with the EdgeTX voice pack. Install path changes accordingly.
- **Telemetry-lost/recovered and low-link-quality now use spoken WAVs** instead of tones
  (`telem_lost`/`telem_ok`/`link_warn`/`link_crit`).
- **Low-link-quality is announced once per episode** (re-armed on recovery above the warn
  threshold; a warn→critical escalation announces once more) instead of repeating on the
  `CalloutInt` interval.
- **Statistics page:** the first column is renamed **"Actual" → "Latest"** (current while
  disarmed/connected, frozen at the last value after disconnect); **RQ/TQ are hidden** in
  the stats top bar; the header keeps showing the **Rotorflight FC** model name after a
  disconnect (cached) instead of falling back to the EdgeTX model name.
- **Default alert thresholds tuned from real flight logs:** link quality `RQlyWarn`/
  `RQlyCrit` 50/30 → **80/50** (RQly sits at ~100 % in clean flight, so a higher warn is
  both earlier and false-alarm-free); RSSI `RssWarn`/`RssCrit` default **15/8** (% headroom).
- **Top-bar date** now shows a 2-digit year to free space for the link bars.

### Fixed
- **Statistics Min/Max no longer show spurious 0s** from connect/disconnect transients:
  EdgeTX-sourced min/max are reset once the link is actually up and frozen while it's down,
  and **ESC-temp Min** is now widget-tracked ignoring the 0 the ESC reports before its
  temperature telemetry comes up (so it shows the real low instead of 0.0).
- **No more "battery critical 0 V" on power loss:** the cell-voltage alert ignores
  implausible (< 1 V) readings, and a `Vbat` that collapses to ~0 while the link is still
  up is now reported as **main-power-loss** (`pwr_backup`), not a critical-voltage callout.
- **Statistics min voltage no longer polluted by the buffer:** `Vbat`/`Vcel`/`Vbec`
  min/max are widget-tracked **only while armed** (like the RPM extrema), so the
  post-landing unplug decay (where the buffer bridges and the voltage falls 4.x → 0,
  e.g. a stray 2.89 V) is no longer recorded as the minimum.
- **Statistics page scoped per connection:** `ever_armed` now resets on each fresh connect,
  so the stats page only appears after the craft was armed *this* connection (not because
  an earlier connection in the same session was armed), and the dashboard returns to the
  flight view on reconnect.

### Licensing
- **UltiDash is now cleanly GPLv3.** The HeliDash base (gismo2004 / HeliWidget) is now
  licensed **GPL-3.0 (or later)**, resolving the earlier blocker (the base was previously
  unlicensed). `NOTICE.md`, the root `README.md` and the `main.lua` header are updated to
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
  link-quality / telemetry-lost warnings (armed only, configurable via `LinkWarn`,
  `RQlyWarn`, `RQlyCrit`).
- Flight-time tracking made governor-independent (headspeed-based) and run in the
  background so it counts off-screen too.
- `Skp` (skipped-telemetry-packet counter) shown in the bottom status bars.

### Notes
- MSP is only read on connect/disarm — never during armed flight.
- No external libraries (no eLib); UltiDash loads only its own files.
- Licensing: GPLv3 intended; the unlicensed HeliDash base must be clarified before a
  formal public release — see [NOTICE.md](NOTICE.md).
