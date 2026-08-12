local M = {}

local function ensure_rf_state(wgt)
    wgt.rf = wgt.rf or {
        available = false,
        provider_ref = nil,
        is_registered = false,
        last_state = nil,
        msp_allowed = false,
        battery_profile = nil,
        battery_config = nil,
        governor_config = nil,
        flight_stats = nil,
        callback_installed = false,
        read_pending = nil          -- debounced MSP read request (see read_rf_data/background)
    }
    return wgt.rf
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
    return tostring(seconds or 0) .. "s"
end

-- Report an rf2 API failure ONCE per session (goes to the console + the file log when
-- DebugLog is on); a mismatch would otherwise repeat on every read.
local function log_api_err(state)
    if not state.api_err_logged then
        state.api_err_logged = true
        print("[UltiDash] rf2 API call failed (RFTool version mismatch?)")
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
    if mode == nil then
        wgt.values.rf_gov_has_state = nil
    elseif type(rf2.apiVersion) == "number" and rf2.apiVersion < 12.09 then
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

    wgt.rf_data_dirty = true
end

local function on_flight_stats_received(wgt, stats)
    ensure_rf_state(wgt).flight_stats = stats
    wgt.values.rf_total_flights = stats and stats.stats_total_flights and stats.stats_total_flights.value
    wgt.values.rf_total_flight_time = stats and stats.stats_total_time_s and stats.stats_total_time_s.value
    wgt.values.rf_total_flight_time_formatted = format_seconds(wgt.values.rf_total_flight_time)

    wgt.rf_data_dirty = true
end

local function read_rf_data(wgt)
    if not rf2 or not rf2.useApi then return end

    local state = ensure_rf_state(wgt)
    if not state.msp_allowed then return end
    -- defense-in-depth (NEVER issue MSP while armed): whatever the
    -- RFTool state claims, an armed ARM sensor blocks the reads. Callers park their
    -- pending flags (nothing is lost — the read fires on the disarm transition).
    if craft_armed(wgt) then return end

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
        wgt.values.rf_battery_capacity_mah = nil
        wgt.values.rf_battery_cell_count = nil
        wgt.values.rf_cell_warning_voltage = nil
        wgt.values.rf_cell_alarm_voltage = nil
        wgt.values.rf_cell_full_voltage = nil
        wgt.values.rf_gov_mode = nil
        wgt.values.rf_gov_mode_name = nil
        wgt.values.rf_gov_mode_label = nil
        wgt.values.rf_gov_has_state = nil
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
        wgt.rf_data_dirty = true
    end
end

function M.init(wgt, on_telemetry_state_changed, is_armed)
    ensure_rf_state(wgt)
    if is_armed ~= nil then armed_check = is_armed end
    if not wgt.rf.callback_installed then
        wgt.onStateChanged = function(widget, new_state)
            M.on_state_changed(widget, new_state, on_telemetry_state_changed)
        end
        wgt.rf.callback_installed = true
    end
    return wgt.rf
end

function M.background(wgt, on_telemetry_state_changed)
    local state = M.init(wgt, on_telemetry_state_changed)
    local provider_available = rf2 ~= nil and type(rf2.registerWidget) == "function" and rf2.useApi ~= nil
    -- also re-init when the rf2 global itself was replaced (RFTool reload), not only when
    -- availability changed — otherwise we keep a stale registration and stop getting the
    -- onStateChanged callbacks (gismo2004's HeliDash fix; critical here since rfToolState
    -- is nil on this RFTool, so state arrives ONLY via the callback).
    local provider_changed = state.provider_ref ~= rf2

    if provider_changed or provider_available ~= state.available then
        state.available = provider_available
        state.provider_ref = rf2
        state.is_registered = false
        state.msp_allowed = false

        if provider_available then
            state.last_state = nil
        else
            M.on_state_changed(wgt, "disconnected", on_telemetry_state_changed)
            return
        end
    elseif not provider_available then
        return
    end

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

    local current_state = rf2.rfToolState
    if current_state == "ready" then
        current_state = "connected"
    end

    if current_state == "armed" or current_state == "disarmed" or current_state == "connected" or current_state == "disconnected" then
        M.on_state_changed(wgt, current_state, on_telemetry_state_changed)
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
    if not rf2 or not rf2.useApi then return false end
    if type(index) ~= "number" or index < 0 or index > 5 then return false end
    local state = ensure_rf_state(wgt)
    if not state.msp_allowed then return false end
    -- defense-in-depth, exactly as read_rf_data has it: msp_allowed flips only on the
    -- RFTool callback, which lags the ARM sensor and on documented setups never reports
    -- the armed sub-state at all. A picker press inside the close-on-arm window reached
    -- the write. The ARM sensor decides armed-questions, so the "DISARMED ONLY" above is
    -- now true of the only MSP WRITE this widget makes.
    if craft_armed(wgt) then return false end

    local ok = pcall(function()
        rf2.useApi("mspBatteryProfile").write({ batteryProfile = { value = index } })
    end)
    if not ok then return false end

    -- persist to eeprom, NO reboot (second arg = reboot flag). pcall'd: a failure
    -- here still leaves the profile switched live, just not saved across a power cycle.
    pcall(function()
        if type(rf2.settingsSaved) == "function" then rf2.settingsSaved(true, false) end
    end)

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
