# UltiDash

LVGL dashboard widget for EdgeTX / Rotorflight (RadioMaster TX16S MK3 / TX15, EdgeTX 2.12).

> **Other radios:** UltiDash runs in principle on the RadioMaster **TX16S MK2** (480×272)
> too, but that radio is **not actively tested** by the maintainer and its aspect ratio is
> less ideal for the layout. Feedback welcome.

UltiDash is based on **HeliDash** and integrates features from three widgets by
Rob "bob00" Gayle:

| Source | Reused feature |
|-----------|----------------------|
| **HeliDash** | Base structure, layout, LVGL build, telemetry, flight statistics |
| **ePowerbar** | Battery model (reserve/fuel), discrete colors, cell-check, voice/vibration alerts |
| **eBitmap** | Model/heli image from `/images/` |
| **eStatus** | Throttle %, multi-vendor ESC fault decoder, arming-disable reasons, armed/disarm callout |

---

## 1. Files

| File | Content |
|-------|--------|
| `main.lua` | Entry point, registers the widget (`useLvgl = true`) |
| `ultidash.lua` | UI build (dashboard views + settings menu), lifecycle (create/update/refresh), touch handling, the skin engine |
| `ultidashDetail.lua` | The four detail pages (ELRS / status log / battery / telemetry). Split out in 0.7.0 so a skin can draw them; the host keeps opening, closing, tap routing and the gates |
| `ultidashMenu.lua` | Every full-screen menu page: the menu hub, the Settings and Toolbox submenus, the settings pages, sensor check and the two battery pickers. Lazy-loaded on menu open and released when the menu family closes |
| `ultidashFunctions.lua` | Telemetry updates, battery logic, callout engine, switch voices, eStatus, shared-state publisher |
| `ultidashValues.lua` | Value table with formatting/color getters |
| `ultidashRf.lua` | RF service: connection state, MSP (battery profile, flight statistics) |
| `ultidashRfs.lua` | Second MSP provider: the same read surface served through **RFSuite for EdgeTX**'s published MSP service instead of RF Tool (§2.9). Loaded only on a card where that service is actually published, so a card with RF Tool — or with neither — never pays for it |
| `ultidashElrs.lua` | ELRS TX-module configuration client: reads the ExpressLRS transmitter module's own CRSF parameters (packet rate, telemetry ratio, antenna mode) that no telemetry sensor carries. **Read only** — the parameter-write command is never sent |
| `ultidashOptions.lua` | The EdgeTX widget-option list (empty — everything is configured in-widget, §2.2) |
| `ultidashSettings.lua` | Per-model settings store (SD-card cfg files) — the in-widget settings overlay |
| `ultidashEsc.lua` | Multi-vendor ESC status/fault decoder (from eStatus) |
| `ultidashDebug.lua` | Optional SD-card debug logger (see §11) |
| `skins/default.lua` | The built-in **UltiDash** look as a skin module — the fallback whenever a chosen skin is missing or broken, and the worked example for [SKINS.md](SKINS.md). Further skins are dropped in beside it as `skins/<id>.lua` |
| `toolbox/adjmap.lua`, `toolbox/adjed.lua` | Toolbox tool pages: RF Adjustment Map / Editor (see §2.7b and [TOOLBOX.md](TOOLBOX.md)) |
| `toolbox/common.lua` | Shared adjustment tables and helpers behind the Map and the Editor, loaded once so a `labels.lua` override applies identically to both |
| `toolbox/labels.example.lua` | Optional custom adjustment-function labels (copy to `labels.lua`) |
| `toolbox/logview.lua` | Toolbox tool page: telemetry Log Viewer (graphs `/LOGS/*.csv`; WIP, disarmed-only) |
| `toolbox/livemon.lua` | Toolbox tool page: **Live Monitor** — up to 4 sensors as live min/max curves of the last 15–60 s (§2.3b; in-flight capable, the sampling runs in the host) |
| `toolbox/logtemplates.example.lua` | Commented template for stocking own Log Viewer sensor sets from a PC (copy to `cfg/logtemplates.lua`) — since 0.7.0 the radio itself maintains that file |
| `toolbox/rf2cfg.lua` | Toolbox tool page: RF2 Config — zero-copy adapter running the original rotorflight-lua-scripts tool from `/SCRIPTS/RF2/` (disarmed-only) |
| `toolbox/fltdata.lua` | Flight-log data core: battery registry parse, `flights.csv` append, cycle counters (see §12) |
| `toolbox/rfscfg.lua` | Toolbox tool page: **RFSuite (exp.)** — zero-copy adapter running the RFSuite for EdgeTX suite from `/SCRIPTS/TOOLS/rfsuite-core/` (optional install, disarmed-only, **highly experimental**: a warning page precedes every open; see [TOOLBOX.md](TOOLBOX.md) §8) |
| `toolbox/fltlog.lua` | Toolbox tool page: Flight Log viewer (flights / per-model totals / batteries; disarmed-only) |
| `toolbox/fltbatt.lua` | Battery detail, editor and models sub-page behind the Flight Log — one form, reached both from the viewer and from the battery query's *+ New* (disarmed-only; only *Save* writes) |
| `toolbox/adjnames.lua` | Adjustment function id → display name, all 83 ids of the Rotorflight 4.6.0 line. Loaded lazily, and only when the adjustment table comes from the flight controller (which answers with a number, never a name) |
| `img/` | The menu icon set — 39 32×32 PNGs (`ud_*.png`), used as the menu tiles' glyphs, every menu page's header icon, the sibling strip's cells and the alert cards' state marks (§2.2, §2.6a). Part of the install; a missing file makes that one tile fall back to text alone rather than failing |
| `cfg/` | Widget-owned data folder, never overwritten by an update: `cfg_m_<model-name>.cfg` per-model settings (§2.8) and `logtemplates.lua`, the Log Viewer's own sensor sets |
| `logs/` | Debug-log folder: `debug_NN.log`, written only while *General ▸ Debug log to SD card* is on (§11) |
| `fltlog/` | Flight-log data folder: `flights.csv` (written by the widget) + `batteries.cfg` (your battery registry, editable on the radio and on the PC) |
| `fltlog/batteries.example.cfg` | Commented template for the battery registry (copy to `batteries.cfg`) |

One file lives **outside** the widget folder, because EdgeTX's Tools menu only reads its own
directory:

| File | Content |
|-------|--------|
| `/SCRIPTS/TOOLS/udlogview.lua` | Launcher that puts the **Log Viewer** in EdgeTX's *SYS ▸ Apps* menu. It loads and drives `WIDGETS/UltiDash/toolbox/logview.lua` — no second implementation, and it does nothing on a card without UltiDash but say so (§2.7b) |

---

## 2. Configuration

### 2.1 EdgeTX widget options: the craft target

The widget declares **one EdgeTX option**, set in the widget-settings dialog where the
widget is **placed** — not in the in-widget settings menu, and not per model file:

| Option | Values | Default |
|---|---|---|
| **Craft target** | *Rotorflight* | *Rotorflight* |

The list has a single entry today, because Rotorflight is the only craft firmware UltiDash
realises. The option exists so the widget **says** which firmware it is reading rather than
assuming it, and so the Rotorflight-specific machinery is only loaded for a Rotorflight
craft. Nothing else changes: with one entry there is nothing to choose wrongly.

**Upgrading needs no action.** An UltiDash placed under 0.7.x carries no stored value for an
option that did not exist then; EdgeTX hands it to the widget as an out-of-range `0` and the
widget reads that as *Rotorflight*. Nothing is announced, nothing is reset and no setting
moves — the option simply shows *Rotorflight* the next time you open the dialog. The same
applies to a model file hand-edited to a nonsense value, or written by a later UltiDash that
offered more entries: anything unrecognised falls back to *Rotorflight*.

A `Target=` line in a per-model `cfg_m_<model>.cfg` is **ignored** — this option lives in the
EdgeTX model file, never in the settings store, and the dialog always wins.

**The cross-check.** When the declared target is *Rotorflight*, the link is up, the model has
telemetry sensors, the sensor resolver derived its index base, **and** not one Rotorflight
telemetry sensor was recognised, the *Sensor check* page (§3.6) and **menu ▸ Status** say so:
*"no Rotorflight sensors found"*. It states what was observed, not what is wrong — a model
whose sensors were renamed away from their Rotorflight IDs looks identical from the radio's
side. All five conditions must hold, so a cold radio, a powered-down craft or a model without
telemetry never triggers it.

Place **exactly one** UltiDash instance — if
two are placed, both drive callouts and the shared state (doubled announcements) and a
**"2 Dashboard instances active!"** banner appears on both until you remove one.

> ⚠️ **Upgrading from a version with `ViewMode`:** the second-screen *ELRS details* /
> *Status info* views were removed (the feedback round found no real use). A second
> instance that was set to one of them becomes a **full dashboard** after the update —
> the banner above is the symptom. **Delete the second instance.** The same data lives on
> as the Dashboard's own detail pages (tap the link bars / the status line) and the
> menu's **Status** entry.

Everything else is configured **inside the widget**, not in the EdgeTX option list.

### 2.2 The in-widget settings menu

1. **Long-press** the widget → **Full screen**.
2. Tap the **☰ menu glyph** (top-left, before the clock) — **disarmed only** (no config
   in flight). The tap target is the whole top-left corner.
3. The **menu hub** is a **two-column** grid of icon tiles. First the two things you *do* —
   **Settings** and **Toolbox** (the tool pages, §2.7b) — then a **‹ Diagnostics ›** heading
   over the three pages that only read something out: **Status**, **ELRS Status** (§3.6a)
   and **Sensor check** (§3.6). The heading groups them; it costs no tap, all three stay
   exactly where they were.

**Settings** shows the **whole configuration on one screen**: all 13 groups as icon tiles in
a 3-column grid under four themed section headings. Nothing scrolls on the TX16S MK3 (55 px
rows) or the TX15; the 480×272 MK2 scrolls by about one row. Pick a group to open its page,
its back arrow returns here:

| Section | Groups |
|---------|--------|
| **Appearance** | **Display**, **Skin** (§2.3s — the active skin's own colour scheme + options), **Colors** (§2.3b — submenu, one page per scheme of the active skin) |
| **Battery & limits** | **Telemetry** (submenu: *Tele Main* / *Tele Details* / *Live monitor*, §2.3a/§2.3b), **Battery**, **Thresholds**, **ESC load** (§2.5a) |
| **Sound & callouts** | **Volume** (§2.6), **Alerts** (§2.6a — submenu, one page per alert), **Voice** (submenu: *Switch voice* §2.7 / *Gov voice* §2.7-gov / *Telemetry report* §2.7-say) |
| **System** | **Shortcuts** (§2.7c), **Toolbox** (§2.7b), **General** (§2.7a) |

**Every menu page carries its own header icon** — the same glyph as the tile that opened it,
so a page shows where you are before a word of it is read.

**And the header spells that path out.** On every page of the menu tree the title stays
**UltiDash**; the line under it is the **full navigation chain**, joined by ` > `. The hub
reads *Menu*, the settings grid *Settings*, the Toolbox menu *Toolbox*; a plain group page
reads *Settings > Display*, the alert list *Settings > Alerts* and one alert *Settings >
Alerts > Voltage*, a colour page *Settings > Colors > UltiDash dark*, a Telemetry page
*Settings > Telemetry > Tele Main*. The three read-out pages sit under the hub's
*Diagnostics* heading and say so: *Diagnostics > Status*, *Diagnostics > ELRS Status*,
*Diagnostics > Sensor check*. The tool pages (§2.7b) and the battery pickers are not part of
that tree and keep their own titles.

**Sibling pages have two ways forward, and both are on the page.** Where several pages belong
to one set — the eight plain settings groups, the 13 alert pages, and the pages inside
*Colors*, *Telemetry*, *Voice* and *Shortcuts* — the page header carries **‹ ›** arrows that
step to the previous / next page and **grey out at the ends** of the set, and the top of the
page body carries an **icon strip**: one cell per sibling, the current one highlighted. Tap a
cell to jump straight to that page, or turn the **rotary encoder** onto it and press. The
strip is the encoder's route (EdgeTX offers the header arrows to touch only), which is why it
is there and not in the header: it sits inside the scrolling body, so it **scrolls away with
the content** — and comes back by itself as soon as encoder focus reaches it again. Where a
whole set shares one glyph (the 13 alert pages, the three Telemetry pages) the strip reads as
a position indicator: it still shows where in the set you are, and every cell still jumps.

Bools are real toggle switches, multi-value options are dropdown pickers, numbers use
−/+ buttons (long-press = bigger step), the two volume percentages are real sliders; all
controls on a page share one right edge and rows are separated by thin lines. Edits are
**saved automatically** when a page is left (back arrow or **RTN**); arming or leaving
full-screen also saves. Each group page also has a **Reset <page> to defaults** button
(with confirmation) that resets only that page's settings.

**Resetting everything is a row now, not a button under the grid.** *Reset to defaults* for
the whole model is the **last row of the *General* group** (§2.7a) — same confirmation, same
effect as before, only its place changed (that button and the space it reserved are what the
13 group tiles now use). Confirming it resets every setting of this model, **drops the
unsaved edits** of the page you are on so nothing can be written back over the fresh
defaults, and returns you to the settings menu.

### 2.3 Settings — Display

Display holds the settings that are **common to every skin**. Anything specific to a
particular layout — including the **colour scheme** — lives in the **Skin** group (§2.3s).

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Dashboard skin** | choice | UltiDash | the flight/stats **layout** (§2.3s). This release carries the built-in **UltiDash** look; the choice lists every skin file found in `skins/` beside it. Each skin has its own colour scheme + options in the *Skin* group |
| **Fill background** | bool | on | fill the panel background color |
| **Units on detail pages** | bool | **off** | show the unit (V / A / rpm / °C …) as a small suffix next to each value on the **detail pages**. **Off = the original formatting:** the value keeps the whole column and therefore the biggest font that fits. Worth turning on where there is room (800×480); on 480×320 (TX15) / 480×272 (TX16S MK2) it costs font size where there is none to spare. **Since 0.8.0 the dashboard's own units belong to the skin** — *Skin ▸ Units beside values* — because what a unit costs in font size is a property of the layout. Under the built-in **UltiDash** skin the two rows are the same switch, exactly as before; another skin may carry its own, and a skin that declares none follows this row |
| **Stats page** | choice | On disconnected | Never / On disarmed / On disconnected |
| **Voltage shown as** | choice | Cell voltage | Cell voltage / Battery voltage |
| **Close detail pages on arm** | bool | off | when on, arming closes an open detail page (off = keep ELRS detail open in flight) |
| **Open page on arming** | choice | Off | bring a **detail page up by itself** when the craft arms — the in-flight counterpart to *Stats page*, which governs the disarmed side. Off / ELRS / Status log / Battery / Telemetry. It opens **once per arm**, a moment after the arm so the view switch is settled, and only in full screen with nothing else on screen; close it like any other page (the **X**, RTN, a bound switch) and it stays closed until the next arm. Nothing happens if you were already looking at something else. **Greyed out while *Close detail pages on arm* is on** — that option re-closes any detail page for as long as you are armed, so the two cannot both hold |
| **Tap zones for detail pages** | bool | on | enable tapping the bars / status line / gauge to open detail pages (the menu glyph stays active either way) |
| **Keep backlight on (full screen)** | bool | on | while UltiDash owns the **whole** display, defer the radio's *Backlight off after* timeout each pass. With the backlight already off, EdgeTX spends the next press on waking the screen and no widget sees it — that is the tap meant to open a detail page. Only in full screen: in a layout zone the radio's own power saving stands. Your *Backlight off after* setting is deferred, never overridden |

> **Moved to the skin (0.7.0).** *Color scheme* and the top-bar / left-panel rows
> (*Top-left shows*, *Top bar clock*, *Timer*, the *RQ / TQ / RSSI / TX-voltage* toggles,
> *Link bars: color only on warning*) are now part of the **Skin** group (§2.3s) — they
> describe the UltiDash layout, not every skin. Stored keys are unchanged.
>
> The former *Bottom bar* section is gone too: **Status bar: TPWR** moved into **every
> skin's own options** (§2.3s) — it toggles content of the status bar, and whether that bar
> is shown at all is already a per-skin setting. **TX power limit (mW)** (the old *TPWR bar
> max*) moved to **Thresholds ▸ Link & signal** (§2.5) — it describes this transmitter's
> ELRS dynamic-power ceiling, not the display. Stored keys are unchanged.

> Hands-free opening of detail pages **and** Toolbox tools by switch now lives in its own
> **Shortcuts** group (§2.7c) — the old *Detail page switch* / *Switch opens* rows and the
> Toolbox *Activation switch* were folded into it.

### 2.3s Settings — Skin

The **Skin** group holds everything that belongs to the *currently selected* dashboard
skin (chosen with **Display → Dashboard skin**): its **Color scheme** row (always first),
then that skin's own layout options. Switch the skin and this group's contents change with
it. Each skin **remembers its own** scheme pick and option values independently — switching
away and back restores them.

**Built-in skins**

| Skin | Layout | Own colour schemes | Own options |
|------|--------|--------------------|-------------|
| **UltiDash** | the classic three-panel dashboard (status · battery gauge · values) with the top bar and status bar — the default, unchanged | *UltiDash* / *UltiDash dark* / *EdgeTX theme* (the historical three) | *Top-left shows*, *Top bar clock*, *Timer*, *Top bar: RQ / TQ / RSSI / TX voltage*, *Link bars: color only on warning*, *Status bar: TPWR* |

> **Rows several skins share.** Options that configure a **host component** rather than a
> skin's own drawing — the top-bar rows (*Top bar clock*, *RQ / TQ / RSSI / TX voltage*,
> *Link bars quiet*), *Timer* and *Status bar: TPWR* — use the same stored key in every skin
> that offers them, so they are set **once for all of them** (only each skin decides whether
> it draws that component at all). A skin's *own* rows are per-skin and independent.

> **A skin that draws no top bar draws no menu glyph.** The settings menu stays
> reachable regardless: **tap the top-left corner** of the screen in full-screen — the host
> keeps that region tappable whatever the skin draws there, and a skin that draws its own
> header can place the tap zone itself.

The **Color scheme** row lists the active skin's schemes only. Their colours are edited
the usual way under *Settings ▸ Colors* (§2.3b), which shows one page per scheme of the
active skin. A skin's colour overrides are stored under the skin's own keys, so different
skins never share a palette and switching skins never disturbs another skin's colours.

Some schemes are **fixed**: their colours are defined by the skin itself and are not
user-adjustable (they appear in the *Color scheme* choice but get no *Colors* page). A
skin declares that per scheme; the built-in UltiDash look has none.

> **Adding your own skins.** Skins are Lua files in `WIDGETS/UltiDash/skins/` and are
> **discovered automatically** — dropping the file in is the install (the file name is
> the skin's id). See **[SKINS.md](SKINS.md)** for the skin API, the value catalog and
> the rules. A broken or missing skin falls back to the built-in UltiDash look — never a
> blank screen.

> **Color scheme — feedback-dependent.** UltiDash is developed and tested against the
> built-in **UltiDash** palette (the primary path). The **EdgeTX theme** option
> (theme-aware colors) is **not the maintainer's personal focus**, is less tested, and
> relies on community feedback — please report theme glitches with a screenshot.
> On **EdgeTX theme**, the semantic status colours (green/yellow/red/neutral) automatically
> switch to the bright variant when the radio theme's panel surface is dark. UltiDash reads
> the theme colours once when its script loads, so **after changing the radio theme, reload
> the model (or restart the radio)** for the new theme colours to take effect.
>
> The **menu and settings pages always follow the radio's EdgeTX theme** (their background and
> scrollbar are native EdgeTX page chrome that a widget cannot repaint) — even on the
> *UltiDash dark* scheme, where the dashboard itself is black. For a dark menu, choose a dark
> EdgeTX theme.

### 2.3a Settings — Tele Main / Tele Details (configurable value slots)

The right-hand dashboard panel and the Telemetry detail page (§3.4) show **freely chosen
sensors**. Two groups configure them; each row is a **sensor picker**.

| Group | Slots | Default sensors |
|-------|-------|-----------------|
| **Tele Main** | `Panel 1..5` (the 5 right-hand dashboard rows) | Voltage (auto), Headspeed, Current, ESC Temp, BEC |
| **Tele Details** | `Detail 1..12` (the Telemetry detail grid) | Battery, Cell, Current, Energy Used, Fuel, then 7× **Off** |

Each row is a **two-field hybrid**, both writing the same slot:

- The **curated dropdown** lists **— Off —**, **Voltage (auto)**, **ESC Load (calc)** and
  the Rotorflight sensors UltiDash knows on this model (friendly labels) — plus a single
  **‹ Raw sensor ›** display entry. The known-sensor catalog covers the battery/cell values,
  both ESC groups (`Esc*` / `Es2*`), the rail voltages & currents (`Vesc`/`Vbus`/`Vmcu`/
  `Iesc`/`Ibec`/`Ibus`/`Imcu`), MCU loads, and altitude / attitude / GPS sensors.
- The **raw field** next to it is EdgeTX's **native telemetry source picker**: pick *any*
  sensor the radio has, including ones UltiDash doesn't curate. A raw pick flips the
  dropdown to ‹ Raw sensor ›; a curated pick blanks the raw field (`---`). The selection
  is stored as the EdgeTX **sensor name** (string) so it stays identified before EdgeTX
  re-discovers it (raw picks additionally persist the source index so both the picker and
  the value read survive a restart).
- **Voltage (auto)** is the smart cell/battery voltage with the warn color (the dashboard's
  original slot-1 behaviour) — it follows *Display → Voltage shown as*.
- **ESC Load (calc)** is the computed ESC utilization % (§2.5a) — it shows `not set`
  until ESC-load monitoring is on and the limit GVAR is delivered.
- Known Rotorflight sensors get a friendly label, decimals and a **unit** (V, A, °C, mAh,
  %, rpm, …); raw sensors show their EdgeTX name and the precision EdgeTX reports.

### 2.3b Settings — Live monitor (the Toolbox curve tool's sensors)

The **Live Monitor** (Toolbox ▸ Logs, §2.7b) draws up to **4 sensors as live curves** —
after a manoeuvre, one glance answers *how deep did the headspeed sag, how fast did it
recover*, without a PC and without waiting for the flight's log file. Its slots are the
same sensor-picker rows as above:

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Strip 1..4** | sensor | Off | each configured sensor gets a full-width strip; the screen divides by the number configured |
| **Window** | choice | 30 s | 15 / 30 / 60 s — also switchable on the page itself; the recorder always keeps 60 s |

**Sampling runs while the page is closed** (that is the point: open it *after* the
manoeuvre and the manoeuvre is there). Every reading the radio sees is kept as a 0.2 s
**min/max band**, so a one-frame spike cannot fall between samples. Three honest limits:
a peak shorter than the **sensor's own telemetry interval** never reaches the radio and so
never reaches the strip; sampling is **coarser while another screen is shown** (EdgeTX
calls a hidden widget less often); and with **no sensor configured the feature costs
nothing at all** — no memory, no per-cycle work. `menu ▸ Status ▸ Live monitor` shows
whether the recorder is actually running and how much of the 60 s ring is filled.

> **Duplicate / renamed sensors.** UltiDash reads its known sensors by their Rotorflight
> **sensor ID**, so it is immune to duplicate names (a leftover native CRSF `Curr`/`Capa`/… next
> to the custom-telemetry one) and to renaming a known sensor on the radio. After moving a
> model to custom telemetry, deleting the orphaned standard sensors (`RxBt` & co.) is still the
> tidy thing to do, but no longer required for correct readings.

### 2.3b Settings — Colors (per-scheme color overrides)

*Settings ▸ Colors* opens a submenu with **one page per colour scheme of the active skin**
(for the UltiDash skin: UltiDash / UltiDash dark / EdgeTX theme; other skins list their own
schemes — §2.3s). Each page lists that scheme's adjustable color roles; a row shows the role
name, a **Def** button and a color swatch — tap the swatch to open the native EdgeTX color
picker, tap **Def** to revert that color to the scheme's built-in. The page's *Reset … to
defaults* reverts the whole scheme.

| Section | Roles | Notes |
|---------|-------|-------|
| **Palette** | Text / foreground, Base background, Strong lines / text, Accent fill, Panel surface, Accent / headings, Warning accent, Dim / disabled accent | the scheme's 8 base palette slots — *UltiDash* and *UltiDash dark* pages only (the EdgeTX theme defines these itself) |
| **Traffic-light** | Good (green), Warning (yellow), Critical (red), Neutral (quiet) | the semantic status colors (link bars, gauges, states) — on **all three** pages, since the EdgeTX theme does not define them |
| **Status text** | Armed, Disarmed | the statusbar arm-state text (and the Status page's "Armed" line) — on **all three** pages. Unset, they follow the historical colors: *Armed* the effective Good (green), *Disarmed* the Warning accent (palette slot 7) |
| **Chrome** | Panel background (fill), Bar track / empty, Tick marks, Dim secondary text | neutral UI chrome — UltiDash / UltiDash dark pages only |
| **Battery** | Battery bar OK / not full / low / critical / cell check, TX battery OK / low | the main battery bar's five fill colors (§4) and the top-bar TX battery icon — historically fixed, on **all three** pages |

Overrides are stored **per model** in the cfg file (§2.8) as `Clr<scheme><role>=0xRRGGBB`
keys — only for colors you actually changed; everything else follows the built-ins (and, on
the EdgeTX-theme scheme, the active radio theme). That is no longer a colour speciality: the
cfg file stores *any* setting only while its value differs from the default, and a color put
back on **Def** simply loses its line again (§2.8). Colors apply on the next rebuild after
leaving the settings (autosave as usual).

> Upgrading from v0.5.x: the *Color scheme* list order changed (dark is now slot 2, EdgeTX
> theme slot 3). A stored scheme choice is remapped automatically on first load — the scheme
> you picked stays the scheme you get.

### 2.4 Settings — Battery

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Reserve (%)** | num | 20 | reserve capacity; 0 % displayed = reserve reached |
| **Fuel: announce below (%)** | num | from full | fuel callouts start below this level (100 = from full) |
| **Fuel: coarse step (%)** | num | 10 | callout spacing above the dense zone |
| **Fuel: dense below (%)** | num | 15 | below this level the fine step applies |
| **Fuel: fine step (%)** | num | 5 | callout spacing in the dense zone |
| **Fuel callout says** | choice | Percent | what the descending %-step callouts speak: **Percent** / **Battery V** (pack, PREC1) / **Cell V** (per-cell, PREC2) / **% + Battery V** / **% + Cell V** — the %-interval *triggering* is unchanged |
| **Volt callout 1 (V/cell)** | num | off | extra orientation callout at a fixed per-cell voltage (0 = off) |
| **Volt callout 2 (V/cell)** | num | off | second fixed per-cell voltage callout (0 = off) |
| **Volt callout delay (s)** | num | 3 | the cell voltage must stay at/below a threshold this long before it speaks (0 = immediate); filters brief load sags |
| **Cell thresholds from** | choice | FC config | FC config (`mspBatteryConfig`) / Manual |
| **Full cell (manual)** | num | 4.12 V | only used when *Manual* |
| **Low cell (manual)** | num | 3.45 V | only used when *Manual* |
| **Critical cell (manual)** | num | 3.30 V | only used when *Manual* |
| **Cell-check delay (s)** | num | 4 | duration of the startup cell-check. The verdict waits for a reading that belongs to **this** pack: while the voltage is still the previous pack's, or while no per-cell value exists yet (the FC's cell count has not arrived), the grey bar keeps running and the delay restarts — for at most **30 s**, after which the check decides on what it has |
| **Announce voltage as** | choice | Battery | voice: **Battery** (total pack, PREC1) / **Cell** (per-cell, PREC2) — for the voltage alert + cell check |
| **Current sensor** | choice | Curr | which sensor feeds the Current row, ESC load and current min/max (see *Data sources* below) |

**Announce voltage as** is independent of *Display → Voltage shown as*: the display and
the spoken value are chosen separately (e.g. show cells, announce the pack). The spoken
value is the latched, collapse-filtered voltage; *Cell* falls back to the pack voltage
when no per-cell reading is available (never silent).

**Data sources — Current sensor:** **Curr** = the FC battery-current sensor (previous
behaviour); **EscI** = current from the ESC #1 telemetry group; **Iesc** = ESC current from
the FC single-value group. Whatever you pick drives the Current row, the ESC-load monitor
and the current min/max — so a model that reports current only over ESC telemetry (no FC
current sensor) can now show current and use the ESC-load monitor. The stats min/max then
refer to the chosen source.

The four **Fuel** settings shape the fuel-callout density (value-driven, descending %):
quiet up high, denser near the end. The defaults reproduce the historical cadence
(announce from full in 10 % steps, every 1 % below 10 %). Steps are spoken **only on the
way down** — a level that rises again (pack recovering off-load, a fresh pack, an FC value
jumping back) re-arms the ladder silently instead of counting its way back up. Two steps
are never spoken closer together than **2 s**; that gap only stops them treading on each
other. The Fuel alert's *Repeat interval* (§2.6a) applies to the **critical nag only**
— until 0.7.0 it also gated the steps, which swallowed one whenever the fine steps passed
faster than the repeat gap (i.e. exactly at the end of a flight).

**Fuel callout says** changes *what* those descending step callouts announce without
touching *when* they fire: the remaining **percent** (default), the **battery/pack
voltage** (PREC1), the **per-cell voltage** (PREC2), or the percent followed by one of the
two. It reads the latched, collapse-filtered voltage and is independent of *Announce
voltage as* (which scopes only the voltage alert and the startup cell check); a
voltage-only choice with no plausible reading falls back to the percent (never silent).
The critical (below-critical) nag is unaffected — it keeps speaking the percent.

**Volt callouts 1 & 2** are a *second*, voltage-triggered gate that runs **alongside** the
%-step callouts (not instead of them): set a per-cell voltage (e.g. 3.80 and 3.75 V) and
UltiDash speaks that voltage **once per flight** the first time the cell voltage settles
at/below it. Each is announced per *Announce voltage as* (pack or per-cell). **Volt callout
delay** is how long the voltage must stay in-band before it fires — so a brief sag through
a hard maneuver doesn't trigger the callout early (0 = immediate). Both are `0 = off` by
default; they re-arm on the next arm (i.e. each flight / battery). They ignore the low and
critical *Voltage* alert thresholds (§2.6) — these are purely for orientation at a level
you choose. MAIN-POWER-LOST suppresses them (the frozen last-good value is not a reading).

Both thresholds are published to the skin API, so a skin that draws a cell-voltage scale can
**mark them on it** — a tick in the text colour next to the red *alarm* and yellow *warning*
ticks, so you see where the callout will fire. Whether it does is that skin's own option; the
built-in UltiDash look draws no cell scale.

With **FC config** the thresholds come from the Rotorflight FC
(`vbatfullcellvoltage` / `vbatwarningcellvoltage` / `vbatmincellvoltage`), read on
connect/disarm and cached. Cell count and capacity always come from the FC.

### 2.5 Settings — Thresholds

Warning thresholds, grouped by subject with section headers on the page. *(The former
"Callout interval" is gone — repeat cadence is now configured **per alert**, §2.6a. The
ESC-load thresholds live in their own group, §2.5a. New in 0.7.0: **TX power limit**, the
old Display row "TPWR bar max" — same key, it is a per-transmitter setup limit.)*

**Link & signal**

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Link warn (%)** | num | 80 | RQly warning. High by design — RQly sits at ~100 % in clean flight |
| **Link critical (%)** | num | 50 | RQly critical |
| **RSSI warn (% headroom)** | num | 15 | best-antenna signal margin above the rate floor (see note) |
| **RSSI critical (%)** | num | 8 | RSSI critical |
| **RSSI hold time (s)** | num | 2 | low RSSI must persist this long before warning (filters rotational nulls) |
| **Skipped-packet limit** | num | 50 | armed: `*Skp` counter reaching this → callout |
| **TX power limit (mW)** | num | not set | this transmitter's **ELRS dynamic-power ceiling** (25 / 100 / 250 / 500 / 1000 mW — region- and config-dependent). It is the 100 % reference of the inverted TPWR bar on the ELRS detail page (§3.2), so you can see how close dynamic power runs to its limit. *not set* → that bar stays empty and shows a hint; the raw mW value is still printed |

**Power & BEC**

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Power warn from** | choice | Cell count (auto) | how the main-power-loss threshold is derived: **Cell count (auto)** = cells × *Power warn (V/cell)*, **Fixed voltage** = the manual value below |
| **Power warn (V/cell)** | num | 3.0 V | per-cell collapse mark for the auto threshold (3S × 3.0 V = 9.0 V — the historical default) |
| **Power warn voltage** | num | 9.0 V | the fixed threshold — used with *Fixed voltage*, and as the fallback while no cell count is known yet |
| **BEC warn (% drop)** | num | 8 | live BEC this far below the flight's reference → warning |
| **BEC critical (% drop)** | num | 15 | … and this far below → critical |

> **The auto threshold adapts to the pack.** With *Cell count (auto)* (default) a 2S warns
> at 6.0 V, a 6S at 18.0 V, a 12S at 36.0 V — no per-model tuning needed; 3S behaves
> exactly like the old fixed 9.0 V default. The cell count comes from the live `Cel#`
> sensor or the FC battery config; until one is seen, the fixed voltage applies. If you
> had hand-tuned *Power warn voltage*, set *Power warn from* to *Fixed voltage* once.

**Temperature** (drives the *Temperature* alert, §2.6a)

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **ESC warn (C)** | num | 90 | armed: live `Tesc` at/above this → ESC-temp warning (**0 = off**) |
| **ESC critical (C)** | num | 110 | … and at/above this → ESC-temp critical |
| **MCU warn (C)** | num | 75 | armed: live `Tmcu` at/above this → MCU-temp warning (**0 = off**) |
| **MCU critical (C)** | num | 90 | … and at/above this → MCU-temp critical |

> **RSSI thresholds are `% headroom`, not raw dBm.** The widget maps the ELRS RSSI
> (`1RSS`/`2RSS`) to 0–100 % between the **current rate's sensitivity floor** (from `RFMD`)
> and a fixed top of −40 dBm, then warns on the **better** antenna's headroom, so the same
> thresholds work across rates. Defaults (15 / 8) are intentionally low: in real "all fine"
> logs the headroom stayed ≥ 16 % with RQly at 100 %.

> **BEC thresholds are relative (self-calibrating).** The reference is the BEC voltage
> **at the moment of arming** (first plausible reading, frozen for the flight; reset on
> disarm/disconnect) — so the same % thresholds work for any 5 V / 6 V / 8.4 V BEC
> without configuration, and the alarm sensitivity doesn't drift mid-flight.

### 2.5a Settings — ESC load

An **entirely optional** feature (off by default): the ESC continuous-current **load
monitor**. A GVAR on the model holds the ESC's continuous-current limit in **amps**.

**Prerequisite — filling the GVAR:** the Rotorflight **RF2/RFTool Lua suite** (which
UltiDash requires anyway) can be configured **per model** to write FC values into GVARs —
map the ESC's continuous-current limit to a free GVAR there, and point *ESC limit: GVAR*
at it. UltiDash only ever **reads** the GVAR (and zeroes it at session end, since the
writer never clears it).

UltiDash then computes **load % = current / limit × 100** and shows it as a live load
bar (see *Load bar* below) plus the **ESC Load (calc)** telemetry slot (§2.3a).

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **ESC load monitoring** | bool | off | **master switch** — off = the whole feature is off (no bar, tile shows `not set`, no alarm, the GVAR is never touched) |
| **ESC limit: GVAR (A)** | num | Off | which GVAR holds the limit; **Off = feature off** as well |
| **Warn (%)** | num | 80 | bar/tile turn yellow; sustained → warn alarm |
| **Critical (%)** | num | 100 | bar/tile turn red; sustained → critical alarm |
| **Alarm hold time (s)** | num | 5 | load must stay at/above a threshold this long before the alarm fires (ESCs tolerate short bursts above the continuous limit) |
| **Load bar** | choice | Current row | where the dashboard shows the live load: **Current row** = the classic thin bar under the Current value, or **Battery gauge** = the **whole free gap** between the gauge's fill segments and its outline becomes the load display, filling **bottom-up** like a rising liquid and following both contours (the outline's rounded corners and the segments' rounding). The side gaps reaching the top means **100 %**; the **top gap is the overload zone** — it fills over **100…150 %** and the ring closes completely at ≥150 %, so a sustained overload is visible at a glance. The unfilled gap stays **transparent** — nothing shows at zero load |

The **Battery detail page** (§3.4) always shows the same gap-ring load display in its
battery graphic while monitoring is on — regardless of the *Load bar* choice (filling
left → right there, the direction the laid-down battery fills).

- The limit is **latched once per session** (polled for up to 10 s after connect); on the
  disarmed disconnect the latch and the GVAR are cleared for the next session. GVAR reads
  are local — no MSP, armed-safe.
- The **alarm** is a separate opt-in: the *ESC load* alert's **Active** switch (§2.6a).
  It fires only while armed, and only when monitoring is on — display without alarm is
  simply *monitoring on, alert off*.

### 2.6 Settings — Volume

Two independent loudness worlds (see §5.4 for the full picture):

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Callout volume** | num | System | System / 1 (min) … 5 (max) — the per-WAV mix level of UltiDash's own callouts |
| **Widget volume applies** | choice | Always | Always / Only connected |
| **Master volume via GVAR** | num | Off | Off / GV1…GV15 — bridge to the radio's **master volume** through a model *Volume* special function (§5.4) |
| **Normal volume (%)** | slider | 80 | master volume written while connected (GVAR world only) |
| **Escalation volume (%)** | slider | 100 | master volume while an alert with *Escalation volume* is active (GVAR world only) |
| **Test callout** | button | — | *Play* previews a callout ("battery" + "70 %") with the page's **current, unsaved** volume/mute values |

The GVAR bridge is **optional** and needs a **one-time radio-side model setup** (an
input, a logical switch and a *Volume* special function — step-by-step example in §5.4).
Without it, callouts simply use the radio volume and the two sliders do nothing.

### 2.6a Settings — Alerts (per-alert pages)

**Alerts** is a submenu: a **Voice / mute** page plus **one page per alert**, so every
alert is configured in one place. Every alert page opens with a one-line summary of **when
the alert fires**.

**The list is a column of cards, and it scrolls** (0.8.0 — it used to be a two-column tile
grid). One card per page: the **name** on the first line, and on the second the alert's state
as glyphs together with the values it is actually working with.

| On the second line | Means |
|---|---|
| **bell** | the alert is on |
| **struck bell** | it is off — the card **dims but still opens**; its page is where you switch it back on |
| **loop** + `3x 5s`, `inf 5s` | *Repeat* is on, with its count and interval; `inf` = repeat until the condition clears |
| **vibration mark** | *Vibrate* is on |
| **loudspeaker** | *Escalation volume* is on — drawn only where it is effective (it needs the master-volume GVAR, §2.6) |
| **overlay mark** | *Fullscreen overlay* is on — only on the alerts that offer one |

The value beside the glyphs is read from **the same settings the alert itself reads**, so it
cannot disagree with what the alert does: the fuel reserve, announce start and step; the extra
voltage levels and their hold; the link and RSSI warn/crit pairs; the power threshold with the
source it uses; the BEC drops; the ESC and MCU temperature steps; the skipped-packet limit. Two
cards say why there is no number of yours to show — **Cell check** reads *"thresholds from FC
config"* unless *Cell thresholds from* is set to *Manual* (§2.4), and **ESC load** reads
*"monitoring off"* until both the monitor and its GVAR are set up (§2.5a) — and the alerts
that have no threshold at all (*Armed / disarm*, *Telemetry*) say **"no threshold"**. A value
the widget does not have yet shows as `-` rather than a number that would only be a guess. The
**Voice / mute** card carries the two master switches on the same bell and vibration glyphs,
plus the voice language in force.

> **Gone with the grid (0.8.0):** the **+R / +E / +V / +O** text markers and the legend row
> that explained them. The glyphs are the legend, and the numbers that used to be one page
> deeper are on the card.

**Voice / mute**

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Voice language** | choice | English | English / Deutsch — picks the `/SOUNDS/<lang>/ultidash/` voice pack (spoken numbers/units still follow the radio's system language). **Deutsch needs the separate voice-pack download**; without those files the callouts are simply silent |
| **Mute (master)** | choice | None | None / **All** silences every **voice** callout (audio only) |
| **Vibration (master)** | bool | on | master switch for **haptic** feedback, independent of *Mute* — turn off to stop all vibration while keeping (or muting) sound separately |
| **Overlay auto-close (s)** | num | until tapped | shared timer for the **fullscreen alert overlay** (below): >0 = the overlay closes itself after that many seconds; 0 = it stays until tapped or the condition clears. The timer counts from the episode's **start** — also while a menu or detail page covers the overlay |
| **Config warning overlay** | bool | **on** | shows a **misconfiguration** in the same red box, in words you can act on. Today one message: the ELRS module's link rate and telemetry ratio against what the flight controller was told (§3.6a) — both sides, what the difference does, and the two values to set. **Disarmed only**, and only after a link connect actually measured one; the three alert overlays above always take precedence. Closed with the **X** in its corner, and it does not come back until the next connect |
| **Test callout** | button | — | *Play* previews a callout in the **currently selected (unsaved)** language |

**Per-alert pages** — Fuel, Voltage, Cell check, Armed / disarm, Telemetry, Link quality,
RSSI / signal, Main power lost, BEC voltage, ESC load, Temperature, Skipped packets. Each
page has the same rows:

| Setting | Type | Notes |
|---------|------|-------|
| **Active** | bool | the alert's on/off (voice + vibration together) |
| **Repeat** | bool | re-announce while the condition still holds |
| **Repeat count** | num | 0 = until cleared, else total announcements (**includes the first** — e.g. "3 total") |
| **Repeat interval (s)** | num | spacing between repeats |
| **Escalation volume** | bool | while this alert is active, boost the GVAR master volume to *Escalation volume (%)* (§2.6 — GVAR world only). **Not shown on Cell check / Armed-disarm** (one-shot alerts with no escalation) |
| **Vibrate** | bool | haptic pulse with this alert |
| **Fullscreen overlay** | bool | **only on Main power lost / Voltage / Telemetry** (default off): while the alert is active, an unmissable red inset box covers the flight/stats view — big alert title plus the live value (buffer/BEC voltage, cell voltage). **The X in the box's top-right corner closes it, and nothing else does** — a tap elsewhere on the box is swallowed and ignored, so a mis-tap cannot throw the warning away before it has been read (0.8.0; the tap-anywhere it replaces is the same change the detail pages got). *Overlay auto-close* (Voice / mute page) can still close it by itself. It reappears only when the condition clears and fires again; the Voltage overlay covers the **critical** level only |

The same box carries one message that is **not** an alert — see *Config warning overlay*
below.
| **Test callout** | button | *Play* previews **this alert's** real announcement (with a sample number where the live callout speaks one; voltage alerts follow *Announce voltage as*) using the current, unsaved language/volume/mute — works even while the alert is off, so you can hear it before enabling |

Rows that depend on another setting (e.g. *Repeat count* / *Repeat interval* when *Repeat* is
off, or *Escalation volume* without a master-volume GVAR) show their label **dimmed** to
signal they currently have no effect — they still work, the greying is only a hint.

Defaults: every alert **Active** except **ESC load** (off — enable after setting up
§2.5a). **Fuel** and **Voltage** default to *Repeat = on, until cleared, 6 s* — exactly
the historical continuous callout cadence. **Main power lost** defaults to *Repeat = on,
until cleared* (an audible buffer countdown) and **Telemetry** to *Repeat = on, 3×* —
both safety-critical, where a single announce is easy to miss. The remaining alerts
default to *Repeat = off* (announce once per episode). **Vibrate** defaults to on for
Fuel, Voltage, Telemetry, BEC, ESC load, Temperature and Main power lost. `Mute = All` remains the
audio master kill-switch. With **Repeat** on, the **Voltage** alert re-announces the
current level — *low or critical* — while it holds, not just critical.

### 2.7 Settings — Switch voice

Announce TX-switch positions, read **read-only** from the switch — fully independent of
the model's mixer / logical-switch / arming logic.

| Setting | Type | Default | Announces |
|---------|------|---------|-----------|
| **Motor on/off switch** | switch | Off | "motor on" / "motor off" |
| **Rescue switch** | switch | Off | "rescue on" / "rescue off" |
| **Governor mode switch** | switch | Off | "governor on" / "governor off" |
| **Profile switch (1-3)** | switch | Off | "profile" + 1/2/3 |

Each row uses **EdgeTX's native switch picker** (filtered to physical + logical
switches, with the `!…` inverted variants) — so it shows exactly the switches *this*
radio has, including custom names. Use a logical switch to follow real conditions — e.g.
tie "motor on/off" to your arming-gate logical switch instead of the raw switch.
Announcements are debounced (0.3 s, so a 3-pos switch passing through the middle stays
quiet) and silent on boot / on first assignment. Rapid flipping does **not** queue a
pile of announcements: per switch at most one announcement per **1.5 s** — changes
inside that window are held and only the *current* position is spoken when it expires
(back at the already-announced position: nothing). Logical switches are on/off only; the
3-position profile needs a physical switch.

> ⚠️ **Upgrading from ≤ v0.4:** the switch selections use new storage keys (the native
> picker's source index). Old selections are **not migrated** — re-pick your switches
> once in *Settings ▸ Switch voice* (and any Shortcut switches, §2.7c).

<a id="27-gov"></a>
### 2.7-gov Settings — Gov voice

Speak the **governor state** (the `Gov` sensor, §Governor state below) whenever it changes
**in flight (armed only)** — a hands-free confirmation of spool-up, autorotation, bailout,
governor fallback/bypass, etc. Read-only from the cached telemetry value; issues no MSP.

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Announce gov state** | bool | Off | Master switch for the whole feature (opt-in). |
| *(per state)* | bool | On | One toggle each for **Throttle off / Throttle Idle / Spooling up / Recovery / Gov. Active / Throttle Hold / Gov. Fallback / Autorotation / Bailing Out / Gov. Bypass** — silence the states you don't want called out. Dimmed while the master is off. |

The spoken phrase follows the on-screen label ("governor active", "spooling up",
"autorotation", …). A state must hold **~0.3 s** before it's announced, so the codes the
governor passes through quickly on spool-up don't chatter; the state present at the moment
of arming is taken as the silent baseline (no announcement for it). Honors *Mute* and the
callout volume like every other callout. Disarmed, the feature is silent and re-baselines,
so it never fires on a state that was already there when you arm.

### 2.7-say Settings — Telemetry report (spoken)

Your **own telemetry readout, on demand**: up to eight sensors, spoken **in the configured
order**, triggered by a **shortcut switch** — bind any position or toggle slot (§2.7c) to
the target *Voice: Telemetry report*. A momentary press speaks one report; a **held
position slot repeats** it at the configured interval. It **may speak in flight** — alerts
keep precedence (below).

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Slot 1…8** | sensor | Voltage (auto), Headspeed, Current, ESC Temp, BEC, Link Qual, Off, Off | the sensors, spoken in this order (~2 s each). An empty/off slot is skipped; a sensor with no value is skipped too (with a debug-log line) |
| **Repeat (switch held)** | num | 30 s | 10–120 s, counted from the report's **start**. The 10 s floor is functional: eight slots run ~15–20 s — but see *Speak sensor names*, which roughly doubles that, so with names on pick an interval to match |
| **When an alert speaks** | choice | Report stops | or *Report pauses* — the report stands back and resumes after the alert. Either way an alert is never delayed by the report |
| **Speak sensor names** | bool | Off | opt-in: speak each sensor's name before its value, from `SOUNDS/<lang>/ultidash/s_<sensor>.wav` (lowercased sensor name, `%`→`pct`, `#`→`n`: `s_vbat.wav`, `s_batpct.wav`). **A missing file falls back to value-and-unit, never to silence** — *menu ▸ Status ▸ Report name wavs* counts the coverage. The **whole sensor catalogue ships recorded**, 62 clips per language in **English and German** (same voices as the governor callouts); a name averages **1.8 s (EN) / 1.9 s (DE)**, which is what roughly doubles the report's length |

*Voltage (auto)* speaks exactly like the voltage alert (latched value, in the format the
*Announce voltage as* setting selects). Honors *Mute* and the callout volume like every
other callout.

The name recordings are generated from the sensor catalogue, and their coverage is checked
against `SENSOR_INFO` in the source rather than against a list of its own — so a sensor added
without a recording is caught before it can turn the report quiet on the radio.

### 2.7a Settings — General

Meta settings: diagnostics, flight log and battery behaviour.

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Debug log to SD card** | bool | off | write a diagnostics log to the SD card (see §11) |
| **Debug log: sessions kept** | num | 20 | 1–50 — how many rotating log files to retain |
| **Show perf overlay** | bool | **on** | the small live *UI Hz / Lua heap / free heap* strip in the bottom-left corner, shown on every view while the debug log is on. Switch it off to keep the **log** without the strip over the layout — for a flight, a screenshot, or anything somebody else is going to look at. Dimmed while *Debug log* is off, which is the only state in which the overlay is not drawn anyway |
| **Log flights to SD card** | bool | off | flight log: one `flights.csv` line per flight (see §12) |
| **Log per-flight stats** | bool | off | append the flight-statistics (cell / headspeed P1-3 / current / ESC temp / BEC min-max, sag count+deepest, mAh) to each flight line; shown on the viewer's per-flight detail page (§12.4). Needs *Log flights* |
| **Min. flight time** | num | 30 s | 0–300 s — shorter arm cycles are not a flight (0 = log every arm) |
| **Ask battery on connect** | bool | off | battery query page after a fresh connect (needs `fltlog/batteries.cfg`, see §12) |
| **Battery sets FC profile** | bool | off | selecting a battery activates the matching FC battery profile — by capacity, or an explicit `profile=` override (MSP, disarmed) |
| **Reset to defaults** | button | — | *Reset* (with confirmation) puts **every** setting of this model back to its default — the whole-model reset, which until 0.8.0 sat as a button under the settings grid (§2.2). It also drops this page's unsaved edits and returns to the settings menu; the settings file is left holding nothing but its bookkeeping stamps (§2.8) |

### 2.7b Settings — Toolbox

The Toolbox embeds the **RF Adjustment Map / Editor** tool pages (view and touch-adjust
Rotorflight adjustment functions from the radio). Full setup — model prerequisites,
channels, GVAR pulse, labels — in **[TOOLBOX.md](TOOLBOX.md)**.

The Toolbox submenu additionally hosts five zero-config, **disarmed-only** tool pages
(no settings below apply to them): the **Flight Log** viewer (recent flights, per-model
totals and battery usage from the flight log — see §12), the **Log Viewer** (graphs EdgeTX telemetry logs
from `/LOGS/*.csv` — swipe-scroll the file list, then pick a built-in template or one of
your own — templates are made and managed on the radio, see [TOOLBOX.md](TOOLBOX.md) §8), **RF2 Config** (the
original rotorflight-lua-scripts configuration tool, run unmodified from `/SCRIPTS/RF2/`;
needs the RF Tool widget connected and force-closes on arming — see
[TOOLBOX.md](TOOLBOX.md) §8) and the **FC battery profile** picker (switches the flight
controller's active battery profile — the same page the dashboard's *B-Profile* field
opens, so it stays reachable with a layout that has no such field; it is the one page that
writes to the FC, and it needs a live MSP connection).

One more tool is deliberately **not** disarmed-only: the **Live Monitor** (up to 4 sensors
as live min/max curves of the last 15–60 s, §2.3b) — reading it *in flight* is its purpose,
so like the two adjustment tools it opens armed and is exempt from the arm-close. It reads
EdgeTX telemetry sources only; no MSP.

Opening a Toolbox tool by switch moved to the **Shortcuts** group (§2.7c) — a shortcut can
now open *Adjust Map*, *Adjust Edit*, *Log Viewer* or *RF2 Config* like any other page.

The **Log Viewer has a second entry point** outside the widget: EdgeTX's own **SYS ▸ Apps ▸
UltiDash Log Viewer** (`SCRIPTS/TOOLS/udlogview.lua`), which launches the very same module
with the same templates. It needs UltiDash installed on the card, and — unlike the Toolbox
entry — it has no arm-close, because EdgeTX suspends the widget for as long as any Tools
script runs. See [TOOLBOX.md](TOOLBOX.md) §8.

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Adj: Config channel** | num | CH11 | channel carrying the adjustment-function selector |
| **Adj: Value channel** | num | CH12 | channel carrying the adjustment value |
| **Adj editor: GVAR** | num | GV1 | GVAR pulsed by the editor's − / + buttons |
| **Adj editor: pulse (ms)** | num | 150 | pulse length |
| **Adj value divider** | num | 1 | display divider for the value channel |
| **Adj editor: ranges hint** | bool | off | show the recommended-range hint in the editor |
| **Toolbox sunlight mode** | bool | off | high-contrast toolbox palette |
| **Announce bank (voice)** | bool | on | speak "bank" + number when the adjustment bank changes — debounced: a bank must hold 0.3 s and two announcements stay 1.5 s apart, so a sweep speaks only its destination |

### 2.7c Settings — Shortcuts

Bind switches to pages, hands-free. Any target below can be a **detail page** (ELRS /
Status log / Battery / Telemetry), a **Toolbox tool** (Adjust Map / Adjust Edit / Log
Viewer / RF2 Config / Flight Log / FC battery profile / Live Monitor — the last one opens
**armed too**, like the adjust tools), the **spoken telemetry report**
(*Voice: Telemetry report*, §2.7-say — no page: it speaks, armed included, and a held
position slot repeats it) or the **menu** (*Page: Menu / settings* — opens the settings
hub on exactly the menu glyph's own condition: refused only while genuinely flying).
Detail targets open only over the flight view; the disarmed-only tools (Log Viewer,
RF2 Config, Flight Log, FC battery profile) refuse to open while armed. *FC battery
profile* additionally needs a live MSP connection — it is the one page that writes to the
flight controller — and re-reads the profile before it opens.
**Every** target opens only while the widget is **fullscreen** (both the detail pages and
the tools are fullscreen pages) — a switch held while not fullscreen opens as soon as you
enter fullscreen. In a widget-grid zone a detail page would have no way out: a zone gets no
touch, so its close button cannot be pressed. Throwing a bound switch while **not**
fullscreen therefore does nothing — and says so: the dashboard shows a brief
**"Shortcut needs Full screen"** banner, because in a zone there is no menu glyph to ask and
a silently dead switch is indistinguishable from a broken setting.
Works independently of *Tap zones* (§2.3); *Close detail pages on arm* still applies to
detail targets.

Two mechanisms:

- **6 position slots** — pick a **switch position** (one native EdgeTX picker: switch
  *and* position in a single pick, e.g. `SA↓`; logical switches work too) and what it
  *opens*. While that position is held the page is shown; leave it and it closes
  ("hold = open"). Use several slots on the same 3-position switch to map each position
  to a different page.
- **2 toggle slots** — pick a **switch position** and up to **4 options**. Each press
  (the switch entering that position — momentary switches like `SH↓` work naturally)
  steps to the next option (skipping any left on *Off*), then closes after the last:
  opt 1 → opt 2 → … → closed → opt 1 …
  **Hold the press for at least 0.2 s.** Switches are read from the widget's own pass, which
  runs about every 0.2 s, so the switch has to still be in the position when one of those
  samples lands. A shorter flick is not filtered — it is simply **sometimes** not seen, which
  from the cockpit is a switch that works most of the time. Measured on the MK3, five presses
  per length: **0.20 s and longer 5/5**, 0.15 s 4/5, 0.10 s 4/5, **0.06 s 1/5**. Position
  slots are unaffected (they are held anyway, and *Switch delay* is the relevant number
  there).

Each slot is its own section on the page (*Position slot 1…6*, *Toggle switch 1…2*). In
the *Opens* dropdown a target reads as `Category: Name` — detail pages `Page: …`
(e.g. `Page: ELRS`) and Toolbox tools `Toolbox: …` (e.g. `Toolbox: Flight Log`), so it is
always clear what kind of target a slot opens. The one entry without a prefix is
**FC battery profile**: it is a host feature rather than a Toolbox tool, reachable from the
Toolbox, from a tap zone and from here alike.

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Switch delay (ms)** | num | 300 ms | position must be held this long before it fires — passing *through* a middle position on the way to another therefore doesn't open the intermediate one (0 = instant) |
| **Switch position** (per position slot) | switch | --- | native EdgeTX switch picker — switch **and** position in one pick |
| **Opens** (per position slot) | choice | Off | the page this switch position opens |
| **Switch position** (per toggle slot) | switch | --- | native EdgeTX switch picker; a "press" = the switch entering this position |
| **Option 1…4** (per toggle slot) | choice | Off | the step chain; leave trailing slots on *Off* for a shorter cycle |

> A shortcut only ever closes the exact page **it** opened — a page you opened manually
> (tap / menu) is left alone. Closing a shortcut-opened page by hand while the switch is
> still held stays closed until the switch cycles (no auto-reopen).
>
> A **held position keeps retrying** an open that is currently refused (a disarmed-only
> tool while armed, a detail target while not on the flight view) and opens as soon as
> the block clears — e.g. hold the Log-Viewer switch in flight and the page appears right
> after disarming. **Toggle** steps do *not* retry: a refused step leaves the chain
> closed until the next press.
>
> **A toggle chain resynchronises when you close its page some other way.** Close a
> shortcut-opened page with RTN, by tapping it away or by arming, and the next press of that
> toggle starts the chain again at option 1 — it does not carry on where the chain stood.
> (Before 0.7.1 it did, so with a single-option chain every second press appeared to do
> nothing and with a longer one the next press opened the option *after* the page you had
> just left.)
>
> **RTN** from a shortcut-opened Toolbox tool returns **straight to the dashboard** — there
> is no menu trail to unwind (opened from ☰ ▸ Toolbox, RTN returns to that submenu as usual).

### 2.8 Where settings are stored

EdgeTX gives widgets no API to write their own options, so settings live in a file on the
SD card and overlay the (effectively empty) EdgeTX option list at runtime.

- **Per model (default):** `/WIDGETS/UltiDash/cfg/cfg_m_<model>.cfg`, keyed by the **EdgeTX
  model name**, read once when the model becomes active and held for the rest of the session.
  Two consequences worth knowing:
  - **Reorganising the model list is safe.** EdgeTX hands out its model files (`model7.yml`)
    by lowest free number, and rewriting the list — which EdgeTX Companion does whenever
    models are added or deleted — renumbers the survivors. Keying by name survives that;
    keying by the file number did not, and cost every model its settings.
  - **Two models with the same name share one config file.** EdgeTX has no stable per-model
    identifier, so this is yours to manage: a copied model needs its **own name** if it is
    to have its own configuration. Names from a template (`Rotorflight`, `Rotorflight
    Test`, …) are the case to watch.

  Rotorflight's *"set model name on TX"* renames the EdgeTX model to the connected craft,
  but only while it is connected — RF restores the stored name on disconnect, and the latch
  means a craft connecting never moves the config file **while UltiDash is running**. What the
  latch cannot cover is a rename that had **already happened** at the first load: boot the
  radio with the craft powered and the model is wearing the craft's name before UltiDash ever
  reads it. The lookup by name then misses — and used to create a second config under the
  craft name, so one machine owned two files and settings landed in whichever one that boot
  had picked.
  - **Since 0.7.1 the file is found by NAME and identified by MODEL FILE.** Every save stamps
    the config with the model file it belongs to (`ModelFile=model7`). When the lookup by name
    misses, UltiDash scans `cfg/` for the config carrying this model's stamp and uses **that
    one in place** — read *and* written for the rest of the session, not copied, since a copy
    would only postpone the split by one save. `menu ▸ Status` names the file in force (§3).
  - **The stamp is written from 0.7.1 onwards.** A config last saved by an earlier version
    carries none, so that model is protected from its **next save** on, not retroactively.
  - **If the file found by name carries another model's stamp** — two models sharing a name,
    or a rename caught mid-flight — **the name wins**. It is what you see on the radio and
    what every earlier session used; the contradiction is reported on the Status page rather
    than repaired behind your back.
- **One file per model, and no second level.** *Config file per craft*
  (`cfg_m_<model>_<craft>.cfg`) was **removed in 0.7.0**. Its `<craft>` half was the model
  name as it read at that moment, so it only ever split anything while Rotorflight was
  actively renaming the model — with *"set model name on TX"* off, both halves of the file
  name were identical and the option did nothing. **Upgrading loses nothing:** that mode
  always wrote the plain model file as well, with the same content, so your last saved
  configuration is in it. Old `cfg_m_*_*.cfg` files stay on the card unread and can be
  deleted.
- **Upgrading keeps your settings.** Versions before 0.7.0 keyed the file by the model
  number (`cfg_m_model7.cfg`); the first start after the upgrade reads that file and
  rewrites it under the model name. Nothing is deleted — the old file stays behind.
- **Renaming a model starts its UltiDash settings fresh.** The file is keyed by the name, so
  the renamed model finds no config of its own and comes up on the defaults. The old file is
  still there under the old name: rename it to `cfg_m_<new name>.cfg` on a PC and the
  settings are back. One trap goes with it — if a **pre-0.7.0** file for the same model slot
  is still on the card, the renamed model adopts *that* instead, i.e. the configuration as it
  stood before the upgrade rather than the defaults. Deleting the old `cfg_m_model<N>.cfg`
  files once after upgrading avoids it.
- **Two kinds of value migration run on the loaded file, in memory.** UltiDash's own schema
  migration (stamped as `ClrSchemeV`) reinterprets keys whose *meaning* changed between
  versions — the colour-scheme order in v1 is the example. Beside it, a **skin** may declare
  `M.migrate` and convert **its own** keys the same way (see `docs/SKINS.md` §7c); the host
  runs every installed skin's migration once per model, right after the file is read and
  before anything is drawn. Both are **read-time** conversions: nothing is written to the SD
  card for their sake, so an upgrade costs no extra write, and the converted form becomes
  permanent the next time you save something on that model.
- **The `cfg/` subfolder** keeps the widget root tidy. It ships with the widget, so nothing
  is created at runtime; UltiDash just uses it when present. Config files left in the widget
  **root** by older versions are moved into `cfg/` automatically on start (and adopted per
  model on first load), so upgrading loses nothing. If the folder is ever missing, UltiDash
  falls back to the old flat layout (files directly in `/WIDGETS/UltiDash/`) — settings are
  never at risk either way.
- Defaults come from the settings tables above; a missing file simply means defaults.
  A value that is corrupt or the wrong type in the file (hand-edited, damaged) falls
  back to its default instead of causing an error.
- **Only what you changed is stored.** The file holds a line for every setting whose value
  differs from its default, and nothing else beyond three bookkeeping stamps
  (`ClrSchemeV`, `ModelFile`, `SkinsSeen`). Put a setting back to its default and its line
  leaves the file on the next save. A file written in full by an earlier version **compacts
  page by page**: a save rewrites the settings of the page you were on and leaves every other
  line alone, so the redundant lines go as you visit the pages they belong to, and a full-size
  file may stay full-size for a long time. Nothing waits on that, because a line holding a
  default value and no line at all are the same state, and *Reset to defaults* clears the
  whole file in one step whenever you want it gone. A key that is **not** in the file means the
  default for that key, exactly as a missing file means the defaults for all of them — so
  *"never touched"* and *"set to the default"* are one and the same state, and *Reset to
  defaults* writes a file that is nothing but the stamps. This has a consequence worth
  knowing: if a later UltiDash version changes a default, that new default applies to every
  setting you never touched, because nothing is stored to hold the old value in place. It
  was always how colour overrides behaved (§2.3b); since 0.8.0 it is how every setting
  behaves.
- **Unknown keys are dropped on save:** a key the current version doesn't know (a typo,
  or one left behind by a different version) is removed the next time the file is
  written. Downgrading to an older UltiDash therefore loses the newer version's
  settings keys — re-check the settings after a downgrade.
- Settings are written back only when you actually change something on a page (no needless
  SD writes for a page you just looked at). If a write fails (card full, write-protected or
  removed), a **"Settings NOT saved (SD write failed)"** banner shows on the dashboard/stats
  view for ~10 s.
- **Orphaned files are harmless.** Deleting a model, or renaming it, leaves its `cfg_m_*.cfg`
  behind in `cfg/`, and rotated `debug_NN.log` files accumulate in `logs/`. UltiDash never
  auto-deletes them; they do no harm. Delete them from `/WIDGETS/UltiDash/cfg/` or `…/logs/`
  on a PC if you like — UltiDash recreates what it needs. The same goes for a stray
  `cfg_m_*.cfg.new`: saves are written there first and renamed into place only after a size
  check, so switching the radio off mid-save leaves that leftover beside an intact config —
  never a half-written config. Nothing ever reads a `.new` file and the next save overwrites
  it.

---

## 3. Display / views & navigation

The Dashboard instance has two automatic views (**flight** / **stats**) plus four
tap-to-open **detail pages**, the **battery-profile picker** and the **settings menu**
(all full-screen only).

### 3.1 Stats-view switching (`Stats page`)
- **armed** → always **flight view**
- **Never** or not armed yet **this connection** → always flight view
- **On disarmed** → stats once disarmed
- **On disconnected** → stats only when the link is lost
- In the **simulator** the views alternate every ~12 s (preview)

> **"Armed this connection":** stats only appears after the craft was **armed during the
> current connection**. The has-flown flag resets on every fresh connect, so a stats page
> from an earlier flight doesn't reappear on a new connection that never armed.
> **Manual dismiss (changed in 0.8.0):** the stats page carries an **X** in the top bar,
> left of the radio-battery pill; tapping it (full-screen) returns to the flight view, and
> it reappears with the next arm / reconnect cycle. Until 0.7.1 a tap **anywhere** did
> this, with nothing on the page saying so — which also meant any fumbled touch while you
> were reading the page threw it away. A tap that hits nothing now does nothing.

**Manual open (new in 0.8.0):** tapping the **status panel** (the left card with the
flight counter and total time — anywhere outside its status line, which opens the Status
log) opens the statistics page **on demand, disarmed only** — and it does so **whatever
*Stats page* says**: *Never* governs only the automatic route, a deliberate tap is a
second, manual one. Close it with the **X** as usual; the next arm retires a tap-open
like it retires a manual dismiss.

### 3.2 Flight view

The flight (and stats) view **layout depends on the selected skin** (§2.3s). The diagram
below is the **UltiDash** skin — the built-in look and the one this release carries; an
installed skin may arrange the same data differently. The detail pages, the settings menu,
the status bar and the safety overlays (setup hint, warning banners, critical-alert overlay)
are the same under every skin.

```
┌───────────────────────────────────────┐
│ ☰ Date/Time   [link bars]   Radio batt │  ← top bar
├─────────────┬──────────┬─────────────┤
│ STATUS      │ BATTERY  │  VALUES     │
│ (left)      │ (center) │  (right)    │
├─────────────┴──────────┴─────────────┤
│            Status bar                 │
└───────────────────────────────────────┘
```

**Top bar:** ☰ menu glyph (full-screen only) · clock (date+time or time-only) · **ELRS
link bars** centered (RQ / TQ / 1RSS / 2RSS, each color-by-zone with threshold ticks;
each group toggleable; quiet mode optional) · radio (TX) battery icon with % and voltage.

**Left – status panel:** model image (or timer) · flights + total flight time · governor
+ throttle · ESC/arming status line (colored; tap to open the status detail) ·
profile/rate/**battery-profile** (tap the battery-profile field — disarmed — to open the
profile picker, §3.5).

**Center – battery gauge** (see §4). Tap to open the battery detail.

**Right – values panel:** five configurable sensor slots (default: voltage · headspeed ·
current · ESC temp · BEC). Tap to open the **Telemetry** detail (§3.4).

**Bottom status bar:** `Model` · arm state · `TPWR` (toggleable) · `Skp`. With
arming-disable flags it shows "Arming Disabled: …" instead. With **no FC connected**
the arm-state slot shows a muted **"No FC connected"** instead of Disarmed (the craft
state is unknown without telemetry). While disconnected the UI also drops to a 2 Hz
refresh, so values updating slowly then is by design, not a hang.

### 3.3 Stats view

- **Top bar:** clock + radio battery only (the link bars are hidden — momentary link
  figures are misleading after disconnect).
- **Header:** the Rotorflight FC craft name (cached so it survives disconnect) · total
  flight time · flights.
- **Table** (Latest / Min / Max): cell/battery voltage · **Headspeed P1 / P2 / P3** ·
  current · ESC temp · BEC · **V sags** (voltage-sag counter).
- **Info line:** session flight time + mAh used (raw %).
- **Status bar:** TPWR+ · RQly- · Tmcu+ · Skp.

> **"Latest"** = live while disarmed/connected, frozen at the last value once disconnected.

**Headspeed per PID profile.** Governor headspeed differs per profile, so min/max are
tracked **per `PID#` profile** and shown as three fixed rows P1–P3. "Latest" only shows
on the row of the currently selected profile. (The `PID#` sensor freezes after a
disconnect, so fixed rows — not a switchable one — keep every profile visible.)

#### Min/Max integrity
- **Headspeed** is tracked only while the **governor is running** (no 0 from a stopped
  rotor), per profile. In governor modes **OFF / LIMIT** the `Gov` sensor never changes,
  so the widget reads the governor mode from the FC at connect and falls back to
  **armed + rotor spinning** (`Hspd > 100 rpm`; armed-only without an `Hspd` sensor).
  The same gate applies to the **current** min/max.
- The **minimum** is stricter than the maximum: it tracks only in the **steady**
  governor states (Active / Fallback / Bypass) and only after the run gate has been
  true for **~2 s**. Ramp states (a **Recovery** re-spool after a throttle hold,
  autorotation, bailout) therefore can't leave a misleading low "minimum" — typically
  seen as a few-hundred-rpm min in the profile you always spool up in. The **maximum**
  keeps the broad gate on purpose (an overspeed during an autorotation entry or bailout
  is exactly what a max should catch).
- **Voltages (`Vbat`/`Vcel`/`Vbec`)** are tracked **only while armed** and latched against
  implausible (≤ 1 V) readings, so the post-landing buffer decay (4.x → 0 V, e.g. a stray
  2.89 V) never pollutes Min, and "Latest" doesn't freeze at 0 V. The BEC value is held
  through a supply collapse (it would otherwise show the buffer rail).
- **ESC temp** ignores the spurious 0 the ESC reports before its temperature telemetry is
  up.
- **RQly / TPWR / MCU temp** use EdgeTX's `-`/`+` sensors, reset once the link is actually
  up and frozen while it's down.
- **Current** Min is naturally ~0 at idle — a real reading.
- **V sags** counts episodes where the (latched) cell voltage dipped to/below the **critical**
  threshold — including the short load sags the voltage alert's 0.5 s debounce ignores — with
  +0.05 V hysteresis so hovering around the threshold counts once. The *Latest* column shows
  the count, *Min* the deepest cell voltage seen (a main-power collapse is **not** counted).
  Zero-config; resolution is bounded by the 5 Hz pass and the telemetry rate — sub-200 ms
  spikes stay invisible.

**"Flight Time" (session timer):** counts while **armed AND the rotor spins** (read from
the `ARM` bit-0 and `Hspd > 100 rpm` sensors, independent of the RFTool state). Runs in
the background too; resets only on telemetry (re)connect. Distinct from header "Total
Flight Time / Flights" (cumulative, from the FC via MSP).

> **Fresh-connect side effects.** When a connection is first established, UltiDash resets the
> **session min/max of every telemetry sensor** once (so the detail-page `min .. max` chips
> and the stats extrema start clean). It also resets the **model timer** — but **only when
> *Display ▸ Top-left shows* is set to Timer** (i.e. the widget is actually displaying it);
> otherwise your model timer is left alone.

### 3.4 Detail pages (tap a panel, full-screen)

Tap-zones are gated by *Display → Tap zones for detail pages*. **Close with the X in the
top-right corner**, **RTN**, or (optionally) by arming. A configured **Shortcut** switch (§2.7c) opens/closes a
chosen page hands-free — independently of the tap zones (so it works even with them off); it
closes only the page it opened, and *Close detail pages on arm* still applies. The whole
telemetry/alert engine keeps running while a detail page is open — you can watch the ELRS
detail in flight without losing callouts.

- **Telemetry** (tap the right value panel): a **3-column grid of up to 12** freely chosen
  sensors (§2.3a — *Tele Details*). Off slots are skipped. This page shows **raw sensor
  data** — the live EdgeTX reading, not the dashboard's latched/filtered values. Each tile
  shows the label, the big value **+ its unit**, and a dim **`min .. max` chip** — the
  EdgeTX session low/high read from the sensor's **`-`/`+` variants** (so every sensor
  gets a low/high, not just the few the stats page tracks). The tile lays the label left
  of the value on the wide TX16S, above it on the narrow TX15. *(Reading the per-sensor
  min/max is gated to while this page is open, to keep the dashboard's sensor-lookup
  budget light.)*
- **ELRS link** (tap the top-bar bars): seven labelled bars — **RQ, TQ, 1RSS, 2RSS, TRSS,
  SNR, TPWR** — with reactive threshold ticks and values; the rate/mode header; footer with
  the **antenna pair**, the transmitter module's antenna mode and the session RQ-min. **TRSS**
  is the **downlink RSSI** (measured at the TX
  module) — it separates downlink issues (telemetry dropouts, module antenna, too-low
  telemetry ratio) from uplink/control ones; its bar uses the same rate floor as the uplink
  RSSI. The **SNR** value shows uplink / downlink combined (e.g. "8 / 5dB") while the bar
  tracks the uplink; in **FLRC and FSK/Kernel** modes the radio chip reports SNR as a
  constant 0, so the value and bar read
  "-". **Diversity** is reported only once the data proves a second antenna (2RSS live, or the
  antenna field actually switching) and latched for the session. Since 0.8.0 the footer draws
  it as **two antenna symbols** instead of the words "Diversity: yes/no" beside "Ant 1": a
  **filled head on a mast** means that antenna is there, the one currently carrying the link
  (the `ANT` sensor) is **green and drawn radiating**, and a **hollow, dimmed** second antenna
  means the receiver has only one. *(On a Gemini/GemX dual-band receiver 1RSS is the 900 MHz path, 2RSS the 2.4 GHz path —
  two filled antennas are correct there.)* Beside them the footer names the **antenna mode of
  the ExpressLRS transmitter module** — *Gemini*, *Ant 1*, *Ant 2*, *Switch* — read from the
  module itself by the once-per-connect configuration scan (§ *menu ▸ ELRS Status*). It is the
  **transmitter's** setting, while the antennas beside it are the **receiver's**; a module that
  does not have the setting at all (any single-radio 2.4 GHz module never registers the field)
  shows nothing there rather than a permanent dash, which would read as a failed read.
  TPWR is inverted (high power = working hard)
  relative to *Thresholds ▸ TX power limit* (shows a hint until that is set).
- **Status & events** (tap the ESC/status line): a bordered **status card** — arm state /
  governor / throttle, the ESC status and the arming status including the **full
  arming-disable reason list** — above a **scrollable, timestamped ESC event log** (every
  ESC status change, RESTART, and arm/disarm — newest first, color by severity; ▲/▼
  paging with an `N-M/30` position readout). A small footer shows dev metrics (Lua heap,
  free heap, UI loop Hz, pass ms). The menu's **Status** entry shows a grouped
  configuration overview (thresholds & their source, alert switches incl. repeat
  summary and ESC-load state, volume setup), with a **Version** row at the top naming the
  build the card carries. A development build appends a short commit there — the widget
  cannot know it at runtime, so the build tooling writes it onto the card as an extra
  `WIDGETS/UltiDash/build.lua`; a `+` after it means the build came from an uncommitted
  working tree. **A release card has no such file** and the row shows the version alone.
  Under it, a **Craft target** row names the firmware this instance was placed for (§2.1) —
  *Rotorflight*, and with a connected craft on which no Rotorflight sensor was recognised at
  all, *"(no Rotorflight sensors found)"* beside it.
  Then a **Config file** row names the `cfg_m_*.cfg` this radio is actually reading and
  writing — the question §2.8 leaves open once a connected craft can rename the model. Two
  markers may follow the file name: **(found)** means the lookup by name missed and this file
  was located by its model-file stamp, i.e. the model is wearing a craft name right now;
  **(! model7)** means the file found by name says it belongs to another model.
  An **MSP provider** row names **who is answering the flight controller for this radio**
  (§8). *RFTool* is the normal case. *RFTool  (RFSuite also seen)* means both config suites
  are loaded — UltiDash keeps to RFTool and says so, because both would master the radio's
  single CRSF transmit slot. *RFSuite service v1 (active)* is the second provider serving;
  **(idle)** is the same surface with nobody driving it, which is the one case where the FC
  rows below stay empty and nothing else looks wrong. *RFSuite (no API)* is an RFSuite
  install that publishes no consumer surface — for UltiDash that is the same as none.
  *RFSuite service (no back end)* is the opposite and is **UltiDash's own fault**: the
  service is there and `WIDGETS/UltiDash/ultidashRfs.lua` did not reach the card — re-deploy.
  The row exists so that "why is there no FC data" has an answer on screen.
  A **Flight controller** section below that carries what the FC itself is configured for,
  read over MSP at connect and never shown on the dashboard (it is configuration — it cannot
  change while you fly): **Meters V / I** (the voltage and current meter sources; a current
  meter of *None* is one of the conditions under which a SmartFuel percentage cannot move),
  **FC fuel warn (info)** — the flight controller's own consumption warning, shown **to
  compare** with your own fuel thresholds and never used to drive a callout — **LVC / cell
  max**, the **governor** mode with its spool-up / start-up / handover figures and its
  throttle block, **Telemetry** (the craft's CRSF mode and how many of the 40 slots it fills),
  **SmartFuel** and **ESC protocol**. A row reads `-` when the flight controller has not been
  asked yet, or when the value does not exist on that firmware version.
  **Adjust table** names the source the two Toolbox adjust tools are **actually** using:
  `manual`, or `FC - N slots` once the craft's own adjustment table has been read
  (*Settings ▸ Toolbox ▸ Adj table from*). The option can say FC while a failed or
  not-yet-run read leaves the manual table in force — this row is where that state is
  visible, since the tools themselves fall back silently rather than showing an empty grid.
- **Battery** (tap the gauge): a **cell-voltage scale** with the active crit/low/full
  thresholds marked (and whether they come from FC or manual), then the battery in the
  dashboard segment look with % and used mAh inside it, and a Batt / Cell-min / Reserve
  line. With **ESC load monitoring** on (§2.5a), the free gap between the battery
  graphic's segments and its frame carries the **ESC-load ring** (fills left → right
  towards the cap, warn/critical colours; the cap-side gap is the **overload zone**,
  100…150 % — same scale as the dashboard gauge, §2.5a).

### 3.5 Battery-profile picker (tap the B-Profile field — **disarmed only**)

Tapping the **B-Profile** field in the status panel opens a picker of the **6 Rotorflight
battery profiles**, each shown with its capacity (`1800 mAh`, or `undefined` when the
profile has none); the active one is marked. Selecting one **switches the active battery
profile on the FC**.

> ⚠️ **This is the only place UltiDash *writes* to the flight controller.** It is therefore
> gated to **disarmed** (the picker won't open armed, and the FC also rejects config writes
> while armed). The switch is **MSP 176**, the same call the RFTool's own battery page uses,
> and persists **without an FC reboot** (an EEPROM write with the reboot flag off). It goes
> through whichever MSP provider is serving (§8) — `mspBatteryProfile.write` +
> `settingsSaved(true, false)` under RFTool, MSP 176 followed by MSP 250 under the RFSuite
> service, which is the same two messages written out. The picker re-reads the FC's current profile
> fresh on open, so it reflects external profile switches too. Everything else in UltiDash
> stays **read/announce-only**.

### 3.6 Sensor check (menu ▸ Sensor check)

A read-only page that evaluates the telemetry sensors UltiDash relies on and explains what a
gap breaks. Each row: a **colored status badge** — green **OK** (present, live data), gray
**--** (discovered but no data right now — normal with the FC off), red/yellow **MISS**
(never discovered), red/yellow **N/S** (*not sent* — see below) — the sensor's friendly name,
and the sensor code at the right edge; a legend at the bottom explains the states. **While the FC is connected, the right column also
shows each sensor's live value** (updated 1 Hz), making the page a quick diagnostic view. It
resolves sensors by their Rotorflight sensor ID (immune to duplicates/renames), with a name
fallback for the ELRS / decoder sensors that carry no ID. The scan runs only while the page
is open (≤ 1 Hz) — no cost in normal use, no MSP.

- **Required** (RFTool running · RF2 telemetry discovered · ARM · Vbat · Bat% · Cel# · Vcel ·
  Hspd · Gov · RQly): a MISS here is **red** and counts in the summary ("N required sensor(s)
  missing"), with a one-line note on what it breaks. If the RF2 custom telemetry was never
  discovered, the hint points you to *Discover new sensors* (with the FC powered) — and if that
  finds nothing, to §6.2.
- **Active features**: only the sensors used by whatever you have enabled (current source, BEC
  alert, RSSI, skipped-packet alert, temperature alert, ESC / arming decoders, profile line,
  uplink / TX power). A MISS here is a **yellow** advisory (except the current source, which is
  red when the ESC-load monitor needs it).
- **Value slots**: your configured *Tele Main / Tele Details* picks — catches a typo'd raw
  sensor or an orphaned slot.

When the FC is disconnected the page adds a "FC not connected — showing discovered state only"
line and shows discovered-but-dataless sensors as **--** (not an error). In its place, a
connected craft on which **no** Rotorflight sensor was recognised at all gets the craft-target
cross-check line — *"No Rotorflight sensors found"* — see §2.1 for what it does and does not
claim.

**N/S — the flight controller does not send this row.** A sensor can exist on the radio and
still never be transmitted: your craft's `telemetry_sensors` names at most 40 rows, and a
sensor that was discovered once and later dropped from that list keeps its place in the model
and reads a constant **0**. EdgeTX serves that 0 like any other reading, so such a row used to
show a green *OK 0.0* — worst exactly where 0 is also a legitimate value (ESC faults, arming
flags, governor state). UltiDash now reads the flight controller's own slot list and marks
those rows **N/S**; a *required* one counts in the summary line, which then reads "N required
sensor(s) missing or not sent". The fix is on the flight controller — put the row back into
`telemetry_sensors` — after which the radio may need *Discover new sensors* again, and §6.2
if that turns up nothing.

### 3.6a ELRS Status (menu ▸ ELRS Status) — **experimental**

A read-only page showing what the **ExpressLRS transmitter module** is configured to, and
holding it against what the **flight controller** was told the link carries. No telemetry
sensor reports any of this: it is read out of the module itself over CRSF, the same
parameter conversation the stock `elrs.lua` tool script has.

| Section | Rows |
|---------|------|
| **TX module** | module name, firmware version, the build **commit**, and the state of the last read |
| **Link configuration** | RF band (dual-band modules), packet rate, **link rate**, telemetry ratio, antenna mode, switch mode, link mode, model match, max power, dynamic power |
| **Flight controller expects** | the FC's `crsf_telemetry_link_rate` / `_link_ratio`, its telemetry mode and slot count, and a **rate/ratio match** verdict |

**Why the last section exists.** The flight controller's rate and ratio are a *declaration*,
not a measurement — Rotorflight turns them into the token bucket that paces every telemetry
frame it emits, and nothing checks them against the real link. Declared faster than the link
is (the default 250 Hz / 1:8 against, say, 150 Hz / 1:32) and the FC schedules several times
what the link drains: backlog, dropped frames, values that are stale rather than absent.
Declared slower and the bandwidth is simply unused. Both feel like *"telemetry is laggy"* and
neither raises an error. The verdict row reads **ok**, **MISMATCH** or **TELEM OFF**, and
stays `-` unless both sides are known. Since 0.8.0 the same verdict also raises the
**config warning overlay** on the dashboard (§2.6a) — the page is where you look it up, the
overlay is what tells you to.

**What is actually compared — and it is not the two numbers.** The flight controller only
ever sees the *quotient*: it refills a bucket at `rate ÷ ratio` telemetry slots per second
and spends slots per frame. ExpressLRS sizes its own telemetry bandwidth the same way. So a
module on **500 Hz 1:16** against an FC told **250 Hz / 1:8** is **correct** — same 31.25
slots per second — and comparing the pairs for equality (which is what this page did before
0.8.0) called it a mismatch. The comparison is the slot rate.

**The link rate row, and why a packet rate can lie.** The rate the module *displays* is not
always the rate the link *runs at*, and the FC has to be told the latter. The **DVDA** rates
repeat every packet two to four times and keep the fast send interval:

| Module shows | Packets/s on the link |
|---|---|
| `F500` / `F1000` | 500 / 1000 |
| `D500` | **1000** |
| `D250` | **1000** |
| `D50Hz` (900 MHz) | **200** |
| everything else (`150Hz`, `333Hz Full`, …) | the number in the name |

**The firmware row, and why it used to show a bare hash.** ExpressLRS registers its version
as `{version_domain, CRSF_INFO}, commit` — so the field's **name** carries the version and the
frequency domain (`4.1.0 ISM2G4`, at most 26 characters) and its **value** is only the short
build commit. Until 0.8.0 UltiDash read the value, which is why *Firmware* showed something
like `4eafzt` where a version belongs. They are now two rows: *Firmware* is the version,
*Commit* the hash, kept because it is what a bug report needs.

The *Link rate* row shows the value the verdict actually used, so a `D500` module reading
`1000 Hz` there is right, not a display bug. A rate name UltiDash does not know reads `-`,
and then **no verdict is given at all** — an invented rate would send you off to change a
setting that was correct.

**When it reads.** Once per link **connect**, **disarmed only** — never on opening the page,
never on a timer. Each request the read makes replaces one RC channel frame on the way to the
module, so the scan is paced at one request per background pass, skips the remainder of any
field it will not keep after the first chunk named it, and jumps straight to the last field
(the firmware version) once everything else is in — a few seconds for a typical module — and
is aborted if the craft arms, keeping whatever it already has. The **RF band** row appears
only when the module registers the parameter (dual-band LR1121 hardware); other absent values
read `-`. On ExpressLRS 4.x the firmware manages the antenna mode itself, so the value shown
is the *effective* one, not necessarily the one you picked.

Two limits, both deliberate:

- **NATIVE CRSF telemetry makes no claim at all.** In `crsf_telemetry_mode = NATIVE` the
  firmware sends a fixed legacy set and ignores `telemetry_sensors` completely, so there is
  nothing to compare a row against and every row keeps its old badge. The *Telemetry* row on
  the Status page names the mode.
- **The list is read once per connect.** Change a telemetry setting without rebooting the
  flight controller and the page shows the previous list until the next connect.

---

## 4. Central battery display (ePowerbar model)

### Fuel calculation (reserve-adjusted)
```
raw   = Bat% sensor
fuel  = (raw − Reserve) / (100 − Reserve) × 100
```
- **0 % displayed = reserve reached** (land safely); with `Reserve = 0` the raw value is used.

### Discrete colors
| State | Color |
|---------|-------|
| `fuel ≤ critical` (critical = 0 when Reserve > 0) | **Red** |
| `fuel ≤ critical + 20` | **Yellow** |
| otherwise | **Green** |
| pack not full at startup | **Amber** |
| during the startup cell-check | **Grey** |

All five fill colors are adjustable per scheme under *Settings ▸ Colors ▸ Battery* (§2.3b);
the defaults above are unchanged.

### Overlays & look
- top: cell count (e.g. "6S") · middle: large % (`--` during the cell-check) · bottom: mAh.
- Coarse, chunky segments; empty area light grey (`0xC8C8C8`); plain-black overlay text.

### Startup cell-check
On first voltage (power-on/connect): grey progress bar for *Cell-check delay* seconds,
then compare cell vs the FC full-cell voltage — full → green, not full → amber + `batlow`
voice + spoken total voltage.

---

## 5. Voice callouts & vibration

All outputs are UltiDash's own WAVs in `/SOUNDS/en/ultidash/` or `/SOUNDS/de/ultidash/`
(*Voice language*; spoken numbers/units come from the EdgeTX voice pack). English ships with
the widget, **German is a separate download** — see §8. Every alert has
its own page (§2.6a) with Active / Repeat / Vibrate / Escalation; `Mute = All` overrides
everything.

### 5.1 Telemetry-driven callouts

The *vib* column shows the **default** — vibration is per-alert configurable now.

| # | Trigger | Condition | Output | Active key | Background |
|---|----------|-----------|---------|--------|-----------|
| 1 | **Startup cell-check** | after the delay, if cell < FC full-cell | `batlow` + voltage | `SndCellChk` | yes |
| 2 | **Fuel callout** | connected + armed, by fuel level | `battry`/`batlow`/`batcrt` + % **or voltage** (step callouts follow *Fuel callout says*, §2.4) (+vib) | `SndFuel` | yes |
| 3 | **Voltage alert** | connected + armed, cell ≤ FC warn/min | `batlow`/`batcrt` + voltage (+vib) | `SndVolt` | yes |
| 4 | **Armed / disarm** | arm state change | `armed` / `disarm` | `SndArm` | yes |
| 4a | **Gov state** (§2.7-gov) | armed, on a state change held ~0.3 s (opt-in master, per-state toggles) | `gs_*` (spoken state name) | `GovVoice` | yes |
| 5 | **Telemetry lost / ok** | armed-only loss; "ok" only after an armed loss | `telem_lost` (+vib) / `telem_ok` | `SndTelem` | yes |
| 6 | **Low link quality** | armed; RQly ≤ Link warn/crit | `link_warn`/`link_crit` + % | `SndLink` | yes |
| 7 | **Low RSSI / signal** | armed; best-antenna headroom ≤ RSSI warn/crit, held *RSSI hold* s | `rssi_warn`/`rssi_crit` + % | `SndRssi` | yes |
| 8 | **Main power lost** | armed + connected; `Vbat` < power-warn (incl. collapse to ~0) | `pwr_backup` + **BEC voltage** · restored: `pwr_ok` | `PwrWarn` | yes |
| 9 | **BEC voltage** | armed; live BEC ≥ *BEC warn/crit %* below the flight's reference | `bec_low`/`bec_crit` + voltage (+vib) | `SndBec` | yes |
| 10 | **ESC load** | armed + monitoring on (§2.5a); load ≥ warn/crit % for the hold time | `escl_warn`/`escl_crit` + % (+vib) | `EscLoad` | yes |
| 10a | **Temperature** | armed; live `Tesc`/`Tmcu` ≥ its warn/crit °C (§2.5, 0 = off) | `esct_warn`/`esct_crit` · `mcut_warn`/`mcut_crit` + °C (+vib) | `SndTemp` | yes |
| 11 | **Skipped packets** | armed; `*Skp` ≥ limit | `skp_high` | `SkpWarn` | yes |

Notes:
- **Repeat engine (per alert, §2.6a):** an alert with *Repeat = on* re-announces on its
  own interval while the condition holds (count-limited or until cleared). Fuel and
  Voltage ship with the historical continuous cadence (6 s, until cleared); Main power
  lost (until cleared) and Telemetry (3×) also default to repeating; everything else
  defaults to once per episode (re-armed on recovery; a warn→crit escalation announces
  once more). The **Voltage** repeat covers the **low band too** — a sustained dip below
  the low threshold keeps calling out (switching between "battery low" and "battery
  critical" as the level moves), not just the critical level.
- **Spoken voltage (rows 1 & 3)** follows *Battery → Announce voltage as* — total pack
  voltage (default) or per-cell voltage (§2.5); the latched, collapse-filtered value.
- **Fuel step callouts (row 2)** speak the percent by default, but *Battery → Fuel callout
  says* (§2.4) can switch them to the pack voltage, the per-cell voltage, or the percent
  plus one of the two. The %-interval triggering is unchanged; the critical nag keeps the
  percent.
- **Escalation volume:** while any alert with *Escalation volume = on* is active, the
  GVAR master volume (§5.4) is raised to *Escalation volume (%)* — the repeats get
  louder; back to *Normal volume (%)* once cleared. The boost acts on the **repeats**:
  the first announcement is already playing by the time the volume is raised (that is
  true for every alert). For **Telemetry** this means the escalation needs *Repeat = on*.
  On a link loss **in flight** the boost holds even though the FC is disconnected, and it
  ends with the last repeat (*Repeat count*; 0 = until reconnect) — after a crash the
  volume therefore returns to the pot / *Normal volume (%)* by itself. A disarmed
  disconnect (landing, switching the heli off) never escalates — the pot rules
  immediately.
- **Voltage alert** ignores ≤ 1 V/cell readings — a collapsed/lost supply (~0 V) never
  produces a misleading "battery critical 0 V"; that case is the main-power-loss warning.
- **Main power lost** distinguishes a buffer-kick (telemetry still flowing → reported)
  from a plain dropout (handled as telemetry-lost). The callout speaks the **live BEC
  voltage** with each repeat — an audible countdown of the buffer. If the main pack comes
  back while still armed (the buffer bridged the gap), **`pwr_ok`** announces the
  recovery. While the mode is active the status line shows **MAIN POWER LOST** (highest
  priority, red), the voltage slot flips to an explicit **"Buffer"** readout — the live
  BEC/buffer voltage in the warn color instead of the old bare `--` — the fuel gauge %
  reads `--`, and the fuel/voltage callouts are suppressed — only main-power-lost and
  BEC speak.
- **No recovery hysteresis (deliberate):** an alert clears the moment its value crosses
  back over the threshold — a value hovering right at a threshold can therefore announce
  once per crossing. The per-alert debounce (the condition must *hold* briefly) filters
  spikes, and with *Repeat = on* the periodic re-announce makes the hovering audible as
  a steady cadence rather than chatter.
- ⚠️ EdgeTX may have its **own** "telemetry lost" callout → it can double up; disable the
  EdgeTX trigger if so.

### 5.2 Switch announcements
See §2.7 — motor / rescue / governor (on-off) and profile (1-3), read read-only from a
configurable physical or logical switch.

### 5.3 Vibration
Per alert: each alert page's **Vibrate** switch (§2.6a). Defaults reproduce the old
"vibrate on critical" set (fuel, voltage, telemetry, BEC, ESC load, temperature and main power lost). `Mute = All` also
silences vibration.

### 5.4 Volume (two worlds)

**Callout volume (WAV mix level).** *Callout volume* (1–5) plays UltiDash's callouts at a
fixed level regardless of the radio setting; *System* (default) follows the radio.
*Widget volume applies = Only connected* limits the override to when telemetry is up.
This is the per-WAV level Lua can pass to `playFile` — it cannot change the radio's
master volume.

**Master volume via GVAR (optional — needs a one-time model setup on the radio).** To
control the actual **radio master volume**, UltiDash writes a volume value into a
dedicated GVAR; a model-side **Special Function** applies it. The SF's Volume source
can't take a GVAR directly, so it is bridged through an Input. Wire it up once per model
(numbers are examples — use whatever is free):

1. **Widget:** *Volume ▸ Master volume via GVAR* = **GV9** — a GVAR used for **nothing
   else** on this model.
2. **Inputs:** add an input, e.g. `I15 "Vol"`, **Source = GV9** (weight 100).
3. **Logical switch:** `L10: a > x` with **a = GV9, x = −1024** — true while UltiDash is
   driving the volume.
4. **Special Function:** `SF: switch L10 → Volume = I15 (Vol)`.

UltiDash writes **−1024 as the "off" sentinel** whenever the override is inactive
(feature off, disconnected) → `L10` goes false → the SF releases and the radio's volume
pot rules again. While connected, UltiDash drives the master volume to **Normal
volume (%)** — and to **Escalation volume (%)** while an escalating alert is active
(§5.1); the override is kept up to date **also while another screen is active**. Without
the GVAR setup the two sliders do nothing and callouts simply follow the radio volume.

> ⚠️ **Removing the widget** (deleting it from the screen / the model) does not release
> the GVAR — the last written value stays and the model's *Volume* SF keeps applying it.
> When you retire UltiDash from a model, set the GVAR to −1024 once (or remove the
> Special Function / logical switch).

---

## 6. Required telemetry sensors

Hard-wired Rotorflight sensor names (no configurable sources):

| Sensor | Use |
|--------|-----------|
| `Vbat` / `Vbat-` / `Vbat+` | Total voltage; drives the main-power-loss warning |
| `Vcel` / `Cel#` | Cell voltage + cell count |
| `Curr` | Current |
| `Capa` / `Bat%` | Used mAh / fuel level |
| `Vbec` | BEC voltage |
| `Tesc` / `Tmcu+` | ESC / MCU temperature (display uses `Tmcu+` = session max; the Temperature alert reads the **live** `Tesc` / `Tmcu`) |
| `Hspd` | Headspeed (+ flight-time gate) |
| `Gov` | Governor state |
| `ARM` / `ARMD` | Arming flags (bit 0 = armed) / arming-disable flags |
| `PID#` / `RTE#` / `BAT#` | PID profile (drives per-profile rpm stats) / rate / battery profile |
| `Thr`, `Esc#`, `EscF` | Throttle, ESC signature + status flags (eStatus) |
| `RFMD` | ELRS rate/mode → readable rate + RSSI sensitivity floor |
| `RQly` / `TQly` | Down/uplink link quality |
| `1RSS` / `2RSS` / `ANT` | ELRS RSSI per antenna / active antenna (diversity) |
| `RSNR` | ELRS uplink SNR (ELRS detail) |
| `TRSS` / `TSNR` | ELRS **downlink** RSSI / SNR, measured at the TX module — the ELRS detail page's TRSS bar and the combined `uplink / downlink` SNR readout (§3.4). Nothing else reads them: without `TRSS` that bar reads `-`, without `TSNR` the SNR row shows the uplink alone |
| `TPWR` | TX power |
| `*Skp` | Skipped/undecoded packet counter (label starts with `*`) |

> Min/max are taken from the EdgeTX `-`/`+` variants where used; widget-tracked otherwise
> (see §3.3). Sensor *IDs* differ per radio — sensors are referenced by name only.

### 6.1 Duplicate / empty default sensors

EdgeTX auto-discovers telemetry sensors from the RX link. With Rotorflight this commonly
creates **default sensors that duplicate Rotorflight's own names but carry no data** — on
the radio's *Telemetry* page they show `—`. Typical ones seen on RadioMaster radios:
`RxBt`, `Curr`, `Capa`, `Bat%` (other RX-default names possible).

**This rarely bites UltiDash anymore.** UltiDash resolves its known sensors by their
Rotorflight **sensor ID**, not by name (a throttled session scan maps the curated names to
verified telemetry indices), so an empty same-name duplicate no longer *shadows* the real
Current, fuel gauge, cell voltage, headspeed, etc. It can still matter for a **raw sensor
you pick by name** in a value slot (a name resolves to only one match) and for EdgeTX's own
telemetry displays.

**Tidy-up (optional, per model):** open the model's *Telemetry* page, **delete every sensor
that shows `—`/no value**, and turn **"Discover new sensors" off** so they aren't recreated.
The in-widget **Sensor check** page (menu) lists the sensors UltiDash needs and flags
anything missing or data-less, so you can see at a glance whether a clean-up is worthwhile.

### 6.2 *Discover new sensors* finds nothing — discovery is off, or the list is full

EdgeTX creates a telemetry sensor only while *Discover new sensors* is **on**, and a model's
list is capped at **60 sensors** on the radios UltiDash targets. When that cap is reached the
radio turns the switch **off by itself and says nothing about it** — the *telemetry full*
warning EdgeTX carries is compiled for the monochrome radios only. From the outside the two
causes are therefore indistinguishable: discovery was off, or discovery was on and the list
was full.

The consequence is the one that bites during setup: **adding rows to the craft's
`telemetry_sensors` and running *Discover new sensors* again can produce nothing at all** — no
new entry, no error — while the flight controller demonstrably transmits them and the **Sensor
check** page (§3.6) keeps calling them **MISS**. A Rotorflight craft (up to 40 rows) plus the
ELRS link sensors plus the receiver's own empty defaults (§6.1) sits close to the cap, so this
is the normal case rather than an exotic one.

**The remedy is to clear the page and let it rebuild:** delete **every** sensor on the model's
*Telemetry* page, switch *Discover new sensors* on, power the flight controller, and let the
whole list be discovered in one pass.

**What a rebuild costs.** Hand edits on that page go with it — a renamed sensor, a changed
precision or ratio, a *Logs* flag — and EdgeTX's own telemetry screens address sensors by
their slot, so those are worth a look afterwards. UltiDash itself is indifferent to the new
order: it resolves its known sensors by Rotorflight **sensor ID** (§6.1), and a value slot you
filled with a raw sensor **by name** keeps matching the same name.

---

## 7. ESC status decoder (eStatus)

`ultidashEsc.lua` translates `EscF` status codes into plain text depending on the `Esc#`
signature. Supported vendors:

| Signature | Vendor |
|----------|-----------|
| `0xA5` | OpenYGE / YGE |
| `0x53` | Scorpion / Tribunus |
| `0xFD` | HobbyWing Platinum/HW5 (this is what the CLI's `HOBBYWINGV5` selects — **not** `HW4`) |
| `0x73` | FLYROTOR |
| `0xD0` · `0xDD` · `0xA6` | OMP / OFW · ZTW · XDFly — **one protocol** since firmware 4.6.0 (same frame, different sync byte), so one decoder; ZTW contributes three extra throttle bits |
| `0xA0` | APD (Advanced Power Drives) |
| `0xC0` | Graupner |
| `0x4B` | Kontronik |
| `0xC8` | BLHeli_32 |
| `0xFF` | "RESTART ESC" (special case) |
| else | generic status code |

**Three families send no status word at all** — `HW4` (`0x9B`), `BLHeli_32` (`0xC8`) and
Castle (`0xCC`): their telemetry frames have no such field, so `EscF` stays `0` for the whole
flight and a decoder for them cannot exist. What they report is therefore always "OK".

**Everything above is decoded from the bit layouts the flight-controller firmware documents
in `sensors/esc_sensor.c`, and proven against synthetic status words** in 44 cases.
What that does **not** prove is the layouts
themselves: no helicopter here runs a Kontronik, an APD, a Graupner, a ZTW or an XDFly, so
those five decoders have never seen a real ESC.

> **Fixed in 0.8.0 — a Scorpion throttle error read as "Scorpion ESC OK".** Bit 7 of the
> Tribunus error word (throttle error) had no branch, so a real fault was reported as health.
> Also new: the four OpenYGE braking states are named instead of showing a raw `Code x09`.

Severity (text color): **Trace** (grey) · **Info** (theme) · **Warn** (yellow) · **Error** (red).
The worst message is held until the next (re)connect; every status change is also logged
to the Status detail's event log.

### Status line – priority (topmost matching rule wins)
| State | Display | Color |
|---------|---------|-------|
| main power lost (buffer takeover, §5.1) | `MAIN POWER LOST` | Red |
| disarmed **and** arming-disable flags active | reasons, e.g. `* NOGYRO THROTTLE` | Yellow |
| ESC reports restart (`0xFF`) | `RESTART ESC` | Red |
| ESC fault (`Esc#`/`EscF`) | plain text, e.g. `ESC Over Temp` | Yellow/Red by severity |
| ESC connected, no fault | e.g. `BLHeli_32 ESC OK` | Theme |
| connected, no ESC sensors, disarmed | `Ready` | Grey |
| connected, no ESC sensors, armed | `Armed - OK` | Grey |
| no telemetry | `No telemetry` | Grey |

### Governor state (`Gov` sensor)
| Code | Display | Code | Display |
|------|---------|------|---------|
| 0 | Throttle off | 5 | Throttle Hold |
| 1 | Throttle Idle | 6 | Gov. Fallback |
| 2 | Spooling up | 7 | Autorotation |
| 3 | Recovery | 8 | Bailing Out |
| 4 | Gov. Active | 9 | Gov. Bypass |
| unknown / none | Gov. Disabled / `-` | | |

- Labels follow **Rotorflight 2.3** terminology; RF 2.2 sends the same numbers.
- **Bypass (9)** = the GOVBYPASS box is active and the rotor runs on the bypass throttle
  curve (typical for nitro / manual spool-up) — the governor is deliberately bypassed, not off.
- In governor modes **OFF** and **LIMIT** the firmware never updates the state (the sensor
  stays a constant `0`). UltiDash reads the governor mode from the FC at connect
  (`mspGovernorConfig`): in those modes the governor slot shows **Gov. Off / Gov. Limit**
  instead of the misleading *Throttle off*, and the run min/max tracking (headspeed /
  current) falls back to **armed + rotor spinning** instead of the governor state. With no
  FC config available (old RFTool, read failed) the strict governor-state gating remains.

### Throttle
| State | Display |
|---------|---------|
| no telemetry | `**` |
| disarmed | `Safe` |
| armed (with `Thr`) | e.g. `47%` |
| armed, no `Thr` | `--` |

---

## 8. Dependencies & behaviour

- **No external libraries** – UltiDash loads only its own files (no `eLib`/`lib_common`).
- **An MSP provider** must be present → connection state and MSP data. If none is, the state
  stays "disconnected" and every FC-read row shows `-`. Two are supported and **menu ▸ Status
  ▸ MSP provider** names the one in force (§3):
  - **RFTool** (`rf2` global) — the shipping path, and the one the radio has proven.
  - **RFSuite for EdgeTX** *(0.8.0, experimental)* — used only when its **MSP service**
    (`rfsuite.msp`, consumer contract v1) is published **and RFTool is not there**. It fills
    the same rows from the same MSP commands, and it is only ever *active* while something
    on the radio is driving that suite's link; a published-but-undriven service reads
    *(idle)* and UltiDash asks it nothing. An RFSuite install without the service surface
    counts as no provider at all. **Untested against a flight controller** — treat it as
    experimental, and keep RFTool installed if you want the proven path.
  - **When both are loaded UltiDash uses RFTool**, by decision rather than by accident: the
    radio has exactly one CRSF transmit slot and two MSP clients pushing into it lose each
    other's replies. The Status row says the other one was seen.
  **MSP is only read on connect/disarm, and the
  only MSP *write* is the battery-profile switch (§3.5), disarmed — never during armed
  flight.** The FC-read values (battery config / capacity / cell count, FC thresholds,
  governor mode) **survive a mid-flight telemetry blip**: they are cleared only on a
  disarmed disconnect, and while the ARM sensor still reports armed no MSP re-read fires —
  the pending re-read runs after the disarm.
- **Performance:** the telemetry/alert/publish pass is throttled to 5 Hz (idle-throttled
  to 2 Hz while disconnected); touch is handled every cycle. The Status detail footer
  shows the live UI loop rate as a load indicator.
- **Sounds** in `/SOUNDS/en/ultidash/` and `/SOUNDS/de/ultidash/` (own subfolders,
  selected by *Voice language*). **English is in the main download; German is the separate
  `-voice-de` addon zip** — the same catalogue, recorded in German, and needed only if you
  switch the setting. A missing WAV is not an error in EdgeTX: the callout is simply silent.
  All shipped, in both languages:
  - Battery: `batcrt`, `batlow`, `battry` · Arm: `armed`, `disarm`
  - Link/telemetry: `telem_lost`, `telem_ok`, `link_warn`, `link_crit`
  - Signal/RSSI: `rssi_warn`, `rssi_crit` · Packets: `skp_high`
  - Power: `pwr_backup`, `pwr_ok` · BEC: `bec_low`, `bec_crit` · ESC load: `escl_warn`, `escl_crit`
  - Temperature: `esct_warn`, `esct_crit`, `mcut_warn`, `mcut_crit`
  - Switches: `motor_on`/`motor_off`, `rescue_on`/`rescue_off`, `gov_on`/`gov_off`, `profile`
  - Gov states (§2.7-gov): `gs_thoff`, `gs_idle`, `gs_spool`, `gs_recov`, `gs_active`,
    `gs_hold`, `gs_fallbk`, `gs_autorot`, `gs_bailout`, `gs_bypass`
  - Toolbox: `bank`
  - All peak-normalized to match the EdgeTX voice-pack loudness. Spoken numbers/units still
    come from the EdgeTX voice pack.
- **Model images** in `/images/`: a single file named after the Rotorflight model name
  (`rf2.modelName`; falls back to the EdgeTX model name) is enough — search order
  `<name>-<cells>S` (optional) → `<name>` → EdgeTX model bitmap, extensions *(none)*,
  `.png`, `.bmp`, `.jpg`, `.jpeg`. Missing image → empty area, no error.

---

## 9. Known limitations

- The right value panel and the Telemetry detail are configurable (§2.3a); the left status
  panel, the central gauge and the stats table still use fixed Rotorflight sensors.
- Stats "mAh Used (%)" shows the raw, not reserve-adjusted, percentage.
- Touch is only delivered to the widget in **full-screen** — the menu, detail pages and
  the stats manual-dismiss work full-screen only.
- *Callout volume* overrides the WAV level only; controlling the radio **master volume**
  needs the GVAR bridge + model Special Function (§5.4).
- **Connect reads are single-shot (no retry):** the FC values read on connect (battery
  config, capacity, profile names) are requested once. If they are missing after a
  connect (rare — an MSP hiccup), unplug/replug the pack once.
- The **layouts are designed for full-screen zones**. In very small widget zones the
  stats table can run out of row height and overlap — use larger zones there.
- After a fresh connect the raw min/max chips of *raw* telemetry slots may briefly show a
  0 from the disconnected gap — the session wipe on connect clears them; the 0-dip only
  appears while disconnected (honest EdgeTX session view).
- The **fullscreen alert overlay** (§2.6a) shows on the flight/stats views; while a
  detail page or menu is open the overlay waits underneath and reappears when that view
  closes — *Overlay auto-close* keeps counting from the episode's start meanwhile.
- The **config warning overlay** uses the same box and is the **lowest** priority in it: a
  live safety alert always wins, and it is suppressed entirely while armed. It is raised by
  the ELRS link-configuration verdict (§3.6a), which is measured once per connect while
  disarmed — so "once per connect" is what it shows, and the X silences it until the next
  one.
- **Closing is the X in the corner and nothing else** (0.8.0, both for the alert overlays and
  for the config warning). A tap anywhere else on the box does nothing — but it is still
  *swallowed*, so it cannot click through onto the tap zones the box is covering. Reaching the
  X needs full-screen (touch rule above): with the widget in a normal zone the **first tap
  opens fullscreen** (that is EdgeTX's own widget tap), and the X is hittable after that.
  Without touch at all, the overlay clears via *Overlay auto-close* or when the condition ends.

---

## 10. Credits & license

UltiDash is a merged/derivative work and reuses code, logic and visual concepts from the
following widgets – all credit to their respective authors:

| Widget | Author / Source | License | Reused |
|--------|----------------|--------|-----------|
| **HeliDash** | gismo2004 – [HeliWidget](https://github.com/gismo2004/HeliWidget) | **GPL-3.0** (or later) | Base: layout, LVGL UI, telemetry, flight statistics |
| **ePowerbar** | Rob 'bob00' Gayle – [etx-widgets](https://github.com/bob01/etx-widgets) | GPLv3 | Battery/reserve model, discrete colors, cell-check, callout engine |
| **eBitmap** | Rob 'bob00' Gayle – etx-widgets | GPLv3 | Model/heli image from `/images/` |
| **eStatus** | Rob 'bob00' Gayle – etx-widgets | GPLv3 | Throttle %, multi-vendor ESC decoder, arming-disable reasons |
| **BattAnalog** | Offer Shmuely – [edgetx-x10-widgets](https://github.com/offer-shmuely/edgetx-x10-widgets) | GPLv2 (per file header) | only the **style** of the compact top-bar battery icon (no verbatim code) |

**License: GPLv3.** All reused components are GPL-compatible (HeliDash base GPL-3.0;
etx-widgets parts GPL-3.0), so UltiDash as a whole is distributed under **GPLv3**
(http://www.gnu.org/licenses/gpl-3.0.html), with the attributions above preserved.

**No warranty:** the software is provided *as-is*; use is **at your own risk**.

*(Plain-language summary, not legal advice.)* Full license header also in `main.lua`.

## 11. Debug log (diagnostics)

Optional troubleshooting log, enabled per model in **Settings ▸ General ▸ Debug log to SD
card** (default **off**). When off the cost is ~zero (every entry point early-returns; no SD
IO, no heap growth).

- **On-screen perf overlay:** while the debug log is on, a small strip in the **bottom-left**
  of *every* view shows the live **UI-loop Hz**, **Lua heap** (`L`) and **free heap** (`F`), in
  kB — the same metrics as the Status footer, but always visible (handy for watching load while
  flying or stress-testing the Log Viewer). Bottom-left so it covers neither the menu glyph
  (top-left) nor the Log Viewer's zoom/pan buttons (top-right). Nothing is drawn when the
  option is off. **It has its own switch** — *Settings ▸ General ▸ Show perf overlay*
  (default **on**) — so the log can run without the strip: the two used to be one setting,
  and wanting the file for a flight or a bug report meant accepting the strip over the
  layout. Off there leaves the logging untouched.
- **Files:** rotating session files `/WIDGETS/UltiDash/logs/debug_NN.log` (read them from
  the PC at `<card>:\WIDGETS\UltiDash\logs\debug_NN.log`). **Debug log: sessions kept** (1–50,
  default 20) sets how many are retained; a tiny `debug_seq.txt` drives the round-robin
  slot. The `logs/` subfolder ships with the widget; old debug files left in the widget
  root by earlier versions are moved into it the next time logging is enabled (if the
  folder is missing, logging falls back to the widget root as before).
- **A new session** (= new file) starts every time logging is switched on and on every radio
  restart while it is on. The first line is `INIT session #<n> <timestamp> (slot N/keep,
  dir …)` — the highest `session #` is the newest.
- **Contents:** every connection-`STATE` transition and a 1 Hz `PERF` snapshot
  (`hz / heap kB / pass ms / state / armed / view / menu / detail`); messages logged
  internally are mirrored in too.
- **Low impact:** lines are buffered in a capped RAM ring and **appended incrementally**
  to the session file — only the lines since the last flush are written. Disarmed the
  flush runs every ~3 s; **while armed it keeps flushing too**, at a conservative ~10 s
  cadence (the appends are tiny), so a crash / power loss in flight loses at most the
  last few seconds of log. A per-session file cap (~5000 lines) bounds SD growth; hitting
  it writes a marker line and stops that session's log.

## 12. Flight log & battery management

Optional per-model features (all default **off**), configured in **Settings ▸ General**.
Data lives in `/WIDGETS/UltiDash/fltlog/` (plain text, ships with the widget; safe to back
up or edit on the PC).

### 12.1 Flight log (`Log flights to SD card`)

Appends one line per flight to `fltlog/flights.csv`:

```
date,time,model,battery_id,flight_s
2026-07-10,14:32:05,Goblin 580,96dded9b2f4b43f0,312
```

- **date/time** — the flight's START (taken at the ARM rising edge).
- **model** — the FC-set model name (the craft name shown on the dashboard).
- **battery_id** — the pack selected via the battery query (empty when none).
- **flight_s** — the widget's tracked flight time for this arm cycle (counts while
  armed **and** the rotor spins, same counter as the stats page), in seconds.

One line per arm cycle. Arm cycles whose tracked time stays under **Min. flight time**
(default 30 s — spool-up tests, arming checks) are not a flight: they reach neither the
CSV nor the battery cycle counter. Set it to 0 to log every arm. The write happens on
the disarm edge — and immediately on an
armed disconnect (crash / main power lost), so the record survives. A mid-flight telemetry
dropout can split one flight into two logged legs; the totals stay correct. The CSV is
deliberately import-friendly for external tooling. One header note for PC imports: the
header line is written only when the file is **created** — a `flights.csv` started before
*Log per-flight stats* (§2.7a) was enabled keeps its old 5-column header while newer lines
carry the extra stats columns. If your import tool minds, archive/rename the file once;
the next flight starts a fresh file with the full header.

The file **grows forever by design** — UltiDash never prunes it (a season of flying is
a few hundred small lines). Archive or trim it on the PC whenever you like; the viewer
(§12.4) lists the newest 300 flights either way.

### 12.2 Battery registry (`fltlog/batteries.cfg`, editable on the radio and on the PC)

Since 0.8.0 packs can be **created, edited and deleted on the radio**: from the Flight
Log's *Batteries* tab (tap a pack → detail page → **Edit** / **Delete**; **+ New** in the
header) and from the battery query's **+ New battery** button (§12.3). On the PC, start
from the shipped, commented template: copy `fltlog/batteries.example.cfg` to
`fltlog/batteries.cfg` and edit it — both routes work on the same file, and the radio's
editor rewrites **only the edited pack's line** (comments, unknown fields and every other
line survive byte-for-byte). Only `batteries.cfg` is read, so a widget update
never overwrites your list. One battery per line, a leading `#` marks a comment line:

```
id=1;name=Tattu 6S 3700;cap=3700;models=Goblin 580,Logo 550;profile=2;cycles=0;last=
```

| Field | Meaning |
|-------|---------|
| `id` | unique id, any string — `1`, `2`, … or an external-system id like `96dded9b2f4b43f0`; goes into the CSV so usage can be matched externally |
| `name` | display name on the radio |
| `cap` | capacity in mAh — shown on the query page, and with **Battery sets FC profile** on it selects the FC profile whose configured capacity matches (first match wins on duplicates) |
| `models` | comma list of model names the pack is offered for (FC-set name, case-insensitive); `*` or empty = every model — one pack can serve several models, tracked under one id |
| `profile` | optional override: FC battery profile 1–6 activated on selection *instead of* the capacity match — only needed when capacities are ambiguous or not set in the FC (MSP write, disarmed only — same call as the profile picker §3.5; the write is deferred a moment after the pick, skipped when the profile is already active, and retried while rf2's MSP queue is still busy with the connect reads) |
| `cycles`, `last` | maintained by the widget: +1 and the date **once per battery session**, on the first logged flight |

The widget only rewrites what it must — the cycle stamp touches the matched pack's
`cycles`/`last` fields, the on-radio editor only the edited pack's line — comments and any
extra fields you add survive. Every update is **atomic**: the new content is written to a
temp file, size-verified, and only then swapped in — the previous version stays behind
as `batteries.cfg.bak` (normal, not an error; a failed SD write leaves the original
untouched). `id` must be **unique** — on duplicates the first
entry wins and the rest are ignored, and the on-radio editor refuses to create one.

Field rules, shared by both editing routes (the on-radio editor enforces them; keep to
them on the PC too):

- **`id`**: characters `A–Z a–z 0–9 _ -`, non-empty, unique. New packs are prefilled with
  the smallest free positive integer; the field stays editable. **Renaming an id does not
  rewrite `flights.csv`** — old flights keep the old id (the editor warns with the flight
  count before renaming a pack that has logged flights).
- **`name`**: free text without `;`, up to 24 characters; empty falls back to the id.
- **Clearing an optional field removes it from the line**: capacity 0 = no `cap=` (the
  query page shows *capacity ?*, no capacity match), profile *auto* = no `profile=` (match
  by capacity as usual), models *All models* = no `models=` (offered for every model).
- The on-radio editor refuses a registry **larger than 64 KiB** with a visible message
  (*"batteries.cfg too large to edit on the radio"*) — a file that size must be tended on
  the PC.

### 12.3 Battery query (`Ask battery on connect`)

After a fresh connect the Dashboard waits ~3 s (for the FC model name), then opens a
selection page — **fullscreen only** (touch), disarmed, with nothing else on screen; when
no registry pack matches the model it silently never opens. Packs are listed in their
`batteries.cfg` order — stable across connects, so the rows never shift when you rotate
packs; **No battery / skip** (or RTN) continues without an id — flights
still log with an empty battery column. **+ New battery** (below the skip button) opens
the registry create form (§12.2) with *models* preset to the connected craft — for the
moment an unknown pack is plugged in at the field; after Save the pick list reloads with
the new pack at the end, Cancel returns unchanged. The selection sticks until the
disarmed unplug (a telemetry blip or a crash-retrieve-replug within ~2 min keeps it;
arming closes the query window, an open create form included — nothing is written).

### 12.4 Toolbox ▸ Flight Log (viewer & battery editor)

Lazy-loaded, **disarmed-only** (auto-closes on arm; an open edit form is discarded,
nothing written). Since 0.8.0 the page is drawn in the same detail-page style as the other
Toolbox tools: title left, the three tabs as **chips** in the header (filled = active),
a totals/paging footer. Every tappable row ends in a `>` chevron; **all three tabs are
tappable**:

- **Flights** — *Date / Model / Battery / Time*, newest first, paged; the newest 300
  flights are listable, the totals line counts everything. **Tap a flight row** to open its
  **detail page**: a summary (model / battery / duration+mAh, sag count) plus a min/max
  table mirroring the flight-statistics view (cell voltage, headspeed P1-3, current, ESC
  temperature, BEC). Only present when *Log per-flight stats* (§2.7a) was on for that flight;
  otherwise the detail page says *No stats recorded*. RTN or a tap on the header returns
  to the list.
- **Models** — *Model / Flights / Total time*. **Tap a model row** to jump to the Flights
  tab **filtered to that model**: a `Model: … x` chip appears in the header (tap it — or
  RTN — to clear the filter) and the footer counts `N of M flights` with the filtered
  total time. The filter is session-local; leaving the Flights tab clears it.
- **Batteries** — *Battery / Capacity / Cycles / Flights / Last use*, every registry pack.
  **Tap a pack row** for its **detail page** (id, capacity, cycles, flights, last use,
  profile, models) with **Edit** and **Delete**; **+ New** in the header creates a pack.
  The edit form and its rules are §12.2; deleting asks first and names the pack's logged
  flight count (those flights keep the id and show it raw afterwards).
