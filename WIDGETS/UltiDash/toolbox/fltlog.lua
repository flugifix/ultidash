-- =====================================================================
--  UltiDash Toolbox: Flight Log viewer
--  Shows the flight log (fltlog/flights.csv) and the battery registry
--  (fltlog/batteries.cfg): recent flights, per-model totals and battery
--  usage. Three tabs: Flights / Models / Batteries -- ALL rows tappable
--  (Flights -> per-flight detail, Batteries -> battery detail/editor via
--  toolbox/fltbatt.lua, Models -> the Flights tab filtered to that model).
--  Drawn in the Toolbox detail-page style (own header, tab chips, palette
--  via wgt.tb_pal) -- NOT lvgl.page, and no COLOR_THEME_* colours.
--
--  DISARMED-ONLY, LAZY-loaded on open and released on close (same policy
--  as the Log Viewer -- boot-resident modules measurably drag the UI).
--  The CSV parse is CHUNKED over refresh() ticks with fixed work caps
--  against the ~20k instruction budget (getUsage() is a last-cycle
--  snapshot in LVGL widgets -- useless as a live gate, see logview.lua).
--  Per-instance state on wgt.fl; M.close(wgt) frees it.
-- =====================================================================

local M = {}

local CHUNK       = 2048   -- io.read chunk size (several reads per tick if the lines need them)
local LINES_TICK  = 90     -- CSV lines parsed per tick (one string.match each) -- the BINDING
                           -- work cap: the tick pulls as many CHUNKs as those lines take
local MAX_FLIGHTS = 300    -- flight ring: on overflow the OLDEST entries drop,
                           -- totals/aggregates still count EVERY line

-- shared palettes live in toolbox/common.lua, handed in by the host loader
-- via M.init (the adj tools' pattern); nil-guarded for a partial deploy
local C = nil
function M.init(common) C = common end

local function palette(wgt)
    local opt = wgt.options or {}
    if C ~= nil and (opt.TbSun == 1 or opt.TbSun == true) then return C.sun_palette() end
    if wgt.tb_pal then return wgt.tb_pal end
    if C ~= nil then return C.fallback_palette() end
    -- last resort (common.lua missing): the dark fallback literals
    return { bg = lcd.RGB(0, 0, 0), accent = lcd.RGB(0, 229, 255),
             hint = lcd.RGB(255, 122, 26), line = lcd.RGB(56, 60, 64),
             text = lcd.RGB(240, 240, 240), textDim = lcd.RGB(150, 156, 162),
             bannerBg = lcd.RGB(255, 68, 56), bannerFg = lcd.RGB(0, 0, 0) }
end

-- ---------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------
local function ensure(wgt)
    local fl = wgt.fl
    if fl == nil then
        fl = {
            mode = "flights",       -- "flights" | "models" | "batts"
            stage = "open",         -- "open" -> "parse" -> nil (done)
            fh = nil, buf = "",
            ring = {}, n = 0,       -- flight ring + total line count
            tot_s = 0,              -- total seconds over ALL lines
            models = {}, morder = {},
            by_id = {},             -- battery_id -> flight count (all lines)
            reg = {},               -- battery registry (fltdata)
            names = {},             -- battery_id -> display name
            page = 0,
            hit = {},               -- tap targets of the CURRENT build
            filter_model = nil,     -- session-local Flights filter (spec 4.4)
        }
        wgt.fl = fl
    end
    return fl
end

function M.close(wgt)
    local fl = wgt.fl
    if fl ~= nil and fl.fh ~= nil then
        pcall(io.close, fl.fh)
        fl.fh = nil
    end
    wgt.fl = nil
    wgt.fb = nil        -- the battery editor's state dies with the tool
end

-- forced-exit cleanup (fullscreen exit via close_tool_page): release the file
M.cleanup = M.close

-- forward declaration: defined with the chunked loader below, needed by
-- batt_ctx's on_change (a registry write reloads the list in place)
local load_registry

-- ---------------------------------------------------------------------
-- battery detail/editor (toolbox/fltbatt.lua): lazily loaded on the first
-- Batteries-row tap / "+ New"; while open it owns build/refresh/RTN
-- ---------------------------------------------------------------------
local function load_batt_mod(wgt, fl)
    if fl.B == nil then
        local ok, m = pcall(function() return loadScript("/WIDGETS/UltiDash/toolbox/fltbatt.lua")() end)
        if ok and m ~= nil then
            if m.init ~= nil then pcall(m.init, C) end
            fl.B = m
        end
    end
    return fl.B
end

local function batt_ctx(wgt, fl, entry)
    -- known model names: as typed in flights.csv, plus the connected craft
    local known = {}
    for i = 1, #fl.morder do known[#known + 1] = fl.morder[i] end
    local craft = wgt.values ~= nil and wgt.values.craft_name or nil
    if craft ~= nil and craft ~= "" then known[#known + 1] = craft end
    return {
        D = fl.D or wgt.flt_data_mod,
        reg = fl.reg,
        entry = entry,
        known_models = known,
        flights_for = function(id) return fl.by_id[id] or 0 end,
        return_to = "fltlog",
        on_change = function(w, what, id)
            -- a write landed: reload the registry in place (one read, in the
            -- tool's exclusive cycle); returns the fresh entry for `id`
            local flx = w.fl
            if flx == nil then return nil end
            flx.reg, flx.names = {}, {}
            load_registry(w, flx)
            w.fl_dirty = true
            if id ~= nil then
                for i = 1, #flx.reg do
                    if flx.reg[i].id == id then return flx.reg[i] end
                end
            end
            return nil
        end,
        on_close = function(w)
            local flx = w.fl
            if flx ~= nil then flx.batt_open = nil end
            w.fl_dirty = true
        end,
    }
end

local function open_batt(wgt, fl, entry, mode)
    local B = load_batt_mod(wgt, fl)
    if B == nil then return end
    if pcall(B.open, wgt, mode, batt_ctx(wgt, fl, entry)) then
        fl.batt_open = true
        wgt.fl_dirty = true
    end
end

-- RTN: battery pages first (the editor consumes internally; at its top it
-- closes back to the Batteries tab), then a per-flight detail back to the
-- list, then an active model filter is CLEARED before the tool is left
-- (spec 4.4); only then does RTN leave the tool (host closes on false).
function M.on_exit_key(wgt)
    local fl = wgt.fl
    if fl == nil then return false end
    if fl.batt_open and fl.B ~= nil then
        if not fl.B.on_exit_key(wgt) then
            if fl.B.close ~= nil then fl.B.close(wgt) end
            fl.batt_open = nil
        end
        wgt.fl_dirty = true
        return true
    end
    if fl.detail ~= nil then
        fl.detail = nil
        wgt.fl_dirty = true
        return true
    end
    if fl.filter_model ~= nil then
        fl.filter_model = nil
        wgt.fl_dirty = true
        return true
    end
    return false
end

-- ---------------------------------------------------------------------
-- chunked CSV load (runs in M.refresh's own budget)
-- ---------------------------------------------------------------------
load_registry = function(wgt, fl)
    -- prefer the HOST's resident fltdata instance (wgt.flt_data_mod, set by the
    -- dispatch) — loading a second module copy per viewer open wasted heap and
    -- could diverge; own load stays as the fallback for a partial deploy
    local D = wgt.flt_data_mod
    if D == nil then
        local ok, m = pcall(function() return loadScript("/WIDGETS/UltiDash/toolbox/fltdata.lua")() end)
        if ok then D = m end
    end
    if D == nil then return end
    fl.D = D                      -- kept for the per-flight detail's stats parser
    local okr, reg = pcall(D.load_registry)
    if okr and type(reg) == "table" then
        fl.reg = reg
        for i = 1, #reg do
            fl.names[reg[i].id] = reg[i].name or reg[i].id
        end
    end
    fl.csv_path = D.csv_path()
end

local function add_flight(fl, d, t, m, b, s, x)
    fl.n = fl.n + 1
    fl.ring[((fl.n - 1) % MAX_FLIGHTS) + 1] = { d = d, t = t, m = m, b = b, s = s,
        x = (x ~= nil and x ~= "") and x or nil }   -- x = raw stats columns (nil = none)
    fl.tot_s = fl.tot_s + s
    if m ~= "" then
        local e = fl.models[m]
        if e == nil then
            e = { n = 0, s = 0 }
            fl.models[m] = e
            fl.morder[#fl.morder + 1] = m
        end
        e.n = e.n + 1
        e.s = e.s + s
    end
    if b ~= "" then fl.by_id[b] = (fl.by_id[b] or 0) + 1 end
end

-- one tick of load work; returns true when everything is loaded
local function load_tick(wgt, fl)
    if fl.stage == "open" then
        load_registry(wgt, fl)
        local ok, fh = pcall(io.open, fl.csv_path or "/WIDGETS/UltiDash/fltlog/flights.csv", "r")
        if not ok or fh == nil then
            fl.stage = nil
            return true
        end
        fl.fh = fh
        fl.stage = "parse"
        return false
    end
    if fl.stage == "parse" then
        -- The LINE cap is the binding one. This used to read ONE 2 KiB chunk per
        -- tick -- with the stats columns a row is ~180 bytes, so the effective
        -- rate was ~12 lines per cycle whatever LINES_TICK said, and a season's
        -- flights.csv held the page on "Reading flight log ..." for seconds at
        -- every open (radio report, 2026-08-30). Now the tick pulls chunks until
        -- it has parsed its LINES_TICK lines or the file ends; the buffer never
        -- holds more than one chunk plus a partial line.
        local buf, pos = fl.buf, 1
        local eof = false
        local lines = 0
        while lines < LINES_TICK do
            local e = string.find(buf, "\n", pos, true)
            local line
            if e ~= nil then
                line = string.sub(buf, pos, e - 1)
                pos = e + 1
            elseif not eof then
                local ok, data = pcall(io.read, fl.fh, CHUNK)
                if not ok or data == nil or data == "" then
                    eof = true                    -- EOF (or read error: stop, keep what we have)
                else
                    buf = string.sub(buf, pos) .. data
                    pos = 1
                end
            elseif pos <= #buf then
                line = string.sub(buf, pos)       -- last line without newline
                pos = #buf + 1
            else
                break
            end
            if line ~= nil then
                local d, t, m, b, s, x = string.match(line, "^([^,]*),([^,]*),([^,]*),([^,]*),(%d+),?(.*)$")
                if d ~= nil then add_flight(fl, d, t, m, b, tonumber(s) or 0, x) end
                lines = lines + 1
            end
        end
        fl.buf = string.sub(buf, pos)
        if eof and fl.buf == "" then
            pcall(io.close, fl.fh)
            fl.fh = nil
            fl.stage = nil
            return true
        end
        return false
    end
    return true
end

-- ---------------------------------------------------------------------
-- formatting
-- ---------------------------------------------------------------------
local function fmt_mmss(s)
    s = math.floor(s or 0)
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function fmt_hhmm(s)
    s = math.floor(s or 0)
    return string.format("%d:%02d h", math.floor(s / 3600), math.floor(s / 60) % 60)
end

-- totals: below an hour "h:mm" would read "0:00 h" for every short session
local function fmt_total(s)
    if (s or 0) < 3600 then return fmt_mmss(s) .. " min" end
    return fmt_hhmm(s)
end

-- Clip free text to a column width. An LVGL label WRAPS what does not fit, and
-- the second line then bleeds into the next row (a long pack name printed
-- "Tattu 6S" / "62" across two rows). Truncating with an ellipsis keeps rows on
-- one line. Only a few rows per page, so the measure loop is cheap.
local function fit(txt, max_w, font)
    txt = tostring(txt or "")
    if txt == "" then return txt end
    font = font or SMLSIZE
    local tw = lcd.sizeText(txt, font)
    if tw <= max_w then return txt end
    local n = #txt
    while n > 1 do
        n = n - 1
        local cut = string.sub(txt, 1, n) .. "."
        if lcd.sizeText(cut, font) <= max_w then return cut end
    end
    return string.sub(txt, 1, 1)
end

-- ---------------------------------------------------------------------
-- UI (detail-page style: own header + tab chips, plain rects and own hit
-- testing -- a focusable type="button" would capture PAGE/RTN, see
-- logview.lua; rebuilt via wgt.fl_dirty)
-- ---------------------------------------------------------------------
-- `multi` = the hit also accepts EdgeTX double/triple-TAP events: quick
-- successive taps land inside the radio's double-tap window and arrive with
-- tapCount >= 2, and for the pager and the tab chips DROPPING those made
-- paging feel dead -- every second tap vanished (radio report, 2026-08-30).
-- The time cooldown stays as the bounce guard (one physical tap can still
-- fan out into several TAP events; those follow within a few cs).
local function add_hit(fl, x, y, w, h, fn, cool, multi)
    fl.hit[#fl.hit + 1] = { x = x, y = y, w = w, h = h, fn = fn, cool = cool, multi = multi }
end

-- plain-rect button (footer pager): repeated activation is the point, so
-- multi-tap counts and the cooldown is only the bounce guard
local function button(fl, layout, P, x, y, w, h, txt, fn)
    layout[#layout + 1] = { type = "rectangle", x = x, y = y, w = w, h = h,
        thickness = 1, rounded = 4, color = P.line }
    local _, th = lcd.sizeText(txt, SMLSIZE)
    layout[#layout + 1] = { type = "label", x = x, y = y + (h - th) / 2,
        w = w, h = th, font = SMLSIZE, align = CENTER, color = P.text, text = txt }
    add_hit(fl, x, y, w, h, fn, 15, true)
end

-- a filled/outlined chip; `on` decides the fill (logview's chip pattern).
-- Multi-tap accepted here too: set_mode is idempotent and "+ New" re-opens
-- the same fresh form, so a fast second tap can do no harm
local function chip(fl, layout, P, x, y, w, h, txt, on, fn)
    if on then
        layout[#layout + 1] = { type = "rectangle", filled = true, rounded = 4,
            x = x, y = y, w = w, h = h, color = P.accent }
    else
        layout[#layout + 1] = { type = "rectangle", rounded = 4, thickness = 1,
            x = x, y = y, w = w, h = h, color = P.line }
    end
    local _, th = lcd.sizeText(txt, SMLSIZE)
    layout[#layout + 1] = { type = "label", x = x, y = y + (h - th) / 2, w = w, h = th,
        font = SMLSIZE, align = CENTER,
        color = on and (P.bg or lcd.RGB(0, 0, 0)) or P.text, text = txt }
    add_hit(fl, x, y, w, h, fn, 15, true)
end

-- Two INDEPENDENT size flags. `big` (height) drives row heights / fonts, like the
-- rest of the widget. `wide` (WIDTH) drives the column layouts -- the TX15 is
-- 480x320, so its height passes the >=300 "big" test while its width is only 60 %
-- of the TX16S's 800: keying the columns off the height overlapped them (the
-- battery tab printed "1 fl26-07-10", the flight tab wrapped the pack name).
local function page_geometry(zone)
    local big = zone.h >= 300
    local wide = zone.w >= 700
    local titleFont = big and MIDSIZE or SMLSIZE
    local _, tth = lcd.sizeText("Ag", titleFont)
    local _, fh = lcd.sizeText("Ag", SMLSIZE)
    local headH = tth + 8
    local row_h = fh + (big and 8 or 4)
    local top = big and 10 or 5              -- gap below the header
    local foot_h = big and 38 or 28
    local avail = zone.h - headH - top - foot_h - 6
    local rows = math.max(3, math.floor(avail / row_h))
    return big, wide, fh, tth, titleFont, headH, row_h, top, foot_h, rows
end

local function set_mode(wgt, fl, mode)
    if fl.mode ~= mode then
        fl.filter_model = nil       -- leaving the Flights tab clears the filter
        fl.mode = mode
        fl.page = 0
        wgt.fl_dirty = true
    end
end

-- flights matching the model filter: absolute ring indices, newest first
-- (bounded by the ring like the unfiltered list; totals over these entries)
local function filtered_idx(fl)
    local out, sum = {}, 0
    local lo = math.max(1, fl.n - MAX_FLIGHTS + 1)
    for j = fl.n, lo, -1 do
        local e = fl.ring[((j - 1) % MAX_FLIGHTS) + 1]
        if e.m == fl.filter_model then
            out[#out + 1] = j
            sum = sum + e.s
        end
    end
    return out, sum
end

local function item_count(fl)
    if fl.mode == "models" then return #fl.morder end
    if fl.mode == "batts" then return #fl.reg end
    if fl.filter_model ~= nil then return #(fl.fidx or {}) end
    return math.min(fl.n, MAX_FLIGHTS)
end

-- per-flight detail: a min/max table mirroring the dashboard's flight-statistics view.
-- `dec` = decimals; unused headspeed profiles (both nil) are skipped to save space.
local DEG = string.char(0xC2, 0xB0)      -- degree sign (UTF-8), no literal non-ASCII
local STAT_ROWS = {
    { label = "Cell (V)",         min = "vcel_min", max = "vcel_max", dec = 2 },
    { label = "Head P1 (rpm)",    min = "hs1_min",  max = "hs1_max",  dec = 0, hs = true },
    { label = "Head P2 (rpm)",    min = "hs2_min",  max = "hs2_max",  dec = 0, hs = true },
    { label = "Head P3 (rpm)",    min = "hs3_min",  max = "hs3_max",  dec = 0, hs = true },
    { label = "Current (A)",      min = "curr_min", max = "curr_max", dec = 1 },
    { label = "ESC (" .. DEG .. "C)", min = "tesc_min", max = "tesc_max", dec = 0 },
    { label = "BEC (V)",          min = "vbec_min", max = "vbec_max", dec = 2 },
}

local function fmt_num(v, dec)
    if v == nil then return "-" end
    if dec == 0 then return string.format("%d", math.floor(v + 0.5)) end
    return string.format("%." .. dec .. "f", v)
end

-- per-flight detail page (opened by tapping a Flights row): summary + a min/max
-- table, in the detail-page style; back = RTN or a tap on the header title row
local function build_detail(wgt, fl, zone, P)
    local e = fl.detail
    local w, H = zone.w, zone.h
    local big = H >= 300
    local titleFont = big and MIDSIZE or SMLSIZE
    local _, tth = lcd.sizeText("Ag", titleFont)
    local _, fh = lcd.sizeText("Ag", SMLSIZE)
    local headH = tth + 8
    local hhmm = string.sub(e.t or "", 1, 5)
    local elems = {}
    if P.bg then
        elems[#elems + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = w, h = H, color = P.bg }
    end
    elems[#elems + 1] = { type = "label", x = 6, y = (headH - tth) / 2, w = w - 150, h = tth,
        font = titleFont, color = P.accent, text = "Flight" }
    elems[#elems + 1] = { type = "label", x = 6, y = (headH - fh) / 2, w = w - 12, h = fh,
        font = SMLSIZE, align = RIGHT, color = P.hint, text = (e.d or "") .. " " .. hhmm }
    elems[#elems + 1] = { type = "rectangle", filled = true, x = 0, y = headH - 1, w = w, h = 1, color = P.line }
    add_hit(fl, 0, 0, w, headH, function(w2)
        local flx = w2.fl
        if flx ~= nil then flx.detail = nil end
        w2.fl_dirty = true
    end, 30)
    local row_h = fh + (big and 6 or 3)
    local lblw = math.floor(w * 0.42)
    local vw = w - lblw - 22
    local y = headH + (big and 10 or 4)
    local stats = fl.D and fl.D.parse_stats(e.x) or nil
    -- summary block: model / battery / duration+mAh (+ sag count if any)
    local function kv(label, val)
        elems[#elems + 1] = { type = "label", x = 8, y = y, w = lblw, h = fh + 2,
            font = SMLSIZE, color = P.textDim, text = label }
        elems[#elems + 1] = { type = "label", x = 8 + lblw + 6, y = y, w = vw, h = fh + 2,
            font = SMLSIZE, color = P.text, text = val }
        y = y + row_h
    end
    kv("Model", fit(e.m or "-", vw))
    kv("Battery", fit(fl.names[e.b] or e.b or "-", vw))
    local mahtxt = (stats and stats.mah) and string.format("%d mAh", stats.mah) or "-"
    kv("Duration / mAh", fmt_mmss(e.s) .. "   " .. mahtxt)
    if stats and stats.sags and stats.sags > 0 then
        local dp = stats.sag_min and string.format(" (min %.2f V)", stats.sag_min) or ""
        kv("Voltage sags", tostring(stats.sags) .. dp)
    end
    if stats == nil then
        elems[#elems + 1] = { type = "label", x = 8, y = y + 6, w = w - 16, h = fh + 2,
            font = SMLSIZE, align = CENTER, color = P.textDim,
            text = "No stats recorded for this flight" }
        lvgl.build(elems)
        return
    end
    -- min/max table
    elems[#elems + 1] = { type = "rectangle", x = 8, y = y + 2, w = w - 16, h = 1,
        filled = true, color = P.line }
    y = y + 8
    local colw = math.floor((w - lblw - 16) / 2)
    local xmin = 8 + lblw
    local xmax = xmin + colw
    elems[#elems + 1] = { type = "label", x = xmin, y = y, w = colw, h = fh + 2,
        font = SMLSIZE, align = RIGHT, color = P.textDim, text = "Min" }
    elems[#elems + 1] = { type = "label", x = xmax, y = y, w = colw, h = fh + 2,
        font = SMLSIZE, align = RIGHT, color = P.textDim, text = "Max" }
    y = y + row_h
    for i = 1, #STAT_ROWS do
        local r = STAT_ROWS[i]
        local mn, mx = stats[r.min], stats[r.max]
        if not (r.hs and mn == nil and mx == nil) then   -- skip unused headspeed profiles
            elems[#elems + 1] = { type = "label", x = 8, y = y, w = lblw - 4, h = fh + 2,
                font = SMLSIZE, color = P.textDim, text = r.label }
            elems[#elems + 1] = { type = "label", x = xmin, y = y, w = colw, h = fh + 2,
                font = SMLSIZE, align = RIGHT, color = P.text, text = fmt_num(mn, r.dec) }
            elems[#elems + 1] = { type = "label", x = xmax, y = y, w = colw, h = fh + 2,
                font = SMLSIZE, align = RIGHT, color = P.text, text = fmt_num(mx, r.dec) }
            y = y + row_h
        end
    end
    lvgl.build(elems)
end

function M.build(wgt, zone)
    local fl = ensure(wgt)
    fl.hit = {}
    -- the battery detail/editor owns the screen while open
    if fl.batt_open and fl.B ~= nil then
        fl.B.build(wgt, zone)
        return
    end
    local P = palette(wgt)
    -- a tapped Flights row shows its per-flight detail (stats) instead of the list
    if fl.detail ~= nil and fl.stage == nil then
        build_detail(wgt, fl, zone, P)
        return
    end
    local big, wide, fh, tth, titleFont, headH, row_h, top, foot_h, rows = page_geometry(zone)
    local w = zone.w
    local elems = {}
    if P.bg then
        elems[#elems + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = w, h = zone.h, color = P.bg }
    end

    -- header: tab chips right-aligned (B2), then "+ New" / the filter chip,
    -- then the title in whatever is left -- on 480-wide the title yields
    -- first (clipped, then dropped; the templates picker-bar rule)
    local chipY, chipH = 3, headH - 6
    local gap = 6
    local tabs = { { "Flights", "flights" }, { "Models", "models" }, { "Batteries", "batts" } }
    local x = w - 6
    for i = 3, 1, -1 do
        local mode = tabs[i][2]
        local cw = lcd.sizeText(tabs[i][1], SMLSIZE) + 22
        x = x - cw
        chip(fl, elems, P, x, chipY, cw, chipH, tabs[i][1], fl.mode == mode,
            function(w2) set_mode(w2, w2.fl, mode) end)
        x = x - gap
    end
    if fl.mode == "batts" and fl.stage == nil then
        -- "+ New" opens the create form (B5); the editor lives in fltbatt.lua
        local cw = lcd.sizeText("+ New", SMLSIZE) + 22
        x = x - cw
        chip(fl, elems, P, x, chipY, cw, chipH, "+ New", false,
            function(w2) open_batt(w2, w2.fl, nil, "create") end)
        x = x - gap
    elseif fl.mode == "flights" and fl.filter_model ~= nil then
        -- the model filter chip (spec 4.4): filled, P.hint border, tap clears
        local ftxt = "Model: " .. fit(fl.filter_model, 140) .. "  x"
        local cw = lcd.sizeText(ftxt, SMLSIZE) + 22
        x = x - cw
        elems[#elems + 1] = { type = "rectangle", filled = true, rounded = 4,
            x = x, y = chipY, w = cw, h = chipH, color = P.accent }
        elems[#elems + 1] = { type = "rectangle", rounded = 4, thickness = 1,
            x = x, y = chipY, w = cw, h = chipH, color = P.hint }
        elems[#elems + 1] = { type = "label", x = x, y = chipY + (chipH - fh) / 2,
            w = cw, h = fh, font = SMLSIZE, align = CENTER,
            color = P.bg or lcd.RGB(0, 0, 0), text = ftxt }
        add_hit(fl, x, chipY, cw, chipH, function(w2)
            local flx = w2.fl
            if flx ~= nil then flx.filter_model = nil; flx.page = 0 end
            w2.fl_dirty = true
        end, 30)
        x = x - gap
    end
    local titleW = x - 10
    if titleW >= 40 then
        elems[#elems + 1] = { type = "label", x = 6, y = (headH - tth) / 2,
            w = titleW, h = tth, font = titleFont, color = P.accent,
            text = fit("Flight Log", titleW, titleFont) }
    end
    elems[#elems + 1] = { type = "rectangle", filled = true, x = 0, y = headH - 1,
        w = w, h = 1, color = P.line }

    local y = headH + top
    if fl.stage ~= nil then
        elems[#elems + 1] = { type = "label", x = 8, y = y + 12, w = w - 16, h = fh + 4,
            font = SMLSIZE, align = CENTER, color = P.textDim,
            text = "Reading flight log ..." }
        lvgl.build(elems)
        return
    end

    -- the filtered index list is rebuilt per build (ring-bounded, spec 4.4)
    local fsum = 0
    if fl.mode == "flights" and fl.filter_model ~= nil then
        fl.fidx, fsum = filtered_idx(fl)
    else
        fl.fidx = nil
    end

    local count = item_count(fl)
    -- every tab spends one row on a real header line (bare numbers need the column
    -- names — per-cell "cyc"/"flt" suffixes were not self-explanatory)
    local rows_eff = math.max(2, rows - 1)
    local pages = math.max(1, math.ceil(count / rows_eff))
    if fl.page > pages - 1 then fl.page = pages - 1 end
    if fl.page < 0 then fl.page = 0 end

    -- column layout per tab (fractions of the width)
    local function put(x2, ww, txt, color, align)
        elems[#elems + 1] = { type = "label", x = x2, y = y, w = ww, h = fh + 2,
            font = SMLSIZE, text = txt, color = color or P.text,
            align = align or LEFT }
    end

    -- Column geometry is DERIVED from the width (never hardcoded for one radio):
    -- the fixed-width columns keep their measured size, the free text columns
    -- (model / pack name) share whatever is left. Works at 480 and at 800.
    -- Tappable rows end in a `>` chevron (B4) -- the columns stop before it.
    local GAP = 8
    local chev = lcd.sizeText(">", SMLSIZE) + 10
    -- the chevron: the VISIBLE affordance that a row is tappable (the touch
    -- target is the whole row); vertically centered in the row
    local function chevron(rowy)
        elems[#elems + 1] = { type = "label", x = w - chev, y = rowy + math.floor((row_h - fh) / 2),
            w = chev - 4, h = fh + 2, font = SMLSIZE, align = RIGHT, color = P.textDim, text = ">" }
    end
    if count == 0 then
        local hint = (fl.mode == "batts")
            and "No batteries - + New adds the first pack"
            or (fl.filter_model ~= nil) and "No flights for this model"
            or "No flights logged yet"
        put(8, w - 16, hint, P.textDim, CENTER)
    elseif fl.mode == "flights" then
        -- date+time | model | pack | duration(right) | >
        local w_dur = wide and 70 or 52
        local x_dur = w - w_dur - chev
        local w_when = wide and 178 or 112
        local x_model = 6 + w_when + GAP
        local free = x_dur - GAP - x_model         -- shared by model + pack
        local w_model = math.floor(free * 0.5)
        local x_pack = x_model + w_model + GAP
        local w_pack = free - w_model - GAP
        put(6, w_when, "Date", P.textDim)
        put(x_model, w_model, "Model", P.textDim)
        put(x_pack, w_pack, "Battery", P.textDim)
        put(x_dur, w_dur, "Time", P.textDim, RIGHT)
        y = y + row_h
        -- newest first: absolute index j counts down from fl.n (or walks the
        -- filtered index list, which is already newest-first)
        local first = fl.n - fl.page * rows_eff
        local vpad = math.max(0, math.floor((row_h - fh) / 2))
        for i = 0, rows_eff - 1 do
            local j
            if fl.fidx ~= nil then
                j = fl.fidx[fl.page * rows_eff + i + 1]
                if j == nil then break end
            else
                j = first - i
                if j < 1 or j <= fl.n - MAX_FLIGHTS then break end
            end
            local e = fl.ring[((j - 1) % MAX_FLIGHTS) + 1]
            local hhmm = string.sub(e.t or "", 1, 5)
            -- narrow drops the year: "07-10 10:26" instead of "2026-07-10 10:26"
            local when = (wide and (e.d or "") or string.sub(e.d or "", 6)) .. " " .. hhmm
            local rowy = y
            -- full-row tap target -> per-flight detail page
            add_hit(fl, 4, rowy, w - 8, row_h, function(w2)
                local flx = w2.fl
                if flx ~= nil then flx.detail = e end
                w2.fl_dirty = true
            end, 30)
            chevron(rowy)
            y = rowy + vpad                                       -- labels vertically centered
            put(6, w_when, when)
            put(x_model, w_model, fit(e.m, w_model))
            put(x_pack, w_pack, fit(fl.names[e.b] or e.b, w_pack), P.textDim)
            put(x_dur, w_dur, fmt_mmss(e.s), nil, RIGHT)
            y = rowy + row_h
        end
    elseif fl.mode == "models" then
        -- model | flights | total time(right) | >  (tap filters the Flights tab, B3)
        local w_tot = wide and 110 or 84
        local x_tot = w - w_tot - chev
        local w_cnt = wide and 110 or 76
        local x_cnt = x_tot - GAP - w_cnt
        put(6, x_cnt - GAP - 6, "Model", P.textDim)
        put(x_cnt, w_cnt, "Flights", P.textDim)
        put(x_tot, w_tot, "Total time", P.textDim, RIGHT)
        y = y + row_h
        local vpad = math.max(0, math.floor((row_h - fh) / 2))
        for i = 1 + fl.page * rows_eff, math.min(#fl.morder, (fl.page + 1) * rows_eff) do
            local m = fl.morder[i]
            local e = fl.models[m]
            local rowy = y
            add_hit(fl, 4, rowy, w - 8, row_h, function(w2)
                local flx = w2.fl
                if flx ~= nil then
                    flx.filter_model = m
                    flx.mode = "flights"
                    flx.page = 0
                end
                w2.fl_dirty = true
            end, 30)
            chevron(rowy)
            y = rowy + vpad
            put(6, x_cnt - GAP - 6, fit(m, x_cnt - GAP - 6))
            put(x_cnt, w_cnt, tostring(e.n))
            put(x_tot, w_tot, fmt_total(e.s), nil, RIGHT)
            y = rowy + row_h
        end
    else -- batteries: name | capacity | cycles | flights | last use(right) | >
        local w_last = wide and 112 or 86
        local x_last = w - w_last - chev
        local w_cap = wide and 96 or 72
        local w_cyc = wide and 84 or 56
        local w_flt = wide and 84 or 52
        local x_flt = x_last - GAP - w_flt
        local x_cyc = x_flt - GAP - w_cyc
        local x_cap = x_cyc - GAP - w_cap
        -- header line with the full column names; the cells below carry bare numbers
        put(6, x_cap - GAP - 6, "Battery", P.textDim)
        put(x_cap, w_cap, "Capacity", P.textDim)
        put(x_cyc, w_cyc, "Cycles", P.textDim)
        put(x_flt, w_flt, "Flights", P.textDim)
        put(x_last, w_last, "Last use", P.textDim, RIGHT)
        y = y + row_h
        local vpad = math.max(0, math.floor((row_h - fh) / 2))
        for i = 1 + fl.page * rows_eff, math.min(#fl.reg, (fl.page + 1) * rows_eff) do
            local b = fl.reg[i]
            local flights = fl.by_id[b.id] or 0
            local rowy = y
            -- tap -> battery detail page (Edit / Delete live there, B5)
            add_hit(fl, 4, rowy, w - 8, row_h, function(w2)
                local flx = w2.fl
                if flx ~= nil then open_batt(w2, flx, b, "detail") end
            end, 30)
            chevron(rowy)
            y = rowy + vpad
            put(6, x_cap - GAP - 6, fit(b.name or b.id, x_cap - GAP - 6))
            put(x_cap, w_cap, b.cap and (b.cap .. " mAh") or "-")
            put(x_cyc, w_cyc, tostring(b.cycles or 0))
            put(x_flt, w_flt, tostring(flights))
            put(x_last, w_last, (b.last ~= nil and b.last ~= "") and b.last or "-", nil, RIGHT)
            y = rowy + row_h
        end
    end

    -- footer: totals + paging (the pager stays as it was, B2)
    local fy = zone.h - foot_h
    local total_txt
    if fl.mode == "flights" then
        if fl.filter_model ~= nil then
            -- filtered totals over the ring's matching entries; "N of M" makes
            -- the filter legible in the numbers too (spec 4.4)
            total_txt = count .. " of " .. fl.n .. " flights - " .. fmt_total(fsum)
        else
            total_txt = fl.n .. ((fl.n == 1) and " flight - " or " flights - ") .. fmt_total(fl.tot_s)
            if fl.n > MAX_FLIGHTS then
                total_txt = total_txt .. " (last " .. MAX_FLIGHTS .. " listed)"
            end
        end
    elseif fl.mode == "models" then
        total_txt = count .. ((count == 1) and " model" or " models")
    else
        total_txt = count .. ((count == 1) and " battery" or " batteries")
    end
    -- footer text vertically centered on the pager buttons (h = foot_h - 2)
    local fty = fy + math.floor((foot_h - 2 - fh) / 2)
    elems[#elems + 1] = { type = "label", x = 8, y = fty, w = math.floor(w * 0.5), h = fh + 2,
        font = SMLSIZE, color = P.textDim, text = total_txt }
    if pages > 1 then
        local bw = big and 64 or 48
        elems[#elems + 1] = { type = "label", x = w - 2 * bw - 90, y = fty, w = 76, h = fh + 2,
            font = SMLSIZE, align = RIGHT, color = P.textDim,
            text = (fl.page + 1) .. "/" .. pages }
        button(fl, elems, P, w - 2 * bw - 10, fy, bw, foot_h - 2, "<",
            function(w2)
                local flx = w2.fl
                if flx ~= nil and flx.page > 0 then flx.page = flx.page - 1; w2.fl_dirty = true end
            end)
        button(fl, elems, P, w - bw - 4, fy, bw, foot_h - 2, ">",
            function(w2)
                local flx = w2.fl
                if flx ~= nil and flx.page < pages - 1 then flx.page = flx.page + 1; w2.fl_dirty = true end
            end)
    end

    lvgl.build(elems)
end

local function rect_hit(ts, r)
    return ts ~= nil and ts.x ~= nil
        and ts.x >= r.x and ts.x < r.x + r.w
        and ts.y >= r.y and ts.y < r.y + r.h
end

-- tap dispatch over the current build's targets (logview conventions); a hit
-- with `multi` also accepts tapCount >= 2 (see add_hit)
local function dispatch_taps(wgt, fl, event, touch_state)
    local now = getTime() or 0
    if EVT_TOUCH_TAP ~= nil and event == EVT_TOUCH_TAP and touch_state ~= nil
        and now >= (fl.tap_block or 0) then
        local single = (touch_state.tapCount == nil or touch_state.tapCount <= 1)
        local hits = fl.hit
        for i = 1, #hits do
            local r = hits[i]
            if (single or r.multi) and rect_hit(touch_state, r) then
                fl.tap_block = now + (r.cool or 30)
                r.fn(wgt, touch_state)
                break
            end
        end
    end
end

function M.refresh(wgt, event, touch_state)
    local fl = ensure(wgt)

    -- disarmed-only: auto-close on arm; the host clears menu_view (fl_close_req).
    -- M.close also drops the battery editor's state -- an open form is discarded,
    -- nothing is written (spec 6.4)
    if wgt.armed_now then
        M.close(wgt)
        wgt.fl_close_req = true
        return
    end
    -- fullscreen exit: release the file; the host's exit-rebuild runs anyway
    if lvgl.isFullScreen ~= nil and not lvgl.isFullScreen() then
        M.close(wgt)
        wgt.fl_close_req = true
        return
    end

    -- battery detail/editor pages: the module runs its own cycle (deferred
    -- registry writes included); its flags translate into the viewer's own
    if fl.batt_open and fl.B ~= nil then
        fl.B.refresh(wgt, event, touch_state)
        if wgt.fb_close_req then           -- the editor closed itself defensively
            wgt.fb_close_req = nil
            fl.batt_open = nil
            wgt.fl_dirty = true
        end
        if wgt.fb_dirty then
            wgt.fb_dirty = nil
            wgt.fl_dirty = true
        end
        return
    end

    -- chunked load in this call's own budget; one rebuild when done. The taps
    -- stay LIVE through it: the tab chips are on screen from the first build,
    -- and swallowing their events until the whole file was parsed read as a
    -- dead page (radio report, 2026-08-30). Only the chips exist during the
    -- load, so the dispatch is a handful of rect tests on a TAP event.
    if fl.stage ~= nil then
        dispatch_taps(wgt, fl, event, touch_state)
        if load_tick(wgt, fl) then
            wgt.fl_dirty = true
        end
        return
    end

    dispatch_taps(wgt, fl, event, touch_state)
end

return M
