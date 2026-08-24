-- =====================================================================
--  UltiDash: ELRS TX module configuration  (CRSF parameter client)
--
--  Reads the SETTINGS of the ExpressLRS transmitter module -- packet rate,
--  telemetry ratio, antenna mode, ... -- which no telemetry sensor carries.
--  This is the same conversation the stock elrs.lua tool script has:
--
--      push 0x28 {0x00, 0xEA}                     -- broadcast device ping
--      pop  0x29 -> name, serial, versions, fieldCnt
--      push 0x2C {devId, handsetId, fieldId, 0}   -- read one parameter
--      pop  0x2B -> parent, type, name, value     -- CHUNKED, reassembled here
--
--  READ ONLY. 0x2D (parameter write) is never sent -- rule 3, and nothing on
--  this page needs it.
--
--  WHY IT IS PACED THE WAY IT IS. crossfireTelemetryPush() fills the ONE
--  global outputTelemetryBuffer, and EdgeTX's setupPulsesCrossfire() sends
--  that frame INSTEAD of the channels frame for its slot (2.12.0,
--  pulses/crossfire.cpp:141-146). So every request costs one RC channel
--  update. elrs.lua paces a local device at 50 ms because a human is waiting;
--  we are not, so we issue AT MOST ONE REQUEST PER BACKGROUND PASS (5 Hz) --
--  0.5 % of the frames at 150 Hz, for the few seconds a scan lasts. The arming
--  gate on top of that is the caller's (see ultidashRf.M.background).
--
--  The RECEIVE side needs no such care: since EdgeTX 2.11.0 a colour radio
--  gives every Lua script manager its OWN telemetry queue and copies each
--  frame into all of them (telemetry/telemetry.cpp:459-487), so popping here
--  takes nothing away from the RFTool's MSP client. Only frames EdgeTX does
--  not decode itself reach that queue at all (the `default:` branch of
--  telemetry/crossfire.cpp), i.e. no link-stat or sensor traffic -- which is
--  why POP_CAP can be this small.
-- =====================================================================

local M = {}

-- ---- CRSF addresses and commands -------------------------------------------
local ADDR_MODULE   = 0xEE   -- CRSF_ADDRESS_CRSF_TRANSMITTER
local ADDR_HANDSET  = 0xEA   -- CRSF_ADDRESS_RADIO_TRANSMITTER
local ADDR_ELRS_LUA = 0xEF   -- what an ELRS TX expects its config client to be
local CMD_PING      = 0x28
local CMD_INFO      = 0x29
local CMD_ENTRY     = 0x2B
local CMD_READ      = 0x2C

-- ---- pacing ----------------------------------------------------------------
local REQ_TIMEOUT_CS   = 50     -- 0.5 s per request, elrs.lua's local-device value
local SCAN_DEADLINE_CS = 2000   -- 20 s for the whole scan, then give up
local MAX_RETRY        = 3
local POP_CAP          = 4      -- frames handled per pass
local FIELD_CAP        = 64     -- never walk past this, whatever fieldCnt claims
local BUF_CAP          = 320    -- longest field payload we accept (Packet Rate ~260)

-- ---- what we keep ----------------------------------------------------------
-- Field IDs are NOT stable: registration is conditional on hardware and firmware
-- options (isDualRadio() gates Antenna Mode, is_airport drops Switch Mode, the
-- VTX/backpack folders come and go), so the same firmware numbers two modules
-- differently. Matched by NAME, which is what the 0x2B reply carries.
local WANTED = {
    ["RF Band"]      = "elrs_cfg_band",     -- 4.x, dual-band LR1121 only
    ["Packet Rate"]  = "elrs_cfg_rate",
    ["Telem Ratio"]  = "elrs_cfg_tlm",
    ["Switch Mode"]  = "elrs_cfg_switch",
    ["Antenna Mode"] = "elrs_cfg_ant",      -- Gemini-capable modules only
    ["Link Mode"]    = "elrs_cfg_link",     -- 3.5.0+
    ["Model Match"]  = "elrs_cfg_mm",
    ["Max Power"]    = "elrs_cfg_pwr",
    ["Dynamic"]      = "elrs_cfg_dyn",
}
local WANTED_N = 9
-- The early-exit threshold leaves RF Band out: only a dual-band LR1121 module
-- registers it, and in every firmware that has it it sits at the head of the
-- list (before Packet Rate) -- so by the time the other eight are in, it has
-- either been kept or does not exist. Counting it (the first 0.8.0 cut did)
-- meant the exit could NEVER fire on a 2.4 GHz module: every scan walked all
-- fields, and the 2026-08-16 degraded session ran into the 20 s deadline.
local REQ_N = 8

-- Every key this module puts into wgt.values, in ONE list -- same contract as
-- ultidashRf's RF_SESSION_KEYS and for the same reason: a key added to a read
-- and forgotten in the clear survives into a session it does not describe.
-- These describe the RADIO's module, not the flight controller, so they are
-- cleared when the MODULE's answer becomes unknown, not on an FC disconnect.
M.KEYS = {
    "elrs_cfg_state", "elrs_cfg_name", "elrs_cfg_ver", "elrs_cfg_commit",
    "elrs_cfg_band", "elrs_cfg_rate", "elrs_cfg_tlm", "elrs_cfg_switch",
    "elrs_cfg_ant", "elrs_cfg_link", "elrs_cfg_mm", "elrs_cfg_pwr",
    "elrs_cfg_dyn",
}

-- ---- optional file logger (getter, as in ultidashRf) ------------------------
local dbg_get = nil
local function dbg_log(fmt, ...)
    if dbg_get == nil then return end
    local d = dbg_get()
    if d == nil then return end
    d.logf("ELRS", fmt, ...)
end

-- ---- byte helpers -----------------------------------------------------------
--- Read a zero-terminated string out of a byte table. Returns the string and
--- the index one past the terminator.
local function rd_str(b, i)
    local t, n = {}, 0
    local c = b[i]
    while c ~= nil and c ~= 0 do
        n = n + 1
        t[n] = string.char(c)
        i = i + 1
        c = b[i]
    end
    return table.concat(t), i + 1
end

--- Index of the zero terminator of the string starting at i.
local function str_end(b, i)
    while b[i] ~= nil and b[i] ~= 0 do i = i + 1 end
    return i
end

--- Pull option number `idx` (0-based) out of a ';'-separated option list.
--- Deliberately NOT a split into a table: the Packet Rate list is ~260 bytes
--- and 20 entries, and we want exactly one of them.
local function opt_at(b, i, idx)
    local cur, t, n = 0, {}, 0
    local c = b[i]
    while c ~= nil and c ~= 0 do
        if c == 59 then                    -- ';'
            if cur == idx then break end
            cur = cur + 1
        elseif cur == idx then
            n = n + 1
            t[n] = string.char(c)
        end
        i = i + 1
        c = b[i]
    end
    if cur ~= idx then return nil end
    return table.concat(t)
end

-- ---- state ------------------------------------------------------------------
local function ensure(wgt)
    wgt.elrs_cfg = wgt.elrs_cfg or {
        phase = nil,        -- nil = idle | "ping" | "walk"
        dev_id = nil,       -- device that answered the ping
        handset = ADDR_HANDSET,
        fields = nil,       -- fieldCnt from the 0x29 reply
        id = 0,             -- field being read
        chunk = 0,          -- WHICH chunk of it: the module answers the index we ask for
        found = 0,          -- how many WANTED names are in
        req_found = 0,      -- ... of which REQUIRED (RF Band excluded -- it counts
                            -- toward found for the log, never toward the early
                            -- exit: on a dual-band module it fills the counter
                            -- early and the exit would skip the LAST required
                            -- field, which is what the first cut of case 5 caught
        buf = nil,          -- chunk accumulator
        expect = nil,       -- chunksRemaining we expect next
        sent_at = nil,      -- timestamp of the outstanding request
        retry = 0,
        started = nil,      -- scan start, for SCAN_DEADLINE_CS
    }
    return wgt.elrs_cfg
end

local function set(wgt, key, val)
    if wgt.values then wgt.values[key] = val end
end

local function finish(wgt, st, state_text)
    st.phase = nil
    st.buf, st.expect, st.sent_at = nil, nil, nil
    set(wgt, "elrs_cfg_state", state_text)
    wgt.rf_data_dirty = true
    dbg_log("scan end: %s (%d/%d fields kept)", state_text, st.found, WANTED_N)
end

--- Drop everything a previous scan learned. Called before a new scan so a page
--- opened mid-scan never mixes two modules' answers.
local function wipe(wgt)
    if not wgt.values then return end
    for i = 1, #M.KEYS do wgt.values[M.KEYS[i]] = nil end
end

-- ---- wire -------------------------------------------------------------------
--- Empty our own queue. Between two scans nobody pops it, so it holds whatever
--- exotic frames arrived meanwhile (MSP replies are the realistic case) and the
--- first reply of a new scan would be read behind them.
local function flush(cap)
    local n = 0
    while n < cap do
        local cmd = crossfireTelemetryPop()
        if cmd == nil then return true end
        n = n + 1
    end
    return false
end

local function send_ping(st)
    return crossfireTelemetryPush(CMD_PING, { 0x00, ADDR_HANDSET }) ~= false
end

--- A long field arrives in pieces and each piece is REQUESTED: the 4th byte is the
--- chunk index, and the module answers exactly that one. Waiting for the rest to
--- arrive by itself is the bug the decoder's own test caught -- nothing follows.
local function send_read(st)
    return crossfireTelemetryPush(CMD_READ,
        { st.dev_id, st.handset, st.id, st.chunk }) ~= false
end

-- ---- frame handlers ---------------------------------------------------------
--- 0x29 device info: [dest, origin, name..0, serial u32, hw u32, sw u32, fieldCnt]
local function on_info(wgt, st, d)
    if st.phase ~= "ping" then return end
    local id = d[2]
    if id ~= ADDR_MODULE then return end          -- only the TX module interests us
    local name, off = rd_str(d, 3)
    -- serial number "ELRS" is how elrs.lua recognises an ELRS device; it also
    -- decides the client address the module expects (0xEF, not 0xEA).
    local serial = 0
    for k = 0, 3 do serial = serial * 256 + (d[off + k] or 0) end
    local cnt = d[off + 12]
    if type(cnt) ~= "number" or cnt < 1 then return end

    st.dev_id  = id
    st.handset = (serial == 0x454C5253) and ADDR_ELRS_LUA or ADDR_HANDSET
    st.fields  = (cnt > FIELD_CAP) and FIELD_CAP or cnt
    st.phase   = "walk"
    st.id, st.chunk, st.retry, st.sent_at = 1, 0, 0, nil
    set(wgt, "elrs_cfg_name", name)
    wgt.rf_data_dirty = true
    dbg_log("module '%s' fields=%d handset=0x%02X", name, st.fields, st.handset)
end

--- 0x2B parameter entry: [dest, origin, fieldId, chunksRemaining, payload...]
--- payload = parent u8, type u8 (bit 7 = hidden), name..0, then type-specific.
local function on_entry(wgt, st, d)
    if st.phase ~= "walk" or d[2] ~= st.dev_id or d[3] ~= st.id then return end
    local remain = d[4]
    if type(remain) ~= "number" then return end
    if st.buf and st.expect ~= nil and remain ~= st.expect then
        -- lost or duplicated a chunk: start the field over rather than splice a
        -- payload out of two different reads
        st.buf, st.expect, st.chunk = nil, nil, 0
        return
    end

    local b = st.buf or {}
    local n = #b
    for i = 5, #d do
        n = n + 1
        if n > BUF_CAP then                     -- a field we would not keep anyway
            st.buf, st.expect = nil, nil
            st.id, st.chunk = st.id + 1, 0
            st.sent_at = nil
            return
        end
        b[n] = d[i]
    end
    st.buf = b

    if remain > 0 then
        -- Skip the REST of a field we will not keep: the name rides in the first
        -- chunk, and every further chunk is one more displaced RC frame for a
        -- payload the whitelist would drop anyway. Never for the last field (the
        -- version string is kept), and only once the name's terminator has
        -- arrived -- a name split across chunks (never seen: names are ~20
        -- bytes, a chunk ~56) keeps walking rather than guessing.
        if st.id < st.fields then
            local e = str_end(b, 3)
            if b[e] == 0 and WANTED[(rd_str(b, 3))] == nil then
                st.buf, st.expect, st.sent_at = nil, nil, nil
                st.id, st.chunk = st.id + 1, 0
                return
            end
        end
        -- ask for the next piece on the next pass: sent_at nil is "nothing
        -- outstanding", which is what makes poll() send rather than wait out the
        -- timeout. Not a retry -- st.retry is untouched.
        st.expect = remain - 1
        st.chunk = st.chunk + 1
        st.sent_at = nil
        return
    end

    -- complete
    st.buf, st.expect, st.sent_at = nil, nil, nil
    st.chunk = 0
    local ftype = (b[2] or 0) % 128             -- bit 7 = hidden, not a type bit
    local name, off = rd_str(b, 3)
    local key = WANTED[name]
    if key ~= nil then
        local text
        if ftype == 9 then                      -- TEXT SELECTION: options, then value
            local e = str_end(b, off)
            text = opt_at(b, off, b[e + 1] or 0)
        elseif ftype == 12 or ftype == 10 then  -- INFO / STRING
            text = rd_str(b, off)
        end
        if text ~= nil and text ~= "" then
            set(wgt, key, text)
            st.found = st.found + 1
            if key ~= "elrs_cfg_band" then st.req_found = st.req_found + 1 end
            wgt.rf_data_dirty = true
            dbg_log("%s = %s", name, text)
        end
    elseif ftype == 12 and st.id == st.fields then
        -- The ELRS version string is registered LAST in both 3.x and 4.x, so it
        -- is the field with the highest id. Type-checked rather than assumed:
        -- an id that turns out not to be an INFO field is simply not taken.
        --
        -- THE VERSION IS THE FIELD'S *NAME*, NOT ITS VALUE, and reading the value
        -- was how this page came to show a bare commit hash where a version belongs
        -- (reported by the user 2026-08-19). ExpressLRS registers it as
        --     static stringParameter luaELRSversion = { {version_domain, CRSF_INFO}, commit };
        -- (`src/lib/tx-crsf/TXModuleParameters.cpp`) -- so the NAME is
        -- `version_domain`, i.e. the version plus the frequency domain, built by
        -- `addDomainInfo` into at most 26 characters ("4.1.0 ISM2G4", "4.1.0
        -- EU868/ISM2G4"), and the VALUE is `LATEST_COMMIT`, a bare short hash. Both
        -- are worth keeping -- the version for the pilot, the commit for a bug
        -- report -- so they become two rows rather than one concatenation that would
        -- not fit the value column on a 480 px zone.
        local ver = name                          -- `name` was already decoded above
        local commit = rd_str(b, off)
        if ver ~= nil and ver ~= "" then set(wgt, "elrs_cfg_ver", ver) end
        if commit ~= nil and commit ~= "" then set(wgt, "elrs_cfg_commit", commit) end
        wgt.rf_data_dirty = true
        -- logged like the WANTED fields: the 2026-08-16 radio round could not say
        -- whether "Firmware -" was a decode failure or the scan deadline, because
        -- this was the one kept value without a line
        dbg_log("firmware = %s (commit %s)", tostring(ver), tostring(commit))
    end

    st.id, st.retry = st.id + 1, 0
    -- Early exit, in two shapes. Everything we display sits in the first handful
    -- of registered parameters -- EXCEPT the version string, which is the last
    -- one. So once the required names are in, jump STRAIGHT to the last field
    -- instead of walking the middle (every skipped field is an RC frame kept).
    -- The first cut finished here instead of jumping, which made early exit and
    -- the firmware line mutually exclusive by construction (2026-08-16).
    if st.id > st.fields then
        finish(wgt, st, "ok")
    elseif (st.req_found or 0) >= REQ_N and st.id < st.fields then
        st.id = st.fields
    end
end

-- ---- entry points -----------------------------------------------------------
--- Install the file-logger getter (once, from the host).
function M.init(dbg)
    if dbg ~= nil then dbg_get = dbg end
end

--- Arm a scan. Cheap: no wire traffic here, M.poll does the work.
function M.start(wgt)
    local st = ensure(wgt)
    wipe(wgt)
    st.phase, st.dev_id, st.fields = "ping", nil, nil
    st.id, st.chunk, st.found, st.retry = 0, 0, 0, 0
    st.req_found = 0
    st.buf, st.expect, st.sent_at = nil, nil, nil
    st.started = getTime() or 0
    set(wgt, "elrs_cfg_state", "reading")
    wgt.rf_data_dirty = true
    dbg_log("scan armed")
end

--- One bounded step. Returns true while a scan is running.
--- The CALLER owns the arming gate: this pushes CRSF frames, and a pushed frame
--- replaces an RC channel frame.
function M.poll(wgt)
    local st = wgt.elrs_cfg
    if st == nil or st.phase == nil then return false end
    if type(crossfireTelemetryPush) ~= "function" then
        finish(wgt, st, "no CRSF")
        return false
    end

    local now = getTime() or 0
    if (now - (st.started or now)) > SCAN_DEADLINE_CS then
        finish(wgt, st, "timeout")
        return false
    end

    -- 1) drain what arrived, at most POP_CAP frames per pass
    local n = 0
    while n < POP_CAP do
        local cmd, d = crossfireTelemetryPop()
        if cmd == nil then break end
        n = n + 1
        if cmd == CMD_INFO then on_info(wgt, st, d)
        elseif cmd == CMD_ENTRY then on_entry(wgt, st, d) end
        if st.phase == nil then return false end     -- on_entry finished the scan
    end

    -- 2) at most ONE request per pass -- see the header note on the RC frame cost
    if st.sent_at ~= nil and (now - st.sent_at) < REQ_TIMEOUT_CS then
        return true                                  -- still waiting, nothing to send
    end
    if st.sent_at ~= nil then
        st.retry = st.retry + 1
        st.buf, st.expect, st.chunk = nil, nil, 0
        if st.retry > MAX_RETRY then
            finish(wgt, st, (st.phase == "ping") and "no module" or "timeout")
            return false
        end
    end

    local ok
    if st.phase == "ping" then
        if st.retry == 0 and st.sent_at == nil then flush(POP_CAP) end
        ok = send_ping(st)
    else
        ok = send_read(st)
    end
    -- push refused = the single outbound slot is occupied (RFTool mid-MSP).
    -- Leave sent_at alone and try again next pass; that is not a retry.
    if ok then st.sent_at = now end
    return true
end

--- Stop a scan in flight without losing what it already read. Called when the
--- craft arms: the remaining requests would each cost an RC frame, and a scan
--- that spans a flight is not something anybody asked for. What is already in
--- wgt.values stays -- it is still true of the module.
function M.abort(wgt)
    local st = wgt.elrs_cfg
    if st == nil or st.phase == nil then return end
    finish(wgt, st, (st.found > 0) and "partial" or "armed")
end

--- Forget the module's answer. The values describe the RADIO's module, so this
--- is NOT called on an FC disconnect -- only where the module itself may have
--- changed underneath us.
function M.clear(wgt)
    wipe(wgt)
    if wgt.elrs_cfg then wgt.elrs_cfg.phase = nil end
end

return M
