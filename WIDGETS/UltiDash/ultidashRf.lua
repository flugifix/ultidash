local M = {}

local function ensure_rf_state(wgt)
    wgt.rf = wgt.rf or {
        available = false,
        is_registered = false,
        last_state = nil,
        msp_allowed = false,
        battery_profile = nil,
        battery_config = nil,
        flight_stats = nil,
        callback_installed = false
    }
    return wgt.rf
end

local function format_seconds(seconds)
    if rf2 and rf2.executeScript then
        return rf2.executeScript("F/formatSeconds")(seconds or 0)
    end
    return tostring(seconds or 0) .. "s"
end

local function sync_active_battery_capacity(wgt)
    local config = ensure_rf_state(wgt).battery_config
    local profile_value = wgt.values.rf_battery_profile
    local capacity_value = nil

    if config and config.batteryCapacity then
        if type(config.batteryCapacity) == "table" and profile_value ~= nil and profile_value >= 0 then
            if profile_value > 0 and config.batteryCapacity[profile_value - 1] then
                capacity_value = config.batteryCapacity[profile_value - 1].value
            elseif config.batteryCapacity[profile_value] then
                capacity_value = config.batteryCapacity[profile_value].value
            end
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
    sync_active_battery_capacity(wgt)

    wgt.rf_data_dirty = true
end

local function on_battery_config_received(wgt, config)
    ensure_rf_state(wgt).battery_config = config
    wgt.values.rf_battery_cell_count = config and config.batteryCellCount and config.batteryCellCount.value
    wgt.values.rf_cell_warning_voltage = config and config.vbatwarningcellvoltage and config.vbatwarningcellvoltage.value
    wgt.values.rf_cell_alarm_voltage = config and config.vbatmincellvoltage and config.vbatmincellvoltage.value
    sync_active_battery_capacity(wgt)

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

    rf2.useApi("mspBatteryProfile").read(on_battery_profile_received, wgt)
    if rf2.apiVersion ~= nil then
        rf2.useApi("mspBatteryConfig").read(on_battery_config_received, wgt)
    end
    rf2.useApi("mspFlightStats").read(on_flight_stats_received, wgt)
end

function M.on_state_changed(wgt, new_state, on_telemetry_state_changed)
    ensure_rf_state(wgt)
    local previous_state = wgt.rf.last_state
    if wgt.rf.last_state == new_state then return end
    wgt.rf.last_state = new_state
    wgt.rf.msp_allowed = (new_state == "connected" or new_state == "disarmed")

    wgt.values.rf_connection_state = new_state

    if previous_state == "disconnected" and new_state == "connected" then
        wgt.values.rf_battery_profile = -1
        wgt.values.rf_battery_capacity_mah = nil
        wgt.values.rf_battery_cell_count = nil
        wgt.values.rf_cell_warning_voltage = nil
        wgt.values.rf_cell_alarm_voltage = nil
    end

    if on_telemetry_state_changed then
        on_telemetry_state_changed(wgt, previous_state, new_state)
    end

    if new_state == "connected" or new_state == "disarmed" then
        read_rf_data(wgt)
    elseif new_state == "disconnected" then
        wgt.rf_data_dirty = true
    end
end

function M.init(wgt, on_telemetry_state_changed)
    ensure_rf_state(wgt)
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

    if provider_available ~= state.available then
        state.available = provider_available
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
        rf2.registerWidget(wgt)
        state.is_registered = true
    end

    local current_state = rf2.rfToolState
    if current_state == "ready" then
        current_state = "connected"
    end

    if current_state == "armed" or current_state == "disarmed" or current_state == "connected" or current_state == "disconnected" then
        M.on_state_changed(wgt, current_state, on_telemetry_state_changed)
    end
end

M.sync_active_battery_capacity = sync_active_battery_capacity

return M
