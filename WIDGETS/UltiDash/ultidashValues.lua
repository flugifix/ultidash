local M = {}

-- color palette shadows (see ultidash.lua); swapped via M.set_palette
local COLOR_THEME_PRIMARY1   = COLOR_THEME_PRIMARY1
local COLOR_THEME_PRIMARY2   = COLOR_THEME_PRIMARY2
local COLOR_THEME_SECONDARY1 = COLOR_THEME_SECONDARY1
local COLOR_THEME_SECONDARY2 = COLOR_THEME_SECONDARY2
local COLOR_THEME_SECONDARY3 = COLOR_THEME_SECONDARY3
local COLOR_THEME_FOCUS      = COLOR_THEME_FOCUS
local COLOR_THEME_WARNING    = COLOR_THEME_WARNING
local COLOR_THEME_DISABLED   = COLOR_THEME_DISABLED
local THEME_PALETTE = {
    COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2,
    COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS, COLOR_THEME_WARNING, COLOR_THEME_DISABLED,
}
local CLEAN_PALETTE = {
    lcd.RGB(0x00, 0x00, 0x00), lcd.RGB(0xF8, 0xFC, 0xF8), lcd.RGB(0x00, 0x00, 0x00), lcd.RGB(0x98, 0xB4, 0xE8),
    lcd.RGB(0xD8, 0xE0, 0xE8), lcd.RGB(0xC0, 0x30, 0x38), lcd.RGB(0xE8, 0x30, 0x30), lcd.RGB(0xF8, 0x3C, 0x00),
}
local DARK_PALETTE = {
    lcd.RGB(0xFF, 0xFF, 0xFF), lcd.RGB(0x08, 0x0A, 0x0C), lcd.RGB(0xF0, 0xF4, 0xF8), lcd.RGB(0x39, 0xFF, 0x14),
    lcd.RGB(0x08, 0x0A, 0x0C), lcd.RGB(0x00, 0xE5, 0xFF), lcd.RGB(0xFF, 0x1A, 0x40), lcd.RGB(0xFF, 0xC4, 0x00),
}

-- scheme: 1 = UltiDash (clean), 2 = EdgeTX theme, 3 = UltiDash dark (high contrast)
function M.set_palette(scheme)
    local p = (scheme == 3) and DARK_PALETTE or ((scheme == 1) and CLEAN_PALETTE or THEME_PALETTE)
    COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2 = p[1], p[2], p[3], p[4]
    COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS, COLOR_THEME_WARNING, COLOR_THEME_DISABLED = p[5], p[6], p[7], p[8]
end

-- Battery cell-voltage thresholds come from the Rotorflight FC (mspBatteryConfig:
-- vbatfull/warning/min cellvoltage), fetched on connect/disarm. These DEFAULT_* are only
-- internal safety values for the brief window before the FC config has been received —
-- there is intentionally no widget-option fallback (the dashboard is Rotorflight-only).
local DEFAULT_CELL_FULL_VOLTAGE = 4.1
local DEFAULT_CELL_WARNING_VOLTAGE = 3.3
local DEFAULT_CELL_ALARM_VOLTAGE = 3.2
local GOV_STATE_LABELS = {
    [0] = "Throttle off",
    [1] = "Throttle Idle",
    [2] = "Spooling up",
    [3] = "Recovery",
    [4] = "Gov. Active",
    [5] = "Throttle Hold",
    [6] = "Gov. Fallback",
    [7] = "Autorotation",
    [8] = "Bailing Out"
}

local function normalize_cell_voltage(raw_value, fallback)
    if raw_value == nil or raw_value <= 0 then return fallback end
    if raw_value > 20 then return raw_value / 100 end
    return raw_value
end

local function use_total_voltage_display(wgt)
    return wgt.options and wgt.options.VoltageDisplay == 2
end

local function get_effective_cell_count(wgt)
    local cell_count = wgt.values.cel_count or wgt.values.rf_battery_cell_count
    if cell_count == nil or cell_count <= 0 then return nil end
    return cell_count
end

-- Cell-voltage thresholds: from the FC (mspBatteryConfig) or manual options, per the
-- CellSource option (1 = FC config, 2 = Manual). Manual option values are in centivolts.
local function use_manual_cell_thresholds(wgt)
    return wgt.options and wgt.options.CellSource == 2
end

local function get_cell_warning_threshold(wgt)
    if use_manual_cell_thresholds(wgt) then return (wgt.options.CellLow or 345) / 100 end
    return normalize_cell_voltage(wgt.values.rf_cell_warning_voltage, DEFAULT_CELL_WARNING_VOLTAGE)
end

local function get_cell_alarm_threshold(wgt)
    if use_manual_cell_thresholds(wgt) then return (wgt.options.CellCritical or 330) / 100 end
    return normalize_cell_voltage(wgt.values.rf_cell_alarm_voltage, DEFAULT_CELL_ALARM_VOLTAGE)
end

local function get_cell_full_threshold(wgt)
    if use_manual_cell_thresholds(wgt) then return (wgt.options.CellFull or 412) / 100 end
    return normalize_cell_voltage(wgt.values.rf_cell_full_voltage, DEFAULT_CELL_FULL_VOLTAGE)
end

local function get_display_voltage_threshold(wgt, cell_threshold)
    if cell_threshold == nil then return nil end
    if not use_total_voltage_display(wgt) then return cell_threshold end

    local cell_count = get_effective_cell_count(wgt)
    if cell_count == nil then return nil end
    return cell_threshold * cell_count
end

local function get_cell_voltage_color_for_value(wgt, voltage)
    if voltage == nil or voltage <= 0 then return COLOR_THEME_PRIMARY1 end

    local alarm_voltage = get_cell_alarm_threshold(wgt)
    local warning_voltage = math.max(alarm_voltage, get_cell_warning_threshold(wgt))

    if voltage <= alarm_voltage then return COLOR_THEME_WARNING end
    if voltage <= warning_voltage then return YELLOW end
    return COLOR_THEME_PRIMARY1
end

local function get_display_voltage_color_for_value(wgt, voltage)
    if voltage == nil or voltage <= 0 then return COLOR_THEME_PRIMARY1 end

    local alarm_voltage = get_display_voltage_threshold(wgt, get_cell_alarm_threshold(wgt))
    local warning_voltage = get_display_voltage_threshold(wgt, get_cell_warning_threshold(wgt))
    if alarm_voltage == nil or warning_voltage == nil then return COLOR_THEME_PRIMARY1 end

    warning_voltage = math.max(alarm_voltage, warning_voltage)

    if voltage <= alarm_voltage then return COLOR_THEME_WARNING end
    if voltage <= warning_voltage then return YELLOW end
    return COLOR_THEME_PRIMARY1
end

-- Built ONCE at module load: this is read on the status-bar hot path (every frame
-- while arming is disabled), and rebuilding the whole table per call churned the GC.
local ARM_DISABLE_FLAG_NAMES = {
    [0] = "No Gyro",
    [1] = "Fail Safe",
    [2] = "RX Fail Safe",
    [3] = "Bad RX Recovery",
    [4] = "Box Fail Safe",
    [5] = "Governor",
    [6] = "RPM Signal",
    [7] = "Throttle",
    [8] = "Angle",
    [9] = "Boot Grace Time",
    [10] = "No Pre Arm",
    [11] = "Load",
    [12] = "Calibrating",
    [13] = "CLI",
    [14] = "CMS Menu",
    [15] = "BST",
    [16] = "MSP",
    [17] = "Paralyze",
    [18] = "GPS",
    [19] = "Resc",
    [20] = "RPM Filter",
    [21] = "Reboot Required",
    [22] = "DSHOT Bitbang",
    [23] = "Acc Calibration",
    [24] = "Motor Protocol"
}

local function get_arming_disable_flag_names()
    -- the last two indices depend on the FC API version; set them on the cached table
    -- (cheap, no allocation) instead of rebuilding the whole 27-entry table each call
    if rf2 and rf2.apiVersion and rf2.apiVersion >= 12.09 then
        ARM_DISABLE_FLAG_NAMES[25] = "Override"
        ARM_DISABLE_FLAG_NAMES[26] = "Arm Switch"
    else
        ARM_DISABLE_FLAG_NAMES[25] = "Arm Switch"
        ARM_DISABLE_FLAG_NAMES[26] = nil
    end
    return ARM_DISABLE_FLAG_NAMES
end

local function get_arming_disable_flags_list(flags)
    if flags == nil or flags == 0 then return nil end

    local flag_names = get_arming_disable_flag_names()
    local result = {}

    for i = 0, 26 do
        if (flags & (1 << i)) ~= 0 and flag_names[i] then
            result[#result + 1] = flag_names[i]
        end
    end

    if #result == 0 then return nil end
    return result
end

-- Cache the resolved list per raw flags value: BOTH the status-bar visibility check
-- AND the cycling text getter ask for it every frame, but arm_disable_flags only
-- changes on the 5 Hz telemetry pass — so recompute (and allocate) only on change.
local function arm_disable_flags_list_cached(wgt)
    local flags = wgt.values.arm_disable_flags
    local c = wgt.arm_flags_cache
    if c and c.flags == flags then return c.list end
    local list = get_arming_disable_flags_list(flags)
    wgt.arm_flags_cache = { flags = flags, list = list }
    return list
end

local function get_current_arm_disable_flag(wgt)
    local flags = arm_disable_flags_list_cached(wgt)
    if not flags then
        wgt.flag_cycle_time = nil
        wgt.flag_cycle_index = 0
        return nil
    end

    if not wgt.flag_cycle_time then wgt.flag_cycle_time = getTime() end
    wgt.flag_cycle_index = (wgt.flag_cycle_index or 0) % #flags

    local now = getTime()
    if now - wgt.flag_cycle_time >= 200 then
        wgt.flag_cycle_index = (wgt.flag_cycle_index + 1) % #flags
        wgt.flag_cycle_time = now
    end

    return flags[wgt.flag_cycle_index + 1]
end

-- ---------------------------------------------------------------------------
-- Reactive-getter memoisation. The *_formatted getters below are bound as LVGL
-- label texts and run EVERY render frame, but the underlying telemetry only changes
-- on the 5 Hz pass. sfmt() re-runs string.format (the allocation) ONLY when the
-- value actually changed, else it returns the cached string — so a steady display
-- produces ~zero per-frame garbage. `pattern`/`nilstr` MUST be string literals
-- (interned, not allocated per call); never pass a freshly built string or a
-- per-call closure here, that would defeat the purpose. Cache lives on wgt (per
-- instance), keyed by value, so it is always correct across rebuilds.
-- ---------------------------------------------------------------------------
local function sfmt(wgt, slot, v, pattern, nilstr)
    local cache = wgt.fmt_cache
    if cache == nil then cache = {}; wgt.fmt_cache = cache end
    local e = cache[slot]
    if e ~= nil and e.v == v then return e.s end
    local s
    if v == nil then s = nilstr or "-" else s = string.format(pattern, v) end
    if e ~= nil then e.v = v; e.s = s else cache[slot] = { v = v, s = s } end
    return s
end

function M.createValues(wgt)
    return {
        label_current = "Current",
        label_fuel = "Fuel",
        label_capacity = "Energy Used (mAh)",
        label_esc_temp = "ESC Temp",
        label_battery_voltage = "Batt Voltage",
        label_headspeed = "Headspeed",
        label_bec_voltage = "BEC Voltage",
        label_profile = "Profile",
        label_rate = "Rate",
        label_battery_profile = "Batt Profile",
        label_battery_profile_short = "B-Profile",
        label_battery_profile_shorter = "B-Prof",
        label_battery_profile_tiny = "Batt",
        label_arm_state = "Arm State",
        label_governor = "Governor State",
        label_timer = "Timer",
        label_tpwr = "TPWR+",
        label_rqly = "RQly-",
        label_mcu_temp_max = "Tmcu+",
        label_armed = "Armed",
        label_disarmed = "Disarmed",
        label_connected = "Connected",
        label_disconnected = "Disconnected",
        label_flight_stats = "Flight Statistics",
        label_flight_time = "Flight Time",
        label_total_flight_time = "Total Flight Time",
        label_total_flights = "Flights",
        label_capacity_used_short = "mAh Used",
        label_tx_batt = "TX Battery",
        label_model_card = "Model",
        label_status = "Status",
        label_actual = "Latest",
        label_min = "Min",
        label_max = "Max",
        label_esc_t = "ESC T",
        label_cell_v = "Cell Voltage",
        label_bec_v = "BEC V",
        label_curr = "CURR",
        label_model = "Model: ",
        label_skp = "Skp",
        label_rqly_cur = "RQly",
        label_tqly = "TQly",
        label_tpwr_cur = "TPWR",

        -- These getters run as REACTIVE label texts (per LVGL frame, ~20 Hz) — they
        -- must never do sensor NAME lookups themselves. All four values are cached
        -- by update_elrs in the 5 Hz pass (skp_raw, elrs_rq/tq/tpwr).
        skp_formatted = function()
            local v = wgt.values.skp_raw
            return sfmt(wgt, "skp", v ~= nil and math.floor(v) or nil, "%d")
        end,
        rqly_cur_formatted = function() return sfmt(wgt, "rqly_cur", wgt.values.elrs_rq, "%d%%") end,
        tqly_cur_formatted = function() return sfmt(wgt, "tqly_cur", wgt.values.elrs_tq, "%d%%") end,
        tpwr_cur_formatted = function() return sfmt(wgt, "tpwr_cur", wgt.values.elrs_tpwr, "%dmW") end,

        -- ELRS link info (filled by ultidash_functions.update_elrs; slice 1)
        elrs_rfmd = nil,
        elrs_rate_str = "-",
        elrs_rate_desc = "no link",
        elrs_rq = nil,
        elrs_tq = nil,
        elrs_r1_dbm = nil,
        elrs_r2_dbm = nil,
        elrs_r1_pct = nil,
        elrs_r2_pct = nil,
        elrs_snr = nil,
        elrs_diversity = false,
        elrs_rate_formatted = function()
            return wgt.values.elrs_rate_str or "-"
        end,
        elrs_rq_formatted = function() return sfmt(wgt, "elrs_rq", wgt.values.elrs_rq, "%d%%") end,
        elrs_tq_formatted = function() return sfmt(wgt, "elrs_tq", wgt.values.elrs_tq, "%d%%") end,
        elrs_rssi1_formatted = function() return sfmt(wgt, "elrs_r1", wgt.values.elrs_r1_dbm, "%ddBm") end,
        elrs_rssi2_formatted = function() return sfmt(wgt, "elrs_r2", wgt.values.elrs_r2_dbm, "%ddBm") end,
        elrs_snr_formatted = function() return sfmt(wgt, "elrs_snr", wgt.values.elrs_snr, "%ddB") end,

        headspeed = nil,
        headspeed_min = nil,
        headspeed_max = nil,
        headspeed_formatted = function() return sfmt(wgt, "headspeed", wgt.values.headspeed, "%.0f") end,
        headspeed_min_formatted = function() return sfmt(wgt, "headspeed_min", wgt.values.headspeed_min, "%.0f") end,
        headspeed_max_formatted = function() return sfmt(wgt, "headspeed_max", wgt.values.headspeed_max, "%.0f") end,

        vbat = nil,
        vbat_min = nil,
        vbat_max = nil,
        vbat_formatted = function() return sfmt(wgt, "vbat", wgt.values.vbat, "%.02f") end,
        vbat_min_formatted = function() return sfmt(wgt, "vbat_min", wgt.values.vbat_min, "%.02f") end,
        vbat_max_formatted = function() return sfmt(wgt, "vbat_max", wgt.values.vbat_max, "%.02f") end,

        vcel = nil,
        vcel_min = nil,
        vcel_max = nil,
        cel_count = nil,
        vcel_formatted = function() return sfmt(wgt, "vcel", wgt.values.vcel, "%.02f") end,
        vcel_min_formatted = function() return sfmt(wgt, "vcel_min", wgt.values.vcel_min, "%.02f") end,
        vcel_max_formatted = function() return sfmt(wgt, "vcel_max", wgt.values.vcel_max, "%.02f") end,
        cel_count_formatted = function() return sfmt(wgt, "cel_count", wgt.values.cel_count, "(%dS)", "") end,
        vcel_warning_threshold = function()
            return get_cell_warning_threshold(wgt)
        end,
        vcel_alarm_threshold = function()
            return get_cell_alarm_threshold(wgt)
        end,
        vcel_full_threshold = function()
            return get_cell_full_threshold(wgt)
        end,
        vcel_actual_color = function()
            return get_cell_voltage_color_for_value(wgt, wgt.values.vcel)
        end,
        vcel_min_color = function()
            return get_cell_voltage_color_for_value(wgt, wgt.values.vcel_min)
        end,
        vcel_max_color = function()
            return get_cell_voltage_color_for_value(wgt, wgt.values.vcel_max)
        end,
        vcel_color = function()
            return wgt.values.vcel_actual_color()
        end,

        display_voltage_label = function()
            local base = use_total_voltage_display(wgt) and wgt.values.label_battery_voltage
                or wgt.values.label_cell_v
            local cells = wgt.values.cel_count_formatted()   -- memoized
            local c = wgt.fmt_cache; if c == nil then c = {}; wgt.fmt_cache = c end
            local e = c.dv_label
            if e ~= nil and e.b == base and e.c == cells then return e.s end
            local s = base .. " " .. cells
            if e ~= nil then e.b = base; e.c = cells; e.s = s else c.dv_label = { b = base, c = cells, s = s } end
            return s
        end,
        -- short voltage label without the cell-count suffix (cell count is shown
        -- inside the battery gauge instead, so the right-panel label never wraps)
        display_voltage_label_short = function()
            if use_total_voltage_display(wgt) then return wgt.values.label_battery_voltage end
            return wgt.values.label_cell_v
        end,
        display_voltage_formatted = function()
            -- main power lost: the main pack is gone; show "--" instead of the frozen
            -- last-good value (the BEC/buffer voltage is the interesting one now)
            if wgt.power_lost then return "--" end
            if use_total_voltage_display(wgt) then return wgt.values.vbat_formatted() end
            return wgt.values.vcel_formatted()
        end,
        display_voltage_min_formatted = function()
            if use_total_voltage_display(wgt) then return wgt.values.vbat_min_formatted() end
            return wgt.values.vcel_min_formatted()
        end,
        display_voltage_max_formatted = function()
            if use_total_voltage_display(wgt) then return wgt.values.vbat_max_formatted() end
            return wgt.values.vcel_max_formatted()
        end,
        display_voltage_warning_threshold = function()
            return get_display_voltage_threshold(wgt, get_cell_warning_threshold(wgt))
        end,
        display_voltage_alarm_threshold = function()
            return get_display_voltage_threshold(wgt, get_cell_alarm_threshold(wgt))
        end,
        display_voltage_actual_color = function()
            if wgt.power_lost then return COLOR_THEME_PRIMARY1 end   -- "--" shown neutral
            if use_total_voltage_display(wgt) then return get_display_voltage_color_for_value(wgt, wgt.values.vbat) end
            return get_display_voltage_color_for_value(wgt, wgt.values.vcel)
        end,
        display_voltage_min_color = function()
            if use_total_voltage_display(wgt) then return get_display_voltage_color_for_value(wgt, wgt.values.vbat_min) end
            return get_display_voltage_color_for_value(wgt, wgt.values.vcel_min)
        end,
        display_voltage_max_color = function()
            if use_total_voltage_display(wgt) then return get_display_voltage_color_for_value(wgt, wgt.values.vbat_max) end
            return get_display_voltage_color_for_value(wgt, wgt.values.vcel_max)
        end,
        display_voltage_color = function()
            return wgt.values.display_voltage_actual_color()
        end,
        display_voltage_test = function()
            if use_total_voltage_display(wgt) then return "99.99" end
            return "4.20"
        end,

        curr = nil,
        curr_min = nil,
        curr_max = nil,
        curr_min_formatted = function() return sfmt(wgt, "curr_min", wgt.values.curr_min, "%.01f") end,
        curr_formatted = function() return sfmt(wgt, "curr", wgt.values.curr, "%.01f") end,
        curr_max_formatted = function() return sfmt(wgt, "curr_max", wgt.values.curr_max, "%.01f") end,

        capa = nil,
        capa_percent = nil,
        fuel = nil, -- ePowerbar reserve-adjusted fuel %, computed in update_ma_used
        capa_bar_color = COLOR_THEME_PRIMARY1,
        batt_checking = false,
        batt_check_progress = 0,
        capa_formatted = function() return sfmt(wgt, "capa", wgt.values.capa, "%.0f") end,
        capa_percent_formatted = function() return sfmt(wgt, "capa_percent", wgt.values.capa_percent, "%.0f%%") end,
        -- effective fill level for the gauge: startup-check progress while checking,
        -- else the reserve-adjusted fuel %, clamped to 0..100 (ePowerbar)
        gauge_fill_percent = function()
            -- called once per gauge segment (6-9x/frame): memo by input so the clamp
            -- runs once per value change, not once per segment per frame
            local checking = wgt.values.batt_checking
            local raw = checking and (wgt.values.batt_check_progress or 0) or (wgt.values.fuel or 0)
            local c = wgt.fmt_cache; if c == nil then c = {}; wgt.fmt_cache = c end
            local e = c.gauge_fill
            if e ~= nil and e.r == raw and e.k == checking then return e.v end
            local v = checking and raw or math.max(0, math.min(100, raw))
            if e ~= nil then e.r = raw; e.k = checking; e.v = v else c.gauge_fill = { r = raw, k = checking, v = v } end
            return v
        end,
        -- centered percent label: dashes during the startup cell-check, else fuel %
        gauge_percent_formatted = function()
            if wgt.power_lost then return "--" end   -- pack gone: buffer % is meaningless
            if wgt.values.batt_checking then return "--" end
            local f = wgt.values.fuel
            if f ~= nil and f < 0 then f = 0 end
            return sfmt(wgt, "gauge_pct", f, "%.0f%%")
        end,
        -- cell count shown at the top of the battery gauge, e.g. "6S"
        gauge_cells_formatted = function()
            local c = wgt.values.cel_count or wgt.values.rf_battery_cell_count
            if c == nil or c <= 0 then return "" end
            return sfmt(wgt, "gauge_cells", c, "%dS")
        end,
        -- mAh shown as a stacked number over its unit so the number reads larger
        -- (same value/format as capa_formatted -> shares the "capa" memo slot)
        gauge_mah_value_formatted = function() return sfmt(wgt, "capa", wgt.values.capa, "%.0f") end,

        esc_temp = nil,
        esc_temp_min = nil,
        esc_temp_max = nil,
        esc_temp_formatted = function() return sfmt(wgt, "esc_temp", wgt.values.esc_temp, "%.01f") end,
        esc_temp_min_formatted = function() return sfmt(wgt, "esc_temp_min", wgt.values.esc_temp_min, "%.01f") end,
        esc_temp_max_formatted = function() return sfmt(wgt, "esc_temp_max", wgt.values.esc_temp_max, "%.01f") end,

        craft_name = "-",
        craft_name_formatted = function()
            if not wgt.values.craft_name or wgt.values.craft_name == "" or wgt.values.craft_name == "NotDefined" or wgt.values.craft_name == "Unknown" then return
                "-" end
            return wgt.values.craft_name
        end,

        -- resolved SD path + native pixel size of the status-panel model image (eBitmap-style)
        model_image_path = "",
        model_image_w = nil,
        model_image_h = nil,

        -- eStatus integration: throttle + ESC/arming status line
        label_throttle = "Throttle",
        throttle_text = "--",
        status_line_text = "",
        status_line_color = COLOR_THEME_PRIMARY1,

        profile_id = nil,
        rate_id = nil,
        profile_id_formatted = function()
            if wgt.values.profile_id == nil then return "-" end
            return tostring(wgt.values.profile_id)
        end,
        rate_id_formatted = function()
            if wgt.values.rate_id == nil then return "-" end
            return tostring(wgt.values.rate_id)
        end,

        arm_disable_flags = nil,
        arm_disable_flags_list = function()
            return arm_disable_flags_list_cached(wgt)
        end,
        arm_flags_visible = function()
            if not (wgt.rf and wgt.rf.available) then return true end
            return wgt.values.arm_disable_flags_list() ~= nil
        end,
        arm_state_text = function()
            return wgt.values.rf_connection_state == "armed" and wgt.values.label_armed or wgt.values.label_disarmed
        end,
        arm_state_color = function()
            return wgt.values.rf_connection_state == "armed" and DARKGREEN or COLOR_THEME_WARNING
        end,
        arm_flags_text_formatted = function()
            if not (wgt.rf and wgt.rf.available) then return "RFTools widget missing" end
            local current_flag = get_current_arm_disable_flag(wgt)
            if current_flag == nil then return "" end
            -- the cycled flag changes at most every 2 s; memo so the concat is not
            -- re-allocated on every status-bar frame
            return sfmt(wgt, "arm_flags_txt", current_flag, "Arming Disabled: %s")
        end,
        rf_connection_state = "disconnected",
        rf_connection_state_formatted = function()
            if wgt.values.rf_connection_state == "armed" then return wgt.values.label_armed end
            if wgt.values.rf_connection_state == "disarmed" then return wgt.values.label_disarmed end
            if wgt.values.rf_connection_state == "connected" then return wgt.values.label_connected end
            return wgt.values.label_disconnected
        end,
        rf_connection_state_color = function()
            if wgt.values.rf_connection_state == "armed" then return DARKGREEN end
            if wgt.values.rf_connection_state == "disconnected" then return COLOR_THEME_WARNING end
            return COLOR_THEME_PRIMARY1
        end,

        gov_state = nil,
        gov_state_formatted = function()
            -- FC explicitly runs gov_mode OFF/LIMIT: the Gov sensor is a constant 0,
            -- so "Throttle off" would be misleading -> show the mode instead. The
            -- label is precomputed in ultidashRf (this getter runs per LVGL frame).
            if wgt.values.rf_gov_mode_label ~= nil then return wgt.values.rf_gov_mode_label end
            if wgt.values.gov_state == nil then return "-" end
            return GOV_STATE_LABELS[wgt.values.gov_state] or "Gov. Disabled"
        end,

        vbec = nil,
        vbec_min = nil,
        vbec_max = nil,
        vbec_formatted = function() return sfmt(wgt, "vbec", wgt.values.vbec, "%.02f") end,
        vbec_min_formatted = function() return sfmt(wgt, "vbec_min", wgt.values.vbec_min, "%.02f") end,
        vbec_max_formatted = function() return sfmt(wgt, "vbec_max", wgt.values.vbec_max, "%.02f") end,

        vtx_volts = nil,
        vtx_volts_max = -1,
        vtx_volts_min = -1,
        vtx_volts_warn = -1,
        vtx_volts_percent = nil,
        vtx_volts_color = COLOR_THEME_PRIMARY1,
        vtx_low = false,
        vtx_volts_formatted = function() return sfmt(wgt, "vtx_volts_pct", wgt.values.vtx_volts_percent, "%s%%") end,
        -- radio (TX) battery voltage value for the top-bar battery icon
        vtx_voltage_formatted = function() return sfmt(wgt, "vtx_voltage", wgt.values.vtx_volts, "%.1fV") end,
        -- fill level (0..1) and fill color for the top-bar battery icon
        vtx_fill_ratio = function()
            local p = wgt.values.vtx_volts_percent
            if p == nil then return 0 end
            return math.max(0, math.min(100, p)) / 100
        end,
        vtx_fill_color = function()
            local c = wgt.fmt_cache; if c == nil then c = {}; wgt.fmt_cache = c end
            if c.vtx_col_lo == nil then
                c.vtx_col_lo = lcd.RGB(0xff, 0x33, 0x33)
                c.vtx_col_hi = lcd.RGB(0x30, 0xc0, 0x30)
            end
            return wgt.values.vtx_low and c.vtx_col_lo or c.vtx_col_hi
        end,

        -- date / time for the top bar (getDateTime is always available)
        -- getDateTime() allocates a fresh table on every call; on the top bar that is a
        -- table per frame. Re-read it only ~twice a second and memo the string.
        clock_time_formatted = function()
            local now = getTime() or 0
            local c = wgt.fmt_cache; if c == nil then c = {}; wgt.fmt_cache = c end
            local e = c.clock_t
            if e ~= nil and (now - e.t) < 50 then return e.s end
            local t = getDateTime()
            local s = t and string.format("%02d:%02d", t.hour, t.min) or "--:--"
            if e ~= nil then e.t = now; e.s = s else c.clock_t = { t = now, s = s } end
            return s
        end,
        clock_date_formatted = function()
            local now = getTime() or 0
            local c = wgt.fmt_cache; if c == nil then c = {}; wgt.fmt_cache = c end
            local e = c.clock_d
            if e ~= nil and (now - e.t) < 200 then return e.s end
            local t = getDateTime()
            -- 2-digit year (26 instead of 2026) to save top-bar width
            local s = t and string.format("%02d.%02d.%02d", t.day, t.mon, t.year % 100) or "--.--."
            if e ~= nil then e.t = now; e.s = s else c.clock_d = { t = now, s = s } end
            return s
        end,

        timer_str = "00:00",
        timer_is_negative = false,
        timer_color = function() return wgt.values.timer_is_negative and COLOR_THEME_WARNING or COLOR_THEME_PRIMARY1 end,
        timer_str_formatted = function() return wgt.values.timer_str end,

        flight_time_str = "00:00",
        flight_time_color = function() return COLOR_THEME_PRIMARY1 end,
        flight_time_str_formatted = function() return wgt.values.flight_time_str end,

        rqly_min = nil,
        rqly_formatted = function() return sfmt(wgt, "rqly_min", wgt.values.rqly_min, "%s%%") end,

        tpwr_max = nil,
        tpwr_formatted = function() return sfmt(wgt, "tpwr_max", wgt.values.tpwr_max, "%smW") end,

        mcu_temp_max = nil,
        mcu_temp_max_formatted = function() return sfmt(wgt, "mcu_temp_max", wgt.values.mcu_temp_max, "%.0f°C") end,

        rf_battery_profile = nil,
        rf_battery_profile_active = nil,
        rf_cell_warning_voltage = nil,
        rf_cell_alarm_voltage = nil,
        rf_cell_full_voltage = nil,
        rf_battery_profile_display_formatted = function()
            local profile_value = wgt.values.rf_battery_profile
            if profile_value == nil or profile_value < 0 then return "-" end
            local cap = wgt.values.rf_battery_capacity_display_formatted()   -- memoized
            local c = wgt.fmt_cache; if c == nil then c = {}; wgt.fmt_cache = c end
            local e = c.rf_prof_disp
            if e ~= nil and e.p == profile_value and e.c == cap then return e.s end
            local s = (cap == "-") and tostring(profile_value) or string.format("%s (%s)", cap, profile_value)
            if e ~= nil then e.p = profile_value; e.c = cap; e.s = s
            else c.rf_prof_disp = { p = profile_value, c = cap, s = s } end
            return s
        end,
        rf_battery_capacity_mah = nil,
        rf_battery_capacity_display_formatted = function()
            return sfmt(wgt, "rf_cap", wgt.values.rf_battery_capacity_mah, "%.0f")
        end,
        rf_battery_profile_compact_formatted = function()
            local capacity_value = wgt.values.rf_battery_capacity_display_formatted()   -- memoized
            if capacity_value ~= "-" then return capacity_value end
            local p = wgt.values.rf_battery_profile
            if p == nil or p < 0 then return "-" end
            return sfmt(wgt, "rf_prof_compact", p, "%d")
        end,
        battery_usage_summary_formatted = function()
            local used_value = wgt.values.capa_formatted()            -- memoized
            local percent_value = wgt.values.capa_percent_formatted() -- memoized
            if used_value == "-" and percent_value == "-" then return "-" end
            if used_value == "-" then return percent_value end
            if percent_value == "-" then return used_value end
            local c = wgt.fmt_cache; if c == nil then c = {}; wgt.fmt_cache = c end
            local e = c.batt_usage
            if e ~= nil and e.u == used_value and e.p == percent_value then return e.s end
            local s = string.format("%s (%s)", used_value, percent_value)
            if e ~= nil then e.u = used_value; e.p = percent_value; e.s = s
            else c.batt_usage = { u = used_value, p = percent_value, s = s } end
            return s
        end,
        rf_battery_cell_count = nil,
        rf_total_flights = nil,
        rf_total_flights_display_formatted = function()
            if wgt.values.rf_total_flights == nil then return "-" end
            return tostring(wgt.values.rf_total_flights)
        end,
        rf_total_flight_time = nil,
        rf_total_flight_time_formatted = "",
        rf_total_flight_time_display_formatted = function()
            if not wgt.values.rf_total_flight_time_formatted or wgt.values.rf_total_flight_time_formatted == "" then return
                "-" end
            return wgt.values.rf_total_flight_time_formatted
        end
    }
end

function M.createWidget()
    local wgt = {}
    wgt.values = M.createValues(wgt)
    return wgt
end

return M
