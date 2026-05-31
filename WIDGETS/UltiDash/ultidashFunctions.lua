-- currently used RotorFlight telemetry values for this widget:

-- 3 = Vbat (Main battery voltage)
-- 4 = Curr (Main battery current + min/max)
-- 5 = Capa (Capacity used)
-- 6 = Bat% (Battery percentage/fuel)
-- 7 = Cel# (Cell count)
-- 8 = Vcel (Cell voltage + min/max)
-- 43 = Vbec (BEC voltage + min/max)
-- 50 = Tesc (ESC temperature + min/max)
-- 52 = Tmcu (MCU temperature, max used)
-- 60 = Hspd (Headspeed)
-- 90 = ARM (Arming flags)
-- 91 = ARMD (Arming disable flags)
-- 93 = Gov (Governor state)
-- 95 = PID# (Profile ID)
-- 96 = RTE# (Rate ID)

-- set telemetry_sensors = 3,4,5,6,7,8,43,50,52,60,90,91,93,95,96,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0


local ultidash_functions = {}

local esc = loadScript("/WIDGETS/UltiDash/ultidashEsc.lua")()

-- ePowerbar-style discrete bar colors (after Rob 'bob00' Gayle)
local AUDIO_PATH = "/SOUNDS/en/"
local BAR_COLOR_OK       = lcd.RGB(0x00, 0xff, 0x00)
local BAR_COLOR_WARN     = lcd.RGB(0xf8, 0xc0, 0x00)
local BAR_COLOR_LOW      = lcd.RGB(0xff, 0xff, 0x00)
local BAR_COLOR_CRITICAL = lcd.RGB(0xff, 0x00, 0x00)
local BAR_COLOR_CHECK    = lcd.RGB(0xb8, 0xb8, 0xb8)

-- ESC status severity colors (eStatus)
local ESC_LEVEL_COLORS = {
    [esc.LEVEL_TRACE] = COLOR_THEME_DISABLED,
    [esc.LEVEL_INFO]  = COLOR_THEME_PRIMARY1,
    [esc.LEVEL_WARN]  = BAR_COLOR_LOW,
    [esc.LEVEL_ERROR] = BAR_COLOR_CRITICAL,
}

local ARM_DISABLE_DESCS = {
    "NOGYRO", "FAILSAFE", "RXLOSS", "BADRX", "BOXFAILSAFE", "RUNAWAY", "CRASH",
    "THROTTLE", "ANGLE", "BOOTGRACE", "NOPREARM", "LOAD", "CALIB", "CLI", "CMS",
    "BST", "MSP", "PARALYZE", "GPS", "RESCUE_SW", "RPMFILTER", "REBOOT_REQD",
    "DSHOT_BBANG", "NO_ACC_CAL", "MOTOR_PROTO", "ARMSWITCH",
}

-- ePowerbar callout engine constants
local ALERTLEVEL_NONE     = 0
local ALERTLEVEL_LOW      = 1
local ALERTLEVEL_CRITICAL = 2
local FUEL_VLOW           = 10  -- % band above critical handled as singles, not 10s
local ALERT_SAMPLE_CS     = 50  -- voltage must hold the level this long before alerting

-- ============================================================================
-- LOCAL HELPER FUNCTIONS
-- ============================================================================

local function play_audio(file)
    playFile(AUDIO_PATH .. file .. ".wav")
end

local function play_vibe(wgt)
    if wgt.options.Haptic == 1 then playHaptic(100, 0, PLAY_NOW) end
end

-- Logging helper with ms prefix and configurable tag
function ultidash_functions.log(text, ...)
    if not text then return end
    local t = getTime() or 0 -- EdgeTX ticks are centiseconds
    local ms = t * 10        -- convert cs to ms
    local tag = "UltiDash"
    local formatted_text = text
    if select('#', ...) > 0 then formatted_text = string.format(tostring(text), ...) end
    print(string.format("[%dms][%s] %s", ms, tag, formatted_text))
end

-- Detect simulator mode for testing
ultidash_functions.simu_mode = string.sub(select(2, getVersion()), -4) == "simu"
ultidash_functions.log("simu_mode=%s", tostring(ultidash_functions.simu_mode))

local function format_time(t1)
    if not t1 or t1.value == nil then return "00:00", false end

    local seconds = math.abs(t1.value)
    local is_negative = t1.value < 0

    local mm = math.floor(seconds / 60) % 60
    local ss = math.floor(seconds % 60)

    local time_str = string.format("%02d:%02d", mm, ss)

    if is_negative then time_str = '-' .. time_str end
    return time_str, is_negative
end

local function format_elapsed_time(elapsed_centiseconds)
    local seconds = math.floor(math.max(0, elapsed_centiseconds or 0) / 100)
    return format_time({ value = seconds })
end

local function is_rf_connected(wgt)
    return wgt.values.rf_connection_state ~= "disconnected"
end

-- Armed detection. Prefer the ARM telemetry sensor (Rotorflight arming flags,
-- bit 0 = armed) because it's always available and authoritative; the RFTool
-- connection state ("armed") is only a fallback (it doesn't reliably report the
-- armed sub-state on every setup, which left flight-time tracking at 00:00).
local function is_craft_armed(wgt)
    local arm = getSourceValue("ARM")
    if arm ~= nil then
        arm = math.floor(arm)
        return (arm % 2) == 1 or arm == 1024
    end
    return wgt.values.rf_connection_state == "armed"
end

local function should_track_governor_run_extrema(wgt)
    return wgt.values.gov_state ~= nil and wgt.values.gov_state > 2 and wgt.values.gov_state ~= 5
end

-- headspeed (rpm) above which the rotor counts as "spinning" for flight time
local FLIGHT_TIME_MIN_HEADSPEED = 100

-- Flight-time tracking: count only while ARMED *and* the rotor is spinning (both in
-- combination). Sensors are read DIRECTLY here (getSourceValue), independent of the
-- refresh path / rf_connection_state / any wgt.values caching — that indirection was
-- unreliable (rfToolState is nil on this RFTool, so cached values could be stale).
local function should_track_flight_time(wgt)
    local arm = getSourceValue("ARM")
    if arm ~= nil then
        arm = math.floor(arm)
        if (arm % 2) ~= 1 and arm ~= 1024 then return false end   -- ARM bit0 clear = disarmed
    elseif not is_craft_armed(wgt) then
        return false                                              -- no ARM sensor -> cached state
    end
    local hs = getSourceValue("Hspd")
    if hs == nil then return true end            -- no Hspd sensor -> armed-only
    return hs > FLIGHT_TIME_MIN_HEADSPEED
end

local function reset_flight_time(wgt)
    wgt.flight_time_elapsed = 0
    wgt.flight_time_last_tick = nil
    wgt.last_model_timer_value = nil
    wgt.values.flight_time_str = "00:00"
end

local function update_tracked_extrema(wgt, value_key, min_key, max_key)
    local current_value = wgt.values[value_key]
    if current_value == nil then return end

    if wgt.values[min_key] == nil or current_value < wgt.values[min_key] then
        wgt.values[min_key] = current_value
    end
    if wgt.values[max_key] == nil or current_value > wgt.values[max_key] then
        wgt.values[max_key] = current_value
    end
end

local function clear_live_telemetry_values(wgt)
    wgt.values.vbat = nil
    wgt.values.vbat_min = nil
    wgt.values.vbat_max = nil
    wgt.values.vcel = nil
    wgt.values.vcel_min = nil
    wgt.values.vcel_max = nil
    wgt.values.cel_count = nil
    wgt.values.curr = nil
    wgt.values.curr_min = nil
    wgt.values.curr_max = nil
    wgt.values.capa = nil
    wgt.values.capa_percent = nil
    wgt.values.batt_checking = false
    wgt.values.batt_check_progress = 0
    wgt.batt_warn = false
    wgt.prev_vbat = nil
    wgt.values.headspeed = nil
    wgt.values.headspeed_min = nil
    wgt.values.headspeed_max = nil
    wgt.values.vbec = nil
    wgt.values.vbec_min = nil
    wgt.values.vbec_max = nil
    wgt.values.esc_temp = nil
    wgt.values.esc_temp_min = nil
    wgt.values.esc_temp_max = nil
    wgt.values.gov_state = nil
    wgt.values.arm_disable_flags = nil
    wgt.values.profile_id = nil
    wgt.values.rate_id = nil
    wgt.values.rf_battery_profile = nil
    wgt.values.rf_battery_capacity_mah = nil
    wgt.values.rf_battery_cell_count = nil
    wgt.values.rqly_min = nil
    wgt.values.tpwr_max = nil
    wgt.values.mcu_temp_max = nil
    wgt.values.vtx_volts = nil
    wgt.values.vtx_volts_percent = nil
    -- eStatus state
    wgt.values.throttle_text = "--"
    wgt.values.status_line_text = ""
    wgt.values.status_line_color = COLOR_THEME_PRIMARY1
    wgt.esc_status_text = nil
    wgt.esc_status_level = nil
    wgt.esc_last_flags = nil
    wgt.estatus_armed = nil
    -- link warning state
    wgt.link_pending = 0
    wgt.link_level = 0
    wgt.link_next = 0
    esc.reset()
end

-- ============================================================================
-- GENERAL INFO UPDATES
-- ============================================================================
function ultidash_functions.update_craft_name(wgt)
    local model_name = rf2 and rf2.modelName
    if not model_name then
        local model_info = model.getInfo()
        model_name = model_info and model_info.name
    end
    wgt.values.craft_name = string.gsub(model_name or "Unknown", "^>", "")
end

-- eBitmap-style model image: prefer a craft image (optionally cell-count specific),
-- then the plain craft name, then the model's configured bitmap. Resolved to an SD
-- path for the LVGL image object; recomputed only when an input changes.
local IMAGE_DIR = "/images/"
local IMAGE_EXTS = { "", ".png", ".bmp", ".jpg", ".jpeg" }

local function find_image_path(name)
    if not name or name == "" then return nil end
    name = string.gsub(name, "^>", "")
    for _, ext in ipairs(IMAGE_EXTS) do
        local path = IMAGE_DIR .. name .. ext
        if fstat and fstat(path) then return path end
    end
    return nil
end

function ultidash_functions.update_model_image(wgt)
    local craft = wgt.values.craft_name
    if craft == "Unknown" or craft == "NotDefined" or craft == "-" or craft == "" then craft = nil end

    local cells = wgt.values.cel_count or wgt.values.rf_battery_cell_count or 0
    local mi = model.getInfo()
    local model_bmp = mi and mi.bitmap

    if wgt.img_craft == craft and wgt.img_cells == cells and wgt.img_model_bmp == model_bmp then
        return
    end
    wgt.img_craft = craft
    wgt.img_cells = cells
    wgt.img_model_bmp = model_bmp

    local path = nil
    if craft then
        if cells and cells > 0 then
            path = find_image_path(craft .. "-" .. cells .. "S")
        end
        path = path or find_image_path(craft)
    end
    path = path or find_image_path(model_bmp)

    -- read native size so the layout can top-anchor the image at its true aspect ratio
    local img_w, img_h = nil, nil
    if path and Bitmap and Bitmap.open then
        local bmp = Bitmap.open(path)
        if bmp then
            local bw, bh = Bitmap.getSize(bmp)
            if bw and bw > 0 and bh and bh > 0 then img_w, img_h = bw, bh end
        end
    end

    wgt.values.model_image_path = path or ""
    wgt.values.model_image_w = img_w
    wgt.values.model_image_h = img_h

    -- request one rebuild so the panel re-anchors the image with the new size
    if wgt.view then wgt.view.dirty = true end
    wgt.layout_dirty = true
end

function ultidash_functions.update_timer_count(wgt)
    -- model timer (only for optional display in the top-left area via the TopLeft option).
    -- NOTE: deliberately NOT coupled to reset_flight_time anymore — the old coupling wiped
    -- flight time when the timer rolled back to its start value (e.g. on disarm/throttle-cut,
    -- exactly when you look at the stats page). Flight time resets only on telemetry reconnect.
    local t1 = model.getTimer(wgt.options.Timer or 0)
    local timer_text, is_negative = format_time(t1)
    wgt.values.timer_str = timer_text
    wgt.values.timer_is_negative = is_negative

    local now = getTime() or 0
    if should_track_flight_time(wgt) then
        if wgt.flight_time_last_tick ~= nil and now > wgt.flight_time_last_tick then
            wgt.flight_time_elapsed = (wgt.flight_time_elapsed or 0) + (now - wgt.flight_time_last_tick)
        end
        wgt.flight_time_last_tick = now
    else
        wgt.flight_time_last_tick = nil
    end

    wgt.values.flight_time_str = format_elapsed_time(wgt.flight_time_elapsed or 0)
end

function ultidash_functions.update_profiles(wgt)
    wgt.values.profile_id = getSourceValue("PID#")
    wgt.values.rate_id = getSourceValue("RTE#")
    wgt.values.rf_battery_profile = getSourceValue("BAT#")
    if wgt.sync_active_battery_capacity then
        wgt.sync_active_battery_capacity(wgt)
    end
end

-- ============================================================================
-- TRANSMITTER/RADIO UPDATES
-- ============================================================================

function ultidash_functions.update_tx_bat_voltage(wgt)
    wgt.values.vtx_volts = getSourceValue("tx-voltage")
    wgt.values.vtx_volts_max = getGeneralSettings().battMax
    wgt.values.vtx_volts_min = getGeneralSettings().battMin
    wgt.values.vtx_volts_warn = getGeneralSettings().battWarn

    if wgt.values.vtx_volts == nil then
        wgt.values.vtx_volts_percent = nil
        wgt.values.vtx_volts_color = COLOR_THEME_PRIMARY1
        wgt.values.vtx_low = false
        return
    end

    wgt.values.vtx_volts_percent = math.floor(100 -
        (100 * (wgt.values.vtx_volts_max - wgt.values.vtx_volts) //
            (wgt.values.vtx_volts_max - wgt.values.vtx_volts_min)))

    if wgt.values.vtx_volts_percent > 100 then wgt.values.vtx_volts_percent = 100 end

    local warn_percent = math.ceil(100 -
        (100 * (wgt.values.vtx_volts_max - wgt.values.vtx_volts_warn) //
            (wgt.values.vtx_volts_max - wgt.values.vtx_volts_min)))

    wgt.values.vtx_low = wgt.values.vtx_volts_percent < warn_percent
    if wgt.values.vtx_low then
        wgt.values.vtx_volts_color = COLOR_THEME_WARNING
    else
        wgt.values.vtx_volts_color = COLOR_THEME_PRIMARY1
    end
end

function ultidash_functions.update_link_quality(wgt)
    -- Only track minimum link quality; current value not needed
    wgt.values.rqly_min = getSourceValue("RQly-")
end

function ultidash_functions.update_transmitter_power(wgt)
    -- Only track maximum transmitter power; current value not needed
    wgt.values.tpwr_max = getValue("TPWR+")
end

-- ============================================================================
-- AIRCRAFT TELEMETRY: VOLTAGE & TEMPERATURE
-- ============================================================================
function ultidash_functions.update_cell(wgt)
    wgt.values.vbat = getSourceValue("Vbat")
    wgt.values.vbat_min = getSourceValue("Vbat-")
    wgt.values.vbat_max = getSourceValue("Vbat+")

    if ultidash_functions.simu_mode then
        wgt.values.vbat = math.random(1101, 1201) / 100
        wgt.values.vbat_min = 10.80
        wgt.values.vbat_max = 12.30
    end
end

function ultidash_functions.update_vcel(wgt)
    wgt.values.vcel = getSourceValue("Vcel")
    wgt.values.vcel_min = getSourceValue("Vcel-")
    wgt.values.vcel_max = getSourceValue("Vcel+")
    wgt.values.cel_count = getSourceValue("Cel#")

    if ultidash_functions.simu_mode then
        wgt.values.vcel = 3.2
        wgt.values.vcel_max = 4.2
        wgt.values.vcel_min = 3.1
        wgt.values.cel_count = 2
    end
end

function ultidash_functions.update_vbec(wgt)
    wgt.values.vbec = getSourceValue("Vbec")
    wgt.values.vbec_max = getSourceValue("Vbec+")
    wgt.values.vbec_min = getSourceValue("Vbec-")

    if ultidash_functions.simu_mode then
        wgt.values.vbec = math.random(72, 78) / 10
        wgt.values.vbec_max = 8.4
        wgt.values.vbec_min = 7.2
    end
end

function ultidash_functions.update_esc_temperature(wgt)
    wgt.values.esc_temp = getSourceValue("Tesc")
    wgt.values.esc_temp_min = getSourceValue("Tesc-")
    wgt.values.esc_temp_max = getSourceValue("Tesc+")

    if ultidash_functions.simu_mode then
        wgt.values.esc_temp = 60
        wgt.values.esc_temp_max = 75
        wgt.values.esc_temp_min = 45
    end
end

function ultidash_functions.update_mcu_temperature(wgt) wgt.values.mcu_temp_max = getSourceValue("Tmcu+") end

-- ============================================================================
-- AIRCRAFT TELEMETRY: CURRENT & CAPACITY
-- ============================================================================
function ultidash_functions.update_curr(wgt)
    wgt.values.curr = getSourceValue("Curr")

    if ultidash_functions.simu_mode then
        wgt.values.curr = math.random(0, 200)
    end

    if should_track_governor_run_extrema(wgt) then
        update_tracked_extrema(wgt, "curr", "curr_min", "curr_max")
    end
end

function ultidash_functions.update_ma_used(wgt)
    wgt.values.capa = getSourceValue("Capa")
    wgt.values.capa_percent = getSourceValue("Bat%")

    if ultidash_functions.simu_mode then
        wgt.values.capa = math.random(0, 2000)
        wgt.values.capa_percent = math.random(0, 100)
    end

    -- ePowerbar reserve-adjusted fuel: 0% == reserve reached, scaled over usable range
    local raw = wgt.values.capa_percent
    local reserve = wgt.options.Reserve or 20
    if raw == nil then
        wgt.values.fuel = nil
    elseif reserve <= 0 then
        wgt.values.fuel = raw
    elseif raw < reserve then
        wgt.values.fuel = raw - reserve
    else
        wgt.values.fuel = (raw - reserve) / (100 - reserve) * 100
    end
end

-- ePowerbar critical threshold: 0 when a reserve is set, else 20.
local function fuel_critical(wgt)
    return (wgt.options.Reserve or 20) > 0 and 0 or 20
end

-- Resolve the discrete ePowerbar-style fill color for the current fuel level.
local function resolve_bar_color(wgt)
    if wgt.values.batt_checking then return BAR_COLOR_CHECK end

    local fuel = wgt.values.fuel
    if fuel == nil then return COLOR_THEME_PRIMARY1 end

    local critical = fuel_critical(wgt)
    if fuel <= critical then return BAR_COLOR_CRITICAL end
    if fuel <= critical + 20 then return BAR_COLOR_LOW end
    return wgt.batt_warn and BAR_COLOR_WARN or BAR_COLOR_OK
end

-- Startup cell-check (after ePowerbar): show a grey progress bar while the
-- battery settles, then warn (colour + audio) if the pack is not fully charged.
function ultidash_functions.update_battery_gauge(wgt)
    local vbat = wgt.values.vbat
    local startup_delay = math.max(1, wgt.options.StartupDelay or 4) * 100
    local cell_full = (wgt.options.CellFull or 412) / 100

    -- arm the check when voltage first appears
    local had_voltage = wgt.prev_vbat ~= nil and wgt.prev_vbat > 0
    local has_voltage = vbat ~= nil and vbat > 0
    if cell_full > 0 and has_voltage and not had_voltage then
        wgt.batt_check_until = getTime() + startup_delay
        wgt.values.batt_checking = true
        wgt.values.batt_check_progress = 0
        wgt.batt_warn = false
    end
    wgt.prev_vbat = vbat

    if wgt.values.batt_checking then
        local now = getTime()
        if now >= (wgt.batt_check_until or 0) then
            wgt.values.batt_checking = false
            wgt.values.batt_check_progress = 100
            local cellv = wgt.values.vcel
            if cellv == nil or cellv <= 0 then
                wgt.batt_warn = true
            elseif cellv >= cell_full then
                wgt.batt_warn = false
            else
                wgt.batt_warn = true
                play_audio("batlow")
                if vbat then playNumber(vbat * 10, 1, PREC1) end
            end
        else
            wgt.values.batt_check_progress =
                100 - ((wgt.batt_check_until - now) * 100 / startup_delay)
        end
    end

    wgt.values.capa_bar_color = resolve_bar_color(wgt)
end

-- ============================================================================
-- AIRCRAFT TELEMETRY: HELI-SPECIFIC
-- ============================================================================
function ultidash_functions.update_headspeed(wgt)
    wgt.values.headspeed = getSourceValue("Hspd")

    if ultidash_functions.simu_mode then
        wgt.values.headspeed = math.random(2000, 3000)
    end

    if should_track_governor_run_extrema(wgt) then
        update_tracked_extrema(wgt, "headspeed", "headspeed_min", "headspeed_max")
    end
end

function ultidash_functions.update_gov_state(wgt)
    wgt.values.gov_state = getSourceValue("Gov")
    if ultidash_functions.simu_mode then wgt.values.gov_state = math.random(0, 9) end
end

-- ============================================================================
-- ARM STATE UPDATES
-- ============================================================================

function ultidash_functions.update_arm(wgt)
    wgt.values.arm_disable_flags = getSourceValue("ARMD")
end

-- Compact "* REASON REASON" arming-disable summary (eStatus style), capped in length.
local function build_arm_disable_text(flags)
    if not flags or flags == 0 then return nil end
    local parts = {}
    local len = 0
    for i = 1, #ARM_DISABLE_DESCS do
        if bit32.band(flags, bit32.lshift(1, i - 1)) ~= 0 then
            local desc = ARM_DISABLE_DESCS[i]
            if len + #desc + 1 > 18 then
                parts[#parts + 1] = "+"
                break
            end
            parts[#parts + 1] = desc
            len = len + #desc + 1
        end
    end
    if #parts == 0 then return nil end
    return "* " .. table.concat(parts, " ")
end

-- eStatus integration: throttle %, multi-vendor ESC status/fault line,
-- arming-disable reasons when disarmed, and armed/disarm voice callouts.
function ultidash_functions.update_estatus(wgt)
    local connected = is_rf_connected(wgt)
    local armed = is_craft_armed(wgt)

    -- throttle
    if not connected then
        wgt.values.throttle_text = "**"
    elseif not armed then
        wgt.values.throttle_text = "Safe"
    else
        local thr = getSourceValue("Thr")
        wgt.values.throttle_text = thr and string.format("%d%%", thr) or "--"
    end
    if ultidash_functions.simu_mode then
        connected, armed = true, true
        wgt.values.throttle_text = string.format("%d%%", math.random(0, 100))
    end

    -- ESC signature + status flags
    local sig = getSourceValue("Esc#") or 0
    local flags = getSourceValue("EscF") or 0
    local changed = flags ~= wgt.esc_last_flags
    wgt.esc_last_flags = flags

    local status_text, status_color
    if connected and sig == esc.SIG_RESTART then
        status_text = "RESTART ESC"
        status_color = BAR_COLOR_CRITICAL
        wgt.esc_status_level = esc.LEVEL_ERROR
    elseif connected then
        local st = esc.get_status(sig, flags, changed)
        if st then
            -- latch the worst level seen since (re)connect, like eStatus
            if wgt.esc_status_level == nil or st.level >= wgt.esc_status_level then
                wgt.esc_status_text = st.text
                wgt.esc_status_level = st.level
            end
            status_text = wgt.esc_status_text
            status_color = ESC_LEVEL_COLORS[wgt.esc_status_level or esc.LEVEL_INFO]
        end
    end

    -- when disarmed with arming-disable flags, show the reasons instead
    if connected and not armed then
        local adt = build_arm_disable_text(wgt.values.arm_disable_flags)
        if adt then
            status_text = adt
            status_color = COLOR_THEME_WARNING
        end
    end

    -- placeholder when there's nothing specific to report, so the field is clearly
    -- a live status area rather than looking blank/broken
    if status_text == nil or status_text == "" then
        if not connected then
            status_text = "No telemetry"
        elseif armed then
            status_text = "Armed - OK"
        else
            status_text = "Ready"
        end
        status_color = COLOR_THEME_DISABLED
    end

    wgt.values.status_line_text = status_text or ""
    wgt.values.status_line_color = status_color or COLOR_THEME_PRIMARY1

    -- armed/disarm voice on state change (skip the very first sample)
    if connected then
        if wgt.estatus_armed ~= nil and wgt.estatus_armed ~= armed then
            play_audio(armed and "armed" or "disarm")
        end
        wgt.estatus_armed = armed
    else
        wgt.estatus_armed = nil
    end
end

function ultidash_functions.on_telemetry_state_changed(wgt, previous_state, new_state)
    local link_warn = wgt.options and wgt.options.LinkWarn == 1

    if previous_state == "disconnected" and new_state ~= "disconnected" then
        clear_live_telemetry_values(wgt)
        ultidash_functions.reset_telemetry_stats(wgt)
        -- telemetry recovered: chime only if the loss happened while armed (in flight)
        if link_warn and wgt.link_lost_armed then
            playTone(880, 120, 0, PLAY_NOW)
        end
        wgt.link_lost_armed = false
        return
    end

    -- telemetry lost while ARMED (in flight): low urgent tone + vibrate.
    -- losses while disarmed / on the bench stay silent (logged only).
    if new_state == "disconnected" then
        if previous_state == "armed" then
            ultidash_functions.log("Connection lost (armed)")
            if link_warn then
                playTone(220, 400, 0, PLAY_NOW)
                play_vibe(wgt)
                wgt.link_lost_armed = true
            end
        elseif previous_state ~= nil then
            ultidash_functions.log("Connection lost")
        end
    end
end

-- ============================================================================
-- ALERTS & CALLOUTS
-- ============================================================================

-- Reset the ePowerbar callout state machine (on disarm / disconnect).
local function reset_callout_state(wgt)
    wgt.callout_last_capa = 100
    wgt.callout_next_capa = 0
    wgt.alert_pending = 0
    wgt.alert_next = 0
    wgt.alert_level = ALERTLEVEL_NONE
end

-- ePowerbar crankFuelCalls: announce fuel % on the 10s, singles when critical.
local function crank_fuel_calls(wgt)
    -- bail if fuel alerts muted (Mute == "Voltage and fuel alerts")
    if (wgt.options.Mute or 1) > 2 then return end

    local fuel = wgt.values.fuel
    if fuel == nil then return end

    local critical = fuel_critical(wgt)
    local interval = math.max(1, wgt.options.CalloutInt or 6) * 100

    local capa
    if fuel > critical + FUEL_VLOW then
        capa = math.ceil(fuel / 10) * 10
    else
        capa = fuel
    end

    local now = getTime()
    if (wgt.callout_last_capa ~= capa or capa <= 0) and now > wgt.callout_next_capa then
        -- skip the very first pass after arming
        if wgt.callout_next_capa ~= 0 then
            if capa > critical + FUEL_VLOW then
                play_audio("battry")
            elseif capa > critical then
                play_audio("batlow")
            else
                play_audio("batcrt")
                play_vibe(wgt)
            end
            if capa >= 0 then
                playNumber(capa, UNIT_PERCENT)
            end
        end
        wgt.callout_last_capa = capa
        wgt.callout_next_capa = now + interval
    end
end

-- ePowerbar crankVoltageAlerts: low/critical per-cell voltage alerts with debounce.
local function crank_voltage_alerts(wgt)
    -- bail if voltage alerts muted (Mute >= "Voltage alerts")
    if (wgt.options.Mute or 1) > 1 then return end

    local cellv = wgt.values.vcel
    if cellv == nil or cellv <= 0 then return end

    local now = getTime()
    if now < wgt.alert_next then return end

    -- thresholds are configured in centivolts (ePowerbar CellLow / CellCritical)
    local cv = math.floor(cellv * 100)
    local alarm = wgt.options.CellCritical or 330
    local low = wgt.options.CellLow or 345

    local alert_level = (cv <= alarm and ALERTLEVEL_CRITICAL) or (cv <= low and ALERTLEVEL_LOW) or ALERTLEVEL_NONE

    if wgt.alert_pending ~= 0 then
        if alert_level == ALERTLEVEL_NONE then
            -- condition cleared while pending
            wgt.alert_pending = 0
            return
        elseif alert_level < wgt.alert_level then
            wgt.alert_level = alert_level
        end

        if now >= wgt.alert_pending then
            local haptic = false
            if alert_level == ALERTLEVEL_LOW then
                play_audio("batlow")
            elseif alert_level == ALERTLEVEL_CRITICAL then
                play_audio("batcrt")
                haptic = true
            end
            -- report total voltage (ePowerbar workaround for per-cell announce)
            local vbat = wgt.values.vbat
            if vbat then playNumber(vbat * 10, UNIT_VOLTS, PREC1) end
            if haptic then play_vibe(wgt) end

            wgt.alert_next = now + math.max(1, wgt.options.CalloutInt or 6) * 100
            wgt.alert_pending = 0
            return
        end
    elseif alert_level > ALERTLEVEL_NONE then
        wgt.alert_level = alert_level
        wgt.alert_pending = now + ALERT_SAMPLE_CS
    end
end

function ultidash_functions.update_battery_callout(wgt)
    if not is_rf_connected(wgt) or not is_craft_armed(wgt) then
        reset_callout_state(wgt)
        return
    end

    if wgt.callout_next_capa == nil then reset_callout_state(wgt) end

    -- keep the sensors the callouts depend on fresh (also runs from background)
    ultidash_functions.update_ma_used(wgt)
    ultidash_functions.update_cell(wgt)
    ultidash_functions.update_vcel(wgt)

    crank_fuel_calls(wgt)
    crank_voltage_alerts(wgt)
end

-- ExpressLRS link-quality warning on the RQly (Link Quality %) sensor.
-- Two stages (warn / critical) with a short debounce and CalloutInt repeat gap.
-- Only fires while ARMED (in flight); telemetry-lost itself is handled in
-- on_telemetry_state_changed (also armed-gated via previous_state).
local LINK_SAMPLE_CS = 50

function ultidash_functions.update_link_warning(wgt)
    if wgt.options.LinkWarn ~= 1 then
        wgt.link_pending = 0
        wgt.link_level = 0
        return
    end
    -- only while armed (in flight); no link callouts on the bench / disarmed
    if not is_craft_armed(wgt) then
        wgt.link_pending = 0
        wgt.link_level = 0
        return
    end

    local rqly = getSourceValue("RQly")
    if ultidash_functions.simu_mode then rqly = math.random(0, 100) end
    if rqly == nil then return end

    local now = getTime()
    if now < (wgt.link_next or 0) then return end

    local warn = wgt.options.RQlyWarn or 50
    local crit = wgt.options.RQlyCrit or 30
    local level = (rqly <= crit and 2) or (rqly <= warn and 1) or 0

    if (wgt.link_pending or 0) ~= 0 then
        if level == 0 then
            -- recovered above threshold while pending
            wgt.link_pending = 0
            wgt.link_level = 0
            return
        elseif level < (wgt.link_level or 0) then
            -- de-escalated to a less severe level while pending
            wgt.link_level = level
        end

        if now >= wgt.link_pending then
            if wgt.link_level >= 2 then
                playTone(330, 300, 0, PLAY_NOW)
                play_vibe(wgt)
            else
                playTone(660, 150, 0, PLAY_NOW)
            end
            -- announce the actual link quality value
            playNumber(rqly, UNIT_PERCENT)

            wgt.link_next = now + math.max(1, wgt.options.CalloutInt or 6) * 100
            wgt.link_pending = 0
            wgt.link_level = 0
        end
    elseif level > 0 then
        wgt.link_level = level
        wgt.link_pending = now + LINK_SAMPLE_CS
    end
end

function ultidash_functions.reset_telemetry_stats(wgt)
    for i = 0, 99 do model.resetSensor(i) end

    model.resetTimer(wgt.options.Timer or 0)
    reset_flight_time(wgt)

    -- Reset battery callout state on disconnect
    reset_callout_state(wgt)
end

-- ============================================================================
-- REFRESH ORCHESTRATION
-- ============================================================================

function ultidash_functions.refresh_ui_no_conn(wgt)
    ultidash_functions.update_tx_bat_voltage(wgt)
    ultidash_functions.update_craft_name(wgt)
    ultidash_functions.update_model_image(wgt)
    ultidash_functions.update_estatus(wgt)
    ultidash_functions.update_timer_count(wgt)
end

function ultidash_functions.refresh_ui(wgt)
    ultidash_functions.update_gov_state(wgt)
    ultidash_functions.update_headspeed(wgt)
    ultidash_functions.update_cell(wgt)
    ultidash_functions.update_vcel(wgt)
    ultidash_functions.update_curr(wgt)
    ultidash_functions.update_ma_used(wgt)
    ultidash_functions.update_battery_gauge(wgt)
    ultidash_functions.update_profiles(wgt)
    ultidash_functions.update_link_quality(wgt)
    ultidash_functions.update_transmitter_power(wgt)
    ultidash_functions.update_arm(wgt)
    ultidash_functions.update_vbec(wgt)
    ultidash_functions.update_esc_temperature(wgt)
    ultidash_functions.update_mcu_temperature(wgt)

    ultidash_functions.refresh_ui_no_conn(wgt)
end

-- Background refresh: lightweight updates (connection state + battery/link callouts).
-- Also keeps flight-time tracking running when UltiDash is NOT the active screen,
-- so the stats-page "Flight Time" reflects the whole flight, not just the time the
-- widget was on screen.
function ultidash_functions.background_refresh(wgt)
    ultidash_functions.update_battery_callout(wgt)
    ultidash_functions.update_link_warning(wgt)

    -- refresh the sensors the flight-time condition depends on, then accumulate.
    -- read unconditionally (not gated by RFTool state) so headspeed-based tracking
    -- works even if the RFTool connection state isn't feeding through; getSourceValue
    -- returns nil when telemetry is stale, which correctly stops tracking.
    ultidash_functions.update_headspeed(wgt)
    ultidash_functions.update_gov_state(wgt)
    ultidash_functions.update_timer_count(wgt)
end

-- Main refresh: full telemetry updates (handles both connected and disconnected states)
function ultidash_functions.refresh(wgt)
    if ultidash_functions.simu_mode then
        ultidash_functions.refresh_ui(wgt)
        return
    end

    if not is_rf_connected(wgt) then
        ultidash_functions.refresh_ui_no_conn(wgt)
        return
    end
    ultidash_functions.refresh_ui(wgt)
    ultidash_functions.update_battery_callout(wgt)
    ultidash_functions.update_link_warning(wgt)
end

return ultidash_functions
