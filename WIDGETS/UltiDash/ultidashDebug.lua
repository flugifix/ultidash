-- =====================================================================================
-- UltiDash file debug logger.
-- =====================================================================================
-- Optional diagnostics: writes rotating session files to /WIDGETS/UltiDash/logs/ on the
-- SD card so a runtime problem can be inspected afterwards (read them from the PC at
-- E:\WIDGETS\UltiDash\logs\debug_NN.log). The logs/ subdir keeps the widget root tidy;
-- it SHIPS with the widget (folder in the repo). On first enable the widget only
-- detects it and moves old root-level debug files over; if it's missing, logging
-- falls back to the widget root exactly as before.
-- Driven by the per-model "Debug log" setting (DebugLog) — OFF by default. When off the
-- cost is ~zero: every entry point early-returns on the ENABLED flag and nothing touches
-- the SD or grows the heap.
--
-- COST DISCIPLINE: file IO every frame would itself cause lag. So log() only appends to
-- a RAM ring buffer (cheap); flush() writes INCREMENTALLY — only the lines added since
-- the last flush are APPENDED ("a") to the session file, a `flushed` watermark tracks
-- what is already on SD. The session file is created fresh ("w") in start_session (the
-- rotated slot may hold an old session). Because appends are tiny (a handful of lines,
-- not the whole ring), flushing now also runs WHILE ARMED — at the slower ARMED_FLUSH_CS
-- cadence — so a crash / power loss in flight loses at most the last few seconds instead
-- of the whole flight. The ring is CAPPED at MAX_LINES (bounds heap); the per-session
-- FILE is capped at MAX_FILE_LINES (bounds SD growth on very long sessions — a marker
-- line is written when the cap is hit, then appends stop for that session).
-- =====================================================================================

local M = {}

local ROOT         = "/WIDGETS/UltiDash/"
local DIR          = ROOT                     -- resolved on first enable: logs/ subdir
local SEQ_NAME     = "debug_seq.txt"
local SEQ_PATH     = DIR .. SEQ_NAME          -- persisted round-robin session counter
local MAX_SESSIONS = 20           -- keep this many session files (debug_01..debug_20.log)
local FLUSH_CS     = 300          -- disarmed: append to SD at most every 3 s (centisec)
local ARMED_FLUSH_CS = 1000       -- armed: slower cadence (10 s) — small append writes,
                                  -- but keep the in-flight SD touch rate conservative
local FORCE_MIN_CS = 50           -- even a FORCED flush appends no more than every
                                  -- 0.5 s. handle_telemetry_state_change force-flushes
                                  -- on every state transition; a dying backup buffer
                                  -- bounces the link many times/second — the rate limit
                                  -- keeps that from becoming an SD-write storm.
local MAX_LINES    = 500          -- ring-buffer cap (bounds heap)
local MAX_FILE_LINES = 5000       -- per-session file cap (~450 kB worst case)
local PERF_CS      = 100          -- emit a PERF snapshot at most every 1 s

local ENABLED    = false
local log_path   = DIR .. "debug.log"   -- set per session in set_enabled() (rotation)
local lines      = {}
local last_flush = -100000
local last_perf  = -100000
local dirty      = false
local flushed    = 0              -- watermark: lines[1..flushed] are already on SD
local dropped    = 0              -- unflushed lines lost to ring overflow (marker on next flush)
local file_lines = 0              -- lines written to the session file (MAX_FILE_LINES cap)

local function now_ms()
    local t = getTime() or 0     -- EdgeTX ticks are centiseconds
    return t * 10
end

-- Queue a line. Cheap: table append + ring trim, no IO.
function M.log(tag, msg)
    if not ENABLED then return end
    lines[#lines + 1] = string.format("[%dms][%s] %s", now_ms(), tostring(tag or "UD"), tostring(msg or ""))
    if #lines > MAX_LINES then
        table.remove(lines, 1)
        -- keep the SD watermark aligned with the shifted ring; trimming a line that
        -- never made it to SD is real data loss -> counted, marker on the next flush
        if flushed > 0 then flushed = flushed - 1 else dropped = dropped + 1 end
    end
    dirty = true
end

-- printf-style convenience (same idea as ultidash_functions.log).
function M.logf(tag, fmt, ...)
    if not ENABLED then return end
    local ok, s = pcall(string.format, fmt, ...)
    M.log(tag, ok and s or fmt)
end

-- Write NEW lines (past the `flushed` watermark) to SD, appended ("a") to the session
-- file. Throttled: FORCE_MIN_CS when forced, ARMED_FLUSH_CS while armed (in-flight
-- flushing — small appends, conservative cadence), else FLUSH_CS. The per-session file
-- cap (MAX_FILE_LINES) stops appends once hit (one marker line, then silence).
function M.flush(force, armed)
    if not ENABLED or not dirty then return end
    if file_lines >= MAX_FILE_LINES then dirty = false; return end
    local t = getTime() or 0
    local min_gap = force and FORCE_MIN_CS or (armed and ARMED_FLUSH_CS or FLUSH_CS)
    if (t - last_flush) < min_gap then return end
    last_flush = t
    pcall(function()
        local f = io.open(log_path, "a")
        if not f then return end
        if dropped > 0 then
            io.write(f, string.format("[---] %d line(s) lost (ring overflow before flush)", dropped))
            io.write(f, "\n")
            file_lines = file_lines + 1
            dropped = 0
        end
        for i = flushed + 1, #lines do
            io.write(f, lines[i])
            io.write(f, "\n")
            file_lines = file_lines + 1
            if file_lines >= MAX_FILE_LINES then
                io.write(f, "[---] session file cap reached, logging to SD stopped")
                io.write(f, "\n")
                flushed = i
                io.close(f)
                dirty = false
                return
            end
        end
        io.close(f)
        flushed = #lines
        dirty = false
    end)
end

-- Resolve the log directory ONCE (first enable, so the off-by-default path costs
-- nothing): the logs/ folder ships with the widget, so we just detect it (fstat) and
-- move old root-level session files + the seq counter into it. Everything pcall'd;
-- when the folder is missing we keep logging to the widget root exactly as before.
local dir_resolved = false
local function resolve_dir()
    if dir_resolved then return end
    dir_resolved = true
    pcall(function()
        if fstat(ROOT .. "logs") ~= nil then    -- ships with the widget; no mkdir
            DIR = ROOT .. "logs/"
            SEQ_PATH = DIR .. SEQ_NAME
        end
    end)
    if DIR ~= ROOT then
        pcall(function()                        -- one-time sweep, best-effort
            -- COLLECT first, then rename (moving files out of ROOT while iterating
            -- dir(ROOT) can make FatFS f_readdir skip entries)
            local move = {}
            for fname in dir(ROOT) do
                if fname == SEQ_NAME or fname == "debug.log"
                    or string.match(fname, "^debug_%d+%.log$") ~= nil then
                    move[#move + 1] = fname
                end
            end
            for i = 1, #move do
                local fname = move[i]
                if fstat(DIR .. fname) == nil then
                    rename(ROOT .. fname, DIR .. fname)
                end
            end
        end)
    end
end

-- Round-robin session rotation: each enable picks the next slot debug_NN.log (1..N),
-- so a new logging session no longer overwrites the previous one — the last
-- MAX_SESSIONS sessions are kept. A tiny persisted counter (debug_seq.txt) drives it
-- (cheaper than a directory scan). The session header carries the global sequence
-- number + timestamp so the newest file is identifiable.
local function read_seq()
    local n = 0
    pcall(function()
        local f = io.open(SEQ_PATH, "r")
        if not f then return end
        local s = io.read(f, 16)
        io.close(f)
        local v = s and tonumber(string.match(s, "%d+"))
        if v then n = v end
    end)
    return n
end

local function write_seq(n)
    pcall(function()
        local f = io.open(SEQ_PATH, "w")
        if not f then return end
        io.write(f, tostring(n))
        io.close(f)
    end)
end

local function start_session()
    local seq = read_seq() + 1
    local slot = ((seq - 1) % MAX_SESSIONS) + 1
    log_path = string.format("%sdebug_%02d.log", DIR, slot)
    write_seq(seq)
    lines = {}
    flushed, dropped, file_lines = 0, 0, 0
    last_flush, last_perf, dirty = -100000, -100000, false
    -- the rotated slot may hold an OLD session — truncate it now ("w"), because
    -- flush() only ever appends from here on
    pcall(function()
        local f = io.open(log_path, "w")
        if f then io.close(f) end
    end)
    local t = getDateTime()
    local stamp = t and string.format("%04d-%02d-%02d %02d:%02d:%02d",
        t.year, t.mon, t.day, t.hour, t.min, t.sec) or "?"
    M.log("INIT", string.format("session #%d  %s  (slot %d/%d, dir %s)",
        seq, stamp, slot, MAX_SESSIONS, DIR))
    M.flush(true)
end

-- Turn logging on/off at runtime (driven by the DebugLog option). Starting fresh on
-- enable keeps each troubleshooting session self-contained.
-- `keep` (optional) sets how many session files to retain (the DebugKeep option);
-- applied even when the enabled state doesn't change, so it's current for the next
-- session start. Clamped to >= 1.
function M.set_enabled(on, keep)
    if type(keep) == "number" and keep >= 1 then MAX_SESSIONS = math.floor(keep) end
    on = on and true or false
    if on == ENABLED then return end
    ENABLED = on
    if on then
        resolve_dir()
        start_session()
    end
end

function M.is_enabled() return ENABLED end

-- One-line perf snapshot (rate-limited). Reads the dev metrics that ultidash.lua's
-- refresh() already maintains (dbg_hz / dbg_lua_kb / dbg_pass_cs).
function M.perf(wgt)
    if not ENABLED or not wgt then return end
    local t = getTime() or 0
    if (t - last_perf) < PERF_CS then return end
    last_perf = t
    local v = wgt.values or {}
    M.logf("PERF", "hz=%s heap=%skB pass=%sms state=%s armed=%s pl=%s view=%s menu=%s detail=%s vol=%s",
        tostring(wgt.dbg_hz), tostring(wgt.dbg_lua_kb),
        tostring(wgt.dbg_pass_cs and (wgt.dbg_pass_cs * 10) or nil),
        tostring(v.rf_connection_state), tostring(wgt.armed_now), tostring(wgt.power_lost),
        tostring(wgt.view and wgt.view.current), tostring(wgt.menu_view), tostring(wgt.detail_view),
        tostring(wgt.vol_gvar_last))
end

-- Convenience for the 5 Hz pass: snapshot perf + flush. Armed flushes run at the slower
-- ARMED_FLUSH_CS cadence (small incremental appends), so an in-flight crash / power
-- loss loses at most the last few seconds of log instead of the whole flight.
function M.tick(wgt)
    if not ENABLED then return end
    M.perf(wgt)
    M.flush(false, wgt and wgt.armed_now)
end

return M
