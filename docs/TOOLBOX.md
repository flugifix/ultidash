# UltiDash Toolbox — RF adjustment Map & Editor

> **Status: experimental / WIP** — integrated from the standalone *RFAdjMap* / *RFAdjEd*
> widgets into UltiDash as on-demand **Toolbox** pages. Under active hardware testing;
> details (appearance, configurable sources, recommended-value hints) may still change.

The Toolbox hosts two full-screen tool pages for Rotorflight's **trim-based adjustment
functions**:

- **Adjust Map** — *read-only*. Shows which adjustment function each trim maps to (per the
  6-position selector) plus the last value the FC reported.
- **Adjust Edit** — the same table with touch **`[-]` / `[+]`** buttons that perform an
  adjustment step (by pulsing a GVAR). Meant for **in-flight tuning**.

Open them from the fullscreen menu (**☰ → Toolbox**, disarmed only) **or** via an
**activation switch** that works any time, including in flight (see §5).

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

**Example (working model):** `MAX / weight = GV1 / ADD`, additionally **gated on the
Toolbox activation switch** — the pulse can only reach the value channel while the tools
are actually active (a cheap extra safety on top of the dedicated GVAR).

## 4. Telemetry (optional but recommended)

| Sensor | Purpose | Default |
|--------|---------|---------|
| `AdjV` | the new value the FC reports after an adjustment | `AdjV` |
| `PID#` | active PID profile (separate value store per profile) | `PID#` |

Connection is taken from **UltiDash's own link state** (no separate heartbeat sensor
needed): the reported value (`AdjV`) is only latched while the FC is connected.

## 5. Opening the tools — menu or activation switch

- **Menu:** ☰ menu glyph (disarmed) → **Toolbox** → **Adjust Map** / **Adjust Edit**. Back =
  **RTN**.
- **Activation switch (recommended for flight):** set **`Activation switch`** (`TbSrc`)
  and **`Switch opens`** (`TbTool` = *Adjust Map* / *Adjust Edit*). Flipping the switch **on**
  auto-opens the configured tool — **also while armed / in flight** (the menu glyph itself
  is disarmed-only); flipping it **off** returns to the dashboard.

  The same switch also gates **active** state: while it is off (or you open a tool from the
  menu with the switch off), the page is greyed and shows **"CONFIG INACTIVE"** — a guard
  against accidental changes.

  The row uses **EdgeTX's native switch picker** (physical + logical switches, incl. the
  `!…` inverted variants) — it shows exactly the switches your radio has, with their
  custom names.

## 6. Settings reference (Settings ▸ Toolbox)

| Setting | Key | Notes |
|---------|-----|-------|
| Activation switch | `TbSrc` | gates active + (with *Switch opens*) auto-opens a tool (native switch picker) |
| Switch opens | `TbTool` | Off / Adjust Map / Adjust Edit |
| Adj: Config channel | `TbConfigCh` | the 6-position selector channel (default CH11) |
| Adj: Value channel | `TbValueCh` | the trim-magnitude channel (default CH12) |
| Adj editor: GVAR | `TbGvar` | the GVAR pulsed by the editor (GV1…GV15) |
| Adj editor: pulse (ms) | `TbPulse` | pulse length per step |
| Adj value divider | `TbScale` | divides the displayed `AdjV` |
| Adj editor: ranges hint | `TbBert` | show recommended value ranges next to each name |
| Toolbox sunlight mode | `TbSun` | high-contrast light scheme for bright sun |
| Announce bank (voice) | `TbVoice` | speak "Bank N" (the active Config-channel position) on open + on change |

The tool pages follow the **UltiDash color scheme** (Display ▸ Color scheme: UltiDash /
EdgeTX theme / UltiDash dark); the sunlight option overrides to a high-contrast light
scheme. The
per-session values shown in the tools are **cleared on every fresh (re)connect** so they
start empty again.

**Custom labels — the table is fully rebuildable:** if your FC adjustment mapping differs
from the default in §2 (it may be *completely* your own), copy
`WIDGETS/UltiDash/toolbox/labels.example.lua` to `…/toolbox/labels.lua` and edit it:
**every cell** (function name per trim row × position 1…6) and the **column shortcuts**
(`sub`, default P/I/D/F/O/B) can be overridden, unused cells emptied with `""` (removes
the editor's `[-]`/`[+]` there). Overrides are **partial** (set only what differs), apply
to **both** the Map and the Editor, and `labels.lua` is never touched by updates.

## 7. Known limitations / WIP

- The telemetry sensor names are fixed to the Rotorflight standard (`AdjV` / `PID#`);
  the two channels are configurable (§6).
- The **recommended value ranges** (`TbBert`) are hard-coded defaults and still under
  review.
- Appearance (fonts, column widths) is not final.
- Safety model: the tools use only `getValue` + `model.setGlobalVariable` — **no MSP** — so
  the "no MSP while armed" rule is untouched; the FC's adjustment functions (your model
  setup) perform the actual change.
