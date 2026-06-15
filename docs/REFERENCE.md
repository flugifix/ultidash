# UltiDash

LVGL dashboard widget for EdgeTX / Rotorflight (RadioMaster TX16S MK3 / TX15, EdgeTX 2.12).

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
3. Menu entries: **Settings**, **Status**, **Reset settings to defaults** (with a
   confirmation dialog).

On the **Settings** page the ‹ › arrows in the header switch between five groups. Bools
are real toggle switches, multi-value options are dropdown pickers, numbers use −/+
buttons (long-press = bigger step). Edits are **saved automatically** when the page is
left (back arrow or **RTN**); arming or leaving full-screen also saves.

### 2.3 Settings — Display

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Top-left shows** | choice | Model image | Model image / Timer |
| **Top bar clock** | choice | Date + time | Date + time / Time only |
| **Timer (for top-left)** | num | Timer 1 | which model timer when *Top-left = Timer* |
| **Color scheme** | choice | UltiDash | UltiDash (fixed built-in palette) / EdgeTX theme |
| **Fill background** | bool | off | fill the panel background color |
| **Stats page** | choice | On disarmed | Never / On disarmed / On disconnected |
| **Voltage shown as** | choice | Cell voltage | Cell voltage / Battery voltage |
| **Top bar: RQ bar** | bool | on | show the RQ (downlink link quality) bar |
| **Top bar: TQ bar** | bool | on | show the TQ (uplink link quality) bar |
| **Top bar: RSSI bars** | bool | on | show 1RSS (+ 2RSS with antenna diversity) |
| **Top bar: TX voltage** | bool | on | show the radio battery voltage next to the icon |
| **Bottom bar: TPWR** | bool | on | show TX power in the flight-view status bar |
| **Close detail pages on arm** | bool | off | when on, arming closes an open detail page (off = keep ELRS detail open in flight) |
| **Tap zones for detail pages** | bool | on | enable tapping the bars / status line / gauge to open detail pages (the menu glyph stays active either way) |
| **Quiet link bars (color only on warn)** | bool | off | bars stay neutral while fine; color only on warn/crit |
| **Config file per craft** | bool | off | see §2.8 |

### 2.4 Settings — Battery

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Reserve (%)** | num | 20 | reserve capacity; 0 % displayed = reserve reached |
| **Cell thresholds from** | choice | FC config | FC config (`mspBatteryConfig`) / Manual |
| **Full cell (manual)** | num | 4.12 V | only used when *Manual* |
| **Low cell (manual)** | num | 3.45 V | only used when *Manual* |
| **Critical cell (manual)** | num | 3.30 V | only used when *Manual* |
| **Cell-check delay (s)** | num | 4 | duration of the startup cell-check |

With **FC config** the thresholds come from the Rotorflight FC
(`vbatfullcellvoltage` / `vbatwarningcellvoltage` / `vbatmincellvoltage`), read on
connect/disarm and cached. Cell count and capacity always come from the FC.

### 2.5 Settings — Thresholds

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Callout interval (s)** | num | 6 | minimum spacing between fuel/voltage callouts |
| **Link warn (%)** | num | 80 | RQly warning. High by design — RQly sits at ~100 % in clean flight |
| **Link critical (%)** | num | 50 | RQly critical (with vibration) |
| **RSSI warn (% headroom)** | num | 15 | best-antenna signal margin above the rate floor (see note) |
| **RSSI critical (%)** | num | 8 | RSSI critical (with vibration) |
| **RSSI hold time (s)** | num | 2 | low RSSI must persist this long before warning (filters rotational nulls) |
| **Power warn voltage** | num | 9.0 V | armed + connected: `Vbat` below this → main-power-loss callout |
| **Skipped-packet limit** | num | 50 | armed: `*Skp` counter reaching this → callout |
| **TPWR bar max (mW)** | num | not set | 100 % reference for the TPWR bar in the ELRS detail; unset → bar shows a hint |

> **RSSI thresholds are `% headroom`, not raw dBm.** The widget maps the ELRS RSSI
> (`1RSS`/`2RSS`) to 0–100 % between the **current rate's sensitivity floor** (from `RFMD`)
> and a fixed top of −40 dBm, then warns on the **better** antenna's headroom, so the same
> thresholds work across rates. Defaults (15 / 8) are intentionally low: in real "all fine"
> logs the headroom stayed ≥ 16 % with RQly at 100 %.

### 2.6 Settings — Alerts

| Setting | Type | Default | Notes |
|---------|------|---------|-------|
| **Callout volume** | num | System | System / 1 (min) … 5 (max) — see §5.4 |
| **Widget volume applies** | choice | Always | Always / Only connected |
| **Mute (master)** | choice | None | None / **All** silences every voice + vibration |
| **Vibrate on critical** | bool | on | vibration master |
| **Sound: startup cell-check** | bool | on | |
| **Sound: fuel callouts** | bool | on | |
| **Sound: voltage alerts** | bool | on | |
| **Sound: armed / disarm** | bool | on | |
| **Sound: telemetry lost/ok** | bool | on | |
| **Sound: link quality** | bool | on | |
| **Sound: RSSI / signal** | bool | on | |
| **Sound: main power lost** | bool | on | |
| **Sound: skipped packets** | bool | off | |

Each switch disables that event's **voice and its vibration** together. `Mute = All` is
the master kill-switch over everything.

### 2.7 Settings — Switch voice

Announce TX-switch positions, read **read-only** from the switch — fully independent of
the model's mixer / logical-switch / arming logic.

| Setting | Type | Default | Announces |
|---------|------|---------|-----------|
| **Motor on/off switch** | switch | Off | "motor on" / "motor off" |
| **Rescue switch** | switch | Off | "rescue on" / "rescue off" |
| **Governor mode switch** | switch | Off | "governor on" / "governor off" |
| **Profile switch (1-3)** | switch | Off | "profile" + 1/2/3 |

Each picker lists **Off**, the physical switches **SA…SH** (and an inverted `… inv`
variant), **plus every logical switch defined in the model** (`L1`, `L1 inv`, …). Use a
logical switch to follow real conditions — e.g. tie "motor on/off" to your arming-gate
logical switch instead of the raw switch. Announcements are debounced (0.3 s, so a 3-pos
switch passing through the middle stays quiet) and silent on boot / on first assignment.
Logical switches are on/off only; the 3-position profile needs a physical switch.

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

The Dashboard instance has two automatic views (**flight** / **stats**) plus three
tap-to-open **detail pages** and the **settings menu** (all full-screen only).

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
profile/rate/battery-profile.

**Center – battery gauge** (see §4). Tap to open the battery detail.

**Right – values panel:** voltage · headspeed · current · ESC temp · BEC.

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

- **ELRS link** (tap the top-bar bars): six labelled bars — **RQ, TQ, 1RSS, 2RSS, SNR,
  TPWR** — with reactive threshold ticks and values; the rate/mode header; footer with
  SNR, active antenna and session RQ-min. SNR is mapped −10…+10 dB; TPWR is inverted (high
  power = working hard) relative to *TPWR bar max* (shows a hint until that is set).
- **Status & events** (tap the ESC/status line): arm state / governor / throttle summary,
  the colored status line, and a **timestamped ESC event log** (every ESC status change,
  RESTART, and arm/disarm — newest first, color by severity). A footer shows dev metrics
  (Lua heap, UI loop Hz, pass ms). The menu's **Status** entry shows the same configuration
  overview as the passive *Status info* view.
- **Battery** (tap the gauge): a **cell-voltage scale** with the active crit/low/full
  thresholds marked (and whether they come from FC or manual), then the battery in the
  dashboard segment look with % and used mAh inside it, and a Batt / Cell-min / Reserve
  line.

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

All outputs are UltiDash's own WAVs in `/SOUNDS/en/ultidash/` (spoken numbers/units come
from the EdgeTX voice pack). Each has its own on/off; `Mute = All` overrides everything.

### 5.1 Telemetry-driven callouts

| # | Trigger | Condition | Output | Switch | Background |
|---|----------|-----------|---------|--------|-----------|
| 1 | **Startup cell-check** | after the delay, if cell < FC full-cell | `batlow` + voltage | `SndCellChk` | no |
| 2 | **Fuel callout** | connected + armed, by fuel level | `battry`/`batlow`/`batcrt` + % (+vib crit) | `SndFuel` | yes |
| 3 | **Voltage alert** | connected + armed, cell ≤ FC warn/min | `batlow`/`batcrt` + voltage (+vib crit) | `SndVolt` | yes |
| 4 | **Armed / disarm** | arm state change | `armed` / `disarm` | `SndArm` | no |
| 5 | **Telemetry lost / ok** | armed-only loss; "ok" only after an armed loss | `telem_lost` (+vib) / `telem_ok` | `SndTelem` | yes |
| 6 | **Low link quality** | armed; RQly ≤ Link warn/crit | `link_warn`/`link_crit` + % (+vib crit) | `SndLink` | yes |
| 7 | **Low RSSI / signal** | armed; best-antenna headroom ≤ RSSI warn/crit, held *RSSI hold* s | `rssi_warn`/`rssi_crit` (+vib crit) | `SndRssi` | yes |
| 8 | **Main power lost** | armed + connected; `Vbat` < power-warn (incl. collapse to ~0) | `pwr_backup` (+vib) | `PwrWarn` | yes |
| 9 | **Skipped packets** | armed; `*Skp` ≥ limit | `skp_high` | `SkpWarn` | yes |

Notes:
- **Voltage alert** ignores ≤ 1 V/cell readings — a collapsed/lost supply (~0 V) never
  produces a misleading "battery critical 0 V"; that case is the main-power-loss warning.
- **Link / RSSI** are each announced **once per low episode** (re-armed on recovery; a
  warn→crit escalation announces once more), not repeated on the callout interval.
- **Main power lost** distinguishes a buffer-kick (telemetry still flowing → reported) from
  a plain dropout (handled as telemetry-lost).
- ⚠️ EdgeTX may have its **own** "telemetry lost" callout → it can double up; disable the
  EdgeTX trigger if so.

### 5.2 Switch announcements
See §2.7 — motor / rescue / governor (on-off) and profile (1-3), read read-only from a
configurable physical or logical switch.

### 5.3 Vibration
Critical fuel/voltage, telemetry-lost, link-crit, RSSI-crit and main-power-loss vibrate
(when *Vibrate on critical* is on and the event's own switch is on).

### 5.4 Callout volume
*Callout volume* (1–5) plays UltiDash's callouts at a fixed level regardless of the radio
setting; *System* (default) follows the radio. *Widget volume applies = Only connected*
limits the override to when telemetry is up.

> ⚠️ This overrides the **WAV mix level**, not the radio's **master volume** (which Lua
> cannot set). If a model Special Function changes the master volume on connect (e.g.
> `VOLUME MAX` on a telemetry-beat switch), set that SF to a constant `ON` so the widget
> volume governs the callouts reliably.

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
  absent, the state stays "disconnected". **MSP is only read on connect/disarm — never
  during armed flight.**
- **Performance:** the telemetry/alert/publish pass is throttled to 5 Hz; touch is handled
  every cycle. The Status detail footer shows the live UI loop rate as a load indicator.
- **Sounds** in `/SOUNDS/en/ultidash/` (own subfolder, `AUDIO_PATH`). All shipped:
  - Battery: `batcrt`, `batlow`, `battry` · Arm: `armed`, `disarm`
  - Link/telemetry: `telem_lost`, `telem_ok`, `link_warn`, `link_crit`
  - Signal/RSSI: `rssi_warn`, `rssi_crit` · Power: `pwr_backup` · Packets: `skp_high`
  - Switches: `motor_on`/`motor_off`, `rescue_on`/`rescue_off`, `gov_on`/`gov_off`, `profile`
  - All peak-normalized to match the EdgeTX voice-pack loudness. Spoken numbers/units still
    come from the EdgeTX voice pack.
- **Model images** in `/images/`: a single file named after the Rotorflight model name
  (`rf2.modelName`; falls back to the EdgeTX model name) is enough — search order
  `<name>-<cells>S` (optional) → `<name>` → EdgeTX model bitmap, extensions *(none)*,
  `.png`, `.bmp`, `.jpg`, `.jpeg`. Missing image → empty area, no error.

---

## 9. Known limitations

- Sensor sources are fixed (no select options).
- The startup cell-check and armed/disarm callout only run on the **active screen**;
  the ESC event log and switch announcements likewise need the widget visible.
- Stats "mAh Used (%)" shows the raw, not reserve-adjusted, percentage.
- Touch is only delivered to the widget in **full-screen** — the menu, detail pages and
  the stats manual-dismiss work full-screen only.
- Callout volume overrides the WAV level, not the radio master volume (see §5.4).
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
