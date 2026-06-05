# UltiDash

**A full-screen LVGL dashboard widget for EdgeTX / Rotorflight helicopters.**

`Status: v0.1 — experimental, under testing`

UltiDash brings flight telemetry, battery state, ESC status and radio info together
on a single self-contained screen — designed so you can drop the EdgeTX top bar and
run it full-screen.

![UltiDash flight view](images/ultidash.jpg)

*Flight view (above) and the statistics page shown when disarmed/disconnected (below).*

![UltiDash statistics page](images/ultidash02.jpg)

> ⚠️ **Work in progress / under testing.** Version **0.1** is an early experimental
> release and is still being tested in the field. Expect rough edges and changes;
> use at your own risk. Developed on EdgeTX 2.12 with **Rotorflight 2.3 (required)** and
> **tested on RadioMaster TX15 and TX16S MK3**. Feedback and bug reports are very welcome.

---

## A personal note

UltiDash was originally built **just for my own personal use** — a way to combine
everything I need into a single widget. I decided to make it available anyway, in case
it's useful to someone else.

It builds on and reuses the work of several authors (see [Credits](#credits) and
[`NOTICE.md`](NOTICE.md)). Should any of them have concerns about their work being reused
here, I will of course respect that.

---

## Features

- **Top bar** — date/time, ELRS link quality (`RQ` downlink + `TQ` uplink) and a compact
  radio (TX) battery icon with voltage + % (fill turns red below the warning threshold).
  Replaces the EdgeTX top bar. RQ/TQ and the TX voltage can be toggled individually.
- **Center battery gauge** (ePowerbar model) — reserve-adjusted fuel %, discrete
  green/yellow/red colors, cell count (e.g. `6S`), big % and used mAh, plus a
  startup cell-check (grey progress bar + warning if the pack isn't full).
- **Left status panel** — model image (from `/images`), total flights & flight time,
  Governor state + Throttle, a multi-vendor **ESC status / fault line** (YGE/OpenYGE,
  Scorpion, HobbyWing, FLYROTOR, OMP, BLHeli_32) with arming-disable reasons, and a
  compact Profile / Rate / Battery-Profile row.
- **Right values panel** — cell/battery voltage, headspeed, current, ESC temp, BEC.
- **Statistics view** — auto-shown when disarmed/disconnected: per-value Actual/Min/Max
  table, total flights & total flight time (from Rotorflight MSP), capacity used.
- **Voice & vibration callouts** — fuel %, low/critical cell voltage, armed/disarm,
  ELRS **link-quality / telemetry-lost** warnings, and a **main-power-loss** warning
  (link + power warnings are armed only). All spoken via UltiDash's own WAVs; configurable.
- **No external libraries** — UltiDash loads only its own files.

## Requirements

- EdgeTX **color radio** with LVGL widget support (developed on 2.12).
- **Rotorflight 2.3** (required) with the **RFTool** widget installed (provides
  connection/arm state and MSP data). MSP is only read on connect/disarm — never during
  armed flight.
- Telemetry sensors (fixed names): `Vbat`, `Vcel`, `Cel#`, `Curr`, `Capa`, `Bat%`,
  `Vbec`, `Tesc`, `Tmcu`, `Hspd`, `Gov`, `ARM`, `ARMD`, `PID#`, `RTE#`, `BAT#`, `RQly`,
  `TQly`, `TPWR`, `Thr`, and (for ESC status) `Esc#` + `EscF`, plus `*Skp` (skipped-packet
  counter — the sensor label really starts with `*`).
- Sounds in `/SOUNDS/en/ultidash/` (all included, in their own subfolder so they don't
  clash with the EdgeTX voice pack): `battry`, `batlow`, `batcrt`, `armed`, `disarm`,
  `telem_lost`, `telem_ok`, `link_warn`, `link_crit`, `pwr_backup`. Spoken numbers/units
  (`percent`, `volts`, digits) still come from your EdgeTX voice pack.
- Optional model image in `/images/`: a single file named after the **Rotorflight model
  name** is enough — e.g. `MyHeli.png` or `MyHeli.jpg`. (Advanced/optional: a
  `<model>-<cells>S` variant, e.g. `MyHeli-6S.png`, is preferred when present so you can
  use a different picture per cell count; otherwise the plain name, then the EdgeTX model
  bitmap, is used.)

## Installation

Copy the folders from this repo to the **root of your radio's SD card**, merging with
what's already there:

```
WIDGETS/UltiDash/      →  <SD>/WIDGETS/UltiDash/
SOUNDS/en/ultidash/    →  <SD>/SOUNDS/en/ultidash/
```

Then add the **UltiDash** widget to a (full-screen) widget zone on a model screen.

## Configuration

The widget options cover reserve %, callout interval, mute, voltage display
(cell/battery), the cell-threshold source (`CellSource` = FC config **or** Manual, with
manual `CellFull`/`CellLow`/`CellCritical` values), startup delay, the ELRS link warning
(on/off + RQly warn/critical thresholds), the color scheme (`ColorScheme` = fixed UltiDash
palette or follow the EdgeTX theme), what the top-left area shows (`TopLeft` = model image
or a timer), per-element top/bottom-bar toggles (`ShowRQly`, `ShowTQly`, `ShowTxV`,
`ShowTPWR`), and a main-power-loss warning (`PwrWarn` on/off + `PwrWarnV` voltage threshold).

See **[docs/REFERENCE.md](docs/REFERENCE.md)** for the full option list, the layout
breakdown, the callout matrix and the "what is shown when" tables.

## Credits

UltiDash is a merged/derivative work. All credit to the original authors:

- **HeliDash** — base widget, layout & telemetry — based on
  [HeliWidget by gismo2004](https://github.com/gismo2004/HeliWidget)
- **ePowerbar / eBitmap / eStatus** — battery model, model image, ESC decoder — by
  Rob 'bob00' Gayle, [etx-widgets](https://github.com/bob01/etx-widgets) (GPLv3)
- **BattAnalog** — top-bar battery icon style — by
  [Offer Shmuely](https://github.com/offer-shmuely/edgetx-x10-widgets)

## License

GPLv3 is the **intended** license for UltiDash's own code and the etx-widgets-derived
parts. **However the whole work is not yet cleanly licensable:** the HeliDash base
(gismo2004) currently carries **no license** — "no license" means *all rights reserved*
by default, not free to relicense. A formal public release first requires that base to
be licensed (ideally GPLv3 or "GPLv2 or later"). Private use is unaffected.

See [`LICENSE`](LICENSE) (GPLv3 text) and [`NOTICE.md`](NOTICE.md) for the full
attribution and the licensing caveat. *(Plain-language summary, not legal advice.)*
