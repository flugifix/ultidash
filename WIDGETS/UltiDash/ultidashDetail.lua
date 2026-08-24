--[[
================================================================================
 UltiDash - the four DETAIL PAGES (ELRS link / ESC-and-arming status / battery /
 telemetry), lifted out of ultidash.lua.

 WHY THIS FILE EXISTS. ultidash.lua had grown past 6400 lines with its main chunk
 at 198 of Lua's 200 locals, and every further feature had to buy its locals from
 somewhere. These four builders are the largest self-contained block in it: ~810
 lines that only draw, sharing nothing with the rest but the helpers below. Moving
 them frees five of those locals and, more to the point, makes the pages
 SKINNABLE - a skin can override one of them and fall back to "call the host
 module", because the env it gets is the same object this module gets.

 WHAT STAYS IN THE HOST, deliberately: opening and closing a page, the tap
 routing, the data gating, the safety overlays, and the scroll-rect dispatch in
 refresh(). This module only BUILDS. It writes wgt.estatus_scroll_up/_down
 because refresh() reads them from the same wgt - that is the one piece of state
 that crosses the seam, and it is named here so it is not discovered later.

 THE PALETTE IS MIRRORED, NOT SNAPSHOT. Every colour below is a plain local that
 the host reassigns through M.set_theme() on each rebuild, exactly as
 ultidash.lua reassigns its own in set_palette. That shape was chosen over
 rewriting ~50 call sites to env.theme.* for two reasons: the builder bodies stay
 BYTE-IDENTICAL to the ones that shipped, which is what makes the move provable
 rather than merely plausible; and a bare local read costs less per build than a
 table lookup on a page that is already 5.7k instructions. Copying the values
 once at load would have frozen the boot palette - the trap this comment exists
 to stop someone from walking into.

 License: GPLv3 or later, with ultidash.lua.
================================================================================
]]

local M = {}

-- ---------------------------------------------------------------------------
-- The palette mirror. Refreshed by M.set_theme() before every build; never read
-- before the host has called it once.
-- ---------------------------------------------------------------------------
local COLOR_THEME_PRIMARY1, COLOR_THEME_SECONDARY1
local COLOR_THEME_WARNING, COLOR_THEME_DISABLED
local PANEL_BG, force_bg_fill
local COLOR_TRACK, COLOR_TICK, COLOR_DIM
local SEM_GREEN, SEM_YELL, SEM_RED, SEM
local DARK_LUMA_THRESHOLD

-- ---------------------------------------------------------------------------
-- Host helpers, wired once in M.init(env). They are passed rather than
-- reimplemented: sensor_value_text and esc_load_color close over the host's own
-- catalogue and palette upvalues, and a second copy of either would be a second
-- source of truth for what a sensor reads.
-- ---------------------------------------------------------------------------
local select_font, measure_font, color_luma, memo_text, close_button
local sensor_short_label, sensor_unit, sensor_value_text, sensor_value_text_raw
local sensor_minmax_text, sensor_test_text, is_off_sensor, esc_load_color
local ultidash_functions
local VOLT_AUTO, ESCL_AUTO, DETAIL_SLOT_KEYS

--- Wire the host helpers. Called once, from the host's create().
function M.init(env)
    select_font           = env.select_font
    measure_font          = env.measure_font
    color_luma            = env.color_luma
    memo_text             = env.memo_text
    close_button          = env.close_button
    sensor_short_label    = env.sensor_short_label
    sensor_unit           = env.sensor_unit
    sensor_value_text     = env.sensor_value_text
    sensor_value_text_raw = env.sensor_value_text_raw
    sensor_minmax_text    = env.sensor_minmax_text
    sensor_test_text      = env.sensor_test_text
    is_off_sensor         = env.is_off_sensor
    esc_load_color        = env.esc_load_color
    ultidash_functions    = env.ultidash_functions
    VOLT_AUTO             = env.VOLT_AUTO
    ESCL_AUTO             = env.ESCL_AUTO
    DETAIL_SLOT_KEYS      = env.DETAIL_SLOT_KEYS
    DARK_LUMA_THRESHOLD   = env.DARK_LUMA_THRESHOLD
end

--- Mirror the host's live palette. Called from update(), in the same place the
--- host refreshes its own skin_theme, i.e. BEFORE the build dispatch - so a
--- scheme change is already in these locals when a page builds.
function M.set_theme(t)
    COLOR_THEME_PRIMARY1   = t.primary1
    COLOR_THEME_SECONDARY1 = t.secondary1
    COLOR_THEME_WARNING    = t.warning
    COLOR_THEME_DISABLED   = t.disabled
    PANEL_BG               = t.panel_bg
    force_bg_fill          = t.force_bg_fill
    COLOR_TRACK            = t.track
    COLOR_TICK             = t.tick
    COLOR_DIM              = t.dim
    SEM                    = t.sem
    SEM_GREEN              = t.sem.green
    SEM_YELL               = t.sem.yell
    SEM_RED                = t.sem.red
end

-- ===========================================================================
-- The four builders, moved VERBATIM from ultidash.lua. Do not reformat them:
-- their being unchanged is the evidence that the move is behaviour-neutral.
-- ===========================================================================

--- Build the ELRS link detail page (opened by tapping the top-bar bars, fullscreen
--- only). Labeled horizontal bars (RQ, TQ, 1RSS, 2RSS) with reactive crit/warn ticks +
--- values, rate/mode header and SNR/diversity footer. Thresholds and background come from
--- this instance's own options (they came from the Shared snapshot until 0.7.0 — see below).
--- NO image / NO focusable objects — safe for any screen.
local function build_elrs_view(wgt, zone)
    local w = zone.w
    local h = zone.h

    local TRACK   = COLOR_TRACK
    -- dark scheme gets vivid neon green/yellow/red so the bars pop on black
    local C_GREEN, C_YELL, C_RED = SEM_GREEN, SEM_YELL, SEM_RED
    local TICK    = COLOR_TICK

    -- Thresholds come from THIS instance's own options now, not from the Shared snapshot.
    -- The snapshot existed for a reader that no longer exists: a passive second-screen view
    -- had no options of its own, so it borrowed the publishing Dashboard's. Since 0.7.0
    -- every placed instance IS a full Dashboard, so the detour is pure indirection -- and
    -- publish_shared copies exactly these option values verbatim (`t.rq_warn = o.RQlyWarn`),
    -- which is why this substitution cannot change a pixel. Shared keeps its publisher role
    -- and the menu > Status page keeps reading it.
    -- Still NOT env.threshold_for -- but only because of where the values come from, no
    -- longer because of the RULE: since O5 this page brackets at `v <= crit` / `v <= warn`
    -- like the service and like the alert engine, so a skin-built page and this one agree
    -- at a value exactly equal to a threshold. Adopting the service here is the remaining
    -- half of the host-threshold work and belongs to a later release.
    local o = wgt.options
    local function rq_warn() return o.RQlyWarn or 80 end
    local function rq_crit() return o.RQlyCrit or 50 end
    local function rs_warn() return o.RssWarn  or 15 end
    local function rs_crit() return o.RssCrit  or 8 end

    -- FONT-METRIC layout: every column width is measured with lcd.sizeText so the
    -- page fits both the 480x320 (TX15) and the 800x480 (TX16S MK3) screens — the
    -- old fixed-pixel version overflowed/wrapped on the larger display.
    local title_font = h >= 170 and DBLSIZE or MIDSIZE
    local row_font   = h >= 170 and MIDSIZE or 0
    local title_w, title_h = lcd.sizeText("ELRS", title_font)
    local row_tw,  row_th  = lcd.sizeText("TPWR", row_font)
    local val_w            = lcd.sizeText("-108dBm", row_font) + 8
    local foot_tw, foot_th = lcd.sizeText("Ag", row_font)

    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG, filled = force_bg_fill or (o.BGFilled == 1) })

    -- The close control comes FIRST because what is left beside it is the rate label's
    -- width. It replaces the grey "tap to close" word all four pages carried: a label is
    -- not a control, and the thing that actually closed the page was the whole invisible
    -- surface. Still no lvgl button — a focusable object would capture PAGE/RTN/TELE in
    -- fullscreen, which is why these pages never had one.
    local tc_res = close_button(panel, wgt, w)

    -- header: title + rate/mode, separated by a line
    panel:label({ x = 10, y = 4, text = "ELRS", font = title_font, color = COLOR_THEME_PRIMARY1 })
    panel:label({ x = 10 + title_w + 14, y = 4 + math.floor((title_h - row_th) / 2),
        w = w - title_w - 24 - tc_res, h = row_th + 2,
        text = function() return wgt.values.elrs_rate_desc or "-" end,
        font = row_font, color = COLOR_THEME_SECONDARY1, align = LEFT })
    local top = 4 + title_h + 4
    panel:hline({ y = top - 1, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })

    -- fixed rows (2RSS just stays empty/"-" without diversity) so the layout never
    -- depends on whether telemetry was already seen at build time. TPWR is INVERTED:
    -- high transmit power means the link is working hard (dynamic power maxing out),
    -- so the bar turns yellow/red towards the configurable TxPwrMax.
    -- TPWR needs the configurable TxPwrMax as its 100% reference — without it the
    -- bar stays empty and shows a hint instead (the raw mW value is still printed).
    local function tpwr_max() return o.TxPwrMax or 0 end
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
        if wgt.values.elrs_flrc then return nil end   -- FLRC/FSK report SNR constant 0 -> empty bar
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
        { lbl = "TRSS", val = memo_text(function() return wgt.values.elrs_trss end,
              function(t) return (t and t ~= 0) and (math.floor(t) .. "dBm") or "-" end),
          get = function() return wgt.values.elrs_trss_pct end, warn = rs_warn, crit = rs_crit },
        -- SNR value shows uplink / downlink combined ("8 / 5dB"); TSNR nil -> uplink only.
        -- FLRC/FSK modes report SNR constant 0 -> value "-" and empty bar (snr_pct returns nil).
        { lbl = "SNR",
          val = (function()
              local ls, lt, lf, lstr, primed
              return function()
                  local s, t, f = wgt.values.elrs_snr, wgt.values.elrs_tsnr, wgt.values.elrs_flrc
                  if primed and s == ls and t == lt and f == lf then return lstr end
                  ls, lt, lf, primed = s, t, f, true
                  if f or s == nil then lstr = "-"
                  elseif t ~= nil then lstr = string.format("%d / %ddB", math.floor(s), math.floor(t))
                  else lstr = string.format("%ddB", math.floor(s)) end
                  return lstr
              end
          end)(),
          get = snr_pct,
          warn = function() return 70 end, crit = function() return 50 end },
        { lbl = "TPWR", invert = true,
          val = memo_text(function() return wgt.values.elrs_tpwr end,
              function(t) return (t and t > 0) and (math.floor(t) .. "mW") or "-" end),
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
                    -- O5: the low-is-bad branch uses `<=`, the alert engine's boundary, so a
                    -- value exactly ON a threshold reads the same colour the voice announces.
                    -- The inverted branch is already thr_color_high's `>=` and stays.
                    if invert then
                        if v >= crit() then return C_RED elseif v >= warn() then return C_YELL else return C_GREEN end
                    end
                    if v <= crit() then return C_RED elseif v <= warn() then return C_YELL else return C_GREEN end
                end,
                -- no constant `pos` closure: x/y are build-time, only the width is reactive.
                -- See the link bars in ultidash.lua -- measured on the simulator 2026-08-17,
                -- a rectangle with static x/y and a reactive `size` keeps its build position.
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

    -- footer: session RQ-min (left, live) + the ANTENNA PAIR and the TX module's
    -- antenna mode (right)
    local _, sml_h = lcd.sizeText("Ag", SMLSIZE)
    panel:hline({ y = h - foot_h - 1, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })

    -- TWO ANTENNAS, not a DIV pill. The chip 0.8.0 introduced said "a second antenna is
    -- reporting" and nothing else, while the page already knew WHICH one carries the link
    -- (the ANT sensor, spelled out as "Ant 1" in the footer's left half). One drawing now
    -- says both, and the left half gives its words back to the mode text.
    --   a filled ROD   = this antenna is there
    --   green + WAVES  = it is the one currently carrying the link
    --   a hollow rod   = there is no second antenna (the chip's own on/off language)
    -- The first cut drew a 2 px mast with a dot on top and the user's verdict was that it is
    -- not pretty -- it was a stick figure at the size the footer gives it. This one is a
    -- ROUNDED ROD, the same vocabulary the bars above it are drawn in, with the radiating
    -- waves as lvgl ARC sectors (the primitive the battery gauge's corners already use).
    -- Sizes come from the footer BAND rather than from the small font, so the pair uses the
    -- height the band actually has: SMLSIZE is 17 px on both 480-wide radios and 23 on the
    -- MK3, and the band is bigger than either.
    -- The proportions are the ICON's, worked backwards from the height available: the head
    -- sits inside the inner wave, the outer wave decides the width, and the mast is a short
    -- tail below them rather than a stalk running to the bottom of the band -- which is what
    -- the first icon-shaped cut drew, and it looked like a lollipop on a stick.
    local gh   = math.max(sml_h + 4, foot_h - 8)         -- the band, less its padding
    local wav2 = math.max(9, math.floor(gh / 2.45))      -- outer wave radius
    local wav1 = math.max(6, math.floor(wav2 * 0.6))     -- inner wave radius
    local tail = math.max(3, math.floor(wav2 * 0.45))    -- the mast below the waves
    local dotd = math.max(5, math.floor(wav1 * 0.85))    -- the head
    local mstw = math.max(3, math.floor(dotd / 2))       -- the mast
    local wavt = math.max(2, math.floor(gh / 16))        -- wave thickness
    local ah   = 2 * wav2 + tail                         -- one antenna's full height
    local aw   = 2 * wav2 + 2                            -- one antenna's full width
    local agap = math.max(5, math.floor(gh / 5))
    local ant_w = 2 * aw + agap
    -- The mode box takes the WIDEST value the ELRS firmware offers for "Antenna Mode"
    -- ("Gemini;Ant 1;Ant 2;Switch"), not whatever this module happens to answer -- so the
    -- layout sweep sees the real worst case even though the text is reactive.
    local mode_w = math.max(lcd.sizeText("Gemini", SMLSIZE), lcd.sizeText("Switch", SMLSIZE)) + 6
    local ant_x  = w - ant_w - 10
    local mode_x = ant_x - mode_w - 8
    local gy     = h - foot_h + math.max(2, math.floor((foot_h - ah) / 2))

    panel:label({ x = 10, y = h - foot_h + 4, w = mode_x - 16, h = foot_th + 2,
        -- memoized on its one remaining input: re-concat only when the session minimum
        -- moves (the active antenna moved into the drawing on its right)
        text = memo_text(function() return wgt.values.rqly_min end,
            function(m) return (m ~= nil) and ("RQ min " .. math.floor(m) .. "%") or "" end),
        font = row_font, color = COLOR_THEME_PRIMARY1, align = LEFT })

    -- The TX MODULE's antenna mode, from the CRSF config scan (ultidashElrs) -- the other
    -- side of the link from the antennas beside it, which are the receiver's. NOTHING is
    -- drawn while it is unknown: a plain 2.4 GHz module never registers the field at all,
    -- so a "-" there would be permanent and would read as a failed read.
    panel:label({ x = mode_x, y = gy + math.max(0, math.floor((ah - sml_h) / 2)),
        w = mode_w, h = sml_h + 2,
        text = function() return wgt.values.elrs_cfg_ant or "" end,
        font = SMLSIZE, color = COLOR_THEME_SECONDARY1, align = RIGHT })

    -- reactive, like everything else on this page: diversity is only known once a second
    -- antenna has actually reported, which can happen after the page was built
    local function present(i)
        if i == 1 then return true end
        return wgt.values.elrs_diversity == true
    end
    local function active(i)
        local a = wgt.values.elrs_ant
        return a ~= nil and (math.floor(a) + 1) == i
    end
    local ants = {}
    for i = 1, 2 do
        local cx  = ant_x + (i - 1) * (aw + agap) + math.floor(aw / 2)   -- the mast's centre
        -- The HEAD's centre is one OUTER radius below the band's top edge, because the waves
        -- are drawn around it -- measured on the simulator 2026-08-19, where a shallower
        -- offset put the outer wave across the footer's separator line and into the TPWR row.
        local cy  = gy + wav2
        local col = function()
            if active(i) then return SEM_GREEN end
            return present(i) and COLOR_THEME_SECONDARY1 or COLOR_DIM
        end
        local lit = function() return active(i) end
        local dx, dy = cx - math.floor(dotd / 2), cy - math.floor(dotd / 2)
        local mast_y = cy + math.floor(dotd / 2)
        -- head + mast, in `img/ud_antenna.png`'s shape: the same drawing the icon set uses
        -- for an antenna, redrawn rather than placed, because the colour has to switch and a
        -- PNG's does not. Filled where the antenna exists, a 1 px outline where it does not
        -- -- the on/off language the DIV chip spoke.
        local function body(vis, c)
            ants[#ants + 1] = { type = "rectangle", x = dx, y = dy, w = dotd, h = dotd,
                filled = true, rounded = math.floor(dotd / 2), color = c, visible = vis }
            ants[#ants + 1] = { type = "rectangle", x = cx - math.floor(mstw / 2), y = mast_y,
                w = mstw, h = gy + ah - mast_y, filled = true,
                rounded = math.floor(mstw / 2), color = c, visible = vis }
        end
        if i == 1 then
            body(nil, col)
        else
            body(function() return present(2) end, col)
            ants[#ants + 1] = { type = "rectangle", x = dx, y = dy, w = dotd, h = dotd,
                thickness = 1, rounded = math.floor(dotd / 2), color = COLOR_DIM,
                visible = function() return not present(2) end }
            ants[#ants + 1] = { type = "rectangle", x = cx - math.floor(mstw / 2), y = mast_y,
                w = mstw, h = gy + ah - mast_y, thickness = 1,
                rounded = math.floor(mstw / 2), color = COLOR_DIM,
                visible = function() return not present(2) end }
        end
        -- the waves: two arc pairs around the head, LEFT and RIGHT, on the ACTIVE antenna
        -- only -- the icon's own shape. 0 deg is 3 o'clock and angles run clockwise, so the
        -- right pair is 315..405 (it wraps through 0, which lv_arc_set_angles does on its
        -- own) and the left pair 135..225. The background ring is switched off
        -- (bgOpacity = 0), as it is on the battery gauge's corner sectors.
        for _, r in ipairs({ wav1, wav2 }) do
            for _, a in ipairs({ { 315, 405 }, { 135, 225 } }) do
                ants[#ants + 1] = { type = "arc", x = cx, y = cy, radius = r, thickness = wavt,
                    startAngle = a[1], endAngle = a[2], rounded = false,
                    bgStartAngle = 0, bgEndAngle = 0, bgOpacity = 0,
                    color = SEM_GREEN, visible = lit }
            end
        end
    end
    panel:build(ants)
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
    local C_RED, C_GRN = SEM_RED, SEM_GREEN
    -- neutral grey for hints/timestamps (NOT the theme DISABLED color, which is orange-red
    -- in the Clean palette and made the empty hint look like an error)
    local C_DIM = COLOR_DIM

    local title_font = h >= 170 and DBLSIZE or MIDSIZE
    local row_font   = h >= 170 and MIDSIZE or 0
    local title_w, title_h = lcd.sizeText("Status", title_font)
    local _, row_th = lcd.sizeText("Ag", row_font)
    local _, sml_h  = lcd.sizeText("Ag", SMLSIZE)

    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG,
        filled = force_bg_fill or (wgt.options.BGFilled == 1) })

    -- header: title + craft name + close control (see build_elrs_view)
    local tc_res = close_button(panel, wgt, w)
    panel:label({ x = 10, y = 4, text = "Status", font = title_font, color = COLOR_THEME_PRIMARY1 })
    panel:label({ x = 10 + title_w + 14, y = 4 + math.floor((title_h - row_th) / 2),
        w = w - title_w - 24 - tc_res, h = row_th + 2,
        text = function() return wgt.values.craft_name_formatted() end,
        font = row_font, color = COLOR_THEME_SECONDARY1, align = LEFT })
    local top = 8 + title_h + 4

    -- ---------- Header: arm card (left) + Governor/Throttle/ESC card (right) ----------
    -- Two separate rounded cards (was one 3-row card): a prominent arm state on the left
    -- and a 3-column label-over-value block on the right.
    local cx, cw = 6, w - 12
    local rpad = 6
    local hg   = 6                                   -- gap between the two cards
    local card_h = rpad * 2 + row_th + 2 + sml_h     -- one big line (value) + one small line (label)
    local aw_card = math.floor(cw * 0.30)            -- arm card width
    local rx  = cx + aw_card + hg
    local rcw = cw - aw_card - hg

    panel:build({
        { type = "rectangle", x = cx, y = top, w = aw_card, h = card_h, thickness = 1, rounded = 8, color = COLOR_THEME_SECONDARY1 },
        { type = "rectangle", x = rx, y = top, w = rcw,    h = card_h, thickness = 1, rounded = 8, color = COLOR_THEME_SECONDARY1 },
    })

    -- left arm card: ARMED/DISARMED (big) + arm reason (small), both centered
    local big_y = top + rpad
    local sub_y = big_y + row_th + 2
    panel:label({ x = cx, y = big_y, w = aw_card, h = row_th + 2, font = row_font, align = CENTER,
        text = function() return wgt.armed_now and "ARMED" or "DISARMED" end,
        color = function() return wgt.armed_now and C_RED or COLOR_THEME_PRIMARY1 end })
    panel:label({ x = cx, y = sub_y, w = aw_card, h = sml_h + 2, font = SMLSIZE, align = CENTER,
        text = function()
            if wgt.armed_now then return "" end
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

    -- right card: 3 columns, dim label on top / value below
    local pad2  = 10
    local col_x = rx + pad2
    local col_wt = rcw - 2 * pad2
    local gw2 = math.floor(col_wt * 0.32)            -- Governor (left)
    local tw2 = math.floor(col_wt * 0.26)            -- Throttle (center)
    local ew2 = col_wt - gw2 - tw2                   -- ESC (right)
    local lbl_y = top + rpad
    -- values a notch smaller than the arm word (STDSIZE, like the event log) so longer
    -- Governor / ESC statuses ("ESC Starting", vendor fault texts) fit without clipping.
    local val_font = 0
    local val_th = select(2, lcd.sizeText("Ag", val_font))
    local val_y = lbl_y + sml_h + 2 + math.max(0, math.floor((row_th - val_th) / 2))
    -- Governor
    panel:label({ x = col_x, y = lbl_y, w = gw2, h = sml_h + 2, font = SMLSIZE, color = C_DIM, align = LEFT, text = "Governor" })
    panel:label({ x = col_x, y = val_y, w = gw2, h = val_th + 2, font = val_font, color = COLOR_THEME_PRIMARY1, align = LEFT,
        text = wgt.values.gov_state_formatted })
    -- Throttle
    panel:label({ x = col_x + gw2, y = lbl_y, w = tw2, h = sml_h + 2, font = SMLSIZE, color = C_DIM, align = CENTER, text = "Throttle" })
    panel:label({ x = col_x + gw2, y = val_y, w = tw2, h = val_th + 2, font = val_font, color = COLOR_THEME_PRIMARY1, align = CENTER,
        text = function() return wgt.values.throttle_text or "-" end })
    -- ESC (level-colored)
    panel:label({ x = col_x + gw2 + tw2, y = lbl_y, w = ew2, h = sml_h + 2, font = SMLSIZE, color = C_DIM, align = RIGHT, text = "ESC" })
    panel:label({ x = col_x + gw2 + tw2, y = val_y, w = ew2, h = val_th + 2, font = val_font, align = RIGHT,
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
        -- REACTIVE, because the rows under it are: the log keeps growing while the page is
        -- open, and a build-time string said "1-8 / 12" over a list that had reached 20.
        -- The scroll offset is build-time by design (the arrows rebuild the page), so only
        -- the total moves here.
        -- MEMOISED on the only thing that moves. `scroll` and `slots` are build-time
        -- constants (the arrows rebuild the page), so the count alone keys the string --
        -- and it changes at most on an ESC event, not per frame. This was the one
        -- un-memoised formatter left in a file where every neighbour is memoised: a
        -- string.format per LVGL frame for as long as the page stands open.
        panel:label({ x = sux - 96, y = log_lbl_y, w = 90, h = sml_h + 2, font = SMLSIZE, align = RIGHT, color = C_DIM,
            text = memo_text(
                function()
                    local lg = ultidash_functions.get_esc_log(wgt)
                    return lg and #lg or nlog
                end,
                function(n)
                    return string.format("%d-%d / %d", scroll + 1, math.min(scroll + slots, n), n)
                end) })
    else
        -- Below one page, so no chrome -- and this decision IS build-time: a log that grows
        -- past the page while it is open gets its arrows on the next rebuild (a tap, a view
        -- switch, a skin change), not on the event itself. Building them hidden would cost
        -- every healthy build two rects, two triangles and their closures for a case that
        -- resolves itself with the next touch.
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

    -- tiny diagnostics footer (kept subtle, per the "klein/dezent" choice). Memoized on
    -- wgt.dbg_win: all four metrics refresh together once per second, so `pass x ms` now
    -- updates 1x/s instead of 5x/s -- fine for a diagnostics readout.
    panel:label({ x = 10, y = h - footer_h + 2, w = w - 20, h = sml_h + 2, font = SMLSIZE, color = C_DIM, align = LEFT,
        text = (function()
            local last_win, last_s, primed
            return function()
                local win = wgt.dbg_win
                if primed and win == last_win then return last_s end
                last_win, primed = win, true
                last_s = "Lua " .. (wgt.dbg_lua_kb or "-") .. " kB  free " .. (wgt.dbg_free_kb or "-")
                    .. " kB   UI " .. (wgt.dbg_hz or "-") .. " Hz   pass " .. ((wgt.dbg_pass_cs or 0) * 10) .. " ms"
                return last_s
            end
        end)() })
end

--- Build the BATTERY DETAIL page (tap the center fuel gauge, fullscreen only):
--- a big fuel gauge plus a cell-voltage scale with the RESOLVED thresholds
--- (FC config or manual) marked, and the key battery numbers. Drawn with
--- build-table primitives only (no lvgl.box — overlay/window objects swallow
--- fullscreen taps).
local function build_battery_view(wgt, zone)
    local w = zone.w
    local h = zone.h
    -- battery graphic empty segs: same scheme identity as the dashboard gauge —
    -- light grey on the light schemes, muted mid-grey on the dark one
    local TRACK   = force_bg_fill and lcd.RGB(0x6A, 0x6E, 0x72) or lcd.RGB(0xC8, 0xC8, 0xC8)
    -- big-percent ink follows the effective surfaces (same rule as the dashboard gauge)
    local PCT_INK = (color_luma(TRACK) > DARK_LUMA_THRESHOLD
        and color_luma(SEM.bar_ok) > DARK_LUMA_THRESHOLD) and BLACK or WHITE
    -- dark scheme gets vivid neon green/yellow/red so the gauge pops on black
    local C_GREEN, C_YELL, C_RED = SEM_GREEN, SEM_YELL, SEM_RED
    local C_DIM   = COLOR_DIM
    local TICK    = COLOR_TICK

    local title_font = h >= 170 and DBLSIZE or MIDSIZE
    local row_font   = h >= 170 and MIDSIZE or 0
    local title_w, title_h = lcd.sizeText("Battery", title_font)
    local _, row_th = lcd.sizeText("Ag", row_font)

    local panel = lvgl.rectangle({ x = 0, y = 0, w = w, h = h, color = PANEL_BG,
        filled = force_bg_fill or (wgt.options.BGFilled == 1) })

    panel:label({ x = 10, y = 4, text = "Battery", font = title_font, color = COLOR_THEME_PRIMARY1 })
    close_button(panel, wgt, w)   -- see build_elrs_view
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
          -- constant `pos` dropped, same measured reasoning as the bars above
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
        -- memoized on the three thresholds + source; still reactive because an MSP fetch
        -- can change the resolved thresholds live (re-formats only when one moves)
        text = (function()
            local lc, ll, lf, ls, last, primed
            return function()
                local c, l, f = th_crit(), th_low(), th_full()
                local src = wgt.options.CellSource
                if primed and c == lc and l == ll and f == lf and src == ls then return last end
                lc, ll, lf, ls, primed = c, l, f, src, true
                last = string.format("crit %.2f   low %.2f   full %.2f V   (%s)",
                    c, l, f, (src == 2) and "manual" or "FC config")
                return last
            end
        end)(),
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

    -- ESC-load fill: floods the ENTIRE free gap between segments and frame, filling
    -- LEFT -> RIGHT towards the cap (the direction this laid-down battery fills).
    -- Same construction as the dashboard gauge (see there): built BEFORE the segments
    -- (fill sits UNDER them), outer corners as filled arc sectors following the frame
    -- curve, inner-corner patches under the end segments' rounded corners.
    if wgt.options.EscMon == 1 then
        local gap = math.max(1, inner_pad - 1)  -- free gap = outer corner radius R
        local sr  = seg_rounding                -- inner (segment) corner radius
        local rx0 = bx + 1                      -- inside the 1 px outline
        local rx1 = bx + bw - 1
        local ry0 = by2 + 1
        local ry1b = by2 + bh - 1
        -- scale like the dashboard gauge: left gap + middle = 0..100 %; the RIGHT gap
        -- (cap side) is the OVERLOAD zone, filling over 100..150 % (closed at >=150 %)
        local norm   = gap + iw                 -- fill travel for 0..100 %
        local travel = norm + gap               -- incl. the overload (cap) zone
        local esc_vis = function() return wgt.values.esc_load_limit ~= nil end
        local function fillw()
            local p = wgt.values.esc_load_pct or 0
            if p < 0 then p = 0 end
            if p <= 100 then return math.floor(norm * p / 100) end
            local o = p - 100
            if o > 50 then o = 50 end
            return norm + math.floor(gap * o / 50)
        end
        local function fill_color()
            local p = wgt.values.esc_load_pct
            if p == nil then return TRACK end
            local warn = wgt.options.EscWarn or 80
            local crit = wgt.options.EscCrit or 100
            if p >= crit then return C_RED elseif p >= warn then return C_YELL else return C_GREEN end
        end
        local function corner(cx, cy, a0, a1, vis)
            return { type = "arc", x = cx, y = cy, radius = gap, thickness = gap,
                     startAngle = a0, endAngle = a1, rounded = false,
                     bgStartAngle = 0, bgEndAngle = 0, bgOpacity = 0,
                     color = fill_color, visible = vis }
        end
        local function patch(px, py, vis)
            return { type = "rectangle", x = px, y = py, w = sr, h = sr, filled = true,
                     color = fill_color, visible = vis }
        end
        local vis_left    = function() return esc_vis() and fillw() >= gap end
        local vis_inner_l = function() return esc_vis() and fillw() >= gap + sr end
        local vis_inner_r = function() return esc_vis() and fillw() >= gap + iw end
        local vis_right   = function() return esc_vis() and fillw() >= travel end
        panel:build({
            -- left run between the corner discs
            { type = "rectangle", x = rx0, y = iy, w = 1, h = ih, filled = true,
              visible = function() return esc_vis() and fillw() > 0 end,
              size = function() return math.max(1, math.min(fillw(), gap)), ih end,
              color = fill_color },
            corner(rx0 + gap, ry0 + gap, 180, 270, vis_left),    -- top-left
            corner(rx0 + gap, ry1b - gap, 90, 180, vis_left),    -- bottom-left
            -- inner-corner patches under the LEFT segment's rounded corners
            patch(ix, iy, vis_inner_l),
            patch(ix, iy + ih - sr, vis_inner_l),
            -- top + bottom runs flush along segments and frame
            { type = "rectangle", x = ix, y = ry0, w = 1, h = gap, filled = true,
              visible = function() return esc_vis() and fillw() > gap end,
              size = function() return math.max(1, math.min(fillw() - gap, iw)), gap end,
              color = fill_color },
            { type = "rectangle", x = ix, y = ry1b - gap, w = 1, h = gap, filled = true,
              visible = function() return esc_vis() and fillw() > gap end,
              size = function() return math.max(1, math.min(fillw() - gap, iw)), gap end,
              color = fill_color },
            -- right: inner-corner patches, right run + corner discs (~100 %)
            patch(ix + iw - sr, iy, vis_inner_r),
            patch(ix + iw - sr, iy + ih - sr, vis_inner_r),
            { type = "rectangle", x = rx1 - gap, y = iy, w = 1, h = ih, filled = true,
              visible = function() return esc_vis() and fillw() > gap + iw end,
              size = function() return math.max(1, math.min(fillw() - gap - iw, gap)), ih end,
              color = fill_color },
            corner(rx1 - gap, ry0 + gap, 270, 360, vis_right),   -- top-right
            corner(rx1 - gap, ry1b - gap, 0, 90, vis_right),     -- bottom-right
        })
    end

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

    -- ESC-load display: the WHOLE free gap between the segments and the frame becomes
    -- the load gauge, filling LEFT -> RIGHT towards the cap — the same direction this
    -- laid-down battery fills. NO track: the unfilled gap stays transparent, only the
    -- coloured fill appears; the left/right end strips carry rounded corners matching
    -- the frame and the top/bottom strips overlap them by the radius (no notches).
    -- Always shown here while ESC load monitoring is on (the dashboard placement is a
    -- setting, see the "ESC load" settings group).

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
        font = pct_font, color = PCT_INK, align = CENTER })
    -- used mAh only, like the dashboard gauge — the profile's TOTAL capacity is
    -- merely informational and "x / total" misreads as usable-until-total (the
    -- reserve model ends earlier)
    -- memoized: concats rebuild only when the 5 Hz-cached inputs move
    panel:label({ x = ix + iw - math.floor(iw * 0.30) - 8, y = cells_y,
        w = math.floor(iw * 0.30), h = row_th + 2,
        text = memo_text(wgt.values.gauge_mah_value_formatted,
            function(s) return s .. " mAh" end),
        font = row_font, color = pill_text, align = RIGHT })

    -- bottom line: the remaining numbers in one row (memoized)
    local byl = h - bottom_h + 2
    panel:label({ x = 14, y = byl, w = math.floor(w * 0.34), h = row_th + 2,
        text = memo_text(wgt.values.vbat_formatted,
            function(s) return "Batt " .. s end),
        font = row_font, color = COLOR_THEME_PRIMARY1, align = LEFT })
    panel:label({ x = math.floor(w * 0.34), y = byl, w = math.floor(w * 0.32), h = row_th + 2,
        text = memo_text(function() return wgt.values.vcel_min end,
            function(v) return "Cell min " .. (v and string.format("%.2f V", v) or "-") end),
        font = row_font, color = COLOR_THEME_PRIMARY1, align = CENTER })
    panel:label({ x = w - 14 - math.floor(w * 0.30), y = byl, w = math.floor(w * 0.30), h = row_th + 2,
        text = memo_text(function() return wgt.options.Reserve or 20 end,
            function(v) return "Reserve " .. v .. " %" end),
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
        filled = force_bg_fill or (wgt.options.BGFilled == 1) })
    panel:label({ x = 10, y = 4, text = "Telemetry", font = title_font, color = COLOR_THEME_PRIMARY1 })
    close_button(panel, wgt, w)   -- see build_elrs_view
    local top = 4 + title_h + 4
    panel:hline({ y = top - 1, w = w - 4, h = 1, color = COLOR_THEME_SECONDARY1 })

    -- collect active (non-off) slots in order
    local slots = {}
    for i = 1, #DETAIL_SLOT_KEYS do
        local name = wgt.options[DETAIL_SLOT_KEYS[i]]
        if not is_off_sensor(name) then slots[#slots + 1] = name end
    end
    if #slots == 0 then
        -- measured (rule 8): MIDSIZE is taller than 24 px on the 800x480 MK3
        local _, eh = lcd.sizeText("Ag", MIDSIZE)
        panel:label({ x = 0, y = math.floor((h - eh) / 2), w = w, h = eh + 2,
            text = "No values selected  (Settings > Values)", font = MIDSIZE,
            color = COLOR_THEME_DISABLED, align = CENTER })
        return
    end

    -- 3-column grid of CARDS (mockup scheme): each active slot is a bordered card with a
    -- centred label on top, a big value + small unit in the middle, and a soft "min .. max"
    -- chip below. Only filled slots get a card; an empty slot is simply absent.
    local cols   = 3
    local n      = #slots
    local rows_n = math.max(1, math.ceil(n / cols))
    local pad    = 10
    local grid_y = top + 6
    local grid_h = h - grid_y - 6
    local card_w = math.floor((w - pad * (cols + 1)) / cols)
    local card_h = math.floor((grid_h - pad * (rows_n - 1)) / rows_n)
    local card_r = math.min(10, math.max(4, math.floor(card_h * 0.16)))
    local _, lbl_h = lcd.sizeText("Ag", SMLSIZE)
    local ip     = 6
    local chip_h = lbl_h + 2
    -- uniform value font (all cards same size): fill the space left between label and chip
    local val_slot_h = card_h - (ip + lbl_h + 2) - (chip_h + ip) - 2
    local val_font = select_font(math.max(8, val_slot_h), card_w - 2 * ip - 28, "99.99")
    local val_h    = measure_font(val_font)
    local chip_r   = math.floor(chip_h / 2)
    local chip_w   = math.min(card_w - 2 * ip, lcd.sizeText("999.9 .. 999.9", SMLSIZE) + 12)

    local function card_xy(idx)
        local c = (idx - 1) % cols
        local r = math.floor((idx - 1) / cols)
        return pad + c * (card_w + pad), grid_y + r * (card_h + pad)
    end

    for idx = 1, n do
        local name = slots[idx]
        local cardx, cardy = card_xy(idx)
        -- card surface (chrome fill) + subtle border
        panel:build({
            { type = "rectangle", x = cardx, y = cardy, w = card_w, h = card_h, filled = true, rounded = card_r, color = PANEL_BG },
            { type = "rectangle", x = cardx, y = cardy, w = card_w, h = card_h, thickness = 1, rounded = card_r, color = COLOR_TRACK },
        })

        local lbl_y   = cardy + ip
        local chip_y  = cardy + card_h - chip_h - ip
        local val_top = lbl_y + lbl_h + 2
        local val_y   = val_top + math.max(0, math.floor((chip_y - 2 - val_top - val_h) / 2))

        -- label (centred, dim)
        panel:label({ x = cardx + 2, y = lbl_y, w = card_w - 4, h = lbl_h + 2,
            text = sensor_short_label(name), font = SMLSIZE, color = COLOR_DIM, align = CENTER })

        -- value (+ small unit, opt-in via Display ▸ "Units beside values")
        local unit   = (wgt.options.ShowUnits == 1) and sensor_unit(name) or ""
        local unit_w = (unit ~= "") and (lcd.sizeText(unit, SMLSIZE) + 3) or 0
        local vgetter, vcolor
        if name == VOLT_AUTO then
            vgetter, vcolor = wgt.values.display_voltage_formatted, wgt.values.display_voltage_color
        elseif name == ESCL_AUTO then
            vgetter, vcolor = sensor_value_text(wgt, name), esc_load_color(wgt)
        else
            vgetter, vcolor = sensor_value_text_raw(wgt, name), COLOR_THEME_PRIMARY1
        end
        if unit == "" then
            panel:label({ x = cardx + ip, y = val_y, w = card_w - 2 * ip, h = val_h + 2,
                text = vgetter, font = val_font, color = vcolor, align = CENTER })
        else
            -- number right-aligned to a gutter placed (from the per-sensor test width) so a
            -- full-width value+unit pair sits centred; the unit always hugs the number. No
            -- per-frame width math -- short values just lean slightly right of centre.
            local test_w = lcd.sizeText(sensor_test_text(name), val_font)
            local gutter = cardx + math.floor(card_w / 2) + math.floor((test_w - unit_w) / 2)
            gutter = math.min(gutter, cardx + card_w - ip - unit_w - 1)   -- keep the unit inside the card
            panel:label({ x = cardx + ip, y = val_y, w = gutter - (cardx + ip) - 1, h = val_h + 2,
                text = vgetter, font = val_font, color = vcolor, align = RIGHT })
            panel:label({ x = gutter + 1, y = val_y + (val_h - lbl_h), w = unit_w + 6, h = lbl_h + 2,
                text = unit, font = SMLSIZE, color = COLOR_DIM, align = LEFT })
        end

        -- min .. max chip (centred pill)
        local chip_x = cardx + math.floor((card_w - chip_w) / 2)
        panel:build({
            { type = "rectangle", x = chip_x, y = chip_y, w = chip_w, h = chip_h,
              filled = true, rounded = chip_r, color = COLOR_TRACK },
            { type = "label", x = chip_x, y = chip_y, w = chip_w, h = chip_h,
              text = sensor_minmax_text(wgt, name), font = SMLSIZE, color = COLOR_TICK, align = CENTER },
        })
    end

end

-- ===========================================================================
-- One dispatch. The host holds a page id ("elrs" / "estatus" / "battery" /
-- "telem"); an unknown id builds nothing rather than raising, because the host's
-- own dispatch already decided the page exists and a nil here would be a blank
-- screen with no message.
-- ===========================================================================
local BUILDERS = {
    elrs    = build_elrs_view,
    estatus = build_estatus_view,
    battery = build_battery_view,
    telem   = build_telem_view,
}

function M.build(wgt, zone, id)
    local f = BUILDERS[id]
    if f == nil then return false end
    f(wgt, zone)
    return true
end

return M
