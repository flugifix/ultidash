local script_dir = "/WIDGETS/UltiDash/"
local ultidash_functions = loadScript(script_dir .. "ultidashFunctions.lua")()
local ultidash_values = loadScript(script_dir .. "ultidashValues.lua")()
local rf_service = loadScript(script_dir .. "ultidashRf.lua")()
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

-- panel background used when BGFilled is on. For the Clean palette this is WHITE to match
-- the Clean theme's actual wallpaper (which is solid white, not SECONDARY3); for the EdgeTX
-- theme it follows SECONDARY3 as before.
local PANEL_BG = COLOR_THEME_SECONDARY3

local function set_palette(use_clean)
    local p = use_clean and CLEAN_PALETTE or THEME_PALETTE
    COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2 = p[1], p[2], p[3], p[4]
    COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS, COLOR_THEME_WARNING, COLOR_THEME_DISABLED = p[5], p[6], p[7], p[8]
    PANEL_BG = use_clean and lcd.RGB(0xFF, 0xFF, 0xFF) or THEME_PALETTE[5]
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
local SIM_VIEW_SWITCH_INTERVAL = 5 * 100

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

local wgt = ultidash_values.createWidget()

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
        return "flight"
    end
    if mode == STATS_VIEW_MODE_NEVER or view.ever_armed ~= true then
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
    return true
end

--- Propagate telemetry state changes to services and update the selected view.
local function handle_telemetry_state_change(widget, previous_state, new_state)
    ultidash_functions.on_telemetry_state_changed(widget, previous_state, new_state)
    sync_view_for_telemetry(widget)
end

--- Prepare a widget instance once and attach shared services and callbacks.
local function prepare_widget(widget)
    if not widget then return nil end
    if not widget.app_prepared then
        init_view_state(widget)
        rf_service.init(widget, handle_telemetry_state_change)
        widget.sync_active_battery_capacity = rf_service.sync_active_battery_capacity
        widget.app_prepared = true
    end
    return widget
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
    local rows = {
        {
            title = wgt.values.display_voltage_label_short,
            value = wgt.values.display_voltage_formatted,
            test = wgt.values.display_voltage_test(),
            color = wgt.values.display_voltage_color
        },
        { title = wgt.values.label_headspeed,       value = wgt.values.headspeed_formatted, test = "2999",  color = COLOR_THEME_PRIMARY1 },
        { title = wgt.values.label_current,         value = wgt.values.curr_formatted,      test = "999.9", color = COLOR_THEME_PRIMARY1 },
        { title = wgt.values.label_esc_temp,        value = wgt.values.esc_temp_formatted,  test = "120.0", color = COLOR_THEME_PRIMARY1 },
        { title = wgt.values.label_bec_voltage,     value = wgt.values.vbec_formatted,      test = "99.99", color = COLOR_THEME_PRIMARY1 }
    }
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

    -- ESC / arming status line (full width, colored; blank when all OK)
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
        wgt.values.label_battery_profile_short, wgt.values.rf_battery_profile_compact_formatted, battp_font, battp_font_h)

    build_card_element(container, x, y, c_w, c_h, status_children)

    container:hline({ x = x + pad, y = y + y_meta - 1, w = inner_w, h = 1, color = COLOR_THEME_SECONDARY1 })
    container:hline({ x = x + pad, y = y + y_gt - 1, w = inner_w, h = 1, color = COLOR_THEME_SECONDARY1 })
    container:hline({ x = x + pad, y = y + y_esc - 1, w = inner_w, h = 1, color = COLOR_THEME_SECONDARY1 })
    container:hline({ x = x + pad, y = y + y_grid - 1, w = inner_w, h = 1, color = COLOR_THEME_SECONDARY1 })
end

local function get_flight_statistics_rows(wgt)
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
        }, {
        label = wgt.values.label_headspeed,
        actual = wgt.values.headspeed_formatted,
        min = wgt.values.headspeed_min_formatted,
        max = wgt.values.headspeed_max_formatted,
        actualColor = COLOR_THEME_PRIMARY1,
        minColor = COLOR_THEME_PRIMARY1,
        maxColor = COLOR_THEME_PRIMARY1,
        test = "3200"
    }, {
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

    -- left: date + time
    local date_w = math.floor(c_w * 0.36)
    container:label({
        x = x + 1,
        y = y + y_off,
        w = date_w,
        h = font_h,
        text = function() return wgt.values.clock_date_formatted() .. "  " .. wgt.values.clock_time_formatted() end,
        font = header_font,
        color = COLOR_THEME_PRIMARY1,
        align = LEFT
    })

    -- display toggles (per options). RQ/TQ are suppressed entirely on the stats
    -- page (show_link == false) — there the link quality lives in the table/status
    -- bar and the momentary RQ/TQ would be misleading after disconnect.
    local show_rq  = show_link ~= false and wgt.options.ShowRQly == 1
    local show_tq  = show_link ~= false and wgt.options.ShowTQly == 1
    local show_txv = wgt.options.ShowTxV == 1

    -- center: ELRS link quality (RQly downlink + TQly uplink), each toggleable
    if show_rq or show_tq then
        local center_x = x + date_w + 4
        local center_right = show_txv and volt_text_x or icon_x
        local center_w = math.max(1, center_right - center_x - 4)
        container:label({
            x = center_x,
            y = y + y_off,
            w = center_w,
            h = font_h,
            text = function()
                local parts = {}
                if show_rq then parts[#parts + 1] = "RQ " .. wgt.values.rqly_cur_formatted() end
                if show_tq then parts[#parts + 1] = "TQ " .. wgt.values.tqly_cur_formatted() end
                return table.concat(parts, "  ")
            end,
            font = header_font,
            color = COLOR_THEME_PRIMARY1,
            align = CENTER
        })
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

    local main_panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG, filled = (wgt.options.BGFilled == 1) })

    -- top bar (date/time + radio battery)
    local top_bar_box = main_panel:box({ x = 0, y = outer_pad, w = w - 4, h = top_box_h })
    build_top_bar_element(top_bar_box, wgt, 0, 0, w - 4, top_box_h)
    main_panel:hline({ y = y_content - 1, w = w - 3, h = 1, color = COLOR_THEME_SECONDARY1 })

    build_flight_status_panel(main_panel, wgt, outer_pad, y_content, w_left, content_h)
    build_vertical_fuel_gauge_element(main_panel, wgt, x_fuel, y_content, w_fuel, content_h)
    build_flight_values_panel(main_panel, wgt, x_right, y_content, w_right, content_h)

    main_panel:hline({ y = y_status - 1, w = w - 3, h = 1, color = COLOR_THEME_SECONDARY1 })

    local status_bar_box = main_panel:box({ x = 0, y = y_status, w = w - 4, h = status_box_h })
    wgt.status_bar_box = status_bar_box
    wgt.status_bar_dims = { x = 0, y = 0, w = w - 4, h = status_box_h }

    build_status_bar_element(status_bar_box, wgt, 0, 0, w - 4, status_box_h)
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
    local h_info = math.max(header_h * 3 + 8, math.floor(content_h * 0.16))
    local h_mid = content_h - h_info

    local y_info = y_content + h_mid + line_h
    local y_status = y_info + h_info + line_h

    wgt.status_bar_elements = nil
    wgt.status_bar_state = nil

    local main_panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG, filled = (wgt.options.BGFilled == 1) })

    -- top bar (date/time + radio battery); no RQ/TQ on the stats page
    local top_bar_box = main_panel:box({ x = 0, y = 1, w = w - 4, h = top_box_h })
    build_top_bar_element(top_bar_box, wgt, 0, 0, w - 4, top_box_h, false)
    main_panel:hline({ y = y_content - line_h, w = w - 3, h = line_h, color = COLOR_THEME_SECONDARY1 })

    build_flight_statistics_element(main_panel, wgt, 0, y_content, stats_content_w, h_mid - line_h)

    main_panel:hline({ y = y_info - line_h, w = w - 3, h = line_h, color = COLOR_THEME_SECONDARY1 })

    local info_card_h = h_info
    local equal_item_w = math.floor(info_content_w / 3)
    local equal_item_last_w = info_content_w - equal_item_w * 2
    local weighted_item_w = math.floor(info_content_w * 0.28)
    local weighted_item_mid_w = math.floor(info_content_w * 0.28)
    local weighted_item_last_w = info_content_w - weighted_item_w - weighted_item_mid_w

    local equal_shared_font = get_shared_info_font(info_card_h, equal_item_w, equal_item_w, equal_item_last_w)
    local weighted_shared_font = get_shared_info_font(info_card_h, weighted_item_w, weighted_item_mid_w,
        weighted_item_last_w)

    local shared_info_font = weighted_shared_font
    local info_item_w = weighted_item_w
    local info_item_mid_w = weighted_item_mid_w
    local info_item_last_w = weighted_item_last_w
    if measure_font(equal_shared_font) >= measure_font(weighted_shared_font) then
        shared_info_font = equal_shared_font
        info_item_w = equal_item_w
        info_item_mid_w = equal_item_w
        info_item_last_w = equal_item_last_w
    end
    local info_value_font_h = measure_font(shared_info_font)
    local info_value_y = card_padding + header_h +
    math.floor((info_card_h - header_h - 2 * card_padding - info_value_font_h) / 2)

    local info_cards = {
        {
            x = 0,
            w = info_item_w,
            title = wgt.values.label_flight_time,
            value = wgt.values.flight_time_str_formatted,
            color = wgt.values.flight_time_color
        }, {
        x = info_item_w,
        w = info_item_mid_w,
        title = wgt.values.label_capacity_used_short,
        value = wgt.values.battery_usage_summary_formatted,
        color = COLOR_THEME_PRIMARY1
    }, {
        x = info_item_w + info_item_mid_w,
        w = info_item_last_w,
        title = wgt.values.label_battery_profile,
        value = wgt.values.rf_battery_profile_display_formatted,
        color = COLOR_THEME_PRIMARY1
    }
    }

    for i = 1, #info_cards do
        local card = info_cards[i]
        build_card_element(main_panel, card.x, y_info, card.w, info_card_h, {
            {
                type = "label",
                x = card_padding,
                y = card_padding - 1,
                w = card.w - 2 * card_padding,
                h = header_h,
                text = card.title,
                font = header_font,
                color = COLOR_THEME_SECONDARY1,
                align = CENTER
            }, {
            type = "label",
            x = card_padding,
            y = info_value_y,
            w = card.w - 2 * card_padding,
            h = info_value_font_h,
            text = card.value,
            font = shared_info_font,
            color = card.color,
            align = CENTER
        }
        })
    end

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

    -- apply the chosen color palette to all modules before (re)building the UI
    local use_clean = (options.ColorScheme or 1) == 1   -- 1 = Clean (default), 2 = EdgeTX theme
    set_palette(use_clean)
    ultidash_functions.set_palette(use_clean)
    ultidash_values.set_palette(use_clean)

    lvgl.clear()

    if init_view_state(wgt).current == "flight" then
        build_flight_ui(wgt, wgt.zone)
    else
        build_stats_ui(wgt, wgt.zone)
    end
    init_view_state(wgt).dirty = false
    wgt.layout_dirty = false
    -- Force status bar visibility update after UI rebuild
    update_status_bar_visibility(wgt, true)
    return wgt
end

--- Create the widget instance and perform the initial layout build.
local function create(zone, options)
    wgt.zone = zone
    wgt.options = options
    return update(wgt, options)
end

--- Run background RF and telemetry work that should not rebuild the UI.
local function background(wgt)
    if not wgt then return end
    prepare_widget(wgt)
    rf_service.background(wgt, handle_telemetry_state_change)
    ultidash_functions.background_refresh(wgt)
end

--- Refresh live telemetry, switch views if needed, and rebuild only when dirty.
local function refresh(wgt, event, touch_state)
    if not wgt then return end
    prepare_widget(wgt)
    rf_service.background(wgt, handle_telemetry_state_change)
    ultidash_functions.refresh(wgt)
    sync_view_for_telemetry(wgt)
    if init_view_state(wgt).dirty == true then
        return update(wgt, wgt.options)
    end
    update_status_bar_visibility(wgt)
end

return { create = create, update = update, background = background, refresh = refresh }
