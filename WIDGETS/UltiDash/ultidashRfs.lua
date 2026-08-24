-- =======================================================================================
--  UltiDash -- the RFSuite MSP service back end
--
--  A SECOND provider for the read surface ultidashRf.lua already fills from RFTool. It is
--  loaded ONLY when `_G.rfsuite.msp` is actually published, so a card with RFTool (or with
--  neither) never pays for this file: the detection in ultidashRf is two table reads.
--
--  WHY A FACADE AND NOT A SECOND MSP STACK. crossfireTelemetryPush writes ONE global
--  transmit slot for the whole radio and answers false while it is occupied, so a widget
--  that brings its own queue does not get a second channel -- it gets contention, and both
--  sides lose replies. RFSuite publishes `rfsuite.msp` for exactly that reason and this
--  file is a consumer of that contract, v1.
--
--  WHAT IS CONTRACT AND WHAT IS A BORROW. `rfsuite.msp` (register/request/cancel/release/
--  status/pump) and `rfsuite.session.isConnected` are the only two things touched here.
--  Everything else on `_G.rfsuite` is RFSuite's internals -- including its own MSP api/
--  modules, which would have saved every decoder below and are deliberately not used.
--
--  WE DO NOT PUMP. `msp.pump()` exists, and calling it would tick the MSP runtime ALONE --
--  no events runtime, so no sensors and no session fill. A provider nobody pumps is
--  therefore treated as "no provider" (see connected() below) rather than driven from here.
--
--  THE REPLIES ARE PARKED, NOT DECODED, IN THE CALLBACK. A consumer callback runs inside
--  the suite's queue processing, which runs inside whichever widget is pumping -- so
--  decoding there would spend UltiDash's work out of a FOREIGN widget's 20k instruction
--  budget. The contract asks for "copy the bytes, set a flag, return"; poll() then does the
--  decode on our own pass, in our own budget.
--
--  THE LAYOUTS ARE RFTOOL'S, FIELD FOR FIELD. Every decoder below reproduces the reply
--  parse of the matching rotorflight-lua-scripts MSP module (mspBatteryConfig,
--  mspGovernorConfig, mspFlightStats, mspTelemetryConfig, mspSmartFuel, mspEscSensorConfig,
--  mspBatteryProfile) including its version branches, its `scale` and its enum tables --
--  because the handlers in ultidashRf consume the shape those modules produce, and parity
--  means the same value out of the same bytes, not merely a value.
-- =======================================================================================

local M = {}

-- The consumer contract this file was written against. register() refuses at the door when
-- the service has moved on, and that refusal is FINAL for the session: retrying a version
-- mismatch every pass would print the same sentence for ever and change nothing.
local SERVICE_VERSION = 1
local CLIENT_NAME = "ultidash"

local client = nil
local version_refused = false
local short_reply_logged = false
local dbg_get = nil

-- Replies waiting to be decoded on our own pass. Filled by the parked callbacks, drained
-- by M.poll. A flat array: the suite processes one message at a time, so this holds one or
-- two entries in practice and never grows unbounded.
local inbox = {}

local function dbg_log(fmt, ...)
    if dbg_get == nil then return end
    local d = dbg_get()
    if d == nil then return end
    d.logf("RFS", fmt, ...)
end

-- ---------------------------------------------------------------------------------------
-- Byte reader
-- ---------------------------------------------------------------------------------------
-- A cursor of our own rather than the `buf.offset` field RFTool's mspHelper writes into the
-- buffer it is handed: that buffer belongs to the suite's queue (the message keeps it), and
-- writing a field into somebody else's table is the kind of borrow this file exists to
-- avoid. Plain arithmetic rather than bit32 -- the same idiom the adjustment walk uses.
local function rd(buf) return { b = buf, i = 1 } end

local function u8(r)
    local v = r.b[r.i]
    r.i = r.i + 1
    return v
end

local function u16(r)
    local a, b = r.b[r.i], r.b[r.i + 1]
    r.i = r.i + 2
    if a == nil or b == nil then return nil end
    return a + 256 * b
end

local function u32(r)
    local a, b, c, d = r.b[r.i], r.b[r.i + 1], r.b[r.i + 2], r.b[r.i + 3]
    r.i = r.i + 4
    if a == nil or b == nil or c == nil or d == nil then return nil end
    return a + 256 * b + 65536 * c + 16777216 * d
end

local function skip(r, n) r.i = r.i + n end

-- One line per session, not per reply: a firmware whose payload is shorter than this build
-- expects would otherwise write the same sentence on every connect read.
local function short(what, need, got)
    if not short_reply_logged then
        short_reply_logged = true
        print("[UltiDash] rfsuite.msp: short " .. what .. " reply")
    end
    dbg_log("short %s reply: need %d bytes, got %d", what, need, got)
end

-- ---------------------------------------------------------------------------------------
-- The enum tables the handlers read through enum_name(), copied from RFTool's getDefaults()
-- ---------------------------------------------------------------------------------------
local METER_SRC = { [0] = "None", "ADC", "ESC" }
local GOV_MODE_NEW = { [0] = "OFF", "LIMIT", "DIRECT", "ELECTRIC", "NITRO" }
local GOV_MODE_OLD = { [0] = "OFF", "PASSTHROUGH", "STANDARD", "MODE1", "MODE2" }
local GOV_THROTTLE = { [0] = "NORMAL", "SWITCH", "FUNCTION" }
local CRSF_MODE = { [0] = "NATIVE", "CUSTOM" }
local SMARTFUEL_MODE = { [0] = "OFF", "VOLTAGE", "CURRENT", "COMBINED" }
-- ONE flat table where RFTool builds it up per API version: the tail entries exist only on
-- a firmware that can report them, so a lookup can never hit an entry the FC did not send.
local ESC_PROTOCOL = { [0] = "NONE", "BLHELI32", "HOBBYWING V4", "HOBBYWING V5", "SCORPION",
    "KONTRONIK", "OMP", "ZTW", "APD", "OPENYGE", "FLYROTOR", "GRAUPNER", "XDFLY",
    "FrSky F.BUS" }

-- ---------------------------------------------------------------------------------------
-- Decoders. Each returns the table shape the matching ultidashRf handler consumes, or nil.
-- Only the fields UltiDash actually reads are unpacked; the rest is stepped over, which is
-- what keeps this file a read surface rather than a second configurator.
-- ---------------------------------------------------------------------------------------
local DECODE = {}

-- MSP 175 MSP_BATTERY_PROFILE (API >= 12.09) -- the active profile index, 0-based.
DECODE.battery_profile = function(buf)
    if #buf < 1 then short("battery profile", 1, #buf) return nil end
    return { batteryProfile = { value = buf[1] } }
end

-- MSP 32 MSP_BATTERY_CONFIG
DECODE.battery_config = function(buf, api)
    if #buf < 15 then short("battery config", 15, #buf) return nil end
    local r = rd(buf)
    local c = {}
    local active = u16(r)                       -- the ACTIVE profile's capacity
    if api < 12.09 then c.batteryCapacity = { value = active } end
    c.batteryCellCount = { value = u8(r) }
    c.voltageMeterSource = { value = u8(r), table = METER_SRC }
    c.currentMeterSource = { value = u8(r), table = METER_SRC }
    c.vbatmincellvoltage = { value = u16(r), scale = 100 }
    c.vbatmaxcellvoltage = { value = u16(r), scale = 100 }
    c.vbatfullcellvoltage = { value = u16(r), scale = 100 }
    c.vbatwarningcellvoltage = { value = u16(r), scale = 100 }
    c.lvcPercentage = { value = u8(r) }
    c.consumptionWarningPercentage = { value = u8(r) }
    if api >= 12.09 then
        -- the per-profile capacities, 0-based [0..5] and indexed DIRECTLY by the profile
        -- value -- the same table sync_active_battery_capacity() reads
        local t = {}
        for i = 0, 5 do t[i] = { value = u16(r) } end
        c.batteryCapacity = t
    end
    return c
end

-- MSP 142 MSP_GOVERNOR_CONFIG. gov_autorotation_timeout is scale 10 below API 12.09 and
-- plain seconds from 12.09 on -- carried as `scale` rather than divided here, because
-- scaled() in ultidashRf is what the handler reads it through.
DECODE.governor = function(buf, api)
    if #buf < 20 then short("governor config", 20, #buf) return nil end
    local r = rd(buf)
    local c = {}
    c.gov_mode = { value = u8(r), table = (api < 12.09) and GOV_MODE_OLD or GOV_MODE_NEW }
    c.gov_startup_time = { value = u16(r), scale = 10 }
    c.gov_spoolup_time = { value = u16(r), scale = 10 }
    skip(r, 2 * 3)                              -- tracking / recovery / throttle_hold
    skip(r, 2)                                  -- lost_headspeed (<12.09) / reserved
    c.gov_autorotation_timeout = { value = u16(r), scale = (api < 12.09) and 10 or nil }
    skip(r, 2 * 2)                              -- autorotation bailout / min entry
    c.gov_handover_throttle = { value = u8(r) }
    skip(r, 4)                                  -- pwr / rpm / tta / ff filters
    skip(r, 1)                                  -- spoolup_min_throttle (12.08) / reserved
    if api >= 12.09 then
        skip(r, 1)                              -- d_filter
        skip(r, 2)                              -- spooldown_time
        c.gov_throttle_type = { value = u8(r), table = GOV_THROTTLE }
        skip(r, 2)
        c.gov_idle_throttle = { value = u8(r), scale = 10 }
    end
    return c
end

-- MSP 14 MSP_FLIGHT_STATS (API >= 12.09) -- lifetime counters, the only two shown.
DECODE.stats = function(buf)
    if #buf < 8 then short("flight stats", 8, #buf) return nil end
    local r = rd(buf)
    return {
        stats_total_flights = { value = u32(r) },
        stats_total_time_s = { value = u32(r) },
    }
end

-- MSP 73 MSP_TELEMETRY_CONFIG. The CRSF block exists from API 12.07; below that the reply
-- carries three legacy fields and nothing this asked for, which is why the caller does not
-- even issue the request there.
DECODE.telemetry = function(buf, api)
    if api < 12.07 then return nil end
    if #buf < 51 then short("telemetry config", 51, #buf) return nil end
    local r = rd(buf)
    skip(r, 1 + 1 + 4)                          -- inverted / halfduplex / telemetry_sensors
    skip(r, 1)                                  -- pinswap
    local c = {}
    c.crsf_telemetry_mode = { value = u8(r), table = CRSF_MODE }
    c.crsf_telemetry_rate = { value = u16(r) }
    c.crsf_telemetry_ratio = { value = u16(r) }
    local slots = {}
    for i = 1, 40 do slots[i] = u8(r) end
    c.crsf_telemetry_sensors = slots
    return c
end

-- MSP2 0x4000 MSP2_GET_SMARTFUEL_CONFIG (API >= 12.09)
DECODE.smartfuel = function(buf)
    if #buf < 1 then short("smartfuel config", 1, #buf) return nil end
    return { smartfuel_mode = { value = buf[1], table = SMARTFUEL_MODE } }
end

-- MSP 123 MSP_ESC_SENSOR_CONFIG -- the protocol byte alone, which is what explains a blank
-- Esc# decoder (no signature byte -> SIG_NONE -> get_status() returns nil).
DECODE.esc = function(buf)
    if #buf < 1 then short("ESC sensor config", 1, #buf) return nil end
    return { protocol = { value = buf[1], table = ESC_PROTOCOL } }
end

-- ---------------------------------------------------------------------------------------
-- The simulator responses. NOT optional: with `status().simulator` true the suite answers
-- from this table and NEVER SENDS THE REQUEST -- a read without one is a read that silently
-- does not happen on the harness. Byte for byte RFTool's own, so the two providers produce
-- the same simulated dashboard.
-- ---------------------------------------------------------------------------------------
local SIM = {
    battery_profile = { 1 },
    battery_config = { 184, 11, 12, 2, 2, 64, 1, 174, 1, 154, 1, 94, 1, 100, 10,
                       152, 8, 184, 11, 172, 13, 160, 15, 0, 0, 0, 0 },
    governor = { 2, 200, 0, 100, 0, 20, 0, 20, 0, 50, 0, 0, 0, 50, 0, 0, 0, 0, 0, 20, 5,
                 10, 0, 5, 0, 50, 30, 0, 0, 0, 0, 0, 0, 0, 50, 100, 120, 140, 150, 160,
                 165, 170 },
    stats = { 123, 1, 0, 0, 100, 1, 2, 0, 0, 0, 0, 0, 15 },
    telemetry = { 0, 1, 15, 0, 22, 0, 0, 1, 500, 0, 8, 0, 1, 8, 99, 0, 0, 0, 0, 0, 0, 0, 0,
                  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                  0, 0, 0, 0, 0 },
    smartfuel = { 12, 3, 42, 52 },
    esc = { 0, 0, 200, 0, 15, 0, 0, 0, 0, 30, 0, 0, 0, 0 },
}

-- ---------------------------------------------------------------------------------------
-- The service surface
-- ---------------------------------------------------------------------------------------
local function service()
    local s = _G.rfsuite and _G.rfsuite.msp
    if type(s) ~= "table" then return nil end
    return s
end

--- Is our service surface published in this Lua state?
--- `_G.rfsuite` alone is UPSTREAM RFSuite and offers nothing a consumer may use.
function M.present() return service() ~= nil end

--- The link, as the service reports it -- a COPY, never its live state table. nil when the
--- surface is gone or answered something unexpected.
function M.status()
    local s = service()
    if s == nil then return nil end
    local ok, st = pcall(s.status)
    if not ok or type(st) ~= "table" then return nil end
    return st
end

--- The MSP API version as a NUMBER, which is what every version branch in this widget
--- compares against. The service reports it as a string ("12.09"), and "0" while it is
--- still unknown -- that case answers nil, exactly like a missing rf2.apiVersion.
function M.api_version(st)
    st = st or M.status()
    if st == nil then return nil end
    local v = tonumber(st.apiVersion)
    if v == nil or v <= 0 then return nil end
    return v
end

--- Is somebody pumping AND is the link up? `session.isConnected` is the events runtime's
--- own hysteresis (0.6 s up / 2.0 s down), so it means a live link and not merely that code
--- is loaded. A surface published with nobody pumping never moves it, and that is exactly
--- the "present, idle" case we decline to read on.
function M.connected()
    local s = _G.rfsuite and _G.rfsuite.session
    return type(s) == "table" and s.isConnected == true
end

--- Take (or re-take) our one client id. One client for the widget, not one per instance and
--- never one per read: the service hands out a fresh id on every call, so a caller that
--- registers per refresh leaks an entry per refresh.
function M.attach()
    if client ~= nil then return client end
    if version_refused then return nil end
    local s = service()
    if s == nil then return nil end
    local ok, c, why = pcall(s.register, CLIENT_NAME, SERVICE_VERSION)
    if not ok then
        dbg_log("register raised: %s", tostring(c))
        return nil
    end
    if type(c) ~= "table" then
        -- "version" = the surface moved on. Final, and worth saying out loud: the feature
        -- is off for this session and probing further would only half-work.
        -- "unavailable" = the runtime is not up yet; retried on the next pass.
        if why == "version" then
            version_refused = true
            print("[UltiDash] rfsuite.msp refused contract v" .. SERVICE_VERSION)
            dbg_log("register refused: version - RFSuite's MSP contract moved past v%d",
                SERVICE_VERSION)
        end
        return nil
    end
    client = c
    dbg_log("registered on rfsuite.msp v%d as %s", SERVICE_VERSION, tostring(c.id))
    return client
end

--- Give the client up. Everything it still had queued goes with it; work belonging to
--- RFSuite itself keeps its place.
function M.detach()
    if client ~= nil then pcall(client.release, client) end
    client = nil
    for i = #inbox, 1, -1 do inbox[i] = nil end
end

--- Ask the flight controller something. `on_buf` is called with the reply bytes INSIDE the
--- suite's queue processing -- keep whatever is passed here tiny (see the file header).
--- Returns true when the request was queued.
function M.request(command, payload, sim, on_buf)
    local c = M.attach()
    if c == nil then return false end
    local ok, id = pcall(c.request, c, {
        command = command,
        payload = payload,
        simulatorResponse = sim,
        onReply = on_buf,
        -- "aborted" means the link dropped and everything in flight was invalidated at
        -- once. Nothing is re-issued from here: the connect flank in ultidashRf owes the
        -- reads again, and a retry loop on a dead link is how the one TX slot gets wasted.
        onError = function(reason)
            dbg_log("msp %d failed: %s", command, tostring(reason))
        end,
    })
    return ok and id ~= nil
end

-- One parked callback per kind, built ONCE at chunk level: a closure per request would be a
-- table per read on a path that runs on every connect and every disarm.
local function parker(what)
    return function(buf)
        inbox[#inbox + 1] = { what = what, buf = buf }
    end
end
local PARK = {
    battery_profile = parker("battery_profile"),
    battery_config = parker("battery_config"),
    governor = parker("governor"),
    stats = parker("stats"),
    telemetry = parker("telemetry"),
    smartfuel = parker("smartfuel"),
    esc = parker("esc"),
}

local function ask(what, command)
    return M.request(command, nil, SIM[what], PARK[what])
end

--- The four per-connect/disarm reads, the same set and the same version gates the RFTool
--- path issues. The caller owns the arming gate and the debounce; this only puts them on
--- the wire.
function M.read_session(api)
    ask("battery_profile", 175)
    if api ~= nil then ask("battery_config", 32) end
    ask("stats", 14)
    if api ~= nil then ask("governor", 142) end
end

--- The three once-per-connect reads. Returns false when the API version is not known yet --
--- the caller then keeps owing them, exactly as read_connect_data does for RFTool.
function M.read_connect(api)
    if api == nil then return false end
    if api >= 12.07 then ask("telemetry", 73) end
    if api >= 12.09 then ask("smartfuel", 16384) end
    ask("esc", 123)
    return true
end

--- Decode whatever came back and hand it to the host's handlers, on the HOST's pass and in
--- the host's budget. `h` maps a kind onto the matching on_*_received function.
function M.poll(wgt, h)
    local n = #inbox
    if n == 0 then return end
    -- read AFTER the empty check: status() is a pcall plus a table build in the service, and
    -- the overwhelmingly common pass has nothing waiting.
    local api = M.api_version() or 0
    for i = 1, n do
        local e = inbox[i]
        inbox[i] = nil
        local decode = DECODE[e.what]
        local fn = h[e.what]
        if decode ~= nil and fn ~= nil then
            local cfg = decode(e.buf, api)
            if cfg ~= nil then fn(wgt, cfg) end
        end
    end
end

--- Switch the ACTIVE battery profile: MSP 176, then MSP 250 to persist it WITHOUT a reboot.
--- The two are separate messages on one queue and go out in order. index is 0-based.
--- The caller owns the arming gate -- the FC rejects both while armed, and so does UltiDash
--- one step earlier.
function M.set_battery_profile(index)
    if not M.request(176, { index }, {}, nil) then return false end
    -- MSP_EEPROM_WRITE, no payload. It therefore goes out as a CRSF MSP_REQ frame rather
    -- than an MSP_WRITE one; rx/crsf.c handles the two in the same case, so the FC sees no
    -- difference. A failure here still leaves the profile switched live, just not saved.
    M.request(250, nil, {}, nil)
    return true
end

--- The Status row. Says WHO is serving and, for this provider, whether anybody is pumping:
--- "present" and "active" are different claims and a pilot chasing missing values needs
--- them apart.
function M.provider_text()
    if service() == nil then
        -- upstream RFSuite, which publishes no consumer surface at all
        return (type(_G.rfsuite) == "table") and "RFSuite (no API)" or nil
    end
    if version_refused then
        return "RFSuite service (contract past v" .. SERVICE_VERSION .. ")"
    end
    return "RFSuite service v" .. SERVICE_VERSION
        .. (M.connected() and " (active)" or " (idle)")
end

function M.init(dbg)
    if dbg ~= nil then dbg_get = dbg end
end

return M
