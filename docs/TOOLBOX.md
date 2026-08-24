# UltiDash Toolbox — RF adjustment Map & Editor

> **Status: experimental / WIP** — integrated from the standalone *RFAdjMap* / *RFAdjEd*
> widgets into UltiDash as on-demand **Toolbox** pages. Under active hardware testing;
> details (appearance, configurable sources, recommended-value hints) may still change.

The Toolbox hosts full-screen tool pages. This document covers the two pages for
Rotorflight's **trim-based adjustment functions**:

- **Adjust Map** — *read-only*. Shows which adjustment function each trim maps to (per the
  6-position selector) plus the last value the FC reported.
- **Adjust Edit** — the same table with touch **`[-]` / `[+]`** buttons that perform an
  adjustment step (by pulsing a GVAR). Meant for **in-flight tuning**.

Open them from the fullscreen menu (**☰ → Toolbox**, disarmed only) **or** via a
**shortcut switch** that works any time, including in flight (see §5).

Five further, zero-config pages live in the same Toolbox submenu — the **Log Viewer**,
**RF2 Config**, **RFSuite**, the **Flight Log** and the **FC battery profile** picker —
described briefly in §8.

---

## 1. Concept

Rotorflight binds **adjustment functions** to the six trims (Pitch / Roll / Yaw / Throttle
/ Trim 5 / Trim 6). A **6-position selector** chooses which of six functions a trim
controls — the columns **P / I / D / F / O / B**. The tools need two things from the radio:

| Signal | What it is | Default source |
|--------|-----------|----------------|
| **Config** | the 6-position selector (which column P…B is active) | `ch11` |
| **Value channel** | a channel encoding *which* trim is pressed | `ch12` |

plus optional telemetry (§4).

The two **channels are configurable** in *Settings ▸ Toolbox* (*Adj: Config channel* /
*Adj: Value channel*, defaults CH11 / CH12). The telemetry sensor names (`AdjV`, `PID#`)
are fixed — they are the Rotorflight standard.

> **The Toolbox is entirely optional.** Without the model setup below the tool pages
> simply stay inactive; the rest of UltiDash is unaffected.

## 2. FC side — Rotorflight adjustment functions

In the Rotorflight Configurator, set up the **Adjustment Functions** so each trim (per the
6-pos selector position) changes the intended parameter. The Toolbox's table assumes the
standard Rotorflight layout:

| Trim | P | I | D | F | O | B |
|------|---|---|---|---|---|---|
| Pitch | Pitch P | Pitch I | Pitch D | Pitch F | Pitch O | Pitch B |
| Roll | Roll P | Roll I | Roll D | Roll F | Roll O | Roll B |
| Yaw | Yaw P | Yaw I | Yaw D | Yaw F | Gov Cyc FF | Yaw B |
| Throttle | Gov P | Gov I | Gov D | Gov F | Gov Col FF | Gov Gain |
| Trim 5 | Yaw CCW | Yaw Cyc FF | Resc Climb Col | — | — | Gov Headspeed |
| Trim 6 | Yaw CW | Yaw Col FF | Resc Hover Col | — | — | — |

> **The whole mapping is freely yours.** The table above is only the **default** layout —
> on the FC you can bind *any* adjustment function to *any* trim/position (your own
> `adjfunc` config), and the tools' displayed table follows via **custom labels**: every
> cell and the column shortcuts are overridable, cells can be emptied (see §6). The CLI
> example below just implements this default.

### 2.1 Example — paste-able CLI config

**[`examples/rf_adjfunc_example.txt`](examples/rf_adjfunc_example.txt)** is a complete
`adjfunc` CLI block that implements the mapping above (all 6 selector positions, all 6
value rows, enable/value windows matching the channel setup in §3). Paste it into the
Rotorflight CLI and `save`.

> ⚠️ **Before pasting, check your existing adjustment functions.** The example uses the
> `adjfunc` **slots 2…31** — pasting it **overwrites** whatever those slots hold. If your
> model already uses adjustment functions, move the example to **free indices** (the
> first number in each line). Also verify the two **channel indices** in the example
> match where your Config/Value channels (§3) arrive on the FC (receiver channel map).

## 3. EdgeTX model setup (once per model)

### 3.1 The 6-position Config channel (default CH11, configurable)
Drive a channel from a 6-position source (a 6-pos switch, or two switches combined, or a
pot in 6 steps) so its value steps evenly across −1024 … +1024 → mapped to **Pos 1…6 =
P/I/D/F/O/B**. Set *Adj: Config channel* to the channel you used.

**Example (working model, no 6-pos switch needed):** combine a 3-position switch with a
2-position switch — three mixer lines on CH11:

| # | Source | Weight | Mode | Switch |
|---|--------|--------|------|--------|
| 1 | `SB` (3-pos) | 40 | ADD | — |
| 2 | `MAX` | +60 | ADD | 2-pos switch, position A |
| 3 | `MAX` | −60 | ADD | 2-pos switch, position B |

→ the six evenly spaced values **−100 / −60 / −20 / +20 / +60 / +100 %** = Pos 1…6
(these are exactly the enable windows the CLI example in §2.1 expects).

### 3.2 The Value channel (default CH12, configurable via *Adj: Value channel*)
Encode *which* trim is pressed as a distinct magnitude on this channel:

| Trim | Row | Magnitude |
|------|-----|-----------|
| Pitch | 1 | ±90 % |
| Roll | 2 | ±75 % |
| Yaw | 3 | ±60 % |
| Throttle | 4 | ±45 % |
| Trim 5 | 5 | ±30 % |
| Trim 6 | 6 | ±15 % |

**Example (working model):** one `MAX` mixer line per trim direction on CH12, each gated
on the trim switch, **Replace** mode (first line Add), weight = the row's magnitude:

| Source | Weight | Mode | Switch |
|--------|--------|------|--------|
| `MAX` | −90 | ADD | Trim Ele down |
| `MAX` | +90 | REPL | Trim Ele up |
| `MAX` | −75 | REPL | Trim Ail left |
| `MAX` | +75 | REPL | Trim Ail right |
| `MAX` | −60 | REPL | Trim Rud left |
| `MAX` | +60 | REPL | Trim Rud right |
| `MAX` | −45 | REPL | Trim Thr down |
| `MAX` | +45 | REPL | Trim Thr up |

The example wires the four stick trims (rows 1–4); extend the same pattern with
±30 / ±15 for Trim 5 / Trim 6 if your radio has them. *(Optional guard from the same
model: one more `MAX / 0 / REPL` line on a switch position that forces the channel to 0
while the tools are not in use.)*

> ⚠️ **Switch the trims themselves OFF.** These lines are gated on the trim **buttons**, not
> on the trim **values** — so unless trimming is disabled, every tuning press *also* trims the
> corresponding flight axis. In EdgeTX: **Model ▸ Flight Modes ▸ FM0 ▸ Trim** = off for all six
> (Ele / Ail / Rud / Thr / T5 / T6). The working model above has all six off.
>
> And claim each trim **once**: a trim button used by a line here must not drive anything else
> as well, for the same reason the Editor's GVAR has to be dedicated (§3.3).

### 3.3 Editor — the GVAR mixer line
The Editor performs a step by briefly **pulsing a dedicated GVAR** onto the value channel
and back to 0; the FC then adjusts exactly as if you pressed that trim.

One-time mixer line **on the value channel** (e.g. `CH12`):
- **Source = MAX**, **Weight = GVx** (Add / `+=`), with **GVx idle = 0**.
- The GVAR is used as a **percentage weight**, so its value range must cover the per-trim
  magnitudes (**±90**): set the GVAR's **min/max to ≈ −100 … +100** and unit **`%`**. The
  Editor writes ±90 / 75 / 60 / 45 / 30 / 15 into it per row, so a `[+]`/`[-]` tap equals
  one trim step up/down.
- Set the **`Adj editor: GVAR`** (`TbGvar`) option to that GVAR number (**GV1…GV15** — fully
  configurable in Settings ▸ Toolbox).

`Adj editor: pulse (ms)` (`TbPulse`, default 150) sets the pulse length. The GVAR must be
**dedicated** (used only in this mixer line) — pulsing it in flight then only drives the
adjustment, never control.

**Example (working model):** `MAX / weight = GV1 / ADD`, additionally **gated on a
dedicated switch** in the mixer — the pulse can only reach the value channel while that
switch is on (a cheap extra safety on top of the dedicated GVAR). You can reuse the same
switch you bind to open the editor under *Settings ▸ Shortcuts* (§5).

## 4. Telemetry (optional but recommended)

| Sensor | Purpose | Default |
|--------|---------|---------|
| `AdjV` | the new value the FC reports after an adjustment | `AdjV` |
| `PID#` | active PID profile (separate value store per profile) | `PID#` |

Connection is taken from **UltiDash's own link state** (no separate heartbeat sensor
needed): the reported value (`AdjV`) is only latched while the FC is connected.

## 5. Opening the tools — menu or a shortcut switch

- **Menu:** ☰ menu glyph (disarmed) → **Toolbox** → **Adjust Map** / **Adjust Edit**. Back =
  **RTN**. Since 0.8.0 the Toolbox page groups its tiles by what the tool is *for* —
  **Adjustments** (Adjust Map, Adjust Edit) · **Logs** (Log Viewer, Flight Log) · **Flight
  controller** (RF2 Config, RFSuite, Battery profile) — and lays them out in two columns
  where the
  screen is wide enough, which is what pays for the three headings: on a 480×272 MK2 the six
  tiles in one column already ran past the bottom of the page.
- **Shortcut switch (recommended for flight):** under *Settings ▸ Shortcuts* (REFERENCE §2.7c)
  bind a switch position — or a toggle step — to *Adjust Map* / *Adjust Edit* (or any other
  page). A **position slot** opens the tool while the switch is held there and closes it when
  you leave the position — **also while armed / in flight** (the menu glyph itself is
  disarmed-only). The pickers use **EdgeTX's native switch picker** (physical + logical
  switches, incl. the `!…` inverted variants), so they show exactly the switches your radio
  has, with their custom names.

  The tool page is **active whenever it is open** (there is no separate switch-gated
  "CONFIG INACTIVE" mode any more — the earlier Toolbox activation switch was folded into
  the Shortcuts group). Keep the value channel's mixer gated on a switch (§3) if you want an
  extra guard against unintended pulses.

## 6. Settings reference (Settings ▸ Toolbox)

| Setting | Key | Notes |
|---------|-----|-------|
| Adj table from | `TbSource` | where the displayed table comes from: **Manual** (the built-in table + `labels.lua`, today's behaviour) · **Flight controller** · **FC + labels.lua** (the FC's table with your `labels.lua` overrides on top). See *The FC-served table* below |
| Adj: Config channel | `TbConfigCh` | the 6-position selector channel (default CH11) |
| Adj: Value channel | `TbValueCh` | the trim-magnitude channel (default CH12) |
| Adj editor: GVAR | `TbGvar` | the GVAR pulsed by the editor (GV1…GV15) |
| Adj editor: pulse (ms) | `TbPulse` | pulse length per step; the editor's `[-]`/`[+]` tap lockout follows it (a new tap is accepted ~0.1 s after the pulse ends) |
| Adj value divider | `TbScale` | divides the displayed `AdjV` |
| Adj editor: ranges hint | `TbBert` | show recommended value ranges next to each name |
| Toolbox sunlight mode | `TbSun` | high-contrast light scheme for bright sun |
| Announce bank (voice) | `TbVoice` | speak "Bank N" (the active Config-channel position) on open + on change; **off** silences it entirely |

**The announcement waits for the knob to settle.** Each one queues two clips and EdgeTX
offers Lua no way to flush the sound queue, so speaking every position a sweep passes
through used to chain them all: turning the Config channel from bank 1 to bank 6 spoke six
announcements over the next several seconds. A bank now has to hold for **0.3 s** before it
is spoken, and two announcements keep at least **1.5 s** apart — so a sweep says its
destination and nothing else, while an ordinary single change speaks with no delay worth
noticing. A position between the FC's windows (see *The FC-served table*) stays silent and
does not consume the announcement: the next real bank is still spoken.

The tool pages follow the **active skin's colour scheme** (*Settings ▸ Skin ▸ Color
scheme* — for the built-in UltiDash look: *UltiDash* / *UltiDash dark* / *EdgeTX theme*);
the sunlight option overrides to a high-contrast light scheme. **The two curve pages — Log
Viewer and Live Monitor — pick their curve colours from that same scheme**, a bright set on
a dark background and a deeper set on a light one, so a curve is never a pale line on white.
The
per-session values shown in the tools are **cleared on every fresh (re)connect** so they
start empty again.

**Custom labels — the table is fully rebuildable:** if your FC adjustment mapping differs
from the default in §2 (it may be *completely* your own), copy
`WIDGETS/UltiDash/toolbox/labels.example.lua` to `…/toolbox/labels.lua` and edit it:
**every cell** (function name per trim row × position 1…6) and the **column shortcuts**
(`sub`, default P/I/D/F/O/B) can be overridden, unused cells emptied with `""` (removes
the editor's `[-]`/`[+]` there). Overrides are **partial** (set only what differs), apply
to **both** the Map and the Editor, and `labels.lua` is never touched by updates.

The same file may carry a **`ranges` block** to override the editor's recommended-value
hints (`TbBert`) for your own setup: same shape as the table — `ranges = { [row 1…6] =
{ [pos 1…6] = "text" } }`, partial, strings only, `""` blanks a hint. Example:

```lua
return {
  rows   = { [5] = { [1] = "Gov TTA" } },          -- rename a cell
  ranges = { [5] = { [1] = "0-50" } },             -- give it a range hint
}
```

### The FC-served table (`TbSource` = *Flight controller* / *FC + labels.lua*)

With one of the two FC states selected, UltiDash reads the craft's **own `adjfunc`
configuration** over MSP **once per connect** (about 4–7 s, during which the telemetry
sensors pause — the read runs at plug-in, and *only* when this option asks for it;
on *Manual* nothing is ever read). It **queues behind the connect reads**, never ahead of
them: the flight controller's battery configuration (cell count, full-cell voltage) has to
land first, because the startup cell-check needs it seconds after the pack is plugged in.
The tools then rebuild their table from the answer:

- **Cells and columns follow the craft.** Where the craft carries the standard layout the
  table looks exactly like the built-in one; a custom `adjfunc` setup shows *its* functions,
  named from a built-in table of all 83 adjustment functions. With *FC + labels.lua* your
  `labels.lua` renames apply on top; with plain *Flight controller* they do not.
- **The bank comes from the FC's real enable windows**, not from an even six-way split of
  the Config channel. The standard windows leave five dead gaps between banks — a selector
  sitting in a gap now reads **`Pos -`** (no bank, no live cell) instead of the nearest
  bank. This also removes the edge error near every window boundary.
- **A cell the editor cannot drive shows no `[-]`/`[+]`** — a slot whose adjust channel is
  not the configured Value channel would get buttons that do nothing.
- **menu ▸ Status ▸ Adjust table** names the source actually in force: the option can say
  FC while a failed or not-yet-run read leaves the manual table in use (after a read
  failure the tools fall back rather than showing an empty grid).
- The `ranges` hints (`TbBert`) stay **positional** (row × position), whatever the source —
  they describe the standard layout unless your `labels.lua` overrides them.

## 7. Known limitations / WIP

- The telemetry sensor names are fixed to the Rotorflight standard (`AdjV` / `PID#`);
  the two channels are configurable (§6).
- The **recommended value ranges** (`TbBert`) ship as defaults that are still under
  review; a `labels.lua` `ranges` block overrides them per setup (§6).
- Appearance (fonts, column widths) is not final.
- **GVAR residual risk (theoretical):** if the radio's Lua state dies *exactly* inside
  the ~150 ms editor pulse window (power-off at that instant), the GVAR could stay at a
  trim code. The editor defensively zeroes the GVAR every time it is opened, and closing
  the page (RTN, switch, arming, fullscreen exit) always ends an in-flight pulse — the
  switch-gated mixer line (§3.3 example) covers the remaining window.
- Safety model: the tools use only `getValue` + `model.setGlobalVariable` — **no MSP** — so
  the "no MSP while armed" rule is untouched; the FC's adjustment functions (your model
  setup) perform the actual change.

## 8. The other Toolbox pages: Log Viewer, RF2 Config, RFSuite, Flight Log, Battery profile & Live Monitor

The first four need **no model setup and no settings** and are **disarmed-only** (an armed
tap is refused with a hint; they close automatically on arming). The **Live Monitor** at the
end of this section is the exception — in-flight use is its purpose. All the big ones are
**lazy-loaded**: the modules are read from the SD card only when the page is opened and
released again on close, so they cost no memory while flying.

- **Log Viewer** *(WIP)* — graphs EdgeTX telemetry logs (`/LOGS/*.csv`) directly on the
  radio, no PC needed. Uses no MSP at all. Still under hardware testing.

  **Workflow:**
  1. **Browse** — the file list shows only real telemetry logs (`<model>-YYYY-MM-DD…csv`),
     newest first, for **all models by default**. The header button (top-right) shows the
     active filter and opens the **Filter by model** page: every model name found in
     `/LOGS` with its log count, plus *All models* — tap one to filter the list. Scroll
     by **swiping** or dragging the list (the scrollbar on the right is a position
     indicator). The list keeps the **newest 600** logs; with more files in `/LOGS` the
     oldest are dropped and the footer appends *"(list truncated)"*. *(The hardware wheel
     does not scroll here yet — EdgeTX only delivers wheel events to a focused LVGL
     object, and this page has none.)*
  2. **Open** a log (tap). A progress bar shows the parse (all file work is chunked, so the
     radio stays responsive); **RTN** cancels.
  3. **Pick what to display.** If the log has several recording **sessions** (gaps > 30 s),
     you choose one first. Then the **"What to display?"** page shows a **two-column card
     grid** with a card for each built-in set — **Power / Battery / RF link / Governor** —
     (each showing how many of its sensors the log contains; a set with none is
     dimmed), plus a **Custom sensors** card. Custom opens a sensor
     picker that groups every column in the log **exactly like the Rotorflight
     Configurator's Telemetry Sensors dialog** (Battery, Voltage, Current, Temperature,
     ESC #1 / ESC #2, RPM, Barometer, Gyro, GPS, Status, Profile, Control, System, Debug —
     plus RF-link, stick, switch and channel groups for the radio-side columns). Groups
     start **collapsed**, each with a *selected / available* count; tap a group header to
     fold it open. Each sensor row has an **on/off toggle switch** — tap to select, up to
     **4**. A **List / Grid** toggle (top-right, like the configurator's Sort/Select) swaps
     the roomy one-sensor-per-row layout for a compact multi-column grid. Tap **Show** to
     graph the set.
  4. **Chart.** Up to 4 min/max envelope curves, a scaled time axis, and a **time cursor**
     you drag with a finger (the footer reads out each curve's value there). Zoom with the
     **− / +** buttons — **100 %** resets to the whole session in one tap — and pan with
     **< / >**; a thin bar along the chart's top edge shows re-loading while a new zoom/pan
     window is extracted (the old curves stay up meanwhile). The template and session
     selectors are bordered **header chips**: tap the template chip to re-pick the display,
     the session chip to switch session. **RTN** steps back: chart → picker/browser →
     Toolbox.

  **Own templates — made on the radio.** The card page is also the manager. Tap **Edit**
  (top-right) and a card tap opens its actions instead of applying it:

  | | built-in card | own card |
  |---|---|---|
  | Rename | – | ✓ |
  | Duplicate | ✓ | ✓ |
  | Delete | – | ✓ (asks first) |
  | Move forward / Move back | – | ✓, one position at a time in **list** order |

  Create one in the **sensor picker**: pick your set and tap **Save** (next to *Show*) — it
  saves *and* displays. The name is proposed from the picked sensors and can be typed over;
  saving under a name that already exists asks **"Replace X?"**, and that overwrite *is* how
  you change a template. Names are capped at **16 characters**, which is the longest a card
  can show on the smallest radio whatever the name is made of. At most **24** own templates.

  The four built-ins (*Power / Battery / RF link / Governor*) are part of the program: they
  cannot be renamed or deleted. Two ways round that — **Duplicate** one and edit the copy, or
  switch **Hide built-ins** on in Edit mode to take all four off the page.

  **Where it lives:** `WIDGETS/UltiDash/cfg/logtemplates.lua`. The widget owns that file and
  rewrites it whole, so hand-written comments in it do not survive a save. Deploying UltiDash
  never touches it. An older `toolbox/logtemplates.lua` from before 0.7.0 is **adopted once**
  into the new location on the next open and then ignored; the old file is left where it is.
  You can still stock the new file from a PC — the format is unchanged — but the radio is the
  maintainer from then on.

  **No restart is needed** to pick up template changes: close and reopen the Log Viewer.

  **Standalone access — the EdgeTX Tools menu.** The Log Viewer is also reachable without the
  dashboard: **SYS ▸ Apps ▸ UltiDash Log Viewer**. It is the *same* viewer — one file, the
  same templates, the same charts; the Tools entry is only a launcher
  (`SCRIPTS/TOOLS/udlogview.lua`) for the installed
  `WIDGETS/UltiDash/toolbox/logview.lua`. Three properties of that route are EdgeTX's, not
  ours, and are stated rather than worked around:

  - **UltiDash is not running while the tool is open.** EdgeTX suspends widget scripts for the
    duration of *any* Tools script — no callouts, no announcements, no flight-log capture. That
    is the menu's doing and applies to every tool in it.
  - **No auto-close on arming.** Opening a Tools script is your own decision, and there is no
    widget left running that a gate could protect; the viewer reads log files and nothing else.
    The Toolbox entry inside the widget keeps its arm-close unchanged.
  - **UltiDash has to be installed on the same card.** The launcher loads the widget's own
    module and the templates live in the widget's `cfg/`. On a card without UltiDash the entry
    opens a page saying so instead of failing.
  - **It wears the RADIO's theme, not your UltiDash colour scheme.** A Tools script has no
    widget behind it and therefore no model configuration to read a scheme from, so the
    standalone viewer builds its palette — and its curve colours — from the EdgeTX theme the
    radio is running. The same viewer opened from *Toolbox ▸ Log Viewer* follows the UltiDash
    scheme as before, so the two look different on purpose. For the same reason the Toolbox
    *sunlight mode* option has no effect here: switch the radio to a light theme instead.
- **RF2 Config** — runs the **original rotorflight-lua-scripts configuration tool**
  (main menu, all config pages, Save, the Reload/Reboot popup) with its original look,
  navigation and key handling, inside UltiDash's fullscreen. Nothing is copied: the
  stock scripts load from `/SCRIPTS/RF2/` on the SD card, so updating the Rotorflight
  Lua suite updates this page too. Requirements: the **RF Tool widget** must be placed
  and connected (it provides the `rf2` runtime), and the RF2 scripts must be present /
  compiled (RF Tool does that on its first run) — otherwise the page shows what is
  missing. RTN walks back exactly like the original (page → main menu → Toolbox).
  If the FC disconnects **while a config page is open**, the stock tool falls back to its
  original "waiting for connection" screen, which does not process RTN — leave fullscreen
  or reconnect the FC to get out.
  Unlike the standalone tool it is blocked while armed (UltiDash's
  no-MSP-while-armed rule).
- **RFSuite (exp.)** *(0.8.0, optional and **highly experimental** — the tile only appears
  if the adapter is installed)* — runs
  the **RFSuite for EdgeTX** configuration suite (`rotorflight-lua-edgetx-suite`) inside
  UltiDash's fullscreen, the same way *RF2 Config* runs the classic tool. Nothing is copied:
  the suite loads from `/SCRIPTS/TOOLS/rfsuite-core/` on the SD card, so updating RFSuite
  updates this page. **RFSuite is a separate, optional install and does not replace RF Tool** —
  UltiDash reads the flight controller through RF Tool's `rf2` runtime either way. Without the
  suite on the card the tile opens a page that says so and what to do about it.
  Disarmed-only, force-closes on arming, RTN walks back through RFSuite's own navigation.

  **The tile carries `(exp.)` and the page in front of it says why.** Tapping it shows
  *HIGHLY EXPERIMENTAL* with the two effects below, and only the **Open anyway** button
  loads the suite; RTN goes back to the Toolbox. That page appears **every time** — there is
  no setting to switch it off — because once RFSuite is up it paints the whole screen itself
  and nothing of UltiDash's is left on it to carry a marker.

  Two things are worth knowing before you rely on it, and both come from how EdgeTX runs Lua
  rather than from either project:

  - **Pages can stutter, and one may go blank.** EdgeTX gives a *widget* 20 000 instructions
    per call and kills the call at that point; a **standalone Tools script** is suspended and
    resumed instead, with no such ceiling. RFSuite's pages are written for the second regime,
    so running them here means some page builds are cut short. UltiDash retries rather than
    closing the tool, and pages then finish across several passes — but if the cut lands in
    the middle of a page's own redraw, RFSuite loses the redraw request and **the page stays
    blank**. **RTN still works**, so you are never stuck; reopen the page and it usually
    comes up. You may also see EdgeTX print its own
    *“Error in widget UltiDash widget function: CPU limit”* line while a heavy RFSuite page
    is open. It is **cosmetic**: the next widget pass starts with a fresh budget and the
    dashboard carries on. UltiDash cannot suppress it — EdgeTX clears the counter only when
    a call *begins*, so once it has fired, anything still running in that same call can fire
    it again where no error handler of ours can reach.
    Running RFSuite from EdgeTX's own *Tools* menu is not affected by any of this.
  - **It costs memory while it is open.** The suite's module graph lands in the shared widget
    Lua state — measured at ~0,7 MB — and closing the page gives roughly two thirds of that
    back. Open it when you need it rather than leaving it open.
- **Flight Log** — browses the flight history UltiDash records on the SD card, and since
  0.8.0 **edits the battery registry** there too. Drawn in the same detail-page style as
  the other tools (own header, the three tabs as chips, palette-matched); every tappable
  row ends in a `>` chevron and **all three tabs are tappable**:
  **Flights** (date / model / battery / duration; tap a row for the per-flight stats
  detail), **Models** (flights + total time per model; tap a row to filter the Flights tab
  to that model — a header chip shows and clears the filter, the footer counts
  `N of M flights`) and **Batteries** (per-pack cycle counts from `batteries.cfg`; tap a
  pack for its detail page with **Edit** / **Delete**, **+ New** in the header creates
  one). The same create form opens from the battery query's **+ New battery** button —
  the moment an unknown pack is plugged in at the field — with *models* preset to the
  connected craft.

  The editor performs **line surgery**: only the edited pack's line is rewritten, atomically
  — comments, unknown fields and every other line stay byte-identical, so a hand-maintained
  file survives radio edits. A registry **larger than 64 KiB** is refused for editing with
  a visible message (viewing works; tend a file that size on the PC). Renaming an id never
  rewrites `flights.csv` — the editor warns with the flight count instead. Everything here
  is **disarmed-only**; arming closes every page and discards an open form.

  One caveat for users of the Radio Sync Tool (EdgeTX Toolsuite): its `batteries` merge has
  so far only ever seen radio-side *cycle stamps* — **a pack deleted on one radio may come
  back after a sync** until the sync tool's deletion handling is verified, and two radios
  creating packs between two syncs can mint the same id for different packs (the sync tool
  should report that rather than merge silently). Both are recorded as open items there.
  The data files, the battery registry format and field rules, and the related
  settings are described in **REFERENCE §12** (Flight log & battery management).
- **Battery profile** — switches the **flight controller's** active battery profile (1…6),
  showing each profile's configured capacity where the FC reports one. This is the one page
  in UltiDash that *writes* to the flight controller, so it is gated twice: **disarmed** and
  **MSP connected**. Unavailable in either state the tile is dimmed and does not open.

  It is also reachable by tapping the **B-Profile** field on the dashboard — but only if the
  active layout offers that tap zone, which is why the entry exists here as well: a layout
  must not be able to remove a host feature. A **switch shortcut** can open it too
  (REFERENCE §2.7c). Whichever route is used, the profile is re-read from the FC on open, so
  the list never shows a value cached at connect time. The back arrow returns to the Toolbox
  when it was opened from here, and to the dashboard otherwise; picking a profile always
  closes to the dashboard.

- **Live Monitor** — up to **4 sensors as live curves** of the last **15 / 30 / 60 s**:
  stacked full-width strips, each a 0.2 s **min/max band** with the sensor's current value
  and the window's min/max as numbers, auto-scaled with a noise floor. Configure the sensors
  under *Settings ▸ Telemetry ▸ Live monitor* (REFERENCE §2.3b); the window is switchable on
  the page (the bordered chip, top-left).

  **The arm marker** is a vertical line in the page's accent colour, standing in the curve
  areas of every strip (it stops short of the label lines). It marks the moment you armed,
  so it **travels left with the data** and disappears once that moment has scrolled out of
  the window — a line that is not there simply means you armed longer ago than the window
  is long.

  **In flight is the point**: like the two adjustment tools it opens armed, does not
  auto-close on arming, and uses **no MSP** — it reads EdgeTX telemetry sources only. The
  recorder runs in the widget itself, page open or not, so opening the page *after* a
  manoeuvre shows the manoeuvre; what it cannot show is a peak shorter than the sensor's own
  telemetry interval (that never reaches the radio at all), and sampling is coarser while
  another screen is shown. With no sensor configured the whole feature is off and costs
  nothing. `menu ▸ Status ▸ Live monitor` shows the recorder's actual state.
