# UltiDash — Quick Start

The shortest path to a working UltiDash: the **base features** — the flight dashboard, the
detail **views** and the **statistics** page — up and running. Everything else is
optional and configured later inside the widget.

> Prerequisites: an EdgeTX **color radio** (developed on 2.12), a heli on **Rotorflight
> 2.3** with an **ELRS** link, and the **RFTool** widget from the Rotorflight Lua scripts.
> For the full settings reference see **[REFERENCE.md](REFERENCE.md)**.

---

## 1. Copy the files to the SD card

Merge these folders into the **root of your radio's SD card**:

```
WIDGETS/UltiDash/      →  <SD>/WIDGETS/UltiDash/
SOUNDS/en/ultidash/    →  <SD>/SOUNDS/en/ultidash/
```

The **German voice pack is a separate download** (`UltiDash-v<version>-voice-de.zip` →
`<SD>/SOUNDS/de/ultidash/`). You need it only if you later set *Voice language* to
**Deutsch**; the default is English and the files above cover it.

## 2. Rotorflight: send the sensors UltiDash needs

UltiDash reads its data from **Rotorflight custom telemetry** (the FC sensors) plus the
**ELRS link** sensors. You configure the FC sensors once, on the flight controller.

**Enable custom telemetry** (described — do it in the Configurator or the CLI):

- In the **Configurator ▸ Receiver** tab, enable **Telemetry** and set the CRSF telemetry
  mode to **Custom**. Match **Telemetry Rate / Ratio** to your ELRS **Packet Rate / Telem
  Ratio**. *(CLI equivalent: `set crsf_telemetry_mode = CUSTOM`.)*

**Select the sensors — the one CLI line that matters.** Open the **CLI** tab, paste this,
then `save`:

```
set telemetry_sensors = 3,4,5,6,7,8,15,27,28,43,50,52,60,90,91,93,95,96,97
save
```

That covers everything the built-in dashboard, views and statistics need. What each ID is:

| ID | Sensor | Feeds |
|----|--------|-------|
| 3  | `Vbat` | Pack voltage, main-power-loss detection |
| 4  | `Curr` | Current row + current min/max (default current source) |
| 5  | `Capa` | Used mAh / energy |
| 6  | `Bat%` | Fuel gauge + fuel callouts |
| 7  | `Cel#` | Cell count |
| 8  | `Vcel` | Cell voltage + voltage alerts / cell check |
| 15 | `Thr`  | Throttle (governor/throttle line) |
| 27 | `EscF` | ESC fault flags (ESC status decoder) |
| 28 | `Esc#` | ESC signature (picks the ESC decoder vendor) |
| 43 | `Vbec` | BEC voltage + BEC-drop alert |
| 50 | `Tesc` | ESC temperature (display + temp alert) |
| 52 | `Tmcu` | MCU temperature (display + temp alert) |
| 60 | `Hspd` | Headspeed + the flight-time gate + rpm stats |
| 90 | `ARM`  | Arming state — drives callouts, stats and flight time |
| 91 | `ARMD` | Arming-disable flags (why it won't arm) |
| 93 | `Gov`  | Governor state |
| 95 | `PID#` | PID profile (drives per-profile rpm stats) |
| 96 | `RTE#` | Rate profile |
| 97 | `BAT#` | Battery profile |

> **Order and the rest of the slots don't matter** — list them in any order; up to 40
> sensors are allowed. If you also use the **RF Adjustment** toolbox tools, add `99` (the
> adjustment report) to the list. It reaches the radio as **one** CRSF frame, which the
> RFTool telemetry decoder (step 3) splits into the two sensors the tools read: **`AdjF`**
> (which function) and **`AdjV`** (its new value) — so those are the names to look for on
> the Telemetry page, not `99`.

> **The ELRS link sensors are automatic.** `RQly`, `TQly`, `1RSS`, `2RSS`, `RSNR`, `TPWR`,
> `ANT` and `RFMD` come **natively from the ELRS receiver** — they are **not** part of
> `telemetry_sensors` and need no FC setup. Likewise `*Skp` / `*Cnt` are created by the
> RFTool telemetry decoder (step 3).

## 3. Install the RFTool widget (required)

Add the **RFTool** widget (from the Rotorflight Lua scripts) to any widget zone. It
provides the connection/arm state and the MSP data UltiDash relies on, **and it decodes
the custom telemetry** for you — so the separate `rf2tlm.lua` background script is **not
needed**. Without RFTool, UltiDash stays "disconnected".

> 💡 **Recommended placement.** Put **UltiDash in a full-screen widget zone** and **hide
> the EdgeTX top bar** so the dashboard runs edge-to-edge — but place **RFTool in a
> top-bar slot**. A widget in the top bar keeps running (and keeps providing the `rf2`
> runtime + connection state) even while the bar is hidden, so RFTool stays active without
> taking any screen space away from the dashboard.

> ℹ️ **Turn on "Set name on TX".** In **RF Lua ▸ Model**, enable **Set name on TX** so the
> FC pushes the model name to the radio. The flight log and the EdgeTX telemetry logs are
> named/keyed on that model name — logging only works correctly with it on.

## 4. Discover the sensors on the radio

On the model's **EdgeTX Telemetry** page, with the **FC powered and connected**, run
**Discover new sensors**. The `Vbat`, `Curr`, … names from step 2 and the ELRS link
sensors should appear.

> ⚠️ **Nothing new appeared? Then discovery was not running.** EdgeTX creates a sensor only
> while *Discover new sensors* is **on** *and* the model's list still has room — the cap is
> **60 sensors** on these radios, and when it is reached the radio switches discovery **off by
> itself without saying so** (the *telemetry full* warning exists on the monochrome radios
> only). A Rotorflight craft plus the ELRS link sensors plus the receiver's own defaults sits
> close to that cap, so **adding a few rows on the flight controller and discovering again
> often finds nothing at all** — no entry, no error. The remedy is to **delete every sensor on
> the Telemetry page, switch *Discover new sensors* back on and let the whole list rebuild in
> one go**. See **[REFERENCE.md §6.2](REFERENCE.md)** for what such a rebuild costs.

> **Recommended (not required):** delete the **empty duplicate sensors** that the ELRS
> receiver creates without values — typically `RxBt`, `Curr`, `Capa`, `Bat%` (they show
> `—` on the Telemetry page). Then turn **Discover new sensors off** so they aren't
> recreated. UltiDash resolves its sensors by Rotorflight **sensor ID** and no longer gets
> shadowed by these, so this is a tidy-up rather than a fix — but it keeps the sensor list
> clean and matters for any raw sensor you later pick **by name**. **Keep in mind what that
> switch then does:** with discovery off, a sensor the craft only starts sending later never
> appears at all — turn it back on for that, then off again.

## 5. Add the UltiDash widget

Place the **UltiDash** widget in a (full-screen) widget zone on a model screen — one
instance per model. Its settings dialog carries one option, **Craft target** — leave it at
*Rotorflight*.

## 6. Configure and verify

- **Long-press** the widget → **Full screen**.
- Tap the **☰ menu glyph** (top-left, next to the clock) — *disarmed only* — to open the
  settings menu.
- Tap a panel (value panel, link bars, status line, battery gauge) to open its **detail
  page**.
- Open **menu ▸ Sensor check**: it lists the sensors UltiDash needs and flags any that are
  **missing / no data**, with a one-line note on what each gap breaks — the fastest way to
  confirm your telemetry is complete.

That's the base setup. From here, explore the settings menu (colors, value slots, alerts,
voices, Toolbox, flight log). For the **optional features** and the elementary steps each
one needs, see **[OPTIONAL_FEATURES.md](OPTIONAL_FEATURES.md)**; for the full settings
reference, **[REFERENCE.md](REFERENCE.md)**.
