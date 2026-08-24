-- =====================================================================
--  UltiDash Toolbox: RFSuite
--  Zero-copy adapter that runs the ORIGINAL rotorflight-lua-edgetx-suite
--  configuration tool inside UltiDash's fullscreen canvas. NO RFSuite
--  file is copied: everything loads from /SCRIPTS/TOOLS/rfsuite-core/
--  on the SD card, so the card's own install decides the version.
--
--  WHY THIS IS NOT rf2cfg.lua, although it looks like it. rf2cfg BORROWS:
--  the RfTool WIDGET has already published `rf2` -- MSP stack, radio,
--  queue -- into the shared widget Lua state, and the adapter only loads
--  the UI runner and pumps it. RFSuite publishes no `rf2`, offers no
--  third-party API, and its tool lives in the STANDALONE script state.
--  There is nothing to borrow, so this adapter LOADS THE WHOLE TOOL into
--  the widget state itself. That is the entire difference, and it is what
--  makes the two cost lines below unlike anything rf2cfg pays.
--
--  Seams (the ONLY coupling points -- check on an RFSuite update):
--    * SEAM home:   ui/home.lua returns { init, run, useLvgl = true };
--                   run(event, touchState) -> 0 | 2 (2 = user exited).
--                   Same contract EdgeTX gives a TOOLS script, and the
--                   same one rf2cfg's ui_lvgl_runner has.
--    * SEAM require: lib/require.lua installs _G.rfsuite.require and,
--                   crucially, _G.rfsuite.clearAllModules. RFSuite's own
--                   widget can never call that (its only caller sits in
--                   the other Lua state); WE loaded it, so we can. That
--                   is the one lever against the module graph pinning
--                   itself until power-off.
--    * SEAM msp:    tasks/msp/runtime.lua attach("tool")/detach("tool").
--                   home.lua attaches on its first run and detaches on
--                   its own exit -- but NOT when WE close it (arm), so
--                   close() detaches by hand.
--
--  THE TWO COSTS, MEASURED on the simulator 2026-08-18 against a control
--  card differing only in whether RFSuite is installed:
--    1. HEAP. Opening the tool costs +656..737 kB. close() calls
--       clearAllModules -- a call RFSuite's own widget can never make,
--       its only caller sitting in the standalone Lua state -- and that
--       gives back roughly 60-75 %: 172-281 kB stays reachable above the
--       measurement's own 81 kB floor. Neither a no-op nor a full
--       release. What is still held is readable in their source:
--       clearAllModules empties _G.rfsuite.modules and nothing else,
--       while tasks/msp/runtime.lua parks the runtime on a SECOND global
--       and home.lua's init leaves preferences/session/savePreferences
--       on _G.rfsuite -- the last a closure over its whole state.
--    2. MSP CONTENTION. RFSuite brings its own CRSF MSP stack. While
--       open, RfTool's rf2.mspQueue pump is stopped completely (not
--       merely context-pinned as in rf2cfg) so only ONE client is on the
--       wire. Restored on every close path.
--
--  THE BUDGET, and it is the thing that shapes this file. EdgeTX runs
--  standalone scripts in `lsScripts`, whose hook YIELDS on a long call
--  and resumes next cycle (interface.cpp:122) -- no ceiling on the work
--  a page build may do. Widgets live in `lsWidgets` and are KILLED at
--  20000 instructions PER CALL (widgets.cpp:53). RFSuite's pages are
--  written for the first regime and this adapter runs them in the
--  second, so "CPU limit" is a NORMAL event here and not a fault of
--  theirs: their telemetry page raised it on the first attempt ever
--  made. refresh() therefore swallows it and retries rather than
--  closing the tool, and the page then completes across several calls.
--  TWO THINGS CANNOT BE REPAIRED FROM THIS SIDE, and both were tried
--  before being written down.
--    a) A kill landing INSIDE their buildUI: ui/home.lua:1962 clears
--       state.pendingBuildUI BEFORE building, so the request is lost,
--       and buildUI is not exported. The tree stays empty -- a white
--       page -- and only RTN gets out of it, which works because their
--       key handling reads state rather than pixels.
--    b) The kill cannot be fully CONTAINED. widgets.cpp:93 resets
--       instructionsPercent only when a call BEGINS, so once the hook
--       has raised it raises again every ~200 instructions for the rest
--       of that call -- outside any pcall of ours. Measured as one
--       escaped "Error in widget UltiDash widget function: CPU limit"
--       per ~90 s with the telemetry page open, and it survived both
--       counter-measures tried: making this branch an exclusive cycle
--       (so the host does no work afterwards) and cutting the post-catch
--       work to a 9-byte tail compare. Both are kept -- they shorten the
--       window and cost nothing -- but the escape is EdgeTX's to fix, not
--       ours. It is cosmetic: the next call starts with a fresh budget.
--
--  DISARMED-ONLY (UltiDash hard rule: no MSP while armed). Entry is gated
--  in the host toolbox menu; refresh() force-closes on arm. The host
--  exempts tb_rfscfg from its generic close-on-arm so THIS close, with
--  the queue restore and the detach, always runs (rf2cfg pattern).
-- =====================================================================

local M = {}

local RFS = "/SCRIPTS/TOOLS/rfsuite-core/"

-- module-local state: RFSuite is single-instance by nature (one _G.rfsuite),
-- so no per-widget wgt.* namespace is needed here
local home = nil           -- the loaded ui/home.lua table
local is_open = false
local inited = false       -- home.init() ran for THIS load
local present = false      -- sticky once the install has been seen
local notice_install = nil
local next_probe = 0       -- SD probe throttle (1 s)
local load_error = nil     -- sticky: home.lua would not load
local run_error = nil      -- last runtime error; cleared on leaving the view
local shown_notice = nil   -- notice text currently built (change -> rebuild)
local rf2_process = nil    -- unwrapped rf2.mspQueue.processQueue
local rf2_stub = nil       -- our no-op (identity check against double-wrap)
local cpu_hits = 0         -- consecutive "CPU limit" kills inside home.run
-- The experimental gate, taken for THIS open only. The host releases this module on every
-- close (rfscfg.mod = nil), so the flag dies with it and the warning stands again the next
-- time the tile is tapped. That is deliberate: it is a warning, not a preference, and there
-- is no cfg key behind it.
local gate_ok = false

--- How many budget kills in a row before the tool is given up on. A page that overruns ONCE
--- is normal for RFSuite -- their own widget expects it and backs off (widgets/rfsuite/main.lua
--- matches the same string and parks for 0.8-1.2 s) -- and retrying is what lets it finish a
--- build it started. A page that overruns every single time is not going to come up, and
--- looping on it forever would freeze the dashboard instead of reporting.
local CPU_GIVEUP = 12

--- What the gate says. Three measured effects, no disclaimer prose: the CPU-limit stutter
--- (a widget call is KILLED at 20k instructions where a standalone script would be yielded),
--- the blank page a kill inside their buildUI leaves behind, and the 172-281 kB that close()
--- does not get back. The exit route is named because it is the one thing that still works
--- on a page that painted nothing -- their key handling reads state, not pixels.
local GATE_HEAD = "HIGHLY EXPERIMENTAL"
local GATE_BODY = "RFSuite runs inside UltiDash's widget state, which is not what it is "
    .. "written for. Expect CPU-limit stutters, blank pages and higher memory use. "
    .. "RTN always gets you out."

-- ---------------------------------------------------------------------
-- readiness: nil = good to open, otherwise a user-facing notice line
-- ---------------------------------------------------------------------

-- install probe, throttled to 1 Hz (SD access) until it succeeds once.
-- A missing install is the NORMAL state on a card that only has RFTool -- most pilots will
-- never install RFSuite, and this page has to read as "nothing is wrong here" rather than as
-- a fault. Hence a HINT beside the notice: what is missing, where it goes, and that the tile
-- is optional. Without it the page said four words and left the reader to guess whether they
-- had broken something.
local function install_check()
    if present then return nil end
    local now = getTime() or 0
    if now >= next_probe then
        next_probe = now + 100
        if fstat ~= nil and fstat(RFS .. "ui/home.lua") ~= nil then
            present, notice_install = true, nil
        else
            notice_install = "RFSuite is not installed"
        end
    end
    return notice_install
end

-- nil = good to open. Otherwise TWO strings: the headline, and a hint that says what to do
-- about it. The hint may be nil, and is for the states a pilot can act on -- an internal
-- error gets a headline and no advice, because there is none to give.
local function readiness(wgt)
    local c = install_check()
    if c then
        return c, "Optional. RFSuite for EdgeTX is a separate config suite; install it to "
            .. "SCRIPTS/TOOLS/ on this card and this tile opens it. UltiDash needs the RF Tool "
            .. "widget either way -- RFSuite does not replace it."
    end
    if load_error then
        return load_error, "The install under SCRIPTS/TOOLS/rfsuite-core/ looks incomplete. "
            .. "Re-copy it from the RFSuite release for your radio."
    end
    if run_error then
        return "RFSuite error", run_error
    end
    return nil
end

-- ---------------------------------------------------------------------
-- open / close
-- ---------------------------------------------------------------------

-- SEAM require + SEAM home. RFSuite's own widget does exactly these two steps
-- (widgets/rfsuite/main.lua create()): install the memoizer, then load. We do
-- NOT load their SCRIPTS/TOOLS/rfsuite.lua -- it replaces _G.loadScript with a
-- chunk cache that only its own clearChunkCache ever takes back, and that would
-- outlive this page in the shared widget state.
local function load_home()
    local okr = pcall(function()
        local c = loadScript(RFS .. "lib/require.lua", "t")
        if c then c() end
    end)
    if not okr then
        load_error = "RFSuite require won't load"
        return false
    end
    local ok, m = pcall(function() return loadScript(RFS .. "ui/home.lua", "t")() end)
    if not ok or type(m) ~= "table" or type(m.run) ~= "function" then
        load_error = "RFSuite UI won't load"
        return false
    end
    home, inited = m, false
    return true
end

-- Stop RfTool's queue pump outright while we are open. rf2cfg context-PINS the
-- pump (replies must land in its own LVGL context); here the point is different
-- and stronger -- RFSuite talks MSP itself, and two clients pushing CRSF frames
-- on one link is the thing to avoid. Absent rf2 (RFSuite installed instead of
-- RFTool) this is simply a no-op, which is the configuration worth learning about.
local function rf2_pause()
    if type(rf2) ~= "table" or type(rf2.mspQueue) ~= "table" then return end
    if rf2.mspQueue.processQueue ~= rf2_stub then
        rf2_process = rf2.mspQueue.processQueue
        rf2_stub = function() end
        rf2.mspQueue.processQueue = rf2_stub
    end
end

local function rf2_resume()
    if rf2_process and type(rf2) == "table" and type(rf2.mspQueue) == "table" then
        rf2.mspQueue.processQueue = rf2_process
    end
    rf2_process, rf2_stub = nil, nil
end

local function open(wgt)
    if is_open then return true end
    if not home and not load_home() then return false end
    rf2_pause()
    -- pcall'd: an RFSuite framework error here would otherwise crash the widget
    -- Lua state, and a failed open must hand RfTool its pump back
    if not inited and type(home.init) == "function" then
        local ok, err = pcall(home.init)
        if not ok then
            rf2_resume()
            run_error = tostring(err)
            return false
        end
        inited = true
    end
    shown_notice = nil
    is_open = true
    return true
end

-- SEAM msp: home.lua detaches itself only on ITS OWN exit (shouldExit -> 2).
-- An arm-close or a fullscreen exit never reaches that path, so the client
-- would stay registered and the runtime would keep ticking on the next open.
local function msp_detach()
    pcall(function()
        local req = _G.rfsuite and _G.rfsuite.require
        local rt = req and req("tasks/msp/runtime.lua")
        if rt and type(rt.detach) == "function" then rt.detach("tool") end
    end)
end

function M.close(wgt)
    if not is_open then return end
    is_open = false
    msp_detach()
    rf2_resume()
    -- SEAM require: the heap lever. Dropping our own reference is not enough --
    -- _G.rfsuite.modules holds the whole graph and nothing else will ever clear
    -- it in this Lua state. Whether the memory actually returns is what the
    -- spike is for; calling it is free either way.
    pcall(function()
        if _G.rfsuite and type(_G.rfsuite.clearAllModules) == "function" then
            _G.rfsuite.clearAllModules()
        end
    end)
    home, inited = nil, false
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

--- Does the ORIGINAL tool currently own the screen? The host asks before its rebuild: while
--- this is true it must not clear the LVGL tree, because build() below draws nothing and
--- RFSuite repaints only on a state change of its own -- so a host clear would leave the
--- background rectangle standing with the page still open. See ultidash.lua's update().
function M.owns_screen()
    return is_open
end

--- Break a message into lines that fit `w`, MEASURED with lcd.sizeText rather than guessed at
--- a character count: a Lua error is mostly a path, and a path in a proportional font is not
--- n * average. Breaks on separators first and mid-token only when a single token is longer
--- than the box -- which for "/SCRIPTS/TOOLS/rfsuite-core/..." is the normal case.
local function wrap_text(s, w, font)
    local lines, cur = {}, ""
    local function fits(t)
        local tw = lcd.sizeText(t, font)
        return tw <= w
    end
    -- split on separators but KEEP them: a path broken at "/" reads as a path
    for tok in string.gmatch(s, "[^ ]+") do
        local piece = (cur == "") and tok or (cur .. " " .. tok)
        if fits(piece) then
            cur = piece
        else
            if cur ~= "" then lines[#lines + 1] = cur end
            cur = ""
            -- the token itself may be wider than the box (a long path); cut it by measure
            while not fits(tok) and #tok > 1 do
                local n = #tok
                while n > 1 and not fits(string.sub(tok, 1, n)) do n = n - 1 end
                lines[#lines + 1] = string.sub(tok, 1, n)
                tok = string.sub(tok, n + 1)
            end
            cur = tok
        end
        if #lines >= 8 then break end          -- a bounded page, never a scrolling one
    end
    if cur ~= "" and #lines < 8 then lines[#lines + 1] = cur end
    return lines
end

--- THE GATE PAGE, and the reason it exists at all: this is the LAST screen UltiDash owns.
--- From the first pump on, RFSuite runs lvgl.clear() + lvgl.build() inside its own run() and
--- the host must not paint over it (M.owns_screen below), so there is no corner left to put
--- a marker in once the tool is up -- not a header, not a footer, not a colour. The choice
--- was therefore a page in front or nothing at all.
---
--- Layout the way the notice page under it works, with one correction: the block is centred
--- in the BODY, not in the zone. `zone.h` includes EdgeTX's menu header (MENU_HEADER_HEIGHT
--- = LAYOUT_SCALE(45): 45 px on the TX15 and the MK2, 62 on the MK3) while the build table's
--- y is body-relative, so centring on the zone pushes the block down by half a header and
--- can walk the RTN line off the bottom of a 272 px screen.
local function build_gate(wgt, zone)
    local pg = lvgl.page({
        title = "UltiDash",
        subtitle = "RFSuite",
        back = function()
            run_error = nil
            wgt.rfs_close_req = "toolbox"
        end,
    })
    local pad = 20
    local w = zone.w - 2 * pad
    local _, hh = lcd.sizeText("Ag", SMLSIZE)
    -- three words: MIDSIZE fits on every target radio, and the fallback costs one compare
    local hfont = (lcd.sizeText(GATE_HEAD, MIDSIZE) <= w) and MIDSIZE or SMLSIZE
    local _, fh = lcd.sizeText("Ag", hfont)
    local body = wrap_text(GATE_BODY, w, SMLSIZE)
    -- the button honours the theme's element height -- below it EdgeTX draws its own control
    -- larger than the box we gave it, the overlap build_menu_grid's floor exists to prevent
    local btn_h = math.max(lvgl.UI_ELEMENT_HEIGHT or 32, hh + 10)
    local btn_w = math.min(w, 240)
    local block = fh + 10 + #body * hh + 14 + btn_h + 10 + hh
    local body_h = zone.h - ((zone.w >= 800) and 62 or 45)
    local y = math.floor((body_h - block) / 2)
    if y < 8 then y = 8 end
    local items = { { type = "label", x = pad, y = y, w = w, h = fh, font = hfont,
                      align = CENTER, color = COLOR_THEME_WARNING, text = GATE_HEAD } }
    local by = y + fh + 10
    for i = 1, #body do
        items[#items + 1] = { type = "label", x = pad, y = by + (i - 1) * hh, w = w, h = hh,
                              font = SMLSIZE, align = (#body > 1) and LEFT or CENTER,
                              color = COLOR_THEME_SECONDARY1, text = body[i] }
    end
    local ay = by + #body * hh + 14
    -- ONE control on the page, so touch and the encoder see the same thing: a button is
    -- focusable, a label is not, which is what makes this page answer the rotary at all
    -- (the read-only pages had to grow focus stops for exactly that reason).
    items[#items + 1] = { type = "button", x = pad + math.floor((w - btn_w) / 2), y = ay,
                          w = btn_w, h = btn_h, font = SMLSIZE, text = "Open anyway",
                          press = function() gate_ok = true end }
    items[#items + 1] = { type = "label", x = pad, y = ay + btn_h + 10, w = w, h = hh,
                          font = SMLSIZE, align = CENTER, color = COLOR_THEME_SECONDARY1,
                          text = "RTN: back to Toolbox" }
    pg:build(items)
end

--- Host build pass. The original tool paints ITSELF (lvgl.clear + lvgl.build
--- inside run()), so while open we build nothing at all -- unlike rf2cfg there
--- is no re-show slot to poke, because RFSuite rebuilds from its own state on
--- the next run(). Not-open shows a glue notice page (host style).
function M.build(wgt, zone)
    if is_open then return end
    local notice, hint = readiness(wgt)
    -- Readiness FIRST: a card without RFSuite gets the "not installed" notice, not a warning
    -- about a tool that is not there. Installed and the gate not yet taken -> the gate page.
    -- Taken -> nothing, because refresh() opens the tool in the same cycle and RFSuite's own
    -- paint is what replaces the gate; a host page here would only flash.
    if not notice then
        if not gate_ok then build_gate(wgt, zone) end
        return
    end
    shown_notice = notice
    local pg = lvgl.page({
        title = "UltiDash",
        subtitle = "RFSuite",
        back = function()
            run_error = nil
            wgt.rfs_close_req = "toolbox"
        end,
    })
    -- The message is WRAPPED over as many lines as it needs. The first version drew it into
    -- one fixed-height label, which was fine for "RFSuite not installed" and useless for the
    -- thing the page exists for: a Lua error carrying a path overflowed its box and painted
    -- over the hint beneath it, so the one screen that was supposed to say what went wrong
    -- said "RFSuite error: ...TS/TOOLS/rfsuite-" and nothing else. Caught on the simulator
    -- 2026-08-18, on the first error this page ever had to show.
    --
    -- Three blocks, and the middle one is the reason this page exists at all: HEADLINE (what
    -- state we are in), HINT (what to do about it), then the RTN line. A headline stays
    -- MIDSIZE and centred -- it should read as a statement, not as a stack trace -- while
    -- anything needing more than two lines drops to SMLSIZE and goes left-aligned, because a
    -- wrapped path centred line by line is unreadable.
    local pad = 20
    local w = zone.w - 2 * pad
    local font = MIDSIZE
    local lines = wrap_text(notice, w, font)
    if #lines > 2 then
        font = SMLSIZE
        lines = wrap_text(notice, w, font)
    end
    local _, lh = lcd.sizeText("Ag", font)
    local _, hh = lcd.sizeText("Ag", SMLSIZE)
    local hlines = hint and wrap_text(hint, w, SMLSIZE) or {}
    local block = #lines * lh
    local hblock = (#hlines > 0) and (#hlines * hh + 10) or 0
    -- centre the WHOLE thing, hint and RTN line included, and clamp so a long error starts
    -- below the page header rather than under it
    local y = math.floor((zone.h - block - hblock - hh - 12) / 2)
    if y < 8 then y = 8 end
    local items = {}
    for i = 1, #lines do
        items[#items + 1] = { type = "label", x = pad, y = y + (i - 1) * lh, w = w, h = lh,
                              font = font, align = (#lines > 2) and LEFT or CENTER,
                              text = lines[i] }
    end
    for i = 1, #hlines do
        items[#items + 1] = { type = "label", x = pad, y = y + block + 10 + (i - 1) * hh,
                              w = w, h = hh, font = SMLSIZE,
                              align = (#hlines > 1) and LEFT or CENTER,
                              color = COLOR_THEME_SECONDARY1, text = hlines[i] }
    end
    items[#items + 1] = { type = "label", x = pad, y = y + block + hblock + 8, w = w, h = hh,
                          font = SMLSIZE, align = CENTER, color = COLOR_THEME_SECONDARY1,
                          text = "RTN: back to Toolbox" }
    pg:build(items)
end

--- Host refresh pass: arm force-close, readiness/notice handling, then the
--- original tool. Key handling stays 1:1 in RFSuite (it owns RTN down to its
--- own main menu); the ONLY remapped semantic is its exit code 2, which
--- returns to the toolbox instead of leaving the script. wgt.rfs_close_req
--- ("toolbox"|"dashboard") tells the host where to go; wgt.rfs_dirty requests
--- a host rebuild (notice page).
---
--- NOTE, and it is the open risk of the spike: there is no host-side escape
--- hatch. If RFSuite parks on a screen that does not process RTN (rf2cfg hit
--- exactly that with the RF2 "connecting" screen, which is why IT gates on a
--- connected FC), the way out is EdgeTX's own fullscreen exit -- which runs
--- close_tool_page and therefore M.cleanup, so nothing is left installed.
function M.refresh(wgt, event, touch_state)
    -- hard rule: no MSP while armed. Entry is gated by the toolbox menu; this
    -- covers arming while open (detach + queue restore run, then straight back
    -- to the flight view).
    if is_open and wgt.armed_now then
        M.close(wgt)
        wgt.rfs_close_req = "dashboard"
        return
    end
    if not is_open then
        if wgt.armed_now then
            run_error = nil
            wgt.rfs_close_req = "dashboard"
            return
        end
        if exit_evt(event) then
            run_error = nil
            wgt.rfs_close_req = "toolbox"
            return
        end
        local n = readiness(wgt)
        if n then
            if n ~= shown_notice then wgt.rfs_dirty = true end
            return
        end
        -- The gate page is up and owns the screen until its button is pressed. Nothing to
        -- pump: the press closure flips gate_ok, and the NEXT cycle falls through to open()
        -- below, which pumps the tool straight away -- so the gate is replaced by RFSuite's
        -- own paint and never by a host rebuild (which is what leaves a white screen here).
        if not gate_ok then return end
        if not open(wgt) then
            wgt.rfs_dirty = true
            return
        end
        -- fall through: pump right away so the tool paints this tick
    end
    local ok, result = pcall(home.run, event, touch_state)
    if not ok then
        -- "CPU limit" is NOT a tool error and must not close the page. It is EdgeTX killing
        -- the call at ~20k instructions, and RFSuite hits it as a matter of course: its
        -- telemetry page raised it on the FIRST attempt this project ever made
        -- (page.lua:329, simulator 2026-08-18), and their own widget is written around the
        -- same string. Two things follow.
        --
        -- The page is HALF-PAINTED when this happens, and THE WHITE SCREEN IS THIS. RFSuite's
        -- builders do lvgl.clear() and then lvgl.build(); a kill in between leaves an empty
        -- tree. That is the radio report of 2026-08-18 -- "kurz den home screen und dann
        -- weiss" is the home screen painting, a page build being killed, and nothing painting
        -- after it.
        --
        -- AND WE CANNOT REPAINT IT FOR THEM. ui/home.lua:1962 sets state.pendingBuildUI =
        -- false BEFORE calling M.buildUI(), so a kill inside the build loses the request and
        -- their next run() has no reason to try again; buildUI is not exported either. The
        -- host must not repaint over it (see ultidash.lua's update(): while the tool owns the
        -- screen a host clear is exactly what must NOT happen), so nothing here asks for a
        -- host rebuild. What the user still has is RTN: their key handling works off state
        -- rather than pixels, so a blank page is escapable even when it cannot be redrawn.
        --
        -- Retrying is still right for the kills that land OUTSIDE a build -- the common case,
        -- since most of their run() is polling -- and it is what turns a stutter into a
        -- stutter instead of into "the tool quit with an error", which is what the first
        -- version of this file did. No timed back-off like theirs (0.8-1.2 s): this adapter is
        -- pumped only from UltiDash's refresh, so returning already yields the call, and a
        -- sleep would just make a blank last longer.
        --
        -- The counter is the honesty half: a page that overruns EVERY time will never come up,
        -- and retrying it forever would freeze the dashboard rather than report anything.
        -- The test is a 9-byte TAIL compare and not a search, and the reason is the budget
        -- itself. EdgeTX resets `instructionsPercent` only at the START of a widget call
        -- (widgets.cpp:93), so once the hook has raised, it raises again every ~200
        -- instructions for the REST of this call -- outside any pcall of ours. Everything
        -- done between catching and returning is therefore exposure, and a
        -- string.find over a ~60-character path was most of it. Measured as the thing that
        -- escapes: "Error in widget UltiDash widget function: CPU limit" in the simulator
        -- trace. This does not eliminate the escape -- nothing in Lua can, the counter is
        -- already over -- it shortens the window.
        local msg = (type(result) == "string") and result or tostring(result)
        if string.sub(msg, -9) == "CPU limit" then
            cpu_hits = cpu_hits + 1
            if cpu_hits < CPU_GIVEUP then return end
            M.close(wgt)
            run_error = "page over the CPU budget (" .. cpu_hits .. "x): " .. msg
            cpu_hits = 0
            wgt.rfs_dirty = true
            return
        end
        -- contain a tool/page error: restore the queue + detach, then surface
        -- the error on the glue notice page (RTN leaves, reopen retries)
        M.close(wgt)
        run_error = tostring(result)
        wgt.rfs_dirty = true
        return
    end
    cpu_hits = 0                          -- a call that returned clears the streak
    if result == 2 then      -- original exit semantics
        M.close(wgt)
        wgt.rfs_close_req = "toolbox"
    end
end

return M
