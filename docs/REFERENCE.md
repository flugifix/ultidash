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
| `ultidash.lua` | UI build (all views + detail pages + settings menu), lifecycle (create/update/refresh), touch handling |
| `ultidashFunctions.lua` | Telemetry updates, battery logic, callout engine, switch voices, eStatus, shared-state publisher |
| `ultidashValues.lua` | Value table with formatting/color getters |
| `ultidashRf.lua` | RF service: connection state, MSP (battery profile, flight statistics) |
| `ultidashOptions.lua` | The single EdgeTX widget option (`ViewMode`) |
| `ultidashSettings.lua` | Per-model settings store (SD-card cfg files) — the in-widget settings overlay |
| `ultidashEsc.lua` | Multi-vendor ESC status/fault decoder (from eStatus) |
| `ultidashDebug.lua` | Optional SD-card debug logger (see §11) |
| `toolbox/adjmap.lua`, `toolbox/adjed.lua` | Toolbox tool pages: RF Adjustment Map / Editor (see §2.7b and [TOOLBOX.md](TOOLBOX.md)) |
| `toolbox/labels.example.lua` | Optional custom adjustment-function labels (copy to `labels.lua`) |

---

## 2. Configuration

### 2.1 The only EdgeTX widget option: `ViewMode`

| Option | Type | Default | Values | Meaning |
|--------|------|---------|--------|---------|
| **ViewMode** | CHOICE | Dashboard | Dashboard / ELRS details / Status info | What this widget **instance** shows |

- **Dashboard** — the full widget (flight/stats views, all detail pages, the settings
  menu, all sounds, MSP). Place **exactly one** Dashboard instance.
- **ELRS details / Status info** — passive views for a **second instance on another
  screen**. They run no MSP, no audio and no statistics; they mirror the Dashboard
  instance's data through a shared (module-local) state. While no Dashboard instance is
  running they show a "No Dashboard instance running" notice. They also inherit the
  Dashboard's color scheme and background.

Everything else is configured **inside the widget**, not in the EdgeTX option list.

### 2.2 The in-widget settings menu

1. **Long-press** the widget → **Full screen**.
2. Tap the **☰ menu glyph** (top-left, before the clock) — **disarmed only** (no config
   in flight). The tap target is the whole top-left corner.
3. Menu entries (laid out as a button grid): **Settings**, **Status**, **Toolbox**
   (opens the tool pages, §2.7b), **Reset settings to defaults** (with a confirmation
   dialog).

**Settings** opens a **submenu** of the configuration groups (also a grid) — pick one to
open its page; its back arrow returns to the submenu. Groups: **Display**, **Tele Main**,
**Tele Details** (§2.3a), **Battery**, **Thresholds**, **ESC load** (§2.5a), **Volume**
(§2.6), **Alerts** (§2.6a — itself a submenu with one page per alert), **Switch voice**,
**General** (§2.7a), **Toolbox** (§2.7b). Bools are real toggle switches, multi-value
options are dropdown pickers, numbers use −/+ buttons (long-press = bigger step), the two
volume percentages are real sliders. Edits are **saved automatically** when a page is left
(back arrow or **RTN**); arming or leaving full-screen also saves. Each group page also
has a **Reset <page> to defaults** button (with confirmation) that resets only that page's
settings; the menu-level *Reset to defaults* resets the whole model.

### 2.3 Settings — Display

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Top-left shows** | choice | Model image | Model image / Timer |
| **Top bar clock** | choice | Time only | Date + time / Time only |
| **Timer (for top-left)** | num | Timer 1 | which model timer when *Top-left = Timer* |
| **Color scheme** | choice | UltiDash | UltiDash (fixed built-in palette) / EdgeTX theme / UltiDash dark (high-contrast white-on-black with neon accents) |
| **Fill background** | bool | on | fill the panel background color |
| **Stats page** | choice | On disconnected | Never / On disarmed / On disconnected |
| **Voltage shown as** | choice | Cell voltage | Cell voltage / Battery voltage |
| **Top bar: RQ bar** | bool | on | show the RQ (downlink link quality) bar |
| **Top bar: TQ bar** | bool | on | show the TQ (uplink link quality) bar |
| **Top bar: RSSI bars** | bool | on | show 1RSS (+ 2RSS with antenna diversity) |
| **Top bar: TX voltage** | bool | off | show the radio battery voltage next to the icon |
| **Bottom bar: TPWR** | bool | on | show TX power in the flight-view status bar |
| **TPWR bar max (mW)** | num | not set | 100 % reference for the TPWR bar in the ELRS detail; unset → bar shows a hint |
| **Close detail pages on arm** | bool | off | when on, arming closes an open detail page (off = keep ELRS detail open in flight) |
| **Tap zones for detail pages** | bool | on | enable tapping the bars / status line / gauge to open detail pages (the menu glyph stays active either way) |
| **Link bars: color only on warning** | bool | on | bars stay neutral while fine; color only on warn/crit (key `BarsQuiet`) |

> **Color scheme — feedback-dependent.** UltiDash is developed and tested against the
> built-in **UltiDash** palette (the primary path). The **EdgeTX theme** option
> (theme-aware colors) is **not the maintainer's personal focus**, is less tested, and
> relies on community feedback — please report theme glitches with a screenshot.

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
  **‹ Raw sensor ›** display entry.
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

### 2.4 Settings — Battery

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Reserve (%)** | num | 20 | reserve capacity; 0 % displayed = reserve reached |
| **Fuel: announce below (%)** | num | from full | fuel callouts start below this level (100 = from full) |
| **Fuel: coarse step (%)** | num | 10 | callout spacing above the dense zone |
| **Fuel: dense below (%)** | num | 10 | below this level the fine step applies |
| **Fuel: fine step (%)** | num | 1 | callout spacing in the dense zone |
| **Cell thresholds from** | choice | FC config | FC config (`mspBatteryConfig`) / Manual |
| **Full cell (manual)** | num | 4.12 V | only used when *Manual* |
| **Low cell (manual)** | num | 3.45 V | only used when *Manual* |
| **Critical cell (manual)** | num | 3.30 V | only used when *Manual* |
| **Cell-check delay (s)** | num | 4 | duration of the startup cell-check |

The four **Fuel** settings shape the fuel-callout density (value-driven, descending %):
quiet up high, denser near the end. The defaults reproduce the historical cadence
(announce from full in 10 % steps, every 1 % below 10 %).

With **FC config** the thresholds come from the Rotorflight FC
(`vbatfullcellvoltage` / `vbatwarningcellvoltage` / `vbatmincellvoltage`), read on
connect/disarm and cached. Cell count and capacity always come from the FC.

### 2.5 Settings — Thresholds

Warning thresholds, grouped by subject with section headers on the page. *(The former
"Callout interval" is gone — repeat cadence is now configured **per alert**, §2.6a. The
TPWR bar max moved to Display, the ESC-load thresholds to their own group, §2.5a.)*

**Link & signal**

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Link warn (%)** | num | 80 | RQly warning. High by design — RQly sits at ~100 % in clean flight |
| **Link critical (%)** | num | 50 | RQly critical |
| **RSSI warn (% headroom)** | num | 15 | best-antenna signal margin above the rate floor (see note) |
| **RSSI critical (%)** | num | 8 | RSSI critical |
| **RSSI hold time (s)** | num | 2 | low RSSI must persist this long before warning (filters rotational nulls) |
| **Skipped-packet limit** | num | 50 | armed: `*Skp` counter reaching this → callout |

**Power & BEC**

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Power warn voltage** | num | 9.0 V | armed + connected: `Vbat` below this → main-power-loss callout |
| **BEC warn (% drop)** | num | 8 | live BEC this far below the flight's reference → warning |
| **BEC critical (% drop)** | num | 15 | … and this far below → critical |

> **RSSI thresholds are `% headroom`, not raw dBm.** The widget maps the ELRS RSSI
> (`1RSS`/`2RSS`) to 0–100 % between the **current rate's sensitivity floor** (from `RFMD`)
> and a fixed top of −40 dBm, then warns on the **better** antenna's headroom, so the same
> thresholds work across rates. Defaults (15 / 8) are intentionally low: in real "all fine"
> logs the headroom stayed ≥ 16 % with RQly at 100 %.

> **BEC thresholds are relative (self-calibrating).** While armed the widget captures a
> reference — the highest plausible BEC voltage seen this flight (the healthy nominal) —
> so the same % thresholds work for any 5 V / 6 V / 8.4 V BEC without configuration.

### 2.5a Settings — ESC load

An **entirely optional** feature (off by default): the ESC continuous-current **load
monitor**. A GVAR on the model holds the ESC's continuous-current limit in **amps**.

**Prerequisite — filling the GVAR:** the Rotorflight **RF2/RFTool Lua suite** (which
UltiDash requires anyway) can be configured **per model** to write FC values into GVARs —
map the ESC's continuous-current limit to a free GVAR there, and point *ESC limit: GVAR*
at it. UltiDash only ever **reads** the GVAR (and zeroes it at session end, since the
writer never clears it).

UltiDash then computes **load % = current / limit × 100** and shows it as a full-width
bar under the dashboard's Current row plus the **ESC Load (calc)** telemetry slot
(§2.3a).

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **ESC load monitoring** | bool | off | **master switch** — off = the whole feature is off (no bar, tile shows `not set`, no alarm, the GVAR is never touched) |
| **ESC limit: GVAR (A)** | num | Off | which GVAR holds the limit; **Off = feature off** as well |
| **Warn (%)** | num | 80 | bar/tile turn yellow; sustained → warn alarm |
| **Critical (%)** | num | 100 | bar/tile turn red; sustained → critical alarm |
| **Alarm hold time (s)** | num | 5 | load must stay at/above a threshold this long before the alarm fires (ESCs tolerate short bursts above the continuous limit) |

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

The GVAR bridge is **optional** and needs a **one-time radio-side model setup** (an
input, a logical switch and a *Volume* special function — step-by-step example in §5.4).
Without it, callouts simply use the radio volume and the two sliders do nothing.

### 2.6a Settings — Alerts (per-alert pages)

**Alerts** is a submenu: a **Voice / mute** page plus **one page per alert**, so every
alert is configured in one place.

**Voice / mute**

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Voice language** | choice | English | English / Deutsch — picks the `/SOUNDS/<lang>/ultidash/` voice pack (spoken numbers/units still follow the radio's system language) |
| **Mute (master)** | choice | None | None / **All** silences every voice + vibration |

**Per-alert pages** — Fuel, Voltage, Cell check, Armed / disarm, Telemetry, Link quality,
RSSI / signal, Main power lost, BEC voltage, ESC load, Skipped packets. Each page has the
same rows:

| Setting | Type | Notes |
|---------|------|-------|
| **Active** | bool | the alert's on/off (voice + vibration together) |
| **Repeat** | bool | re-announce while the condition still holds |
| **Repeat count** | num | 0 = until cleared, else max repeats |
| **Repeat interval (s)** | num | spacing between repeats |
| **Escalation volume** | bool | while this alert is active, boost the GVAR master volume to *Escalation volume (%)* (§2.6 — GVAR world only) |
| **Vibrate** | bool | haptic pulse with this alert |
| **Overlay (prep)** | bool | reserved — fullscreen alert overlay, not implemented yet |

Defaults: every alert **Active** except **ESC load** (off — enable after setting up
§2.5a). **Fuel** and **Voltage** default to *Repeat = on, until cleared, 6 s* — exactly
the historical continuous callout cadence; the other alerts default to *Repeat = off*
(announce once per episode). **Vibrate** defaults to on for Fuel, Voltage, Telemetry,
BEC and ESC load (the historical "vibrate on critical" set). `Mute = All` remains the
master kill-switch over everything.

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
quiet) and silent on boot / on first assignment. Logical switches are on/off only; the
3-position profile needs a physical switch.

> ⚠️ **Upgrading from ≤ v0.4:** the switch selections use new storage keys (the native
> picker's source index). Old selections are **not migrated** — re-pick your switches
> once in *Settings ▸ Switch voice* (and the Toolbox activation switch, §2.7b).

### 2.7a Settings — General

Meta settings: config-file behaviour and diagnostics.

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Config file per craft** | bool | off | keep a separate config per craft flown from the same model slot (see §2.8) |
| **Debug log to SD card** | bool | off | write a diagnostics log to the SD card (see §11) |
| **Debug log: sessions kept** | num | 20 | 1–50 — how many rotating log files to retain |

### 2.7b Settings — Toolbox

The Toolbox embeds the **RF Adjustment Map / Editor** tool pages (view and touch-adjust
Rotorflight adjustment functions from the radio). Full setup — model prerequisites,
channels, GVAR pulse, labels — in **[TOOLBOX.md](TOOLBOX.md)**.

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Activation switch** | switch | Off | native switch picker; flipping it opens the chosen tool (full-screen) |
| **Switch opens** | choice | Off | Off / Adjust Map / Adjust Edit |
| **Adj: Config channel** | num | CH11 | channel carrying the adjustment-function selector |
| **Adj: Value channel** | num | CH12 | channel carrying the adjustment value |
| **Adj editor: GVAR** | num | GV1 | GVAR pulsed by the editor's − / + buttons |
| **Adj editor: pulse (ms)** | num | 150 | pulse length |
| **Adj value divider** | num | 1 | display divider for the value channel |
| **Adj editor: ranges hint** | bool | off | show the recommended-range hint in the editor |
| **Toolbox sunlight mode** | bool | off | high-contrast toolbox palette |
| **Announce bank (voice)** | bool | on | speak "bank" + number when the adjustment bank changes |

### 2.8 Where settings are stored

EdgeTX gives widgets no API to write their own options, so settings live in a file on the
SD card and overlay the (effectively empty) EdgeTX option list at runtime.

- **Per model slot (default):** `/WIDGETS/UltiDash/cfg_m_<slot>.cfg`, keyed by the model's
  file name (`model.getInfo().filename`) so it is **stable across Rotorflight's "set model
  name on TX"** renaming. One file per model slot.
- **Per craft (optional):** enable *Display → Config file per craft* to keep a separate
  `cfg_m_<slot>_<craft>.cfg` per craft flown from the same slot.
- Defaults come from the settings tables above; a missing file simply means defaults. The
  module-local cache is shared by all instances of the widget (so the passive views see
  the same values).

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
> **Manual dismiss:** tapping anywhere on the stats page (full-screen) returns to the
> flight view; it reappears with the next arm / reconnect cycle.

### 3.2 Flight view

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
arming-disable flags it shows "Arming Disabled: …" instead.

### 3.3 Stats view

- **Top bar:** clock + radio battery only (the link bars are hidden — momentary link
  figures are misleading after disconnect).
- **Header:** the Rotorflight FC craft name (cached so it survives disconnect) · total
  flight time · flights.
- **Table** (Latest / Min / Max): cell/battery voltage · **Headspeed P1 / P2 / P3** ·
  current · ESC temp · BEC.
- **Info line:** session flight time + mAh used (raw %).
- **Status bar:** TPWR+ · RQly- · Tmcu+ · Skp.

> **"Latest"** = live while disarmed/connected, frozen at the last value once disconnected.

**Headspeed per PID profile.** Governor headspeed differs per profile, so min/max are
tracked **per `PID#` profile** and shown as three fixed rows P1–P3. "Latest" only shows
on the row of the currently selected profile. (The `PID#` sensor freezes after a
disconnect, so fixed rows — not a switchable one — keep every profile visible.)

#### Min/Max integrity
- **Headspeed** is tracked only while the **governor is running** (no 0 from a stopped
  rotor), per profile.
- **Voltages (`Vbat`/`Vcel`/`Vbec`)** are tracked **only while armed** and latched against
  implausible (≤ 1 V) readings, so the post-landing buffer decay (4.x → 0 V, e.g. a stray
  2.89 V) never pollutes Min, and "Latest" doesn't freeze at 0 V. The BEC value is held
  through a supply collapse (it would otherwise show the buffer rail).
- **ESC temp** ignores the spurious 0 the ESC reports before its temperature telemetry is
  up.
- **RQly / TPWR / MCU temp** use EdgeTX's `-`/`+` sensors, reset once the link is actually
  up and frozen while it's down.
- **Current** Min is naturally ~0 at idle — a real reading.

**"Flight Time" (session timer):** counts while **armed AND the rotor spins** (read from
the `ARM` bit-0 and `Hspd > 100 rpm` sensors, independent of the RFTool state). Runs in
the background too; resets only on telemetry (re)connect. Distinct from header "Total
Flight Time / Flights" (cumulative, from the FC via MSP).

### 3.4 Detail pages (tap a panel, full-screen)

Tap-zones are gated by *Display → Tap zones for detail pages*. Close with a tap anywhere,
**RTN**, or (optionally) by arming. The whole telemetry/alert engine keeps running while
a detail page is open — you can watch the ELRS detail in flight without losing callouts.

- **Telemetry** (tap the right value panel): a **3-column grid of up to 12** freely chosen
  sensors (§2.3a — *Tele Details*). Off slots are skipped. This page shows **raw sensor
  data** — the live EdgeTX reading, not the dashboard's latched/filtered values. Each tile
  shows the label, the big value **+ its unit**, and a dim **`min .. max` chip** — the
  EdgeTX session low/high read from the sensor's **`-`/`+` variants** (so every sensor
  gets a low/high, not just the few the stats page tracks). The tile lays the label left
  of the value on the wide TX16S, above it on the narrow TX15. *(Reading the per-sensor
  min/max is gated to while this page is open, to keep the dashboard's sensor-lookup
  budget light.)*
- **ELRS link** (tap the top-bar bars): six labelled bars — **RQ, TQ, 1RSS, 2RSS, SNR,
  TPWR** — with reactive threshold ticks and values; the rate/mode header; footer with
  SNR, active antenna and session RQ-min. SNR is mapped −10…+10 dB; TPWR is inverted (high
  power = working hard) relative to *TPWR bar max* (shows a hint until that is set).
- **Status & events** (tap the ESC/status line): a bordered **status card** — arm state /
  governor / throttle, the ESC status and the arming status including the **full
  arming-disable reason list** — above a **scrollable, timestamped ESC event log** (every
  ESC status change, RESTART, and arm/disarm — newest first, color by severity; ▲/▼
  paging with an `N-M/30` position readout). A small footer shows dev metrics (Lua heap,
  free heap, UI loop Hz, pass ms). The menu's **Status** entry shows the same grouped
  configuration overview as the passive *Status info* view (thresholds & their source,
  alert switches incl. repeat summary and ESC-load state, volume setup).
- **Battery** (tap the gauge): a **cell-voltage scale** with the active crit/low/full
  thresholds marked (and whether they come from FC or manual), then the battery in the
  dashboard segment look with % and used mAh inside it, and a Batt / Cell-min / Reserve
  line.

### 3.5 Battery-profile picker (tap the B-Profile field — **disarmed only**)

Tapping the **B-Profile** field in the status panel opens a picker of the **6 Rotorflight
battery profiles**, each shown with its capacity (`1800 mAh`, or `undefined` when the
profile has none); the active one is marked. Selecting one **switches the active battery
profile on the FC**.

> ⚠️ **This is the only place UltiDash *writes* to the flight controller.** It is therefore
> gated to **disarmed** (the picker won't open armed, and the FC also rejects config writes
> while armed). The switch goes through the RFTool MSP API — `mspBatteryProfile.write`
> (MSP 176, the same call the RFTool's own battery page uses) — and persists **without an
> FC reboot** (`settingsSaved(true, false)`). The picker re-reads the FC's current profile
> fresh on open, so it reflects external profile switches too. Everything else in UltiDash
> stays **read/announce-only**.

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
(*Voice language*; spoken numbers/units come from the EdgeTX voice pack). Every alert has
its own page (§2.6a) with Active / Repeat / Vibrate / Escalation; `Mute = All` overrides
everything.

### 5.1 Telemetry-driven callouts

The *vib* column shows the **default** — vibration is per-alert configurable now.

| # | Trigger | Condition | Output | Active key | Background |
|---|----------|-----------|---------|--------|-----------|
| 1 | **Startup cell-check** | after the delay, if cell < FC full-cell | `batlow` + voltage | `SndCellChk` | no |
| 2 | **Fuel callout** | connected + armed, by fuel level | `battry`/`batlow`/`batcrt` + % (+vib) | `SndFuel` | yes |
| 3 | **Voltage alert** | connected + armed, cell ≤ FC warn/min | `batlow`/`batcrt` + voltage (+vib) | `SndVolt` | yes |
| 4 | **Armed / disarm** | arm state change | `armed` / `disarm` | `SndArm` | no |
| 5 | **Telemetry lost / ok** | armed-only loss; "ok" only after an armed loss | `telem_lost` (+vib) / `telem_ok` | `SndTelem` | yes |
| 6 | **Low link quality** | armed; RQly ≤ Link warn/crit | `link_warn`/`link_crit` + % | `SndLink` | yes |
| 7 | **Low RSSI / signal** | armed; best-antenna headroom ≤ RSSI warn/crit, held *RSSI hold* s | `rssi_warn`/`rssi_crit` | `SndRssi` | yes |
| 8 | **Main power lost** | armed + connected; `Vbat` < power-warn (incl. collapse to ~0) | `pwr_backup` + **BEC voltage** · restored: `pwr_ok` | `PwrWarn` | yes |
| 9 | **BEC voltage** | armed; live BEC ≥ *BEC warn/crit %* below the flight's reference | `bec_low`/`bec_crit` + voltage (+vib) | `SndBec` | yes |
| 10 | **ESC load** | armed + monitoring on (§2.5a); load ≥ warn/crit % for the hold time | `escl_warn`/`escl_crit` + % (+vib) | `EscLoad` | yes |
| 11 | **Skipped packets** | armed; `*Skp` ≥ limit | `skp_high` | `SkpWarn` | yes |

Notes:
- **Repeat engine (per alert, §2.6a):** an alert with *Repeat = on* re-announces on its
  own interval while the condition holds (count-limited or until cleared). Fuel and
  Voltage ship with the historical continuous cadence (6 s, until cleared); everything
  else defaults to once per episode (re-armed on recovery; a warn→crit escalation
  announces once more).
- **Escalation volume:** while any alert with *Escalation volume = on* is active, the
  GVAR master volume (§5.4) is raised to *Escalation volume (%)* — the repeats get
  louder; back to *Normal volume (%)* once cleared.
- **Voltage alert** ignores ≤ 1 V/cell readings — a collapsed/lost supply (~0 V) never
  produces a misleading "battery critical 0 V"; that case is the main-power-loss warning.
- **Main power lost** distinguishes a buffer-kick (telemetry still flowing → reported)
  from a plain dropout (handled as telemetry-lost). The callout speaks the **live BEC
  voltage** with each repeat — an audible countdown of the buffer. If the main pack comes
  back while still armed (the buffer bridged the gap), **`pwr_ok`** announces the
  recovery. While the mode is active the status line shows **MAIN POWER LOST** (highest
  priority, red), the main voltage reads `--` (BEC is the interesting value now), and the
  fuel/voltage callouts are suppressed — only main-power-lost and BEC speak.
- ⚠️ EdgeTX may have its **own** "telemetry lost" callout → it can double up; disable the
  EdgeTX trigger if so.

### 5.2 Switch announcements
See §2.7 — motor / rescue / governor (on-off) and profile (1-3), read read-only from a
configurable physical or logical switch.

### 5.3 Vibration
Per alert: each alert page's **Vibrate** switch (§2.6a). Defaults reproduce the old
"vibrate on critical" set (fuel, voltage, telemetry, BEC, ESC load). `Mute = All` also
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
(§5.1). Without the GVAR setup the two sliders do nothing and callouts simply follow the
radio volume.

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
| `Tesc` / `Tmcu+` | ESC / MCU temperature |
| `Hspd` | Headspeed (+ flight-time gate) |
| `Gov` | Governor state |
| `ARM` / `ARMD` | Arming flags (bit 0 = armed) / arming-disable flags |
| `PID#` / `RTE#` / `BAT#` | PID profile (drives per-profile rpm stats) / rate / battery profile |
| `Thr`, `Esc#`, `EscF` | Throttle, ESC signature + status flags (eStatus) |
| `RFMD` | ELRS rate/mode → readable rate + RSSI sensitivity floor |
| `RQly` / `TQly` | Down/uplink link quality |
| `1RSS` / `2RSS` / `ANT` | ELRS RSSI per antenna / active antenna (diversity) |
| `RSNR` | ELRS SNR (ELRS detail) |
| `TPWR` | TX power |
| `*Skp` | Skipped/undecoded packet counter (label starts with `*`) |

> Min/max are taken from the EdgeTX `-`/`+` variants where used; widget-tracked otherwise
> (see §3.3). Sensor *IDs* differ per radio — sensors are referenced by name only.

### 6.1 Duplicate / empty default sensors (important)

EdgeTX auto-discovers telemetry sensors from the RX link. With Rotorflight this commonly
creates **default sensors that duplicate Rotorflight's own names but carry no data** — on
the radio's *Telemetry* page they show `—`. Because UltiDash (like EdgeTX itself) looks
sensors up **by name**, and a name resolves to only **one** matching sensor, an empty
duplicate can *shadow* the real Rotorflight sensor. The value then reads `-` in the
widget — e.g. **Current** goes blank and the **fuel gauge** shows `-` / `-` instead of
`%` / `mAh`.

Typical empty duplicates seen on RadioMaster radios: `RxBt`, `Curr`, `Capa`, `Bat%`
(other RX-default names possible).

**Fix (one-time, per model):** open the model's *Telemetry* page and **delete every
sensor that shows `—`/no value**, keeping the Rotorflight sensors that actually carry
data. Turn **"Discover new sensors" off** afterwards so they aren't recreated. Once the
empty duplicates are gone, UltiDash reads the live values correctly.

---

## 7. ESC status decoder (eStatus)

`ultidashEsc.lua` translates `EscF` status codes into plain text depending on the `Esc#`
signature. Supported vendors:

| Signature | Vendor |
|----------|-----------|
| `0xA5` | OpenYGE / YGE |
| `0x53` | Scorpion / Tribunus |
| `0xFD` | HobbyWing Platinum/HW5 |
| `0x73` | FLYROTOR |
| `0xD0` | OMP / OFW |
| `0xC8` | BLHeli_32 |
| `0xFF` | "RESTART ESC" (special case) |
| else | generic status code |

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
| 4 | Gov. Active | unknown / none | Gov. Disabled / `-` |

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
- **RFTool widget** must be present (`rf2` global) → connection state and MSP data. If
  absent, the state stays "disconnected". **MSP is only read on connect/disarm, and the
  only MSP *write* is the battery-profile switch (§3.5), disarmed — never during armed
  flight.**
- **Performance:** the telemetry/alert/publish pass is throttled to 5 Hz (idle-throttled
  to 2 Hz while disconnected); touch is handled every cycle. The Status detail footer
  shows the live UI loop rate as a load indicator.
- **Sounds** in `/SOUNDS/en/ultidash/` and `/SOUNDS/de/ultidash/` (own subfolders,
  selected by *Voice language*). All shipped:
  - Battery: `batcrt`, `batlow`, `battry` · Arm: `armed`, `disarm`
  - Link/telemetry: `telem_lost`, `telem_ok`, `link_warn`, `link_crit`
  - Signal/RSSI: `rssi_warn`, `rssi_crit` · Packets: `skp_high`
  - Power: `pwr_backup`, `pwr_ok` · BEC: `bec_low`, `bec_crit` · ESC load: `escl_warn`, `escl_crit`
  - Switches: `motor_on`/`motor_off`, `rescue_on`/`rescue_off`, `gov_on`/`gov_off`, `profile`
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
- The startup cell-check and armed/disarm callout only run on the **active screen**;
  the ESC event log and switch announcements likewise need the widget visible.
- Stats "mAh Used (%)" shows the raw, not reserve-adjusted, percentage.
- Touch is only delivered to the widget in **full-screen** — the menu, detail pages and
  the stats manual-dismiss work full-screen only.
- *Callout volume* overrides the WAV level only; controlling the radio **master volume**
  needs the GVAR bridge + model Special Function (§5.4).
- The **escalation volume boost** (GVAR world) is only written while the Dashboard is
  on-screen; an alert announced off-screen still speaks, just at the normal volume.
- The per-alert **Overlay** switch is preparation only — the fullscreen alert overlay is
  not implemented yet.
- A passive *ELRS details* / *Status info* instance needs a running **Dashboard** instance
  to mirror.

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

- **Files:** rotating session files `/WIDGETS/UltiDash/debug_NN.log` (read them from the PC
  at `E:\WIDGETS\UltiDash\debug_NN.log`). **Debug log: sessions kept** (1–50, default 20)
  sets how many are retained; a tiny `debug_seq.txt` drives the round-robin slot.
- **A new session** (= new file) starts every time logging is switched on and on every radio
  restart while it is on. The first line is `INIT session #<n> <timestamp> (slot N/keep)` —
  the highest `session #` is the newest.
- **Contents:** every connection-`STATE` transition and a 1 Hz `PERF` snapshot
  (`hz / heap kB / pass ms / state / armed / view / menu / detail`); messages logged
  internally are mirrored in too.
- **Low impact:** lines are buffered in a capped RAM ring and **appended incrementally**
  to the session file — only the lines since the last flush are written. Disarmed the
  flush runs every ~3 s; **while armed it keeps flushing too**, at a conservative ~10 s
  cadence (the appends are tiny), so a crash / power loss in flight loses at most the
  last few seconds of log. A per-session file cap (~5000 lines) bounds SD growth; hitting
  it writes a marker line and stops that session's log.
