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

-- color palette shadows (see ultidash.lua); swapped via ultidash_functions.set_palette
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

-- ePowerbar-style discrete bar colors (after Rob 'bob00' Gayle)
local AUDIO_PATH = "/SOUNDS/en/ultidash/"
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

-- swap the theme color shadows (called from ultidash.lua update())
function ultidash_functions.set_palette(use_clean)
    local p = use_clean and CLEAN_PALETTE or THEME_PALETTE
    COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2 = p[1], p[2], p[3], p[4]
    COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS, COLOR_THEME_WARNING, COLOR_THEME_DISABLED = p[5], p[6], p[7], p[8]
    ESC_LEVEL_COLORS[esc.LEVEL_TRACE] = COLOR_THEME_DISABLED
    ESC_LEVEL_COLORS[esc.LEVEL_INFO]  = COLOR_THEME_PRIMARY1
end

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
-- A genuinely connected/measured cell never reads in the ~0..3 V "dead zone" while
-- flying — it shows its real 3.3..4.2 V or collapses to ~0 when the supply is lost
-- (e.g. a buffer/backup kicking in). So any per-cell reading below this floor is
-- treated as "no valid data", NOT as a critically low cell -> prevents a misleading
-- "battery critical 0 V" callout on power loss. Far below the real critical (~3.3 V),
-- so it can never mask a genuine alert.
local MIN_PLAUSIBLE_CELL_V = 1.0
-- The collapse DECAY however passes through plausible-looking values (4.x -> 2.9 ->
-- 1.4 -> 0) that the floor alone can't catch. Physical distinction: while DISARMED
-- there is no load, so a real pack voltage never falls quickly — a fast drop while
-- disarmed is always a supply collapse. Such a reading is only accepted after it
-- stayed STABLE for VOLT_ACCEPT_CS (which a genuinely lower pack — e.g. swapped at
-- a powered buffer — does, and a decay never does). While ARMED every plausible
-- reading is accepted live: real load sag must show immediately.
local VOLT_ACCEPT_CS = 300   -- stability window (centiseconds) for a suspicious drop
local VOLT_DROP_CELL = 0.2   -- per-cell drop (V) considered suspicious while disarmed

-- ============================================================================
-- LOCAL HELPER FUNCTIONS
-- ============================================================================

-- Master mute (the `Mute` option) — when set, suppresses ALL voice + vibration,
-- overriding the per-event toggles. Refreshed from wgt.options at every entry
-- point that can produce sound (refresh / background_refresh / state change).
local master_muted = false

-- Widget callout volume (the `Volume` setting, 1..5; 0/nil = follow the system
-- volume). EdgeTX's playFile/playNumber accept a per-playback volume override, so
-- every callout can play at this level regardless of the radio's volume setting.
-- Refreshed alongside master_muted at every sound-capable entry point; honors the
-- `VolWhen` setting ("Only connected": override only while telemetry is up).
local audio_volume = nil

-- ============================================================================
-- SHARED STATE (cross-instance)
-- ============================================================================
-- Module-local table shared by ALL instances of this widget (the script chunk is
-- loaded once; its upvalues are common to every instance). Discipline, unlike the
-- looser master_muted above: ONLY the Dashboard-mode instance (the "publisher",
-- ViewMode = Dashboard) writes here — via publish_shared in its refresh/background
-- cycle. ELRS-details / Status-info instances are read-only subscribers, so a
-- passive view on a second screen can show the dashboard's REAL active config
-- (incl. the MSP-fetched FC thresholds) without doing MSP or audio itself.
-- Tables are mutated in place (no per-cycle allocations).
local Shared = {
    ready      = false,   -- true once a Dashboard instance has published
    ts         = nil,     -- getTime() of the last publish (staleness detection)
    model_name = nil,     -- FC craft name (cached by the publisher)
    connected  = false,
    -- style: passive views follow the Dashboard's look (the main widget is the boss)
    color_scheme = nil,   -- ColorScheme option value of the Dashboard instance
    bg_filled    = nil,   -- BGFilled as boolean
    thresholds = {
        source = nil,                                  -- "FC config" / "Manual"
        cell_full = nil, cell_warn = nil, cell_crit = nil,  -- volts (resolved)
        reserve = nil, callout_int = nil,
        rq_warn = nil, rq_crit = nil,
        rss_warn = nil, rss_crit = nil, rss_hold = nil,
        pwr_warn_v = nil, skp_limit = nil,
    },
    alerts = {
        mute = nil, haptic = nil,
        cellchk = nil, fuel = nil, volt = nil, arm = nil,
        telem = nil, link = nil, rssi = nil, pwr = nil, skp = nil,
    },
}

function ultidash_functions.get_shared()
    return Shared
end

-- True while a Dashboard instance is actually RUNNING (published recently). Passive
-- views require this: without a live publisher they show a notice instead of stale
-- or instance-local data ("the main widget is the boss"). Window is generous (10 s)
-- because EdgeTX schedules background() for off-screen widgets at a coarse interval —
-- a too-tight window would flicker the passive views between notice and live.
function ultidash_functions.shared_alive()
    if not Shared.ready then return false end
    local now = getTime() or 0
    return (now - (Shared.ts or 0)) < 1000
end

-- Publisher snapshot: called from the Dashboard instance's refresh/background.
function ultidash_functions.publish_shared(wgt)
    local o, v = wgt.options, wgt.values
    if not o or not v then return end
    local t, a = Shared.thresholds, Shared.alerts

    Shared.ts         = getTime() or 0
    Shared.model_name = v.craft_name
    Shared.connected  = v.rf_connection_state ~= nil and v.rf_connection_state ~= "disconnected"
    Shared.color_scheme = o.ColorScheme or 1
    Shared.bg_filled    = (o.BGFilled == 1)

    t.source      = (o.CellSource == 2) and "Manual" or "FC config"
    t.cell_full   = v.vcel_full_threshold()
    t.cell_warn   = v.vcel_warning_threshold()
    t.cell_crit   = v.vcel_alarm_threshold()
    t.reserve     = o.Reserve
    t.callout_int = o.CalloutInt
    t.rq_warn     = o.RQlyWarn
    t.rq_crit     = o.RQlyCrit
    t.rss_warn    = o.RssWarn
    t.rss_crit    = o.RssCrit
    t.rss_hold    = o.RssHold
    t.pwr_warn_v  = (o.PwrWarnV or 90) / 10
    t.skp_limit   = o.SkpLimit
    t.tpwr_max    = o.TxPwrMax

    a.mute    = (o.Mute == 2)
    a.haptic  = (o.Haptic == 1)
    a.cellchk = (o.SndCellChk == 1)
    a.fuel    = (o.SndFuel == 1)
    a.volt    = (o.SndVolt == 1)
    a.arm     = (o.SndArm == 1)
    a.telem   = (o.SndTelem == 1)
    a.link    = (o.SndLink == 1)
    a.rssi    = (o.SndRssi == 1)
    a.pwr     = (o.PwrWarn == 1)
    a.skp     = (o.SkpWarn == 1)

    Shared.ready = true
end

local function play_audio(file)
    if master_muted then return end
    if audio_volume then
        playFile(AUDIO_PATH .. file .. ".wav", audio_volume)
    else
        playFile(AUDIO_PATH .. file .. ".wav")
    end
end

-- Spoken numbers go through here too, so they follow the widget volume AND the
-- master mute (previously a muted callout could still speak its bare number).
local function play_number(value, unit, attr)
    if master_muted then return end
    if audio_volume then
        playNumber(value, unit, attr or 0, audio_volume)
    else
        playNumber(value, unit, attr or 0)
    end
end

local function play_vibe(wgt)
    if master_muted then return end
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

-- Simulator demo data: smooth, coherent values driven by getTime() so the dashboard
-- drifts gently like a real flight instead of flickering with per-frame random noise.
local SIM_CELLS = 6
-- 0..1 sine; `period_s` = seconds for a full cycle, `phase` = 0..1 offset.
local function sim_wave(period_s, phase)
    local now = getTime() or 0   -- centiseconds
    return 0.5 + 0.5 * math.sin((now / (period_s * 100) + (phase or 0)) * 6.2831853)
end
-- shared simulated per-cell voltage so Vbat = Vcel * cells stays consistent
local function sim_vcel()
    return 3.78 + 0.10 * sim_wave(45, 0)   -- ~3.78..3.88 V, slow drift
end

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

-- resolve the effective callout volume from the settings (see audio_volume above)
local function refresh_audio_volume(wgt)
    local v = wgt.options and wgt.options.Volume or 0
    if v ~= nil and v > 0 then
        if (wgt.options.VolWhen or 1) == 2 and not is_rf_connected(wgt) then
            audio_volume = nil   -- "Only connected" and telemetry is down -> system volume
        else
            audio_volume = v
        end
    else
        audio_volume = nil
    end
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

-- exported armed check (thin wrapper) for the UI layer (e.g. auto-closing the ELRS
-- detail page when the craft arms)
function ultidash_functions.is_armed(wgt)
    return is_craft_armed(wgt)
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
    -- also reset the voltage-latch pendings + collapse flag so each connection starts fresh
    wgt.vbat_pending = nil
    wgt.vcel_pending = nil
    wgt.vbec_pending = nil
    wgt.supply_collapsed = nil
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
    wgt.hs_profile_stats = nil
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
    wgt.link_announced = 0
    -- rssi warning state
    wgt.rssi_pending = 0
    wgt.rssi_level = 0
    wgt.rssi_announced = 0
    -- main-power-loss warning state
    wgt.pwr_pending = 0
    wgt.pwr_announced = false
    -- skipped-packet warning state
    wgt.skp_announced = false
    esc.reset()
end

-- Wipe the EdgeTX min/max sensors and the widget-side extrema. Done once per
-- connection, the first time telemetry is actually valid ("FC fully available"),
-- so the 0-readings EdgeTX recorded before the link was up don't survive.
-- Only clears min/max fields — NOT the MSP data (battery profile/capacity), which
-- is only re-read on a state change and must not be blanked here.
local function reset_stat_sensors(wgt)
    for i = 0, 99 do model.resetSensor(i) end
    local v = wgt.values
    v.vbat_min, v.vbat_max = nil, nil
    v.vcel_min, v.vcel_max = nil, nil
    v.vbec_min, v.vbec_max = nil, nil
    v.esc_temp_min, v.esc_temp_max = nil, nil
    v.curr_min, v.curr_max = nil, nil
    v.headspeed_min, v.headspeed_max = nil, nil
    wgt.hs_profile_stats = nil
    v.rqly_min = nil
    v.tpwr_max = nil
    v.mcu_temp_max = nil
end

-- Per-refresh stats housekeeping based on the RQly (link quality) sensor:
--  * Freeze flag `telemetry_alive`: false ONLY when the link is positively down
--    (RQly == 0); unknown/no sensor (nil) -> true so we don't freeze (legacy).
--    The min/max readers skip their EdgeTX -/+ reads while frozen, so the 0s a
--    lost link produces never reach the stats.
--  * One-shot reset: when a reset is pending (set on (re)connect) and the link is
--    genuinely up (RQly > 0 = "FC fully available"), wipe the stat sensors once so
--    the 0-readings recorded before the link was up don't survive.
local function maybe_reset_stats(wgt)
    if ultidash_functions.simu_mode then
        wgt.telemetry_alive = true
        return
    end
    if wgt.stats_reset_pending == nil then wgt.stats_reset_pending = true end

    local rqly = getSourceValue("RQly")
    wgt.telemetry_alive = (rqly == nil) or (rqly > 0)

    if rqly ~= nil and rqly > 0 and wgt.stats_reset_pending then
        reset_stat_sensors(wgt)
        wgt.stats_reset_pending = false
    end
end

-- ============================================================================
-- GENERAL INFO UPDATES
-- ============================================================================
function ultidash_functions.update_craft_name(wgt)
    -- Prefer the Rotorflight FC model name and CACHE it, so the stats page (shown
    -- on disconnect, where rf2.modelName goes nil) keeps showing the FC name rather
    -- than falling back to the EdgeTX model/profile name. Only fall back to the
    -- EdgeTX name if no FC name was ever seen.
    local fc_name = rf2 and rf2.modelName
    if fc_name and fc_name ~= "" then
        wgt.values.rf_craft_name = string.gsub(fc_name, "^>", "")
    end

    local name = wgt.values.rf_craft_name
    if not name then
        local model_info = model.getInfo()
        name = string.gsub((model_info and model_info.name) or "Unknown", "^>", "")
    end
    wgt.values.craft_name = name
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

    -- guard the integer floor-division: if the radio's General-Settings battery
    -- limits are equal/invalid (battMax <= battMin), the span is 0 and `//` would
    -- raise "attempt to perform 'n//0'" and crash the refresh pass.
    local vtx_span = wgt.values.vtx_volts_max - wgt.values.vtx_volts_min
    if vtx_span <= 0 then
        wgt.values.vtx_volts_percent = 100
        wgt.values.vtx_volts_color = COLOR_THEME_PRIMARY1
        wgt.values.vtx_low = false
        return
    end

    wgt.values.vtx_volts_percent = math.floor(100 -
        (100 * (wgt.values.vtx_volts_max - wgt.values.vtx_volts) // vtx_span))

    if wgt.values.vtx_volts_percent > 100 then wgt.values.vtx_volts_percent = 100 end

    local warn_percent = math.ceil(100 -
        (100 * (wgt.values.vtx_volts_max - wgt.values.vtx_volts_warn) // vtx_span))

    wgt.values.vtx_low = wgt.values.vtx_volts_percent < warn_percent
    if wgt.values.vtx_low then
        wgt.values.vtx_volts_color = COLOR_THEME_WARNING
    else
        wgt.values.vtx_volts_color = COLOR_THEME_PRIMARY1
    end
end

function ultidash_functions.update_link_quality(wgt)
    -- Only track minimum link quality; current value not needed.
    -- Freeze (keep last) while telemetry is down so a 0 doesn't pollute the min.
    if wgt.telemetry_alive ~= false then
        wgt.values.rqly_min = getSourceValue("RQly-")
    end
end

function ultidash_functions.update_transmitter_power(wgt)
    -- Only track maximum transmitter power; current value not needed.
    if wgt.telemetry_alive ~= false then
        wgt.values.tpwr_max = getValue("TPWR+")
    end
end

-- ============================================================================
-- ELRS LINK INFO (RFMD rate, RQ/TQ, RSSI headroom, diversity)  -- slice 1: data
-- ============================================================================
-- RFMD enum -> { rate_str, min_rssi_dBm (sensitivity floor), desc }.
-- Covers ELRS 3.x sequential (1-13, 2.4GHz) + 4.x 2.4GHz (21-41) + GemX (100+).
-- 900MHz 4.x (0-16) collides with 3.x and is NOT disambiguated (rare on a heli) —
-- see ultidash_resourcesandtools/elrs_rfmd_reference.md.
local RFMD_INFO = {
    [1]={"25Hz",-123,"25Hz (LORA)"},   [2]={"50Hz",-115,"50Hz (LORA)"},   [3]={"100Hz",-117,"100Hz (LORA)"},
    [4]={"100HzF",-112,"100Hz (LORA-full)"}, [5]={"150Hz",-112,"150Hz (LORA)"}, [6]={"200Hz",-112,"200Hz (LORA)"},
    [7]={"250Hz",-108,"250Hz (LORA)"}, [8]={"333HzF",-105,"333Hz (LORA-full)"}, [9]={"500Hz",-105,"500Hz (LORA)"},
    [10]={"D250",-104,"250Hz (FLRC-DVDA)"}, [11]={"D500",-104,"500Hz (FLRC-DVDA)"}, [12]={"F500",-104,"500Hz (FLRC)"}, [13]={"F1000",-104,"1000Hz (FLRC)"},
    [21]={"50Hz",-115,"50Hz (LORA)"},  [23]={"100HzF",-112,"100Hz (LORA-full)"}, [24]={"150Hz",-112,"150Hz (LORA)"},
    [27]={"250Hz",-108,"250Hz (LORA)"}, [28]={"333HzF",-105,"333Hz (LORA-full)"}, [29]={"500Hz",-105,"500Hz (LORA)"},
    [30]={"D250",-104,"250Hz (FLRC-DVDA)"}, [31]={"D500",-104,"500Hz (FLRC-DVDA)"}, [32]={"F500",-104,"500Hz (FLRC)"}, [33]={"F1000",-103,"1000Hz (FLRC)"},
    [34]={"DK250",-105,"250Hz (LoRa-DVDA-K)"}, [35]={"DK500",-105,"500Hz (LoRa-DVDA-K)"}, [36]={"K500",-105,"500Hz (Kernel)"}, [37]={"K1000",-102,"1000Hz (Kernel)"},
    [40]={"AP500",-105,"500Hz (Airport)"}, [41]={"APF1000",-103,"1000Hz FLRC (Airport)"},
    [100]={"GX100",-112,"100Hz 8CH (GemX)"}, [101]={"GX150",-112,"150Hz (GemX)"}, [102]={"GX333",-105,"333Hz 8CH (GemX)"}, [103]={"GX500",-105,"500Hz (GemX)"},
}
local ELRS_MAX_RSSI = -40   -- top of the usable RSSI window (like elrs_rf)

-- Convert an RSSI (dBm, negative) to a 0..100 "headroom" % between the per-rate
-- sensitivity floor and ELRS_MAX_RSSI. nil/0 (no value) -> nil.
local function rssi_to_pct(dbm, floor)
    if dbm == nil or dbm == 0 then return nil end
    if floor == nil or floor >= ELRS_MAX_RSSI then return nil end
    local r = math.min(dbm, ELRS_MAX_RSSI)
    local p = 100 * (r - floor) / (ELRS_MAX_RSSI - floor)
    if p < 0 then p = 0 elseif p > 100 then p = 100 end
    return math.floor(p)
end

-- Read the ELRS link sensors and derive rate label + RSSI headroom + diversity.
-- Sensor reads only (no CRSF device ping) so it never interferes with RFTool/MSP.
function ultidash_functions.update_elrs(wgt)
    local v = wgt.values
    if ultidash_functions.simu_mode then
        v.elrs_rfmd  = 24                                   -- 150Hz, 2.4GHz LORA
        v.elrs_rq    = math.floor(95 + 4 * sim_wave(15, 0.2))
        v.elrs_tq    = 100
        v.elrs_r1_dbm = math.floor(-60 - 20 * sim_wave(22, 0.4))
        v.elrs_r2_dbm = math.floor(-70 - 20 * sim_wave(22, 0.9))
        v.elrs_snr   = math.floor(8 + 6 * sim_wave(30, 0))
        v.elrs_diversity = true
        v.elrs_tpwr  = 100
        v.elrs_ant   = 0
    else
        v.elrs_rfmd  = getSourceValue("RFMD")
        v.elrs_rq    = getSourceValue("RQly")
        v.elrs_tq    = getSourceValue("TQly")
        v.elrs_r1_dbm = getSourceValue("1RSS")
        v.elrs_r2_dbm = getSourceValue("2RSS")
        v.elrs_snr   = getSourceValue("RSNR")
        v.elrs_tpwr  = getSourceValue("TPWR")
        -- cached here so the bottom-bar getters never do per-frame name lookups
        v.skp_raw    = getSourceValue("*Skp") or getSourceValue("Skp")
        local ant = getSourceValue("ANT")
        v.elrs_ant   = ant and math.floor(ant) or nil
        v.elrs_diversity = (v.elrs_r2_dbm ~= nil and v.elrs_r2_dbm ~= 0) or (ant ~= nil)
    end

    local info = v.elrs_rfmd and RFMD_INFO[math.floor(v.elrs_rfmd)] or nil
    v.elrs_rate_str  = info and info[1] or "-"
    v.elrs_rate_desc = info and info[3] or "no link"
    local floor = info and info[2] or nil

    v.elrs_r1_pct = rssi_to_pct(v.elrs_r1_dbm, floor)
    v.elrs_r2_pct = rssi_to_pct(v.elrs_r2_dbm, floor)
end

-- ============================================================================
-- AIRCRAFT TELEMETRY: VOLTAGE & TEMPERATURE
-- ============================================================================

-- Latched voltage update (see the MIN_PLAUSIBLE_CELL_V / VOLT_* notes at the top):
-- ≤ 1 V never overwrites the held value; while disarmed a drop > drop_delta below
-- the held value is only accepted once it stayed stable for VOLT_ACCEPT_CS.
-- Returns true when `raw` was accepted into wgt.values[key].
local function latch_voltage(wgt, key, raw, drop_delta)
    local pend_key = key .. "_pending"
    if raw == nil or raw <= MIN_PLAUSIBLE_CELL_V then
        wgt[pend_key] = nil                       -- collapse tail / no data
        return false
    end
    local held = wgt.values[key]
    if held == nil or is_craft_armed(wgt) or raw >= held - drop_delta then
        wgt.values[key] = raw
        wgt[pend_key] = nil
        return true
    end
    -- disarmed + suspicious drop: a decay keeps falling (pending resets every frame
    -- because consecutive readings differ), a real lower pack reads steady and gets
    -- accepted after the window
    local now = getTime()
    local pending = wgt[pend_key]
    if pending == nil or math.abs(raw - pending.v) > drop_delta then
        wgt[pend_key] = { v = raw, t = now }
        return false
    end
    if (now - pending.t) >= VOLT_ACCEPT_CS then
        wgt.values[key] = raw
        wgt[pend_key] = nil
        return true
    end
    return false
end

function ultidash_functions.update_cell(wgt)
    -- Latched (see latch_voltage): the buffer-bridged unplug decay never overwrites
    -- the last good value, so the stats "Latest" column freezes at the real last
    -- battery state instead of 0.00 / a mid-decay value. The collapse itself is still
    -- detected by update_power_warning, which reads the sensor directly.
    local raw = getSourceValue("Vbat")
    local accepted = latch_voltage(wgt, "vbat", raw, VOLT_DROP_CELL * (wgt.values.cel_count or 6))
    -- Main-supply-collapse flag: a real Vbat reading that the latch rejected while we
    -- already hold a good value means the main supply is collapsing/collapsed (unplug
    -- on a buffer). Fires on the FIRST decay frame — other channels (BEC) use it to
    -- hold their last NORMAL value, because once the buffer feeds the rail their
    -- reading shows the buffer, not their own state. False at session start (no held
    -- value yet) and cleared as soon as a reading is accepted again.
    wgt.supply_collapsed = (raw ~= nil and not accepted and wgt.values.vbat ~= nil)
    -- Widget-tracked min/max, recorded ONLY while ARMED (operating) — like the RPM
    -- extrema gate on the governor run-state. The disarmed unplug decay is excluded
    -- twice over (armed gate + latch).
    if is_craft_armed(wgt) and wgt.values.vbat ~= nil then
        update_tracked_extrema(wgt, "vbat", "vbat_min", "vbat_max")
    end

    if ultidash_functions.simu_mode then
        wgt.values.vbat = sim_vcel() * SIM_CELLS
        wgt.values.vbat_min = 3.70 * SIM_CELLS
        wgt.values.vbat_max = 4.15 * SIM_CELLS
    end
end

function ultidash_functions.update_vcel(wgt)
    -- latched like update_cell (fixes "Latest 0.00" after a buffer-bridged unplug)
    local accepted = latch_voltage(wgt, "vcel", getSourceValue("Vcel"), VOLT_DROP_CELL)
    -- widget-tracked, ARMED-only (see update_cell)
    if is_craft_armed(wgt) and wgt.values.vcel ~= nil then
        update_tracked_extrema(wgt, "vcel", "vcel_min", "vcel_max")
    end
    -- Cell count follows the voltage latch: the FC derives Cel# from Vbat, so during a
    -- collapse it reports 0 (or transient counts like 1S mid-decay) — only accept it on
    -- frames whose voltage was accepted too (fixes the "(0S)" header on the stats page).
    local cells = getSourceValue("Cel#")
    if (accepted or wgt.values.vcel == nil) and cells ~= nil and cells > 0 then
        wgt.values.cel_count = cells
    end

    if ultidash_functions.simu_mode then
        wgt.values.vcel = sim_vcel()
        wgt.values.vcel_max = 4.15
        wgt.values.vcel_min = 3.70
        wgt.values.cel_count = SIM_CELLS
    end
end

function ultidash_functions.update_vbec(wgt)
    -- During a main-supply collapse (flag from update_cell) the rail is fed by the
    -- buffer, so the Vbec reading shows the BUFFER's voltage, not the BEC's normal
    -- state (seen as stats "Latest" 8.21 below a Min of 8.30) -> hold the last normal
    -- value for the whole event. The latch's own 0.5 V disarmed-drop guard would NOT
    -- catch this (buffer voltage is typically only ~0.1 V below the BEC).
    if not wgt.supply_collapsed then
        latch_voltage(wgt, "vbec", getSourceValue("Vbec"), 0.5)
    end
    -- widget-tracked, ARMED-only (see update_cell)
    if is_craft_armed(wgt) and wgt.values.vbec ~= nil then
        update_tracked_extrema(wgt, "vbec", "vbec_min", "vbec_max")
    end

    if ultidash_functions.simu_mode then
        wgt.values.vbec = 8.0
        wgt.values.vbec_max = 8.4
        wgt.values.vbec_min = 7.8
    end
end

function ultidash_functions.update_esc_temperature(wgt)
    wgt.values.esc_temp = getSourceValue("Tesc")

    if ultidash_functions.simu_mode then
        wgt.values.esc_temp = 55 + 10 * sim_wave(60, 0)   -- ~55..65 °C, slow
        wgt.values.esc_temp_max = 72
        wgt.values.esc_temp_min = 28
        return
    end

    -- Widget-tracked min/max that ignores the spurious 0 the ESC reports before its
    -- temperature telemetry is up (EdgeTX's Tesc-/+ would keep that 0 in the min).
    local t = wgt.values.esc_temp
    if t ~= nil and t > 0 then
        update_tracked_extrema(wgt, "esc_temp", "esc_temp_min", "esc_temp_max")
    end
end

function ultidash_functions.update_mcu_temperature(wgt)
    if wgt.telemetry_alive ~= false then wgt.values.mcu_temp_max = getSourceValue("Tmcu+") end
end

-- ============================================================================
-- AIRCRAFT TELEMETRY: CURRENT & CAPACITY
-- ============================================================================
function ultidash_functions.update_curr(wgt)
    wgt.values.curr = getSourceValue("Curr")

    if ultidash_functions.simu_mode then
        wgt.values.curr = 28 + 12 * sim_wave(20, 0.3)   -- ~28..40 A
    end

    if should_track_governor_run_extrema(wgt) then
        update_tracked_extrema(wgt, "curr", "curr_min", "curr_max")
    end
end

function ultidash_functions.update_ma_used(wgt)
    wgt.values.capa = getSourceValue("Capa")
    wgt.values.capa_percent = getSourceValue("Bat%")

    if ultidash_functions.simu_mode then
        wgt.values.capa_percent = 40 + 40 * sim_wave(150, 0)   -- ~40..80 %, very slow
        wgt.values.capa = math.floor((100 - wgt.values.capa_percent) / 100 * 2500)
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
    local cell_full = wgt.values.vcel_full_threshold()   -- from FC (mspBatteryConfig)

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
                if wgt.options.SndCellChk == 1 then
                    play_audio("batlow")
                    if vbat then play_number(vbat * 10, 1, PREC1) end
                end
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
        wgt.values.headspeed = 2350 + 150 * sim_wave(25, 0.5)   -- ~2200..2500 rpm
    end

    -- Min/max are tracked PER PID PROFILE: the governor headspeed differs per
    -- profile, so a single pair would mix unrelated rpm bands into meaningless
    -- extremes. The displayed headspeed_min/max always mirror the CURRENTLY
    -- selected profile's pair — flip the profile switch after landing to inspect
    -- each profile's stats. Cost: one table lookup per 5 Hz tick.
    local prof = wgt.values.profile_id or 0
    local stats = wgt.hs_profile_stats
    if stats == nil then stats = {}; wgt.hs_profile_stats = stats end
    local s = stats[prof]
    if s == nil then s = {}; stats[prof] = s end
    if should_track_governor_run_extrema(wgt) then
        local v = wgt.values.headspeed
        if v ~= nil then
            if s.min == nil or v < s.min then s.min = v end
            if s.max == nil or v > s.max then s.max = v end
        end
    end
    wgt.values.headspeed_min = s.min
    wgt.values.headspeed_max = s.max
end

function ultidash_functions.update_gov_state(wgt)
    wgt.values.gov_state = getSourceValue("Gov")
    if ultidash_functions.simu_mode then wgt.values.gov_state = 4 end   -- Gov. Active (stable)
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

-- ============================================================================
-- SWITCH VOICE ANNOUNCEMENTS
-- ============================================================================
-- Speak configured TX-switch positions (motor/rescue/governor on-off + profile
-- 1..3). READ-ONLY getValue on the physical switch — fully independent of the
-- model's mixer/logical-switch safety chain (which stays in the model) and of
-- telemetry. Each function is selectable in the settings incl. an inverted
-- variant (choice list: Off, SA, SA inv, SB, ... SH inv).

local SWITCH_SRC = { "sa", "sb", "sc", "sd", "se", "sf", "sg", "sh" }

local function switch_voice_pos(idx)
    if idx == nil or idx <= 1 then return nil end          -- 1 = Off
    if idx >= 100 then
        -- logical switch (code = 100 + 2*ls_index, +1 = inverted): boolean on/off
        local lsi = math.floor((idx - 100) / 2)
        local ok, v = pcall(getLogicalSwitchValue, lsi)
        if not ok or v == nil then return nil end
        local p = v and 3 or 1
        if idx % 2 == 1 then p = 4 - p end
        return p
    end
    local si = math.floor((idx - 2) / 2) + 1
    local src = SWITCH_SRC[si]
    if src == nil then return nil end
    local ok, v = pcall(getValue, src)
    if not ok or v == nil then return nil end
    local p
    if v > 200 then p = 3 elseif v < -200 then p = 1 else p = 2 end
    if idx % 2 == 1 then p = 4 - p end                     -- odd indices = inverted
    return p
end

local SWITCH_VOICES = {
    { key = "MotorSw",   on = "motor_on",  off = "motor_off" },
    { key = "RescueSw",  on = "rescue_on", off = "rescue_off" },
    { key = "GovSw",     on = "gov_on",    off = "gov_off" },
    { key = "ProfileSw", profile = true },
}

function ultidash_functions.update_switch_voices(wgt)
    if wgt.options == nil then return end
    local st = wgt.swv
    if st == nil then st = {}; wgt.swv = st end
    local now = getTime() or 0
    for i = 1, #SWITCH_VOICES do
        local f = SWITCH_VOICES[i]
        local p = switch_voice_pos(wgt.options[f.key])
        local s = st[f.key]
        if s == nil then
            s = { last = p, pend = p, t = now }             -- no announce on boot
            st[f.key] = s
        end
        if p ~= s.pend then
            s.pend = p
            s.t = now
        elseif p ~= nil and p ~= s.last and (now - s.t) >= 30 then
            -- stable for 0.3 s (a 3-pos switch passes through mid on its way)
            local first = (s.last == nil)   -- switch just got configured: baseline silently
            s.last = p
            if first then
                -- baseline only, no announcement
            elseif f.profile then
                play_audio("profile")
                play_number(p, 0)
            elseif p == 3 then
                play_audio(f.on)
            elseif p == 1 then
                play_audio(f.off)
            end
            -- the mid position of on/off functions stays silent on purpose
        end
    end
end

-- ESC/status event LOG (modeled after eStatus' app-mode view): every status
-- change is recorded with a wall-clock timestamp for the status detail page.
local ESC_LOG_MAX = 30

local function estatus_log(wgt, text, level)
    if text == nil or text == "" then return end
    local log = wgt.esc_log
    if log == nil then log = {}; wgt.esc_log = log end
    local last = log[#log]
    if last ~= nil and last.text == text then return end   -- dedup repeats
    local dt = getDateTime()
    local ts = dt and string.format("%02d:%02d:%02d", dt.hour or 0, dt.min or 0, dt.sec or 0) or ""
    log[#log + 1] = { time = ts, text = text, level = level or 1 }
    if #log > ESC_LOG_MAX then table.remove(log, 1) end
end

function ultidash_functions.get_esc_log(wgt)
    return wgt.esc_log
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
        wgt.values.throttle_text = string.format("%d%%", math.floor(55 + 15 * sim_wave(18, 0.7)))
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
        estatus_log(wgt, "RESTART ESC", esc.LEVEL_ERROR)
    elseif connected then
        local st = esc.get_status(sig, flags, changed)
        if st then
            -- every status CHANGE goes into the event log (detail page)
            if changed then estatus_log(wgt, st.text, st.level) end
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
            if wgt.options.SndArm == 1 then
                play_audio(armed and "armed" or "disarm")
            end
            estatus_log(wgt, armed and "Armed" or "Disarmed", esc.LEVEL_INFO)
        end
        wgt.estatus_armed = armed
    else
        wgt.estatus_armed = nil
    end
end

function ultidash_functions.on_telemetry_state_changed(wgt, previous_state, new_state)
    master_muted = wgt.options and wgt.options.Mute == 2   -- CHOICE: 1=None, 2=All
    refresh_audio_volume(wgt)
    local telem_snd = wgt.options and wgt.options.SndTelem == 1

    if previous_state == "disconnected" and new_state ~= "disconnected" then
        clear_live_telemetry_values(wgt)
        ultidash_functions.reset_telemetry_stats(wgt)
        -- telemetry recovered: announce only if the loss happened while armed (in flight)
        if telem_snd and wgt.link_lost_armed then
            play_audio("telem_ok")
        end
        wgt.link_lost_armed = false
        return
    end

    -- telemetry lost while ARMED (in flight): urgent voice + vibrate.
    -- losses while disarmed / on the bench stay silent (logged only).
    if new_state == "disconnected" then
        if previous_state == "armed" then
            ultidash_functions.log("Connection lost (armed)")
            if telem_snd then
                play_audio("telem_lost")
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
    -- bail if fuel callouts are switched off
    if wgt.options.SndFuel ~= 1 then return end

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
                play_number(capa, UNIT_PERCENT)
            end
        end
        wgt.callout_last_capa = capa
        wgt.callout_next_capa = now + interval
    end
end

-- ePowerbar crankVoltageAlerts: low/critical per-cell voltage alerts with debounce.
local function crank_voltage_alerts(wgt)
    -- bail if voltage alerts are switched off
    if wgt.options.SndVolt ~= 1 then return end

    local cellv = wgt.values.vcel
    -- ignore implausible (<1V) readings -> a collapsed/lost supply is no real "critical"
    if cellv == nil or cellv <= MIN_PLAUSIBLE_CELL_V then return end

    local now = getTime()
    if now < wgt.alert_next then return end

    -- thresholds come from the Rotorflight FC (mspBatteryConfig), in centivolts
    local cv = math.floor(cellv * 100)
    local alarm = math.floor(wgt.values.vcel_alarm_threshold() * 100)
    local low = math.floor(wgt.values.vcel_warning_threshold() * 100)

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
            if vbat then play_number(vbat * 10, UNIT_VOLTS, PREC1) end
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
-- Two stages (warn / critical) with a short debounce. Spoken ONCE per low-link
-- episode (re-armed when the link recovers above the warn threshold; a warn->crit
-- escalation announces once more). Only fires while ARMED (in flight);
-- telemetry-lost itself is handled in on_telemetry_state_changed (armed-gated).
local LINK_SAMPLE_CS = 50

function ultidash_functions.update_link_warning(wgt)
    if wgt.options.SndLink ~= 1 then
        wgt.link_pending = 0
        wgt.link_level = 0
        wgt.link_announced = 0
        return
    end
    -- only while armed (in flight); no link callouts on the bench / disarmed
    if not is_craft_armed(wgt) then
        wgt.link_pending = 0
        wgt.link_level = 0
        wgt.link_announced = 0
        return
    end

    local rqly = getSourceValue("RQly")
    if ultidash_functions.simu_mode then rqly = 99 end
    if rqly == nil then return end

    local now = getTime()
    local warn = wgt.options.RQlyWarn or 50
    local crit = wgt.options.RQlyCrit or 30
    local level = (rqly <= crit and 2) or (rqly <= warn and 1) or 0

    -- recovered above the warn threshold: re-arm so the next drop announces again
    if level == 0 then
        wgt.link_pending = 0
        wgt.link_level = 0
        wgt.link_announced = 0
        return
    end

    -- already announced this severity (or worse) this episode: stay silent until
    -- the link recovers or escalates to a more severe level (announce once)
    if level <= (wgt.link_announced or 0) then
        wgt.link_pending = 0
        return
    end

    -- new or escalated low-link level: debounce, take the worst seen, announce once
    if (wgt.link_pending or 0) == 0 then
        wgt.link_level = level
        wgt.link_pending = now + LINK_SAMPLE_CS
        return
    end
    if level > wgt.link_level then wgt.link_level = level end

    if now >= wgt.link_pending then
        if wgt.link_level >= 2 then
            play_audio("link_crit")
            play_vibe(wgt)
        else
            play_audio("link_warn")
        end
        -- announce the actual link quality value
        play_number(rqly, UNIT_PERCENT)
        wgt.link_announced = wgt.link_level
        wgt.link_pending = 0
    end
end

-- ELRS RSSI warning: while ARMED, when the (best-antenna) RSSI headroom % drops to
-- RssWarn/RssCrit, speak `rssi_warn`/`rssi_crit` ONCE per episode (re-armed when it
-- recovers above warn; a warn->crit escalation announces once more). Sensor-derived
-- (elrs_r1_pct/elrs_r2_pct from update_elrs), no MSP -> armed-safe. Toggle: SndRssi.
function ultidash_functions.update_rssi_warning(wgt)
    if wgt.options.SndRssi ~= 1 then
        wgt.rssi_pending = 0
        wgt.rssi_level = 0
        wgt.rssi_announced = 0
        return
    end
    if not is_craft_armed(wgt) then
        wgt.rssi_pending = 0
        wgt.rssi_level = 0
        wgt.rssi_announced = 0
        return
    end

    -- effective signal = the better antenna's headroom (diversity picks the stronger)
    local p = wgt.values.elrs_r1_pct
    if wgt.values.elrs_diversity and wgt.values.elrs_r2_pct then
        p = math.max(p or 0, wgt.values.elrs_r2_pct)
    end
    if ultidash_functions.simu_mode then p = 80 end
    if p == nil then return end

    local now = getTime()
    local warn = wgt.options.RssWarn or 50
    local crit = wgt.options.RssCrit or 25
    local level = (p <= crit and 2) or (p <= warn and 1) or 0

    if level == 0 then
        wgt.rssi_pending = 0
        wgt.rssi_level = 0
        wgt.rssi_announced = 0
        return
    end
    if level <= (wgt.rssi_announced or 0) then
        wgt.rssi_pending = 0
        return
    end
    -- RSSI is noisier than RQly (raw dBm, brief rotational antenna nulls last up to
    -- ~1.5 s and are harmless) -> use a dedicated, longer hold time (RssHold, seconds)
    -- so only a SUSTAINED low signal alarms. The value must stay at/below the
    -- threshold for the whole window; any recovery (level 0) above resets it.
    local hold_cs = (wgt.options.RssHold or 2) * 100
    if (wgt.rssi_pending or 0) == 0 then
        wgt.rssi_level = level
        wgt.rssi_pending = now + hold_cs
        return
    end
    if level > wgt.rssi_level then wgt.rssi_level = level end

    if now >= wgt.rssi_pending then
        if wgt.rssi_level >= 2 then
            play_audio("rssi_crit")
            play_vibe(wgt)
        else
            play_audio("rssi_warn")
        end
        wgt.rssi_announced = wgt.rssi_level
        wgt.rssi_pending = 0
    end
end

-- Main-power-loss warning: while ARMED *and still connected*, if Vbat drops below the
-- configurable threshold (PwrWarnV, in 0.1 V; default 9.0 V) the craft is likely
-- running on backup power. This explicitly INCLUDES a Vbat that has collapsed to ~0
-- (main pack disconnected, FC alive on the buffer) — telemetry keeps flowing in that
-- case, so the connection stays live and we can trust the reading; a real telemetry
-- dropout flips to "disconnected" and is suppressed (handled as telem-lost instead).
-- Announced ONCE per drop (re-armed when Vbat recovers above the threshold). Separate
-- on/off via PwrWarn. Reads Vbat directly so it also works off-screen (background);
-- sensor read only (no MSP) -> armed-safe.
function ultidash_functions.update_power_warning(wgt)
    if not wgt.options or wgt.options.PwrWarn ~= 1 then
        wgt.pwr_pending = 0
        wgt.pwr_announced = false
        return
    end
    if not is_craft_armed(wgt) then
        wgt.pwr_pending = 0
        wgt.pwr_announced = false
        return
    end

    local vbat = getSourceValue("Vbat")
    if vbat == nil then return end

    local thresh = (wgt.options.PwrWarnV or 90) / 10
    local now = getTime()

    if vbat < thresh then
        -- Distinguish a real main-power loss (buffer/backup took over) from a plain
        -- telemetry dropout: a buffer-kick keeps telemetry flowing, so the connection
        -- stays live while Vbat collapses to ~0; a dropout flips to "disconnected"
        -- (and usually clears the armed gate above). Only warn while still connected
        -- -> a dropout's 0/stale Vbat can't false-trigger "main power lost". (This is
        -- why the old `vbat <= 0 -> return` guard is gone: a collapsed Vbat IS the
        -- signal we now want to catch, as long as the link is alive.)
        if not is_rf_connected(wgt) then
            wgt.pwr_pending = 0
            return
        end
        if wgt.pwr_announced then return end
        -- debounce: the low reading must hold briefly (avoids transient sag)
        if (wgt.pwr_pending or 0) == 0 then
            wgt.pwr_pending = now + ALERT_SAMPLE_CS
            return
        end
        if now >= wgt.pwr_pending then
            play_audio("pwr_backup")
            play_vibe(wgt)
            wgt.pwr_announced = true
            wgt.pwr_pending = 0
        end
    else
        wgt.pwr_pending = 0
        wgt.pwr_announced = false
    end
end

-- Skipped-telemetry-packet warning: while ARMED, if the cumulative *Skp counter
-- reaches the configurable limit, speak `skp_high` once. The counter only climbs
-- and is reset on telemetry (re)connect, so it announces once per flight; re-arms
-- when it drops below the limit again (i.e. after a reset). Sensor read only (no
-- MSP) -> armed-safe. Separate on/off via the SkpWarn option.
function ultidash_functions.update_skp_warning(wgt)
    if not wgt.options or wgt.options.SkpWarn ~= 1 then
        wgt.skp_announced = false
        return
    end
    if not is_craft_armed(wgt) then
        wgt.skp_announced = false
        return
    end

    local skp = getSourceValue("*Skp")
    if skp == nil then skp = getSourceValue("Skp") end
    if skp == nil then return end

    local limit = wgt.options.SkpLimit or 50
    if skp >= limit then
        if not wgt.skp_announced then
            play_audio("skp_high")
            wgt.skp_announced = true
        end
    else
        wgt.skp_announced = false
    end
end

function ultidash_functions.reset_telemetry_stats(wgt)
    model.resetTimer(wgt.options.Timer or 0)
    reset_flight_time(wgt)

    -- Reset battery callout state on disconnect
    reset_callout_state(wgt)

    -- Defer the EdgeTX min/max sensor wipe until telemetry is actually valid
    -- ("FC fully available"), so pre-link 0-readings don't survive the reset.
    wgt.stats_reset_pending = true
end

-- ============================================================================
-- REFRESH ORCHESTRATION
-- ============================================================================

function ultidash_functions.refresh_ui_no_conn(wgt)
    ultidash_functions.update_tx_bat_voltage(wgt)
    ultidash_functions.update_craft_name(wgt)
    ultidash_functions.update_model_image(wgt)
    ultidash_functions.update_estatus(wgt)
    ultidash_functions.update_elrs(wgt)
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
    master_muted = wgt.options and wgt.options.Mute == 2   -- CHOICE: 1=None, 2=All
    refresh_audio_volume(wgt)
    ultidash_functions.update_switch_voices(wgt)
    maybe_reset_stats(wgt)
    ultidash_functions.update_battery_callout(wgt)
    ultidash_functions.update_link_warning(wgt)
    ultidash_functions.update_rssi_warning(wgt)
    ultidash_functions.update_power_warning(wgt)
    ultidash_functions.update_skp_warning(wgt)

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
    master_muted = wgt.options and wgt.options.Mute == 2   -- CHOICE: 1=None, 2=All
    refresh_audio_volume(wgt)
    ultidash_functions.update_switch_voices(wgt)
    if ultidash_functions.simu_mode then
        wgt.telemetry_alive = true
        ultidash_functions.refresh_ui(wgt)
        return
    end

    maybe_reset_stats(wgt)

    if not is_rf_connected(wgt) then
        ultidash_functions.refresh_ui_no_conn(wgt)
        return
    end
    ultidash_functions.refresh_ui(wgt)
    ultidash_functions.update_battery_callout(wgt)
    ultidash_functions.update_link_warning(wgt)
    ultidash_functions.update_rssi_warning(wgt)
    ultidash_functions.update_power_warning(wgt)
    ultidash_functions.update_skp_warning(wgt)
end

return ultidash_functions
