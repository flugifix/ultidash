# Changelog

All notable changes to UltiDash are documented here.

## v0.6.1 — 2026-07-23

Maintenance release on top of v0.6.0: one small battery-callout option plus Log Viewer
performance and a smoother disconnected idle. Existing behaviour is unchanged by default.

### Added

- **Fuel callout can speak voltage.** A new *Settings ▸ Battery ▸ Fuel callout says* choice
  (**Percent** / **Battery V** / **Cell V** / **% + Battery V** / **% + Cell V**) picks what
  the descending %-step callouts announce. The %-interval triggering is unchanged — only the
  spoken value changes; it reads the latched, collapse-filtered voltage, is independent of
  *Announce voltage as*, and falls back to the percent when a requested voltage isn't
  available (never silent). The critical nag keeps speaking the percent. Default *Percent*
  = unchanged behaviour.

### Changed
- **Faster Log Viewer pan/zoom.** Panning now shifts the existing scratch buckets and only
  re-reads the newly exposed edge, and a unified RAM window cache (a hi-res base plus finer
  zoom levels) backs the view, so zooming and panning stay fluid even on large logs.
- **Cursor readouts follow the chart.** The Log Viewer's value readouts moved into a
  compact legend that tracks the chart line instead of sitting in a fixed corner.
- **Snappier idle UI while disconnected.** `read_src` holds a nil telemetry result for 3 s
  instead of re-hitting the source every cycle, keeping the dashboard responsive when no
  flight controller is connected.

## v0.6.0 — 2026-07-19

Maintenance + feature release on top of v0.5.1. **Experimental — still shaking out in the
field.**

### Added
- **Dedicated "Status text" colors for Armed / Disarmed** (*Settings ▸ Colors*, new
  section on all three scheme pages). The statusbar arm-state text no longer has to share
  the traffic-light green / the Warning-accent palette slot: assign *Armed* and *Disarmed*
  their own colors per scheme. Left unset, both follow the historical colors (armed = the
  effective Good green incl. its override, disarmed = the resolved Warning accent), so the
  default look is unchanged. The Status page's "Armed" connection line follows the Armed
  color too.
- **ESC load display in the battery gauge** (alternative placement). New *Load bar*
  choice in *Settings ▸ ESC load*: keep the classic thin bar under the dashboard's
  Current row, or turn the **free gap** between the battery gauge's fill segments and its
  outline into the load display. The load lights **whole gauge rows bottom-up** (snapped
  to the segment rows, in the warn/critical colours) — so a row is ever fully on or off,
  never a ragged partial edge — following both contours: the outline's rounded corners via
  filled arc sectors, the top/bottom segments' rounding via under-laid fill. The **ring
  closes at 100 %**; beyond that the colour (red ≥ critical) carries the overload. The
  unfilled gap stays transparent. The **Battery detail page** carries a matching gap-ring
  load display along its Current row while monitoring is on.
- **Governor-mode aware statistics.** UltiDash now reads the FC's governor mode at
  connect (`mspGovernorConfig`, MSP — connect/disarm only). In governor modes
  **OFF / LIMIT** the firmware never updates the `Gov` state sensor, which used to keep
  the headspeed/current min-max tracking from ever engaging; in those modes the tracking
  now falls back to **armed + rotor spinning** (`Hspd > 100 rpm`; armed-only without an
  `Hspd` sensor), the governor slot shows **Gov. Off / Gov. Limit** instead of the
  misleading *Throttle off*, and the sensor-check hint for `Gov` explains the fallback.
  Setups with a running governor (DIRECT / ELECTRIC / NITRO) are unchanged; without a
  readable governor config (old RFTool) the previous strict gating remains.
- **Flight log & battery management** (opt-in, *General* settings group). *Log flights to
  SD card* appends one line per flight to `WIDGETS/UltiDash/fltlog/flights.csv`
  (`date,time,model,battery_id,flight_s` — start time, the FC-set model name and the
  tracked flight time; arm cycles under the configurable *Min. flight time*, default 30 s,
  are skipped). *Ask battery on connect* opens a
  selection page after each fresh connect when the PC-edited registry
  `fltlog/batteries.cfg` lists packs for the current model — a commented template
  `fltlog/batteries.example.cfg` ships with the widget (last-used pack first and
  `>`-marked; *No battery / skip* always available); the selected pack's id goes into the
  log and its `cycles`/`last` fields are bumped once per battery session, so usage can be
  matched to an external system by id. *Battery sets FC profile* optionally activates the
  matching FC battery profile on selection — matched by the pack's capacity against the
  FC profiles' configured capacities, or via an explicit `profile=` override (MSP,
  disarmed only, same call as the profile picker; skipped when already active). A new
  Toolbox page **Flight Log** (lazy-loaded, disarmed-only) shows
  the recent flights, per-model totals and the battery usage — three tabs, paged, each
  with a proper column-header line (Date / Model / Battery / Time, Model / Flights /
  Total time, Battery / Capacity / Cycles / Flights / Last use) over plain-number cells.
  An opt-in **Log per-flight stats** (default off) appends the dashboard's
  flight-statistics to each logged flight — cell voltage, per-profile headspeed (P1..P3),
  current, ESC temperature and BEC voltage as min/max, plus the voltage-sag count/deepest
  and the mAh used. **Tap a flight row** to open its detail page (a min/max table mirroring
  the stats view). These are the session min/max at disarm, so they are exact per flight
  when you disconnect between flights (several flights on one link accumulate, like the
  stats view). Extra CSV columns, appended after the existing ones — old logs and the
  5-column format keep working.
- **Configurable theme colors.** New *Colors* settings submenu (under *Settings*) with one
  page per color scheme: for *UltiDash* and *UltiDash dark* every color is adjustable —
  the 8 palette slots (text, backgrounds, accents), the traffic-light set (good / warning /
  critical / neutral) and the chrome colors (panel fill, bar track, tick marks, dim text);
  for *EdgeTX theme* the colors the theme itself does not define (the traffic-light set).
  Each row uses the native EdgeTX color picker plus a *Def* button that reverts that color
  to the scheme's built-in; the per-page reset reverts a whole scheme. Overrides are stored
  per model (0xRRGGBB in the cfg file) and only for colors you actually changed.
- **Battery colors are configurable too.** The main battery bar's five fill colors
  (OK / not-full warn / low / critical / cell-check) and the top-bar TX battery icon
  (OK / low) — historically fixed — now have their own *Battery* section on each Colors
  page. Defaults are unchanged.
- **PC-side instruction-budget check** (`tools/check_budget.lua`, dev tool): loads the real
  widget sources with EdgeTX API stubs and counts Lua VM instructions per lifecycle call
  with the same hook mechanism as EdgeTX's ~20k "CPU limit" — so a budget overrun is
  visible before deploying. Run `lua tools/check_budget.lua` (repo root, `-v` for
  per-cycle detail; exit 0 = within budget).
- **Governor-state voice callouts.** New *Gov voice* settings group announces the governor
  state (the `Gov` sensor) on every change **in flight (armed only)** — "spooling up",
  "governor active", "throttle hold", "autorotation", "bailing out", "governor fallback",
  "governor bypass", etc. A master *Announce gov state* toggle (default off) plus a per-state
  enable for each of the ten states, so you pick what gets called out. Debounced (~0.3 s) so
  the spool-up sequence doesn't chatter; the state at arming is the silent baseline. English
  and German voice files included; read-only, issues no MSP.
- **Voltage callouts can announce per-cell voltage.** New *Battery ▸ Announce voltage as*
  (Battery / Cell): the voltage alert and the startup cell check speak either the total
  pack voltage (default — unchanged) or the per-cell voltage. Independent of the on-screen
  *Voltage shown as* display setting, so you can show cells but hear the pack, or vice
  versa. Uses the latched, collapse-filtered value; falls back to pack voltage if no
  per-cell reading is available.
- **On-screen warning when settings can't be saved.** If writing the per-model config to
  the SD card fails (card full, write-protected or removed), a short warning banner now
  appears on the dashboard/stats view for ~10 s — previously the failure was silent and you
  only noticed after a restart lost your changes.
- **Alerts submenu shows each alert's on/off state.** Every alert button now carries an
  "On" / "Off" status, so you can see which alerts are active without opening each page.
- **Fuller telemetry-sensor catalog for the value slots.** The *Tele Main / Tele Details*
  dropdowns now know the second ESC group (`Es2*`), the rail voltages/currents (`Vesc`/`Iesc`/
  `Ibec`/`Ibus`/`Imcu`), extra ESC values (used mAh, RPM, PWM, load), MCU load, and altitude /
  attitude / GPS sensors — each with a friendly label. (The dropdown still lists only the
  sensors your model actually reports.) Fixed three dead entries that named non-existent
  sensors (`Cbec`/`Cbus`/`Cmcu` → the real `Ibec`/`Ibus`/`Imcu`).
- **New alert: ESC / MCU over-temperature.** A *Temperature* alert (under *Alerts*) calls out
  ESC or MCU over-temperature with the value in °C. Separate warn/critical thresholds per
  sensor live under *Thresholds ▸ Temperature* (defaults ESC 90/110 °C, MCU 75/90 °C; set a
  threshold to 0 to disable that branch). Armed-only, with vibrate and repeat like the other
  alerts; a model without the `Tesc`/`Tmcu` sensors stays silent.
- **Warning when two Dashboard instances are placed.** Two placed Dashboard instances both
  drive callouts and the shared state, which doubles announcements and flickers the passive
  views. A "2 Dashboard instances active!" banner now appears on both so the misconfiguration
  is obvious — place exactly one Dashboard (passive ELRS/Status views are fine).
- **Configurable current source.** New *Battery ▸ Current sensor* (Curr / EscI / Iesc) picks
  which sensor feeds the Current row, the ESC-load monitor and the current min/max — so a
  model that reports current only over ESC telemetry (no FC current sensor) can show current
  and use the ESC-load monitor. Default *Curr* keeps the previous behaviour.
- **Sensor check page.** A new *Sensor check* entry in the menu lists the sensors UltiDash
  relies on and flags what is missing: the required sensors (arming, battery, cells,
  headspeed, governor, link) with a one-line note on what a gap breaks, the sensors
  used by the features you have enabled, and your configured value slots. Each row carries a
  colored status badge — green **OK**, red **MISS** (required), yellow **MISS** (optional),
  gray **--** (present but no data — normal with the FC off) — the friendly sensor name in
  the standard font, the sensor code at the right edge, and a hint to run *Discover new
  sensors* when the custom telemetry hasn't been set up; a legend at the bottom explains the
  three states. **While the FC is connected the right column also shows each sensor's live
  value** (1 Hz), which turns the page into a quick diagnostic view. Read-only; it only
  scans while the page is open.
- **Voltage-sag counter in the flight stats.** A new *V sags* row counts how often the cell
  voltage briefly dipped to/below the critical threshold — including the short load sags the
  voltage alert's debounce ignores — and shows the deepest cell voltage seen. Zero-config,
  display-only; resets with the other session stats.
- **Switch shortcuts — open any page hands-free.** A new *Shortcuts* settings group binds
  switches to pages (no touch needed, so it works in flight or with gloves). Targets are the
  detail pages (ELRS / Status log / Battery / Telemetry) **and** the Toolbox tools (Adjust
  Map / Adjust Edit / Log Viewer / RF2 Config / Flight Log). Two mechanisms: **6 position slots** — a
  switch position *holds* its page open (leave the position, it closes), with a configurable
  *Switch delay* so passing through a middle position on the way to another doesn't fire the
  intermediate one; and **2 toggle slots** — each press steps through up to four options, then
  closes. Replaces (and folds in) the old *Display ▸ Detail page switch* and the *Toolbox ▸
  Activation switch* — those single-purpose switches are gone; re-assign under *Shortcuts*.
  A shortcut only closes the page it opened, and *Close detail pages on arm* still applies to
  detail targets; the disarmed-only tools refuse to open while armed. RTN from a
  shortcut-opened tool returns straight to the dashboard (no menu trail to unwind); each
  slot is its own section on the settings page.
- **ELRS page shows the downlink RSSI/SNR.** A new *TRSS* row (downlink RSSI, measured at the
  TX module) helps separate downlink problems — telemetry dropouts, module antenna, too-low
  telemetry ratio — from uplink/control ones. The SNR row now shows uplink / downlink together
  (e.g. "8 / 5dB").
- **Governor "Bypass" state (Rotorflight 2.3).** The governor-state readout now shows
  *Gov. Bypass* for the new bypass state (GOVBYPASS box active, rotor running on the bypass
  throttle curve) instead of the misleading *Gov. Disabled*.
- **Toolbox: Log Viewer (WIP).** A new *Log Viewer* tool page graphs EdgeTX telemetry logs
  (`/LOGS/*.csv`) directly on the radio: up to 4 min/max envelope curves, zoom / pan /
  draggable time cursor, and automatic recording-session split. A **100 %** button resets
  the zoom to the whole session in one tap, and the template / session selectors are
  bordered header chips so it's clear they open a picker. After opening a log you
  choose what to display on a **two-column card page** — a built-in template (**Power /
  Battery / RF link / Governor**, each showing how many of its sensors the log contains)
  **or** your own set from a sensor picker. The picker groups every column **exactly like
  the Rotorflight Configurator's Telemetry Sensors dialog** (Battery, Voltage, Current,
  Temperature, ESC #1/#2, RPM, Barometer, Gyro, GPS, Status, Profile, Control, System,
  Debug — plus RF-link, stick, switch and channel groups for the radio-side columns);
  groups start **collapsed** with a *selected/available* counter and fold open on tap, each
  sensor carries an **on/off toggle switch**, and a **List / Grid** toggle at the top picks
  the roomy one-per-row layout or the compact multi-column grid (up to 4). Own templates
  via `toolbox/logtemplates.lua`
  (copy the `.example`). The file list shows only real telemetry logs (newest first,
  **all models by default** with the model name per row; a header button opens a
  **Filter by model** page built from the model names found in `/LOGS`, each with its
  log count) and is **swipe-scrolled**
  without page rebuilds, so scrolling stays fluid even with hundreds of logs. Folders with
  more than ~370 logs are scanned incrementally (the one-shot scan used to hit the Lua
  instruction budget, silently dropping the **newest** logs and sometimes reporting
  "Cannot read /LOGS folder"); the list cap keeps the newest 600 logs. Log parsing
  extracts all curve columns with a single precompiled pattern match per line, making
  first load and every zoom/pan re-load several times faster. A graphical progress bar
  covers both. English UI throughout. Disarmed-only; still under hardware testing.
  *(Known limitation: the hardware wheel does not scroll the file list yet — EdgeTX
  routes wheel events only to a focused LVGL object.)*
- **Toolbox: RF2 Config — the original Rotorflight configuration tool inside UltiDash.**
  A new *RF2 Config* tool page runs the stock **rotorflight-lua-scripts** configuration
  tool (main menu, all config pages, save, reload/reboot popup) with its original look,
  navigation and key handling, opened straight from the dashboard's Toolbox. Zero-copy:
  nothing is duplicated — the original scripts load from `/SCRIPTS/RF2/` on the SD card,
  so updating the Rotorflight Lua suite updates this page automatically. Requires the RF Tool
  widget (as UltiDash already does). Disarmed-only — it refuses to open and force-closes
  on arming (UltiDash's no-MSP-while-armed rule; the standalone tool has no such guard).

- **Fullscreen overlay for critical alerts** (opt-in, per alert). *Main power lost*,
  *Voltage* (critical level) and *Telemetry* each gained a *Fullscreen overlay* toggle
  (default off): while the alert is active, an unmissable red inset box covers the
  flight/stats view with the alert name in the biggest fitting font plus the live value
  (buffer/BEC voltage, cell voltage). A tap dismisses it for the current episode, and a
  shared *Overlay auto-close (s)* setting (Voice / mute page, default "until tapped")
  can close it hands-free; it comes back only when the condition clears and fires again.
  Drawn as plain build-table primitives toggled by reactive visibility — showing or
  hiding it never rebuilds the view and never blocks the telemetry/callout pass.
- **Explicit "Buffer" readout while main power is lost.** During a main-power loss the
  voltage slot no longer shows a bare "--": it flips to a red **Buffer** readout of the
  live BEC/buffer voltage — mirroring what the repeated callout speaks, so the buffer
  can be watched, not just heard. (The fuel-gauge % still reads "--"; a pack % is
  meaningless on the buffer.)
- **Cell-count-relative main-power-loss threshold.** *Thresholds ▸ Power warn from*
  (new, default **Cell count (auto)**) derives the threshold as cell count × *Power warn
  (V/cell)* (new, default 3.0 V) — a 2S warns at 6.0 V, a 6S at 18.0 V, with 3S exactly
  matching the old fixed 9.0 V default. *Fixed voltage* keeps the manual override (the
  existing *Power warn voltage* value), which is also the fallback until a cell count is
  seen. Replaces the "lower the threshold by hand on a 2S" tip. If you had hand-tuned
  *Power warn voltage*, set *Power warn from* to *Fixed voltage* once.
- **"No FC connected" hint on the flight view.** With no FC link the status bar's center
  text now reads "No FC connected" (dimmed) instead of a stale arming state — previously
  the disconnected state was only recognizable indirectly (empty values, slower updates).
  While disconnected the telemetry pass deliberately idles at 2 Hz.
- **The editor's range hints are overridable.** `toolbox/labels.lua` may now carry a
  `ranges` block (same shape as the label rows) that replaces the built-in
  recommended-value hints (*Adj editor: ranges hint*) per setup — see TOOLBOX.md §6.

- **Test buttons for the voice callouts.** The *Volume* page, the *Alerts ▸ Voice / mute*
  page and every per-alert page now carry a *Test callout ▸ Play* row that previews the
  alert's real announcement — including a sample number where the live callout speaks one
  (Fuel says "70 %", Voltage / Cell check speak a sample voltage in the format your
  *Announce voltage as* selects). The preview uses the page's **current, unsaved** values
  for language, widget volume and master mute, so you hear exactly what you are about to
  save — no flight needed to check loudness or language. (The settings menu closes on
  arming, so a preview can never play in flight.)

### Documentation
- **New [Illustrated Walkthrough](docs/WALKTHROUGH.md)** — a screenshot tour of the flight
  dashboard, the tap-to-open detail pages (Battery / Telemetry / ELRS / Status), the menu,
  Sensor check, and the Toolbox (Log Viewer + Flight Log), in both the light and dark
  colour schemes. Linked from the top of the README.
- **New [Quick Start guide](docs/QUICKSTART.md)** — the shortest path to a working base
  setup (dashboard, views, statistics): copy files, the **one Rotorflight CLI line**
  (`set telemetry_sensors = …`) that enables every FC sensor the built-in features need
  (with an ID→sensor table), install RFTool, discover sensors and place the widget. Notes
  that the ELRS link sensors arrive natively (no FC setup) and that the empty duplicate
  ELRS sensors are best deleted. Linked prominently from the top of the README.
- **New [Optional Features guide](docs/OPTIONAL_FEATURES.md)** — a supplement to the Quick
  Start with the elementary setup steps for the optional features (extra value-slot sensors,
  model image, master-volume GVAR bridge, ESC-load monitor, RF-adjustment tools, Log Viewer,
  flight log & battery management) plus a list of the menu-only features that need no
  external setup. Linked from the README and the Quick Start.
- **Quick Start: placement tip** — put UltiDash in a full-screen zone with the top bar
  hidden, but keep RFTool in a top-bar slot so it stays active without costing screen space.
- **README: a "Key features" summary** near the top for a fast overview, above the
  existing detailed feature list.

### Changed
- **Fuel-callout density defaults relaxed.** *Fuel: dense below* 10 → **15 %** and *Fuel:
  fine step* 1 → **5 %**, so the fine-grained end-of-flight callouts start a touch earlier
  and space out more sensibly by default (the old 1 % spacing was too chatty).
- **Shortcuts pick switch + position in ONE native picker.** The position slots' separate
  *Switch* + *Position (Up/Middle/Down)* rows and the toggle slots' *Switch* row are
  replaced by a single **Switch position** field using EdgeTX's own switch picker
  (`SA↓`-style entries, logical switches included) — the same pattern the radio uses
  everywhere else, and a toggle "press" can now be any position (momentary `SH↓` works
  naturally). *(WIP-only break: shortcut switches picked with an earlier 0.6.0 build use
  new cfg keys — re-pick them once; released versions are unaffected.)*
- **Shortcut targets labelled by kind.** The *Opens* dropdown reads as `Category: Name`
  throughout — `Page: ELRS`, `Page: Battery`, … for detail pages and `Toolbox: Log Viewer`,
  `Toolbox: RF2 Config`, `Toolbox: Flight Log`, … for tools, so it is obvious what kind of
  page a shortcut opens.
- **Alerts overview shows each alert's setup at a glance.** The per-alert buttons in
  *Settings ▸ Alerts* now append compact feature markers to the On/Off state — **+R**
  repeat, **+E** escalation volume, **+V** vibrate, **+O** fullscreen overlay (legend
  under the grid; only effective features appear, e.g. +E needs the volume GVAR).
- **Every alert page explains its trigger.** Each per-alert settings page opens with a
  one-line summary of when the alert fires (armed-only conditions, thresholds, what the
  callout speaks), so the knobs below have context.
- **Settings menu reorganized into a themed grid.** The settings groups now sit in a
  3-column grid under four section headers — *Appearance* (Display / Colors / Telemetry),
  *Battery & limits* (Battery / Thresholds / ESC load), *Sound & callouts* (Volume /
  Alerts / Voice) and *System* (Shortcuts / Toolbox / General). *Tele Main* and *Tele
  Details* moved into a small **Telemetry** submenu, *Switch voice* and *Gov voice* into a
  **Voice** submenu (one extra tap each; all keys and stored settings are unchanged).
- **Settings pages: aligned columns and row separators.** All controls on a page now end
  flush at the same right edge — dropdowns share one width per page (previously each row
  sized its own, so the left edges jittered), the stepper value column is measured from the
  page's actual values instead of a fixed worst case, and toggles line up with the fields
  around them. Thin separator lines between rows and underlined section headers make the
  long pages (Thresholds, Shortcuts) considerably easier to scan.
- **Menus sized for the small radios.** Single-column menu buttons (Menu / Colors /
  Telemetry / Voice / Toolbox) are now capped at ~65 % of the screen width instead of
  running edge-to-edge on a 480 px display, and a menu grid that would overflow the screen
  shrinks its gaps and row heights (still comfortably tappable) before anything scrolls —
  the Toolbox page no longer pushes its "available only while disarmed" hint off-screen,
  and the settings grid keeps its *Reset to defaults* button visible.
- **Toolbox marks the disarmed-only tools while armed.** Log Viewer, RF2 Config and Flight
  Log are drawn dimmed while the craft is armed (the menu redraws on the arm transition);
  tapping one still shows the explanatory hint.
- **Color-scheme list reordered.** *Display ▸ Color scheme* now lists UltiDash /
  **UltiDash dark** / **EdgeTX theme** (dark moved to slot 2, the EdgeTX theme to slot 3).
  Stored settings are remapped automatically by a one-time cfg migration (`ClrSchemeV`
  version stamp), so the scheme you picked stays the scheme you get.
- **Staged widget startup (CPU-limit fix).** EdgeTX gives each widget call ~20k Lua VM
  instructions, and `create()` alone already carries loading all five module chunks
  (~13.5k). The cold per-model cfg read + apply on top tripped "CPU limit" once the cfg
  grew (color overrides). Startup is now staged: create = module load + flag only →
  next cycle = cfg read/apply alone → next cycle = UI build. Costs two invisible frames.
- **Tidier SD layout: per-model configs in `cfg/`, debug logs in `logs/`.** UltiDash no
  longer scatters its data files across the widget root — per-model settings now live in
  `/WIDGETS/UltiDash/cfg/` (`cfg_m_<slot>.cfg`, and the optional per-craft files) and the
  debug logger writes to `/WIDGETS/UltiDash/logs/`. Both folders ship with the widget, so
  nothing is created at runtime; files left in the root by earlier versions are **moved in
  automatically** on start (settings) / on first enable (logs), and settings are also
  adopted per model on load — upgrading loses nothing. If a folder is ever missing UltiDash
  falls back to the old flat root layout, so it can never fail to read your settings.
- **Toolbox Log Viewer and RF2 Config load on demand.** Both modules are now loaded when
  their Toolbox entry is tapped and released again on close, instead of staying resident
  from boot. Keeping the Log Viewer permanently loaded had grown the Lua heap by ~250 KB
  and the extra garbage-collector work measurably slowed the whole UI loop (~19 → ~15
  refreshes/s) — dashboards, menus and detail pages all felt sluggish. Opening a tool now
  has a one-off (imperceptible) load moment; everything else got its speed back.
- **Voltage alert repeats the LOW band too, not just critical** (with *Voltage ▸ Repeat*
  on). A sustained dip below the low threshold — e.g. pulling through a loop — now keeps
  calling out at the repeat interval until it recovers, and switches from "battery
  critical" back to "battery low" if it eases off. Turn *Voltage ▸ Repeat* off for the old
  single-announce-per-level behaviour. (The low band never boosts the escalation volume —
  that stays tied to critical.)
- **Louder defaults for the two safety-critical alerts (fresh configs only).** Main power
  lost now defaults to **Vibrate on** and **Repeat until cleared** (an audible buffer
  countdown); telemetry lost now **repeats** a few times by default. Existing models keep
  their saved settings.
- **RSSI / signal callout now speaks the value** (signal headroom %), like the other
  value-carrying alerts; repeats speak the current value.
- **Settings are only written when you actually change something.** Opening a settings page
  and leaving it without editing no longer rewrites the per-model config file — fewer
  needless SD-card writes.
- **Settings that currently have no effect are dimmed.** A row that depends on another
  setting (e.g. the manual cell thresholds when *Cell thresholds from* is *FC config*, the
  ESC-load rows when monitoring is off, a repeat count when *Repeat* is off, escalation
  volume without a master-volume GVAR) now shows its label greyed out — so it is clear what
  is active. Dimmed rows still work; the greying only signals "no effect right now".
- **Alert "Repeat count" reads as a total.** The count now shows e.g. "3 total" (or "until
  cleared" for 0) and includes the first announcement, instead of a bare number that read
  ambiguously.
- **Vibration has its own master switch, separate from Mute.** New *Voice / mute ▸ Vibration
  (master)* controls haptic feedback independently of *Mute*. Previously *Mute: All* silenced
  vibration too; now *Mute* affects sound only, and vibration keeps working unless you turn
  its own master off. Existing models default to vibration on.
- **The model timer is only auto-reset when the widget actually shows it.** On a fresh
  telemetry connect UltiDash used to zero the configured model timer even when the top-left
  area showed the model image; it now resets that timer only when *Display ▸ Top-left shows*
  is set to *Timer*. If you use the model timer for something else, it is no longer touched.
- **Removed the non-functional "Overlay (prep)" toggle** from the alert pages until the
  full-screen overlay feature actually ships (it never did anything yet).
- **Settings pages are easier to scan.** Long pages now carry **section headers** (Display:
  *Layout & theme* / *Top & bottom bar* / *Behaviour*; Battery: *Fuel callouts* / *Cell
  thresholds* / *Cell check & voice*; Thresholds: *Link & signal* / *Power & BEC*), the two
  telemetry-slot pages explain the **dropdown + raw-source** two-field concept, and pages with
  steppers show a **"long press − / + for big steps"** tip. Row heights, the value column and
  hint wrapping are now measured (no clipped descenders or "until cleared" text on the TX16S,
  no clipped ESC hint on the TX15). The **[−]/[+] touch targets scale up** on the big TX16S.
- **Destructive resets are set apart.** The per-page *Reset … to defaults* now sits below a
  divider in a warning colour, and *Reset to defaults* (whole model) is a separate,
  warning-coloured button under the settings grid instead of one more grid tile — so neither
  reads like an ordinary navigation button. Confirmation dialogs are unchanged.
- **BEC alarm reference is frozen at arming.** The relative BEC warn/critical thresholds
  now measure against the BEC voltage captured **at the moment of arming**, instead of
  the highest value seen since arming — the running maximum could ratchet upward on noise
  spikes and silently tighten the alarm mid-flight. Reset on disarm/disconnect as before.
- **Unknown config keys are dropped on save.** The per-model cfg no longer accumulates
  keys forever: anything the current version doesn't know (typos, keys from another
  version) is removed on the next save. Note this is downgrade-unfriendly — an older
  UltiDash will find the newer version's keys gone; re-check settings after a downgrade.
- **Battery registry updates are atomic.** `fltlog/batteries.cfg` (the PC-maintained pack
  list) is no longer rewritten in place for a cycle-count bump: the new content is
  written to a temp file, size-verified and swapped in, keeping the previous version as
  `batteries.cfg.bak`. A full/failing SD card now leaves the original untouched (and
  skips that cycle count) instead of truncating the file. Duplicate `id`s are ignored
  (first entry wins), and an oversized registry is never written back truncated.
- **Volume-GVAR override keeps working off-screen.** The master-volume bridge (normal /
  escalation volume, the −1024 release on disconnect) is now also maintained while
  another main screen is active — an escalation boost no longer stays latched until the
  Dashboard is brought back up.
- **Dark scheme: the battery identity is readable.** The fuel gauge's empty segments use
  a muted mid-gray on the dark scheme (instead of glaring light gray), the %-and-mAh
  overlays pick black/white ink from the underlying fill's luminance (also with dark
  user color overrides), and the top-bar TX battery icon gets a light track behind its
  fill so the % text stays legible.
- **Status colours adapt to dark radio themes and read better everywhere.** The green /
  yellow / red status colours (battery, link, ESC load, arming) now follow whether the
  surface under the text is dark, so the *EdgeTX theme* colour scheme on a dark radio theme
  gets the bright variant instead of a muted one that sank into the background. Alongside
  this, the voltage-warning yellow, the armed / connected green, and the ESC-status
  warning/error text now use these theme-aware colours instead of raw built-in colours that
  were hard to read on some backgrounds (notably the armed green on the dark scheme). The
  *UltiDash* (light) and *dark* schemes are otherwise unchanged, and all bar/gauge fills are
  unchanged. Note: after switching the radio theme, reload the model (or restart the radio)
  so UltiDash picks up the new theme colours.

### Fixed
- **Colour picker: theme/fixed swatch picks no longer come back as dark blue.** The
  native EdgeTX colour popup returns two encodings: RGB/HSV pad picks arrive as an
  RGB565 value, but the *Theme* tab and the fixed swatch buttons return a raw colour
  **index** — which UltiDash decoded as if it were RGB565, turning e.g. the light-brown
  swatch into pure dark blue on the next visit to the Colors page (and on the dashboard).
  Indexed picks are now resolved first (theme colours via `lcd.getColor`, fixed swatches
  via a copy of the firmware's fixed colour table). Colours already saved through the
  broken path keep their wrong value — re-pick them once.
- **Switch voice announcements no longer pile up when flipping quickly.** EdgeTX offers
  no way to flush queued audio, so rapid flipping used to queue one announcement per
  stable position and play them all back to back. Announcements of the same switch are
  now rate-limited (1.5 s): changes inside the window are held and only the *current*
  position speaks when it expires — flipped back to the already-announced position,
  nothing plays. A single ordinary flip is announced with no added delay.
- **Alerts and latches now work while the link is down on the visible dashboard.** With
  the FC link lost, the *visible* dashboard skipped the whole alert machinery (the
  background pass did not) — so the telemetry-lost **repeat** nagged only when another
  screen happened to be active, and the power-lost / fuel / voltage latches and the
  overlay state froze through the outage instead of resetting. The disconnected
  foreground pass now runs the same machinery as the background pass. Also cleaned up:
  after a link loss + reconnect in the disarmed state, a no-longer-observable "armed"
  reminder no longer keeps nagging — it is cleared on the connection reset.
- **FC-read values survive a mid-flight telemetry blip.** A short link loss while armed
  used to throw away everything read from the FC at connect — battery capacity / cell
  count, the FC-config cell thresholds and the governor mode — and the re-read had to
  wait until the disarm: thresholds fell back to defaults, the fuel % lost its basis and
  the *Gov. Off / Limit* stats gate degraded, mid-flight. These caches are now cleared
  only on a **disarmed** disconnect. On top, the connect-time MSP reads are gated by the
  ARM sensor: a blip that reconnects while the model is still flying never fires MSP —
  the read is parked and runs after landing (no-MSP-while-armed, defense in depth).
- **Escalation volume now works for the Telemetry alert.** The volume-override used to
  release the master-volume GVAR on *any* disconnect, so the Telemetry alert's
  *Escalation volume* could never apply — the one alert whose active state IS a
  disconnect. On a link loss **in flight** the boost now holds and the repeats come in
  loud; it ends with the last repeat (*Repeat count*; 0 = until reconnect), handing the
  volume back to the pot / *Normal volume (%)* by itself — also after a crash. Needs
  *Telemetry ▸ Repeat* on (the escalation acts on the repeats — the first announcement
  is already out before the boost can land; that is true for every alert, see
  REFERENCE §5.1). A disarmed disconnect (landing, heli off) still never escalates.
- **Skipped-packets alert: *Vibrate* now fires.** It was the only alert whose
  announcement skipped the haptic pulse — the setting existed but did nothing.
- **Dismissing one alert's fullscreen overlay no longer swallows another alert's
  overlay.** The tap-dismiss is tracked per alert now — e.g. after tapping away a
  Voltage overlay, a Main-power-lost overlay in the same flight still appears.
- **Per-craft configs: a craft change under an open settings page can no longer write
  the old craft's edits into the new craft's file.** The save now re-checks the target
  config before writing.
- **The "settings could not be saved" banner now covers every config write** — including
  the internal snapshot / first-run markers, which used to fail silently — and a failing
  write stops being retried on every pass.
- **Adjustment Editor: the tap lockout follows the configured pulse length.** With a
  long *Adj editor: pulse* a fast second tap could land inside the still-running pulse;
  a new tap is now accepted ~0.1 s after the pulse ends (the fixed 250 ms lockout is
  gone).
- **A Toolbox tool that fails to initialize shows its error on the tool page** instead
  of taking the widget down (the tool init is now error-guarded on every open path —
  menu, shortcut and re-open behave identically).
- **Flight statistics and the flight log now track fully off-screen.** With another main
  screen active, profile changes, the ESC-temperature min/max and the TX-power tracking
  paused, and flight-log arm edges could be missed — off-screen flights were missing or
  shortened in `flights.csv`. The background pass now feeds the same edges and stats as
  the on-screen one.
- **TX battery icon: the percent label stays readable on a dark color override.** The
  label ink now follows the fill's luminance (black on light, white on dark), like the
  fuel gauge's overlay text; the default look is pixel-identical.
- **RF2 Config with no FC connected could trap you.** Opening *Toolbox ▸ RF2 Config* while
  the flight controller was disconnected dropped straight into the stock RF2 runner's
  "connecting" wait screen, which never processes RTN — so you couldn't get back until
  something connected. RF2 Config now checks the link first: with no FC it shows a
  **"No FC connected"** notice (RTN returns to the Toolbox) and opens by itself once the FC
  connects.
- **Menu glyph tap could be dead right after entering full-screen.** The ☰ tap was
  hit-tested only against the built glyph rect, which is `nil` during the staggered
  full-screen-enter build (and the window stretches when a heavy frame — e.g. debug log on —
  starves the rebuild), so the menu wouldn't open until a detail-view visit forced a
  rebuild. Now falls back to a fixed top-left region so the menu opens regardless of build
  timing. *(The underlying debug-log-induced sluggishness is tracked separately.)*
- **Menu glyph stretched on the TX16S MK3.** The fullscreen ☰ settings glyph used a fixed
  20-px width but filled the top bar's height, so on the 800×480 MK3 (tall bar) it drew as
  a stretched vertical rectangle. The box is now **square** and the three bars scale from
  the box height — a clean aspect ratio on both the MK3 and the short 480×320 TX15 bar.
- **Headspeed / current minimum polluted by spool-up ramps** (field report: "always
  starts in P2 — P2 min 500 rpm"). A re-spool after a throttle hold runs in the
  governor's *Recovery* state, which the min/max gate tracked from its first low-rpm
  sample (and the `Hspd` telemetry lags the spool-up→active transition by a couple of
  seconds on top). The **minimum** now only tracks in the steady states (Active /
  Fallback / Bypass) and only after ~2 s of continuous run — ramps and the telemetry
  lag can no longer leave a misleading low min. The **maximum** deliberately keeps the
  broad gate (autorotation / bailout overspeeds stay visible).
- **Leaving fullscreen with the Log Viewer open no longer leaks.** The exit path skipped
  the viewer's cleanup: an open `/LOGS` file handle stayed behind and the ~2000-line
  module stayed resident, whose garbage-collection load measurably slowed the whole UI
  (the ~19 → ~15 Hz class of slowdown). All four tool pages now run one shared close
  path (cleanup + module release) on every way out — RTN, arming, fullscreen exit,
  shortcut close. A bound shortcut switch held in position also no longer loads a tool
  module that its open would then be refused.
- **A shortcut no longer opens a Toolbox tool while not fullscreen.** Tool pages are
  fullscreen UIs; a switch that opened one in normal widget mode built a fullscreen page
  into the small widget zone — the Log Viewer flashed open and shut, the Flight Log threw
  "attempt to index a nil value" (the effect showed up after a reboot, before the tool had
  ever been opened from the menu). Shortcut tool-opens are now gated to fullscreen, exactly
  like the menu path (the menu glyph is fullscreen-only); a held switch opens the tool as
  soon as you are fullscreen.
- **Armed/disarm callout and ESC fault log now run off-screen.** Arming while another
  main screen was active announced "armed" only on the next screen switch, and ESC
  faults that occurred off-screen were missing from the worst-fault latch and event log.
- **A passive view now follows a full scheme change too.** Switching *Color scheme*
  3 → 1 plus save left a passive second-screen instance on the old palette (a style
  signature collision); any scheme/color change now rebuilds passive views.
- **The flight clock stops promptly on a total link loss.** With the RC link positively
  down (RQly 0) EdgeTX serves the last ARM/headspeed values for up to ~30 s until the
  sensors expire — the flight timer (and the flight-log duration) kept counting through
  that window after an in-flight RX/telemetry loss.
- **The skipped-packet sensor follows a model change.** The `*Skp`-vs-`Skp` name choice
  is re-probed on every fresh connect — switching between models with different
  telemetry generations used to silently disable the Skip alert until a Lua reload.
- **Sensor check: no stale green with the FC off, raw slots verified correctly.** With
  the FC disconnected the page now shows "--" chips instead of a stale "OK"; value slots
  picked via the raw source picker are verified by their stored source index (they
  showed a false MISS despite working); a model with old-generation telemetry (`Skp`
  instead of `*Skp`) is recognized; and a mid-view row-set change no longer shifts the
  status badges onto the wrong rows.
- **RTN on a settings submenu page returns to the Settings menu.** On the Telemetry /
  Voice / Shortcuts submenus RTN used to fall through to the dashboard while the back
  arrow correctly returned to the menu — both go to the menu now.
- **A toggle-shortcut switch already "on" at boot no longer auto-opens its page.** The
  first evaluation now seeds the edge detector instead of treating the standing "on" as
  a press (maintained switches).
- **Battery picker: every pack is reachable on the TX15.** The pick list scrolls; packs
  beyond the first ~3 visible rows used to be unselectable on the small screen.
- **ESC-load bar follows the configured current source.** The bar under the Current row
  was tied to the literal `Curr` slot and vanished when *Battery ▸ Current sensor* was
  set to EscI / Iesc.
- **Stats header no longer clips a long FC model name that arrives off-screen.** The
  header font is re-measured when the craft name changes, not just at build time; long
  raw-slot labels in the flight view are also truncated with ".." instead of overflowing.
- **RF2 Config: UltiDash's own connect reads no longer queue into an open tool page**
  (they are parked while the tool owns the MSP queue and run after it closes), and
  framework errors from the embedded tool (restart/registration) are caught into the
  tool's error page instead of taking down the widget state.
- **Sensor reads follow the Rotorflight sensor, not a same-named duplicate or a rename.**
  When you switch a model to custom telemetry but leave the old native CRSF sensors in place,
  EdgeTX ends up with two `Curr` / `Capa` / `Bat%` … sensors, and a name lookup could hit the
  wrong (stale) one — throwing off the fuel callouts, ESC-load and stats. UltiDash now resolves
  its known sensors by their Rotorflight **sensor ID**, so it always reads the right one — and
  a renamed known sensor keeps working and still shows with its friendly label. (Falls back to
  the plain name read on models without custom telemetry — no change there.)
- **Alerts kept working with stale values while another screen was active.** When the
  Dashboard ran in the background (a second screen showing the passive ELRS/Status view),
  the ESC-load, BEC-voltage and link/RSSI warnings evaluated the last on-screen sensor
  readings instead of live ones — so an off-screen ESC-load or BEC drop could go
  unannounced. The background pass now refreshes the same telemetry the on-screen pass
  does before running the alert checks.
- **Toolbox / Adjustment Editor: a pulse could stick when the page was closed mid-pulse.**
  A tap pulses the adjustment GVAR for ~150 ms and then releases it. Leaving the editor
  page (back/RTN, the activation switch, or exiting full-screen) inside that window left
  the GVAR at the trim code — a permanent adjustment command to the flight controller. The
  value channel is now released whenever the editor page closes.
- **Toolbox / Adjustment Editor: a single tap could apply two adjustment steps.** The
  `-`/`+` tap targets now use the same time-based debounce as the rest of the widget, so
  one physical tap = exactly one step (a single tap bounces into several touch events,
  more so on the TX16S). Deliberate fast tapping still works.
- **Wrong arming-disable reason names in the compact status line.** The compact
  `* REASON` arming-disable summary inherited Betaflight legacy names: it showed
  **RUNAWAY** / **CRASH** where Rotorflight means **Governor** / **RPM Signal**, and on
  current firmware a held override read **ARMSWITCH** instead of **Override** (with the
  arm-switch reason missing entirely). The compact line now matches the firmware enum and
  the full reason list on the Status page — both name every reason identically.
- **Cell-check alert: Repeat / Repeat count / Repeat interval / Vibrate now work.** These
  per-alert settings were listed for the startup cell check but had no effect. With Repeat
  on, a not-full pack now re-announces up to the configured count; Vibrate fires if
  enabled. The check clears the repeat when the pack reads full, when a new check starts,
  and on disconnect. The Cell check and Armed/disarm pages no longer show the *Escalation
  volume* toggle — it never did anything for those two one-shot alerts.
- **ESC-load alert is shown in the Status page's repeat summary** (and in "Sounds off"
  while ESC-load monitoring is on) — its repeat was running but wasn't reflected there.
- **Startup cell check now also runs off-screen.** Plugging a battery in while another main
  screen was showing skipped the cell check until the Dashboard was brought back up; it now
  runs in the background pass like the other callouts. It is also no longer silenced by a
  momentary voltage glitch at the moment the check finishes (a transient "main power lost"
  no longer suppresses the low-cell callout, which the off-screen timing made more likely).
- **Config files no longer truncate past ~8 KB.** A config that grew beyond 8 KB (many
  per-alert settings) was read only up to the first 8 KB and the rest was silently dropped,
  losing settings without any error. The whole file is now read.
- **A corrupt config value can no longer crash the widget.** A hand-edited or damaged config
  line that put text where a number was expected could later crash a formatter or a +/-
  stepper; such values now fall back to the default.
- **"CPU limit" errors on busy update cycles / cold boot.** EdgeTX gives a widget a fixed
  CPU budget per call; several things could pile into one call and overrun it, killing the
  widget with a "CPU limit" error: a screen rebuild (view switch, page open/close) landing in
  the same cycle as the telemetry/alert pass; on a cold boot, the first settings-file read
  sharing its cycle with the full UI build (worse with a large config, or with the debug log
  on, which also starts a log session). These one-time / heavy steps now each run in their own
  cycle — in particular the initial UI build is deferred one frame past widget creation, so it
  never shares a cycle with the cold settings read. The first-placement hint is also no longer
  rebuilt once acknowledged. Net effect: a blank frame or two at startup instead of a crash.
- **ELRS "Diversity" no longer reads "yes" on a single-antenna receiver.** The antenna field
  is always present in the link frame (constant 0 without diversity), which made the page
  report "Diversity: yes" for every receiver. It is now reported only once the data proves a
  second antenna and latched for the session.
- **ELRS SNR row is blank in FLRC — and now also FSK/Kernel — modes.** These modulations
  report SNR as a constant 0 (verified against the ELRS signal-health doc and the LR1121
  radio driver), which showed a permanent "0dB" with a yellow bar; the SNR value and bar
  now read "-" in all of them. The FSK mode entries (DK250 / DK500 / K1000) also got their
  official sensitivity floors.
- **A transient connection-handshake state no longer shows an inconsistent state.** During the
  RFTool connect handshake a brief intermediate state could flicker the connection readout and
  skip the one-time battery-profile reset; the connection state is now normalised to the four
  known states, and the profile reset fires on any first connect (including one that settles
  straight into "disarmed").
- **A few rare ELRS 3.x rates show their label instead of "no link".** D50 / DK500 / K1000Full
  now display their rate name (checked against the current ELRS signal-health docs).
- **A passive second-screen view now follows a color override change live.** When the
  Dashboard changed an individual color (not the whole scheme), a passive ELRS/Status
  instance on another screen kept the old color until the scheme was toggled or the radio
  rebooted. Passive views now rebuild on any color change too.
- **Unset colors are no longer written into the model config.** Saving color settings used
  to store all ~57 color slots (as "unset") in every model's cfg file, needlessly bloating
  it; only colors you actually changed are stored now. Tapping *Def* removes a color's
  override from the file again.
- **Dark scheme: the menu/settings pages ignore EdgeTX-theme color overrides.** Because the
  native menu pages can't be repainted dark, they are rendered with the EdgeTX-theme palette
  for readability — but they now use the neutral theme built-ins, not your EdgeTX-theme color
  overrides (which are meant for the actual EdgeTX-theme scheme, not the forced menus).

### Performance
- **~107 kB of cold code moved off the resident Lua heap** (less GC drag on the whole
  UI loop — the same effect that lazy-loading the Log Viewer already proved with a
  measured 15 → 19 Hz recovery). Three steps: (1) the **entire menu/settings UI**
  (menu hub, Toolbox/Settings submenus, all settings pages, sensor check, both battery
  pickers — ~84 kB) now lives in its own module `ultidashMenu.lua`, lazy-loaded when a
  menu opens and released when it closes; (2) the **Adjust Map / Adjust Edit** toolbox
  tools are lazy-loaded/released like the other tools instead of boot-resident (their
  shared `toolbox/common.lua` data stays resident, so labels overrides survive);
  (3) the **debug logger** `ultidashDebug.lua` loads only when the *Debug log* option
  is actually turned on instead of always. Behaviour and looks are unchanged; opening
  a menu now includes a one-time module compile (imperceptible next to the page build).
  Follow-up: the **12 alert settings pages** now build their row tables lazily on
  first open (like the Shortcuts and Colors pages) instead of eagerly at module load —
  together these steps cut the measured `create()` instruction cost from ~15.1k to
  ~13.9k of the 20k budget.
- **The permanently visible views stopped allocating per frame.** The passive Status
  view (the heaviest: ~15 value closures plus a rebuilt "sounds off" list on every LVGL
  frame at ~20 Hz), the Telemetry-detail min/max texts, the eStatus Gov/Throttle lines
  and the Log Viewer's footer/filter rows are all memoized now — text is rebuilt only
  when a value actually changes. Pixel-identical, steady GC pressure gone. The radio's
  general settings (TX battery limits) are also read once per 10 s instead of per pass.
- **The budget check now measures the historically risky paths.** `tools/check_budget.lua`
  runs every settings group, the submenus, the detail pages, sensor check and toolbox
  menu, plus a connected-FC pass with a legacy-cfg migration fixture, and reports
  per-chunk module-load costs — the class of overrun that used to surface as a "CPU
  limit" crash on the radio now shows up on the PC first.
- **Settings pages open comfortably within the instruction budget again.** Copying the
  saved settings into a page's edit buffer used to run in the same call as the page
  build — the heaviest first-opens (Colors) measured ~16.5k of the ~20k budget. That
  seeding now runs in its own invisible frame, and the sensor-check page builds its rows
  in a separate cycle from its first scan (a brief "Scanning…" shows instead); the
  periodic sensor re-scan got its own exclusive cycle too. The budget harness now also
  charges the seeding to **every** page's first open (it used to hit only the first page
  measured, hiding ~7k on the rest).
- **Fewer sensor lookups per update pass.** Each telemetry sensor is now resolved at most
  once per 5 Hz pass (a shared per-pass cache), instead of several callers each doing their
  own name lookup — the name lookup is the expensive part, and piling them up used to
  starve the Lua scheduler enough to make full-screen taps laggy. The battery latch/fuel
  bookkeeping also runs exactly once per pass now. The background (off-screen) pass is
  throttled to the same cadence as the on-screen one. No behaviour change.
- **Less per-frame text churn.** The bottom status bar, the stats headspeed rows, the
  detail-page footers/legends and the ESC-status / arming-reason strings now re-format only
  when their value actually changes, instead of rebuilding the text on every display frame.
  The activation-switch poll moved into the throttled pass. Smoother frame timing,
  especially on the TX15; nothing shown changes. No behaviour change.
- **Toolbox tool pages: fewer per-frame reads.** The Adjustment Map/Editor now resolve the
  active 6-position bank once per cycle instead of on every reactive label each frame, and
  the two tools share one code module (single source for the trim mapping / `labels.lua`
  overrides). No behaviour change.
- **Color palette resolved less often.** The per-scheme built-in colors and the config-key
  strings are now computed once and reused instead of being rebuilt on every UI redraw, and
  the effective palette is memoised until the scheme changes or you save a setting. The
  Colors settings pages are also built only when first opened, keeping them off the startup
  instruction budget. No behaviour change.

## v0.5.2 — 2026-07-12

Maintenance release on top of v0.5.1 (backport from the 0.6.0 line).

### Added
- **Governor-mode aware statistics.** UltiDash now reads the FC's governor mode at
  connect (`mspGovernorConfig`, MSP — connect/disarm only). In governor modes
  **OFF / LIMIT** the firmware never updates the `Gov` state sensor, which used to keep
  the headspeed/current min-max tracking from ever engaging; in those modes the tracking
  now falls back to **armed + rotor spinning** (`Hspd > 100 rpm`; armed-only without an
  `Hspd` sensor) and the governor slot shows **Gov. Off / Gov. Limit** instead of the
  misleading *Throttle off*. Setups with a running governor (DIRECT / ELECTRIC / NITRO)
  are unchanged; without a readable governor config (old RFTool) the previous strict
  gating remains.

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
