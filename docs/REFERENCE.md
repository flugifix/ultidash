# UltiDash

LVGL dashboard widget for EdgeTX / Rotorflight (RadioMaster TX16S/TX15, EdgeTX 2.12).

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
| `ultidash.lua` | UI build (flight & stats view), lifecycle (create/update/refresh) |
| `ultidashFunctions.lua` | Telemetry updates, battery logic, callout engine, eStatus |
| `ultidashValues.lua` | Value table with formatting/color getters |
| `ultidashRf.lua` | RF service: connection state, MSP (battery profile, flight statistics) |
| `ultidashOptions.lua` | Configuration options + translations |
| `ultidashEsc.lua` | Multi-vendor ESC status/fault decoder (from eStatus) |

---

## 2. Configuration

All options appear in the EdgeTX widget configuration.

Options are grouped: display/layout, battery/fuel, alert thresholds, and the
alert on/off switches.

| Option | Type | Default | Range | Meaning |
|--------|-----|---------|---------|-----------|
| **Timer** | TIMER | 0 | – | Which model timer is shown in the top-left area when `TopLeft = Timer` |
| **BGFilled** | BOOL | 0 (off) | – | Fill the background color |
| **TopLeft** | CHOICE | Model image | Model image / Timer | What the top-left area shows: model image or the `Timer` |
| **ColorScheme** | CHOICE | UltiDash | UltiDash / by EdgeTX Theme | `UltiDash` = fixed built-in palette (independent of the active EdgeTX theme); `by EdgeTX Theme` = follow the active EdgeTX theme colors |
| **StatsViewMode** | CHOICE | On disarmed | Never / On disarmed / On disconnected | When the statistics page is shown |
| **VoltageDisplay** | CHOICE | Cell voltage | Cell voltage / Battery voltage | Whether cell or total voltage is shown |
| **ShowRQly** | BOOL | 1 (on) | – | Top bar: show `RQ` (RQly, downlink link quality) |
| **ShowTQly** | BOOL | 1 (on) | – | Top bar: show `TQ` (TQly, uplink link quality) |
| **ShowTPWR** | BOOL | 1 (on) | – | Bottom status bar (flight view): show `TPWR` (TX power) |
| **ShowTxV** | BOOL | 1 (on) | – | Top bar: show the radio (TX) battery voltage next to the icon |
| **Reserve** | VALUE | 20 | 0–40 | Reserve capacity in %. 0 % displayed = reserve reached (ePowerbar model) |
| **CellSource** | CHOICE | FC config | FC config / Manual | Where the cell-voltage thresholds come from: the Rotorflight FC (`mspBatteryConfig`) or the manual `CellFull`/`CellLow`/`CellCritical` values below |
| **CellFull** | VALUE | 412 | 0–480 | Full-cell voltage in **centivolts** (e.g. 412 = 4.12 V). Only used when `CellSource = Manual` |
| **CellLow** | VALUE | 345 | 0–440 | Low/warning cell voltage in centivolts. Only used when `CellSource = Manual` |
| **CellCritical** | VALUE | 330 | 0–440 | Critical/min cell voltage in centivolts. Only used when `CellSource = Manual` |
| **StartupDelay** | VALUE | 4 | 1–20 | Duration of the startup cell-check (seconds) |
| **CalloutInt** | VALUE | 6 | 1–60 | Minimum spacing between voice callouts (seconds) |
| **RQlyWarn** | VALUE | 50 | 0–100 | RQly warning threshold in % (ELRS Link Quality) |
| **RQlyCrit** | VALUE | 30 | 0–100 | RQly critical threshold in % (with vibration) |
| **PwrWarnV** | VALUE | 90 | 30–500 | Main-power-loss threshold in **0.1 V** (90 = 9.0 V). While armed, if `Vbat` drops below this, `pwr_backup` is announced once |
| **SkpLimit** | VALUE | 50 | 1–2000 | Skipped-packet limit. While armed, when the `*Skp` counter reaches this, `skp_high` is announced once |
| **Mute** | CHOICE | None | None / All | **Master**: `All` silences every voice callout **and** vibration, overriding all per-event switches below |
| **Haptic** | BOOL | 1 (on) | – | Vibrate on critical alerts (master for vibration) |
| **SndCellChk** | BOOL | 1 (on) | – | Sound: startup cell-check |
| **SndFuel** | BOOL | 1 (on) | – | Sound: fuel callouts |
| **SndVolt** | BOOL | 1 (on) | – | Sound: cell-voltage alerts |
| **SndArm** | BOOL | 1 (on) | – | Sound: armed/disarm |
| **SndTelem** | BOOL | 1 (on) | – | Sound: telemetry lost/recovered |
| **SndLink** | BOOL | 1 (on) | – | Sound: low link quality (RQly) |
| **PwrWarn** | BOOL | 1 (on) | – | Sound: main-power-loss warning |
| **SkpWarn** | BOOL | 0 (off) | – | Sound: skipped-packet warning |

> **Alert switches:** each callout/announcement has its own on/off (`Snd*` / `PwrWarn` /
> `SkpWarn`). `Mute = All` is a master kill-switch that overrides them all (voice +
> vibration). `Haptic` is the master for vibration. (Replaces the former `Mute` levels and
> the combined `LinkWarn`.)

> **Cell-voltage thresholds** default to the **Rotorflight FC** (`CellSource = FC config`):
> `mspBatteryConfig.vbatfullcellvoltage` / `vbatwarningcellvoltage` / `vbatmincellvoltage`,
> read on connect/disarm and cached. Set `CellSource = Manual` to override them with the
> `CellFull`/`CellLow`/`CellCritical` options (centivolts). Cell count and capacity always
> come from the FC.
> **ColorScheme = UltiDash** applies a fixed built-in palette (based on the "Clean Theme"
> by Mate Soos) so the widget looks the same regardless of the active EdgeTX theme;
> **by EdgeTX Theme** uses the `COLOR_THEME_*` colors of the active theme. With `BGFilled`
> on, the fill is **white** in UltiDash mode (matching that palette's white background), or
> `SECONDARY3` in EdgeTX-theme mode. Enable `BGFilled` to get the full UltiDash look on
> other EdgeTX themes.

---

## 3. Display / views

UltiDash has two views that switch automatically.

### Switching logic (`StatsViewMode`)
- **armed** → always **flight view**
- **Never** or never armed yet → always flight view
- **On disarmed** → stats view once disarmed
- **On disconnected** → stats view only when the link is lost
- In the **simulator** the views alternate every 5 s (preview)

### 3.1 Flight view

```
┌───────────────────────────────────────┐
│ Date/Time            Radio batt [###]  │  ← top bar
├─────────────┬──────────┬─────────────┤
│ STATUS      │ BATTERY  │  VALUES     │
│ (left)      │ (center) │  (right)    │
├─────────────┴──────────┴─────────────┤
│            Status bar                 │
└───────────────────────────────────────┘
```

**Top bar** (replaces the EdgeTX top bar for full-screen use):
- **left:** date + time (`getDateTime()`)
- **center:** ELRS link quality — `RQ` (RQly, downlink, option `ShowRQly`) and `TQ`
  (TQly, uplink, option `ShowTQly`); each can be hidden independently
- **right:** radio (TX) battery as a compact icon with the **% drawn on the icon** and the
  voltage beside it (voltage toggle: `ShowTxV`); fill green/red depending on the warning
  threshold (from `getGeneralSettings`)
- *Volume is intentionally not included* – EdgeTX Lua cannot read the level
  (no `getVolume`); see section 9.

**Left – status panel** (top to bottom):
1. **Model image** (eBitmap) – fixed reserved area (~32 % of the panel height), image
   top-anchored at its true aspect ratio (no floating). The fixed area keeps the rows
   below from **shifting** with different image formats. Alternatively (option
   `TopLeft = Timer`) this area shows the selected model **`Timer`** large instead of the image.
2. **Flights** + **total flight time** (from RF MSP flight stats) – directly below the image area
3. **Headline row: governor state** (left) + **throttle %** (right)
4. **ESC/arming status line** (full width, colored). Shows ESC faults or arming-disable
   reasons. When there's nothing to report, a muted placeholder:
   "No telemetry" (disconnected), "Ready" (disarmed, OK) or "Armed - OK" (armed, OK)
5. **Profile · Rate · Batt profile** in a single 3-column row

**Center – vertical battery** (see section 4)

**Right – values panel** (5 rows):
- Voltage (cell or total voltage, color-coded)
- Headspeed
- Current (Curr)
- ESC temperature
- BEC voltage

**Bottom status bar:** `Model: <name>` · arm state (Armed/Disarmed) · `TPWR: <mW>`
(toggle: `ShowTPWR`) · `Skp: <n>` ("Skp" = counter of skipped/undecoded telemetry packets;
the TX battery now sits in the top bar)
→ When arming-disable flags are present, the warning "Arming Disabled: …" is shown instead.

### 3.2 Stats view

- **Top bar:** date/time + radio battery only — **RQ/TQ are hidden here** (the momentary
  link quality is misleading after disconnect; link figures live in the status bar below).
- **Header:** model name (the **Rotorflight FC** craft name, cached so it stays after
  disconnect instead of falling back to the EdgeTX model name) · total flight time · flights
- **Table** (**Latest** / Min / Max) for: voltage, headspeed, current, ESC temp, BEC
- **Info cards:** flight time · mAh used (%) · batt profile
- **Status bar:** TPWR+ · RQly- · Tmcu+ · Skp

> **"Latest" column** = the current reading while disarmed/connected (live), frozen at the
> last value once disconnected (renamed from "Actual", which read as misleading after a
> disconnect).

#### Min/Max integrity
The Min/Max are kept clean of the 0-readings that occur during connect/disconnect:
- **Headspeed & current** are tracked by the widget only while the **governor is running**,
  so e.g. headspeed Min is the lowest *in-flight* rpm (not 0 from a stopped rotor).
- **ESC temp** is tracked by the widget ignoring the spurious **0** the ESC reports before
  its temperature telemetry is up, so ESC-temp Min shows the real low (≈ ambient), not 0.
- **Voltages / RQly / TPWR / MCU temp** are read from EdgeTX's `-`/`+` min/max sensors, but
  those are (a) **reset once** when the link is actually up ("FC fully available", RQly > 0),
  wiping pre-link 0s, and (b) **frozen** while the link is down (RQly = 0) so a lost-link 0
  can't pollute them. (A brief mid-flight link dropout can still nudge an EdgeTX-sourced Min.)

> The stats card "mAh Used (%)" shows the **raw** Bat% value (not reserve-adjusted).
> Only the flight-view battery uses the reserve-adjusted value.

**"Flight Time" (local session timer):** counts up while the craft is **armed AND the
rotor is spinning** (both in combination) — read **directly** from the `ARM` sensor
(bit 0) and the `Hspd` sensor (`> 100 rpm`), independent of the RFTool connection state.
If no headspeed sensor is present it falls back to armed-only. Accumulated in centiseconds
and also tracked in the **background** (not only on the active screen). It resets **only on
telemetry (re)connect** — it is deliberately **not** coupled to the model timer anymore
(that coupling used to wipe the time on disarm/throttle-cut). Distinct from **"Total Flight
Time"/"Flights"** in the header = cumulative from the RF flight controller (MSP).

> **Requirement:** the `ARM` and `Hspd` sensors must be active.

---

## 4. Central battery display (ePowerbar model)

### Fuel calculation (reserve-adjusted)
```
raw   = Bat% sensor
fuel  = (raw − Reserve) / (100 − Reserve) × 100
```
- **0 % displayed = reserve reached** (land safely)
- With `Reserve = 0` the raw value is used

### Discrete colors (ePowerbar)
| State | Color |
|---------|-------|
| `fuel ≤ critical` (critical = 0 when Reserve > 0) | **Red** |
| `fuel ≤ critical + 20` | **Yellow** |
| otherwise | **Green** |
| pack not full at startup | **Amber** |
| during the startup cell-check | **Grey** |

### Overlays in the battery
- **top:** cell count (e.g. "6S")
- **middle:** large percentage (`--` during the cell-check)
- **bottom:** mAh number large, unit "mAh" small below it
- Cell voltage is **not** shown in the battery (it's in the right values panel); the right
  "Cell Voltage" label no longer carries the "(NS)" suffix (the cell count is in the
  battery now) so it doesn't wrap
- Segments are intentionally coarse (few, thick steps) for a bold look
- Empty bar area = **light grey** (`0xC8C8C8`, like ePowerbar) instead of deep black
- Overlay text = **plain black** (no outline) – clearly legible on light grey/green/yellow;
  at a critical (red) fill level the bar is nearly empty anyway, so the text mostly sits
  over the grey area

### Startup cell-check
When the voltage first appears (power-on/connect):
1. Grey progress bar for `StartupDelay` seconds
2. Then compare cell voltage vs. the FC's full-cell voltage (`vbatfullcellvoltage`):
   - full → green
   - not full → amber + **`batlow` voice** + spoken total voltage

---

## 5. Voice callouts & vibration

There are **eight** triggers. All outputs are UltiDash's own WAVs in
`/SOUNDS/en/ultidash/` (spoken numbers/units come from the EdgeTX voice pack).
Each has its own on/off switch; **`Mute = All` overrides them all** (voice + vibration):

| # | Trigger | Condition | Output | Switch | Runs in background? |
|---|----------|-----------|---------|-------------|----------------------|
| 1 | **Startup cell-check** | after `StartupDelay`, if cell < FC full-cell voltage | `batlow` + voltage | `SndCellChk` | no (active screen only) |
| 2 | **Fuel callout** | connected **and** armed; depending on fuel level | `battry`/`batlow`/`batcrt` + % (+ vibration when critical) | `SndFuel` | **yes** |
| 3 | **Voltage alert** | connected **and** armed; cell ≤ FC warning/min voltage | `batlow`/`batcrt` + total voltage (+ vibration when critical) | `SndVolt` | **yes** |
| 4 | **Armed/disarm** | arm state change | `armed` / `disarm` | `SndArm` | no (active screen only) |
| 5 | **Telemetry lost / recovered** | **armed only**: loss from the `armed` state; "recovered" only if the loss was armed | `telem_lost` + vibration (lost) / `telem_ok` (recovered) | `SndTelem` | **yes** |
| 6 | **Low link quality** | **armed only**; RQly ≤ `RQlyWarn`/`RQlyCrit` | `link_warn`/`link_crit` + RQly % (+ vibration when critical) | `SndLink` | **yes** |
| 7 | **Main power lost** | **armed only**; `Vbat` < `PwrWarnV` | `pwr_backup` + vibration | `PwrWarn` | **yes** |
| 8 | **Skipped packets** | **armed only**; `*Skp` counter ≥ `SkpLimit` | `skp_high` | `SkpWarn` | **yes** |

> Turning a switch off disables that event's **voice and its vibration** together.
> `Mute = All` is the master kill-switch (everything); `Haptic` is the vibration master.

Details:
- **Fuel callout (2):** value rounded to the 10s (above reserve), singles near critical; the first sample after arming is skipped; min. spacing `CalloutInt`.
- **Voltage alert (3):** debounce (hold 0.5 s), then at the earliest after `CalloutInt`. Thresholds from the FC (`vbatwarningcellvoltage`/`vbatmincellvoltage`).
- **Telemetry lost (5):** **only if the loss happens from the armed state** (a real in-flight loss). Losses on the ground / while disarmed stay silent (logged only). The "recovered" voice only fires if an armed loss was reported before. Source = RF connection state (not raw RSSI). ⚠️ EdgeTX may have its **own** "telemetry lost" callout → it can double up; disable the EdgeTX trigger in that case.
- **Link quality (6):** ELRS **RQly** (Link Quality %), **armed only**; debounce 0.5 s. Announced **once per low-link episode** — re-armed only when RQly recovers above `RQlyWarn`; a warn→critical escalation announces once more. (No longer repeats on the `CalloutInt` interval.)
- **Main power lost (7):** **armed only**; reads `Vbat` directly. When it falls below `PwrWarnV` (in 0.1 V, default 9.0 V) the craft is likely on backup power. 0.5 s debounce, announced **once per drop**, re-armed when `Vbat` recovers above the threshold. Separate on/off via `PwrWarn`.
- **Skipped packets (8):** **armed only**; reads the cumulative `*Skp` counter directly. When it reaches `SkpLimit`, `skp_high` ("high packet loss") is spoken **once per flight** (the counter only climbs and resets on telemetry reconnect, which re-arms it). Voice only, no vibration. Separate on/off via `SkpWarn` (default **off**).
- **Background:** 2, 3, 5, 6, 7, 8 also run when UltiDash isn't the active screen (when armed).

---

## 6. Required telemetry sensors

Hard-wired Rotorflight sensor names (no configurable sources):

| Sensor | Use |
|--------|-----------|
| `Vbat` / `Vbat-` / `Vbat+` | Total voltage + min/max; also drives the main-power-loss warning (`PwrWarnV`) |
| `Vcel` / `Vcel-` / `Vcel+` / `Cel#` | Cell voltage + min/max + cell count |
| `Curr` | Current |
| `Capa` | Capacity used (mAh) |
| `Bat%` | Fuel level (basis for fuel) |
| `Vbec` / `Vbec-` / `Vbec+` | BEC voltage |
| `Tesc` | ESC temperature (Min/Max widget-tracked, ignores the startup 0) |
| `Tmcu+` | MCU temperature (max) |
| `Hspd` | Headspeed |
| `Gov` | Governor state |
| `ARM` | Arming flags (bit 0 = armed) – drives flight-time / callout gating |
| `ARMD` | Arming-disable flags |
| `PID#` / `RTE#` / `BAT#` | Profile / rate / battery profile |
| `Thr` | **Throttle (eStatus)** |
| `Esc#` / `EscF` | **ESC signature + status flags (eStatus)** |
| `RQly` / `RQly-` | **Link quality current (link warning)** / min |
| `TQly` | Uplink link quality (top-bar `TQ`) |
| `TPWR` / `TPWR+` | TX power (top-bar bottom `TPWR`) / max |
| `*Skp` | Counter of skipped/undecoded telemetry packets (bottom status bars); the sensor label really starts with `*` |

> **Note:** sensor *IDs* differ from radio to radio — sensors are always referenced by
> name, never by numeric id.

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
The worst message is held until the next (re)connect.

### Status line – what is shown when?

Order = priority (the topmost matching rule wins):

| State | Display | Color |
|---------|---------|-------|
| disarmed **and** arming-disable flags active | reasons, e.g. `* NOGYRO THROTTLE` | Yellow (WARNING) |
| ESC reports restart (signature `0xFF`) | `RESTART ESC` | Red |
| ESC fault detected (`Esc#`/`EscF`) | plain text, e.g. `ESC Over Temp` | Yellow/Red by severity |
| ESC connected, no fault | e.g. `BLHeli_32 ESC OK` | Theme (Info) |
| connected, **no** ESC sensors, disarmed | `Ready` | Grey (muted) |
| connected, **no** ESC sensors, armed | `Armed - OK` | Grey (muted) |
| no telemetry | `No telemetry` | Grey (muted) |

The grey placeholders (`Ready` / `Armed - OK` / `No telemetry`) only appear when there's
nothing concrete to report – so it's clear the field is alive.

### Governor state – what is shown when?

From the `Gov` sensor (RF internal governor). Values:

| Code | Display |
|------|---------|
| 0 | Throttle off |
| 1 | Throttle Idle |
| 2 | Spooling up |
| 3 | Recovery |
| 4 | Gov. Active |
| 5 | Throttle Hold |
| 6 | Gov. Fallback |
| 7 | Autorotation |
| 8 | Bailing Out |
| unknown | Gov. Disabled |
| no value | `-` |

### Throttle – what is shown when?

| State | Display |
|---------|---------|
| no telemetry | `**` |
| disarmed | `Safe` |
| armed (with `Thr` sensor) | e.g. `47%` |
| armed, no `Thr` sensor | `--` |

---

## 8. Dependencies

- **No external libraries** – UltiDash loads only its own files. In particular **no
  `eLib`/`lib_common`/`loadGUI`** (unlike the original ePowerbar/eStatus/eBitmap widgets,
  whose eLib usage was replaced when porting).
- **RFTool widget** must be present (`rf2` global) → provides the connection state
  (armed/disarmed/connected/disconnected) and MSP data (battery profile, flight stats).
  If absent, the state stays "disconnected" or the bar shows "RFTools widget missing".
  **MSP is only read on connect/disarm – never during armed flight.**
- **Sounds** in `/SOUNDS/en/ultidash/` (own subfolder so they don't clash with the EdgeTX
  voice pack; `AUDIO_PATH` in `ultidashFunctions.lua`). **All shipped with UltiDash:**
  - Battery: `batcrt.wav`, `batlow.wav`, `battry.wav`
  - Arm state: `armed.wav`, `disarm.wav`
  - Link/telemetry: `telem_lost.wav`, `telem_ok.wav`, `link_warn.wav`, `link_crit.wav`
  - Power: `pwr_backup.wav`
  - Skipped packets: `skp_high.wav`
  - Spoken numbers/units (digits, `percent`, `volts`) still come from the EdgeTX voice pack.
- **Model images** in `/images/`:
  - **The simplest setup is enough:** place a single file named after the **Rotorflight
    model name** (`rf2.modelName`), e.g. `MyHeli.png` or `MyHeli.jpg`, in `/images/`.
    That's all that's needed — the cell-count variant below is purely optional.
  - **`<name>`** is the Rotorflight model name (`rf2.modelName`); if RFTool is not
    available it falls back to the **EdgeTX model name** (`model.getInfo().name`).
  - **Full search order** (first existing file wins):
    1. `<name>-<cell count>S` — *optional*, only tried when a name **and** a cell count
       (> 0) are known, e.g. `MyHeli-6S`. Use this only if you want a different picture
       per cell count (e.g. a 6S vs. a 12S build of the same model).
    2. `<name>` — the plain model name, e.g. `MyHeli`. **This is the normal case.**
    3. the EdgeTX model bitmap (`model.getInfo().bitmap`) as a last fallback.
  - For each of those names the extensions are tried in this order: *(none)*, `.png`,
    `.bmp`, `.jpg`, `.jpeg`. (The "*(none)*" step matches a name that already includes its
    own extension.)
  - If no image is found the area simply stays empty (no error).

---

## 9. Known limitations

- Sensor sources are fixed (no select options like in ePowerbar/eStatus).
- The startup cell-check and armed/disarm callout only run on the **active screen**.
- Stats-view "mAh Used (%)" shows the raw, not reserve-adjusted, percentage.
- After changing the option set (e.g. after an update) check/re-set the widget options once.

---

## 10. Credits & license

UltiDash is a merged/derivative work and reuses code, logic and visual concepts from the
following widgets – all credit to their respective authors:

| Widget | Author / Source | License | Reused |
|--------|----------------|--------|-----------|
| **HeliDash** | gismo2004 – [HeliWidget](https://github.com/gismo2004/HeliWidget) | **none** (see below) | Base: layout, LVGL UI, telemetry, flight statistics |
| **ePowerbar** | Rob 'bob00' Gayle – [etx-widgets](https://github.com/bob01/etx-widgets) | GPLv3 | Battery/reserve model, discrete colors, cell-check, callout engine (itself based on "Lipo battery from single analog source" by Offer Shmuely) |
| **eBitmap** | Rob 'bob00' Gayle – etx-widgets | GPLv3 | Model/heli image from `/images/` |
| **eStatus** | Rob 'bob00' Gayle – etx-widgets | GPLv3 | Throttle %, multi-vendor ESC decoder, arming-disable reasons |
| **BattAnalog** | Offer Shmuely – [edgetx-x10-widgets](https://github.com/offer-shmuely/edgetx-x10-widgets) | GPLv2 (per file header) | only the **style** of the compact top-bar battery icon (no verbatim code) |

**License status (verified):**
- **etx-widgets** (ePowerbar/eBitmap/eStatus): repo LICENSE = **GPLv3** (the file headers
  still say "GPLv2", but the repo LICENSE is authoritative).
- **HeliWidget/HeliDash** (gismo2004) – the **base and thus the bulk of the code** – has
  **no** license file. The author describes it as a "personal hobby project shared freely
  with the community" (as-is). That is **not** a formal open-source license.
- **BattAnalog** (Offer Shmuely): no repo LICENSE, only a "GPLv2" file header; only the
  icon's visual concept was reimplemented, no code was copied.

**Intended license: GPLv3 – but not yet cleanly licensable as a whole.**

- For UltiDash's own parts and the etx-widgets-derived parts, **GPLv3** is intended
  (http://www.gnu.org/licenses/gpl-3.0.html).
- **Important:** "no license" (the HeliDash base) does **not** mean "free to use"; by
  default it is *all rights reserved*. Only **gismo2004** can license that code – it
  **cannot** be unilaterally placed under GPLv3 here.
- Therefore the **whole work is not yet** cleanly GPLv3. A *formal* release requires
  gismo2004 to license the HeliDash base (ideally GPLv3 or "GPLv2 or later"). For
  **private use** this does not matter.

*(Plain-language summary, not legal advice.)* Full license header also in `main.lua`.
