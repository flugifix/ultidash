local script_dir = "/WIDGETS/UltiDash/"
local ultidash_functions = loadScript(script_dir .. "ultidashFunctions.lua")()
local ultidash_values = loadScript(script_dir .. "ultidashValues.lua")()
local rf_service = loadScript(script_dir .. "ultidashRf.lua")()
local ultidash_settings = loadScript(script_dir .. "ultidashSettings.lua")()
-- Toolbox tool pages (RF adjustment map/editor), loaded modular + pcall'd so a missing
-- file degrades gracefully (the Toolbox menu entries just won't do anything).
local tb_adjmap = nil
local tb_adjed = nil
do
    local ok1, m1 = pcall(function() return loadScript(script_dir .. "toolbox/adjmap.lua")() end)
    if ok1 then tb_adjmap = m1 end
    local ok2, m2 = pcall(function() return loadScript(script_dir .. "toolbox/adjed.lua")() end)
    if ok2 then tb_adjed = m2 end
end
local show_debug_border = 0

-- ============================================================================
-- COLOR PALETTE
-- Shadow the EdgeTX theme color constants as file-locals so the whole UI can be
-- switched to a fixed "Clean" palette (independent of the active EdgeTX theme)
-- via the ColorScheme option — without touching the many call sites below.
-- set_palette() reassigns these locals; the call sites just see the new values.
-- ============================================================================
local COLOR_THEME_PRIMARY1   = COLOR_THEME_PRIMARY1
local COLOR_THEME_PRIMARY2   = COLOR_THEME_PRIMARY2
local COLOR_THEME_SECONDARY1 = COLOR_THEME_SECONDARY1
local COLOR_THEME_SECONDARY2 = COLOR_THEME_SECONDARY2
local COLOR_THEME_SECONDARY3 = COLOR_THEME_SECONDARY3
local COLOR_THEME_FOCUS      = COLOR_THEME_FOCUS
local COLOR_THEME_WARNING    = COLOR_THEME_WARNING
local COLOR_THEME_DISABLED   = COLOR_THEME_DISABLED

-- originals (follow active EdgeTX theme)
local THEME_PALETTE = {
    COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2,
    COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS, COLOR_THEME_WARNING, COLOR_THEME_DISABLED,
}
-- static "Clean Theme" (Mate Soos) values
local CLEAN_PALETTE = {
    lcd.RGB(0x00, 0x00, 0x00), lcd.RGB(0xF8, 0xFC, 0xF8), lcd.RGB(0x00, 0x00, 0x00), lcd.RGB(0x98, 0xB4, 0xE8),
    lcd.RGB(0xD8, 0xE0, 0xE8), lcd.RGB(0xC0, 0x30, 0x38), lcd.RGB(0xE8, 0x30, 0x30), lcd.RGB(0xF8, 0x3C, 0x00),
}
-- static "UltiDash dark" high-contrast palette (bright text + NEON accents on black).
-- Slots map the same way as CLEAN/THEME: 1 PRIMARY1, 2 PRIMARY2, 3 SECONDARY1,
-- 4 SECONDARY2, 5 SECONDARY3, 6 FOCUS, 7 WARNING, 8 DISABLED. Text roles (PRIMARY1,
-- SECONDARY1) stay near-white for readability; the accents (SECONDARY2 neon green,
-- FOCUS neon cyan, WARNING neon red, DISABLED neon amber) glow against the black panel.
local DARK_PALETTE = {
    lcd.RGB(0xFF, 0xFF, 0xFF), lcd.RGB(0x08, 0x0A, 0x0C), lcd.RGB(0xF0, 0xF4, 0xF8), lcd.RGB(0x39, 0xFF, 0x14),
    lcd.RGB(0x08, 0x0A, 0x0C), lcd.RGB(0x00, 0xE5, 0xFF), lcd.RGB(0xFF, 0x1A, 0x40), lcd.RGB(0xFF, 0xC4, 0x00),
}

-- panel background used when BGFilled is on. For the Clean palette this is WHITE to match
-- the Clean theme's actual wallpaper (which is solid white, not SECONDARY3); for the EdgeTX
-- theme it follows SECONDARY3 as before; the dark scheme paints solid black.
local PANEL_BG = COLOR_THEME_SECONDARY3
-- The dark scheme needs a solid dark panel to read white text, so it FORCES the
-- background fill on regardless of the BGFilled option (set by set_palette).
local force_bg_fill = false
-- True while the dark scheme is the ACTIVE palette — lets a few call sites pick a
-- brighter variant (e.g. the link-bar "quiet" fill, which would otherwise sit too
-- close to the dark track and become invisible).
local dark_scheme = false

-- Neutral UI chrome (bar/track backgrounds, tick marks, dim labels). Kept as fixed
-- greys in the UltiDash/Clean look, but DERIVED FROM THE THEME in EdgeTX-theme mode
-- so theme awareness is consistent there too. Semantic colours (battery/warn
-- green-yellow-red) and the battery graphic's own black overlay text stay fixed.
local COLOR_TRACK = lcd.RGB(0xC8, 0xC8, 0xC8)   -- empty bar / track background
local COLOR_TICK  = lcd.RGB(0x20, 0x20, 0x20)   -- strong threshold tick marks
local COLOR_DIM   = lcd.RGB(0x90, 0x90, 0x90)   -- dim secondary text / light ticks

-- scheme: 1 = UltiDash (clean/white), 2 = EdgeTX theme, 3 = UltiDash dark (high contrast)
local function set_palette(scheme)
    local clean = (scheme == 1)
    local dark  = (scheme == 3)
    local p = dark and DARK_PALETTE or (clean and CLEAN_PALETTE or THEME_PALETTE)
    COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2 = p[1], p[2], p[3], p[4]
    COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS, COLOR_THEME_WARNING, COLOR_THEME_DISABLED = p[5], p[6], p[7], p[8]
    force_bg_fill = dark
    dark_scheme   = dark
    if dark then
        PANEL_BG    = lcd.RGB(0x00, 0x00, 0x00)
        COLOR_TRACK = lcd.RGB(0x28, 0x30, 0x38)   -- dark empty bar/track (lets neon fills pop)
        COLOR_TICK  = lcd.RGB(0xFF, 0xFF, 0xFF)   -- pure-white tick marks on black
        COLOR_DIM   = lcd.RGB(0xC0, 0xC8, 0xD0)   -- bright dim text on black
    elseif clean then
        PANEL_BG    = lcd.RGB(0xFF, 0xFF, 0xFF)
        COLOR_TRACK = lcd.RGB(0xC8, 0xC8, 0xC8)
        COLOR_TICK  = lcd.RGB(0x20, 0x20, 0x20)
        COLOR_DIM   = lcd.RGB(0x90, 0x90, 0x90)
    else
        PANEL_BG    = THEME_PALETTE[5]
        COLOR_TRACK = COLOR_THEME_SECONDARY2   -- subtle fill against the theme bg
        COLOR_TICK  = COLOR_THEME_SECONDARY1   -- strong line/mark colour
        COLOR_DIM   = COLOR_THEME_DISABLED     -- greyed/dim text
    end
end

-- Palette for the Toolbox tool pages so they FIT the dashboard's look. The tools are kept
-- MONOCHROME like the detail pages (light = black on light-grey, dark = white on dark-grey):
-- header, labels and the +/- buttons use the theme fg/greys, and ONLY the VALUES carry the
-- scheme accent colour so they stand out (the "blue everywhere" of the old palette is gone).
-- Handed to the tool modules via wgt.tb_pal (the sunlight option overrides inside the module).
local function toolbox_palette(scheme)
    if scheme == 1 then         -- UltiDash clean (light): mono black/grey, values in the accent
        return { bg = lcd.RGB(248,250,248), accent = lcd.RGB(24,24,24), hint = lcd.RGB(216,96,0), line = lcd.RGB(180,184,190),
                 text = lcd.RGB(24,24,24), textDim = lcd.RGB(130,130,130),
                 valText = lcd.RGB(48,90,144), valHi = lcd.RGB(192,48,56), bannerBg = lcd.RGB(192,48,40), bannerFg = lcd.RGB(255,255,255),
                 btnBg = lcd.RGB(208,212,218), btnPressed = lcd.RGB(184,190,200), btnDim = lcd.RGB(226,228,231), btnFg = lcd.RGB(24,24,24) }
    elseif scheme == 3 then     -- UltiDash dark: mono white/grey, values in the neon accent
        return { bg = lcd.RGB(0,0,0), accent = lcd.RGB(240,240,240), hint = lcd.RGB(255,122,26), line = lcd.RGB(56,60,64),
                 text = lcd.RGB(240,240,240), textDim = lcd.RGB(150,156,162),
                 valText = lcd.RGB(0,229,255), valHi = lcd.RGB(255,176,0), bannerBg = lcd.RGB(255,68,56), bannerFg = lcd.RGB(0,0,0),
                 btnBg = lcd.RGB(48,52,58), btnPressed = lcd.RGB(74,80,88), btnDim = lcd.RGB(34,36,40), btnFg = lcd.RGB(235,235,235) }
    else                        -- EdgeTX theme: mono theme fg/bg, values in the theme focus colour
        return { bg = COLOR_THEME_SECONDARY3, accent = COLOR_THEME_PRIMARY1, hint = COLOR_THEME_DISABLED, line = COLOR_THEME_SECONDARY1,
                 text = COLOR_THEME_PRIMARY1, textDim = COLOR_THEME_DISABLED,
                 valText = COLOR_THEME_FOCUS, valHi = COLOR_THEME_WARNING, bannerBg = COLOR_THEME_WARNING, bannerFg = COLOR_THEME_PRIMARY2,
                 btnBg = COLOR_THEME_SECONDARY2, btnPressed = COLOR_THEME_SECONDARY1, btnDim = COLOR_THEME_SECONDARY3, btnFg = COLOR_THEME_PRIMARY2 }
    end
end
-- Header font - set dynamically in the active UI builder based on available space
local header_font = MIDSIZE
local header_h = 0
local card_gap = 2
local card_padding = 3
local compact_card_padding = math.max(2, card_padding - 1)
local default_view = "flight"
local STATS_VIEW_MODE_NEVER = 1
local STATS_VIEW_MODE_DISARMED = 2
local STATS_VIEW_MODE_DISCONNECTED = 3
local DEFAULT_STATS_VIEW_MODE = STATS_VIEW_MODE_DISARMED
local SIM_VIEW_SWITCH_INTERVAL = 12 * 100

local FONT_CONSTANTS = {
    TINSIZE = TINSIZE,
    SMLSIZE = SMLSIZE,
    STDSIZE = STDSIZE,
    MIDSIZE = MIDSIZE,
    DBLSIZE = DBLSIZE,
    XXLSIZE = XXLSIZE
}

local xlsize = _G["XLSIZE"]
local has_xlsize = (type(xlsize) == "number")
if has_xlsize then
    ultidash_functions.log("XLSIZE font constant found with value: " .. tostring(xlsize))
    FONT_CONSTANTS.XLSIZE = xlsize
end

local FONT_ORDER = { "XXLSIZE", "DBLSIZE", "MIDSIZE", "STDSIZE", "SMLSIZE", "TINSIZE" }
if has_xlsize then
    table.insert(FONT_ORDER, 2, "XLSIZE")
end

-- NOTE: each placed instance gets its OWN widget table (created in `create`), so a
-- second instance (ViewMode = ELRS details / Status info) on another screen has its
-- own zone/options/values. Cross-instance data flows ONLY through the module-local
-- `Shared` table in ultidashFunctions (publisher = the Dashboard-mode instance).

local VIEW_MODE_DASHBOARD = 1
local VIEW_MODE_ELRS      = 2
local VIEW_MODE_STATUS    = 3

--- The Dashboard-mode instance is the publisher: it alone runs the RF state machine,
--- MSP, audio/stats side effects and publishes the Shared snapshot. ELRS/Status
--- instances are passive (sensor reads + rendering only).
local function is_publisher(widget)
    -- lenient: anything that isn't explicitly a passive mode counts as Dashboard
    -- (an out-of-range stored value — e.g. after the option-list change — must
    -- never silently turn a Dashboard placement passive and kill audio/MSP)
    local vm = widget.options and widget.options.ViewMode
    return vm ~= VIEW_MODE_ELRS and vm ~= VIEW_MODE_STATUS
end

--- Signature of everything a passive view inherits from the Dashboard (publisher
--- alive? which palette/background?). Compared each refresh against the value stored
--- at build time — on change the passive view rebuilds itself, so it follows the
--- Dashboard's look live and flips to/from the "no Dashboard" notice automatically.
local function passive_style_sig()
    -- numeric on purpose: this runs every refresh cycle of passive instances and
    -- a string build there would churn the garbage collector
    if not ultidash_functions.shared_alive() then return -1 end
    local shared = ultidash_functions.get_shared()
    return (shared.color_scheme or 0) * 2 + (shared.bg_filled and 1 or 0)
end

--- Initialize the widget view state and fill in any missing defaults.
local function init_view_state(widget)
    widget.view = widget.view or { current = default_view, dirty = true, ever_armed = false }
    widget.view.current = widget.view.current or default_view
    if widget.view.ever_armed == nil then widget.view.ever_armed = false end
    return widget.view
end

--- Return a valid statistics view mode, falling back to the default when needed.
local function get_stats_view_mode(widget)
    if widget.options.StatsViewMode ~= STATS_VIEW_MODE_NEVER and widget.options.StatsViewMode ~= STATS_VIEW_MODE_DISARMED and widget.options.StatsViewMode ~= STATS_VIEW_MODE_DISCONNECTED then
        return DEFAULT_STATS_VIEW_MODE
    end
    return widget.options.StatsViewMode
end

--- Alternate between flight and stats views while running in the simulator.
local function get_simulation_target_view()
    local now = getTime() or 0
    local phase = math.floor(now / SIM_VIEW_SWITCH_INTERVAL) % 2
    if phase == 0 then
        return "flight"
    end
    return "stats"
end

--- Decide which high-level view should be active for the current telemetry state.
local function get_target_view(widget)
    local view = init_view_state(widget)
    local mode = get_stats_view_mode(widget)

    if ultidash_functions.simu_mode then
        return get_simulation_target_view()
    end

    if widget.values.rf_connection_state == "armed" then
        view.ever_armed = true
        -- NB: do NOT clear stats_dismissed here — the "armed" sub-state is unreliable on
        -- this RFTool and can briefly bounce back to "armed" right after disarming, which
        -- would undo a just-made manual dismiss ("stats closes then reopens instantly").
        -- A REAL arm clears the dismiss via the ARM sensor (armed_now) in the 5 Hz pass.
        return "flight"
    end
    if mode == STATS_VIEW_MODE_NEVER or view.ever_armed ~= true then
        return "flight"
    end
    -- manually dismissed (tap on the stats page) — stay on flight until the next
    -- arm or reconnect clears the flag
    if widget.stats_dismissed then
        return "flight"
    end
    if mode == STATS_VIEW_MODE_DISARMED then
        return "stats"
    end
    if mode == STATS_VIEW_MODE_DISCONNECTED and widget.values.rf_connection_state == "disconnected" then
        return "stats"
    end
    return "flight"
end

--- Switch the active view when telemetry state requires a different layout.
local function sync_view_for_telemetry(widget)
    local view = init_view_state(widget)
    local target_view = get_target_view(widget)
    if view.current == target_view then return false end

    view.current = target_view
    view.dirty = true
    widget.layout_dirty = true
    -- any flight/stats switch closes the ELRS detail page (it only overlays "flight")
    widget.detail_view = nil
    return true
end

--- Propagate telemetry state changes to services and update the selected view.
local function handle_telemetry_state_change(widget, previous_state, new_state)
    -- diagnostics: log every state transition + flush promptly (no-op unless DebugLog on).
    -- The disarm/disconnect transition is also where the in-flight buffer reaches the SD.
    if ultidash_functions.dbg then
        ultidash_functions.dbg.logf("STATE", "%s -> %s", tostring(previous_state), tostring(new_state))
        ultidash_functions.dbg.flush(true)
    end
    ultidash_functions.on_telemetry_state_changed(widget, previous_state, new_state)
    -- Scope ever_armed to THIS connection: on every fresh connect (disconnected -> any
    -- connected state) start a new "session". So the stats page (On disarmed / On
    -- disconnected) only appears after the craft was armed *this* connection — not
    -- because an earlier connection in the same widget runtime was armed. Without this,
    -- ever_armed stayed true for the whole runtime → stats showed on a later connect that
    -- never armed, and the dashboard stuck on old/stats values instead of returning to the
    -- flight view. Live values + stats are already cleared in on_telemetry_state_changed.
    if previous_state == "disconnected" and new_state ~= "disconnected" then
        init_view_state(widget).ever_armed = false
        -- NB: do NOT clear stats_dismissed on reconnect. A main-power-lost aftermath can
        -- bounce the link (disconnect/reconnect) while the pilot is trying to close the
        -- stats page, and re-clearing here reopened it. The "arming forgets the dismiss"
        -- clear (debounced, in the 5 Hz pass) is the single source for that reset now.
    end
    sync_view_for_telemetry(widget)
end

--- Prepare a widget instance once (view state only — RF services are publisher-only).
local function prepare_widget(widget)
    if not widget then return nil end
    if not widget.app_prepared then
        init_view_state(widget)
        widget.app_prepared = true
    end
    return widget
end

--- Attach the RF service lazily and only for the publisher (Dashboard) instance.
--- ELRS/Status instances never register with rf2 → no second MSP consumer, no
--- duplicate state-machine callbacks. Lazy (not in prepare_widget) so a mode change
--- via the options menu picks the service up on the next cycle.
local function ensure_rf_service(widget)
    if widget.rf_service_ready then return end
    rf_service.init(widget, handle_telemetry_state_change)
    widget.sync_active_battery_capacity = rf_service.sync_active_battery_capacity
    widget.rf_service_ready = true
end

-- ============================================================================
-- UTILITY FUNCTIONS: Font management
-- ============================================================================

--- Measure font height and optionally reject it when a sample string is too wide.
local function measure_font(font_const, max_w, test_string)
    local test_text = test_string or "X"
    local text_w, text_h = lcd.sizeText(test_text, font_const)

    -- If width constraint provided, return -1 if text is too wide
    if max_w and text_w > max_w then
        return -1
    end

    return text_h
end

--- Pick the largest font that fits the available space and optional width sample.
local function select_font(available_h, available_w, test_string, font_limit)
    local start_index = 1
    if type(font_limit) == "string" and font_limit ~= "" then
        for i = 1, #FONT_ORDER do
            if FONT_ORDER[i] == font_limit then
                start_index = i
                break
            end
        end
    end

    local font_tolerance = 2 -- Allow up to 2 pixels of overshoot
    local max_h = available_h + font_tolerance

    for i = start_index, #FONT_ORDER do
        local font_name = FONT_ORDER[i]
        local font_const = FONT_CONSTANTS[font_name]
        if font_const then
            local font_h = measure_font(font_const, available_w, test_string)
            if font_h > 0 and font_h <= max_h then
                return font_const
            end
        end
    end

    local fallback = FONT_ORDER[#FONT_ORDER]
    return FONT_CONSTANTS[fallback] or FONT_CONSTANTS.STDSIZE
end

--- Return the smallest font from a list of candidate font constants.
local function pick_smallest_font(...)
    local selected_font = nil
    for i = 1, select("#", ...) do
        local font_const = select(i, ...)
        if font_const and (not selected_font or measure_font(font_const) < measure_font(selected_font)) then selected_font =
            font_const end
    end
    return selected_font or STDSIZE
end

--- Choose one shared info-card font that fits all compared value columns.
local function get_shared_info_font(info_card_h, first_w, second_w, third_w)
    return pick_smallest_font(
        select_font(info_card_h - header_h, first_w - 2 * card_padding, "-00:00"),
        select_font(info_card_h - header_h, second_w - 2 * card_padding, "9999 (100%)"),
        select_font(info_card_h - header_h, third_w - 2 * card_padding, "9999 (9)")
    )
end

--- Build a reusable card rectangle and its child LVGL elements.
local function build_card_element(container, x, y, c_w, c_h, children)
    container:build({
        {
            type = "rectangle",
            x = x,
            y = y,
            w = c_w,
            h = c_h,
            thickness = show_debug_border,
            color = COLOR_THEME_SECONDARY2,
            filled = false,
            children = children
        }
    })
end

--- Add a centered stacked field with a label above its value.
local function add_stacked_field(children, x, y, c_w, row_padding, label_text, value_text, value_font, value_h)
    local label_y = y + row_padding
    children[#children + 1] = {
        type = "label",
        x = x,
        y = label_y,
        w = c_w,
        h = header_h,
        text = label_text,
        font = header_font,
        color = COLOR_THEME_SECONDARY1,
        align = CENTER
    }
    children[#children + 1] = {
        type = "label",
        x = x,
        y = label_y + header_h,
        w = c_w,
        h = value_h,
        text = value_text,
        font = value_font,
        color = COLOR_THEME_PRIMARY1,
        align = CENTER
    }
end

-- ── Configurable telemetry value slots ───────────────────────────────────────
-- The right-hand value panel (5 slots) and the "Telemetry" detail page (8 slots)
-- show sensors the user picks in Settings ▸ Values. A selection is stored as the
-- EdgeTX sensor NAME (a string in the cfg file) so the chosen sensor stays
-- identified even offline / before EdgeTX has (re)discovered it. Three sentinels are
-- not real sensors: SENSOR_OFF (empty slot), VOLT_AUTO (the smart cell/battery
-- voltage with warn colour — the dashboard's original slot-1 behaviour) and
-- ESCL_AUTO (the computed ESC utilization %, see update_esc_load_warning).
local SENSOR_OFF = "~off"
local VOLT_AUTO  = "~volt"
local ESCL_AUTO  = "~escl"
-- Dropdown DISPLAY state only (never stored): marks "this slot holds a raw sensor
-- picked via the native raw field". Keeps the curated dropdown short — raw names
-- don't get folded into it; the dropdown just shows this one "‹ Raw ›" entry and
-- the raw field shows which source it is.
local RAW_SENTINEL = "~raw"

-- Friendly label + default decimals for known Rotorflight / ELRS sensor names
-- (EdgeTX only stores the terse 4-char name). Unknown sensors fall back to their
-- raw name and the precision reported live by model.getSensor.
local SENSOR_INFO = {
    Vbat     = { lbl = "Battery",      dec = 2, unit = "V" },
    Vcel     = { lbl = "Cell",         dec = 2, unit = "V" },
    ["Cel#"] = { lbl = "Cells",        dec = 0, unit = "" },
    Cels     = { lbl = "Cell V",       dec = 2, unit = "V" },
    Curr     = { lbl = "Current",      dec = 1, unit = "A" },
    Capa     = { lbl = "Energy Used",  dec = 0, unit = "mAh" },
    ["Bat%"] = { lbl = "Fuel",         dec = 0, unit = "%" },
    Vbec     = { lbl = "BEC Voltage",  dec = 2, unit = "V" },
    Cbec     = { lbl = "BEC Current",  dec = 1, unit = "A" },
    Vbus     = { lbl = "Bus Voltage",  dec = 2, unit = "V" },
    Cbus     = { lbl = "Bus Current",  dec = 1, unit = "A" },
    Vmcu     = { lbl = "MCU Voltage",  dec = 2, unit = "V" },
    Cmcu     = { lbl = "MCU Current",  dec = 1, unit = "A" },
    Tesc     = { lbl = "ESC Temp",     dec = 0, unit = "°C" },
    Tbec     = { lbl = "BEC Temp",     dec = 0, unit = "°C" },
    Tmcu     = { lbl = "MCU Temp",     dec = 0, unit = "°C" },
    Tair     = { lbl = "Air Temp",     dec = 0, unit = "°C" },
    Tmtr     = { lbl = "Motor Temp",   dec = 0, unit = "°C" },
    Tbat     = { lbl = "Batt Temp",    dec = 0, unit = "°C" },
    Hspd     = { lbl = "Headspeed",    dec = 0, unit = "rpm" },
    Tspd     = { lbl = "Tailspeed",    dec = 0, unit = "rpm" },
    Thr      = { lbl = "Throttle",     dec = 0, unit = "%" },
    EscV     = { lbl = "ESC Voltage",  dec = 2, unit = "V" },
    EscI     = { lbl = "ESC Current",  dec = 1, unit = "A" },
    EscT     = { lbl = "ESC Temp",     dec = 0, unit = "°C" },
    RQly     = { lbl = "Link Qual",    dec = 0, unit = "%" },
    TQly     = { lbl = "Uplink Qual",  dec = 0, unit = "%" },
    RSNR     = { lbl = "SNR",          dec = 0, unit = "dB" },
    TPWR     = { lbl = "TX Power",     dec = 0, unit = "mW" },
    -- virtual (computed) sensors also resolve label/decimals/unit through this table
    ["~escl"] = { lbl = "ESC Load",    dec = 0, unit = "%" },
}

-- precision learned live from model.getSensor (used only for unknown sensors)
local sensor_prec_cache = {}

-- Sensors the dashboard already computes into wgt.values.* (with latching /
-- plausibility filtering AND simulator demo data). Prefer those fields over a raw
-- getSourceValue read: correct on hardware and populated in the simulator, where
-- getSourceValue has no real sensors. Other sensors fall back to the 5 Hz cache.
local SENSOR_VALUE_FIELD = {
    Vbat = "vbat", Vcel = "vcel", ["Cel#"] = "cel_count",
    Curr = "curr", Capa = "capa", ["Bat%"] = "capa_percent",
    Tesc = "esc_temp", Vbec = "vbec", Hspd = "headspeed",
    ["~escl"] = "esc_load_pct",   -- virtual: computed by update_esc_load_warning
}

-- keys of all configurable value slots (5 panel + 8 detail)
local PANEL_SLOT_KEYS  = { "PanelV1", "PanelV2", "PanelV3", "PanelV4", "PanelV5" }
local DETAIL_SLOT_KEYS = { "DetV1", "DetV2", "DetV3", "DetV4", "DetV5", "DetV6",
                          "DetV7", "DetV8", "DetV9", "DetV10", "DetV11", "DetV12" }

local function is_off_sensor(name)
    return name == nil or name == SENSOR_OFF or name == ""
end

-- a "raw" pick = a sensor name UltiDash doesn't curate (not Off / the two virtual
-- entries / a known SENSOR_INFO name). These are chosen via the native raw field and
-- shown in the curated dropdown only as the single ‹ Raw › state.
local function is_raw_sensor(name)
    return not is_off_sensor(name) and name ~= VOLT_AUTO and name ~= ESCL_AUTO
        and name ~= RAW_SENTINEL and SENSOR_INFO[name] == nil
end

local function sensor_dec(name)
    local info = SENSOR_INFO[name]
    if info then return info.dec end
    local p = sensor_prec_cache[name]
    if type(p) == "number" then return p end
    return 1
end

-- short label for the panel / detail cell (no parenthetical raw name)
local function sensor_short_label(name)
    if is_off_sensor(name) then return "" end
    if name == VOLT_AUTO then return "Voltage" end
    local info = SENSOR_INFO[name]
    if info then return info.lbl end
    return name
end

-- unit suffix for the value (telemetry detail page). Known sensors carry it in
-- SENSOR_INFO; VOLT_AUTO is the smart voltage → "V"; unknowns have no unit string
-- (EdgeTX only exposes a numeric unit id, too version-fragile to map reliably).
local function sensor_unit(name)
    if name == VOLT_AUTO then return "V" end
    local info = SENSOR_INFO[name]
    return (info and info.unit) or ""
end

-- label shown in the settings dropdown (friendly). Curated names get their nice
-- label; the ‹ Raw › entry is the display state for a raw pick (chosen in the raw
-- field, not here).
local function sensor_pick_label(name)
    if is_off_sensor(name) then return "— Off —" end
    if name == VOLT_AUTO then return "Voltage (auto)" end
    if name == ESCL_AUTO then return "ESC Load (calc)" end
    if name == RAW_SENTINEL then return "‹ Raw sensor ›" end
    local info = SENSOR_INFO[name]
    if info then return info.lbl .. " (" .. name .. ")" end
    return name
end

-- Build the CURATED pick list for the settings dropdown: Off + smart-voltage +
-- ESC load + only the model's sensors that UltiDash KNOWS (SENSOR_INFO — with
-- friendly labels), so the list stays short. Everything else is picked via the
-- native raw source field instead; a currently chosen raw name is still added
-- (labelled "Raw: …") so the dropdown can DISPLAY it and a stored selection
-- stays selectable offline. Codes are the NAME strings stored in the cfg.
local function build_sensor_list(wgt)
    local labels = { sensor_pick_label(SENSOR_OFF), sensor_pick_label(VOLT_AUTO), sensor_pick_label(ESCL_AUTO) }
    local codes  = { SENSOR_OFF, VOLT_AUTO, ESCL_AUTO }
    local seen   = { [SENSOR_OFF] = true, [VOLT_AUTO] = true, [ESCL_AUTO] = true }
    local function add(name)
        if name == nil or name == "" or seen[name] then return end
        seen[name] = true
        labels[#labels + 1] = sensor_pick_label(name)
        codes[#codes + 1]   = name
    end
    if model ~= nil and type(model.getSensor) == "function" then
        for i = 0, 59 do
            local ok, s = pcall(model.getSensor, i)
            if ok and type(s) == "table" and type(s.name) == "string" and s.name ~= "" then
                if type(s.prec) == "number" then sensor_prec_cache[s.name] = s.prec end
                if SENSOR_INFO[s.name] then add(s.name) end   -- curated: known only
            end
        end
    end
    -- keep a currently-chosen KNOWN sensor selectable even offline (before
    -- model.getSensor has (re)discovered it). Raw picks are NOT added — they show
    -- via the ‹ Raw › entry, so the curated list stays short.
    local src = wgt.settings_working or wgt.options or {}
    local function add_known(name) if name and SENSOR_INFO[name] then add(name) end end
    for i = 1, #PANEL_SLOT_KEYS  do add_known(src[PANEL_SLOT_KEYS[i]])  end
    for i = 1, #DETAIL_SLOT_KEYS do add_known(src[DETAIL_SLOT_KEYS[i]]) end
    -- trailing display state for a raw pick (selecting it is inert — pick the raw
    -- sensor in the raw field beside the dropdown)
    labels[#labels + 1] = sensor_pick_label(RAW_SENTINEL)
    codes[#codes + 1]   = RAW_SENTINEL
    return labels, codes
end

-- Cheap reactive text getter for a configured sensor slot: reads the 5 Hz cache,
-- never does a sensor name-lookup itself (see update_user_sensors).
local function sensor_value_text(wgt, name)
    local fmt = "%." .. sensor_dec(name) .. "f"
    local field = SENSOR_VALUE_FIELD[name]
    -- memo via closure upvalues: this reactive text runs every render frame but the
    -- value only changes on the 5 Hz pass, so re-run string.format (allocate) only on
    -- change. Each panel gets its own closure -> its own private cache, no shared table.
    local last_v, last_s, primed = nil, "-", false
    return function()
        local v
        if field then v = wgt.values[field] end
        if v == nil then
            local cache = wgt.values.user_sensors
            v = cache and cache[name]
        end
        if primed and v == last_v then return last_s end
        last_v = v
        last_s = (v == nil) and "-" or string.format(fmt, v)
        primed = true
        return last_s
    end
end

-- Like sensor_value_text but ALWAYS the RAW sensor reading (user_sensors_raw, filled
-- while the telemetry detail page is open). The detail page shows raw data so the value
-- matches its raw "min .. max" chip — no latching / plausibility filtering / mapping.
local function sensor_value_text_raw(wgt, name)
    local fmt = "%." .. sensor_dec(name) .. "f"
    local last_v, last_s, primed = nil, "-", false
    return function()
        local cache = wgt.values.user_sensors_raw
        local v = cache and cache[name]
        if primed and v == last_v then return last_s end
        last_v = v
        last_s = (v == nil) and "-" or string.format(fmt, v)
        primed = true
        return last_s
    end
end

-- Reactive low/high text for a sensor slot: EdgeTX keeps a per-sensor session
-- min/max, addressable by appending "-" / "+" to the name (e.g. Tesc-, Tesc+) — we
-- cache both at 5 Hz (update_user_sensors) and format them as "min .. max" here.
-- VOLT_AUTO is synthetic (smart cell/battery voltage) → reuse its own min/max getters.
local function sensor_minmax_text(wgt, name)
    if name == VOLT_AUTO then
        local lo = wgt.values.display_voltage_min_formatted
        local hi = wgt.values.display_voltage_max_formatted
        return function() return (lo and lo() or "-") .. " .. " .. (hi and hi() or "-") end
    end
    if name == ESCL_AUTO then
        -- computed value, no EdgeTX session min/max: the chip shows the session limit
        return function()
            local lim = wgt.values.esc_load_limit
            return lim and ("limit " .. lim .. " A") or "not set"
        end
    end
    local fmt = "%." .. sensor_dec(name) .. "f"
    return function()
        local mn = wgt.values.user_sensors_min
        local mx = wgt.values.user_sensors_max
        local lo = mn and mn[name]
        local hi = mx and mx[name]
        return (lo and string.format(fmt, lo) or "-") .. " .. " .. (hi and string.format(fmt, hi) or "-")
    end
end

-- a wide sample string for font sizing, by decimals
local function sensor_test_text(name)
    local d = sensor_dec(name)
    if d <= 0 then return "9999" end
    if d == 1 then return "999.9" end
    return "99.99"
end

-- Reactive color for the virtual ESC-load value: neutral below warn, then the same
-- warn/crit palette as the panel's utilization bar (theme-aware via dark_scheme).
local function esc_load_color(wgt)
    return function()
        local p = wgt.values.esc_load_pct
        if p == nil then return COLOR_THEME_PRIMARY1 end
        local o = wgt.options
        if p >= ((o and o.EscCrit) or 100) then
            return dark_scheme and lcd.RGB(0xFF, 0x1A, 0x40) or lcd.RGB(0xE0, 0x30, 0x30)
        end
        if p >= ((o and o.EscWarn) or 80) then
            return dark_scheme and lcd.RGB(0xFF, 0xE0, 0x00) or lcd.RGB(0xF0, 0xC0, 0x00)
        end
        return COLOR_THEME_PRIMARY1
    end
end

-- 5 Hz pass: refresh the cache of user-selected sensor values. A nil reading (no
-- telemetry) KEEPS the last value, so the panel/detail stay populated while
-- configuring with no craft connected.
--
-- COST DISCIPLINE: every getSourceValue is a sensor-name lookup, and piling them on
-- the 5 Hz pass starves the Lua scheduler enough to make fullscreen taps laggy (same
-- lesson as the 5 Hz throttle itself). So the EdgeTX session min/max ("-"/"+" reads)
-- are fetched ONLY while the telemetry detail page is actually open — on the
-- dashboard this stays as cheap as before (just the non-mapped panel/detail values).
local function update_user_sensors(wgt)
    local o = wgt.options
    if o == nil then return end
    local v = wgt.values
    local cache = v.user_sensors; if cache == nil then cache = {}; v.user_sensors = cache end

    -- RAW picks: the stored name is getSourceName's DISPLAY string, but
    -- getSourceValue's STRING lookup (luaFindFieldByName, 2.12 api_general.cpp)
    -- matches the sensor LABEL — the two don't reliably round-trip, so raw slots
    -- read "-". Fix: getSourceValue also accepts the numeric MIXSRC index (same
    -- space as getSourceName / the lvgl.source picker), and the picker's index is
    -- persisted as the <slot>Raw shadow key. Verify index -> name still matches
    -- (getSourceName), then read BY INDEX. Telemetry sources come as value/min/max
    -- index triples (idx / idx+1 "-" / idx+2 "+"), each verified by name before
    -- use. Verification is cached per name (re-checked only when the persisted
    -- index changes) so the 5 Hz pass stays cheap — index reads are cheaper than
    -- the failing name lookups were.
    local raw_src = wgt.raw_src; if raw_src == nil then raw_src = {}; wgt.raw_src = raw_src end
    local function raw_sources(name, key)
        if not is_raw_sensor(name) then return nil end
        local idx = o[key .. "Raw"]
        if type(idx) ~= "number" or idx == 0 then return nil end
        local rs = raw_src[name]
        if rs and rs.probe == idx then return rs.ok and rs or nil end
        rs = { probe = idx, ok = false }
        local okn, n = pcall(getSourceName, idx)
        if okn and n == name then
            rs.ok = true
            rs.v = idx
            local okm, m = pcall(getSourceName, idx + 1)
            if okm and m == name .. "-" then rs.mn = idx + 1 end
            local okx, x = pcall(getSourceName, idx + 2)
            if okx and x == name .. "+" then rs.mx = idx + 2 end
        end
        raw_src[name] = rs
        return rs.ok and rs or nil
    end

    -- main values: mapped sensors already live in wgt.values.* (latched /
    -- plausibility-filtered / simulator demo); others read the raw EdgeTX source —
    -- raw picks by verified index, everything else (and as fallback) by name
    local function pull_val(key)
        local name = o[key]
        if is_off_sensor(name) or name == VOLT_AUTO or SENSOR_VALUE_FIELD[name] then return end
        local rs = raw_sources(name, key)
        local ok, val
        if rs then ok, val = pcall(getSourceValue, rs.v) end
        if not (ok and val ~= nil) then ok, val = pcall(getSourceValue, name) end
        if ok and val ~= nil then cache[name] = val end
    end
    for i = 1, #PANEL_SLOT_KEYS  do pull_val(PANEL_SLOT_KEYS[i])  end
    for i = 1, #DETAIL_SLOT_KEYS do pull_val(DETAIL_SLOT_KEYS[i]) end

    -- value + low/high: only needed by the open telemetry detail page, and only for its
    -- slots. The detail page shows RAW data, so pull the raw value here too (even for the
    -- "mapped" sensors that the dashboard shows latched) into a dedicated raw cache.
    if wgt.detail_view == "telem" then
        local craw = v.user_sensors_raw; if craw == nil then craw = {}; v.user_sensors_raw = craw end
        local cmin = v.user_sensors_min; if cmin == nil then cmin = {}; v.user_sensors_min = cmin end
        local cmax = v.user_sensors_max; if cmax == nil then cmax = {}; v.user_sensors_max = cmax end
        for i = 1, #DETAIL_SLOT_KEYS do
            local key = DETAIL_SLOT_KEYS[i]
            local name = o[key]
            if not is_off_sensor(name) and name ~= VOLT_AUTO and name ~= ESCL_AUTO then
                local rs = raw_sources(name, key)
                local okv, val
                if rs then okv, val = pcall(getSourceValue, rs.v) end
                if not (okv and val ~= nil) then okv, val = pcall(getSourceValue, name) end
                if okv and val ~= nil then craw[name] = val end
                local okn, vmin
                if rs and rs.mn then okn, vmin = pcall(getSourceValue, rs.mn) end
                if not (okn and vmin ~= nil) then okn, vmin = pcall(getSourceValue, name .. "-") end
                if okn and vmin ~= nil then cmin[name] = vmin end
                local okx, vmax
                if rs and rs.mx then okx, vmax = pcall(getSourceValue, rs.mx) end
                if not (okx and vmax ~= nil) then okx, vmax = pcall(getSourceValue, name .. "+") end
                if okx and vmax ~= nil then cmax[name] = vmax end
            end
        end
    end
end

--- Build the left flight panel with live telemetry values.
local function build_flight_values_panel(container, wgt, x, y, c_w, c_h)
    local padding = compact_card_padding
    local row_gap = 1
    local row_h = math.floor((c_h - 2 * padding - 4 * row_gap) / 5)
    local used_h = row_h * 5 + 4 * row_gap
    local start_y = padding + math.floor((c_h - used_h) / 2)
    local label_w = math.floor(c_w * 0.55)
    local value_x = padding + label_w
    local value_w = c_w - value_x - padding
    -- ESC continuous-current load bar (shown on the Curr row when monitoring is on)
    local esc_on = (wgt.options.EscMon == 1)
    local ESC_GREEN = dark_scheme and lcd.RGB(0x39, 0xFF, 0x14) or lcd.RGB(0x20, 0xB0, 0x20)
    local ESC_YELL  = dark_scheme and lcd.RGB(0xFF, 0xE0, 0x00) or lcd.RGB(0xF0, 0xC0, 0x00)
    local ESC_RED   = dark_scheme and lcd.RGB(0xFF, 0x1A, 0x40) or lcd.RGB(0xE0, 0x30, 0x30)
    -- 5 configurable slots (Settings ▸ Values). Defaults reproduce the original
    -- panel: smart voltage, headspeed, current, ESC temp, BEC. VOLT_AUTO keeps the
    -- cell/battery toggle + warn colour; a plain sensor uses the cheap cache getter;
    -- an Off slot renders blank.
    local rows = {}
    for i = 1, 5 do
        local name = wgt.options[PANEL_SLOT_KEYS[i]] or SENSOR_OFF
        if name == VOLT_AUTO then
            rows[i] = {
                title = wgt.values.display_voltage_label_short,
                value = wgt.values.display_voltage_formatted,
                test  = wgt.values.display_voltage_test(),
                color = wgt.values.display_voltage_color
            }
        elseif is_off_sensor(name) then
            rows[i] = { title = "", value = "", test = "9999", color = COLOR_THEME_PRIMARY1 }
        else
            rows[i] = {
                title = sensor_short_label(name),
                value = sensor_value_text(wgt, name),
                test  = sensor_test_text(name),
                color = (name == ESCL_AUTO) and esc_load_color(wgt) or COLOR_THEME_PRIMARY1,
                esc_bar = esc_on and (name == "Curr")
            }
        end
    end
    local value_font = pick_smallest_font(
        select_font(row_h - 2, value_w, rows[1].test),
        select_font(row_h - 2, value_w, rows[2].test),
        select_font(row_h - 2, value_w, rows[3].test),
        select_font(row_h - 2, value_w, rows[4].test),
        select_font(row_h - 2, value_w, rows[5].test)
    )
    local value_font_h = measure_font(value_font)

    for i = 1, 5 do
        local current_row_h = row_h
        local row_y = start_y + (i - 1) * (row_h + row_gap)
        local value_y = row_y + math.floor((current_row_h - value_font_h) / 2)
        local label_y = row_y + math.floor((current_row_h - header_h) / 2)

        build_card_element(container, x, y + row_y, c_w, current_row_h, {
            {
                type = "label",
                x = padding,
                y = label_y - row_y,
                w = label_w - padding,
                h = header_h,
                text = rows[i].title,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = LEFT
            }, {
            type = "label",
            x = value_x,
            y = value_y - row_y,
            w = value_w,
            h = value_font_h,
            text = rows[i].value,
            font = value_font,
            color = rows[i].color,
            align = RIGHT
        }
        })

        -- ESC-load utilization bar along the bottom of the Current row, FULL row width
        -- (track + reactive fill), same span as the row divider. Hidden entirely while
        -- no session limit is latched (GVAR still 0 -> not set up on THIS model).
        if rows[i].esc_bar then
            local bx  = x + padding
            local bw  = c_w - 2 * padding
            local byy = y + row_y + current_row_h - 6
            local esc_vis = function() return wgt.values.esc_load_limit ~= nil end
            container:build({
                { type = "rectangle", x = bx, y = byy, w = bw, h = 5, filled = true, rounded = 2, color = COLOR_TRACK, visible = esc_vis },
                { type = "rectangle", x = bx, y = byy, w = 1, h = 5, filled = true, rounded = 2, visible = esc_vis,
                    size = function()
                        local p = wgt.values.esc_load_pct
                        if p == nil then return 1, 5 end
                        if p < 0 then p = 0 elseif p > 100 then p = 100 end
                        return math.max(1, math.floor(bw * p / 100)), 5
                    end,
                    color = function()
                        local p = wgt.values.esc_load_pct
                        if p == nil then return COLOR_TRACK end
                        local warn = wgt.options.EscWarn or 80
                        local crit = wgt.options.EscCrit or 100
                        if p >= crit then return ESC_RED elseif p >= warn then return ESC_YELL else return ESC_GREEN end
                    end },
            })
        end

        if i < 5 then
            container:hline({ x = x + padding, y = y + row_y + current_row_h, w = c_w - 2 * padding, h = 1, color =
            COLOR_THEME_SECONDARY1 })
        end
    end
end

--- Build the center vertical battery gauge used on the flight view.
local function build_vertical_fuel_gauge_element(container, wgt, x, y, c_w, c_h)
    local side_inset = math.max(1, math.floor(c_w * 0.04))
    local cap_h = math.max(5, math.floor(c_h * 0.06))
    local cap_w = math.max(10, math.floor((c_w - 2 * side_inset) * 0.36))
    local cap_x = x + math.floor((c_w - cap_w) / 2)
    local body_x = x + card_padding + side_inset
    local body_y = y + card_padding + cap_h
    local body_w = c_w - 2 * (card_padding + side_inset)
    local body_h = c_h - 2 * card_padding - cap_h
    local body_rounding = math.max(3, math.floor(body_w * 0.10))
    local cap_rounding = math.max(2, math.floor(cap_h * 0.45))
    local cap_base_h = math.max(1, math.floor(cap_h * 0.35))
    local inner_padding = math.max(3, math.floor(body_w * 0.10))
    local segment_gap = math.max(1, math.floor(body_h * 0.01))
    local inner_x = body_x + inner_padding
    local inner_y = body_y + inner_padding
    local inner_w = body_w - 2 * inner_padding
    local inner_h = body_h - 2 * inner_padding
    local segment_rounding = math.max(1, math.floor(inner_w * 0.10))
    -- fewer, chunkier segments (was 8..12) for a bolder look
    local segment_count = math.max(6, math.min(9, math.floor(inner_h / 16)))
    local segment_h = math.floor((inner_h - (segment_count - 1) * segment_gap) / segment_count)
    local segment_last_h = inner_h - segment_h * (segment_count - 1) - segment_gap * (segment_count - 1)
    -- percent (center) and mAh (bottom) enlarged now that cell voltage was removed
    local value_font = select_font(math.floor(body_h * 0.22), body_w - 2 * inner_padding, "100%")
    local value_font_h = measure_font(value_font)
    local overlay_font = select_font(math.max(6, math.floor(body_h * 0.11)), body_w - 2 * inner_padding, "mAh")
    local overlay_font_h = measure_font(overlay_font)
    local overlay_pad = math.max(1, math.floor(body_h * 0.02))
    local mah_num_font = select_font(math.floor(body_h * 0.17), body_w - 2 * inner_padding, "8888")
    local mah_num_font_h = measure_font(mah_num_font)

    -- empty segments use a light grey (like ePowerbar's bar background) instead of a
    -- deep theme black, so overlay text stays readable over the unfilled area
    local EMPTY_SEGMENT_COLOR = lcd.RGB(0xc8, 0xc8, 0xc8)

    local function get_segment_color(segment_threshold)
        local current_percent = wgt.values.gauge_fill_percent()
        if current_percent >= segment_threshold then
            return wgt.values.capa_bar_color
        end
        return EMPTY_SEGMENT_COLOR
    end

    -- With the light-grey empty area and the green/yellow fills, plain black text
    -- reads cleanly across the whole bar; no outline/halo needed (it only blurred
    -- the text on grey/yellow). Critical (red) fill only appears near-empty, so the
    -- overlays then sit mostly over the grey area anyway.
    local function add_overlay_label(children, lx, ly, lw, lh, ltext, lfont)
        children[#children + 1] = {
            type = "label", x = lx, y = ly, w = lw, h = lh,
            text = ltext, font = lfont, color = BLACK, align = CENTER
        }
    end

    container:build({
        {
            type = "rectangle",
            x = cap_x,
            y = y + card_padding,
            w = cap_w,
            h = cap_h,
            thickness = 1,
            rounded = cap_rounding,
            color = COLOR_THEME_SECONDARY1,
            filled = true
        }, {
        type = "rectangle",
        x = cap_x,
        y = y + card_padding + cap_h - cap_base_h,
        w = cap_w,
        h = cap_base_h,
        thickness = 0,
        color = COLOR_THEME_SECONDARY1,
        filled = true
        }, {
        -- body outline only (filled=false) — the interior between the bars and the
        -- outline stays transparent so it follows the background (theme/BGFilled/wallpaper)
        type = "rectangle",
        x = body_x,
        y = body_y,
        w = body_w,
        h = body_h,
        thickness = 1,
        rounded = body_rounding,
        color = COLOR_THEME_SECONDARY1,
        filled = false
    }
    })

    for segmentIndex = 1, segment_count do
        local top_index = segmentIndex - 1
        local segment_item_h = segmentIndex == segment_count and segment_last_h or segment_h
        local segment_threshold = ((segment_count - top_index) / segment_count) * 100
        local segment_y = inner_y + top_index * (segment_h + segment_gap)
        local segment_color = function() return get_segment_color(segment_threshold) end
        local segment_flat_h = math.max(1, math.min(segment_rounding, segment_item_h))

        container:build({
            {
                type = "rectangle",
                x = inner_x,
                y = segment_y,
                w = inner_w,
                h = segment_item_h,
                thickness = 1,
                rounded = (segmentIndex == 1 or segmentIndex == segment_count) and segment_rounding or 0,
                color = segment_color,
                filled = true
            }, {
                type = "rectangle",
                x = inner_x,
                y = segmentIndex == 1 and (segment_y + segment_item_h - segment_flat_h) or segment_y,
                w = inner_w,
                h = segment_flat_h,
                thickness = 0,
                color = segment_color,
                filled = (segmentIndex == 1 or segmentIndex == segment_count)
            }
        })
    end

    -- overlays: cell count (top) + big percent (center) + mAh number/unit (bottom).
    -- cell voltage is intentionally NOT shown here (it's in the right values panel).
    local cells_y = body_y + inner_padding + overlay_pad
    local percent_y = body_y + math.floor((body_h - value_font_h) / 2)
    local mah_block_h = mah_num_font_h + overlay_font_h
    local mah_num_y = body_y + body_h - inner_padding - overlay_pad - mah_block_h
    local mah_unit_y = mah_num_y + mah_num_font_h

    local overlay_labels = {}
    add_overlay_label(overlay_labels, body_x, cells_y, body_w, overlay_font_h,
        wgt.values.gauge_cells_formatted, overlay_font)
    add_overlay_label(overlay_labels, body_x, percent_y, body_w, value_font_h,
        wgt.values.gauge_percent_formatted, value_font)
    add_overlay_label(overlay_labels, body_x, mah_num_y, body_w, mah_num_font_h,
        wgt.values.gauge_mah_value_formatted, mah_num_font)
    add_overlay_label(overlay_labels, body_x, mah_unit_y, body_w, overlay_font_h,
        "mAh", overlay_font)
    container:build(overlay_labels)
end

--- Build the flight status panel: model image on top, flight totals directly
--- beneath it, the eStatus ESC/throttle line, the governor state, and a single
--- Profile / Rate / Batt-Profile row.
local function build_flight_status_panel(container, wgt, x, y, c_w, c_h)
    local pad = card_padding
    local inner_w = c_w - 2 * pad

    -- model image: FIXED reserved slot at the top so the sections below never shift
    -- when images have different aspect ratios. The image is top-anchored inside the
    -- slot (frame height = its own scaled height, so it hugs the top, no float), but
    -- the layout below always starts at the fixed slot bottom.
    local image_slot_h = math.max(1, math.floor(c_h * 0.32))
    local image_h = image_slot_h
    local img_bw = wgt.values.model_image_w
    local img_bh = wgt.values.model_image_h
    if img_bw and img_bh and img_bw > 0 and img_bh > 0 then
        local scale = math.min(inner_w / img_bw, image_slot_h / img_bh)
        image_h = math.max(1, math.floor(img_bh * scale))
    end

    -- everything below starts at the fixed slot bottom, regardless of image height
    local y_meta = pad + image_slot_h
    local rest = math.max(1, c_h - y_meta - pad)
    local h_meta = math.max(header_h + 4, math.floor(rest * 0.28))
    local h_gt   = math.max(header_h + 2, math.floor(rest * 0.30)) -- governor + throttle headline
    local h_esc  = math.max(header_h + 2, math.floor(rest * 0.16)) -- ESC / arming status line
    local h_grid = math.max(header_h + 2, rest - h_meta - h_gt - h_esc)

    local y_gt = y_meta + h_meta
    local y_esc = y_gt + h_gt
    local y_grid = y_esc + h_esc

    local half_w = math.floor(inner_w / 2)
    local gov_w = math.floor(inner_w * 0.62)
    local thr_w = inner_w - gov_w

    -- fonts: flight totals
    local flights_font = select_font(h_meta - header_h, half_w, "9999")
    local flights_font_h = measure_font(flights_font)
    local time_font = select_font(h_meta - header_h, inner_w - half_w, "999:59:59")
    local time_font_h = measure_font(time_font)
    local meta_value_h = math.max(flights_font_h, time_font_h)
    local meta_pad = math.max(0, math.floor((h_meta - header_h - meta_value_h) / 2))

    -- fonts: governor + throttle headline row
    local gov_font = select_font(h_gt - header_h, gov_w, "Gov. Disabled", "MIDSIZE")
    local gov_font_h = measure_font(gov_font)
    local thr_font = select_font(h_gt - header_h, thr_w, "100%")
    local thr_font_h = measure_font(thr_font)
    local gt_value_h = math.max(gov_font_h, thr_font_h)
    local gt_pad = math.max(0, math.floor((h_gt - header_h - gt_value_h) / 2))

    -- font: ESC / arming status line (full width, single colored line)
    local stat_font = select_font(h_esc - 2, inner_w, "ESC Motor Connection")
    local stat_font_h = measure_font(stat_font)

    local third_w = math.floor(inner_w / 3)
    local third_last_w = inner_w - 2 * third_w
    local profile_font = select_font(h_grid - header_h, third_w, "9")
    local profile_font_h = measure_font(profile_font)
    local rate_font = select_font(h_grid - header_h, third_w, "9")
    local rate_font_h = measure_font(rate_font)
    local battp_font = select_font(h_grid - header_h, third_last_w, "9999")
    local battp_font_h = measure_font(battp_font)
    -- battery-profile column header: prefer "B-Profile"; on the narrow TX15 third
    -- column it would clip, so fall back to the shorter "B-Prof" when it doesn't fit
    local battp_label = wgt.values.label_battery_profile_short
    if lcd.sizeText(battp_label, header_font) > third_last_w then
        battp_label = wgt.values.label_battery_profile_shorter
    end
    local grid_value_h = math.max(profile_font_h, rate_font_h, battp_font_h)
    local grid_pad = math.max(0, math.floor((h_grid - header_h - grid_value_h) / 2))

    local status_children = {}

    -- top-left slot: model image (default) or the configured model timer (TopLeft option)
    if wgt.options.TopLeft == 2 then
        local timer_val_h = math.max(1, image_slot_h - header_h - 2)
        local timer_font = select_font(timer_val_h, inner_w, "-00:00")
        local timer_font_h = measure_font(timer_font)
        status_children[#status_children + 1] = {
            type = "label", x = pad, y = pad, w = inner_w, h = header_h,
            text = wgt.values.label_timer, font = header_font, color = COLOR_THEME_SECONDARY1, align = CENTER
        }
        status_children[#status_children + 1] = {
            type = "label",
            x = pad,
            y = pad + header_h + math.floor((image_slot_h - header_h - timer_font_h) / 2),
            w = inner_w, h = timer_font_h,
            text = wgt.values.timer_str_formatted,
            font = timer_font,
            color = function() return wgt.values.timer_color() end,
            align = CENTER
        }
    else
        status_children[#status_children + 1] = {
            type = "image",
            x = pad,
            y = pad,
            w = inner_w,
            h = image_h,
            file = function() return wgt.values.model_image_path end,
            fill = false
        }
    end

    -- flight totals directly under the image
    add_stacked_field(status_children, pad, y_meta, half_w, meta_pad,
        wgt.values.label_total_flights, wgt.values.rf_total_flights_display_formatted, flights_font, flights_font_h)
    add_stacked_field(status_children, pad + half_w, y_meta, inner_w - half_w, meta_pad,
        "Total Time", wgt.values.rf_total_flight_time_display_formatted, time_font, time_font_h)

    -- headline status row: Governor State (left) + Throttle (right)
    add_stacked_field(status_children, pad, y_gt, gov_w, gt_pad,
        "Governor", wgt.values.gov_state_formatted, gov_font, gov_font_h)
    add_stacked_field(status_children, pad + gov_w, y_gt, thr_w, gt_pad,
        wgt.values.label_throttle, function() return wgt.values.throttle_text end, thr_font, thr_font_h)

    -- ESC / arming status line (full width, colored; blank when all OK).
    -- Tapping it (fullscreen) opens the status detail page — remember its rect
    -- in widget coords for the hit-test in refresh().
    wgt.estatus_rect = { x = x + pad, y = y + y_esc, w = inner_w, h = h_esc }
    status_children[#status_children + 1] = {
        type = "label",
        x = pad,
        y = y_esc + math.floor((h_esc - stat_font_h) / 2),
        w = inner_w,
        h = stat_font_h,
        text = function() return wgt.values.status_line_text end,
        font = stat_font,
        color = function() return wgt.values.status_line_color end,
        align = CENTER
    }

    -- Profile / Rate / Batt-Profile in a single 3-column row
    add_stacked_field(status_children, pad, y_grid, third_w, grid_pad,
        wgt.values.label_profile, wgt.values.profile_id_formatted, profile_font, profile_font_h)
    add_stacked_field(status_children, pad + third_w, y_grid, third_w, grid_pad,
        wgt.values.label_rate, wgt.values.rate_id_formatted, rate_font, rate_font_h)
    add_stacked_field(status_children, pad + 2 * third_w, y_grid, third_last_w, grid_pad,
        battp_label, wgt.values.rf_battery_profile_compact_formatted, battp_font, battp_font_h)
    -- the battery-profile field is a tap target (DISARMED only): opens the profile
    -- picker, which switches the active profile via the RFTool MSP API
    wgt.battprofile_rect = { x = x + pad + 2 * third_w, y = y + y_grid, w = third_last_w, h = h_grid }

    build_card_element(container, x, y, c_w, c_h, status_children)

    container:hline({ x = x + pad, y = y + y_meta - 1, w = inner_w, h = 1, color = COLOR_THEME_SECONDARY1 })
    container:hline({ x = x + pad, y = y + y_gt - 1, w = inner_w, h = 1, color = COLOR_THEME_SECONDARY1 })
    container:hline({ x = x + pad, y = y + y_esc - 1, w = inner_w, h = 1, color = COLOR_THEME_SECONDARY1 })
    container:hline({ x = x + pad, y = y + y_grid - 1, w = inner_w, h = 1, color = COLOR_THEME_SECONDARY1 })
end

local function get_flight_statistics_rows(wgt)
    -- Headspeed min/max are tracked PER PID PROFILE (see update_headspeed). Three
    -- FIXED rows (P1-P3) keep every profile's pair visible after a disconnect —
    -- the PID# sensor freezes then, so a single switched row would be useless.
    -- "Latest" shows the live rpm only on the active profile's row.
    local function hs_actual(p)
        return function()
            local cur = wgt.values.profile_id
            if cur ~= nil and math.floor(cur) == p and wgt.values.headspeed ~= nil then
                return string.format("%d", math.floor(wgt.values.headspeed))
            end
            return "-"
        end
    end
    local function hs_get(p, key)
        return function()
            local s = wgt.hs_profile_stats and wgt.hs_profile_stats[p]
            local v = s and s[key]
            return v and string.format("%d", math.floor(v)) or "-"
        end
    end
    local function hs_row(p)
        return {
            label = "Headspeed P" .. p,
            actual = hs_actual(p),
            min = hs_get(p, "min"),
            max = hs_get(p, "max"),
            actualColor = COLOR_THEME_PRIMARY1,
            minColor = COLOR_THEME_PRIMARY1,
            maxColor = COLOR_THEME_PRIMARY1,
            test = "3200"
        }
    end
    return {
        {
            label = wgt.values.display_voltage_label,
            actual = wgt.values.display_voltage_formatted,
            min = wgt.values.display_voltage_min_formatted,
            max = wgt.values.display_voltage_max_formatted,
            actualColor = wgt.values.display_voltage_actual_color,
            minColor = wgt.values.display_voltage_min_color,
            maxColor = wgt.values.display_voltage_max_color,
            test = wgt.values.display_voltage_test()
        },
        hs_row(1),
        hs_row(2),
        hs_row(3),
        {
        label = wgt.values.label_current,
        actual = wgt.values.curr_formatted,
        min = wgt.values.curr_min_formatted,
        max = wgt.values.curr_max_formatted,
        actualColor = COLOR_THEME_PRIMARY1,
        minColor = COLOR_THEME_PRIMARY1,
        maxColor = COLOR_THEME_PRIMARY1,
        test = "999.9"
    }, {
        label = wgt.values.label_esc_temp,
        actual = wgt.values.esc_temp_formatted,
        min = wgt.values.esc_temp_min_formatted,
        max = wgt.values.esc_temp_max_formatted,
        actualColor = COLOR_THEME_PRIMARY1,
        minColor = COLOR_THEME_PRIMARY1,
        maxColor = COLOR_THEME_PRIMARY1,
        test = "120.0"
    }, {
        label = wgt.values.label_bec_voltage,
        actual = wgt.values.vbec_formatted,
        min = wgt.values.vbec_min_formatted,
        max = wgt.values.vbec_max_formatted,
        actualColor = COLOR_THEME_PRIMARY1,
        minColor = COLOR_THEME_PRIMARY1,
        maxColor = COLOR_THEME_PRIMARY1,
        test = "99.99"
    }
    }
end

--- Calculate the statistics header layout for model name and RF totals.
local function get_flight_statistics_top_layout(wgt, c_w, top_row_h, table_start_y)
    local time_value_sample = "999:59:59"
    local flights_value_sample = "9999"
    local top_meta_pair_gap = 8
    local top_meta_item_gap = 3
    local total_time_label = wgt.values.label_total_flight_time .. ":"
    local flights_label = wgt.values.label_total_flights .. ":"
    local total_time_label_w = lcd.sizeText(total_time_label, header_font)
    local flights_label_w = lcd.sizeText(flights_label, header_font)
    local available_meta_w = math.max(1, c_w - 2 * card_padding)
    local meta_fixed_w = total_time_label_w + flights_label_w + top_meta_pair_gap + top_meta_item_gap * 2
    local meta_value_w = math.max(1, math.floor((available_meta_w - meta_fixed_w) / 2))
    local top_meta_value_font = select_font(top_row_h - 2, meta_value_w, time_value_sample, "MIDSIZE")
    local top_meta_value_font_h = measure_font(top_meta_value_font)
    local total_time_value_w = lcd.sizeText(time_value_sample, top_meta_value_font)
    local flights_value_w = lcd.sizeText(flights_value_sample, top_meta_value_font)
    local total_time_block_w = total_time_label_w + top_meta_item_gap + total_time_value_w
    local top_meta_cluster_w = total_time_block_w + top_meta_pair_gap + flights_label_w + top_meta_item_gap +
    flights_value_w
    local top_meta_x = math.max(card_padding, c_w - card_padding - top_meta_cluster_w)
    local top_model_actual_w = math.max(1, top_meta_x - card_padding - 8)
    local top_model_font = select_font(top_row_h - 2, top_model_actual_w, wgt.values.craft_name_formatted(), "DBLSIZE")
    local top_model_font_h = measure_font(top_model_font)
    local top_row_center_y = table_start_y + math.floor(top_row_h / 2)

    return {
        model_w = top_model_actual_w,
        model_font = top_model_font,
        model_font_h = top_model_font_h,
        meta_value_font = top_meta_value_font,
        meta_value_font_h = top_meta_value_font_h,
        meta_label_y = top_row_center_y - math.floor(header_h / 2),
        meta_value_y = top_row_center_y - math.floor(top_meta_value_font_h / 2),
        total_time_label = total_time_label,
        total_time_label_w = total_time_label_w,
        total_time_value_w = total_time_value_w,
        flights_label = flights_label,
        flights_label_w = flights_label_w,
        flights_value_w = flights_value_w,
        meta_x = top_meta_x,
        meta_last_x = top_meta_x + total_time_block_w + top_meta_pair_gap
    }
end

--- Build the full statistics table and top metadata row.
local function build_flight_statistics_element(container, wgt, x, y, c_w, c_h)
    local stats_w = math.max(1, c_w - 1)
    local stats_h = math.max(1, c_h - 1)
    local label_w = math.floor((stats_w - 2 * card_padding) * 0.31)
    local value_area_w = stats_w - 2 * card_padding - label_w
    local value_col_w = math.floor(value_area_w / 3)
    local value_last_col_w = value_area_w - value_col_w * 2
    local top_row_h = math.max(header_h + 4, math.floor(stats_h * 0.15))
    local header_row_h = math.max(header_h + 2, math.floor(stats_h * 0.12))
    local header_gap_h = math.max(3, math.floor(stats_h * 0.02))
    local rows = get_flight_statistics_rows(wgt)
    local data_area_h = stats_h - top_row_h - header_gap_h - header_row_h
    local row_h = math.floor(data_area_h / #rows)
    local used_h = top_row_h + header_gap_h + header_row_h + row_h * #rows
    local table_start_y = math.floor((stats_h - used_h) / 2)
    local table_header_y = table_start_y + top_row_h + header_gap_h
    local top = get_flight_statistics_top_layout(wgt, stats_w, top_row_h, table_start_y)
    container:build({
        {
            type = "rectangle",
            x = x,
            y = y,
            w = stats_w,
            h = stats_h,
            thickness = show_debug_border,
            children = {
                {
                    type = "label",
                    x = card_padding,
                    y = table_start_y + math.floor((top_row_h - top.model_font_h) / 2),
                    w = top.model_w,
                    h = top.model_font_h,
                    text = wgt.values.craft_name_formatted,
                    font = top.model_font,
                    color = COLOR_THEME_PRIMARY1,
                    align = LEFT
                }, {
                type = "label",
                x = top.meta_x,
                y = top.meta_label_y,
                w = top.total_time_label_w,
                h = header_h,
                text = top.total_time_label,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = LEFT
            }, {
                type = "label",
                x = top.meta_x + top.total_time_label_w + 2,
                y = top.meta_value_y,
                w = top.total_time_value_w,
                h = top.meta_value_font_h,
                text = wgt.values.rf_total_flight_time_display_formatted,
                font = top.meta_value_font,
                color = COLOR_THEME_PRIMARY1,
                align = LEFT
            }, {
                type = "label",
                x = top.meta_last_x,
                y = top.meta_label_y,
                w = top.flights_label_w,
                h = header_h,
                text = top.flights_label,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = LEFT
            }, {
                type = "label",
                x = top.meta_last_x + top.flights_label_w + 2,
                y = top.meta_value_y,
                w = top.flights_value_w,
                h = top.meta_value_font_h,
                text = wgt.values.rf_total_flights_display_formatted,
                font = top.meta_value_font,
                color = COLOR_THEME_PRIMARY1,
                align = LEFT
            }, {
                type = "label",
                x = card_padding,
                y = table_header_y,
                w = label_w - card_padding,
                h = header_row_h,
                text = wgt.values.rf_connection_state_formatted,
                font = header_font,
                color = wgt.values.rf_connection_state_color,
                align = LEFT
            }, {
                type = "label",
                x = card_padding + label_w,
                y = table_header_y,
                w = value_col_w,
                h = header_row_h,
                text = wgt.values.label_actual,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = CENTER
            }, {
                type = "label",
                x = card_padding + label_w + value_col_w,
                y = table_header_y,
                w = value_col_w,
                h = header_row_h,
                text = wgt.values.label_min,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = CENTER
            }, {
                type = "label",
                x = card_padding + label_w + value_col_w * 2,
                y = table_header_y,
                w = value_last_col_w,
                h = header_row_h,
                text = wgt.values.label_max,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = CENTER
            }
            }
        }
    })

    for i = 1, #rows do
        local current_row_h = row_h
        local row_y = y + table_header_y + header_row_h + (i - 1) * row_h
        local row_value_font = select_font(current_row_h - 2, value_col_w, rows[i].test, "DBLSIZE")
        local row_value_font_h = measure_font(row_value_font)
        local row_label_y = math.floor((current_row_h - header_h) / 2)
        local row_value_y = math.floor((current_row_h - row_value_font_h) / 2)

        build_card_element(container, x, row_y, stats_w, current_row_h, {
            {
                type = "label",
                x = card_padding,
                y = row_label_y,
                w = label_w - card_padding,
                h = header_h,
                text = rows[i].label,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = LEFT
            }, {
            type = "label",
            x = card_padding + label_w,
            y = row_value_y,
            w = value_col_w,
            h = row_value_font_h,
            text = rows[i].actual,
            font = row_value_font,
            color = rows[i].actualColor,
            align = CENTER
        }, {
            type = "label",
            x = card_padding + label_w + value_col_w,
            y = row_value_y,
            w = value_col_w,
            h = row_value_font_h,
            text = rows[i].min,
            font = row_value_font,
            color = rows[i].minColor,
            align = CENTER
        }, {
            type = "label",
            x = card_padding + label_w + value_col_w * 2,
            y = row_value_y,
            w = value_last_col_w,
            h = row_value_font_h,
            text = rows[i].max,
            font = row_value_font,
            color = rows[i].maxColor,
            align = CENTER
        }
        })

        if i == 1 then
            container:hline({ x = x + card_padding, y = y + table_header_y + header_row_h, w = stats_w - 2 * card_padding, h = 1, color =
            COLOR_THEME_SECONDARY1 })
        end
        if i < #rows then
            container:hline({ x = x + card_padding, y = row_y + current_row_h, w = stats_w - 2 * card_padding, h = 1, color =
            COLOR_THEME_SECONDARY1 })
        end
    end
end

-- ============================================================================
-- STATUS BAR FUNCTIONS: Dual-mode status bar (normal telemetry vs arming flags)
-- ============================================================================

--- Build the normal status-bar labels for the active view.
local function build_status_bar_normal_element(container, wgt, x, y, c_w, c_h)
    -- Calculate vertical centering offset
    local header_font_h = measure_font(header_font)
    local y_offset = math.floor((c_h - header_font_h) / 2)
    local labels = {}

    if init_view_state(wgt).current == "flight" then
        local model_w = math.floor(c_w * 0.46)
        local skp_w = math.floor(c_w * 0.16)
        local tpwr_w = math.floor(c_w * 0.24)
        local model_text_x = x + card_padding
        local model_text_w = math.max(1, model_w - 2 * card_padding)

        labels[1] = container:label({
            x = model_text_x,
            y = y + y_offset,
            w = model_text_w,
            h = header_font_h,
            text = function() return string.format("%s%s", wgt.values.label_model, wgt.values.craft_name_formatted()) end,
            font = header_font,
            color = COLOR_THEME_PRIMARY1,
            align = LEFT
        })
        labels[2] = container:label({
            x = x,
            y = y + y_offset,
            w = c_w,
            h = header_font_h,
            text = wgt.values.arm_state_text,
            font = header_font,
            color = wgt.values.arm_state_color,
            align = CENTER
        })
        labels[3] = container:label({
            x = x + c_w - skp_w,
            y = y + y_offset,
            w = skp_w,
            h = header_font_h,
            text = function() return string.format("%s: %s", wgt.values.label_skp, wgt.values.skp_formatted()) end,
            font = header_font,
            color = COLOR_THEME_PRIMARY1,
            align = RIGHT
        })

        -- TPWR between the (centered) arm state and Skp (toggleable)
        if wgt.options.ShowTPWR == 1 then
            labels[#labels + 1] = container:label({
                x = x + c_w - skp_w - tpwr_w,
                y = y + y_offset,
                w = tpwr_w,
                h = header_font_h,
                text = function() return string.format("%s: %s", wgt.values.label_tpwr_cur, wgt.values.tpwr_cur_formatted()) end,
                font = header_font,
                color = COLOR_THEME_PRIMARY1,
                align = RIGHT
            })
        end

        return labels
    end

    local item_w = math.floor(c_w / 4)

    labels[1] = container:label({
        x = x,
        y = y + y_offset,
        w = item_w,
        h = header_font_h,
        text = function() return string.format("%s: %s", wgt.values.label_tpwr, wgt.values.tpwr_formatted()) end,
        font = header_font,
        color = COLOR_THEME_PRIMARY1,
        align = CENTER
    })
    labels[2] = container:label({
        x = x + item_w,
        y = y + y_offset,
        w = item_w,
        h = header_font_h,
        text = function() return string.format("%s: %s", wgt.values.label_rqly, wgt.values.rqly_formatted()) end,
        font = header_font,
        color = COLOR_THEME_PRIMARY1,
        align = CENTER
    })
    labels[3] = container:label({
        x = x + 2 * item_w,
        y = y + y_offset,
        w = item_w,
        h = header_font_h,
        text = function() return string.format("%s: %s", wgt.values.label_mcu_temp_max,
                wgt.values.mcu_temp_max_formatted()) end,
        font = header_font,
        color = COLOR_THEME_PRIMARY1,
        align = CENTER
    })
    labels[4] = container:label({
        x = x + 3 * item_w,
        y = y + y_offset,
        w = item_w,
        h = header_font_h,
        text = function() return string.format("%s: %s", wgt.values.label_skp, wgt.values.skp_formatted()) end,
        font = header_font,
        color = COLOR_THEME_PRIMARY1,
        align = CENTER
    })

    return labels
end

--- Show either the normal status bar or the arming-flags warning state.
local function update_status_bar_visibility(wgt, force_update)
    if not wgt.status_bar_elements then return end

    local has_flags = wgt.values.arm_flags_visible()

    -- Only update if state changed (unless force update requested)
    if not force_update and has_flags == wgt.status_bar_state then return end
    wgt.status_bar_state = has_flags

    if has_flags then
        wgt.status_bar_elements.flags:show()
        for i = 1, #wgt.status_bar_elements.normal do wgt.status_bar_elements.normal[i]:hide() end
    else
        for i = 1, #wgt.status_bar_elements.normal do wgt.status_bar_elements.normal[i]:show() end
        wgt.status_bar_elements.flags:hide()
    end
end

--- Build both status-bar modes and cache the created element references.
local function build_status_bar_element(container, wgt, x, y, c_w, c_h)
    -- Build both status bar modes and store references
    if not wgt.status_bar_elements then
        local header_font_h = measure_font(header_font)
        local y_offset = math.floor((c_h - header_font_h) / 2)
        wgt.status_bar_elements = {}
        wgt.status_bar_elements.normal = build_status_bar_normal_element(container, wgt, x, y, c_w, c_h)
        wgt.status_bar_elements.flags = container:label({
            x = x,
            y = y + y_offset,
            w = c_w,
            h = header_font_h,
            text = wgt.values.arm_flags_text_formatted,
            font = header_font,
            color = COLOR_THEME_WARNING
        })
    end
end

--- Build the in-widget top bar: date/time (left) + radio (TX) battery icon (right).
--- Replaces the EdgeTX top bar so the widget can run fullscreen self-contained.
local function build_top_bar_element(container, wgt, x, y, c_w, c_h, show_link)
    wgt.elrs_bar_rect = nil   -- (re)set by the bar block below when bars are built
    local font_h = measure_font(header_font)
    local y_off = math.floor((c_h - font_h) / 2)

    -- right: a compact battery icon with the percentage overlaid ON the icon and
    -- the voltage right-aligned just to its left — one tight, integrated cluster.
    local icon_h = math.max(8, c_h - 2)
    local icon_w = math.max(30, math.floor(icon_h * 2.6))
    local term_w = math.max(2, math.floor(icon_w * 0.06))
    local icon_x = x + c_w - icon_w - term_w - 1
    local icon_y = y + math.floor((c_h - icon_h) / 2)
    local volt_w = math.floor(c_w * 0.20)
    local volt_text_x = icon_x - volt_w - 3
    local pct_font = select_font(icon_h - 2, icon_w - 4, "100%")
    local pct_font_h = measure_font(pct_font)

    -- fullscreen-only settings entry: small "menu" glyph (3 bars) before the date.
    -- The tap target is hit-tested in refresh() like the ELRS bars — no lvgl button.
    wgt.settings_icon_rect = nil
    local date_x = x + 1
    local in_fs = lvgl.isFullScreen ~= nil and lvgl.isFullScreen() == true
    if in_fs then
        -- compact boxed "hamburger" tight against the date (the visible button is
        -- deliberately small); the TAP TARGET is the whole top-left corner plus the
        -- hit-test margin — much larger than the glyph itself
        local ic_w = 20
        local bar_x = date_x + 4
        local bar_w = ic_w - 8
        local ic_y = y + math.floor((c_h - 10) / 2)
        container:build({
            { type = "rectangle", x = date_x, y = y + 1, w = ic_w, h = c_h - 2, thickness = 1, rounded = 3, color = COLOR_THEME_PRIMARY1 },
            { type = "rectangle", x = bar_x, y = ic_y,     w = bar_w, h = 2, filled = true, color = COLOR_THEME_PRIMARY1 },
            { type = "rectangle", x = bar_x, y = ic_y + 4, w = bar_w, h = 2, filled = true, color = COLOR_THEME_PRIMARY1 },
            { type = "rectangle", x = bar_x, y = ic_y + 8, w = bar_w, h = 2, filled = true, color = COLOR_THEME_PRIMARY1 },
        })
        wgt.settings_icon_rect = { x = 0, y = 0, w = date_x + ic_w + 16, h = c_h + 8 }
        date_x = date_x + ic_w + 4
    end

    -- left: clock (date + time, or time only via ClockMode), width MEASURED (a
    -- fixed 30% left a huge gap on the 800x480 TX16S and pushed the bars right)
    local time_only = wgt.options.ClockMode == 2
    local date_w = lcd.sizeText(time_only and "00:00" or "00.00.00  00:00", header_font) + 8
    container:label({
        x = date_x,
        y = y + y_off,
        w = date_w,
        h = font_h,
        text = (function()
            -- both parts are already time-throttled memoized strings; memo the
            -- concatenation too so the top bar allocates only when the string changes
            local last_d, last_t, last_s
            return function()
                if time_only then return wgt.values.clock_time_formatted() end
                local d = wgt.values.clock_date_formatted()
                local t = wgt.values.clock_time_formatted()
                if d ~= last_d or t ~= last_t then last_d, last_t, last_s = d, t, d .. "  " .. t end
                return last_s
            end
        end)(),
        font = header_font,
        color = COLOR_THEME_PRIMARY1,
        align = LEFT
    })

    local show_txv = wgt.options.ShowTxV == 1

    -- center: ELRS link as thin stacked bars (RQ, TQ, 1RSS, 2RSS) — unlabeled,
    -- color-by-zone with a threshold tick. Suppressed on the stats page
    -- (show_link == false), where the link figures live in the table/status bar.
    if show_link ~= false then
        -- The cluster is ALWAYS centered on the top bar's midline so it never
        -- shifts when the surroundings change (menu glyph, TxV on/off, date width).
        -- Width: capped at 40% of the bar, shrunk symmetrically if either side
        -- (date / voltage / battery) would be touched.
        local left_lim = date_x + date_w + 6
        local right_lim = (show_txv and volt_text_x or icon_x) - 6
        local mid = x + math.floor(c_w / 2)
        local half = math.min(mid - left_lim, right_lim - mid)
        local bar_w = math.max(8, math.min(2 * half, math.floor(c_w * 0.40)))
        local center_x = mid - math.floor(bar_w / 2)

        local TRACK   = COLOR_TRACK
        -- dark scheme gets vivid neon green/yellow/red so the bars pop on black
        local C_GREEN = dark_scheme and lcd.RGB(0x39, 0xFF, 0x14) or lcd.RGB(0x20, 0xB0, 0x20)
        local C_YELL  = dark_scheme and lcd.RGB(0xFF, 0xE0, 0x00) or lcd.RGB(0xF0, 0xC0, 0x00)
        local C_RED   = dark_scheme and lcd.RGB(0xFF, 0x1A, 0x40) or lcd.RGB(0xE0, 0x30, 0x30)
        -- quiet-mode "all fine" fill. On the dark scheme a 0x4A grey is barely
        -- brighter than the dark track -> invisible; use a clearly lighter grey there.
        local C_NEUT  = dark_scheme and lcd.RGB(0xA8, 0xB0, 0xB8) or lcd.RGB(0x4A, 0x4A, 0x4A)
        local TICK    = COLOR_DIM
        local quiet   = wgt.options.BarsQuiet == 1
        local rq_warn = wgt.options.RQlyWarn or 50
        local rq_crit = wgt.options.RQlyCrit or 30
        local rs_warn = wgt.options.RssWarn or 50
        local rs_crit = wgt.options.RssCrit or 25

        -- build the bar list (RQ/TQ honor the Show* toggles; 2RSS only if diversity)
        local bars = {}
        local show_rssi = wgt.options.ShowRSSI == 1
        if wgt.options.ShowRQly == 1 then bars[#bars + 1] = { get = function() return wgt.values.elrs_rq end,     warn = rq_warn, crit = rq_crit } end
        if wgt.options.ShowTQly == 1 then bars[#bars + 1] = { get = function() return wgt.values.elrs_tq end,     warn = rq_warn, crit = rq_crit } end
        if show_rssi then
            bars[#bars + 1] = { get = function() return wgt.values.elrs_r1_pct end, warn = rs_warn, crit = rs_crit }
            if wgt.values.elrs_diversity then
                bars[#bars + 1] = { get = function() return wgt.values.elrs_r2_pct end, warn = rs_warn, crit = rs_crit }
            end
        end

        local n = #bars
        if n > 0 then
        local avail_h = math.max(n * 2, c_h - 2)
        local slot_h  = math.floor(avail_h / n)
        local bar_h   = math.max(2, slot_h - 1)
        local top_y   = y + math.floor((c_h - slot_h * n) / 2)

        -- V2 "outline look" (matches the TX battery icon): empty rounded track with
        -- a fine outline, inset fill, threshold NOTCHES at the bottom edge. With the
        -- BarsQuiet setting the fill stays neutral dark while everything is fine and
        -- only turns yellow/red on warn/crit ("quiet when good, loud when bad").
        -- Tiny bars (small screens) fall back to the simple filled-track style.
        local outlined = bar_h >= 6
        local function fill_color(get, warn, crit)
            return function()
                local v = get()
                if v == nil then return TRACK end
                if v < crit then return C_RED end
                if v < warn then return C_YELL end
                return quiet and C_NEUT or C_GREEN
            end
        end

        local elems = {}
        for i = 1, n do
            local by   = top_y + (i - 1) * slot_h
            local get  = bars[i].get
            local warn = bars[i].warn
            local crit = bars[i].crit
            if outlined then
                local fx, fy, fh = center_x + 1, by + 1, bar_h - 2
                local fw_max = bar_w - 2
                elems[#elems + 1] = { type = "rectangle", x = center_x, y = by, w = bar_w, h = bar_h, thickness = 1, rounded = 2, color = COLOR_THEME_SECONDARY1 }
                elems[#elems + 1] = {
                    type = "rectangle", x = fx, y = fy, w = 1, h = fh, filled = true, rounded = 1,
                    color = fill_color(get, warn, crit),
                    pos = function() return fx, fy end,
                    size = function()
                        local v = get() or 0
                        if v < 0 then v = 0 elseif v > 100 then v = 100 end
                        return math.floor(fw_max * v / 100), fh
                    end
                }
                local nh = math.max(2, math.floor(bar_h * 0.45))
                elems[#elems + 1] = { type = "rectangle", x = center_x + math.floor(bar_w * crit / 100), y = by + bar_h - nh, w = 2, h = nh, filled = true, color = TICK }
                elems[#elems + 1] = { type = "rectangle", x = center_x + math.floor(bar_w * warn / 100), y = by + bar_h - nh, w = 2, h = nh, filled = true, color = TICK }
            else
                elems[#elems + 1] = { type = "rectangle", x = center_x, y = by, w = bar_w, h = bar_h, filled = true, color = TRACK }
                elems[#elems + 1] = {
                    type = "rectangle", x = center_x, y = by, w = 1, h = bar_h, filled = true,
                    color = fill_color(get, warn, crit),
                    pos = function() return center_x, by end,
                    size = function()
                        local v = get() or 0
                        if v < 0 then v = 0 elseif v > 100 then v = 100 end
                        return math.floor(bar_w * v / 100), bar_h
                    end
                }
                elems[#elems + 1] = { type = "rectangle", x = center_x + math.floor(bar_w * crit / 100), y = by, w = 1, h = bar_h, filled = true, color = TICK }
                elems[#elems + 1] = { type = "rectangle", x = center_x + math.floor(bar_w * warn / 100), y = by, w = 1, h = bar_h, filled = true, color = TICK }
            end
        end
        container:build(elems)

        -- bar-cluster rect for the fullscreen tap hit-test in refresh() (box-local ≈
        -- screen coords here: the widget runs as a full-screen zone, box sits ~2 px in).
        -- The ELRS detail is fullscreen-only: outside fullscreen touch never reaches
        -- the script, and the lvgl-button experiment for normal-mode taps did not
        -- fire on hardware — dropped on purpose.
        wgt.elrs_bar_rect = { x = center_x, y = y, w = bar_w, h = c_h }
        end
    end

    -- voltage left of the icon (toggleable)
    if show_txv then
        container:label({
            x = volt_text_x,
            y = y + y_off,
            w = volt_w,
            h = font_h,
            text = wgt.values.vtx_voltage_formatted,
            font = header_font,
            color = function() return wgt.values.vtx_volts_color end,
            align = RIGHT
        })
    end

    -- battery icon (terminal, reactive fill, outline)
    container:build({
        {
            type = "rectangle",
            x = icon_x + icon_w,
            y = icon_y + math.floor(icon_h * 0.28),
            w = term_w,
            h = math.max(2, math.floor(icon_h * 0.44)),
            filled = true,
            color = COLOR_THEME_PRIMARY1
        },
        {
            type = "rectangle",
            x = icon_x + 1,
            y = icon_y + 1,
            w = 1,
            h = icon_h - 2,
            filled = true,
            color = function() return wgt.values.vtx_fill_color() end,
            pos = function() return icon_x + 1, icon_y + 1 end,
            size = function() return math.max(0, math.floor((icon_w - 2) * wgt.values.vtx_fill_ratio())), icon_h - 2 end
        },
        {
            type = "rectangle",
            x = icon_x,
            y = icon_y,
            w = icon_w,
            h = icon_h,
            thickness = 1,
            color = COLOR_THEME_PRIMARY1
        }
    })

    -- percentage overlaid on the icon (drawn last → on top of the fill)
    container:label({
        x = icon_x,
        y = icon_y + math.floor((icon_h - pct_font_h) / 2),
        w = icon_w,
        h = pct_font_h,
        text = wgt.values.vtx_volts_formatted,
        font = pct_font,
        color = BLACK,
        align = CENTER
    })
end

-- ========== UI Builder Function ==========
-- ============================================================================
-- MAIN FUNCTIONS: Widget lifecycle (create, update, background, refresh)
-- ============================================================================

--- Notice page shown by passive views while NO Dashboard instance is running.
--- The passive views deliberately have no life of their own ("the main widget is
--- the boss") — without a publisher there is nothing trustworthy to show.
local function build_missing_dashboard_view(wgt, zone, title)
    local w = zone.w
    local h = zone.h
    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG, filled = false })
    panel:label({ x = 10, y = 6, text = title, font = h >= 170 and MIDSIZE or 0, color = COLOR_THEME_PRIMARY1 })
    panel:label({ x = 10, y = math.floor(h / 2) - 22, w = w - 20, h = 20,
        text = "No Dashboard instance running", font = 0, color = COLOR_THEME_PRIMARY1, align = CENTER })
    panel:label({ x = 10, y = math.floor(h / 2) + 2, w = w - 20, h = 20,
        text = "place an UltiDash with ViewMode = Dashboard", font = SMLSIZE, color = COLOR_THEME_DISABLED, align = CENTER })
end

--- Build the ELRS link detail view (ViewMode = "ELRS details", passive instance).
--- Labeled horizontal bars (RQ, TQ, 1RSS, 2RSS) with reactive crit/warn ticks +
--- values, rate/mode header and SNR/diversity footer. Thresholds AND look (palette,
--- background) come exclusively from the Dashboard instance via Shared — requires a
--- running Dashboard (notice page otherwise).
--- NO image / NO focusable objects — safe for any screen.
--- as_detail: built as the Dashboard instance's own detail page (opened by tapping
--- the top-bar bars) — adds the close hint + a full-area invisible close button in
--- normal mode (in fullscreen the tap-anywhere close is hit-tested in refresh()).
local function build_elrs_view(wgt, zone, as_detail)
    if not ultidash_functions.shared_alive() then
        return build_missing_dashboard_view(wgt, zone, "ELRS")
    end
    local w = zone.w
    local h = zone.h

    local TRACK   = COLOR_TRACK
    -- dark scheme gets vivid neon green/yellow/red so the bars pop on black
    local C_GREEN = dark_scheme and lcd.RGB(0x39, 0xFF, 0x14) or lcd.RGB(0x20, 0xB0, 0x20)
    local C_YELL  = dark_scheme and lcd.RGB(0xFF, 0xE0, 0x00) or lcd.RGB(0xF0, 0xC0, 0x00)
    local C_RED   = dark_scheme and lcd.RGB(0xFF, 0x1A, 0x40) or lcd.RGB(0xE0, 0x30, 0x30)
    local TICK    = COLOR_TICK

    local shared = ultidash_functions.get_shared()
    local shared_th = shared.thresholds
    -- live thresholds from the Dashboard instance (its options drive the warnings);
    -- plain numeric safety defaults only, never this instance's own options
    local function rq_warn() return shared_th.rq_warn  or 80 end
    local function rq_crit() return shared_th.rq_crit  or 50 end
    local function rs_warn() return shared_th.rss_warn or 15 end
    local function rs_crit() return shared_th.rss_crit or 8 end

    -- FONT-METRIC layout: every column width is measured with lcd.sizeText so the
    -- page fits both the 480x272 (TX15) and the 800x480 (TX16S MK3) screens — the
    -- old fixed-pixel version overflowed/wrapped on the larger display.
    local title_font = h >= 170 and DBLSIZE or MIDSIZE
    local row_font   = h >= 170 and MIDSIZE or 0
    local title_w, title_h = lcd.sizeText("ELRS", title_font)
    local row_tw,  row_th  = lcd.sizeText("TPWR", row_font)
    local val_w            = lcd.sizeText("-108dBm", row_font) + 8
    local foot_tw, foot_th = lcd.sizeText("Ag", row_font)

    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG, filled = force_bg_fill or (shared.bg_filled == true) })

    -- header: title + rate/mode, separated by a line
    panel:label({ x = 10, y = 4, text = "ELRS", font = title_font, color = COLOR_THEME_PRIMARY1 })
    panel:label({ x = 10 + title_w + 14, y = 4 + math.floor((title_h - row_th) / 2),
        w = w - title_w - 24 - (as_detail and 110 or 10), h = row_th + 2,
        text = function() return wgt.values.elrs_rate_desc or "-" end,
        font = row_font, color = COLOR_THEME_SECONDARY1, align = LEFT })
    if as_detail then
        -- fullscreen-only page: closing is handled in refresh() (any tap) or by
        -- leaving fullscreen (RTN) — no lvgl button needed (and none allowed: a
        -- focusable button would capture PAGE/RTN/TELE in fullscreen)
        panel:label({ x = w - 110, y = 8, w = 100, h = 18, text = "tap to close", font = SMLSIZE, color = COLOR_THEME_DISABLED, align = RIGHT })
    end
    local top = 4 + title_h + 4
    panel:hline({ y = top - 1, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })

    -- fixed rows (2RSS just stays empty/"-" without diversity) so the layout never
    -- depends on whether telemetry was already seen at build time. TPWR is INVERTED:
    -- high transmit power means the link is working hard (dynamic power maxing out),
    -- so the bar turns yellow/red towards the configurable TxPwrMax.
    -- TPWR needs the configurable TxPwrMax as its 100% reference — without it the
    -- bar stays empty and shows a hint instead (the raw mW value is still printed).
    local function tpwr_max() return shared_th.tpwr_max or 0 end
    local function tpwr_pct()
        local t = wgt.values.elrs_tpwr
        local m = tpwr_max()
        if t == nil or t <= 0 or m <= 0 then return nil end
        local p = math.floor(100 * t / m)
        if p > 100 then p = 100 end
        return p
    end
    -- SNR mapped -10..+10 dB -> 0..100% (LoRa demodulates down to ~-7 dB depending
    -- on rate; 10 dB+ is comfortable). Yellow below ~4 dB, red below 0 dB.
    local function snr_pct()
        local s = wgt.values.elrs_snr
        if s == nil then return nil end
        local p = math.floor((s + 10) * 5)
        if p < 0 then p = 0 elseif p > 100 then p = 100 end
        return p
    end
    local rows = {
        { lbl = "RQ",   val = function() return wgt.values.elrs_rq_formatted() end,    get = function() return wgt.values.elrs_rq end,     warn = rq_warn, crit = rq_crit },
        { lbl = "TQ",   val = function() return wgt.values.elrs_tq_formatted() end,    get = function() return wgt.values.elrs_tq end,     warn = rq_warn, crit = rq_crit },
        { lbl = "1RSS", val = function() return wgt.values.elrs_rssi1_formatted() end, get = function() return wgt.values.elrs_r1_pct end, warn = rs_warn, crit = rs_crit },
        { lbl = "2RSS", val = function() return wgt.values.elrs_rssi2_formatted() end, get = function() return wgt.values.elrs_r2_pct end, warn = rs_warn, crit = rs_crit },
        { lbl = "SNR",  val = function() return wgt.values.elrs_snr_formatted() end,   get = snr_pct,
          warn = function() return 70 end, crit = function() return 50 end },
        { lbl = "TPWR", invert = true,
          val = function()
              local t = wgt.values.elrs_tpwr
              return (t and t > 0) and (math.floor(t) .. "mW") or "-"
          end,
          get = tpwr_pct,
          warn = function() return 60 end, crit = function() return 85 end,
          tick_vis = function() return tpwr_max() > 0 end,
          hint = "set 'TPWR bar max' in settings",
          hint_vis = function() return tpwr_max() <= 0 end },
    }

    local foot_h = foot_th + 10
    local row_h = math.floor((h - top - foot_h - 2) / #rows)
    local bar_h = math.max(8, row_h - 10)
    local lbl_w = row_tw + 10
    local bar_x = 10 + lbl_w
    local bar_w = math.max(20, w - bar_x - val_w - 14)

    for i = 1, #rows do
        local r = rows[i]
        local ry = top + 4 + (i - 1) * row_h
        local ty = ry + math.floor((bar_h - row_th) / 2)   -- text vertically centered on the bar
        local get, warn, crit, invert = r.get, r.warn, r.crit, r.invert
        panel:label({ x = 10, y = ty, w = lbl_w, h = row_th + 2, text = r.lbl, font = row_font, color = COLOR_THEME_PRIMARY1, align = LEFT })
        panel:build({
            { type = "rectangle", x = bar_x, y = ry, w = bar_w, h = bar_h, filled = true, rounded = 3, color = TRACK },
            {
                type = "rectangle", x = bar_x, y = ry, w = 1, h = bar_h, filled = true, rounded = 3,
                color = function()
                    local v = get()
                    if v == nil then return TRACK end
                    if invert then
                        if v >= crit() then return C_RED elseif v >= warn() then return C_YELL else return C_GREEN end
                    end
                    if v >= warn() then return C_GREEN elseif v >= crit() then return C_YELL else return C_RED end
                end,
                pos = function() return bar_x, ry end,
                size = function()
                    local v = get() or 0
                    if v < 0 then v = 0 elseif v > 100 then v = 100 end
                    return math.floor(bar_w * v / 100), bar_h
                end
            },
            -- threshold ticks (= the color-switch points), reactive so they follow
            -- the dashboard's live options; hidden via tick_vis when meaningless
            { type = "rectangle", x = bar_x, y = ry, w = 2, h = bar_h, filled = true, color = TICK, visible = r.tick_vis,
              pos = function() return bar_x + math.floor(bar_w * crit() / 100), ry end },
            { type = "rectangle", x = bar_x, y = ry, w = 2, h = bar_h, filled = true, color = TICK, visible = r.tick_vis,
              pos = function() return bar_x + math.floor(bar_w * warn() / 100), ry end },
            { type = "rectangle", x = bar_x, y = ry, w = bar_w, h = bar_h, thickness = 1, rounded = 3, color = COLOR_THEME_SECONDARY1 },
        })
        if r.hint then
            panel:label({ x = bar_x + 6, y = ty, w = bar_w - 12, h = row_th + 2,
                text = r.hint, font = SMLSIZE, color = COLOR_THEME_DISABLED, align = CENTER,
                visible = r.hint_vis })
        end
        panel:label({ x = bar_x + bar_w + 6, y = ty, w = val_w, h = row_th + 2, text = r.val, font = row_font, color = COLOR_THEME_PRIMARY1, align = RIGHT })
    end

    -- footer: link details (left, live) + diversity (right)
    panel:hline({ y = h - foot_h - 1, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })
    panel:label({ x = 10, y = h - foot_h + 4, w = w - 130, h = foot_th + 2,
        text = function()
            local v = wgt.values
            local s = ""
            if v.elrs_ant ~= nil then s = "Ant " .. (v.elrs_ant + 1) end
            if v.rqly_min ~= nil then s = s .. (s ~= "" and "    " or "") .. "RQ min " .. math.floor(v.rqly_min) .. "%" end
            return s
        end,
        font = row_font, color = COLOR_THEME_PRIMARY1, align = LEFT })
    panel:label({ x = w - 124, y = h - foot_h + 6, w = 114, h = 20,
        text = function() return wgt.values.elrs_diversity and "Diversity: yes" or "Diversity: no" end,
        font = SMLSIZE, color = COLOR_THEME_DISABLED, align = RIGHT })
end

-- Add a filled triangle (up/down) to a build-table list from stacked 1px bars — the
-- EdgeTX font has no ▲/▼ glyphs, so scroll arrows are drawn. `size` = rows (px tall);
-- base width = 2*size-1, centered at cx, starting at top_y.
local function add_tri(list, cx, top_y, size, up, col)
    for r = 0, size - 1 do
        local wr = up and (2 * r + 1) or (2 * (size - r) - 1)
        -- 2px-tall bars stepped by 1px overlap into a solid triangle (1px bars were too
        -- thin to render visibly on the radio)
        list[#list + 1] = { type = "rectangle", filled = true, x = cx - math.floor(wr / 2), y = top_y + r, w = math.max(2, wr), h = 2, color = col }
    end
end

--- Build the STATUS DETAIL page (opened by tapping the ESC/arming status line,
--- fullscreen only). A bordered "status card" (arm/gov/throttle + ESC status + arming
--- status incl. the FULL disable-reason list) over the timestamped ESC event log, with
--- a tiny diagnostics footer. All rows are reactive (log updates live, no rebuilds).
local function build_estatus_view(wgt, zone)
    local w = zone.w
    local h = zone.h
    local C_RED = dark_scheme and lcd.RGB(0xFF, 0x1A, 0x40) or lcd.RGB(0xE0, 0x30, 0x30)
    local C_GRN = dark_scheme and lcd.RGB(0x39, 0xFF, 0x14) or lcd.RGB(0x20, 0xB0, 0x20)
    -- neutral grey for hints/timestamps (NOT the theme DISABLED color, which is orange-red
    -- in the Clean palette and made the empty hint look like an error)
    local C_DIM = COLOR_DIM

    local title_font = h >= 170 and DBLSIZE or MIDSIZE
    local row_font   = h >= 170 and MIDSIZE or 0
    local title_w, title_h = lcd.sizeText("Status", title_font)
    local _, row_th = lcd.sizeText("Ag", row_font)
    local _, sml_h  = lcd.sizeText("Ag", SMLSIZE)

    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG,
        filled = force_bg_fill or (ultidash_functions.get_shared().bg_filled == true) })

    -- header: title + craft name + close hint
    panel:label({ x = 10, y = 4, text = "Status", font = title_font, color = COLOR_THEME_PRIMARY1 })
    panel:label({ x = 10 + title_w + 14, y = 4 + math.floor((title_h - row_th) / 2),
        w = w - title_w - 150, h = row_th + 2,
        text = function() return wgt.values.craft_name_formatted() end,
        font = row_font, color = COLOR_THEME_SECONDARY1, align = LEFT })
    panel:label({ x = w - 110, y = 8, w = 100, h = 18, text = "tap to close", font = SMLSIZE, color = C_DIM, align = RIGHT })
    local top = 8 + title_h + 4

    -- ---------- Status card: arm/gov/thr + ESC status + arming status ----------
    local cx, cw = 6, w - 12
    local rpad = 4
    local lh = row_th + 2
    local card_h = rpad * 2 + lh * 3
    panel:build({ { type = "rectangle", x = cx, y = top, w = cw, h = card_h, thickness = 1, rounded = 8,
        color = COLOR_THEME_SECONDARY1 } })

    local ix = cx + 10
    local iw = cw - 20
    local lblW = math.max(40, math.floor(iw * 0.14))   -- "ESC"/"Arm" tag column

    -- row 1: ARMED/Disarmed | Gov | Thr
    local r1 = top + rpad
    local aw = math.floor(iw * 0.28)
    local gw = math.floor(iw * 0.42)
    panel:label({ x = ix, y = r1, w = aw, h = lh, font = row_font, align = LEFT,
        text = function() return wgt.armed_now and "ARMED" or "Disarmed" end,
        color = function() return wgt.armed_now and C_RED or COLOR_THEME_PRIMARY1 end })
    panel:label({ x = ix + aw, y = r1, w = gw, h = lh, font = row_font, align = LEFT,
        text = function() return "Gov: " .. wgt.values.gov_state_formatted() end, color = COLOR_THEME_PRIMARY1 })
    panel:label({ x = ix + aw + gw, y = r1, w = iw - aw - gw, h = lh, font = row_font, align = RIGHT,
        text = function() return "Thr: " .. (wgt.values.throttle_text or "-") end, color = COLOR_THEME_PRIMARY1 })

    -- row 2: ESC status (level-colored)
    local r2 = r1 + lh
    panel:label({ x = ix, y = r2, w = lblW, h = lh, font = row_font, text = "ESC", color = C_DIM, align = LEFT })
    panel:label({ x = ix + lblW, y = r2, w = iw - lblW, h = lh, font = row_font, align = LEFT,
        text = function()
            if wgt.esc_status_text and wgt.esc_status_text ~= "" then return wgt.esc_status_text end
            return (wgt.values.rf_connection_state == "disconnected") and "-" or "OK"
        end,
        color = function()
            local lvl = wgt.esc_status_level
            if lvl == nil then return COLOR_THEME_PRIMARY1 end
            if lvl >= 3 then return C_RED end
            if lvl == 2 then return COLOR_THEME_WARNING end
            return COLOR_THEME_PRIMARY1
        end })

    -- row 3: arming status (Armed / Ready to arm / the full disable-reason list)
    local r3 = r2 + lh
    panel:label({ x = ix, y = r3, w = lblW, h = lh, font = row_font, text = "Arm", color = C_DIM, align = LEFT })
    panel:label({ x = ix + lblW, y = r3, w = iw - lblW, h = lh, font = row_font, align = LEFT,
        text = function()
            if wgt.armed_now then return "Armed" end
            local r = wgt.values.arm_reasons_full
            if r and r ~= "" then return r end
            return (wgt.values.rf_connection_state == "disconnected") and "-" or "Ready to arm"
        end,
        color = function()
            if wgt.armed_now then return COLOR_THEME_PRIMARY1 end
            local r = wgt.values.arm_reasons_full
            if r and r ~= "" then return COLOR_THEME_WARNING end
            return (wgt.values.rf_connection_state == "disconnected") and C_DIM or C_GRN
        end })

    -- ---------- Event log ----------
    local log_font = 0
    local time_w, log_th = lcd.sizeText("00:00:00", log_font)
    time_w = time_w + 10
    local footer_h = sml_h + 6
    local log_lbl_y = top + card_h + 6
    panel:label({ x = 10, y = log_lbl_y, w = 200, h = sml_h + 2, text = "Event log", font = SMLSIZE, color = C_DIM, align = LEFT })
    panel:hline({ y = log_lbl_y + sml_h + 3, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })

    local list_y = log_lbl_y + sml_h + 8
    local list_bottom = h - footer_h - 4
    local log_row_h = log_th + 4
    local slots = math.max(1, math.floor((list_bottom - list_y) / log_row_h))

    -- scroll offset (0 = newest at top), clamped to the current log length. The ▲/▼
    -- buttons (handled in refresh()) change wgt.estatus_scroll and rebuild.
    local log0 = ultidash_functions.get_esc_log(wgt)
    local nlog = log0 and #log0 or 0
    local maxscroll = math.max(0, nlog - slots)
    local scroll = math.min(math.max(0, wgt.estatus_scroll or 0), maxscroll)
    wgt.estatus_scroll = scroll

    if nlog > slots then
        local sb  = sml_h + 8
        local sby = log_lbl_y - math.floor((sb - sml_h) / 2)
        local sdx = w - 10 - sb
        local sux = sdx - 6 - sb
        local tri_sz = math.max(5, math.floor(sb * 0.42))
        local tri_y  = sby + math.floor((sb - tri_sz) / 2)
        local btns = {
            { type = "rectangle", x = sux, y = sby, w = sb, h = sb, thickness = 1, rounded = 4, color = COLOR_THEME_SECONDARY1 },
            { type = "rectangle", x = sdx, y = sby, w = sb, h = sb, thickness = 1, rounded = 4, color = COLOR_THEME_SECONDARY1 },
        }
        add_tri(btns, sux + math.floor(sb / 2), tri_y, tri_sz, true,  COLOR_THEME_PRIMARY1)   -- up (newer)
        add_tri(btns, sdx + math.floor(sb / 2), tri_y, tri_sz, false, COLOR_THEME_PRIMARY1)   -- down (older)
        panel:build(btns)
        wgt.estatus_scroll_up   = { x = sux, y = sby, w = sb, h = sb }
        wgt.estatus_scroll_down = { x = sdx, y = sby, w = sb, h = sb }
        panel:label({ x = sux - 96, y = log_lbl_y, w = 90, h = sml_h + 2, font = SMLSIZE, align = RIGHT, color = C_DIM,
            text = string.format("%d-%d / %d", scroll + 1, math.min(scroll + slots, nlog), nlog) })
    else
        wgt.estatus_scroll_up   = nil
        wgt.estatus_scroll_down = nil
    end

    local function log_empty()
        local log = ultidash_functions.get_esc_log(wgt)
        return log == nil or #log == 0
    end
    -- clean centered empty-state (instead of a broken half-line in the timestamp column)
    panel:label({ x = 0, y = math.floor((list_y + list_bottom) / 2 - log_th / 2), w = w, h = log_th + 2,
        font = log_font, color = C_DIM, align = CENTER, text = "No events yet", visible = log_empty })

    for i = 1, slots do
        local idx = i   -- 1 = newest (before scroll)
        local ry = list_y + (i - 1) * log_row_h
        local function entry()
            local log = ultidash_functions.get_esc_log(wgt)
            return log and log[#log - (idx - 1) - scroll] or nil
        end
        panel:label({ x = 10, y = ry, w = time_w, h = log_th + 2, font = log_font, color = C_DIM, align = LEFT,
            text = function() local e = entry(); return e and e.time or "" end })
        panel:label({ x = 10 + time_w, y = ry, w = w - 20 - time_w, h = log_th + 2, font = log_font, align = LEFT,
            text = function() local e = entry(); return e and e.text or "" end,
            color = function()
                local e = entry()
                if not e then return C_DIM end
                if e.level >= 3 then return C_RED end
                if e.level == 2 then return COLOR_THEME_WARNING end
                if e.level <= 0 then return C_DIM end
                return COLOR_THEME_PRIMARY1
            end })
    end

    -- tiny diagnostics footer (kept subtle, per the "klein/dezent" choice)
    panel:label({ x = 10, y = h - footer_h + 2, w = w - 20, h = sml_h + 2, font = SMLSIZE, color = C_DIM, align = LEFT,
        text = function()
            return "Lua " .. (wgt.dbg_lua_kb or "-") .. " kB  free " .. (wgt.dbg_free_kb or "-")
                .. " kB   UI " .. (wgt.dbg_hz or "-") .. " Hz   pass " .. ((wgt.dbg_pass_cs or 0) * 10) .. " ms"
        end })
end

--- Build the BATTERY DETAIL page (tap the center fuel gauge, fullscreen only):
--- a big fuel gauge plus a cell-voltage scale with the RESOLVED thresholds
--- (FC config or manual) marked, and the key battery numbers. Drawn with
--- build-table primitives only (no lvgl.box — overlay/window objects swallow
--- fullscreen taps).
local function build_battery_view(wgt, zone)
    local w = zone.w
    local h = zone.h
    local TRACK   = lcd.RGB(0xC8, 0xC8, 0xC8)   -- battery graphic empty segs (fixed identity)
    -- dark scheme gets vivid neon green/yellow/red so the gauge pops on black
    local C_GREEN = dark_scheme and lcd.RGB(0x39, 0xFF, 0x14) or lcd.RGB(0x20, 0xB0, 0x20)
    local C_YELL  = dark_scheme and lcd.RGB(0xFF, 0xE0, 0x00) or lcd.RGB(0xF0, 0xC0, 0x00)
    local C_RED   = dark_scheme and lcd.RGB(0xFF, 0x1A, 0x40) or lcd.RGB(0xE0, 0x30, 0x30)
    local C_DIM   = COLOR_DIM
    local TICK    = COLOR_TICK

    local title_font = h >= 170 and DBLSIZE or MIDSIZE
    local row_font   = h >= 170 and MIDSIZE or 0
    local title_w, title_h = lcd.sizeText("Battery", title_font)
    local _, row_th = lcd.sizeText("Ag", row_font)

    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG,
        filled = force_bg_fill or (ultidash_functions.get_shared().bg_filled == true) })

    panel:label({ x = 10, y = 4, text = "Battery", font = title_font, color = COLOR_THEME_PRIMARY1 })
    panel:label({ x = w - 110, y = 8, w = 100, h = 18, text = "tap to close", font = SMLSIZE, color = COLOR_THEME_DISABLED, align = RIGHT })
    local top = 4 + title_h + 4
    panel:hline({ y = top - 1, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })

    -- cell-voltage scale with the resolved thresholds marked (full width); the
    -- current value gets the big title-size font
    local rx = 14
    local rw = w - 28
    local val_font = title_font
    local _, val_h = lcd.sizeText("8.88", val_font)
    local val_w = lcd.sizeText("88.88", val_font) + 10
    local bar_w = rw - val_w - 8
    local bar_h = math.max(12, row_th)
    local function th_full() return wgt.values.vcel_full_threshold() end
    local function th_low()  return wgt.values.vcel_warning_threshold() end
    local function th_crit() return wgt.values.vcel_alarm_threshold() end
    local function vx(v)
        local smin = th_crit() - 0.15
        local smax = th_full() + 0.10
        if smax <= smin then smax = smin + 1 end
        local f = (v - smin) / (smax - smin)
        if f < 0 then f = 0 elseif f > 1 then f = 1 end
        return math.floor(bar_w * f)
    end

    local sy = top + 6
    -- SMLSIZE is taller on 800x480 — measure instead of hardcoding (label used to
    -- collide with the scale bar on the TX16S)
    local _, sml_h = lcd.sizeText("Ag", SMLSIZE)
    panel:label({ x = rx, y = sy, w = rw, h = sml_h + 2, text = "Cell voltage", font = SMLSIZE, color = C_DIM, align = LEFT })
    local by = sy + sml_h + 4
    panel:build({
        { type = "rectangle", x = rx, y = by, w = bar_w, h = bar_h, filled = true, rounded = 3, color = COLOR_TRACK },
        { type = "rectangle", x = rx + 1, y = by + 1, w = 1, h = bar_h - 2, filled = true, rounded = 2,
          color = function()
              local v = wgt.values.vcel
              if v == nil then return COLOR_TRACK end
              if v <= th_crit() then return C_RED end
              if v <= th_low() then return C_YELL end
              return C_GREEN
          end,
          pos = function() return rx + 1, by + 1 end,
          size = function()
              local v = wgt.values.vcel
              if v == nil then return 0, bar_h - 2 end
              return math.max(1, vx(v) - 1), bar_h - 2
          end },
        { type = "rectangle", x = rx, y = by, w = 2, h = bar_h, filled = true, color = TICK,
          pos = function() return rx + vx(th_crit()), by end },
        { type = "rectangle", x = rx, y = by, w = 2, h = bar_h, filled = true, color = TICK,
          pos = function() return rx + vx(th_low()), by end },
        { type = "rectangle", x = rx, y = by, w = 2, h = bar_h, filled = true, color = TICK,
          pos = function() return rx + vx(th_full()), by end },
        { type = "rectangle", x = rx, y = by, w = bar_w, h = bar_h, thickness = 1, rounded = 3, color = COLOR_THEME_SECONDARY1 },
    })
    panel:label({ x = rx + bar_w + 6, y = by + math.floor((bar_h - val_h) / 2), w = val_w, h = val_h + 2,
        text = function() return wgt.values.vcel_formatted() end,
        font = val_font, color = COLOR_THEME_PRIMARY1, align = RIGHT })
    -- threshold legend incl. the source (FC config vs manual values)
    panel:label({ x = rx, y = by + bar_h + 4, w = rw, h = sml_h + 2,
        text = function()
            return string.format("crit %.2f   low %.2f   full %.2f V   (%s)",
                th_crit(), th_low(), th_full(),
                (wgt.options.CellSource == 2) and "manual" or "FC config")
        end,
        font = SMLSIZE, color = C_DIM, align = LEFT })

    -- horizontal battery in the EXACT dashboard look (coarse segments, light grey
    -- empty area, black overlays) — "laid down" under the voltage scale, cap right,
    -- filling left -> right. Values are drawn INSIDE the graphic.
    local bottom_h = row_th + 8
    local cap_w = math.max(7, math.floor(w * 0.018))
    local bx = 14
    local by2 = by + bar_h + 8 + sml_h + 6
    local bw = w - 28 - cap_w
    local bh = math.max(40, h - by2 - bottom_h - 10)
    local body_rounding = math.max(3, math.floor(bh * 0.10))
    local inner_pad = math.max(3, math.floor(bh * 0.10))
    local ix = bx + inner_pad
    local iy = by2 + inner_pad
    local iw = bw - 2 * inner_pad
    local ih = bh - 2 * inner_pad
    local seg_gap = math.max(1, math.floor(iw * 0.01))
    local seg_count = math.max(6, math.min(9, math.floor(iw / 16)))
    local seg_w = math.floor((iw - (seg_count - 1) * seg_gap) / seg_count)
    local seg_last_w = iw - seg_w * (seg_count - 1) - seg_gap * (seg_count - 1)
    local seg_rounding = math.max(1, math.floor(ih * 0.10))
    local function seg_color(threshold)
        return function()
            local p = wgt.values.gauge_fill_percent()
            if p >= threshold then return wgt.values.capa_bar_color end
            return TRACK
        end
    end

    -- cap (the "plus pole", right) + body outline
    local cap_h = math.floor(bh * 0.36)
    panel:build({
        { type = "rectangle", x = bx + bw, y = by2 + math.floor((bh - cap_h) / 2), w = cap_w, h = cap_h,
          rounded = 2, color = COLOR_THEME_SECONDARY1, filled = true },
        { type = "rectangle", x = bx, y = by2, w = bw, h = bh, thickness = 1, rounded = body_rounding,
          color = COLOR_THEME_SECONDARY1, filled = false },
    })

    -- segments, leftmost = lowest threshold (fills from the left towards the cap)
    for i = 1, seg_count do
        local sw = (i == seg_count) and seg_last_w or seg_w
        local sx = ix + (i - 1) * (seg_w + seg_gap)
        local col = seg_color((i / seg_count) * 100)
        local flat_w = math.max(1, math.min(seg_rounding, sw))
        panel:build({
            { type = "rectangle", x = sx, y = iy, w = sw, h = ih, thickness = 1,
              rounded = (i == 1 or i == seg_count) and seg_rounding or 0, color = col, filled = true },
            { type = "rectangle", x = (i == 1) and (sx + sw - flat_w) or sx, y = iy, w = flat_w, h = ih,
              thickness = 0, color = col, filled = (i == 1 or i == seg_count) },
        })
    end

    -- overlays INSIDE the graphic: cells (left), big percent (center), used/capacity (right)
    local pct_font = select_font(math.floor(bh * 0.50), 220, "100%")
    local pct_h = measure_font(pct_font)
    -- Translucent rounded "pills" behind the two SMALL in-graphic values (cells + mAh)
    -- so they stay readable on any segment colour (esp. the dark scheme's neon fills).
    -- The big percent is large enough to read as plain black text, so it gets NO pill.
    -- Each pill hugs its CURRENT text (measured at build), capsule-shaped; white text on
    -- top. Drawn AFTER the segments and BEFORE the labels so the z-order is bg -> text.
    -- (LVGL geometry is not reactive, so a pill can lag a little if its value grows a lot
    -- while the page stays open.)
    local cells_y = by2 + math.floor((bh - row_th) / 2)
    local pct_y   = by2 + math.floor((bh - pct_h) / 2)
    local pill_px = math.max(4, math.floor(row_th * 0.35))
    local pill_py = math.max(2, math.floor(row_th * 0.16))
    local pill_text = lcd.RGB(0xF8, 0xF8, 0xF8)
    local cells_tw = lcd.sizeText(wgt.values.gauge_cells_formatted(), row_font)
    local mah_tw   = lcd.sizeText(wgt.values.gauge_mah_value_formatted() .. " mAh", row_font)
    local pill_h   = row_th + 2 + 2 * pill_py
    local function pill_rect(rx, rw)
        return { type = "rectangle", x = rx, y = cells_y - pill_py, w = rw, h = pill_h, filled = true,
                 color = BLACK, opacity = 140, rounded = math.floor(pill_h / 2) }
    end
    panel:build({
        pill_rect(ix + 8 - pill_px, cells_tw + 2 * pill_px),
        pill_rect((ix + iw - 8) - mah_tw - pill_px, mah_tw + 2 * pill_px),
    })
    panel:label({ x = ix + 8, y = cells_y, w = math.floor(iw * 0.20), h = row_th + 2,
        text = function() return wgt.values.gauge_cells_formatted() end,
        font = row_font, color = pill_text, align = LEFT })
    panel:label({ x = bx, y = pct_y, w = bw, h = pct_h,
        text = function() return wgt.values.gauge_percent_formatted() end,
        font = pct_font, color = BLACK, align = CENTER })
    -- used mAh only, like the dashboard gauge — the profile's TOTAL capacity is
    -- merely informational and "x / total" misreads as usable-until-total (the
    -- reserve model ends earlier)
    panel:label({ x = ix + iw - math.floor(iw * 0.30) - 8, y = cells_y,
        w = math.floor(iw * 0.30), h = row_th + 2,
        text = function() return wgt.values.gauge_mah_value_formatted() .. " mAh" end,
        font = row_font, color = pill_text, align = RIGHT })

    -- bottom line: the remaining numbers in one row
    local byl = h - bottom_h + 2
    panel:label({ x = 14, y = byl, w = math.floor(w * 0.34), h = row_th + 2,
        text = function() return "Batt " .. wgt.values.vbat_formatted() end,
        font = row_font, color = COLOR_THEME_PRIMARY1, align = LEFT })
    panel:label({ x = math.floor(w * 0.34), y = byl, w = math.floor(w * 0.32), h = row_th + 2,
        text = function()
            local v = wgt.values.vcel_min
            return "Cell min " .. (v and string.format("%.2f V", v) or "-")
        end,
        font = row_font, color = COLOR_THEME_PRIMARY1, align = CENTER })
    panel:label({ x = w - 14 - math.floor(w * 0.30), y = byl, w = math.floor(w * 0.30), h = row_th + 2,
        text = function() return "Reserve " .. (wgt.options.Reserve or 20) .. " %" end,
        font = row_font, color = COLOR_THEME_PRIMARY1, align = RIGHT })
end

--- Build the "Telemetry" detail page (opened by tapping the right value panel):
--- a 3-column grid of up to 12 freely chosen sensors (Settings ▸ Values). Off
--- slots are skipped; each cell shows the value plus the EdgeTX session low/high
--- ("min .. max", read from the sensor's "-"/"+" variants). Same look / tap-to-close
--- behaviour as the other detail pages.
local function build_telem_view(wgt, zone)
    local w = zone.w
    local h = zone.h
    local title_font = h >= 170 and DBLSIZE or MIDSIZE
    local _, title_h = lcd.sizeText("Telemetry", title_font)

    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG,
        filled = force_bg_fill or (ultidash_functions.get_shared().bg_filled == true) })
    panel:label({ x = 10, y = 4, text = "Telemetry", font = title_font, color = COLOR_THEME_PRIMARY1 })
    panel:label({ x = w - 110, y = 8, w = 100, h = 18, text = "tap to close", font = SMLSIZE,
        color = COLOR_THEME_DISABLED, align = RIGHT })
    local top = 4 + title_h + 4
    panel:hline({ y = top - 1, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })

    -- collect active (non-off) slots in order
    local slots = {}
    for i = 1, #DETAIL_SLOT_KEYS do
        local name = wgt.options[DETAIL_SLOT_KEYS[i]]
        if not is_off_sensor(name) then slots[#slots + 1] = name end
    end
    if #slots == 0 then
        panel:label({ x = 0, y = math.floor(h / 2) - 12, w = w, h = 24,
            text = "No values selected  (Settings > Values)", font = MIDSIZE,
            color = COLOR_THEME_DISABLED, align = CENTER })
        return
    end

    -- 3-column grid on both radios. Each tile shows the value (right-aligned) + unit
    -- and the EdgeTX session low/high as a soft "min .. max" chip beneath it. The
    -- label placement adapts to the tile width: wide tiles (TX16S) put the label to
    -- the LEFT of the value; narrow tiles (TX15) put it on TOP (Value2 widget style),
    -- so the value still gets the full width and stays large.
    local cols   = 3
    local rows_n = math.ceil(#slots / cols)
    local pad    = 12
    local grid_y = top + 6
    local grid_h = h - grid_y - 6
    local cell_w = math.floor((w - pad * (cols + 1)) / cols)
    local cell_h = math.floor(grid_h / rows_n)
    local _, lbl_h = lcd.sizeText("Ag", SMLSIZE)
    local mm_h = lbl_h

    local wide     = cell_w >= 190          -- room for a label column beside the value
    local lbl_w    = wide and math.floor(cell_w * 0.40) or 0
    local va_x_off = lbl_w                  -- value area starts after the side label
    local va_w     = cell_w - lbl_w
    local lbl_top_h = wide and 0 or (lbl_h + 1)   -- height the top label consumes
    -- value font sized once (uniform), leaving headroom for the widest unit
    local val_font = select_font(cell_h - mm_h - lbl_top_h - 8, va_w - 30, "99.99")
    local val_h    = measure_font(val_font)
    local block_h  = lbl_top_h + val_h + 2 + mm_h
    -- low/high chip: a soft rounded pill sized to a worst-case range string
    local chip_w   = math.min(va_w, lcd.sizeText("999.9 .. 999.9", SMLSIZE) + 12)
    local chip_r   = math.floor((mm_h + 2) / 2)

    for idx = 1, #slots do
        local name = slots[idx]
        local c = (idx - 1) % cols
        local r = math.floor((idx - 1) / cols)
        local cx = pad + c * (cell_w + pad)
        local cy = grid_y + r * cell_h + math.max(0, math.floor((cell_h - block_h) / 2))

        local unit = sensor_unit(name)
        local unit_w = (unit ~= "") and (lcd.sizeText(unit, SMLSIZE) + 3) or 0
        local va_x = cx + va_x_off
        local unit_x = va_x + va_w - unit_w           -- unit at the value area's right edge
        local val_x = va_x
        local val_w = (unit ~= "") and (unit_x - 2 - val_x) or va_w
        local val_top = cy + lbl_top_h                -- value sits below the top label (if any)

        -- label: left of the value (wide) or on top spanning the tile (narrow)
        if wide then
            -- long labels ("Energy Used", "BEC Voltage") don't fit the 40% side
            -- column on one SMLSIZE line → LVGL wraps them. Reserve two lines when
            -- needed (else the 2nd line clips) and vertically centre against the value.
            local lbl_text = sensor_short_label(name)
            local lbl_box_w = lbl_w - 4
            local lbl_lines = (lcd.sizeText(lbl_text, SMLSIZE) > lbl_box_w) and 2 or 1
            local lbl_box_h = lbl_lines * lbl_h + 2
            panel:label({ x = cx, y = val_top + math.floor((val_h - lbl_box_h) / 2),
                w = lbl_box_w, h = lbl_box_h,
                text = lbl_text, font = SMLSIZE, color = COLOR_THEME_SECONDARY1, align = LEFT })
        else
            panel:label({ x = cx, y = cy, w = cell_w, h = lbl_h + 2,
                text = sensor_short_label(name), font = SMLSIZE, color = COLOR_THEME_SECONDARY1, align = LEFT })
        end
        -- value: big, right-aligned (leaves room for the unit to its right)
        if name == VOLT_AUTO then
            panel:label({ x = val_x, y = val_top, w = val_w, h = val_h + 2,
                text = wgt.values.display_voltage_formatted, font = val_font,
                color = wgt.values.display_voltage_color, align = RIGHT })
        elseif name == ESCL_AUTO then
            -- computed (no raw sensor behind it): the 5 Hz-cached load % with the
            -- bar's warn/crit colour semantics
            panel:label({ x = val_x, y = val_top, w = val_w, h = val_h + 2,
                text = sensor_value_text(wgt, name), font = val_font,
                color = esc_load_color(wgt), align = RIGHT })
        else
            panel:label({ x = val_x, y = val_top, w = val_w, h = val_h + 2,
                text = sensor_value_text_raw(wgt, name), font = val_font,
                color = COLOR_THEME_PRIMARY1, align = RIGHT })
        end
        -- unit: small, sitting on the big value's baseline at the value area's right edge
        if unit ~= "" then
            panel:label({ x = unit_x, y = val_top + (val_h - lbl_h), w = unit_w, h = lbl_h + 2,
                text = unit, font = SMLSIZE, color = COLOR_THEME_SECONDARY1, align = LEFT })
        end
        -- low/high chip under the value, right-aligned within the value area
        local chip_x = va_x + va_w - chip_w
        local chip_y = val_top + val_h + 2
        panel:build({
            { type = "rectangle", x = chip_x, y = chip_y, w = chip_w, h = mm_h + 2,
              filled = true, rounded = chip_r, color = COLOR_TRACK },
            { type = "label", x = chip_x, y = chip_y, w = chip_w, h = mm_h + 2,
              text = sensor_minmax_text(wgt, name), font = SMLSIZE, color = COLOR_TICK, align = CENTER },
        })
    end
end

--- Build the status/config view (ViewMode = "Status info", passive instance).
--- Shows the ACTIVE configuration of the Dashboard instance — read exclusively from
--- the Shared snapshot it publishes (resolved cell thresholds incl. the MSP-fetched
--- FC values, alert thresholds, alert switches). Look (palette, background) follows
--- the Dashboard too. Requires a running Dashboard (notice page otherwise).
--- as_page: opened from the Dashboard's own menu — rendered as an lvgl.page with
--- back-to-menu instead of the passive full-zone panel (no alive-gate needed: the
--- dashboard instance publishes itself).
local function build_status_view(wgt, zone, as_page)
    if not as_page and not ultidash_functions.shared_alive() then
        return build_missing_dashboard_view(wgt, zone, "UltiDash config")
    end
    local w = zone.w
    local h = zone.h
    local shared = ultidash_functions.get_shared()
    local th, al, vol = shared.thresholds, shared.alerts, shared.volume

    local function num(v, fmt) if v == nil then return "-" end return string.format(fmt, v) end
    local function sounds_off()
        if not shared.ready then return "-" end
        local off = {}
        if al.cellchk == false then off[#off + 1] = "CellChk" end
        if al.fuel    == false then off[#off + 1] = "Fuel" end
        if al.volt    == false then off[#off + 1] = "Volt" end
        if al.arm     == false then off[#off + 1] = "Arm" end
        if al.telem   == false then off[#off + 1] = "Telem" end
        if al.link    == false then off[#off + 1] = "Link" end
        if al.rssi    == false then off[#off + 1] = "Rssi" end
        if al.pwr     == false then off[#off + 1] = "Pwr" end
        if al.bec     == false then off[#off + 1] = "Bec" end
        if al.skp     == false then off[#off + 1] = "Skp" end
        if #off == 0 then return "none (all enabled)" end
        return table.concat(off, ", ")
    end

    -- section markers ({ section=... }) group the config; the rest are label/value rows
    local items = {
        { lbl = "Model / link", val = function()
            if not shared.ready then return "-" end
            return (shared.model_name or "-") .. (shared.connected and "  (conn)" or "  (disc)")
        end },
        { section = "Battery" },
        { lbl = "Cell source", val = function() return th.source or "-" end },
        { lbl = "Cell full / low / crit", val = function()
            if th.cell_full == nil then return "-" end
            return string.format("%.2f / %.2f / %.2f V", th.cell_full or 0, th.cell_warn or 0, th.cell_crit or 0)
        end },
        { lbl = "Reserve", val = function() if not shared.ready then return "-" end return num(th.reserve, "%d %%") end },
        { section = "Link" },
        { lbl = "RQly warn / crit", val = function()
            if not shared.ready then return "-" end
            return num(th.rq_warn, "%d %%") .. "  /  " .. num(th.rq_crit, "%d %%")
        end },
        { lbl = "RSSI warn / crit / hold", val = function()
            if not shared.ready then return "-" end
            return num(th.rss_warn, "%d %%") .. " / " .. num(th.rss_crit, "%d %%") .. " / " .. num(th.rss_hold, "%d s")
        end },
        { section = "Alerts" },
        { lbl = "Power warn", val = function() if not shared.ready then return "-" end return num(th.pwr_warn_v, "%.1f V") end },
        { lbl = "BEC warn / crit", val = function()
            if not shared.ready then return "-" end
            return num(th.bec_warn, "%d %%") .. "  /  " .. num(th.bec_crit, "%d %%")
        end },
        { lbl = "ESC load", val = function()
            if not shared.ready then return "-" end
            if not th.esc_load then return "off" end
            local lim = th.esc_limit and (th.esc_limit .. " A") or "not set"
            return "GV" .. (th.esc_gvar or "?") .. "  " .. lim .. "  " .. num(th.esc_warn, "%d") .. " / " .. num(th.esc_crit, "%d %%")
                .. "  " .. num(th.esc_hold, "%d s")
        end },
        { lbl = "Skipped limit", val = function() if not shared.ready then return "-" end return num(th.skp_limit, "%d") end },
        { lbl = "Repeat", val = function() if not shared.ready then return "-" end return al.repeat_summary or "none" end },
        { lbl = "Mute / escalation", val = function()
            if not shared.ready then return "-" end
            return (al.mute and "ALL MUTED" or "none") .. "  /  " .. (al.escalating and "ACTIVE" or "idle")
        end },
        { lbl = "Sounds off", val = sounds_off },
        { section = "Volume" },
        { lbl = "Callout / voice", val = function()
            if not shared.ready or vol == nil then return "-" end
            local c = vol.callout or 0
            return ((c == 0) and "System" or (c .. "/5")) .. "  /  " .. (vol.voice or "-")
        end },
        { lbl = "Master (GVAR)", val = function()
            if not shared.ready or vol == nil then return "-" end
            if (vol.gvar or 0) == 0 then return "off (radio vol)" end
            return "GV" .. vol.gvar .. "   " .. (vol.flight or "-") .. " / " .. (vol.escal or "-") .. " %"
        end },
    }

    if as_page then
        -- scrollable page (menu -> Status): sections + rows, everything fits via scroll
        local pg = lvgl.page({
            title = "UltiDash", subtitle = "Status",
            back = function() wgt.menu_view = "menu"; init_view_state(wgt).dirty = true end,
        })
        local _, sml_h = lcd.sizeText("Ag", SMLSIZE)
        local row_h = 26
        local lblw = math.floor(w * 0.46)
        local y = 2
        for i = 1, #items do
            local it = items[i]
            if it.section then
                y = y + 6
                pg:label({ x = 10, y = y, w = w - 40, h = sml_h + 2, text = it.section, font = SMLSIZE, color = COLOR_THEME_FOCUS, align = LEFT })
                y = y + sml_h + 4
            else
                pg:label({ x = 10, y = y, w = lblw, h = 22, text = it.lbl, color = COLOR_THEME_SECONDARY1, align = LEFT })
                pg:label({ x = 10 + lblw, y = y, w = w - lblw - 34, h = 22, text = it.val, color = COLOR_THEME_PRIMARY1, align = RIGHT })
                y = y + row_h
            end
        end
        pg:label({ x = 10, y = y + 8, w = w - 34, h = 20, font = SMLSIZE, color = COLOR_DIM, align = LEFT,
            text = function()
                return "Lua " .. (wgt.dbg_lua_kb or "-") .. " kB  free " .. (wgt.dbg_free_kb or "-")
                    .. " kB   UI " .. (wgt.dbg_hz or "-") .. " Hz"
            end })
        return
    end

    -- passive ViewMode "Status info" panel (fixed height): same items, equal rows
    local big = h >= 170
    local title_font = big and MIDSIZE or 0
    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG, filled = force_bg_fill or (shared.bg_filled == true) })

    local top = big and 30 or 22
    local foot = big and 22 or 16
    panel:label({ x = 10, y = 4, text = "UltiDash config", font = title_font, color = COLOR_THEME_PRIMARY1 })
    panel:hline({ y = top - 2, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })

    local row_h = math.floor((h - top - foot) / #items)
    local row_font = select_font(row_h - 1, nil, nil)
    local lbl_w = math.floor(w * 0.46)

    for i = 1, #items do
        local it = items[i]
        local ry = top + (i - 1) * row_h
        if it.section then
            panel:label({ x = 10, y = ry, w = w - 20, h = row_h, text = it.section, font = row_font, color = COLOR_THEME_FOCUS, align = LEFT })
        else
            panel:label({ x = 10, y = ry, w = lbl_w, h = row_h, text = it.lbl, font = row_font, color = COLOR_THEME_SECONDARY1, align = LEFT })
            panel:label({ x = 10 + lbl_w, y = ry, w = w - lbl_w - 14, h = row_h, text = it.val, font = row_font, color = COLOR_THEME_PRIMARY1, align = RIGHT })
        end
    end

    panel:label({ x = 10, y = h - foot + 2, w = w - 14, h = foot - 2,
        text = "live from the Dashboard instance", font = SMLSIZE, color = COLOR_THEME_DISABLED, align = LEFT })
end

-- ============================================================================
-- IN-WIDGET SETTINGS PAGE (fullscreen only)
-- ============================================================================
-- The EdgeTX widget-options list is flat and survives updates badly (index
-- shifts); these settings are edited here instead and persisted per model via
-- ultidashSettings (which overlays them onto wgt.options). First group: alerts.

local function fmt_centivolt(v) return string.format("%.2f V", v / 100) end
local function fmt_decivolt(v) return string.format("%.1f V", v / 10) end

local SETTINGS_DISPLAY = {
    { key = "TopLeft",       lbl = "Top-left shows",        kind = "choice", def = 1, vals = { "Model image", "Timer" } },
    { key = "ClockMode",     lbl = "Top bar clock",         kind = "choice", def = 2, vals = { "Date + time", "Time only" } },
    { key = "Timer",         lbl = "Timer (for top-left)",  kind = "num", def = 0, min = 0, max = 2, step = 1, big = 1,
                             fmt = function(v) return "Timer " .. (v + 1) end },
    { key = "ColorScheme",   lbl = "Color scheme",          kind = "choice", def = 1, vals = { "UltiDash", "EdgeTX theme", "UltiDash dark" } },
    { key = "BGFilled",      lbl = "Fill background",       kind = "bool", def = 1 },
    { key = "StatsViewMode", lbl = "Stats page",            kind = "choice", def = 3, vals = { "Never", "On disarmed", "On disconnected" } },
    { key = "VoltageDisplay",lbl = "Voltage shown as",      kind = "choice", def = 1, vals = { "Cell voltage", "Battery voltage" } },
    { key = "ShowRQly",      lbl = "Top bar: RQ bar",       kind = "bool", def = 1 },
    { key = "ShowTQly",      lbl = "Top bar: TQ bar",       kind = "bool", def = 1 },
    { key = "ShowRSSI",      lbl = "Top bar: RSSI bars",    kind = "bool", def = 1 },
    { key = "ShowTxV",       lbl = "Top bar: TX voltage",   kind = "bool", def = 0 },
    { key = "ShowTPWR",      lbl = "Bottom bar: TPWR",      kind = "bool", def = 1 },
    { key = "TxPwrMax",      lbl = "TPWR bar max (mW)",     kind = "num", def = 0, min = 0, max = 1000, step = 10, big = 50,
                             fmt = function(v) return v == 0 and "not set" or (v .. " mW") end },
    { key = "ArmClose",      lbl = "Close detail pages on arm", kind = "bool", def = 0 },
    { key = "TapDetails",    lbl = "Tap zones for detail pages", kind = "bool", def = 1 },
    { key = "BarsQuiet",     lbl = "Link bars: color only on warning", kind = "bool", def = 1 },
}

local function fmt_pctval(v) return v .. " %" end

local SETTINGS_BATTERY = {
    { key = "Reserve",      lbl = "Reserve (%)",            kind = "num", def = 20,  min = 0,   max = 40,  step = 1, big = 5 },
    -- Fuel-callout density (value-driven descending %): quiet up high, denser near the end.
    -- Defaults reproduce the historical fixed cadence (from full, 10 % steps, 1 % below 10 %).
    { key = "FuelStart",    lbl = "Fuel: announce below (%)", kind = "num", def = 100, min = 5, max = 100, step = 5, big = 10,
                            fmt = function(v) return (v >= 100) and "from full" or (v .. " %") end },
    { key = "FuelStep",     lbl = "Fuel: coarse step (%)",  kind = "num", def = 10, min = 1, max = 50, step = 1, big = 5, fmt = fmt_pctval },
    { key = "FuelDense",    lbl = "Fuel: dense below (%)",   kind = "num", def = 10, min = 0, max = 100, step = 5, big = 10, fmt = fmt_pctval },
    { key = "FuelStepFine", lbl = "Fuel: fine step (%)",    kind = "num", def = 1,  min = 1, max = 50, step = 1, big = 5, fmt = fmt_pctval },
    { key = "CellSource",   lbl = "Cell thresholds from",   kind = "choice", def = 1, vals = { "FC config", "Manual" } },
    { key = "CellFull",     lbl = "Full cell (manual)",     kind = "num", def = 412, min = 300, max = 480, step = 1, big = 10, fmt = fmt_centivolt },
    { key = "CellLow",      lbl = "Low cell (manual)",      kind = "num", def = 345, min = 300, max = 440, step = 1, big = 10, fmt = fmt_centivolt },
    { key = "CellCritical", lbl = "Critical cell (manual)", kind = "num", def = 330, min = 300, max = 440, step = 1, big = 10, fmt = fmt_centivolt },
    { key = "StartupDelay", lbl = "Cell-check delay (s)",   kind = "num", def = 4,   min = 1,   max = 20,  step = 1, big = 5 },
}

local function fmt_pctdrop(v) return v .. " %" end

-- Warning thresholds, grouped by subject via non-interactive section headers
-- (kind="info" rows). ESC-load thresholds live in their own "ESC load" group;
-- the TPWR bar max moved to Display (it scales the bottom-bar TPWR display).
local SETTINGS_THRESHOLDS = {
    { kind = "info", lbl = "Link & signal" },
    { key = "RQlyWarn",   lbl = "Link warn (%)",          kind = "num", def = 80, min = 0,  max = 100,  step = 1,  big = 5 },
    { key = "RQlyCrit",   lbl = "Link critical (%)",      kind = "num", def = 50, min = 0,  max = 100,  step = 1,  big = 5 },
    { key = "RssWarn",    lbl = "RSSI warn (% headroom)", kind = "num", def = 15, min = 0,  max = 100,  step = 1,  big = 5 },
    { key = "RssCrit",    lbl = "RSSI critical (%)",      kind = "num", def = 8,  min = 0,  max = 100,  step = 1,  big = 5 },
    { key = "RssHold",    lbl = "RSSI hold time (s)",     kind = "num", def = 2,  min = 1,  max = 10,   step = 1,  big = 2 },
    { key = "SkpLimit",   lbl = "Skipped-packet limit",   kind = "num", def = 50, min = 10, max = 2000, step = 10, big = 100 },
    { kind = "info", lbl = "Power & BEC" },
    { key = "PwrWarnV",   lbl = "Power warn voltage",     kind = "num", def = 90, min = 30, max = 500,  step = 5,  big = 20, fmt = fmt_decivolt },
    { key = "BecWarn",    lbl = "BEC warn (% drop)",      kind = "num", def = 8,  min = 1,  max = 50,   step = 1,  big = 5, fmt = fmt_pctdrop },
    { key = "BecCrit",    lbl = "BEC critical (% drop)",  kind = "num", def = 15, min = 1,  max = 60,   step = 1,  big = 5, fmt = fmt_pctdrop },
}

-- ESC continuous-current LOAD monitor (own settings group). The FC writes the ESC's
-- continuous-current limit (amps) into the configured GVAR after connect;
-- load% = Curr / limit * 100. One MASTER switch runs the whole feature:
--   * EscMon ("ESC load monitoring") + a configured EscGvar. Off (or no GVAR) => the
--     whole feature is off: no bar, no "ESC Load" tile value ("not set"), no alarm.
--   * When on, the bar (Current row) + the "ESC Load" virtual sensor show; Warn/
--     Critical % colour both. The ALARM is an additional opt-in — the "ESC load"
--     alert's Active (key EscLoad) under Alerts > ESC load — and is itself gated by
--     EscMon (monitoring off = alarm silent). EscHold gates how long the load must
--     stay high before it fires (alarm is armed-only).
local SETTINGS_ESC = {
    { key = "EscMon",   lbl = "ESC load monitoring",   kind = "bool", def = 0 },
    { key = "EscGvar",  lbl = "ESC limit: GVAR (A)",   kind = "num", def = 0, min = 0, max = 15, step = 1, big = 1,
                        fmt = function(v) return (v == 0) and "Off" or ("GV" .. v) end },
    { key = "EscWarn",  lbl = "Warn (%)",              kind = "num", def = 80,  min = 10, max = 200, step = 5, big = 10, fmt = fmt_pctval },
    { key = "EscCrit",  lbl = "Critical (%)",          kind = "num", def = 100, min = 10, max = 200, step = 5, big = 10, fmt = fmt_pctval },
    { key = "EscHold",  lbl = "Alarm hold time (s)",   kind = "num", def = 5,   min = 1,  max = 30,  step = 1, big = 5, fmt = function(v) return v .. " s" end },
    { kind = "info", lbl = "Monitoring off = feature off. GVAR holds the ESC continuous-current limit (A), written by the FC. Alarm on/off is under Alerts > ESC load." },
}

local function fmt_pct(v) return tostring(v) .. " %" end

-- Loudness / volume — its own settings group (see the "Volume" entry in
-- SETTINGS_GROUPS). Two independent loudness worlds:
--   * the per-callout WIDGET volume (Volume 1..5, passed to playFile/playNumber), and
--   * the GVAR MASTER-volume bridge (VolGvar drives a model "Volume" special function).
-- Normal vs. escalation % (VolFlight / VolEscal) only apply in the GVAR world.
local SETTINGS_VOLUME = {
    { key = "Volume",     lbl = "Callout volume",            kind = "num", def = 0, min = 0, max = 5, step = 1, big = 1,
                          fmt = function(v)
                              if v == 0 then return "System" end
                              if v == 1 then return "1 (min)" end
                              if v == 5 then return "5 (max)" end
                              return tostring(v) .. " / 5"
                          end },
    { key = "VolWhen",    lbl = "Widget volume applies",     kind = "choice", def = 1, vals = { "Always", "Only connected" } },
    { key = "VolGvar",    lbl = "Master volume via GVAR",     kind = "num", def = 0, min = 0, max = 15, step = 1, big = 1,
                          fmt = function(v) return (v == 0) and "Off" or ("GV" .. v) end },
    { kind = "info", lbl = "GVAR is optional. Without it, callouts use the radio volume; the normal/escalation % below apply only when a GVAR is set." },
    { key = "VolFlight",  lbl = "Normal volume (%)",          kind = "slider", def = 80,  min = 0, max = 100, step = 5, big = 10, fmt = fmt_pct },
    { key = "VolEscal",   lbl = "Escalation volume (%)",      kind = "slider", def = 100, min = 0, max = 100, step = 5, big = 10, fmt = fmt_pct },
}

-- Global voice settings (language + master mute), reached via the Alerts submenu's
-- first entry ("Voice / mute"). Separate from the per-alert pages.
local SETTINGS_VOICE = {
    { key = "VoiceLang",  lbl = "Voice language",            kind = "choice", def = 1, vals = { "English", "Deutsch" } },
    { key = "Mute",       lbl = "Mute (master)",             kind = "choice", def = 1, vals = { "None", "All" } },
}

-- Per-alert configuration. Each alert is its own settings sub-page (the Alerts
-- submenu). The historical on/off key (enKey) is REUSED as "Active" so existing
-- user choices survive; the rest are new per-alert keys, prefixed by `code`:
--   <code>Rep  repeat on/off          <code>Cnt  repeat count (0 = until cleared)
--   <code>Int  repeat interval (s)     <code>Esc  boost to escalation volume
--   <code>Vib  vibrate                 <code>Ovl  fullscreen overlay (prep only)
-- repDef/cntDef/intDef default the repeat behaviour. Fuel & Voltage already repeat
-- continuously while the condition holds, so they default to Repeat=on / count=until
-- cleared / 6 s (reproducing the previous CalloutInt cadence); the once-shot alerts
-- default to Repeat=off (announce once, as before). vibDef mirrors the old "vibrate on
-- critical" (fuel/voltage/telemetry).
local ALERTS_SPEC = {
    { code = "Fuel",  name = "Fuel",            enKey = "SndFuel",    enDef = 1, vibDef = 1, repDef = 1, cntDef = 0, intDef = 6 },
    { code = "Volt",  name = "Voltage",         enKey = "SndVolt",    enDef = 1, vibDef = 1, repDef = 1, cntDef = 0, intDef = 6 },
    { code = "Cell",  name = "Cell check",      enKey = "SndCellChk", enDef = 1, vibDef = 0, repDef = 0, cntDef = 3, intDef = 5 },
    { code = "Arm",   name = "Armed / disarm",  enKey = "SndArm",     enDef = 1, vibDef = 0, repDef = 0, cntDef = 3, intDef = 5 },
    { code = "Telem", name = "Telemetry",       enKey = "SndTelem",   enDef = 1, vibDef = 1, repDef = 0, cntDef = 3, intDef = 5 },
    { code = "Link",  name = "Link quality",    enKey = "SndLink",    enDef = 1, vibDef = 0, repDef = 0, cntDef = 3, intDef = 5 },
    { code = "Rssi",  name = "RSSI / signal",   enKey = "SndRssi",    enDef = 1, vibDef = 0, repDef = 0, cntDef = 3, intDef = 5 },
    { code = "Pwr",   name = "Main power lost", enKey = "PwrWarn",    enDef = 1, vibDef = 0, repDef = 0, cntDef = 3, intDef = 5 },
    { code = "Bec",   name = "BEC voltage",     enKey = "SndBec",     enDef = 1, vibDef = 1, repDef = 0, cntDef = 3, intDef = 5 },
    { code = "EscL",  name = "ESC load",        enKey = "EscLoad",    enDef = 0, vibDef = 1, repDef = 0, cntDef = 3, intDef = 5 },
    { code = "Skp",   name = "Skipped packets", enKey = "SkpWarn",    enDef = 1, vibDef = 0, repDef = 0, cntDef = 3, intDef = 5 },
}

local function build_alert_items(a)
    return {
        { key = a.enKey,         lbl = "Active",             kind = "bool", def = a.enDef },
        { key = a.code .. "Rep", lbl = "Repeat",             kind = "bool", def = a.repDef },
        { key = a.code .. "Cnt", lbl = "Repeat count",       kind = "num", def = a.cntDef, min = 0, max = 20, step = 1, big = 5,
                                 fmt = function(v) return (v == 0) and "until cleared" or tostring(v) end },
        { key = a.code .. "Int", lbl = "Repeat interval (s)", kind = "num", def = a.intDef, min = 1, max = 60, step = 1, big = 5 },
        { key = a.code .. "Esc", lbl = "Escalation volume",  kind = "bool", def = 0 },
        { key = a.code .. "Vib", lbl = "Vibrate",            kind = "bool", def = a.vibDef },
        { key = a.code .. "Ovl", lbl = "Overlay (prep)",     kind = "bool", def = 0 },
    }
end

-- Alerts submenu: a "Voice / mute" entry plus one page per alert.
local ALERT_PAGES = { { name = "Voice / mute", items = SETTINGS_VOICE } }
for i = 1, #ALERTS_SPEC do
    ALERT_PAGES[#ALERT_PAGES + 1] = { name = ALERTS_SPEC[i].name, items = build_alert_items(ALERTS_SPEC[i]) }
end

-- Switch voice announcements: the switch per function is picked with the NATIVE
-- EdgeTX source picker (lvgl.source, filtered to switches + logical switches).
-- Stored value = SIGNED EdgeTX source index of the WHOLE switch (negative =
-- inverted, picked as "!SA" in the popup; 0 = Off) — so the picker shows only
-- switches this radio actually has, including custom names, and the 3-position
-- semantics (read via getValue -> -1024/0/1024) stay intact.
-- READ-ONLY — the model's mixer/arming logic is untouched.
local SETTINGS_SWITCHES = {
    { key = "MotorSrc",   lbl = "Motor on/off switch",  kind = "switch", def = 0 },
    { key = "RescueSrc",  lbl = "Rescue switch",        kind = "switch", def = 0 },
    { key = "GovSrc",     lbl = "Governor mode switch", kind = "switch", def = 0 },
    { key = "ProfileSrc", lbl = "Profile switch (1-3)", kind = "switch", def = 0 },
}

-- NB: the pre-native stored codes (own list: 1=Off, 2..17 SA..SH, 18..29 CFS,
-- 100+ logical switches, old keys MotorSw/RescueSw/GovSw/ProfileSw/TbSwitch) are
-- NOT auto-migrated: an in-widget migration needed file I/O inside update() and
-- tripped the CPU limit on SD remount. Existing models: re-pick the switches
-- once in Settings > Switch voice; the old cfg keys are simply ignored.

-- Configurable telemetry value slots, split into two settings groups:
--   "Tele Main"    = the 5 rows of the dashboard's right-hand value panel
--   "Tele Details" = the 12 cells of the tap-to-open Telemetry detail page
-- kind="sensor" stores the EdgeTX sensor NAME (string). Defaults reproduce the
-- original panel; the detail page defaults to a sensible battery/ESC set.
-- VOLT_AUTO = the smart cell/battery voltage (warn colour).
local SETTINGS_TELE_MAIN = {
    { key = "PanelV1", lbl = "Panel 1 (top)", kind = "sensor", def = VOLT_AUTO },
    { key = "PanelV2", lbl = "Panel 2",       kind = "sensor", def = "Hspd" },
    { key = "PanelV3", lbl = "Panel 3",       kind = "sensor", def = "Curr" },
    { key = "PanelV4", lbl = "Panel 4",       kind = "sensor", def = "Tesc" },
    { key = "PanelV5", lbl = "Panel 5 (btm)", kind = "sensor", def = "Vbec" },
}

local SETTINGS_TELE_DETAIL = {
    { key = "DetV1",   lbl = "Detail 1",      kind = "sensor", def = "Vbat" },
    { key = "DetV2",   lbl = "Detail 2",      kind = "sensor", def = "Vcel" },
    { key = "DetV3",   lbl = "Detail 3",      kind = "sensor", def = "Curr" },
    { key = "DetV4",   lbl = "Detail 4",      kind = "sensor", def = "Capa" },
    { key = "DetV5",   lbl = "Detail 5",      kind = "sensor", def = "Bat%" },
    { key = "DetV6",   lbl = "Detail 6",      kind = "sensor", def = SENSOR_OFF },
    { key = "DetV7",   lbl = "Detail 7",      kind = "sensor", def = SENSOR_OFF },
    { key = "DetV8",   lbl = "Detail 8",      kind = "sensor", def = SENSOR_OFF },
    { key = "DetV9",   lbl = "Detail 9",      kind = "sensor", def = SENSOR_OFF },
    { key = "DetV10",  lbl = "Detail 10",     kind = "sensor", def = SENSOR_OFF },
    { key = "DetV11",  lbl = "Detail 11",     kind = "sensor", def = SENSOR_OFF },
    { key = "DetV12",  lbl = "Detail 12",     kind = "sensor", def = SENSOR_OFF },
}

-- General / meta settings (config-file behaviour, diagnostics)
local SETTINGS_GENERAL = {
    { key = "CfgPerCraft", lbl = "Config file per craft", kind = "bool", def = 0 },
    { key = "DebugLog",    lbl = "Debug log to SD card",  kind = "bool", def = 0 },
    { key = "DebugKeep",   lbl = "Debug log: sessions kept", kind = "num", def = 20, min = 1, max = 50, step = 1, big = 5 },
}

-- Toolbox: RF adjustment map/editor tool pages (sources default to ch11/ch12/AdjV/BEAT/PID#)
local SETTINGS_TOOLBOX = {
    { key = "TbSrc",    lbl = "Activation switch",       kind = "switch", def = 0 },
    { key = "TbTool",   lbl = "Switch opens",            kind = "choice", def = 1, vals = { "Off", "Adjust Map", "Adjust Edit" } },
    { key = "TbConfigCh", lbl = "Adj: Config channel",  kind = "num", def = 11, min = 1, max = 32, step = 1, big = 4, fmt = function(v) return "CH" .. v end },
    { key = "TbValueCh",  lbl = "Adj: Value channel",   kind = "num", def = 12, min = 1, max = 32, step = 1, big = 4, fmt = function(v) return "CH" .. v end },
    { key = "TbGvar",  lbl = "Adj editor: GVAR",        kind = "num", def = 1, min = 1, max = 15, step = 1, big = 1,
                       fmt = function(v) return "GV" .. v end },
    { key = "TbPulse", lbl = "Adj editor: pulse (ms)",  kind = "num", def = 150, min = 50, max = 1000, step = 10, big = 50 },
    { key = "TbScale", lbl = "Adj value divider",       kind = "num", def = 1, min = 1, max = 1000, step = 1, big = 10 },
    { key = "TbBert",  lbl = "Adj editor: ranges hint", kind = "bool", def = 0 },
    { key = "TbSun",   lbl = "Toolbox sunlight mode",   kind = "bool", def = 0 },
    { key = "TbVoice", lbl = "Announce bank (voice)",   kind = "bool", def = 1 },
}

local SETTINGS_GROUPS = {
    { name = "Display",      items = SETTINGS_DISPLAY },
    { name = "Tele Main",    items = SETTINGS_TELE_MAIN },
    { name = "Tele Details", items = SETTINGS_TELE_DETAIL },
    { name = "Battery",      items = SETTINGS_BATTERY },
    { name = "Thresholds",   items = SETTINGS_THRESHOLDS },
    { name = "ESC load",     items = SETTINGS_ESC },
    { name = "Volume",       items = SETTINGS_VOLUME },
    { name = "Alerts",       submenu = ALERT_PAGES },
    { name = "Switch voice", items = SETTINGS_SWITCHES },
    { name = "General",      items = SETTINGS_GENERAL },
    { name = "Toolbox",      items = SETTINGS_TOOLBOX },
}

-- Visit every settings item across all groups AND alert sub-pages. Used for the
-- defaults table and the working-copy snapshot so both cover the submenu items.
local function for_each_setting_item(fn)
    for g = 1, #SETTINGS_GROUPS do
        local grp = SETTINGS_GROUPS[g]
        if grp.items then
            for i = 1, #grp.items do fn(grp.items[i]) end
        elseif grp.submenu then
            for p = 1, #grp.submenu do
                local items = grp.submenu[p].items
                for i = 1, #items do fn(items[i]) end
            end
        end
    end
end

-- defaults derived from the group tables (single source of truth now that the
-- EdgeTX option list no longer carries these values) — handed to the settings
-- layer so apply() can fill anything missing from the file
local SETTINGS_DEFAULTS = {}
for_each_setting_item(function(it)
    if it.key then SETTINGS_DEFAULTS[it.key] = it.def end   -- skip keyless info rows
end)
-- hidden key (no settings row): tracks whether the in-widget menu was opened at
-- least once — drives the first-placement hint banner on the dashboard
SETTINGS_DEFAULTS.SetupSeen = 0
ultidash_settings.set_defaults(SETTINGS_DEFAULTS)

--- Persist pending settings edits (if any) and resolve them into the options.
--- AUTOSAVE policy: edits are saved no matter HOW the page is left (back arrow,
--- RTN, arming, fullscreen exit) — losing changes on exit confused more than a
--- discard path ever helped.
local function save_pending_settings(wgt)
    if not wgt.settings_working then return end
    if not ultidash_settings.save(wgt.settings_working) then
        ultidash_functions.log("settings save FAILED (cfg file not writable)")
    end
    ultidash_settings.apply(wgt)
    wgt.settings_working = nil
end

--- Close the settings page back to wherever it was opened from (autosaves). Normal
--- group pages return to the settings submenu; alert sub-pages to the alerts submenu.
local function close_settings(wgt)
    save_pending_settings(wgt)
    wgt.menu_view = (wgt.settings_page and wgt.settings_page.back) or "settings_menu"
    init_view_state(wgt).dirty = true
end

--- Build the settings page (lvgl.page scrolls; its back arrow catches RTN, the
--- unfocused-RTN case is handled in refresh). One group per page, opened by name
--- from the menu's group list (back returns there). Rows = name label + REACTIVE value label + plain
--- buttons (no toggle/slider — documented one-time-script-only): bools/choices
--- cycle with [>], numbers use [-]/[+] (long press = big step). Presses only
--- mutate the working copy — the reactive labels update by themselves, so the
--- page is never rebuilt while editing and the scroll position survives.
--- Back/RTN = save ALL groups to the per-model file; arming/fullscreen-exit discard.
local function build_settings_view(wgt, zone)
    if not wgt.settings_working then
        local t = {}
        for_each_setting_item(function(it)
            if it.key then
                t[it.key] = wgt.options[it.key]
                -- sensor slots carry a shadow key (<key>Raw = the native picker's
                -- source index of a raw pick) so the raw field can redisplay the
                -- pick after a restart — seed it alongside the slot itself
                if it.kind == "sensor" then
                    t[it.key .. "Raw"] = wgt.options[it.key .. "Raw"]
                end
            end
        end)
        wgt.settings_working = t
    end
    local working = wgt.settings_working

    -- The page to render is a {name, items, back} spec set when it was opened
    -- (a normal group, or one alert sub-page). Fall back to the first group.
    local grp = wgt.settings_page or SETTINGS_GROUPS[1]

    -- one page opened by name from the menu (no blind ‹ › tab cycling); the back
    -- arrow / RTN returns to that list (grp.back) and autosaves.
    local pg = lvgl.page({
        title = grp.name,
        subtitle = "UltiDash settings",
        back = function() close_settings(wgt) end,
    })

    local w = zone.w
    -- index of the trailing ‹ Raw › display entry in the shared sensor list (same
    -- for every row), used to show the raw state in each curated dropdown
    local se_raw_idx = 1
    -- sensor pick list (Off + smart-voltage + known model sensors + ‹ Raw ›) built
    -- once per page build and shared by every kind="sensor" row
    local se_labels, se_codes = build_sensor_list(wgt)
    for ci = 1, #se_codes do if se_codes[ci] == RAW_SENTINEL then se_raw_idx = ci; break end end
    -- row height adapts to the screen: EdgeTX toggle switches are ~40 px tall on
    -- the 800x480 TX16S and overlapped each other in 38 px rows
    local row_h = (zone.h >= 300) and 50 or 38
    local lbl_dy = math.floor((row_h - 24) / 2)
    local btn_w = 40
    local val_w = 120
    local right = w - 20            -- keep clear of the scrollbar
    -- picker boxes (choice / sensor / switch) only need to fit one text line; at
    -- full row height they looked oversized/chunky. Size to the ACTUAL font height
    -- (device-correct — this radio reports 480x320, so a height-based "big" guess
    -- was wrong) plus a little padding, and center them vertically in the row.
    local _, dd_txt_h = lcd.sizeText("Ag", 0)
    local field_h = math.min(row_h - 4, dd_txt_h + 8)
    local function field_y(ry) return ry + math.floor((row_h - field_h) / 2) end
    -- info rows wrap to ~2 lines of the small font; measure so they never overlap
    local _, sml_h = lcd.sizeText("Ag", SMLSIZE)
    local info_h = sml_h * 2 + 8
    local elems = {}

    -- running vertical cursor: rows have per-kind heights (info rows are taller),
    -- so positions are accumulated rather than derived from the index
    local ry = 2
    for i = 1, #grp.items do
        local it = grp.items[i]
        local row_this = (it.kind == "info") and info_h or row_h
        local is_num = it.kind == "num"

        -- value text resolver (reactive)
        local function value_text()
            local v = working[it.key]
            if it.kind == "bool" then return (v == 1) and "On" or "Off" end
            if it.kind == "choice" then return it.vals[v or 1] or "?" end
            if it.kind == "sensor" then return sensor_pick_label(v) end
            if it.kind == "switch" then
                -- fallback-only readout (the native picker renders its own text):
                -- signed source index -> source name, "!" marks the inverted pick
                v = v or 0
                if v == 0 then return "Off" end
                local okn, n = pcall(getSourceName, math.abs(v))
                local name = (okn and n) and n or tostring(math.abs(v))
                return (v < 0) and ("!" .. name) or name
            end
            v = v or it.min or 0
            if it.fmt then return it.fmt(v) end
            return tostring(v)
        end

        if it.kind == "info" then
            -- non-interactive hint line: muted, small font, wraps to ~2 lines
            elems[#elems + 1] = { type = "label", x = 10, y = ry + 2, w = right - 10, h = info_h - 4,
                                  text = it.lbl, font = SMLSIZE,
                                  color = COLOR_THEME_DISABLED or COLOR_THEME_SECONDARY1 }
        elseif it.kind == "slider" then
            -- name + reactive % + real LVGL slider (pg:slider — verified 2.12: h is
            -- ignored, w sets the length). Falls back to a -/+ stepper if the
            -- firmware lacks the slider control.
            local sl_w = math.min(300, math.floor(w * 0.40))
            local sl_x = right - sl_w
            local val_w2 = 66
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = sl_x - val_w2 - 16, h = 22,
                                  text = it.lbl, color = COLOR_THEME_PRIMARY1 }
            elems[#elems + 1] = { type = "label", x = sl_x - val_w2 - 6, y = ry + lbl_dy, w = val_w2, h = 22,
                                  text = value_text, color = COLOR_THEME_PRIMARY1, align = RIGHT }
            local function set_val(v)
                if it.step and it.step > 1 then v = math.floor(v / it.step + 0.5) * it.step end
                if v < it.min then v = it.min elseif v > it.max then v = it.max end
                working[it.key] = v
            end
            local oksl = pcall(function()
                pg:slider({ x = sl_x, y = field_y(ry), w = sl_w, min = it.min, max = it.max,
                    get = function() return working[it.key] or it.def or it.min end,
                    set = set_val })
            end)
            if not oksl then
                local btn_x2 = right - btn_w
                local btn_x1 = btn_x2 - btn_w - 8
                elems[#elems + 1] = { type = "button", x = btn_x1, y = ry, w = btn_w, h = row_h - 6, text = "-",
                                      press = function() set_val((working[it.key] or it.min) - it.step) end,
                                      longpress = function() set_val((working[it.key] or it.min) - (it.big or it.step)) end }
                elems[#elems + 1] = { type = "button", x = btn_x2, y = ry, w = btn_w, h = row_h - 6, text = "+",
                                      press = function() set_val((working[it.key] or it.min) + it.step) end,
                                      longpress = function() set_val((working[it.key] or it.min) + (it.big or it.step)) end }
            end
        elseif is_num then
            -- [-] [reactive value] [+]
            local btn_x2 = right - btn_w
            local btn_x1 = btn_x2 - val_w - btn_w - 8
            local val_x  = btn_x1 + btn_w + 4
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = val_x - 14, h = 22,
                                  text = it.lbl, color = COLOR_THEME_PRIMARY1 }
            elems[#elems + 1] = { type = "label", x = val_x, y = ry + lbl_dy, w = val_w, h = 22,
                                  text = value_text, color = COLOR_THEME_PRIMARY1, align = CENTER }
            local function adjust(delta)
                local v = (working[it.key] or it.min or 0) + delta
                if v < it.min then v = it.min elseif v > it.max then v = it.max end
                working[it.key] = v
            end
            elems[#elems + 1] = { type = "button", x = btn_x1, y = ry, w = btn_w, h = row_h - 6, text = "-",
                                  press = function() adjust(-it.step) end,
                                  longpress = function() adjust(-(it.big or it.step)) end }
            elems[#elems + 1] = { type = "button", x = btn_x2, y = ry, w = btn_w, h = row_h - 6, text = "+",
                                  press = function() adjust(it.step) end,
                                  longpress = function() adjust(it.big or it.step) end }
        elseif it.kind == "bool" then
            -- real toggle switch (works in fullscreen widgets despite the docs'
            -- one-time-only note — verified in the 2.12 source: no script-type
            -- guard); pcall'd with the old cycle-button as fallback
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = right - 110, h = 22,
                                  text = it.lbl, color = COLOR_THEME_PRIMARY1 }
            local okt = pcall(function()
                pg:toggle({ x = right - 90, y = ry + 4,
                    get = function() return working[it.key] == 1 end,
                    set = function(v) working[it.key] = (v == 1 or v == true) and 1 or 0 end })
            end)
            if not okt then
                elems[#elems + 1] = { type = "button", x = right - 100, y = ry, w = 100, h = row_h - 6,
                                      text = value_text,
                                      press = function() working[it.key] = (working[it.key] == 1) and 0 or 1 end }
            end
        elseif it.kind == "switch" then
            -- NATIVE switch selection: lvgl.source picker filtered to switches +
            -- logical switches, with the popup's own inverted entries ("!SA") and
            -- clear ("---"). Exchanges a SIGNED source index (verified on hardware:
            -- negative = inverted, 0 = none); the control renders the current name
            -- itself, incl. user-customized switch names, and lists ONLY switches
            -- this radio actually has.
            local cyc_w = 140
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = right - cyc_w - 24, h = 22,
                                  text = it.lbl, color = COLOR_THEME_PRIMARY1 }
            local oks = pcall(function()
                local filt = (lvgl.SRC_SWITCH or 0) | (lvgl.SRC_LOGICAL_SWITCH or 0)
                    | (lvgl.SRC_INVERT or 0) | (lvgl.SRC_CLEAR or 0)
                pg:source({ x = right - cyc_w, y = field_y(ry), w = cyc_w, h = field_h,
                    filter = filt,
                    get = function() return working[it.key] or 0 end,
                    set = function(v) working[it.key] = v or 0 end })
            end)
            if not oks then
                -- pre-2.12 firmware without lvgl.source: read-only display (the
                -- legacy hand-built list was removed with the code migration)
                elems[#elems + 1] = { type = "label", x = right - cyc_w - 80, y = ry + lbl_dy, w = cyc_w + 80, h = 22,
                                      text = value_text, color = COLOR_THEME_WARNING, align = RIGHT }
            end
        elseif it.kind == "sensor" then
            -- DECOUPLED two-field sensor selection, both writing the SAME slot
            -- (stored as the sensor NAME string; downstream is unchanged):
            --  * curated dropdown: Off + smart-voltage + ESC load + the model's
            --    KNOWN sensors (friendly labels) + one "‹ Raw ›" state entry.
            --  * native raw field: EdgeTX's own telemetry source popup. Picking a
            --    source stores its NAME (getSourceName) -> the dropdown flips to
            --    ‹ Raw › (via is_raw_sensor), the raw field shows the source.
            -- The two never both show a value: a curated pick -> raw field "---";
            -- a raw pick -> dropdown "‹ Raw ›". Raw names are NOT folded into the
            -- curated list (that keeps it short — the whole point).
            local raw_w = (w < 600) and 84 or 110
            local cyc_w = (w < 600) and math.floor(w * 0.34) or 170
            local cap = math.floor(w * 0.40)
            if cyc_w > cap then cyc_w = cap end
            local cyc_x = right - raw_w - 6 - cyc_w
            -- Shadow key <key>Raw: the raw picker's OWN source index. getSourceName
            -- (the stored name) does NOT round-trip back through getFieldInfo to the
            -- picker's index space, so the field cannot redisplay a pick from the
            -- name alone. The index is persisted alongside the name and VERIFIED
            -- against getSourceName on read (a firmware/model change that shifts
            -- indices falls back to "---" instead of showing a wrong source).
            local raw_key = it.key .. "Raw"
            local function cur_index()
                local v = working[it.key] or SENSOR_OFF
                if is_raw_sensor(v) then return se_raw_idx end   -- raw pick -> ‹ Raw ›
                for ci = 1, #se_codes do
                    if se_codes[ci] == v then return ci end
                end
                return 1
            end
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = cyc_x - 14, h = 22,
                                  text = it.lbl, color = COLOR_THEME_PRIMARY1 }
            local oks = pcall(function()
                pg:choice({ x = cyc_x, y = field_y(ry), w = cyc_w, h = field_h,
                    title = it.lbl, values = se_labels,
                    get = cur_index,
                    set = function(ci)
                        local code = se_codes[ci] or SENSOR_OFF
                        -- ‹ Raw › is display-only: keep the current raw pick, don't
                        -- overwrite it (the raw sensor is chosen in the raw field)
                        if code == RAW_SENTINEL then return end
                        working[it.key] = code
                    end })
            end)
            if not oks then
                elems[#elems + 1] = { type = "button", x = cyc_x, y = field_y(ry), w = cyc_w, h = field_h,
                                      text = value_text,
                                      press = function()
                                          local ci = cur_index() % #se_codes + 1
                                          local code = se_codes[ci]
                                          if code ~= RAW_SENTINEL then working[it.key] = code end
                                      end }
            end
            -- raw source field (2.12 lvgl.source; silently absent on older firmware —
            -- the curated dropdown keeps working alone). Shows a source ONLY while the
            -- slot holds a raw pick; curated picks (Off/auto/calc/known) render "---".
            pcall(function()
                pg:source({ x = right - raw_w, y = field_y(ry), w = raw_w, h = field_h,
                    filter = (lvgl.SRC_TELEM or 0) | (lvgl.SRC_CLEAR or 0),
                    get = function()
                        local nm = working[it.key]
                        if not is_raw_sensor(nm) then return 0 end   -- curated -> "---"
                        local idx = working[raw_key]
                        if type(idx) == "number" and idx ~= 0 then
                            local okn, n = pcall(getSourceName, idx)
                            if okn and n == nm then return idx end   -- verified
                        end
                        return 0   -- unknown/shifted index -> "---" (value still works)
                    end,
                    set = function(v)
                        if v == nil or v == 0 then
                            working[it.key] = SENSOR_OFF
                            working[raw_key] = 0
                            return
                        end
                        local okn, n = pcall(getSourceName, v)
                        if okn and type(n) == "string" and n ~= "" then
                            working[it.key] = n   -- dropdown reactively flips to ‹ Raw ›
                            working[raw_key] = v  -- persisted; redisplay after restart
                        end
                    end })
            end)
        else
            -- real dropdown (lvgl.choice popup picker, 1-based indices like our
            -- CHOICE values); width follows the longest value text
            local cyc_w = 100
            for vi = 1, #it.vals do
                local tw = lcd.sizeText(it.vals[vi], 0)
                if tw + 40 > cyc_w then cyc_w = tw + 40 end
            end
            local cap = math.floor(w * 0.45)
            if cyc_w > cap then cyc_w = cap end
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = right - cyc_w - 24, h = 22,
                                  text = it.lbl, color = COLOR_THEME_PRIMARY1 }
            local okc = pcall(function()
                pg:choice({ x = right - cyc_w, y = field_y(ry), w = cyc_w, h = field_h,
                    title = it.lbl, values = it.vals,
                    get = function() return working[it.key] or 1 end,
                    set = function(i) working[it.key] = i end })
            end)
            if not okc then
                elems[#elems + 1] = { type = "button", x = right - cyc_w, y = field_y(ry), w = cyc_w, h = field_h,
                                      text = value_text,
                                      press = function() working[it.key] = ((working[it.key] or 1) % #it.vals) + 1 end }
            end
        end
        ry = ry + row_this
    end

    -- Per-page reset: restores ONLY this page's keys to their defaults (the settings
    -- menu's "Reset to defaults" wipes the whole model instead). Mutates the working
    -- copy; the reactive rows/toggles/pickers reflect it at once and the autosave on
    -- exit persists it. Confirmed via lvgl.confirm when available (plain reset otherwise).
    local function reset_group()
        for i = 1, #grp.items do
            if grp.items[i].key then working[grp.items[i].key] = grp.items[i].def end
        end
    end
    local reset_y = ry + 8
    -- Width tracks the label: a fixed 260 px clipped the longer group names ("Reset Tele
    -- Details to defaults" / "Reset Thresholds to defaults") on both sides because the
    -- button text is centered. Measure it (project rule: never assume font widths) and grow
    -- up to w-20, keeping 260 as a floor so short labels stay visually consistent.
    local reset_text = "Reset " .. grp.name .. " to defaults"
    local reset_tw = lcd.sizeText(reset_text, 0)   -- 0 = STDSIZE, the build-table button font
    local reset_w = math.max(260, math.min(w - 20, reset_tw + 28))
    elems[#elems + 1] = { type = "button", x = 10, y = reset_y, w = reset_w, h = row_h - 6,
        text = reset_text,
        press = function()
            local ok = pcall(function()
                lvgl.confirm({ title = "Reset " .. grp.name,
                               message = "Reset this page to defaults?",
                               confirm = reset_group })
            end)
            if not ok then reset_group() end
        end }
    pg:build(elems)
end

-- Lay out menu buttons as a centered multi-column grid (RF2-Lua look) instead of
-- single full-width buttons, which looked "stretched" on the wide 800x480 TX16S.
-- The block is horizontally centered; cols/optional max width keep the buttons a
-- sensible size on both radios. Vertically centered within the page content area.
local function build_menu_grid(pg, w, h, items, cols, max_btn_w)
    local big = h >= 300
    local gap = big and math.max(10, math.floor(h * 0.02)) or 6
    local row_h = big and math.max(44, math.floor(h * 0.12)) or 36
    local btn_font = big and MIDSIZE or 0   -- 0 = STDSIZE (default)
    local side = math.max(16, math.floor(w * 0.05))
    local btn_w = math.floor((w - 2 * side - (cols - 1) * gap) / cols)
    if max_btn_w and btn_w > max_btn_w then btn_w = max_btn_w end
    local grid_w = cols * btn_w + (cols - 1) * gap
    local x0 = math.floor((w - grid_w) / 2)
    local rows = math.ceil(#items / cols)
    local grid_h = rows * row_h + (rows - 1) * gap
    -- page header (title + subtitle) eats the top of the zone; center in what's left
    local header_px = big and 56 or 40
    local y0 = math.max(big and 10 or 6, math.floor((h - header_px - grid_h) / 2))
    local elems = {}
    for i = 1, #items do
        local c = (i - 1) % cols
        local r = math.floor((i - 1) / cols)
        elems[#elems + 1] = { type = "button",
            x = x0 + c * (btn_w + gap), y = y0 + r * (row_h + gap),
            w = btn_w, h = row_h, text = items[i].txt, font = btn_font, press = items[i].act }
    end
    pg:build(elems)
end

--- Entry menu shown when tapping the fullscreen menu glyph — a general hub in
--- front of the settings. The configuration groups live one level deeper, under
--- "Settings" (build_settings_menu_view). Back/RTN = dashboard.
local function build_menu_view(wgt, zone)
    local pg = lvgl.page({
        title = "UltiDash",
        subtitle = "Menu",
        back = function()
            wgt.menu_view = nil
            init_view_state(wgt).dirty = true
        end,
    })

    local function open(view)
        return function()
            wgt.menu_view = view
            init_view_state(wgt).dirty = true
        end
    end

    -- single column, capped width so the buttons aren't stretched across the 800 px
    -- TX16S; the group list opens under "Settings"
    build_menu_grid(pg, zone.w, zone.h, {
        { txt = "Settings", act = open("settings_menu") },
        { txt = "Status",   act = open("status") },
        { txt = "Toolbox",  act = open("toolbox") },
    }, 1, (zone.h >= 300) and 460 or nil)
end

--- Toolbox submenu: on-demand tool pages (RF adjustment map / editor). Opened from the
--- main menu's "Toolbox" entry; back/RTN returns there. The tool pages themselves are
--- drawn by the modular tool modules (tb_adjmap / tb_adjed) and stay open across arming
--- (in-flight tuning is the point), unlike the rest of the menu.
local function build_toolbox_menu_view(wgt, zone)
    local pg = lvgl.page({
        title = "UltiDash",
        subtitle = "Toolbox",
        back = function()
            wgt.menu_view = "menu"
            init_view_state(wgt).dirty = true
        end,
    })
    local function open(view)
        return function()
            wgt.menu_view = view
            init_view_state(wgt).dirty = true
        end
    end
    build_menu_grid(pg, zone.w, zone.h, {
        { txt = "Adjust Map",  act = open("tb_adjmap") },
        { txt = "Adjust Edit", act = open("tb_adjed") },
    }, 1, (zone.h >= 300) and 460 or nil)
end

--- Settings submenu: the configuration groups (Display / Values / ... ) plus the
--- reset action, laid out as a 2-column grid (RF2-Lua look). Opened from the main
--- menu's "Settings" entry; back/RTN returns there.
local function build_settings_menu_view(wgt, zone)
    local pg = lvgl.page({
        title = "UltiDash",
        subtitle = "Settings",
        back = function()
            wgt.menu_view = "menu"
            init_view_state(wgt).dirty = true
        end,
    })

    -- one button per settings group: direct, named entry. A normal group opens its
    -- page; a group with a submenu (Alerts) opens the alert-picker instead.
    local function open_group(gi)
        return function()
            local grp = SETTINGS_GROUPS[gi]
            if grp.submenu then
                wgt.menu_view = "alerts_menu"
            else
                wgt.settings_page = { name = grp.name, items = grp.items, back = "settings_menu" }
                wgt.menu_view = "settings"
            end
            init_view_state(wgt).dirty = true
        end
    end

    local function reset_defaults()
        local function do_reset()
            if not ultidash_settings.reset() then
                ultidash_functions.log("settings reset FAILED (cfg file not writable)")
            end
            ultidash_settings.apply(wgt)
            wgt.settings_working = nil
            init_view_state(wgt).dirty = true
        end
        -- confirmation dialog when available; plain reset otherwise
        local ok = pcall(function()
            lvgl.confirm({ title = "Reset settings",
                           message = "Reset ALL settings of this model to defaults?",
                           confirm = do_reset })
        end)
        if not ok then do_reset() end
    end

    local items = {}
    for gi = 1, #SETTINGS_GROUPS do
        items[#items + 1] = { txt = SETTINGS_GROUPS[gi].name, act = open_group(gi) }
    end
    items[#items + 1] = { txt = "Reset to defaults", act = reset_defaults }
    build_menu_grid(pg, zone.w, zone.h, items, 2)
end

--- Alerts submenu: one button per alert sub-page ("Voice / mute" + each alert).
--- Opened from the settings submenu's "Alerts" entry; back/RTN returns there. Each
--- entry opens that page via build_settings_view (its back returns here).
local function build_alerts_menu_view(wgt, zone)
    local pg = lvgl.page({
        title = "UltiDash",
        subtitle = "Alerts",
        back = function()
            wgt.menu_view = "settings_menu"
            init_view_state(wgt).dirty = true
        end,
    })
    local function open_page(page)
        return function()
            wgt.settings_page = { name = page.name, items = page.items, back = "alerts_menu" }
            wgt.menu_view = "settings"
            init_view_state(wgt).dirty = true
        end
    end
    local items = {}
    for p = 1, #ALERT_PAGES do
        items[#items + 1] = { txt = ALERT_PAGES[p].name, act = open_page(ALERT_PAGES[p]) }
    end
    build_menu_grid(pg, zone.w, zone.h, items, 2)
end

--- Battery-profile picker — opened by tapping the B-Profile field (DISARMED only).
--- Lists the 6 battery profiles with their per-profile capacity (when the FC reports
--- it) and switches the active one through the RFTool MSP API (write MSP 176, persist
--- without reboot, then re-read). Read-side stays as-is; this is the one place the
--- widget WRITES to the FC, and only when disarmed. Back/RTN returns to the dashboard.
local function build_battprofile_view(wgt, zone)
    local pg = lvgl.page({
        title = "Battery profile",
        subtitle = "select active profile",
        back = function()
            wgt.menu_view = nil
            init_view_state(wgt).dirty = true
        end,
    })
    local w, h = zone.w, zone.h
    -- always-fresh active index (0-based; -1 / nil = unknown) — refreshed by the
    -- on-open MSP read so it reflects the FC's real current profile
    local active = wgt.values.rf_battery_profile_active

    -- 2-column grid of 6 tall buttons; each button is TWO lines — "Profile N" on top
    -- and its capacity below ("1800 mAh", or "undefined" when the profile has none).
    -- Two lines keep the capacity from clipping (single line overflowed the button).
    local cols, gap = 2, 10
    local _, fh = lcd.sizeText("Ag", 0)            -- STDSIZE line height (device-correct)
    local row_h = 2 * fh + 18                       -- room for two lines + padding
    local side = math.max(16, math.floor(w * 0.05))
    local btn_w = math.floor((w - 2 * side - (cols - 1) * gap) / cols)
    local grid_w = cols * btn_w + (cols - 1) * gap
    local x0 = math.floor((w - grid_w) / 2)
    local rows = 3
    local grid_h = rows * row_h + (rows - 1) * gap
    local header_px = (h >= 300) and 56 or 40       -- page header eats the top
    local y0 = math.max((h >= 300) and 10 or 6, math.floor((h - header_px - grid_h) / 2))

    local elems = {}
    for i = 0, 5 do
        local c = i % cols
        local r = math.floor(i / cols)
        local cap = rf_service.get_profile_capacity(wgt, i)
        local line1 = (active == i and "> " or "") .. "Profile " .. (i + 1)
        local line2 = (cap and cap > 0) and (cap .. " mAh") or "undefined"
        elems[#elems + 1] = { type = "button",
            x = x0 + c * (btn_w + gap), y = y0 + r * (row_h + gap),
            w = btn_w, h = row_h, font = 0, text = line1 .. "\n" .. line2,
            press = function()
                rf_service.set_battery_profile(wgt, i)
                wgt.menu_view = nil
                init_view_state(wgt).dirty = true
            end }
    end
    pg:build(elems)
end

--- Build the flight dashboard layout for the current widget zone.
local function build_flight_ui(wgt, zone)
    local w = zone.w
    local h = zone.h

    local h_status = math.floor(h * 0.075)
    local h_top = h_status
    local status_box_h = math.max(1, h_status - 2)
    local top_box_h = math.max(1, h_top - 2)
    local outer_pad = 2

    header_font = select_font(status_box_h, nil, nil)
    header_h = measure_font(header_font)

    local content_w = w - 2 * outer_pad
    local content_h = h - h_top - h_status - 2 * card_gap - 2 * outer_pad
    local y_content = outer_pad + h_top + card_gap
    local y_status = y_content + content_h + card_gap

    local w_fuel = math.max(46, math.floor(content_w * 0.20))
    local remaining_w = content_w - w_fuel - 2 * card_gap
    local w_left = math.floor(remaining_w / 2)
    local w_right = remaining_w - w_left
    local x_fuel = outer_pad + w_left + card_gap
    local x_right = x_fuel + w_fuel + card_gap

    wgt.status_bar_elements = nil
    wgt.status_bar_state = nil

    local main_panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG, filled = force_bg_fill or (wgt.options.BGFilled == 1) })

    -- top bar (date/time + radio battery)
    local top_bar_box = main_panel:box({ x = 0, y = outer_pad, w = w - 4, h = top_box_h })
    build_top_bar_element(top_bar_box, wgt, 0, 0, w - 4, top_box_h)
    main_panel:hline({ y = y_content - 1, w = w - 3, h = 1, color = COLOR_THEME_SECONDARY1 })

    build_flight_status_panel(main_panel, wgt, outer_pad, y_content, w_left, content_h)
    build_vertical_fuel_gauge_element(main_panel, wgt, x_fuel, y_content, w_fuel, content_h)
    -- tapping the gauge (fullscreen) opens the battery detail page
    wgt.battery_rect = { x = x_fuel, y = y_content, w = w_fuel, h = content_h }
    build_flight_values_panel(main_panel, wgt, x_right, y_content, w_right, content_h)
    -- tapping the values panel (fullscreen) opens the Telemetry detail page
    wgt.values_rect = { x = x_right, y = y_content, w = w_right, h = content_h }

    main_panel:hline({ y = y_status - 1, w = w - 3, h = 1, color = COLOR_THEME_SECONDARY1 })

    local status_bar_box = main_panel:box({ x = 0, y = y_status, w = w - 4, h = status_box_h })
    wgt.status_bar_box = status_bar_box
    wgt.status_bar_dims = { x = 0, y = 0, w = w - 4, h = status_box_h }

    build_status_bar_element(status_bar_box, wgt, 0, 0, w - 4, status_box_h)

    -- first-placement hint: all options live in the fullscreen menu, which a new
    -- user cannot know — a clear centered overlay window (built last = on top),
    -- shown until the menu was opened once (SetupSeen, persisted). The box's
    -- reactive `visible` hides all children with it.
    -- IMPORTANT: drawn as plain build-table primitives on the panel, NOT an
    -- lvgl.box — boxes built while fullscreen keep LV_OBJ_FLAG_CLICKABLE (the old
    -- touch root cause) and a centered box swallowed every tap on the screen
    -- middle (status line, stats dismiss) while the hint was visible.
    local function hint_visible() return (wgt.options.SetupSeen or 0) ~= 1 end
    local hint_w = math.floor(w * 0.74)
    local hint_h = math.max(88, math.floor(h * 0.34))
    local hx = math.floor((w - hint_w) / 2)
    local hy = math.floor((h - hint_h) / 2)
    local line_h = math.floor((hint_h - 12) / 4)
    main_panel:build({
        { type = "rectangle", x = hx, y = hy, w = hint_w, h = hint_h, filled = true, rounded = 6, color = PANEL_BG, visible = hint_visible },
        { type = "rectangle", x = hx, y = hy, w = hint_w, h = hint_h, thickness = 2, rounded = 6, color = COLOR_THEME_WARNING, visible = hint_visible },
        { type = "label", x = hx + 10, y = hy + 6, w = hint_w - 20, h = line_h,
          text = "UltiDash setup", font = MIDSIZE, color = COLOR_THEME_PRIMARY1, align = CENTER, visible = hint_visible },
        { type = "label", x = hx + 10, y = hy + 6 + line_h, w = hint_w - 20, h = line_h,
          text = "All settings live in the widget menu:", color = COLOR_THEME_PRIMARY1, align = CENTER, visible = hint_visible },
        { type = "label", x = hx + 10, y = hy + 6 + 2 * line_h, w = hint_w - 20, h = line_h,
          text = "long-press > Full screen,", color = COLOR_THEME_PRIMARY1, align = CENTER, visible = hint_visible },
        { type = "label", x = hx + 10, y = hy + 6 + 3 * line_h, w = hint_w - 20, h = line_h,
          text = "then tap the menu symbol (top left)", color = COLOR_THEME_PRIMARY1, align = CENTER, visible = hint_visible },
    })
end

--- Build the statistics dashboard layout for the current widget zone.
local function build_stats_ui(wgt, zone)
    local w = zone.w
    local h = zone.h
    local stats_content_w = math.max(1, w - 1)
    local info_content_w = math.max(1, stats_content_w - 1)

    local line_h = 1
    local h_status = math.floor(h * 0.075)
    local h_top = h_status
    local status_box_h = math.max(1, h_status - 2)
    local top_box_h = math.max(1, h_top - 2)

    header_font = select_font(status_box_h, nil, nil)
    header_h = measure_font(header_font)

    local y_content = h_top + line_h
    local content_h = h - h_top - h_status - 3 * line_h
    -- slim single info line (was a 3-card band Flight Time / mAh Used / Batt
    -- Profile: the profile is not useful here and the cards ate ~16% height;
    -- the freed space hosts the per-profile headspeed rows in the table)
    local h_info = header_h + 6
    local h_mid = content_h - h_info

    local y_info = y_content + h_mid + line_h
    local y_status = y_info + h_info + line_h

    wgt.status_bar_elements = nil
    wgt.status_bar_state = nil

    local main_panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG, filled = force_bg_fill or (wgt.options.BGFilled == 1) })

    -- top bar (date/time + radio battery); no RQ/TQ on the stats page
    local top_bar_box = main_panel:box({ x = 0, y = 1, w = w - 4, h = top_box_h })
    build_top_bar_element(top_bar_box, wgt, 0, 0, w - 4, top_box_h, false)
    main_panel:hline({ y = y_content - line_h, w = w - 3, h = line_h, color = COLOR_THEME_SECONDARY1 })

    build_flight_statistics_element(main_panel, wgt, 0, y_content, stats_content_w, h_mid - line_h)

    main_panel:hline({ y = y_info - line_h, w = w - 3, h = line_h, color = COLOR_THEME_SECONDARY1 })

    -- one slim line: session flight time + used mAh (raw %)
    main_panel:label({ x = 0, y = y_info + 3, w = info_content_w, h = header_h,
        text = (function()
            -- inputs are memoized; memo the concat so the stats page (the default
            -- disconnected view) doesn't allocate this line on every frame
            local last_ft, last_bu, last_s
            return function()
                local ft = wgt.values.flight_time_str_formatted()
                local bu = wgt.values.battery_usage_summary_formatted()
                if ft ~= last_ft or bu ~= last_bu then
                    last_ft, last_bu = ft, bu
                    last_s = wgt.values.label_flight_time .. "  " .. ft
                        .. "        " .. wgt.values.label_capacity_used_short .. "  " .. bu
                end
                return last_s
            end
        end)(),
        font = header_font, color = COLOR_THEME_PRIMARY1, align = CENTER })

    main_panel:hline({ y = y_status - line_h, w = w - 3, h = line_h, color = COLOR_THEME_SECONDARY1 })

    local status_bar_box = main_panel:box({ x = 0, y = y_status, w = w - 4, h = status_box_h })
    wgt.status_bar_box = status_bar_box
    wgt.status_bar_dims = { x = 0, y = 0, w = w - 4, h = status_box_h }

    build_status_bar_element(status_bar_box, wgt, 0, 0, w - 4, status_box_h)
end

--- Rebuild the widget UI for the active view and current options.
local function update(wgt, options)
    if (wgt == nil) then return end
    prepare_widget(wgt)
    wgt.options = options
    -- overlay the per-model settings file onto the EdgeTX options (file wins for
    -- saved keys; no file = pure EdgeTX behavior). ViewMode is never overridden.
    ultidash_settings.apply(wgt)
    -- diagnostics: drive the optional file logger from the per-model DebugLog option.
    -- Publisher only (it owns telemetry/state logging); no-op without ultidashDebug.lua.
    if is_publisher(wgt) and ultidash_functions.dbg then
        ultidash_functions.dbg.set_enabled(wgt.options.DebugLog == 1, wgt.options.DebugKeep)
    end
    -- One-time migration: when no per-model file exists yet, snapshot the current
    -- effective option values into it. Only the Dashboard placement does this (its
    -- options carry the user's tuning; passive instances may sit at defaults).
    -- Prerequisite for eventually shrinking the EdgeTX option list to ViewMode.
    -- DEFERRED to a refresh() cycle of its own: EdgeTX gives each widget call a
    -- 20k-instruction budget (lua_widget.cpp MAX_INSTRUCTIONS), and snapshot +
    -- cfg file write on top of the full UI build in this same call blew it
    -- ("CPU limit" mid-build).
    if is_publisher(wgt) and ultidash_settings.load() == nil then
        wgt.cfg_snapshot_pending = true
    end


    local mode = options.ViewMode or VIEW_MODE_DASHBOARD

    -- apply the chosen color palette to all modules before (re)building the UI.
    -- Passive views inherit the DASHBOARD's published scheme ("the main widget is
    -- the boss"); their own ColorScheme option only matters while no Dashboard runs.
    local scheme = options.ColorScheme or 1   -- 1 = UltiDash, 2 = EdgeTX theme, 3 = dark
    if mode ~= VIEW_MODE_DASHBOARD and ultidash_functions.shared_alive() then
        scheme = ultidash_functions.get_shared().color_scheme or scheme
    end
    -- The in-widget menu / settings pages are native lvgl.page objects: their chrome
    -- (background, scrollbar) follows the EdgeTX theme, which we cannot repaint. On the
    -- dark scheme our white label text would sit on that light page and be unreadable,
    -- so render those native-page views with the EdgeTX-theme palette instead. The
    -- dashboard and the detail pages (our own dark panels) keep the dark scheme.
    local render_scheme = scheme
    if scheme == 3 and wgt.menu_view ~= nil then render_scheme = 2 end
    set_palette(render_scheme)
    ultidash_functions.set_palette(render_scheme)
    ultidash_values.set_palette(render_scheme)
    -- palette for the Toolbox tool pages: use the REAL scheme (not the forced render_scheme)
    -- so the tools match the dashboard look (black+neon on dark, etc.)
    wgt.tb_pal = toolbox_palette(scheme)

    lvgl.clear()
    -- everything lvgl is gone now — drop the cached element references so nothing
    -- (e.g. update_status_bar_visibility) touches a cleared object ("Invalid object"
    -- error). The flight/stats builders repopulate them; the other views have none.
    wgt.status_bar_elements = nil
    wgt.status_bar_state = nil
    wgt.status_bar_box = nil
    -- tap-target rects: only the builders that exist in the new layout re-set them
    wgt.estatus_rect = nil
    wgt.elrs_bar_rect = nil
    wgt.settings_icon_rect = nil
    wgt.battery_rect = nil
    wgt.values_rect = nil
    wgt.battprofile_rect = nil

    -- dispatch by ViewMode: Dashboard keeps the flight/stats switching; the passive
    -- modes render their dedicated single view (no stats page, no status bar).
    if mode == VIEW_MODE_ELRS then
        build_elrs_view(wgt, wgt.zone)
    elseif mode == VIEW_MODE_STATUS then
        build_status_view(wgt, wgt.zone)
    elseif wgt.menu_view == "settings" then
        build_settings_view(wgt, wgt.zone)
    elseif wgt.menu_view == "alerts_menu" then
        build_alerts_menu_view(wgt, wgt.zone)
    elseif wgt.menu_view == "settings_menu" then
        -- settings submenu: the configuration groups (one level under the hub)
        build_settings_menu_view(wgt, wgt.zone)
    elseif wgt.menu_view == "battprofile" then
        -- battery-profile picker (opened by tapping the B-Profile field, disarmed)
        build_battprofile_view(wgt, wgt.zone)
    elseif wgt.menu_view == "status" then
        build_status_view(wgt, wgt.zone, true)
    elseif wgt.menu_view == "menu" then
        -- in-widget menu hub (opened via the fullscreen menu glyph)
        build_menu_view(wgt, wgt.zone)
    elseif wgt.menu_view == "toolbox" then
        build_toolbox_menu_view(wgt, wgt.zone)
    elseif wgt.menu_view == "tb_adjmap" and tb_adjmap then
        tb_adjmap.build(wgt, wgt.zone)
    elseif wgt.menu_view == "tb_adjed" and tb_adjed then
        tb_adjed.build(wgt, wgt.zone)
    elseif wgt.detail_view == "elrs" and init_view_state(wgt).current == "flight" then
        -- Dashboard's own ELRS detail page (opened by tapping the top-bar bars)
        build_elrs_view(wgt, wgt.zone, true)
    elseif wgt.detail_view == "estatus" and init_view_state(wgt).current == "flight" then
        -- status detail page (opened by tapping the ESC/arming status line)
        build_estatus_view(wgt, wgt.zone)
    elseif wgt.detail_view == "battery" and init_view_state(wgt).current == "flight" then
        -- battery detail page (opened by tapping the center fuel gauge)
        build_battery_view(wgt, wgt.zone)
    elseif wgt.detail_view == "telem" and init_view_state(wgt).current == "flight" then
        -- telemetry detail page (opened by tapping the right value panel)
        build_telem_view(wgt, wgt.zone)
    elseif init_view_state(wgt).current == "flight" then
        build_flight_ui(wgt, wgt.zone)
    else
        build_stats_ui(wgt, wgt.zone)
    end
    init_view_state(wgt).dirty = false
    wgt.layout_dirty = false
    if mode == VIEW_MODE_DASHBOARD then
        -- Force status bar visibility update after UI rebuild
        update_status_bar_visibility(wgt, true)
    else
        -- remember what this build inherited from the Dashboard; refresh rebuilds
        -- when it changes (publisher appears/disappears, palette change)
        wgt.passive_style_sig = passive_style_sig()
    end
    return wgt
end

--- Create a NEW widget instance (own table per placement) and build its layout.
local function create(zone, options)
    local wgt = ultidash_values.createWidget()
    wgt.zone = zone
    wgt.options = options
    return update(wgt, options)
end

--- Run background RF and telemetry work that should not rebuild the UI.
--- Publisher only: passive instances (ELRS/Status) do no background work at all —
--- no MSP, no audio, no stats, no rf2 registration.
local function background(wgt)
    if not wgt then return end
    prepare_widget(wgt)
    if not is_publisher(wgt) then return end
    ensure_rf_service(wgt)
    rf_service.background(wgt, handle_telemetry_state_change)
    ultidash_functions.background_refresh(wgt)
    ultidash_functions.publish_shared(wgt)
end

--- Hit-test a touch point against a rect (with a generous margin for fat fingers).
local function rect_hit(ts, r, margin)
    if not r or not ts or ts.x == nil or ts.y == nil then return false end
    margin = margin or 8
    return ts.x >= r.x - margin and ts.x <= r.x + r.w + margin
       and ts.y >= r.y - margin and ts.y <= r.y + r.h + margin
end

--- Refresh live telemetry, switch views if needed, and rebuild only when dirty.
local function refresh(wgt, event, touch_state)
    if not wgt then return end
    prepare_widget(wgt)
    -- dev metrics (shown in the status detail footer): UI loop rate per second —
    -- the most honest "load" indicator (scheduler starvation = rate drops) — plus
    -- the Lua heap, sampled once per window
    local mnow = getTime() or 0
    wgt.dbg_calls = (wgt.dbg_calls or 0) + 1
    if mnow - (wgt.dbg_win or 0) >= 100 then
        wgt.dbg_hz = wgt.dbg_calls
        wgt.dbg_calls = 0
        wgt.dbg_win = mnow
        local okgc, kb = pcall(collectgarbage, "count")
        wgt.dbg_lua_kb = (okgc and type(kb) == "number") and math.floor(kb) or nil
        -- free heap headroom (getAvailableMemory, bytes) — so we can see the margin, not
        -- just the used total (dbg_lua_kb = collectgarbage count = whole-VM used)
        local okfm, fb = pcall(getAvailableMemory)
        wgt.dbg_free_kb = (okfm and type(fb) == "number") and math.floor(fb / 1024) or nil
    end
    -- Deferred one-time migration snapshot (flagged in update()): runs in its own
    -- refresh cycle so snapshot + cfg file write get a fresh 20k-instruction
    -- budget instead of sharing create()'s with the full UI build ("CPU limit").
    -- Skipping the rest of this one 20 Hz cycle is invisible. Re-check load():
    -- a menu autosave may have created the file meanwhile.
    if wgt.cfg_snapshot_pending then
        wgt.cfg_snapshot_pending = nil
        if ultidash_settings.load() == nil then
            local snap = {}
            for_each_setting_item(function(it)
                local k = it.key
                if k and type(wgt.options[k]) == "number" then snap[k] = wgt.options[k] end
            end)
            ultidash_settings.save(snap)
        end
        return
    end
    -- Rebuild ONCE after leaving fullscreen. Root cause (EdgeTX 2.12 source): lvgl.box
    -- containers keep LV_OBJ_FLAG_CLICKABLE when built while fullscreen (EdgeTX clears
    -- the flag only for widget-mode NON-fullscreen builds), and EdgeTX rebuilds the
    -- tree on fullscreen ENTER (updateWithoutRefresh) but NOT on exit — so the
    -- leftover clickable boxes swallow taps/long-press and the widget menu stops
    -- opening. Rebuilding outside fullscreen restores non-clickable boxes. We only
    -- OBSERVE the state — EdgeTX fully owns the enter/exit lifecycle (lesson learned:
    -- never intercept RTN / never call exitFullScreen here).
    local fs = (lvgl.isFullScreen ~= nil) and lvgl.isFullScreen() == true
    if wgt.was_fullscreen and not fs then
        wgt.was_fullscreen = false
        -- ELRS detail + menu/settings/status are fullscreen-only features (normal
        -- mode gets no touch), so leaving fullscreen always returns to the dashboard.
        -- Leaving with the settings page open DISCARDS unsaved edits (save = back/RTN).
        wgt.detail_view = nil
        save_pending_settings(wgt)
        wgt.menu_view = nil
        return update(wgt, wgt.options)
    end
    wgt.was_fullscreen = fs
    -- Fullscreen ELRS-detail taps (touch only reaches refresh while fullscreen):
    -- tap on the bar cluster opens the detail, any tap closes it again. Strictly the
    -- discrete EVT_TOUCH_TAP, plus a TIME-based cooldown: one physical tap often
    -- bounces into several TAP events (EdgeTX double-tap counting), which made the
    -- detail flicker open-closed-open. The cooldown expires by itself, so unlike the
    -- old state-based debounce it can never get stuck. No key/RTN interception —
    -- EdgeTX owns the fullscreen lifecycle.
    -- RTN navigates the menu pages even when NO control has focus: lvgl.page's
    -- built-in back catches RTN only while one of its controls is focused; with
    -- nothing focused the key arrives here as EVT_VIRTUAL_EXIT instead. Same
    -- semantics as each page's back arrow.
    -- RTN also closes the ELRS detail (alternative to tap-anywhere)
    if fs and wgt.detail_view ~= nil and wgt.menu_view == nil
        and EVT_VIRTUAL_EXIT ~= nil and event == EVT_VIRTUAL_EXIT then
        wgt.detail_view = nil
        init_view_state(wgt).dirty = true
    end
    if fs and wgt.menu_view ~= nil and EVT_VIRTUAL_EXIT ~= nil and event == EVT_VIRTUAL_EXIT then
        if wgt.menu_view == "settings" then
            close_settings(wgt)                   -- autosave, back to the group/alert list
        elseif wgt.menu_view == "alerts_menu" then
            wgt.menu_view = "settings_menu"       -- alert picker -> settings submenu
            init_view_state(wgt).dirty = true
        elseif wgt.menu_view == "settings_menu" or wgt.menu_view == "status"
            or wgt.menu_view == "toolbox" then
            wgt.menu_view = "menu"                -- submenu -> hub
            init_view_state(wgt).dirty = true
        elseif wgt.menu_view == "tb_adjmap" or wgt.menu_view == "tb_adjed" then
            wgt.menu_view = "toolbox"             -- tool page -> toolbox submenu
            init_view_state(wgt).dirty = true
        else
            wgt.menu_view = nil                   -- hub -> dashboard
            init_view_state(wgt).dirty = true
        end
    end
    -- Toolbox tool pages: run their state/touch/pulse every cycle while open (UltiDash's
    -- own tap zones below are gated to menu_view==nil, so no conflict). In-flight capable.
    if wgt.menu_view == "tb_adjmap" and tb_adjmap then
        wgt.tb_announce = ultidash_functions.tb_announce_pos
        tb_adjmap.refresh(wgt, event, touch_state)
    elseif wgt.menu_view == "tb_adjed" and tb_adjed then
        wgt.tb_announce = ultidash_functions.tb_announce_pos
        tb_adjed.refresh(wgt, event, touch_state)
    end
    if fs and is_publisher(wgt) and EVT_TOUCH_TAP ~= nil and event == EVT_TOUCH_TAP then
        local now = getTime() or 0
        -- Bounce protection, device-robust (the TX16S spreads bounce taps wider
        -- than the TX15, which re-flickered the detail open-closed-open):
        -- (a) multi-tap reports (tapCount > 1) are ignored outright;
        -- (b) ASYMMETRIC cooldown — a long 1 s block right after OPENING the detail
        --     (only "a tap instantly closes it again" causes the flicker; a
        --     deliberate close naturally comes later). The SAME 1 s now applies to
        --     close/dismiss actions too: the view changes under the finger, and a
        --     late bounce tap would otherwise click through onto whatever tap zone
        --     sits at the same spot in the NEW view (seen on hardware: stats
        --     dismiss opened the status detail, closing that opened the battery).
        -- No tap handling while a menu page is up — its lvgl page/buttons own the
        -- touch (closing goes through the page's back arrow / RTN).
        local tap_count = touch_state and touch_state.tapCount
        if (tap_count == nil or tap_count <= 1)
            and now >= (wgt.elrs_tap_block or 0) and wgt.menu_view == nil then
            if wgt.detail_view ~= nil then
                -- Status log scroll: taps on the ▲/▼ buttons scroll the log (short cooldown)
                -- and do NOT close; any other tap closes the detail (long cooldown).
                if wgt.detail_view == "estatus" and rect_hit(touch_state, wgt.estatus_scroll_up, 6) then
                    wgt.elrs_tap_block = now + 25
                    wgt.estatus_scroll = math.max(0, (wgt.estatus_scroll or 0) - 1)
                    init_view_state(wgt).dirty = true
                elseif wgt.detail_view == "estatus" and rect_hit(touch_state, wgt.estatus_scroll_down, 6) then
                    wgt.elrs_tap_block = now + 25
                    wgt.estatus_scroll = (wgt.estatus_scroll or 0) + 1
                    init_view_state(wgt).dirty = true
                else
                    wgt.elrs_tap_block = now + 100
                    wgt.detail_view = nil
                    init_view_state(wgt).dirty = true
                end
            elseif rect_hit(touch_state, wgt.settings_icon_rect, 10)
                and not (ultidash_functions.is_armed(wgt)
                    and wgt.values.rf_connection_state ~= "disconnected") then
                -- menu entry (menu glyph): blocked only while genuinely flying (armed AND
                -- still connected). After a main-power loss where telemetry has dropped, the
                -- ARM sensor holds a STALE "armed" for ~30 s — but with telemetry gone the
                -- craft is no longer flying, so the menu must open again (bug: menu was dead
                -- while detail pages still worked). No config in flight otherwise.
                wgt.elrs_tap_block = now + 100
                wgt.menu_view = "menu"
                -- acknowledge the first-placement hint banner (persisted)
                if (wgt.options.SetupSeen or 0) ~= 1 then
                    wgt.options.SetupSeen = 1
                    ultidash_settings.save({ SetupSeen = 1 })
                end
                init_view_state(wgt).dirty = true
            elseif init_view_state(wgt).current == "stats" then
                -- manual dismiss of the statistics page: any tap (outside the menu
                -- glyph) returns to the flight view; it reappears with the next
                -- arm/disarm or reconnect cycle (flags cleared there)
                wgt.elrs_tap_block = now + 100
                wgt.stats_dismissed = true
                init_view_state(wgt).dirty = true
            elseif rect_hit(touch_state, wgt.battprofile_rect, 6)
                and not ultidash_functions.is_armed(wgt)
                and wgt.rf and wgt.rf.msp_allowed then
                -- battery-profile picker: switches the active profile via RFTool MSP
                -- (a config WRITE → DISARMED ONLY; the FC also blocks writes while armed)
                wgt.elrs_tap_block = now + 100
                -- read the current profile/config fresh on open (disarmed, so MSP is
                -- allowed) — otherwise the picker shows a value cached at connect time
                rf_service.refresh_data(wgt)
                wgt.menu_view = "battprofile"
                init_view_state(wgt).dirty = true
            elseif wgt.options.TapDetails == 1 and rect_hit(touch_state, wgt.elrs_bar_rect, 10) then
                wgt.elrs_tap_block = now + 100   -- long: any tap closes, see above
                wgt.detail_view = "elrs"
                init_view_state(wgt).dirty = true
            elseif wgt.options.TapDetails == 1 and rect_hit(touch_state, wgt.estatus_rect, 6) then
                wgt.elrs_tap_block = now + 100
                wgt.detail_view = "estatus"
                wgt.estatus_scroll = 0
                init_view_state(wgt).dirty = true
            elseif wgt.options.TapDetails == 1 and rect_hit(touch_state, wgt.battery_rect, 6) then
                wgt.elrs_tap_block = now + 100
                wgt.detail_view = "battery"
                init_view_state(wgt).dirty = true
            elseif wgt.options.TapDetails == 1 and rect_hit(touch_state, wgt.values_rect, 6) then
                wgt.elrs_tap_block = now + 100
                wgt.detail_view = "telem"
                init_view_state(wgt).dirty = true
            end
        end
    end
    if not is_publisher(wgt) then
        -- passive view: sensor-only ELRS data (no MSP/audio/stats side effects);
        -- the Status view renders reactively straight from Shared. Same 5 Hz
        -- throttle as the publisher — no need to poll sensors every cycle.
        local tnow = getTime() or 0
        if (tnow - (wgt.telem_gate or 0)) >= 20 then
            wgt.telem_gate = tnow
            ultidash_functions.update_elrs(wgt)
        end
        -- follow the Dashboard: rebuild when the publisher appears/disappears or
        -- changes its palette/background (notice page <-> live view, look change)
        if wgt.passive_style_sig ~= passive_style_sig() then
            return update(wgt, wgt.options)
        end
        return
    end
    -- Toolbox activation switch: resolve its state (the tool pages' active gate reads
    -- wgt.tb_switch_on) and AUTO-OPEN the configured tool on the switch's rising edge /
    -- close on its falling edge. Works in flight (the menu glyph is disarmed-only; this is
    -- not). Edge-triggered so it doesn't fight manual navigation while the switch is held.
    do
        local code = wgt.options.TbSrc or 0
        if code ~= 0 then
            local on = ultidash_functions.switch_is_on(code)
            wgt.tb_switch_on = on
            local tool = wgt.options.TbTool or 1   -- 1=Off, 2=Map, 3=Editor
            if tool ~= 1 then
                local target = (tool == 2) and "tb_adjmap" or "tb_adjed"
                if on and not wgt.tb_switch_prev
                    and (wgt.menu_view == nil or wgt.menu_view == "toolbox") then
                    wgt.menu_view = target
                    wgt.tb_switch_opened = true
                    init_view_state(wgt).dirty = true
                elseif (not on) and wgt.tb_switch_prev and wgt.tb_switch_opened then
                    if wgt.menu_view == "tb_adjmap" or wgt.menu_view == "tb_adjed" then
                        wgt.menu_view = nil
                        init_view_state(wgt).dirty = true
                    end
                    wgt.tb_switch_opened = false
                end
            end
            wgt.tb_switch_prev = on
        else
            wgt.tb_switch_on = nil
            wgt.tb_switch_prev = nil
        end
    end
    -- THROTTLE the telemetry/alert/publish pass to 5 Hz: with a connected FC the
    -- full update (~35 sensor-name lookups) on EVERY display cycle starved the Lua
    -- scheduler enough that fullscreen taps became a lottery (RFTool works the CRSF
    -- link in parallel). 5 Hz is plenty for the display and for the alerts (their
    -- debounce windows are 0.5-3 s) — taps above are still handled every cycle.
    -- While a menu page / the ELRS detail is up, the dashboard isn't visible at
    -- all: skip the heavy pass entirely (status page reads Shared; the detail only
    -- needs the cheap update_elrs) so page interaction stays snappy.
    -- Idle throttle: run the heavy telemetry/alert/publish pass AND the RF-service
    -- housekeeping at 5 Hz while a FC is linked, but back off to 2 Hz when
    -- disconnected — with no craft every sensor read returns nil, so there is nothing
    -- to do 5x/s and the radio CPU can idle more (lower battery drain). State CHANGES
    -- still arrive immediately via the rf2 onStateChanged callback (independent of this
    -- cadence), so a connecting FC is picked up without extra delay.
    local tnow = getTime() or 0
    local gate_cs = (wgt.values.rf_connection_state ~= "disconnected") and 20 or 50
    if (tnow - (wgt.telem_gate or 0)) >= gate_cs then
        wgt.telem_gate = tnow
        ensure_rf_service(wgt)
        rf_service.background(wgt, handle_telemetry_state_change)
        -- FULL pass even while the detail/menu pages are up: all dashboard
        -- functions (alerts, stats, callouts) keep running in the background —
        -- the ELRS detail may now stay open in flight. The 5 Hz throttle keeps
        -- the interaction snappy regardless.
        local pass_t0 = getTime() or 0
        ultidash_functions.refresh(wgt)
        update_user_sensors(wgt)
        ultidash_functions.publish_shared(wgt)
        ultidash_functions.refresh_volume_override(wgt)   -- adaptive master volume via GVAR (off unless configured)
        wgt.dbg_pass_cs = (getTime() or 0) - pass_t0
        -- cache the armed state for reactive closures (they run per LVGL frame;
        -- calling is_armed there would be a sensor name-lookup at ~20 Hz)
        wgt.armed_now = ultidash_functions.is_armed(wgt)
        -- diagnostics: perf snapshot + buffered SD flush (no-op unless DebugLog is on)
        if ultidash_functions.dbg then ultidash_functions.dbg.tick(wgt) end
        -- "arming forgets the manual stats dismiss" — cleared ONLY on a genuine rising
        -- edge of the ARM telemetry sensor (a real new flight). The EdgeTX logs prove the
        -- ARM sensor is clean (1 -> 0, no flicker) even through a main-power-lost, whereas
        -- the connection sub-state is flaky; a level check or a connection-driven reset kept
        -- reopening the stats page after such an event. A telemetry dropout reads as "not
        -- armed" (arm_sensor_on -> false), so it can never be mistaken for an arm.
        local arm_on = ultidash_functions.arm_sensor_on(wgt)
        if arm_on and not wgt.was_armed_sensor then
            wgt.stats_dismissed = false
            if ultidash_functions.dbg then ultidash_functions.dbg.logf("STATS", "dismiss cleared (arm rising edge)") end
        end
        wgt.was_armed_sensor = arm_on
        if wgt.armed_now and wgt.values.rf_connection_state ~= "disconnected" then
            -- menu/settings/status close on arm (no configuring in flight; pending edits
            -- autosaved) — EXCEPT the Toolbox tool pages, which are meant for in-flight
            -- tuning (RF2 adjustment functions) and deliberately stay open while armed.
            -- The condition mirrors the menu-glyph OPEN gate (armed AND connected =
            -- genuinely flying): after a main-power loss with telemetry gone, the ARM
            -- sensor holds a stale "armed" for ~30 s — the open gate let the menu open
            -- in that window, but this close-on-arm then shut it again 200 ms later
            -- ("menu opens but won't stay open"). Disconnected = not flying -> keep it.
            local tb = (wgt.menu_view == "tb_adjmap" or wgt.menu_view == "tb_adjed")
            if wgt.menu_view ~= nil and not tb then
                save_pending_settings(wgt)
                wgt.menu_view = nil
                init_view_state(wgt).dirty = true
            end
            -- the ELRS detail only closes on arm when the option says so — with
            -- it off the pilot can deliberately watch the link details in flight
            -- (alerts keep running either way)
            if wgt.detail_view ~= nil and wgt.options.ArmClose == 1 then
                wgt.detail_view = nil
                init_view_state(wgt).dirty = true
            end
        end
    end
    -- a completed MSP read updates wgt.values.* (e.g. the battery-profile picker's
    -- on-open refresh); rebuild an open menu page so it reflects the fresh data. The
    -- dashboard itself is reactive and needs no rebuild.
    if wgt.rf_data_dirty then
        wgt.rf_data_dirty = false
        if wgt.menu_view ~= nil then init_view_state(wgt).dirty = true end
    end
    sync_view_for_telemetry(wgt)
    if init_view_state(wgt).dirty == true then
        return update(wgt, wgt.options)
    end
    update_status_bar_visibility(wgt)
end

return { create = create, update = update, background = background, refresh = refresh }
