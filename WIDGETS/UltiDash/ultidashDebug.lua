-- =====================================================================================
-- UltiDash file debug logger.
-- =====================================================================================
-- Optional diagnostics: writes /WIDGETS/UltiDash/debug.log on the SD card so a runtime
-- problem can be inspected afterwards (read it from the PC at E:\WIDGETS\UltiDash\debug.log).
-- Driven by the per-model "Debug log" setting (DebugLog) — OFF by default. When off the
-- cost is ~zero: every entry point early-returns on the ENABLED flag and nothing touches
-- the SD or grows the heap.
--
-- COST DISCIPLINE: file IO every frame would itself cause lag. So log() only appends to a
-- RAM ring buffer (cheap); the whole buffer is rewritten to SD at most every FLUSH_CS
-- ("w" only, EdgeTX-io-safe, like ultidashSettings). The ring is CAPPED at MAX_LINES, so
-- the heap/file are bounded no matter how long it runs — a very long armed flight simply
-- keeps the most recent MAX_LINES (older lines roll off). To avoid an in-flight SD hitch,
-- tick() does NOT flush while armed; the buffer is flushed on disarm/disconnect instead.
-- =====================================================================================

local M = {}

local DIR          = "/WIDGETS/UltiDash/"
local SEQ_PATH     = DIR .. "debug_seq.txt"   -- persisted round-robin session counter
local MAX_SESSIONS = 20           -- keep this many session files (debug_01..debug_20.log)
local FLUSH_CS     = 300          -- write to SD at most every 3 s (centiseconds)
local MAX_LINES    = 500          -- ring-buffer cap (bounds heap + per-file size)
local PERF_CS      = 100          -- emit a PERF snapshot at most every 1 s

local ENABLED    = false
local log_path   = DIR .. "debug.log"   -- set per session in set_enabled() (rotation)
local lines      = {}
local last_flush = -100000
local last_perf  = -100000
local dirty      = false

local function now_ms()
    local t = getTime() or 0     -- EdgeTX ticks are centiseconds
    return t * 10
end

-- Queue a line. Cheap: table append + ring trim, no IO.
function M.log(tag, msg)
    if not ENABLED then return end
    lines[#lines + 1] = string.format("[%dms][%s] %s", now_ms(), tostring(tag or "UD"), tostring(msg or ""))
    if #lines > MAX_LINES then table.remove(lines, 1) end
    dirty = true
end

-- printf-style convenience (same idea as ultidash_functions.log).
function M.logf(tag, fmt, ...)
    if not ENABLED then return end
    local ok, s = pcall(string.format, fmt, ...)
    M.log(tag, ok and s or fmt)
end

-- Write the buffer to SD. Throttled unless `force`. Uses ONLY "w" (EdgeTX-io-safe).
function M.flush(force)
    if not ENABLED or not dirty then return end
    local t = getTime() or 0
    if not force and (t - last_flush) < FLUSH_CS then return end
    last_flush = t
    pcall(function()
        local f = io.open(log_path, "w")
        if not f then return end
        for i = 1, #lines do
            io.write(f, lines[i])
            io.write(f, "\n")
        end
        io.close(f)
        dirty = false
    end)
end

-- Round-robin session rotation: each enable picks the next slot debug_NN.log (1..N),
-- so a new logging session no longer overwrites the previous one — the last
-- MAX_SESSIONS sessions are kept. A tiny persisted counter (debug_seq.txt) drives it;
-- no directory listing needed (EdgeTX widgets have none). The session header carries
-- the global sequence number + timestamp so the newest file is identifiable.
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
    last_flush, last_perf, dirty = -100000, -100000, false
    local t = getDateTime()
    local stamp = t and string.format("%04d-%02d-%02d %02d:%02d:%02d",
        t.year, t.mon, t.day, t.hour, t.min, t.sec) or "?"
    M.log("INIT", string.format("session #%d  %s  (slot %d/%d)", seq, stamp, slot, MAX_SESSIONS))
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
    if on then start_session() end
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
    M.logf("PERF", "hz=%s heap=%skB pass=%sms state=%s armed=%s view=%s menu=%s detail=%s",
        tostring(wgt.dbg_hz), tostring(wgt.dbg_lua_kb),
        tostring(wgt.dbg_pass_cs and (wgt.dbg_pass_cs * 10) or nil),
        tostring(v.rf_connection_state), tostring(wgt.armed_now),
        tostring(wgt.view and wgt.view.current), tostring(wgt.menu_view), tostring(wgt.detail_view))
end

-- Convenience for the 5 Hz pass: snapshot perf + flush (flush skipped while armed to
-- avoid an in-flight SD hitch; the disarm/disconnect transition force-flushes instead).
function M.tick(wgt)
    if not ENABLED then return end
    M.perf(wgt)
    if not (wgt and wgt.armed_now) then M.flush(false) end
end

return M
