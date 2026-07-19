-- check_budget.lua — PC-side EdgeTX instruction-budget check for UltiDash.
--
-- EdgeTX gives every widget call (create/update/refresh/background) a budget of
-- ~20k Lua VM instructions (lua_widget.cpp MAX_INSTRUCTIONS, enforced via
-- lua_sethook LUA_MASKCOUNT -> "CPU limit"). This harness loads the REAL widget
-- sources with stubbed EdgeTX APIs and counts VM instructions per lifecycle
-- phase with the same mechanism (debug.sethook count), so a budget overrun is
-- visible BEFORE deploying to the radio.
--
-- Run (from the repo root):
--   lua.exe _tools/check_budget.lua        (-v = per-cycle detail)
-- Exit code 1 when a phase exceeds the WARN threshold.
--
-- Measured phases:
--   RUN 1 (disconnected, warm cfg — the classic cold boot):
--     1. create()      = the five module chunks (lazy-loaded inside create) + flag-only update
--        (+ a per-chunk module-level cost table from the loadScript hook)
--     2. refresh #1    = stage 2: cold cfg SD read + parse + apply (alone in its cycle)
--     3. refresh #2..N = stage 3: the full UI build + steady state (max of any single call)
--     4. PAGE BUILDS   = menu hub, settings menu, every settings group (incl. submenu
--        pages, driven through the REAL captured button callbacks — so lazy builds run
--        exactly like a user tap), the 4 detail pages, sensor check, status, toolbox.
--        This is the historically most overrun-prone class (the Shortcuts-page "CPU
--        limit" crash was exactly such a blind spot).
--   RUN 2 (connected rf2 stub + legacy-cfg fixture, fresh module instances):
--     5. create / refresh #1 (measures the legacy cfg adoption incl. its writes)
--        / refresh #2..N (the full CONNECTED 5 Hz pass incl. the sensor scan).
--
-- CAVEATS (why WARN sits well under 20k):
--   * lcd/lvgl/getValue are stubs: real C-call overhead differs a little, and reactive
--     closures (color=/text= functions) don't run at build time here.
--   * The synthetic cfg below should stay >= the biggest real per-model cfg.
--   * Page builds are measured as a direct update() call — on the radio the rebuild
--     runs inside a refresh cycle whose preamble adds a few hundred instructions.
-- Treat >WARN as broken, >INFO as "needs a look".

local WARN = 16000   -- fail: too close to the radio's ~20k
local INFO = 12000   -- headroom note

local ROOT = arg and arg[0] and string.match(arg[0], "^(.*)[/\\][^/\\]+$") or "."
ROOT = ROOT .. "/.."                       -- _tools/ -> repo root
local WIDGET_DIR = ROOT .. "/WIDGETS/UltiDash/"
local verbose = arg and arg[1] == "-v"

-- ---------------------------------------------------------------------------
-- instruction counter state (the hook mechanism EdgeTX uses for its CPU limit);
-- declared FIRST so the loadScript hook below can share the counter upvalue
-- ---------------------------------------------------------------------------
local counted = 0
local chunk_cost = {}   -- rel path -> module-level instructions (incl. nested loads)

-- ---------------------------------------------------------------------------
-- synthetic per-model cfg: worst-case size (all settings keys incl. the 36
-- colour overrides). Kept as a COUNT so it tracks growth generously.
-- ---------------------------------------------------------------------------
local CFG_LINES = 300
local cfg_content = {}
for i = 1, CFG_LINES do cfg_content[i] = string.format("TestKey%03d=%d", i, i * 3) end
cfg_content[#cfg_content + 1] = "ColorScheme=2"
cfg_content[#cfg_content + 1] = "ClrDS2=16711680"
cfg_content = table.concat(cfg_content, "\n") .. "\n"

-- ---------------------------------------------------------------------------
-- EdgeTX API stubs (only what the widget touches on the measured paths)
-- ---------------------------------------------------------------------------
local function rgb565(r, g, b)
    return ((((r // 8) * 2048) + ((g // 4) * 32) + (b // 8)) * 65536)
end

-- in-memory "SD card": path -> content (the widget reads/writes cfg files here)
local sd_files = { ["/WIDGETS/UltiDash/cfg/cfg_m_model01.cfg"] = cfg_content }

local G = {}   -- shared sandbox env for all widget chunks

local function stub_io_open(path, mode)
    if mode == nil or string.find(mode, "r", 1, true) then
        local data = sd_files[path]
        if data == nil then return nil end
        return { data = data, pos = 1, w = false }
    end
    local f = { data = "", pos = 1, w = true, path = path }
    sd_files[path] = ""
    return f
end

G.io = {
    open = stub_io_open,
    -- EdgeTX signature: io.read(file, bytes)
    read = function(f, n)
        if f == nil or f.data == nil then return nil end
        if f.pos > #f.data then return "" end
        local chunk = string.sub(f.data, f.pos, f.pos + n - 1)
        f.pos = f.pos + n
        return chunk
    end,
    write = function(f, s)
        if f and f.w then f.data = f.data .. s; sd_files[f.path] = f.data end
    end,
    close = function() end,
}
G.fstat = function(path)
    if sd_files[path] ~= nil then return { size = #(sd_files[path]) } end
    if path == "/WIDGETS/UltiDash/cfg" then return { size = 0 } end   -- cfg/ subdir exists
    -- toolbox sources exist locally, report them present like on the radio
    local fh = io.open(WIDGET_DIR .. string.gsub(path, "^/WIDGETS/UltiDash/", ""), "r")
    if fh then fh:close(); return { size = 1 } end
    return nil
end
-- dir() lists the immediate children of a path from the in-memory SD (names only,
-- like the radio) — the cfg flat-sweep and the legacy-adoption fixture need it
G.dir = function(path)
    local prefix = path
    if string.sub(prefix, -1) ~= "/" then prefix = prefix .. "/" end
    local names, seen = {}, {}
    for p in pairs(sd_files) do
        if string.sub(p, 1, #prefix) == prefix then
            local name = string.match(string.sub(p, #prefix + 1), "^([^/]+)")
            if name and not seen[name] then seen[name] = true; names[#names + 1] = name end
        end
    end
    table.sort(names)
    local i = 0
    return function() i = i + 1; return names[i] end
end
-- del/rename return FRESULT like the radio (0 = FR_OK); rename moves the sd_files entry
G.rename = function(from, to)
    if sd_files[from] == nil then return 4 end   -- FR_NO_FILE
    if sd_files[to] ~= nil then return 8 end     -- FR_EXIST
    sd_files[to] = sd_files[from]; sd_files[from] = nil
    return 0
end
G.del = function(path)
    if sd_files[path] == nil then return 4 end   -- FR_NO_FILE
    sd_files[path] = nil
    return 0
end

-- loadScript hook: wraps every chunk so its MODULE-LEVEL cost is attributed per file
-- (nested loadScript'ed chunks count into their parent too — noted in the report).
G.loadScript = function(path, _mode)
    local rel = string.gsub(path, "^/WIDGETS/UltiDash/", "")
    local fh = assert(io.open(WIDGET_DIR .. rel, "rb"), "missing source: " .. rel)
    local src = fh:read("*a"); fh:close()
    local chunk = assert(load(src, "@" .. rel, "t", G))
    return function(...)
        local before = counted
        local r1, r2, r3 = chunk(...)
        chunk_cost[rel] = (chunk_cost[rel] or 0) + (counted - before)
        return r1, r2, r3
    end
end

G.lcd = {
    RGB = function(r, g, b) return rgb565(r, g, b) end,
    sizeText = function(t, _f) return #tostring(t or "") * 10, 20 end,
}

-- ---------------------------------------------------------------------------
-- LVGL stub with BUTTON CAPTURE: every table handed to any lvgl call is scanned
-- for {press=function} entries. update() calls lvgl.clear() first, so each build
-- starts with a fresh capture set — the page phases below press the REAL menu
-- callbacks (open_group/open_page), exercising lazy item builds like a user tap.
-- ---------------------------------------------------------------------------
local captured = {}
local hook_on = false          -- true while count_call has the instruction hook set
local function count_hook() counted = counted + 1 end
local function scan_buttons(t, depth, seen)
    if type(t) ~= "table" or depth > 8 or seen[t] then return end
    seen[t] = true
    if type(t.press) == "function" then
        captured[#captured + 1] = { text = tostring(t.text or t.txt or "?"), press = t.press }
    end
    for _, v in pairs(t) do
        if type(v) == "table" then scan_buttons(v, depth + 1, seen) end
    end
end
local lvobj
local function lv_call(...)
    -- the capture walk is HARNESS work — suspend the instruction hook so it never
    -- counts into the measured phase (it inflated builds by thousands of instr)
    if hook_on then debug.sethook() end
    for i = 1, select("#", ...) do
        local a = select(i, ...)
        if type(a) == "table" and a ~= lvobj then scan_buttons(a, 1, {}) end
    end
    if hook_on then debug.sethook(count_hook, "", 1) end
    return lvobj
end
lvobj = setmetatable({}, { __index = function() return lv_call end })
G.lvgl = setmetatable({
    isFullScreen = function() return false end,
    isAppMode = function() return false end,
    clear = function() for i = #captured, 1, -1 do captured[i] = nil end end,
    LCD_SCALE = 1, UI_ELEMENT_HEIGHT = 32,
    SRC_SWITCH = 1, SRC_LOGICAL_SWITCH = 2, SRC_INVERT = 4, SRC_CLEAR = 8, SRC_TELEM = 16,
}, { __index = function() return lv_call end })

local function find_button(text)
    for i = 1, #captured do
        if captured[i].text == text then return captured[i] end
    end
    return nil
end
local function button_texts(skip)
    local out = {}
    for i = 1, #captured do
        local t = captured[i].text
        if not (skip and skip[t]) then out[#out + 1] = t end
    end
    return out
end

-- fonts/attrs/theme colours (plausible numeric values; heights come from lcd.sizeText)
G.TINSIZE, G.SMLSIZE, G.STDSIZE, G.MIDSIZE, G.DBLSIZE, G.XXLSIZE = 1, 2, 0, 3, 4, 5
G.LEFT, G.RIGHT, G.CENTER, G.VCENTER, G.BOLD, G.BLINK, G.INVERS, G.SHADOWED = 0, 16, 32, 64, 128, 256, 512, 1024
G.COLOR_THEME_PRIMARY1   = rgb565(0x20, 0x20, 0x20)
G.COLOR_THEME_PRIMARY2   = rgb565(0xF0, 0xF0, 0xF0)
G.COLOR_THEME_SECONDARY1 = rgb565(0x30, 0x30, 0x30)
G.COLOR_THEME_SECONDARY2 = rgb565(0xA0, 0xB0, 0xC0)
G.COLOR_THEME_SECONDARY3 = rgb565(0xE0, 0xE4, 0xE8)
G.COLOR_THEME_FOCUS      = rgb565(0x30, 0x60, 0xC0)
G.COLOR_THEME_WARNING    = rgb565(0xE0, 0x30, 0x30)
G.COLOR_THEME_DISABLED   = rgb565(0x90, 0x90, 0x90)
G.WHITE, G.BLACK, G.GREY, G.RED, G.GREEN, G.YELLOW, G.ORANGE, G.BLUE =
    rgb565(255,255,255), 0, rgb565(128,128,128), rgb565(224,0,0),
    rgb565(0,192,0), rgb565(240,224,0), rgb565(240,144,0), rgb565(0,64,224)
G.EVT_TOUCH_TAP, G.EVT_TOUCH_SLIDE, G.EVT_VIRTUAL_EXIT, G.EVT_VIRTUAL_ENTER = 100, 101, 102, 103

-- Time advances a fixed 5 cs per WIDGET CALL (see count_call/build_silent), like the
-- radio's ~20 Hz refresh — NOT per getTime() read: advancing on every read made the
-- 5 Hz telemetry gate fire in EVERY cycle, so `ran_pass` permanently deferred the UI
-- build and the build cost never showed up (a harness artifact, not radio behavior).
local fake_time = 0
G.getTime = function() return fake_time end
G.getDateTime = function() return { year = 2026, mon = 7, day = 9, hour = 12, min = 0, sec = 0 } end
G.getValue = function() return 0 end
G.getFieldInfo = function() return nil end
G.getSourceValue = function() return 0 end
G.getSourceName = function() return "SA" end
G.getLogicalSwitchValue = function() return false end
G.getSwitchIndex = function() return nil end
G.getAvailableMemory = function() return 3 * 1024 * 1024 end
G.getVersion = function() return "2.12.0", "tx16s", 2, 12, 0 end
G.getGeneralSettings = function() return { battMin = 6.8, battMax = 8.4, battWarn = 7.2 } end
G.getRSSI = function() return 90, 45, 42 end
G.playFile = function() end
G.playNumber = function() end
G.playHaptic = function() end
G.playTone = function() end
G.model = {
    getInfo = function() return { name = "TestModel", filename = "model01" } end,
    getGlobalVariable = function() return 0 end,
    getTimer = function() return { value = 0, mode = 1 } end,
    getSensor = function() return nil end,   -- 60-slot sensor scan runs its full loop
}
G.GVAR_MAX, G.CHAR_TRIM = 1024, "\128"
G.killEvents = function() end
G.crossfireTelemetryPush = function() return false end
G.sportTelemetryPush = function() return false end
G.serialWrite = function() end
G.rf2 = nil   -- RUN 1: RFTool absent, connection state stays "disconnected"

-- base library passthrough (what EdgeTX exposes to widgets)
G.string, G.table, G.math, G.os = string, table, math, { clock = os.clock, time = os.time }
G.pairs, G.ipairs, G.next, G.type, G.tostring, G.tonumber = pairs, ipairs, next, type, tostring, tonumber
G.pcall, G.xpcall, G.error, G.assert, G.select, G.unpack = pcall, xpcall, error, assert, select, table.unpack
G.setmetatable, G.getmetatable, G.rawset, G.rawget, G.rawequal = setmetatable, getmetatable, rawset, rawget, rawequal
G.collectgarbage = collectgarbage
G.print = print
G._G = G

-- ---------------------------------------------------------------------------
-- instruction counter (the exact mechanism EdgeTX uses for its CPU limit)
-- ---------------------------------------------------------------------------
local function count_call(fn, ...)
    fake_time = fake_time + 5          -- one widget call = one ~20 Hz cycle
    counted = 0
    hook_on = true
    debug.sethook(count_hook, "", 1)
    local ok, err = pcall(fn, ...)
    debug.sethook()
    hook_on = false
    return counted, ok, (not ok) and err or nil
end

local function report(label, n, ok, err)
    local flag = "OK  "
    if not ok then flag = "ERR "
    elseif n > WARN then flag = "FAIL"
    elseif n > INFO then flag = "WARN" end
    print(string.format("%-4s %-40s %6d instr  (limit 20000)", flag, label, n))
    if not ok then print("     stub gap: " .. tostring(err)) end
    return ok and n <= WARN
end

-- ---------------------------------------------------------------------------
-- lifecycle driver (shared by both runs)
-- ---------------------------------------------------------------------------
local zone = { x = 0, y = 0, w = 800, h = 480 }
local pass = true

local function run_lifecycle(tag)
    local widget, wgt
    -- phase 1: create() = module chunks (all five, incl. toolbox probes) + flag-only
    -- update. Counted as ONE call, exactly like main.lua's lazy get_ulti_dash().
    local n1, ok1, err1 = count_call(function()
        widget = G.loadScript("/WIDGETS/UltiDash/ultidash.lua", "btd")()
        wgt = widget.create(zone, { ViewMode = 1 })
    end)
    pass = report(tag .. "create() [module load + flag]", n1, ok1 and wgt ~= nil, err1) and pass

    if not (ok1 and wgt) then return nil, nil end

    -- phase 2: first refresh cycle = stage-2 settings apply (cold cfg read + parse;
    -- with the RUN-2 fixture this includes the legacy adoption + its writes)
    local n2, ok2, err2 = count_call(function() widget.refresh(wgt, nil, nil) end)
    pass = report(tag .. "refresh #1 [cfg read + apply]", n2, ok2, err2) and pass

    -- phase 3+: a batch of refresh cycles. Stage-3 UI build, throttled telemetry pass
    -- and steady-state frames distribute over these depending on the internal gates —
    -- what matters for the budget is the MAX any single call reaches.
    local max_n, max_i, worst_err = 0, 0, nil
    local all_ok = true
    for i = 2, 40 do
        local dirty_before = wgt.view and wgt.view.dirty
        local n, ok, err = count_call(function() widget.refresh(wgt, nil, nil) end)
        if verbose then
            print(string.format("     cycle %2d: %6d instr  dirty(before)=%s%s",
                i, n, tostring(dirty_before), ok and "" or ("  ERR " .. tostring(err))))
        end
        if not ok then all_ok = false; worst_err = err end
        if n > max_n then max_n, max_i = n, i end
    end
    pass = report(string.format("%srefresh #2..40 max (at #%d)", tag, max_i), max_n, all_ok, worst_err) and pass
    return widget, wgt
end

-- ---------------------------------------------------------------------------
-- RUN 1: disconnected, warm cfg (the classic cold boot) + page-build phases
-- ---------------------------------------------------------------------------
print("UltiDash EdgeTX budget check (warn > " .. WARN .. ", info > " .. INFO .. ")")
print(string.rep("-", 76))

local widget, wgt = run_lifecycle("")

-- per-chunk module-level cost (from the loadScript hook; parents include nested loads)
do
    local rels = {}
    for rel in pairs(chunk_cost) do rels[#rels + 1] = rel end
    table.sort(rels, function(a, b) return chunk_cost[a] > chunk_cost[b] end)
    print("     module-level cost per chunk (nested loads count into their parent):")
    for i = 1, #rels do
        print(string.format("       %-32s %6d instr", rels[i], chunk_cost[rels[i]]))
    end
end

-- ---------------------------------------------------------------------------
-- page-build phases: drive the menu through the REAL captured button callbacks
-- ---------------------------------------------------------------------------
if widget and wgt then
    -- a direct update() = the rebuild call the dirty flag defers to its own cycle.
    -- Staggered working-copy seeding (F-S13-1): a settings page's FIRST update only
    -- seeds + flags rf_data_dirty; the build then runs in its own call on the radio.
    -- Measure both calls and report the MAX — each has its own 20k budget.
    local function measure_page_call()
        local n1, ok1, err1 = count_call(function() widget.update(wgt, wgt.options) end)
        if not (ok1 and wgt.rf_data_dirty) then return n1, ok1, err1, nil end
        wgt.rf_data_dirty = false
        fake_time = fake_time + 5
        local n2, ok2, err2 = count_call(function() widget.update(wgt, wgt.options) end)
        return math.max(n1, n2), ok2, err2, string.format("%d seed + %d build", n1, n2)
    end
    local function measure_update(label)
        local n, ok, err, split = measure_page_call()
        pass = report(label, n, ok, err) and pass
        if verbose and split then print("       (" .. split .. ")") end
        return ok
    end
    -- rebuild a view WITHOUT measuring (to (re)capture its buttons)
    local function build_silent()
        fake_time = fake_time + 5      -- still a widget call on the fake clock
        widget.update(wgt, wgt.options)
    end
    local function goto_view(view)
        wgt.detail_view = nil
        wgt.settings_page = nil
        -- charge the working-copy seeding to EVERY page (F-S13-1): on the radio each
        -- first-open seeds it afresh (close_settings nils it), so a measurement that
        -- lets one page's seed ride into the next hides ~7k instructions per page
        wgt.settings_working = nil
        wgt.menu_view = view
        build_silent()
    end

    -- the menu hub + the fixed pages
    wgt.menu_view = "menu"; wgt.detail_view = nil
    measure_update("page: menu hub")
    goto_view("settings_menu"); measure_update("page: settings menu (grid)")
    goto_view("status");        measure_update("page: status")
    -- sensor check opens in three own calls now (F-S13-2/F-S9-2): the frame + note
    -- build, the host's exclusive 1 Hz scan-tick refresh, then the row rebuild
    goto_view("sensorcheck")
    wgt.senscheck = nil; wgt.senscheck_next = 0   -- measure a true first open
    measure_update("page: sensor check [frame]")
    fake_time = fake_time + 5
    do
        local n, ok, err = count_call(function() widget.refresh(wgt, nil, nil) end)
        pass = report("page: sensor check [scan tick]", n, ok, err) and pass
    end
    measure_update("page: sensor check [rows]")
    goto_view("toolbox");       measure_update("page: toolbox menu")

    -- every settings group, via its REAL settings-menu button (lazy builds run like a tap)
    goto_view("settings_menu")
    local groups = button_texts({ ["Reset to defaults"] = true })
    for gi = 1, #groups do
        local gname = groups[gi]
        goto_view("settings_menu")
        local gb = find_button(gname)
        if gb then
            gb.press()                        -- sets settings_page / settings_sub + menu_view
            local sub = wgt.menu_view
            if sub == "settings" then
                measure_update("group: " .. gname)
            else
                -- submenu grid (Alerts / Colors / Telemetry / Voice / Shortcuts):
                -- measure the grid, then EVERY page behind it; report the max as the group
                build_silent()
                local pages = button_texts()
                local max_n, max_p, all_ok, worst = 0, "grid", true, nil
                local ng, okg, errg = count_call(function() widget.update(wgt, wgt.options) end)
                if not okg then all_ok = false; worst = errg end
                if ng > max_n then max_n, max_p = ng, "grid" end
                for pi = 1, #pages do
                    wgt.menu_view = sub; wgt.settings_page = nil
                    wgt.settings_working = nil   -- seed per page here too (F-S13-1)
                    build_silent()
                    local pb = find_button(pages[pi])
                    if pb then
                        pb.press()
                        local np, okp, errp, split = measure_page_call()
                        if not okp then all_ok = false; worst = errp end
                        if np > max_n then max_n, max_p = np, pages[pi] end
                        if verbose then
                            print(string.format("       %-36s %6d instr%s", gname .. " > " .. pages[pi], np,
                                split and ("  (" .. split .. ")") or ""))
                        end
                    end
                end
                pass = report(string.format("group: %s (max: %s)", gname, max_p), max_n, all_ok, worst) and pass
            end
        else
            print("ERR  group button not found: " .. gname)
            pass = false
        end
    end

    -- the 4 tap-detail pages (flight view only)
    wgt.menu_view = nil; wgt.settings_page = nil; wgt.settings_working = nil
    wgt.view = wgt.view or {}
    wgt.view.current = "flight"
    for _, dv in ipairs({ "elrs", "estatus", "battery", "telem" }) do
        wgt.detail_view = dv
        measure_update("detail: " .. dv)
    end
    wgt.detail_view = nil
end

-- ---------------------------------------------------------------------------
-- RUN 2: connected rf2 stub + legacy-cfg fixture, FRESH module instances.
-- Measures the legacy adoption (refresh #1) and the full connected 5 Hz pass
-- incl. the sensor scan (refresh #2..40).
-- ---------------------------------------------------------------------------
print(string.rep("-", 76))
G.rf2 = {
    rfToolState = "connected",
    registerWidget = function() end,
    -- reads complete without a callback (queue drained instantly); the widget's
    -- nil-guards cover the never-delivered configs
    useApi = function() return { read = function() end, write = function() end } end,
}
sd_files["/WIDGETS/UltiDash/cfg/cfg_m_model01.cfg"] = nil      -- no slot cfg yet ...
sd_files["/WIDGETS/UltiDash/cfg_TestModel.cfg"] = cfg_content  -- ... only a legacy flat file
run_lifecycle("connected+legacy: ")

print(string.rep("-", 76))
print(pass and "RESULT: within budget" or "RESULT: BUDGET PROBLEM — fix before deploying")
os.exit(pass and 0 or 1)
