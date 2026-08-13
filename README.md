# UltiDash

**A full-screen LVGL dashboard widget for EdgeTX / Rotorflight helicopters.**

`Status: v0.7.1 — in development, experimental`

> 🚀 **New to UltiDash?** See it first in the **[Illustrated Walkthrough](docs/WALKTHROUGH.md)**,
> then get it running with the **[Quick Start guide](docs/QUICKSTART.md)** — the shortest path
> to a working dashboard, including the one Rotorflight CLI line that enables all the sensors
> the built-in features need. Add the extras with the
> **[Optional Features guide](docs/OPTIONAL_FEATURES.md)**.

UltiDash brings flight telemetry, battery state, ESC status, the ELRS link and radio
info together on a single self-contained screen — designed so you can drop the EdgeTX
top bar and run it full-screen. Everything is configured **inside the widget** (a
fullscreen menu), and tapping a panel opens a detailed view of it.

![UltiDash in action](images/ultidash_showcase.gif)

*Flight view, the tap-to-open detail pages (telemetry, battery, ELRS, status), the
battery-profile picker, the stats page and the settings menu.*

### The dashboard at a glance

The flight view packs a lot in; tapping a panel (in full-screen) drills into it:

![UltiDash dashboard — interactive zones](images/ultidash_dashboard_annotated.png)

> ⚠️ **Work in progress / under testing.** UltiDash is an experimental project and is
> still being tested in the field. Expect rough edges and changes.
> **Use entirely at your own risk — there is NO warranty of any kind (see [License](#license)).**
> Intended for the **RadioMaster TX15 and TX16S MK3 running ELRS**, on EdgeTX 2.12 with
> **Rotorflight 2.3 (required)**. It runs in principle on the **TX16S MK2** (480×272)
> too, but that radio is **not actively tested** and its aspect ratio is less ideal for
> the layout. Feedback and bug reports are very welcome.

---

## Key features

At a glance — full detail in the **[Features](#features)** list below.

**Dashboard & views**
- **Full-screen dashboard** — link, battery gauge, governor/throttle, ESC status, headspeed, voltages, temps, BEC.
- **Auto statistics** — Latest/Min/Max per value + flights & flight time (shown when disarmed).
- **Detail pages** — tap a panel: Telemetry · ELRS · Status & events · Battery.

**Alerts & voice**
- **Per-alert voice & vibration** — EN/DE, repeat, escalation volume, fullscreen overlay.
- **Switch & governor callouts** — spoken from a chosen switch / on governor-state changes.

**Battery & power**
- **Battery-profile picker** — switch the FC battery profile from the dashboard (disarmed).
- **Main-power-lost mode** — live backup-buffer readout, adaptive threshold.
- **ESC load monitor** *(opt.)* — utilization bar + overload alarm.

**Config & tools**
- **In-widget settings menu** — saved per EdgeTX model; no EdgeTX option list.
- **Configurable value slots** — any sensor + selectable current source.
- **Toolbox** *(opt.)* — **RF2 Config** (full FC setup on the radio — bind to a shortcut) · Log Viewer (`/LOGS` graphs) · RF Adjustment · Flight Log · FC battery profile.
- **Flight log & battery management** *(opt.)* — per-flight CSV + per-pack cycle counting.
- **Sensor check** — flags any missing/renamed telemetry sensor.
- **No external libraries.**

> **Setup in a nutshell:** copy the files → send the FC sensors (one CLI line) → install
> RFTool → discover sensors → place the widget. Full steps in the
> **[Quick Start guide](docs/QUICKSTART.md)**.

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

- **Flight dashboard** — top bar (date/time, the ELRS link as up to four stacked bars,
  radio battery), a central reserve-adjusted battery gauge, a left status panel (model
  image, flights & flight time, governor + throttle, a multi-vendor ESC status/fault line,
  profile/rate/battery-profile) and a right values panel (voltage, headspeed, current,
  ESC temp, BEC).
- **Statistics view** — auto-shown when disarmed/disconnected: per-value Latest/Min/Max
  table (headspeed **per PID profile**), total flights & flight time, capacity used.
- **Configurable values** — the 5 right-hand panel slots and the Telemetry detail page are
  freely assignable to any model sensor (a smart **Voltage (auto)** slot keeps the
  warn-colored cell/battery voltage). A **configurable current source** (`Curr` / ESC / rail
  current) feeds the Current row and the ESC-load monitor, so models that report current only
  over ESC telemetry work too.
- **Tap-to-open detail pages** (full-screen) — tap a panel to drill in:
  - **Telemetry** (tap the value panel): a 3-column grid of up to 12 chosen sensors, each
    with its **unit** and the EdgeTX session **low/high** (`min .. max`).
  - **ELRS link** (tap the top-bar bars): RQ, TQ, 1RSS, 2RSS, SNR and TPWR as labelled
    bars with thresholds, plus **downlink RSSI/SNR (TRSS)**, active antenna and session
    RQ-min.
  - **Status & events** (tap the status line): arm/governor/throttle summary, the live
    status line and a timestamped ESC event log.
  - **Battery** (tap the gauge): a cell-voltage scale with the active thresholds marked
    plus the battery in the dashboard look.
- **Battery-profile picker** (tap the **B-Profile** field, **disarmed**) — switch the
  active Rotorflight battery profile (shown with their capacities) right from the
  dashboard, via the RFTool MSP API and without rebooting the FC. *(This is the only place
  UltiDash writes to the FC — disarmed only; everything else is read/announce-only.)*
- **In-widget settings menu** — no EdgeTX option list to fight: open the full-screen menu
  and edit everything with real toggle switches, dropdowns and +/− steppers, grouped into
  named pages. Settings are **saved per EdgeTX model** on the SD card — shared by every
  Rotorflight craft flown on that model (see below).
- **Voice & vibration callouts, configurable per alert** — fuel % (or the pack / cell
  voltage — the descending %-step callouts can speak voltage instead of, or alongside, the
  percent), cell/pack voltage (announce as cell **or** pack, independent of the display),
  armed/disarm, ELRS
  link-quality, RSSI/signal, telemetry-lost, main-power-loss, **BEC-drop**, **ESC-load**,
  **ESC/MCU over-temperature** and skipped-packet warnings, plus optional **switch
  announcements** (motor / rescue / governor / profile) and **governor-state callouts**
  (spooling up, gov active, throttle hold, autorotation, bailout, … — armed only, per-state
  selectable). Every alert has its own page:
  on/off, **repeat** (count/interval), **escalation volume**, vibration — the critical
  ones also an optional **fullscreen overlay** (red warning box over the dashboard,
  tap or auto-close to dismiss) — with a master
  mute, a separate **vibration master**, English/German voice packs and two volume worlds
  (fixed callout volume and an optional **master-volume control via GVAR**, boosted while a
  critical alert repeats — needs a small one-time model setup, see the reference §5.4).
- **Main-power-lost mode** — a collapsed main pack with live telemetry (backup buffer
  took over) flips the dashboard into a dedicated state: **MAIN POWER LOST** status, the
  voltage slot becomes a red live **Buffer** readout, the
  repeating callout counts the **live BEC voltage** down, and recovery is announced if
  the pack comes back mid-flight. The loss threshold adapts to the pack by default
  (**cell count × 3.0 V/cell**, manual override available).
- **ESC load monitor** *(optional, off by default)* — a model GVAR delivers the ESC's
  continuous-current limit (mapped via the RF2/RFTool Lua suite's per-model GVAR
  feature); UltiDash shows the utilization as a green/yellow/red bar (plus an *ESC Load*
  telemetry slot) and can alarm on sustained overload.
- **Toolbox** *(optional, on-demand tool pages)* — opened from the menu (see
  [docs/TOOLBOX.md](docs/TOOLBOX.md)):
  - **RF Adjustment Map / Editor** — view and touch-adjust Rotorflight adjustment functions
    from the radio (needs a one-time model setup).
  - **Log Viewer** *(WIP)* — graph `/LOGS/*.csv` on the radio: swipe the file list, pick a
    built-in template or a category-grouped sensor set, then zoom / pan / drag a time cursor
    over up to 4 curves. Own template sets are made and managed **on the radio** — save a
    picked set, then rename, duplicate, reorder or delete it from the same page.
  - **RF2 Config** — the original Rotorflight configuration tool (rotorflight-lua-scripts)
    opened straight from the dashboard, run unmodified from `/SCRIPTS/RF2/` (needs the RF
    Tool widget; disarmed only).
  - **Flight Log** — browse the flight log on the radio: recent flights, per-model
    totals and battery usage (see the flight-log feature below).
  - **Battery profile** — the same FC battery-profile picker the dashboard's *B-Profile*
    field opens, so it stays reachable under a layout that offers no such field (disarmed
    and MSP-connected only — it is the one page that writes to the FC).
- **Flight log & battery management** *(optional, off by default)* — log every flight
  (date, time, FC model name, tracked flight time) to an import-friendly
  `fltlog/flights.csv`, with a configurable **minimum flight time** so spool-up tests
  never count; optionally UltiDash asks **which battery you plugged in** after
  each connect (packs defined per model in a PC-edited `fltlog/batteries.cfg`, with a
  free-form id that external tools can match — start from the commented template
  `fltlog/batteries.example.cfg`), counts cycles + last use per pack, and
  can activate the pack's FC battery profile on selection (see
  [docs/REFERENCE.md](docs/REFERENCE.md) §12).
- **Sensor check** *(diagnostic)* — a read-only menu page that lists the sensors UltiDash
  needs and flags what is **OK / no data / missing**, with a one-line note on what each gap
  breaks — the fastest way to spot a mis-discovered or renamed telemetry sensor.
- **No external libraries** — the dashboard loads only its own files. *(The one exception is
  the optional **RF2 Config** tool, which by design runs the stock Rotorflight scripts already
  on your SD card at `/SCRIPTS/RF2/`.)*

## Requirements

- EdgeTX **color radio** with LVGL widget support (developed on 2.12).
- **Rotorflight 2.3** (required) with the **RFTool** widget installed (provides
  connection/arm state and MSP data). MSP is only read on connect/disarm — never during
  armed flight.
- An **ELRS** RF link: the link bars and the link/RSSI warnings read ELRS telemetry
  sensors (`RFMD`, `RQly`, `TQly`, `1RSS`, `2RSS`, `RSNR`, `TPWR`, `ANT`).
- Telemetry sensors (fixed names): `Vbat`, `Vcel`, `Cel#`, `Curr`, `Capa`, `Bat%`,
  `Vbec`, `Tesc`, `Tmcu`, `Hspd`, `Gov`, `ARM`, `ARMD`, `PID#`, `RTE#`, `BAT#`, `Thr`,
  `Esc#` + `EscF` (ESC status), the ELRS sensors above, and `*Skp` (skipped-packet counter
  — the label really starts with `*`).
- Sounds in `/SOUNDS/en/ultidash/` and `/SOUNDS/de/ultidash/` (all included, in their own
  subfolders so they don't clash with the EdgeTX voice pack; pick the language in
  *Alerts ▸ Voice / mute*). Spoken numbers/units (`percent`, `volts`, digits) still come
  from your EdgeTX voice pack.
- Optional model image in `/images/`: a single file named after the **Rotorflight model
  name** is enough — e.g. `MyHeli.png` or `MyHeli.jpg`. (Advanced/optional: a
  `<model>-<cells>S` variant is preferred when present; otherwise the plain name, then the
  EdgeTX model bitmap, is used.)

## Installation

Copy the folders from this repo to the **root of your radio's SD card**, merging with
what's already there:

```
WIDGETS/UltiDash/      →  <SD>/WIDGETS/UltiDash/
SOUNDS/en/ultidash/    →  <SD>/SOUNDS/en/ultidash/
SOUNDS/de/ultidash/    →  <SD>/SOUNDS/de/ultidash/
```

Then add the **UltiDash** widget to a (full-screen) widget zone on a model screen —
**one instance per model**. The widget has no EdgeTX options; everything is configured
inside the widget (see below).

> ⚠️ **Upgrading from a version with `ViewMode`:** the second-screen *ELRS details* /
> *Status info* views were removed. A second instance that used one of them becomes a
> full dashboard after the update (a "2 Dashboard instances active!" banner appears) —
> delete that second instance.

> ℹ️ **Telemetry sensors.** UltiDash resolves its known sensors by their Rotorflight sensor
> **ID**, so leftover empty EdgeTX duplicate sensors (`RxBt`, `Curr`, …) no longer *shadow*
> the real values — the old "delete the empty sensors first" step is **no longer required**.
> If a value still looks wrong, open the in-widget **Sensor check** page (menu) to see what
> is missing; deleting the `—`/no-value sensors and turning *Discover new sensors* off is
> still tidy (and matters for a raw sensor you pick **by name**). Details in
> **[docs/REFERENCE.md §6.1](docs/REFERENCE.md)**.

## Configuration

There are **no EdgeTX widget options** — all configuration lives in an **in-widget
settings menu**:

1. **Long-press** the widget → **Full screen**.
2. Tap the **menu symbol** (the ☰ glyph, top-left, next to the clock) — *disarmed only*.
3. The menu offers **Settings** (a submenu of the configuration groups), **Status**,
   **Sensor check** and **Toolbox**. The menu and the Settings submenu are laid out as
   button grids; each group opens its own page.

The **Settings** submenu — a 3-column grid in four themed sections:

| Section | Group | Covers |
|---------|-------|--------|
| *Appearance* | **Display** | **dashboard skin**, background fill, unit suffixes, stats-page mode, voltage display, detail-page behaviour |
| | **Skin** | the **active skin's** own colour scheme + layout options (the UltiDash skin: top-left content, clock, timer, the top-bar toggles, quiet bars, status-bar TPWR). Pick the layout with *Display → Dashboard skin*; this release carries the built-in **UltiDash** look (see [docs/SKINS.md](docs/SKINS.md) — **skins are in development**) |
| | **Colors** | **per-scheme color overrides**: one page per scheme *of the active skin* — palette slots, traffic-light status colors, UI chrome and the battery-bar / TX-battery fills, each with a native color picker + per-color *Def* reset |
| *Battery & limits* | **Telemetry** | submenu: **Tele Main** — the 5 right-hand dashboard value slots (curated sensors, *Voltage (auto)*, *ESC Load (calc)* — or **any raw sensor** via the native picker); **Tele Details** — the 12 sensor slots of the Telemetry detail page (same hybrid pickers) |
| | **Battery** | reserve %, fuel-callout density, **fuel callout value (percent / pack / cell voltage)**, cell-threshold source (FC config / manual cell voltages), startup cell-check delay, **current sensor**, **announce voltage as cell/pack** |
| | **Thresholds** | link (RQly) warn/crit, RSSI warn/crit/hold, skipped-packet limit, **TX power limit (ELRS dynamic-power ceiling)**, power-warn voltage, BEC warn/crit, **ESC/MCU temperature warn/crit** |
| | **ESC load** | the ESC continuous-current load monitor: master switch, limit GVAR, warn/critical %, alarm hold time, load-bar placement (Current row / vertical in the battery gauge) |
| *Sound & callouts* | **Volume** | fixed callout volume + when it applies, the optional **master-volume bridge via GVAR** with normal / escalation percentages, and a **Test/Play** preview row |
| | **Alerts** | **voice language (English / Deutsch)**, master mute, overlay auto-close, and **one page per alert**: active, repeat (count / interval), escalation volume, vibrate, fullscreen overlay (critical alerts) — plus a **Test/Play** row per alert that previews its real callout |
| | **Voice** | submenu: **Switch voice** — announce motor / rescue / governor / profile from a chosen TX switch (physical **or** logical, native picker); **Gov voice** — announce the governor state on change (armed only), master toggle + per-state enables |
| *System* | **Shortcuts** | bind switches to pages hands-free — 6 position slots (hold = open) + 2 toggle slots (press to step), targeting any detail page **or** Toolbox tool |
| | **Toolbox** | the RF adjustment tools: channels, GVAR pulse, look & voice (see [docs/TOOLBOX.md](docs/TOOLBOX.md)) |
| | **General** | the **debug log** (off by default) + how many log sessions to keep, and the **flight log / battery query / FC-profile-on-pick** switches |

Each group page also has a **Reset … to defaults** button that resets only that page; the
*Reset to defaults* button below the settings grid resets the whole model.

> 🧪 **The skin system is in development.** The dashboard layout is pluggable: the engine,
> the skin API, the discovery (`skins/*.lua`) and the *Skin* settings group are part of this
> release, and the built-in **UltiDash** look is a skin like any other. The **additional
> layouts are not part of it** — they are still being reworked, and the API they are written
> against may still change in ways that break a skin written against today's version. Read
> [docs/SKINS.md](docs/SKINS.md) as a preview rather than as a stable contract.
>
> They are not lost, only kept out of the widget release: the four of them —
> *Minimal*, *Grid*, *Cockpit* and *Dash1* — live in
> [flugifix/ultidash_skins](https://github.com/flugifix/ultidash_skins), tagged per UltiDash
> release. Installing one is copying a file into `WIDGETS/UltiDash/skins/`; a skin that
> fails to load falls back to the built-in look.

> 🎨 **About the color scheme (Skin → Color scheme).** Colour schemes belong to the skin.
> The **UltiDash** skin offers three palettes: the built-in **UltiDash** look (the path I
> actually fly and test), **UltiDash dark** (high-contrast white-on-black with neon
> accents), and an **EdgeTX theme** option (theme-aware — **not my personal focus**, less
> tested, feedback welcome). Other skins bring their own schemes. Every scheme's colors can
> be customized under **Settings → Colors** (per model, with per-color *Def* reset). If
> something looks off under the theme palette, please open an issue with a screenshot.

Edits are **saved automatically** when you leave the page (back arrow or RTN) and stored
**per EdgeTX model** in `/WIDGETS/UltiDash/cfg/cfg_m_<model-name>.cfg` — so every
Rotorflight craft flown on that model shares them. The key is the **model name**, which
survives the model-file renumbering that EdgeTX Companion does when models are added or
deleted. Rotorflight's "set model name on TX" temporarily renames the model to the connected
craft, and since **0.7.1** that can no longer split a model's config in two: each file also
records the model it belongs to, so a config is found by name and identified by model file
(see `menu ▸ Status`, which names the file in force). Two models with the same name still
share one file, so give a copied model its own name if it needs its own config. (Config files
from older versions are picked up automatically — those in the widget root are moved into
`cfg/`, and pre-0.7.0 files keyed by the model number are re-keyed to the name on first
start.)

See **[docs/REFERENCE.md](docs/REFERENCE.md)** for the full settings list, the layout
breakdown, the callout matrix, the detail pages and the "what is shown when" tables.

### Touch navigation (full-screen)

| Tap | Opens |
|-----|-------|
| ☰ menu glyph (top-left) | the settings menu (disarmed only) |
| the right value panel | the **Telemetry** detail page |
| the link bars | the **ELRS** detail page |
| the ESC/status line | the **Status & events** page |
| the battery gauge | the **Battery** detail page |
| the **B-Profile** field | the **battery-profile picker** (disarmed only) |
| anywhere on a detail page / RTN | back to the dashboard |
| anywhere on the stats page | dismiss it (returns next flight) |

Detail tap-zones can be turned off (*Display → Tap zones for detail pages*); the menu
glyph always stays active.

## Credits

UltiDash is a merged/derivative work. All credit to the original authors:

- **HeliDash** — base widget, layout & telemetry — based on
  [HeliWidget by gismo2004](https://github.com/gismo2004/HeliWidget) (GPL-3.0)
- **ePowerbar / eBitmap / eStatus** — battery model, model image, ESC decoder — by
  Rob 'bob00' Gayle, [etx-widgets](https://github.com/bob01/etx-widgets) (GPLv3)
- **BattAnalog** — top-bar battery icon style — by
  [Offer Shmuely](https://github.com/offer-shmuely/edgetx-x10-widgets)

## License

UltiDash is licensed under **GPLv3** (see [`LICENSE`](LICENSE)). All reused components are
GPL-compatible: the HeliDash base (gismo2004) is **GPL-3.0**, and the etx-widgets-derived
parts are GPLv3 — so the combined work can be distributed under GPLv3 with the
attributions in [`NOTICE.md`](NOTICE.md) preserved.

**No warranty.** This software is provided *as-is*, without warranty of any kind; you use
it **entirely at your own risk**. See [`NOTICE.md`](NOTICE.md) for the full attribution.
*(Plain-language summary, not legal advice.)*
