# UltiDash — Optional Features Setup

A supplement to the **[Quick Start guide](QUICKSTART.md)**. The Quick Start gets the
**base** running (dashboard, views, statistics). This document lists the **optional**
features and the **elementary steps** each one needs — grouped by *"needs a bit of model /
FC / SD setup"* vs *"just a switch in the settings menu"*.

For the full detail behind every step, follow the **REFERENCE §** / **TOOLBOX §** pointers.

> Everything here is **off / unset by default** — set up only what you want. All widget
> settings live in the in-widget menu (☰ glyph, full-screen, disarmed) and are saved per
> model.

---

## Needs a little setup (FC / model / SD)

### A. Model image

A photo of the heli in the left status panel.

1. Put an image file in `/IMAGES/` on the SD card **named after the Rotorflight model
   name** — e.g. `Goblin 580.png` (or `.jpg`).
2. *(Optional)* a per-cell-count variant `Goblin 580-6S.png` is preferred when present;
   otherwise the plain name, then the EdgeTX model bitmap, is used.

**Detail:** [README ▸ Requirements](../README.md#requirements).

### B. Master volume via GVAR (escalation volume)

Lets UltiDash drive the **radio master volume** (normal level while connected, a louder
**escalation** level while a critical alert repeats). Needs a **one-time model setup**
because a *Volume* special function can't read a GVAR directly — it is bridged through an
input. Numbers are examples; use whatever is free:

1. **Widget:** *Settings ▸ Volume ▸ Master volume via GVAR* = **GV9** (a GVAR used for
   nothing else on this model). Set *Normal volume %* and *Escalation volume %*.
2. **Inputs:** add an input, e.g. `I15 "Vol"`, **Source = GV9** (weight 100).
3. **Logical switch:** `L10: a > x` with **a = GV9, x = −1024** (true while UltiDash drives
   the volume).
4. **Special Function:** `SF: switch L10 → Volume = I15 (Vol)`.

UltiDash writes **−1024** as the "off" sentinel when the override is inactive, so your
volume pot rules again.

> ⚠️ When you retire UltiDash from a model, set that GVAR to −1024 once (or remove the SF /
> logical switch) — removing the widget does not release it.

**Detail:** [REFERENCE §5.4](REFERENCE.md#54-volume-two-worlds),
[§2.6](REFERENCE.md#26-settings--volume).

### C. ESC load monitor

A live utilization bar (current ÷ ESC continuous-current limit) plus an optional
sustained-overload alarm.

1. **Fill a GVAR with the ESC limit (amps):** in **RF Lua ▸ Model**, map the ESC
   continuous-current limit to a free GVAR (the RF2/RFTool **per-model** GVAR feature).
   This has to be set **per model** — and UltiDash always reads whichever GVAR you point
   its *ESC limit: GVAR* setting at (step 2).
2. **Widget:** *Settings ▸ ESC load* → set **ESC load monitoring = on** and **ESC limit:
   GVAR** to that GVAR. Adjust *Warn %* / *Critical %* / *Alarm hold* and the *Load bar*
   placement (Current row or the battery-gauge gap-ring) to taste.
3. *(Optional alarm)* enable the **ESC load** alert under *Settings ▸ Alerts* (armed-only).

UltiDash only ever **reads** the GVAR (armed-safe, no MSP).

**Detail:** [REFERENCE §2.5a](REFERENCE.md#25a-settings--esc-load).

### D. RF Adjustment tools (Toolbox — Map & Editor)

Touch-adjust Rotorflight adjustment functions from the radio. This is the most involved
optional setup (FC + model). Summary of the pieces:

1. **FC:** set up the Rotorflight **adjustment functions** (Configurator, or paste the
   ready CLI block **[`examples/rf_adjfunc_example.txt`](examples/rf_adjfunc_example.txt)**
   → check it doesn't clash with your existing `adjfunc` slots, then `save`).
2. **Recommended — RF Lua:** activate the **Adjustment Teller** under *RF Lua ▸ Settings*
   (it announces adjustment changes). This is a **global** RF Lua setting — done once, not
   per model.
3. **Model — Config channel** (default CH11): a 6-position source (P/I/D/F/O/B selector).
4. **Model — Value channel** (default CH12): encodes *which* trim is pressed (per-row
   magnitude), plus — for the **Editor** — one **GVAR pulse** mixer line on that channel.
5. **Widget:** *Settings ▸ Toolbox* → point *Config channel*, *Value channel* and *Adj
   editor: GVAR* at what you wired; optionally bind an open **shortcut switch**
   (*Settings ▸ Shortcuts*) so it works in flight.

**Detail:** the whole **[TOOLBOX.md](TOOLBOX.md)** guide
([§2 FC](TOOLBOX.md#2-fc-side--rotorflight-adjustment-functions),
[§3 model](TOOLBOX.md#3-edgetx-model-setup-once-per-model),
[§5 opening](TOOLBOX.md#5-opening-the-tools--menu-or-a-shortcut-switch)).

### E. Log Viewer (Toolbox)

Graph EdgeTX telemetry logs on the radio. No widget/model *setup* — it just needs the
logs to exist:

1. **Enable telemetry logging** on the model so the radio writes `/LOGS/<model>-<date>.csv`
   — an EdgeTX **Special Function ▸ SD Logs** (a switch + a rate, e.g. 1 s) is the usual
   way.
2. Fly, then open *Toolbox ▸ Log Viewer* (disarmed): browse → open → pick a set → chart.
3. *(Optional)* own templates — **made on the radio**: pick your sensors in the picker and
   tap **Save**; the *"What to display?"* page's **Edit** chip renames, duplicates, deletes
   and reorders them. They live in `cfg/logtemplates.lua`, which the widget writes and
   rewrites whole. Stocking that file from a PC still works (see
   `toolbox/logtemplates.example.lua` for the format), but edits made to the **old**
   `toolbox/logtemplates.lua` are ignored: it is adopted once into `cfg/` on the next Log
   Viewer open and never read again. Changes need no restart, only closing and reopening
   the page.

**Detail:** [TOOLBOX §8](TOOLBOX.md#8-the-other-toolbox-pages-log-viewer-rf2-config-flight-log--battery-profile).

### F. Flight log & battery management

Log every flight and (optionally) track which pack you flew.

1. **Widget:** *Settings ▸ General* → **Log flights to SD card** (writes
   `WIDGETS/UltiDash/fltlog/flights.csv`). Set **Min. flight time** (default 30 s) so
   spool-up tests don't count.
2. *(Optional)* **battery registry:** on the PC, copy `fltlog/batteries.example.cfg` to
   `fltlog/batteries.cfg` and list your packs (`id;name;cap;models;profile;…`).
3. *(Optional)* **Ask battery on connect** (General) opens a pack picker after each connect
   when the registry has packs for the current model; **Battery sets FC profile** activates
   the pack's FC battery profile on selection (MSP, disarmed).
4. View it under *Toolbox ▸ Flight Log* (Flights / Batteries / Models tabs).

**Detail:** [REFERENCE §12](REFERENCE.md#12-flight-log--battery-management).

---

## Just a switch in the settings menu (no external setup)

These need **no** FC/model/SD wiring — open the menu (☰, full-screen, disarmed) and set them:

- **RF2 Config tool** (*Toolbox ▸ RF2 Config*) — the stock Rotorflight config tool inside
  UltiDash. Needs only the **RFTool** widget (already required) + the RF2 scripts in
  `/SCRIPTS/RF2/` (RFTool compiles them on first run). Disarmed-only.
  *([TOOLBOX §8](TOOLBOX.md#8-the-other-toolbox-pages-log-viewer-rf2-config-flight-log--battery-profile).)*
- **Switch announcements** (*Settings ▸ Voice ▸ Switch voice*) — announce motor / rescue /
  governor / profile from any physical or logical switch you pick.
  *([REFERENCE §2.7](REFERENCE.md#27-settings--switch-voice),
  [§5.2](REFERENCE.md#52-switch-announcements).)*
- **Governor-state callouts** (*Settings ▸ Voice ▸ Gov voice*) — spool-up / active / hold /
  autorotation / bailout announcements (armed-only), per-state selectable.
  *([REFERENCE §2.7-gov](REFERENCE.md#27-gov-settings--gov-voice).)*
- **Per-alert tuning** (*Settings ▸ Alerts*) — for each alert: active, repeat (count/
  interval), **escalation volume** (needs the GVAR bridge, §B), **vibrate**, and a
  **fullscreen overlay** for the critical ones. Voice language EN/DE, master mute + master
  vibrate live here too.
  *([REFERENCE §2.6a](REFERENCE.md#26a-settings--alerts-per-alert-pages),
  [§5](REFERENCE.md#5-voice-callouts--vibration).)*
- **Shortcut switches** (*Settings ▸ Shortcuts*) — bind switches to open any detail page or
  Toolbox tool hands-free (position slots open-while-held, work in flight).
  *([REFERENCE §2.7c](REFERENCE.md#27c-settings--shortcuts).)*
- **Colors / palette** (*Settings ▸ Colors*) — per-scheme color overrides with a native
  picker. *([REFERENCE §2.3b](REFERENCE.md#23b-settings--colors-per-scheme-color-overrides).)*
- **Debug log** (*Settings ▸ General*) — diagnostics to `WIDGETS/UltiDash/logs/debug_NN.log`
  (a new numbered file per session; *Keep sessions* decides how many are kept).
  *([REFERENCE §11](REFERENCE.md#11-debug-log-diagnostics).)*

---

See **[REFERENCE.md](REFERENCE.md)** for the complete settings list and behaviour, and
**[TOOLBOX.md](TOOLBOX.md)** for the RF adjustment tools.
