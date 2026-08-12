-- UltiDash default skin — the built-in dashboard look, extracted from ultidash.lua's
-- build_flight_ui / build_stats_ui (skin system, stage 2). This is the reference skin
-- AND the fallback if a chosen skin fails to load.
--
-- PURE PRESENTATION. A skin only LAYS OUT the host's component library and reads a theme
-- snapshot; every value comes from the host (wgt.values.*, the engine). A skin never polls
-- telemetry, runs MSP/audio, or measures anything the host doesn't hand it. See docs/SKINS.md.
--
-- Behaviour-neutral vs. the old in-file builders: same geometry, same component calls, same
-- order. The HOST stacks the safety overlays (setup hint, save-failed / dual-publisher warn
-- banners, the critical-alert overlay) on top of whatever a skin returns — a skin can never
-- suppress them. build_flight / build_stats therefore return (main_panel, content_top_y) so
-- the host can place those overlays.
--
-- Loaded lazily by the host (loadScript + pcall) and cached; M.init wires the API (env).
-- Only function-style string calls (s:method() crashes the widget Lua state). No lvgl.box
-- overlays (they steal touch after a fullscreen cycle) — the host owns that discipline; a
-- skin sticks to the component builders + build-table primitives on the returned panel.

local M = {}
M.api = 1        -- skin API version the host checks before accepting this module
M.name = "UltiDash"   -- display name in the Dashboard-skin choice (id = file name)

-- ---- manifest (skins are self-contained) -----------------------------------
-- The default skin owns the STANDARD three colour schemes (UltiDash / UltiDash dark /
-- EdgeTX theme). Their descriptors live host-side (the host needs them as the ultimate
-- fallback and for the menu-neutral rendering) and are handed in via the env —
-- M.schemes is assigned in M.init below.
M.scheme_key = "ColorScheme"   -- historical key: existing cfgs keep working
M.def_scheme = 1
-- The skin's OWN settings rows (menu group "Skin"): the rows that describe THIS
-- layout — top bar content/toggles and the left panel's top slot.
M.items = {
    { kind = "section", lbl = "Top bar & left panel" },
    { key = "TopLeft",       lbl = "Top-left shows",        kind = "choice", def = 1, vals = { "Model image", "Timer" } },
    { key = "ClockMode",     lbl = "Top bar clock",         kind = "choice", def = 2, vals = { "Date + time", "Time only" } },
    { key = "Timer",         lbl = "Timer (for top-left)",  kind = "num", def = 0, min = 0, max = 2, step = 1, big = 1,
                             fmt = function(v) return "Timer " .. (v + 1) end,
                             dim = function(w) return w.TopLeft ~= 2 end },
    { key = "ShowRQly",      lbl = "Top bar: RQ bar",       kind = "bool", def = 1 },
    { key = "ShowTQly",      lbl = "Top bar: TQ bar",       kind = "bool", def = 1 },
    { key = "ShowRSSI",      lbl = "Top bar: RSSI bars",    kind = "bool", def = 1 },
    { key = "ShowTxV",       lbl = "Top bar: TX voltage",   kind = "bool", def = 0 },
    { key = "BarsQuiet",     lbl = "Link bars: color only on warning", kind = "bool", def = 1 },
    -- status bar (always shown by this skin): the TPWR field is optional. Only the
    -- FLIGHT view honours this — the stats page always prints TPWR (it is the only
    -- place TX power appears there). Host key, declared by every skin that draws the
    -- host status bar.
    { kind = "section", lbl = "Status bar" },
    { key = "ShowTPWR",      lbl = "Status bar: TPWR",      kind = "bool", def = 1 },
}

-- ---- host context (assigned in M.init) ------------------------------------
-- component library (host-owned panel builders) + font/measure helpers + a live theme
-- snapshot table (host mutates its fields before each build) + small helpers.
local top_bar, status_bar, fuel_gauge, flight_values, flight_status, stats_table
local select_font, measure_font
local set_header, set_tap
local theme       -- reused table: {panel_bg, force_bg_fill, primary1, secondary1}
local card_gap

function M.init(env)
    top_bar       = env.top_bar
    status_bar    = env.status_bar
    fuel_gauge    = env.fuel_gauge
    flight_values = env.flight_values
    flight_status = env.flight_status
    stats_table   = env.stats_table
    select_font   = env.select_font
    measure_font  = env.measure_font
    set_header    = env.set_header
    set_tap       = env.set_tap
    theme         = env.theme
    card_gap      = env.card_gap
    M.schemes     = env.standard_schemes   -- manifest: this skin's colour schemes
end

--- Flight dashboard layout. Returns (main_panel, content_top_y) for the host overlays.
function M.build_flight(wgt, zone)
    local w = zone.w
    local h = zone.h

    -- floor of 18 px: at 7.5 % a 480x272 screen (TX16S MK2) yields only 20 px, and the
    -- box (-2) then forces select_font down to the smallest face. Same guard Dash1 uses.
    local h_status = math.max(18, math.floor(h * 0.075))
    local h_top = h_status
    local status_box_h = math.max(1, h_status - 2)
    local top_box_h = math.max(1, h_top - 2)
    local outer_pad = 2

    -- header font/height feed the host panels via set_header (they read the host locals)
    local hf = select_font(status_box_h, nil, nil)
    set_header(hf, measure_font(hf))

    local content_w = w - 2 * outer_pad
    local content_h = h - h_top - h_status - 2 * card_gap - 2 * outer_pad
    local y_content = outer_pad + h_top + card_gap
    local y_status = y_content + content_h + card_gap

    -- gauge width: 20 % of the content, with a readable floor -- but the floor must never
    -- exceed what is actually there, or the two side panels get a NEGATIVE width in a very
    -- narrow (non-fullscreen) widget zone
    local w_fuel = math.min(math.max(8, content_w - 8), math.max(46, math.floor(content_w * 0.20)))
    local remaining_w = math.max(0, content_w - w_fuel - 2 * card_gap)
    local w_left = math.floor(remaining_w / 2)
    local w_right = remaining_w - w_left
    local x_fuel = outer_pad + w_left + card_gap
    local x_right = x_fuel + w_fuel + card_gap

    wgt.status_bar_elements = nil
    wgt.status_bar_state = nil

    local main_panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = theme.panel_bg, filled = theme.force_bg_fill or (wgt.options.BGFilled == 1) })

    -- top bar (date/time + radio battery)
    local top_bar_box = main_panel:box({ x = 0, y = outer_pad, w = w - 4, h = top_box_h })
    top_bar(top_bar_box, wgt, 0, 0, w - 4, top_box_h)

    flight_status(main_panel, wgt, outer_pad, y_content, w_left, content_h)
    fuel_gauge(main_panel, wgt, x_fuel, y_content, w_fuel, content_h)
    -- tapping the gauge (fullscreen) opens the battery detail page
    set_tap(wgt, "battery", { x = x_fuel, y = y_content, w = w_fuel, h = content_h })
    flight_values(main_panel, wgt, x_right, y_content, w_right, content_h)
    -- tapping the values panel (fullscreen) opens the Telemetry detail page
    set_tap(wgt, "values", { x = x_right, y = y_content, w = w_right, h = content_h })

    local status_bar_box = main_panel:box({ x = 0, y = y_status, w = w - 4, h = status_box_h })
    wgt.status_bar_box = status_bar_box
    wgt.status_bar_dims = { x = 0, y = 0, w = w - 4, h = status_box_h }

    status_bar(status_bar_box, wgt, 0, 0, w - 4, status_box_h)

    return main_panel, y_content
end

--- Statistics dashboard layout. Returns (main_panel, content_top_y) for the host overlays.
function M.build_stats(wgt, zone)
    local w = zone.w
    local h = zone.h
    local stats_content_w = math.max(1, w - 1)
    local info_content_w = math.max(1, stats_content_w - 1)

    local line_h = 1
    -- floor of 18 px: at 7.5 % a 480x272 screen (TX16S MK2) yields only 20 px, and the
    -- box (-2) then forces select_font down to the smallest face. Same guard Dash1 uses.
    local h_status = math.max(18, math.floor(h * 0.075))
    local h_top = h_status
    local status_box_h = math.max(1, h_status - 2)
    local top_box_h = math.max(1, h_top - 2)

    local hf = select_font(status_box_h, nil, nil)
    local hh = measure_font(hf)
    set_header(hf, hh)

    local y_content = h_top + line_h
    local content_h = h - h_top - h_status - 3 * line_h
    -- slim single info line (was a 3-card band Flight Time / mAh Used / Batt Profile: the
    -- profile is not useful here and the cards ate ~16% height; the freed space hosts the
    -- per-profile headspeed rows in the table)
    local h_info = hh + 6
    local h_mid = content_h - h_info

    local y_info = y_content + h_mid + line_h
    local y_status = y_info + h_info + line_h

    wgt.status_bar_elements = nil
    wgt.status_bar_state = nil

    local main_panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = theme.panel_bg, filled = theme.force_bg_fill or (wgt.options.BGFilled == 1) })

    -- top bar (date/time + radio battery); no RQ/TQ on the stats page
    local top_bar_box = main_panel:box({ x = 0, y = 1, w = w - 4, h = top_box_h })
    top_bar(top_bar_box, wgt, 0, 0, w - 4, top_box_h, false)
    main_panel:hline({ y = y_content - line_h, w = w - 3, h = line_h, color = theme.secondary1 })

    stats_table(main_panel, wgt, 0, y_content, stats_content_w, h_mid - line_h)

    main_panel:hline({ y = y_info - line_h, w = w - 3, h = line_h, color = theme.secondary1 })

    -- one slim line: session flight time + used mAh (raw %)
    main_panel:label({ x = 0, y = y_info + 3, w = info_content_w, h = hh,
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
        font = hf, color = theme.primary1, align = CENTER })

    main_panel:hline({ y = y_status - line_h, w = w - 3, h = line_h, color = theme.secondary1 })

    local status_bar_box = main_panel:box({ x = 0, y = y_status, w = w - 4, h = status_box_h })
    wgt.status_bar_box = status_bar_box
    wgt.status_bar_dims = { x = 0, y = 0, w = w - 4, h = status_box_h }

    status_bar(status_bar_box, wgt, 0, 0, w - 4, status_box_h)

    return main_panel, y_content
end

return M
