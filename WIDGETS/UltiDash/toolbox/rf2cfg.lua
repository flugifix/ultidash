-- =====================================================================
--  UltiDash Toolbox: RF2 Config
--  Zero-copy adapter that runs the ORIGINAL rotorflight-lua-scripts
--  configuration tool inside UltiDash's fullscreen canvas. NO RF2 file
--  is copied: the UI runner/framework, the LVGL views, all PAGES and
--  the MSP layer load from /SCRIPTS/RF2/ on the SD card through the
--  rf2 global that the RfTool widget initializes. This module is pure
--  lifecycle glue (~200 lines); look & feel, navigation and key
--  handling are the original tool's, 1:1.
--
--  Reuse seams (the ONLY coupling points -- check these on RF2 updates,
--  see docs/RF2CFG_UPDATE_GUIDE.md in the release repo):
--    * SEAM run():   run = rf2.executeScript("ui_lvgl_runner")
--                    signature run(event, touchState, noUi) -> 0 | 2
--                    (2 = user exited the main menu with RTN/back).
--    * SEAM SLOTS:   the rf2.* UI callback slots the runner installs at
--                    load time; saved/restored so the RfTool widget's
--                    own fullscreen UI keeps working after we close.
--    * SEAM queue:   rf2.mspQueue.processQueue is gated while open so
--                    MSP reply callbacks (page builds, message boxes)
--                    always fire inside UltiDash's refresh()/LVGL
--                    context, never inside RfTool's background context.
--    * readiness:    rf2 + rf2.radio/mspQueue/mspHelper must exist
--                    (= RfTool widget in state "ready") and the RF2
--                    scripts must be compiled (RfTool does that).
--
--  DISARMED-ONLY (UltiDash hard rule: no MSP while armed). Entry is
--  gated in the host toolbox menu; refresh() force-closes on arm. The
--  host exempts tb_rf2cfg from its generic close-on-arm so THIS close,
--  with slot/queue restore, always runs (logview pattern).
-- =====================================================================

local M = {}

-- SEAM SLOTS: assigned at the bottom of /SCRIPTS/RF2/ui_lvgl_runner.lua and
-- called back by PAGES/*, MSP/* and the helpers. Extend on RF2 updates if the
-- runner installs new slots.
local SLOTS = {
    "reloadPage", "reloadMainMenu", "setWaitMessage", "clearWaitMessage",
    "settingsSaved", "onPageReady", "restartUi",
}

-- module-local state: the RF2 tool is single-instance by nature (one shared
-- rf2 global), so no per-widget wgt.* namespace is needed here
local run = nil            -- private ui_lvgl_runner instance (its run function)
local my_slots = nil       -- the slot functions OUR runner installed
local host_slots = nil     -- RfTool's slot functions (restored on close)
local orig_process = nil   -- unwrapped rf2.mspQueue.processQueue
local queue_wrapper = nil  -- our wrapper (identity check against double-wrap)
local in_refresh = false   -- true only while OUR refresh() pumps the queue
local is_open = false
local compiled_ok = false  -- sticky once true
local compiled_notice = nil
local next_probe = 0       -- SD probe throttle for the compile check (1 s)
local load_error = nil     -- sticky: runner failed to load
local run_error = nil      -- last runtime error; cleared on leaving the view
local shown_notice = nil   -- notice text currently built (change -> rebuild)

-- ---------------------------------------------------------------------
-- readiness: nil = good to open, otherwise a user-facing notice line
-- ---------------------------------------------------------------------

-- compile-state probe, throttled to 1 Hz (SD access) until it succeeds once.
-- RfTool compiles the scripts on its first run; we only ever check.
local function compiled_check()
    if compiled_ok then return nil end
    local now = getTime() or 0
    if now >= next_probe then
        next_probe = now + 100
        local ok, compiled = pcall(function()
            return loadScript("/SCRIPTS/RF2/COMPILE/scripts_compiled.lua")()
        end)
        if not ok then
            compiled_notice = "RF2 scripts missing (/SCRIPTS/RF2)"
        elseif not compiled then
            compiled_notice = "RF2 scripts not compiled - start RF Tool once"
        else
            compiled_ok = true
            compiled_notice = nil
        end
    end
    return compiled_notice
end

local function readiness(wgt)
    if type(rf2) ~= "table" or type(rf2.executeScript) ~= "function" then
        return "RF Tool widget not active"
    end
    if not (rf2.mspQueue and rf2.radio and rf2.mspHelper) then
        return "RF Tool not ready yet"
    end
    local c = compiled_check()
    if c then return c end
    if load_error then return load_error end
    if run_error then return "RF2 error: " .. run_error end
    -- No FC = no MSP: the original RF2 runner would sit forever on its "connecting"
    -- wait screen, which does NOT process RTN -> the tool looked stuck ("can't go back
    -- until something connects"). Gate on msp_allowed (connected/disarmed), which is
    -- callback-driven (telemetry state), so it stays valid even though open() pauses the
    -- MSP queue. On the notice page RTN exits cleanly, and readiness re-checks every
    -- refresh -> the tool opens by itself once the FC connects.
    if not (wgt and wgt.rf and wgt.rf.msp_allowed) then
        return "No FC connected"
    end
    return nil
end

-- ---------------------------------------------------------------------
-- open / close
-- ---------------------------------------------------------------------

-- Load a private ui_lvgl_runner instance (SEAM run()). Loading OVERWRITES the
-- rf2.* slots, so RfTool's are captured first and parked back afterwards;
-- ours live in my_slots and are only installed while the module is open.
local function load_runner()
    local before = {}
    for i = 1, #SLOTS do before[SLOTS[i]] = rf2[SLOTS[i]] end
    local ok, r = pcall(rf2.executeScript, "ui_lvgl_runner")
    if not ok or type(r) ~= "function" then
        for i = 1, #SLOTS do rf2[SLOTS[i]] = before[SLOTS[i]] end
        load_error = "RF2 UI won't load"
        return false
    end
    my_slots = {}
    for i = 1, #SLOTS do
        my_slots[SLOTS[i]] = rf2[SLOTS[i]]
        rf2[SLOTS[i]] = before[SLOTS[i]]   -- park RfTool's slots until open()
    end
    run = r
    return true
end

local function open(wgt)
    if is_open then return true end
    if not run and not load_runner() then return false end
    -- capture RfTool's CURRENT slots (it may have re-created its UI task) and
    -- install ours. Skip capturing a slot that still points at OUR function --
    -- that would mean a missed restore, and adopting our own function as
    -- "host" would make RfTool unrepairable.
    host_slots = host_slots or {}
    for i = 1, #SLOTS do
        local s = SLOTS[i]
        if rf2[s] ~= my_slots[s] then host_slots[s] = rf2[s] end
        rf2[s] = my_slots[s]
    end
    -- SEAM queue: context pinning. RfTool's background also pumps the shared
    -- queue; replies processed there would lvgl-build into the WRONG widget
    -- tree (RfTool's hidden one). While open, the pump only runs from inside
    -- OUR refresh(). Throughput is unchanged: we pump every cycle.
    if rf2.mspQueue.processQueue ~= queue_wrapper then
        orig_process = rf2.mspQueue.processQueue
        queue_wrapper = function(self, ...)
            if in_refresh or not is_open then return orig_process(self, ...) end
        end
        rf2.mspQueue.processQueue = queue_wrapper
    end
    -- original mechanic: full re-init incl. API handshake. pcall'd: an
    -- RF2-framework error here would otherwise crash the widget Lua state -- and a
    -- failed open must hand RfTool its slots/queue back, or its MSP processing
    -- would stay parked behind our (never-opened) context gate.
    local okr, err = pcall(my_slots.restartUi)
    if not okr then
        if host_slots then
            for i = 1, #SLOTS do
                local s = SLOTS[i]
                if host_slots[s] ~= nil then rf2[s] = host_slots[s] end
            end
        end
        if orig_process then
            rf2.mspQueue.processQueue = orig_process
            orig_process = nil
            queue_wrapper = nil
        end
        run_error = tostring(err)   -- surfaces via readiness() on the notice page
        return false
    end
    shown_notice = nil
    is_open = true
    return true
end

function M.close(wgt)
    if not is_open then return end
    is_open = false
    in_refresh = false
    if orig_process then
        rf2.mspQueue.processQueue = orig_process
        orig_process = nil
        queue_wrapper = nil
    end
    if host_slots then
        for i = 1, #SLOTS do
            local s = SLOTS[i]
            if host_slots[s] ~= nil then rf2[s] = host_slots[s] end
        end
    end
    pcall(function() rf2.mspQueue:clear() end)   -- drop pending reads/writes
end

-- forced close (fullscreen exit via close_tool_page, widget teardown): also
-- drop a sticky runtime error so the next open retries fresh
function M.cleanup(wgt)
    run_error = nil
    M.close(wgt)
end

-- ---------------------------------------------------------------------
-- host contract: build / refresh
-- ---------------------------------------------------------------------

local function exit_evt(event)
    return (EVT_VIRTUAL_EXIT ~= nil and event == EVT_VIRTUAL_EXIT)
        or (EVT_EXIT_BREAK ~= nil and event == EVT_EXIT_BREAK)
end

--- Host build pass. The original tool paints ITSELF (lvgl.clear + lvgl.build
--- inside run(): wait message, main menu, pages), so while open we only poke
--- the framework to re-show after the host cleared the screen. Not-open shows
--- a glue notice page (host style -- deliberately NOT part of the 1:1 RF2 UI).
function M.build(wgt, zone)
    local notice = (not is_open) and readiness(wgt) or nil
    if not notice then
        if is_open and my_slots then
            -- the framework rebuilds only on a state CHANGE; clearWaitMessage()
            -- ends in ui.refresh() (previousState = nil) -> next run() re-shows
            -- the current main menu / page (original mechanic, no new code path).
            -- pcall'd: a framework error lands on the notice page instead
            -- of crashing the widget state
            local okc, errc = pcall(my_slots.clearWaitMessage)
            if not okc then run_error = tostring(errc) end
        end
        return   -- opening this tick; the framework paints on the next refresh
    end
    shown_notice = notice
    local pg = lvgl.page({
        title = "UltiDash",
        subtitle = "RF2 Config",
        back = function()
            run_error = nil
            wgt.rf2cfg_close_req = "toolbox"
        end,
    })
    local _, mh = lcd.sizeText("Ag", MIDSIZE)
    local y = math.floor(zone.h / 3)
    pg:build({
        { type = "label", x = 20, y = y, w = zone.w - 40, h = mh,
          font = MIDSIZE, align = CENTER, text = notice },
        { type = "label", x = 20, y = y + mh + 8, w = zone.w - 40,
          font = SMLSIZE, align = CENTER, color = COLOR_THEME_SECONDARY1,
          text = "RTN: back to Toolbox" },
    })
end

--- Host refresh pass: arm force-close, readiness/notice handling, then the
--- original runner. Key handling stays 1:1 in the runner (RTN page->menu->
--- exit, PAGE</> page cycling, SYS popup); the ONLY remapped semantic is the
--- runner's exit code 2, which returns to the toolbox instead of leaving
--- fullscreen. wgt.rf2cfg_close_req ("toolbox"|"dashboard") tells the host
--- where to go; wgt.rf2cfg_dirty requests a host rebuild (notice page).
function M.refresh(wgt, event, touch_state)
    -- hard rule: no MSP while armed. Entry is gated by the toolbox menu; this
    -- covers arming while open (slot/queue restore runs, then straight back
    -- to the flight view).
    if is_open and wgt.armed_now then
        M.close(wgt)
        wgt.rf2cfg_close_req = "dashboard"
        return
    end
    if not is_open then
        -- notice mode: arming closes the view too (nothing to restore, but the
        -- notice page must not sit over the flight view)
        if wgt.armed_now then
            run_error = nil
            wgt.rf2cfg_close_req = "dashboard"
            return
        end
        -- RTN returns to the toolbox, otherwise wait for readiness
        if exit_evt(event) then
            run_error = nil
            wgt.rf2cfg_close_req = "toolbox"
            return
        end
        local n = readiness(wgt)
        if n then
            if n ~= shown_notice then wgt.rf2cfg_dirty = true end
            return
        end
        if not open(wgt) then return end
        -- fall through: pump right away so the wait message appears this tick
    end
    in_refresh = true
    local ok, result = pcall(run, event, touch_state, false)
    in_refresh = false
    if not ok then
        -- contain a runner/page error: restore RfTool's slots + queue, then
        -- surface the error on the glue notice page (RTN leaves, reopen retries)
        M.close(wgt)
        run_error = tostring(result)
        wgt.rf2cfg_dirty = true
        return
    end
    if result == 2 then      -- original exit semantics (RTN on the main menu)
        M.close(wgt)
        wgt.rf2cfg_close_req = "toolbox"
    end
end

return M
