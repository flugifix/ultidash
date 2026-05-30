# UltiDash

**A full-screen LVGL dashboard widget for EdgeTX / Rotorflight helicopters.**

`Status: v0.1 — experimental, under testing`

UltiDash brings flight telemetry, battery state, ESC status and radio info together
on a single self-contained screen — designed so you can drop the EdgeTX top bar and
run it full-screen.

![UltiDash dashboard](images/ultidash.jpg)

> ⚠️ **Work in progress / under testing.** Version **0.1** is an early experimental
> release and is still being tested in the field. Expect rough edges and changes;
> use at your own risk. Developed on RadioMaster TX16S / EdgeTX 2.12 with
> Rotorflight 2.x. Feedback and bug reports are very welcome.

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

- **Top bar** — date/time and a compact radio (TX) battery icon with voltage + %
  (fill turns red below the warning threshold). Replaces the EdgeTX top bar.
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
  and ELRS **link-quality / telemetry-lost** warnings (armed only). Configurable.
- **No external libraries** — UltiDash loads only its own files.

## Requirements

- EdgeTX **color radio** with LVGL widget support (developed on 2.12).
- **Rotorflight** with the **RFTool** widget installed (provides connection/arm state
  and MSP data). MSP is only read on connect/disarm — never during armed flight.
- Telemetry sensors (fixed names): `Vbat`, `Vcel`, `Cel#`, `Curr`, `Capa`, `Bat%`,
  `Vbec`, `Tesc`, `Tmcu`, `Hspd`, `Gov`, `ARMD`, `PID#`, `RTE#`, `BAT#`, `RQly`,
  `TPWR`, and (for ESC status) `Esc#` + `EscF`, plus `Skp` (skipped-packet counter).
- Sounds in `/SOUNDS/en/`: `batcrt/batlow/battry` (included); `armed/disarm` for the
  arm callout (usually in the EdgeTX voice pack).
- Optional model images in `/images/` (`<model>-<cells>S` → `<model>` → model bitmap).

## Installation

Copy the folders from this repo to the **root of your radio's SD card**, merging with
what's already there:

```
WIDGETS/UltiDash/   →  <SD>/WIDGETS/UltiDash/
SOUNDS/en/          →  <SD>/SOUNDS/en/
```

Then add the **UltiDash** widget to a (full-screen) widget zone on a model screen.

## Configuration

The widget options cover reserve %, callout interval, mute, voltage display
(cell/battery), cell-check thresholds (`CellFull`/`CellLow`/`CellCritical`), startup
delay, and the ELRS link warning (on/off + RQly warn/critical thresholds).

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
