-- =====================================================================
--  UltiDash Toolbox: Flight Log viewer
--  Shows the flight log (fltlog/flights.csv) and the battery registry
--  (fltlog/batteries.cfg): recent flights, per-model totals and battery
--  usage (cycles / last use). Three tabs: Flights / Models / Batteries.
--
--  DISARMED-ONLY, LAZY-loaded on open and released on close (same policy
--  as the Log Viewer -- boot-resident modules measurably drag the UI).
--  The CSV parse is CHUNKED over refresh() ticks with fixed work caps
--  against the ~20k instruction budget (getUsage() is a last-cycle
--  snapshot in LVGL widgets -- useless as a live gate, see logview.lua).
--  Per-instance state on wgt.fl; M.close(wgt) frees it.
-- =====================================================================

local M = {}

local CHUNK       = 2048   -- io.read chunk per tick
local LINES_TICK  = 90     -- CSV lines parsed per tick (one string.match each)
local MAX_FLIGHTS = 300    -- flight ring: on overflow the OLDEST entries drop,
                           -- totals/aggregates still count EVERY line

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
end

-- forced-exit cleanup (fullscreen exit via close_tool_page): release the file
M.cleanup = M.close

-- RTN: from a per-flight detail page it returns to the list (handled = true); from
-- the list it leaves the tool (host closes on false).
function M.on_exit_key(wgt)
    local fl = wgt.fl
    if fl ~= nil and fl.detail ~= nil then
        fl.detail = nil
        wgt.fl_dirty = true
        return true
    end
    return false
end

-- ---------------------------------------------------------------------
-- chunked CSV load (runs in M.refresh's own budget)
-- ---------------------------------------------------------------------
local function load_registry(wgt, fl)
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
        local ok, data = pcall(io.read, fl.fh, CHUNK)
        if not ok then data = nil end
        local buf = fl.buf .. (data or "")
        local eof = (data == nil or data == "")
        local pos = 1
        local lines = 0
        while lines < LINES_TICK do
            local e = string.find(buf, "\n", pos, true)
            local line
            if e ~= nil then
                line = string.sub(buf, pos, e - 1)
                pos = e + 1
            elseif eof and pos <= #buf then
                line = string.sub(buf, pos)       -- last line without newline
                pos = #buf + 1
            else
                break
            end
            local d, t, m, b, s, x = string.match(line, "^([^,]*),([^,]*),([^,]*),([^,]*),(%d+),?(.*)$")
            if d ~= nil then add_flight(fl, d, t, m, b, tonumber(s) or 0, x) end
            lines = lines + 1
        end
        fl.buf = string.sub(buf, pos)
        if eof and fl.buf == "" and lines < LINES_TICK then
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
local function fit(txt, max_w)
    txt = tostring(txt or "")
    if txt == "" then return txt end
    local tw = lcd.sizeText(txt, SMLSIZE)
    if tw <= max_w then return txt end
    local n = #txt
    while n > 1 do
        n = n - 1
        local cut = string.sub(txt, 1, n) .. "."
        if lcd.sizeText(cut, SMLSIZE) <= max_w then return cut end
    end
    return string.sub(txt, 1, 1)
end

-- ---------------------------------------------------------------------
-- UI (lvgl.page like the host menu pages; rebuilt via wgt.fl_dirty)
-- ---------------------------------------------------------------------
-- Two INDEPENDENT size flags. `big` (height) drives row heights / fonts, like the
-- rest of the widget. `wide` (WIDTH) drives the column layouts -- the TX15 is
-- 480x320, so its height passes the >=300 "big" test while its width is only 60 %
-- of the TX16S's 800: keying the columns off the height overlapped them (the
-- battery tab printed "1 fl26-07-10", the flight tab wrapped the pack name).
local function page_geometry(fl, zone)
    local big = zone.h >= 300
    local wide = zone.w >= 700
    local _, fh = lcd.sizeText("Ag", SMLSIZE)
    local row_h = fh + (big and 8 or 4)
    local top = big and 12 or 6              -- below the page header
    local tab_h = big and 36 or 26
    local foot_h = big and 38 or 28
    local header_px = big and 56 or 40       -- page title bar
    local avail = zone.h - header_px - top - tab_h - 8 - foot_h - 4
    local rows = math.max(3, math.floor(avail / row_h))
    return big, wide, fh, row_h, top, tab_h, foot_h, rows
end

local function item_count(fl)
    if fl.mode == "models" then return #fl.morder end
    if fl.mode == "batts" then return #fl.reg end
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

-- per-flight detail page (opened by tapping a Flights row): summary + a min/max table.
local function build_detail(wgt, fl, zone)
    local e = fl.detail
    local w = zone.w
    local big = zone.h >= 300
    local _, fh = lcd.sizeText("Ag", SMLSIZE)
    local hhmm = string.sub(e.t or "", 1, 5)
    local pg = lvgl.page({
        title = "Flight",
        subtitle = (e.d or "") .. " " .. hhmm,
        back = function() fl.detail = nil; wgt.fl_dirty = true end,
    })
    local row_h = fh + (big and 6 or 3)
    local lblw = math.floor(w * 0.42)
    local vw = w - lblw - 22
    local elems = {}
    local y = big and 10 or 4
    local stats = fl.D and fl.D.parse_stats(e.x) or nil
    -- summary block: model / battery / duration+mAh (+ sag count if any)
    local function kv(label, val)
        elems[#elems + 1] = { type = "label", x = 8, y = y, w = lblw, h = fh + 2,
            font = SMLSIZE, color = COLOR_THEME_SECONDARY1, text = label }
        elems[#elems + 1] = { type = "label", x = 8 + lblw + 6, y = y, w = vw, h = fh + 2,
            font = SMLSIZE, color = COLOR_THEME_PRIMARY1, text = val }
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
            font = SMLSIZE, align = CENTER, color = COLOR_THEME_DISABLED,
            text = "No stats recorded for this flight" }
        pg:build(elems)
        return
    end
    -- min/max table
    elems[#elems + 1] = { type = "rectangle", x = 8, y = y + 2, w = w - 16, h = 1,
        filled = true, color = COLOR_THEME_SECONDARY1 }
    y = y + 8
    local colw = math.floor((w - lblw - 16) / 2)
    local xmin = 8 + lblw
    local xmax = xmin + colw
    elems[#elems + 1] = { type = "label", x = xmin, y = y, w = colw, h = fh + 2,
        font = SMLSIZE, align = RIGHT, color = COLOR_THEME_SECONDARY1, text = "Min" }
    elems[#elems + 1] = { type = "label", x = xmax, y = y, w = colw, h = fh + 2,
        font = SMLSIZE, align = RIGHT, color = COLOR_THEME_SECONDARY1, text = "Max" }
    y = y + row_h
    for i = 1, #STAT_ROWS do
        local r = STAT_ROWS[i]
        local mn, mx = stats[r.min], stats[r.max]
        if not (r.hs and mn == nil and mx == nil) then   -- skip unused headspeed profiles
            elems[#elems + 1] = { type = "label", x = 8, y = y, w = lblw - 4, h = fh + 2,
                font = SMLSIZE, color = COLOR_THEME_SECONDARY1, text = r.label }
            elems[#elems + 1] = { type = "label", x = xmin, y = y, w = colw, h = fh + 2,
                font = SMLSIZE, align = RIGHT, color = COLOR_THEME_PRIMARY1, text = fmt_num(mn, r.dec) }
            elems[#elems + 1] = { type = "label", x = xmax, y = y, w = colw, h = fh + 2,
                font = SMLSIZE, align = RIGHT, color = COLOR_THEME_PRIMARY1, text = fmt_num(mx, r.dec) }
            y = y + row_h
        end
    end
    pg:build(elems)
end

function M.build(wgt, zone)
    local fl = ensure(wgt)
    -- a tapped Flights row shows its per-flight detail (stats) instead of the list
    if fl.detail ~= nil and fl.stage == nil then
        build_detail(wgt, fl, zone)
        return
    end
    local pg = lvgl.page({
        title = "Flight Log",
        subtitle = (fl.mode == "models") and "Per model"
            or (fl.mode == "batts") and "Batteries"
            or "Flights",
        back = function()
            M.close(wgt)
            wgt.fl_close_req = true
        end,
    })
    local big, wide, fh, row_h, top, tab_h, foot_h, rows = page_geometry(fl, zone)
    local w = zone.w
    local elems = {}

    -- tab row
    local tabs = { { "Flights", "flights" }, { "Models", "models" }, { "Batteries", "batts" } }
    local gap = 6
    local tw = math.floor((w - 16 - 2 * gap) / 3)
    for i = 1, 3 do
        local mode = tabs[i][2]
        local txt = (fl.mode == mode and "[ " .. tabs[i][1] .. " ]") or tabs[i][1]
        elems[#elems + 1] = { type = "button", x = 8 + (i - 1) * (tw + gap), y = top,
            w = tw, h = tab_h, font = big and 0 or SMLSIZE, text = txt,
            press = function()
                if fl.mode ~= mode then
                    fl.mode = mode
                    fl.page = 0
                    wgt.fl_dirty = true
                end
            end }
    end

    local y = top + tab_h + 8
    if fl.stage ~= nil then
        elems[#elems + 1] = { type = "label", x = 8, y = y + 12, w = w - 16, h = fh + 4,
            font = SMLSIZE, align = CENTER, color = COLOR_THEME_DISABLED,
            text = "Reading flight log ..." }
        pg:build(elems)
        return
    end

    local count = item_count(fl)
    -- every tab spends one row on a real header line (bare numbers need the column
    -- names — per-cell "cyc"/"flt" suffixes were not self-explanatory)
    local rows_eff = math.max(2, rows - 1)
    local pages = math.max(1, math.ceil(count / rows_eff))
    if fl.page > pages - 1 then fl.page = pages - 1 end
    if fl.page < 0 then fl.page = 0 end

    -- column layout per tab (fractions of the width)
    local function put(x, ww, txt, color, align)
        elems[#elems + 1] = { type = "label", x = x, y = y, w = ww, h = fh + 2,
            font = SMLSIZE, text = txt, color = color or COLOR_THEME_PRIMARY1,
            align = align or LEFT }
    end

    -- Column geometry is DERIVED from the width (never hardcoded for one radio):
    -- the fixed-width columns keep their measured size, the free text columns
    -- (model / pack name) share whatever is left. Works at 480 and at 800.
    local GAP = 8
    -- header lines match the muted data-column gray, NOT COLOR_THEME_DISABLED --
    -- the UltiDash palette repurposes DISABLED as an orange accent, which made the
    -- headers/footer read like warnings
    local HDR_COLOR = COLOR_THEME_SECONDARY1
    if count == 0 then
        local hint = (fl.mode == "batts")
            and "No batteries - edit fltlog/batteries.cfg on the PC"
            or "No flights logged yet"
        put(8, w - 16, hint, COLOR_THEME_DISABLED, CENTER)
    elseif fl.mode == "flights" then
        -- date+time | model | pack | duration(right)
        local w_dur = wide and 70 or 52
        local x_dur = w - w_dur - 6
        local w_when = wide and 178 or 112
        local x_model = 6 + w_when + GAP
        local free = x_dur - GAP - x_model         -- shared by model + pack
        local w_model = math.floor(free * 0.5)
        local x_pack = x_model + w_model + GAP
        local w_pack = free - w_model - GAP
        put(6, w_when, "Date", HDR_COLOR)
        put(x_model, w_model, "Model", HDR_COLOR)
        put(x_pack, w_pack, "Battery", HDR_COLOR)
        put(x_dur, w_dur, "Time", HDR_COLOR, RIGHT)
        y = y + row_h
        -- newest first: absolute index j counts down from fl.n
        local first = fl.n - fl.page * rows_eff
        local vpad = math.max(0, math.floor((row_h - fh) / 2))   -- center text in the row button
        for i = 0, rows_eff - 1 do
            local j = first - i
            if j < 1 or j <= fl.n - MAX_FLIGHTS then break end
            local e = fl.ring[((j - 1) % MAX_FLIGHTS) + 1]
            local hhmm = string.sub(e.t or "", 1, 5)
            -- narrow drops the year: "07-10 10:26" instead of "2026-07-10 10:26"
            local when = (wide and (e.d or "") or string.sub(e.d or "", 6)) .. " " .. hhmm
            -- full-row tap target (behind the column labels) -> per-flight detail page
            local rowy = y
            elems[#elems + 1] = { type = "button", x = 4, y = rowy, w = w - 8, h = row_h,
                text = " ", press = function() fl.detail = e; wgt.fl_dirty = true end }
            y = rowy + vpad                                       -- labels vertically centered
            put(6, w_when, when)
            put(x_model, w_model, fit(e.m, w_model))
            put(x_pack, w_pack, fit(fl.names[e.b] or e.b, w_pack), COLOR_THEME_SECONDARY1)
            put(x_dur, w_dur, fmt_mmss(e.s), nil, RIGHT)
            y = rowy + row_h
        end
    elseif fl.mode == "models" then
        -- model | flights | total time(right)
        local w_tot = wide and 110 or 84
        local x_tot = w - w_tot - 6
        local w_cnt = wide and 110 or 76
        local x_cnt = x_tot - GAP - w_cnt
        put(6, x_cnt - GAP - 6, "Model", HDR_COLOR)
        put(x_cnt, w_cnt, "Flights", HDR_COLOR)
        put(x_tot, w_tot, "Total time", HDR_COLOR, RIGHT)
        y = y + row_h
        for i = 1 + fl.page * rows_eff, math.min(#fl.morder, (fl.page + 1) * rows_eff) do
            local m = fl.morder[i]
            local e = fl.models[m]
            put(6, x_cnt - GAP - 6, fit(m, x_cnt - GAP - 6))
            put(x_cnt, w_cnt, tostring(e.n))
            put(x_tot, w_tot, fmt_total(e.s), nil, RIGHT)
            y = y + row_h
        end
    else -- batteries: name | capacity | cycles | flights | last use(right)
        local w_last = wide and 112 or 86
        local x_last = w - w_last - 6
        local w_cap = wide and 96 or 72
        local w_cyc = wide and 84 or 56
        local w_flt = wide and 84 or 52
        local x_flt = x_last - GAP - w_flt
        local x_cyc = x_flt - GAP - w_cyc
        local x_cap = x_cyc - GAP - w_cap
        -- header line with the full column names; the cells below carry bare numbers
        put(6, x_cap - GAP - 6, "Battery", HDR_COLOR)
        put(x_cap, w_cap, "Capacity", HDR_COLOR)
        put(x_cyc, w_cyc, "Cycles", HDR_COLOR)
        put(x_flt, w_flt, "Flights", HDR_COLOR)
        put(x_last, w_last, "Last use", HDR_COLOR, RIGHT)
        y = y + row_h
        for i = 1 + fl.page * rows_eff, math.min(#fl.reg, (fl.page + 1) * rows_eff) do
            local b = fl.reg[i]
            local flights = fl.by_id[b.id] or 0
            put(6, x_cap - GAP - 6, fit(b.name or b.id, x_cap - GAP - 6))
            put(x_cap, w_cap, b.cap and (b.cap .. " mAh") or "-")
            put(x_cyc, w_cyc, tostring(b.cycles or 0))
            put(x_flt, w_flt, tostring(flights))
            put(x_last, w_last, (b.last ~= nil and b.last ~= "") and b.last or "-", nil, RIGHT)
            y = y + row_h
        end
    end

    -- footer: totals + paging
    local fy = zone.h - ((big and 56 or 40)) - foot_h
    local total_txt
    if fl.mode == "flights" then
        total_txt = fl.n .. ((fl.n == 1) and " flight - " or " flights - ") .. fmt_total(fl.tot_s)
        if fl.n > MAX_FLIGHTS then
            total_txt = total_txt .. " (last " .. MAX_FLIGHTS .. " listed)"
        end
    elseif fl.mode == "models" then
        total_txt = count .. ((count == 1) and " model" or " models")
    else
        total_txt = count .. ((count == 1) and " battery" or " batteries")
    end
    -- footer text vertically centered on the pager buttons (h = foot_h - 2), in the
    -- same muted gray as the headers (see HDR_COLOR above)
    local fty = fy + math.floor((foot_h - 2 - fh) / 2)
    elems[#elems + 1] = { type = "label", x = 8, y = fty, w = math.floor(w * 0.5), h = fh + 2,
        font = SMLSIZE, color = HDR_COLOR, text = total_txt }
    if pages > 1 then
        local bw = big and 64 or 48
        elems[#elems + 1] = { type = "label", x = w - 2 * bw - 90, y = fty, w = 76, h = fh + 2,
            font = SMLSIZE, align = RIGHT, color = HDR_COLOR,
            text = (fl.page + 1) .. "/" .. pages }
        elems[#elems + 1] = { type = "button", x = w - 2 * bw - 10, y = fy, w = bw, h = foot_h - 2,
            font = SMLSIZE, text = "<",
            press = function()
                if fl.page > 0 then fl.page = fl.page - 1; wgt.fl_dirty = true end
            end }
        elems[#elems + 1] = { type = "button", x = w - bw - 4, y = fy, w = bw, h = foot_h - 2,
            font = SMLSIZE, text = ">",
            press = function()
                if fl.page < pages - 1 then fl.page = fl.page + 1; wgt.fl_dirty = true end
            end }
    end

    pg:build(elems)
end

function M.refresh(wgt, event, touch_state)
    local fl = ensure(wgt)

    -- disarmed-only: auto-close on arm; the host clears menu_view (fl_close_req)
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

    -- chunked load in this call's own budget; one rebuild when done
    if fl.stage ~= nil then
        if load_tick(wgt, fl) then
            wgt.fl_dirty = true
        end
        return
    end
end

return M
