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
  `pwr_backup`, `skp_high`.

### Changed
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

### Fixed
- **Statistics Min/Max no longer show spurious 0s** from connect/disconnect transients:
  EdgeTX-sourced min/max are reset once the link is actually up and frozen while it's down,
  and **ESC-temp Min** is now widget-tracked ignoring the 0 the ESC reports before its
  temperature telemetry comes up (so it shows the real low instead of 0.0).

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
