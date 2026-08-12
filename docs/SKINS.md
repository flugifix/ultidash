# Writing UltiDash skins

A **skin** decides how the UltiDash dashboard is laid out — where the battery gauge, the
values and the status bar sit, what tiles are drawn, which colour schemes are offered, and
since 0.7.0 it may also draw the four **detail pages** (§8a).
UltiDash ships one, the built-in **UltiDash** look (`skins/default.lua`), which is a skin
like any other and is the best-documented example to read alongside this guide.

> ## ⚠️ Status: the skin system is IN DEVELOPMENT
>
> What this release carries is the **substructure**: the engine, the module contract
> described here, the discovery of `skins/*.lua`, the *Skin* settings group and the
> per-skin colour schemes. The **additional layouts are deliberately not part of it** —
> they are still being reworked, and holding them back is what keeps the API free to change
> while they settle.
>
> So treat this document as a **preview, not a stable contract**. The API is `api = 1` and
> it may gain fields, rename them or drop them; a skin written against today's version can
> break on the next release, and cfg keys and colour-override storage may move with it.
> Skins are an advanced, opt-in extension — the built-in look never depends on one, and
> a broken or missing skin always falls back to it.

## 1. What a skin is (and isn't)

- A skin is **pure presentation.** Every value it shows comes from the host
  (`wgt.values.*`, the 5 Hz-cached telemetry/format/colour catalog). A skin **never** reads
  telemetry itself, runs MSP, plays audio, or measures anything the host doesn't hand it.
  All of that — the engine — stays in the host and keeps running whatever the skin draws.
- A skin lays out the **flight** and **stats** views. The detail pages, the settings menu,
  the Toolbox, the status bar and the **safety overlays** (setup hint, warning banners, the
  critical-alert overlay) are the host's and are stacked on top of any skin — a skin can
  never suppress them. The top-left **menu glyph** always works, even from a skin that
  draws no top bar.
- A skin does **not** change fonts arbitrarily or hardcode sizes: the two radios differ
  (TX16S 800×480, TX15 480×320), so fonts are **measured** via the API.

## 2. Where skins live — installing is dropping a file in

Skin modules are Lua files in `WIDGETS/UltiDash/skins/`, and a skin is fully
**self-contained**: its file declares the layout *and* its manifest — display name,
colour schemes, own settings rows, scheme persistence (§3). **Nothing is registered in
the host**: skins are **discovered** by scanning `skins/*.lua` at startup.

- the **file name is the skin's id** (`myskin.lua` → id `myskin`; must start with a
  letter/digit — `_`-prefixed names are host-reserved). The *Dashboard skin* setting
  stores this id, so files can come and go without disturbing anyone's pick. Ids are
  **claimed in the registry** in §6a — `default`, `minimal`, `grid`, `cockpit` and `dash1`
  are taken permanently, and the same table holds the colour-scheme tags and cfg-key
  prefixes, which are the two things that actually collide.
- the choice lists **`default` first**, the rest **alphabetically by id**.
- `skins/default.lua` **must exist** — it is the fallback look when a chosen skin is
  missing or broken (the only skin the host hard-requires).
- discovery is capped (16 skins) and staged over a few startup cycles (budget), and
  every discovered skin is loaded once so all cfg keys are known before anything is
  saved — an inactive skin's stored options and colour overrides always survive.
- the modules stay cached, so **keep skins small** (a few hundred lines; heavy work
  belongs in the host).

## 3. The module contract

A skin file returns a table with the build functions **and its manifest**:

```lua
local M = {}
M.api = 1                 -- required; the host rejects other versions
M.name = "My Skin"        -- display name in the Dashboard-skin choice (omit -> the id)

-- manifest: the skin's colour schemes, its own settings, its scheme persistence
M.schemes = {             -- scheme descriptors (§6); omit -> the standard three
    { id = "mdark", name = "My dark", tag = "Y", dark = true, pal = { --[[8 colours]] } },
}
M.scheme_key = "MySkinScheme"   -- cfg key remembering THIS skin's scheme pick (unique);
                                -- omit -> auto ("Scheme_<id>")
M.def_scheme = 1                -- the scheme a fresh model starts in
M.items = {                     -- own settings rows (§7); omit -> none
    { key = "MyBig", lbl = "Big value", kind = "bool", def = 1 },
}
M.wants_extrema = true          -- opt in to .min_formatted/.max_formatted on sensor slots
                                -- (§4); omit -> the host skips those extra reads

function M.migrate(t) ... end              -- optional (§7c): convert YOUR OWN stored keys,
                                           -- in place, once per model; must be idempotent
function M.init(env) ... end               -- wire the skin API (once)
function M.build_flight(wgt, zone) ... end -- lay out the flight view
function M.build_stats(wgt, zone) ... end  -- lay out the stats view

return M
```

- `M.migrate(t)` is optional and is called **before** `M.init`'s first build sees anything:
  the host hands every installed skin's migration the raw per-model config table once per
  model, right after it is read (§7c). Omit it and nothing happens.
- `M.init(env)` is called once. Stash the parts of `env` (§4) you need in module locals.
  (The default skin assigns `M.schemes = env.standard_schemes` here — its three schemes
  are the host's standard descriptors.)
- `build_flight` / `build_stats` build the view for `zone` (`zone.w`, `zone.h`) and **return
  `main_panel, content_top_y`** — the root panel plus the y where your content starts, so
  the host can place its overlays. Return `nil` to fall back to the built-in look.
- A broken load, a wrong `api`, a missing build function, or an error in `init` → the host
  falls back to the default skin (never a crash, never a blank screen) — **and says so**:
  the rejection is logged with its reason (console always, `logs/debug_NN.log` when
  *Debug log to SD card* is on), the *Dashboard skin* choice marks the row
  `"<name> (error)"`, and if the rejected skin is the one you picked, the dashboard shows a
  **`Skin '<id>' failed - using default`** notice until you fix the file or pick another.
  The same applies to a skin id stored in the model config whose file is not on the card.
- **A build that raises is caught too, not just a broken load.** `build_flight` /
  `build_stats` and the host's own menu build run guarded: a raising view builder falls back
  to the default skin's (with the same *"failed - using default"* banner) and a raising menu
  page closes back to the dashboard, both with a log line naming the reason, once per
  distinct error. It is not remembered for the session — a builder can raise on a data state
  rather than on its code, and one bad frame must not cost you your layout for the rest of
  the flight. Numeric rows from `M.items` that omit `min`, `max` or `step` degrade to
  unbounded / step 1 instead of raising inside a control callback.
- While any discovered skin failed to load, the config's **unknown-key sweep is suspended
  for that session**. A skin that failed never got the chance to declare its `M.items`
  keys, and the sweep — which drops every key no current setting knows — would otherwise
  delete your settings for a skin that is merely half-copied. Fix the file and the next
  session sweeps normally.
- **A skin that is not on the card at all is protected the same way.** The model config
  remembers which skins it was written with (`SkinsSeen`), and while one of them is missing
  the sweep stays suspended — otherwise copying the widget without the skins and saving
  once would delete the settings of every layout that did not come along. The list only
  ever grows: if you remove a skin for good, its stored keys simply stay in the file, and
  the sweep resumes as soon as every remembered skin is back on the card.

## 4. The skin API (`env`)

`M.init(env)` receives:

**Component library** — the host's ready-made panels (call `fn(container, wgt, x, y, w, h)`):

| `env.` | Draws |
|--------|-------|
| `top_bar(c, wgt, x, y, w, h [, show_link])` | clock · link bars · TX battery (pass `false` to hide the link bars). Sets the menu-glyph and ELRS tap zones itself. |
| `status_bar(c, wgt, x, y, w, h)` | the status line (model · arm state · TPWR · Skp, or the arming-flag warning). In the **stats** view it shows TX power / RQly / MCU max / Skp instead. Its optional TPWR field is the shared `ShowTPWR` row — see §7. It keeps its own element refs (the host clears them before every rebuild), so hand it a container and nothing else — the `wgt.status_bar_box` / `_dims` fields some shipped skins still assign are vestigial, the host never reads them. |
| `fuel_gauge(c, wgt, x, y, w, h)` | the vertical battery gauge. |
| `flight_values(c, wgt, x, y, w, h)` | the configurable 5-slot values panel. |
| `flight_status(c, wgt, x, y, w, h)` | the left status panel (flights, governor, profile…). |
| `stats_table(c, wgt, x, y, w, h)` | the flight-statistics table (for `build_stats`). |

**Fonts** (never hardcode sizes):

- `env.select_font(available_h, available_w?, sample?)` → the largest font constant fitting
  the height (and the `sample` string within `available_w`, if given).
- `env.measure_font(font)` → that font's pixel height.
- `env.set_header(font, height)` → tell the host which header font/height the component
  library should use; call it **before** the components. Use the same values for your own
  labels.

**Layout / theme / taps:**

- `env.card_gap` — the standard inter-panel gap (px).
- `env.theme` — a live palette snapshot (§5). Read fields at build time.
- `env.set_tap(wgt, zone, rect)` — register a detail-page tap zone (§8).
- `env.card(container, x, y, w, h, children)` / `env.stacked_field(children, x, y, w,
  pad, label, value, font, h)` — the low-level card + stacked label/value primitives the
  host panels use, for free-form skins that want the same look.

**Sensors** (free sensor slots — §7a):

- `env.sensor_slot(wgt, key)` → resolve a `kind="sensor"` slot key to a render-ready
  descriptor, or `nil` when the slot is *Off*. Mirrors the built-in Tele Main panel, incl.
  *Voltage (auto)*, *ESC Load (calc)* and raw picks. Fields:

| Field | What |
|-------|------|
| `.label` | the catalog label — a string, or a **getter** for Voltage-auto's live cell/pack label |
| `.label_short` | the **compact caption** for narrow cards ("BEC Voltage" → "BEC"); string or getter, same shape as `.label` |
| `.value` | reactive value-text closure |
| `.unit` | `"V"` / `"A"` / `"°C"` / … — **`""` while *Display ▸ Units beside values* is off** (that option trades the unit against the value's font size) |
| `.unit_raw` | the unit **regardless** of that option — use it when the unit rides in a caption row, where it costs the value nothing |
| `.color` | a colour value/closure, or `nil` for the default text colour |
| `.min_formatted` / `.max_formatted` | the sensor's **EdgeTX session extrema**, memoized; `nil` for values without any (the ESC-load calc). They only carry data when the skin opted in with **`M.wants_extrema = true`** — the extra source reads are not free, so the host fetches them only on request. |
| `.num` | the **raw number** behind `.value`, or `nil` — for a bar, ring or scale that needs the value numerically rather than as text. Same sources `.value` reads; for *Voltage (auto)* it follows the same cell/pack switch. Nothing is memoized: it returns a number, so there is no string to build. |
| `.name` | the stored sensor name (`"Curr"`, `"~volt"`, `"~escl"`, a raw name) |

**Thresholds** — `env.threshold_for(wgt, name)` → a render-ready bundle, or `nil` when the
host has no threshold knowledge for that name (render as you would without it). This exists
so a skin never re-derives what the host already knows: before it, the same warn/crit
arithmetic and the same cell-voltage scale lived in several skin files and drifted the moment
a settings key was renamed.

| Field | What |
|-------|------|
| `.num()` | the live value, or `nil`. Per frame, cache reads only. |
| `.pct()` | `0…100` against the scale, or **`nil` for *no data*** — do not coalesce that to `0`. A real zero is a real zero; `nil` means draw the track and no fill. |
| `.color` | per-frame colour. For the sources the host already colours (ESC load, fuel) this is the host's own closure or field getter, handed straight through — **never wrap it again**, that is the `number expected, got function` build error. |
| `.marks` | `{ crit_pct, warn_pct }` tick positions in scale-%, or `nil`. `warn_pct` is `nil` when no warning step is configured. |
| `.off` | build-time: the threshold is **not configured** (e.g. ESC-load monitoring off, `Tesc` critical set to 0). Render as if there were no bundle. This is the *permanent* state; a `nil` `.pct()` is the *transient* one. |

Names served today: `~volt`, `~escl`, `Tesc`, `Tmcu`, `Vcel`, `Vbat`, `Bat%`, `RQly`, `TQly`,
`RSSI`, `TPWR` — **both sentinels included**, so a slot the user left on *Voltage (auto)* or
*ESC Load (calc)* can be asked for by the name that is actually stored in the config, with no
resolving on your side. `~volt` follows the same cell/pack switch as `slot.num`, so the bundle
and the slot can never disagree about which voltage they mean.
Thresholds and the scale are **snapshot when you ask**, the values are live — so ask
during your build, and a rebuild refreshes them. Asking for a name the host has to fetch
itself (`Tmcu`) registers it with the 5 Hz pass for you; stop asking and the read stops, so
there is no reason to be shy about it. For `RQly` / `TQly` / `RSSI` the **fill is not
inverted** — high still fills high — only the colour comparison is.

**Contrast:**

- `env.is_dark(color)` → is this colour dark by the host's own threshold?
  `env.ink_on(color)` → `BLACK` or `WHITE`, whichever stays readable on it. A skin cannot
  judge luminance itself (the colour is an opaque RGB565 int), so use these when you paint
  text over a fill whose colour comes from the theme or a battery role.

## 5. The theme snapshot (`env.theme`)

Read at build time (a full rebuild happens on every scheme/palette change, so the values
are always current). `sem` is a live reference — read `theme.sem.red` etc. at draw time.

| Field | Use |
|-------|-----|
| `panel_bg`, `force_bg_fill` | root rectangle: `color = theme.panel_bg`, `filled = theme.force_bg_fill or (wgt.options.BGFilled == 1)` |
| `primary1` / `primary2` | foreground text / inverse text |
| `secondary1` | strong lines / borders |
| `focus` | accent / headings |
| `warning` | warning accent |
| `disabled` | dim/disabled accent |
| `dim`, `track`, `tick` | dim secondary text, bar tracks, tick marks |
| `sem.green/yell/red/neut` | traffic-light status colours |
| `sem.bar_ok/bar_warn/bar_low/bar_crit/bar_check` | battery-bar fills |
| `sem.vtx_ok/vtx_low`, `sem.st_armed/st_disarmed` | TX-battery icon, arm-state text |

Many `wgt.values.*` getters already return the **right colour** for a value (e.g.
`display_voltage_actual_color`) — prefer those over deciding colours yourself.

## 6. Colour scheme descriptors

**At most seven per skin** — each one costs a set of per-model override keys, and the config
file is the budget. Over the cap the host offers **none** of them (the skin still loads and
runs on the standard three) and says so in the log; it does not silently keep the first
seven, because which seven would be arbitrary.

A scheme in a skin's `schemes` list:

```lua
{ id = "mdark", name = "My dark", tag = "Y", dark = true,
  pal = { text, base_bg, strong_line, accent_fill, panel_surface, accent_head, warning, dim } }
```

| Field | Meaning |
|-------|---------|
| `id` | stable key (unique within the skin). |
| `name` | shown in the **Color scheme** choice. |
| `tag` | **optional.** With a tag the scheme is **user-adjustable**: it gets a *Settings ▸ Colors* page and per-model override keys (`Clr<tag><role>`). The tag is one character and must be **globally unique across all installed skins** — two schemes sharing a tag share their override keys, so the user's colours bleed between skins. Taken so far: `U` `D` `E` (the built-in UltiDash look); `M` `L` `G` `C` `K` `1` `2` are **reserved** for the layouts still in development, so do not take them. A collision is not fatal but is written to the debug log during discovery. **Without a tag the scheme is FIXED** — its colours are defined by the skin file alone, independent of the user config: no Colors page, no override keys, and no overrides applied to it. |
| `dark` | `true` = dark scheme (forces the panel fill, picks the neon traffic-light set, renders the native menu pages neutral for readability). |
| `pal` | the **8 base palette slots** (see the table below). Required. |
| `follows_theme` | (rare) follow the live EdgeTX theme instead of a fixed palette — only the default skin's *EdgeTX theme* uses this. |

Everything else (traffic-light, chrome, battery fills, the Toolbox palette) is **derived**
from `pal` + `dark`, so a minimal scheme is just a name, a tag and eight colours. The eight
slots, in order:

1. Text / foreground 2. Base background 3. Strong lines / text 4. Accent fill
5. Panel surface 6. Accent / headings 7. Warning accent 8. Dim / disabled accent

Users tune any **tagged** scheme's colours under *Settings ▸ Colors* (one page per such
scheme of the active skin); overrides are stored per model under the scheme's `tag`.
Fixed (tag-less) schemes appear in the *Color scheme* choice but not in *Colors*.

### 6a. The namespace registry

A `tag` is **one character** and it is stored in the model config, so two schemes sharing a
tag share the user's colours — they bleed between skins, silently, and dropping a file into
`skins/` is all it takes to cause it. The host logs a collision it can see, but it can only
see the skins on that one card. So the tags, the ids and the cfg-key prefixes are claimed
here, in the document that ships with the API they belong to:

| Tag | Key prefix | Skin (id) | Status |
|-----|-----------|-----------|--------|
| `U` `D` `E` | *(host keys)* | `default` | reserved permanently |
| `M` | `Min` | `minimal` | reserved |
| `L` `G` | `Grid` | `grid` | reserved |
| `C` `K` | `Ckpt` | `cockpit` | reserved |
| `1` `2` | `D1` | `dash1` | reserved |

- **Ids:** the file name is the id. The five above are reserved permanently; a leading `_`
  is reserved for the host. Anything else is first come, claimed by a row in this table.
- **Config keys:** every key a skin adds starts with its registered **key prefix**, at least
  three characters (`Ckpt…`, `Grid…`, `D1…`, `Min…`). This is what makes a skin checkable
  against its row instead of relying on "pick something unique". The only sanctioned
  exception is the shared component keys — the rows several skins render identically.
- **Running out of tags is not a crisis.** A skin may ship **tag-less schemes only** and work
  completely; the tag buys user-adjustable colours and nothing else. See §6 above — a scheme
  without a `tag` is simply fixed.

> The tag space is 1 character and this table is the whole of it, so it is worth a look before
> inventing one. The skins listed above are in development and shipped separately from the
> widget; the reservations hold regardless.

## 7. Skin settings (`M.items`)

`M.items` is a list of settings rows in the same format as the built-in groups; they
appear in the **Skin** menu group under the (auto-added) *Color scheme* row.

```lua
M.items = {
  { kind = "section", lbl = "Layout" },
  { key = "MyGaugeW", lbl = "Gauge width", kind = "num",  def = 30, min = 20, max = 45, step = 1, big = 5,
    fmt = function(v) return v .. " %" end },
  { key = "MyBars",   lbl = "Show bars",    kind = "bool", def = 1 },
  { key = "MyMode",   lbl = "Big tile",     kind = "choice", def = 1, vals = { "Fuel", "Voltage" } },
}
```

Row kinds: `section` (header, `lbl` only) · `info` (muted hint, `lbl` only) · `bool`
(`def` 0/1) · `num` (`min`/`max`/`step`/`big` long-press step/`fmt`) · `choice` (`vals`
array, stored 1-based — or **`ids`**, see below) · `sensor` (a free sensor picker — §7a) ·
`color` (a real colour picker — §7b). Read the values in your build via
`wgt.options.<key>`. An optional `dim = function(w) return ... end` greys a row when it's
inert.

**`choice` rows: `ids` stores a name instead of a position.** Add an `ids` array beside
`vals`, index-parallel with it, and the config stores `ids[i]` — a short string — where a
plain `choice` would have stored `i`:

```lua
{ key = "MyRing", lbl = "Ring shows", kind = "choice", def = "fuel",
  ids  = { "off",  "fuel",      "vcel" },          -- what is STORED (and `def`)
  vals = { "Off",  "Battery %", "Cell voltage" } } -- what the menu SHOWS
```

- With `ids`, `def` is one of the **ids**, and `wgt.options.<key>` hands your build that
  string. Without `ids`, `def` and the stored value are the 1-based index into `vals`.
- **Use `ids` for any list you expect to grow.** A stored index means the list order is part
  of your config format: insert an entry in the middle and every user's pick shifts to its
  neighbour, silently. Ids decouple the two, so the list is free to be reordered, extended and
  translated.
- A stored id that is no longer in the list renders as `"?"` and the picker opens on the first
  entry — which is also exactly what a **number** does once a row has `ids`. So switching an
  existing row from indices to ids is a **stored-format change** and needs §7c.

> **Key names are not free-form: use your registered prefix** (§6a) — at least three
> characters, e.g. `Ckpt…` / `Grid…` / `D1…`. Keys live in one flat per-model config shared by
> the host and every installed skin, so a collision silently hands your setting to another
> skin, or to the host. The examples above use `My…` because they are examples. See §12 for
> where and how the keys are stored.

**Exception — options of a host component you draw.** A component from §4 has options of its
own, and they live in the item list of every skin that draws it, under **shared keys** (so the
user sets them once, whatever skin is active). Declare the rows only if your skin draws that
component:

| Component | Rows to declare (key · default) |
|-----------|--------------------------------|
| `top_bar` | `ClockMode` (2) · `ShowRQly` (1) · `ShowTQly` (1) · `ShowRSSI` (1) · `ShowTxV` (0) · `BarsQuiet` (1) — plus `Timer` (0) if your skin shows a timer |
| `status_bar` | `ShowTPWR` (1) — the optional TPWR field in the **flight** view (the stats view always shows TX power) |

Copy the row verbatim from `skins/default.lua`, and add a `dim` when your skin can switch the
component off (e.g. `dim = function(w) return (w.MinStatusBar or 1) == 0 end`), so the row
greys out when it has no effect.

### 7a. Free sensor slots

A `kind="sensor"` row is a full sensor picker — the same one *Tele Main* uses: a curated
dropdown (the model's known sensors + *Off* + *Voltage (auto)* + *ESC Load (calc)*) **plus**
a native raw-source field for *any* other sensor. The pick is stored as the sensor name
(`def` is a sensor name, e.g. `"Curr"`, `"Tesc"`, `"Vbec"`, `"Capa"`, `"Hspd"`, or the
sentinels `"~volt"` = Voltage-auto / `"~escl"` = ESC-load-calc). The host fills the live
value at 5 Hz for the **active** skin's sensor slots automatically.

Render a slot with `env.sensor_slot(wgt, key)` (§4) — it returns `nil` for an *Off* slot,
else `{ label, value, unit, color }`:

```lua
local s = sensor_slot(wgt, "MyS1")
if s then
    panel:build({
        { type = "label", x = x+6, y = y+4, w = cw-12, h = lh,
          text = type(s.label) == "string" and string.upper(s.label) or s.label, color = theme.dim },
        { type = "label", x = x+6, y = y+lh+4, w = cw-12, h = vh,
          text = s.value, color = s.color or theme.primary1 },      -- s.value is a closure
        -- s.unit ("V"/"A"/…) rendered as a small suffix if non-empty
    })
end
```

### 7b. Colours a skin invents itself

The theme snapshot (§5) covers the roles the **host** knows. If your layout needs a colour
the host has no role for — a filled **card surface** is the typical example; the host's
`chrome.track` is the *bar* track — you do **not** have to hardcode it: the settings
renderer's `kind = "color"` row is generic, so a skin can offer the same native picker
(+ **Def** reset) the *Colors* pages use, under its own key:

```lua
{ key = "MyCard", lbl = "Cards (light scheme)", kind = "color", def = -1,
  role = { k = "CARD", chrome = "track" },   -- what "Def" falls back to
  scheme = M.schemes[1] },                   -- ... in which scheme
```

- Stored as **`0xRRGGBB`**, with **`-1` = unset** (follow your built-in). Decode it in your
  build with plain arithmetic — `lcd.RGB(math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256)`.
- `role` only supplies the swatch's *fallback* colour and takes one of
  `slot` (1..8) / `sem` / `chrome` / `batt` / `stat`, resolved against `scheme`.
- **One row per scheme.** A single stored colour cannot serve a light and a dark scheme, so
  declare one key per scheme and pick the matching one at build time via
  **`wgt.active_scheme`** — the 1-based index into **your own** `M.schemes`, resolved by the
  host before it calls your build. It is always a valid index: a stored pick that no longer
  has a row (a hand-edited config, a scheme you removed) has already fallen back to your
  `M.def_scheme` by the time you read it, so you never need to range-check it.
- Put the built-in itself in your scheme descriptor as an extra field (e.g.
  `card = lcd.RGB(...)`): the host ignores fields it doesn't know, and your skin reads its
  own descriptors.

### 7c. Migrating your own stored keys (`M.migrate`)

A skin that has already shipped sometimes has to change what it stores — rename a key, or
change a value's *format*, which is what switching a `choice` row to `ids` (§7) does. Declare
an optional `M.migrate` and the host hands you the **raw per-model config table**, once per
model, right after it is read and **before the first time your build sees any of it**:

```lua
-- every cfg written before this row grew `ids` stored a 1-based index; RING_LEGACY is a
-- FROZEN copy of the ordering it was an index into, and is never reordered again
function M.migrate(t)
    if type(t.MyRing) == "number" then t.MyRing = RING_LEGACY[t.MyRing] end
end
```

The rules, all four load-bearing:

- **Mutate `t` in place, and return nothing.** `t` is the store's live table — the host reads
  your converted value straight out of it.
- **It must be idempotent.** It runs once per model *per session*, and a model you switch away
  from and back to is loaded again. Guard on what distinguishes the old form from the new
  (`type(v) == "number"` above), never on a flag. A transform that only survives one pass will
  destroy the value on the second.
- **Touch only your own prefixed keys** (§7). `t` is the one flat config shared by the host
  and every installed skin — including skins that are not currently active. A stray write into
  someone else's key is the same collision §7 warns about, with no menu in front of it.
- **Bring your own decode table, frozen.** Map an old value through a **copy** of the list as
  it stood, kept beside the live one and never tidied. Mapping through the *live* list is the
  trap: it silently re-points every stored pick at whatever now sits at that position, and it
  overwrites the evidence — the old value was still readable until you replaced it.

**Persistence is opportunistic, and that is deliberate.** Nothing is written to the SD card
for the migration's sake: the table you mutated *is* the settings cache, so the converted
value is what every build gets from `wgt.options` from that moment on, and it reaches the file
the next time something is saved on that model. On a radio that already has a config, that may
not be until the user next changes a setting — and it does not matter, because the conversion
is redone, identically, on every load until then.

**Keep the tolerant read as well, if you have one.** A migration only runs for skins the host
managed to load, on a host new enough to have the hook. Decoding an old value at *read* time
(`type(v) == "number" and LEGACY[v] or v`) stays the contract for what you draw; `M.migrate`
fixes the stored **form**, which is what the settings menu matches against your `ids`.

## 8. Tap zones

`env.set_tap(wgt, zone, rect)` registers a rectangle (`{x,y,w,h}`) that opens a detail page
when tapped (full-screen, gated by *Display → Tap zones*). Place them where your elements
are; unregistered zones simply don't offer that tap.

| `zone` | Opens |
|--------|-------|
| `"battery"` | the battery detail page |
| `"values"` | the telemetry detail page |
| `"status"` | the ESC/arming status detail |
| `"elrs"` | the ELRS link detail |
| `"battprofile"` | the FC battery-profile picker (**disarmed only** — the host gates it) |
| `"menu"` | the **settings menu** — for a skin that draws its own header/menu button. Unregistered, the host keeps a fixed top-left region tappable as the fallback. |

**One rect per zone, and the last writer wins.** `set_tap` stores a single rectangle per
zone name, and the host clears all zones before every rebuild — so "last" means the last
element *your* builder registers in that build, not something left over from the previous
frame. If two elements can claim the same zone in some configuration (assignable sources
make this the normal case), **register the more important one last**. Overwrites and unknown
zone names are reported on the console, and in the debug log when *Debug log to SD card* is
on; at the defaults a collision may be invisible, so check a non-default configuration.

## 8a. Detail pages

The four detail pages are skinnable, one at a time. Declare only the ones you have a design
for; anything you leave out keeps the built-in page.

```lua
function M.build_detail_elrs(wgt, zone, env)    ... end   -- the ELRS link page
function M.build_detail_estatus(wgt, zone, env) ... end   -- the ESC / arming status log
function M.build_detail_battery(wgt, zone, env) ... end   -- the battery page
function M.build_detail_telem(wgt, zone, env)   ... end   -- the telemetry page
```

- `zone` is the **whole screen** — detail pages are full-screen only. `env` is the same object
  your `M.init` received.
- The host has already cleared the screen; do **not** call `lvgl.clear()`.
- **Return nothing.** Unlike `build_flight` / `build_stats` there are no host overlays to stack,
  so there is nothing for the host to do with a return value.
- **No focusable objects and no images**, the same rule the built-in pages follow.
- The host keeps opening and closing the page, the tap that got there, the data gating and the
  arming gates. You draw.

**If your hook raises**, the host draws its own page instead, logs the reason once, and shows a
`Skin page '<id>' failed - using default` notice along the bottom **while that page is open** —
not on the dashboard, because the failure belongs to the page you were looking at. Your hook is
**retried** the next time the page opens: a detail builder can trip over a data state rather
than over its own code, and one bad frame should not cost you the page for the rest of the
session.

**A hook that is not a function is treated as absent**, not as a failure: the built-in page
appears and nothing is logged.

### The Status log's paging buttons

If you draw the ESC event log yourself, you own its paging:

- Register the two buttons as tap zones: `env.set_tap(wgt, "status_up", rect)` and
  `"status_down"`. Register neither and the page simply does not page — no error.
- `wgt.estatus_scroll` is the newest-first row offset. Read it, **clamp it against your own row
  count, write the clamped value back**, and draw from there. The host moves it when the user
  taps your rects and rebuilds.

### What a detail page may use beyond §4

These were host internals until the pages became skinnable, and they are what the built-in
pages are written against — a page that draws sensor values needs the same catalogue readers:

| `env.` | What |
|--------|------|
| `color_luma(c)` / `DARK_LUMA_THRESHOLD` | raw luminance and the host's threshold, for an ink decision `is_dark` / `ink_on` cannot express (two candidate colours rather than one) |
| `memo_text(input, build)` | rebuild a string only when its inputs change — the per-frame closure discipline the built-in pages use |
| `sensor_short_label(name)` / `sensor_unit(name)` | the catalogue's label and unit for a sensor name |
| `sensor_value_text(wgt, name)` | the latched, plausibility-filtered value as a reactive string |
| `sensor_value_text_raw(wgt, name)` | the **raw** source value — what the telemetry page shows deliberately, bypassing the latch |
| `sensor_minmax_text(wgt, name)` | the pre-joined `"min .. max"` session-extrema string |
| `sensor_test_text(name)` | the sensor-check page's own status wording |
| `is_off_sensor(name)` | is this slot's stored value the *Off* sentinel |
| `esc_load_color(wgt)` | the ESC-load colour **closure** — hand it straight through, never wrap it |
| `VOLT_AUTO` / `ESCL_AUTO` | the two virtual sensor-name sentinels (*Voltage (auto)*, *ESC Load (calc)*) |
| `DETAIL_SLOT_KEYS` | the telemetry page's own twelve slot keys |
| `ultidash_functions` | the shared module, for `get_esc_log(wgt)` (the event log's entries) |

> **Budget:** a detail page builds **in flight**, on the tap that opens it. There is no runtime
> safety net — EdgeTX aborts a call that runs too long and the widget cannot catch its own
> abort. Keep every page you draw under **16000 instructions**, well inside EdgeTX's ~20k
> ceiling, and test each one on the radio: a page that builds fine at the defaults says
> nothing about yours, because the defaults use the built-in skin.

## 9. The value catalog (`wgt.values.*`)

The data source. Getters ending in `_formatted` return a ready display string; `_color`
getters return the right colour; plain `label_*` fields are static localised labels. A
sample (see `ultidashValues.lua` for the full list):

- **Battery:** `display_voltage_formatted` / `_actual_color` / `_label_short`,
  `vbat_formatted`, `vcel_formatted`, `curr_formatted` (+ `_min`/`_max`),
  `capa_formatted`, `capa_percent_formatted`, `capa_bar_color`,
  `gauge_fill_percent()` (0–100 number), `gauge_percent_formatted`, `gauge_cells_formatted`.
- **Flight:** `headspeed_formatted` (+ `_min`/`_max`), `esc_temp_formatted`,
  `throttle_text`, `profile_id_formatted`, `rate_id_formatted`.
- **Link:** `rqly_cur_formatted`, `tqly_cur_formatted`, `tpwr_cur_formatted`,
  `elrs_rate_formatted`, `elrs_snr_formatted`.
- **State / session:** `craft_name_formatted`, `arm_state_text` / `arm_state_color`,
  `rf_connection_state_formatted`, `flight_time_str_formatted`,
  `battery_usage_summary_formatted`, `status_line_text` / `status_line_color`.
- **Labels:** `label_fuel`, `label_current`, `label_headspeed`, `label_esc_t`,
  `label_curr`, `label_rqly_cur`, `label_flight_time`, … (localised).

## 10. Rules (the hard ones)

These cost real debugging rounds — they are not optional:

- **Cheap per-frame.** `color=` / `text=` closures run every LVGL frame (~20 Hz). Read only
  `wgt.values.*` / `wgt.options.*` in them — **never** `getValue` / `getSourceValue` /
  `is_armed` (name lookups) per frame. The host already caches at 5 Hz.
- **Memoize string building.** A `text=` closure that concatenates every frame churns the
  GC and drops UI Hz. Keep the last input and the string it produced as upvalues of the
  closure and rebuild only when the input actually changed.
- **Function-style string calls only.** `string.format(s, …)`, never `s:format(…)` — method
  syntax raises “attempt to index a string value” and crashes the widget Lua state.
- **No `lvgl.box` overlays.** Boxes built in full-screen keep a clickable surface that
  swallows taps after a full-screen cycle. Draw with `panel:build{…}` primitives
  (rect/label/…) instead. (The component library and the host overlays already follow this.)
- **Measure fonts, never hardcode.** Use `select_font` / `measure_font`; the two radios
  differ. Test any custom skin on **both** the TX16S and the TX15.
- **Keep children INSIDE their parent's content box.** A child that reaches the edge of a
  bordered rect overflows it (the border shrinks the content box) and LVGL answers with an
  automatic **scrollbar** — a translucent dark bar along the bottom edge that looks like a
  drawing bug. Leave a padding of a few px on every side, exactly as the host's panels do
  with their `card_padding`. (Cost one hardware round during skin development: a card-wide
  caption.)
- **A label that doesn't fit WRAPS — and loses its tail.** LVGL word-wraps, it does not
  ellipsize, and the second line is clipped by the label's height: `"CELL VOLTAGE"` silently
  renders as `"CELL"`. So fit the FONT to the text for anything dynamic:
  `select_font(max_h, avail_w, worst_case_sample)` — sample a getter label once at build
  time, never per frame. Short captions of your own are usually the better answer — keep a
  caption table in the skin instead of using the catalog's prose.
- **Stay in budget.** Each build shares EdgeTX's ~20k-instruction call budget with the host,
  so a skin that is heavy at build time shows up as a **"CPU limit"** abort rather than as a
  slow screen. Keep the build lean, and exercise every configuration of your skin on the
  radio — not just the one you develop against.

## 11. A minimal skin

```lua
local M = {}
M.api = 1
local status_bar, select_font, measure_font, set_header, set_tap, theme
function M.init(env)
    status_bar  = env.status_bar
    select_font = env.select_font;  measure_font = env.measure_font
    set_header  = env.set_header;   set_tap      = env.set_tap
    theme       = env.theme
end
local function build(wgt, zone)
    local w, h, v = zone.w, zone.h, wgt.values
    local hs = math.floor(h * 0.075)
    local hf = select_font(hs - 2); set_header(hf, measure_font(hf))
    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h,
        color = theme.panel_bg, filled = theme.force_bg_fill or (wgt.options.BGFilled == 1) })
    local big = select_font(math.floor(h * 0.5), w, "88.8 V")
    panel:label({ x = 0, y = math.floor(h * 0.15), w = w, h = math.floor(h * 0.5), align = CENTER,
        font = big, text = function() return v.display_voltage_formatted() end,
        color = function() return v.display_voltage_actual_color() end })
    set_tap(wgt, "battery", { x = 0, y = 0, w = w, h = h })
    status_bar(panel:box({ x = 0, y = h - hs, w = w - 4, h = hs - 2 }), wgt, 0, 0, w - 4, hs - 2)
    return panel, math.floor(h * 0.15)
end
M.build_flight = build
M.build_stats  = build
return M
```

## 12. Where a skin's settings are stored

A skin's file (`skins/<id>.lua`) is **code only** — no user value ever lives there.
Everything a user configures is stored, together with all other UltiDash settings, in the
**per-model config file** `/WIDGETS/UltiDash/cfg/cfg_m_<model-name>.cfg`. There is **no
separate file per skin**. Four kinds of key come from a skin:

| What | Key | Example |
|------|-----|---------|
| which skin is active | `Skin` (the id string) | `Skin=myskin` |
| the skin's chosen scheme | its `M.scheme_key` | `GridScheme=2` |
| the skin's options | its `M.items` keys | `GridBig=1`, `GridHspdMax=2500` |
| per-scheme colour overrides | `Clr<tag><role>` | `ClrGS1=0xFFAA00` |

Two consequences worth knowing:

- **All skins share the one file, and inactive skins are preserved.** At startup the host
  loads every discovered skin once and registers its keys, so saving never drops the keys
  of a skin you're not currently using — switch skins back and forth and each skin keeps
  its own scheme pick, options and colour tweaks. (This is also why keys must be unique —
  §7.)
- **Config is per model, not per skin.** The same skin flown on two models has an
  independent copy of its settings on each. Colour overrides only exist for schemes with
  a `tag`; a **fixed** scheme (no tag, §6) writes nothing — its colours are the skin
  file's alone.

> ### A key name is still close to final — migrate it at the one point that can
>
> **Renaming a settings key resets it to its default for every user who had it configured,
> unless you convert it in `M.migrate` (§7c).** There is exactly one moment at which that is
> possible, and both of the host properties below are the reason why:
>
> - the host fills **every declared key with its default before any build runs**, so from
>   inside a skin *never set* and *set to the default* are the same observation — there is
>   no way to detect that a migration is even due;
> - a save **deletes every key no currently loaded skin declares** (deliberately
>   downgrade-hostile, so orphans cannot accumulate in a card's config forever) — so the
>   old key, the source you would migrate *from*, does not survive to be read.
>
> `M.migrate` sits **before both**: it gets the raw config table as it came off the card, so
> the old key is still there and nothing has been defaulted yet. Anything you try to do later
> — in `M.init`, in a build, off `wgt.options` — runs after the first of those two and is the
> naive migration that looks like it works: it survives testing, because an orphaned key does
> reach `wgt.options` until the next save, and then loses the setting of exactly the user who
> changed something before updating the skin. Do not build that one.
>
> So: pick your key names once, with your registered prefix (§7), and treat a rename as a
> format change that owes its readers a conversion — write it, and make it idempotent. If you
> must retire a setting outright, leave its row in place until you are willing to lose its
> value; nothing migrates a key that has nowhere to go.

For a full example read `skins/default.lua` — the built-in look, composed from the host
components, and the only skin this release carries.

The layouts that exercise the rest of this document — free-form tiles, ring gauges via the
arc-sector trick, a skin drawing its **own header** instead of the host top bar, free
sensor slots, `stacked_field`, every settings row kind and every tap zone — are the ones
held back as *in development* (see the status box at the top). They are not in this
release, and this guide describes capabilities ahead of the examples that demonstrate
them.
