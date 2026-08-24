local M = {}

local function ensure_rf_state(wgt)
    wgt.rf = wgt.rf or {
        available = false,
        provider_ref = nil,
        provider_kind = nil,        -- "rf2" (RFTool) | "rfs" (the RFSuite service) | nil
        rfs_seen = nil,             -- how much of RFSuite was in this state on the last
                                    -- pass (0/1/2, see note_provider) -- the Status row's
                                    -- second half, compared rather than rebuilt
        is_registered = false,
        last_state = nil,
        msp_allowed = false,
        battery_profile = nil,
        battery_config = nil,
        governor_config = nil,
        flight_stats = nil,
        crsf_slots = nil,           -- TELEM id -> true, from MSP 73 (nil = no claim)
        connect_reads = nil,        -- true = the once-per-connect reads are still owed
        elrs_scan = nil,            -- true = the once-per-connect ELRS module scan is owed
        reads_issued = nil,         -- getTime() of the pass that put the connect reads on
                                    -- the wire -- the holdoff reference for adj_may_start
        adj_walk = nil,             -- true = the adjustment-table walk is owed (T2); armed
                                    -- at connect UNCONDITIONALLY (a flag is free), the
                                    -- TbSource option gates the FIRST REQUEST -- so a
                                    -- pilot on the hand table never spends a byte, and
                                    -- turning the option on mid-session starts the walk
                                    -- on the next disarmed pass instead of never
        adj = nil,                  -- walk in progress (adj_step state machine)
        adj_table = nil,            -- completed records (toolbox/common.applyFcTable reads it)
        adj_gen = 0,                -- bumped on every table change -> page rebuild signal
        callback_installed = false,
        read_pending = nil          -- debounced MSP read request (see read_rf_data/background)
    }
    return wgt.rf
end

-- Everything the MSP reads put into wgt.values, in ONE list. Cleared together on a real
-- session end (see on_state_changed). A list rather than a run of assignments because the
-- 0.8.0 MSP block tripled the number of fields: a key added to a read and forgotten in the
-- clear survives a model change and then describes the wrong helicopter.
-- rf_battery_profile is NOT here -- it seeds -1 rather than nil (the picker shows "unknown").
local RF_SESSION_KEYS = {
    "rf_battery_capacity_mah", "rf_battery_cell_count",
    "rf_cell_warning_voltage", "rf_cell_alarm_voltage", "rf_cell_full_voltage",
    "rf_cell_max_voltage", "rf_lvc_pct", "rf_fc_fuel_warn_pct",
    "rf_volt_meter_name", "rf_curr_meter_name", "rf_meter_src_text", "rf_batt_limits_text",
    "rf_gov_mode", "rf_gov_mode_name", "rf_gov_mode_label", "rf_gov_has_state",
    "rf_gov_spoolup_s", "rf_gov_startup_s", "rf_gov_handover_pct", "rf_gov_idle_pct",
    "rf_gov_autorot_s", "rf_gov_throttle_type_name",
    "rf_gov_timing_text", "rf_gov_throttle_text",
    "rf_crsf_mode", "rf_crsf_mode_name", "rf_crsf_rate", "rf_crsf_ratio",
    "rf_crsf_slot_count", "rf_crsf_text",
    "rf_smartfuel_mode", "rf_smartfuel_mode_name", "rf_esc_protocol_name",
    "rf_adj_state",
    -- Deliberately NOT in this list: rf_tool_api_text and rf_provider_text. Every key above
    -- describes the FLIGHT CONTROLLER and must not survive a model change; the RFTool's
    -- contract version and the name of the serving provider describe the RADIO's own
    -- tooling and do not change with the link. Both are cleared where they actually become
    -- unknown — when the provider goes away (M.background).
}

-- An MSP field carries its own `scale` in the API's own default table, so a value is read
-- THROUGH it rather than through a divisor written down here: gov_autorotation_timeout is
-- scale 10 below API 12.09 and plain seconds from 12.09 on, and a hardcoded /10 would be
-- silently wrong on one of the two.
local function scaled(entry)
    if type(entry) ~= "table" or type(entry.value) ~= "number" then return nil end
    local s = entry.scale
    if type(s) == "number" and s > 1 then return entry.value / s end
    return entry.value
end

-- The enum LABEL out of the API's own table (same trick rf_gov_mode_name already used):
-- the tables are version-dependent and the module that parsed the reply owns the right one.
local function enum_name(entry)
    if type(entry) ~= "table" then return nil end
    local t, v = entry.table, entry.value
    if type(t) ~= "table" or v == nil then return nil end
    return t[v]
end

-- The RFTool bounces between initializing/disarmed/connected several times during the
-- connect handshake; firing read_rf_data on every msp-allowed transition produced 2-3
-- back-to-back 3-request MSP storms (the "connect burst"). We instead DEBOUNCE: each
-- transition just timestamps a pending request, and background() fires ONE read once the
-- state has been stable this long. A genuine post-flight disarm read still happens (just
-- ~this much later); explicit reads (picker / after a profile write) call read_rf_data
-- directly and are not debounced.
local RF_READ_SETTLE_CS = 40        -- 0.4 s (EdgeTX centiseconds)

-- ARM-sensor gate for the MSP reads: msp_allowed alone hangs on the RFTool
-- state, and a disconnected->connected->armed handshake with a >settle "connected"
-- window would fire the 4 connect reads WHILE THE MODEL FLIES. The host hands in its
-- is_armed predicate (the shared ARM-sensor read incl. per-tick cache) via M.init;
-- the getValue fallback covers a host that never did (bit 0 / 1024 = armed, exactly
-- like is_craft_armed). Module-local: the RF service runs on the publisher only.
local armed_check = nil
local function craft_armed(wgt)
    if armed_check then return armed_check(wgt) end
    if type(getValue) ~= "function" then return false end
    local ok, arm = pcall(getValue, "ARM")
    if not ok or type(arm) ~= "number" then return false end
    arm = math.floor(arm)
    return (arm % 2) == 1 or arm == 1024
end

local function format_seconds(seconds)
    -- pcall the load AND the call: an RFTool update that renamed/removed the F/formatSeconds
    -- helper must degrade to the fallback string, not crash the widget Lua state.
    if rf2 and rf2.executeScript then
        local ok, s = pcall(function() return rf2.executeScript("F/formatSeconds")(seconds or 0) end)
        if ok and s ~= nil then return s end
    end
    -- No RFTool to borrow the helper from -- the normal case under the RFSuite provider, and
    -- the reason this reproduces F/formatSeconds rather than printing a bare second count:
    -- the same lifetime figure must read the same on the Status page whoever served it.
    local t = seconds or 0
    local days = math.floor(t / 86400)
    t = t % 86400
    local s = string.format("%02d:%02d:%02d", math.floor(t / 3600), math.floor((t % 3600) / 60), t % 60)
    if days > 0 then return string.format("%dd%s", days, s) end
    return s
end

-- Optional file logger, handed in by the host (M.init). A GETTER rather than the module
-- itself: ultidashDebug is lazy-loaded and stays nil until the DebugLog option is first
-- turned on, so a reference captured at init would be nil for ever. Off = two compares.
-- This is E2 ("every fallback writes a debug-log line") applied, not a new mechanism.
local dbg_get = nil
-- The ELRS TX configuration client (ultidashElrs), handed in by the host through
-- M.init. Module-local for the same reason as the two hooks above: the RF service
-- runs on the publisher instance only.
local elrs_module = nil
local function dbg_log(fmt, ...)
    if dbg_get == nil then return end
    local d = dbg_get()
    if d == nil then return end
    d.logf("RF", fmt, ...)
end

-- Report an rf2 API failure ONCE per session (goes to the console + the file log when
-- DebugLog is on); a mismatch would otherwise repeat on every read.
local function log_api_err(state)
    if not state.api_err_logged then
        state.api_err_logged = true
        print("[UltiDash] rf2 API call failed (RFTool version mismatch?)")
    end
end

-- --------------------------------------------------------------------------------------
-- WHO SERVES. Two providers can publish MSP into this Lua state, and they both master the
-- ONE CRSF transmit slot the radio has -- so there is nothing to arbitrate between them:
-- one is picked and the Status row says the other was seen.
--
--   rf2          RFTool (rotorflight-lua-scripts). Internal, unversioned surface -- a
--                borrow, not a contract, and what UltiDash has shipped on since 0.1.
--   rfsuite.msp  RFSuite for EdgeTX, consumer contract v1. `_G.rfsuite` ALONE is upstream
--                RFSuite, which publishes no consumer surface at all and counts as nothing.
--
-- RFTOOL WINS when both are present. That is the conservative choice rather than a measured
-- one: the RFTool path is what ships and what the radio has proven, and the second provider
-- has not been on a card with a flight controller behind it yet.
-- --------------------------------------------------------------------------------------
-- A LOADER rather than the module: ultidashRfs.lua is loaded the first time `rfsuite.msp`
-- is actually seen, so a card with RFTool -- or with neither -- never spends the load. The
-- host hands it in so every loadScript in the widget stays in one place.
local rfs_loader = nil
local rfs = nil
local function rfs_module()
    if rfs ~= nil then return rfs end
    if rfs_loader == nil then return nil end
    local m = rfs_loader()
    if type(m) ~= "table" then
        rfs_loader = nil                -- a missing or broken file is not retried per pass
        return nil
    end
    rfs = m
    rfs.init(dbg_get)
    return rfs
end

-- "rf2" | "rfs" | nil, decided once per background pass.
local provider = nil

-- The MSP API version from whichever provider serves. Every version branch below compares
-- against a NUMBER; both providers can answer "not known yet", and that stays nil rather
-- than becoming 0 -- a 0 would read as "a very old flight controller".
local function api_version()
    if provider == "rfs" then
        return rfs ~= nil and rfs.api_version() or nil
    end
    if rf2 ~= nil then return rf2.apiVersion end
    return nil
end

-- The RFTool widget-API contract version. RFTool sets it at chunk level right next to
-- rf2.registerWidget (WIDGETS/RfTool/app.lua:361-362); 1.00 is what the current release
-- publishes.
local RF_TOOL_API_KNOWN = 1.00

-- It is a SIGNAL, not a gate, and that is a decision rather than caution.
--
-- The version field shipped in RFTool 2.3.0-RC2; rf2.registerWidget already shipped in RC1,
-- and 2.2.1 has no widget API at all (which is why this widget exists). So the population
-- that reports NIL is not "some older RFTool" in the abstract — it is exactly RC1, an install
-- that registers, calls back and works today. A gate that locked nil out would kill a working
-- install to enforce a number nothing here needs.
--
-- The real capability gate therefore stays what it already was: registerWidget/useApi being
-- present (M.background) plus the per-read pcalls. This function only reports — a row on
-- menu > Status, and ONE debug-log line per session for each of the two cases worth knowing
-- about. Nothing branches on the number.
local function note_tool_api(wgt, state)
    if state.tool_api_read then return end
    state.tool_api_read = true
    local v = rf2 and rf2.rfToolApiVersion
    if type(v) == "number" then
        if wgt.values then wgt.values.rf_tool_api_text = string.format("%.2f", v) end
        if v > RF_TOOL_API_KNOWN then
            dbg_log("rfToolApiVersion %.2f > %.2f, the contract this build was written against"
                .. " - reporting only, nothing is gated on it", v, RF_TOOL_API_KNOWN)
        end
    else
        -- Not an error and not degraded: RC1 registers and calls back exactly like RC2.
        if wgt.values then wgt.values.rf_tool_api_text = "not reported" end
        dbg_log("rfToolApiVersion absent - RFTool 2.3.0-RC1 (the field shipped in RC2, the"
            .. " widget API itself in RC1); nothing is gated on it")
    end
end

local function sync_active_battery_capacity(wgt)
    local config = ensure_rf_state(wgt).battery_config
    -- prefer the always-fresh active index (follows external profile switches);
    -- fall back to the seeded one. `x or y` keeps a legit 0 (0 is truthy in Lua).
    local profile_value = wgt.values.rf_battery_profile_active or wgt.values.rf_battery_profile
    local capacity_value = nil

    if config and config.batteryCapacity then
        if type(config.batteryCapacity) == "table" and profile_value ~= nil and profile_value >= 0 then
            -- batteryCapacity is a 0-based [0..5] table indexed DIRECTLY by the
            -- 0-based profile value (value 0 = profile 1) — NO -1 offset (matches
            -- mspBatteryConfig and get_profile_capacity; the old -1 was off by one).
            local entry = config.batteryCapacity[profile_value]
            if entry then capacity_value = entry.value end
        elseif config.batteryCapacity.value ~= nil then
            capacity_value = config.batteryCapacity.value
        end
    end

    wgt.values.rf_battery_capacity_mah = capacity_value
end

local function on_battery_profile_received(wgt, config)
    ensure_rf_state(wgt).battery_profile = config
    if wgt.values.rf_battery_profile == nil or wgt.values.rf_battery_profile < 0 then
        wgt.values.rf_battery_profile = config and config.batteryProfile and config.batteryProfile.value or -1
    end
    -- ALWAYS-fresh active profile index (0-based), no freeze — the battery-profile
    -- picker reads this so it reflects the FC's real current profile every time it is
    -- (re)read, e.g. on the picker's on-open refresh.
    wgt.values.rf_battery_profile_active = config and config.batteryProfile and config.batteryProfile.value
    sync_active_battery_capacity(wgt)

    wgt.rf_data_dirty = true
end

local function on_battery_config_received(wgt, config)
    ensure_rf_state(wgt).battery_config = config
    wgt.values.rf_battery_cell_count = config and config.batteryCellCount and config.batteryCellCount.value
    wgt.values.rf_cell_warning_voltage = config and config.vbatwarningcellvoltage and config.vbatwarningcellvoltage.value
    wgt.values.rf_cell_alarm_voltage = config and config.vbatmincellvoltage and config.vbatmincellvoltage.value
    wgt.values.rf_cell_full_voltage = config and config.vbatfullcellvoltage and config.vbatfullcellvoltage.value
    sync_active_battery_capacity(wgt)

    -- G1: five more fields that were ALREADY IN THIS REPLY and were being dropped. No
    -- extra request -- RFTool parses the whole payload and this callback used to pick out
    -- four values. All of it is CONFIGURATION (it cannot change in flight, so one read
    -- holds all session) and all of it goes to menu > Status and the sensor check, NONE
    -- of it to the dashboard: a dashboard is for what moves.
    wgt.values.rf_volt_meter_name = enum_name(config and config.voltageMeterSource)
    wgt.values.rf_curr_meter_name = enum_name(config and config.currentMeterSource)
    -- The FLIGHT CONTROLLER's own fuel warning, shown to OBSERVE only. It must never feed
    -- UltiDash's fuel callouts: those thresholds are the pilot's and are set here, and
    -- letting this drive them would move a user-set value from the other side of the link.
    -- Displaying the two next to each other is the whole feature.
    wgt.values.rf_fc_fuel_warn_pct = config and config.consumptionWarningPercentage and config.consumptionWarningPercentage.value
    wgt.values.rf_lvc_pct = config and config.lvcPercentage and config.lvcPercentage.value
    -- centivolts, exactly like the three cell voltages above
    wgt.values.rf_cell_max_voltage = config and config.vbatmaxcellvoltage and config.vbatmaxcellvoltage.value

    -- Display strings built HERE, once per read, for the same reason rf_gov_mode_label is:
    -- the Status rows are reactive getters that run per LVGL frame, and a per-frame concat
    -- is constant GC pressure for a value that cannot change between reads.
    local vs, cs = wgt.values.rf_volt_meter_name, wgt.values.rf_curr_meter_name
    wgt.values.rf_meter_src_text = (vs ~= nil or cs ~= nil)
        and ((vs or "?") .. " / " .. (cs or "?")) or nil
    -- string.format, never the method form: the widget Lua state has no string metatable,
    -- so s:format(...) raises "attempt to index a string value" and takes the dashboard down.
    local lvc, vmax = wgt.values.rf_lvc_pct, wgt.values.rf_cell_max_voltage
    wgt.values.rf_batt_limits_text = (lvc ~= nil or vmax ~= nil)
        and string.format("%s  /  %s",
                lvc and string.format("%d %%", lvc) or "-",
                vmax and string.format("%.2f V", vmax / 100) or "-") or nil

    -- ONE line at connect, no warning and no popup (rule 3 is read and report only, and
    -- the alert surface belongs to the user). current_meter = None is the third condition
    -- of the SmartFuel bat_capacity trap, so naming it in the log is worth real support
    -- time -- but a row and a log line REPORT, where a warning would be UltiDash deciding.
    dbg_log("meters V=%s I=%s  lvc=%s%%  fc_fuel_warn=%s%%",
        tostring(vs), tostring(cs), tostring(lvc), tostring(wgt.values.rf_fc_fuel_warn_pct))

    wgt.rf_data_dirty = true
end

-- Governor config (MSP 142) — read once per connect/disarm alongside the battery
-- reads. Only gov_mode matters to the widget: in gov_mode OFF/LIMIT the firmware
-- never updates gov.state (the Gov sensor stays constant 0), so the stats extrema
-- need to know whether the governor state machine runs at all (rf_gov_has_state).
local function on_governor_config_received(wgt, config)
    ensure_rf_state(wgt).governor_config = config
    local mode = config and config.gov_mode and config.gov_mode.value
    wgt.values.rf_gov_mode = mode
    -- version-aware enum label straight from the API's own table
    -- (>=12.09: OFF/LIMIT/DIRECT/ELECTRIC/NITRO; older: OFF/PASSTHROUGH/...)
    local tbl = config and config.gov_mode and config.gov_mode.table
    local name = (mode ~= nil and tbl ~= nil) and tbl[mode] or nil
    wgt.values.rf_gov_mode_name = name
    -- does the gov state machine run (= does the Gov sensor carry real states)?
    -- RF 2.3 (API >= 12.09): OFF(0)/LIMIT(1) never update gov.state -> false.
    -- Older API (RF 2.2 enum): only OFF(0) is dead; PASSTHROUGH+ run the state machine.
    local gov_api = api_version()
    if mode == nil then
        wgt.values.rf_gov_has_state = nil
    elseif type(gov_api) == "number" and gov_api < 12.09 then
        wgt.values.rf_gov_has_state = mode >= 1
    else
        wgt.values.rf_gov_has_state = mode >= 2
    end
    -- precomputed display label ("Gov. Off"/"Gov. Limit") for the dashboard's governor
    -- slot when the state machine is off — computed HERE (once per read), because
    -- gov_state_formatted is a reactive getter running per LVGL frame
    if wgt.values.rf_gov_has_state == false and name ~= nil then
        wgt.values.rf_gov_mode_label = "Gov. " ..
            string.upper(string.sub(name, 1, 1)) .. string.lower(string.sub(name, 2))
    else
        wgt.values.rf_gov_mode_label = nil
    end

    -- G1: the rest of MSP 142's reply, which this callback used to drop on the floor. It
    -- is CONTEXT rather than measurement -- a spool-up with a known duration is a progress
    -- bar instead of a wait, and the handover throttle is a threshold the live throttle can
    -- be read against. Status page only, like the battery block above.
    --
    -- NOTE, and it is the one exception under "configuration cannot change in flight": the
    -- governor block is a member of the PID PROFILE (rotorflight-firmware pg/pid.h), and PID
    -- profiles switch in flight. MSP 142 is the per-craft governor CONFIG and is safe; the
    -- per-profile GOVERNOR PROFILE (MSP 148) is exactly what that seam voided, which is why
    -- the target headspeed is not here and must not be re-proposed without a firmware change.
    wgt.values.rf_gov_spoolup_s    = scaled(config and config.gov_spoolup_time)
    wgt.values.rf_gov_startup_s    = scaled(config and config.gov_startup_time)
    wgt.values.rf_gov_handover_pct = scaled(config and config.gov_handover_throttle)
    wgt.values.rf_gov_idle_pct     = scaled(config and config.gov_idle_throttle)
    wgt.values.rf_gov_autorot_s    = scaled(config and config.gov_autorotation_timeout)
    wgt.values.rf_gov_throttle_type_name = enum_name(config and config.gov_throttle_type)

    local sp, st, ho = wgt.values.rf_gov_spoolup_s, wgt.values.rf_gov_startup_s, wgt.values.rf_gov_handover_pct
    wgt.values.rf_gov_timing_text = (sp ~= nil or st ~= nil or ho ~= nil)
        and string.format("%s / %s s   %s",
                sp and string.format("%.1f", sp) or "-",
                st and string.format("%.1f", st) or "-",
                ho and string.format("%g %%", ho) or "-") or nil
    -- gov_throttle_type / gov_idle_throttle are API >= 12.09 only; below that both are nil
    -- and the row reads "-", which is the truthful answer for an older flight controller.
    local tt, idle, ar = wgt.values.rf_gov_throttle_type_name, wgt.values.rf_gov_idle_pct, wgt.values.rf_gov_autorot_s
    wgt.values.rf_gov_throttle_text = (tt ~= nil or idle ~= nil or ar ~= nil)
        and string.format("%s   idle %s   auto %s",
                tt or "-",
                idle and string.format("%g %%", idle) or "-",
                ar and string.format("%g s", ar) or "-") or nil

    wgt.rf_data_dirty = true
end

local function on_flight_stats_received(wgt, stats)
    ensure_rf_state(wgt).flight_stats = stats
    wgt.values.rf_total_flights = stats and stats.stats_total_flights and stats.stats_total_flights.value
    wgt.values.rf_total_flight_time = stats and stats.stats_total_time_s and stats.stats_total_time_s.value
    wgt.values.rf_total_flight_time_formatted = format_seconds(wgt.values.rf_total_flight_time)

    wgt.rf_data_dirty = true
end

-- --------------------------------------------------------------------------------------
-- The three ONCE-PER-CONNECT reads (G2). Everything above is per connect/disarm.
-- --------------------------------------------------------------------------------------
-- Cadence, decided: these fire once per CONNECT, the four older ones stay per disarm. So
-- the first connect costs 7 requests and every later disarm costs 4 -- unchanged from
-- before after the first one. The accepted price, stated so nobody files it as a bug: a
-- telemetry configuration changed WITHOUT a reboot shows a stale slot list until the next
-- connect. MSP starves the sensor frames, not the other way round, which is why an added
-- read is not free on the wire even when it is free on the budget.

-- Telemetry config (MSP 73) -- G2-Telem, and it is UltiDash's OWN request. RFTool asks
-- command 73 itself (background_init.lua:142) and then THROWS THE ANSWER AWAY: the reply
-- goes into module-locals returned through the init-task result, and background.lua drops
-- the whole task (initTask = nil). Nothing of it reaches the rf2 global, so there is
-- nothing for a widget to read. An upstream RFTool patch exposing it would be the cleaner
-- shape and is deliberately out of scope -- a release must not depend on a foreign merge.
--
-- This is the ONE MSP module in the suite without the read/write/getDefaults shape: it
-- exports getTelemetryConfig alone, so `.read(...)` here is a call on nil.
local function on_telemetry_config_received(wgt, config)
    local state = ensure_rf_state(wgt)
    local mode = config and config.crsf_telemetry_mode and config.crsf_telemetry_mode.value
    wgt.values.rf_crsf_mode = mode
    wgt.values.rf_crsf_mode_name = enum_name(config and config.crsf_telemetry_mode)
    wgt.values.rf_crsf_rate  = config and config.crsf_telemetry_rate and config.crsf_telemetry_rate.value
    wgt.values.rf_crsf_ratio = config and config.crsf_telemetry_ratio and config.crsf_telemetry_ratio.value

    -- The slot list is meaningful ONLY in CUSTOM mode. CRSF_TELEMETRY_MODE_NATIVE runs a
    -- fixed legacy set and never consults telemetry_sensors at all
    -- (rotorflight-firmware telemetry/crsf.c), even when the list is populated. So NATIVE
    -- leaves crsf_slots NIL and every consumer reads nil as "no claim" rather than as
    -- "nothing is sent" -- otherwise a NATIVE craft would be told every row is missing.
    local slots, n = nil, 0
    if mode == 1 and type(config.crsf_telemetry_sensors) == "table" then
        slots = {}
        for i = 1, 40 do
            local id = config.crsf_telemetry_sensors[i]
            if type(id) == "number" and id > 0 and not slots[id] then
                slots[id] = true
                n = n + 1
            end
        end
    end
    state.crsf_slots = slots
    wgt.values.rf_crsf_slot_count = slots and n or nil
    wgt.values.rf_crsf_text = (mode ~= nil)
        and ((wgt.values.rf_crsf_mode_name or ("mode " .. tostring(mode)))
             .. (slots and string.format("   %d/40", n) or "")) or nil

    dbg_log("telemetry mode=%s slots=%s rate=%s ratio=%s",
        tostring(wgt.values.rf_crsf_mode_name), tostring(wgt.values.rf_crsf_slot_count),
        tostring(wgt.values.rf_crsf_rate), tostring(wgt.values.rf_crsf_ratio))

    wgt.rf_data_dirty = true
end

-- SmartFuel config (MSP2 0x4000) -- G2-Diag. With currentMeterSource from the battery
-- reply and the capacity already read, the SmartFuel bat_capacity trap becomes detectable
-- AT CONNECT instead of being a support case. Reported, never acted on.
local function on_smartfuel_received(wgt, config)
    ensure_rf_state(wgt)
    wgt.values.rf_smartfuel_mode = config and config.smartfuel_mode and config.smartfuel_mode.value
    wgt.values.rf_smartfuel_mode_name = enum_name(config and config.smartfuel_mode)
    dbg_log("smartfuel mode=%s", tostring(wgt.values.rf_smartfuel_mode_name))
    wgt.rf_data_dirty = true
end

-- ESC sensor config (MSP 123) -- G2-Diag. Names the ESC family in words, which is what
-- explains a blank Esc# decoder: without a signature byte the decoder is picked as
-- SIG_NONE and get_status() returns nil.
local function on_esc_sensor_config_received(wgt, config)
    ensure_rf_state(wgt)
    wgt.values.rf_esc_protocol_name = enum_name(config and config.protocol)
    dbg_log("esc protocol=%s", tostring(wgt.values.rf_esc_protocol_name))
    wgt.rf_data_dirty = true
end

-- What ultidashRfs hands its decoded replies to. The SAME seven handlers the RFTool path
-- calls: that is what "a second provider" means here -- one read surface, two transports.
-- The RFSuite side decodes the raw reply bytes into the shape RFTool's MSP modules produce,
-- so nothing downstream of this table knows or cares which provider filled a value.
local RFS_HANDLERS = {
    battery_profile = on_battery_profile_received,
    battery_config  = on_battery_config_received,
    governor        = on_governor_config_received,
    stats           = on_flight_stats_received,
    telemetry       = on_telemetry_config_received,
    smartfuel       = on_smartfuel_received,
    esc             = on_esc_sensor_config_received,
}

-- Issued from read_rf_data, inside the same two gates, only while state.connect_reads is
-- owed. Each in its OWN pcall, exactly like the four above: one missing or renamed API
-- must not block the others or crash the widget's Lua state.
local function read_connect_data(wgt, state, api)
    -- getDefaults() in all three modules dereferences rf2.apiVersion, so a nil version is
    -- not "an old flight controller", it is an error inside the module. Gate, do not pcall
    -- past it. The RFSuite side needs the same gate for the same reason: its version comes
    -- from an MSP read of its own and is simply not there yet on the first pass.
    if type(api) ~= "number" then return false end
    if provider == "rfs" then return rfs.read_connect(api) end

    -- >= 12.07 is where crsf_telemetry_mode and the 40 slots appear in the reply at all;
    -- below it the answer carries three legacy fields and nothing this asked for.
    local ok5 = true
    if api >= 12.07 then
        ok5 = pcall(function()
            rf2.useApi("mspTelemetryConfig").getTelemetryConfig(on_telemetry_config_received, wgt)
        end)
    end
    -- SmartFuel exists from 12.09; below that the module parses nothing and answers with
    -- an empty table, so there is no point spending a request on it.
    local ok6 = true
    if api >= 12.09 then
        ok6 = pcall(function() rf2.useApi("mspSmartFuel").read(on_smartfuel_received, wgt) end)
    end
    local ok7 = pcall(function() rf2.useApi("mspEscSensorConfig").read(on_esc_sensor_config_received, wgt) end)

    if not (ok5 and ok6 and ok7) then log_api_err(state) end
    return true
end

-- --------------------------------------------------------------------------------------
-- T2: the adjustment-table walk -- MSP_GET_ADJUSTMENT_FUNCTION_IDS (167) once, then
-- MSP_GET_ADJUSTMENT_RANGE (156) per used slot. UltiDash's OWN requests over
-- rf2.mspQueue: RFTool has no adjustments module at all (checked against the whole
-- suite), so there is nothing to reuse. The queue is SHARED and RFTool's pump retries
-- an enqueued message every 0.8 s until a reply arrives -- which is why this machine
-- keeps AT MOST ONE message in the queue and issues every next one from background(),
-- behind the same two gates as every other read here: an armed craft cannot be handed
-- a backlog it will drain in flight.
--
-- MSP 52 (the whole-table form) is NEVER sent: its 588-byte reply overruns the FC's
-- 320-byte telemetry response buffer by 268 bytes -- a firmware defect, measured
-- 2026-08-15, and 156/167 exist precisely as the paged accessors for this path.
--
-- Cadence: armed once per connect (adj_walk above), first request gated on TbSource
-- >= 2 -- the user's decision of 2026-08-16: the read runs on connect, only when the
-- option is on, and never on a Toolbox page open (the two adjust tools are usable in
-- flight, so that trigger would be an MSP read while armed). Cost when it runs: ~34
-- requests, ~130 ms each, during which MSP starves the sensor frames -- the accepted
-- price, falling at plug-in where nothing else happens.
-- --------------------------------------------------------------------------------------
local ADJ_DEADLINE_CS = 2000        -- 20 s for the whole walk (nominal ~5-7 s), like the
                                    -- ELRS scan; a reply lost to a queue clear or a
                                    -- simulator drop ends here instead of hanging
local ADJ_HOLDOFF_CS  = 500         -- 5 s ceiling on waiting for the connect reads below

-- The walk NEVER goes ahead of the once-per-connect reads. It shares ONE MSP queue with
-- them and then holds it for ~34 requests (~4,5 s), while read_rf_data first waits out
-- RF_READ_SETTLE_CS -- so an ungated walk is issued FIRST and the battery config queues
-- behind it. That reply carries the cell count and vbatfullcellvoltage, and the startup
-- cell check needs both ~4 s after the pack is plugged in. Without them it reaches the
-- one verdict in update_battery_gauge that warns SILENTLY: an amber bar and no callout.
-- Reported from the radio 2026-08-16, the evening TbSource=FC was first switched on.
--
-- The gate is about who starts FIRST, never about interrupting: a walk already running
-- passes straight through.
--
-- `reads_issued` is the whole condition, and it is nil until read_rf_data has actually put
-- MSP on the wire -- so "the connect reads have not gone out yet" needs no second flag.
-- From there the walk waits for the battery config REPLY, and the holdoff is what makes
-- that wait bounded: an FC that never answers it (no rf2.apiVersion, so the request is
-- never even issued; a read that failed its pcall) must not block the walk for ever.
-- Deliberately NOT gated on state.connect_reads: that flag stays set exactly in the
-- apiVersion case, and gating on it would turn this into a permanent stall.
local function adj_may_start(wgt, state)
    if state.adj ~= nil then return true end                       -- running: never stall
    local since = state.reads_issued
    if since == nil then return false end                          -- reads not on the wire
    if wgt.values and wgt.values.rf_cell_full_voltage ~= nil then return true end
    return ((getTime() or 0) - since) >= ADJ_HOLDOFF_CS
end

local function s8(v) if v > 127 then return v - 256 end return v end
local function s16(v) if v > 32767 then return v - 65536 end return v end
local function step_us(v) return 1500 + 5 * v end   -- STEP_TO_CHANNEL_VALUE, rc_modes.h

-- The walk's own simulator answers. RFTool needs none (its queue sends regardless), the
-- RFSuite service will not put a request on the wire at all without one -- so a walk on the
-- harness would otherwise stall for its whole 20 s deadline and abort, and the abort would
-- look like a finding. All zero = no adjustment slot in use, which is the only honest
-- answer with no flight controller behind the link: the Toolbox stays on the hand table.
-- 42 is MAX_ADJUSTMENT_RANGE_COUNT (fc pg/adjustments.h); 14 is the range record's length.
local ADJ_IDS_SIM = {}
for i = 1, 42 do ADJ_IDS_SIM[i] = 0 end
local ADJ_RANGE_SIM = {}
for i = 1, 14 do ADJ_RANGE_SIM[i] = 0 end

-- ONE MSP message, whichever provider serves. Both sides are fire-and-forget with a reply
-- callback; the RFSuite side needs the simulator answer above, the RFTool side ignores it.
-- Returns false when nothing could be queued, which the caller turns into an abort.
local function msp_enqueue(command, payload, sim, on_buf)
    if provider == "rfs" then
        return rfs ~= nil and rfs.request(command, payload, sim, on_buf) or false
    end
    if not (rf2 and rf2.mspQueue and rf2.mspQueue.add and rf2.mspQueue.processQueue) then
        return false
    end
    return (pcall(function()
        rf2.mspQueue:add({
            command = command,
            payload = payload,
            processReply = function(_, buf) on_buf(buf) end,
        })
    end))
end

local function adj_abort(wgt, state, why, rearm)
    local a = state.adj
    state.adj = nil
    if rearm then state.adj_walk = true end
    if wgt.values then wgt.values.rf_adj_state = rearm and nil or "failed" end
    wgt.rf_data_dirty = true
    if a then
        dbg_log("adj walk %s after %d/%d slots%s", why, (a.idx or 1) - 1,
            a.slots and #a.slots or 0, rearm and " - re-armed for disarm" or
            " - hand table stays in force")
    end
end

local function adj_step(wgt, state)
    local a = state.adj
    if a == nil then
        if not state.adj_walk then return end
        -- The OPTION gate holds HERE, before the first request: a walk that starts and
        -- then finds the option off has already spent its requests. The armed flag
        -- itself is free and stays, so flipping TbSource to FC mid-session (settings
        -- are a disarmed surface) starts the walk on the next pass.
        local src = wgt.options and wgt.options.TbSource or 1
        if src < 2 then return end
        if provider == nil then return end
        state.adj_walk = nil
        a = { phase = "ids", records = {}, idx = 1, pending = false, started = getTime() or 0 }
        state.adj = a
        if wgt.values then wgt.values.rf_adj_state = "reading" end
        wgt.rf_data_dirty = true
        dbg_log("adj walk start (TbSource=%d)", src)
    end

    local now = getTime() or 0
    if (now - (a.started or now)) > ADJ_DEADLINE_CS then
        adj_abort(wgt, state, "timeout", false)
        return
    end
    if a.pending then return end        -- one message in the shared queue, ever

    if a.phase == "ids" then
        a.pending = true
        -- MSP_GET_ADJUSTMENT_FUNCTION_IDS
        local ok = msp_enqueue(167, nil, ADJ_IDS_SIM, function(buf)
            -- one u8 function id per slot; 0 = unused. Read raw off the byte
            -- array -- no helper, no offset convention to inherit.
            local slots = {}
            for i = 1, #buf do
                if buf[i] ~= 0 then slots[#slots + 1] = i - 1 end
            end
            a.slots = slots
            a.phase, a.idx, a.pending = "ranges", 1, false
            dbg_log("adj walk: %d of %d slots used", #slots, #buf)
        end)
        if not ok then adj_abort(wgt, state, "enqueue failed", false) end
        return
    end

    -- phase "ranges": one 156 per used slot, in slot order
    if a.idx > #a.slots then
        -- complete: publish and let the Toolbox build its view out of it
        local n = #a.records
        state.adj = nil
        state.adj_table = a.records
        state.adj_gen = (state.adj_gen or 0) + 1
        if wgt.values then wgt.values.rf_adj_state = "ok" end
        wgt.rf_data_dirty = true
        dbg_log("adj table read: %d slots in %.1f s", n, (now - (a.started or now)) / 100)
        return
    end
    local slot = a.slots[a.idx]
    a.pending = true
    -- MSP_GET_ADJUSTMENT_RANGE, one slot per request
    local ok = msp_enqueue(156, { slot }, ADJ_RANGE_SIM, function(buf)
        -- 14 bytes, <BBbbBbbbbhhB (fc pg/adjustments.h; 14, not the 12 a field
        -- count suggests -- two of the twelve writes are U16). Window bounds
        -- arrive as STEPS and convert 1500 + 5*step; adjMin/adjMax stay raw.
        if #buf < 14 then
            adj_abort(wgt, state, "short reply", false)
            return
        end
        local fn = buf[1]
        if fn ~= 0 then
            a.records[#a.records + 1] = {
                slot = slot, fn = fn,
                enaCh = buf[2],
                enaS = step_us(s8(buf[3])), enaE = step_us(s8(buf[4])),
                adjCh = buf[5],
                r1s = step_us(s8(buf[6])), r1e = step_us(s8(buf[7])),
                r2s = step_us(s8(buf[8])), r2e = step_us(s8(buf[9])),
                min = s16(buf[10] + 256 * buf[11]),
                max = s16(buf[12] + 256 * buf[13]),
                step = buf[14],
            }
        end
        a.idx, a.pending = a.idx + 1, false
    end)
    if not ok then adj_abort(wgt, state, "enqueue failed", false) end
end

local function read_rf_data(wgt)
    if provider == nil then return end
    if provider == "rf2" and not (rf2 and rf2.useApi) then return end

    local state = ensure_rf_state(wgt)
    if not state.msp_allowed then return end
    -- defense-in-depth (NEVER issue MSP while armed): whatever the
    -- RFTool state claims, an armed ARM sensor blocks the reads. Callers park their
    -- pending flags (nothing is lost — the read fires on the disarm transition).
    if craft_armed(wgt) then return end

    local api = api_version()

    if provider == "rfs" then
        -- The same four reads, the same version gates, over the v1 request surface. No
        -- pcall ring around them: every request goes through ultidashRfs, which pcalls the
        -- foreign call itself and answers false -- a failure leaves the rf_* fields nil,
        -- exactly as a failed RFTool read does, and every consumer is already nil-guarded.
        rfs.read_session(type(api) == "number" and api or nil)
        state.reads_issued = getTime() or 0
        if state.connect_reads then
            if read_connect_data(wgt, state, api) then state.connect_reads = nil end
        end
        return
    end

    -- Each read in its OWN pcall: one missing/renamed API (RFTool update, or an older RFTool
    -- without mspFlightStats) must not block the other reads or crash the widget. Failed reads
    -- simply leave their wgt.values.rf_* fields nil (all consumers are already nil-guarded).
    local ok1 = pcall(function() rf2.useApi("mspBatteryProfile").read(on_battery_profile_received, wgt) end)
    local ok2 = true
    if rf2.apiVersion ~= nil then
        ok2 = pcall(function() rf2.useApi("mspBatteryConfig").read(on_battery_config_received, wgt) end)
    end
    local ok3 = pcall(function() rf2.useApi("mspFlightStats").read(on_flight_stats_received, wgt) end)
    -- governor config: gated on apiVersion like mspBatteryConfig (its getDefaults
    -- compares rf2.apiVersion); a failure just leaves rf_gov_* nil = legacy behavior
    local ok4 = true
    if rf2.apiVersion ~= nil then
        ok4 = pcall(function() rf2.useApi("mspGovernorConfig").read(on_governor_config_received, wgt) end)
    end
    if not (ok1 and ok2 and ok3 and ok4) then log_api_err(state) end
    -- the holdoff reference for the adjustment-table walk: MSP is on the wire as of here,
    -- and ok2 above is the request whose reply the startup cell check is waiting for
    state.reads_issued = getTime() or 0

    -- ...and the three once-per-connect reads, on the SAME two gates as the four above --
    -- they are issued from inside this function on purpose, so there is exactly one place
    -- in the widget that can put MSP on the wire and exactly one arming gate to audit.
    -- The flag is cleared only when the reads were actually ISSUED; a connect that arrives
    -- before rf2.apiVersion is known keeps owing them and spends them on the next pass.
    if state.connect_reads then
        if read_connect_data(wgt, state, api) then state.connect_reads = nil end
    end
end

function M.on_state_changed(wgt, new_state, on_telemetry_state_changed)
    ensure_rf_state(wgt)
    -- Normalize: the RFTool callback can deliver transient handshake
    -- states ("initializing", ...). Map "ready" like the poll path and
    -- DROP everything outside the four known states — the follow-up
    -- connected/disarmed of the same handshake lands moments later.
    -- Keeps rf_connection_state consumer-safe (formatters/gates know
    -- only these four).
    if new_state == "ready" then new_state = "connected" end
    if new_state ~= "armed" and new_state ~= "disarmed"
        and new_state ~= "connected" and new_state ~= "disconnected" then
        return
    end
    local previous_state = wgt.rf.last_state
    if wgt.rf.last_state == new_state then return end
    wgt.rf.last_state = new_state
    wgt.rf.msp_allowed = (new_state == "connected" or new_state == "disarmed")

    wgt.values.rf_connection_state = new_state

    -- FC-config caches (battery thresholds/capacity/cell count, governor mode)
    -- survive an ARMED disconnect: the FC config cannot change mid-flight,
    -- and after a telemetry blip the re-read parks until disarm (msp_allowed) — the
    -- old on-reconnect clear dropped the alert thresholds to defaults, lost the fuel
    -- basis and degenerated the OFF/LIMIT gov gate for the rest of the flight. Clear
    -- only on a real session end: the craft was DISARMED (or never seen) when the
    -- link dropped, so a model change / unplug still wipes immediately. The
    -- reconnect path only schedules the re-read (read_pending below);
    -- rf_battery_profile seeds -1 (not nil) so the battery-profile picker shows
    -- "unknown" until that read lands.
    if new_state == "disconnected" and previous_state ~= "armed" then
        wgt.values.rf_battery_profile = -1
        for i = 1, #RF_SESSION_KEYS do wgt.values[RF_SESSION_KEYS[i]] = nil end
        wgt.rf.crsf_slots = nil
        -- the adjustment table is FC config like everything above: it survives an ARMED
        -- disconnect (a blip cannot change adjfunc lines) and dies with the session. The
        -- gen bump is the rebuild signal for an open Toolbox page -- back to the hand table.
        if wgt.rf.adj_table ~= nil then
            wgt.rf.adj_table = nil
            wgt.rf.adj_gen = (wgt.rf.adj_gen or 0) + 1
        end
    end

    -- The once-per-connect reads are owed on every fresh connection: from a cold start
    -- (previous_state nil, which background() also produces when the rf2 global itself is
    -- replaced) and after a real link drop. NOT on an ordinary arm/disarm cycle -- that is
    -- what keeps a later disarm at 4 requests instead of 7.
    if (previous_state == nil or previous_state == "disconnected")
        and (new_state == "connected" or new_state == "disarmed") then
        wgt.rf.connect_reads = true
        -- The ELRS module scan rides the SAME trigger. It does not go to the flight
        -- controller at all (the TX module is local, no OTA traffic), but every request
        -- it makes replaces an RC channel frame, so it gets the same connect-only
        -- cadence and the same arming gate as the MSP reads. See ultidashElrs.
        wgt.rf.elrs_scan = true
        -- ...and so does the adjustment-table walk (T2). The flag is free; the TbSource
        -- option gates the first REQUEST inside adj_step, per the trigger rule -- and
        -- adj_may_start holds that request until the connect reads have been answered.
        wgt.rf.adj_walk = true
        wgt.rf.reads_issued = nil       -- a fresh connect owes its reads again
    end

    if on_telemetry_state_changed then
        on_telemetry_state_changed(wgt, previous_state, new_state)
    end

    if new_state == "connected" or new_state == "disarmed" then
        -- debounced: timestamp the request; background() fires it once the state settles,
        -- so the connect-handshake bounce collapses into a single MSP read
        wgt.rf.read_pending = getTime() or 0
    elseif new_state == "disconnected" then
        wgt.rf.read_pending = nil
        -- a walk in progress dies with the link: a PARTIAL table must never become the
        -- rendered one (half a grid claiming completeness), so nothing of it is kept
        if wgt.rf.adj ~= nil then
            wgt.rf.adj = nil
            wgt.values.rf_adj_state = nil
        end
        wgt.rf_data_dirty = true
    end
end

function M.init(wgt, on_telemetry_state_changed, is_armed, dbg, elrs, rfs_load)
    ensure_rf_state(wgt)
    if is_armed ~= nil then armed_check = is_armed end
    -- background() calls M.init with two arguments; both hooks are therefore installed on
    -- the create()-time call only and are module-local (the RF service runs on one
    -- publisher). Never overwrite an installed hook with the nil of a two-argument call.
    if dbg ~= nil then dbg_get = dbg end
    -- 5th: the ELRS TX configuration client. Handed in rather than loaded here so the
    -- host keeps every loadScript in one place, and so a build without it simply has
    -- no ELRS scan instead of failing to load the RF service.
    if elrs ~= nil then elrs_module = elrs end
    -- 6th: a LOADER for the RFSuite service back end, for the same reason and one step
    -- further -- it is not even called until `rfsuite.msp` is seen in this Lua state, so
    -- the load lands on the card that has the second provider and on no other.
    if rfs_load ~= nil then rfs_loader = rfs_load end
    if not wgt.rf.callback_installed then
        wgt.onStateChanged = function(widget, new_state)
            M.on_state_changed(widget, new_state, on_telemetry_state_changed)
        end
        wgt.rf.callback_installed = true
    end
    return wgt.rf
end

-- The Status row: WHO is serving, and for the second provider whether anybody is pumping.
-- "present" and "active" are different claims and a pilot chasing missing values needs them
-- apart. Called on a change only -- never per pass, because two of the four cases build a
-- string and this runs off screen as well.
-- `level`: 0 = no RFSuite in this state, 1 = RFSuite without a consumer surface, 2 = the
-- service published. Level 2 with no serving provider is the one case worth its own words:
-- the surface is there and OUR back end is not, which means ultidashRfs.lua did not reach
-- the card -- a deploy fault, and it must not read as RFSuite's shortcoming.
local function note_provider(wgt, kind, level)
    if wgt.values == nil then return end
    if kind == "rf2" then
        wgt.values.rf_provider_text = (level > 0) and "RFTool  (RFSuite also seen)" or "RFTool"
    elseif kind == "rfs" then
        wgt.values.rf_provider_text = rfs.provider_text()
    elseif level == 2 then
        wgt.values.rf_provider_text = "RFSuite service (no back end)"
    elseif level == 1 then
        wgt.values.rf_provider_text = "RFSuite (no API)"
    else
        wgt.values.rf_provider_text = nil
    end
end

function M.background(wgt, on_telemetry_state_changed)
    local state = M.init(wgt, on_telemetry_state_changed)

    -- Who is in this Lua state. The second provider costs two table reads per pass on every
    -- card, and the module behind it is loaded only when they both answer.
    local rf2_there = rf2 ~= nil and type(rf2.registerWidget) == "function" and rf2.useApi ~= nil
    local rfs_level = 0
    if type(_G.rfsuite) == "table" then
        rfs_level = (type(_G.rfsuite.msp) == "table") and 2 or 1
    end
    local kind, ref = nil, nil
    if rf2_there then
        kind, ref = "rf2", rf2
    elseif rfs_level == 2 and rfs_module() ~= nil then
        kind, ref = "rfs", _G.rfsuite.msp
    end
    provider = kind
    local provider_available = kind ~= nil

    -- also re-init when the provider's own global was replaced (an RFTool reload, an
    -- RFSuite reload), not only when availability changed — otherwise we keep a stale
    -- registration and stop getting the onStateChanged callbacks (gismo2004's HeliDash fix;
    -- critical here because the callback is the ONLY state channel a real RFTool has — see
    -- note_tool_api below).
    local provider_changed = state.provider_ref ~= ref or state.provider_kind ~= kind

    if provider_changed or provider_available ~= state.available then
        -- Leaving the service: hand the client back rather than leaving a registration on a
        -- runtime we no longer read. Everything still queued for us goes with it.
        if state.provider_kind == "rfs" and kind ~= "rfs" and rfs ~= nil then rfs.detach() end
        state.available = provider_available
        state.provider_ref = ref
        state.provider_kind = kind
        state.is_registered = false
        state.msp_allowed = false
        -- a replaced global may be a different RFTool build: read its version again
        state.tool_api_read = nil

        if provider_available then
            state.last_state = nil
        else
            if wgt.values then wgt.values.rf_tool_api_text = nil end
            note_provider(wgt, nil, rfs_level)
            state.rfs_seen = rfs_level
            M.on_state_changed(wgt, "disconnected", on_telemetry_state_changed)
            return
        end
    elseif not provider_available then
        -- Still nobody serving. The row can still MOVE here — upstream RFSuite loading into
        -- a state that has no RFTool is exactly this case — so it is compared, not rebuilt.
        if state.rfs_seen ~= rfs_level then
            state.rfs_seen = rfs_level
            note_provider(wgt, nil, rfs_level)
        end
        return
    end

    -- The row also moves when the OTHER provider appears beside the serving one.
    if state.rfs_seen ~= rfs_level or provider_changed then
        state.rfs_seen = rfs_level
        note_provider(wgt, kind, rfs_level)
    end

    if kind == "rfs" then
        -- The service has no callback channel like RFTool's onStateChanged, so the
        -- connection state is POLLED off rfsuite.session.isConnected — the events runtime's
        -- own hysteresis (0.6 s up / 2.0 s down), which means a live link and not merely
        -- that code is loaded — and turned into the same four states every consumer in this
        -- widget already knows. Armed/disarmed is ours to decide: the ARM sensor, exactly
        -- as the MSP read gate uses it.
        if not state.is_registered then
            if rfs.attach() ~= nil then state.is_registered = true end
        end
        local st = "disconnected"
        if rfs.connected() then st = craft_armed(wgt) and "armed" or "disarmed" end
        if st ~= state.last_state then
            M.on_state_changed(wgt, st, on_telemetry_state_changed)
            note_provider(wgt, kind, rfs_level)  -- active <-> idle moves with this
        end
        -- Decode whatever came back, on OUR pass and in OUR budget: the reply callbacks run
        -- inside the suite's queue processing, inside a FOREIGN widget's 20k instructions.
        rfs.poll(wgt, RFS_HANDLERS)
    else
        if not state.is_registered then
            -- pcall'd: an RFTool-version mismatch here crashed the widget Lua
            -- state. On failure stay unregistered (retried next pass, the pcall is cheap)
            -- and log once.
            if pcall(rf2.registerWidget, wgt) then
                state.is_registered = true
            else
                log_api_err(state)
            end
        end

        note_tool_api(wgt, state)
    end

    -- Debounced MSP read: fire ONE read once the connection state has been stable for
    -- RF_READ_SETTLE_CS (collapses the connect-handshake bounce — see on_state_changed).
    if state.read_pending and state.msp_allowed then
        local now = getTime() or 0
        if (now - state.read_pending) >= RF_READ_SETTLE_CS then
            -- ARM-sensor gate: a mid-flight blip's handshake can pass
            -- through a >settle "connected" window — never fire the connect reads
            -- while the ARM sensor still reports armed. PARK the request (don't
            -- clear it), so it fires on the first disarmed pass.
            if not craft_armed(wgt) then
                state.read_pending = nil
                read_rf_data(wgt)
            end
        end
    end

    -- ELRS TX module scan: owed once per connect, and it PUSHES CRSF frames, so it
    -- takes the same ARM-sensor gate as everything above -- one pushed frame is one
    -- RC channel update not sent (EdgeTX setupPulsesCrossfire). Parked, not dropped:
    -- elrs_scan is cleared only where the scan actually starts, so a connect that
    -- arrives armed spends it on the first disarmed pass. A scan already in flight
    -- when the craft arms is ABORTED and keeps what it has.
    if elrs_module ~= nil then
        if craft_armed(wgt) then
            elrs_module.abort(wgt)
        else
            if state.elrs_scan then
                state.elrs_scan = nil
                elrs_module.start(wgt)
            end
            elrs_module.poll(wgt)
        end
    end

    -- T2 adjustment-table walk: the same two gates as every MSP read above. A walk
    -- interrupted by arming is ABORTED and re-armed rather than resumed -- adjfunc
    -- lines cannot change in flight, so a fresh walk on the disarm flank costs a few
    -- seconds on the ground and can never publish a table read across a flight.
    if craft_armed(wgt) then
        if state.adj ~= nil then adj_abort(wgt, state, "aborted by arm", true) end
    elseif state.msp_allowed and adj_may_start(wgt, state) then
        adj_step(wgt, state)
    end
end

--- Switch the ACTIVE battery profile via the RFTool MSP API.
--- Writes MSP 176 (MSP_SET_BATTERY_PROFILE, the same call the RFTool's own
--- batSwitcher uses), then persists WITHOUT an FC reboot via
--- rf2.settingsSaved(true, false) — the no-reboot path (cf. rotorflight-lua-scripts
--- commit 4fbe4b9, which flipped the battery page's reboot flag true→false). Finally
--- re-reads so the dashboard reflects the new profile's capacity/thresholds.
--- DISARMED ONLY (msp_allowed AND the ARM sensor); the FC also rejects config writes
--- while armed.
--- index is 0-based (0..5 = profile 1..6). Returns true if the write was queued.
local function set_battery_profile(wgt, index)
    if provider == nil then return false end
    if provider == "rf2" and not (rf2 and rf2.useApi) then return false end
    if type(index) ~= "number" or index < 0 or index > 5 then return false end
    local state = ensure_rf_state(wgt)
    if not state.msp_allowed then return false end
    -- defense-in-depth, exactly as read_rf_data has it: msp_allowed flips only on the
    -- RFTool callback, which lags the ARM sensor and on documented setups never reports
    -- the armed sub-state at all. A picker press inside the close-on-arm window reached
    -- the write. The ARM sensor decides armed-questions, so the "DISARMED ONLY" above is
    -- now true of the only MSP WRITE this widget makes.
    if craft_armed(wgt) then return false end

    if provider == "rfs" then
        -- The same two messages RFTool's batSwitcher sends, written out rather than
        -- borrowed: MSP 176, then MSP_EEPROM_WRITE with no reboot. The service has no
        -- settingsSaved of its own to call, and reaching into RFSuite's save path would be
        -- exactly the borrow this provider exists to avoid.
        if not rfs.set_battery_profile(index) then return false end
    else
        local ok = pcall(function()
            rf2.useApi("mspBatteryProfile").write({ batteryProfile = { value = index } })
        end)
        if not ok then return false end

        -- persist to eeprom, NO reboot (second arg = reboot flag). pcall'd: a failure
        -- here still leaves the profile switched live, just not saved across a power cycle.
        pcall(function()
            if type(rf2.settingsSaved) == "function" then rf2.settingsSaved(true, false) end
        end)
    end

    wgt.values.rf_battery_profile = index
    wgt.values.rf_battery_profile_active = index
    read_rf_data(wgt)     -- queued AFTER the write/save → returns the new profile state
    wgt.rf_data_dirty = true
    return true
end

--- Request a fresh MSP read of the battery profile/config/stats (DISARMED ONLY).
--- Used to refresh the battery-profile picker when it opens, so it shows the FC's
--- real current profile instead of a value cached at connect time.
local function refresh_data(wgt)
    local state = ensure_rf_state(wgt)
    if not state.msp_allowed then return false end
    read_rf_data(wgt)
    return true
end

--- Capacity (mAh) of a battery profile (0-based index) if the FC reports per-profile
--- capacities (MSP API >= 12.09: battery_config.batteryCapacity is a [0..5] table);
--- nil otherwise (older API exposes only the active profile's single value).
local function get_profile_capacity(wgt, index)
    local cfg = ensure_rf_state(wgt).battery_config
    local bc = cfg and cfg.batteryCapacity
    if type(bc) ~= "table" then return nil end
    local entry = bc[index]
    if type(entry) == "table" and entry.value then return entry.value end
    return nil
end

M.sync_active_battery_capacity = sync_active_battery_capacity
M.set_battery_profile = set_battery_profile
M.get_profile_capacity = get_profile_capacity
M.refresh_data = refresh_data

return M
