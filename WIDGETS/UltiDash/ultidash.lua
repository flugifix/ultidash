local script_dir = "/WIDGETS/UltiDash/"
local ultidash_functions = loadScript(script_dir .. "ultidashFunctions.lua")()
local ultidash_values = loadScript(script_dir .. "ultidashValues.lua")()
-- Rotorflight MSP/telemetry client. Resident once loaded, but loaded LAZILY in
-- ensure_rf_service and only for a craft whose declared target is Rotorflight -- so a
-- later target skips it with a condition instead of a refactor. At module level its 90
-- instructions sat in create(), the one call 0.8.0 spent three commits emptying. The
-- local STAYS: this chunk is at Lua's 200-active-locals wall (tools/check_locals).
local rf_service = nil
-- ELRS TX module configuration client. Resident once loaded (it runs from
-- background(), not from an open page), but loaded LAZILY in ensure_rf_service --
-- at module level it put its 137 instructions into create(), which is the one call
-- 0.8.0 spent three commits emptying.
local elrs_cfg = nil
local ultidash_settings = loadScript(script_dir .. "ultidashSettings.lua")()
-- Toolbox tool pages (RF adjustment map/editor), ALL lazy-loaded + pcall'd so a
-- missing file degrades gracefully (the Toolbox menu entries just won't appear).
local tb_adjmap = nil
local tb_adjed = nil
local tb_logview = nil
local tb_rf2cfg = nil
local tb_adjmap_avail = false
local tb_adjed_avail = false
local tb_logview_avail = false
local tb_rf2cfg_avail = false
-- shared toolbox data/helpers for the adjust tools: stays RESIDENT (small) so both
-- tools share ONE SUB/TBL/labels instance across their lazy load/release cycles
-- (a labels.lua override is applied once and survives a tool reload).
local tb_common = nil
-- Flight log / battery management: ONE table for all its state + functions
-- (the main chunk is close to Lua's 200-local limit -- same trick as `shortcut`).
-- .mod = viewer module (lazy, released on close), .data = data core (lazy,
-- stays resident once loaded), .avail/.data_avail = boot fstat flags.
local fltlog = { mod = nil, data = nil, avail = false, data_avail = false }
-- M5: the Live Monitor's namespace table -- ONE local for the whole feature (the main
-- chunk stands 4 below Lua's 200-active-locals wall, measured by tools/check_locals).
-- The DATA lives on wgt.lm (ultidashFunctions lm_sample); this holds the lazy module.
local livemon = { mod = nil, avail = false }
-- The RFSuite adapter (toolbox/rfscfg.lua). ONE local for the whole feature,
-- same trick as livemon -- the main chunk stands at 184/200 active locals and a pair
-- of tb_*/tb_*_avail locals is exactly what that wall is there to prevent.
local rfscfg = { mod = nil, avail = false }
do
    local okc, m = pcall(function() return loadScript(script_dir .. "toolbox/common.lua")() end)
    if okc then tb_common = m end
    -- ALL tool modules are LAZY-LOADED (see tb_load_* below): keeping the
    -- big Log Viewer (~75 KB source) resident from boot grew the Lua heap
    -- ~650 -> ~900 kB and the extra GC mark/sweep work dropped the whole UI
    -- loop from ~19 to ~15 Hz (debug_03 vs debug_04 PERF lines). At boot only
    -- check the files EXIST (menu entry visibility); missing -> no entry.
    -- The flags are LOAD TRIES LEFT (number, truthy) rather than booleans: a
    -- failed load used to latch `false` for the whole session, but load failures
    -- can be TRANSIENT -- an out-of-memory at a bloated heap killed one adjed
    -- load on 2026-08-16 and the latch then dead-ended the switch shortcut AND
    -- the menu entry until reboot. Now a failure logs, decrements, and the entry
    -- only disappears after the tries are used up (a truly broken file still
    -- cannot fail forever). Every read site keeps working: number = truthy.
    tb_adjmap_avail  = fstat(script_dir .. "toolbox/adjmap.lua") ~= nil and 3
    tb_adjed_avail   = fstat(script_dir .. "toolbox/adjed.lua") ~= nil and 3
    tb_logview_avail = fstat(script_dir .. "toolbox/logview.lua") ~= nil and 3
    tb_rf2cfg_avail  = fstat(script_dir .. "toolbox/rf2cfg.lua") ~= nil and 3
    rfscfg.avail     = fstat(script_dir .. "toolbox/rfscfg.lua") ~= nil and 3
    fltlog.avail      = fstat(script_dir .. "toolbox/fltlog.lua") ~= nil and 3
    fltlog.data_avail = fstat(script_dir .. "toolbox/fltdata.lua") ~= nil and 3
    fltlog.batted_avail = fstat(script_dir .. "toolbox/fltbatt.lua") ~= nil and 3
    livemon.avail     = fstat(script_dir .. "toolbox/livemon.lua") ~= nil and 3
end

-- One line to the debug log per failed load: the 2026-08-16 field report -- "the
-- switch did nothing, only a reboot helped" -- was undiagnosable because the
-- failed pcall left no trace. Hangs off `fltlog` (declared above, so in scope
-- here) because the main chunk is at Lua's 200-local limit.
fltlog.load_err = function(name, err)
    local d = ultidash_functions.dbg
    if d then d.logf("TB", "%s load failed: %s", name, tostring(err)) end
end

-- load a big toolbox module on first OPEN (disarmed-only pages, so the one-off
-- compile hiccup happens on a menu tap, never in flight); the module ref is
-- dropped again on CLOSE so nothing stays resident during flight. A failed load
-- logs, burns one try, and only after the last try does the entry disappear
-- (see the avail-flag note above); a success resets the tries.
local function tb_load_adjmap()
    if tb_adjmap == nil and tb_adjmap_avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/adjmap.lua")() end)
        -- init inside the protection too: a raising init left a half-set-up
        -- module resident and crashed the widget state instead of degrading
        if ok and m ~= nil and (m.init == nil or pcall(m.init, tb_common)) then
            tb_adjmap, tb_adjmap_avail = m, 3
        else
            tb_adjmap_avail = tb_adjmap_avail > 1 and tb_adjmap_avail - 1 or false
            fltlog.load_err("adjmap", ok and "no module/init" or m)
        end
    end
    return tb_adjmap
end
local function tb_load_adjed()
    if tb_adjed == nil and tb_adjed_avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/adjed.lua")() end)
        if ok and m ~= nil and (m.init == nil or pcall(m.init, tb_common)) then
            tb_adjed, tb_adjed_avail = m, 3
        else
            tb_adjed_avail = tb_adjed_avail > 1 and tb_adjed_avail - 1 or false
            fltlog.load_err("adjed", ok and "no module/init" or m)
        end
    end
    return tb_adjed
end
local function tb_load_logview()
    if tb_logview == nil and tb_logview_avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/logview.lua")() end)
        if ok then tb_logview, tb_logview_avail = m, 3
        else
            tb_logview_avail = tb_logview_avail > 1 and tb_logview_avail - 1 or false
            fltlog.load_err("logview", m)
        end
    end
    return tb_logview
end
local function tb_load_rf2cfg()
    if tb_rf2cfg == nil and tb_rf2cfg_avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/rf2cfg.lua")() end)
        if ok then tb_rf2cfg, tb_rf2cfg_avail = m, 3
        else
            tb_rf2cfg_avail = tb_rf2cfg_avail > 1 and tb_rf2cfg_avail - 1 or false
            fltlog.load_err("rf2cfg", m)
        end
    end
    return tb_rf2cfg
end
-- RFSuite adapter, livemon's lazy pattern (function on the namespace table,
-- a failed load logs and burns one try). No init hand-off: the adapter takes nothing
-- from the host but wgt.
rfscfg.load = function()
    if rfscfg.mod == nil and rfscfg.avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/rfscfg.lua")() end)
        if ok and m ~= nil then rfscfg.mod, rfscfg.avail = m, 3
        else
            rfscfg.avail = rfscfg.avail > 1 and rfscfg.avail - 1 or false
            fltlog.load_err("rfscfg", ok and "no module" or m)
        end
    end
    return rfscfg.mod
end
-- M5: same lazy pattern as the adjust tools (init handed tb_common for the palettes,
-- a failed load logs and burns one try). A field on the namespace table, not a local.
livemon.load = function()
    if livemon.mod == nil and livemon.avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/livemon.lua")() end)
        if ok and m ~= nil and (m.init == nil or pcall(m.init, tb_common)) then
            livemon.mod, livemon.avail = m, 3
        else
            livemon.avail = livemon.avail > 1 and livemon.avail - 1 or false
            fltlog.load_err("livemon", ok and "no module/init" or m)
        end
    end
    return livemon.mod
end
function fltlog.load_viewer()
    if fltlog.mod == nil and fltlog.avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/fltlog.lua")() end)
        -- init hands tb_common over for the palettes (the adj tools' pattern)
        if ok and m ~= nil and (m.init == nil or pcall(m.init, tb_common)) then
            fltlog.mod, fltlog.avail = m, 3
        else
            fltlog.avail = fltlog.avail > 1 and fltlog.avail - 1 or false
            fltlog.load_err("fltlog", ok and "no module/init" or m)
        end
    end
    return fltlog.mod
end
-- battery detail/editor (fltbatt): loaded by the HOST only for the battery
-- query's "+ New" flow -- the Flight Log viewer loads its own copy for the
-- Batteries tab. Same lazy/tries pattern as the viewer.
function fltlog.load_batted()
    if fltlog.batted == nil and fltlog.batted_avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/fltbatt.lua")() end)
        if ok and m ~= nil and (m.init == nil or pcall(m.init, tb_common)) then
            fltlog.batted, fltlog.batted_avail = m, 3
        else
            fltlog.batted_avail = fltlog.batted_avail > 1 and fltlog.batted_avail - 1 or false
            fltlog.load_err("fltbatt", ok and "no module/init" or m)
        end
    end
    return fltlog.batted
end
-- flight-log data core: unlike the big viewer it STAYS resident once loaded --
-- the disarm write needs it while the craft is still connected, and it is only
-- a few KB. Loaded on first use (battery query / first flight flush), so a
-- disabled feature costs nothing.
function fltlog.load_data()
    if fltlog.data == nil and fltlog.data_avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/fltdata.lua")() end)
        -- same transient-failure story as the tool loaders, and the stakes are
        -- higher: a latched false here silently loses the flight log for the session
        if ok then fltlog.data, fltlog.data_avail = m, 3
        else
            fltlog.data_avail = fltlog.data_avail > 1 and fltlog.data_avail - 1 or false
            fltlog.load_err("fltdata", m)
        end
    end
    return fltlog.data
end
local show_debug_border = 0

-- ============================================================================
-- COLOR PALETTE
-- Shadow the EdgeTX theme color constants as file-locals so the whole UI can be
-- switched to a fixed "Clean" palette (independent of the active EdgeTX theme)
-- via the ColorScheme option — without touching the many call sites below.
-- set_palette() reassigns these locals; the call sites just see the new values.
-- ============================================================================
local COLOR_THEME_PRIMARY1   = COLOR_THEME_PRIMARY1
local COLOR_THEME_PRIMARY2   = COLOR_THEME_PRIMARY2
local COLOR_THEME_SECONDARY1 = COLOR_THEME_SECONDARY1
local COLOR_THEME_SECONDARY2 = COLOR_THEME_SECONDARY2
local COLOR_THEME_SECONDARY3 = COLOR_THEME_SECONDARY3
local COLOR_THEME_FOCUS      = COLOR_THEME_FOCUS
local COLOR_THEME_WARNING    = COLOR_THEME_WARNING
local COLOR_THEME_DISABLED   = COLOR_THEME_DISABLED

-- originals (follow active EdgeTX theme)
local THEME_PALETTE = {}   -- filled IN PLACE by SETTINGS_GROUPS._build (stage 2a0); see there
-- static "Clean Theme" (Mate Soos) values
local CLEAN_PALETTE = {}   -- filled IN PLACE by SETTINGS_GROUPS._build (stage 2a0); see there
-- static "UltiDash dark" high-contrast palette (bright text + NEON accents on black).
-- Slots map the same way as CLEAN/THEME: 1 PRIMARY1, 2 PRIMARY2, 3 SECONDARY1,
-- 4 SECONDARY2, 5 SECONDARY3, 6 FOCUS, 7 WARNING, 8 DISABLED. Text roles (PRIMARY1,
-- SECONDARY1) stay near-white for readability; the accents (SECONDARY2 neon green,
-- FOCUS neon cyan, WARNING neon red, DISABLED neon amber) glow against the black panel.
local DARK_PALETTE = {}   -- filled IN PLACE by SETTINGS_GROUPS._build (stage 2a0); see there

-- panel background used when BGFilled is on. For the Clean palette this is WHITE to match
-- the Clean theme's actual wallpaper (which is solid white, not SECONDARY3); for the EdgeTX
-- theme it follows SECONDARY3 as before; the dark scheme paints solid black.
local PANEL_BG = COLOR_THEME_SECONDARY3
-- The dark scheme needs a solid dark panel to read white text, so it FORCES the
-- background fill on regardless of the BGFilled option (set by set_palette).
local force_bg_fill = false

-- Neutral UI chrome (bar/track backgrounds, tick marks, dim labels). Kept as fixed
-- greys in the UltiDash/Clean look, but DERIVED FROM THE THEME in EdgeTX-theme mode
-- so theme awareness is consistent there too. Semantic colours (battery/warn
-- green-yellow-red) and the battery graphic's own black overlay text stay fixed.
local COLOR_TRACK = lcd.RGB(0xC8, 0xC8, 0xC8)   -- empty bar / track background
local COLOR_TICK  = lcd.RGB(0x20, 0x20, 0x20)   -- strong threshold tick marks
local COLOR_DIM   = lcd.RGB(0x90, 0x90, 0x90)   -- dim secondary text / light ticks

-- Semantic "traffic-light" colours (good / warn / bad + a neutral chrome grey). Single
-- source: the builders read these instead of inlining per-scheme variants. Set per
-- scheme in set_palette (neon on the dark scheme, muted otherwise).
local SEM_GREEN = lcd.RGB(0x20, 0xB0, 0x20)
local SEM_YELL  = lcd.RGB(0xF0, 0xC0, 0x00)
local SEM_RED   = lcd.RGB(0xE0, 0x30, 0x30)
local SEM_NEUT  = lcd.RGB(0x4A, 0x4A, 0x4A)
-- reused table handed to the other modules' set_palette (no per-update allocation)
local SEM = { green = SEM_GREEN, yell = SEM_YELL, red = SEM_RED, neut = SEM_NEUT }

-- Pack an EdgeTX colour value (an lcd.RGB result or a COLOR_THEME_* constant — RGB565
-- lives in bits 16+, colors.h: COLOR() embeds lcdColorTable[i] << 16) down to a plain
-- 0xRRGGBB integer for the cfg file, and back. The 565->888->565 round trip is stable
-- (lcd.RGB re-quantises to 565) and the stored form is human-readable. -1 in a cfg
-- slot means "unset" -> follow the scheme's built-in colour.
-- This is also the ONE place the 565 payload is unpacked — color_luma
-- builds on it instead of duplicating the bit fiddling.
local function color_to_rgb24(c)
    local v = (c >> 16) & 0xFFFF
    local r = ((v >> 11) & 0x1F) * 255 // 31
    local g = ((v >> 5)  & 0x3F) * 255 // 63
    local b = ( v        & 0x1F) * 255 // 31
    return (r << 16) | (g << 8) | b
end
local function rgb24_to_color(n)
    return lcd.RGB((n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
end

-- The native colour picker (lvgl "color") hands its set() TWO different encodings:
-- an RGB pick (RGB/HSV pads -> RGB2FLAGS: 565 payload in bits 16.. + RGB_FLAG 0x8000)
-- or an INDEXED pick (the "Theme"/fixed swatch buttons -> COLOR2FLAGS: the raw
-- LcdColorIndex in bits 16.., NO RGB_FLAG). Feeding an index through the 565 decoder
-- turned e.g. the LIGHTBROWN swatch (index 30) into pure dark blue. Resolve indexes
-- first: theme indexes via lcd.getColor (follows the active theme; nil for fixed
-- indexes), fixed swatches from this copy of the firmware's fixed colour table
-- (colors.cpp lcdColorTable[14..33], EdgeTX 2.12 — values by ARRAY position).
local FIXED_INDEX_RGB24 = {
    [14] = 0x000000, [15] = 0xFFFFFF, [16] = 0xEAEAEA, [17] = 0xC0C0C0,
    [18] = 0x404040, [19] = 0x606060, [20] = 0xFF0000, [21] = 0xA00000,
    [22] = 0xFF9999, [23] = 0x00FF00, [24] = 0x00A000, [25] = 0x00B43C,
    [26] = 0x0000FF, [27] = 0x0000A0, [28] = 0x00FFFF, [29] = 0xFFFF00,
    [30] = 0x9C6D20, [31] = 0x6A4810, [32] = 0xE5641E, [33] = 0x800080,
}
local function picker_color_to_rgb24(c)
    if (c & 0x8000) == 0 then                       -- no RGB_FLAG -> indexed pick
        local fixed = FIXED_INDEX_RGB24[(c >> 16) & 0xFFFF]
        if fixed ~= nil then return fixed end
        local ok, resolved = pcall(lcd.getColor, c) -- theme index -> RGB_FLAG value
        if ok and type(resolved) == "number" then
            c = resolved
        else
            return 0                                -- unknown index: black, not garbage
        end
    end
    return color_to_rgb24(c)
end

-- 0..255 luminance of an EdgeTX colour value, to judge how bright a surface is.
-- ONLY VALID FOR AN RGB VALUE (lcd.RGB / a stored override). A COLOR_THEME_* constant is an
-- INDEX flag -- the LcdColorIndex in bits 16.., no RGB_FLAG -- and running it through the
-- 565 decoder reads the index itself as a colour: every theme index lands under 42/255 and
-- therefore reads as "dark". Use theme_luma below for those.
local function color_luma(c)
    local n = color_to_rgb24(c)
    return 0.299 * ((n >> 16) & 0xFF) + 0.587 * ((n >> 8) & 0xFF) + 0.114 * (n & 0xFF)
end
-- The same number for a THEME colour, resolved through lcd.getColor first (that is what
-- picker_color_to_rgb24 does, and the only reason it exists).
local function theme_luma(c)
    local n = picker_color_to_rgb24(c)
    return 0.299 * ((n >> 16) & 0xFF) + 0.587 * ((n >> 8) & 0xFF) + 0.114 * (n & 0xFF)
end
-- Below this luminance the surface under our text counts as "dark" -> use the neon semantic
-- set (resolve_builtins evaluates it live per scheme). Verified against the light and a
-- dark EdgeTX stock theme; tune within ~80..140.
local DARK_LUMA_THRESHOLD = 96

-- Bumped on every settings save/reset. Module-local -> shared across ALL instances of the
-- widget (one loaded chunk, same as Shared). It invalidates the palette memo (pal_memo)
-- so a colour edit takes effect on the very next rebuild.
local settings_gen = 0

-- ============================================================================
-- SCHEME REGISTRY (groundwork for the skin system): the built-in colour
-- schemes as plain data DESCRIPTORS. The stored ColorScheme choice (1..3, order
-- unchanged since the v0.6.0 remap in ultidashSettings) indexes this table; a
-- future skin-supplied scheme ("Skin colors") gets the reserved slot 4, so the
-- stored numbers stay stable forever. Everything scheme-specific the code needs
-- lives in the descriptor — resolve_builtins/toolbox_palette derive the rest:
--   id            stable string key (named lookup below; skins/Shared later)
--   name          menu label — the ColorScheme vals and the Colors submenu pages
--                 derive from it (single source)
--   tag           override-key namespace: cfg keys are "Clr" .. tag .. role.k
--   dark          static dark flag: forces the bg fill (set_palette) and the
--                 neutral rendering of the native menu pages (update())
--   follows_theme palette follows the live EdgeTX theme; only COLOR_ROLES
--                 flagged `theme` are user-configurable (role_in_scheme)
--   pal           8-slot base palette (required); sem/chrome/batt/stat/toolbox
--                 are optional — absent parts are derived from pal + the flags
local SCHEMES = {}   -- filled IN PLACE by SETTINGS_GROUPS._build (stage 2a0); see there
-- named lookups (SCHEMES.ulti/.dark/.theme) — string keys don't disturb #SCHEMES

-- ============================================================================
-- SKIN REGISTRY (skin system): the selectable dashboard LAYOUTS.
-- A skin is SELF-CONTAINED and DISCOVERED: nothing about a skin is hardcoded here.
-- Skins are found by scanning skins/*.lua at startup (register_skin_defaults) — the
-- file name is the id, the module's manifest supplies the rest: M.name (display),
-- M.schemes (colour schemes), M.items (own settings rows), M.scheme_key /
-- M.def_scheme (its scheme persistence). Dropping a file into skins/ IS the install.
-- skins/default.lua must exist (the fallback look); menu order = default first, the
-- rest alphabetical.
-- The stored `Skin` setting is the skin's ID STRING (stable however many files come
-- and go). Legacy cfgs stored a 1-based index into the old fixed registry — mapped
-- once on read via LEGACY_SKIN_ORDER (the next save persists the string).
-- Scheme descriptors follow the SCHEMES format (the old max-7-per-skin limit fell with
-- the second-screen removal).
-- A scheme WITH a globally unique `tag` gets user colour overrides (a Colors page,
-- Clr<tag>* keys); a scheme WITHOUT a tag is FIXED — its colours live only in the
-- skin file, independent of the user config.
local SKINS = {}   -- filled by discovery: array rows {id, name, file, seq} + [id] = row
-- legacy index -> id mapping as a FIELD (main chunk sits at the 200-locals limit);
-- the "_" prefix can never collide with a discovered id (ids must start alnum).
-- Index 4 was shipped as "rings" while that skin was being built and later RENAMED to
-- "cockpit" — the mapping has to follow the rename, or every cfg from that window
-- silently falls back to the default skin.
SKINS._legacy = { "default", "minimal", "grid", "cockpit" }
SKINS._sensor_keys = {}   -- the active skin's kind="sensor" slot keys (see update_user_sensors)
-- resolve a stored Skin value (id string, legacy number, or nil) to its SKINS row;
-- unknown/missing skins fall back to the default row (nil only before discovery)
local function skin_reg_for(val)
    if type(val) == "number" then val = SKINS._legacy[val] end
    return (val ~= nil and SKINS[val]) or SKINS.default
end

-- The configurable colour ROLES — the single source for the Colors settings pages, the
-- override lookup and the picker's "current value". `slot` = palette index 1..8; `sem` = a
-- traffic-light key; `chrome` = a neutral-chrome key. `theme = true` marks the roles offered
-- even in EdgeTX-theme mode (the ones the EdgeTX theme does NOT itself define — only the
-- traffic-light colours). `grp` drives the section headers on the page.
local COLOR_ROLES = {}   -- filled IN PLACE by SETTINGS_GROUPS._build (stage 2a0); see there
-- a role is offered for a scheme when: own-palette schemes (UltiDash light/dark) -> all
-- roles; theme-following schemes -> only the roles flagged `theme` (the traffic-light
-- colours the EdgeTX theme itself doesn't define). Takes a SCHEMES descriptor.
local function role_in_scheme(role, def)
    return def.follows_theme ~= true or role.theme == true
end
-- cfg key for a (scheme, role) override: "Clr" + descriptor tag + role key. All charset-safe
-- for the cfg parser ([%w_]+). Value = 0xRRGGBB (>=0 = override) or -1 (unset -> built-in).
-- ONLY call this for a scheme WITH a tag: a tag-less descriptor is a FIXED scheme (its
-- colours live in the skin file, see docs/SKINS.md) and has no keys at all. The "_"
-- fallback below only exists so a stray call can never produce a key that COLLIDES with
-- a real tag -- it used to fall back to "U", i.e. the UltiDash scheme's keys, which made
-- a fixed scheme silently inherit that scheme's user overrides.
-- The (scheme, role) -> cfg-key mapping is fixed, but this used to re-concatenate
-- "Clr"..tag..role.k on every palette rebuild (23 keys/rebuild -> GC churn). Memoise it,
-- nested by role then descriptor (both stable table keys).
local color_key_cache = {}
local function color_key(def, role)
    local per_role = color_key_cache[role]
    if per_role == nil then per_role = {}; color_key_cache[role] = per_role end
    local k = per_role[def]
    if k == nil then k = "Clr" .. (def.tag or "_") .. role.k; per_role[def] = k end
    return k
end

-- Pure resolver of a scheme descriptor's BUILT-IN colours (no side effects): takes a
-- SCHEMES entry and returns the single definition of what that scheme looks like before
-- overrides. Only `pal` + the flags are required in the descriptor — sem/chrome/batt/stat
-- are derived when absent, so a future skin-supplied descriptor stays minimal.
-- set_palette applies overrides on top of this, and the settings picker uses it to show
-- the current value of an unset (default) colour.
local function resolve_builtins(def)
    local base = def.pal
    local pal  = { base[1], base[2], base[3], base[4], base[5], base[6], base[7], base[8] }
    local dark = def.dark == true
    -- dark descriptors are always dark-UI, own light palettes never; theme-following ones
    -- go by the theme panel luminance (SECONDARY3 = the surface we paint when BGFilled is
    -- on). LIMIT: with BGFilled=0 the text sits on the theme wallpaper, which can differ
    -- from SECONDARY3 (accepted).
    local dui = dark or (def.follows_theme == true and color_luma(pal[5]) < DARK_LUMA_THRESHOLD)
    -- semantic traffic-light colours: neon on a dark surface, muted otherwise
    local sem = def.sem
    if sem == nil then
        if dui then
            sem = { green = lcd.RGB(0x39, 0xFF, 0x14), yell = lcd.RGB(0xFF, 0xE0, 0x00),
                    red   = lcd.RGB(0xFF, 0x1A, 0x40), neut = lcd.RGB(0xA8, 0xB0, 0xB8) }
        else
            sem = { green = lcd.RGB(0x20, 0xB0, 0x20), yell = lcd.RGB(0xF0, 0xC0, 0x00),
                    red   = lcd.RGB(0xE0, 0x30, 0x30), neut = lcd.RGB(0x4A, 0x4A, 0x4A) }
        end
    end
    local chrome = def.chrome
    if chrome == nil then
        if def.follows_theme then
            -- chrome derives from the theme palette (subtle fill / strong line / dim)
            chrome = { bg = pal[5], track = pal[4], tick = pal[3], dim = pal[8] }
        elseif dui then
            chrome = { bg = lcd.RGB(0x00, 0x00, 0x00), track = lcd.RGB(0x28, 0x30, 0x38),
                       tick = lcd.RGB(0xFF, 0xFF, 0xFF), dim = lcd.RGB(0xC0, 0xC8, 0xD0) }
        else
            chrome = { bg = lcd.RGB(0xFF, 0xFF, 0xFF), track = lcd.RGB(0xC8, 0xC8, 0xC8),
                       tick = lcd.RGB(0x20, 0x20, 0x20), dim = lcd.RGB(0x90, 0x90, 0x90) }
        end
    end
    -- battery fills (main bar levels + TX battery icon): historically fixed, never
    -- theme-driven — the same built-ins for every scheme (values = the old BAR_COLOR_* /
    -- vtx_fill_color literals, so the default look is unchanged)
    local batt = def.batt or {
        ok    = lcd.RGB(0x00, 0xFF, 0x00), warn = lcd.RGB(0xF8, 0xC0, 0x00),
        low   = lcd.RGB(0xFF, 0xFF, 0x00), crit = lcd.RGB(0xFF, 0x00, 0x00),
        check = lcd.RGB(0xB8, 0xB8, 0xB8),
        vtx_ok = lcd.RGB(0x30, 0xC0, 0x30), vtx_low = lcd.RGB(0xFF, 0x33, 0x33),
    }
    -- statusbar arm-state text built-ins: the colours the text historically used
    -- (armed = traffic-light green, disarmed = the WARNING palette slot)
    local stat = def.stat or { armed = sem.green, disarmed = pal[7] }
    return { pal = pal, sem = sem, chrome = chrome, batt = batt, stat = stat,
             dark = dark, dark_ui = dui }
end

-- resolve_builtins is pure per descriptor (a handful of lcd.RGB allocations + a few tables)
-- and its result never changes within a session, so cache it per descriptor (stable table
-- key). set_palette COPIES b.pal before overlaying overrides, so the cached tables stay
-- pristine across rebuilds.
local builtins_cache = {}
local function cached_builtins(def)
    local b = builtins_cache[def]
    if b == nil then b = resolve_builtins(def); builtins_cache[def] = b end
    return b
end

-- Effective colour of a single role for the settings picker: the stored override (0xRRGGBB,
-- >=0) when set, else the scheme's built-in. `b` = resolve_builtins(scheme).
local function role_color(b, role, stored)
    if type(stored) == "number" and stored >= 0 then return rgb24_to_color(stored) end
    if role.slot   then return b.pal[role.slot] end
    if role.sem    then return b.sem[role.sem] end
    if role.chrome then return b.chrome[role.chrome] end
    if role.batt   then return b.batt[role.batt] end
    if role.stat   then return b.stat[role.stat] end
    return b.pal[1]
end

-- Build the override lookup for set_palette from a scheme's effective options: a table with
-- optional .pal[1..8] / .sem[key] / .chrome[key] entries, only for the roles the user set.
-- Returns nil when nothing is overridden (the common case -> zero extra work in set_palette).
-- `def` = a SCHEMES descriptor.
local function build_overrides(options, def)
    if not options then return nil end
    -- FIXED scheme (no tag): defined by its skin file alone, no Colors page, no override
    -- keys -- so there is nothing to look up (docs/SKINS.md §6). Leaving this to
    -- color_key's fallback made a fixed scheme read another scheme's keys.
    if def.tag == nil then return nil end
    local o = nil
    for i = 1, #COLOR_ROLES do
        local role = COLOR_ROLES[i]
        if role_in_scheme(role, def) then
            local v = options[color_key(def, role)]
            if type(v) == "number" and v >= 0 then
                local c = rgb24_to_color(v)
                o = o or {}
                if role.slot then
                    o.pal = o.pal or {}; o.pal[role.slot] = c
                elseif role.sem then
                    o.sem = o.sem or {}; o.sem[role.sem] = c
                elseif role.chrome then
                    o.chrome = o.chrome or {}; o.chrome[role.chrome] = c
                elseif role.batt then
                    o.batt = o.batt or {}; o.batt[role.batt] = c
                elseif role.stat then
                    o.stat = o.stat or {}; o.stat[role.stat] = c
                end
            end
        end
    end
    return o
end

-- Apply a scheme (built-ins `b` = cached_builtins(scheme) + optional overrides `ovr`).
-- Reassigns the file-local colour constants the whole UI reads, mutates the shared SEM table
-- and returns the resolved 8-slot palette (handed to the other modules' set_palette so they
-- render with the same — overridden — colours).
-- KNOWN LIMIT (latent): these are MODULE-locals, i.e. last-writer-wins across
-- instances — visible only when two Dashboard instances are placed at once, which the
-- dual-publisher banner already flags as an unsupported setup.
local function set_palette(b, ovr)
    -- b.pal is the CACHED built-in palette (cached_builtins) — never write overrides into it in
    -- place; copy the 8 slots first, then overlay.
    local base = b.pal
    local pal = { base[1], base[2], base[3], base[4], base[5], base[6], base[7], base[8] }
    if ovr and ovr.pal then
        for i = 1, 8 do if ovr.pal[i] then pal[i] = ovr.pal[i] end end
    end
    COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2 = pal[1], pal[2], pal[3], pal[4]
    COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS, COLOR_THEME_WARNING, COLOR_THEME_DISABLED = pal[5], pal[6], pal[7], pal[8]
    force_bg_fill = b.dark
    local sem = b.sem
    local osem = ovr and ovr.sem
    SEM_GREEN = (osem and osem.green) or sem.green
    SEM_YELL  = (osem and osem.yell)  or sem.yell
    SEM_RED   = (osem and osem.red)   or sem.red
    SEM_NEUT  = (osem and osem.neut)  or sem.neut
    SEM.green, SEM.yell, SEM.red, SEM.neut = SEM_GREEN, SEM_YELL, SEM_RED, SEM_NEUT
    -- battery fills ride along in the shared SEM table (same reused-table pattern): the
    -- modules pick them up in their set_palette (bar colours in Functions, TX icon in Values)
    local batt = b.batt
    local obat = ovr and ovr.batt
    SEM.bar_ok    = (obat and obat.ok)    or batt.ok
    SEM.bar_warn  = (obat and obat.warn)  or batt.warn
    SEM.bar_low   = (obat and obat.low)   or batt.low
    SEM.bar_crit  = (obat and obat.crit)  or batt.crit
    SEM.bar_check = (obat and obat.check) or batt.check
    SEM.vtx_ok    = (obat and obat.vtx_ok)  or batt.vtx_ok
    SEM.vtx_low   = (obat and obat.vtx_low) or batt.vtx_low
    -- statusbar arm-state text roles (also via SEM). UNSET falls back to what the text
    -- historically followed: armed -> the EFFECTIVE green (incl. a Good-green override),
    -- disarmed -> the resolved WARNING slot (incl. a slot-7 override) — so the default
    -- look is unchanged until the dedicated role is actually set.
    local ostat = ovr and ovr.stat
    SEM.st_armed    = (ostat and ostat.armed)    or SEM_GREEN
    SEM.st_disarmed = (ostat and ostat.disarmed) or pal[7]
    local chrome = b.chrome
    local ochr = ovr and ovr.chrome
    PANEL_BG    = (ochr and ochr.bg)    or chrome.bg
    COLOR_TRACK = (ochr and ochr.track) or chrome.track
    COLOR_TICK  = (ochr and ochr.tick)  or chrome.tick
    COLOR_DIM   = (ochr and ochr.dim)   or chrome.dim
    return pal   -- resolved palette handed to the other modules' set_palette (single source)
end

-- Palette memo for the rebuild path: build_overrides + the built-ins resolve only change when
-- the rendered scheme changes or settings are saved (settings_gen bumps then). Cache them so a
-- plain view switch (same scheme, no save) skips the ~57-role override scan and the resolve.
-- The cheap file-local / SEM assignments in set_palette still run on every rebuild (another
-- instance may have repainted them since).
-- `theme_dark` is the odd one out and rides here rather than in a top-level local of its own
-- (the locals wall; check_locals names this exact pattern as the relief). It answers "is the
-- RADIO's theme dark", which no scheme change and no settings save can move, so it is filled
-- once and never invalidated -- deliberately, and with the same limit builtins_cache already
-- carries: switching the EdgeTX theme without a reboot leaves it stale. Measured reason for
-- the memo: resolving it per rebuild costs ~35 instructions on EVERY cycle.
local pal_memo = { scheme = nil, gen = -1, neutral = nil, b = nil, ovr = nil, theme_dark = nil }

-- Palette for the Toolbox tool pages so they FIT the dashboard's look. The tools are kept
-- MONOCHROME like the detail pages (light = black on light-grey, dark = white on dark-grey):
-- header, labels and the +/- buttons use the theme fg/greys, and ONLY the VALUES carry the
-- scheme accent colour so they stand out (the "blue everywhere" of the old palette is gone).
-- Handed to the tool modules via wgt.tb_pal (the sunlight option overrides inside the module).
-- Data-driven: a descriptor either CARRIES its toolbox palette (def.toolbox, returned as a
-- fresh copy — same per-update allocation as before, and the tools must never write into the
-- registry's table) or, theme-following, it derives from the CURRENT resolved palette locals
-- (which include the user's colour overrides, as before).
local function toolbox_palette(def)
    local src = def.toolbox
    if src ~= nil then
        local t = {}
        for k, v in pairs(src) do t[k] = v end
        return t
    end
    if def.follows_theme then
        -- EdgeTX theme: mono theme fg/bg, values in the theme focus colour (reads the
        -- CURRENT resolved palette locals, incl. the user's colour overrides, as before)
        if pal_memo.theme_dark == nil then
            pal_memo.theme_dark = theme_luma(COLOR_THEME_SECONDARY3) < DARK_LUMA_THRESHOLD
        end
        return { bg = COLOR_THEME_SECONDARY3, accent = COLOR_THEME_PRIMARY1, hint = COLOR_THEME_DISABLED, line = COLOR_THEME_SECONDARY1,
                 text = COLOR_THEME_PRIMARY1, textDim = COLOR_THEME_DISABLED,
                 valText = COLOR_THEME_FOCUS, valHi = COLOR_THEME_WARNING, bannerBg = COLOR_THEME_WARNING, bannerFg = COLOR_THEME_PRIMARY2,
                 btnBg = COLOR_THEME_SECONDARY2, btnPressed = COLOR_THEME_SECONDARY1, btnDim = COLOR_THEME_SECONDARY3, btnFg = COLOR_THEME_PRIMARY2,
                 -- `dark` is what the Log Viewer and the Live Monitor pick their CURVE set
                 -- from, and this branch used to omit it -- so a pilot on this scheme with a
                 -- DARK radio theme got the light curves (deep blue, dark red) on a dark
                 -- chart. Judged from bg, the surface the chart is drawn on, and through
                 -- theme_luma rather than color_luma because bg is a theme INDEX here.
                 dark = pal_memo.theme_dark or nil }
    end
    -- own-palette descriptor WITHOUT explicit toolbox data (a skin-supplied scheme):
    -- derive the same mono look from the descriptor's own builtins — deliberately NOT
    -- from the palette locals, which may hold the menu-neutral forcing at this point
    local b = cached_builtins(def)
    return { bg = b.chrome.bg, accent = b.pal[1], hint = b.pal[8], line = b.chrome.track,
             text = b.pal[1], textDim = b.chrome.dim,
             valText = b.pal[6], valHi = b.pal[7], bannerBg = b.pal[7], bannerFg = b.pal[2],
             btnBg = b.chrome.track, btnPressed = b.chrome.dim, btnDim = b.chrome.bg, btnFg = b.pal[1],
             dark = b.dark_ui or nil }
end
-- Header font — set dynamically per build based on available space. Since the skin split
-- (stage 2) the ACTIVE SKIN sets these via the skin API's set_header(); the host component
-- builders (build_top_bar_element / the panels) read them.
-- MODULE-WIDE MUTABLES: only read these in code that runs AFTER the skin's set_header for
-- the current zone — a read before/outside that path sees the previous build's values.
local header_font = MIDSIZE
local header_h = 0
local card_gap = 2
local card_padding = 3
local compact_card_padding = math.max(2, card_padding - 1)
local default_view = "flight"
local STATS_VIEW_MODE_NEVER = 1
local STATS_VIEW_MODE_DISARMED = 2
local STATS_VIEW_MODE_DISCONNECTED = 3
local DEFAULT_STATS_VIEW_MODE = STATS_VIEW_MODE_DISARMED
local SIM_VIEW_SWITCH_INTERVAL = 12 * 100

local FONT_CONSTANTS = {}   -- filled IN PLACE by SETTINGS_GROUPS._build (stage 2a0); see there

local xlsize = _G["XLSIZE"]
local has_xlsize = (type(xlsize) == "number")
if has_xlsize then
    ultidash_functions.log("XLSIZE font constant found with value: " .. tostring(xlsize))
    FONT_CONSTANTS.XLSIZE = xlsize
end

local FONT_ORDER = { "XXLSIZE", "DBLSIZE", "MIDSIZE", "STDSIZE", "SMLSIZE", "TINSIZE" }
if has_xlsize then
    table.insert(FONT_ORDER, 2, "XLSIZE")
end

-- NOTE: each placed instance gets its OWN widget table (created in `create`). Every
-- placed instance is a full Dashboard (the second-screen views were removed); the
-- module-local `Shared` table in
-- ultidashFunctions stays as the snapshot the Status page and the detail builders
-- read, and as the dual-publisher detector for two placed instances.

--- Initialize the widget view state and fill in any missing defaults.
local function init_view_state(widget)
    widget.view = widget.view or { current = default_view, dirty = true, ever_armed = false }
    widget.view.current = widget.view.current or default_view
    if widget.view.ever_armed == nil then widget.view.ever_armed = false end
    return widget.view
end

--- Return a valid statistics view mode, falling back to the default when needed.
local function get_stats_view_mode(widget)
    if widget.options.StatsViewMode ~= STATS_VIEW_MODE_NEVER and widget.options.StatsViewMode ~= STATS_VIEW_MODE_DISARMED and widget.options.StatsViewMode ~= STATS_VIEW_MODE_DISCONNECTED then
        return DEFAULT_STATS_VIEW_MODE
    end
    return widget.options.StatsViewMode
end

--- Alternate between flight and stats views while running in the simulator.
local function get_simulation_target_view()
    local now = getTime() or 0
    local phase = math.floor(now / SIM_VIEW_SWITCH_INTERVAL) % 2
    if phase == 0 then
        return "flight"
    end
    return "stats"
end

--- Decide which high-level view should be active for the current telemetry state.
local function get_target_view(widget)
    local view = init_view_state(widget)
    local mode = get_stats_view_mode(widget)

    if ultidash_functions.simu_mode then
        return get_simulation_target_view()
    end

    if widget.values.rf_connection_state == "armed" then
        view.ever_armed = true
        -- NB: do NOT clear stats_dismissed here — the "armed" sub-state is unreliable on
        -- this RFTool and can briefly bounce back to "armed" right after disarming, which
        -- would undo a just-made manual dismiss ("stats closes then reopens instantly").
        -- A REAL arm clears the dismiss via the ARM sensor (armed_now) in the 5 Hz pass.
        return "flight"
    end
    -- C3: a deliberate tap on the flight view's status panel opened the page. It wins
    -- over StatsViewMode ("Never" governs the AUTOMATIC route only — a tap is a second,
    -- manual one), over ever_armed and over a standing manual dismiss. Cleared by the
    -- page's own X and by the next real arm (the ARM-sensor edge), nowhere else.
    if widget.stats_tap_open then
        return "stats"
    end
    if mode == STATS_VIEW_MODE_NEVER or view.ever_armed ~= true then
        return "flight"
    end
    -- manually dismissed (tap on the stats page) — stay on flight until the next
    -- arm or reconnect clears the flag
    if widget.stats_dismissed then
        return "flight"
    end
    if mode == STATS_VIEW_MODE_DISARMED then
        return "stats"
    end
    if mode == STATS_VIEW_MODE_DISCONNECTED and widget.values.rf_connection_state == "disconnected" then
        return "stats"
    end
    return "flight"
end

--- Switch the active view when telemetry state requires a different layout.
local function sync_view_for_telemetry(widget)
    local view = init_view_state(widget)
    local target_view = get_target_view(widget)
    if view.current == target_view then return false end

    view.current = target_view
    view.dirty = true
    widget.layout_dirty = true
    -- any flight/stats switch closes the ELRS detail page (it only overlays "flight")
    widget.detail_view = nil
    return true
end

--- Propagate telemetry state changes to services and update the selected view.
local function handle_telemetry_state_change(widget, previous_state, new_state)
    -- diagnostics: log every state transition (ring-buffer append, cheap) and REQUEST a
    -- prompt flush (no-op unless DebugLog on). The flush itself is SD work and this
    -- callback can run inside the RFTool's instruction budget (rf2.registerWidget
    -- delivers onStateChanged from ITS task) -- so only flag it here; the widget's own
    -- next refresh/background cycle performs it. The disarm/disconnect
    -- transition is where the in-flight buffer reaches the SD.
    if ultidash_functions.dbg then
        ultidash_functions.dbg.logf("STATE", "%s -> %s", tostring(previous_state), tostring(new_state))
        widget.dbg_flush_req = true
    end
    ultidash_functions.on_telemetry_state_changed(widget, previous_state, new_state)
    -- Scope ever_armed to THIS connection: on every fresh connect (disconnected -> any
    -- connected state) start a new "session". So the stats page (On disarmed / On
    -- disconnected) only appears after the craft was armed *this* connection — not
    -- because an earlier connection in the same widget runtime was armed. Without this,
    -- ever_armed stayed true for the whole runtime → stats showed on a later connect that
    -- never armed, and the dashboard stuck on old/stats values instead of returning to the
    -- flight view. Live values + stats are already cleared in on_telemetry_state_changed.
    if previous_state == "disconnected" and new_state ~= "disconnected" then
        init_view_state(widget).ever_armed = false
        -- NB: do NOT clear stats_dismissed on reconnect. A main-power-lost aftermath can
        -- bounce the link (disconnect/reconnect) while the pilot is trying to close the
        -- stats page, and re-clearing here reopened it. The "arming forgets the dismiss"
        -- clear (debounced, in the 5 Hz pass) is the single source for that reset now.
    end
    -- Flight log / battery management session edges (publisher-only: only the
    -- Dashboard registers this callback). All flags only -- the SD work runs
    -- deferred in its OWN refresh cycle (flt_flush_req / battpick_load_req).
    if new_state == "disconnected" then
        -- NOT `previous_state == "armed"`: the RF tool passes through "disarmed" on its way to
        -- "disconnected" at every real link loss (it loses the ARM value ~1.3 s in, its own
        -- timeout fires ~4.9 s later), so that test never matched in flight and this branch
        -- took its else. The flight record was then flushed only when the falling ARM edge
        -- arrived -- which is at the RECONNECT, by which time the same reconnect has reset the
        -- flight-time counter, so the flush computed 0 s and wrote no row at all. An in-flight
        -- dropout long enough for the tool to reconnect lost that flight's line entirely.
        -- ultidash_functions.disconnected_while_armed reads the ARM sensor, which holds its
        -- last received value through the gap; see its comment for why a normal disarm is
        -- unaffected.
        if ultidash_functions.disconnected_while_armed(widget, previous_state) then
            -- armed disconnect (crash / main power lost): flush the open flight
            -- record NOW -- a later reconnect resets the flight-time counter. The
            -- battery selection is KEPT (a telemetry blip / retrieve-and-replug
            -- continues the same pack); flt_disc_at bounds that window below.
            if widget.flt_open then widget.flt_flush_req = true end
            widget.flt_disc_at = getTime() or 0
        else
            -- normal disarmed unplug: the battery session is over
            widget.flt_batt_id = nil
            widget.flt_batt_counted = nil
            widget.flt_disc_at = nil
        end
        widget.battpick_wait = nil
        widget.flt_prof_req = nil   -- no FC left to write the profile to
    elseif previous_state == "disconnected" then
        -- fresh connect: after a LONG gap since an armed disconnect (> 2 min) assume
        -- a new pack was plugged in and drop the kept selection
        if widget.flt_batt_id ~= nil and widget.flt_disc_at ~= nil
            and ((getTime() or 0) - widget.flt_disc_at) > 12000 then
            widget.flt_batt_id = nil
            widget.flt_batt_counted = nil
        end
        widget.flt_disc_at = nil
        -- schedule the battery query (needs the FC-set model name -> settle delay);
        -- opened by the 5 Hz pass once fullscreen + disarmed with nothing else up
        if (widget.options.FltBatt or 0) == 1 and widget.flt_batt_id == nil then
            widget.battpick_wait = (getTime() or 0) + 300
        end
    end
    sync_view_for_telemetry(widget)
end

--- Prepare a widget instance once (view state only — RF services are publisher-only).
local function prepare_widget(widget)
    if not widget then return nil end
    if not widget.app_prepared then
        init_view_state(widget)
        widget.app_prepared = true
    end
    return widget
end

--- Attach the RF service lazily. Lazy (not in prepare_widget) so the service is
--- picked up on a normal cycle after create, in that cycle's own budget.
local function ensure_rf_service(widget)
    if widget.rf_service_ready then return end
    -- The RF service is the one part of the widget that is target-specific, so the
    -- declared craft target gates its LOAD. For 0.8.0 the condition is always true
    -- (Rotorflight is the only realised target and normalize_target maps everything
    -- onto it) -- it is structure for a second target, not a saving anyone sees.
    -- Not pcall'd, unlike the elrs_cfg block below: a missing ultidashRf.lua was fatal
    -- while this load sat at module level and stays fatal. Degrading the whole RF
    -- service to silence would hide the cause of a dashboard full of dashes.
    if rf_service == nil then
        if not (widget.opt_mod and widget.target == widget.opt_mod.TARGET_RF) then return end
        rf_service = loadScript(script_dir .. "ultidashRf.lua")()
    end
    -- 3rd arg: the ARM-sensor predicate for the MSP read gate — the
    -- service must never fire reads while the craft is armed, whatever the
    -- RFTool connection state claims
    -- 4th arg: a GETTER for the file logger, not the logger — ultidashDebug is lazy-loaded
    -- and ultidash_functions.dbg is nil until the DebugLog option is first turned on, so a
    -- reference captured here would stay nil for the whole session.
    -- 5th arg: the ELRS TX configuration client, loaded here rather than at module
    -- level so its load lands in THIS cycle's budget and not in create()'s. The RF
    -- service drives it because that is where the connect trigger and the ARM-sensor
    -- gate already are — a CRSF push costs an RC channel frame exactly like an MSP
    -- one does. pcall'd: a card without the file loses the ELRS Status page and
    -- nothing else.
    if elrs_cfg == nil then
        local ok, m = pcall(function() return loadScript(script_dir .. "ultidashElrs.lua")() end)
        if ok and type(m) == "table" then
            elrs_cfg = m
            elrs_cfg.init(function() return ultidash_functions.dbg end)
        end
    end
    -- 6th arg: a LOADER for the RFSuite MSP service back end, not the module. The RF service
    -- calls it the first time it sees `rfsuite.msp` published in this Lua state and never
    -- otherwise, so a card with RFTool -- or with neither -- pays nothing for the second
    -- provider. pcall'd like the ELRS client: a card without the file loses that provider
    -- and nothing else.
    rf_service.init(widget, handle_telemetry_state_change, ultidash_functions.is_armed,
                    function() return ultidash_functions.dbg end, elrs_cfg,
                    function()
                        local ok, m = pcall(function()
                            return loadScript(script_dir .. "ultidashRfs.lua")()
                        end)
                        if ok and type(m) == "table" then return m end
                        return nil
                    end)
    widget.sync_active_battery_capacity = rf_service.sync_active_battery_capacity
    widget.rf_service_ready = true
end

-- ============================================================================
-- UTILITY FUNCTIONS: Font management
-- ============================================================================

--- Measure font height and optionally reject it when a sample string is too wide.
local function measure_font(font_const, max_w, test_string)
    local test_text = test_string or "X"
    local text_w, text_h = lcd.sizeText(test_text, font_const)

    -- If width constraint provided, return -1 if text is too wide
    if max_w and text_w > max_w then
        return -1
    end

    return text_h
end

--- Pick the largest font that fits the available space and optional width sample.
local function select_font(available_h, available_w, test_string, font_limit)
    local start_index = 1
    if type(font_limit) == "string" and font_limit ~= "" then
        for i = 1, #FONT_ORDER do
            if FONT_ORDER[i] == font_limit then
                start_index = i
                break
            end
        end
    end

    local font_tolerance = 2 -- Allow up to 2 pixels of overshoot
    local max_h = available_h + font_tolerance

    for i = start_index, #FONT_ORDER do
        local font_name = FONT_ORDER[i]
        local font_const = FONT_CONSTANTS[font_name]
        if font_const then
            local font_h = measure_font(font_const, available_w, test_string)
            if font_h > 0 and font_h <= max_h then
                return font_const
            end
        end
    end

    local fallback = FONT_ORDER[#FONT_ORDER]
    return FONT_CONSTANTS[fallback] or FONT_CONSTANTS.STDSIZE
end

--- Return the smallest font from a list of candidate font constants.
local function pick_smallest_font(...)
    local selected_font = nil
    for i = 1, select("#", ...) do
        local font_const = select(i, ...)
        if font_const and (not selected_font or measure_font(font_const) < measure_font(selected_font)) then selected_font =
            font_const end
    end
    return selected_font or STDSIZE
end

--- Build a reusable card rectangle and its child LVGL elements.
local function build_card_element(container, x, y, c_w, c_h, children)
    container:build({
        {
            type = "rectangle",
            x = x,
            y = y,
            w = c_w,
            h = c_h,
            thickness = show_debug_border,
            color = COLOR_THEME_SECONDARY2,
            filled = false,
            children = children
        }
    })
end

--- Add a centered stacked field with a label above its value.
local function add_stacked_field(children, x, y, c_w, row_padding, label_text, value_text, value_font, value_h)
    local label_y = y + row_padding
    children[#children + 1] = {
        type = "label",
        x = x,
        y = label_y,
        w = c_w,
        h = header_h,
        text = label_text,
        font = header_font,
        color = COLOR_THEME_SECONDARY1,
        align = CENTER
    }
    children[#children + 1] = {
        type = "label",
        x = x,
        y = label_y + header_h,
        w = c_w,
        h = value_h,
        text = value_text,
        font = value_font,
        color = COLOR_THEME_PRIMARY1,
        align = CENTER
    }
end

-- ── Configurable telemetry value slots ───────────────────────────────────────
-- The right-hand value panel (5 slots) and the "Telemetry" detail page (8 slots)
-- show sensors the user picks in Settings ▸ Values. A selection is stored as the
-- EdgeTX sensor NAME (a string in the cfg file) so the chosen sensor stays
-- identified even offline / before EdgeTX has (re)discovered it. Three sentinels are
-- not real sensors: SENSOR_OFF (empty slot), VOLT_AUTO (the smart cell/battery
-- voltage with warn colour — the dashboard's original slot-1 behaviour) and
-- ESCL_AUTO (the computed ESC utilization %, see update_esc_load_warning).
local SENSOR_OFF = "~off"
local VOLT_AUTO  = "~volt"
local ESCL_AUTO  = "~escl"
-- Dropdown DISPLAY state only (never stored): marks "this slot holds a raw sensor
-- picked via the native raw field". Keeps the curated dropdown short — raw names
-- don't get folded into it; the dropdown just shows this one "‹ Raw ›" entry and
-- the raw field shows which source it is.
local RAW_SENTINEL = "~raw"

-- Friendly label + default decimals for known Rotorflight / ELRS sensor names
-- (EdgeTX only stores the terse 4-char name). Unknown sensors fall back to their
-- raw name and the precision reported live by model.getSensor.
-- cap = optional COMPACT caption for card-style layouts (skins): `lbl` is prose that reads
-- badly in a narrow card ("BEC Voltage" -> "BEC", "Energy Used" -> "Used"). Handed to skins
-- as sensor_slot().label_short; absent -> `lbl` is already short enough.
-- appId = the Rotorflight custom-telemetry app ID (0x1000+ range, from rf2tlm_sensors.lua).
-- It is the STABLE, unique reference: EdgeTX can create a same-named native CRSF sensor
-- (RxBt/Curr/Capa/Bat% …), so name lookups are ambiguous; the app-id resolver reads the RIGHT
-- sensor by this ID. ELRS link + name-only sensors carry no appId (no RF custom sensor).
local SENSOR_INFO = {}   -- filled IN PLACE by SETTINGS_GROUPS._build (stage 2a0); see there

-- appId -> canonical SENSOR_INFO name (built from the table above), for the app-id resolver:
-- a scanned sensor whose model-sensor `id` matches an appId is our known sensor, even if the
-- user renamed it or a native CRSF sensor stole the name.
local NAME_BY_APPID = {}

-- precision learned live from model.getSensor (used only for unknown sensors)
local sensor_prec_cache = {}

-- Sensors the dashboard already computes into wgt.values.* (with latching /
-- plausibility filtering AND simulator demo data). Prefer those fields over a raw
-- getSourceValue read: correct on hardware and populated in the simulator, where
-- getSourceValue has no real sensors. Other sensors fall back to the 5 Hz cache.
local SENSOR_VALUE_FIELD = {}   -- filled IN PLACE by SETTINGS_GROUPS._build (stage 2a0); see there

-- keys of all configurable value slots (5 panel + 12 detail)
local PANEL_SLOT_KEYS  = { "PanelV1", "PanelV2", "PanelV3", "PanelV4", "PanelV5" }
local DETAIL_SLOT_KEYS = { "DetV1", "DetV2", "DetV3", "DetV4", "DetV5", "DetV6",
                          "DetV7", "DetV8", "DetV9", "DetV10", "DetV11", "DetV12" }
-- Sensor slot keys declared by the ACTIVE skin (its manifest's kind="sensor" rows) live
-- in SKINS._sensor_keys (a FIELD, not a new local — the main chunk is at the 200-local
-- limit). The 5 Hz pass (update_user_sensors) pulls these too, so a skin's own sensor
-- slots get live values exactly like Tele Main / Details. Filled by refresh_skin_menus
-- when the active skin changes (only the active skin's keys — inactive skins cost nothing).
-- Switch shortcuts: all data AND the engine hang off ONE table (`shortcut`) so the
-- feature costs a single main-chunk local (the chunk is near Lua's 200-local limit).
-- `shortcut.targets` = the pages a configured switch position / toggle can open. The
-- choice value stored in the cfg is the 1-based INDEX into this list, so APPEND new
-- entries at the END and NEVER reorder (old cfg values would then point elsewhere).
-- index 1 = "Off" (no assignment). MAINTAIN THIS LIST whenever a detail page or a
-- Toolbox tool is added — it is the single place the shortcut menu is fed from.
--   kind = "none"   -> the Off entry
--   kind = "detail" -> a tap-to-open detail overlay (id = wgt.detail_view value)
--   kind = "tool"   -> a Toolbox page (id = wgt.menu_view value)
--     disarmed = true -> refuse to open while armed (MSP / file tools)
--     load     = "logview"/"rf2cfg" -> lazy-load the module before opening
-- The open/close/run methods are attached further down (after close_tool_page, where
-- init_view_state / the tb_load_* loaders are in scope).
local shortcut = {}
shortcut.targets = {
    -- labels follow one "Category: Name" scheme — detail overlays carry a "Page:"
    -- prefix, Toolbox tools a "Toolbox:" prefix — so the dropdown reads consistently
    -- and makes clear WHAT opens (renaming is safe — the cfg stores the index).
    -- APPEND new entries at the END and NEVER reorder (old cfg values would then
    -- point elsewhere).
    { id = "off",       lbl = "Off",                  kind = "none" },
    { id = "elrs",      lbl = "Page: ELRS",           kind = "detail" },
    { id = "estatus",   lbl = "Page: Status log",     kind = "detail" },
    { id = "battery",   lbl = "Page: Battery",        kind = "detail" },
    { id = "telem",     lbl = "Page: Telemetry",      kind = "detail" },
    { id = "tb_adjmap", lbl = "Toolbox: Adjust Map",  kind = "tool" },
    { id = "tb_adjed",  lbl = "Toolbox: Adjust Edit", kind = "tool" },
    { id = "tb_logview",lbl = "Toolbox: Log Viewer",  kind = "tool", disarmed = true, load = "logview" },
    { id = "tb_rf2cfg", lbl = "Toolbox: RF2 Config",  kind = "tool", disarmed = true, load = "rf2cfg" },
    { id = "tb_fltlog", lbl = "Toolbox: Flight Log",  kind = "tool", disarmed = true, load = "fltlog" },
    -- The FC battery-profile picker. It is a host
    -- feature whose only other way in is a TAP ZONE, and the zone belongs to whichever skin
    -- is active -- `minimal` registers none, and any assignable layout can be configured
    -- into a state that has none. A skin must not be able to remove a host feature, so this
    -- is the route it cannot take away, together with the Toolbox tile.
    -- `msp = true` is the extra gate the other tools do not need: this is the one page that
    -- WRITES to the flight controller, so it replicates the tap's full condition rather than
    -- just the disarmed rule -- see shortcut.open.
    { id = "battprofile", lbl = "FC battery profile", kind = "tool", disarmed = true, msp = true },
    -- D3: the spoken telemetry report. kind = "action" opens no page: the "open" fires
    -- the report (armed included -- the user's decision; the callout engine keeps
    -- precedence), a HELD position slot repeats it at TsayInt, the release stops the
    -- repeat but never cuts a running report (a momentary press is one report).
    { id = "telemsay", lbl = "Voice: Telemetry report", kind = "action" },
    -- M2: the menu (options) on a switch. Its armed rule is the MENU GLYPH's own,
    -- shared through shortcut.menu_allowed rather than copied -- the user's requirement
    -- ("genauso wie der tap auf die zone"): blocked only while GENUINELY flying.
    { id = "menu", lbl = "Page: Menu / settings", kind = "menu" },
    -- M5: the Live Monitor. NO disarmed and NO msp on purpose -- reading it in flight
    -- is the tool's point, and it touches EdgeTX telemetry sources only.
    { id = "tb_livemon", lbl = "Toolbox: Live Monitor", kind = "tool" },
    -- RFSuite. APPENDED, never inserted -- the cfg stores the INDEX, so an
    -- entry anywhere above would silently repoint every saved shortcut. Disarmed-only
    -- like RF2 Config; no msp flag, because RFSuite brings its own MSP stack and
    -- rf_service.refresh_data would be the wrong queue to prime.
    -- The "(exp.)" the Toolbox tile carries, on the shortcut picker too -- a switch is the
    -- other way in, and it must not be the way in that says nothing. 23 characters, the
    -- length of the longest entry above it, so the picker's value column is unchanged.
    { id = "tb_rfscfg", lbl = "Toolbox: RFSuite (exp.)", kind = "tool", disarmed = true, load = "rfscfg" },
}

-- The one armed condition the menu glyph and the M2 shortcut share: the menu is
-- refused only while the craft is genuinely flying -- armed by the ARM sensor AND not
-- disconnected. A field, not a local (the main chunk is at Lua's 200-local limit),
-- and ONE definition so the two entry points can never drift apart.
shortcut.menu_allowed = function(wgt)
    return not (ultidash_functions.is_armed(wgt)
        and wgt.values.rf_connection_state ~= "disconnected")
end
-- choice-row labels for the shortcut settings (built once, mirrors shortcut.targets)
shortcut.tlabels = {}
for i = 1, #shortcut.targets do shortcut.tlabels[i] = shortcut.targets[i].lbl end

-- The "open a page on arming" choice (Display ▸ Behaviour) reuses THIS list, filtered to
-- Off + the four detail overlays: they are the only targets that can open while armed, a
-- Toolbox tool being disarmed-only by construction. The filter PRESERVES the order, so
-- the append-only rule above covers the filtered list too -- a fifth detail page appended
-- to targets lands at the end of this list as well and shifts no stored value. The two
-- helpers are FIELDS on this table, not module locals: the main chunk is at Lua's 200.
shortcut.detail_labels = function()
    local v = {}
    for i = 1, #shortcut.targets do
        local t = shortcut.targets[i]
        if t.kind == "none" or t.kind == "detail" then v[#v + 1] = t.lbl end
    end
    return v
end
shortcut.detail_choice = function(n)
    if n == nil or n <= 1 then return nil end   -- 1 = Off
    local k = 0
    for i = 1, #shortcut.targets do
        local t = shortcut.targets[i]
        if t.kind == "none" or t.kind == "detail" then
            k = k + 1
            if k == n then return t end
        end
    end
    return nil
end

local function is_off_sensor(name)
    return name == nil or name == SENSOR_OFF or name == ""
end

-- a "raw" pick = a sensor name UltiDash doesn't curate (not Off / the two virtual
-- entries / a known SENSOR_INFO name). These are chosen via the native raw field and
-- shown in the curated dropdown only as the single ‹ Raw › state.
local function is_raw_sensor(name)
    return not is_off_sensor(name) and name ~= VOLT_AUTO and name ~= ESCL_AUTO
        and name ~= RAW_SENTINEL and SENSOR_INFO[name] == nil
end

local function sensor_dec(name)
    local info = SENSOR_INFO[name]
    if info then return info.dec end
    local p = sensor_prec_cache[name]
    if type(p) == "number" then return p end
    return 1
end

-- short label for the panel / detail cell (no parenthetical raw name)
local function sensor_short_label(name)
    if is_off_sensor(name) then return "" end
    if name == VOLT_AUTO then return "Voltage" end
    local info = SENSOR_INFO[name]
    if info then return info.lbl end
    return name
end

-- unit suffix for the value (telemetry detail page). Known sensors carry it in
-- SENSOR_INFO; VOLT_AUTO is the smart voltage → "V"; unknowns have no unit string
-- (EdgeTX only exposes a numeric unit id, too version-fragile to map reliably).
local function sensor_unit(name)
    if name == VOLT_AUTO then return "V" end
    local info = SENSOR_INFO[name]
    return (info and info.unit) or ""
end

-- label shown in the settings dropdown (friendly). Curated names get their nice
-- label; the ‹ Raw › entry is the display state for a raw pick (chosen in the raw
-- field, not here).
local function sensor_pick_label(name)
    if is_off_sensor(name) then return "— Off —" end
    if name == VOLT_AUTO then return "Voltage (auto)" end
    if name == ESCL_AUTO then return "ESC Load (calc)" end
    if name == RAW_SENTINEL then return "‹ Raw sensor ›" end
    local info = SENSOR_INFO[name]
    if info then return info.lbl .. " (" .. name .. ")" end
    return name
end

-- App-id sensor resolver (session cache in wgt.sensor_idx). Maps each curated sensor NAME to
-- a VERIFIED telemetry READ INDEX, so reads hit the right RF custom sensor even when a native
-- CRSF sensor shares the name or the user renamed it. Telemetry sources sit as value/min/max
-- triples in MIXSRC space (value idx of model-sensor i = base + 3*i; min/max = +1/+2). The
-- base is derived AND validated purely from getFieldInfo over the UNIQUELY named sensors:
-- every unique anchor must yield the same base (fid - 3*i), any inconsistency rejects the
-- whole map and read_src falls back to the plain name read (today's behaviour). NOTE: no
-- per-candidate getSourceName check here -- that function enumerates a DIFFERENT index
-- space on this radio (see the base derivation below). Throttled by the caller -- never
-- per frame.
local function resolve_sensor_indices(wgt)
    if model == nil or type(model.getSensor) ~= "function" then return end
    -- Cheap change signature over the sensor list: the expensive derivation below only
    -- reruns when the model's sensors actually changed (discovery, delete, reorder).
    -- Renames keep the slot+id, so a stale map stays CORRECT (index reads are rename-immune
    -- by design).
    --
    -- SCRATCH TABLES REUSED ACROSS CALLS. This function runs every 3 s for the whole
    -- session, connected and disconnected, and it used to build a FRESH `scan` with ~40
    -- {name,id} entries plus two containers on every run -- then, on the overwhelmingly
    -- common unchanged path, throw all of it away again at the signature test below. That
    -- was ~33 table allocations per second amortised, the largest steady allocator in the
    -- widget's own files and a standing contributor to the GC duty cycle that rides the
    -- widget's budget. Now the entries are filled IN PLACE and outlive the call, so the
    -- steady state allocates nothing at all here.
    -- The obvious alternative -- signature first, build the scan only after it moved --
    -- was measured and rejected: it needs a SECOND pass of 60 model.getSensor probes on
    -- the change path, +1 085 instructions on that cycle (differential run, everything
    -- else unmoved), for exactly the same steady-state saving.
    -- The 60 probes themselves are API-imposed: each returns an EdgeTX-allocated table and
    -- there is no way to ask for the id alone. That garbage stays.
    local scan = wgt.sensor_scan
    if scan == nil then scan = {}; wgt.sensor_scan = scan end
    local name_count = wgt.sensor_ncount
    if name_count == nil then name_count = {}; wgt.sensor_ncount = name_count end
    for k in pairs(name_count) do name_count[k] = nil end
    local sig = 0
    for i = 0, 59 do
        local ok, s = pcall(model.getSensor, i)
        if ok and type(s) == "table" and type(s.name) == "string" and s.name ~= "" then
            local e = scan[i]
            if e == nil then e = {}; scan[i] = e end
            e.name, e.id = s.name, s.id
            sig = (sig * 33 + (type(s.id) == "number" and s.id or 1) + i) & 0x7FFFFFFF
            name_count[s.name] = (name_count[s.name] or 0) + 1
        else
            -- a slot that went away must not survive as a ghost entry in the reused table
            scan[i] = nil
        end
    end
    if sig == wgt.sensor_sig and wgt.sensor_idx ~= nil then return end
    wgt.sensor_sig = sig
    -- Telemetry values live in the getFieldInfo/getValue index space as one triple per model
    -- sensor SLOT: value id of slot i = base + 3*i (verified on hardware: fid(1RSS@0)=284,
    -- fid(2RSS@1)=287, ... perfectly 3-spaced). NOTE this is NOT getSourceName's index space
    -- (different enumeration on this radio) -- so derive AND validate the base purely from
    -- getFieldInfo over the UNIQUELY named sensors: every unique anchor must yield the SAME
    -- base (fid - 3*i). Duplicates can't poison this (getFieldInfo is only called for names
    -- without a twin); any inconsistency (holes, other layout) -> no map -> name-read fallback.
    local base
    for i = 0, 59 do
        local e = scan[i]
        if e and name_count[e.name] == 1 then
            local okfi, fi = pcall(getFieldInfo, e.name)
            if okfi and type(fi) == "table" and type(fi.id) == "number" then
                local cand = fi.id - 3 * i
                if base == nil then base = cand
                elseif base ~= cand then base = false; break end   -- inconsistent -> reject
            end
        end
    end
    -- base proven consistent across all anchors -> map every sensor with a KNOWN app-id to its
    -- slot's value id. Duplicate pairs resolve correctly because the RF-custom twin sits in its
    -- own slot with its own app-id (the native CRSF twin's small frame id isn't in the map).
    local map
    if type(base) == "number" then
        map = {}
        for i = 0, 59 do
            local e = scan[i]
            local canon = e and e.id and NAME_BY_APPID[e.id]    -- our curated name for this app-id
            if canon then map[canon] = base + 3 * i end
        end
    end
    wgt.sensor_idx = map or {}
    -- diagnostic (only when the outcome changes; needs DebugLog on): how many sensors resolved
    -- by app-id, or a safe fall-back to name reads
    local cnt = 0; if map then for _ in pairs(map) do cnt = cnt + 1 end end
    -- CAPABILITY SET, derived from what the radio actually carries -- never from the declared
    -- target. An abstract flag can be wrong; a derived set cannot disagree with the radio, and
    -- keeping both and comparing them is what turns a wrong setting into a sentence on screen
    -- (see `norf` below). Built here, inside the signature gate above, so it costs nothing per
    -- cycle: this function only gets past that gate when the model's sensors changed, and the
    -- pass it rides on returns without doing anything else (~500 instr in a ~3400 cycle).
    -- Read out of the SCAN's app-ids, not out of `map`: NAME_BY_APPID is built from
    -- SENSOR_INFO, and the arming state (0x1202), the governor state (0x1205) and the two ESC
    -- status words (0x104F signature / 0x104E flags) are not SENSOR_INFO rows -- they are read
    -- by NAME. `map` can therefore never carry them, and a caps built from it would report
    -- "no governor" for every craft that has one. The scan holds the same evidence, and it
    -- holds it whether or not the app-id base resolved.
    local cgov, cesc, carm, nsen = false, false, false, 0
    for i = 0, 59 do
        local e = scan[i]
        if e then
            nsen = nsen + 1
            if e.id == 0x1205 then cgov = true
            elseif e.id == 0x1202 then carm = true
            elseif e.id == 0x104F or e.id == 0x104E then cesc = true end
        end
    end
    wgt.caps = {
        gov = cgov, esc = cesc, arm = carm,
        msp = wgt.target == (wgt.opt_mod and wgt.opt_mod.TARGET_RF),
        -- `norf` is cross-check STATE, not a capability: the three conditions of the target
        -- cross-check that this pass can observe -- the model carries telemetry sensors, the
        -- app-id base was derived AND validated (`map` exists, so this is not the name-read
        -- fallback), and not one curated Rotorflight app-id resolved. The fourth condition,
        -- "telemetry is connected", moves between two of these scans and is read live at the
        -- display sites. All four together are the POSITIVE CONTROL: "no Rotorflight sensor"
        -- is equally true before discovery, with the link down and when the base could not be
        -- derived, so firing on absence alone would alarm on every cold radio.
        norf = map ~= nil and nsen > 0 and cnt == 0,
    }
    if cnt ~= wgt.sensor_idx_n then
        wgt.sensor_idx_n = cnt
        if ultidash_functions.dbg then
            ultidash_functions.dbg.logf("SENSOR", "app-id resolver: %s (base=%s)",
                map and (cnt .. " sensors mapped") or "name-read fallback (base unverified)", tostring(base))
        end
    end
end

-- Build the CURATED pick list for the settings dropdown: Off + smart-voltage +
-- ESC load + only the model's sensors that UltiDash KNOWS (SENSOR_INFO — with
-- friendly labels), so the list stays short. Everything else is picked via the
-- native raw source field instead; a currently chosen raw name is still added
-- (labelled "Raw: …") so the dropdown can DISPLAY it and a stored selection
-- stays selectable offline. Codes are the NAME strings stored in the cfg.
local function build_sensor_list(wgt)
    local labels = { sensor_pick_label(SENSOR_OFF), sensor_pick_label(VOLT_AUTO), sensor_pick_label(ESCL_AUTO) }
    local codes  = { SENSOR_OFF, VOLT_AUTO, ESCL_AUTO }
    local seen   = { [SENSOR_OFF] = true, [VOLT_AUTO] = true, [ESCL_AUTO] = true }
    local function add(name)
        if name == nil or name == "" or seen[name] then return end
        seen[name] = true
        labels[#labels + 1] = sensor_pick_label(name)
        codes[#codes + 1]   = name
    end
    if model ~= nil and type(model.getSensor) == "function" then
        for i = 0, 59 do
            local ok, s = pcall(model.getSensor, i)
            if ok and type(s) == "table" and type(s.name) == "string" and s.name ~= "" then
                if type(s.prec) == "number" then sensor_prec_cache[s.name] = s.prec end
                if SENSOR_INFO[s.name] then
                    add(s.name)                               -- curated: known by name
                elseif s.id and NAME_BY_APPID[s.id] then
                    add(NAME_BY_APPID[s.id])                  -- known by RF app-id (renamed sensor)
                end
            end
        end
    end
    -- keep a currently-chosen KNOWN sensor selectable even offline (before
    -- model.getSensor has (re)discovered it). Raw picks are NOT added — they show
    -- via the ‹ Raw › entry, so the curated list stays short.
    -- Read the open page's UNSAVED edits first and fall back to the live options PER KEY.
    -- This used to be one `wgt.settings_working or wgt.options` pick, which was equivalent
    -- while the working copy carried the whole catalogue. Since the seed became
    -- page-scoped (ultidashMenu.lua, 2026-08-17) a working copy exists that holds only the
    -- open page's slots, and a whole-table pick would hand `nil` for every slot configured
    -- on another page -- silently dropping those sensors from the pick list while a
    -- telemetry page is open, which is exactly when the list is looked at.
    local work = wgt.settings_working
    local opts = wgt.options or {}
    local function add_known(k)
        local name = work and work[k]
        if name == nil then name = opts[k] end
        if name and SENSOR_INFO[name] then add(name) end
    end
    for i = 1, #PANEL_SLOT_KEYS  do add_known(PANEL_SLOT_KEYS[i])  end
    for i = 1, #DETAIL_SLOT_KEYS do add_known(DETAIL_SLOT_KEYS[i]) end
    -- trailing display state for a raw pick (selecting it is inert — pick the raw
    -- sensor in the raw field beside the dropdown)
    labels[#labels + 1] = sensor_pick_label(RAW_SENTINEL)
    codes[#codes + 1]   = RAW_SENTINEL
    return labels, codes
end

-- Cheap reactive text getter for a configured sensor slot: reads the 5 Hz cache,
-- never does a sensor name-lookup itself (see update_user_sensors).
local function sensor_value_text(wgt, name)
    local fmt = "%." .. sensor_dec(name) .. "f"
    local field = SENSOR_VALUE_FIELD[name]
    -- memo via closure upvalues: this reactive text runs every render frame but the
    -- value only changes on the 5 Hz pass, so re-run string.format (allocate) only on
    -- change. Each panel gets its own closure -> its own private cache, no shared table.
    local last_v, last_s, primed = nil, "-", false
    return function()
        local v
        if field then v = wgt.values[field] end
        if v == nil then
            local cache = wgt.values.user_sensors
            v = cache and cache[name]
        end
        if primed and v == last_v then return last_s end
        last_v = v
        last_s = (v == nil) and "-" or string.format(fmt, v)
        primed = true
        return last_s
    end
end

-- Like sensor_value_text but ALWAYS the RAW sensor reading (user_sensors_raw, filled
-- while the telemetry detail page is open). The detail page shows raw data so the value
-- matches its raw "min .. max" chip — no latching / plausibility filtering / mapping.
local function sensor_value_text_raw(wgt, name)
    local fmt = "%." .. sensor_dec(name) .. "f"
    local last_v, last_s, primed = nil, "-", false
    return function()
        local cache = wgt.values.user_sensors_raw
        local v = cache and cache[name]
        if primed and v == last_v then return last_s end
        last_v = v
        last_s = (v == nil) and "-" or string.format(fmt, v)
        primed = true
        return last_s
    end
end

-- Memoized reactive label text: re-run `build` (the allocating format/concat) only
-- when `input()` changes. Reactive closures run every LVGL frame (rule 4) -- the memo
-- keeps steady frames alloc-free. `primed` guards the nil-first-call case.
local function memo_text(input, build)
    local last_in, last_s, primed
    return function()
        local v = input()
        if primed and v == last_in then return last_s end
        last_in, last_s, primed = v, build(v), true
        return last_s
    end
end

-- Reactive low/high text for a sensor slot: EdgeTX keeps a per-sensor session
-- min/max, addressable by appending "-" / "+" to the name (e.g. Tesc-, Tesc+) — we
-- cache both at 5 Hz (update_user_sensors) and format them as "min .. max" here.
-- VOLT_AUTO is synthetic (smart cell/battery voltage) → reuse its own min/max getters.
-- MEMOIZED on the raw inputs: up to 12 of these chips sit on the Telem
-- detail and each closure ran two string.format + concats per LVGL frame — now the
-- string rebuilds only when the cached min/max actually move (5 Hz at most).
local function sensor_minmax_text(wgt, name)
    if name == VOLT_AUTO then
        local lo = wgt.values.display_voltage_min_formatted
        local hi = wgt.values.display_voltage_max_formatted
        local k1, k2, s
        return function()
            local n1 = lo and lo() or "-"
            local n2 = hi and hi() or "-"
            if s == nil or n1 ~= k1 or n2 ~= k2 then
                k1, k2 = n1, n2
                s = n1 .. " .. " .. n2
            end
            return s
        end
    end
    if name == ESCL_AUTO then
        -- computed value, no EdgeTX session min/max: the chip shows the session limit
        local k1, s
        return function()
            local lim = wgt.values.esc_load_limit
            if s == nil or lim ~= k1 then
                k1 = lim
                s = lim and ("limit " .. lim .. " A") or "not set"
            end
            return s
        end
    end
    local fmt = "%." .. sensor_dec(name) .. "f"
    local k1, k2, s
    return function()
        local mn = wgt.values.user_sensors_min
        local mx = wgt.values.user_sensors_max
        local lo = mn and mn[name]
        local hi = mx and mx[name]
        if s == nil or lo ~= k1 or hi ~= k2 then
            k1, k2 = lo, hi
            s = (lo and string.format(fmt, lo) or "-") .. " .. " .. (hi and string.format(fmt, hi) or "-")
        end
        return s
    end
end

-- a wide sample string for font sizing, by decimals
local function sensor_test_text(name)
    local d = sensor_dec(name)
    if d <= 0 then return "9999" end
    if d == 1 then return "999.9" end
    return "99.99"
end

-- Reactive color for the virtual ESC-load value: neutral below warn, then the same
-- warn/crit palette as the panel's utilization bar (theme-aware via the SEM_* set).
local function esc_load_color(wgt)
    return function()
        local p = wgt.values.esc_load_pct
        if p == nil then return COLOR_THEME_PRIMARY1 end
        local o = wgt.options
        if p >= ((o and o.EscCrit) or 100) then
            return SEM_RED
        end
        if p >= ((o and o.EscWarn) or 80) then
            return SEM_YELL
        end
        return COLOR_THEME_PRIMARY1
    end
end

-- 5 Hz pass: refresh the cache of user-selected sensor values. A nil reading (no
-- telemetry) KEEPS the last value, so the panel/detail stay populated while
-- configuring with no craft connected.
--
-- COST DISCIPLINE: every getSourceValue is a sensor-name lookup, and piling them on
-- the 5 Hz pass starves the Lua scheduler enough to make fullscreen taps laggy (same
-- lesson as the 5 Hz throttle itself). So the EdgeTX session min/max ("-"/"+" reads)
-- are fetched ONLY while the telemetry detail page is actually open — on the
-- dashboard this stays as cheap as before (just the non-mapped panel/detail values).
local function update_user_sensors(wgt)
    local o = wgt.options
    if o == nil then return end
    local v = wgt.values
    local cache = v.user_sensors; if cache == nil then cache = {}; v.user_sensors = cache end

    -- RAW picks: the stored name is getSourceName's DISPLAY string, but
    -- getSourceValue's STRING lookup (luaFindFieldByName, 2.12 api_general.cpp)
    -- matches the sensor LABEL — the two don't reliably round-trip, so raw slots
    -- read "-". Fix: getSourceValue also accepts the numeric MIXSRC index (same
    -- space as getSourceName / the lvgl.source picker), and the picker's index is
    -- persisted as the <slot>Raw shadow key. Verify index -> name still matches
    -- (getSourceName), then read BY INDEX. Telemetry sources come as value/min/max
    -- index triples (idx / idx+1 "-" / idx+2 "+"), each verified by name before
    -- use. Verification is cached per name (re-checked only when the persisted
    -- index changes) so the 5 Hz pass stays cheap — index reads are cheaper than
    -- the failing name lookups were.
    local raw_src = wgt.raw_src; if raw_src == nil then raw_src = {}; wgt.raw_src = raw_src end
    local function raw_sources(name, key)
        if not is_raw_sensor(name) then return nil end
        local idx = o[key .. "Raw"]
        if type(idx) ~= "number" or idx == 0 then return nil end
        local rs = raw_src[name]
        if rs and rs.probe == idx then return rs.ok and rs or nil end
        rs = { probe = idx, ok = false }
        local okn, n = pcall(getSourceName, idx)
        if okn and n == name then
            rs.ok = true
            rs.v = idx
            local okm, m = pcall(getSourceName, idx + 1)
            if okm and m == name .. "-" then rs.mn = idx + 1 end
            local okx, x = pcall(getSourceName, idx + 2)
            if okx and x == name .. "+" then rs.mx = idx + 2 end
        end
        raw_src[name] = rs
        return rs.ok and rs or nil
    end

    -- main values: mapped sensors already live in wgt.values.* (latched /
    -- plausibility-filtered / simulator demo); others read the raw EdgeTX source —
    -- raw picks by verified index, everything else (and as fallback) by name
    local function pull_val(key)
        local name = o[key]
        if is_off_sensor(name) or name == VOLT_AUTO or SENSOR_VALUE_FIELD[name] then return end
        local rs = raw_sources(name, key)
        local ok, val
        if rs then ok, val = pcall(getSourceValue, rs.v) end
        if not (ok and val ~= nil) then ok, val = pcall(ultidash_functions.read_src, wgt, name) end
        if ok and val ~= nil then cache[name] = val end
    end
    for i = 1, #PANEL_SLOT_KEYS  do pull_val(PANEL_SLOT_KEYS[i])  end
    for i = 1, #DETAIL_SLOT_KEYS do pull_val(DETAIL_SLOT_KEYS[i]) end
    -- the active skin's own sensor slots (empty for the built-in skins)
    local sk = SKINS._sensor_keys
    for i = 1, #sk do pull_val(sk[i]) end
    -- Names registered by env.threshold_for for a row with no host field and no other
    -- producer -- today only Tmcu, whose mcu_temp_max is max-only so nothing else fetches
    -- it. By NAME, not by cfg key: there is no setting behind these, something simply asked
    -- for the value. The list is empty unless a build actually called threshold_for for such
    -- a row, and it is cleared on every skin rebuild, so a deselected consumer stops costing
    -- its read within one cycle.
    local ex = SKINS._extra_names
    if ex ~= nil then
        for i = 1, #ex do
            local nm = ex[i]
            local ok, val = pcall(ultidash_functions.read_src, wgt, nm)
            if ok and val ~= nil then cache[nm] = val end
        end
    end

    -- value + low/high, for the two consumers that show them: the open telemetry detail
    -- page (raw value + "min .. max" chip, its own slots) and a skin that declared
    -- M.wants_extrema (its sensor slots' .min_formatted / .max_formatted). Both are
    -- OPT-IN because each sensor costs two extra source reads per pass — the dashboard
    -- itself stays as cheap as before.
    local want_telem = (wgt.detail_view == "telem")
    local want_skin  = (SKINS._want_extrema == true)
    if want_telem or want_skin then
        local craw = v.user_sensors_raw; if craw == nil then craw = {}; v.user_sensors_raw = craw end
        local cmin = v.user_sensors_min; if cmin == nil then cmin = {}; v.user_sensors_min = cmin end
        local cmax = v.user_sensors_max; if cmax == nil then cmax = {}; v.user_sensors_max = cmax end
        local function pull_extremes(key, with_raw)
            local name = o[key]
            if is_off_sensor(name) or name == VOLT_AUTO or name == ESCL_AUTO then return end
            local rs = raw_sources(name, key)
            if with_raw then
                local okv, val
                if rs then okv, val = pcall(getSourceValue, rs.v) end
                if not (okv and val ~= nil) then okv, val = pcall(ultidash_functions.read_src, wgt, name) end
                if okv and val ~= nil then craw[name] = val end
            end
            local okn, vmin
            if rs and rs.mn then okn, vmin = pcall(getSourceValue, rs.mn) end
            if not (okn and vmin ~= nil) then okn, vmin = pcall(ultidash_functions.read_src, wgt, name .. "-") end
            if okn and vmin ~= nil then cmin[name] = vmin end
            local okx, vmax
            if rs and rs.mx then okx, vmax = pcall(getSourceValue, rs.mx) end
            if not (okx and vmax ~= nil) then okx, vmax = pcall(ultidash_functions.read_src, wgt, name .. "+") end
            if okx and vmax ~= nil then cmax[name] = vmax end
        end
        -- the detail page shows RAW data, so it needs the raw value too; a skin card shows
        -- the same latched value as the dashboard and only wants the extrema
        if want_telem then
            for i = 1, #DETAIL_SLOT_KEYS do pull_extremes(DETAIL_SLOT_KEYS[i], true) end
        end
        if want_skin then
            for i = 1, #sk do pull_extremes(sk[i], false) end
        end
    end
end

--- Build the left flight panel with live telemetry values.
local function build_flight_values_panel(container, wgt, x, y, c_w, c_h)
    local padding = compact_card_padding
    local row_gap = 1
    local row_h = math.floor((c_h - 2 * padding - 4 * row_gap) / 5)
    local used_h = row_h * 5 + 4 * row_gap
    local start_y = padding + math.floor((c_h - used_h) / 2)
    local label_w = math.floor(c_w * 0.55)
    local value_x = padding + label_w
    local value_w = c_w - value_x - padding
    -- ESC continuous-current load bar (shown on the Curr row when monitoring is on
    -- and the bar placement is "Current row" — the alternative lives in the gauge)
    local esc_on = (wgt.options.EscMon == 1) and (wgt.options.EscBar or 1) == 1
    local ESC_GREEN, ESC_YELL, ESC_RED = SEM_GREEN, SEM_YELL, SEM_RED
    -- the ESC-load bar belongs on the slot showing the SELECTED current source, not
    -- on the literal "Curr" — keep in sync with the CurrSrc choice values
    local curr_name = (wgt.options.CurrSrc == 2) and "EscI"
        or (wgt.options.CurrSrc == 3) and "Iesc" or "Curr"
    -- a raw pick's source name can be long: trim to the label column at
    -- build time so it ends in ".." instead of overdrawing the value column
    local function fit_label(s)
        local max_w = label_w - padding
        if type(s) ~= "string" or lcd.sizeText(s, header_font) <= max_w then return s end
        while #s > 1 and lcd.sizeText(s .. "..", header_font) > max_w do
            s = string.sub(s, 1, #s - 1)
        end
        return s .. ".."
    end
    -- 5 configurable slots (Settings ▸ Values). Defaults reproduce the original
    -- panel: smart voltage, headspeed, current, ESC temp, BEC. VOLT_AUTO keeps the
    -- cell/battery toggle + warn colour; a plain sensor uses the cheap cache getter;
    -- an Off slot renders blank.
    -- Units are opt-in: with them off every row keeps the full value column and
    -- therefore the biggest font that fits -- the original formatting, and the readable
    -- one on the small screens. The KEY belongs to the active skin since 0.8.0 (see
    -- SKINS._units_key): whether a unit is worth its font size is a property of the
    -- layout, exactly like the colour scheme, and the same value that reads well on the
    -- MK3's default panel does not on a 480 px card layout. A skin that declares no key
    -- of its own falls back to the host's, which is also what the detail pages read.
    local units_on = (wgt.options[SKINS._units_key or "ShowUnits"] == 1)
    local rows = {}
    for i = 1, 5 do
        local name = wgt.options[PANEL_SLOT_KEYS[i]] or SENSOR_OFF
        if name == VOLT_AUTO then
            rows[i] = {
                title = wgt.values.display_voltage_label_short,
                value = wgt.values.display_voltage_formatted,
                test  = wgt.values.display_voltage_test(),
                color = wgt.values.display_voltage_color,
                unit  = units_on and "V" or ""
            }
        elseif is_off_sensor(name) then
            rows[i] = { title = "", value = "", test = "9999", color = COLOR_THEME_PRIMARY1, unit = "" }
        else
            rows[i] = {
                title = fit_label(sensor_short_label(name)),
                value = sensor_value_text(wgt, name),
                test  = sensor_test_text(name),
                color = (name == ESCL_AUTO) and esc_load_color(wgt) or COLOR_THEME_PRIMARY1,
                esc_bar = esc_on and (name == curr_name),
                unit  = units_on and sensor_unit(name) or ""
            }
        end
    end
    -- small accent unit rendered beside each value (mockup style)
    local unit_font = SMLSIZE
    local unit_font_h = measure_font(unit_font)
    -- Each row picks its OWN value font: the biggest that fits its widest value BESIDE its
    -- unit. So every row keeps its unit, and only a genuinely wide row (a 4-digit Headspeed +
    -- "rpm") ends up a touch smaller -- instead of one shared "smallest" font shrinking the
    -- whole panel, or a unit being dropped.
    for i = 1, 5 do
        local unit = rows[i].unit or ""
        local uw = (unit ~= "") and (lcd.sizeText(unit, unit_font) + 3) or 0
        local value_font = select_font(row_h - 2, value_w - (uw > 0 and (uw + 2) or 0), rows[i].test)
        local value_font_h = measure_font(value_font)
        local current_row_h = row_h
        local row_y = start_y + (i - 1) * (row_h + row_gap)
        local value_y = row_y + math.floor((current_row_h - value_font_h) / 2)
        local label_y = row_y + math.floor((current_row_h - header_h) / 2)

        local vy_rel = value_y - row_y
        local vw = value_w
        local children = {
            {
                type = "label",
                x = padding,
                y = label_y - row_y,
                w = label_w - padding,
                h = header_h,
                text = rows[i].title,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = LEFT
            }
        }
        -- unit suffix (small, accent color) right of the number; hidden when the value
        -- isn't numeric ("-" / "Buffer") so it never reads "- V". The row font (above) was
        -- already sized to leave room for it, so it always fits.
        if unit ~= "" then
            local vg = rows[i].value
            children[#children + 1] = {
                type = "label",
                x = value_x + value_w - uw,
                y = vy_rel + math.floor((value_font_h - unit_font_h) / 2),
                w = uw,
                h = unit_font_h,
                text = unit,
                font = unit_font,
                color = COLOR_DIM,
                align = RIGHT,
                -- numeric? cheap byte checks only -- runs every LVGL frame, so NO
                -- string.match here (it allocates a capture per frame -> GC churn).
                visible = function()
                    if type(vg) ~= "function" then return false end
                    local s = vg()
                    if type(s) ~= "string" then return false end
                    local b = string.byte(s, 1)
                    if b == nil then return false end
                    if b >= 48 and b <= 57 then return true end     -- leading digit
                    if b == 45 then                                 -- '-': keep "-5.0", hide bare "-"
                        local b2 = string.byte(s, 2)
                        return b2 ~= nil and b2 >= 48 and b2 <= 57
                    end
                    return false
                end
            }
            vw = value_w - uw - 2
        end
        children[#children + 1] = {
            type = "label",
            x = value_x,
            y = vy_rel,
            w = vw,
            h = value_font_h,
            text = rows[i].value,
            font = value_font,
            color = rows[i].color,
            align = RIGHT
        }
        build_card_element(container, x, y + row_y, c_w, current_row_h, children)

        -- ESC-load utilization bar along the bottom of the Current row, FULL row width
        -- (track + reactive fill), same span as the row divider. Hidden entirely while
        -- no session limit is latched (GVAR still 0 -> not set up on THIS model).
        if rows[i].esc_bar then
            local bx  = x + padding
            local bw  = c_w - 2 * padding
            local byy = y + row_y + current_row_h - 6
            local esc_vis = function() return wgt.values.esc_load_limit ~= nil end
            container:build({
                { type = "rectangle", x = bx, y = byy, w = bw, h = 5, filled = true, rounded = 2, color = COLOR_TRACK, visible = esc_vis },
                { type = "rectangle", x = bx, y = byy, w = 1, h = 5, filled = true, rounded = 2, visible = esc_vis,
                    size = function()
                        local p = wgt.values.esc_load_pct
                        if p == nil then return 1, 5 end
                        if p < 0 then p = 0 elseif p > 100 then p = 100 end
                        return math.max(1, math.floor(bw * p / 100)), 5
                    end,
                    color = function()
                        local p = wgt.values.esc_load_pct
                        if p == nil then return COLOR_TRACK end
                        local warn = wgt.options.EscWarn or 80
                        local crit = wgt.options.EscCrit or 100
                        if p >= crit then return ESC_RED elseif p >= warn then return ESC_YELL else return ESC_GREEN end
                    end },
            })
        end

        if i < 5 then
            container:hline({ x = x + padding, y = y + row_y + current_row_h, w = c_w - 2 * padding, h = 1, color =
            COLOR_THEME_SECONDARY1 })
        end
    end
end

--- Build the center vertical battery gauge used on the flight view.
local function build_vertical_fuel_gauge_element(container, wgt, x, y, c_w, c_h)
    local side_inset = math.max(1, math.floor(c_w * 0.04))
    local cap_h = math.max(5, math.floor(c_h * 0.06))
    local cap_w = math.max(10, math.floor((c_w - 2 * side_inset) * 0.36))
    local cap_x = x + math.floor((c_w - cap_w) / 2)
    local body_x = x + card_padding + side_inset
    local body_y = y + card_padding + cap_h
    local body_w = c_w - 2 * (card_padding + side_inset)
    local body_h = c_h - 2 * card_padding - cap_h
    local body_rounding = math.max(3, math.floor(body_w * 0.10))
    local cap_rounding = math.max(2, math.floor(cap_h * 0.45))
    local cap_base_h = math.max(1, math.floor(cap_h * 0.35))
    local inner_padding = math.max(3, math.floor(body_w * 0.10))
    local segment_gap = math.max(1, math.floor(body_h * 0.01))
    local inner_x = body_x + inner_padding
    local inner_y = body_y + inner_padding
    local inner_w = body_w - 2 * inner_padding
    local inner_h = body_h - 2 * inner_padding
    local segment_rounding = math.max(1, math.floor(inner_w * 0.10))
    -- chunky segments, capped at 10 so each row reads as a 10% step
    -- (was capped 9 -> odd 11.1% steps; user request 2026-07-22)
    local segment_count = math.max(6, math.min(10, math.floor(inner_h / 16)))
    local segment_h = math.floor((inner_h - (segment_count - 1) * segment_gap) / segment_count)
    local segment_last_h = inner_h - segment_h * (segment_count - 1) - segment_gap * (segment_count - 1)
    -- percent (center) and mAh (bottom) enlarged now that cell voltage was removed
    local value_font = select_font(math.floor(body_h * 0.22), body_w - 2 * inner_padding, "100%")
    local value_font_h = measure_font(value_font)
    local overlay_font = select_font(math.max(6, math.floor(body_h * 0.11)), body_w - 2 * inner_padding, "mAh")
    local overlay_font_h = measure_font(overlay_font)
    local overlay_pad = math.max(1, math.floor(body_h * 0.02))
    local mah_num_font = select_font(math.floor(body_h * 0.17), body_w - 2 * inner_padding, "8888")
    local mah_num_font_h = measure_font(mah_num_font)

    -- Empty segments: light grey (like ePowerbar's bar background) in the light
    -- schemes; the DARK scheme gets a muted mid-grey that no longer glows on the
    -- black panel but stays just light enough for the black overlay ink.
    local EMPTY_SEGMENT_COLOR = force_bg_fill and lcd.RGB(0x6A, 0x6E, 0x72)
        or lcd.RGB(0xc8, 0xc8, 0xc8)

    local function get_segment_color(segment_threshold)
        local current_percent = wgt.values.gauge_fill_percent()
        if current_percent >= segment_threshold then
            return wgt.values.capa_bar_color
        end
        return EMPTY_SEGMENT_COLOR
    end

    -- Overlay ink: plain black reads cleanly over the grey empty area and the
    -- green/yellow fills (no outline/halo needed — it only blurred the text).
    -- But a DARK bar_* override (Colors page) made black unreadable — pick the
    -- ink from the EFFECTIVE surfaces' luma instead of hardcoding it.
    local overlay_ink = (color_luma(EMPTY_SEGMENT_COLOR) > DARK_LUMA_THRESHOLD
        and color_luma(SEM.bar_ok) > DARK_LUMA_THRESHOLD) and BLACK or WHITE
    local function add_overlay_label(children, lx, ly, lw, lh, ltext, lfont)
        children[#children + 1] = {
            type = "label", x = lx, y = ly, w = lw, h = lh,
            text = ltext, font = lfont, color = overlay_ink, align = CENTER
        }
    end

    container:build({
        {
            type = "rectangle",
            x = cap_x,
            y = y + card_padding,
            w = cap_w,
            h = cap_h,
            thickness = 1,
            rounded = cap_rounding,
            color = COLOR_THEME_SECONDARY1,
            filled = true
        }, {
        type = "rectangle",
        x = cap_x,
        y = y + card_padding + cap_h - cap_base_h,
        w = cap_w,
        h = cap_base_h,
        thickness = 0,
        color = COLOR_THEME_SECONDARY1,
        filled = true
        }, {
        -- body outline only (filled=false) — the interior between the bars and the
        -- outline stays transparent so it follows the background (theme/BGFilled/wallpaper)
        type = "rectangle",
        x = body_x,
        y = body_y,
        w = body_w,
        h = body_h,
        thickness = 1,
        rounded = body_rounding,
        color = COLOR_THEME_SECONDARY1,
        filled = false
    }
    })

    -- ESC-load fill (Settings > ESC load, "Load bar: Battery gauge"): colours the free
    -- gap between the segments and the outline, QUANTISED to the segment rows -- the
    -- load lights whole rows bottom-up (a row is ever ALL on or ALL off), so there is
    -- never a partial, square-cornered leading edge, and every reactive prop is a cheap
    -- boolean (no per-frame geometry math -- the geometry is all static, built once).
    -- Built BEFORE the segments so it sits UNDER them (the top/bottom segments' own
    -- rounded corners then reveal the inner-corner patches, hugging the curve).
    --   * outer corners: body_rounding == inner_padding, so each gap corner is a
    --     QUARTER DISC of radius R = gap -- a filled lvgl arc sector (thickness = radius;
    --     indicator part = colour, bg arc zeroed) matching the outline's curve.
    --   * inner corners: small fill-coloured patches under the first/last segment's
    --     rounded corners. The ring closes at 100 %; colour = green/yellow/red by
    --     EscWarn/EscCrit. Visible only while a session limit is latched.
    if wgt.options.EscMon == 1 and (wgt.options.EscBar or 1) == 2 then
        local gap = math.max(1, inner_padding - 1)  -- free gap = outer corner radius R
        local sr  = segment_rounding                -- inner (segment) corner radius
        local rx0 = body_x + 1                      -- inside the 1 px outline
        local rx1 = body_x + body_w - 1
        local ry1 = body_y + body_h - 1
        local nseg = segment_count
        -- load % -> count of fully-lit rows (0..nseg), bottom-up, snapped to the rows
        local function esc_level()
            local p = wgt.values.esc_load_pct
            if p == nil or p <= 0 then return 0 end
            local L = math.floor(p * nseg / 100)
            if L > nseg then L = nseg end
            return L
        end
        local esc_vis = function() return wgt.values.esc_load_limit ~= nil end
        local function vis_at(need)   -- shown once `need` rows (from the bottom) are lit
            return function() return esc_vis() and esc_level() >= need end
        end
        local function fill_color()
            local p = wgt.values.esc_load_pct
            if p == nil then return EMPTY_SEGMENT_COLOR end
            local warn = wgt.options.EscWarn or 80
            local crit = wgt.options.EscCrit or 100
            if p >= crit then return SEM_RED elseif p >= warn then return SEM_YELL else return SEM_GREEN end
        end
        -- corner quarter disc (filled sector; x/y = the arc centre)
        local function corner(cx, cy, a0, a1, vis)
            return { type = "arc", x = cx, y = cy, radius = gap, thickness = gap,
                     startAngle = a0, endAngle = a1, rounded = false,
                     bgStartAngle = 0, bgEndAngle = 0, bgOpacity = 0,
                     color = fill_color, visible = vis }
        end
        -- inner-corner patch under a segment's rounded corner
        local function patch(px, py, vis)
            return { type = "rectangle", x = px, y = py, w = sr, h = sr, filled = true,
                     color = fill_color, visible = vis }
        end
        local vis1 = vis_at(1)          -- any fill: bottom cap on
        local visT = vis_at(nseg)       -- fully lit: top cap on (ring closes at 100 %)
        local pieces = {
            -- bottom cap: run under the bottom segment + outer corner discs + the
            -- inner-corner patches under the bottom segment's rounded corners
            { type = "rectangle", x = inner_x, y = inner_y + inner_h, w = inner_w, h = gap,
              filled = true, color = fill_color, visible = vis1 },
            corner(rx0 + gap, ry1 - gap, 90, 180, vis1),   -- bottom-left
            corner(rx1 - gap, ry1 - gap, 0, 90, vis1),     -- bottom-right
            patch(inner_x, inner_y + inner_h - sr, vis1),
            patch(inner_x + inner_w - sr, inner_y + inner_h - sr, vis1),
            -- top cap: lid run + outer corner discs + inner-corner patches (at 100 %)
            { type = "rectangle", x = inner_x, y = body_y + 1, w = inner_w, h = gap,
              filled = true, color = fill_color, visible = visT },
            corner(rx0 + gap, body_y + 1 + gap, 180, 270, visT),  -- top-left
            corner(rx1 - gap, body_y + 1 + gap, 270, 360, visT),  -- top-right
            patch(inner_x, inner_y, visT),
            patch(inner_x + inner_w - sr, inner_y, visT),
        }
        -- one left+right side strip per segment row; the strip beside segment i lights
        -- when the fill has climbed to it (bottom segment first). Each spans its segment
        -- plus the gap below, so consecutive rows tile seamlessly into one column.
        for i = 1, nseg do
            local seg_top = inner_y + (i - 1) * (segment_h + segment_gap)
            local band_h  = (i < nseg) and (segment_h + segment_gap) or (inner_y + inner_h - seg_top)
            local vis = vis_at(nseg - i + 1)
            pieces[#pieces + 1] = { type = "rectangle", x = rx0, y = seg_top, w = gap, h = band_h,
                filled = true, color = fill_color, visible = vis }
            pieces[#pieces + 1] = { type = "rectangle", x = inner_x + inner_w, y = seg_top, w = gap, h = band_h,
                filled = true, color = fill_color, visible = vis }
        end
        container:build(pieces)
    end

    for segmentIndex = 1, segment_count do
        local top_index = segmentIndex - 1
        local segment_item_h = segmentIndex == segment_count and segment_last_h or segment_h
        local segment_threshold = ((segment_count - top_index) / segment_count) * 100
        local segment_y = inner_y + top_index * (segment_h + segment_gap)
        local segment_color = function() return get_segment_color(segment_threshold) end
        local segment_flat_h = math.max(1, math.min(segment_rounding, segment_item_h))

        container:build({
            {
                type = "rectangle",
                x = inner_x,
                y = segment_y,
                w = inner_w,
                h = segment_item_h,
                thickness = 1,
                rounded = (segmentIndex == 1 or segmentIndex == segment_count) and segment_rounding or 0,
                color = segment_color,
                filled = true
            }, {
                type = "rectangle",
                x = inner_x,
                y = segmentIndex == 1 and (segment_y + segment_item_h - segment_flat_h) or segment_y,
                w = inner_w,
                h = segment_flat_h,
                thickness = 0,
                color = segment_color,
                filled = (segmentIndex == 1 or segmentIndex == segment_count)
            }
        })
    end

    -- (the ESC-load fill in the segment gap is built ABOVE, before the segments.)
    -- overlays: cell count (top) + big percent (center) + mAh number/unit (bottom).
    -- cell voltage is intentionally NOT shown here (it's in the right values panel).
    local cells_y = body_y + inner_padding + overlay_pad
    local percent_y = body_y + math.floor((body_h - value_font_h) / 2)
    local mah_block_h = mah_num_font_h + overlay_font_h
    local mah_num_y = body_y + body_h - inner_padding - overlay_pad - mah_block_h
    local mah_unit_y = mah_num_y + mah_num_font_h

    local overlay_labels = {}
    add_overlay_label(overlay_labels, body_x, cells_y, body_w, overlay_font_h,
        wgt.values.gauge_cells_formatted, overlay_font)
    add_overlay_label(overlay_labels, body_x, percent_y, body_w, value_font_h,
        wgt.values.gauge_percent_formatted, value_font)
    add_overlay_label(overlay_labels, body_x, mah_num_y, body_w, mah_num_font_h,
        wgt.values.gauge_mah_value_formatted, mah_num_font)
    add_overlay_label(overlay_labels, body_x, mah_unit_y, body_w, overlay_font_h,
        "mAh", overlay_font)
    container:build(overlay_labels)
end

--- Build the flight status panel: model image on top, flight totals directly
--- beneath it, the eStatus ESC/throttle line, the governor state, and a single
--- Profile / Rate / Batt-Profile row.
local function build_flight_status_panel(container, wgt, x, y, c_w, c_h)
    local pad = card_padding
    local inner_w = c_w - 2 * pad

    -- model image: FIXED reserved slot at the top so the sections below never shift
    -- when images have different aspect ratios. The image is top-anchored inside the
    -- slot (frame height = its own scaled height, so it hugs the top, no float), but
    -- the layout below always starts at the fixed slot bottom.
    local image_slot_h = math.max(1, math.floor(c_h * 0.32))
    local image_h = image_slot_h
    local img_bw = wgt.values.model_image_w
    local img_bh = wgt.values.model_image_h
    if img_bw and img_bh and img_bw > 0 and img_bh > 0 then
        local scale = math.min(inner_w / img_bw, image_slot_h / img_bh)
        image_h = math.max(1, math.floor(img_bh * scale))
    end

    -- everything below starts at the fixed slot bottom, regardless of image height
    local y_meta = pad + image_slot_h
    local rest = math.max(1, c_h - y_meta - pad)
    local h_meta = math.max(header_h + 4, math.floor(rest * 0.28))
    local h_gt   = math.max(header_h + 2, math.floor(rest * 0.30)) -- governor + throttle headline
    local h_esc  = math.max(header_h + 2, math.floor(rest * 0.16)) -- ESC / arming status line
    local h_grid = math.max(header_h + 2, rest - h_meta - h_gt - h_esc)

    local y_gt = y_meta + h_meta
    local y_esc = y_gt + h_gt
    local y_grid = y_esc + h_esc

    local half_w = math.floor(inner_w / 2)
    local gov_w = math.floor(inner_w * 0.62)
    local thr_w = inner_w - gov_w

    -- fonts: flight totals
    -- M1: the pair shares ONE font and ONE glyph height. The two picks used to run
    -- independently against the same height budget, and the Flights sample ("9999") is
    -- less than half as wide as the time's -- so wherever the ladder had a step in
    -- between, Flights came out a size larger and the two baselines (each stacked
    -- field centres its OWN value_h) drifted apart. pick_smallest_font existed for
    -- exactly this and had never been called.
    local flights_font = select_font(h_meta - header_h, half_w, "9999")
    local time_font = select_font(h_meta - header_h, inner_w - half_w, "999:59:59")
    local meta_font = pick_smallest_font(flights_font, time_font)
    local meta_value_h = measure_font(meta_font)
    local meta_pad = math.max(0, math.floor((h_meta - header_h - meta_value_h) / 2))

    -- fonts: governor + throttle headline row
    local gov_font = select_font(h_gt - header_h, gov_w, "Gov. Disabled", "MIDSIZE")
    local gov_font_h = measure_font(gov_font)
    local thr_font = select_font(h_gt - header_h, thr_w, "100%")
    local thr_font_h = measure_font(thr_font)
    local gt_value_h = math.max(gov_font_h, thr_font_h)
    local gt_pad = math.max(0, math.floor((h_gt - header_h - gt_value_h) / 2))

    -- font: ESC / arming status line (full width, single colored line)
    local stat_font = select_font(h_esc - 2, inner_w, "ESC Motor Connection")
    local stat_font_h = measure_font(stat_font)

    local third_w = math.floor(inner_w / 3)
    local third_last_w = inner_w - 2 * third_w
    local profile_font = select_font(h_grid - header_h, third_w, "9")
    local profile_font_h = measure_font(profile_font)
    local rate_font = select_font(h_grid - header_h, third_w, "9")
    local rate_font_h = measure_font(rate_font)
    local battp_font = select_font(h_grid - header_h, third_last_w, "9999")
    local battp_font_h = measure_font(battp_font)
    -- battery-profile column header: prefer "B-Profile"; on the narrow TX15 third
    -- column it would clip, so fall back to the shorter "B-Prof" when it doesn't fit
    local battp_label = wgt.values.label_battery_profile_short
    if lcd.sizeText(battp_label, header_font) > third_last_w then
        battp_label = wgt.values.label_battery_profile_shorter
    end
    local grid_value_h = math.max(profile_font_h, rate_font_h, battp_font_h)
    local grid_pad = math.max(0, math.floor((h_grid - header_h - grid_value_h) / 2))

    local status_children = {}

    -- top-left slot: model image (default) or the configured model timer (TopLeft option)
    if wgt.options.TopLeft == 2 then
        local timer_val_h = math.max(1, image_slot_h - header_h - 2)
        local timer_font = select_font(timer_val_h, inner_w, "-00:00")
        local timer_font_h = measure_font(timer_font)
        status_children[#status_children + 1] = {
            type = "label", x = pad, y = pad, w = inner_w, h = header_h,
            text = wgt.values.label_timer, font = header_font, color = COLOR_THEME_SECONDARY1, align = CENTER
        }
        status_children[#status_children + 1] = {
            type = "label",
            x = pad,
            y = pad + header_h + math.floor((image_slot_h - header_h - timer_font_h) / 2),
            w = inner_w, h = timer_font_h,
            text = wgt.values.timer_str_formatted,
            font = timer_font,
            -- the reference, not a wrapper around it: timer_color is a stable per-widget
            -- closure in the values table, exactly like timer_str_formatted on the line
            -- above and arm_state_color further down, both of which are already passed
            -- straight through. The wrapper was one extra Lua call per LVGL frame for
            -- nothing.
            color = wgt.values.timer_color,
            align = CENTER
        }
    else
        status_children[#status_children + 1] = {
            type = "image",
            x = pad,
            y = pad,
            w = inner_w,
            h = image_h,
            file = function() return wgt.values.model_image_path end,
            fill = false
        }
    end

    -- flight totals directly under the image
    add_stacked_field(status_children, pad, y_meta, half_w, meta_pad,
        wgt.values.label_total_flights, wgt.values.rf_total_flights_display_formatted, meta_font, meta_value_h)
    add_stacked_field(status_children, pad + half_w, y_meta, inner_w - half_w, meta_pad,
        "Total Time", wgt.values.rf_total_flight_time_display_formatted, meta_font, meta_value_h)

    -- headline status row: Governor State (left) + Throttle (right)
    add_stacked_field(status_children, pad, y_gt, gov_w, gt_pad,
        "Governor", wgt.values.gov_state_formatted, gov_font, gov_font_h)
    add_stacked_field(status_children, pad + gov_w, y_gt, thr_w, gt_pad,
        wgt.values.label_throttle, function() return wgt.values.throttle_text end, thr_font, thr_font_h)

    -- ESC / arming status line (full width, colored; blank when all OK).
    -- Tapping it (fullscreen) opens the status detail page — remember its rect
    -- in widget coords for the hit-test in refresh().
    wgt.estatus_rect = { x = x + pad, y = y + y_esc, w = inner_w, h = h_esc }
    -- C3: the whole status panel is the tap zone that opens the STATISTICS page — it
    -- already shows the flight counter and total time, so it is the stats surface. The
    -- status LINE keeps its own estatus_rect; the tap dispatcher checks that one first.
    wgt.statspage_rect = { x = x, y = y, w = c_w, h = c_h }
    status_children[#status_children + 1] = {
        type = "label",
        x = pad,
        y = y_esc + math.floor((h_esc - stat_font_h) / 2),
        w = inner_w,
        h = stat_font_h,
        text = function() return wgt.values.status_line_text end,
        font = stat_font,
        color = function() return wgt.values.status_line_color end,
        align = CENTER
    }

    -- Profile / Rate / Batt-Profile in a single 3-column row
    add_stacked_field(status_children, pad, y_grid, third_w, grid_pad,
        wgt.values.label_profile, wgt.values.profile_id_formatted, profile_font, profile_font_h)
    add_stacked_field(status_children, pad + third_w, y_grid, third_w, grid_pad,
        wgt.values.label_rate, wgt.values.rate_id_formatted, rate_font, rate_font_h)
    add_stacked_field(status_children, pad + 2 * third_w, y_grid, third_last_w, grid_pad,
        battp_label, wgt.values.rf_battery_profile_compact_formatted, battp_font, battp_font_h)
    -- the battery-profile field is a tap target (DISARMED only): opens the profile
    -- picker, which switches the active profile via the RFTool MSP API
    wgt.battprofile_rect = { x = x + pad + 2 * third_w, y = y + y_grid, w = third_last_w, h = h_grid }

    build_card_element(container, x, y, c_w, c_h, status_children)

    container:hline({ x = x + pad, y = y + y_meta - 1, w = inner_w, h = 1, color = COLOR_THEME_SECONDARY1 })
    container:hline({ x = x + pad, y = y + y_gt - 1, w = inner_w, h = 1, color = COLOR_THEME_SECONDARY1 })
    container:hline({ x = x + pad, y = y + y_esc - 1, w = inner_w, h = 1, color = COLOR_THEME_SECONDARY1 })
    container:hline({ x = x + pad, y = y + y_grid - 1, w = inner_w, h = 1, color = COLOR_THEME_SECONDARY1 })
end

local function get_flight_statistics_rows(wgt)
    -- Headspeed min/max are tracked PER PID PROFILE (see update_headspeed). Three
    -- FIXED rows (P1-P3) keep every profile's pair visible after a disconnect —
    -- the PID# sensor freezes then, so a single switched row would be useless.
    -- "Latest" shows the live rpm only on the active profile's row.
    -- closure-local memo (last_v/last_s/primed, same pattern as sensor_value_text):
    -- these run every render frame but the rpm only changes on the 5 Hz pass.
    local function hs_actual(p)
        local last_v, last_s, primed = nil, "-", false
        return function()
            local cur = wgt.values.profile_id
            local v
            if cur ~= nil and math.floor(cur) == p and wgt.values.headspeed ~= nil then
                v = math.floor(wgt.values.headspeed)
            end
            if primed and v == last_v then return last_s end
            last_v = v
            last_s = (v == nil) and "-" or string.format("%d", v)
            primed = true
            return last_s
        end
    end
    local function hs_get(p, key)
        local last_v, last_s, primed = nil, "-", false
        return function()
            local s = wgt.hs_profile_stats and wgt.hs_profile_stats[p]
            local raw = s and s[key]
            local v = raw and math.floor(raw) or nil
            if primed and v == last_v then return last_s end
            last_v = v
            last_s = (v == nil) and "-" or string.format("%d", v)
            primed = true
            return last_s
        end
    end
    -- Voltage-sag counter: count in the "Latest" column, deepest cell
    -- voltage of any sag in the "Min" column (the combined string does not fit one
    -- table column). Memoized like hs_actual; red once any episode is counted.
    local function sag_count_text()
        local last_v, last_s, primed = nil, "-", false
        return function()
            local v = wgt.values.sag_count
            if primed and v == last_v then return last_s end
            last_v = v; primed = true
            last_s = (v == nil or v == 0) and "-" or (v .. "x")
            return last_s
        end
    end
    local function sag_min_text()
        local last_v, last_s, primed = nil, "-", false
        return function()
            local n = wgt.values.sag_count
            local v = (n ~= nil and n > 0) and wgt.values.sag_min or nil
            if primed and v == last_v then return last_s end
            last_v = v; primed = true
            last_s = (v == nil) and "-" or string.format("%.2f", v)
            return last_s
        end
    end
    local function sag_color()
        return ((wgt.values.sag_count or 0) > 0) and SEM_RED or COLOR_THEME_PRIMARY1
    end
    local function hs_row(p)
        return {
            label = "Headspeed P" .. p,
            actual = hs_actual(p),
            min = hs_get(p, "min"),
            max = hs_get(p, "max"),
            actualColor = COLOR_THEME_PRIMARY1,
            minColor = COLOR_THEME_PRIMARY1,
            maxColor = COLOR_THEME_PRIMARY1,
            test = "3200"
        }
    end
    return {
        {
            label = wgt.values.display_voltage_label,
            actual = wgt.values.display_voltage_formatted,
            min = wgt.values.display_voltage_min_formatted,
            max = wgt.values.display_voltage_max_formatted,
            actualColor = wgt.values.display_voltage_actual_color,
            minColor = wgt.values.display_voltage_min_color,
            maxColor = wgt.values.display_voltage_max_color,
            test = wgt.values.display_voltage_test()
        },
        hs_row(1),
        hs_row(2),
        hs_row(3),
        {
        label = wgt.values.label_current,
        actual = wgt.values.curr_formatted,
        min = wgt.values.curr_min_formatted,
        max = wgt.values.curr_max_formatted,
        actualColor = COLOR_THEME_PRIMARY1,
        minColor = COLOR_THEME_PRIMARY1,
        maxColor = COLOR_THEME_PRIMARY1,
        test = "999.9"
    }, {
        label = wgt.values.label_esc_temp,
        actual = wgt.values.esc_temp_formatted,
        min = wgt.values.esc_temp_min_formatted,
        max = wgt.values.esc_temp_max_formatted,
        actualColor = COLOR_THEME_PRIMARY1,
        minColor = COLOR_THEME_PRIMARY1,
        maxColor = COLOR_THEME_PRIMARY1,
        test = "120.0"
    }, {
        label = wgt.values.label_bec_voltage,
        actual = wgt.values.vbec_formatted,
        min = wgt.values.vbec_min_formatted,
        max = wgt.values.vbec_max_formatted,
        actualColor = COLOR_THEME_PRIMARY1,
        minColor = COLOR_THEME_PRIMARY1,
        maxColor = COLOR_THEME_PRIMARY1,
        test = "99.99"
    }, {
        label = "V sags",
        actual = sag_count_text(),
        min = sag_min_text(),
        max = "-",
        actualColor = sag_color,
        minColor = sag_color,
        maxColor = COLOR_THEME_PRIMARY1,
        test = "3.21"
    }
    }
end

--- Calculate the statistics header layout for model name and RF totals.
local function get_flight_statistics_top_layout(wgt, c_w, top_row_h, table_start_y)
    local time_value_sample = "999:59:59"
    local flights_value_sample = "9999"
    local top_meta_pair_gap = 8
    local top_meta_item_gap = 3
    local total_time_label = wgt.values.label_total_flight_time .. ":"
    local flights_label = wgt.values.label_total_flights .. ":"
    local total_time_label_w = lcd.sizeText(total_time_label, header_font)
    local flights_label_w = lcd.sizeText(flights_label, header_font)
    local available_meta_w = math.max(1, c_w - 2 * card_padding)
    local meta_fixed_w = total_time_label_w + flights_label_w + top_meta_pair_gap + top_meta_item_gap * 2
    local meta_value_w = math.max(1, math.floor((available_meta_w - meta_fixed_w) / 2))
    local top_meta_value_font = select_font(top_row_h - 2, meta_value_w, time_value_sample, "MIDSIZE")
    local top_meta_value_font_h = measure_font(top_meta_value_font)
    local total_time_value_w = lcd.sizeText(time_value_sample, top_meta_value_font)
    local flights_value_w = lcd.sizeText(flights_value_sample, top_meta_value_font)
    local total_time_block_w = total_time_label_w + top_meta_item_gap + total_time_value_w
    local top_meta_cluster_w = total_time_block_w + top_meta_pair_gap + flights_label_w + top_meta_item_gap +
    flights_value_w
    local top_meta_x = math.max(card_padding, c_w - card_padding - top_meta_cluster_w)
    local top_model_actual_w = math.max(1, top_meta_x - card_padding - 8)
    local top_model_font = select_font(top_row_h - 2, top_model_actual_w, wgt.values.craft_name_formatted(), "DBLSIZE")
    local top_model_font_h = measure_font(top_model_font)
    local top_row_center_y = table_start_y + math.floor(top_row_h / 2)

    return {
        model_w = top_model_actual_w,
        model_font = top_model_font,
        model_font_h = top_model_font_h,
        meta_value_font = top_meta_value_font,
        meta_value_font_h = top_meta_value_font_h,
        meta_label_y = top_row_center_y - math.floor(header_h / 2),
        meta_value_y = top_row_center_y - math.floor(top_meta_value_font_h / 2),
        total_time_label = total_time_label,
        total_time_label_w = total_time_label_w,
        total_time_value_w = total_time_value_w,
        flights_label = flights_label,
        flights_label_w = flights_label_w,
        flights_value_w = flights_value_w,
        meta_x = top_meta_x,
        meta_last_x = top_meta_x + total_time_block_w + top_meta_pair_gap
    }
end

--- Build the full statistics table and top metadata row.
local function build_flight_statistics_element(container, wgt, x, y, c_w, c_h)
    local stats_w = math.max(1, c_w - 1)
    local stats_h = math.max(1, c_h - 1)
    local label_w = math.floor((stats_w - 2 * card_padding) * 0.31)
    local value_area_w = stats_w - 2 * card_padding - label_w
    local value_col_w = math.floor(value_area_w / 3)
    local value_last_col_w = value_area_w - value_col_w * 2
    local top_row_h = math.max(header_h + 4, math.floor(stats_h * 0.15))
    local header_row_h = math.max(header_h + 2, math.floor(stats_h * 0.12))
    local header_gap_h = math.max(3, math.floor(stats_h * 0.02))
    local rows = get_flight_statistics_rows(wgt)
    local data_area_h = stats_h - top_row_h - header_gap_h - header_row_h
    local row_h = math.floor(data_area_h / #rows)
    local used_h = top_row_h + header_gap_h + header_row_h + row_h * #rows
    local table_start_y = math.floor((stats_h - used_h) / 2)
    local table_header_y = table_start_y + top_row_h + header_gap_h
    local top = get_flight_statistics_top_layout(wgt, stats_w, top_row_h, table_start_y)
    container:build({
        {
            type = "rectangle",
            x = x,
            y = y,
            w = stats_w,
            h = stats_h,
            thickness = show_debug_border,
            children = {
                {
                    type = "label",
                    x = card_padding,
                    y = table_start_y + math.floor((top_row_h - top.model_font_h) / 2),
                    w = top.model_w,
                    h = top.model_font_h,
                    text = wgt.values.craft_name_formatted,
                    font = top.model_font,
                    color = COLOR_THEME_PRIMARY1,
                    align = LEFT
                }, {
                type = "label",
                x = top.meta_x,
                y = top.meta_label_y,
                w = top.total_time_label_w,
                h = header_h,
                text = top.total_time_label,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = LEFT
            }, {
                type = "label",
                x = top.meta_x + top.total_time_label_w + 2,
                y = top.meta_value_y,
                w = top.total_time_value_w,
                h = top.meta_value_font_h,
                text = wgt.values.rf_total_flight_time_display_formatted,
                font = top.meta_value_font,
                color = COLOR_THEME_PRIMARY1,
                align = LEFT
            }, {
                type = "label",
                x = top.meta_last_x,
                y = top.meta_label_y,
                w = top.flights_label_w,
                h = header_h,
                text = top.flights_label,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = LEFT
            }, {
                type = "label",
                x = top.meta_last_x + top.flights_label_w + 2,
                y = top.meta_value_y,
                w = top.flights_value_w,
                h = top.meta_value_font_h,
                text = wgt.values.rf_total_flights_display_formatted,
                font = top.meta_value_font,
                color = COLOR_THEME_PRIMARY1,
                align = LEFT
            }, {
                type = "label",
                x = card_padding,
                y = table_header_y,
                w = label_w - card_padding,
                h = header_row_h,
                text = wgt.values.rf_connection_state_formatted,
                font = header_font,
                color = wgt.values.rf_connection_state_color,
                align = LEFT
            }, {
                type = "label",
                x = card_padding + label_w,
                y = table_header_y,
                w = value_col_w,
                h = header_row_h,
                text = wgt.values.label_actual,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = CENTER
            }, {
                type = "label",
                x = card_padding + label_w + value_col_w,
                y = table_header_y,
                w = value_col_w,
                h = header_row_h,
                text = wgt.values.label_min,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = CENTER
            }, {
                type = "label",
                x = card_padding + label_w + value_col_w * 2,
                y = table_header_y,
                w = value_last_col_w,
                h = header_row_h,
                text = wgt.values.label_max,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = CENTER
            }
            }
        }
    })

    for i = 1, #rows do
        local current_row_h = row_h
        local row_y = y + table_header_y + header_row_h + (i - 1) * row_h
        local row_value_font = select_font(current_row_h - 2, value_col_w, rows[i].test, "DBLSIZE")
        local row_value_font_h = measure_font(row_value_font)
        local row_label_y = math.floor((current_row_h - header_h) / 2)
        local row_value_y = math.floor((current_row_h - row_value_font_h) / 2)

        build_card_element(container, x, row_y, stats_w, current_row_h, {
            {
                type = "label",
                x = card_padding,
                y = row_label_y,
                w = label_w - card_padding,
                h = header_h,
                text = rows[i].label,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = LEFT
            }, {
            type = "label",
            x = card_padding + label_w,
            y = row_value_y,
            w = value_col_w,
            h = row_value_font_h,
            text = rows[i].actual,
            font = row_value_font,
            color = rows[i].actualColor,
            align = CENTER
        }, {
            type = "label",
            x = card_padding + label_w + value_col_w,
            y = row_value_y,
            w = value_col_w,
            h = row_value_font_h,
            text = rows[i].min,
            font = row_value_font,
            color = rows[i].minColor,
            align = CENTER
        }, {
            type = "label",
            x = card_padding + label_w + value_col_w * 2,
            y = row_value_y,
            w = value_last_col_w,
            h = row_value_font_h,
            text = rows[i].max,
            font = row_value_font,
            color = rows[i].maxColor,
            align = CENTER
        }
        })

        if i == 1 then
            container:hline({ x = x + card_padding, y = y + table_header_y + header_row_h, w = stats_w - 2 * card_padding, h = 1, color =
            COLOR_THEME_SECONDARY1 })
        end
        if i < #rows then
            container:hline({ x = x + card_padding, y = row_y + current_row_h, w = stats_w - 2 * card_padding, h = 1, color =
            COLOR_THEME_SECONDARY1 })
        end
    end
end

-- ============================================================================
-- STATUS BAR FUNCTIONS: Dual-mode status bar (normal telemetry vs arming flags)
-- ============================================================================

--- Build the normal status-bar labels for the active view.
local function build_status_bar_normal_element(container, wgt, x, y, c_w, c_h)
    -- Calculate vertical centering offset
    local header_font_h = measure_font(header_font)
    local y_offset = math.floor((c_h - header_font_h) / 2)
    local labels = {}

    if init_view_state(wgt).current == "flight" then
        local model_w = math.floor(c_w * 0.46)
        local skp_w = math.floor(c_w * 0.16)
        local tpwr_w = math.floor(c_w * 0.24)
        local model_text_x = x + card_padding
        local model_text_w = math.max(1, model_w - 2 * card_padding)

        labels[1] = container:label({
            x = model_text_x,
            y = y + y_offset,
            w = model_text_w,
            h = header_font_h,
            text = memo_text(wgt.values.craft_name_formatted,
                function(s) return string.format("%s%s", wgt.values.label_model, s) end),
            font = header_font,
            color = COLOR_THEME_PRIMARY1,
            align = LEFT
        })
        labels[2] = container:label({
            x = x,
            y = y + y_offset,
            w = c_w,
            h = header_font_h,
            text = wgt.values.arm_state_text,
            font = header_font,
            color = wgt.values.arm_state_color,
            align = CENTER
        })
        labels[3] = container:label({
            x = x + c_w - skp_w,
            y = y + y_offset,
            w = skp_w,
            h = header_font_h,
            text = memo_text(wgt.values.skp_formatted,
                function(s) return string.format("%s: %s", wgt.values.label_skp, s) end),
            font = header_font,
            color = COLOR_THEME_PRIMARY1,
            align = RIGHT
        })

        -- TPWR between the (centered) arm state and Skp (toggleable)
        if wgt.options.ShowTPWR == 1 then
            labels[#labels + 1] = container:label({
                x = x + c_w - skp_w - tpwr_w,
                y = y + y_offset,
                w = tpwr_w,
                h = header_font_h,
                text = memo_text(wgt.values.tpwr_cur_formatted,
                    function(s) return string.format("%s: %s", wgt.values.label_tpwr_cur, s) end),
                font = header_font,
                color = COLOR_THEME_PRIMARY1,
                align = RIGHT
            })
        end

        return labels
    end

    local item_w = math.floor(c_w / 4)

    labels[1] = container:label({
        x = x,
        y = y + y_offset,
        w = item_w,
        h = header_font_h,
        text = memo_text(wgt.values.tpwr_formatted,
            function(s) return string.format("%s: %s", wgt.values.label_tpwr, s) end),
        font = header_font,
        color = COLOR_THEME_PRIMARY1,
        align = CENTER
    })
    labels[2] = container:label({
        x = x + item_w,
        y = y + y_offset,
        w = item_w,
        h = header_font_h,
        text = memo_text(wgt.values.rqly_formatted,
            function(s) return string.format("%s: %s", wgt.values.label_rqly, s) end),
        font = header_font,
        color = COLOR_THEME_PRIMARY1,
        align = CENTER
    })
    labels[3] = container:label({
        x = x + 2 * item_w,
        y = y + y_offset,
        w = item_w,
        h = header_font_h,
        text = memo_text(wgt.values.mcu_temp_max_formatted,
            function(s) return string.format("%s: %s", wgt.values.label_mcu_temp_max, s) end),
        font = header_font,
        color = COLOR_THEME_PRIMARY1,
        align = CENTER
    })
    labels[4] = container:label({
        x = x + 3 * item_w,
        y = y + y_offset,
        w = item_w,
        h = header_font_h,
        text = memo_text(wgt.values.skp_formatted,
            function(s) return string.format("%s: %s", wgt.values.label_skp, s) end),
        font = header_font,
        color = COLOR_THEME_PRIMARY1,
        align = CENTER
    })

    return labels
end

--- Show either the normal status bar or the arming-flags warning state.
local function update_status_bar_visibility(wgt, force_update)
    if not wgt.status_bar_elements then return end

    local has_flags = wgt.values.arm_flags_visible()

    -- Only update if state changed (unless force update requested)
    if not force_update and has_flags == wgt.status_bar_state then return end
    wgt.status_bar_state = has_flags

    if has_flags then
        wgt.status_bar_elements.flags:show()
        for i = 1, #wgt.status_bar_elements.normal do wgt.status_bar_elements.normal[i]:hide() end
    else
        for i = 1, #wgt.status_bar_elements.normal do wgt.status_bar_elements.normal[i]:show() end
        wgt.status_bar_elements.flags:hide()
    end
end

--- Build both status-bar modes and cache the created element references.
local function build_status_bar_element(container, wgt, x, y, c_w, c_h)
    -- Build both status bar modes and store references
    if not wgt.status_bar_elements then
        local header_font_h = measure_font(header_font)
        local y_offset = math.floor((c_h - header_font_h) / 2)
        wgt.status_bar_elements = {}
        wgt.status_bar_elements.normal = build_status_bar_normal_element(container, wgt, x, y, c_w, c_h)
        wgt.status_bar_elements.flags = container:label({
            x = x,
            y = y + y_offset,
            w = c_w,
            h = header_font_h,
            text = wgt.values.arm_flags_text_formatted,
            font = header_font,
            color = COLOR_THEME_WARNING
        })
    end
end

--- Build the in-widget top bar: date/time (left) + radio (TX) battery icon (right).
--- Replaces the EdgeTX top bar so the widget can run fullscreen self-contained.
local function build_top_bar_element(container, wgt, x, y, c_w, c_h, show_link)
    wgt.elrs_bar_rect = nil   -- (re)set by the bar block below when bars are built
    local font_h = measure_font(header_font)
    local y_off = math.floor((c_h - font_h) / 2)

    -- right: a compact battery icon with the percentage overlaid ON the icon and
    -- the voltage right-aligned just to its left — one tight, integrated cluster.
    -- slimmer than the full bar height + rounded corners so it reads as a neat battery
    -- pill instead of a chunky block (was icon_h = c_h - 2, sharp corners).
    -- 0.68 read a touch too small on hardware (2026-07-22) -> 0.76. The top bar
    -- is 0.075*H on both radios, so on the short 480x320 TX15 (c_h ~22 vs the
    -- TX16S ~34) that fraction leaves the pill too small -> use a taller fraction
    -- on the small bar (2026-07-22). TX16S value unchanged.
    local icon_frac = (c_h >= 28) and 0.76 or 0.92
    local icon_h = math.max(8, math.floor((c_h - 2) * icon_frac))
    local icon_w = math.max(30, math.floor(icon_h * 2.6))
    local term_w = math.max(2, math.floor(icon_w * 0.06))
    local icon_x = x + c_w - icon_w - term_w - 1
    local icon_y = y + math.floor((c_h - icon_h) / 2)
    local icon_r = math.max(2, math.floor(icon_h * 0.26))
    local volt_w = math.floor(c_w * 0.20)
    local volt_text_x = icon_x - volt_w - 3
    local pct_font = select_font(icon_h - 2, icon_w - 4, "100%")
    local pct_font_h = measure_font(pct_font)

    -- fullscreen-only settings entry: small "menu" glyph (3 bars) before the date.
    -- The tap target is hit-tested in refresh() like the ELRS bars — no lvgl button.
    wgt.settings_icon_rect = nil
    local date_x = x + 1
    local in_fs = lvgl.isFullScreen ~= nil and lvgl.isFullScreen() == true
    if in_fs then
        -- compact boxed "hamburger" tight against the date (the visible button is
        -- deliberately small); the TAP TARGET is the whole top-left corner plus the
        -- hit-test margin — much larger than the glyph itself.
        -- SQUARE box + bars scaled from the box height: a fixed 20-wide box filled the
        -- TALL 800x480 top bar (c_h ~36) as a stretched vertical rectangle, while it
        -- happened to look square on the short 480x320 (TX15) bar. Deriving width and the bars
        -- from c_h keeps a clean aspect ratio on both radios.
        local box_h = c_h - 2
        local box_w = box_h                                   -- square
        local box_x, box_y = date_x, y + 1
        local bar_th = math.max(2, math.floor(box_h * 0.11))  -- bar thickness
        local pad_x  = math.max(3, math.floor(box_w * 0.24))  -- horizontal inset
        local bar_x  = box_x + pad_x
        local bar_w  = box_w - 2 * pad_x
        local gap    = math.max(bar_th + 1, math.floor(box_h * 0.20))  -- bar spacing
        local mid_y  = box_y + math.floor(box_h / 2) - math.floor(bar_th / 2)
        container:build({
            { type = "rectangle", x = box_x, y = box_y, w = box_w, h = box_h, thickness = 1, rounded = 3, color = COLOR_THEME_PRIMARY1 },
            { type = "rectangle", x = bar_x, y = mid_y - gap, w = bar_w, h = bar_th, filled = true, color = COLOR_THEME_PRIMARY1 },
            { type = "rectangle", x = bar_x, y = mid_y,       w = bar_w, h = bar_th, filled = true, color = COLOR_THEME_PRIMARY1 },
            { type = "rectangle", x = bar_x, y = mid_y + gap, w = bar_w, h = bar_th, filled = true, color = COLOR_THEME_PRIMARY1 },
        })
        wgt.settings_icon_rect = { x = 0, y = 0, w = box_x + box_w + 16, h = c_h + 8 }
        date_x = box_x + box_w + 4
    end

    -- STATS PAGE ONLY: the one visible way out. Since 0.8.0 no page closes on a tap
    -- anywhere, so the page that never even had the "tap to close" hint needs a real
    -- control. It goes in the TOP BAR rather than over the table because the bar is
    -- host-owned on every skin -- a skin that draws it gets the button without knowing
    -- about it, and the host does not have to guess at a free corner in someone else's
    -- layout. Fullscreen only, exactly like the menu glyph beside it: a widget zone
    -- gets no touch, and a control that cannot be pressed is worse than none.
    -- Placed left of the TX voltage / battery pill, the one gap the stats top bar has
    -- (its link bars are suppressed).
    if in_fs and init_view_state(wgt).current == "stats" then
        local cx, csz = ultidash_functions.close_control(container,
            ((wgt.options.ShowTxV == 1) and volt_text_x or icon_x) - 6, y + 1,
            COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY1, c_h - 2)
        -- deliberately larger than the glyph, and anchored to the bar's own top edge
        -- rather than to the box: the container's origin is the skin's, not ours (the
        -- same reason settings_icon_rect above spans the whole corner)
        wgt.close_rect = { x = cx - 6, y = 0, w = csz + 12, h = c_h + 6 }
    end

    -- left: clock (date + time, or time only via ClockMode), width MEASURED (a
    -- fixed 30% left a huge gap on the 800x480 TX16S and pushed the bars right)
    local time_only = wgt.options.ClockMode == 2
    local date_w = lcd.sizeText(time_only and "00:00" or "00.00.00  00:00", header_font) + 8
    container:label({
        x = date_x,
        y = y + y_off,
        w = date_w,
        h = font_h,
        text = (function()
            -- both parts are already time-throttled memoized strings; memo the
            -- concatenation too so the top bar allocates only when the string changes
            local last_d, last_t, last_s
            return function()
                if time_only then return wgt.values.clock_time_formatted() end
                local d = wgt.values.clock_date_formatted()
                local t = wgt.values.clock_time_formatted()
                if d ~= last_d or t ~= last_t then last_d, last_t, last_s = d, t, d .. "  " .. t end
                return last_s
            end
        end)(),
        font = header_font,
        color = COLOR_THEME_PRIMARY1,
        align = LEFT
    })

    local show_txv = wgt.options.ShowTxV == 1

    -- center: ELRS link as thin stacked bars (RQ, TQ, 1RSS, 2RSS) — unlabeled,
    -- color-by-zone with a threshold tick. Suppressed on the stats page
    -- (show_link == false), where the link figures live in the table/status bar.
    if show_link ~= false then
        -- The cluster is ALWAYS centered on the top bar's midline so it never
        -- shifts when the surroundings change (menu glyph, TxV on/off, date width).
        -- Width: capped at 40% of the bar, shrunk symmetrically if either side
        -- (date / voltage / battery) would be touched.
        local left_lim = date_x + date_w + 6
        local right_lim = (show_txv and volt_text_x or icon_x) - 6
        local mid = x + math.floor(c_w / 2)
        local half = math.min(mid - left_lim, right_lim - mid)
        local bar_w = math.max(8, math.min(2 * half, math.floor(c_w * 0.40)))
        local center_x = mid - math.floor(bar_w / 2)

        local TRACK   = COLOR_TRACK
        -- dark scheme gets vivid neon green/yellow/red so the bars pop on black
        local C_GREEN, C_YELL, C_RED = SEM_GREEN, SEM_YELL, SEM_RED
        -- quiet-mode "all fine" fill. On the dark scheme a 0x4A grey is barely
        -- brighter than the dark track -> invisible; SEM_NEUT is a clearly lighter grey there.
        local C_NEUT  = SEM_NEUT
        local TICK    = COLOR_DIM
        local quiet   = wgt.options.BarsQuiet == 1
        -- Fallbacks match the DECLARED defaults (the Thresholds group: 80/50/15/8). They used
        -- to read 50/30/50/25, which agreed with nothing: an RSSI fallback of 50 % against a
        -- declared 15 % would have warned permanently. Dead code either way -- apply() fills
        -- every default before the first read, which is precisely why nobody noticed -- but
        -- the threshold service must not have two sets of fallbacks to choose from.
        local rq_warn = wgt.options.RQlyWarn or 80
        local rq_crit = wgt.options.RQlyCrit or 50
        local rs_warn = wgt.options.RssWarn or 15
        local rs_crit = wgt.options.RssCrit or 8

        -- build the bar list (RQ/TQ honor the Show* toggles; 2RSS only if diversity)
        local bars = {}
        local show_rssi = wgt.options.ShowRSSI == 1
        if wgt.options.ShowRQly == 1 then bars[#bars + 1] = { get = function() return wgt.values.elrs_rq end,     warn = rq_warn, crit = rq_crit } end
        if wgt.options.ShowTQly == 1 then bars[#bars + 1] = { get = function() return wgt.values.elrs_tq end,     warn = rq_warn, crit = rq_crit } end
        if show_rssi then
            bars[#bars + 1] = { get = function() return wgt.values.elrs_r1_pct end, warn = rs_warn, crit = rs_crit }
            if wgt.values.elrs_diversity then
                bars[#bars + 1] = { get = function() return wgt.values.elrs_r2_pct end, warn = rs_warn, crit = rs_crit }
            end
        end

        local n = #bars
        if n > 0 then
        local avail_h = math.max(n * 2, c_h - 2)
        local slot_h  = math.floor(avail_h / n)
        local bar_h   = math.max(2, slot_h - 1)
        local top_y   = y + math.floor((c_h - slot_h * n) / 2)

        -- V2 "outline look" (matches the TX battery icon): empty rounded track with
        -- a fine outline, inset fill, threshold NOTCHES at the bottom edge. With the
        -- BarsQuiet setting the fill stays neutral dark while everything is fine and
        -- only turns yellow/red on warn/crit ("quiet when good, loud when bad").
        -- Tiny bars (small screens) fall back to the simple filled-track style.
        local outlined = bar_h >= 6
        local function fill_color(get, warn, crit)
            return function()
                local v = get()
                if v == nil then return TRACK end
                -- O5: `<=`, the alert engine's boundary (update_link_warning /
                -- update_rssi_warning), NOT `<`. Exactly ON a threshold the voice said
                -- critical while this bar was still amber.
                if v <= crit then return C_RED end
                if v <= warn then return C_YELL end
                return quiet and C_NEUT or C_GREEN
            end
        end

        local elems = {}
        for i = 1, n do
            local by   = top_y + (i - 1) * slot_h
            local get  = bars[i].get
            local warn = bars[i].warn
            local crit = bars[i].crit
            if outlined then
                local fx, fy, fh = center_x + 1, by + 1, bar_h - 2
                local fw_max = bar_w - 2
                elems[#elems + 1] = { type = "rectangle", x = center_x, y = by, w = bar_w, h = bar_h, thickness = 1, rounded = 2, color = COLOR_THEME_SECONDARY1 }
                -- NO `pos` closure: x/y are build-time constants and only the WIDTH is
                -- reactive. It used to carry `pos = function() return fx, fy end`, a closure
                -- LVGL invoked every frame to be handed the same two numbers it was built
                -- with. MEASURED on the simulator 2026-08-17 (harness scenario `h5pos`, the
                -- link bars at 800x480): with and without the closure, all 12 resolved
                -- rectangles -- 3 bands x 4 RQly steps -- are identical to the pixel, x0/y0
                -- never move, and band 0's width does change across the sweep, which is the
                -- positive control that the run could have seen a difference.
                elems[#elems + 1] = {
                    type = "rectangle", x = fx, y = fy, w = 1, h = fh, filled = true, rounded = 1,
                    color = fill_color(get, warn, crit),
                    size = function()
                        local v = get() or 0
                        if v < 0 then v = 0 elseif v > 100 then v = 100 end
                        return math.floor(fw_max * v / 100), fh
                    end
                }
                local nh = math.max(2, math.floor(bar_h * 0.45))
                elems[#elems + 1] = { type = "rectangle", x = center_x + math.floor(bar_w * crit / 100), y = by + bar_h - nh, w = 2, h = nh, filled = true, color = TICK }
                elems[#elems + 1] = { type = "rectangle", x = center_x + math.floor(bar_w * warn / 100), y = by + bar_h - nh, w = 2, h = nh, filled = true, color = TICK }
            else
                elems[#elems + 1] = { type = "rectangle", x = center_x, y = by, w = bar_w, h = bar_h, filled = true, color = TRACK }
                -- same as the outlined branch above, and NOT separately measured: this is the
                -- thin-bar branch (bar_h < 6), which no supported radio reaches at its
                -- fullscreen zone, so the simulator could not drive it. It is the same element
                -- type on the same container:build path, and what was measured there is a
                -- property of that path -- the binding updates w/h through its own setter and
                -- never touches x/y without a `pos`.
                elems[#elems + 1] = {
                    type = "rectangle", x = center_x, y = by, w = 1, h = bar_h, filled = true,
                    color = fill_color(get, warn, crit),
                    size = function()
                        local v = get() or 0
                        if v < 0 then v = 0 elseif v > 100 then v = 100 end
                        return math.floor(bar_w * v / 100), bar_h
                    end
                }
                elems[#elems + 1] = { type = "rectangle", x = center_x + math.floor(bar_w * crit / 100), y = by, w = 1, h = bar_h, filled = true, color = TICK }
                elems[#elems + 1] = { type = "rectangle", x = center_x + math.floor(bar_w * warn / 100), y = by, w = 1, h = bar_h, filled = true, color = TICK }
            end
        end
        container:build(elems)

        -- bar-cluster rect for the fullscreen tap hit-test in refresh() (box-local ≈
        -- screen coords here: the widget runs as a full-screen zone, box sits ~2 px in).
        -- The ELRS detail is fullscreen-only: outside fullscreen touch never reaches
        -- the script, and the lvgl-button experiment for normal-mode taps did not
        -- fire on hardware — dropped on purpose.
        wgt.elrs_bar_rect = { x = center_x, y = y, w = bar_w, h = c_h }
        end
    end

    -- voltage left of the icon (toggleable)
    if show_txv then
        container:label({
            x = volt_text_x,
            y = y + y_off,
            w = volt_w,
            h = font_h,
            text = wgt.values.vtx_voltage_formatted,
            font = header_font,
            color = function() return wgt.values.vtx_volts_color end,
            align = RIGHT
        })
    end

    -- battery icon (track on dark panels, terminal, reactive fill, outline)
    local icon_elems = {}
    -- ICON TRACK: on a dark panel the unfilled interior was the panel
    -- itself, so the fixed-black % text vanished below ~60% fill — this icon is
    -- the ONLY radio-battery display (it replaces the EdgeTX top bar). A light
    -- track layer between fill and outline keeps BLACK readable; built only when
    -- the EFFECTIVE panel is dark, so the light look stays untouched (build-time
    -- decision, no frame cost).
    if force_bg_fill or color_luma(PANEL_BG) < DARK_LUMA_THRESHOLD then
        icon_elems[#icon_elems + 1] = {
            type = "rectangle",
            x = icon_x + 1,
            y = icon_y + 1,
            w = icon_w - 2,
            h = icon_h - 2,
            filled = true,
            rounded = math.max(1, icon_r - 1),
            color = lcd.RGB(0xB4, 0xB8, 0xBC)
        }
    end
    icon_elems[#icon_elems + 1] = {
        type = "rectangle",
        x = icon_x + icon_w,
        y = icon_y + math.floor(icon_h * 0.28),
        w = term_w,
        h = math.max(2, math.floor(icon_h * 0.44)),
        filled = true,
        color = COLOR_THEME_PRIMARY1
    }
    icon_elems[#icon_elems + 1] = {
        type = "rectangle",
        x = icon_x + 1,
        y = icon_y + 1,
        w = 1,
        h = icon_h - 2,
        filled = true,
        rounded = math.max(1, icon_r - 2),
        color = function() return wgt.values.vtx_fill_color() end,
        -- constant `pos` dropped, same reasoning as the link bars -- and NOT separately
        -- measured either: this fill is driven by the RADIO's own battery
        -- (vtx_fill_ratio), which the simulator harness cannot move, so a run there would
        -- have watched a size that never changes and proved nothing about position under a
        -- changing one. Covered by the measured property of the binding, not by its own run.
        size = function() return math.max(0, math.floor((icon_w - 2) * wgt.values.vtx_fill_ratio())), icon_h - 2 end
    }
    icon_elems[#icon_elems + 1] = {
        type = "rectangle",
        x = icon_x,
        y = icon_y,
        w = icon_w,
        h = icon_h,
        thickness = 1,
        rounded = icon_r,
        color = COLOR_THEME_PRIMARY1
    }
    container:build(icon_elems)

    -- percentage overlaid on the icon (drawn last → on top of the fill). Ink from
    -- the EFFECTIVE fill colours' luma (same build-time decision as the
    -- fuel gauge's overlay_ink): fixed BLACK was unreadable on a dark ClrXO/ClrXL
    -- override. Defaults are both above the threshold -> BLACK, look unchanged.
    -- % overlaid on the TX battery: on the LIGHT design always BLACK (user request
    -- 2026-07-22 — white read wrong there); on the DARK design WHITE on the
    -- (mid-bright) green/red fills like the mockup, flipped to BLACK only if a very
    -- LIGHT battery-color override would swallow white.
    local vtx_ink
    if not (force_bg_fill or color_luma(PANEL_BG) < DARK_LUMA_THRESHOLD) then
        vtx_ink = BLACK
    else
        vtx_ink = (color_luma(SEM.vtx_ok) > 180
            and color_luma(SEM.vtx_low) > 180) and BLACK or WHITE
    end
    container:label({
        x = icon_x,
        y = icon_y + math.floor((icon_h - pct_font_h) / 2),
        w = icon_w,
        h = pct_font_h,
        text = wgt.values.vtx_volts_formatted,
        font = pct_font,
        color = vtx_ink,
        align = CENTER
    })
end

-- ========== UI Builder Function ==========
-- ============================================================================
-- MAIN FUNCTIONS: Widget lifecycle (create, update, background, refresh)
-- ============================================================================


--- Build the status/config page (menu ▸ Status): the ACTIVE configuration — read
--- from the Shared snapshot this instance publishes (resolved cell thresholds incl.
--- the MSP-fetched FC values, alert thresholds, alert switches). Rendered as an
--- lvgl.page with back-to-menu.
-- WHICH BUILD IS ON THE CARD (menu -> Status, one row).
-- The version is main.lua's `app_ver`, handed over by set_version() below rather than
-- duplicated here: main.lua stays the single place that is bumped at release.
-- The commit cannot be known at runtime -- this is plain Lua on an SD card -- so a dev
-- build gets it from `build.lua`, which the card-building step WRITES ONTO THE CARD and
-- which is never part of the sources. Its absence is the normal case (a
-- release card has none) and means "version only", not an error.
-- Resolved LAZILY on the first Status build: this costs create() nothing, and the Status
-- page is built rarely and has ~15k of headroom.
local app_ver = nil
local version_str = nil
local function version_text()
    if version_str ~= nil then return version_str end
    version_str = app_ver or "?"
    local ok, b = pcall(function()
        local f = loadScript(script_dir .. "build.lua")
        return f ~= nil and f() or nil
    end)
    if ok and type(b) == "table" and type(b.commit) == "string" then
        -- "+" marks a build made from a dirty tree: the commit alone would name a state
        -- the card does not actually carry.
        version_str = version_str .. "  " .. b.commit .. ((b.dirty == true) and "+" or "")
    end
    return version_str
end

-- The cfg file in force, file name only -- the directory is fixed and the row is narrow.
-- Read through the settings module rather than rebuilt here: `target_path` is already
-- "the file a save would land in RIGHT NOW", which is exactly the question being asked.
local cfg_file_str = nil
local function cfg_file_text()
    if cfg_file_str ~= nil then return cfg_file_str end
    local ok, p = pcall(ultidash_settings.target_path)
    -- string.match, NOT p:match -- the widget Lua state has no string metatable, so method
    -- syntax raises "attempt to index a string value" and takes the dashboard down with it.
    cfg_file_str = (ok and type(p) == "string" and string.match(p, "([^/]+)$")) or "?"
    -- ...plus WHY it is this file, when it is not simply the model's name. Two states,
    -- and they mean opposite things, so they never share a marker:
    --   (found)   the name lookup missed and this cfg was located by its ModelFile stamp
    --             -- i.e. the model is wearing a craft name right now.
    --   (! <slot>) this file says it belongs to another model file. The name won; the
    --             contradiction is shown rather than silently resolved.
    local ok2, resolved, conflict = pcall(ultidash_settings.key_state)
    if ok2 then
        if conflict ~= nil then cfg_file_str = cfg_file_str .. "  (! " .. tostring(conflict) .. ")"
        elseif resolved then cfg_file_str = cfg_file_str .. "  (found)" end
    end
    return cfg_file_str
end

local function build_status_view(wgt, zone)
    local w = zone.w
    local h = zone.h
    local shared = ultidash_functions.get_shared()
    local th, al, vol = shared.thresholds, shared.alerts, shared.volume

    local function num(v, fmt) if v == nil then return "-" end return string.format(fmt, v) end
    -- Per-frame MEMO: every val closure runs per LVGL frame (~20 Hz) while the
    -- page is open. The old closures format/concat fresh strings (and sounds_off a
    -- fresh table) on EVERY frame = constant GC pressure. Each row now rebuilds its string only
    -- when its (up to 4) key values change — key() uses multiple RETURNS, so the
    -- per-frame path is compares only, zero allocation. Settings-derived rows key
    -- on settings_gen (module-local, bumps on every save/reset in any instance).
    local function memo(key, build)
        local k1, k2, k3, k4, s
        return function()
            local n1, n2, n3, n4 = key()
            if s == nil or n1 ~= k1 or n2 ~= k2 or n3 ~= k3 or n4 ~= k4 then
                k1, k2, k3, k4 = n1, n2, n3, n4
                s = build()
            end
            return s
        end
    end
    local sounds_off = memo(
        -- the alert flags + the two gates are all settings-derived -> settings_gen
        function() return shared.ready, settings_gen, th.esc_load, th.temp_on end,
        function()
            if not shared.ready then return "-" end
            local off = {}
            if al.cellchk == false then off[#off + 1] = "CellChk" end
            if al.fuel    == false then off[#off + 1] = "Fuel" end
            if al.volt    == false then off[#off + 1] = "Volt" end
            if al.arm     == false then off[#off + 1] = "Arm" end
            if al.telem   == false then off[#off + 1] = "Telem" end
            if al.link    == false then off[#off + 1] = "Link" end
            if al.rssi    == false then off[#off + 1] = "Rssi" end
            if al.pwr     == false then off[#off + 1] = "Pwr" end
            if al.bec     == false then off[#off + 1] = "Bec" end
            if al.skp     == false then off[#off + 1] = "Skp" end
            -- EscL only when ESC-load monitoring is actually on (else every non-user would
            -- permanently see "EscL" listed as off)
            if al.escl == false and th.esc_load then off[#off + 1] = "EscL" end
            -- Temp only when at least one temperature threshold is set (same reasoning as EscL)
            if al.temp == false and th.temp_on then off[#off + 1] = "Temp" end
            if #off == 0 then return "none (all enabled)" end
            return table.concat(off, ", ")
        end)

    -- section markers ({ section=... }) group the config; the rest are label/value rows.
    -- Rows without string building ("Cell source", "Repeat") stay plain closures.
    local items = {
        -- Which build is on the card. Until now the version existed only as a constant in
        -- main.lua and appeared nowhere on screen, so "which UltiDash is this radio
        -- running" was unanswerable without pulling the card. A plain string: neither the
        -- version nor the build reference can change while the widget runs.
        { lbl = "Version", val = version_text() },
        -- The craft target this instance was PLACED with (EdgeTX widget options), plus the
        -- cross-check against what the sensors say. The message states the OBSERVATION and
        -- not a diagnosis -- a model with renamed sensors and a wrongly declared target look
        -- exactly alike from here, and only the pilot can tell them apart. Silent unless all
        -- four positive-control conditions hold (caps.norf covers three, `connected` the
        -- fourth); see the caps build in resolve_sensor_indices.
        { lbl = "Craft target", val = memo(
            function() return shared.connected, wgt.caps and wgt.caps.msp,
                              wgt.caps and wgt.caps.norf end,
            function()
                local n = wgt.opt_mod and wgt.opt_mod.target_name(wgt.target) or "-"
                if shared.connected and wgt.caps and wgt.caps.msp and wgt.caps.norf then
                    return n .. "  (no " .. n .. " sensors found)"
                end
                return n
            end) },
        -- WHICH cfg file this radio is actually reading and writing, by name. The key is
        -- the model name LATCHED AT BOOT (ultidashSettings model_key), and a connected
        -- craft renames the EdgeTX model underneath us -- Rotorflight's own RF2 background
        -- script does it and puts the name back on disconnect. So one helicopter can own
        -- two cfg files, and which one is in force depends on whether the craft was
        -- powered when the radio booted. That was invisible until now: a user looking at
        -- settings they did not make had nothing on screen to explain it (2026-08-13).
        -- Static like Version: the latch cannot move without a model switch, and a model
        -- switch rebuilds this page anyway.
        { lbl = "Config file", val = cfg_file_text() },
        { lbl = "Model / link", val = memo(
            function() return shared.ready, shared.model_name, shared.connected end,
            function()
                if not shared.ready then return "-" end
                return (shared.model_name or "-") .. (shared.connected and "  (conn)" or "  (disc)")
            end) },
        -- WHICH RFTool this radio carries, by its own contract version. It is the answer to
        -- "why does this install behave differently", and it is reported rather than acted
        -- on: nothing in the widget branches on the number (see ultidashRf note_tool_api).
        -- "not reported" is a working RFTool 2.3.0-RC1, not a fault; "-" means no RFTool.
        { lbl = "RFTool API", val = function() return wgt.values.rf_tool_api_text or "-" end },
        -- WHO is serving MSP, and -- for the RFSuite service -- whether anybody is pumping
        -- it. Two providers can publish into this Lua state and they share the radio's one
        -- CRSF transmit slot, so UltiDash picks RFTool and says the other was seen rather
        -- than arbitrating silently. "(idle)" is a published surface nobody drives, which
        -- is the one case where the values are missing and nothing looks wrong.
        { lbl = "MSP provider", val = function() return wgt.values.rf_provider_text or "-" end },
        { section = "Battery" },
        { lbl = "Cell source", val = function() return th.source or "-" end },
        { lbl = "Cell full / low / crit", val = memo(
            function() return th.cell_full, th.cell_warn, th.cell_crit end,
            function()
                if th.cell_full == nil then return "-" end
                return string.format("%.2f / %.2f / %.2f V", th.cell_full or 0, th.cell_warn or 0, th.cell_crit or 0)
            end) },
        { lbl = "Reserve", val = memo(
            function() return shared.ready, th.reserve end,
            function() if not shared.ready then return "-" end return num(th.reserve, "%d %%") end) },
        -- What the FLIGHT CONTROLLER itself is configured for (MSP, read at connect/disarm).
        -- All of it is configuration: it cannot change while the craft flies, so one read
        -- holds all session and every row is a PLAIN closure over a string the RF service
        -- built once per read (ultidashRf on_*_received) -- no memo, no per-frame concat.
        -- Deliberately none of this is on the dashboard: a dashboard is for what moves.
        { section = "Flight controller" },
        -- voltage / current meter source. current = None is the third condition of the
        -- SmartFuel bat_capacity trap, which is why it is worth a row of its own.
        { lbl = "Meters  V / I", val = function() return wgt.values.rf_meter_src_text or "-" end },
        -- The FC's OWN consumption warning, shown so the pilot can compare it with the
        -- UltiDash fuel thresholds two sections up. It drives NOTHING here, by decision:
        -- the callout thresholds are the pilot's and are set in this widget.
        -- The one row in this block that FORMATS rather than reading a string the RF service
        -- built once, so it is the one that needs the memo its neighbours two sections up
        -- use: without it, string.format ran per LVGL frame for a number that moves at most
        -- once per connect.
        { lbl = "FC fuel warn (info)", val = memo(
            function() return wgt.values.rf_fc_fuel_warn_pct end,
            function()
                local v = wgt.values.rf_fc_fuel_warn_pct
                return v and string.format("%d %%", v) or "-"
            end) },
        { lbl = "LVC / cell max", val = function() return wgt.values.rf_batt_limits_text or "-" end },
        { lbl = "Gov mode", val = function() return wgt.values.rf_gov_mode_name or "-" end },
        { lbl = "Gov spool / start / hand", val = function() return wgt.values.rf_gov_timing_text or "-" end },
        { lbl = "Gov throttle", grow = true, val = function() return wgt.values.rf_gov_throttle_text or "-" end },
        -- The FC's own telemetry slot list -- the row that explains an N/S on the sensor
        -- check. In NATIVE mode there is no slot count, because the firmware ignores the
        -- list entirely in that mode.
        { lbl = "Telemetry", val = function() return wgt.values.rf_crsf_text or "-" end },
        { lbl = "SmartFuel", val = function() return wgt.values.rf_smartfuel_mode_name or "-" end },
        { lbl = "ESC protocol", val = function() return wgt.values.rf_esc_protocol_name or "-" end },
        -- M4: the EFFECTIVE adjust-table source. The option can say FC while a refused,
        -- failed or never-triggered walk leaves the hand table in force -- that state is
        -- silent by design everywhere else, so this row is where it becomes checkable.
        { lbl = "Adjust table", val = memo(
            function()
                return settings_gen, wgt.values.rf_adj_state,
                    wgt.rf and wgt.rf.adj_gen or 0, wgt.rf and wgt.rf.adj_table ~= nil
            end,
            function()
                local src = wgt.options and wgt.options.TbSource or 1
                if src < 2 then return "manual" end
                local lbl = (src >= 3) and "FC + labels" or "FC"
                local t = wgt.rf and wgt.rf.adj_table
                if t ~= nil then return string.format("%s - %d slots", lbl, #t) end
                local st = wgt.values.rf_adj_state
                if st == "reading" then return lbl .. " - reading..." end
                if st == "failed" then return lbl .. " - read failed, manual in use" end
                return lbl .. " - waiting for connect, manual in use"
            end) },
        -- M4 for M5: whether the live monitor's ring is actually RUNNING. The option
        -- rows can name sensors while every read returns nil (renamed sensor, wrong
        -- model) -- the strips would sit at their baseline with no error anywhere,
        -- so the sampled state is made checkable here.
        { lbl = "Live monitor", val = memo(
            function()
                local lm = wgt.lm
                return settings_gen, lm ~= nil and lm.n or 0,
                    lm ~= nil and lm.head or 0
            end,
            function()
                local lm = wgt.lm
                if lm == nil then return "off (no sensors configured)" end
                if lm.head == 0 then return string.format("%d sensor(s), no samples yet", lm.n) end
                return string.format("%d sensor(s), ring at %d s of 60",
                    lm.n, math.min(60, math.floor(lm.head / 5)))
            end) },
        { section = "Link" },
        { lbl = "RQly warn / crit", val = memo(
            function() return shared.ready, th.rq_warn, th.rq_crit end,
            function()
                if not shared.ready then return "-" end
                return num(th.rq_warn, "%d %%") .. "  /  " .. num(th.rq_crit, "%d %%")
            end) },
        { lbl = "RSSI warn / crit / hold", val = memo(
            function() return shared.ready, th.rss_warn, th.rss_crit, th.rss_hold end,
            function()
                if not shared.ready then return "-" end
                return num(th.rss_warn, "%d %%") .. " / " .. num(th.rss_crit, "%d %%") .. " / " .. num(th.rss_hold, "%d s")
            end) },
        { section = "Alerts" },
        { lbl = "Power warn", val = memo(
            function() return shared.ready, th.pwr_warn_v end,
            function() if not shared.ready then return "-" end return num(th.pwr_warn_v, "%.1f V") end) },
        { lbl = "BEC warn / crit", val = memo(
            function() return shared.ready, th.bec_warn, th.bec_crit end,
            function()
                if not shared.ready then return "-" end
                return num(th.bec_warn, "%d %%") .. "  /  " .. num(th.bec_crit, "%d %%")
            end) },
        { lbl = "ESC load", val = memo(
            -- all inputs are settings-derived -> settings_gen covers the whole row
            function() return shared.ready, settings_gen, th.esc_limit end,
            function()
                if not shared.ready then return "-" end
                if not th.esc_load then return "off" end
                local lim = th.esc_limit and (th.esc_limit .. " A") or "not set"
                return "GV" .. (th.esc_gvar or "?") .. "  " .. lim .. "  " .. num(th.esc_warn, "%d") .. " / " .. num(th.esc_crit, "%d %%")
                    .. "  " .. num(th.esc_hold, "%d s")
            end) },
        { lbl = "Skipped limit", val = memo(
            function() return shared.ready, th.skp_limit end,
            function() if not shared.ready then return "-" end return num(th.skp_limit, "%d") end) },
        { lbl = "Repeat", grow = true,
          val = function() if not shared.ready then return "-" end return al.repeat_summary or "none" end },
        { lbl = "Mute / escalation", val = memo(
            function() return shared.ready, al.mute, al.escalating end,
            function()
                if not shared.ready then return "-" end
                return (al.mute and "ALL MUTED" or "none") .. "  /  " .. (al.escalating and "ACTIVE" or "idle")
            end) },
        { lbl = "Sounds off", val = sounds_off },
        -- M4 (D3): name-wav coverage of the spoken report. The decided fallback speaks
        -- value-and-unit, so an incomplete recording set cannot be HEARD -- this row is
        -- where that state becomes checkable. "off" = the names option itself is off.
        { lbl = "Report name wavs", val = memo(
            function() return settings_gen end,
            function()
                local f, t, lang = ultidash_functions.tsay_wav_state(wgt)
                if f == nil then return "off (values only)" end
                if t == 0 then return "no slots configured" end
                return string.format("%d/%d found (%s)", f, t, lang)
            end) },
        { section = "Volume" },
        { lbl = "Callout / voice", val = memo(
            function() return shared.ready, vol ~= nil and vol.callout or nil, vol ~= nil and vol.voice or nil end,
            function()
                if not shared.ready or vol == nil then return "-" end
                local c = vol.callout or 0
                return ((c == 0) and "System" or (c .. "/5")) .. "  /  " .. (vol.voice or "-")
            end) },
        { lbl = "Master (GVAR)", val = memo(
            function()
                if vol == nil then return shared.ready end
                return shared.ready, vol.gvar, vol.flight, vol.escal
            end,
            function()
                if not shared.ready or vol == nil then return "-" end
                if (vol.gvar or 0) == 0 then return "off (radio vol)" end
                return "GV" .. vol.gvar .. "   " .. (vol.flight or "-") .. " / " .. (vol.escal or "-") .. " %"
            end) },
    }

    -- scrollable page (menu -> Status): sections + rows, everything fits via scroll
    local pg = lvgl.page({
        -- M5: the header wears the glyph of the hub tile that leads here
        title = "UltiDash", subtitle = "Diagnostics > Status", icon = "/WIDGETS/UltiDash/img/ud_status.png",
        back = function() wgt.menu_view = "menu"; init_view_state(wgt).dirty = true end,
    })
    -- row height + label boxes MEASURED (rule 8): the hardcoded 26/22 clipped the
    -- descenders of the taller STDSIZE on the 800x480 MK3 -- the very bug that was
    -- already fixed in the settings renderer (see ultidashMenu build_settings_view)
    -- and overlooked here.
    local _, lbl_h = lcd.sizeText("Ag", 0)
    local row_h = lbl_h + 4
    local lblw = math.floor(w * 0.46)
    local y = 2
    for i = 1, #items do
        local it = items[i]
        if it.section then
            -- FOCUS STOP, not a label: an lvgl.page reacts to the encoder only through
            -- focusable objects, so a page built from labels alone cannot be scrolled
            -- without a finger at all. ultidash_functions.focus_stop carries the mechanism
            -- and the reason the closing line below is one too.
            y = y + 6
            y = y + ultidash_functions.focus_stop(pg, y, w, it.section,
                                                  SMLSIZE, COLOR_THEME_FOCUS) + 2
        else
            -- `it.grow`: a row whose value is GENERATED and whose length is not bounded by
            -- anything the layout knows -- the Repeat summary grows with the number of
            -- active alerts. No fixed box can be right for it, so this one is MEASURED at
            -- build time and given a second line when it needs one: 226 px of value box on
            -- a 480-wide radio against a 37-character string was two lines in a one-line
            -- box, on the TX15 and the MK2 (the MK3's row is wider, which is the only
            -- reason it never showed). The alternative was to shorten the summary, and it
            -- is a diagnostic line -- keeping all of it is worth one sizeText per build.
            local vh = lbl_h + 2
            if it.grow then
                local vtxt = it.val
                if type(vtxt) == "function" then vtxt = vtxt() end
                -- as many lines as it takes, not one extra. A single doubling covered the
                -- 37-character case that was reported and clipped again past ~5 enabled
                -- repeats on a 480-wide radio -- which is a realistic setup, not a corner.
                -- The 0.95 is LVGL breaking on word boundaries: a line rarely fills to the
                -- last pixel, so the raw division under-counts.
                local box = w - lblw - 34
                local need = math.ceil(lcd.sizeText(tostring(vtxt), 0) / math.max(1, box * 0.95))
                if need > 1 then vh = math.min(need, 4) * lbl_h + 2 end
            end
            pg:label({ x = 10, y = y, w = lblw, h = lbl_h + 2, text = it.lbl, color = COLOR_THEME_SECONDARY1, align = LEFT })
            pg:label({ x = 10 + lblw, y = y, w = w - lblw - 34, h = vh, text = it.val, color = COLOR_THEME_PRIMARY1, align = RIGHT })
            y = y + math.max(row_h, vh + 2)
        end
    end
    -- The metrics line is the LAST focus stop, and that is what makes the section above it
    -- reachable: a stop only ever reveals what sits ABOVE it (see focus_stop), so without
    -- one past the last section that section's rows stay under the fold for the encoder.
    ultidash_functions.focus_stop(pg, y + 8, w,
        -- memoized on wgt.dbg_win (metrics refresh together once per second)
        (function()
            local last_win, last_s, primed
            return function()
                local win = wgt.dbg_win
                if primed and win == last_win then return last_s end
                last_win, primed = win, true
                last_s = "Lua " .. (wgt.dbg_lua_kb or "-") .. " kB  free " .. (wgt.dbg_free_kb or "-")
                    .. " kB   UI " .. (wgt.dbg_hz or "-") .. " Hz"
                return last_s
            end
        end)(), SMLSIZE, COLOR_DIM)
end


-- ============================================================================
-- IN-WIDGET SETTINGS PAGE (fullscreen only)
-- ============================================================================
-- The EdgeTX widget-options list is flat and survives updates badly (index
-- shifts); these settings are edited here instead and persisted per model via
-- ultidashSettings (which overlays them onto wgt.options). First group: alerts.

local function fmt_centivolt(v) return string.format("%.2f V", v / 100) end
local function fmt_decivolt(v) return string.format("%.1f V", v / 10) end

-- Order/grouping is presentation only (section headers); the keys are unchanged so cfg
-- files are unaffected.
-- The settings ITEM CATALOGUE is built by SETTINGS_GROUPS._build in its own staged
-- cycle (stage 2a0, drained by the stage-2a gates right before register_skin_defaults)
-- instead of at module level: the constructors cost ~5.7k instructions, which used to
-- be the largest single block inside create()'s budget. Forward locals only here.
-- The two tables whose REFERENCE other code captures (SETTINGS_GROUPS via the menu
-- env, ALERT_PAGES the same way) are created here and filled IN PLACE by the builder,
-- so a captured reference can never go stale; the item tables are only ever reached
-- through SETTINGS_GROUPS rows the builder itself writes.
-- Since 2026-08-17 the fourteen flat group tables are LAZY (builder + keys() on the
-- group row, see MK/KEYS in the builder) and need no forward locals at all -- which is
-- also 13 of them back under the 200-local wall.
local ALERT_PAGES = {}


-- Switch shortcuts: bind switch positions / toggle presses to any detail page or
-- Toolbox tool (targets come from SHORTCUT_TARGETS). Two mechanisms:
--   * 6 POSITION slots: while the picked switch position is held the page is open
--     ("hold = open, leave = close"). A stability delay (SwDelay) means passing
--     through an intermediate position on the way to another doesn't fire it.
--   * 2 TOGGLE slots: each press of the picked switch steps opt1 -> opt2 -> ... -> close.
-- Switch + position are picked in ONE native EdgeTX switch picker (kind="swpos",
-- lvgl.switch: "SA-up" etc., incl. logical switches) — the value is a swsrc index read
-- via getSwitchValue. Keys (per slot): Sc<i>Sp / Sc<i>Tgt (positions), Tg<j>Sp /
-- Tg<j>O1..O4 (toggles). (The pre-picker keys Sc<i>Sw/Sc<i>Pos/Tg<j>Sw from the first
-- 0.6.0 WIP builds are ignored — re-pick once.) Rows are generated so the slot count is
-- a one-line change. All slots READ the switch only — the model's mixer/arming logic
-- stays untouched.
-- The Shortcuts group is SUBMENU PAGES (not a flat list): the position slots and the
-- toggle slots each get their own page. The flat 39-row page built ~14 dropdowns + 8
-- switch pickers in ONE refresh() call and overran EdgeTX's ~20k-instruction widget budget
-- ("CPU limit" mid-build); split, each page's build stays well within budget.
-- The item tables build LAZILY on first open (page.build — same idea as the colour
-- pages): building both pages at module load ran inside create()'s budget for rows the
-- user may never open. page.keys hands for_each_setting_item the key/def pairs WITHOUT
-- building the rows — keep keys() and the builders in sync when adding a slot.
function shortcut.pos_items()
    -- page 1: switch delay + the 6 hold-to-open position slots
    local pos = {}
    pos[#pos + 1] = { key = "SwDelay", lbl = "Switch delay (ms)", kind = "num", def = 300,
                      min = 0, max = 1000, step = 10, big = 100,
                      fmt = function(v) return v == 0 and "instant" or (v .. " ms") end }
    pos[#pos + 1] = { kind = "info", lbl = "Position slots: hold the picked switch position to show the page, leave it to close. The delay above filters passing through a position." }
    for i = 1, 6 do
        local swk = "Sc" .. i .. "Sp"
        local function off(w) return (w[swk] or 0) == 0 end
        pos[#pos + 1] = { kind = "section", lbl = "Position slot " .. i }
        pos[#pos + 1] = { key = swk, lbl = "Switch position", kind = "swpos", def = 0 }
        pos[#pos + 1] = { key = "Sc" .. i .. "Tgt", lbl = "Opens", kind = "choice",
                          def = 1, vals = shortcut.tlabels, dim = off }
    end
    return pos
end
function shortcut.tgl_items()
    -- page 2: the 2 press-to-step toggle slots
    local tgl = {}
    tgl[#tgl + 1] = { kind = "info", lbl = "Toggle switches: each press (switch into the picked position) steps to the next option, after the last it closes." }
    for j = 1, 2 do
        local swk = "Tg" .. j .. "Sp"
        local function off(w) return (w[swk] or 0) == 0 end
        tgl[#tgl + 1] = { kind = "section", lbl = "Toggle switch " .. j }
        tgl[#tgl + 1] = { key = swk, lbl = "Switch position", kind = "swpos", def = 0 }
        for k = 1, 4 do
            tgl[#tgl + 1] = { key = "Tg" .. j .. "O" .. k, lbl = "Option " .. k,
                              kind = "choice", def = 1, vals = shortcut.tlabels, dim = off }
        end
    end
    return tgl
end
-- attached to the existing shortcut table, not a new module local (200-locals limit)
shortcut.pages = {
    { name = "Position slots",  icon = "positions", build = shortcut.pos_items, keys = function(fn)
        fn("SwDelay", 300)
        for i = 1, 6 do
            fn("Sc" .. i .. "Sp", 0); fn("Sc" .. i .. "Tgt", 1)
        end
    end },
    { name = "Toggle switches", icon = "toggles", build = shortcut.tgl_items, keys = function(fn)
        for j = 1, 2 do
            fn("Tg" .. j .. "Sp", 0)
            for k = 1, 4 do fn("Tg" .. j .. "O" .. k, 1) end
        end
    end },
}

-- items are built LAZILY on first open (open_page in build_colors_menu_view) — building all
-- three pages here at module load happened inside create()'s instruction budget (~57 rows of
-- item tables) and pushed it toward the CPU limit. The defaults/working-copy walk derives the
-- colour keys straight from COLOR_ROLES (see for_each_setting_item), so nothing needs .items
-- until the user actually opens a colour page.
-- Since stage 3b the colour pages follow the ACTIVE SKIN's scheme list, and the "Skin"
-- settings group shows the active skin's own option rows. Both are IN-PLACE refreshed
-- tables (refresh_skin_menus below): the menu module and SETTINGS_GROUPS hold their
-- references from module load, only the contents swap on a skin change.
local COLOR_PAGES = {}
local SETTINGS_SKIN = {}
local menus_skin = nil   -- the SKINS entry the two tables currently reflect
local function refresh_skin_menus(reg)
    if menus_skin == reg then return end
    menus_skin = reg
    local schemes = reg.schemes or SCHEMES
    -- Colors pages: only the OVERRIDABLE schemes (with a tag). Tag-less schemes are
    -- fixed by the skin file — nothing for the user to edit, so no page.
    for i = #COLOR_PAGES, 1, -1 do COLOR_PAGES[i] = nil end
    for i = 1, #schemes do
        if schemes[i].tag ~= nil then
            -- M1/M5 one level down: the page carries its OWN glyph instead of the Colors
            -- group's palette. A skin-supplied scheme brings none and falls back to the
            -- glyph the Skin group already owns -- one meaning, one picture, and it keeps
            -- a skin from having to ship artwork before it may offer a scheme.
            COLOR_PAGES[#COLOR_PAGES + 1] = { name = schemes[i].name, scheme = schemes[i],
                                              icon = schemes[i].icon or "layers" }
        end
    end
    for i = #SETTINGS_SKIN, 1, -1 do SETTINGS_SKIN[i] = nil end
    -- row 1 is always the skin's OWN scheme choice (synthesised per skin: its key,
    -- its default, its scheme names — colour settings belong to the skin). ALL
    -- schemes are choosable here, fixed ones included.
    if reg.scheme_key ~= nil then
        local names = {}
        for i = 1, #schemes do names[i] = schemes[i].name end
        SETTINGS_SKIN[1] = { key = reg.scheme_key, lbl = "Color scheme", kind = "choice",
                             def = reg.def_scheme or 1, vals = names }
    end
    -- row 2, when the skin claims the units switch: whether a unit is worth the font
    -- size it costs is a LAYOUT property (the reason the key ships off is itself one),
    -- so it belongs beside the colour scheme rather than in the host's Display group.
    -- Absent = the skin reads the host key and the host row alone governs it.
    if reg.units_key ~= nil then
        SETTINGS_SKIN[#SETTINGS_SKIN + 1] = { key = reg.units_key, lbl = "Units beside values",
                                              kind = "bool", def = reg.def_units or 0 }
    end
    -- what the flight panel and env.sensor_slot read per build (a plain field, not a
    -- module local: the main chunk is at Lua's 200-local limit)
    SKINS._units_key = reg.units_key
    local items = reg.items
    if items ~= nil then
        local base = #SETTINGS_SKIN
        for i = 1, #items do SETTINGS_SKIN[base + i] = items[i] end
    end
    -- does this skin want the session extrema of its sensor slots? (opt-in: they cost two
    -- extra source reads per slot per 5 Hz pass — see update_user_sensors). Stored as a
    -- FIELD, not a local: the main chunk sits at the 200-local limit.
    SKINS._want_extrema = (reg.wants_extrema == true)
    -- collect this skin's sensor-slot keys so the 5 Hz pass fills their live values
    local sk = SKINS._sensor_keys
    for i = #sk, 1, -1 do sk[i] = nil end
    if items ~= nil then
        for i = 1, #items do
            if items[i].kind == "sensor" and items[i].key then
                sk[#sk + 1] = items[i].key
            end
        end
    end
    -- the threshold service's pull list goes with them: the names in it were registered by
    -- the OUTGOING skin's build, and a skin that no longer asks for Tmcu must stop paying
    -- for the read. env.threshold_for re-registers on the next build.
    local ex = SKINS._extra_names
    if ex ~= nil then
        for i = #ex, 1, -1 do ex[i] = nil end
    end
end
-- NOTE deliberately NOT called at module load anymore: the manifests only exist after
-- register_skin_defaults ran (first settings-apply cycle); update() refreshes the
-- menus right after resolving the scheme, which is always past that point.

-- Ordered so that each consecutive run of 3 groups forms one themed row of the settings
-- grid; .sections names those rows (counts must add up to the group count — keep both in
-- sync when adding a group: extend a section to 6 entries / two rows, or add a section).
-- "Telemetry" and "Voice" are two-page submenus purely to keep the grid at 3x4: their
-- inline page lists are plain {name, items}, walked by the generic build_sub_menu_view
-- and for_each_setting_item like the Alerts pages. (NB main chunk is at the 200-locals
-- limit — the page lists/section table are inline/attached, NOT new module locals.)
local SETTINGS_GROUPS = {}

-- Visit every settings item across all groups AND alert sub-pages. Used for the
-- defaults table and the working-copy snapshot so both cover the submenu items.
local color_setting_scratch = { def = -1 }   -- reused scratch row for synthesised keys (fn must only READ it; key AND def are (re)set per row)
local function for_each_setting_item(fn)
    for g = 1, #SETTINGS_GROUPS do
        local grp = SETTINGS_GROUPS[g]
        if grp.items then
            for i = 1, #grp.items do fn(grp.items[i]) end
        elseif grp.keys then
            -- lazy GROUP (the fourteen flat ones since 2026-08-17): its rows build on
            -- first open, so keys() hands the key/def pairs over without constructing
            -- them -- same shape and the same reused scratch row as the lazy PAGES
            -- below. Once a group has been opened its .items exist and the branch above
            -- takes over, which is why this one comes second.
            grp.keys(function(key, def)
                color_setting_scratch.key = key
                color_setting_scratch.def = def
                fn(color_setting_scratch)
            end)
        elseif grp.submenu then
            for p = 1, #grp.submenu do
                local page = grp.submenu[p]
                if page.scheme then
                    -- colour page: its rows are built lazily on open, so synthesise the keyed
                    -- rows straight from COLOR_ROLES (def -1 = unset) instead of walking .items —
                    -- keeps the item tables off the module-load / create() budget.
                    for r = 1, #COLOR_ROLES do
                        local role = COLOR_ROLES[r]
                        if role_in_scheme(role, page.scheme) then
                            color_setting_scratch.key = color_key(page.scheme, role)
                            color_setting_scratch.def = -1
                            fn(color_setting_scratch)
                        end
                    end
                elseif page.items == nil and page.keys then
                    -- lazy page (Shortcuts): rows build on first open — page.keys hands the
                    -- key/def pairs over without building them (same reused scratch row)
                    page.keys(function(key, def)
                        color_setting_scratch.key = key
                        color_setting_scratch.def = def
                        fn(color_setting_scratch)
                    end)
                else
                    local items = page.items
                    for i = 1, #items do fn(items[i]) end
                end
            end
        end
    end
end

-- defaults derived from the group tables (single source of truth now that the
-- EdgeTX option list no longer carries these values) — handed to the settings
-- layer so apply() can fill anything missing from the file
local SETTINGS_DEFAULTS = {}
-- EVERY skin's own rows and scheme overrides must be known to the defaults, not only
-- the active skin's: save()'s orphan-drop removes any key missing from the defaults,
-- which would silently wipe an INACTIVE skin's stored options/colour overrides. Since
-- skins are SELF-CONTAINED (manifest in the skin file), collecting the keys means
-- loading every skin once — far too heavy for module level (create()'s budget), so it
-- runs ONCE in a settings-apply cycle: register_skin_defaults is called right before
-- ultidash_settings.apply/save at each call site — always before the first apply that
-- overlays skin keys and long before any save's orphan-drop. SETTINGS_DEFAULTS is the
-- very table set_defaults holds, so the late mutation is visible immediately.
-- FORWARD-DECLARED: the body needs skin_load (defined with the skin system below).
local skin_defaults_done = false
local register_skin_defaults
ultidash_settings.set_defaults(SETTINGS_DEFAULTS)

-- Stage 2a0: the whole settings item catalogue, in one place and one budget.
-- Self-clearing -- it runs exactly once per session. Body kept verbatim from the
-- old module-level block (helpers and ALERTS_SPEC become builder-locals; the row
-- closures keep them alive).
SETTINGS_GROUPS._build = function()
    -- ultidashFunctions' own deferred data rides this stage (its reference tables --
    -- flight-mode info, arming-disable names, the voice maps -- moved off ITS module
    -- level for the same reason everything here did; self-clearing on its side)
    if ultidash_functions.deferred_init ~= nil then ultidash_functions.deferred_init() end
    -- Is the RADIO's theme dark? A constant of the radio, so it is answered HERE, in the
    -- one-off stage that already has a cycle of its own, rather than lazily inside
    -- toolbox_palette -- which would put its ~35 instructions into whichever ordinary
    -- refresh happened to be the first to build a tool palette. That was visible: on the
    -- 480x272 layout run it pushed one refresh cycle across the harness's 12k INFO line.
    -- toolbox_palette keeps its nil-guard, so nothing depends on this stage having run.
    pal_memo.theme_dark = theme_luma(COLOR_THEME_SECONDARY3) < DARK_LUMA_THRESHOLD
    -- The shared DATA TABLES first: palettes, schemes, colour roles, font constants and
    -- the sensor catalogue -- ~2.7k instructions of constructors that used to run at
    -- module level, inside create()'s budget. Filled IN PLACE (temp constructor + copy),
    -- because their references are captured elsewhere (the menu env takes SENSOR_INFO,
    -- the skin env takes SCHEMES as standard_schemes) and a reassignment would strand
    -- those captures on the empty shell. Order preserved: SCHEMES rows reference the
    -- palettes, the two derivation loops run after their tables.
    do local __t = {
        COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2,
        COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS, COLOR_THEME_WARNING, COLOR_THEME_DISABLED,
    }
    for k, v in pairs(__t) do THEME_PALETTE[k] = v end end
    do local __t = {
        lcd.RGB(0x00, 0x00, 0x00), lcd.RGB(0xF8, 0xFC, 0xF8), lcd.RGB(0x00, 0x00, 0x00), lcd.RGB(0x98, 0xB4, 0xE8),
        lcd.RGB(0xD8, 0xE0, 0xE8), lcd.RGB(0xC0, 0x30, 0x38), lcd.RGB(0xE8, 0x30, 0x30), lcd.RGB(0xF8, 0x3C, 0x00),
    }
    for k, v in pairs(__t) do CLEAN_PALETTE[k] = v end end
    do local __t = {
        lcd.RGB(0xFF, 0xFF, 0xFF), lcd.RGB(0x08, 0x0A, 0x0C), lcd.RGB(0xF0, 0xF4, 0xF8), lcd.RGB(0x39, 0xFF, 0x14),
        lcd.RGB(0x08, 0x0A, 0x0C), lcd.RGB(0x00, 0xE5, 0xFF), lcd.RGB(0xFF, 0x1A, 0x40), lcd.RGB(0xFF, 0xC4, 0x00),
    }
    for k, v in pairs(__t) do DARK_PALETTE[k] = v end end
    do local __t = {
        { id = "ulti", name = "UltiDash", tag = "U", icon = "sun", pal = CLEAN_PALETTE,
          -- Toolbox palette, UltiDash clean (light): mono black/grey, values in the accent
          toolbox = { bg = lcd.RGB(248,250,248), accent = lcd.RGB(24,24,24), hint = lcd.RGB(216,96,0), line = lcd.RGB(180,184,190),
                      text = lcd.RGB(24,24,24), textDim = lcd.RGB(130,130,130),
                      valText = lcd.RGB(48,90,144), valHi = lcd.RGB(192,48,56), bannerBg = lcd.RGB(192,48,40), bannerFg = lcd.RGB(255,255,255),
                      btnBg = lcd.RGB(208,212,218), btnPressed = lcd.RGB(184,190,200), btnDim = lcd.RGB(226,228,231), btnFg = lcd.RGB(24,24,24) } },
        { id = "dark", name = "UltiDash dark", tag = "D", icon = "moon", dark = true, pal = DARK_PALETTE,
          -- Toolbox palette, UltiDash dark: mono white/grey, values in the neon accent;
          -- the Log Viewer picks its dark neon curve colours off the `dark` flag
          toolbox = { bg = lcd.RGB(0,0,0), accent = lcd.RGB(240,240,240), hint = lcd.RGB(255,122,26), line = lcd.RGB(56,60,64),
                      text = lcd.RGB(240,240,240), textDim = lcd.RGB(150,156,162),
                      valText = lcd.RGB(0,229,255), valHi = lcd.RGB(255,176,0), bannerBg = lcd.RGB(255,68,56), bannerFg = lcd.RGB(0,0,0),
                      btnBg = lcd.RGB(48,52,58), btnPressed = lcd.RGB(74,80,88), btnDim = lcd.RGB(34,36,40), btnFg = lcd.RGB(235,235,235),
                      dark = true } },
        { id = "theme", name = "EdgeTX theme", tag = "E", icon = "contrast", follows_theme = true, pal = THEME_PALETTE },
    }
    for k, v in pairs(__t) do SCHEMES[k] = v end end
    for i = 1, #SCHEMES do SCHEMES[SCHEMES[i].id] = SCHEMES[i] end
    do local __t = {
        { grp = "Palette",       k = "P1", slot = 1, lbl = "Text / foreground" },
        { grp = "Palette",       k = "P2", slot = 2, lbl = "Base background" },
        { grp = "Palette",       k = "S1", slot = 3, lbl = "Strong lines / text" },
        { grp = "Palette",       k = "S2", slot = 4, lbl = "Accent fill" },
        { grp = "Palette",       k = "S3", slot = 5, lbl = "Panel surface" },
        { grp = "Palette",       k = "FC", slot = 6, lbl = "Accent / headings" },
        { grp = "Palette",       k = "WN", slot = 7, lbl = "Warning accent" },
        { grp = "Palette",       k = "DS", slot = 8, lbl = "Dim / disabled accent" },
        { grp = "Traffic-light", k = "SG", sem = "green", lbl = "Good (green)",     theme = true },
        { grp = "Traffic-light", k = "SY", sem = "yell",  lbl = "Warning (yellow)", theme = true },
        { grp = "Traffic-light", k = "SR", sem = "red",   lbl = "Critical (red)",   theme = true },
        { grp = "Traffic-light", k = "SN", sem = "neut",  lbl = "Neutral (quiet)",  theme = true },
        -- statusbar arm-state text. UNSET they follow what the text always followed (armed =
        -- the EFFECTIVE traffic-light green incl. its override, disarmed = the resolved
        -- WARNING slot 7) — see set_palette; the built-ins here only feed the picker swatch.
        { grp = "Status text",   k = "AR", stat = "armed",    lbl = "Armed",    theme = true },
        { grp = "Status text",   k = "DA", stat = "disarmed", lbl = "Disarmed", theme = true },
        { grp = "Chrome",        k = "BG", chrome = "bg",    lbl = "Panel background (fill)" },
        { grp = "Chrome",        k = "TR", chrome = "track", lbl = "Bar track / empty" },
        { grp = "Chrome",        k = "TK", chrome = "tick",  lbl = "Tick marks" },
        { grp = "Chrome",        k = "DM", chrome = "dim",   lbl = "Dim secondary text" },
        -- battery fills: the main battery bar (ePowerbar levels) + the top-bar TX battery icon.
        -- These were historically FIXED (never theme-driven), so their built-ins are the same for
        -- every scheme and they are offered in EdgeTX-theme mode too (theme = true).
        { grp = "Battery",       k = "BO", batt = "ok",    lbl = "Battery bar OK",           theme = true },
        { grp = "Battery",       k = "BW", batt = "warn",  lbl = "Battery bar not full",     theme = true },
        { grp = "Battery",       k = "BL", batt = "low",   lbl = "Battery bar low",          theme = true },
        { grp = "Battery",       k = "BC", batt = "crit",  lbl = "Battery bar critical",     theme = true },
        { grp = "Battery",       k = "BK", batt = "check", lbl = "Battery bar cell check",   theme = true },
        { grp = "Battery",       k = "XO", batt = "vtx_ok",  lbl = "TX battery OK",          theme = true },
        { grp = "Battery",       k = "XL", batt = "vtx_low", lbl = "TX battery low",         theme = true },
    }
    for k, v in pairs(__t) do COLOR_ROLES[k] = v end end
    do local __t = {
        TINSIZE = TINSIZE,
        SMLSIZE = SMLSIZE,
        STDSIZE = STDSIZE,
        MIDSIZE = MIDSIZE,
        DBLSIZE = DBLSIZE,
        XXLSIZE = XXLSIZE
    }
    for k, v in pairs(__t) do FONT_CONSTANTS[k] = v end end
    do local __t = {
        -- battery / cells
        Vbat     = { lbl = "Battery", cap = "Batt",      dec = 2, unit = "V",   appId = 0x1011 },
        Curr     = { lbl = "Current", cap = "Current",      dec = 1, unit = "A",   appId = 0x1012 },
        Capa     = { lbl = "Energy Used", cap = "Used",  dec = 0, unit = "mAh", appId = 0x1013 },
        ["Bat%"] = { lbl = "Fuel", cap = "Fuel",         dec = 0, unit = "%",   appId = 0x1014 },
        ["Cel#"] = { lbl = "Cells", cap = "Cell#",        dec = 0, unit = "",    appId = 0x1020 },
        Vcel     = { lbl = "Cell",         dec = 2, unit = "V",   appId = 0x1021 },
        Cels     = { lbl = "Cell V", cap = "Cells",       dec = 2, unit = "V" },   -- composite (no single appId)
        Thr      = { lbl = "Throttle",     dec = 0, unit = "%",   appId = 0x1035 },
        -- ESC #1
        EscV     = { lbl = "ESC Voltage", cap = "ESC V",  dec = 2, unit = "V",   appId = 0x1041 },
        EscI     = { lbl = "ESC Current", cap = "ESC A",  dec = 1, unit = "A",   appId = 0x1042 },
        EscC     = { lbl = "ESC Used", cap = "ESC Used",     dec = 0, unit = "mAh", appId = 0x1043 },
        EscR     = { lbl = "ESC RPM", cap = "ESC RPM",      dec = 0, unit = "rpm", appId = 0x1044 },
        EscP     = { lbl = "ESC PWM", cap = "ESC PWM",      dec = 1, unit = "%",   appId = 0x1045 },
        ["Esc%"] = { lbl = "ESC Load", cap = "ESC Load",     dec = 1, unit = "%",   appId = 0x1046 },
        EscT     = { lbl = "ESC Temp", cap = "ESC T",     dec = 0, unit = "°C",  appId = 0x1047 },
        BecT     = { lbl = "BEC T (ESC)", cap = "BEC T",  dec = 0, unit = "°C",  appId = 0x1048 },
        BecV     = { lbl = "BEC V (ESC)", cap = "BEC V",  dec = 2, unit = "V",   appId = 0x1049 },
        BecI     = { lbl = "BEC I (ESC)", cap = "BEC A",  dec = 1, unit = "A",   appId = 0x104A },
        -- ESC #2
        Es2V     = { lbl = "ESC2 Voltage", cap = "ESC2 V", dec = 2, unit = "V",   appId = 0x1051 },
        Es2I     = { lbl = "ESC2 Current", cap = "ESC2 A", dec = 1, unit = "A",   appId = 0x1052 },
        Es2C     = { lbl = "ESC2 Used", cap = "ESC2 Used",    dec = 0, unit = "mAh", appId = 0x1053 },
        Es2R     = { lbl = "ESC2 RPM", cap = "ESC2 RPM",     dec = 0, unit = "rpm", appId = 0x1054 },
        Es2T     = { lbl = "ESC2 Temp", cap = "ESC2 T",    dec = 0, unit = "°C",  appId = 0x1057 },
        -- rails / currents
        Vesc     = { lbl = "ESC Rail V", cap = "ESC V",   dec = 2, unit = "V",   appId = 0x1080 },
        Vbec     = { lbl = "BEC Voltage", cap = "BEC",  dec = 2, unit = "V",   appId = 0x1081 },
        Vbus     = { lbl = "Bus Voltage", cap = "Bus V",  dec = 2, unit = "V",   appId = 0x1082 },
        Vmcu     = { lbl = "MCU Voltage", cap = "MCU V",  dec = 2, unit = "V",   appId = 0x1083 },
        Iesc     = { lbl = "ESC Rail I", cap = "ESC A",   dec = 1, unit = "A",   appId = 0x1090 },
        Ibec     = { lbl = "BEC Current", cap = "BEC A",  dec = 1, unit = "A",   appId = 0x1091 },
        Ibus     = { lbl = "Bus Current", cap = "Bus A",  dec = 1, unit = "A",   appId = 0x1092 },
        Imcu     = { lbl = "MCU Current", cap = "MCU A",  dec = 1, unit = "A",   appId = 0x1093 },
        -- temperatures
        Tesc     = { lbl = "ESC Temp", cap = "ESC T",     dec = 0, unit = "°C",  appId = 0x10A0 },
        Tbec     = { lbl = "BEC Temp", cap = "BEC T",     dec = 0, unit = "°C",  appId = 0x10A1 },
        Tmcu     = { lbl = "MCU Temp", cap = "MCU T",     dec = 0, unit = "°C",  appId = 0x10A3 },
        Tair     = { lbl = "Air Temp", cap = "Air T",     dec = 0, unit = "°C" },   -- name-only (not in the
        Tmtr     = { lbl = "Motor Temp", cap = "Mtr T",   dec = 0, unit = "°C" },   -- RF2 sensor table; harmless
        Tbat     = { lbl = "Batt Temp", cap = "Batt T",    dec = 0, unit = "°C" },   -- if a model reports them
        -- rotor / speeds / MCU loads
        Hspd     = { lbl = "Headspeed",    dec = 0, unit = "rpm", appId = 0x10C0 },
        Tspd     = { lbl = "Tailspeed", cap = "Tail",    dec = 0, unit = "rpm", appId = 0x10C1 },
        ["CPU%"] = { lbl = "CPU Load", cap = "CPU",     dec = 0, unit = "%",   appId = 0x1141 },
        ["SYS%"] = { lbl = "SYS Load", cap = "SYS",     dec = 0, unit = "%",   appId = 0x1142 },
        ["RT%"]  = { lbl = "RT Load", cap = "RT",      dec = 0, unit = "%",   appId = 0x1143 },
        -- altitude / attitude / GPS
        Alt      = { lbl = "Altitude",     dec = 1, unit = "m",   appId = 0x10B2 },
        Var      = { lbl = "Vario",        dec = 1, unit = "m/s", appId = 0x10B3 },
        Hdg      = { lbl = "Heading",      dec = 1, unit = "°",   appId = 0x10B1 },
        Sats     = { lbl = "GPS Sats",     dec = 0, unit = "",    appId = 0x1121 },
        GSpd     = { lbl = "GPS Speed", cap = "GPS Spd",    dec = 1, unit = "m/s", appId = 0x1128 },
        GAlt     = { lbl = "GPS Alt", cap = "GPS Alt",      dec = 1, unit = "m",   appId = 0x1126 },
        GDis     = { lbl = "GPS Dist", cap = "Dist",     dec = 1, unit = "m",   appId = 0x1129 },
        CPtc     = { lbl = "Ctrl Pitch", cap = "C Ptch",   dec = 1, unit = "°",   appId = 0x1031 },
        CRol     = { lbl = "Ctrl Roll", cap = "C Roll",    dec = 1, unit = "°",   appId = 0x1032 },
        CYaw     = { lbl = "Ctrl Yaw", cap = "C Yaw",     dec = 1, unit = "°",   appId = 0x1033 },
        CCol     = { lbl = "Ctrl Coll", cap = "C Coll",    dec = 1, unit = "°",   appId = 0x1034 },
        Ptch     = { lbl = "Pitch",        dec = 1, unit = "°",   appId = 0x1101 },
        Roll     = { lbl = "Roll",         dec = 1, unit = "°",   appId = 0x1102 },
        Yaw      = { lbl = "Yaw",          dec = 1, unit = "°",   appId = 0x1103 },
        -- ELRS link quality (name-based; no RF custom appId)
        RQly     = { lbl = "Link Qual",    dec = 0, unit = "%" },
        TQly     = { lbl = "Uplink Qual",  dec = 0, unit = "%" },
        RSNR     = { lbl = "SNR",          dec = 0, unit = "dB" },
        TPWR     = { lbl = "TX Power",     dec = 0, unit = "mW" },
        -- virtual (computed) sensor: UltiDash's Curr/limit ESC utilisation (distinct from the
        -- telemetry-reported Esc% "ESC Load")
        ["~escl"] = { lbl = "ESC Util",    dec = 0, unit = "%" },
    }
    for k, v in pairs(__t) do SENSOR_INFO[k] = v end end
    for name, info in pairs(SENSOR_INFO) do
        if info.appId then NAME_BY_APPID[info.appId] = name end
    end
    do local __t = {
        Vbat = "vbat", Vcel = "vcel", ["Cel#"] = "cel_count",
        Curr = "curr", Capa = "capa", ["Bat%"] = "capa_percent",
        -- Curr follows the CurrSrc setting: the Current row / value.curr shows the
        -- CONFIGURED source (Curr/EscI/Iesc), not necessarily the raw Curr sensor.
        Tesc = "esc_temp", Vbec = "vbec", Hspd = "headspeed",
        ["~escl"] = "esc_load_pct",   -- virtual: computed by update_esc_load_warning
    }
    for k, v in pairs(__t) do SENSOR_VALUE_FIELD[k] = v end end

    -- D3: the spoken report's DATA half, handed to ultidashFunctions as a closure --
    -- SENSOR_INFO / SENSOR_VALUE_FIELD are locals here, and the engine owns only the
    -- audio half. Returns value, UNIT const, decimals (capped at 2 -- PREC2 is the
    -- deepest playNumber speaks), and the name-wav key (lowercased, % -> pct, # -> n,
    -- everything non-alphanumeric dropped: Vbat -> vbat, Bat% -> batpct).
    do
        local TSAY_UNITS = {
            ["V"] = UNIT_VOLTS, ["A"] = UNIT_AMPS, ["mAh"] = UNIT_MAH,
            ["%"] = UNIT_PERCENT, ["rpm"] = UNIT_RPMS, ["°C"] = UNIT_CELSIUS,
            ["m"] = UNIT_METERS, ["m/s"] = UNIT_METERS_PER_SECOND,
            ["°"] = UNIT_DEGREE, ["dB"] = UNIT_DB, ["mW"] = UNIT_MILLIWATTS,
        }
        ultidash_functions.telemsay_init(function(wgt, name)
            local info = SENSOR_INFO[name]
            local field = SENSOR_VALUE_FIELD[name]
            local v
            if field then v = wgt.values[field] end
            if v == nil then
                -- a slot also shown on the dashboard sits in the 5 Hz cache
                -- (index-verified read); anything else is read at speak time --
                -- one read per spoken item, not per pass
                local us = wgt.values.user_sensors
                v = us and us[name]
            end
            if v == nil then
                local ok, r = pcall(ultidash_functions.read_src, wgt, name)
                if ok then v = r end
            end
            local dec = info and info.dec or 0
            if dec > 2 then dec = 2 end
            local wav = string.gsub(string.gsub(string.gsub(string.lower(name),
                "%%", "pct"), "#", "n"), "%W", "")
            return v, (info and TSAY_UNITS[info.unit]) or 0, dec, wav
        end)
    end

-- The fourteen flat settings groups, LAZY since 2026-08-17 (finding L-3 of the CPU
-- review). They used to be constructed right here: ~120 item rows across the fourteen
-- tables, most of them carrying an `fmt` and/or a `dim` closure -- spent at a point
-- that only needs KEY/DEF PAIRS (SETTINGS_DEFAULTS, the save's orphan-drop, the
-- one-time cfg snapshot). Labels, value lists and closures are first needed when a page
-- BUILDS, and a page the user never opens never needed them at all.
-- So each group becomes { name, build = MK.<x>, keys = KEYS.<x> } -- the shape
-- shortcut.pages, ALERT_PAGES and the colour pages already use. open_group (the menu
-- module) materialises grp.items on first open and caches it there.
-- MEASURED (the budget harness, this tree): the catalogue stage (refresh #1) falls
-- 10,463 -> 8,621, and what moved out is 1,866 instructions of row construction spread
-- over sixteen lazy nodes, worst single page 267 -- against 9-14k of headroom in the
-- call a page open actually gets. The lasting half is that the stage stops growing
-- row-for-row per release: a new settings row now costs its own page, not every boot.
-- (The review's ~5.7k estimate for this block was high; the number above is the run.)
-- TWO tables, not fourteen locals: the builders and the key stubs are parked on MK and
-- KEYS because the main chunk sits at the 200-local wall (197 measured) -- and _build
-- has the same wall of its own.
-- THE TRADEOFF, and it is the one that costs data if it slips: keys() and the builder
-- of a group must stay in sync. A key the builder writes and keys() omits is missing
-- from SETTINGS_DEFAULTS, and prepare_save's orphan sweep then DELETES it from the
-- user's cfg file -- a silently lost setting, not a visible error. That is why keys()
-- sits directly under its builder here, and why the budget harness materialises
-- every group and compares the two sets against SETTINGS_DEFAULTS on every run
-- ("catalogue: lazy groups"). Keep them adjacent when adding a row.
local MK, KEYS = {}, {}

MK.display = function() return {
    { kind = "section", lbl = "Layout & theme" },
    -- dashboard layout skin. Skins are DISCOVERED (skins/*.lua), so both lists are
    -- functions resolved at page-build time (after discovery); `ids` makes the menu
    -- STORE the skin's id string instead of a list index (stable across file changes).
    -- a rejected skin is marked "<name> (error)" -- the row is where the user looks, and
    -- the mark points at the file rather than at the widget. `ids` is UNCHANGED, so the
    -- pick still stores the plain id and a repaired skin needs no re-pick.
    { key = "Skin",          lbl = "Dashboard skin",        kind = "choice", def = "default",
                             vals = function() local v = {} for i = 1, #SKINS do
                                        v[i] = SKINS[i].failed and (SKINS[i].name .. " (error)") or SKINS[i].name
                                    end return v end,
                             ids  = function() local v = {} for i = 1, #SKINS do v[i] = SKINS[i].id end return v end },
    -- the colour-scheme choice lives in the "Skin" group since stage 3b (colour
    -- settings belong to the skin: per-skin key, per-skin default, per-skin list —
    -- the row is synthesised in refresh_skin_menus)
    { key = "BGFilled",      lbl = "Fill background",       kind = "bool", def = 1 },
    -- Unit suffixes beside the values (flight panel, Telemetry cards, and every skin
    -- slot fed by env.sensor_slot). OFF by default = the original formatting: the value
    -- gets the full column, so it keeps the BIGGEST font that fits. Switching them on
    -- costs font size — on a 480x320 (TX15) or 480x272 (TX16S MK2) screen that is the
    -- difference between readable at arm's length and not.
    -- The HOST's units key. Since 0.8.0 the dashboard's own units follow the ACTIVE
    -- SKIN's key (Skin ▸ "Units beside values"); this row keeps the four detail pages,
    -- which are host-owned and must not lose their setting when a skin claims its own.
    -- The default skin declares THIS key as its own, so under it the two rows are one
    -- switch — which is exactly what it was before the split.
    { key = "ShowUnits",     lbl = "Units on detail pages", kind = "bool", def = 0 },
    { key = "StatsViewMode", lbl = "Stats page",            kind = "choice", def = 3, vals = { "Never", "On disarmed", "On disconnected" } },
    { key = "VoltageDisplay",lbl = "Voltage shown as",      kind = "choice", def = 1, vals = { "Cell voltage", "Battery voltage" } },
    { kind = "section", lbl = "Behaviour" },
    { key = "ArmClose",      lbl = "Close detail pages on arm", kind = "bool", def = 0 },
    -- A page that comes up BY ITSELF on the arm edge -- the counterpart to the row above
    -- and to StatsViewMode, which is the only other automatic view switch and governs the
    -- DISARMED side. Only a detail overlay can be the target: a Toolbox tool is
    -- disarmed-only by construction. It opens once per arm and is closed like any other
    -- page (the X, RTN, or the switch that would have opened it) -- it does not come back
    -- until the next arm, deliberately.
    -- DIMMED while "Close detail pages on arm" is on, because that option re-closes any
    -- detail page on EVERY armed pass, not just on the edge: the two cannot both hold, and
    -- the auto-open would be the one silently losing.
    { key = "ArmOpen",       lbl = "Open page on arming",   kind = "choice", def = 1,
                             vals = shortcut.detail_labels(),
                             dim = function(w) return w.ArmClose == 1 end },
    { key = "TapDetails",    lbl = "Tap zones for detail pages", kind = "bool", def = 1 },
    -- The radio's backlight timeout (Radio Setup > "Backlight off after", g_eeGeneral
    -- .lightAutoOff, 10 s at the shipped default of 2) costs the pilot his next tap: with
    -- the backlight off EdgeTX delivers the press with NO coordinates and waits for the
    -- release (gui/colorlcd/LvglWrapper.cpp, touchDriverRead), so the tap is spent waking
    -- the screen and never reaches a widget. On the bench between flights that is exactly
    -- the tap that was meant to open a detail page. ON keeps the timer alive while
    -- UltiDash owns the WHOLE display, and only then -- in a layout zone the radio's own
    -- behaviour is unchanged, and so is every screen that is not this widget.
    { key = "KeepLit",       lbl = "Keep backlight on (full screen)", kind = "bool", def = 1 },
    -- switch shortcuts (detail pages + Toolbox tools) moved to their own group, see
    -- SETTINGS_SHORTCUTS / the "Shortcuts" group. The top-bar / left-panel rows moved
    -- to the DEFAULT SKIN's own settings (SKINS.default.items below, stage 3c).
    -- The former "Bottom bar" section is gone: `ShowTPWR` only toggles content of the
    -- host STATUS BAR component, and whether that bar exists at all is a per-skin
    -- decision (MinStatusBar / CkptStatusBar / GridStatusBar) -> the row moved into
    -- every skin's own items. `TxPwrMax` is not a bar option but the ELRS dynamic-power
    -- ceiling of this TX/region (also the ELRS detail page's 100 % reference) -> it
    -- moved to Thresholds > Link & signal. Both KEYS are unchanged (no cfg migration).
} end
KEYS.display = function(fn)
    fn("Skin", "default"); fn("BGFilled", 1); fn("ShowUnits", 0); fn("StatsViewMode", 3)
    fn("VoltageDisplay", 1); fn("ArmClose", 0); fn("ArmOpen", 1); fn("TapDetails", 1)
    fn("KeepLit", 1)
end

-- (The default skin's own settings rows — top bar & left panel — live in its skin
-- file, skins/default.lua M.items, like every skin's. Keys unchanged, no migration.)

local function fmt_pctval(v) return v .. " %" end

MK.battery = function() return {
    { kind = "section", lbl = "Fuel callouts" },
    { key = "Reserve",      lbl = "Reserve (%)",            kind = "num", def = 20,  min = 0,   max = 40,  step = 1, big = 5 },
    -- Fuel-callout density (value-driven descending %): quiet up high, denser near the end.
    -- Defaults reproduce the historical fixed cadence (from full, 10 % steps, 1 % below 10 %).
    { key = "FuelStart",    lbl = "Fuel: announce below (%)", kind = "num", def = 100, min = 5, max = 100, step = 5, big = 10,
                            fmt = function(v) return (v >= 100) and "from full" or (v .. " %") end },
    { key = "FuelStep",     lbl = "Fuel: coarse step (%)",  kind = "num", def = 10, min = 1, max = 50, step = 1, big = 5, fmt = fmt_pctval },
    { key = "FuelDense",    lbl = "Fuel: dense below (%)",   kind = "num", def = 15, min = 0, max = 100, step = 5, big = 10, fmt = fmt_pctval },
    { key = "FuelStepFine", lbl = "Fuel: fine step (%)",    kind = "num", def = 5,  min = 1, max = 50, step = 1, big = 5, fmt = fmt_pctval },
    -- What the descending %-step callouts SPEAK (the %-interval triggering is unchanged):
    -- the remaining percent (default), the battery/pack voltage, the per-cell voltage, or the
    -- percent followed by one of the two. Independent of "Announce voltage as" (VoltVoice),
    -- which scopes only the voltage alert / startup cell check.
    { key = "FuelSay",      lbl = "Fuel callout says",      kind = "choice", def = 1,
                            vals = { "Percent", "Battery V", "Cell V", "% + Battery V", "% + Cell V" } },
    -- Extra fixed per-cell voltage callouts, ALONGSIDE the %-steps above: speak the voltage
    -- once (per VoltVoice) when the cell voltage settles at/below each threshold. 0 = that
    -- step off. VSayHold = how long the voltage must stay in-band before firing (filters a
    -- brief load sag). Independent of the low/critical Voltage alert (Alerts group).
    { key = "VSay1",    lbl = "Volt callout 1 (V/cell)", kind = "num", def = 0, min = 0, max = 430, step = 1, big = 5,
                        fmt = function(v) return (v <= 0) and "off" or fmt_centivolt(v) end },
    { key = "VSay2",    lbl = "Volt callout 2 (V/cell)", kind = "num", def = 0, min = 0, max = 430, step = 1, big = 5,
                        fmt = function(v) return (v <= 0) and "off" or fmt_centivolt(v) end },
    { key = "VSayHold", lbl = "Volt callout delay (s)",  kind = "num", def = 3, min = 0, max = 30, step = 1, big = 5,
                        fmt = function(v) return (v <= 0) and "immediate" or (v .. " s") end,
                        dim = function(w) return (w.VSay1 or 0) <= 0 and (w.VSay2 or 0) <= 0 end },
    { kind = "info", lbl = "Volt callouts: 0 = off. Suggested 3.80 / 3.75 V/cell. Spoken once each while armed, alongside the % steps." },
    { kind = "section", lbl = "Cell thresholds" },
    { key = "CellSource",   lbl = "Cell thresholds from",   kind = "choice", def = 1, vals = { "FC config", "Manual" } },
    { key = "CellFull",     lbl = "Full cell (manual)",     kind = "num", def = 412, min = 300, max = 480, step = 1, big = 10, fmt = fmt_centivolt, dim = function(w) return w.CellSource ~= 2 end },
    { key = "CellLow",      lbl = "Low cell (manual)",      kind = "num", def = 345, min = 300, max = 440, step = 1, big = 10, fmt = fmt_centivolt, dim = function(w) return w.CellSource ~= 2 end },
    { key = "CellCritical", lbl = "Critical cell (manual)", kind = "num", def = 330, min = 300, max = 440, step = 1, big = 10, fmt = fmt_centivolt, dim = function(w) return w.CellSource ~= 2 end },
    { kind = "section", lbl = "Cell check & voice" },
    { key = "StartupDelay", lbl = "Cell-check delay (s)",   kind = "num", def = 4,   min = 1,   max = 20,  step = 1, big = 5 },
    -- Voice announcement source for the voltage alert + startup cell check: total battery
    -- voltage (as before) or per-cell voltage. Independent of "Voltage shown as" (display).
    { key = "VoltVoice",    lbl = "Announce voltage as",    kind = "choice", def = 1, vals = { "Battery", "Cell" } },
    { kind = "section", lbl = "Data sources" },
    { key = "CurrSrc",      lbl = "Current sensor",         kind = "choice", def = 1, vals = { "Curr", "EscI", "Iesc" } },
    { kind = "info", lbl = "Feeds the Current row, ESC load and current min/max. Curr = FC battery current; EscI/Iesc = ESC-reported current." },
} end
KEYS.battery = function(fn)
    fn("Reserve", 20); fn("FuelStart", 100); fn("FuelStep", 10); fn("FuelDense", 15)
    fn("FuelStepFine", 5); fn("FuelSay", 1); fn("VSay1", 0); fn("VSay2", 0); fn("VSayHold", 3)
    fn("CellSource", 1); fn("CellFull", 412); fn("CellLow", 345); fn("CellCritical", 330)
    fn("StartupDelay", 4); fn("VoltVoice", 1); fn("CurrSrc", 1)
end

local function fmt_pctdrop(v) return v .. " %" end
local function fmt_temp(v) return (v == 0) and "Off" or (v .. " C") end

-- Warning thresholds, grouped by subject via non-interactive section headers
-- (kind="info" rows). ESC-load thresholds live in their own "ESC load" group;
-- the TX power limit (TxPwrMax) lives here under "Link & signal" — it is a per-TX /
-- per-region ELRS setting, not a bar option (see the comment on the row).
MK.thresholds = function() return {
    { kind = "section", lbl = "Link & signal" },
    { key = "RQlyWarn",   lbl = "Link warn (%)",          kind = "num", def = 80, min = 0,  max = 100,  step = 1,  big = 5 },
    { key = "RQlyCrit",   lbl = "Link critical (%)",      kind = "num", def = 50, min = 0,  max = 100,  step = 1,  big = 5 },
    { key = "RssWarn",    lbl = "RSSI warn (% headroom)", kind = "num", def = 15, min = 0,  max = 100,  step = 1,  big = 5 },
    { key = "RssCrit",    lbl = "RSSI critical (%)",      kind = "num", def = 8,  min = 0,  max = 100,  step = 1,  big = 5 },
    { key = "RssHold",    lbl = "RSSI hold time (s)",     kind = "num", def = 2,  min = 1,  max = 10,   step = 1,  big = 2 },
    { key = "SkpLimit",   lbl = "Skipped-packet limit",   kind = "num", def = 50, min = 10, max = 2000, step = 10, big = 100 },
    -- ELRS dynamic-power ceiling of THIS transmitter/region (25/100/250/500/1000 mW) —
    -- a setup limit like the ones above, NOT a display option: it is the 100 % reference
    -- of the TPWR bar on the ELRS detail page (published via Shared.tpwr_max).
    -- 0 = unknown -> that bar stays empty and shows a hint instead, the raw mW value
    -- is still printed.
    { key = "TxPwrMax",   lbl = "TX power limit (mW)",    kind = "num", def = 0, min = 0, max = 1000, step = 10, big = 50,
                          fmt = function(v) return v == 0 and "not set" or (v .. " mW") end },
    { kind = "section", lbl = "Power & BEC" },
    -- the main-power-loss threshold defaults to cell count x per-cell volts
    -- (3S x 3.0 V = 9.0 V = the old fixed default -> 3S behaviour unchanged, 2S/6S/12S
    -- work unconfigured). "Fixed voltage" keeps the manual override; with no cell count
    -- seen yet the fixed value is the fallback either way (see pwr_warn_threshold).
    { key = "PwrSrc",     lbl = "Power warn from",        kind = "choice", def = 1, vals = { "Cell count (auto)", "Fixed voltage" } },
    { key = "PwrCellV",   lbl = "Power warn (V/cell)",    kind = "num", def = 30, min = 20, max = 40,   step = 1,  big = 5,  fmt = fmt_decivolt, dim = function(w) return (w.PwrSrc or 1) ~= 1 end },
    { key = "PwrWarnV",   lbl = "Power warn voltage",     kind = "num", def = 90, min = 30, max = 500,  step = 5,  big = 20, fmt = fmt_decivolt, dim = function(w) return (w.PwrSrc or 1) == 1 end },
    { key = "BecWarn",    lbl = "BEC warn (% drop)",      kind = "num", def = 8,  min = 1,  max = 50,   step = 1,  big = 5, fmt = fmt_pctdrop },
    { key = "BecCrit",    lbl = "BEC critical (% drop)",  kind = "num", def = 15, min = 1,  max = 60,   step = 1,  big = 5, fmt = fmt_pctdrop },
    { kind = "section", lbl = "Temperature" },
    { key = "TescWarn",   lbl = "ESC warn (C)",           kind = "num", def = 90,  min = 0, max = 150, step = 5, big = 10, fmt = fmt_temp },
    { key = "TescCrit",   lbl = "ESC critical (C)",       kind = "num", def = 110, min = 0, max = 150, step = 5, big = 10, fmt = fmt_temp },
    { key = "TmcuWarn",   lbl = "MCU warn (C)",           kind = "num", def = 75,  min = 0, max = 150, step = 5, big = 10, fmt = fmt_temp },
    { key = "TmcuCrit",   lbl = "MCU critical (C)",       kind = "num", def = 90,  min = 0, max = 150, step = 5, big = 10, fmt = fmt_temp },
} end
KEYS.thresholds = function(fn)
    fn("RQlyWarn", 80); fn("RQlyCrit", 50); fn("RssWarn", 15); fn("RssCrit", 8)
    fn("RssHold", 2); fn("SkpLimit", 50); fn("TxPwrMax", 0); fn("PwrSrc", 1); fn("PwrCellV", 30)
    fn("PwrWarnV", 90); fn("BecWarn", 8); fn("BecCrit", 15); fn("TescWarn", 90)
    fn("TescCrit", 110); fn("TmcuWarn", 75); fn("TmcuCrit", 90)
end

-- ESC continuous-current LOAD monitor (own settings group). The FC writes the ESC's
-- continuous-current limit (amps) into the configured GVAR after connect;
-- load% = Curr / limit * 100. One MASTER switch runs the whole feature:
--   * EscMon ("ESC load monitoring") + a configured EscGvar. Off (or no GVAR) => the
--     whole feature is off: no bar, no "ESC Load" tile value ("not set"), no alarm.
--   * When on, the load bar (Current row, or vertical in the battery gauge — EscBar)
--     + the "ESC Load" virtual sensor show; Warn/Critical % colour both. The ALARM is an additional opt-in — the "ESC load"
--     alert's Active (key EscLoad) under Alerts > ESC load — and is itself gated by
--     EscMon (monitoring off = alarm silent). EscHold gates how long the load must
--     stay high before it fires (alarm is armed-only).
MK.esc = function() return {
    { key = "EscMon",   lbl = "ESC load monitoring",   kind = "bool", def = 0 },
    { key = "EscGvar",  lbl = "ESC limit: GVAR (A)",   kind = "num", def = 0, min = 0, max = 15, step = 1, big = 1,
                        fmt = function(v) return (v == 0) and "Off" or ("GV" .. v) end,
                        dim = function(w) return w.EscMon ~= 1 end },
    { key = "EscWarn",  lbl = "Warn (%)",              kind = "num", def = 80,  min = 10, max = 200, step = 5, big = 10, fmt = fmt_pctval, dim = function(w) return w.EscMon ~= 1 end },
    { key = "EscCrit",  lbl = "Critical (%)",          kind = "num", def = 100, min = 10, max = 200, step = 5, big = 10, fmt = fmt_pctval, dim = function(w) return w.EscMon ~= 1 end },
    { key = "EscHold",  lbl = "Alarm hold time (s)",   kind = "num", def = 5,   min = 1,  max = 30,  step = 1, big = 5, fmt = function(v) return v .. " s" end, dim = function(w) return w.EscMon ~= 1 end },
    -- where the live load bar lives on the dashboard: the classic thin bar under the
    -- current row, or vertically in the battery gauge's free right gap (the battery
    -- DETAIL page always shows the vertical bar while monitoring is on)
    { key = "EscBar",   lbl = "Load bar",              kind = "choice", def = 1, vals = { "Current row", "Battery gauge" },
                        dim = function(w) return w.EscMon ~= 1 end },
    { kind = "info", lbl = "Monitoring off = feature off. GVAR holds the ESC continuous-current limit (A), written by the FC. Alarm on/off is under Alerts > ESC load." },
} end
KEYS.esc = function(fn)
    fn("EscMon", 0); fn("EscGvar", 0); fn("EscWarn", 80); fn("EscCrit", 100); fn("EscHold", 5)
    fn("EscBar", 1)
end

local function fmt_pct(v) return tostring(v) .. " %" end

-- Loudness / volume — its own settings group (see the "Volume" entry in
-- SETTINGS_GROUPS). Two independent loudness worlds:
--   * the per-callout WIDGET volume (Volume 1..5, passed to playFile/playNumber), and
--   * the GVAR MASTER-volume bridge (VolGvar drives a model "Volume" special function).
-- Normal vs. escalation % (VolFlight / VolEscal) only apply in the GVAR world.
MK.volume = function()
    local t = {
    { key = "Volume",     lbl = "Callout volume",            kind = "num", def = 0, min = 0, max = 5, step = 1, big = 1,
                          fmt = function(v)
                              if v == 0 then return "System" end
                              if v == 1 then return "1 (min)" end
                              if v == 5 then return "5 (max)" end
                              return tostring(v) .. " / 5"
                          end },
    { key = "VolWhen",    lbl = "Widget volume applies",     kind = "choice", def = 1, vals = { "Always", "Only connected" },
                          dim = function(w) return (w.Volume or 0) == 0 end },
    { key = "VolGvar",    lbl = "Master volume via GVAR",     kind = "num", def = 0, min = 0, max = 15, step = 1, big = 1,
                          fmt = function(v) return (v == 0) and "Off" or ("GV" .. v) end },
    { kind = "info", lbl = "GVAR is optional. Without it, callouts use the radio volume; the normal/escalation % below apply only when a GVAR is set." },
    { key = "VolFlight",  lbl = "Normal volume (%)",          kind = "slider", def = 80,  min = 0, max = 100, step = 5, big = 10, fmt = fmt_pct,
                          dim = function(w) return (w.VolGvar or 0) == 0 end },
    { key = "VolEscal",   lbl = "Escalation volume (%)",      kind = "slider", def = 100, min = 0, max = 100, step = 5, big = 10, fmt = fmt_pct,
                          dim = function(w) return (w.VolGvar or 0) == 0 end },
    }
    -- "Test callout / Play" row: preview a callout with the page's WORKING values (see
    -- test_callout). Deliberately never dimmed — previewing an alert that is still off is
    -- exactly the point. Volume page: hear the working widget volume; Voice page: hear the
    -- working language. Appended rather than inlined so the literal above stays the plain
    -- key/def block it always was (it used to be appended from below the alert specs, which
    -- a lazy builder can no longer reach).
    t[#t + 1] = { kind = "action", lbl = "Test callout", btn = "Play",
        act = function(wgt, working)
            ultidash_functions.test_callout(wgt, working, { files = { "battry" }, num = { 70, UNIT_PERCENT } })
        end }
    return t
end
KEYS.volume = function(fn)
    fn("Volume", 0); fn("VolWhen", 1); fn("VolGvar", 0); fn("VolFlight", 80)
    fn("VolEscal", 100)
end

-- Global voice settings (language + master mute), reached via the Alerts submenu's
-- first entry ("Voice / mute"). Separate from the per-alert pages.
MK.voice = function()
    local t = {
    { key = "VoiceLang",  lbl = "Voice language",            kind = "choice", def = 1, vals = { "English", "Deutsch" } },
    { key = "Mute",       lbl = "Mute (master)",             kind = "choice", def = 1, vals = { "None", "All" } },
    -- separate haptic master: "Mute: All" silences AUDIO only; vibration has its own switch
    { key = "VibMaster",  lbl = "Vibration (master)",        kind = "bool", def = 1 },
    -- shared auto-close for the per-alert fullscreen overlay (PwrOvl/VoltOvl/
    -- TelemOvl pages); 0 = the overlay stays until tapped or the condition clears
    { key = "OvlClose",   lbl = "Overlay auto-close (s)",    kind = "num", def = 0, min = 0, max = 60, step = 1, big = 5,
      fmt = function(v) return (v == 0) and "until tapped" or (v .. " s") end },
    -- The NOTICE overlay: not an alert (no voice, no vibration, no armed condition),
    -- so it has no page of its own under Alerts. It sits here because this is where
    -- the shared overlay behaviour already lives. Default ON -- its whole purpose is
    -- being seen by somebody who did not go looking, and it only ever appears
    -- disarmed, after a link connect, when a real misconfiguration was measured.
    { key = "NoteOvl",    lbl = "Config warning overlay",    kind = "bool", def = 1 },
    }
    -- the second "Test callout / Play" row (see MK.volume): hear the working language
    t[#t + 1] = { kind = "action", lbl = "Test callout", btn = "Play",
        act = function(wgt, working)
            ultidash_functions.test_callout(wgt, working, { files = { "telem_ok" } })
        end }
    return t
end
KEYS.voice = function(fn)
    fn("VoiceLang", 1); fn("Mute", 1); fn("VibMaster", 1); fn("OvlClose", 0)
    fn("NoteOvl", 1)
end

-- Per-alert configuration. Each alert is its own settings sub-page (the Alerts
-- submenu). The historical on/off key (enKey) is REUSED as "Active" so existing
-- user choices survive; the rest are new per-alert keys, prefixed by `code`:
--   <code>Rep  repeat on/off          <code>Cnt  repeat count (0 = until cleared; total incl. first)
--   <code>Int  repeat interval (s)     <code>Esc  boost to escalation volume
--   <code>Vib  vibrate
-- (<code>Ovl, the fullscreen-overlay toggle, is not offered until that feature ships.)
-- repDef/cntDef/intDef default the repeat behaviour. Fuel & Voltage already repeat
-- continuously while the condition holds, so they default to Repeat=on / count=until
-- cleared / 6 s (reproducing the previous CalloutInt cadence); Telemetry and Main-power-
-- lost also default to Repeat=on (safety-critical, a single announce can be missed --
-- main-power-lost repeats until cleared as an audible buffer countdown, telemetry-lost
-- nags a few times); the remaining one-shot alerts default to Repeat=off (announce once,
-- as before). vibDef is on for the alerts you must not miss with the radio in your hands:
-- fuel, voltage, telemetry, main power lost, BEC, ESC load, temperature.
-- test = the "Play" preview spec (ultidash_functions.test_callout): the alert's first-
-- announce wav plus, where the real callout speaks a number, a fixed sample value.
-- desc = one-line behaviour summary shown as the info row on the alert's page (keep in
-- sync with the callout engine / README §5.1 when a trigger changes).
local ALERTS_SPEC = {
    { code = "Fuel",  name = "Fuel",            enKey = "SndFuel",    enDef = 1, vibDef = 1, repDef = 1, cntDef = 0, intDef = 6,
      desc = "Armed: announces the remaining battery % as it falls through the fuel warn / critical levels.",
      test = { files = { "battry" }, num = { 70, UNIT_PERCENT } } },
    { code = "Volt",  name = "Voltage",         enKey = "SndVolt",    enDef = 1, vibDef = 1, repDef = 1, cntDef = 0, intDef = 6, ovl = true,
      desc = "Armed: announces the voltage when the cell sinks to the warn / min threshold. Collapsed readings (about 1 V or less) are ignored - that case is Main power lost.",
      test = { files = { "batlow" }, voltnum = true } },
    { code = "Cell",  name = "Cell check",      enKey = "SndCellChk", enDef = 1, vibDef = 0, repDef = 0, cntDef = 3, intDef = 5, noEsc = true,
      desc = "Once after power-on/connect: compares the cell against the FC full-cell voltage (after the cell-check delay) and warns when the pack is not full.",
      test = { files = { "batlow" }, voltnum = true } },
    { code = "Arm",   name = "Armed / disarm",  enKey = "SndArm",     enDef = 1, vibDef = 0, repDef = 0, cntDef = 3, intDef = 5, noEsc = true,
      desc = "Announces every arm and disarm.",
      test = { files = { "armed" } } },
    { code = "Telem", name = "Telemetry",       enKey = "SndTelem",   enDef = 1, vibDef = 1, repDef = 1, cntDef = 3, intDef = 5, ovl = true,
      desc = "Armed: announces telemetry loss; 'telemetry ok' follows when it comes back after an armed loss.",
      test = { files = { "telem_lost" } } },
    { code = "Link",  name = "Link quality",    enKey = "SndLink",    enDef = 1, vibDef = 0, repDef = 0, cntDef = 3, intDef = 5,
      desc = "Armed: announces low link quality (RQly) with the % at the warn / critical thresholds.",
      test = { files = { "link_warn" } } },
    { code = "Rssi",  name = "RSSI / signal",   enKey = "SndRssi",    enDef = 1, vibDef = 0, repDef = 0, cntDef = 3, intDef = 5,
      desc = "Armed: warns when the best antenna's signal headroom stays at / below the RSSI warn / critical level for the hold time.",
      test = { files = { "rssi_warn" } } },
    { code = "Pwr",   name = "Main power lost", enKey = "PwrWarn",    enDef = 1, vibDef = 1, repDef = 1, cntDef = 0, intDef = 5, ovl = true,
      desc = "Armed + connected: the main pack voltage collapsed while the buffer keeps the FC alive. Each repeat speaks the live BEC voltage (buffer countdown); 'power ok' on recovery.",
      test = { files = { "pwr_backup" } } },
    { code = "Bec",   name = "BEC voltage",     enKey = "SndBec",     enDef = 1, vibDef = 1, repDef = 0, cntDef = 3, intDef = 5,
      desc = "Armed: announces the BEC voltage when it sags below the flight's reference by the BEC warn / critical %.",
      test = { files = { "bec_low" } } },
    { code = "EscL",  name = "ESC load",        enKey = "EscLoad",    enDef = 0, vibDef = 1, repDef = 0, cntDef = 3, intDef = 5,
      desc = "Armed, with ESC load monitoring on: announces the load % after it stays at / above the warn / critical % for the hold time.",
      test = { files = { "escl_warn" } } },
    { code = "Temp",  name = "Temperature",     enKey = "SndTemp",    enDef = 1, vibDef = 1, repDef = 0, cntDef = 3, intDef = 5,
      desc = "Armed: warns when the ESC temperature crosses the warn / critical threshold.",
      test = { files = { "esct_warn" } } },
    { code = "Skp",   name = "Skipped packets", enKey = "SkpWarn",    enDef = 1, vibDef = 0, repDef = 0, cntDef = 3, intDef = 5,
      desc = "Armed: warns when the skipped-packets rate (Skp) reaches the limit.",
      test = { files = { "skp_high" } } },
}

-- Alerts submenu: a "Voice / mute" entry plus one page per alert. The alert pages'
-- ROW TABLES build LAZILY on first open (build_alert_items lives in the lazy menu
-- module, like the Shortcuts/Colors rows) -- 12 pages x ~8 rows of item tables +
-- dim closures used to build here at module load, inside create()'s instruction
-- budget, for pages the user may never open. page.keys hands for_each_setting_item
-- the key/def pairs WITHOUT building rows -- keep it in sync with build_alert_items
-- (ultidashMenu.lua) when adding an alert row. page.spec carries the alert's spec
-- so the submenu shows On/Off + the feature markers straight from the options.
ALERT_PAGES[1] = { name = "Voice / mute", build = MK.voice, keys = KEYS.voice }
for i = 1, #ALERTS_SPEC do
    local a = ALERTS_SPEC[i]
    ALERT_PAGES[#ALERT_PAGES + 1] = { name = a.name, enKey = a.enKey, spec = a,
        keys = function(fn)
            fn(a.enKey, a.enDef)
            fn(a.code .. "Rep", a.repDef)
            fn(a.code .. "Cnt", a.cntDef)
            fn(a.code .. "Int", a.intDef)
            if not a.noEsc then fn(a.code .. "Esc", 0) end
            fn(a.code .. "Vib", a.vibDef)
            if a.ovl then fn(a.code .. "Ovl", 0) end
        end }
end

-- Switch voice announcements: the switch per function is picked with the NATIVE
-- EdgeTX source picker (lvgl.source, filtered to switches + logical switches).
-- Stored value = SIGNED EdgeTX source index of the WHOLE switch (negative =
-- inverted, picked as "!SA" in the popup; 0 = Off) — so the picker shows only
-- switches this radio actually has, including custom names, and the 3-position
-- semantics (read via getValue -> -1024/0/1024) stay intact.
-- READ-ONLY — the model's mixer/arming logic is untouched.
MK.switches = function() return {
    { key = "MotorSrc",   lbl = "Motor on/off switch",  kind = "switch", def = 0 },
    { key = "RescueSrc",  lbl = "Rescue switch",        kind = "switch", def = 0 },
    { key = "GovSrc",     lbl = "Governor mode switch", kind = "switch", def = 0 },
    { key = "ProfileSrc", lbl = "Profile switch (1-3)", kind = "switch", def = 0 },
} end
KEYS.switches = function(fn)
    fn("MotorSrc", 0); fn("RescueSrc", 0); fn("GovSrc", 0); fn("ProfileSrc", 0)
end

-- Governor-state voice: announce the Gov sensor's state (0..9) on every stable change
-- while ARMED. GovVoice is the master toggle (default off — opt-in feature); each state
-- has its own enable so noisy transitions can be silenced. All states default ON so the
-- master switch alone gives full feedback; dim the per-state rows while the master is off.
local function gov_voice_off(w) return (w.GovVoice or 0) ~= 1 end
MK.govvoice = function() return {
    { key = "GovVoice",  lbl = "Announce gov state",  kind = "bool", def = 0 },
    { kind = "info", lbl = "Speaks the governor state on change, in flight only (armed). Pick which states are called out below." },
    { key = "GvsOff",     lbl = "Throttle off",   kind = "bool", def = 1, dim = gov_voice_off },
    { key = "GvsIdle",    lbl = "Throttle Idle",  kind = "bool", def = 1, dim = gov_voice_off },
    { key = "GvsSpool",   lbl = "Spooling up",    kind = "bool", def = 1, dim = gov_voice_off },
    { key = "GvsRecov",   lbl = "Recovery",       kind = "bool", def = 1, dim = gov_voice_off },
    { key = "GvsActive",  lbl = "Gov. Active",    kind = "bool", def = 1, dim = gov_voice_off },
    { key = "GvsHold",    lbl = "Throttle Hold",  kind = "bool", def = 1, dim = gov_voice_off },
    { key = "GvsFallbk",  lbl = "Gov. Fallback",  kind = "bool", def = 1, dim = gov_voice_off },
    { key = "GvsAutorot", lbl = "Autorotation",   kind = "bool", def = 1, dim = gov_voice_off },
    { key = "GvsBailout", lbl = "Bailing Out",    kind = "bool", def = 1, dim = gov_voice_off },
    { key = "GvsBypass",  lbl = "Gov. Bypass",    kind = "bool", def = 1, dim = gov_voice_off },
} end
KEYS.govvoice = function(fn)
    fn("GovVoice", 0); fn("GvsOff", 1); fn("GvsIdle", 1); fn("GvsSpool", 1); fn("GvsRecov", 1)
    fn("GvsActive", 1); fn("GvsHold", 1); fn("GvsFallbk", 1); fn("GvsAutorot", 1)
    fn("GvsBailout", 1); fn("GvsBypass", 1)
end

-- NB: the pre-native stored codes (own list: 1=Off, 2..17 SA..SH, 18..29 CFS,
-- 100+ logical switches, old keys MotorSw/RescueSw/GovSw/ProfileSw/TbSwitch) are
-- NOT auto-migrated: an in-widget migration needed file I/O inside update() and
-- tripped the CPU limit on SD remount. Existing models: re-pick the switches
-- once in Settings > Switch voice; the old cfg keys are simply ignored.

-- Configurable telemetry value slots, split into two settings groups:
--   "Tele Main"    = the 5 rows of the dashboard's right-hand value panel
--   "Tele Details" = the 12 cells of the tap-to-open Telemetry detail page
-- kind="sensor" stores the EdgeTX sensor NAME (string). Defaults reproduce the
-- original panel; the detail page defaults to a sensible battery/ESC set.
-- VOLT_AUTO = the smart cell/battery voltage (warn colour).
MK.tele_main = function() return {
    { kind = "info", lbl = "Dropdown = common sensors. Right field = any raw source (overrides the dropdown)." },
    { key = "PanelV1", lbl = "Panel 1 (top)", kind = "sensor", def = VOLT_AUTO },
    { key = "PanelV2", lbl = "Panel 2",       kind = "sensor", def = "Hspd" },
    { key = "PanelV3", lbl = "Panel 3",       kind = "sensor", def = "Curr" },
    { key = "PanelV4", lbl = "Panel 4",       kind = "sensor", def = "Tesc" },
    { key = "PanelV5", lbl = "Panel 5 (btm)", kind = "sensor", def = "Vbec" },
} end
KEYS.tele_main = function(fn)
    fn("PanelV1", VOLT_AUTO); fn("PanelV2", "Hspd"); fn("PanelV3", "Curr")
    fn("PanelV4", "Tesc"); fn("PanelV5", "Vbec")
end

MK.tele_detail = function() return {
    { kind = "info", lbl = "Dropdown = common sensors. Right field = any raw source (overrides the dropdown)." },
    { key = "DetV1",   lbl = "Detail 1",      kind = "sensor", def = "Vbat" },
    { key = "DetV2",   lbl = "Detail 2",      kind = "sensor", def = "Vcel" },
    { key = "DetV3",   lbl = "Detail 3",      kind = "sensor", def = "Curr" },
    { key = "DetV4",   lbl = "Detail 4",      kind = "sensor", def = "Capa" },
    { key = "DetV5",   lbl = "Detail 5",      kind = "sensor", def = "Bat%" },
    { key = "DetV6",   lbl = "Detail 6",      kind = "sensor", def = SENSOR_OFF },
    { key = "DetV7",   lbl = "Detail 7",      kind = "sensor", def = SENSOR_OFF },
    { key = "DetV8",   lbl = "Detail 8",      kind = "sensor", def = SENSOR_OFF },
    { key = "DetV9",   lbl = "Detail 9",      kind = "sensor", def = SENSOR_OFF },
    { key = "DetV10",  lbl = "Detail 10",     kind = "sensor", def = SENSOR_OFF },
    { key = "DetV11",  lbl = "Detail 11",     kind = "sensor", def = SENSOR_OFF },
    { key = "DetV12",  lbl = "Detail 12",     kind = "sensor", def = SENSOR_OFF },
} end
KEYS.tele_detail = function(fn)
    fn("DetV1", "Vbat"); fn("DetV2", "Vcel"); fn("DetV3", "Curr"); fn("DetV4", "Capa")
    fn("DetV5", "Bat%"); fn("DetV6", SENSOR_OFF); fn("DetV7", SENSOR_OFF)
    fn("DetV8", SENSOR_OFF); fn("DetV9", SENSOR_OFF); fn("DetV10", SENSOR_OFF)
    fn("DetV11", SENSOR_OFF); fn("DetV12", SENSOR_OFF)
end

-- M5: the Live Monitor's sensor slots (Toolbox ▸ Live Monitor page). Same kind="sensor"
-- component as Tele Main / Details / D3's report rows; all four default OFF, and the
-- HOST allocates the ring only while at least one is set -- the feature costs nothing
-- until someone configures it.
MK.livemon = function() return {
    { kind = "info", lbl = "Live Monitor (Toolbox): each sensor gets a full-width strip of the last 15-60 s, min/max per 0.2 s. Sampling runs while the page is closed." },
    { key = "LmV1", lbl = "Strip 1 (top)", kind = "sensor", def = SENSOR_OFF },
    { key = "LmV2", lbl = "Strip 2",       kind = "sensor", def = SENSOR_OFF },
    { key = "LmV3", lbl = "Strip 3",       kind = "sensor", def = SENSOR_OFF },
    { key = "LmV4", lbl = "Strip 4",       kind = "sensor", def = SENSOR_OFF },
    { key = "LmWin", lbl = "Window", kind = "choice", def = 2, vals = { "15 s", "30 s", "60 s" } },
} end
KEYS.livemon = function(fn)
    fn("LmV1", SENSOR_OFF); fn("LmV2", SENSOR_OFF); fn("LmV3", SENSOR_OFF)
    fn("LmV4", SENSOR_OFF); fn("LmWin", 2)
end

-- General / meta settings (config-file behaviour, diagnostics)
MK.general = function() return {
    { key = "DebugLog",    lbl = "Debug log to SD card",  kind = "bool", def = 0 },
    { key = "DebugKeep",   lbl = "Debug log: sessions kept", kind = "num", def = 20, min = 1, max = 50, step = 1, big = 5 },
    -- The on-screen half of the debug mode, separated from the logging half. Default ON, so
    -- switching the log on behaves exactly as it always did; what is new is that a session
    -- that wants the LOG (a flight, a screenshot, a bug report someone else will read) can
    -- have it without the strip sitting over the layout. Dimmed rather than hidden while the
    -- log is off, because the row is meaningless then and disappearing rows move every row
    -- under them.
    { key = "DbgOvl",      lbl = "Show perf overlay",     kind = "bool", def = 1,
      dim = function(w) return (w.DebugLog or 0) ~= 1 end },
    -- Flight log / battery management (Toolbox "Flight Log" shows the data;
    -- batteries are defined in fltlog/batteries.cfg, edited on the PC)
    { kind = "section", lbl = "Flight log" },
    { key = "FltLog",  lbl = "Log flights to SD card",     kind = "bool", def = 0 },
    { key = "FltStats",lbl = "Log per-flight stats",       kind = "bool", def = 0 },
    { key = "FltMinS", lbl = "Min. flight time",           kind = "num", def = 30,
                       min = 0, max = 300, step = 5, big = 30,
                       fmt = function(v) return (v == 0) and "log every arm" or (v .. " s") end },
    { key = "FltBatt", lbl = "Ask battery on connect",     kind = "bool", def = 0 },
    { key = "FltProf", lbl = "Battery sets FC profile",    kind = "bool", def = 0 },
    -- RESET TO DEFAULTS, which used to be a warning-coloured button under the settings
    -- menu's grid. It moved here for the room: that button plus its reserve is what kept
    -- the 13 group tiles from getting the whole body. Last row of the last group, behind a
    -- confirmation -- the same routine, only its route changed. No settings key, so it adds
    -- nothing to KEYS.general and nothing to SETTINGS_DEFAULTS.
    { kind = "action", lbl = "Reset to defaults", btn = "Reset",
      act = function(wgt)
        local function do_reset()
            -- STAGGERED exactly like the autosave (see save_pending_settings): this runs
            -- inside a dialog callback, whose call already carries the page -- so only
            -- FLAG it here; the host's stage 1 does the write in its own cycle (a
            -- stamps-only file since the delta rule) and hands over to stage 2
            -- (settings_apply_pending), which applies, bumps settings_gen and flags the
            -- rebuild.
            wgt.settings_reset_pending = true
            -- Drop the working copy WITHOUT saving it, and leave for the group list. Not
            -- cosmetic: a reset changes every key, so a working copy seeded before it
            -- would hold pre-reset values that the next autosave would write straight back
            -- over the defaults. Leaving is also where the old button left the user.
            wgt.settings_working = nil
            wgt.settings_senslist = nil
            wgt.settings_target = nil
            wgt.menu_view = "settings_menu"
            init_view_state(wgt).dirty = true
        end
        -- confirmation dialog when available; plain reset otherwise
        local ok = pcall(function()
            lvgl.confirm({ title = "Reset settings",
                           message = "Reset ALL settings of this model to defaults?",
                           confirm = do_reset })
        end)
        if not ok then do_reset() end
      end },
} end
KEYS.general = function(fn)
    fn("DebugLog", 0); fn("DebugKeep", 20); fn("DbgOvl", 1); fn("FltLog", 0); fn("FltStats", 0)
    fn("FltMinS", 30); fn("FltBatt", 0); fn("FltProf", 0)
end

-- D3: the spoken telemetry report. The TRIGGER is a shortcut switch (target
-- "Voice: Telemetry report" in the Shortcuts group) -- deliberately no switch row
-- here, so switches keep living in one place. Slots are spoken in THIS order;
-- with the names option off the pilot infers the sensor from that order. Defaults
-- follow the design's ~15-20 s: battery, headspeed, current, temperature, BEC,
-- link, two free.
MK.telemsay = function() return {
    { kind = "section", lbl = "Report slots (spoken in order)" },
    { key = "TsayV1", lbl = "Slot 1", kind = "sensor", def = VOLT_AUTO },
    { key = "TsayV2", lbl = "Slot 2", kind = "sensor", def = "Hspd" },
    { key = "TsayV3", lbl = "Slot 3", kind = "sensor", def = "Curr" },
    { key = "TsayV4", lbl = "Slot 4", kind = "sensor", def = "Tesc" },
    { key = "TsayV5", lbl = "Slot 5", kind = "sensor", def = "Vbec" },
    { key = "TsayV6", lbl = "Slot 6", kind = "sensor", def = "RQly" },
    { key = "TsayV7", lbl = "Slot 7", kind = "sensor", def = SENSOR_OFF },
    { key = "TsayV8", lbl = "Slot 8", kind = "sensor", def = SENSOR_OFF },
    { kind = "section", lbl = "Behaviour" },
    -- floor 10 s is functional: eight slots run ~15-20 s, below that a report
    -- would overtake itself (the repeat counts from the report's START)
    { key = "TsayInt",   lbl = "Repeat (switch held)", kind = "num", def = 30, min = 10, max = 120, step = 5, big = 15,
                         fmt = function(v) return v .. " s" end },
    -- the third variant -- a warning waiting for the report -- was decided OUT
    { key = "TsayPrio",  lbl = "When an alert speaks", kind = "choice", def = 1, vals = { "Report stops", "Report pauses" } },
    -- opt-in name wavs (s_<sensor>.wav in SOUNDS/<lang>/ultidash/); a missing file
    -- falls back to value-and-unit, and menu > Status counts the coverage
    { key = "TsayNames", lbl = "Speak sensor names",   kind = "bool", def = 0 },
} end
KEYS.telemsay = function(fn)
    fn("TsayV1", VOLT_AUTO); fn("TsayV2", "Hspd"); fn("TsayV3", "Curr"); fn("TsayV4", "Tesc")
    fn("TsayV5", "Vbec"); fn("TsayV6", "RQly"); fn("TsayV7", SENSOR_OFF)
    fn("TsayV8", SENSOR_OFF); fn("TsayInt", 30); fn("TsayPrio", 1); fn("TsayNames", 0)
end

-- Toolbox: RF adjustment map/editor tool pages (sources default to ch11/ch12/AdjV/BEAT/PID#)
MK.toolbox = function() return {
    -- activation switch / auto-open moved to the "Shortcuts" group (SETTINGS_SHORTCUTS);
    -- a shortcut can now open Adjust Map / Adjust Edit like any other page.
    -- T: where the adjust table comes from. Manual = the built-in table (labels.lua on
    -- top, unchanged behaviour). The two FC states read the craft's own adjfunc lines
    -- over MSP once per connect (ultidashRf adj_step) -- the exact bank windows included,
    -- so a Config channel in a dead gap reads "no bank" instead of a wrong one. The read
    -- runs ONLY when this option asks for it; menu > Status names the effective source.
    { key = "TbSource", lbl = "Adj table from", kind = "choice", def = 1,
      vals = { "Manual", "Flight controller", "FC + labels.lua" } },
    { key = "TbConfigCh", lbl = "Adj: Config channel",  kind = "num", def = 11, min = 1, max = 32, step = 1, big = 4, fmt = function(v) return "CH" .. v end },
    { key = "TbValueCh",  lbl = "Adj: Value channel",   kind = "num", def = 12, min = 1, max = 32, step = 1, big = 4, fmt = function(v) return "CH" .. v end },
    { key = "TbGvar",  lbl = "Adj editor: GVAR",        kind = "num", def = 1, min = 1, max = 15, step = 1, big = 1,
                       fmt = function(v) return "GV" .. v end },
    { key = "TbPulse", lbl = "Adj editor: pulse (ms)",  kind = "num", def = 150, min = 50, max = 1000, step = 10, big = 50 },
    { key = "TbScale", lbl = "Adj value divider",       kind = "num", def = 1, min = 1, max = 1000, step = 1, big = 10 },
    { key = "TbBert",  lbl = "Adj editor: ranges hint", kind = "bool", def = 0 },
    { key = "TbSun",   lbl = "Toolbox sunlight mode",   kind = "bool", def = 0 },
    { key = "TbVoice", lbl = "Announce bank (voice)",   kind = "bool", def = 1 },
} end
KEYS.toolbox = function(fn)
    fn("TbSource", 1); fn("TbConfigCh", 11); fn("TbValueCh", 12); fn("TbGvar", 1)
    fn("TbPulse", 150); fn("TbScale", 1)
    fn("TbBert", 0); fn("TbSun", 0); fn("TbVoice", 1)
end

-- `build` + `keys` instead of `items` on every flat group and on the two plain
-- submenus' pages (see MK/KEYS above for the why and the tradeoff). "Skin" keeps
-- `items`: SETTINGS_SKIN is the IN-PLACE table refresh_skin_menus rewrites on a skin
-- change, and its keys come from the skin manifests via register_skin_defaults, not
-- from here.
-- `icon` is the bare glyph name of the settings menu's tile image; the menu module turns it
-- into /WIDGETS/UltiDash/img/ud_<icon>.png. Names and assignment come from the menu-icon
-- spec's group table; a group without one degrades to a text-only tile.
local __groups = {
    { name = "Display",    icon = "monitor", build = MK.display, keys = KEYS.display },
    { name = "Skin",       icon = "layers",  items = SETTINGS_SKIN },   -- the ACTIVE skin's own rows (in-place, stage 3c)
    { name = "Colors",     icon = "palette", submenu = COLOR_PAGES, menu = "colors_menu" },
    { name = "Telemetry",  icon = "wave",    menu = "sub_menu", submenu = {
        { name = "Tele Main",    icon = "list",     build = MK.tele_main,   keys = KEYS.tele_main },
        { name = "Tele Details", icon = "listfind", build = MK.tele_detail, keys = KEYS.tele_detail },
        { name = "Live monitor", icon = "pulse",    build = MK.livemon,     keys = KEYS.livemon },   -- the Toolbox tile wears the same glyph: one feature, one picture
    } },

    { name = "Battery",    icon = "battery", build = MK.battery,    keys = KEYS.battery },
    { name = "Thresholds", icon = "gauge",   build = MK.thresholds, keys = KEYS.thresholds },
    { name = "ESC load",   icon = "esc",     build = MK.esc,        keys = KEYS.esc },

    { name = "Volume",     icon = "speaker", build = MK.volume, keys = KEYS.volume },
    { name = "Alerts",     icon = "bell",    submenu = ALERT_PAGES, menu = "alerts_menu" },
    { name = "Voice",      icon = "voice",   menu = "sub_menu", submenu = {
        { name = "Switch voice", icon = "switchvoice", build = MK.switches, keys = KEYS.switches },
        { name = "Gov voice",    icon = "governor",    build = MK.govvoice, keys = KEYS.govvoice },
        -- D3: filed under Voice, not Telemetry -- a voice feature filed under
        -- telemetry is found by nobody looking for voice (the user's call)
        { name = "Telemetry report", icon = "report", build = MK.telemsay, keys = KEYS.telemsay },
    } },

    { name = "Shortcuts",  icon = "switch",  menu = "sub_menu", submenu = shortcut.pages },
    { name = "Toolbox",    icon = "wrench",  build = MK.toolbox, keys = KEYS.toolbox },
    { name = "General",    icon = "sliders", build = MK.general, keys = KEYS.general },
}
for i = 1, #__groups do SETTINGS_GROUPS[i] = __groups[i] end
-- section runs MUST sum to #SETTINGS_GROUPS (currently 13) — the menu hub walks groups
-- section-by-section, so any group past the last run's end is dropped from the grid (this
-- is what hid "General"/Debug log after the "Skin" group was added as a 13th group).
SETTINGS_GROUPS.sections = {
    { hdr = "Appearance",       n = 3 },   -- Display, Skin, Colors
    { hdr = "Battery & limits", n = 4 },   -- Telemetry, Battery, Thresholds, ESC load
    { hdr = "Sound & callouts", n = 3 },   -- Volume, Alerts, Voice
    { hdr = "System",           n = 3 },   -- Shortcuts, Toolbox, General
}
for_each_setting_item(function(it)
    if it.key then SETTINGS_DEFAULTS[it.key] = it.def end   -- skip keyless info rows
end)
-- hidden key (no settings row): tracks whether the in-widget menu was opened at
-- least once — drives the first-placement hint banner on the dashboard
SETTINGS_DEFAULTS.SetupSeen = 0
SETTINGS_GROUPS._build = nil
end


--- Persist pending settings edits (if any) and resolve them into the options.
--- AUTOSAVE policy: edits are saved no matter HOW the page is left (back arrow,
--- RTN, arming, fullscreen exit) — losing changes on exit confused more than a
--- discard path ever helped.
--- True when the settings working copy differs from the live options (i.e. the user
--- actually changed something on the page). Working was seeded FROM wgt.options at page
--- open, so a plain key compare is sufficient (covers the <key>Raw shadow keys too --
--- they are part of the working copy). Avoids a needless SD write + apply on every page
--- that was merely viewed.
local function settings_changed(wgt)
    local w = wgt.settings_working
    if not w then return false end
    for k, v in pairs(w) do
        if wgt.options[k] ~= v then return true end
    end
    return false
end

local function save_pending_settings(wgt)
    if not wgt.settings_working then return end
    -- target file moved since the page was opened (model switch / craft rename
    -- mid-edit): discard rather than write model A's edits into B's cfg
    if wgt.settings_target ~= nil and ultidash_settings.target_path ~= nil
        and wgt.settings_target ~= ultidash_settings.target_path() then
        ultidash_functions.log("settings discarded (cfg target moved mid-edit)")
        wgt.cfg_save_failed_text = "Settings discarded (model changed)"
        wgt.cfg_save_failed_until = (getTime() or 0) + 1000
        wgt.settings_working = nil
        wgt.settings_target = nil
        -- ...and the staged pick list with it. This exit is the one that skipped it, so a
        -- discard left ~40 formatted strings resident for the rest of the session -- the
        -- boot-resident heap the normal path below goes out of its way to avoid.
        wgt.settings_senslist = nil
        return
    end
    if settings_changed(wgt) then
        -- HAND THE WRITE OVER instead of doing it here: unstaggered, the save plus the
        -- apply in one call is what tripped "CPU limit" at the apply() line -- the
        -- arm-close caller runs INSIDE the 5 Hz heavy pass (measured 22.4k, reported
        -- from a v0.6.1 radio). Stage 1 = the SD write (chunked since E1, one bounded
        -- batch per call -- see settings_write_stage1), stage 2 = the apply, each alone
        -- in its own cycle (refresh()/background()). Costs a few invisible frames. The
        -- edits live on wgt until the write lands, so only a widget teardown inside
        -- that short window could drop them.
        wgt.settings_save_pending = wgt.settings_working
    end
    wgt.settings_working = nil
    wgt.settings_target = nil
    -- the page's staged sensor pick list goes with the working copy: it is ~40 formatted
    -- strings and nothing outside an open settings page reads it, so holding it would be
    -- boot-resident heap, which slows the whole UI through the GC
    wgt.settings_senslist = nil
end

--- Close the settings page back to wherever it was opened from (autosaves). Normal
--- group pages return to the settings submenu; alert sub-pages to the alerts submenu.
local function close_settings(wgt)
    save_pending_settings(wgt)
    wgt.menu_view = (wgt.settings_page and wgt.settings_page.back) or "settings_menu"
    init_view_state(wgt).dirty = true
end

--- Cleanup for EVERY forced transition away from an open tool page (RTN, switch falling
--- edge, arm, fullscreen exit): reset an in-flight adjed GVAR pulse, run the module's own
--- close/cleanup, and DROP the lazy-loaded module refs for GC (boot-resident modules
--- measurably drag the whole UI — the lazy-load contract; since the lazy-load pass ALL
--- tools including adjed/adjmap release here). NOTE: the fullscreen-exit transition runs BEFORE the
--- tools' exclusive refresh branches, so the modules' own FS-exit checks never fire —
--- this is the only close that reaches them on that path.
local function close_tool_page(wgt)
    -- Adjust Map/Editor: lazy-loaded like the rest; release the module ref on close
    -- (per-session state lives on wgt.tb_map / wgt.tb_ed, so a reload loses nothing;
    -- the shared tb_common with the labels override stays resident)
    if wgt.menu_view == "tb_adjmap" and tb_adjmap then
        tb_adjmap = nil                 -- release the lazy-loaded module (GC)
    end
    if wgt.menu_view == "tb_adjed" and tb_adjed then
        if tb_adjed.cleanup then tb_adjed.cleanup(wgt) end
        tb_adjed = nil                  -- release the lazy-loaded module (GC)
    end
    -- M5: the Live Monitor has no cleanup -- its data lives in the HOST (wgt.lm keeps
    -- sampling with the page closed, which is the feature) -- only the module ref drops
    if wgt.menu_view == "tb_livemon" and livemon.mod then
        livemon.mod = nil               -- release the lazy-loaded module (GC)
        wgt.lmv = nil                   -- and the page's per-instance draw state
    end
    -- RF2 Config MUST run its own close on ANY forced exit (fullscreen exit):
    -- it restores the rf2.* UI slots and the un-gated mspQueue pump -- without
    -- that, the RfTool widget's MSP processing would stay parked behind the
    -- module's context gate.
    if wgt.menu_view == "tb_rf2cfg" and tb_rf2cfg then
        if tb_rf2cfg.cleanup then tb_rf2cfg.cleanup(wgt) end
        wgt.rf2cfg_close_req = nil      -- consumed here; a stale flag would shut a fresh page
        tb_rf2cfg = nil                 -- release the lazy-loaded module (GC)
    end
    -- RFSuite MUST run its own close on ANY forced exit for the same reason
    -- and one more: besides restoring the rf2 pump it detaches RFSuite's MSP client
    -- and calls clearAllModules -- the only chance this Lua state ever gets to give
    -- that module graph back.
    if wgt.menu_view == "tb_rfscfg" and rfscfg.mod then
        if rfscfg.mod.cleanup then rfscfg.mod.cleanup(wgt) end
        wgt.rfs_close_req = nil         -- consumed here; a stale flag would shut a fresh page
        rfscfg.mod = nil                -- release the lazy-loaded module (GC)
    end
    -- Log Viewer: release the open /LOGS file handle + the ~2000-line module
    if wgt.menu_view == "tb_logview" and tb_logview then
        if tb_logview.close then tb_logview.close(wgt) end
        wgt.lv_close_req = nil          -- consumed here; a stale flag would shut a fresh page
        tb_logview = nil                -- release the lazy-loaded module (GC)
    end
    -- Flight Log viewer: release the open CSV handle on a forced exit
    -- (its cleanup also drops the battery editor's state, wgt.fb)
    if wgt.menu_view == "tb_fltlog" and fltlog.mod then
        if fltlog.mod.cleanup then fltlog.mod.cleanup(wgt) end
        wgt.fl_close_req = nil          -- consumed here; a stale flag would shut a fresh page
        wgt.fb_close_req, wgt.fb_saved, wgt.fb_dirty = nil, nil, nil
        fltlog.mod = nil                -- release the lazy-loaded module (GC)
    end
    -- battpick "+ New" create form (fltbatt): a forced exit discards the open
    -- form -- nothing is written (only its own deferred save cycle ever writes)
    if wgt.menu_view == "tb_batted" and fltlog.batted then
        if fltlog.batted.cleanup then fltlog.batted.cleanup(wgt) end
        wgt.fb_close_req, wgt.fb_saved, wgt.fb_dirty = nil, nil, nil
        fltlog.batted = nil             -- release the lazy-loaded module (GC)
    end
end

-- ============================================================================
-- FLIGHT LOG / BATTERY MANAGEMENT (publisher-only glue)
-- ============================================================================
-- Records one flights.csv line per flight (FltLog) and tracks battery usage in
-- fltlog/batteries.cfg (FltBatt: query on connect, cycles+1 / last-use stamp
-- once per battery session). Flight time = the widget's own tracked counter
-- (armed AND rotor spinning), taken as a per-arm-cycle delta so multi-flight
-- sessions log each flight. All SD work runs via tb_fltdata in its OWN refresh
-- cycle (flt_flush_req / battpick_load_req), never inside the heavy pass.

-- Deferred FC battery-profile write (FltProf). The write must NOT run inside the
-- LVGL press callback: the battery query opens seconds after the connect, while the
-- RF service's own connect reads (profile/config/stats) are still working through
-- rf2's mspQueue -- a write pushed in there was silently lost (the FC kept its old
-- profile). So the pick only records the wish; this runs it from a normal refresh
-- cycle, re-reads first (exactly what the manual profile picker does before its
-- write) and RETRIES while the queue is busy.
fltlog.PROF_TRIES = 8       -- ~4 s at the 5 Hz pass
fltlog.PROF_DELAY_CS = 60   -- first attempt ~0.6 s after the pick (page close settles)

-- every exit of the profile write is logged (with the debug log on): a silent
-- give-up sent the first hardware round hunting for a bug that was really a
-- registry line without a profile= field
local function prof_log(fmt, ...)
    if ultidash_functions.dbg then ultidash_functions.dbg.logf("FLTLOG", fmt, ...) end
end

-- Arm-edge bookkeeping, shared by refresh() AND background(): the
-- stats-dismiss clear and the flight-log open/flush edges must not depend on
-- UltiDash being the active screen — with the dashboard covered, a whole flight
-- used to log 0 s (the edges only ran in refresh). Rising ARM-sensor edge = a
-- real new flight (clear the manual stats dismiss, open the flight record);
-- falling edge = flight over (flush deferred to its own cycle). The ARM sensor
-- is clean through a main-power-lost (EdgeTX logs) whereas the connection
-- sub-state is flaky; a telemetry dropout reads as "not armed" — that splits a
-- flight into two logged legs, the totals stay correct.
function fltlog.arm_edges(wgt)
    local arm_on = ultidash_functions.arm_sensor_on(wgt)
    if arm_on and not wgt.was_armed_sensor then
        wgt.stats_dismissed = false
        wgt.stats_tap_open = nil   -- C3: a new flight retires a standing tap-open too
        if ultidash_functions.dbg then ultidash_functions.dbg.logf("STATS", "dismiss cleared (arm rising edge)") end
        -- flight log: a genuine arm opens a flight record (counter snapshot)
        fltlog.arm(wgt)
        -- "Open page on arming": ARM the request here, execute it two ticks later. The
        -- edge itself is the worst possible moment -- this is exactly the switch on which
        -- sync_view_for_telemetry sets detail_view = nil (a stats page being replaced by
        -- the flight view), so a page opened now is wiped before it is ever drawn. Same
        -- shape as fltlog.open_battpick's deferred open. Nothing happens here beyond the
        -- flag: whether it may open at all is decided where the view state is known.
        if wgt.options ~= nil and (wgt.options.ArmOpen or 1) > 1 and wgt.options.ArmClose ~= 1 then
            wgt.arm_open_at = (getTime() or 0) + 40   -- ~0.4 s
        end
    elseif wgt.was_armed_sensor and not arm_on and wgt.flt_open then
        wgt.flt_flush_req = true
    end
    wgt.was_armed_sensor = arm_on
end

-- ============================================================================
-- LAZY MENU/SETTINGS MODULE (ultidashMenu.lua)
-- ============================================================================
-- Every fullscreen menu page (hub, Toolbox/Settings submenus, the settings
-- pages, sensor check, both battery pickers) lives in ultidashMenu.lua. It is
-- lazy-loaded on menu open and released once the menu family closes -- ~85 kB
-- of cold builder source off the resident heap (same GC rationale as the lazy
-- Toolbox tools). The env hands it the resident context ONCE (functions/tables
-- never reassigned after load); the palette + tool-avail flags DO change, so
-- those go in as getters the module pulls fresh per build.
local menu_mod = nil
local menu_env = nil
local function menu_load(wgt)
    if menu_mod ~= nil then return menu_mod end
    if menu_env == nil then
        -- The env captures `rf_service` BY VALUE, once, and the menu module keeps that
        -- reference for the session (its battery-profile picker calls through it). Since
        -- the service is lazy-loaded, capturing before it is attached would hand the menu
        -- a permanent nil. Attach first: idempotent, and by any real menu open long done.
        ensure_rf_service(wgt)
        menu_env = {
            init_view_state       = init_view_state,
            close_settings        = close_settings,
            -- for_each_setting_item is NOT handed over any more — the menu's settings
            -- seed became page-scoped (2026-08-17) and was its only consumer there
            build_sensor_list     = build_sensor_list,
            sensor_pick_label     = sensor_pick_label,
            is_raw_sensor         = is_raw_sensor,
            resolve_builtins      = resolve_builtins,
            role_color            = role_color,
            role_in_scheme        = role_in_scheme,
            color_key             = color_key,
            picker_rgb24          = picker_color_to_rgb24,
            prof_log              = prof_log,
            bump_settings_gen     = function() settings_gen = settings_gen + 1 end,
            -- open a Toolbox tool through the ONE shared open path:
            -- shortcut.open lazy-loads, refuses armed (sets the ~2 s hint), clears
            -- stale close flags and sets tool_back — by target id from the menu
            shortcut_open         = function(w, id)
                for i = 1, #shortcut.targets do
                    if shortcut.targets[i].id == id then
                        return shortcut.open(w, shortcut.targets[i])
                    end
                end
                return false
            end,
            tb_avail              = function()
                return tb_adjmap_avail, tb_adjed_avail, tb_logview_avail, tb_rf2cfg_avail,
                       livemon.avail, rfscfg.avail
            end,
            SETTINGS_GROUPS       = SETTINGS_GROUPS,
            ALERT_PAGES           = ALERT_PAGES,
            COLOR_PAGES           = COLOR_PAGES,
            COLOR_ROLES           = COLOR_ROLES,
            SENSOR_INFO           = SENSOR_INFO,
            PANEL_SLOT_KEYS       = PANEL_SLOT_KEYS,
            DETAIL_SLOT_KEYS      = DETAIL_SLOT_KEYS,
            fltlog                = fltlog,
            rf_service            = rf_service,
            ultidash_settings     = ultidash_settings,
            ultidash_functions    = ultidash_functions,
            SENSOR_OFF            = SENSOR_OFF,
            VOLT_AUTO             = VOLT_AUTO,
            ESCL_AUTO             = ESCL_AUTO,
            RAW_SENTINEL          = RAW_SENTINEL,
            SCHEME_DEFAULT        = SCHEMES.ulti,   -- fallback descriptor for colour rows
            colors                = function()
                return COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1,
                       COLOR_THEME_SECONDARY2, COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS,
                       COLOR_THEME_WARNING, COLOR_THEME_DISABLED,
                       SEM_GREEN, SEM_YELL, SEM_RED, SEM_NEUT, COLOR_DIM
            end,
        }
    end
    local ok, m = pcall(function() return loadScript(script_dir .. "ultidashMenu.lua")() end)
    -- init inside the protection too: a raising init would crash the widget
    -- state; failing here just degrades like a missing module (menu falls back to
    -- the dashboard in update()'s dispatch) and retries on the next open
    if ok and m ~= nil and pcall(m.init, menu_env) then
        menu_mod = m
    end
    return menu_mod
end

-- wgt.flt_prof_req is a table: { idx = 0..5 } (explicit profile= override) or
-- { cap = mAh } (resolve against the FC profiles' configured capacities).
function fltlog.write_profile(wgt)
    wgt.flt_prof_try = (wgt.flt_prof_try or 0) + 1
    local req = wgt.flt_prof_req
    -- armed or MSP not allowed: never write (hard safety rule)
    if req == nil or wgt.armed_now or not (wgt.rf and wgt.rf.msp_allowed) then
        if (wgt.flt_prof_try or 0) >= fltlog.PROF_TRIES or wgt.armed_now then
            wgt.flt_prof_req = nil
            prof_log("profile write dropped (armed=%s, msp_allowed=%s)",
                tostring(wgt.armed_now), tostring(wgt.rf and wgt.rf.msp_allowed))
        end
        return
    end
    -- first attempt: only re-read (the manual picker reads on open, writes on the
    -- later tap) -- the write then goes out on the next cycle against fresh state,
    -- and the capacity match below sees the freshly read per-profile capacities
    if wgt.flt_prof_try == 1 then
        rf_service.refresh_data(wgt)
        return
    end
    local idx = req.idx
    if idx == nil then
        -- capacity match: the FC profile whose configured capacity equals the pack's
        -- cap= (first match wins on duplicates). The config may still be in flight
        -- from the re-read -> keep retrying until the tries run out.
        for i = 0, 5 do
            if rf_service.get_profile_capacity(wgt, i) == req.cap then idx = i; break end
        end
        if idx == nil then
            if wgt.flt_prof_try >= fltlog.PROF_TRIES then
                wgt.flt_prof_req = nil
                prof_log("no FC profile with %d mAh (or per-profile capacities unavailable)", req.cap)
            end
            return
        end
    end
    -- already the active profile: nothing to write (spares the eeprom save)
    if wgt.values.rf_battery_profile_active == idx then
        wgt.flt_prof_req = nil
        prof_log("profile %d already active", idx + 1)
        return
    end
    if rf_service.set_battery_profile(wgt, idx) then
        wgt.flt_prof_req = nil
        prof_log("battery profile set to %d", idx + 1)
    elseif wgt.flt_prof_try >= fltlog.PROF_TRIES then
        wgt.flt_prof_req = nil
        prof_log("battery profile write gave up after %d tries (idx %d)", wgt.flt_prof_try, idx)
    end
end

-- ARM rising edge: open a flight record (snapshot the counter + start time)
function fltlog.arm(wgt)
    wgt.battpick_wait = nil   -- armed without answering: the query window is over
    if (wgt.options.FltLog or 0) ~= 1 and wgt.flt_batt_id == nil then return end
    wgt.flt_open = true
    wgt.flt_base = wgt.flight_time_elapsed or 0
    local ok, dt = pcall(getDateTime)
    wgt.flt_start = (ok and type(dt) == "table") and dt or nil
    wgt.flt_model = wgt.values.craft_name
end

-- Deferred flush (own cycle): CSV append + battery cycles/last-use stamp
function fltlog.flush(wgt)
    if not wgt.flt_open then return end
    wgt.flt_open = false
    local el = wgt.flight_time_elapsed or 0
    local base = wgt.flt_base or 0
    if el < base then base = 0 end   -- counter was reset mid-record (reconnect)
    local secs = math.floor((el - base) / 100 + 0.5)
    -- "Min. flight time": arm cycles below it (spool-up tests, arming checks) are no
    -- flight -- they neither reach the CSV nor burn a battery cycle. 0 = log every arm.
    if secs < (wgt.options.FltMinS or 0) or wgt.flt_start == nil then return end
    local fd = fltlog.load_data()
    if fd == nil then return end
    if (wgt.options.FltLog or 0) == 1 then
        -- per-flight statistics (FltStats): the SAME session min/max the stats view
        -- shows, snapshotted at disarm (accurate per flight when you disconnect between
        -- flights; several flights on one link accumulate, like the stats view itself).
        -- Appended as extra CSV columns; nil when off -> the classic 5-column line.
        local stats = nil
        if (wgt.options.FltStats or 0) == 1 then
            local v = wgt.values
            local hp = wgt.hs_profile_stats or {}
            local function hsv(p, k) local e = hp[p]; return e and e[k] or nil end
            stats = {
                mah      = (v.capa_max ~= nil) and math.floor(v.capa_max + 0.5) or nil,
                vcel_min = v.vcel_min,     vcel_max = v.vcel_max,
                hs1_min  = hsv(1, "min"),  hs1_max  = hsv(1, "max"),
                hs2_min  = hsv(2, "min"),  hs2_max  = hsv(2, "max"),
                hs3_min  = hsv(3, "min"),  hs3_max  = hsv(3, "max"),
                curr_min = v.curr_min,     curr_max = v.curr_max,
                tesc_min = v.esc_temp_min, tesc_max = v.esc_temp_max,
                vbec_min = v.vbec_min,     vbec_max = v.vbec_max,
                sags     = (v.sag_count ~= nil) and math.floor(v.sag_count + 0.5) or nil,
                sag_min  = v.sag_min,
            }
        end
        -- append_flight verifies the appended bytes landed (fstat) -- a false means
        -- the line was lost (full card); log it so the gap in flights.csv is explained
        local okf, resf = pcall(fd.append_flight, wgt.flt_start, wgt.flt_model or "", wgt.flt_batt_id or "", secs, stats)
        if not okf or resf ~= true then
            prof_log("flight line NOT logged (%s)", (not okf) and tostring(resf) or "append verify failed")
        end
    end
    -- one usage count per battery session, on the FIRST real flight (not on pick:
    -- a pick without a flight must not burn a cycle)
    if wgt.flt_batt_id ~= nil and wgt.flt_batt_counted ~= true then
        wgt.flt_batt_counted = true
        -- mark_used replaces batteries.cfg atomically; any failure exit leaves the
        -- user's file untouched and only skips this cycle count -- log it (DebugLog on)
        local ok, res = pcall(fd.mark_used, wgt.flt_batt_id, wgt.flt_start)
        if not ok or res ~= true then
            prof_log("mark_used skipped (id=%s, %s)", tostring(wgt.flt_batt_id),
                (not ok) and tostring(res) or "registry unchanged/atomic-replace failed")
        end
    end
end

-- Deferred battery-query open (own cycle): load the registry, filter for the
-- FC-set model name; no matching battery -> the page silently never opens
function fltlog.open_battpick(wgt)
    -- defense-in-depth: the request is gated on menu_view == nil when it is
    -- FLAGGED, but it executes a cycle later -- never stomp a page opened in between
    if wgt.menu_view ~= nil then return end
    local fd = fltlog.load_data()
    if fd == nil then return end
    local ok, reg = pcall(fd.load_registry)
    if not ok or type(reg) ~= "table" then return end
    local ok2, list = pcall(fd.for_model, reg, wgt.values.craft_name)
    if not ok2 or type(list) ~= "table" or #list == 0 then return end
    -- stable order (exactly as listed in batteries.cfg), no last-used marker or
    -- reordering -- the rows stay constant across connects, so you don't hit the
    -- wrong one when the last pack isn't the next one flown
    wgt.flt_batts = list
    wgt.menu_view = "battpick"
    init_view_state(wgt).dirty = true
end

-- Deferred open of the battery CREATE form from battpick's "+ New" (B11).
-- Own cycle like open_battpick itself (batted_req; the registry read for the
-- id prefill must not share a press callback's budget). models is preset to
-- the connected craft; after Save the pick list reloads through the existing
-- battpick_load_req path and the new pack appears at the end (stable order).
function fltlog.open_batted(wgt)
    if wgt.menu_view ~= "battpick" then return end
    local fb = fltlog.load_batted()
    local fd = fltlog.load_data()
    if fb == nil or fd == nil then return end
    local ok, reg = pcall(fd.load_registry)
    if not ok or type(reg) ~= "table" then reg = {} end
    local craft = wgt.values ~= nil and wgt.values.craft_name or nil
    local ok2 = pcall(fb.open, wgt, "create", {
        D = fd, reg = reg, craft = craft,
        known_models = (craft ~= nil and craft ~= "") and { craft } or {},
        preset_models = (craft ~= nil and craft ~= "") and { craft } or nil,
        return_to = "battpick",
        on_change = function(w) w.fb_saved = true end,
        on_close = function(w) w.fb_close_req = true end,
    })
    if not ok2 then return end
    wgt.menu_view = "tb_batted"
    init_view_state(wgt).dirty = true
end

-- ============================================================================
-- SWITCH SHORTCUTS ENGINE
-- ============================================================================
-- Methods on the `shortcut` table (data + labels declared near the top). Drives the
-- shortcut bindings (6 position slots + 2 toggle slots) from inside the 5 Hz pass.
-- Replaces the old single DvSrc/TbSrc auto-open blocks: every binding routes through
-- shortcut.open/close against shortcut.targets, so a switch can open ANY detail page or
-- Toolbox tool. Edge/hold triggered — never fights manual navigation (open/close only
-- act on the exact page THIS binding controls).

-- One debug-log line per shortcut ACTION or refusal, WITH the reason. The
-- 2026-08-16 field report -- "the switch did nothing, only a reboot helped" --
-- could have been a missed press, the menu gate, the fullscreen gate or a dead
-- loader, and the log could not tell them apart: none of the four left a trace.
-- Consecutive DUPLICATE lines are swallowed (a held position slot re-tries its
-- refused open every 5 Hz pass; one line says everything the repetition would).
-- Two DIFFERENT refusals alternating would defeat the dedup -- that takes two
-- switches held at once and is capped by the session file limit anyway.
shortcut.log = function(wgt, fmt, ...)
    local d = ultidash_functions.dbg
    if d == nil then return end
    local ok, s = pcall(string.format, fmt, ...)
    s = ok and s or fmt
    if s == wgt.sc_lastlog then return end
    wgt.sc_lastlog = s
    d.logf("SC", "%s", s)
end

-- Is THIS target the page currently showing? The predicate `shortcut.close` decides by
-- and the toggle slot resyncs its stage against (see shortcut.run). Identity, not
-- provenance: a page of the same id opened by another route counts as up.
function shortcut.is_up(wgt, tgt)
    if tgt == nil then return false end
    if tgt.kind == "detail" then return wgt.detail_view == tgt.id end
    if tgt.kind == "tool"   then return wgt.menu_view == tgt.id end
    if tgt.kind == "menu"   then return wgt.menu_view == "menu" end
    return false
end

-- Arm the ~2 s "needs full screen" banner on the dashboard (add_dashboard_overlays).
-- The fullscreen gate below is the one refusal a user cannot see the reason for: the
-- menu glyph does not exist in a layout zone, so there is nothing on screen to connect
-- the dead switch to. Every OTHER refusal here is either visible (a page is already up)
-- or has its own hint (the disarmed-only one, in the Toolbox page).
local function shortcut_fs_hint(wgt)
    wgt.sc_fs_hint = (getTime() or 0) + 200
end

-- Is a tool target actually available right now (module present / loadable)?
function shortcut.tool_ready(tgt)
    if tgt.id == "tb_adjmap" then return tb_load_adjmap() ~= nil end
    if tgt.id == "tb_adjed"  then return tb_load_adjed()  ~= nil end
    if tgt.id == "tb_livemon" then return livemon.load() ~= nil end
    if tgt.load == "logview" then return tb_load_logview() ~= nil end
    if tgt.load == "rf2cfg"  then return tb_load_rf2cfg()  ~= nil end
    if tgt.load == "rfscfg"  then return rfscfg.load()     ~= nil end
    if tgt.load == "fltlog"  then return fltlog.load_viewer() ~= nil end
    return true
end

-- Open a shortcut target. Mirrors the tap-open gating: a detail overlay opens only over
-- the flight view with nothing else up; a tool page honours the disarmed-only rule and
-- opens over the dashboard or the Toolbox hub. Returns true if it opened.
function shortcut.open(wgt, tgt, held)
    if not tgt or tgt.kind == "none" then return false end
    if tgt.kind == "action" then
        -- D3: audio needs no screen -- no fullscreen gate, no view gate, no armed
        -- gate (decided: it may speak in flight; precedence stays with the alerts).
        -- `held` comes from a position slot and arms the repeat loop.
        ultidash_functions.telemsay_start(wgt, held == true)
        shortcut.log(wgt, "start %s%s", tgt.id, held and " (hold)" or "")
        return true
    end
    if tgt.kind == "menu" then
        -- M2: the menu hub, on the glyph's own conditions -- fullscreen only (the glyph
        -- exists only there), nothing else up, and the SHARED armed rule.
        if lvgl.isFullScreen == nil or not lvgl.isFullScreen() then
            shortcut_fs_hint(wgt)
            shortcut.log(wgt, "open menu refused: not fullscreen")
            return false
        end
        if not (wgt.menu_view == nil and wgt.detail_view == nil and wgt.ovl_active == nil) then
            shortcut.log(wgt, "open menu refused: %s up",
                         wgt.menu_view or wgt.detail_view or "overlay")
            return false
        end
        if not shortcut.menu_allowed(wgt) then
            shortcut.log(wgt, "open menu refused: armed")
            return false
        end
        wgt.menu_view = "menu"
        init_view_state(wgt).dirty = true
        shortcut.log(wgt, "open menu")
        return true
    end
    if tgt.kind == "detail" then
        -- The same fullscreen gate the tool branch carries below, and for the same reason:
        -- the detail builders declare themselves fullscreen-only, and in a widget-grid zone
        -- the page renders into a box whose close hint ("tap anywhere") is dead, because a
        -- widget zone gets no touch. The menu-glyph and tap routes cannot reach this state
        -- at all -- both are fullscreen-only -- so a shortcut was the one way in.
        if lvgl.isFullScreen == nil or not lvgl.isFullScreen() then
            shortcut_fs_hint(wgt)
            shortcut.log(wgt, "open %s refused: not fullscreen", tgt.id)
            return false
        end
        -- nothing to open when the module did not load (see detail_load). Read off the
        -- instance, not off the module local: that local is declared further down the file
        -- and would be a global -- i.e. always nil -- from here.
        if not wgt.detail_ok then
            shortcut.log(wgt, "open %s refused: detail module not loaded", tgt.id)
            return false
        end
        if wgt.menu_view == nil and wgt.detail_view == nil
            and init_view_state(wgt).current == "flight" then
            wgt.detail_view = tgt.id
            -- the tap route resets this when it opens estatus; a shortcut-opened page used
            -- to inherit the scroll position of the last one and open part-scrolled
            if tgt.id == "estatus" then wgt.estatus_scroll = 0 end
            init_view_state(wgt).dirty = true
            shortcut.log(wgt, "open %s", tgt.id)
            return true
        end
        shortcut.log(wgt, "open %s refused: %s up", tgt.id,
                     wgt.menu_view or wgt.detail_view or "non-flight view")
        return false
    end
    -- tool page
    if tgt.disarmed and wgt.armed_now then
        wgt.lv_armed_hint = (getTime() or 0) + 200   -- ~2 s "disarmed only" hint
        shortcut.log(wgt, "open %s refused: armed", tgt.id)
        return false
    end
    -- Tool pages are FULLSCREEN UIs (lvgl.page / immediate fullscreen builds); opening
    -- one in normal widget mode builds a fullscreen page into the small widget zone —
    -- lvgl.page crashes ("attempt to index a nil value"), the Log Viewer flickers open
    -- then closes. The menu path can't hit this (the menu glyph is fullscreen-only), so
    -- mirror that guarantee here. Gated BEFORE tool_ready so we don't even lazy-load the
    -- module while not fullscreen. A held position re-fires once the user is fullscreen.
    if lvgl.isFullScreen == nil or not lvgl.isFullScreen() then
        shortcut_fs_hint(wgt)
        shortcut.log(wgt, "open %s refused: not fullscreen", tgt.id)
        return false
    end
    -- view gate BEFORE tool_ready: tool_ready lazy-LOADS the module, so with a bound
    -- switch held while another page is open it would load logview/rf2cfg every 5 Hz
    -- pass just to have the open refused below — the module stayed resident (GC drag)
    if not (wgt.menu_view == nil or wgt.menu_view == "toolbox") then
        shortcut.log(wgt, "open %s refused: %s up", tgt.id, wgt.menu_view)
        return false
    end
    if not shortcut.tool_ready(tgt) then
        -- the loader already logged WHY (fltlog.load_err) -- this line adds WHAT
        -- the user did to hit it
        shortcut.log(wgt, "open %s refused: tool not loadable", tgt.id)
        return false
    end
    -- The MSP gate, for the one target that writes to the flight controller
    -- Replicated from the tap dispatch, NOT relaxed:
    -- the tap requires disarmed AND wgt.rf.msp_allowed and re-reads before opening, because
    -- a picker opened on data cached at connect time shows the wrong active profile. Placed
    -- after every refusal above so refresh_data -- a real MSP read -- cannot run for an open
    -- that is then declined. Rule 1 of this project is no MSP while armed; the disarmed
    -- check above and this one are the two halves of it.
    if tgt.msp then
        if not (wgt.rf and wgt.rf.msp_allowed) then
            shortcut.log(wgt, "open %s refused: no MSP", tgt.id)
            return false
        end
        rf_service.refresh_data(wgt)
    end
    shortcut.log(wgt, "open %s", tgt.id)
    wgt.detail_view = nil                             -- tool pages own the whole screen
    -- a stale close request from an earlier shortcut-close of the SAME module would
    -- otherwise shut the fresh page in its first refresh (the module never saw the
    -- close, so the flag was never consumed)
    if tgt.id == "tb_logview" then wgt.lv_close_req = nil end
    if tgt.id == "tb_rf2cfg"  then wgt.rf2cfg_close_req = nil end
    if tgt.id == "tb_rfscfg"  then wgt.rfs_close_req = nil end
    if tgt.id == "tb_fltlog"  then wgt.fl_close_req = nil end
    -- RTN from a shortcut-opened tool goes STRAIGHT back to the dashboard — the
    -- user never navigated the menu, so there is no menu trail to unwind (opened
    -- from the Toolbox submenu, tool_back is "toolbox" and RTN returns there)
    wgt.tool_back = (wgt.menu_view == "toolbox") and "toolbox" or "dashboard"
    wgt.menu_view = tgt.id
    init_view_state(wgt).dirty = true
    return true
end

-- Close a shortcut target, but ONLY if that exact page is still the one showing (a
-- manually opened other page is left alone). Tool pages run the ONE shared close path
-- (close_tool_page): module close/cleanup, close-flag reset and lazy-module ref release
-- for GC (boot-resident modules measurably drag the whole UI, see the lazy-load design).
function shortcut.close(wgt, tgt)
    if not tgt then return end
    if tgt.kind == "action" then
        -- leaving the held position ends the REPEAT; a running report finishes
        ultidash_functions.telemsay_release(wgt)
        shortcut.log(wgt, "release %s", tgt.id)
        return
    end
    if tgt.kind == "menu" then
        -- only the HUB is closed -- a user who navigated deeper from it keeps the page
        if wgt.menu_view == "menu" then
            wgt.menu_view = nil
            init_view_state(wgt).dirty = true
            shortcut.log(wgt, "close menu")
        end
        return
    end
    if tgt.kind == "detail" then
        if wgt.detail_view == tgt.id then
            wgt.detail_view = nil
            init_view_state(wgt).dirty = true
            shortcut.log(wgt, "close %s", tgt.id)
        end
    elseif tgt.kind == "tool" then
        if wgt.menu_view == tgt.id then
            close_tool_page(wgt)
            wgt.menu_view = nil
            init_view_state(wgt).dirty = true
            shortcut.log(wgt, "close %s", tgt.id)
        end
    end
end

--- Evaluate all switch-shortcut bindings. Called once per 5 Hz pass.
function shortcut.run(wgt)
    local opts = wgt.options
    if opts == nil then return end
    local now = getTime() or 0
    local delay_cs = math.floor((opts.SwDelay or 300) / 10)   -- ms -> centiseconds
    local st = wgt.sc_state
    if st == nil then st = { pos = {}, tg = {} }; wgt.sc_state = st end
    local targets = shortcut.targets

    -- 6 POSITION slots: hold-to-open. The picked value is a swsrc switch POSITION
    -- (native picker); getSwitchValue says whether it is held. The stability delay is
    -- per slot: whenever the active-state flips the timer restarts, so a quick pass
    -- through the position on the way elsewhere never satisfies the delay. Leaving the
    -- position closes at once.
    for i = 1, 6 do
        local sw  = opts["Sc" .. i .. "Sp"] or 0
        local tgt = targets[opts["Sc" .. i .. "Tgt"] or 1] or targets[1]
        local s = st.pos[i]
        if s == nil then s = {}; st.pos[i] = s end
        if sw == 0 or tgt.kind == "none" then
            if s.opened then shortcut.close(wgt, s.tgt); s.opened = false end
            s.pos = nil
        else
            local cur = ultidash_functions.swpos_active(sw)
            if cur ~= s.pos then s.pos = cur; s.since = now end   -- state changed: restart delay
            if cur then
                if not s.opened and (now - (s.since or now)) >= delay_cs then
                    -- held=true: a position slot's action target (D3) repeats while held
                    if shortcut.open(wgt, tgt, true) then s.opened = true; s.tgt = tgt end
                end
            elseif s.opened then
                shortcut.close(wgt, s.tgt); s.opened = false
            end
        end
    end

    -- 2 TOGGLE slots: each rising edge of the switch steps to the next non-Off option,
    -- then closes after the last. The chain is rebuilt on each press so a settings change
    -- takes effect immediately; shortcut.close only touches the page this toggle opened.
    for j = 1, 2 do
        local sw = opts["Tg" .. j .. "Sp"] or 0
        local s = st.tg[j]
        if s == nil then s = { stage = 0 }; st.tg[j] = s end
        if sw == 0 then
            if (s.stage or 0) >= 1 and s.list then shortcut.close(wgt, s.list[s.stage]) end
            s.stage = 0; s.prev = nil; s.list = nil
        else
            -- RESYNC before the edge is read. `s.stage` used to be reset ONLY by
            -- shortcut.close, i.e. only by a press of THIS switch -- so RTN, a tap and the
            -- arm-close each shut the page and left the counter standing. The next press
            -- then meant "close what is already closed": with a one-option chain it stepped
            -- past the end and opened NOTHING (every other flick dead), and with a longer
            -- one it opened the option AFTER the page the user had just left. Reported from
            -- the field as "the switch does not always open the Log Viewer", and reproduced
            -- under measurement. Cheap: two table reads on a slot that is not at stage 0.
            if (s.stage or 0) >= 1
                and not shortcut.is_up(wgt, s.list and s.list[s.stage]) then
                s.stage = 0
                shortcut.log(wgt, "tg%d resync: page closed elsewhere", j)
            end
            local on = ultidash_functions.swpos_active(sw)
            if s.prev == nil then
                -- first evaluation of this slot: SEED the edge detector without firing.
                -- A maintained switch already sitting "on" at boot (or right after
                -- binding the slot) is not a press and must not auto-open --
                -- analogous to the position slots' delay restart.
                s.prev = on
            elseif on and not s.prev then
                if (s.stage or 0) >= 1 and s.list and s.list[s.stage] then
                    shortcut.close(wgt, s.list[s.stage])      -- close current before advancing
                end
                local list = {}
                for k = 1, 4 do
                    local tgt = targets[opts["Tg" .. j .. "O" .. k] or 1] or targets[1]
                    if tgt.kind ~= "none" then list[#list + 1] = tgt end
                end
                s.list = list
                local nx = (s.stage or 0) + 1
                if nx > #list then nx = 0 end                 -- past the last option: closed
                s.stage = nx
                -- the press itself, BEFORE the open (whose own line then says what
                -- came of it) -- a press that opens nothing is otherwise invisible
                shortcut.log(wgt, "tg%d press: stage %d/%d", j, nx, #list)
                if nx >= 1 and not shortcut.open(wgt, list[nx]) then
                    s.stage = 0                               -- open refused (e.g. armed tool): stay closed
                end
            end
            s.prev = on
        end
    end
end



-- Small one-line warning banner drawn as build-table primitives (rule 7: never lvgl.box in
-- fullscreen -- it keeps LV_OBJ_FLAG_CLICKABLE and would swallow taps). Reactive `visible_fn`
-- toggles it. Shared by the "settings not saved" warning here and (later) the dual-dashboard
-- warning; callers pass distinct y values so two active banners never overlap.
local function add_warn_banner(panel, w, y, text, visible_fn)
    local bh = measure_font(STDSIZE) + 4
    local bx = math.floor(w * 0.06)
    local bw = math.max(1, w - 2 * bx)
    panel:build({
        { type = "rectangle", x = bx, y = y, w = bw, h = bh, filled = true, rounded = 4,
          color = COLOR_THEME_WARNING, visible = visible_fn },
        { type = "label", x = bx + 4, y = y + 2, w = bw - 8, h = bh, text = text, font = STDSIZE,
          color = COLOR_THEME_PRIMARY2, align = CENTER, visible = visible_fn },
    })
end

-- Reactive visibility for the "a shortcut was refused because we are not full screen"
-- banner (~2 s, armed in shortcut_fs_hint). Unlike the three below it this one is about a
-- state the LAYOUT ZONE is in, which is exactly where the user has no menu glyph to ask.
local function sc_fs_hint_visible(wgt)
    return function() return (wgt.sc_fs_hint or 0) > (getTime() or 0) end
end
-- Reactive visibility for the SD-write-failed warning banner (sticky ~10 s after a failed
-- settings save/reset; see save_pending_settings / reset_defaults).
local function save_failed_visible(wgt)
    return function() return (wgt.cfg_save_failed_until or 0) > (getTime() or 0) end
end
-- Reactive wording for it: the mid-edit discard names its cause; every
-- other setter clears cfg_save_failed_text back to the default SD-write wording.
local function save_failed_text(wgt)
    return function() return wgt.cfg_save_failed_text or "Settings NOT saved (SD write failed)" end
end

-- Reactive visibility for the two-Dashboard-instances warning (sticky ~5 s past the last
-- foreign publish; set in publish_shared when a second publisher is detected).
local function dual_publisher_visible(wgt)
    return function() return (wgt.dual_publisher_until or 0) > (getTime() or 0) end
end

-- Reactive visibility for the failed-skin warning: the user chose a skin other than the
-- default and it is either unknown on this card (SKINS holds no row for the stored id --
-- skin_reg_for silently substitutes the default row, so the id itself has to be looked up)
-- or it was rejected at load time (reg.failed, set in skin_load). Plain field reads only;
-- discovery is always finished before a dashboard builds, so an empty SKINS cannot make
-- this fire.
local function skin_failed_visible(wgt)
    return function()
        local id = wgt.options and wgt.options.Skin
        if id == nil or id == "default" then return false end
        -- wgt.skin_build_failed: a builder that RAISED on this build (see skin_build).
        -- Per instance and not sticky on the registry row, because a build can raise on a
        -- data state rather than on its code -- the same reasoning the detail hooks carry.
        if wgt.skin_build_failed then return true end
        local reg = SKINS[id]
        return reg == nil or reg.failed == true
    end
end

-- ============================================================================
-- SKIN SYSTEM (stage 2): the flight/stats LAYOUT lives in a swappable skin module
-- (skins/<id>.lua). The host owns the component library (the build_*_panel / bar
-- builders above), the palette, touch dispatch and the safety overlays; a skin only
-- arranges the components and returns its root panel. skins/default.lua is the
-- built-in look AND the fallback. The contract is docs/SKINS.md.
-- ============================================================================

-- Live theme snapshot handed to the active skin (reused table; the host mutates its
-- fields in update() before each build, a skin reads them at build time). A full
-- rebuild happens on every palette/scheme change, so a value snapshot is always current.
-- `sem` is a LIVE reference to the shared semantic table (set_palette mutates it in
-- place): traffic-light green/yell/red/neut + bar_*/vtx_*/st_* — see set_palette.
-- public skin tap-zone name -> the host wgt rect field refresh() dispatches to a detail
-- page (see the tap block in refresh). Keeps skin code decoupled from internal names.
-- "menu" lets a skin that draws its own header put the SETTINGS BUTTON where it likes:
-- the host hit-tests wgt.settings_icon_rect first and falls back to the fixed top-left
-- corner region (menu_tap_rect) when no skin/top bar set one.
-- status_up / status_down are the ESC event log's paging buttons. They go through set_tap
-- like everything else so a skin that draws the Status log itself can put them where its
-- layout wants -- and so a collision or a typo lands on the contract that already reports
-- both. The host builder assigns these two fields directly, as it does the others.
local SKIN_TAP_KEYS = { battery = "battery_rect", values = "values_rect",
                        status = "estatus_rect", elrs = "elrs_bar_rect",
                        battprofile = "battprofile_rect", menu = "settings_icon_rect",
                        status_up = "estatus_scroll_up", status_down = "estatus_scroll_down" }
local skin_theme = { panel_bg = PANEL_BG, force_bg_fill = false,
                     primary1 = COLOR_THEME_PRIMARY1, primary2 = COLOR_THEME_PRIMARY2,
                     secondary1 = COLOR_THEME_SECONDARY1, focus = COLOR_THEME_FOCUS,
                     warning = COLOR_THEME_WARNING, disabled = COLOR_THEME_DISABLED,
                     dim = COLOR_DIM, track = COLOR_TRACK, tick = COLOR_TICK,
                     sem = SEM }

-- The skin API (env) handed to every skin at init: the host-owned component library +
-- font/measure helpers + set_header (feeds the panels' header font/height) + set_tap
-- (registers a detail-page touch zone) + the theme snapshot + card_gap. Built once,
-- shared by all skins (they all render against the same host).
local skin_env = nil
local function skin_env_build()
    if skin_env ~= nil then return skin_env end

    -- ------------------------------------------------------------------------------------
    -- HOST THRESHOLD SERVICE. Three skins were describing the
    -- same thresholds against the same host values, each in its own file, and the cell scale
    -- already existed twice in code -- they drift the moment a key is renamed. The table
    -- lives here because only the host has the name-keyed 5 Hz cache and knows the rebuild
    -- triggers; a shared skin file would still be a copy of host knowledge.
    --
    -- EVERYTHING below is function-scope on purpose. The main chunk sits at ~198 of Lua's
    -- 200 locals (see the notes at the top of this file), so the service may not spend a
    -- single one; skin_env_build runs exactly once, so these closures are as good as
    -- module-level and cost nothing at load.
    --
    -- BOUNDARY CONVENTION: `v <= crit` is critical, `v <= warn` is warning -- the alert
    -- engine's rule (update_link_warning). The alert engine is what speaks to the pilot, and
    -- a bar reading green while the voice says critical is the confusing direction.
    -- O5, CLOSED: the top bar (`v <`) and the ELRS detail page (`v >= warn` green) were the
    -- two dissenters and now follow this rule too, so a skin-built ELRS page no longer
    -- differs from the host-built one at a value exactly equal to a threshold.
    -- One divergence survives on purpose: the `> 0` guards below mean 0 = "step disabled"
    -- for the shared rows (the temperature keys use it that way), while the alert engine
    -- has no such guard and would announce critical at a value of 0 with crit = 0.
    -- ------------------------------------------------------------------------------------
    local thr_rows = nil
    -- The rows whose value has NO host field and NO other producer -- the only ones that
    -- cost a 5 Hz read, and only while something asks for them. Note what is NOT here:
    -- RQly / TQly / RSSI / TPWR look like unmapped sensor names (they are absent from
    -- SENSOR_VALUE_FIELD) but the ELRS pass fills wgt.values for them, so deriving the pull
    -- list from that table instead of stating it would have bought four useless reads per
    -- pass. Tmcu is the one real case: mcu_temp_max is max-only, so nothing fetches it.
    local thr_pull = { Tmcu = true }

    -- The raw number behind a sensor name: the same two sources sensor_value_text reads,
    -- minus the formatting -- the curated/latched field first, the 5 Hz name cache second.
    -- No third value path, deliberately.
    local function thr_num(wgt, name)
        local f = SENSOR_VALUE_FIELD[name]
        local v
        if f ~= nil then v = wgt.values[f] end
        if v == nil then
            local c = wgt.values.user_sensors
            v = c ~= nil and c[name] or nil
        end
        return v
    end

    -- percent of a build-time scale. Keeps NO DATA (nil) apart from a real zero: a caller
    -- must draw a track without fill for nil, and callers may not coalesce it to 0.
    local function thr_pct(v, lo, hi)
        if v == nil or hi == nil or lo == nil or hi <= lo then return nil end
        local p = 100 * (v - lo) / (hi - lo)
        if p < 0 then return 0 end
        if p > 100 then return 100 end
        return p
    end

    -- the two colour rules, as closures over build-time thresholds. `warn` of 0 or nil means
    -- "no warning step" (the temperature keys use 0 for off); nil value -> green, which is
    -- invisible anyway because pct() is nil and nothing is filled.
    local function thr_color_low(getn, warn, crit)
        return function()
            local v = getn()
            if v == nil then return SEM_GREEN end
            if crit ~= nil and crit > 0 and v <= crit then return SEM_RED end
            if warn ~= nil and warn > 0 and v <= warn then return SEM_YELL end
            return SEM_GREEN
        end
    end
    local function thr_color_high(getn, warn, crit)
        return function()
            local v = getn()
            if v == nil then return SEM_GREEN end
            if crit ~= nil and crit > 0 and v >= crit then return SEM_RED end
            if warn ~= nil and warn > 0 and v >= warn then return SEM_YELL end
            return SEM_GREEN
        end
    end

    -- tick positions in scale-%, snapshot at build time like the scale itself
    local function thr_marks(warn, crit, lo, hi)
        local c = thr_pct(crit, lo, hi)
        if c == nil then return nil end
        return { c, thr_pct((warn ~= nil and warn > 0) and warn or nil, lo, hi) }
    end

    -- assemble a bundle. `color` may be handed in ready-made for the two sources the host
    -- already colours (T9): wrapping an existing closure in another closure is the
    -- "number expected, got function" lvgl build error.
    local function thr_bundle(getn, lo, hi, warn, crit, high_bad, off, color)
        return {
            num   = getn,
            pct   = function() return thr_pct(getn(), lo, hi) end,
            color = color or (high_bad and thr_color_high(getn, warn, crit)
                                       or  thr_color_low(getn, warn, crit)),
            marks = thr_marks(warn, crit, lo, hi),
            off   = off == true,
        }
    end

    -- The cell-voltage scale, in one place at last: it existed verbatim in two skin files.
    -- The `full <= alarm` guard is carried by both of those copies and stays.
    local function thr_cell_scale(wgt)
        local v = wgt.values
        local alarm = v.vcel_alarm_threshold()
        local warn  = v.vcel_warning_threshold()
        local full  = v.vcel_full_threshold()
        if alarm == nil or full == nil then return nil end
        if full <= alarm then full = alarm + 0.5 end
        return alarm - 0.15, full + 0.10, warn, alarm
    end

    -- One constructor per sensor name the pickers can store. Built LAZILY on the first
    -- threshold_for call, never at module load: create() has no room to spare.
    local function thr_table()
        if thr_rows ~= nil then return thr_rows end
        thr_rows = {
            ["~escl"] = function(wgt)
                local o = wgt.options
                local crit = o.EscCrit or 100
                -- esc_load_color(wgt) ALREADY returns the reactive closure -- handed through
                return thr_bundle(function() return wgt.values.esc_load_pct end,
                    0, crit * 1.15, o.EscWarn or 80, crit, true,
                    o.EscMon ~= 1, esc_load_color(wgt))
            end,
            Tesc = function(wgt)
                local o = wgt.options
                local crit = o.TescCrit or 0
                return thr_bundle(function() return wgt.values.esc_temp end,
                    0, (crit > 0) and crit * 1.15 or nil, o.TescWarn or 0, crit, true,
                    crit <= 0)
            end,
            -- Tmcu has no host field at all (mcu_temp_max is max-only), so it is the row the
            -- pull registration exists for: threshold_for asks the 5 Hz pass to fetch it.
            Tmcu = function(wgt)
                local o = wgt.options
                local crit = o.TmcuCrit or 0
                return thr_bundle(function() return thr_num(wgt, "Tmcu") end,
                    0, (crit > 0) and crit * 1.15 or nil, o.TmcuWarn or 0, crit, true,
                    crit <= 0)
            end,
            Vcel = function(wgt)
                local lo, hi, warn, alarm = thr_cell_scale(wgt)
                return thr_bundle(function() return wgt.values.vcel end,
                    lo, hi, warn, alarm, false, false)
            end,
            -- the pack scale is the cell scale times the cell count. Snapshot, like every
            -- other scale here: a cell count that changes without a rebuild leaves the
            -- bundle stale (the spec's O2, unchanged from what both skin copies do today).
            Vbat = function(wgt)
                local v = wgt.values
                local n = v.cel_count or v.rf_battery_cell_count
                local lo, hi, warn, alarm = thr_cell_scale(wgt)
                if n == nil or lo == nil then
                    -- no cell count is NO DATA, not "off": track without fill
                    return thr_bundle(function() return v.vbat end, nil, nil, nil, nil,
                        false, false)
                end
                return thr_bundle(function() return v.vbat end,
                    lo * n, hi * n, warn * n, alarm * n, false, false)
            end,
            -- The SENTINEL, and it is the pick a skin is most likely to store: the free
            -- sensor slots offer "Voltage (auto)" and a bar set to it drew its headline over
            -- an empty track, because the table had Vcel and Vbat and not the name in the
            -- cfg. No decision is re-made here -- the host already resolves the sentinel for
            -- slot.num (VoltageDisplay == 2 -> pack, else cell), and this follows exactly
            -- that switch, so the bundle and the slot can never disagree. Resolving it
            -- skin-side would re-decide which of the two the host meant, i.e. the very
            -- duplication this service exists to end.
            -- thr_rows (not thr_table()) is safe: the constructor's assignment completes
            -- before any row can be called, and it saves the re-entry.
            ["~volt"] = function(wgt)
                return thr_rows[(wgt.options.VoltageDisplay == 2) and "Vbat" or "Vcel"](wgt)
            end,
            ["Bat%"] = function(wgt)
                -- capa_bar_color is a plain colour FIELD refreshed by the 5 Hz pass, not a
                -- closure -- so it needs a getter around it, which is not double-wrapping.
                return thr_bundle(function() return wgt.values.capa_percent end,
                    0, 100, nil, nil, false, false,
                    function() return wgt.values.capa_bar_color end)
            end,
            RQly = function(wgt)
                local o = wgt.options
                return thr_bundle(function() return wgt.values.elrs_rq end,
                    0, 100, o.RQlyWarn or 80, o.RQlyCrit or 50, false, false)
            end,
            -- TQly deliberately shares the RQly key pair: there is no TQly pair anywhere in
            -- the settings, and both the host and Cockpit already treat them as one.
            TQly = function(wgt)
                local o = wgt.options
                return thr_bundle(function() return wgt.values.elrs_tq end,
                    0, 100, o.RQlyWarn or 80, o.RQlyCrit or 50, false, false)
            end,
            RSSI = function(wgt)
                local o = wgt.options
                -- the BETTER antenna while diversity is active, mirroring
                -- update_rssi_warning: the voice already speaks for the stronger of the
                -- two, and reading antenna 1 alone made a skin's bar go red while the
                -- voice stayed silent -- on a link that was fine. This service exists so
                -- the bar and the word cannot disagree.
                return thr_bundle(function()
                        local p = wgt.values.elrs_r1_pct
                        if wgt.values.elrs_diversity and wgt.values.elrs_r2_pct then
                            p = math.max(p or 0, wgt.values.elrs_r2_pct)
                        end
                        return p
                    end,
                    0, 100, o.RssWarn or 15, o.RssCrit or 8, false, false)
            end,
            -- TPWR's SCALE is configured (TxPwrMax) but its colour rule is not: 60 % and
            -- 85 % OF THE SCALE, written as literals in the ELRS page. Carried across as-is
            -- rather than promoted to two new option keys, which nobody asked for.
            TPWR = function(wgt)
                local m = wgt.options.TxPwrMax or 0
                if m <= 0 then
                    return thr_bundle(function() return wgt.values.elrs_tpwr end,
                        nil, nil, nil, nil, true, true)
                end
                return thr_bundle(function() return wgt.values.elrs_tpwr end,
                    0, m, m * 0.60, m * 0.85, true, false)
            end,
        }
        return thr_rows
    end

    skin_env = {
        top_bar       = build_top_bar_element,
        status_bar    = build_status_bar_element,
        fuel_gauge    = build_vertical_fuel_gauge_element,
        flight_values = build_flight_values_panel,
        flight_status = build_flight_status_panel,
        stats_table   = build_flight_statistics_element,
        select_font   = select_font,
        measure_font  = measure_font,
        set_header    = function(f, h) header_font = f; header_h = h end,
        -- clean public tap-zone names -> the host's internal rect fields (refresh()
        -- dispatches these to the detail pages). ONE RECT PER ZONE, LAST WRITER WINS:
        -- update() nils every rect before each rebuild, so a second set_tap on the same
        -- zone within one build silently discarded the first (the Cockpit defect the
        -- simulator saw as "a tap that moved 0 pixels"). Both failure modes now say so:
        -- an unknown zone name (a typo made a dead zone with zero evidence) and an
        -- overwrite. Build-time only, and the concatenations run on the failure paths
        -- alone. The host's own panels assign the fields directly, so no exemption is
        -- needed here; a skin that deliberately overrides a host-set rect logs once per
        -- rebuild, which is accepted. See docs/SKINS.md §8.
        set_tap       = function(w, name, r)
            local key = SKIN_TAP_KEYS[name]
            if key == nil then
                ultidash_functions.log("set_tap: unknown zone '" .. tostring(name) .. "'")
                return
            end
            if w[key] ~= nil then
                ultidash_functions.log("set_tap: zone '" .. name .. "' set twice - last wins")
            end
            w[key] = r
        end,
        -- The page-close control for a FULL-SCREEN page: draws the "X" in the top-right
        -- corner of `panel` (a `w`-wide page) and registers its tap rect. Returns the
        -- width it occupies, so the caller can keep its header text out of it.
        -- SINCE 0.8.0 THIS IS THE ONLY WAY A DETAIL PAGE CLOSES BY TOUCH -- the tap
        -- anywhere that used to close it is gone (it was invisible, and it made tap
        -- zones on those pages impossible). A skin that overrides a detail page and
        -- does NOT call this builds a page the pilot can only leave with RTN.
        -- See docs/SKINS.md.
        close_button  = function(panel, wgt, w)
            local cx, csz = ultidash_functions.close_control(panel, w - 8, 6,
                COLOR_THEME_SECONDARY1, COLOR_THEME_PRIMARY1)
            -- generous on purpose: the glyph is small and the corner is the one place
            -- nothing else can be hit, so the rect covers the whole corner
            wgt.close_rect = { x = cx - 8, y = 0, w = csz + 16, h = csz + 14 }
            return csz + 16
        end,
        -- A render-ready threshold bundle for a sensor name, or nil when the name is not in
        -- the host table (the caller then renders as it does today). Thresholds and the
        -- scale are snapshot HERE, at build time; the value getters are per-frame. That is
        -- the contract both existing skin copies already followed, so nothing moves.
        -- Signature is (wgt, name), not the spec's (name): the thresholds live on
        -- wgt.options and the values on wgt.values, and this matches sensor_slot(wgt, key).
        threshold_for = function(wgt, name)
            local mk = thr_table()[name]
            if mk == nil then return nil end
            -- Pull registration: the 5 Hz cache only carries what something asked for, so a
            -- Tmcu ring is possible for the first time. Deduped within the list only -- a
            -- name also reachable through a sensor slot costs nothing extra, because
            -- read_src caches per name per tick and the second read is a cache hit.
            if thr_pull[name] then
                local ex = SKINS._extra_names
                if ex == nil then ex = {}; SKINS._extra_names = ex end
                local seen = false
                for i = 1, #ex do
                    if ex[i] == name then seen = true; break end
                end
                if not seen then ex[#ex + 1] = name end
            end
            return mk(wgt)
        end,
        theme         = skin_theme,
        card_gap      = card_gap,
        -- the host's standard three scheme descriptors: the default skin declares
        -- M.schemes = env.standard_schemes (they stay host-side as the ultimate
        -- fallback + the menu-neutral rendering needs the EdgeTX-theme descriptor
        -- even when no skin file loads)
        standard_schemes = SCHEMES,
        -- Sensor slot resolver: a skin declares kind="sensor" rows in M.items (real
        -- pickers, incl. Voltage-auto / ESC-load-calc / raw picks, persisted as the
        -- sensor name); this turns a stored slot key into a render-ready descriptor,
        -- mirroring the built-in Tele Main panel. Returns nil for an "Off" slot.
        --   .label  short label (string, or a getter for Voltage-auto's cell/pack label)
        --   .value  reactive value-text closure
        --   .unit   unit string ("V"/"A"/"°C"/…) or ""
        --   .color  a colour value/closure, or nil (default text colour)
        -- Beyond the four original fields the descriptor also carries (all ADDITIVE, the
        -- built-in skins ignore them):
        --   .label_short  the catalog's compact caption (SENSOR_INFO.cap) for narrow cards
        --   .unit_raw     the unit REGARDLESS of Display ▸ Units beside values — that option
        --                 trades the unit against the VALUE's font size, which does not apply
        --                 when a skin puts the unit in a caption row
        --   .min_formatted / .max_formatted  the EdgeTX session extrema of this sensor,
        --                 memoized; nil for sensors that have none (the ESC-load calc).
        --                 They only carry data while the skin opted in with
        --                 M.wants_extrema (the 5 Hz pass then fetches them, see
        --                 update_user_sensors) — otherwise they read "-".
        sensor_slot = function(wgt, key)
            local name = wgt.options and wgt.options[key]
            if is_off_sensor(name) then return nil end
            -- units follow the ACTIVE SKIN's own units key since 0.8.0 (the host key when
            -- it declares none), so a skin that renders `.unit` (Cockpit, Grid) decides
            -- for its own layout instead of inheriting a Display option meant for a
            -- different one. `.unit_raw` below is unaffected, by design.
            local units_on = (wgt.options[SKINS._units_key or "ShowUnits"] == 1)
            if name == VOLT_AUTO then
                return { name = name, label = wgt.values.display_voltage_label_short,
                         -- short form of the same live label: "Cell"/"Batt", "Buffer" while
                         -- main power is lost (memoized on the long label's text)
                         label_short = memo_text(wgt.values.display_voltage_label_short,
                             function(t)
                                 if t == "Cell Voltage" then return "Cell" end
                                 if t == "Batt Voltage" then return "Batt" end
                                 return t or ""
                             end),
                         unit = units_on and "V" or "", unit_raw = "V",
                         value = wgt.values.display_voltage_formatted,
                         color = wgt.values.display_voltage_color,
                         -- the NUMBER behind display_voltage_formatted. Same switch the
                         -- formatted string follows -- ultidashValues keeps it as a private
                         -- local (use_total_voltage_display), and it is exactly this option
                         -- read, so the test is repeated rather than a field invented.
                         num = function()
                             if wgt.options.VoltageDisplay == 2 then return wgt.values.vbat end
                             return wgt.values.vcel
                         end,
                         min_formatted = wgt.values.display_voltage_min_formatted,
                         max_formatted = wgt.values.display_voltage_max_formatted }
            end
            -- esc_load_color(wgt) ALREADY returns the reactive colour closure (not a
            -- colour) — hand it straight to the value's `color` (double-wrapping it in
            -- another function made the label's colour resolve to a function -> lvgl
            -- build "number expected, got function")
            local color
            if name == ESCL_AUTO then color = esc_load_color(wgt) end
            local info = SENSOR_INFO[name]
            local slot = { name = name, label = sensor_short_label(name),
                     label_short = (info and (info.cap or info.lbl)) or sensor_short_label(name),
                     unit = units_on and sensor_unit(name) or "",
                     unit_raw = (name == ESCL_AUTO) and "%" or sensor_unit(name),
                     value = sensor_value_text(wgt, name), color = color,
                     -- the raw number beside the formatted string, so a bar, a card or a
                     -- ring can consume a free sensor pick numerically. Same two sources
                     -- sensor_value_text reads, minus the formatting; nothing to memoize,
                     -- because it returns a number rather than building a string.
                     num = function() return thr_num(wgt, name) end }
            -- session extrema: EdgeTX tracks them per sensor ("<name>-" / "<name>+"), the
            -- 5 Hz pass caches them. The computed ESC-load has none.
            if name ~= ESCL_AUTO then
                local fmt = "%." .. sensor_dec(name) .. "f"
                slot.min_formatted = memo_text(
                    function() local t = wgt.values.user_sensors_min; return t and t[name] end,
                    function(x) return x and string.format(fmt, x) or "-" end)
                slot.max_formatted = memo_text(
                    function() local t = wgt.values.user_sensors_max; return t and t[name] end,
                    function(x) return x and string.format(fmt, x) or "-" end)
            end
            return slot
        end,
        -- a detail-page tap zone by public name (battery/values/status/elrs/battprofile)
        -- battprofile opens the FC battery-profile picker (disarmed only) — the same
        -- gate as the default skin's B-Profile field.
        -- the host component builders below are the "component library"; card/stacked
        -- are the small primitives the panels use, exposed for free-form skins
        card          = build_card_element,
        stacked_field = add_stacked_field,
        -- contrast helpers: a skin cannot compute luminance itself (the colour value is an
        -- opaque RGB565 int), so it cannot decide "black or white ink on this fill".
        -- is_dark(c) uses the same threshold as the host's own ink decisions.
        is_dark = function(c) return color_luma(c) < DARK_LUMA_THRESHOLD end,
        ink_on  = function(c) return (color_luma(c) < DARK_LUMA_THRESHOLD) and WHITE or BLACK end,
        -- ------------------------------------------------------------------------------
        -- DETAIL-PAGE EXTRAS. ultidashDetail.lua gets THIS object, not a parallel one --
        -- deliberately, so that when a skin may override a detail page the host fallback
        -- is literally "call the host module with the same env". The set is bounded and was
        -- inventoried from the four builders rather than guessed: they need raw luminance
        -- (the battery page's ink decision is a two-colour test that is_dark/ink_on cannot
        -- express), the memo helper, the sensor catalogue readers, and the two sentinel
        -- names. The sensor helpers are PASSED rather than reimplemented: they close over
        -- the host's catalogue and palette upvalues, and a second copy of any of them would
        -- be a second answer to "what does this sensor read".
        -- Not documented in docs/SKINS.md as public API yet -- that happens with the
        -- detail-page hooks, which are what make them useful to a skin.
        color_luma            = color_luma,
        DARK_LUMA_THRESHOLD   = DARK_LUMA_THRESHOLD,
        memo_text             = memo_text,
        sensor_short_label    = sensor_short_label,
        sensor_unit           = sensor_unit,
        sensor_value_text     = sensor_value_text,
        sensor_value_text_raw = sensor_value_text_raw,
        sensor_minmax_text    = sensor_minmax_text,
        sensor_test_text      = sensor_test_text,
        is_off_sensor         = is_off_sensor,
        esc_load_color        = esc_load_color,
        ultidash_functions    = ultidash_functions,
        VOLT_AUTO             = VOLT_AUTO,
        ESCL_AUTO             = ESCL_AUTO,
        DETAIL_SLOT_KEYS      = DETAIL_SLOT_KEYS,
    }
    return skin_env
end

-- The four detail pages live in ultidashDetail.lua. EAGERLY loaded (in create()), unlike
-- the menu module: a detail page opens on a tap that can happen in flight, and a loadScript
-- hitch there would be felt. Its env is skin_env, extras included -- see the block above.
local ultidash_detail = nil
local function detail_load()
    if ultidash_detail ~= nil then return ultidash_detail end
    local ok, m = pcall(function() return loadScript(script_dir .. "ultidashDetail.lua")() end)
    -- The acceptance check is what makes "detail pages disabled" a soft failure, so it has
    -- to cover the whole contract the host later relies on -- set_theme is called every
    -- rebuild and init is called right here. Both were taken on trust, so a module that
    -- loaded but was not this module (a partial deploy, the only way here) killed the
    -- widget at the one moment the log line promises it will not. Same shape as skin_load.
    local why
    if not ok then why = "load error: " .. tostring(m)
    elseif type(m) ~= "table" then why = "module is not a table"
    elseif type(m.build) ~= "function" then why = "build missing"
    elseif type(m.init) ~= "function" then why = "init missing"
    elseif type(m.set_theme) ~= "function" then why = "set_theme missing"
    else
        local iok, ierr = pcall(m.init, skin_env_build())
        if not iok then why = "init error: " .. tostring(ierr) end
    end
    if why ~= nil then
        ultidash_functions.log("ultidashDetail.lua " .. why .. " - detail pages disabled")
        return nil
    end
    ultidash_detail = m
    return m
end

-- Load a skin module BY REGISTRY ID (lazy, cached per id). Each id is loaded at most
-- once per session — success caches the module, failure caches `false` so a broken/
-- missing skin never re-runs loadScript every frame. Accepts only a well-formed,
-- API-compatible module whose init() doesn't raise; a broken/absent skin must NEVER
-- crash the widget Lua state (pcall around load + init).
-- On success the skin's MANIFEST (M.schemes / M.items / M.scheme_key / M.def_scheme,
-- declared in the skin file — skins are self-contained) is attached onto its registry
-- row, where the defaults walk, the menus and the palette resolution read it.
-- Modules stay cached/resident: skins are small by rule (see docs/SKINS.md) — unlike
-- the Toolbox tools, which are lazy-loaded AND dropped for good GC reasons.
local skin_cache = {}   -- id -> module (ok) | false (tried & failed)
local function skin_load(id)
    local reg = SKINS[id] or SKINS.default
    local cached = skin_cache[reg.id]
    if cached ~= nil then return cached or nil end
    local env = skin_env_build()
    local ok, m = pcall(function() return loadScript(script_dir .. reg.file)() end)
    -- The acceptance check is UNROLLED so the rejection can name its reason. Collapsed
    -- into one `and` chain it could only say "no skin", which is unrecoverable even
    -- locally: six distinct failures all read as "the dashboard is unchanged". The cost
    -- is paid only on the failure path — the green path runs the same comparisons.
    local why
    if not ok then why = "load error: " .. tostring(m)
    elseif type(m) ~= "table" then why = "module is not a table"
    elseif m.api ~= 1 then why = "api " .. tostring(m.api) .. " (host expects 1)"
    elseif type(m.build_flight) ~= "function" or type(m.build_stats) ~= "function" then
        why = "build_flight/build_stats missing"
    else
        local iok, ierr = pcall(m.init, env)
        if not iok then why = "init error: " .. tostring(ierr) end
    end
    if why ~= nil then
        ultidash_functions.log("skin '" .. reg.id .. "' rejected: " .. why)
        reg.failed = true
        -- a FIELD, not a local: the main chunk sits at the 200-locals limit. Read by the
        -- flight/stats banner and by the settings sweep guard (a failed skin never
        -- registered its M.items keys, so the sweep would delete the user's settings
        -- for it on the next save).
        SKINS._load_failed = true
        skin_cache[reg.id] = false
        return nil
    end
    -- accepted: attach the manifest onto the registry row
    reg.failed = nil
    -- The 7-scheme cap is REAL and it drops the WHOLE manifest, not the eighth entry --
    -- a skin over the cap silently loses every colour scheme it declares, including the
    -- ones under it. Not silently any more: the cap is a colour-key budget decision, so
    -- it stays, and the skin is told which side of it it landed on.
    if type(m.schemes) == "table" and #m.schemes >= 1 then
        if #m.schemes <= 7 then
            reg.schemes = m.schemes
        else
            ultidash_functions.log("skin '" .. reg.id .. "': " .. #m.schemes
                .. " colour schemes declared, 7 is the maximum - none are offered")
        end
    end
    if type(m.items) == "table" then reg.items = m.items end
    reg.scheme_key = (type(m.scheme_key) == "string" and m.scheme_key)
        or ("Scheme_" .. reg.id)
    reg.def_scheme = (type(m.def_scheme) == "number" and m.def_scheme) or 1
    -- The skin's own "units beside values" key, same shape as scheme_key -- but with NO
    -- generated fallback, deliberately: a skin that declares none keeps reading the
    -- host's ShowUnits, which is what every skin written before 0.8.0 does. Inventing a
    -- "Units_<id>" key for them would silently reset a setting they already honour.
    reg.units_key = (type(m.units_key) == "string" and m.units_key) or nil
    reg.def_units = (type(m.def_units) == "number" and m.def_units) or 0
    -- opt-in for the session extrema of this skin's sensor slots (refresh_skin_menus
    -- hands it to the 5 Hz pass as SKINS._want_extrema). Must be copied here with the
    -- rest of the manifest -- while it was missing, the whole opt-in was inert and a
    -- skin's .min_formatted/.max_formatted only filled while the Telemetry detail
    -- page was open.
    reg.wants_extrema = (m.wants_extrema == true)
    skin_cache[reg.id] = m
    return m
end

-- Resolve the widget's active skin with graceful degradation: the chosen skin, else the
-- default skin (a broken third skin still gives the built-in look), else nil -> emergency.
local function active_skin(wgt)
    local reg = skin_reg_for(wgt.options.Skin)
    if reg == nil then return nil end   -- only before discovery -> emergency view
    local m = skin_load(reg.id)
    if m == nil and reg.id ~= "default" and SKINS.default ~= nil then
        m = skin_load("default")
    end
    return m
end

-- body of the forward-declared register_skin_defaults (see the declaration next to
-- SETTINGS_DEFAULTS for the full why). STAGED across refresh cycles (each call does one
-- slice; the stage-2a gates keep calling until skin_defaults_done):
--   call 1: DISCOVER skins/*.lua (dir scan; file name = id; default first, rest
--           alphabetical, capped) — nothing about a skin is hardcoded in the host.
--   later:  load up to 3 skins per call, attach their manifests and register their
--           keys — scheme choice, option rows, and the colour override keys of every
--           OVERRIDABLE scheme (schemes without a `tag` are FIXED: no Clr* keys).
-- discovery state: { q = rows still to load, seen = descriptor dedupe, tags = tag -> skin id }
local skin_disc = nil
register_skin_defaults = function()
    if skin_defaults_done then return end
    -- SYNCHRONOUS callers (update's register+apply pair) need the item catalogue NOW,
    -- so build it if the staged gates have not drained it yet — those gates run
    -- _build in its OWN cycle first, which makes this a no-op on the staged path.
    if SETTINGS_GROUPS._build then SETTINGS_GROUPS._build() end
    if skin_disc == nil then
        skin_disc = { q = {}, seen = {}, tags = {} }
        local ids = {}
        -- a failed scan is not fatal (default.lua is added below regardless), but it used
        -- to be completely silent: "no skins on the card" and "the card could not be read"
        -- looked identical from the menu.
        local scan_ok = pcall(function()
            for fname in dir(script_dir .. "skins") do
                -- ids must start alphanumeric ("_"-prefixed names stay host-reserved)
                local id = string.match(fname, "^([%w][%w_%-]*)%.lua$")
                if id ~= nil and id ~= "default" then ids[#ids + 1] = id end
            end
        end)
        if not scan_ok then
            ultidash_functions.log("skin discovery: cannot read skins/ - only the default skin is available")
        end
        table.sort(ids)
        table.insert(ids, 1, "default")   -- must be first (fallback + legacy index 1)
        for i = 1, #ids do
            if #SKINS < 16 then           -- safety cap (a wild folder must not run away)
                local row = { id = ids[i], name = ids[i], file = "skins/" .. ids[i] .. ".lua", seq = #SKINS + 1 }
                SKINS[#SKINS + 1] = row
                SKINS[row.id] = row
                skin_disc.q[#skin_disc.q + 1] = row
            else
                -- dropped by the cap: name the file, or the skin is simply missing from the
                -- list with nothing anywhere saying why
                ultidash_functions.log("skin discovery: '" .. ids[i] .. "' dropped (16-skin limit)")
            end
        end
        SETTINGS_DEFAULTS.Skin = "default"
        return                            -- the scan gets its own cycle
    end
    for _ = 1, 3 do                       -- ~1.5-2k instr per skin: 3 per cycle is safe
        local reg = table.remove(skin_disc.q, 1)
        if reg == nil then break end
        local m = skin_load(reg.id)       -- attaches reg.schemes/items/scheme_key/... (pcall'd)
        if m ~= nil and type(m.name) == "string" then reg.name = m.name end
        -- The skin's optional cfg migration (docs/SKINS.md §7c), run once per model when the
        -- store loads. Handed straight to the settings module rather than parked on `reg`:
        -- it is a lifecycle hook, not manifest the menus walk.
        -- Wrapped rather than handed over bare: the settings module pcalls a migrator so a
        -- raising one cannot take the dashboard down, but it has no logger, so the failure
        -- was invisible -- and a migration that silently never ran leaves every number
        -- exactly where it was, which is indistinguishable from having nothing to convert.
        if m ~= nil and type(m.migrate) == "function" then
            local mig, sid = m.migrate, reg.id
            ultidash_settings.add_migrator(function(t)
                local mok, merr = pcall(mig, t)
                if not mok then
                    ultidash_functions.log("skin '" .. sid .. "': migrate failed - " .. tostring(merr))
                end
            end)
        end
        if reg.scheme_key then
            SETTINGS_DEFAULTS[reg.scheme_key] = reg.def_scheme or 1
        end
        -- EVERY skin's units key, not just the active one's -- save()'s orphan-drop
        -- removes any key the defaults do not know, which would wipe an inactive skin's
        -- stored choice (the same reason the scheme keys are registered here)
        if reg.units_key then
            SETTINGS_DEFAULTS[reg.units_key] = reg.def_units or 0
        end
        local items = reg.items
        if items ~= nil then
            for i = 1, #items do
                if items[i].key then SETTINGS_DEFAULTS[items[i].key] = items[i].def end
            end
        end
        local schemes = reg.schemes
        if schemes ~= nil then
            for j = 1, #schemes do
                local d = schemes[j]
                if d.tag ~= nil and not skin_disc.seen[d] then
                    skin_disc.seen[d] = true
                    -- Scheme tags must be GLOBALLY unique (docs/SKINS.md): two schemes
                    -- sharing a tag share their Clr<tag>* keys, i.e. the user's colours
                    -- silently bleed between skins. With "drop a file into skins/ = the
                    -- install" that is a realistic mistake, so name it in the log instead
                    -- of letting it puzzle someone later. Not fatal: the skin still loads.
                    local owner = skin_disc.tags[d.tag]
                    if owner ~= nil and owner ~= reg.id then
                        ultidash_functions.log("skin '" .. reg.id .. "': scheme tag '"
                            .. d.tag .. "' already used by '" .. owner .. "' (colours will be shared)")
                    else
                        skin_disc.tags[d.tag] = reg.id
                    end
                    for r = 1, #COLOR_ROLES do
                        if role_in_scheme(COLOR_ROLES[r], d) then
                            SETTINGS_DEFAULTS[color_key(d, COLOR_ROLES[r])] = -1
                        end
                    end
                end
            end
        end
    end
    if #skin_disc.q == 0 then
        skin_defaults_done = true
        -- A skin that failed to load never registered its M.items keys into
        -- SETTINGS_DEFAULTS, and save()'s unknown-key sweep would then drop every one of
        -- them from the model file -- a user with a temporarily broken skin file loses
        -- that skin's settings permanently. Hold the sweep for this session: orphans
        -- survive one session longer, which costs nothing.
        ultidash_settings.sweep_hold = (SKINS._load_failed == true)
        -- ...and hand over WHICH skins this card carries. A skin that is not here at all
        -- never declared its keys either, so the sweep would drop them on the next save --
        -- an incomplete deploy costs the user a configuration they never touched. The
        -- settings module stores this roster in the cfg and holds the sweep when the file
        -- remembers a skin the card no longer has.
        local roster = {}
        for i = 1, #SKINS do roster[i] = SKINS[i].id end
        ultidash_settings.skin_roster = table.concat(roster, ",")
        -- Every skin has been loaded, so the migrator list is complete and a cfg load may
        -- run it. This is also the ordering guarantee the hook is specified with: every
        -- apply() call site is either behind the skin_defaults_done gate or preceded by a
        -- register_skin_defaults() call, so the first apply of a session always follows.
        ultidash_settings.seal()
    end
end

-- Ultimate fallback when the skin file is missing/broken (only ever a botched deploy):
-- a plain panel with a notice, so the screen is never blank. The top-left menu-glyph
-- fallback rect (menu_tap_rect) still lets the user reach the settings.
local function skin_emergency(wgt, zone)
    local main_panel = lvgl.rectangle({ x = 0, y = 0, w = zone.w, h = zone.h, color = PANEL_BG, filled = true })
    -- measured (rule 8): MIDSIZE is taller than 24 px on the 800x480 MK3
    local _, eh = lcd.sizeText("Ag", MIDSIZE)
    main_panel:label({ x = 0, y = math.floor((zone.h - eh) / 2), w = zone.w, h = eh + 2,
        text = "UltiDash: skin load failed", font = MIDSIZE, color = COLOR_THEME_WARNING, align = CENTER })
    ultidash_functions.add_alert_overlay(main_panel, wgt, zone.w, zone.h)
end

-- Host safety overlays stacked on TOP of whatever a skin returned (a skin can never
-- suppress them): the first-placement setup hint (flight only), the two transient warn
-- banners, and the hidden critical-alert overlay layer (LAST = on top). y_content is the
-- skin's content-top y so the banners land where they always did.
local function add_dashboard_overlays(main_panel, wgt, w, h, y_content, with_setup_hint)
    -- first-placement hint: all options live in the fullscreen menu, which a new user
    -- cannot know — a clear centered overlay, shown until the menu was opened once
    -- (SetupSeen, persisted). Plain build-table primitives, NOT an lvgl.box (a box keeps
    -- LV_OBJ_FLAG_CLICKABLE and would swallow taps on the screen middle). Only BUILT while
    -- pending (SetupSeen only flips 0->1), keeping this near-20k build under the CPU budget.
    if with_setup_hint and (wgt.options.SetupSeen or 0) ~= 1 then
        -- The four lines are NOT four equal quarters: the title is MIDSIZE and the three
        -- body lines are not, so a quarter that fits the body clips the title -- 42 px of
        -- title in 37 on the MK3, 29 in 24 on the TX15, 29 in 20 on the MK2, on every
        -- radio and since the panel was written. Measured shares instead (rule 8), and the
        -- panel grows if the measured lines need more than the proportional height does.
        local title_h = measure_font(MIDSIZE, nil, "Ag")
        local body_h  = measure_font(STDSIZE, nil, "Ag")
        local hint_w = math.floor(w * 0.74)
        local hint_h = math.max(88, math.floor(h * 0.34), 12 + title_h + 3 * body_h)
        local hx = math.floor((w - hint_w) / 2)
        local hy = math.floor((h - hint_h) / 2)
        -- whatever the panel has over the measured minimum is shared by the body lines
        local line_h = math.max(body_h, math.floor((hint_h - 12 - title_h) / 3))
        local y0 = hy + 6
        main_panel:build({
            { type = "rectangle", x = hx, y = hy, w = hint_w, h = hint_h, filled = true, rounded = 6, color = PANEL_BG },
            { type = "rectangle", x = hx, y = hy, w = hint_w, h = hint_h, thickness = 2, rounded = 6, color = COLOR_THEME_WARNING },
            { type = "label", x = hx + 10, y = y0, w = hint_w - 20, h = title_h,
              text = "UltiDash setup", font = MIDSIZE, color = COLOR_THEME_PRIMARY1, align = CENTER },
            { type = "label", x = hx + 10, y = y0 + title_h, w = hint_w - 20, h = line_h,
              text = "All settings live in the widget menu:", color = COLOR_THEME_PRIMARY1, align = CENTER },
            { type = "label", x = hx + 10, y = y0 + title_h + line_h, w = hint_w - 20, h = line_h,
              text = "long-press > Full screen,", color = COLOR_THEME_PRIMARY1, align = CENTER },
            { type = "label", x = hx + 10, y = y0 + title_h + 2 * line_h, w = hint_w - 20, h = line_h,
              text = "then tap the menu symbol (top left)", color = COLOR_THEME_PRIMARY1, align = CENTER },
        })
    end
    -- transient warning if a settings save/reset couldn't be written to the SD card
    add_warn_banner(main_panel, w, y_content + 2, save_failed_text(wgt), save_failed_visible(wgt))
    -- config error: two Dashboard instances both publishing (doubled callouts / flicker).
    -- Distinct y (a line below) so it never overlaps the save-failed banner.
    add_warn_banner(main_panel, w, y_content + 2 + measure_font(STDSIZE) + 6,
        "2 Dashboard instances active!", dual_publisher_visible(wgt))
    -- config error: the CHOSEN skin could not be loaded and the default look is standing in
    -- for it. Without this the failure is indistinguishable from "the skin looks like the
    -- default" -- a persistent state, like the dual-publisher case, so a banner and not a
    -- toast. A third distinct y so no two of them overlap.
    -- Unlike the two above, this banner is only BUILT when it applies. Its state cannot
    -- change without a rebuild (discovery has finished, a skin fails once, and switching
    -- skins rebuilds), so an always-present hidden element would cost every healthy build
    -- the two elements, the two closures and the concatenation for nothing -- measured at
    -- ~118 instructions on the 5 Hz refresh. The closure is kept for the visible case so
    -- the banner still follows the same reactive machinery as its two neighbours.
    local skin_bad = skin_failed_visible(wgt)
    if skin_bad() then
        add_warn_banner(main_panel, w, y_content + 2 + 2 * (measure_font(STDSIZE) + 6),
            "Skin '" .. tostring(wgt.options.Skin) .. "' failed - using default", skin_bad)
    end
    -- A switch shortcut was thrown while the widget is NOT in EdgeTX's Full screen, where a
    -- tool/detail page cannot be built at all. Always built and reactive like the first two
    -- banners rather than conditional like the one above: its state DOES change without a
    -- rebuild -- that is the whole point, the switch is thrown while the dashboard stands --
    -- and arming it through a rebuild would redraw the dashboard twice a second under a HELD
    -- position slot. A fourth distinct y so no two of them overlap -- but CLAMPED into the
    -- panel, which the three above are not: a layout zone is exactly where this one has to
    -- be readable, and a zone is short. Off the bottom it would be clipped rather than
    -- error, i.e. it would fail in the one state it exists for. Overlapping the (rare,
    -- persistent) skin-failed banner on a short zone is the better of the two.
    local bh = measure_font(STDSIZE) + 4
    add_warn_banner(main_panel, w,
        math.min(y_content + 2 + 3 * (measure_font(STDSIZE) + 6), h - bh - 2),
        "Shortcut needs Full screen", sc_fs_hint_visible(wgt))
    -- hidden critical-alert overlay layer, LAST so it stacks on top (reactive visible
    -- only -- state lives in update_alert_overlay, tap-dismiss in refresh())
    ultidash_functions.add_alert_overlay(main_panel, wgt, w, h)
end

--- Run one of the active skin's two view builders under a pcall, falling back to the
--- default skin's. A skin file is a THIRD PARTY's code that the user drops into skins/,
--- and this call was the one place where it ran unguarded: a raising builder took the whole
--- widget Lua state down, and with it the alert engine and the callouts -- everything that
--- has nothing to do with how the screen is laid out. The detail hooks were pcall'd from
--- the start; this is the same pattern for the two builders that matter more.
--- Cost: one pcall per rebuild, not per frame.
local function skin_build(wgt, zone, which)
    local skin = active_skin(wgt)
    if skin == nil then return nil end
    wgt.skin_build_failed = nil
    -- FOUR slots, not three: a builder's optional THIRD return is the two-cycle-build
    -- continuation (see build_flight_ui), and a `local ok, a, b = pcall(...)` drops it
    -- silently -- the builder still succeeds, the stage-2 half of the layout just never
    -- runs and nothing says so. The fallback below unpacks the same way for the same reason.
    local ok, main_panel, y_content, cont = pcall(skin[which], wgt, zone)
    if ok then return main_panel, y_content, cont end
    local why = tostring(main_panel)
    local id = tostring(wgt.options.Skin)
    -- one line per builder per distinct reason (a builder raising every frame still says
    -- it once), on wgt: the main chunk has no local to spare
    if wgt.skin_build_said ~= which .. why then
        wgt.skin_build_said = which .. why
        ultidash_functions.log("skin '" .. id .. "' " .. which .. " failed: " .. why)
    end
    wgt.skin_build_failed = true
    -- the designed degradation, same as a skin that fails to LOAD: the default skin's
    -- builder, under its own pcall -- a default that raises leaves the emergency view.
    if id == "default" or SKINS.default == nil then return nil end
    local fb = skin_load("default")
    if fb == nil then return nil end
    local fok, fmp, fyc, fcont = pcall(fb[which], wgt, zone)
    if not fok then return nil end
    return fmp, fyc, fcont
end

--- Build the flight dashboard: the active skin lays it out, the host stacks its overlays.
local function build_flight_ui(wgt, zone)
    local main_panel, y_content, cont = skin_build(wgt, zone, "build_flight")
    if main_panel == nil then
        if wgt.skin_build_failed or active_skin(wgt) == nil then
            return skin_emergency(wgt, zone)
        end
        return                                   -- the skin declined, as it may
    end
    add_dashboard_overlays(main_panel, wgt, zone.w, zone.h, y_content, true)
    -- TWO-CYCLE BUILD (optional, skin API): a builder may return a THIRD value, a
    -- continuation the host runs in the NEXT refresh cycle with a budget of its own —
    -- the same staggering as everything else, applied to the build itself. The heaviest
    -- layouts sat within ~4k of the harness fail line in ONE call; split, neither half
    -- does. The continuation must be self-contained (it builds its own top-level
    -- lvgl.box — nothing hands it a parent) and is dropped unrun by any newer build
    -- (see the lvgl.clear site). One frame shows part 1 alone; at 20 Hz that is the
    -- same invisibility every staged cycle here relies on.
    if type(cont) == "function" then wgt.skin_build_cont = cont end
end

--- Build the statistics dashboard: same split, no setup hint on the stats page.
local function build_stats_ui(wgt, zone)
    local main_panel, y_content, cont = skin_build(wgt, zone, "build_stats")
    if main_panel == nil then
        if wgt.skin_build_failed or active_skin(wgt) == nil then
            return skin_emergency(wgt, zone)
        end
        return
    end
    add_dashboard_overlays(main_panel, wgt, zone.w, zone.h, y_content, false)
    -- THE HOST GUARANTEES A WAY OUT. The close control normally comes from the host top
    -- bar, so every skin that draws it gets one without knowing about it — but `minimal`
    -- and `dash1` build their own stats header and never call it, and since 0.8.0 there
    -- is no tap-anywhere left to fall back on. Without this the page would have no touch
    -- route out at all. Same principle as the safety overlays above: a skin may PLACE the
    -- control (docs/SKINS.md), it can never remove it.
    if wgt.close_rect == nil and lvgl.isFullScreen ~= nil and lvgl.isFullScreen() then
        skin_env_build().close_button(main_panel, wgt, zone.w)
    end
    if type(cont) == "function" then wgt.skin_build_cont = cont end
end

--- Rebuild the widget UI for the active view and current options. `defer_build` (used only
--- by create()) runs the cheap settings/palette prep but leaves the heavy build to the next
--- refresh() cycle, so a cold boot's first cfg read doesn't share create()'s budget.
local function update(wgt, options, defer_build)
    if (wgt == nil) then return end
    prepare_widget(wgt)
    wgt.options = options
    -- The declared craft target, RE-READ on every update() and never cached from create():
    -- EdgeTX calls update() when the user changes an option in the widget dialog, so a
    -- value taken once at placement time would be the previous one until reboot. Resolved
    -- BEFORE the flag-only return below because the create path never reaches the rest of
    -- this function, and the first gated refresh cycle -- which is where ensure_rf_service
    -- attaches the RF service -- runs before the first full update().
    -- ultidashOptions owns both the declaration and the MEANING of the stored value (the 0
    -- an already-placed 0.7.x instance reports included); it is cached on the WIDGET rather
    -- than in a top-level local because this chunk is at Lua's 200-active-locals wall.
    -- The STORED value is what is re-read every time; the normalisation runs only when it
    -- actually moved (measured: the unconditional call cost ~24 instructions in every
    -- update(), and update() runs on every UI rebuild). Same memo discipline as the Status
    -- page rows -- an option change still lands on the very next update(), which is the
    -- call EdgeTX makes when the dialog closes.
    local traw = options and options.Target
    if traw ~= wgt.target_raw or wgt.target == nil then
        if wgt.opt_mod == nil then wgt.opt_mod = loadScript(script_dir .. "ultidashOptions.lua")() end
        wgt.target_raw = traw
        wgt.target = wgt.opt_mod.normalize_target(traw)
    end
    -- create() path: do NOTHING beyond flagging. create()'s 20k-instruction budget already
    -- carries the five module chunks (this file + Functions/Values/Rf/Settings, lazy-loaded
    -- by main.lua INSIDE create), which is most of the budget by itself — the cold cfg
    -- SD read + parse in apply() on top blew it ("CPU limit" at the apply call). Stage 1
    -- (here): flag only. Stage 2 (first refresh/background cycle): settings apply alone.
    -- Stage 3 (next refresh): the UI build (cfg cached by then). Costs two invisible frames.
    if defer_build then
        wgt.settings_apply_pending = true
        init_view_state(wgt).dirty = true
        return wgt
    end
    -- Fullscreen-ENTER inside the staggered-startup window: EdgeTX calls
    -- update() on enter (updateWithoutRefresh, 2.12 source) -- with the stage-2 apply
    -- still pending this one call would run cold cfg apply + the FULL UI build in ONE
    -- instruction budget, exactly the overrun class the staggering exists for.
    -- Degrade to stage-2 behaviour: apply alone (+ its ride-alongs), leave dirty set;
    -- the next refresh cycle builds with a fresh budget (one invisible frame).
    if wgt.settings_apply_pending then
        -- stage 2a, in its OWN cycle: harvest the skin manifests + register their keys
        -- (loads every skin once). Sharing this with the cfg read+apply below overran
        -- the budget (measured 18.2k) — so apply stays pending for the NEXT cycle.
        if not skin_defaults_done then
            -- stage 2a0 first, in its OWN cycle: the settings item catalogue (~5.7k,
            -- moved out of create()'s module-level budget); the harvest gets the next
            if SETTINGS_GROUPS._build then SETTINGS_GROUPS._build() else register_skin_defaults() end
            return wgt
        end
        wgt.settings_apply_pending = nil
        ultidash_settings.apply(wgt)
        -- may also be the autosave's stage 2 (fullscreen ENTER can land between the
        -- save cycle and the next refresh) -> the palette memo must be invalidated here too
        settings_gen = settings_gen + 1
        -- ...and stamp the apply memo AFTER the bump, or the very next update() would see a
        -- generation it has never applied and repeat the walk it just did (see the memo below)
        wgt.applied_gen, wgt.applied_target, wgt.applied_opts =
            settings_gen, ultidash_settings.target_path(), wgt.options
        if ultidash_functions.dbg_loadable()
            and (wgt.options.DebugLog == 1)
                ~= (ultidash_functions.dbg ~= nil and ultidash_functions.dbg.is_enabled()) then
            wgt.dbg_enable_pending = { wgt.options.DebugLog == 1, wgt.options.DebugKeep }
        end
        if ultidash_settings.load() == nil then
            wgt.cfg_snapshot_pending = true
        end
        init_view_state(wgt).dirty = true
        return wgt
    end
    -- overlay the per-model settings file onto the EdgeTX options (file wins for
    -- saved keys; no file = pure EdgeTX behavior).
    if SETTINGS_GROUPS._build then
        -- too EARLY for the synchronous pair: catalogue + skin harvest + apply is
        -- three staged budgets' worth in one call — and building the UI below without
        -- the apply would run on EMPTY options. Flag the apply and return, exactly
        -- like the create path's flag-only update: the refresh()/background() gates
        -- drain the chain one cycle each and the stage-2 apply flags the rebuild.
        wgt.settings_apply_pending = true
        return wgt
    end
    register_skin_defaults()   -- no-op after the first call
    -- MEMOISED, and this call used to be unconditional: apply() walks the whole ~296-key
    -- catalogue (ultidashSettings.lua, `for k, def in pairs(defaults)`), and EVERY dirty
    -- rebuild comes through here — a stats<->flight flip on arm/disarm, a detail page
    -- opening, every menu navigation step, the settings-page seed — each paying ~1.8k
    -- (measured: the staged `stage 2: apply` call is 2 077) with NOTHING changed in the cfg.
    -- apply()'s output depends only on (cfg file, defaults) plus the options table it writes
    -- into, so those three are exactly the memo keys:
    --   settings_gen  — bumped by every path that changes settings (autosave stage 2, reset
    --                   stage 2, settings_apply_pending); module-shared, so a save in ANY
    --                   instance invalidates every instance's memo.
    --   target_path() — a model switch moves the cfg file under us; M.load re-reads on it
    --                   and so must this.
    --   options       — EdgeTX may hand update() a FRESH options table (the widget dialog);
    --                   a new table carries none of the file's keys and must be re-applied.
    --                   Identity, not content: cheap and exact.
    -- Same generation mechanic as pal_memo three blocks below. Fields on `wgt` rather than
    -- top-level locals — this chunk is at Lua's 200-active-locals wall.
    local apply_target = ultidash_settings.target_path()
    if wgt.applied_gen ~= settings_gen or wgt.applied_target ~= apply_target
        or wgt.applied_opts ~= options then
        wgt.applied_gen, wgt.applied_target, wgt.applied_opts = settings_gen, apply_target, options
        ultidash_settings.apply(wgt)
    end
    -- diagnostics: drive the optional file logger from the per-model DebugLog option.
    -- No-op without ultidashDebug.lua.
    -- Enabling it STARTS a log session (several SD writes); that I/O must not share this
    -- call's instruction budget with the full UI build, or a cold boot (module ENABLED
    -- starts false) overruns it mid-build ("CPU limit"). Defer to its own refresh cycle,
    -- and only on an actual on/off change -- a no-op set_enabled is cheap, the session
    -- start is not. DebugKeep rides along on that transition.
    if ultidash_functions.dbg_loadable()
        and (wgt.options.DebugLog == 1)
            ~= (ultidash_functions.dbg ~= nil and ultidash_functions.dbg.is_enabled()) then
        wgt.dbg_enable_pending = { wgt.options.DebugLog == 1, wgt.options.DebugKeep }
    end
    -- One-time migration: when no per-model file exists yet, write it once so it
    -- exists and is stamped. (Since the delta rule that is a stamps-only file on a
    -- fresh model — every effective value IS its default — but a pre-cfg upgrade
    -- whose options carry non-defaults still snapshots those.)
    -- DEFERRED to a refresh() cycle of its own: EdgeTX gives each widget call a
    -- 20k-instruction budget (lua_widget.cpp MAX_INSTRUCTIONS), and snapshot +
    -- cfg file write on top of the full UI build in this same call blew it
    -- ("CPU limit" mid-build).
    if ultidash_settings.load() == nil then
        wgt.cfg_snapshot_pending = true
    end

    -- apply the chosen color palette to all modules before (re)building the UI.
    -- schemes belong EXCLUSIVELY to the skin (stage 3b): each skin stores its own
    -- pick under its scheme_key (default skin keeps the historical "ColorScheme" key)
    -- and starts at its manifest default.
    -- Legacy cfgs stored the skin as a list index — normalize to the id string once
    -- (the next settings save then persists the string form).
    if type(options.Skin) == "number" then
        options.Skin = SKINS._legacy[options.Skin] or "default"
    end
    -- A stored id with no file on the card resolves to the default row inside
    -- skin_reg_for, silently. Say it ONCE per id (this runs on every update): the banner
    -- covers the screen, the log line names what the cfg actually asks for.
    if skin_defaults_done and options.Skin ~= nil and SKINS[options.Skin] == nil
        and SKINS._unknown_said ~= options.Skin then
        SKINS._unknown_said = options.Skin
        ultidash_functions.log("skin '" .. tostring(options.Skin) .. "' not installed - using default")
    end
    -- the bare-row fallback only ever triggers before discovery finished (an update
    -- forced ahead of the staggered start): renders one frame in the standard look
    local scheme_skin = skin_reg_for(options.Skin) or { seq = 1 }
    local schemes = scheme_skin.schemes or SCHEMES
    local scheme = options[scheme_skin.scheme_key] or scheme_skin.def_scheme or 1
    -- out-of-range/corrupt values (hand-edited cfg) fall back to the skin's default.
    -- Written as a normalisation of `scheme` rather than as an `or` chain over the
    -- descriptors, because the INDEX is published below and it has to be the index that
    -- was actually used -- a skin handed 7 would look for a per-scheme key that has no row.
    local scheme_def = schemes[scheme]
    if scheme_def == nil then
        scheme = scheme_skin.def_scheme or 1
        scheme_def = schemes[scheme]
        if scheme_def == nil then scheme = 1; scheme_def = schemes[1] or SCHEMES.ulti end
    end
    -- PUBLISHED FOR THE SKIN. docs/SKINS.md §7b tells a skin to pick the matching one of its
    -- per-scheme `kind = "color"` rows by this index ("the host resolves your scheme index
    -- for you") -- and until now the host resolved it into a local and published nothing.
    -- The field read `nil`, `nil or M.def_scheme` looked deliberate, and the skin rendered a
    -- plausible wrong picture forever; a MISSING field can be asserted in M.init and fail by
    -- name, a documented-but-absent one cannot. It survived a month because kind = "color"
    -- has exactly one consumer in the whole tree (Dash1's card surface).
    -- It is an index into the ACTIVE skin's own M.schemes (the default skin's is SCHEMES).
    wgt.active_scheme = scheme
    -- the menus (colour pages, the "Skin" options group) always show the OWN skin's content
    local own_reg = skin_reg_for(options.Skin)
    if own_reg ~= nil then refresh_skin_menus(own_reg) end
    -- The in-widget menu / settings pages are native lvgl.page objects: their chrome
    -- (background, scrollbar) follows the EdgeTX theme, which we cannot repaint. On the
    -- dark scheme our white label text would sit on that light page and be unreadable,
    -- so render those native-page views with the EdgeTX-theme palette instead. The
    -- dashboard and the detail pages (our own dark panels) keep the dark scheme.
    local render_def = scheme_def
    -- when a dark scheme is FORCED onto the native menu pages, render them NEUTRAL: use the
    -- EdgeTX-theme built-ins WITHOUT this model's EdgeTX-theme colour overrides (ClrE*). A dark
    -- user's theme-page overrides are meant for the actual EdgeTX-theme scheme, not for the
    -- menus they only see because of this readability forcing (design decision, review #5).
    local menu_neutral = false
    if scheme_def.dark and wgt.menu_view ~= nil then
        render_def   = SCHEMES.theme
        menu_neutral = true
    end
    -- per-model colour overrides + built-ins for the scheme being rendered — MEMOISED, so a
    -- plain view switch (same scheme, no settings save) reuses them instead of rebuilding both
    -- every time. settings_gen invalidates the memo whenever settings are saved/reset.
    if pal_memo.scheme ~= render_def or pal_memo.gen ~= settings_gen or pal_memo.neutral ~= menu_neutral then
        pal_memo.scheme  = render_def
        pal_memo.gen     = settings_gen
        pal_memo.neutral = menu_neutral
        pal_memo.b       = cached_builtins(render_def)
        pal_memo.ovr     = menu_neutral and nil or build_overrides(options, render_def)
    end
    local pal = set_palette(pal_memo.b, pal_memo.ovr)   -- applies palette + semantics + overrides
    ultidash_functions.set_palette(render_def, pal, SEM)
    ultidash_values.set_palette(render_def, pal, SEM)
    -- palette for the Toolbox tool pages: use the REAL scheme (not the forced render_def)
    -- so the tools match the dashboard look (black+neon on dark, etc.)
    wgt.tb_pal = toolbox_palette(scheme_def)
    -- refresh the skin's theme snapshot from the just-resolved palette locals (the active
    -- skin reads these at build time below; sem stays a live reference)
    skin_theme.panel_bg      = PANEL_BG
    skin_theme.force_bg_fill = force_bg_fill
    skin_theme.primary1      = COLOR_THEME_PRIMARY1
    skin_theme.primary2      = COLOR_THEME_PRIMARY2
    skin_theme.secondary1    = COLOR_THEME_SECONDARY1
    skin_theme.focus         = COLOR_THEME_FOCUS
    skin_theme.warning       = COLOR_THEME_WARNING
    skin_theme.disabled      = COLOR_THEME_DISABLED
    skin_theme.dim           = COLOR_DIM
    skin_theme.track         = COLOR_TRACK
    skin_theme.tick          = COLOR_TICK
    -- The detail module mirrors the same palette into its own locals, and it has to happen
    -- HERE -- after the refresh above, before the build dispatch below. Snapshotting it at
    -- load time instead would freeze the boot scheme, which is the one way this seam can
    -- break silently: every colour would still be a valid colour.
    if ultidash_detail ~= nil then ultidash_detail.set_theme(skin_theme) end

    -- While the RFSuite adapter has the tool up, THAT TOOL owns the screen and this
    -- rebuild must not happen at all.
    --
    -- The chain, and none of it is inference: this function clears the tree, paints its
    -- background rectangle and dispatches to the open page's build; `rfscfg.M.build` draws
    -- nothing while the tool is open (RFSuite paints inside its own run()); and RFSuite
    -- rebuilds only when ITS state changes (`state.pendingBuildUI`, ui/home.lua). So one host
    -- rebuild leaves the background rectangle standing and nothing ever repaints over it --
    -- a white screen with the page still open. Reported from the radio 2026-08-18
    -- ("kurz den home screen und dann weiss").
    --
    -- Why this and not rf2cfg's trick: RF2's framework exposes a re-show seam (clearWaitMessage)
    -- that adapter pokes from its build. `ui/home.lua` returns { init, run, useLvgl } and
    -- exports neither buildUI nor its pending flag, so there is nothing equivalent to reach --
    -- the only lever left is not to clear in the first place.
    --
    -- The dirty flag is CONSUMED here on purpose. Leaving it set would re-enter this path on
    -- every cycle, and the caller's `return update(...)` makes that a wasted call each time.
    if wgt.menu_view == "tb_rfscfg" and rfscfg.mod ~= nil
        and rfscfg.mod.owns_screen ~= nil and rfscfg.mod.owns_screen() then
        init_view_state(wgt).dirty = false
        wgt.layout_dirty = false
        return wgt
    end

    lvgl.clear()
    -- M3: one filled rectangle in the widget's own background colour, immediately after
    -- the clear and before the dispatch. The staged page opens (build_settings_view seeds
    -- its working copy and returns; a sensor page spends a second cycle on the pick list)
    -- leave the tree EMPTY for 2-3 frames, and what showed through was whatever EdgeTX
    -- paints behind the widget -- the price of the CPU-limit staggering, reported from
    -- the radio 2026-08-16. The rectangle costs a handful of instructions in cycles that
    -- are deliberately near-empty; every after-the-clear staged site is covered at once.
    -- (build_sensorcheck_view already solved this for itself with a titled placeholder
    -- page -- this is the cheap general form underneath everything else.)
    lvgl.build({ { type = "rectangle", filled = true, x = 0, y = 0,
                   w = wgt.zone and wgt.zone.w or LCD_W, h = wgt.zone and wgt.zone.h or LCD_H,
                   color = skin_theme.panel_bg } })
    -- a pending two-cycle-build continuation dies with the tree it was meant to finish:
    -- its part-1 objects are gone as of the clear above, and the new build either sets
    -- a fresh one or needs none
    wgt.skin_build_cont = nil
    -- everything lvgl is gone now — drop the cached element references so nothing
    -- (e.g. update_status_bar_visibility) touches a cleared object ("Invalid object"
    -- error). The flight/stats builders repopulate them; the other views have none.
    wgt.status_bar_elements = nil
    wgt.status_bar_state = nil
    wgt.status_bar_box = nil
    -- tap-target rects: only the builders that exist in the new layout re-set them
    wgt.estatus_rect = nil
    wgt.statspage_rect = nil
    wgt.elrs_bar_rect = nil
    wgt.settings_icon_rect = nil
    wgt.battery_rect = nil
    wgt.values_rect = nil
    wgt.battprofile_rect = nil
    -- the page-close control: set by the detail builders and by the stats top bar, and
    -- by NOTHING on the flight view -- so a stale rect from the page just closed must not
    -- survive into a view that has no close at all
    wgt.close_rect = nil
    -- the Status log's paging buttons, for the same reason: a skin that stops drawing the log
    -- must not inherit buttons from the build before it. The host builder sets or nils them
    -- itself, so clearing them first changes nothing on the host path.
    wgt.estatus_scroll_up = nil
    wgt.estatus_scroll_down = nil
    -- Same idea one level up: the threshold service's pull list is re-registered by whatever
    -- this build asks for, so it is cleared here rather than only on a skin change. A ring or
    -- tile the user just switched away from stops costing its 5 Hz read within one cycle,
    -- instead of for the rest of the session. (refresh_skin_menus clears it too, for the
    -- skin-change path -- it returns early when the skin is unchanged.)
    local ex = SKINS._extra_names
    if ex ~= nil then
        for i = #ex, 1, -1 do ex[i] = nil end
    end

    -- dispatch: menu family first, then tool pages, then detail overlays, then
    -- the flight/stats switching.
    if wgt.menu_view == "status" then
        build_status_view(wgt, wgt.zone)
    elseif wgt.menu_view ~= nil and string.sub(wgt.menu_view, 1, 3) ~= "tb_" then
        -- menu family (hub, Toolbox/Settings submenus, settings pages, sensor
        -- check, battery pickers): all built by the LAZY menu module. Missing
        -- module (partial deploy) = clean degrade back to the dashboard.
        local m = menu_load(wgt)
        if m ~= nil then
            -- pcall'd for the same reason the skin builders are: the settings pages render
            -- SKIN-SUPPLIED rows (M.items), so a third-party skin's malformed row could
            -- raise inside the host's own menu build and take the widget down. A failure
            -- closes the page and falls back to the dashboard rather than leaving a
            -- half-built one on screen with no way out.
            local bok, berr = pcall(m.build, wgt, wgt.zone, wgt.menu_view)
            if not bok then
                ultidash_functions.log("menu page '" .. tostring(wgt.menu_view)
                    .. "' failed: " .. tostring(berr))
                wgt.menu_view = nil
                lvgl.clear()
                if init_view_state(wgt).current == "flight" then
                    build_flight_ui(wgt, wgt.zone)
                else
                    build_stats_ui(wgt, wgt.zone)
                end
            end
        else
            wgt.menu_view = nil
            if init_view_state(wgt).current == "flight" then
                build_flight_ui(wgt, wgt.zone)
            else
                build_stats_ui(wgt, wgt.zone)
            end
        end
    elseif wgt.menu_view == "tb_adjmap" and tb_adjmap then
        tb_adjmap.build(wgt, wgt.zone)
    elseif wgt.menu_view == "tb_adjed" and tb_adjed then
        tb_adjed.build(wgt, wgt.zone)
    elseif wgt.menu_view == "tb_livemon" and livemon.mod then
        livemon.mod.build(wgt, wgt.zone)
    elseif wgt.menu_view == "tb_logview" and tb_logview then
        tb_logview.build(wgt, wgt.zone)
    elseif wgt.menu_view == "tb_fltlog" and fltlog.mod then
        -- hand the viewer the resident fltdata instance (it loaded a second
        -- module copy per open); fltdata is tiny and stays resident by design anyway
        wgt.flt_data_mod = fltlog.load_data()
        fltlog.mod.build(wgt, wgt.zone)
    elseif wgt.menu_view == "tb_batted" and fltlog.batted then
        -- battpick's "+ New" create form (fltbatt renders detail-page style)
        fltlog.batted.build(wgt, wgt.zone)
    elseif wgt.menu_view == "tb_rf2cfg" and tb_rf2cfg then
        -- RF2 Config paints ITSELF (original tool: lvgl.clear+build inside its
        -- runner); build() only shows the glue notice page / pokes a re-show.
        tb_rf2cfg.build(wgt, wgt.zone)
    elseif wgt.menu_view == "tb_rfscfg" and rfscfg.mod then
        -- RFSuite paints ITSELF (lvgl.clear+build inside its run());
        -- build() only shows the glue notice page while the tool is not open.
        rfscfg.mod.build(wgt, wgt.zone)
    elseif wgt.detail_view ~= nil and ultidash_detail ~= nil
        and init_view_state(wgt).current == "flight" then
        -- The four detail pages live in ultidashDetail.lua since 0.7.0 (elrs = the top-bar
        -- bars, estatus = the ESC/arming status line, battery = the centre gauge, telem =
        -- the right value panel). The host still owns opening and closing them, the tap
        -- routing below, the data gating and the safety overlays; the module only builds.
        -- An unknown id builds nothing and falls through to the dashboard, which is the
        -- same outcome the old if-chain gave.
        --
        -- The ACTIVE SKIN gets first refusal, per page: M.build_detail_<id>. Absent, or not a
        -- function, is not a failure -- it is the normal case and says nothing. A hook that
        -- RAISES falls back to the host page, logs once, and shows a banner for as long as
        -- this page is open.
        -- Deliberately NOT cached as failed: a detail builder can raise on a data state
        -- rather than on its code (a nil sensor mid-flight), and caching would keep the host
        -- page for the rest of the session because of one bad frame. The log line carries the
        -- rate limit instead, so a hook raising every frame still says it once.
        -- The name is CONCATENATED rather than looked up in a static map. A map was tried and
        -- measured worse: +2 per detail build and +12 at module load, because the cost here is
        -- active_skin(), not the string. Recorded so the "obvious" optimisation is not redone.
        local drawn = false
        local skin = active_skin(wgt)
        local hook = skin ~= nil and skin["build_detail_" .. wgt.detail_view] or nil
        if type(hook) == "function" then
            local ok, err = pcall(hook, wgt, wgt.zone, skin_env_build())
            if ok then
                drawn = true
                wgt.detail_fail_id = nil
            else
                local why = tostring(err)
                -- one line per page per distinct reason, on wgt (no module local to spare)
                if wgt.detail_fail_said ~= wgt.detail_view .. why then
                    wgt.detail_fail_said = wgt.detail_view .. why
                    ultidash_functions.log("skin page '" .. wgt.detail_view
                        .. "' failed: " .. why)
                end
                wgt.detail_fail_id = wgt.detail_view
            end
        else
            -- No hook is the NORMAL case and says nothing -- but it must still clear a
            -- banner a previous skin left behind. Switching from a skin whose page raised
            -- to one that simply has no hook for it kept "Skin page failed - using default"
            -- on screen over a page the host had built correctly.
            wgt.detail_fail_id = nil
        end
        -- ultidash_detail == nil is unreachable now that every open is gated on it, and the
        -- test stays anyway: it is the last thing between a missing module and a widget that
        -- dies on a page it was never able to build.
        if not drawn and (ultidash_detail == nil
            or not ultidash_detail.build(wgt, wgt.zone, wgt.detail_view)) then
            build_flight_ui(wgt, wgt.zone)
        end
        -- The same guarantee as on the stats page: a skin hook that drew its own detail
        -- page and did not call env.close_button would leave a page with NO touch route
        -- out since 0.8.0 (`dash1` overrides detail pages today). The control is placed
        -- in the corner as its own top-level object, because a hook returns no panel to
        -- build into. A hook that called it already set the rect and nothing happens here.
        if wgt.close_rect == nil then
            local cx, csz = ultidash_functions.close_control(nil, wgt.zone.w - 8, 6,
                COLOR_THEME_SECONDARY1, COLOR_THEME_PRIMARY1)
            wgt.close_rect = { x = cx - 8, y = 0, w = csz + 16, h = csz + 14 }
        end
        -- The notice, built ONLY when it applies and only on the page it is about -- it must
        -- never reach the dashboard, which is why add_dashboard_overlays is not involved.
        -- Its own top-level object rather than add_warn_banner: that helper builds INTO a
        -- panel, and a skin hook returns nothing to build into (spec D3). Built last, so it
        -- stacks over whichever builder drew, and at the BOTTOM, so it does not cover the
        -- page title. Not reactive -- it cannot change without a rebuild.
        if wgt.detail_fail_id == wgt.detail_view then
            local bh = measure_font(STDSIZE) + 4
            local bx = math.floor(wgt.zone.w * 0.06)
            local bw = math.max(1, wgt.zone.w - 2 * bx)
            local bar = lvgl.rectangle({ x = bx, y = wgt.zone.h - bh - 2, w = bw, h = bh,
                color = COLOR_THEME_WARNING, filled = true, rounded = 4 })
            bar:label({ x = 4, y = 2, w = bw - 8, h = bh, font = STDSIZE,
                color = COLOR_THEME_PRIMARY2, align = CENTER,
                text = "Skin page '" .. tostring(wgt.detail_view) .. "' failed - using default" })
        end
    elseif init_view_state(wgt).current == "flight" then
        build_flight_ui(wgt, wgt.zone)
    else
        build_stats_ui(wgt, wgt.zone)
    end
    -- dev perf overlay (bottom-left, live Hz/heap) on EVERY view while DebugLog is on;
    -- top-level so it stacks over the view/tool built above (no-op when DebugLog off)
    ultidash_functions.add_perf_overlay(wgt, wgt.zone.w, wgt.zone.h)
    init_view_state(wgt).dirty = false
    wgt.layout_dirty = false
    -- Force status bar visibility update after UI rebuild
    update_status_bar_visibility(wgt, true)
    return wgt
end

--- Create a NEW widget instance (own table per placement) and build its layout.
local function create(zone, options)
    local wgt = ultidash_values.createWidget()
    wgt.zone = zone
    wgt.options = options
    -- Load the detail-page module here, on the ground, rather than on the tap that opens a
    -- page: that tap can happen in flight, and the loadScript would be felt. Measured before
    -- choosing this site -- see the commit.
    wgt.detail_ok = detail_load() ~= nil
    return update(wgt, options, true)   -- flag only; cfg apply + UI build follow in refresh()
end

--- Run background RF and telemetry work that should not rebuild the UI.
local function background(wgt)
    if not wgt then return end
    prepare_widget(wgt)
    -- M5: keep the live monitor's ring fed while the widget is hidden -- coarser (the
    -- background rate is EdgeTX's), and stated as a limit in the docs rather than hidden
    ultidash_functions.lm_sample(wgt)
    -- Stage 1 of the deferred settings write when the widget is HIDDEN (refresh never
    -- runs): the module's write_stage1 (autosave begin, one bounded batch of a chunked
    -- write in flight, or a reset), so edits made before the dashboard went off-screen
    -- still reach the card. It flags stage 2 itself when the write is done.
    if wgt.settings_save_pending or wgt.settings_reset_pending or wgt.settings_write_job then
        -- the orphan-drop in the merge needs the full key set; harvesting it is a
        -- cycle of its own (see stage 2a) — normally long done, so a flag check
        if not skin_defaults_done then
            -- stage 2a0 first, in its OWN cycle: the settings item catalogue (~5.7k,
            -- moved out of create()'s module-level budget); the harvest gets the next
            if SETTINGS_GROUPS._build then SETTINGS_GROUPS._build() else register_skin_defaults() end
            return wgt
        end
        ultidash_settings.write_stage1(wgt, ultidash_functions.log)
        return
    end
    -- Stage 2 of the deferred create() when the widget is HIDDEN (refresh never runs),
    -- and of the autosave above: apply the settings alone in this call's budget before
    -- any option-dependent work. The ride-along flags mirror refresh()'s stage 2: a
    -- publisher that never becomes visible must still start its DebugLog session /
    -- write its first cfg.
    if wgt.settings_apply_pending then
        -- stage 2a, in its OWN cycle: harvest the skin manifests + register their keys
        -- (loads every skin once). Sharing this with the cfg read+apply below overran
        -- the budget (measured 18.2k) — so apply stays pending for the NEXT cycle.
        if not skin_defaults_done then
            -- stage 2a0 first, in its OWN cycle: the settings item catalogue (~5.7k,
            -- moved out of create()'s module-level budget); the harvest gets the next
            if SETTINGS_GROUPS._build then SETTINGS_GROUPS._build() else register_skin_defaults() end
            return wgt
        end
        wgt.settings_apply_pending = nil
        ultidash_settings.apply(wgt)
        settings_gen = settings_gen + 1   -- invalidate palette memo
        wgt.applied_gen, wgt.applied_target, wgt.applied_opts =   -- ...and stamp the apply memo
            settings_gen, ultidash_settings.target_path(), wgt.options
        if ultidash_functions.dbg_loadable()
            and (wgt.options.DebugLog == 1)
                ~= (ultidash_functions.dbg ~= nil and ultidash_functions.dbg.is_enabled()) then
            wgt.dbg_enable_pending = { wgt.options.DebugLog == 1, wgt.options.DebugKeep }
        end
        if ultidash_settings.load() == nil then
            wgt.cfg_snapshot_pending = true
        end
        return
    end
    -- Consume the deferred one-shots off-screen too — each alone in its own
    -- call's budget, same deferral pattern as refresh(); no-ops once consumed.
    if wgt.dbg_enable_pending then
        local p = wgt.dbg_enable_pending
        wgt.dbg_enable_pending = nil
        -- enabling loads the lazy module here, in this deferred cycle's own budget
        local d = p[1] and ultidash_functions.dbg_load() or ultidash_functions.dbg
        if d then d.set_enabled(p[1], p[2]) end
        return
    end
    if wgt.cfg_snapshot_pending then
        wgt.cfg_snapshot_pending = nil
        if not wgt.cfg_snapshot_given_up and ultidash_settings.load() == nil then
            local snap = {}
            for_each_setting_item(function(it)
                local k = it.key
                if k and type(wgt.options[k]) == "number" then snap[k] = wgt.options[k] end
            end)
            -- checked like the menu autosave: a read-only SD must show the
            -- warn banner on the very first snapshot too — and stop retrying for
            -- the session (update() re-flags on every rebuild while no file exists)
            if not ultidash_settings.save(snap) then
                ultidash_functions.log("cfg snapshot save FAILED (SD not writable?)")
                wgt.cfg_save_failed_text = nil
                wgt.cfg_save_failed_until = (getTime() or 0) + 1000
                wgt.cfg_snapshot_given_up = true
            end
        end
        return
    end
    if ultidash_settings.flush_adoption ~= nil and ultidash_settings.flush_adoption() then
        return
    end
    -- flight-log flush off-screen too: the falling arm edge below flags
    -- it; consumed in its OWN cycle like refresh() does (SD write = own budget)
    if wgt.flt_flush_req then
        wgt.flt_flush_req = nil
        fltlog.flush(wgt)
        return
    end
    ensure_rf_service(wgt)
    -- Throttle the heavy background pass the same way refresh() throttles the
    -- foreground one. EdgeTX's background() cadence for hidden widgets is not
    -- documented ("coarse"), so this defensive gate also caps the extra background
    -- sensor reads. wgt.telem_gate is SHARED with refresh() on purpose — only one of
    -- the two paths runs per visibility state. State CHANGES still arrive immediately
    -- via the onStateChanged callback, independent of the gate.
    local tnow = getTime() or 0
    local gate_cs = (wgt.values.rf_connection_state ~= "disconnected") and 20 or 50
    if (tnow - (wgt.telem_gate or 0)) < gate_cs then return end
    wgt.telem_gate = tnow
    rf_service.background(wgt, handle_telemetry_state_change)
    -- honour a state-change flush request off-screen too (same deferral as refresh)
    if ultidash_functions.dbg and wgt.dbg_flush_req then
        wgt.dbg_flush_req = nil
        ultidash_functions.dbg.flush(true)
    end
    ultidash_functions.background_refresh(wgt)
    ultidash_functions.publish_shared(wgt)
    -- cache the armed state off-screen too. refresh() has always done this for the
    -- reactive closures; background() did not, and since lm_sample reads the cached flag
    -- instead of calling is_armed itself (2026-08-17) an off-screen arm would otherwise
    -- never reach the Live Monitor's edge marker. Same 5 Hz cadence, same meaning in both
    -- paths -- and arm_edges below wants the state anyway.
    wgt.armed_now = ultidash_functions.is_armed(wgt)
    -- arm/disarm edges off-screen too: opens/flags the flight record —
    -- without this a flight flown on another EdgeTX screen logged 0 s
    fltlog.arm_edges(wgt)
end

--- Hit-test a touch point against a rect (with a generous margin for fat fingers).
local function rect_hit(ts, r, margin)
    if not r or not ts or ts.x == nil or ts.y == nil then return false end
    margin = margin or 8
    return ts.x >= r.x - margin and ts.x <= r.x + r.w + margin
       and ts.y >= r.y - margin and ts.y <= r.y + r.h + margin
end

-- Menu-glyph tap target. Normally the rect the top-bar builder sets (settings_icon_rect);
-- but during the staggered fullscreen-ENTER build it can still be nil (glyph not drawn yet,
-- and a heavy frame -- e.g. debug log on -- can stretch that window), which left the menu
-- tap dead until a detail-view visit forced a rebuild. Fall back to a fixed top-left region
-- so the menu opens regardless of build timing; once the real rect exists it wins.
local function menu_tap_rect(wgt)
    local r = wgt.settings_icon_rect
    if r ~= nil then return r end
    local z = wgt.zone
    local zw = (z and z.w) or 480
    local zh = (z and z.h) or 272
    return { x = 0, y = 0, w = math.min(56, math.floor(zw * 0.14)), h = math.min(46, math.floor(zh * 0.16)) }
end

--- Refresh live telemetry, switch views if needed, and rebuild only when dirty.
local function refresh(wgt, event, touch_state)
    if not wgt then return end
    prepare_widget(wgt)
    -- M5: fold this pass into the live monitor's 5 Hz min/max ring -- EVERY cycle,
    -- before any dispatch or early return, because a peak between two 5 Hz passes is
    -- exactly what the ring exists to keep. Costs a 4-compare no-op while unconfigured.
    ultidash_functions.lm_sample(wgt)
    -- dev metrics (shown in the status detail footer): UI loop rate per second —
    -- the most honest "load" indicator (scheduler starvation = rate drops) — plus
    -- the Lua heap, sampled once per window
    local mnow = getTime() or 0
    wgt.dbg_calls = (wgt.dbg_calls or 0) + 1
    if mnow - (wgt.dbg_win or 0) >= 100 then
        wgt.dbg_hz = wgt.dbg_calls
        wgt.dbg_calls = 0
        wgt.dbg_win = mnow
        local okgc, kb = pcall(collectgarbage, "count")
        wgt.dbg_lua_kb = (okgc and type(kb) == "number") and math.floor(kb) or nil
        -- free heap headroom (getAvailableMemory, bytes) — so we can see the margin, not
        -- just the used total (dbg_lua_kb = collectgarbage count = whole-VM used)
        local okfm, fb = pcall(getAvailableMemory)
        wgt.dbg_free_kb = (okfm and type(fb) == "number") and math.floor(fb / 1024) or nil
    end
    -- Deferred DebugLog apply (flagged in update()): starting a log session does several
    -- SD writes; kept out of the build call's budget (see the note in update()). Own cycle.
    if wgt.dbg_enable_pending then
        local p = wgt.dbg_enable_pending
        wgt.dbg_enable_pending = nil
        -- enabling loads the lazy module here, in this deferred cycle's own budget
        local d = p[1] and ultidash_functions.dbg_load() or ultidash_functions.dbg
        if d then d.set_enabled(p[1], p[2]) end
        return
    end
    -- Stage 1 of the deferred settings WRITE — the module's write_stage1 (the autosave
    -- begin, one bounded batch of a chunked write in flight, or "Reset to defaults"),
    -- alone in this cycle's budget. It flags the shared stage 2 below when it is done;
    -- the chunking and its abort story live at save_begin/save_step in ultidashSettings.
    if wgt.settings_save_pending or wgt.settings_reset_pending or wgt.settings_write_job then
        -- the orphan-drop in the merge needs the full key set; harvesting it is a
        -- cycle of its own (see stage 2a) — normally long done, so a flag check
        if not skin_defaults_done then
            -- stage 2a0 first, in its OWN cycle: the settings item catalogue (~5.7k,
            -- moved out of create()'s module-level budget); the harvest gets the next
            if SETTINGS_GROUPS._build then SETTINGS_GROUPS._build() else register_skin_defaults() end
            return wgt
        end
        ultidash_settings.write_stage1(wgt, ultidash_functions.log)
        return
    end
    -- Stage 2 of the deferred create() (see update) AND of the autosave above: the cfg
    -- SD read + parse + apply runs ALONE in this cycle's budget (on the create path the
    -- read is cold). The checks that need the applied options (DebugLog transition,
    -- cold-boot snapshot) ride along — load() is cached by now, so they're cheap.
    -- The NEXT cycle builds the UI (stage 3 on create, the post-save rebuild here) with
    -- a fresh budget.
    if wgt.settings_apply_pending then
        -- stage 2a, in its OWN cycle: harvest the skin manifests + register their keys
        -- (loads every skin once). Sharing this with the cfg read+apply below overran
        -- the budget (measured 18.2k) — so apply stays pending for the NEXT cycle.
        if not skin_defaults_done then
            -- stage 2a0 first, in its OWN cycle: the settings item catalogue (~5.7k,
            -- moved out of create()'s module-level budget); the harvest gets the next
            if SETTINGS_GROUPS._build then SETTINGS_GROUPS._build() else register_skin_defaults() end
            return wgt
        end
        wgt.settings_apply_pending = nil
        ultidash_settings.apply(wgt)
        -- invalidate the palette memo. Unconditional: on the create path nothing is
        -- memoised yet, so the extra bump costs one recompute.
        settings_gen = settings_gen + 1
        wgt.applied_gen, wgt.applied_target, wgt.applied_opts =   -- ...and stamp the apply memo
            settings_gen, ultidash_settings.target_path(), wgt.options
        init_view_state(wgt).dirty = true   -- the autosave path built with the OLD options
        if ultidash_functions.dbg_loadable()
            and (wgt.options.DebugLog == 1)
                ~= (ultidash_functions.dbg ~= nil and ultidash_functions.dbg.is_enabled()) then
            wgt.dbg_enable_pending = { wgt.options.DebugLog == 1, wgt.options.DebugKeep }
        end
        if ultidash_settings.load() == nil then
            wgt.cfg_snapshot_pending = true
        end
        return
    end
    -- Deferred one-time migration snapshot (flagged in update()): runs in its own
    -- refresh cycle so snapshot + cfg file write get a fresh 20k-instruction
    -- budget instead of sharing create()'s with the full UI build ("CPU limit").
    -- Skipping the rest of this one 20 Hz cycle is invisible. Re-check load():
    -- a menu autosave may have created the file meanwhile.
    if wgt.cfg_snapshot_pending then
        wgt.cfg_snapshot_pending = nil
        if not wgt.cfg_snapshot_given_up and ultidash_settings.load() == nil then
            local snap = {}
            for_each_setting_item(function(it)
                local k = it.key
                if k and type(wgt.options[k]) == "number" then snap[k] = wgt.options[k] end
            end)
            -- checked like the menu autosave: a read-only SD must show the
            -- warn banner on the very first snapshot too — and stop retrying for
            -- the session (update() re-flags on every rebuild while no file exists)
            if not ultidash_settings.save(snap) then
                ultidash_functions.log("cfg snapshot save FAILED (SD not writable?)")
                wgt.cfg_save_failed_text = nil
                wgt.cfg_save_failed_until = (getTime() or 0) + 1000
                wgt.cfg_snapshot_given_up = true
            end
        end
        return
    end
    -- Deferred legacy-cfg adoption write (recorded by the settings load): the load may
    -- only READ inside create()/update()'s budget — persisting the adopted file runs
    -- here, alone in its own cycle (measured: read + adoption write + apply in ONE
    -- call sat at ~19.9k of the 20k limit). No-op ~5 instr when nothing is pending.
    if ultidash_settings.flush_adoption ~= nil and ultidash_settings.flush_adoption() then
        return
    end
    -- Stage 2 of a TWO-CYCLE skin build (see build_flight_ui): the heavy half of the
    -- heaviest layouts runs here, alone in this cycle's budget. Deliberately AFTER the
    -- settings stages above — those may flag a rebuild, whose lvgl.clear drops this
    -- continuation before it could build onto a cleared tree — and pcall'd like every
    -- skin call: a failing stage 2 logs and leaves part 1 standing (values, cards and
    -- taps all live there), which degrades visibly instead of looping a rebuild that
    -- would fail the same way at 20 Hz.
    if wgt.skin_build_cont ~= nil then
        local f = wgt.skin_build_cont
        wgt.skin_build_cont = nil
        local okc, errc = pcall(f)
        if not okc then
            ultidash_functions.log("skin build stage 2 FAILED: " .. tostring(errc))
        end
        return
    end
    -- Rebuild ONCE after leaving fullscreen. Root cause (EdgeTX 2.12 source): lvgl.box
    -- containers keep LV_OBJ_FLAG_CLICKABLE when built while fullscreen (EdgeTX clears
    -- the flag only for widget-mode NON-fullscreen builds), and EdgeTX rebuilds the
    -- tree on fullscreen ENTER (updateWithoutRefresh) but NOT on exit — so the
    -- leftover clickable boxes swallow taps/long-press and the widget menu stops
    -- opening. Rebuilding outside fullscreen restores non-clickable boxes. We only
    -- OBSERVE the state — EdgeTX fully owns the enter/exit lifecycle (lesson learned:
    -- never intercept RTN / never call exitFullScreen here).
    local fs = (lvgl.isFullScreen ~= nil) and lvgl.isFullScreen() == true
    if wgt.was_fullscreen and not fs then
        wgt.was_fullscreen = false
        -- ELRS detail + menu/settings/status are fullscreen-only features (normal
        -- mode gets no touch), so leaving fullscreen always returns to the dashboard.
        -- Leaving with the settings page open AUTOSAVES pending edits (same policy as back/RTN/arm).
        wgt.detail_view = nil
        save_pending_settings(wgt)
        close_tool_page(wgt)                       -- reset a mid-pulse GVAR before closing
        wgt.menu_view = nil
        return update(wgt, wgt.options)
    end
    wgt.was_fullscreen = fs
    -- Keep the screen awake while UltiDash owns the WHOLE display (KeepLit, Display >
    -- Behaviour). Not cosmetic and not about brightness: once the backlight has timed out
    -- EdgeTX delivers the next press with NO coordinates and then waits for the release
    -- (gui/colorlcd/LvglWrapper.cpp, touchDriverRead -- `if (!isBacklightEnabled())`), so
    -- that tap is spent waking the screen and no widget ever sees it. The pilot who taps
    -- to open a detail page after the radio has sat on the bench loses that first tap,
    -- and nothing on screen says why. lcd.resetBacklightTimeout() is EdgeTX's own API for
    -- this (it just re-loads lightOffCounter from the user's own lightAutoOff, so the
    -- setting is respected rather than overridden) and it is a no-op outside a drawing
    -- call. Deliberately gated on `fs`: in a layout zone the widget does not own the
    -- screen, the taps are not its own, and the radio's own power saving must stand.
    -- Guarded for EdgeTX builds without the call (introduced in 2.3.6).
    if fs and wgt.options and wgt.options.KeepLit == 1
        and lcd ~= nil and lcd.resetBacklightTimeout ~= nil then
        lcd.resetBacklightTimeout()
    end
    -- Fullscreen ELRS-detail taps (touch only reaches refresh while fullscreen):
    -- tap on the bar cluster opens the detail, any tap closes it again. Strictly the
    -- discrete EVT_TOUCH_TAP, plus a TIME-based cooldown: one physical tap often
    -- bounces into several TAP events (EdgeTX double-tap counting), which made the
    -- detail flicker open-closed-open. The cooldown expires by itself, so unlike the
    -- old state-based debounce it can never get stuck. No key/RTN interception —
    -- EdgeTX owns the fullscreen lifecycle.
    -- RTN navigates the menu pages even when NO control has focus: lvgl.page's
    -- built-in back catches RTN only while one of its controls is focused; with
    -- nothing focused the key arrives here as EVT_VIRTUAL_EXIT instead. Same
    -- semantics as each page's back arrow.
    -- RTN also closes the ELRS detail (alternative to tap-anywhere)
    if fs and wgt.detail_view ~= nil and wgt.menu_view == nil
        and EVT_VIRTUAL_EXIT ~= nil and event == EVT_VIRTUAL_EXIT then
        wgt.detail_view = nil
        init_view_state(wgt).dirty = true
    end
    if fs and wgt.menu_view ~= nil and EVT_VIRTUAL_EXIT ~= nil and event == EVT_VIRTUAL_EXIT then
        if wgt.menu_view == "settings" then
            close_settings(wgt)                   -- autosave, back to the group/alert list
        elseif wgt.menu_view == "alerts_menu" or wgt.menu_view == "colors_menu"
            or wgt.menu_view == "sub_menu" then
            -- alert/colour picker AND the plain two-page submenus (Telemetry / Voice /
            -- Shortcuts): RTN = one level up, like their back arrow (the old
            -- else-branch dropped sub_menu straight to the dashboard)
            wgt.menu_view = "settings_menu"
            init_view_state(wgt).dirty = true
        elseif wgt.menu_view == "settings_menu" or wgt.menu_view == "status"
            or wgt.menu_view == "elrsstatus"
            or wgt.menu_view == "sensorcheck" or wgt.menu_view == "toolbox" then
            wgt.menu_view = "menu"                -- submenu -> hub
            init_view_state(wgt).dirty = true
        elseif wgt.menu_view == "tb_adjmap" or wgt.menu_view == "tb_adjed"
            or wgt.menu_view == "tb_livemon" then
            close_tool_page(wgt)                   -- reset a mid-pulse GVAR before closing
            -- back to where the tool was OPENED from: toolbox submenu (menu path) or
            -- straight to the dashboard (shortcut path — no menu trail to unwind)
            wgt.menu_view = (wgt.tool_back == "toolbox") and "toolbox" or nil
            init_view_state(wgt).dirty = true
        elseif wgt.menu_view == "tb_logview" then
            -- multi-stage: the viewer consumes RTN internally (chart/picker/load -> browser);
            -- only when it reports "already at the top level" do we leave the tool.
            if not (tb_logview and tb_logview.on_exit_key(wgt)) then
                if tb_logview then tb_logview.close(wgt) end
                tb_logview = nil                   -- release the lazy-loaded module (GC)
                wgt.menu_view = (wgt.tool_back == "toolbox") and "toolbox" or nil
            end
            init_view_state(wgt).dirty = true
        elseif wgt.menu_view == "tb_fltlog" then
            -- RTN steps a battery page / per-flight detail / active model filter
            -- back first (on_exit_key reports it handled that); at the list top
            -- level it leaves the tool.
            if not (fltlog.mod and fltlog.mod.on_exit_key(wgt)) then
                if fltlog.mod then fltlog.mod.close(wgt) end
                fltlog.mod = nil                   -- release the lazy-loaded module (GC)
                wgt.menu_view = (wgt.tool_back == "toolbox") and "toolbox" or nil
            end
            init_view_state(wgt).dirty = true
        elseif wgt.menu_view == "tb_batted" then
            -- battpick's create form: RTN unwinds inside the editor first (models
            -- sub-page / dialog); at its top RTN = Cancel -> battpick unchanged
            if not (fltlog.batted and fltlog.batted.on_exit_key(wgt)) then
                if fltlog.batted then fltlog.batted.close(wgt) end
                fltlog.batted = nil                -- release the lazy-loaded module (GC)
                wgt.fb_close_req, wgt.fb_saved, wgt.fb_dirty = nil, nil, nil
                wgt.menu_view = "battpick"
            end
            init_view_state(wgt).dirty = true
        elseif wgt.menu_view == "tb_rf2cfg" then
            -- RF2 Config owns RTN completely (original RF2 key loop: page ->
            -- main menu -> exit). The event reaches the module in the refresh
            -- dispatch below; the final exit comes back as wgt.rf2cfg_close_req.
            -- No host action here (the branch only keeps the generic else from
            -- closing the view underneath the module).
        elseif wgt.menu_view == "tb_rfscfg" then
            -- RFSuite owns RTN completely, same as RF2 Config -- its own key
            -- loop unwinds page -> main menu -> exit, and the exit comes back as
            -- wgt.rfs_close_req from the refresh dispatch below.
        else
            wgt.menu_view = nil                   -- hub -> dashboard
            init_view_state(wgt).dirty = true
        end
    end
    -- Release the LAZY menu module once no menu page is up (fullscreen = only one
    -- widget visible, so no other instance can be mid-menu). Tool pages (tb_*) don't
    -- use it either — released under them too, so it never rides along in flight.
    -- Placed BEFORE the tool dispatch: the Log Viewer's exclusive branch returns
    -- early every cycle and would otherwise keep it resident for the whole session.
    if menu_mod ~= nil and (wgt.menu_view == nil
        or string.sub(wgt.menu_view, 1, 3) == "tb_") then
        menu_mod = nil
    end
    -- Toolbox tool pages: run their state/touch/pulse every cycle while open (UltiDash's
    -- own tap zones below are gated to menu_view==nil, so no conflict). In-flight capable.
    if wgt.menu_view == "tb_adjmap" and tb_adjmap then
        wgt.tb_announce = ultidash_functions.tb_announce_pos
        -- T: the FC-served table can land or change WHILE the page is open (the connect
        -- walk finishes, the option flips, the session ends) -- applyFcTable reports the
        -- change and the page rebuilds. One string compare per cycle when nothing moved.
        if tb_common and tb_common.applyFcTable then
            tb_common.applyOverrides()
            if tb_common.applyFcTable(wgt) then init_view_state(wgt).dirty = true end
        end
        tb_adjmap.refresh(wgt, event, touch_state)
    elseif wgt.menu_view == "tb_adjed" and tb_adjed then
        wgt.tb_announce = ultidash_functions.tb_announce_pos
        if tb_common and tb_common.applyFcTable then
            tb_common.applyOverrides()
            if tb_common.applyFcTable(wgt) then init_view_state(wgt).dirty = true end
        end
        tb_adjed.refresh(wgt, event, touch_state)
    elseif wgt.menu_view == "tb_livemon" and livemon.mod then
        -- M5: light per-cycle work (chip tap, one strip's rewrite per bucket tick);
        -- the sampling itself already ran at the top of this refresh, page or no page
        livemon.mod.refresh(wgt, event, touch_state)
        if wgt.lmv_dirty then                  -- window switch / late point allocation
            wgt.lmv_dirty = nil
            init_view_state(wgt).dirty = true
        end
    elseif wgt.menu_view == "tb_logview" and tb_logview then
        -- EXCLUSIVE cycles for the Log Viewer: its chunked file parse deliberately
        -- burns most of an instruction budget itself, so NOTHING heavy may share the
        -- call. Skipping only the 4 foreground telemetry calls was not enough — with
        -- a connected FC the ~3 s sensor scan (resolve_sensor_indices, ~60 getSensor
        -- reads) and rf_service.background still ran AFTER the loader chunk and
        -- tripped "CPU limit" even on a 27-line log. So: cheap arm upkeep at 5 Hz
        -- (the module auto-closes on arm via wgt.armed_now), then either rebuild
        -- ALONE (dirty) or run the module ALONE, and return. The viewer is a
        -- fullscreen, disarmed-only page — no dashboard function is missed under it,
        -- and wgt.telem_gate fires immediately once it closes.
        local lnow = getTime() or 0
        if (lnow - (wgt.lv_arm_gate or 0)) >= 20 then
            wgt.lv_arm_gate = lnow
            wgt.armed_now = ultidash_functions.is_armed(wgt)
            -- keep the switch shortcuts alive under the viewer (this branch returns
            -- before the main 5 Hz pass): a toggle press / leaving a bound position
            -- must still step onward or close the viewer. Cheap (a few getValue).
            shortcut.run(wgt)
        end
        if init_view_state(wgt).dirty == true then
            return update(wgt, wgt.options)    -- rebuild alone in this cycle
        end
        if tb_logview == nil then return end   -- shortcut.run just closed the viewer
        tb_logview.refresh(wgt, event, touch_state)
        if wgt.lv_close_req then               -- arm / fullscreen-exit: M.close already ran
            wgt.lv_close_req = nil
            tb_logview = nil                   -- release the lazy-loaded module (GC)
            wgt.menu_view = nil                -- back to the flight view (spec 3.4)
            init_view_state(wgt).dirty = true
        elseif wgt.lv_dirty then               -- mode/page change inside the module
            wgt.lv_dirty = nil
            init_view_state(wgt).dirty = true
        end
        return
    elseif wgt.menu_view == "tb_fltlog" and fltlog.mod then
        -- EXCLUSIVE cycles like the Log Viewer: the chunked CSV parse owns the
        -- call budget; cheap arm upkeep + shortcuts at 5 Hz, rebuild alone.
        local lnow = getTime() or 0
        if (lnow - (wgt.lv_arm_gate or 0)) >= 20 then
            wgt.lv_arm_gate = lnow
            wgt.armed_now = ultidash_functions.is_armed(wgt)
            shortcut.run(wgt)
        end
        if init_view_state(wgt).dirty == true then
            return update(wgt, wgt.options)    -- rebuild alone in this cycle
        end
        fltlog.mod.refresh(wgt, event, touch_state)
        if wgt.fl_close_req then               -- arm / fullscreen-exit / back arrow
            wgt.fl_close_req = nil
            fltlog.mod = nil                   -- release the lazy-loaded module (GC)
            wgt.menu_view = (wgt.tool_back == "toolbox" and not wgt.armed_now)
                            and "toolbox" or nil
            init_view_state(wgt).dirty = true
        elseif wgt.fl_dirty then               -- tab/page change or load finished
            wgt.fl_dirty = nil
            init_view_state(wgt).dirty = true
        end
        return
    elseif wgt.menu_view == "tb_batted" and fltlog.batted then
        -- EXCLUSIVE cycles like the Flight Log pages: the Save registry write
        -- runs in the module's own deferred cycle and owns the call budget.
        -- No shortcut.run here on purpose -- a switch-opened tool must not
        -- stomp the open form; arming still closes it via armed_now below.
        local lnow = getTime() or 0
        if (lnow - (wgt.lv_arm_gate or 0)) >= 20 then
            wgt.lv_arm_gate = lnow
            wgt.armed_now = ultidash_functions.is_armed(wgt)
        end
        if init_view_state(wgt).dirty == true then
            return update(wgt, wgt.options)    -- rebuild alone in this cycle
        end
        fltlog.batted.refresh(wgt, event, touch_state)
        if wgt.fb_saved or wgt.fb_close_req then
            local saved = wgt.fb_saved
            wgt.fb_saved, wgt.fb_close_req, wgt.fb_dirty = nil, nil, nil
            if fltlog.batted and fltlog.batted.close then fltlog.batted.close(wgt) end
            fltlog.batted = nil                -- release the lazy-loaded module (GC)
            if saved then
                -- Save: reload the pick list through the existing deferred open;
                -- the new pack sits at the end (stable file order, B11)
                wgt.menu_view = nil
                wgt.battpick_load_req = true
            elseif not wgt.armed_now then
                wgt.menu_view = "battpick"     -- Cancel -> battery query unchanged
            else
                wgt.menu_view = nil            -- armed: the whole window is closed
            end
            init_view_state(wgt).dirty = true
        elseif wgt.fb_dirty then               -- page/dialog change inside the module
            wgt.fb_dirty = nil
            init_view_state(wgt).dirty = true
        end
        return
    elseif wgt.menu_view == "tb_rf2cfg" and tb_rf2cfg then
        tb_rf2cfg.refresh(wgt, event, touch_state)
        if wgt.rf2cfg_close_req then           -- module closed itself (slots restored):
            local target = wgt.rf2cfg_close_req -- "toolbox" (RTN exit) | "dashboard" (arm)
            wgt.rf2cfg_close_req = nil
            tb_rf2cfg = nil                    -- release the lazy-loaded module (GC)
            -- an RTN exit unwinds to where the tool was opened from (shortcut ->
            -- dashboard, menu -> toolbox submenu); an arm-close always -> dashboard
            wgt.menu_view = (target ~= "dashboard" and wgt.tool_back == "toolbox")
                            and "toolbox" or nil
            init_view_state(wgt).dirty = true
        elseif wgt.rf2cfg_dirty then           -- notice text changed / runner error
            wgt.rf2cfg_dirty = nil
            init_view_state(wgt).dirty = true
        end
    elseif wgt.menu_view == "tb_rfscfg" and rfscfg.mod then
        -- An EXCLUSIVE cycle, and here that is not a nicety -- it is the only way the widget
        -- survives. RFSuite is written for the standalone Lua state, where a long call is
        -- YIELDED and resumed (interface.cpp:122); a widget call is KILLED at 20000
        -- instructions (widgets.cpp:53). So a pumped RFSuite page routinely spends the whole
        -- budget, and anything the host does AFTERWARDS in the same call runs on an exhausted
        -- one and raises where no pcall of ours can reach it -- observed as
        -- "Error in widget UltiDash widget function: CPU limit" in the simulator trace
        -- (2026-08-18), i.e. EdgeTX's own error, not a contained one.
        --
        -- Cheap arm upkeep at 5 Hz FIRST, so the disarmed-only rule keeps working, then the
        -- module, then return. Same shape as tb_fltlog / tb_batted above, for the same reason
        -- stated differently: whoever owns the screen owns the call budget.
        --
        -- No shortcut.run: a bound switch must not stomp an open config page, and arming
        -- still closes it through the module's own arm-close below.
        local rnow = getTime() or 0
        if (rnow - (wgt.lv_arm_gate or 0)) >= 20 then
            wgt.lv_arm_gate = rnow
            wgt.armed_now = ultidash_functions.is_armed(wgt)
        end
        rfscfg.mod.refresh(wgt, event, touch_state)
        if wgt.rfs_close_req then              -- module closed itself (pump restored,
            local target = wgt.rfs_close_req   -- MSP detached, modules cleared)
            wgt.rfs_close_req = nil
            rfscfg.mod = nil                   -- release the lazy-loaded module (GC)
            wgt.menu_view = (target ~= "dashboard" and wgt.tool_back == "toolbox")
                            and "toolbox" or nil
            init_view_state(wgt).dirty = true
        elseif wgt.rfs_dirty then              -- notice text changed / tool error
            wgt.rfs_dirty = nil
            init_view_state(wgt).dirty = true
        end
        return                                 -- exclusive cycle -- see the comment above
    end
    -- Toolbox menu: rebuild on the arm transition while it is open, so the
    -- disarmed-only tools flip between dimmed and normal (build-time tcol)
    if wgt.menu_view == "toolbox" and (wgt.tb_menu_armed or false) ~= (wgt.armed_now or false) then
        init_view_state(wgt).dirty = true
    end
    -- (the sensor-check 1 Hz scan tick lives below with the deferred-work chains —
    -- it needs an EXCLUSIVE cycle)
    if fs and EVT_TOUCH_TAP ~= nil and event == EVT_TOUCH_TAP then
        local now = getTime() or 0
        -- Bounce protection, device-robust (the TX16S spreads bounce taps wider
        -- than the TX15, which re-flickered the detail open-closed-open):
        -- (a) multi-tap reports (tapCount > 1) are ignored outright;
        -- (b) ASYMMETRIC cooldown — a long 1 s block right after OPENING the detail
        --     (only "a tap instantly closes it again" causes the flicker; a
        --     deliberate close naturally comes later). The SAME 1 s now applies to
        --     close/dismiss actions too: the view changes under the finger, and a
        --     late bounce tap would otherwise click through onto whatever tap zone
        --     sits at the same spot in the NEW view (seen on hardware: stats
        --     dismiss opened the status detail, closing that opened the battery).
        -- No tap handling while a menu page is up — its lvgl page/buttons own the
        -- touch (closing goes through the page's back arrow / RTN).
        local tap_count = touch_state and touch_state.tapCount
        -- Does this tap land on the MENU GLYPH, in a state where the glyph is what would
        -- handle it? Computed once and used twice -- to let a multi-tap report through for
        -- the glyph alone, and as the branch's own condition below -- so the two can never
        -- drift apart and a relaxed guard can never open a DIFFERENT branch.
        local glyph_tap = wgt.ovl_active == nil and wgt.detail_view == nil
            and rect_hit(touch_state, menu_tap_rect(wgt), 10)
            and shortcut.menu_allowed(wgt)   -- M2 shares this exact condition
        -- The four detail zones open a page only when there IS one to open. With
        -- ultidashDetail.lua missing (the soft failure detail_load logs) the taps still set
        -- detail_view: the next tap was then eaten closing a page nobody could see, the menu
        -- glyph went dead for exactly that one tap, and the 5 Hz pass started pulling the
        -- telemetry extremes for it. Read once instead of four times, which also makes the
        -- four branches cheaper than they were.
        local tap_details = wgt.options.TapDetails == 1 and ultidash_detail ~= nil
        -- Gate (a) is RELAXED FOR THE GLYPH ONLY. EdgeTX delivers no tap at all for a press
        -- held past LUA_TAP_TIME (250 ms), so a firm press is silently lost; the natural
        -- response is to press again at once, and that second press arrives as tapCount = 2
        -- and was dropped here. Twice, and sometimes not at all. The glyph is the one target
        -- where letting a multi-tap through costs nothing: opening the menu replaces the
        -- whole screen, so there is no tap zone left underneath for a late bounce to click
        -- through onto -- which is the damage (b) exists to prevent, and it still does, for
        -- the glyph as well as everywhere else.
        if (tap_count == nil or tap_count <= 1 or glyph_tap)
            and now >= (wgt.elrs_tap_block or 0) and wgt.menu_view == nil then
            if wgt.ovl_active ~= nil and wgt.detail_view == nil then
                -- Alert/notice overlay: THE X IN THE CORNER AND NOTHING ELSE closes it
                -- (0.8.0, the user's decision — the same change the detail pages got, for
                -- the same reason: "any tap closes" is invisible and turns every mis-tap
                -- into a close, which on a message meant to be READ throws it away before
                -- it has been). Only while it is actually visible (flight/stats view — an
                -- open detail page replaces that tree, so its taps must not be swallowed
                -- here). No rebuild needed either way (reactive visible).
                -- A tap that MISSES the X is still swallowed by this branch and does
                -- nothing: the tap zones underneath must not be reachable through a box
                -- that covers them. It gets the SHORT cooldown, because the pilot is
                -- aiming at the X and a 1 s block would eat the second attempt; the
                -- closing tap keeps the long one, so its bounce cannot click through onto
                -- what the box was covering.
                if rect_hit(touch_state, wgt.ovl_close_rect, 10) then
                    wgt.elrs_tap_block = now + 100
                    wgt.ovl_dismissed = wgt.ovl_active
                    wgt.ovl_active = nil
                else
                    wgt.elrs_tap_block = now + 25
                end
            elseif wgt.detail_view ~= nil then
                -- Status log scroll: taps on the ▲/▼ buttons scroll the log (short cooldown)
                -- and do NOT close. CLOSING IS THE X IN THE CORNER AND NOTHING ELSE since
                -- 0.8.0 (long cooldown): "any tap closes" was invisible, turned every
                -- mis-tap into a close, and was the reason a detail page could never carry
                -- tap zones of its own. RTN and a bound switch are unaffected, and a tap
                -- that hits nothing now does nothing.
                if wgt.detail_view == "estatus" and rect_hit(touch_state, wgt.estatus_scroll_up, 6) then
                    wgt.elrs_tap_block = now + 25
                    wgt.estatus_scroll = math.max(0, (wgt.estatus_scroll or 0) - 1)
                    init_view_state(wgt).dirty = true
                elseif wgt.detail_view == "estatus" and rect_hit(touch_state, wgt.estatus_scroll_down, 6) then
                    wgt.elrs_tap_block = now + 25
                    wgt.estatus_scroll = (wgt.estatus_scroll or 0) + 1
                    init_view_state(wgt).dirty = true
                elseif rect_hit(touch_state, wgt.close_rect, 10) then
                    wgt.elrs_tap_block = now + 100
                    wgt.detail_view = nil
                    init_view_state(wgt).dirty = true
                end
            elseif glyph_tap then
                -- menu entry (menu glyph): blocked only while genuinely flying (armed AND
                -- still connected). After a main-power loss where telemetry has dropped, the
                -- ARM sensor holds a STALE "armed" for ~30 s — but with telemetry gone the
                -- craft is no longer flying, so the menu must open again (bug: menu was dead
                -- while detail pages still worked). No config in flight otherwise.
                wgt.elrs_tap_block = now + 100
                wgt.menu_view = "menu"
                -- acknowledge the first-placement hint banner (persisted; checked
                -- like every other save — the in-memory ack still hides the
                -- hint for this session even when the write fails)
                if (wgt.options.SetupSeen or 0) ~= 1 then
                    wgt.options.SetupSeen = 1
                    if not ultidash_settings.save({ SetupSeen = 1 }) then
                        wgt.cfg_save_failed_text = nil
                        wgt.cfg_save_failed_until = (getTime() or 0) + 1000
                    end
                end
                init_view_state(wgt).dirty = true
            elseif init_view_state(wgt).current == "stats" then
                -- manual dismiss of the statistics page: the X in the top bar, and only
                -- it. It used to be ANY tap outside the menu glyph -- with nothing on the
                -- page saying so, which is the whole point of this change; the page also
                -- vanished on any fumbled touch while reading it. It still reappears with
                -- the next arm/disarm or reconnect cycle (flags cleared there).
                if rect_hit(touch_state, wgt.close_rect, 10) then
                    wgt.elrs_tap_block = now + 100
                    wgt.stats_dismissed = true
                    wgt.stats_tap_open = nil   -- C3: a tap-opened page closes the same way
                    init_view_state(wgt).dirty = true
                end
            elseif rect_hit(touch_state, wgt.battprofile_rect, 6)
                and not ultidash_functions.is_armed(wgt)
                and wgt.rf and wgt.rf.msp_allowed then
                -- battery-profile picker: switches the active profile via RFTool MSP
                -- (a config WRITE → DISARMED ONLY; the FC also blocks writes while armed)
                wgt.elrs_tap_block = now + 100
                -- read the current profile/config fresh on open (disarmed, so MSP is
                -- allowed) — otherwise the picker shows a value cached at connect time
                rf_service.refresh_data(wgt)
                -- The page's back arrow honours tool_back now that the Toolbox can open it
                -- too; a stale value from an earlier shortcut-opened tool would otherwise
                -- send the TAP route back into the Toolbox the user never visited.
                wgt.tool_back = nil
                wgt.menu_view = "battprofile"
                init_view_state(wgt).dirty = true
            elseif tap_details and rect_hit(touch_state, wgt.elrs_bar_rect, 10) then
                wgt.elrs_tap_block = now + 100   -- long: any tap closes, see above
                wgt.detail_view = "elrs"
                init_view_state(wgt).dirty = true
            elseif tap_details and rect_hit(touch_state, wgt.estatus_rect, 6) then
                wgt.elrs_tap_block = now + 100
                wgt.detail_view = "estatus"
                wgt.estatus_scroll = 0
                init_view_state(wgt).dirty = true
            elseif rect_hit(touch_state, wgt.statspage_rect, 6)
                and not ultidash_functions.is_armed(wgt) then
                -- C3: a tap on the status panel (outside its status line, checked above)
                -- opens the STATISTICS page — under StatsViewMode "Never" too, that mode
                -- governs only the automatic route. Disarmed only: while armed the view
                -- stays flight by construction, and a deferred open that popped the page
                -- at disarm, minutes after the tap, would read as a haunting.
                wgt.elrs_tap_block = now + 100
                wgt.stats_tap_open = true
                init_view_state(wgt).dirty = true
            elseif tap_details and rect_hit(touch_state, wgt.battery_rect, 6) then
                wgt.elrs_tap_block = now + 100
                wgt.detail_view = "battery"
                init_view_state(wgt).dirty = true
            elseif tap_details and rect_hit(touch_state, wgt.values_rect, 6) then
                wgt.elrs_tap_block = now + 100
                wgt.detail_view = "telem"
                init_view_state(wgt).dirty = true
            end
        end
    end
    -- Flight log: deferred SD work in its OWN cycle (same pattern as the sensor
    -- scan below) -- the CSV append / registry rewrite / registry load for the
    -- battery query never share a call's budget with the heavy pass or a rebuild.
    if wgt.flt_flush_req then
        wgt.flt_flush_req = nil
        fltlog.flush(wgt)
        return
    end
    if wgt.battpick_load_req then
        wgt.battpick_load_req = nil
        fltlog.open_battpick(wgt)
        return
    end
    if wgt.batted_req then                     -- battpick "+ New": own cycle (B11)
        wgt.batted_req = nil
        fltlog.open_batted(wgt)
        return
    end
    if wgt.flt_prof_req ~= nil and (getTime() or 0) >= (wgt.flt_prof_at or 0) then
        wgt.flt_prof_at = (getTime() or 0) + 20   -- retry cadence (~5 Hz)
        fltlog.write_profile(wgt)
        return
    end
    -- Sensor-check page: refresh the read-only scan at most once per second while
    -- the page is open, in an EXCLUSIVE cycle — same discipline as the
    -- app-id scan below: the ~60 getSensor reads never share a call's budget with
    -- the heavy pass; the page's touch belongs to its lvgl buttons and the host
    -- tap block only runs at menu_view==nil, so nothing is lost). The FIRST fill
    -- flags a rebuild: the page's first build only shows the "scanning" note and
    -- sets senscheck_next=0. Cleanup stays the single point here: drop
    -- the runtime state as soon as the page closes. Never touches MSP.
    if wgt.menu_view == "sensorcheck" then
        local snow = getTime() or 0
        if snow >= (wgt.senscheck_next or 0) then
            wgt.senscheck_next = snow + 100   -- 1 s (centiseconds)
            local first = (wgt.senscheck == nil)
            -- scan lives in the lazy menu module (loaded anyway while the page is open)
            local m = menu_load(wgt)
            if m then m.update_sensorcheck(wgt) end
            if first and wgt.senscheck ~= nil then
                init_view_state(wgt).dirty = true   -- swap the note for the real rows
            end
            return
        end
    elseif wgt.senscheck ~= nil then
        wgt.senscheck = nil
        wgt.senscheck_next = nil
    end
    -- App-id sensor resolution: a throttled (~3 s) session scan mapping curated names to
    -- verified telemetry indices, so core reads dodge duplicate/renamed CRSF sensors. Run in
    -- its OWN cycle (return) so its ~60 getSensor reads never share a call's budget with the
    -- heavy pass below; touch was already handled earlier this frame, so nothing is lost.
    do
        local snow = getTime() or 0
        if (snow - (wgt.sensor_scan_ts or -100000)) >= 300 then
            wgt.sensor_scan_ts = snow
            resolve_sensor_indices(wgt)
            return
        end
    end
    -- THROTTLE the telemetry/alert/publish pass to 5 Hz: with a connected FC the
    -- full update (~35 sensor-name lookups) on EVERY display cycle starved the Lua
    -- scheduler enough that fullscreen taps became a lottery (RFTool works the CRSF
    -- link in parallel). 5 Hz is plenty for the display and for the alerts (their
    -- debounce windows are 0.5-3 s) — taps above are still handled every cycle.
    -- While a menu page / the ELRS detail is up, the dashboard isn't visible at
    -- all: skip the heavy pass entirely (status page reads Shared; the detail only
    -- needs the cheap update_elrs) so page interaction stays snappy.
    -- Idle throttle: run the heavy telemetry/alert/publish pass AND the RF-service
    -- housekeeping at 5 Hz while a FC is linked, but back off to 2 Hz when
    -- disconnected — with no craft every sensor read returns nil, so there is nothing
    -- to do 5x/s and the radio CPU can idle more (lower battery drain). State CHANGES
    -- still arrive immediately via the rf2 onStateChanged callback (independent of this
    -- cadence), so a connecting FC is picked up without extra delay.
    local tnow = getTime() or 0
    local gate_cs = (wgt.values.rf_connection_state ~= "disconnected") and 20 or 50
    local ran_pass = false   -- heavy pass and a dirty REBUILD must not share one call (budget)
    if (tnow - (wgt.telem_gate or 0)) >= gate_cs then
        wgt.telem_gate = tnow
        ran_pass = true
        ensure_rf_service(wgt)
        -- Switch shortcuts: 6 position slots (hold = open) + 2 toggle slots (press =
        -- step). Edge/hold triggered, so they never fight manual navigation — open/close
        -- only touch the exact page a given binding controls. Works in flight (the menu
        -- glyph is disarmed-only; this is not); ArmClose still closes detail pages on arm
        -- (shared detail_view path). Lives INSIDE the 5 Hz gate: switch reads are
        -- pcall+getValue, so polling every display cycle (~20 Hz) was wasted work; the
        -- engine reacts in <=200 ms, plenty. While the Log Viewer is open refresh()
        -- returns BEFORE this gate — its exclusive branch calls shortcut.run itself.
        -- See the engine above (shortcut.run / shortcut.open / shortcut.close).
        shortcut.run(wgt)
        -- RF service skips too while RF2 Config is open: the tool owns
        -- rf2.mspQueue, and a state blip here would queue OUR 3 connect reads into
        -- it — no safety/corruption risk (the queue serialises, the callbacks only
        -- write wgt caches), but the reads delay the tool's own page traffic. State
        -- changes still arrive via the onStateChanged callback; a parked
        -- read_pending fires on the first pass after the tool closes.
        -- tb_rfscfg skips it for a HARDER reason than tb_rf2cfg. There the
        -- shared queue only got delayed; here RFSuite drives its own MSP stack and
        -- the adapter has stopped the rf2 pump outright, so a read queued now would
        -- sit unprocessed until the page closes.
        if wgt.menu_view ~= "tb_rf2cfg" and wgt.menu_view ~= "tb_rfscfg" then
            rf_service.background(wgt, handle_telemetry_state_change)
        end
        -- FULL pass even while the detail/menu pages are up: all dashboard
        -- functions (alerts, stats, callouts) keep running in the background —
        -- the ELRS detail may now stay open in flight. The 5 Hz throttle keeps
        -- the interaction snappy regardless.
        local pass_t0 = getTime() or 0
        -- The Log Viewer is a full-screen, disarmed-only tool that does its OWN heavy
        -- chunked file parse/extract/render against the same 20k instruction budget.
        -- The dashboard isn't visible under it, so skip the ~35-sensor foreground pass
        -- while it's open — otherwise loader chunk + this pass + rebuild share one call
        -- and trip "CPU limit" (seen on a tiny 27-line log). Arm detection below still
        -- runs, so the viewer keeps auto-closing on arm.
        -- tb_rf2cfg skips it for the same reason (RF2 pages do their own MSP +
        -- LVGL work in the same budget); its rf2.mspQueue ownership is covered by the
        -- rf_service gate above (disarmed-only, so no alerts/callouts are lost).
        -- Arm detection below still runs.
        if wgt.menu_view ~= "tb_logview" and wgt.menu_view ~= "tb_rf2cfg"
            and wgt.menu_view ~= "tb_rfscfg" then
            ultidash_functions.refresh(wgt)
            update_user_sensors(wgt)
            ultidash_functions.publish_shared(wgt)
            ultidash_functions.refresh_volume_override(wgt)   -- adaptive master volume via GVAR (off unless configured)
            ultidash_functions.update_elrs_notice(wgt)        -- ELRS<->FC link config verdict -> notice
            ultidash_functions.update_alert_overlay(wgt)      -- critical-alert overlay episode state
        end
        wgt.dbg_pass_cs = (getTime() or 0) - pass_t0
        -- cache the armed state for reactive closures (they run per LVGL frame;
        -- calling is_armed there would be a sensor name-lookup at ~20 Hz)
        wgt.armed_now = ultidash_functions.is_armed(wgt)
        -- diagnostics: perf snapshot + buffered SD flush (no-op unless DebugLog is on).
        -- A state-change flush request (handle_telemetry_state_change runs in the
        -- RFTool's budget) is honoured here, in OUR budget.
        if ultidash_functions.dbg then
            if wgt.dbg_flush_req then
                wgt.dbg_flush_req = nil
                ultidash_functions.dbg.flush(true)
            end
            ultidash_functions.dbg.tick(wgt)
        end
        -- arm/disarm edge bookkeeping (stats-dismiss clear + flight-log open/flush)
        -- — shared with background() so an off-screen flight books too
        fltlog.arm_edges(wgt)
        -- battery query: open once the connect settled (FC name arrived), only in
        -- fullscreen (touch) with nothing else on screen; armed = window closed
        if wgt.battpick_wait ~= nil and tnow >= wgt.battpick_wait then
            if wgt.armed_now then
                wgt.battpick_wait = nil
            elseif fs and wgt.menu_view == nil and wgt.detail_view == nil
                and wgt.values.rf_connection_state ~= "disconnected" then
                wgt.battpick_wait = nil
                wgt.battpick_load_req = true   -- registry load runs in its own cycle
            end
        end
        -- "Open page on arming", executed: ONE attempt, and every refusal is final. A
        -- page that appears seconds after the arm -- over whatever the pilot opened in
        -- the meantime -- is worse than one that never appeared, so there is no retry
        -- loop here. The gates are the tap route's own, not relaxed: full screen only (a
        -- widget zone gets no touch, so the page could not be closed), the module loaded,
        -- nothing else on screen, the flight view settled, and still armed -- a pilot who
        -- disarmed inside the delay gets nothing.
        if wgt.arm_open_at ~= nil and tnow >= wgt.arm_open_at then
            wgt.arm_open_at = nil
            local sc_tgt = shortcut.detail_choice(wgt.options.ArmOpen)
            if sc_tgt ~= nil and wgt.armed_now and wgt.detail_ok and fs
                and wgt.menu_view == nil and wgt.detail_view == nil
                and init_view_state(wgt).current == "flight" then
                wgt.detail_view = sc_tgt.id
                -- as the tap and shortcut routes do: a page opened part-scrolled from the
                -- last visit reads as a bug
                if sc_tgt.id == "estatus" then wgt.estatus_scroll = 0 end
                init_view_state(wgt).dirty = true
            end
        end
        if wgt.armed_now and wgt.values.rf_connection_state ~= "disconnected" then
            -- menu/settings/status close on arm (no configuring in flight; pending edits
            -- autosaved) — EXCEPT the Toolbox tool pages, which are meant for in-flight
            -- tuning (RF2 adjustment functions) and deliberately stay open while armed.
            -- The condition mirrors the menu-glyph OPEN gate (armed AND connected =
            -- genuinely flying): after a main-power loss with telemetry gone, the ARM
            -- sensor holds a stale "armed" for ~30 s — the open gate let the menu open
            -- in that window, but this close-on-arm then shut it again 200 ms later
            -- ("menu opens but won't stay open"). Disconnected = not flying -> keep it.
            -- tb_logview is disarmed-only: leave it to the module's own auto-close (M.refresh
            -- closes the file handle + sets lv_close_req), so the global nil'ing here can't
            -- drop menu_view without releasing the open /LOGS handle.
            -- tb_rf2cfg likewise: its own arm-close (M.refresh) must run so the
            -- rf2.* slots + mspQueue pump get restored before the view drops.
            -- tb_fltlog follows the same pattern (own arm-close in M.refresh sets
            -- fl_close_req) — it is not in the tb list because this branch is
            -- UNREACHABLE for it anyway: its exclusive refresh branch returns
            -- every cycle before the 5 Hz pass gets here.
            -- tb_livemon belongs in this list since M5: the tool has NO disarmed gate on
            -- purpose (shortcut.targets -- reading it in flight is its point) and it runs
            -- BESIDE the 5 Hz pass rather than exclusively (its design law), so without the
            -- exemption this state-based close shut it on every armed pass and the page
            -- could not be open in flight at all -- the exact opposite of its decision.
            -- tb_rfscfg for the rf2cfg reason and one more: its own arm-close is the
            -- only path that detaches RFSuite's MSP client and clears its module
            -- graph, so dropping menu_view from here would strand both.
            local tb = (wgt.menu_view == "tb_adjmap" or wgt.menu_view == "tb_adjed"
                or wgt.menu_view == "tb_logview" or wgt.menu_view == "tb_rf2cfg"
                or wgt.menu_view == "tb_livemon" or wgt.menu_view == "tb_rfscfg")
            if wgt.menu_view ~= nil and not tb then
                save_pending_settings(wgt)
                wgt.menu_view = nil
                init_view_state(wgt).dirty = true
            end
            -- the ELRS detail only closes on arm when the option says so — with
            -- it off the pilot can deliberately watch the link details in flight
            -- (alerts keep running either way)
            if wgt.detail_view ~= nil and wgt.options.ArmClose == 1 then
                wgt.detail_view = nil
                init_view_state(wgt).dirty = true
            end
        end
    end
    -- a completed MSP read updates wgt.values.* (e.g. the battery-profile picker's
    -- on-open refresh); rebuild an open menu page so it reflects the fresh data. The
    -- dashboard itself is reactive and needs no rebuild.
    if wgt.rf_data_dirty then
        wgt.rf_data_dirty = false
        -- not for tb_rf2cfg: the RF2 view shows no wgt.values, and a host
        -- rebuild would force the original framework to re-read its page
        if wgt.menu_view ~= nil and wgt.menu_view ~= "tb_rf2cfg"
            and wgt.menu_view ~= "tb_rfscfg" then
            init_view_state(wgt).dirty = true
        end
    end
    sync_view_for_telemetry(wgt)
    if init_view_state(wgt).dirty == true then
        -- Rebuild in its OWN 20 Hz cycle when the heavy telemetry pass already ran in
        -- THIS call: EdgeTX gives each widget call one instruction budget, and pass +
        -- full UI rebuild together overrun it ("CPU limit" — same reason the cfg
        -- snapshot above defers). The gate just fired, so the next cycle (~50 ms)
        -- arrives with a fresh budget and no pass; dirty stays set and the one-frame
        -- deferral is invisible.
        if ran_pass then return end
        return update(wgt, wgt.options)
    end
    update_status_bar_visibility(wgt)
end

-- set_version: main.lua hands its `app_ver` over right after loading this module, so the
-- version has exactly ONE home (the release rule bumps it there) and this file does not
-- carry a second copy to drift. Called before the first create(), so the Status page
-- always has it.
return { create = create, update = update, background = background, refresh = refresh,
         set_version = function(v) app_ver = v end }
