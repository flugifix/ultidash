local script_dir = "/WIDGETS/UltiDash/"
local ultidash_functions = loadScript(script_dir .. "ultidashFunctions.lua")()
local ultidash_values = loadScript(script_dir .. "ultidashValues.lua")()
local rf_service = loadScript(script_dir .. "ultidashRf.lua")()
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
do
    local okc, m = pcall(function() return loadScript(script_dir .. "toolbox/common.lua")() end)
    if okc then tb_common = m end
    -- ALL tool modules are LAZY-LOADED (see tb_load_* below): keeping the
    -- big Log Viewer (~75 KB source) resident from boot grew the Lua heap
    -- ~650 -> ~900 kB and the extra GC mark/sweep work dropped the whole UI
    -- loop from ~19 to ~15 Hz (debug_03 vs debug_04 PERF lines). At boot only
    -- check the files EXIST (menu entry visibility); missing -> no entry.
    tb_adjmap_avail  = fstat(script_dir .. "toolbox/adjmap.lua") ~= nil
    tb_adjed_avail   = fstat(script_dir .. "toolbox/adjed.lua") ~= nil
    tb_logview_avail = fstat(script_dir .. "toolbox/logview.lua") ~= nil
    tb_rf2cfg_avail  = fstat(script_dir .. "toolbox/rf2cfg.lua") ~= nil
    fltlog.avail      = fstat(script_dir .. "toolbox/fltlog.lua") ~= nil
    fltlog.data_avail = fstat(script_dir .. "toolbox/fltdata.lua") ~= nil
end

-- load a big toolbox module on first OPEN (disarmed-only pages, so the one-off
-- compile hiccup happens on a menu tap, never in flight); the module ref is
-- dropped again on CLOSE so nothing stays resident during flight. A failed
-- load clears the avail flag (entry disappears instead of failing repeatedly).
local function tb_load_adjmap()
    if tb_adjmap == nil and tb_adjmap_avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/adjmap.lua")() end)
        -- init inside the protection too: a raising init left a half-set-up
        -- module resident and crashed the widget state instead of degrading
        if ok and m ~= nil and (m.init == nil or pcall(m.init, tb_common)) then tb_adjmap = m
        else tb_adjmap_avail = false end
    end
    return tb_adjmap
end
local function tb_load_adjed()
    if tb_adjed == nil and tb_adjed_avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/adjed.lua")() end)
        if ok and m ~= nil and (m.init == nil or pcall(m.init, tb_common)) then tb_adjed = m
        else tb_adjed_avail = false end
    end
    return tb_adjed
end
local function tb_load_logview()
    if tb_logview == nil and tb_logview_avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/logview.lua")() end)
        if ok then tb_logview = m else tb_logview_avail = false end
    end
    return tb_logview
end
local function tb_load_rf2cfg()
    if tb_rf2cfg == nil and tb_rf2cfg_avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/rf2cfg.lua")() end)
        if ok then tb_rf2cfg = m else tb_rf2cfg_avail = false end
    end
    return tb_rf2cfg
end
function fltlog.load_viewer()
    if fltlog.mod == nil and fltlog.avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/fltlog.lua")() end)
        if ok then fltlog.mod = m else fltlog.avail = false end
    end
    return fltlog.mod
end
-- flight-log data core: unlike the big viewer it STAYS resident once loaded --
-- the disarm write needs it while the craft is still connected, and it is only
-- a few KB. Loaded on first use (battery query / first flight flush), so a
-- disabled feature costs nothing.
function fltlog.load_data()
    if fltlog.data == nil and fltlog.data_avail then
        local ok, m = pcall(function() return loadScript(script_dir .. "toolbox/fltdata.lua")() end)
        if ok then fltlog.data = m else fltlog.data_avail = false end
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
local THEME_PALETTE = {
    COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2,
    COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS, COLOR_THEME_WARNING, COLOR_THEME_DISABLED,
}
-- static "Clean Theme" (Mate Soos) values
local CLEAN_PALETTE = {
    lcd.RGB(0x00, 0x00, 0x00), lcd.RGB(0xF8, 0xFC, 0xF8), lcd.RGB(0x00, 0x00, 0x00), lcd.RGB(0x98, 0xB4, 0xE8),
    lcd.RGB(0xD8, 0xE0, 0xE8), lcd.RGB(0xC0, 0x30, 0x38), lcd.RGB(0xE8, 0x30, 0x30), lcd.RGB(0xF8, 0x3C, 0x00),
}
-- static "UltiDash dark" high-contrast palette (bright text + NEON accents on black).
-- Slots map the same way as CLEAN/THEME: 1 PRIMARY1, 2 PRIMARY2, 3 SECONDARY1,
-- 4 SECONDARY2, 5 SECONDARY3, 6 FOCUS, 7 WARNING, 8 DISABLED. Text roles (PRIMARY1,
-- SECONDARY1) stay near-white for readability; the accents (SECONDARY2 neon green,
-- FOCUS neon cyan, WARNING neon red, DISABLED neon amber) glow against the black panel.
local DARK_PALETTE = {
    lcd.RGB(0xFF, 0xFF, 0xFF), lcd.RGB(0x08, 0x0A, 0x0C), lcd.RGB(0xF0, 0xF4, 0xF8), lcd.RGB(0x39, 0xFF, 0x14),
    lcd.RGB(0x08, 0x0A, 0x0C), lcd.RGB(0x00, 0xE5, 0xFF), lcd.RGB(0xFF, 0x1A, 0x40), lcd.RGB(0xFF, 0xC4, 0x00),
}

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
local function color_luma(c)
    local n = color_to_rgb24(c)
    return 0.299 * ((n >> 16) & 0xFF) + 0.587 * ((n >> 8) & 0xFF) + 0.114 * (n & 0xFF)
end
-- Below this luminance the surface under our text counts as "dark" -> use the neon semantic
-- set (resolve_builtins evaluates it live per scheme). Verified against the light and a
-- dark EdgeTX stock theme; tune within ~80..140.
local DARK_LUMA_THRESHOLD = 96

-- Bumped on every settings save/reset. Module-local -> shared across ALL instances of the
-- widget (one loaded chunk, same as Shared). Two uses: (1) it invalidates the palette memo
-- (pal_memo) so a colour edit takes effect on the very next rebuild; (2) it folds into
-- passive_style_sig so a passive ELRS/Status instance rebuilds when the Dashboard changes a
-- colour OVERRIDE (which leaves the scheme / bg-fill unchanged and would otherwise not trip
-- the passive rebuild check).
local settings_gen = 0

-- scheme numbering — matches the ColorScheme choice order (see SETTINGS_DISPLAY):
--   1 = UltiDash (clean/white), 2 = UltiDash dark (high contrast), 3 = EdgeTX theme.
-- (Order changed in v0.6.0: dark moved to slot 2, EdgeTX theme to slot 3 — a one-time cfg
-- migration in ultidashSettings remaps stored values so nobody's pick changes.)
local SCHEME_ULTIDASH = 1
local SCHEME_DARK     = 2
local SCHEME_THEME    = 3

-- The configurable colour ROLES — the single source for the Colors settings pages, the
-- override lookup and the picker's "current value". `slot` = palette index 1..8; `sem` = a
-- traffic-light key; `chrome` = a neutral-chrome key. `theme = true` marks the roles offered
-- even in EdgeTX-theme mode (the ones the EdgeTX theme does NOT itself define — only the
-- traffic-light colours). `grp` drives the section headers on the page.
local COLOR_ROLES = {
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
-- a role is offered for a scheme when: UltiDash light/dark -> all roles; EdgeTX theme -> only
-- the roles flagged `theme` (the traffic-light colours the theme itself doesn't define)
local function role_in_scheme(role, scheme)
    return scheme ~= SCHEME_THEME or role.theme == true
end
-- cfg key for a (scheme, role) override: "Clr" + scheme tag + role key. All charset-safe for
-- the cfg parser ([%w_]+). Value = 0xRRGGBB (>=0 = override) or -1 (unset -> built-in).
local SCHEME_TAG = { [SCHEME_ULTIDASH] = "U", [SCHEME_DARK] = "D", [SCHEME_THEME] = "E" }
-- The (scheme, role) -> cfg-key mapping is fixed, but this used to re-concatenate
-- "Clr"..tag..role.k on every palette rebuild (23 keys/rebuild -> GC churn). Memoise it,
-- nested by role (a stable table key) then scheme.
local color_key_cache = {}
local function color_key(scheme, role)
    local per_role = color_key_cache[role]
    if per_role == nil then per_role = {}; color_key_cache[role] = per_role end
    local k = per_role[scheme]
    if k == nil then k = "Clr" .. (SCHEME_TAG[scheme] or "U") .. role.k; per_role[scheme] = k end
    return k
end

-- Pure resolver of a scheme's BUILT-IN colours (no side effects): the single definition of
-- what each scheme looks like before overrides. set_palette applies overrides on top of this,
-- and the settings picker uses it to show the current value of an unset (default) colour.
local function resolve_builtins(scheme)
    local clean = (scheme == SCHEME_ULTIDASH)
    local dark  = (scheme == SCHEME_DARK)
    local base  = dark and DARK_PALETTE or (clean and CLEAN_PALETTE or THEME_PALETTE)
    local pal   = { base[1], base[2], base[3], base[4], base[5], base[6], base[7], base[8] }
    -- scheme dark is always dark, clean always light; EdgeTX theme follows the theme panel
    -- luminance (SECONDARY3 = the surface we paint when BGFilled is on). LIMIT: with BGFilled=0
    -- the text sits on the theme wallpaper, which can differ from SECONDARY3 (accepted).
    local dui = dark or (not clean and color_luma(THEME_PALETTE[5]) < DARK_LUMA_THRESHOLD)
    -- semantic traffic-light colours: neon on a dark surface, muted otherwise
    local sem
    if dui then
        sem = { green = lcd.RGB(0x39, 0xFF, 0x14), yell = lcd.RGB(0xFF, 0xE0, 0x00),
                red   = lcd.RGB(0xFF, 0x1A, 0x40), neut = lcd.RGB(0xA8, 0xB0, 0xB8) }
    else
        sem = { green = lcd.RGB(0x20, 0xB0, 0x20), yell = lcd.RGB(0xF0, 0xC0, 0x00),
                red   = lcd.RGB(0xE0, 0x30, 0x30), neut = lcd.RGB(0x4A, 0x4A, 0x4A) }
    end
    local chrome
    if dark then
        chrome = { bg = lcd.RGB(0x00, 0x00, 0x00), track = lcd.RGB(0x28, 0x30, 0x38),
                   tick = lcd.RGB(0xFF, 0xFF, 0xFF), dim = lcd.RGB(0xC0, 0xC8, 0xD0) }
    elseif clean then
        chrome = { bg = lcd.RGB(0xFF, 0xFF, 0xFF), track = lcd.RGB(0xC8, 0xC8, 0xC8),
                   tick = lcd.RGB(0x20, 0x20, 0x20), dim = lcd.RGB(0x90, 0x90, 0x90) }
    else
        -- EdgeTX theme: chrome derives from the theme palette (subtle fill / strong line / dim)
        chrome = { bg = pal[5], track = pal[4], tick = pal[3], dim = pal[8] }
    end
    -- battery fills (main bar levels + TX battery icon): historically fixed, never
    -- theme-driven — the same built-ins for every scheme (values = the old BAR_COLOR_* /
    -- vtx_fill_color literals, so the default look is unchanged)
    local batt = {
        ok    = lcd.RGB(0x00, 0xFF, 0x00), warn = lcd.RGB(0xF8, 0xC0, 0x00),
        low   = lcd.RGB(0xFF, 0xFF, 0x00), crit = lcd.RGB(0xFF, 0x00, 0x00),
        check = lcd.RGB(0xB8, 0xB8, 0xB8),
        vtx_ok = lcd.RGB(0x30, 0xC0, 0x30), vtx_low = lcd.RGB(0xFF, 0x33, 0x33),
    }
    -- statusbar arm-state text built-ins: the colours the text historically used
    -- (armed = traffic-light green, disarmed = the WARNING palette slot)
    local stat = { armed = sem.green, disarmed = pal[7] }
    return { pal = pal, sem = sem, chrome = chrome, batt = batt, stat = stat,
             dark = dark, clean = clean, dark_ui = dui }
end

-- resolve_builtins is pure per scheme (a handful of lcd.RGB allocations + a few tables) and its
-- result never changes within a session, so cache it per scheme. set_palette COPIES b.pal
-- before overlaying overrides, so the cached tables stay pristine across rebuilds.
local builtins_cache = {}
local function cached_builtins(scheme)
    local b = builtins_cache[scheme]
    if b == nil then b = resolve_builtins(scheme); builtins_cache[scheme] = b end
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
local function build_overrides(options, scheme)
    if not options then return nil end
    local o = nil
    for i = 1, #COLOR_ROLES do
        local role = COLOR_ROLES[i]
        if role_in_scheme(role, scheme) then
            local v = options[color_key(scheme, role)]
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
-- instances. Two simultaneously visible instances with DIVERGENT schemes (e.g. a passive
-- view before its style-sig rebuild caught up) render their reactive colours from
-- whichever instance repainted last. Accepted: the passive views follow the Dashboard's
-- scheme by design, so divergence is a one-rebuild transient.
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
local pal_memo = { scheme = nil, gen = -1, neutral = nil, b = nil, ovr = nil }

-- Palette for the Toolbox tool pages so they FIT the dashboard's look. The tools are kept
-- MONOCHROME like the detail pages (light = black on light-grey, dark = white on dark-grey):
-- header, labels and the +/- buttons use the theme fg/greys, and ONLY the VALUES carry the
-- scheme accent colour so they stand out (the "blue everywhere" of the old palette is gone).
-- Handed to the tool modules via wgt.tb_pal (the sunlight option overrides inside the module).
local function toolbox_palette(scheme)
    if scheme == SCHEME_ULTIDASH then  -- UltiDash clean (light): mono black/grey, values in the accent
        return { bg = lcd.RGB(248,250,248), accent = lcd.RGB(24,24,24), hint = lcd.RGB(216,96,0), line = lcd.RGB(180,184,190),
                 text = lcd.RGB(24,24,24), textDim = lcd.RGB(130,130,130),
                 valText = lcd.RGB(48,90,144), valHi = lcd.RGB(192,48,56), bannerBg = lcd.RGB(192,48,40), bannerFg = lcd.RGB(255,255,255),
                 btnBg = lcd.RGB(208,212,218), btnPressed = lcd.RGB(184,190,200), btnDim = lcd.RGB(226,228,231), btnFg = lcd.RGB(24,24,24) }
    elseif scheme == SCHEME_DARK then  -- UltiDash dark: mono white/grey, values in the neon accent
        return { bg = lcd.RGB(0,0,0), accent = lcd.RGB(240,240,240), hint = lcd.RGB(255,122,26), line = lcd.RGB(56,60,64),
                 text = lcd.RGB(240,240,240), textDim = lcd.RGB(150,156,162),
                 valText = lcd.RGB(0,229,255), valHi = lcd.RGB(255,176,0), bannerBg = lcd.RGB(255,68,56), bannerFg = lcd.RGB(0,0,0),
                 btnBg = lcd.RGB(48,52,58), btnPressed = lcd.RGB(74,80,88), btnDim = lcd.RGB(34,36,40), btnFg = lcd.RGB(235,235,235),
                 dark = true }   -- Log Viewer picks its dark neon curve colours off this flag
    else                        -- EdgeTX theme: mono theme fg/bg, values in the theme focus colour
        return { bg = COLOR_THEME_SECONDARY3, accent = COLOR_THEME_PRIMARY1, hint = COLOR_THEME_DISABLED, line = COLOR_THEME_SECONDARY1,
                 text = COLOR_THEME_PRIMARY1, textDim = COLOR_THEME_DISABLED,
                 valText = COLOR_THEME_FOCUS, valHi = COLOR_THEME_WARNING, bannerBg = COLOR_THEME_WARNING, bannerFg = COLOR_THEME_PRIMARY2,
                 btnBg = COLOR_THEME_SECONDARY2, btnPressed = COLOR_THEME_SECONDARY1, btnDim = COLOR_THEME_SECONDARY3, btnFg = COLOR_THEME_PRIMARY2 }
    end
end
-- Header font - set dynamically in the active UI builder based on available space.
-- MODULE-WIDE MUTABLES: only read these in code that runs AFTER the active
-- builder (build_flight_ui/build_stats_ui) has set them for the current zone — a read
-- before/outside that path sees the previous build's values. Restructure only with the
-- v0.7 module split.
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

local FONT_CONSTANTS = {
    TINSIZE = TINSIZE,
    SMLSIZE = SMLSIZE,
    STDSIZE = STDSIZE,
    MIDSIZE = MIDSIZE,
    DBLSIZE = DBLSIZE,
    XXLSIZE = XXLSIZE
}

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

-- NOTE: each placed instance gets its OWN widget table (created in `create`), so a
-- second instance (ViewMode = ELRS details / Status info) on another screen has its
-- own zone/options/values. Cross-instance data flows ONLY through the module-local
-- `Shared` table in ultidashFunctions (publisher = the Dashboard-mode instance).

local VIEW_MODE_DASHBOARD = 1
local VIEW_MODE_ELRS      = 2
local VIEW_MODE_STATUS    = 3

--- The Dashboard-mode instance is the publisher: it alone runs the RF state machine,
--- MSP, audio/stats side effects and publishes the Shared snapshot. ELRS/Status
--- instances are passive (sensor reads + rendering only).
local function is_publisher(widget)
    -- lenient: anything that isn't explicitly a passive mode counts as Dashboard
    -- (an out-of-range stored value — e.g. after the option-list change — must
    -- never silently turn a Dashboard placement passive and kill audio/MSP)
    local vm = widget.options and widget.options.ViewMode
    return vm ~= VIEW_MODE_ELRS and vm ~= VIEW_MODE_STATUS
end

--- Signature of everything a passive view inherits from the Dashboard (publisher
--- alive? which palette/background?). Compared each refresh against the value stored
--- at build time — on change the passive view rebuilds itself, so it follows the
--- Dashboard's look live and flips to/from the "no Dashboard" notice automatically.
local function passive_style_sig()
    -- numeric on purpose: this runs every refresh cycle of passive instances and
    -- a string build there would churn the garbage collector
    if not ultidash_functions.shared_alive() then return -1 end
    local shared = ultidash_functions.get_shared()
    -- settings_gen (shared module-local, bumped on every save/reset) is folded in so a colour
    -- OVERRIDE change on the Dashboard — which leaves color_scheme / bg_filled untouched — still
    -- changes the signature and rebuilds this passive view onto the new palette.
    -- *8, NOT *4: the base term spans 2..7 (scheme 1..3 *2 + bg), so a *4 step collided
    -- with a scheme change — e.g. scheme 3→1 (base −4) plus the save's gen+1 (+4) left
    -- the signature unchanged and the passive view kept the old palette.
    return (shared.color_scheme or 0) * 2 + (shared.bg_filled and 1 or 0) + settings_gen * 8
end

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
        if previous_state == "armed" then
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

--- Attach the RF service lazily and only for the publisher (Dashboard) instance.
--- ELRS/Status instances never register with rf2 → no second MSP consumer, no
--- duplicate state-machine callbacks. Lazy (not in prepare_widget) so a mode change
--- via the options menu picks the service up on the next cycle.
local function ensure_rf_service(widget)
    if widget.rf_service_ready then return end
    -- 3rd arg: the ARM-sensor predicate for the MSP read gate — the
    -- service must never fire reads while the craft is armed, whatever the
    -- RFTool connection state claims
    rf_service.init(widget, handle_telemetry_state_change, ultidash_functions.is_armed)
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
-- appId = the Rotorflight custom-telemetry app ID (0x1000+ range, from rf2tlm_sensors.lua).
-- It is the STABLE, unique reference: EdgeTX can create a same-named native CRSF sensor
-- (RxBt/Curr/Capa/Bat% …), so name lookups are ambiguous; the app-id resolver reads the RIGHT
-- sensor by this ID. ELRS link + name-only sensors carry no appId (no RF custom sensor).
local SENSOR_INFO = {
    -- battery / cells
    Vbat     = { lbl = "Battery",      dec = 2, unit = "V",   appId = 0x1011 },
    Curr     = { lbl = "Current",      dec = 1, unit = "A",   appId = 0x1012 },
    Capa     = { lbl = "Energy Used",  dec = 0, unit = "mAh", appId = 0x1013 },
    ["Bat%"] = { lbl = "Fuel",         dec = 0, unit = "%",   appId = 0x1014 },
    ["Cel#"] = { lbl = "Cells",        dec = 0, unit = "",    appId = 0x1020 },
    Vcel     = { lbl = "Cell",         dec = 2, unit = "V",   appId = 0x1021 },
    Cels     = { lbl = "Cell V",       dec = 2, unit = "V" },   -- composite (no single appId)
    Thr      = { lbl = "Throttle",     dec = 0, unit = "%",   appId = 0x1035 },
    -- ESC #1
    EscV     = { lbl = "ESC Voltage",  dec = 2, unit = "V",   appId = 0x1041 },
    EscI     = { lbl = "ESC Current",  dec = 1, unit = "A",   appId = 0x1042 },
    EscC     = { lbl = "ESC Used",     dec = 0, unit = "mAh", appId = 0x1043 },
    EscR     = { lbl = "ESC RPM",      dec = 0, unit = "rpm", appId = 0x1044 },
    EscP     = { lbl = "ESC PWM",      dec = 1, unit = "%",   appId = 0x1045 },
    ["Esc%"] = { lbl = "ESC Load",     dec = 1, unit = "%",   appId = 0x1046 },
    EscT     = { lbl = "ESC Temp",     dec = 0, unit = "°C",  appId = 0x1047 },
    BecT     = { lbl = "BEC T (ESC)",  dec = 0, unit = "°C",  appId = 0x1048 },
    BecV     = { lbl = "BEC V (ESC)",  dec = 2, unit = "V",   appId = 0x1049 },
    BecI     = { lbl = "BEC I (ESC)",  dec = 1, unit = "A",   appId = 0x104A },
    -- ESC #2
    Es2V     = { lbl = "ESC2 Voltage", dec = 2, unit = "V",   appId = 0x1051 },
    Es2I     = { lbl = "ESC2 Current", dec = 1, unit = "A",   appId = 0x1052 },
    Es2C     = { lbl = "ESC2 Used",    dec = 0, unit = "mAh", appId = 0x1053 },
    Es2R     = { lbl = "ESC2 RPM",     dec = 0, unit = "rpm", appId = 0x1054 },
    Es2T     = { lbl = "ESC2 Temp",    dec = 0, unit = "°C",  appId = 0x1057 },
    -- rails / currents
    Vesc     = { lbl = "ESC Rail V",   dec = 2, unit = "V",   appId = 0x1080 },
    Vbec     = { lbl = "BEC Voltage",  dec = 2, unit = "V",   appId = 0x1081 },
    Vbus     = { lbl = "Bus Voltage",  dec = 2, unit = "V",   appId = 0x1082 },
    Vmcu     = { lbl = "MCU Voltage",  dec = 2, unit = "V",   appId = 0x1083 },
    Iesc     = { lbl = "ESC Rail I",   dec = 1, unit = "A",   appId = 0x1090 },
    Ibec     = { lbl = "BEC Current",  dec = 1, unit = "A",   appId = 0x1091 },
    Ibus     = { lbl = "Bus Current",  dec = 1, unit = "A",   appId = 0x1092 },
    Imcu     = { lbl = "MCU Current",  dec = 1, unit = "A",   appId = 0x1093 },
    -- temperatures
    Tesc     = { lbl = "ESC Temp",     dec = 0, unit = "°C",  appId = 0x10A0 },
    Tbec     = { lbl = "BEC Temp",     dec = 0, unit = "°C",  appId = 0x10A1 },
    Tmcu     = { lbl = "MCU Temp",     dec = 0, unit = "°C",  appId = 0x10A3 },
    Tair     = { lbl = "Air Temp",     dec = 0, unit = "°C" },   -- name-only (not in the
    Tmtr     = { lbl = "Motor Temp",   dec = 0, unit = "°C" },   -- RF2 sensor table; harmless
    Tbat     = { lbl = "Batt Temp",    dec = 0, unit = "°C" },   -- if a model reports them
    -- rotor / speeds / MCU loads
    Hspd     = { lbl = "Headspeed",    dec = 0, unit = "rpm", appId = 0x10C0 },
    Tspd     = { lbl = "Tailspeed",    dec = 0, unit = "rpm", appId = 0x10C1 },
    ["CPU%"] = { lbl = "CPU Load",     dec = 0, unit = "%",   appId = 0x1141 },
    ["SYS%"] = { lbl = "SYS Load",     dec = 0, unit = "%",   appId = 0x1142 },
    ["RT%"]  = { lbl = "RT Load",      dec = 0, unit = "%",   appId = 0x1143 },
    -- altitude / attitude / GPS
    Alt      = { lbl = "Altitude",     dec = 1, unit = "m",   appId = 0x10B2 },
    Var      = { lbl = "Vario",        dec = 1, unit = "m/s", appId = 0x10B3 },
    Hdg      = { lbl = "Heading",      dec = 1, unit = "°",   appId = 0x10B1 },
    Sats     = { lbl = "GPS Sats",     dec = 0, unit = "",    appId = 0x1121 },
    GSpd     = { lbl = "GPS Speed",    dec = 1, unit = "m/s", appId = 0x1128 },
    GAlt     = { lbl = "GPS Alt",      dec = 1, unit = "m",   appId = 0x1126 },
    GDis     = { lbl = "GPS Dist",     dec = 1, unit = "m",   appId = 0x1129 },
    CPtc     = { lbl = "Ctrl Pitch",   dec = 1, unit = "°",   appId = 0x1031 },
    CRol     = { lbl = "Ctrl Roll",    dec = 1, unit = "°",   appId = 0x1032 },
    CYaw     = { lbl = "Ctrl Yaw",     dec = 1, unit = "°",   appId = 0x1033 },
    CCol     = { lbl = "Ctrl Coll",    dec = 1, unit = "°",   appId = 0x1034 },
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

-- appId -> canonical SENSOR_INFO name (built from the table above), for the app-id resolver:
-- a scanned sensor whose model-sensor `id` matches an appId is our known sensor, even if the
-- user renamed it or a native CRSF sensor stole the name.
local NAME_BY_APPID = {}
for name, info in pairs(SENSOR_INFO) do
    if info.appId then NAME_BY_APPID[info.appId] = name end
end

-- precision learned live from model.getSensor (used only for unknown sensors)
local sensor_prec_cache = {}

-- Sensors the dashboard already computes into wgt.values.* (with latching /
-- plausibility filtering AND simulator demo data). Prefer those fields over a raw
-- getSourceValue read: correct on hardware and populated in the simulator, where
-- getSourceValue has no real sensors. Other sensors fall back to the 5 Hz cache.
local SENSOR_VALUE_FIELD = {
    Vbat = "vbat", Vcel = "vcel", ["Cel#"] = "cel_count",
    Curr = "curr", Capa = "capa", ["Bat%"] = "capa_percent",
    -- Curr follows the CurrSrc setting: the Current row / value.curr shows the
    -- CONFIGURED source (Curr/EscI/Iesc), not necessarily the raw Curr sensor.
    Tesc = "esc_temp", Vbec = "vbec", Hspd = "headspeed",
    ["~escl"] = "esc_load_pct",   -- virtual: computed by update_esc_load_warning
}

-- keys of all configurable value slots (5 panel + 12 detail)
local PANEL_SLOT_KEYS  = { "PanelV1", "PanelV2", "PanelV3", "PanelV4", "PanelV5" }
local DETAIL_SLOT_KEYS = { "DetV1", "DetV2", "DetV3", "DetV4", "DetV5", "DetV6",
                          "DetV7", "DetV8", "DetV9", "DetV10", "DetV11", "DetV12" }
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
}
-- choice-row labels for the shortcut settings (built once, mirrors shortcut.targets)
shortcut.tlabels = {}
for i = 1, #shortcut.targets do shortcut.tlabels[i] = shortcut.targets[i].lbl end

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
    local scan, name_count = {}, {}     -- model_index -> {name,id};  name -> count (for anchor)
    for i = 0, 59 do
        local ok, s = pcall(model.getSensor, i)
        if ok and type(s) == "table" and type(s.name) == "string" and s.name ~= "" then
            scan[i] = { name = s.name, id = s.id }
            name_count[s.name] = (name_count[s.name] or 0) + 1
        end
    end
    -- Cheap change signature over the sensor list: the expensive derivation below only reruns
    -- when the model's sensors actually changed (discovery, delete, reorder). Renames keep the
    -- slot+id, so a stale map stays CORRECT (index reads are rename-immune by design).
    local sig = 0
    for i = 0, 59 do
        local e = scan[i]
        if e then sig = (sig * 33 + (type(e.id) == "number" and e.id or 1) + i) & 0x7FFFFFFF end
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
    local src = wgt.settings_working or wgt.options or {}
    local function add_known(name) if name and SENSOR_INFO[name] then add(name) end end
    for i = 1, #PANEL_SLOT_KEYS  do add_known(src[PANEL_SLOT_KEYS[i]])  end
    for i = 1, #DETAIL_SLOT_KEYS do add_known(src[DETAIL_SLOT_KEYS[i]]) end
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

    -- value + low/high: only needed by the open telemetry detail page, and only for its
    -- slots. The detail page shows RAW data, so pull the raw value here too (even for the
    -- "mapped" sensors that the dashboard shows latched) into a dedicated raw cache.
    if wgt.detail_view == "telem" then
        local craw = v.user_sensors_raw; if craw == nil then craw = {}; v.user_sensors_raw = craw end
        local cmin = v.user_sensors_min; if cmin == nil then cmin = {}; v.user_sensors_min = cmin end
        local cmax = v.user_sensors_max; if cmax == nil then cmax = {}; v.user_sensors_max = cmax end
        for i = 1, #DETAIL_SLOT_KEYS do
            local key = DETAIL_SLOT_KEYS[i]
            local name = o[key]
            if not is_off_sensor(name) and name ~= VOLT_AUTO and name ~= ESCL_AUTO then
                local rs = raw_sources(name, key)
                local okv, val
                if rs then okv, val = pcall(getSourceValue, rs.v) end
                if not (okv and val ~= nil) then okv, val = pcall(ultidash_functions.read_src, wgt, name) end
                if okv and val ~= nil then craw[name] = val end
                local okn, vmin
                if rs and rs.mn then okn, vmin = pcall(getSourceValue, rs.mn) end
                if not (okn and vmin ~= nil) then okn, vmin = pcall(ultidash_functions.read_src, wgt, name .. "-") end
                if okn and vmin ~= nil then cmin[name] = vmin end
                local okx, vmax
                if rs and rs.mx then okx, vmax = pcall(getSourceValue, rs.mx) end
                if not (okx and vmax ~= nil) then okx, vmax = pcall(ultidash_functions.read_src, wgt, name .. "+") end
                if okx and vmax ~= nil then cmax[name] = vmax end
            end
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
    local rows = {}
    for i = 1, 5 do
        local name = wgt.options[PANEL_SLOT_KEYS[i]] or SENSOR_OFF
        if name == VOLT_AUTO then
            rows[i] = {
                title = wgt.values.display_voltage_label_short,
                value = wgt.values.display_voltage_formatted,
                test  = wgt.values.display_voltage_test(),
                color = wgt.values.display_voltage_color
            }
        elseif is_off_sensor(name) then
            rows[i] = { title = "", value = "", test = "9999", color = COLOR_THEME_PRIMARY1 }
        else
            rows[i] = {
                title = fit_label(sensor_short_label(name)),
                value = sensor_value_text(wgt, name),
                test  = sensor_test_text(name),
                color = (name == ESCL_AUTO) and esc_load_color(wgt) or COLOR_THEME_PRIMARY1,
                esc_bar = esc_on and (name == curr_name)
            }
        end
    end
    local value_font = pick_smallest_font(
        select_font(row_h - 2, value_w, rows[1].test),
        select_font(row_h - 2, value_w, rows[2].test),
        select_font(row_h - 2, value_w, rows[3].test),
        select_font(row_h - 2, value_w, rows[4].test),
        select_font(row_h - 2, value_w, rows[5].test)
    )
    local value_font_h = measure_font(value_font)

    for i = 1, 5 do
        local current_row_h = row_h
        local row_y = start_y + (i - 1) * (row_h + row_gap)
        local value_y = row_y + math.floor((current_row_h - value_font_h) / 2)
        local label_y = row_y + math.floor((current_row_h - header_h) / 2)

        build_card_element(container, x, y + row_y, c_w, current_row_h, {
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
            }, {
            type = "label",
            x = value_x,
            y = value_y - row_y,
            w = value_w,
            h = value_font_h,
            text = rows[i].value,
            font = value_font,
            color = rows[i].color,
            align = RIGHT
        }
        })

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
    -- fewer, chunkier segments (was 8..12) for a bolder look
    local segment_count = math.max(6, math.min(9, math.floor(inner_h / 16)))
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
    local flights_font = select_font(h_meta - header_h, half_w, "9999")
    local flights_font_h = measure_font(flights_font)
    local time_font = select_font(h_meta - header_h, inner_w - half_w, "999:59:59")
    local time_font_h = measure_font(time_font)
    local meta_value_h = math.max(flights_font_h, time_font_h)
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
            color = function() return wgt.values.timer_color() end,
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
        wgt.values.label_total_flights, wgt.values.rf_total_flights_display_formatted, flights_font, flights_font_h)
    add_stacked_field(status_children, pad + half_w, y_meta, inner_w - half_w, meta_pad,
        "Total Time", wgt.values.rf_total_flight_time_display_formatted, time_font, time_font_h)

    -- headline status row: Governor State (left) + Throttle (right)
    add_stacked_field(status_children, pad, y_gt, gov_w, gt_pad,
        "Governor", wgt.values.gov_state_formatted, gov_font, gov_font_h)
    add_stacked_field(status_children, pad + gov_w, y_gt, thr_w, gt_pad,
        wgt.values.label_throttle, function() return wgt.values.throttle_text end, thr_font, thr_font_h)

    -- ESC / arming status line (full width, colored; blank when all OK).
    -- Tapping it (fullscreen) opens the status detail page — remember its rect
    -- in widget coords for the hit-test in refresh().
    wgt.estatus_rect = { x = x + pad, y = y + y_esc, w = inner_w, h = h_esc }
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
    local icon_h = math.max(8, c_h - 2)
    local icon_w = math.max(30, math.floor(icon_h * 2.6))
    local term_w = math.max(2, math.floor(icon_w * 0.06))
    local icon_x = x + c_w - icon_w - term_w - 1
    local icon_y = y + math.floor((c_h - icon_h) / 2)
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
        local rq_warn = wgt.options.RQlyWarn or 50
        local rq_crit = wgt.options.RQlyCrit or 30
        local rs_warn = wgt.options.RssWarn or 50
        local rs_crit = wgt.options.RssCrit or 25

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
                if v < crit then return C_RED end
                if v < warn then return C_YELL end
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
                elems[#elems + 1] = {
                    type = "rectangle", x = fx, y = fy, w = 1, h = fh, filled = true, rounded = 1,
                    color = fill_color(get, warn, crit),
                    pos = function() return fx, fy end,
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
                elems[#elems + 1] = {
                    type = "rectangle", x = center_x, y = by, w = 1, h = bar_h, filled = true,
                    color = fill_color(get, warn, crit),
                    pos = function() return center_x, by end,
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
        color = function() return wgt.values.vtx_fill_color() end,
        pos = function() return icon_x + 1, icon_y + 1 end,
        size = function() return math.max(0, math.floor((icon_w - 2) * wgt.values.vtx_fill_ratio())), icon_h - 2 end
    }
    icon_elems[#icon_elems + 1] = {
        type = "rectangle",
        x = icon_x,
        y = icon_y,
        w = icon_w,
        h = icon_h,
        thickness = 1,
        color = COLOR_THEME_PRIMARY1
    }
    container:build(icon_elems)

    -- percentage overlaid on the icon (drawn last → on top of the fill). Ink from
    -- the EFFECTIVE fill colours' luma (same build-time decision as the
    -- fuel gauge's overlay_ink): fixed BLACK was unreadable on a dark ClrXO/ClrXL
    -- override. Defaults are both above the threshold -> BLACK, look unchanged.
    local vtx_ink = (color_luma(SEM.vtx_ok) > DARK_LUMA_THRESHOLD
        and color_luma(SEM.vtx_low) > DARK_LUMA_THRESHOLD) and BLACK or WHITE
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

--- Notice page shown by passive views while NO Dashboard instance is running.
--- The passive views deliberately have no life of their own ("the main widget is
--- the boss") — without a publisher there is nothing trustworthy to show.
local function build_missing_dashboard_view(wgt, zone, title)
    local w = zone.w
    local h = zone.h
    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG, filled = false })
    panel:label({ x = 10, y = 6, text = title, font = h >= 170 and MIDSIZE or 0, color = COLOR_THEME_PRIMARY1 })
    panel:label({ x = 10, y = math.floor(h / 2) - 22, w = w - 20, h = 20,
        text = "No Dashboard instance running", font = 0, color = COLOR_THEME_PRIMARY1, align = CENTER })
    panel:label({ x = 10, y = math.floor(h / 2) + 2, w = w - 20, h = 20,
        text = "place an UltiDash with ViewMode = Dashboard", font = SMLSIZE, color = COLOR_THEME_DISABLED, align = CENTER })
end

--- Build the ELRS link detail view (ViewMode = "ELRS details", passive instance).
--- Labeled horizontal bars (RQ, TQ, 1RSS, 2RSS) with reactive crit/warn ticks +
--- values, rate/mode header and SNR/diversity footer. Thresholds AND look (palette,
--- background) come exclusively from the Dashboard instance via Shared — requires a
--- running Dashboard (notice page otherwise).
--- NO image / NO focusable objects — safe for any screen.
--- as_detail: built as the Dashboard instance's own detail page (opened by tapping
--- the top-bar bars) — adds the close hint + a full-area invisible close button in
--- normal mode (in fullscreen the tap-anywhere close is hit-tested in refresh()).
local function build_elrs_view(wgt, zone, as_detail)
    if not ultidash_functions.shared_alive() then
        return build_missing_dashboard_view(wgt, zone, "ELRS")
    end
    local w = zone.w
    local h = zone.h

    local TRACK   = COLOR_TRACK
    -- dark scheme gets vivid neon green/yellow/red so the bars pop on black
    local C_GREEN, C_YELL, C_RED = SEM_GREEN, SEM_YELL, SEM_RED
    local TICK    = COLOR_TICK

    local shared = ultidash_functions.get_shared()
    local shared_th = shared.thresholds
    -- live thresholds from the Dashboard instance (its options drive the warnings);
    -- plain numeric safety defaults only, never this instance's own options
    local function rq_warn() return shared_th.rq_warn  or 80 end
    local function rq_crit() return shared_th.rq_crit  or 50 end
    local function rs_warn() return shared_th.rss_warn or 15 end
    local function rs_crit() return shared_th.rss_crit or 8 end

    -- FONT-METRIC layout: every column width is measured with lcd.sizeText so the
    -- page fits both the 480x320 (TX15) and the 800x480 (TX16S MK3) screens — the
    -- old fixed-pixel version overflowed/wrapped on the larger display.
    local title_font = h >= 170 and DBLSIZE or MIDSIZE
    local row_font   = h >= 170 and MIDSIZE or 0
    local title_w, title_h = lcd.sizeText("ELRS", title_font)
    local row_tw,  row_th  = lcd.sizeText("TPWR", row_font)
    local val_w            = lcd.sizeText("-108dBm", row_font) + 8
    local foot_tw, foot_th = lcd.sizeText("Ag", row_font)

    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG, filled = force_bg_fill or (shared.bg_filled == true) })

    -- header: title + rate/mode, separated by a line
    panel:label({ x = 10, y = 4, text = "ELRS", font = title_font, color = COLOR_THEME_PRIMARY1 })
    panel:label({ x = 10 + title_w + 14, y = 4 + math.floor((title_h - row_th) / 2),
        w = w - title_w - 24 - (as_detail and 110 or 10), h = row_th + 2,
        text = function() return wgt.values.elrs_rate_desc or "-" end,
        font = row_font, color = COLOR_THEME_SECONDARY1, align = LEFT })
    if as_detail then
        -- fullscreen-only page: closing is handled in refresh() (any tap) or by
        -- leaving fullscreen (RTN) — no lvgl button needed (and none allowed: a
        -- focusable button would capture PAGE/RTN/TELE in fullscreen)
        panel:label({ x = w - 110, y = 8, w = 100, h = 18, text = "tap to close", font = SMLSIZE, color = COLOR_THEME_DISABLED, align = RIGHT })
    end
    local top = 4 + title_h + 4
    panel:hline({ y = top - 1, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })

    -- fixed rows (2RSS just stays empty/"-" without diversity) so the layout never
    -- depends on whether telemetry was already seen at build time. TPWR is INVERTED:
    -- high transmit power means the link is working hard (dynamic power maxing out),
    -- so the bar turns yellow/red towards the configurable TxPwrMax.
    -- TPWR needs the configurable TxPwrMax as its 100% reference — without it the
    -- bar stays empty and shows a hint instead (the raw mW value is still printed).
    local function tpwr_max() return shared_th.tpwr_max or 0 end
    local function tpwr_pct()
        local t = wgt.values.elrs_tpwr
        local m = tpwr_max()
        if t == nil or t <= 0 or m <= 0 then return nil end
        local p = math.floor(100 * t / m)
        if p > 100 then p = 100 end
        return p
    end
    -- SNR mapped -10..+10 dB -> 0..100% (LoRa demodulates down to ~-7 dB depending
    -- on rate; 10 dB+ is comfortable). Yellow below ~4 dB, red below 0 dB.
    local function snr_pct()
        if wgt.values.elrs_flrc then return nil end   -- FLRC/FSK report SNR constant 0 -> empty bar
        local s = wgt.values.elrs_snr
        if s == nil then return nil end
        local p = math.floor((s + 10) * 5)
        if p < 0 then p = 0 elseif p > 100 then p = 100 end
        return p
    end
    local rows = {
        { lbl = "RQ",   val = function() return wgt.values.elrs_rq_formatted() end,    get = function() return wgt.values.elrs_rq end,     warn = rq_warn, crit = rq_crit },
        { lbl = "TQ",   val = function() return wgt.values.elrs_tq_formatted() end,    get = function() return wgt.values.elrs_tq end,     warn = rq_warn, crit = rq_crit },
        { lbl = "1RSS", val = function() return wgt.values.elrs_rssi1_formatted() end, get = function() return wgt.values.elrs_r1_pct end, warn = rs_warn, crit = rs_crit },
        { lbl = "2RSS", val = function() return wgt.values.elrs_rssi2_formatted() end, get = function() return wgt.values.elrs_r2_pct end, warn = rs_warn, crit = rs_crit },
        { lbl = "TRSS", val = memo_text(function() return wgt.values.elrs_trss end,
              function(t) return (t and t ~= 0) and (math.floor(t) .. "dBm") or "-" end),
          get = function() return wgt.values.elrs_trss_pct end, warn = rs_warn, crit = rs_crit },
        -- SNR value shows uplink / downlink combined ("8 / 5dB"); TSNR nil -> uplink only.
        -- FLRC/FSK modes report SNR constant 0 -> value "-" and empty bar (snr_pct returns nil).
        { lbl = "SNR",
          val = (function()
              local ls, lt, lf, lstr, primed
              return function()
                  local s, t, f = wgt.values.elrs_snr, wgt.values.elrs_tsnr, wgt.values.elrs_flrc
                  if primed and s == ls and t == lt and f == lf then return lstr end
                  ls, lt, lf, primed = s, t, f, true
                  if f or s == nil then lstr = "-"
                  elseif t ~= nil then lstr = string.format("%d / %ddB", math.floor(s), math.floor(t))
                  else lstr = string.format("%ddB", math.floor(s)) end
                  return lstr
              end
          end)(),
          get = snr_pct,
          warn = function() return 70 end, crit = function() return 50 end },
        { lbl = "TPWR", invert = true,
          val = memo_text(function() return wgt.values.elrs_tpwr end,
              function(t) return (t and t > 0) and (math.floor(t) .. "mW") or "-" end),
          get = tpwr_pct,
          warn = function() return 60 end, crit = function() return 85 end,
          tick_vis = function() return tpwr_max() > 0 end,
          hint = "set 'TPWR bar max' in settings",
          hint_vis = function() return tpwr_max() <= 0 end },
    }

    local foot_h = foot_th + 10
    local row_h = math.floor((h - top - foot_h - 2) / #rows)
    local bar_h = math.max(8, row_h - 10)
    local lbl_w = row_tw + 10
    local bar_x = 10 + lbl_w
    local bar_w = math.max(20, w - bar_x - val_w - 14)

    for i = 1, #rows do
        local r = rows[i]
        local ry = top + 4 + (i - 1) * row_h
        local ty = ry + math.floor((bar_h - row_th) / 2)   -- text vertically centered on the bar
        local get, warn, crit, invert = r.get, r.warn, r.crit, r.invert
        panel:label({ x = 10, y = ty, w = lbl_w, h = row_th + 2, text = r.lbl, font = row_font, color = COLOR_THEME_PRIMARY1, align = LEFT })
        panel:build({
            { type = "rectangle", x = bar_x, y = ry, w = bar_w, h = bar_h, filled = true, rounded = 3, color = TRACK },
            {
                type = "rectangle", x = bar_x, y = ry, w = 1, h = bar_h, filled = true, rounded = 3,
                color = function()
                    local v = get()
                    if v == nil then return TRACK end
                    if invert then
                        if v >= crit() then return C_RED elseif v >= warn() then return C_YELL else return C_GREEN end
                    end
                    if v >= warn() then return C_GREEN elseif v >= crit() then return C_YELL else return C_RED end
                end,
                pos = function() return bar_x, ry end,
                size = function()
                    local v = get() or 0
                    if v < 0 then v = 0 elseif v > 100 then v = 100 end
                    return math.floor(bar_w * v / 100), bar_h
                end
            },
            -- threshold ticks (= the color-switch points), reactive so they follow
            -- the dashboard's live options; hidden via tick_vis when meaningless
            { type = "rectangle", x = bar_x, y = ry, w = 2, h = bar_h, filled = true, color = TICK, visible = r.tick_vis,
              pos = function() return bar_x + math.floor(bar_w * crit() / 100), ry end },
            { type = "rectangle", x = bar_x, y = ry, w = 2, h = bar_h, filled = true, color = TICK, visible = r.tick_vis,
              pos = function() return bar_x + math.floor(bar_w * warn() / 100), ry end },
            { type = "rectangle", x = bar_x, y = ry, w = bar_w, h = bar_h, thickness = 1, rounded = 3, color = COLOR_THEME_SECONDARY1 },
        })
        if r.hint then
            panel:label({ x = bar_x + 6, y = ty, w = bar_w - 12, h = row_th + 2,
                text = r.hint, font = SMLSIZE, color = COLOR_THEME_DISABLED, align = CENTER,
                visible = r.hint_vis })
        end
        panel:label({ x = bar_x + bar_w + 6, y = ty, w = val_w, h = row_th + 2, text = r.val, font = row_font, color = COLOR_THEME_PRIMARY1, align = RIGHT })
    end

    -- footer: link details (left, live) + diversity (right)
    panel:hline({ y = h - foot_h - 1, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })
    panel:label({ x = 10, y = h - foot_h + 4, w = w - 130, h = foot_th + 2,
        -- memoized on its two inputs (antenna + session RQ min): re-concat only on change
        text = (function()
            local last_ant, last_min, last_s, primed
            return function()
                local v = wgt.values
                local ant, mn = v.elrs_ant, v.rqly_min
                if primed and ant == last_ant and mn == last_min then return last_s end
                local s = ""
                if ant ~= nil then s = "Ant " .. (ant + 1) end
                if mn ~= nil then s = s .. (s ~= "" and "    " or "") .. "RQ min " .. math.floor(mn) .. "%" end
                last_ant, last_min, last_s, primed = ant, mn, s, true
                return s
            end
        end)(),
        font = row_font, color = COLOR_THEME_PRIMARY1, align = LEFT })
    panel:label({ x = w - 124, y = h - foot_h + 6, w = 114, h = 20,
        text = function() return wgt.values.elrs_diversity and "Diversity: yes" or "Diversity: no" end,
        font = SMLSIZE, color = COLOR_THEME_DISABLED, align = RIGHT })
end

-- Add a filled triangle (up/down) to a build-table list from stacked 1px bars — the
-- EdgeTX font has no ▲/▼ glyphs, so scroll arrows are drawn. `size` = rows (px tall);
-- base width = 2*size-1, centered at cx, starting at top_y.
local function add_tri(list, cx, top_y, size, up, col)
    for r = 0, size - 1 do
        local wr = up and (2 * r + 1) or (2 * (size - r) - 1)
        -- 2px-tall bars stepped by 1px overlap into a solid triangle (1px bars were too
        -- thin to render visibly on the radio)
        list[#list + 1] = { type = "rectangle", filled = true, x = cx - math.floor(wr / 2), y = top_y + r, w = math.max(2, wr), h = 2, color = col }
    end
end

--- Build the STATUS DETAIL page (opened by tapping the ESC/arming status line,
--- fullscreen only). A bordered "status card" (arm/gov/throttle + ESC status + arming
--- status incl. the FULL disable-reason list) over the timestamped ESC event log, with
--- a tiny diagnostics footer. All rows are reactive (log updates live, no rebuilds).
local function build_estatus_view(wgt, zone)
    local w = zone.w
    local h = zone.h
    local C_RED, C_GRN = SEM_RED, SEM_GREEN
    -- neutral grey for hints/timestamps (NOT the theme DISABLED color, which is orange-red
    -- in the Clean palette and made the empty hint look like an error)
    local C_DIM = COLOR_DIM

    local title_font = h >= 170 and DBLSIZE or MIDSIZE
    local row_font   = h >= 170 and MIDSIZE or 0
    local title_w, title_h = lcd.sizeText("Status", title_font)
    local _, row_th = lcd.sizeText("Ag", row_font)
    local _, sml_h  = lcd.sizeText("Ag", SMLSIZE)

    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG,
        filled = force_bg_fill or (ultidash_functions.get_shared().bg_filled == true) })

    -- header: title + craft name + close hint
    panel:label({ x = 10, y = 4, text = "Status", font = title_font, color = COLOR_THEME_PRIMARY1 })
    panel:label({ x = 10 + title_w + 14, y = 4 + math.floor((title_h - row_th) / 2),
        w = w - title_w - 150, h = row_th + 2,
        text = function() return wgt.values.craft_name_formatted() end,
        font = row_font, color = COLOR_THEME_SECONDARY1, align = LEFT })
    panel:label({ x = w - 110, y = 8, w = 100, h = 18, text = "tap to close", font = SMLSIZE, color = C_DIM, align = RIGHT })
    local top = 8 + title_h + 4

    -- ---------- Status card: arm/gov/thr + ESC status + arming status ----------
    local cx, cw = 6, w - 12
    local rpad = 4
    local lh = row_th + 2
    local card_h = rpad * 2 + lh * 3
    panel:build({ { type = "rectangle", x = cx, y = top, w = cw, h = card_h, thickness = 1, rounded = 8,
        color = COLOR_THEME_SECONDARY1 } })

    local ix = cx + 10
    local iw = cw - 20
    local lblW = math.max(40, math.floor(iw * 0.14))   -- "ESC"/"Arm" tag column

    -- row 1: ARMED/Disarmed | Gov | Thr
    local r1 = top + rpad
    local aw = math.floor(iw * 0.28)
    local gw = math.floor(iw * 0.42)
    panel:label({ x = ix, y = r1, w = aw, h = lh, font = row_font, align = LEFT,
        text = function() return wgt.armed_now and "ARMED" or "Disarmed" end,
        color = function() return wgt.armed_now and C_RED or COLOR_THEME_PRIMARY1 end })
    -- memoized: the concats only rebuild when the 5 Hz-cached input moves
    panel:label({ x = ix + aw, y = r1, w = gw, h = lh, font = row_font, align = LEFT,
        text = memo_text(wgt.values.gov_state_formatted,
            function(s) return "Gov: " .. s end), color = COLOR_THEME_PRIMARY1 })
    panel:label({ x = ix + aw + gw, y = r1, w = iw - aw - gw, h = lh, font = row_font, align = RIGHT,
        text = memo_text(function() return wgt.values.throttle_text or "-" end,
            function(s) return "Thr: " .. s end), color = COLOR_THEME_PRIMARY1 })

    -- row 2: ESC status (level-colored)
    local r2 = r1 + lh
    panel:label({ x = ix, y = r2, w = lblW, h = lh, font = row_font, text = "ESC", color = C_DIM, align = LEFT })
    panel:label({ x = ix + lblW, y = r2, w = iw - lblW, h = lh, font = row_font, align = LEFT,
        text = function()
            if wgt.esc_status_text and wgt.esc_status_text ~= "" then return wgt.esc_status_text end
            return (wgt.values.rf_connection_state == "disconnected") and "-" or "OK"
        end,
        color = function()
            local lvl = wgt.esc_status_level
            if lvl == nil then return COLOR_THEME_PRIMARY1 end
            if lvl >= 3 then return C_RED end
            if lvl == 2 then return COLOR_THEME_WARNING end
            return COLOR_THEME_PRIMARY1
        end })

    -- row 3: arming status (Armed / Ready to arm / the full disable-reason list)
    local r3 = r2 + lh
    panel:label({ x = ix, y = r3, w = lblW, h = lh, font = row_font, text = "Arm", color = C_DIM, align = LEFT })
    panel:label({ x = ix + lblW, y = r3, w = iw - lblW, h = lh, font = row_font, align = LEFT,
        text = function()
            if wgt.armed_now then return "Armed" end
            local r = wgt.values.arm_reasons_full
            if r and r ~= "" then return r end
            return (wgt.values.rf_connection_state == "disconnected") and "-" or "Ready to arm"
        end,
        color = function()
            if wgt.armed_now then return COLOR_THEME_PRIMARY1 end
            local r = wgt.values.arm_reasons_full
            if r and r ~= "" then return COLOR_THEME_WARNING end
            return (wgt.values.rf_connection_state == "disconnected") and C_DIM or C_GRN
        end })

    -- ---------- Event log ----------
    local log_font = 0
    local time_w, log_th = lcd.sizeText("00:00:00", log_font)
    time_w = time_w + 10
    local footer_h = sml_h + 6
    local log_lbl_y = top + card_h + 6
    panel:label({ x = 10, y = log_lbl_y, w = 200, h = sml_h + 2, text = "Event log", font = SMLSIZE, color = C_DIM, align = LEFT })
    panel:hline({ y = log_lbl_y + sml_h + 3, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })

    local list_y = log_lbl_y + sml_h + 8
    local list_bottom = h - footer_h - 4
    local log_row_h = log_th + 4
    local slots = math.max(1, math.floor((list_bottom - list_y) / log_row_h))

    -- scroll offset (0 = newest at top), clamped to the current log length. The ▲/▼
    -- buttons (handled in refresh()) change wgt.estatus_scroll and rebuild.
    local log0 = ultidash_functions.get_esc_log(wgt)
    local nlog = log0 and #log0 or 0
    local maxscroll = math.max(0, nlog - slots)
    local scroll = math.min(math.max(0, wgt.estatus_scroll or 0), maxscroll)
    wgt.estatus_scroll = scroll

    if nlog > slots then
        local sb  = sml_h + 8
        local sby = log_lbl_y - math.floor((sb - sml_h) / 2)
        local sdx = w - 10 - sb
        local sux = sdx - 6 - sb
        local tri_sz = math.max(5, math.floor(sb * 0.42))
        local tri_y  = sby + math.floor((sb - tri_sz) / 2)
        local btns = {
            { type = "rectangle", x = sux, y = sby, w = sb, h = sb, thickness = 1, rounded = 4, color = COLOR_THEME_SECONDARY1 },
            { type = "rectangle", x = sdx, y = sby, w = sb, h = sb, thickness = 1, rounded = 4, color = COLOR_THEME_SECONDARY1 },
        }
        add_tri(btns, sux + math.floor(sb / 2), tri_y, tri_sz, true,  COLOR_THEME_PRIMARY1)   -- up (newer)
        add_tri(btns, sdx + math.floor(sb / 2), tri_y, tri_sz, false, COLOR_THEME_PRIMARY1)   -- down (older)
        panel:build(btns)
        wgt.estatus_scroll_up   = { x = sux, y = sby, w = sb, h = sb }
        wgt.estatus_scroll_down = { x = sdx, y = sby, w = sb, h = sb }
        panel:label({ x = sux - 96, y = log_lbl_y, w = 90, h = sml_h + 2, font = SMLSIZE, align = RIGHT, color = C_DIM,
            text = string.format("%d-%d / %d", scroll + 1, math.min(scroll + slots, nlog), nlog) })
    else
        wgt.estatus_scroll_up   = nil
        wgt.estatus_scroll_down = nil
    end

    local function log_empty()
        local log = ultidash_functions.get_esc_log(wgt)
        return log == nil or #log == 0
    end
    -- clean centered empty-state (instead of a broken half-line in the timestamp column)
    panel:label({ x = 0, y = math.floor((list_y + list_bottom) / 2 - log_th / 2), w = w, h = log_th + 2,
        font = log_font, color = C_DIM, align = CENTER, text = "No events yet", visible = log_empty })

    for i = 1, slots do
        local idx = i   -- 1 = newest (before scroll)
        local ry = list_y + (i - 1) * log_row_h
        local function entry()
            local log = ultidash_functions.get_esc_log(wgt)
            return log and log[#log - (idx - 1) - scroll] or nil
        end
        panel:label({ x = 10, y = ry, w = time_w, h = log_th + 2, font = log_font, color = C_DIM, align = LEFT,
            text = function() local e = entry(); return e and e.time or "" end })
        panel:label({ x = 10 + time_w, y = ry, w = w - 20 - time_w, h = log_th + 2, font = log_font, align = LEFT,
            text = function() local e = entry(); return e and e.text or "" end,
            color = function()
                local e = entry()
                if not e then return C_DIM end
                if e.level >= 3 then return C_RED end
                if e.level == 2 then return COLOR_THEME_WARNING end
                if e.level <= 0 then return C_DIM end
                return COLOR_THEME_PRIMARY1
            end })
    end

    -- tiny diagnostics footer (kept subtle, per the "klein/dezent" choice). Memoized on
    -- wgt.dbg_win: all four metrics refresh together once per second, so `pass x ms` now
    -- updates 1x/s instead of 5x/s -- fine for a diagnostics readout.
    panel:label({ x = 10, y = h - footer_h + 2, w = w - 20, h = sml_h + 2, font = SMLSIZE, color = C_DIM, align = LEFT,
        text = (function()
            local last_win, last_s, primed
            return function()
                local win = wgt.dbg_win
                if primed and win == last_win then return last_s end
                last_win, primed = win, true
                last_s = "Lua " .. (wgt.dbg_lua_kb or "-") .. " kB  free " .. (wgt.dbg_free_kb or "-")
                    .. " kB   UI " .. (wgt.dbg_hz or "-") .. " Hz   pass " .. ((wgt.dbg_pass_cs or 0) * 10) .. " ms"
                return last_s
            end
        end)() })
end

--- Build the BATTERY DETAIL page (tap the center fuel gauge, fullscreen only):
--- a big fuel gauge plus a cell-voltage scale with the RESOLVED thresholds
--- (FC config or manual) marked, and the key battery numbers. Drawn with
--- build-table primitives only (no lvgl.box — overlay/window objects swallow
--- fullscreen taps).
local function build_battery_view(wgt, zone)
    local w = zone.w
    local h = zone.h
    -- battery graphic empty segs: same scheme identity as the dashboard gauge —
    -- light grey on the light schemes, muted mid-grey on the dark one
    local TRACK   = force_bg_fill and lcd.RGB(0x6A, 0x6E, 0x72) or lcd.RGB(0xC8, 0xC8, 0xC8)
    -- big-percent ink follows the effective surfaces (same rule as the dashboard gauge)
    local PCT_INK = (color_luma(TRACK) > DARK_LUMA_THRESHOLD
        and color_luma(SEM.bar_ok) > DARK_LUMA_THRESHOLD) and BLACK or WHITE
    -- dark scheme gets vivid neon green/yellow/red so the gauge pops on black
    local C_GREEN, C_YELL, C_RED = SEM_GREEN, SEM_YELL, SEM_RED
    local C_DIM   = COLOR_DIM
    local TICK    = COLOR_TICK

    local title_font = h >= 170 and DBLSIZE or MIDSIZE
    local row_font   = h >= 170 and MIDSIZE or 0
    local title_w, title_h = lcd.sizeText("Battery", title_font)
    local _, row_th = lcd.sizeText("Ag", row_font)

    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG,
        filled = force_bg_fill or (ultidash_functions.get_shared().bg_filled == true) })

    panel:label({ x = 10, y = 4, text = "Battery", font = title_font, color = COLOR_THEME_PRIMARY1 })
    panel:label({ x = w - 110, y = 8, w = 100, h = 18, text = "tap to close", font = SMLSIZE, color = COLOR_THEME_DISABLED, align = RIGHT })
    local top = 4 + title_h + 4
    panel:hline({ y = top - 1, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })

    -- cell-voltage scale with the resolved thresholds marked (full width); the
    -- current value gets the big title-size font
    local rx = 14
    local rw = w - 28
    local val_font = title_font
    local _, val_h = lcd.sizeText("8.88", val_font)
    local val_w = lcd.sizeText("88.88", val_font) + 10
    local bar_w = rw - val_w - 8
    local bar_h = math.max(12, row_th)
    local function th_full() return wgt.values.vcel_full_threshold() end
    local function th_low()  return wgt.values.vcel_warning_threshold() end
    local function th_crit() return wgt.values.vcel_alarm_threshold() end
    local function vx(v)
        local smin = th_crit() - 0.15
        local smax = th_full() + 0.10
        if smax <= smin then smax = smin + 1 end
        local f = (v - smin) / (smax - smin)
        if f < 0 then f = 0 elseif f > 1 then f = 1 end
        return math.floor(bar_w * f)
    end

    local sy = top + 6
    -- SMLSIZE is taller on 800x480 — measure instead of hardcoding (label used to
    -- collide with the scale bar on the TX16S)
    local _, sml_h = lcd.sizeText("Ag", SMLSIZE)
    panel:label({ x = rx, y = sy, w = rw, h = sml_h + 2, text = "Cell voltage", font = SMLSIZE, color = C_DIM, align = LEFT })
    local by = sy + sml_h + 4
    panel:build({
        { type = "rectangle", x = rx, y = by, w = bar_w, h = bar_h, filled = true, rounded = 3, color = COLOR_TRACK },
        { type = "rectangle", x = rx + 1, y = by + 1, w = 1, h = bar_h - 2, filled = true, rounded = 2,
          color = function()
              local v = wgt.values.vcel
              if v == nil then return COLOR_TRACK end
              if v <= th_crit() then return C_RED end
              if v <= th_low() then return C_YELL end
              return C_GREEN
          end,
          pos = function() return rx + 1, by + 1 end,
          size = function()
              local v = wgt.values.vcel
              if v == nil then return 0, bar_h - 2 end
              return math.max(1, vx(v) - 1), bar_h - 2
          end },
        { type = "rectangle", x = rx, y = by, w = 2, h = bar_h, filled = true, color = TICK,
          pos = function() return rx + vx(th_crit()), by end },
        { type = "rectangle", x = rx, y = by, w = 2, h = bar_h, filled = true, color = TICK,
          pos = function() return rx + vx(th_low()), by end },
        { type = "rectangle", x = rx, y = by, w = 2, h = bar_h, filled = true, color = TICK,
          pos = function() return rx + vx(th_full()), by end },
        { type = "rectangle", x = rx, y = by, w = bar_w, h = bar_h, thickness = 1, rounded = 3, color = COLOR_THEME_SECONDARY1 },
    })
    panel:label({ x = rx + bar_w + 6, y = by + math.floor((bar_h - val_h) / 2), w = val_w, h = val_h + 2,
        text = function() return wgt.values.vcel_formatted() end,
        font = val_font, color = COLOR_THEME_PRIMARY1, align = RIGHT })
    -- threshold legend incl. the source (FC config vs manual values)
    panel:label({ x = rx, y = by + bar_h + 4, w = rw, h = sml_h + 2,
        -- memoized on the three thresholds + source; still reactive because an MSP fetch
        -- can change the resolved thresholds live (re-formats only when one moves)
        text = (function()
            local lc, ll, lf, ls, last, primed
            return function()
                local c, l, f = th_crit(), th_low(), th_full()
                local src = wgt.options.CellSource
                if primed and c == lc and l == ll and f == lf and src == ls then return last end
                lc, ll, lf, ls, primed = c, l, f, src, true
                last = string.format("crit %.2f   low %.2f   full %.2f V   (%s)",
                    c, l, f, (src == 2) and "manual" or "FC config")
                return last
            end
        end)(),
        font = SMLSIZE, color = C_DIM, align = LEFT })

    -- horizontal battery in the EXACT dashboard look (coarse segments, light grey
    -- empty area, black overlays) — "laid down" under the voltage scale, cap right,
    -- filling left -> right. Values are drawn INSIDE the graphic.
    local bottom_h = row_th + 8
    local cap_w = math.max(7, math.floor(w * 0.018))
    local bx = 14
    local by2 = by + bar_h + 8 + sml_h + 6
    local bw = w - 28 - cap_w
    local bh = math.max(40, h - by2 - bottom_h - 10)
    local body_rounding = math.max(3, math.floor(bh * 0.10))
    local inner_pad = math.max(3, math.floor(bh * 0.10))
    local ix = bx + inner_pad
    local iy = by2 + inner_pad
    local iw = bw - 2 * inner_pad
    local ih = bh - 2 * inner_pad
    local seg_gap = math.max(1, math.floor(iw * 0.01))
    local seg_count = math.max(6, math.min(9, math.floor(iw / 16)))
    local seg_w = math.floor((iw - (seg_count - 1) * seg_gap) / seg_count)
    local seg_last_w = iw - seg_w * (seg_count - 1) - seg_gap * (seg_count - 1)
    local seg_rounding = math.max(1, math.floor(ih * 0.10))
    local function seg_color(threshold)
        return function()
            local p = wgt.values.gauge_fill_percent()
            if p >= threshold then return wgt.values.capa_bar_color end
            return TRACK
        end
    end

    -- cap (the "plus pole", right) + body outline
    local cap_h = math.floor(bh * 0.36)
    panel:build({
        { type = "rectangle", x = bx + bw, y = by2 + math.floor((bh - cap_h) / 2), w = cap_w, h = cap_h,
          rounded = 2, color = COLOR_THEME_SECONDARY1, filled = true },
        { type = "rectangle", x = bx, y = by2, w = bw, h = bh, thickness = 1, rounded = body_rounding,
          color = COLOR_THEME_SECONDARY1, filled = false },
    })

    -- ESC-load fill: floods the ENTIRE free gap between segments and frame, filling
    -- LEFT -> RIGHT towards the cap (the direction this laid-down battery fills).
    -- Same construction as the dashboard gauge (see there): built BEFORE the segments
    -- (fill sits UNDER them), outer corners as filled arc sectors following the frame
    -- curve, inner-corner patches under the end segments' rounded corners.
    if wgt.options.EscMon == 1 then
        local gap = math.max(1, inner_pad - 1)  -- free gap = outer corner radius R
        local sr  = seg_rounding                -- inner (segment) corner radius
        local rx0 = bx + 1                      -- inside the 1 px outline
        local rx1 = bx + bw - 1
        local ry0 = by2 + 1
        local ry1b = by2 + bh - 1
        -- scale like the dashboard gauge: left gap + middle = 0..100 %; the RIGHT gap
        -- (cap side) is the OVERLOAD zone, filling over 100..150 % (closed at >=150 %)
        local norm   = gap + iw                 -- fill travel for 0..100 %
        local travel = norm + gap               -- incl. the overload (cap) zone
        local esc_vis = function() return wgt.values.esc_load_limit ~= nil end
        local function fillw()
            local p = wgt.values.esc_load_pct or 0
            if p < 0 then p = 0 end
            if p <= 100 then return math.floor(norm * p / 100) end
            local o = p - 100
            if o > 50 then o = 50 end
            return norm + math.floor(gap * o / 50)
        end
        local function fill_color()
            local p = wgt.values.esc_load_pct
            if p == nil then return TRACK end
            local warn = wgt.options.EscWarn or 80
            local crit = wgt.options.EscCrit or 100
            if p >= crit then return C_RED elseif p >= warn then return C_YELL else return C_GREEN end
        end
        local function corner(cx, cy, a0, a1, vis)
            return { type = "arc", x = cx, y = cy, radius = gap, thickness = gap,
                     startAngle = a0, endAngle = a1, rounded = false,
                     bgStartAngle = 0, bgEndAngle = 0, bgOpacity = 0,
                     color = fill_color, visible = vis }
        end
        local function patch(px, py, vis)
            return { type = "rectangle", x = px, y = py, w = sr, h = sr, filled = true,
                     color = fill_color, visible = vis }
        end
        local vis_left    = function() return esc_vis() and fillw() >= gap end
        local vis_inner_l = function() return esc_vis() and fillw() >= gap + sr end
        local vis_inner_r = function() return esc_vis() and fillw() >= gap + iw end
        local vis_right   = function() return esc_vis() and fillw() >= travel end
        panel:build({
            -- left run between the corner discs
            { type = "rectangle", x = rx0, y = iy, w = 1, h = ih, filled = true,
              visible = function() return esc_vis() and fillw() > 0 end,
              size = function() return math.max(1, math.min(fillw(), gap)), ih end,
              color = fill_color },
            corner(rx0 + gap, ry0 + gap, 180, 270, vis_left),    -- top-left
            corner(rx0 + gap, ry1b - gap, 90, 180, vis_left),    -- bottom-left
            -- inner-corner patches under the LEFT segment's rounded corners
            patch(ix, iy, vis_inner_l),
            patch(ix, iy + ih - sr, vis_inner_l),
            -- top + bottom runs flush along segments and frame
            { type = "rectangle", x = ix, y = ry0, w = 1, h = gap, filled = true,
              visible = function() return esc_vis() and fillw() > gap end,
              size = function() return math.max(1, math.min(fillw() - gap, iw)), gap end,
              color = fill_color },
            { type = "rectangle", x = ix, y = ry1b - gap, w = 1, h = gap, filled = true,
              visible = function() return esc_vis() and fillw() > gap end,
              size = function() return math.max(1, math.min(fillw() - gap, iw)), gap end,
              color = fill_color },
            -- right: inner-corner patches, right run + corner discs (~100 %)
            patch(ix + iw - sr, iy, vis_inner_r),
            patch(ix + iw - sr, iy + ih - sr, vis_inner_r),
            { type = "rectangle", x = rx1 - gap, y = iy, w = 1, h = ih, filled = true,
              visible = function() return esc_vis() and fillw() > gap + iw end,
              size = function() return math.max(1, math.min(fillw() - gap - iw, gap)), ih end,
              color = fill_color },
            corner(rx1 - gap, ry0 + gap, 270, 360, vis_right),   -- top-right
            corner(rx1 - gap, ry1b - gap, 0, 90, vis_right),     -- bottom-right
        })
    end

    -- segments, leftmost = lowest threshold (fills from the left towards the cap)
    for i = 1, seg_count do
        local sw = (i == seg_count) and seg_last_w or seg_w
        local sx = ix + (i - 1) * (seg_w + seg_gap)
        local col = seg_color((i / seg_count) * 100)
        local flat_w = math.max(1, math.min(seg_rounding, sw))
        panel:build({
            { type = "rectangle", x = sx, y = iy, w = sw, h = ih, thickness = 1,
              rounded = (i == 1 or i == seg_count) and seg_rounding or 0, color = col, filled = true },
            { type = "rectangle", x = (i == 1) and (sx + sw - flat_w) or sx, y = iy, w = flat_w, h = ih,
              thickness = 0, color = col, filled = (i == 1 or i == seg_count) },
        })
    end

    -- ESC-load display: the WHOLE free gap between the segments and the frame becomes
    -- the load gauge, filling LEFT -> RIGHT towards the cap — the same direction this
    -- laid-down battery fills. NO track: the unfilled gap stays transparent, only the
    -- coloured fill appears; the left/right end strips carry rounded corners matching
    -- the frame and the top/bottom strips overlap them by the radius (no notches).
    -- Always shown here while ESC load monitoring is on (the dashboard placement is a
    -- setting, see SETTINGS_ESC).

    -- overlays INSIDE the graphic: cells (left), big percent (center), used/capacity (right)
    local pct_font = select_font(math.floor(bh * 0.50), 220, "100%")
    local pct_h = measure_font(pct_font)
    -- Translucent rounded "pills" behind the two SMALL in-graphic values (cells + mAh)
    -- so they stay readable on any segment colour (esp. the dark scheme's neon fills).
    -- The big percent is large enough to read as plain black text, so it gets NO pill.
    -- Each pill hugs its CURRENT text (measured at build), capsule-shaped; white text on
    -- top. Drawn AFTER the segments and BEFORE the labels so the z-order is bg -> text.
    -- (LVGL geometry is not reactive, so a pill can lag a little if its value grows a lot
    -- while the page stays open.)
    local cells_y = by2 + math.floor((bh - row_th) / 2)
    local pct_y   = by2 + math.floor((bh - pct_h) / 2)
    local pill_px = math.max(4, math.floor(row_th * 0.35))
    local pill_py = math.max(2, math.floor(row_th * 0.16))
    local pill_text = lcd.RGB(0xF8, 0xF8, 0xF8)
    local cells_tw = lcd.sizeText(wgt.values.gauge_cells_formatted(), row_font)
    local mah_tw   = lcd.sizeText(wgt.values.gauge_mah_value_formatted() .. " mAh", row_font)
    local pill_h   = row_th + 2 + 2 * pill_py
    local function pill_rect(rx, rw)
        return { type = "rectangle", x = rx, y = cells_y - pill_py, w = rw, h = pill_h, filled = true,
                 color = BLACK, opacity = 140, rounded = math.floor(pill_h / 2) }
    end
    panel:build({
        pill_rect(ix + 8 - pill_px, cells_tw + 2 * pill_px),
        pill_rect((ix + iw - 8) - mah_tw - pill_px, mah_tw + 2 * pill_px),
    })
    panel:label({ x = ix + 8, y = cells_y, w = math.floor(iw * 0.20), h = row_th + 2,
        text = function() return wgt.values.gauge_cells_formatted() end,
        font = row_font, color = pill_text, align = LEFT })
    panel:label({ x = bx, y = pct_y, w = bw, h = pct_h,
        text = function() return wgt.values.gauge_percent_formatted() end,
        font = pct_font, color = PCT_INK, align = CENTER })
    -- used mAh only, like the dashboard gauge — the profile's TOTAL capacity is
    -- merely informational and "x / total" misreads as usable-until-total (the
    -- reserve model ends earlier)
    -- memoized: concats rebuild only when the 5 Hz-cached inputs move
    panel:label({ x = ix + iw - math.floor(iw * 0.30) - 8, y = cells_y,
        w = math.floor(iw * 0.30), h = row_th + 2,
        text = memo_text(wgt.values.gauge_mah_value_formatted,
            function(s) return s .. " mAh" end),
        font = row_font, color = pill_text, align = RIGHT })

    -- bottom line: the remaining numbers in one row (memoized)
    local byl = h - bottom_h + 2
    panel:label({ x = 14, y = byl, w = math.floor(w * 0.34), h = row_th + 2,
        text = memo_text(wgt.values.vbat_formatted,
            function(s) return "Batt " .. s end),
        font = row_font, color = COLOR_THEME_PRIMARY1, align = LEFT })
    panel:label({ x = math.floor(w * 0.34), y = byl, w = math.floor(w * 0.32), h = row_th + 2,
        text = memo_text(function() return wgt.values.vcel_min end,
            function(v) return "Cell min " .. (v and string.format("%.2f V", v) or "-") end),
        font = row_font, color = COLOR_THEME_PRIMARY1, align = CENTER })
    panel:label({ x = w - 14 - math.floor(w * 0.30), y = byl, w = math.floor(w * 0.30), h = row_th + 2,
        text = memo_text(function() return wgt.options.Reserve or 20 end,
            function(v) return "Reserve " .. v .. " %" end),
        font = row_font, color = COLOR_THEME_PRIMARY1, align = RIGHT })
end

--- Build the "Telemetry" detail page (opened by tapping the right value panel):
--- a 3-column grid of up to 12 freely chosen sensors (Settings ▸ Values). Off
--- slots are skipped; each cell shows the value plus the EdgeTX session low/high
--- ("min .. max", read from the sensor's "-"/"+" variants). Same look / tap-to-close
--- behaviour as the other detail pages.
local function build_telem_view(wgt, zone)
    local w = zone.w
    local h = zone.h
    local title_font = h >= 170 and DBLSIZE or MIDSIZE
    local _, title_h = lcd.sizeText("Telemetry", title_font)

    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG,
        filled = force_bg_fill or (ultidash_functions.get_shared().bg_filled == true) })
    panel:label({ x = 10, y = 4, text = "Telemetry", font = title_font, color = COLOR_THEME_PRIMARY1 })
    panel:label({ x = w - 110, y = 8, w = 100, h = 18, text = "tap to close", font = SMLSIZE,
        color = COLOR_THEME_DISABLED, align = RIGHT })
    local top = 4 + title_h + 4
    panel:hline({ y = top - 1, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })

    -- collect active (non-off) slots in order
    local slots = {}
    for i = 1, #DETAIL_SLOT_KEYS do
        local name = wgt.options[DETAIL_SLOT_KEYS[i]]
        if not is_off_sensor(name) then slots[#slots + 1] = name end
    end
    if #slots == 0 then
        panel:label({ x = 0, y = math.floor(h / 2) - 12, w = w, h = 24,
            text = "No values selected  (Settings > Values)", font = MIDSIZE,
            color = COLOR_THEME_DISABLED, align = CENTER })
        return
    end

    -- 3-column grid on both radios. Each tile shows the value (right-aligned) + unit
    -- and the EdgeTX session low/high as a soft "min .. max" chip beneath it. The
    -- label placement adapts to the tile width: wide tiles (TX16S) put the label to
    -- the LEFT of the value; narrow tiles (TX15) put it on TOP (Value2 widget style),
    -- so the value still gets the full width and stays large.
    local cols   = 3
    local rows_n = math.ceil(#slots / cols)
    local pad    = 12
    local grid_y = top + 6
    local grid_h = h - grid_y - 6
    local cell_w = math.floor((w - pad * (cols + 1)) / cols)
    local cell_h = math.floor(grid_h / rows_n)
    local _, lbl_h = lcd.sizeText("Ag", SMLSIZE)
    local mm_h = lbl_h

    local wide     = cell_w >= 190          -- room for a label column beside the value
    local lbl_w    = wide and math.floor(cell_w * 0.40) or 0
    local va_x_off = lbl_w                  -- value area starts after the side label
    local va_w     = cell_w - lbl_w
    local lbl_top_h = wide and 0 or (lbl_h + 1)   -- height the top label consumes
    -- value font sized once (uniform), leaving headroom for the widest unit
    local val_font = select_font(cell_h - mm_h - lbl_top_h - 8, va_w - 30, "99.99")
    local val_h    = measure_font(val_font)
    local block_h  = lbl_top_h + val_h + 2 + mm_h
    -- low/high chip: a soft rounded pill sized to a worst-case range string
    local chip_w   = math.min(va_w, lcd.sizeText("999.9 .. 999.9", SMLSIZE) + 12)
    local chip_r   = math.floor((mm_h + 2) / 2)

    for idx = 1, #slots do
        local name = slots[idx]
        local c = (idx - 1) % cols
        local r = math.floor((idx - 1) / cols)
        local cx = pad + c * (cell_w + pad)
        local cy = grid_y + r * cell_h + math.max(0, math.floor((cell_h - block_h) / 2))

        local unit = sensor_unit(name)
        local unit_w = (unit ~= "") and (lcd.sizeText(unit, SMLSIZE) + 3) or 0
        local va_x = cx + va_x_off
        local unit_x = va_x + va_w - unit_w           -- unit at the value area's right edge
        local val_x = va_x
        local val_w = (unit ~= "") and (unit_x - 2 - val_x) or va_w
        local val_top = cy + lbl_top_h                -- value sits below the top label (if any)

        -- label: left of the value (wide) or on top spanning the tile (narrow)
        if wide then
            -- long labels ("Energy Used", "BEC Voltage") don't fit the 40% side
            -- column on one SMLSIZE line → LVGL wraps them. Reserve two lines when
            -- needed (else the 2nd line clips) and vertically centre against the value.
            local lbl_text = sensor_short_label(name)
            local lbl_box_w = lbl_w - 4
            local lbl_lines = (lcd.sizeText(lbl_text, SMLSIZE) > lbl_box_w) and 2 or 1
            local lbl_box_h = lbl_lines * lbl_h + 2
            panel:label({ x = cx, y = val_top + math.floor((val_h - lbl_box_h) / 2),
                w = lbl_box_w, h = lbl_box_h,
                text = lbl_text, font = SMLSIZE, color = COLOR_THEME_SECONDARY1, align = LEFT })
        else
            panel:label({ x = cx, y = cy, w = cell_w, h = lbl_h + 2,
                text = sensor_short_label(name), font = SMLSIZE, color = COLOR_THEME_SECONDARY1, align = LEFT })
        end
        -- value: big, right-aligned (leaves room for the unit to its right)
        if name == VOLT_AUTO then
            panel:label({ x = val_x, y = val_top, w = val_w, h = val_h + 2,
                text = wgt.values.display_voltage_formatted, font = val_font,
                color = wgt.values.display_voltage_color, align = RIGHT })
        elseif name == ESCL_AUTO then
            -- computed (no raw sensor behind it): the 5 Hz-cached load % with the
            -- bar's warn/crit colour semantics
            panel:label({ x = val_x, y = val_top, w = val_w, h = val_h + 2,
                text = sensor_value_text(wgt, name), font = val_font,
                color = esc_load_color(wgt), align = RIGHT })
        else
            panel:label({ x = val_x, y = val_top, w = val_w, h = val_h + 2,
                text = sensor_value_text_raw(wgt, name), font = val_font,
                color = COLOR_THEME_PRIMARY1, align = RIGHT })
        end
        -- unit: small, sitting on the big value's baseline at the value area's right edge
        if unit ~= "" then
            panel:label({ x = unit_x, y = val_top + (val_h - lbl_h), w = unit_w, h = lbl_h + 2,
                text = unit, font = SMLSIZE, color = COLOR_THEME_SECONDARY1, align = LEFT })
        end
        -- low/high chip under the value, right-aligned within the value area
        local chip_x = va_x + va_w - chip_w
        local chip_y = val_top + val_h + 2
        panel:build({
            { type = "rectangle", x = chip_x, y = chip_y, w = chip_w, h = mm_h + 2,
              filled = true, rounded = chip_r, color = COLOR_TRACK },
            { type = "label", x = chip_x, y = chip_y, w = chip_w, h = mm_h + 2,
              text = sensor_minmax_text(wgt, name), font = SMLSIZE, color = COLOR_TICK, align = CENTER },
        })
    end
end

--- Build the status/config view (ViewMode = "Status info", passive instance).
--- Shows the ACTIVE configuration of the Dashboard instance — read exclusively from
--- the Shared snapshot it publishes (resolved cell thresholds incl. the MSP-fetched
--- FC values, alert thresholds, alert switches). Look (palette, background) follows
--- the Dashboard too. Requires a running Dashboard (notice page otherwise).
--- as_page: opened from the Dashboard's own menu — rendered as an lvgl.page with
--- back-to-menu instead of the passive full-zone panel (no alive-gate needed: the
--- dashboard instance publishes itself).
local function build_status_view(wgt, zone, as_page)
    if not as_page and not ultidash_functions.shared_alive() then
        return build_missing_dashboard_view(wgt, zone, "UltiDash config")
    end
    local w = zone.w
    local h = zone.h
    local shared = ultidash_functions.get_shared()
    local th, al, vol = shared.thresholds, shared.alerts, shared.volume

    local function num(v, fmt) if v == nil then return "-" end return string.format(fmt, v) end
    -- Per-frame MEMO: as ViewMode "Status info" this panel is PERMANENTLY
    -- visible on a second screen and every val closure runs per LVGL frame (~20 Hz).
    -- The old closures format/concat fresh strings (and sounds_off a fresh table)
    -- on EVERY frame = constant GC pressure. Each row now rebuilds its string only
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
        { lbl = "Model / link", val = memo(
            function() return shared.ready, shared.model_name, shared.connected end,
            function()
                if not shared.ready then return "-" end
                return (shared.model_name or "-") .. (shared.connected and "  (conn)" or "  (disc)")
            end) },
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
        { lbl = "Repeat", val = function() if not shared.ready then return "-" end return al.repeat_summary or "none" end },
        { lbl = "Mute / escalation", val = memo(
            function() return shared.ready, al.mute, al.escalating end,
            function()
                if not shared.ready then return "-" end
                return (al.mute and "ALL MUTED" or "none") .. "  /  " .. (al.escalating and "ACTIVE" or "idle")
            end) },
        { lbl = "Sounds off", val = sounds_off },
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

    if as_page then
        -- scrollable page (menu -> Status): sections + rows, everything fits via scroll
        local pg = lvgl.page({
            title = "UltiDash", subtitle = "Status",
            back = function() wgt.menu_view = "menu"; init_view_state(wgt).dirty = true end,
        })
        local _, sml_h = lcd.sizeText("Ag", SMLSIZE)
        local row_h = 26
        local lblw = math.floor(w * 0.46)
        local y = 2
        for i = 1, #items do
            local it = items[i]
            if it.section then
                y = y + 6
                pg:label({ x = 10, y = y, w = w - 40, h = sml_h + 2, text = it.section, font = SMLSIZE, color = COLOR_THEME_FOCUS, align = LEFT })
                y = y + sml_h + 4
            else
                pg:label({ x = 10, y = y, w = lblw, h = 22, text = it.lbl, color = COLOR_THEME_SECONDARY1, align = LEFT })
                pg:label({ x = 10 + lblw, y = y, w = w - lblw - 34, h = 22, text = it.val, color = COLOR_THEME_PRIMARY1, align = RIGHT })
                y = y + row_h
            end
        end
        pg:label({ x = 10, y = y + 8, w = w - 34, h = 20, font = SMLSIZE, color = COLOR_DIM, align = LEFT,
            -- memoized on wgt.dbg_win (metrics refresh together once per second)
            text = (function()
                local last_win, last_s, primed
                return function()
                    local win = wgt.dbg_win
                    if primed and win == last_win then return last_s end
                    last_win, primed = win, true
                    last_s = "Lua " .. (wgt.dbg_lua_kb or "-") .. " kB  free " .. (wgt.dbg_free_kb or "-")
                        .. " kB   UI " .. (wgt.dbg_hz or "-") .. " Hz"
                    return last_s
                end
            end)() })
        return
    end

    -- passive ViewMode "Status info" panel (fixed height): same items, equal rows
    local big = h >= 170
    local title_font = big and MIDSIZE or 0
    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG, filled = force_bg_fill or (shared.bg_filled == true) })

    local top = big and 30 or 22
    local foot = big and 22 or 16
    panel:label({ x = 10, y = 4, text = "UltiDash config", font = title_font, color = COLOR_THEME_PRIMARY1 })
    panel:hline({ y = top - 2, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })

    local row_h = math.floor((h - top - foot) / #items)
    local row_font = select_font(row_h - 1, nil, nil)
    local lbl_w = math.floor(w * 0.46)

    for i = 1, #items do
        local it = items[i]
        local ry = top + (i - 1) * row_h
        if it.section then
            panel:label({ x = 10, y = ry, w = w - 20, h = row_h, text = it.section, font = row_font, color = COLOR_THEME_FOCUS, align = LEFT })
        else
            panel:label({ x = 10, y = ry, w = lbl_w, h = row_h, text = it.lbl, font = row_font, color = COLOR_THEME_SECONDARY1, align = LEFT })
            panel:label({ x = 10 + lbl_w, y = ry, w = w - lbl_w - 14, h = row_h, text = it.val, font = row_font, color = COLOR_THEME_PRIMARY1, align = RIGHT })
        end
    end

    panel:label({ x = 10, y = h - foot + 2, w = w - 14, h = foot - 2,
        text = "live from the Dashboard instance", font = SMLSIZE, color = COLOR_THEME_DISABLED, align = LEFT })
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
local SETTINGS_DISPLAY = {
    { kind = "section", lbl = "Layout & theme" },
    { key = "TopLeft",       lbl = "Top-left shows",        kind = "choice", def = 1, vals = { "Model image", "Timer" } },
    { key = "ClockMode",     lbl = "Top bar clock",         kind = "choice", def = 2, vals = { "Date + time", "Time only" } },
    { key = "Timer",         lbl = "Timer (for top-left)",  kind = "num", def = 0, min = 0, max = 2, step = 1, big = 1,
                             fmt = function(v) return "Timer " .. (v + 1) end,
                             dim = function(w) return w.TopLeft ~= 2 end },
    { key = "ColorScheme",   lbl = "Color scheme",          kind = "choice", def = 1, vals = { "UltiDash", "UltiDash dark", "EdgeTX theme" } },
    { key = "BGFilled",      lbl = "Fill background",       kind = "bool", def = 1 },
    { key = "StatsViewMode", lbl = "Stats page",            kind = "choice", def = 3, vals = { "Never", "On disarmed", "On disconnected" } },
    { key = "VoltageDisplay",lbl = "Voltage shown as",      kind = "choice", def = 1, vals = { "Cell voltage", "Battery voltage" } },
    { kind = "section", lbl = "Top & bottom bar" },
    { key = "ShowRQly",      lbl = "Top bar: RQ bar",       kind = "bool", def = 1 },
    { key = "ShowTQly",      lbl = "Top bar: TQ bar",       kind = "bool", def = 1 },
    { key = "ShowRSSI",      lbl = "Top bar: RSSI bars",    kind = "bool", def = 1 },
    { key = "ShowTxV",       lbl = "Top bar: TX voltage",   kind = "bool", def = 0 },
    { key = "ShowTPWR",      lbl = "Bottom bar: TPWR",      kind = "bool", def = 1 },
    { key = "TxPwrMax",      lbl = "TPWR bar max (mW)",     kind = "num", def = 0, min = 0, max = 1000, step = 10, big = 50,
                             fmt = function(v) return v == 0 and "not set" or (v .. " mW") end },
    { key = "BarsQuiet",     lbl = "Link bars: color only on warning", kind = "bool", def = 1 },
    { kind = "section", lbl = "Behaviour" },
    { key = "ArmClose",      lbl = "Close detail pages on arm", kind = "bool", def = 0 },
    { key = "TapDetails",    lbl = "Tap zones for detail pages", kind = "bool", def = 1 },
    -- switch shortcuts (detail pages + Toolbox tools) moved to their own group, see
    -- SETTINGS_SHORTCUTS / the "Shortcuts" group.
}

local function fmt_pctval(v) return v .. " %" end

local SETTINGS_BATTERY = {
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
}

local function fmt_pctdrop(v) return v .. " %" end
local function fmt_temp(v) return (v == 0) and "Off" or (v .. " C") end

-- Warning thresholds, grouped by subject via non-interactive section headers
-- (kind="info" rows). ESC-load thresholds live in their own "ESC load" group;
-- the TPWR bar max moved to Display (it scales the bottom-bar TPWR display).
local SETTINGS_THRESHOLDS = {
    { kind = "section", lbl = "Link & signal" },
    { key = "RQlyWarn",   lbl = "Link warn (%)",          kind = "num", def = 80, min = 0,  max = 100,  step = 1,  big = 5 },
    { key = "RQlyCrit",   lbl = "Link critical (%)",      kind = "num", def = 50, min = 0,  max = 100,  step = 1,  big = 5 },
    { key = "RssWarn",    lbl = "RSSI warn (% headroom)", kind = "num", def = 15, min = 0,  max = 100,  step = 1,  big = 5 },
    { key = "RssCrit",    lbl = "RSSI critical (%)",      kind = "num", def = 8,  min = 0,  max = 100,  step = 1,  big = 5 },
    { key = "RssHold",    lbl = "RSSI hold time (s)",     kind = "num", def = 2,  min = 1,  max = 10,   step = 1,  big = 2 },
    { key = "SkpLimit",   lbl = "Skipped-packet limit",   kind = "num", def = 50, min = 10, max = 2000, step = 10, big = 100 },
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
}

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
local SETTINGS_ESC = {
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
}

local function fmt_pct(v) return tostring(v) .. " %" end

-- Loudness / volume — its own settings group (see the "Volume" entry in
-- SETTINGS_GROUPS). Two independent loudness worlds:
--   * the per-callout WIDGET volume (Volume 1..5, passed to playFile/playNumber), and
--   * the GVAR MASTER-volume bridge (VolGvar drives a model "Volume" special function).
-- Normal vs. escalation % (VolFlight / VolEscal) only apply in the GVAR world.
local SETTINGS_VOLUME = {
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

-- Global voice settings (language + master mute), reached via the Alerts submenu's
-- first entry ("Voice / mute"). Separate from the per-alert pages.
local SETTINGS_VOICE = {
    { key = "VoiceLang",  lbl = "Voice language",            kind = "choice", def = 1, vals = { "English", "Deutsch" } },
    { key = "Mute",       lbl = "Mute (master)",             kind = "choice", def = 1, vals = { "None", "All" } },
    -- separate haptic master: "Mute: All" silences AUDIO only; vibration has its own switch
    { key = "VibMaster",  lbl = "Vibration (master)",        kind = "bool", def = 1 },
    -- shared auto-close for the per-alert fullscreen overlay (PwrOvl/VoltOvl/
    -- TelemOvl pages); 0 = the overlay stays until tapped or the condition clears
    { key = "OvlClose",   lbl = "Overlay auto-close (s)",    kind = "num", def = 0, min = 0, max = 60, step = 1, big = 5,
      fmt = function(v) return (v == 0) and "until tapped" or (v .. " s") end },
}

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
-- as before). vibDef mirrors the old "vibrate on critical" (fuel/voltage/telemetry).
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

-- "Test callout / Play" rows: preview a callout with the page's WORKING values (see
-- test_callout). Deliberately never dimmed — previewing an alert that is still off is
-- exactly the point. Volume page: hear the working widget volume; Voice page: hear the
-- working language. (Appended here, after the alert specs, as plain literals — no
-- helper local: the main chunk sits at the 200-locals limit.)
SETTINGS_VOLUME[#SETTINGS_VOLUME + 1] = { kind = "action", lbl = "Test callout", btn = "Play",
    act = function(wgt, working)
        ultidash_functions.test_callout(wgt, working, { files = { "battry" }, num = { 70, UNIT_PERCENT } })
    end }
SETTINGS_VOICE[#SETTINGS_VOICE + 1] = { kind = "action", lbl = "Test callout", btn = "Play",
    act = function(wgt, working)
        ultidash_functions.test_callout(wgt, working, { files = { "telem_ok" } })
    end }

-- Alerts submenu: a "Voice / mute" entry plus one page per alert. The alert pages'
-- ROW TABLES build LAZILY on first open (build_alert_items lives in the lazy menu
-- module, like the Shortcuts/Colors rows) -- 12 pages x ~8 rows of item tables +
-- dim closures used to build here at module load, inside create()'s instruction
-- budget, for pages the user may never open. page.keys hands for_each_setting_item
-- the key/def pairs WITHOUT building rows -- keep it in sync with build_alert_items
-- (ultidashMenu.lua) when adding an alert row. page.spec carries the alert's spec
-- so the submenu shows On/Off + the feature markers straight from the options.
local ALERT_PAGES = { { name = "Voice / mute", items = SETTINGS_VOICE } }
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
local SETTINGS_SWITCHES = {
    { key = "MotorSrc",   lbl = "Motor on/off switch",  kind = "switch", def = 0 },
    { key = "RescueSrc",  lbl = "Rescue switch",        kind = "switch", def = 0 },
    { key = "GovSrc",     lbl = "Governor mode switch", kind = "switch", def = 0 },
    { key = "ProfileSrc", lbl = "Profile switch (1-3)", kind = "switch", def = 0 },
}

-- Governor-state voice: announce the Gov sensor's state (0..9) on every stable change
-- while ARMED. GovVoice is the master toggle (default off — opt-in feature); each state
-- has its own enable so noisy transitions can be silenced. All states default ON so the
-- master switch alone gives full feedback; dim the per-state rows while the master is off.
local function gov_voice_off(w) return (w.GovVoice or 0) ~= 1 end
local SETTINGS_GOVVOICE = {
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
}

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
local SETTINGS_TELE_MAIN = {
    { kind = "info", lbl = "Dropdown = common sensors. Right field = any raw source (overrides the dropdown)." },
    { key = "PanelV1", lbl = "Panel 1 (top)", kind = "sensor", def = VOLT_AUTO },
    { key = "PanelV2", lbl = "Panel 2",       kind = "sensor", def = "Hspd" },
    { key = "PanelV3", lbl = "Panel 3",       kind = "sensor", def = "Curr" },
    { key = "PanelV4", lbl = "Panel 4",       kind = "sensor", def = "Tesc" },
    { key = "PanelV5", lbl = "Panel 5 (btm)", kind = "sensor", def = "Vbec" },
}

local SETTINGS_TELE_DETAIL = {
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
}

-- General / meta settings (config-file behaviour, diagnostics)
local SETTINGS_GENERAL = {
    { key = "CfgPerCraft", lbl = "Config file per craft", kind = "bool", def = 0 },
    { key = "DebugLog",    lbl = "Debug log to SD card",  kind = "bool", def = 0 },
    { key = "DebugKeep",   lbl = "Debug log: sessions kept", kind = "num", def = 20, min = 1, max = 50, step = 1, big = 5 },
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
}

-- Toolbox: RF adjustment map/editor tool pages (sources default to ch11/ch12/AdjV/BEAT/PID#)
local SETTINGS_TOOLBOX = {
    -- activation switch / auto-open moved to the "Shortcuts" group (SETTINGS_SHORTCUTS);
    -- a shortcut can now open Adjust Map / Adjust Edit like any other page.
    { key = "TbConfigCh", lbl = "Adj: Config channel",  kind = "num", def = 11, min = 1, max = 32, step = 1, big = 4, fmt = function(v) return "CH" .. v end },
    { key = "TbValueCh",  lbl = "Adj: Value channel",   kind = "num", def = 12, min = 1, max = 32, step = 1, big = 4, fmt = function(v) return "CH" .. v end },
    { key = "TbGvar",  lbl = "Adj editor: GVAR",        kind = "num", def = 1, min = 1, max = 15, step = 1, big = 1,
                       fmt = function(v) return "GV" .. v end },
    { key = "TbPulse", lbl = "Adj editor: pulse (ms)",  kind = "num", def = 150, min = 50, max = 1000, step = 10, big = 50 },
    { key = "TbScale", lbl = "Adj value divider",       kind = "num", def = 1, min = 1, max = 1000, step = 1, big = 10 },
    { key = "TbBert",  lbl = "Adj editor: ranges hint", kind = "bool", def = 0 },
    { key = "TbSun",   lbl = "Toolbox sunlight mode",   kind = "bool", def = 0 },
    { key = "TbVoice", lbl = "Announce bank (voice)",   kind = "bool", def = 1 },
}

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
    { name = "Position slots",  build = shortcut.pos_items, keys = function(fn)
        fn("SwDelay", 300)
        for i = 1, 6 do
            fn("Sc" .. i .. "Sp", 0); fn("Sc" .. i .. "Tgt", 1)
        end
    end },
    { name = "Toggle switches", build = shortcut.tgl_items, keys = function(fn)
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
local COLOR_PAGES = {
    { name = "UltiDash",      scheme = SCHEME_ULTIDASH },
    { name = "UltiDash dark", scheme = SCHEME_DARK },
    { name = "EdgeTX theme",  scheme = SCHEME_THEME },
}

-- Ordered so that each consecutive run of 3 groups forms one themed row of the settings
-- grid; .sections names those rows (counts must add up to the group count — keep both in
-- sync when adding a group: extend a section to 6 entries / two rows, or add a section).
-- "Telemetry" and "Voice" are two-page submenus purely to keep the grid at 3x4: their
-- inline page lists are plain {name, items}, walked by the generic build_sub_menu_view
-- and for_each_setting_item like the Alerts pages. (NB main chunk is at the 200-locals
-- limit — the page lists/section table are inline/attached, NOT new module locals.)
local SETTINGS_GROUPS = {
    { name = "Display",    items = SETTINGS_DISPLAY },
    { name = "Colors",     submenu = COLOR_PAGES, menu = "colors_menu" },
    { name = "Telemetry",  menu = "sub_menu", submenu = {
        { name = "Tele Main",    items = SETTINGS_TELE_MAIN },
        { name = "Tele Details", items = SETTINGS_TELE_DETAIL },
    } },

    { name = "Battery",    items = SETTINGS_BATTERY },
    { name = "Thresholds", items = SETTINGS_THRESHOLDS },
    { name = "ESC load",   items = SETTINGS_ESC },

    { name = "Volume",     items = SETTINGS_VOLUME },
    { name = "Alerts",     submenu = ALERT_PAGES, menu = "alerts_menu" },
    { name = "Voice",      menu = "sub_menu", submenu = {
        { name = "Switch voice", items = SETTINGS_SWITCHES },
        { name = "Gov voice",    items = SETTINGS_GOVVOICE },
    } },

    { name = "Shortcuts",  menu = "sub_menu", submenu = shortcut.pages },
    { name = "Toolbox",    items = SETTINGS_TOOLBOX },
    { name = "General",    items = SETTINGS_GENERAL },
}
SETTINGS_GROUPS.sections = {
    { hdr = "Appearance",      n = 3 },
    { hdr = "Battery & limits", n = 3 },
    { hdr = "Sound & callouts", n = 3 },
    { hdr = "System",          n = 3 },
}

-- Visit every settings item across all groups AND alert sub-pages. Used for the
-- defaults table and the working-copy snapshot so both cover the submenu items.
local color_setting_scratch = { def = -1 }   -- reused scratch row for synthesised keys (fn must only READ it; key AND def are (re)set per row)
local function for_each_setting_item(fn)
    for g = 1, #SETTINGS_GROUPS do
        local grp = SETTINGS_GROUPS[g]
        if grp.items then
            for i = 1, #grp.items do fn(grp.items[i]) end
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
for_each_setting_item(function(it)
    if it.key then SETTINGS_DEFAULTS[it.key] = it.def end   -- skip keyless info rows
end)
-- hidden key (no settings row): tracks whether the in-widget menu was opened at
-- least once — drives the first-placement hint banner on the dashboard
SETTINGS_DEFAULTS.SetupSeen = 0
ultidash_settings.set_defaults(SETTINGS_DEFAULTS)

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
        return
    end
    if settings_changed(wgt) then
        if not ultidash_settings.save(wgt.settings_working) then
            ultidash_functions.log("settings save FAILED (cfg file not writable)")
            wgt.cfg_save_failed_text = nil                        -- default banner wording
            wgt.cfg_save_failed_until = (getTime() or 0) + 1000   -- ~10 s sticky warn banner
        end
        ultidash_settings.apply(wgt)
        settings_gen = settings_gen + 1   -- invalidate palette memo + trip passive rebuild
    end
    wgt.settings_working = nil
    wgt.settings_target = nil
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
    -- RF2 Config MUST run its own close on ANY forced exit (fullscreen exit):
    -- it restores the rf2.* UI slots and the un-gated mspQueue pump -- without
    -- that, the RfTool widget's MSP processing would stay parked behind the
    -- module's context gate.
    if wgt.menu_view == "tb_rf2cfg" and tb_rf2cfg then
        if tb_rf2cfg.cleanup then tb_rf2cfg.cleanup(wgt) end
        wgt.rf2cfg_close_req = nil      -- consumed here; a stale flag would shut a fresh page
        tb_rf2cfg = nil                 -- release the lazy-loaded module (GC)
    end
    -- Log Viewer: release the open /LOGS file handle + the ~2000-line module
    if wgt.menu_view == "tb_logview" and tb_logview then
        if tb_logview.close then tb_logview.close(wgt) end
        wgt.lv_close_req = nil          -- consumed here; a stale flag would shut a fresh page
        tb_logview = nil                -- release the lazy-loaded module (GC)
    end
    -- Flight Log viewer: release the open CSV handle on a forced exit
    if wgt.menu_view == "tb_fltlog" and fltlog.mod then
        if fltlog.mod.cleanup then fltlog.mod.cleanup(wgt) end
        wgt.fl_close_req = nil          -- consumed here; a stale flag would shut a fresh page
        fltlog.mod = nil                -- release the lazy-loaded module (GC)
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
        if ultidash_functions.dbg then ultidash_functions.dbg.logf("STATS", "dismiss cleared (arm rising edge)") end
        -- flight log: a genuine arm opens a flight record (counter snapshot)
        fltlog.arm(wgt)
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
local function menu_load()
    if menu_mod ~= nil then return menu_mod end
    if menu_env == nil then
        menu_env = {
            init_view_state       = init_view_state,
            close_settings        = close_settings,
            for_each_setting_item = for_each_setting_item,
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
                return tb_adjmap_avail, tb_adjed_avail, tb_logview_avail, tb_rf2cfg_avail
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
            SCHEME_ULTIDASH       = SCHEME_ULTIDASH,
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

-- ============================================================================
-- SWITCH SHORTCUTS ENGINE
-- ============================================================================
-- Methods on the `shortcut` table (data + labels declared near the top). Drives the
-- shortcut bindings (6 position slots + 2 toggle slots) from inside the 5 Hz pass.
-- Replaces the old single DvSrc/TbSrc auto-open blocks: every binding routes through
-- shortcut.open/close against shortcut.targets, so a switch can open ANY detail page or
-- Toolbox tool. Edge/hold triggered — never fights manual navigation (open/close only
-- act on the exact page THIS binding controls).

-- Is a tool target actually available right now (module present / loadable)?
function shortcut.tool_ready(tgt)
    if tgt.id == "tb_adjmap" then return tb_load_adjmap() ~= nil end
    if tgt.id == "tb_adjed"  then return tb_load_adjed()  ~= nil end
    if tgt.load == "logview" then return tb_load_logview() ~= nil end
    if tgt.load == "rf2cfg"  then return tb_load_rf2cfg()  ~= nil end
    if tgt.load == "fltlog"  then return fltlog.load_viewer() ~= nil end
    return true
end

-- Open a shortcut target. Mirrors the tap-open gating: a detail overlay opens only over
-- the flight view with nothing else up; a tool page honours the disarmed-only rule and
-- opens over the dashboard or the Toolbox hub. Returns true if it opened.
function shortcut.open(wgt, tgt)
    if not tgt or tgt.kind == "none" then return false end
    if tgt.kind == "detail" then
        if wgt.menu_view == nil and wgt.detail_view == nil
            and init_view_state(wgt).current == "flight" then
            wgt.detail_view = tgt.id
            init_view_state(wgt).dirty = true
            return true
        end
        return false
    end
    -- tool page
    if tgt.disarmed and wgt.armed_now then
        wgt.lv_armed_hint = (getTime() or 0) + 200   -- ~2 s "disarmed only" hint
        return false
    end
    -- Tool pages are FULLSCREEN UIs (lvgl.page / immediate fullscreen builds); opening
    -- one in normal widget mode builds a fullscreen page into the small widget zone —
    -- lvgl.page crashes ("attempt to index a nil value"), the Log Viewer flickers open
    -- then closes. The menu path can't hit this (the menu glyph is fullscreen-only), so
    -- mirror that guarantee here. Gated BEFORE tool_ready so we don't even lazy-load the
    -- module while not fullscreen. A held position re-fires once the user is fullscreen.
    if lvgl.isFullScreen == nil or not lvgl.isFullScreen() then return false end
    -- view gate BEFORE tool_ready: tool_ready lazy-LOADS the module, so with a bound
    -- switch held while another page is open it would load logview/rf2cfg every 5 Hz
    -- pass just to have the open refused below — the module stayed resident (GC drag)
    if not (wgt.menu_view == nil or wgt.menu_view == "toolbox") then return false end
    if not shortcut.tool_ready(tgt) then return false end
    wgt.detail_view = nil                             -- tool pages own the whole screen
    -- a stale close request from an earlier shortcut-close of the SAME module would
    -- otherwise shut the fresh page in its first refresh (the module never saw the
    -- close, so the flag was never consumed)
    if tgt.id == "tb_logview" then wgt.lv_close_req = nil end
    if tgt.id == "tb_rf2cfg"  then wgt.rf2cfg_close_req = nil end
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
    if tgt.kind == "detail" then
        if wgt.detail_view == tgt.id then
            wgt.detail_view = nil
            init_view_state(wgt).dirty = true
        end
    elseif tgt.kind == "tool" then
        if wgt.menu_view == tgt.id then
            close_tool_page(wgt)
            wgt.menu_view = nil
            init_view_state(wgt).dirty = true
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
                    if shortcut.open(wgt, tgt) then s.opened = true; s.tgt = tgt end
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

--- Build the flight dashboard layout for the current widget zone.
local function build_flight_ui(wgt, zone)
    local w = zone.w
    local h = zone.h

    local h_status = math.floor(h * 0.075)
    local h_top = h_status
    local status_box_h = math.max(1, h_status - 2)
    local top_box_h = math.max(1, h_top - 2)
    local outer_pad = 2

    header_font = select_font(status_box_h, nil, nil)
    header_h = measure_font(header_font)

    local content_w = w - 2 * outer_pad
    local content_h = h - h_top - h_status - 2 * card_gap - 2 * outer_pad
    local y_content = outer_pad + h_top + card_gap
    local y_status = y_content + content_h + card_gap

    local w_fuel = math.max(46, math.floor(content_w * 0.20))
    local remaining_w = content_w - w_fuel - 2 * card_gap
    local w_left = math.floor(remaining_w / 2)
    local w_right = remaining_w - w_left
    local x_fuel = outer_pad + w_left + card_gap
    local x_right = x_fuel + w_fuel + card_gap

    wgt.status_bar_elements = nil
    wgt.status_bar_state = nil

    local main_panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG, filled = force_bg_fill or (wgt.options.BGFilled == 1) })

    -- top bar (date/time + radio battery)
    local top_bar_box = main_panel:box({ x = 0, y = outer_pad, w = w - 4, h = top_box_h })
    build_top_bar_element(top_bar_box, wgt, 0, 0, w - 4, top_box_h)
    main_panel:hline({ y = y_content - 1, w = w - 3, h = 1, color = COLOR_THEME_SECONDARY1 })

    build_flight_status_panel(main_panel, wgt, outer_pad, y_content, w_left, content_h)
    build_vertical_fuel_gauge_element(main_panel, wgt, x_fuel, y_content, w_fuel, content_h)
    -- tapping the gauge (fullscreen) opens the battery detail page
    wgt.battery_rect = { x = x_fuel, y = y_content, w = w_fuel, h = content_h }
    build_flight_values_panel(main_panel, wgt, x_right, y_content, w_right, content_h)
    -- tapping the values panel (fullscreen) opens the Telemetry detail page
    wgt.values_rect = { x = x_right, y = y_content, w = w_right, h = content_h }

    main_panel:hline({ y = y_status - 1, w = w - 3, h = 1, color = COLOR_THEME_SECONDARY1 })

    local status_bar_box = main_panel:box({ x = 0, y = y_status, w = w - 4, h = status_box_h })
    wgt.status_bar_box = status_bar_box
    wgt.status_bar_dims = { x = 0, y = 0, w = w - 4, h = status_box_h }

    build_status_bar_element(status_bar_box, wgt, 0, 0, w - 4, status_box_h)

    -- first-placement hint: all options live in the fullscreen menu, which a new
    -- user cannot know — a clear centered overlay window (built last = on top),
    -- shown until the menu was opened once (SetupSeen, persisted).
    -- IMPORTANT: drawn as plain build-table primitives on the panel, NOT an
    -- lvgl.box — boxes built while fullscreen keep LV_OBJ_FLAG_CLICKABLE (the old
    -- touch root cause) and a centered box swallowed every tap on the screen
    -- middle (status line, stats dismiss) while the hint was visible.
    -- Only BUILT while still pending: SetupSeen only ever flips 0->1 (opening the menu,
    -- which rebuilds), so once seen the hint can never become visible again -- skipping
    -- its 6 primitives keeps this near-20k-instruction build under the EdgeTX CPU budget.
    if (wgt.options.SetupSeen or 0) ~= 1 then
        local hint_w = math.floor(w * 0.74)
        local hint_h = math.max(88, math.floor(h * 0.34))
        local hx = math.floor((w - hint_w) / 2)
        local hy = math.floor((h - hint_h) / 2)
        local line_h = math.floor((hint_h - 12) / 4)
        main_panel:build({
            { type = "rectangle", x = hx, y = hy, w = hint_w, h = hint_h, filled = true, rounded = 6, color = PANEL_BG },
            { type = "rectangle", x = hx, y = hy, w = hint_w, h = hint_h, thickness = 2, rounded = 6, color = COLOR_THEME_WARNING },
            { type = "label", x = hx + 10, y = hy + 6, w = hint_w - 20, h = line_h,
              text = "UltiDash setup", font = MIDSIZE, color = COLOR_THEME_PRIMARY1, align = CENTER },
            { type = "label", x = hx + 10, y = hy + 6 + line_h, w = hint_w - 20, h = line_h,
              text = "All settings live in the widget menu:", color = COLOR_THEME_PRIMARY1, align = CENTER },
            { type = "label", x = hx + 10, y = hy + 6 + 2 * line_h, w = hint_w - 20, h = line_h,
              text = "long-press > Full screen,", color = COLOR_THEME_PRIMARY1, align = CENTER },
            { type = "label", x = hx + 10, y = hy + 6 + 3 * line_h, w = hint_w - 20, h = line_h,
              text = "then tap the menu symbol (top left)", color = COLOR_THEME_PRIMARY1, align = CENTER },
        })
    end

    -- transient warning if a settings save/reset couldn't be written to the SD card
    add_warn_banner(main_panel, w, y_content + 2, save_failed_text(wgt), save_failed_visible(wgt))
    -- config error: two Dashboard instances both publishing (doubled callouts / flicker).
    -- Distinct y (a line below) so it never overlaps the save-failed banner.
    add_warn_banner(main_panel, w, y_content + 2 + measure_font(STDSIZE) + 6,
        "2 Dashboard instances active!", dual_publisher_visible(wgt))
    -- hidden critical-alert overlay layer, LAST so it stacks on top (reactive
    -- visible only -- state lives in update_alert_overlay, tap-dismiss in refresh())
    ultidash_functions.add_alert_overlay(main_panel, wgt, w, h)
end

--- Build the statistics dashboard layout for the current widget zone.
local function build_stats_ui(wgt, zone)
    local w = zone.w
    local h = zone.h
    local stats_content_w = math.max(1, w - 1)
    local info_content_w = math.max(1, stats_content_w - 1)

    local line_h = 1
    local h_status = math.floor(h * 0.075)
    local h_top = h_status
    local status_box_h = math.max(1, h_status - 2)
    local top_box_h = math.max(1, h_top - 2)

    header_font = select_font(status_box_h, nil, nil)
    header_h = measure_font(header_font)

    local y_content = h_top + line_h
    local content_h = h - h_top - h_status - 3 * line_h
    -- slim single info line (was a 3-card band Flight Time / mAh Used / Batt
    -- Profile: the profile is not useful here and the cards ate ~16% height;
    -- the freed space hosts the per-profile headspeed rows in the table)
    local h_info = header_h + 6
    local h_mid = content_h - h_info

    local y_info = y_content + h_mid + line_h
    local y_status = y_info + h_info + line_h

    wgt.status_bar_elements = nil
    wgt.status_bar_state = nil

    local main_panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG, filled = force_bg_fill or (wgt.options.BGFilled == 1) })

    -- top bar (date/time + radio battery); no RQ/TQ on the stats page
    local top_bar_box = main_panel:box({ x = 0, y = 1, w = w - 4, h = top_box_h })
    build_top_bar_element(top_bar_box, wgt, 0, 0, w - 4, top_box_h, false)
    main_panel:hline({ y = y_content - line_h, w = w - 3, h = line_h, color = COLOR_THEME_SECONDARY1 })

    build_flight_statistics_element(main_panel, wgt, 0, y_content, stats_content_w, h_mid - line_h)

    main_panel:hline({ y = y_info - line_h, w = w - 3, h = line_h, color = COLOR_THEME_SECONDARY1 })

    -- one slim line: session flight time + used mAh (raw %)
    main_panel:label({ x = 0, y = y_info + 3, w = info_content_w, h = header_h,
        text = (function()
            -- inputs are memoized; memo the concat so the stats page (the default
            -- disconnected view) doesn't allocate this line on every frame
            local last_ft, last_bu, last_s
            return function()
                local ft = wgt.values.flight_time_str_formatted()
                local bu = wgt.values.battery_usage_summary_formatted()
                if ft ~= last_ft or bu ~= last_bu then
                    last_ft, last_bu = ft, bu
                    last_s = wgt.values.label_flight_time .. "  " .. ft
                        .. "        " .. wgt.values.label_capacity_used_short .. "  " .. bu
                end
                return last_s
            end
        end)(),
        font = header_font, color = COLOR_THEME_PRIMARY1, align = CENTER })

    main_panel:hline({ y = y_status - line_h, w = w - 3, h = line_h, color = COLOR_THEME_SECONDARY1 })

    local status_bar_box = main_panel:box({ x = 0, y = y_status, w = w - 4, h = status_box_h })
    wgt.status_bar_box = status_bar_box
    wgt.status_bar_dims = { x = 0, y = 0, w = w - 4, h = status_box_h }

    build_status_bar_element(status_bar_box, wgt, 0, 0, w - 4, status_box_h)

    -- transient warning if a settings save/reset couldn't be written to the SD card
    add_warn_banner(main_panel, w, y_content + 2, save_failed_text(wgt), save_failed_visible(wgt))
    -- config error: two Dashboard instances both publishing (doubled callouts / flicker).
    -- Distinct y (a line below) so it never overlaps the save-failed banner.
    add_warn_banner(main_panel, w, y_content + 2 + measure_font(STDSIZE) + 6,
        "2 Dashboard instances active!", dual_publisher_visible(wgt))
    -- hidden critical-alert overlay layer, LAST so it stacks on top
    ultidash_functions.add_alert_overlay(main_panel, wgt, w, h)
end

--- Rebuild the widget UI for the active view and current options. `defer_build` (used only
--- by create()) runs the cheap settings/palette prep but leaves the heavy build to the next
--- refresh() cycle, so a cold boot's first cfg read doesn't share create()'s budget.
local function update(wgt, options, defer_build)
    if (wgt == nil) then return end
    prepare_widget(wgt)
    wgt.options = options
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
        wgt.settings_apply_pending = nil
        ultidash_settings.apply(wgt)
        if is_publisher(wgt) and ultidash_functions.dbg_loadable()
            and (wgt.options.DebugLog == 1)
                ~= (ultidash_functions.dbg ~= nil and ultidash_functions.dbg.is_enabled()) then
            wgt.dbg_enable_pending = { wgt.options.DebugLog == 1, wgt.options.DebugKeep }
        end
        if is_publisher(wgt) and ultidash_settings.load() == nil then
            wgt.cfg_snapshot_pending = true
        end
        init_view_state(wgt).dirty = true
        return wgt
    end
    -- overlay the per-model settings file onto the EdgeTX options (file wins for
    -- saved keys; no file = pure EdgeTX behavior). ViewMode is never overridden.
    ultidash_settings.apply(wgt)
    -- diagnostics: drive the optional file logger from the per-model DebugLog option.
    -- Publisher only (it owns telemetry/state logging); no-op without ultidashDebug.lua.
    -- Enabling it STARTS a log session (several SD writes); that I/O must not share this
    -- call's instruction budget with the full UI build, or a cold boot (module ENABLED
    -- starts false) overruns it mid-build ("CPU limit"). Defer to its own refresh cycle,
    -- and only on an actual on/off change -- a no-op set_enabled is cheap, the session
    -- start is not. DebugKeep rides along on that transition.
    if is_publisher(wgt) and ultidash_functions.dbg_loadable()
        and (wgt.options.DebugLog == 1)
            ~= (ultidash_functions.dbg ~= nil and ultidash_functions.dbg.is_enabled()) then
        wgt.dbg_enable_pending = { wgt.options.DebugLog == 1, wgt.options.DebugKeep }
    end
    -- One-time migration: when no per-model file exists yet, snapshot the current
    -- effective option values into it. Only the Dashboard placement does this (its
    -- options carry the user's tuning; passive instances may sit at defaults).
    -- Prerequisite for eventually shrinking the EdgeTX option list to ViewMode.
    -- DEFERRED to a refresh() cycle of its own: EdgeTX gives each widget call a
    -- 20k-instruction budget (lua_widget.cpp MAX_INSTRUCTIONS), and snapshot +
    -- cfg file write on top of the full UI build in this same call blew it
    -- ("CPU limit" mid-build).
    if is_publisher(wgt) and ultidash_settings.load() == nil then
        wgt.cfg_snapshot_pending = true
    end


    local mode = options.ViewMode or VIEW_MODE_DASHBOARD

    -- apply the chosen color palette to all modules before (re)building the UI.
    -- Passive views inherit the DASHBOARD's published scheme ("the main widget is
    -- the boss"); their own ColorScheme option only matters while no Dashboard runs.
    local scheme = options.ColorScheme or 1   -- 1 = UltiDash, 2 = UltiDash dark, 3 = EdgeTX theme
    if mode ~= VIEW_MODE_DASHBOARD and ultidash_functions.shared_alive() then
        scheme = ultidash_functions.get_shared().color_scheme or scheme
    end
    -- The in-widget menu / settings pages are native lvgl.page objects: their chrome
    -- (background, scrollbar) follows the EdgeTX theme, which we cannot repaint. On the
    -- dark scheme our white label text would sit on that light page and be unreadable,
    -- so render those native-page views with the EdgeTX-theme palette instead. The
    -- dashboard and the detail pages (our own dark panels) keep the dark scheme.
    local render_scheme = scheme
    -- when the dark scheme is FORCED onto the native menu pages, render them NEUTRAL: use the
    -- EdgeTX-theme built-ins WITHOUT this model's EdgeTX-theme colour overrides (ClrE*). A dark
    -- user's theme-page overrides are meant for the actual EdgeTX-theme scheme, not for the
    -- menus they only see because of this readability forcing (design decision, review #5).
    local menu_neutral = false
    if scheme == SCHEME_DARK and wgt.menu_view ~= nil then
        render_scheme = SCHEME_THEME
        menu_neutral  = true
    end
    -- per-model colour overrides + built-ins for the scheme being rendered — MEMOISED, so a
    -- plain view switch (same scheme, no settings save) reuses them instead of rebuilding both
    -- every time. settings_gen invalidates the memo whenever settings are saved/reset.
    if pal_memo.scheme ~= render_scheme or pal_memo.gen ~= settings_gen or pal_memo.neutral ~= menu_neutral then
        pal_memo.scheme  = render_scheme
        pal_memo.gen     = settings_gen
        pal_memo.neutral = menu_neutral
        pal_memo.b       = cached_builtins(render_scheme)
        pal_memo.ovr     = menu_neutral and nil or build_overrides(options, render_scheme)
    end
    local pal = set_palette(pal_memo.b, pal_memo.ovr)   -- applies palette + semantics + overrides
    ultidash_functions.set_palette(render_scheme, pal, SEM)
    ultidash_values.set_palette(render_scheme, pal, SEM)
    -- palette for the Toolbox tool pages: use the REAL scheme (not the forced render_scheme)
    -- so the tools match the dashboard look (black+neon on dark, etc.)
    wgt.tb_pal = toolbox_palette(scheme)

    lvgl.clear()
    -- everything lvgl is gone now — drop the cached element references so nothing
    -- (e.g. update_status_bar_visibility) touches a cleared object ("Invalid object"
    -- error). The flight/stats builders repopulate them; the other views have none.
    wgt.status_bar_elements = nil
    wgt.status_bar_state = nil
    wgt.status_bar_box = nil
    -- tap-target rects: only the builders that exist in the new layout re-set them
    wgt.estatus_rect = nil
    wgt.elrs_bar_rect = nil
    wgt.settings_icon_rect = nil
    wgt.battery_rect = nil
    wgt.values_rect = nil
    wgt.battprofile_rect = nil

    -- dispatch by ViewMode: Dashboard keeps the flight/stats switching; the passive
    -- modes render their dedicated single view (no stats page, no status bar).
    if mode == VIEW_MODE_ELRS then
        build_elrs_view(wgt, wgt.zone)
    elseif mode == VIEW_MODE_STATUS then
        build_status_view(wgt, wgt.zone)
    elseif wgt.menu_view == "status" then
        build_status_view(wgt, wgt.zone, true)
    elseif wgt.menu_view ~= nil and string.sub(wgt.menu_view, 1, 3) ~= "tb_" then
        -- menu family (hub, Toolbox/Settings submenus, settings pages, sensor
        -- check, battery pickers): all built by the LAZY menu module. Missing
        -- module (partial deploy) = clean degrade back to the dashboard.
        local m = menu_load()
        if m ~= nil then
            m.build(wgt, wgt.zone, wgt.menu_view)
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
    elseif wgt.menu_view == "tb_logview" and tb_logview then
        tb_logview.build(wgt, wgt.zone)
    elseif wgt.menu_view == "tb_fltlog" and fltlog.mod then
        -- hand the viewer the resident fltdata instance (it loaded a second
        -- module copy per open); fltdata is tiny and stays resident by design anyway
        wgt.flt_data_mod = fltlog.load_data()
        fltlog.mod.build(wgt, wgt.zone)
    elseif wgt.menu_view == "tb_rf2cfg" and tb_rf2cfg then
        -- RF2 Config paints ITSELF (original tool: lvgl.clear+build inside its
        -- runner); build() only shows the glue notice page / pokes a re-show.
        tb_rf2cfg.build(wgt, wgt.zone)
    elseif wgt.detail_view == "elrs" and init_view_state(wgt).current == "flight" then
        -- Dashboard's own ELRS detail page (opened by tapping the top-bar bars)
        build_elrs_view(wgt, wgt.zone, true)
    elseif wgt.detail_view == "estatus" and init_view_state(wgt).current == "flight" then
        -- status detail page (opened by tapping the ESC/arming status line)
        build_estatus_view(wgt, wgt.zone)
    elseif wgt.detail_view == "battery" and init_view_state(wgt).current == "flight" then
        -- battery detail page (opened by tapping the center fuel gauge)
        build_battery_view(wgt, wgt.zone)
    elseif wgt.detail_view == "telem" and init_view_state(wgt).current == "flight" then
        -- telemetry detail page (opened by tapping the right value panel)
        build_telem_view(wgt, wgt.zone)
    elseif init_view_state(wgt).current == "flight" then
        build_flight_ui(wgt, wgt.zone)
    else
        build_stats_ui(wgt, wgt.zone)
    end
    init_view_state(wgt).dirty = false
    wgt.layout_dirty = false
    if mode == VIEW_MODE_DASHBOARD then
        -- Force status bar visibility update after UI rebuild
        update_status_bar_visibility(wgt, true)
    else
        -- remember what this build inherited from the Dashboard; refresh rebuilds
        -- when it changes (publisher appears/disappears, palette change)
        wgt.passive_style_sig = passive_style_sig()
    end
    return wgt
end

--- Create a NEW widget instance (own table per placement) and build its layout.
local function create(zone, options)
    local wgt = ultidash_values.createWidget()
    wgt.zone = zone
    wgt.options = options
    return update(wgt, options, true)   -- flag only; cfg apply + UI build follow in refresh()
end

--- Run background RF and telemetry work that should not rebuild the UI.
--- Publisher only: passive instances (ELRS/Status) do no background work at all —
--- no MSP, no audio, no stats, no rf2 registration.
local function background(wgt)
    if not wgt then return end
    prepare_widget(wgt)
    -- Stage 2 of the deferred create() when the widget is HIDDEN (refresh never runs):
    -- apply the settings alone in this call's budget before any option-dependent work.
    -- The ride-along flags mirror refresh()'s stage 2: a publisher that never
    -- becomes visible must still start its DebugLog session / write its first cfg.
    if wgt.settings_apply_pending then
        wgt.settings_apply_pending = nil
        ultidash_settings.apply(wgt)
        if is_publisher(wgt) and ultidash_functions.dbg_loadable()
            and (wgt.options.DebugLog == 1)
                ~= (ultidash_functions.dbg ~= nil and ultidash_functions.dbg.is_enabled()) then
            wgt.dbg_enable_pending = { wgt.options.DebugLog == 1, wgt.options.DebugKeep }
        end
        if is_publisher(wgt) and ultidash_settings.load() == nil then
            wgt.cfg_snapshot_pending = true
        end
        return
    end
    if not is_publisher(wgt) then return end
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
    -- Stage 2 of the deferred create() (see update): the cold cfg SD read + parse + apply
    -- runs ALONE in this cycle's budget. The checks that need the applied options (DebugLog
    -- transition, cold-boot snapshot) ride along — load() is cached by now, so they're cheap.
    -- dirty is already set, so the NEXT cycle builds the UI (stage 3) with a fresh budget.
    if wgt.settings_apply_pending then
        wgt.settings_apply_pending = nil
        ultidash_settings.apply(wgt)
        if is_publisher(wgt) and ultidash_functions.dbg_loadable()
            and (wgt.options.DebugLog == 1)
                ~= (ultidash_functions.dbg ~= nil and ultidash_functions.dbg.is_enabled()) then
            wgt.dbg_enable_pending = { wgt.options.DebugLog == 1, wgt.options.DebugKeep }
        end
        if is_publisher(wgt) and ultidash_settings.load() == nil then
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
            or wgt.menu_view == "sensorcheck" or wgt.menu_view == "toolbox" then
            wgt.menu_view = "menu"                -- submenu -> hub
            init_view_state(wgt).dirty = true
        elseif wgt.menu_view == "tb_adjmap" or wgt.menu_view == "tb_adjed" then
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
            -- RTN steps a per-flight detail page back to the list first (on_exit_key
            -- reports it handled that); at the list top level it leaves the tool.
            if not (fltlog.mod and fltlog.mod.on_exit_key(wgt)) then
                if fltlog.mod then fltlog.mod.close(wgt) end
                fltlog.mod = nil                   -- release the lazy-loaded module (GC)
                wgt.menu_view = (wgt.tool_back == "toolbox") and "toolbox" or nil
            end
            init_view_state(wgt).dirty = true
        elseif wgt.menu_view == "tb_rf2cfg" then
            -- RF2 Config owns RTN completely (original RF2 key loop: page ->
            -- main menu -> exit). The event reaches the module in the refresh
            -- dispatch below; the final exit comes back as wgt.rf2cfg_close_req.
            -- No host action here (the branch only keeps the generic else from
            -- closing the view underneath the module).
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
        tb_adjmap.refresh(wgt, event, touch_state)
    elseif wgt.menu_view == "tb_adjed" and tb_adjed then
        wgt.tb_announce = ultidash_functions.tb_announce_pos
        tb_adjed.refresh(wgt, event, touch_state)
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
    end
    -- Toolbox menu: rebuild on the arm transition while it is open, so the
    -- disarmed-only tools flip between dimmed and normal (build-time tcol)
    if wgt.menu_view == "toolbox" and (wgt.tb_menu_armed or false) ~= (wgt.armed_now or false) then
        init_view_state(wgt).dirty = true
    end
    -- (the sensor-check 1 Hz scan tick lives below with the deferred-work chains —
    -- it needs an EXCLUSIVE cycle)
    if fs and is_publisher(wgt) and EVT_TOUCH_TAP ~= nil and event == EVT_TOUCH_TAP then
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
        if (tap_count == nil or tap_count <= 1)
            and now >= (wgt.elrs_tap_block or 0) and wgt.menu_view == nil then
            if wgt.ovl_active ~= nil and wgt.detail_view == nil then
                -- critical-alert overlay: ANY tap dismisses the current episode.
                -- Only while it is actually visible (flight/stats view — an open detail
                -- page replaces that tree, so its taps must not be swallowed here).
                -- Long cooldown so the bounce can't click through onto the tap zone
                -- underneath; no rebuild needed (reactive visible).
                wgt.elrs_tap_block = now + 100
                wgt.ovl_dismissed = wgt.ovl_active
                wgt.ovl_active = nil
            elseif wgt.detail_view ~= nil then
                -- Status log scroll: taps on the ▲/▼ buttons scroll the log (short cooldown)
                -- and do NOT close; any other tap closes the detail (long cooldown).
                if wgt.detail_view == "estatus" and rect_hit(touch_state, wgt.estatus_scroll_up, 6) then
                    wgt.elrs_tap_block = now + 25
                    wgt.estatus_scroll = math.max(0, (wgt.estatus_scroll or 0) - 1)
                    init_view_state(wgt).dirty = true
                elseif wgt.detail_view == "estatus" and rect_hit(touch_state, wgt.estatus_scroll_down, 6) then
                    wgt.elrs_tap_block = now + 25
                    wgt.estatus_scroll = (wgt.estatus_scroll or 0) + 1
                    init_view_state(wgt).dirty = true
                else
                    wgt.elrs_tap_block = now + 100
                    wgt.detail_view = nil
                    init_view_state(wgt).dirty = true
                end
            elseif rect_hit(touch_state, menu_tap_rect(wgt), 10)
                and not (ultidash_functions.is_armed(wgt)
                    and wgt.values.rf_connection_state ~= "disconnected") then
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
                -- manual dismiss of the statistics page: any tap (outside the menu
                -- glyph) returns to the flight view; it reappears with the next
                -- arm/disarm or reconnect cycle (flags cleared there)
                wgt.elrs_tap_block = now + 100
                wgt.stats_dismissed = true
                init_view_state(wgt).dirty = true
            elseif rect_hit(touch_state, wgt.battprofile_rect, 6)
                and not ultidash_functions.is_armed(wgt)
                and wgt.rf and wgt.rf.msp_allowed then
                -- battery-profile picker: switches the active profile via RFTool MSP
                -- (a config WRITE → DISARMED ONLY; the FC also blocks writes while armed)
                wgt.elrs_tap_block = now + 100
                -- read the current profile/config fresh on open (disarmed, so MSP is
                -- allowed) — otherwise the picker shows a value cached at connect time
                rf_service.refresh_data(wgt)
                wgt.menu_view = "battprofile"
                init_view_state(wgt).dirty = true
            elseif wgt.options.TapDetails == 1 and rect_hit(touch_state, wgt.elrs_bar_rect, 10) then
                wgt.elrs_tap_block = now + 100   -- long: any tap closes, see above
                wgt.detail_view = "elrs"
                init_view_state(wgt).dirty = true
            elseif wgt.options.TapDetails == 1 and rect_hit(touch_state, wgt.estatus_rect, 6) then
                wgt.elrs_tap_block = now + 100
                wgt.detail_view = "estatus"
                wgt.estatus_scroll = 0
                init_view_state(wgt).dirty = true
            elseif wgt.options.TapDetails == 1 and rect_hit(touch_state, wgt.battery_rect, 6) then
                wgt.elrs_tap_block = now + 100
                wgt.detail_view = "battery"
                init_view_state(wgt).dirty = true
            elseif wgt.options.TapDetails == 1 and rect_hit(touch_state, wgt.values_rect, 6) then
                wgt.elrs_tap_block = now + 100
                wgt.detail_view = "telem"
                init_view_state(wgt).dirty = true
            end
        end
    end
    if not is_publisher(wgt) then
        -- passive view: sensor-only ELRS data (no MSP/audio/stats side effects);
        -- the Status view renders reactively straight from Shared. Same 5 Hz
        -- throttle as the publisher — no need to poll sensors every cycle.
        local tnow = getTime() or 0
        if (tnow - (wgt.telem_gate or 0)) >= 20 then
            wgt.telem_gate = tnow
            ultidash_functions.update_elrs(wgt)
        end
        -- follow the Dashboard: rebuild when the publisher appears/disappears or
        -- changes its palette/background (notice page <-> live view, look change)
        if wgt.passive_style_sig ~= passive_style_sig() then
            return update(wgt, wgt.options)
        end
        return
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
            local m = menu_load()
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
        if wgt.menu_view ~= "tb_rf2cfg" then
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
        if wgt.menu_view ~= "tb_logview" and wgt.menu_view ~= "tb_rf2cfg" then
            ultidash_functions.refresh(wgt)
            update_user_sensors(wgt)
            ultidash_functions.publish_shared(wgt)
            ultidash_functions.refresh_volume_override(wgt)   -- adaptive master volume via GVAR (off unless configured)
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
            local tb = (wgt.menu_view == "tb_adjmap" or wgt.menu_view == "tb_adjed"
                or wgt.menu_view == "tb_logview" or wgt.menu_view == "tb_rf2cfg")
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
        if wgt.menu_view ~= nil and wgt.menu_view ~= "tb_rf2cfg" then
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

return { create = create, update = update, background = background, refresh = refresh }
