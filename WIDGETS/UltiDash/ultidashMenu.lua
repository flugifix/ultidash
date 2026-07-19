-- =====================================================================
--  UltiDash: menu / settings / sensor-check UI  (LAZY-LOADED module)
--  Every fullscreen menu page lives here: the menu hub, the Toolbox and
--  Settings submenus, the settings pages themselves, the sensor-check
--  page and the two battery pickers. ultidash.lua loads this module on
--  menu open (menu_load) and releases it when the menu family closes,
--  keeping ~85 kB of cold builder source OFF the resident heap -- the
--  same GC rationale as the lazy Toolbox tools (boot-resident modules
--  measurably drag the whole UI loop, see the tb_load_* note there).
--
--  The host context comes in via M.init(env) -- resident functions,
--  data tables and constants, unpacked into module-locals with the SAME
--  NAMES as in ultidash.lua so the moved code below stays verbatim.
--  The palette is pulled FRESH at the top of every M.build (env.colors),
--  so pages render with the host's current scheme + colour overrides.
-- =====================================================================

local M = {}

-- ---- host context (assigned in M.init) ------------------------------------
local init_view_state, close_settings, for_each_setting_item
local build_sensor_list, sensor_pick_label, is_raw_sensor
local resolve_builtins, role_color, role_in_scheme, color_key, picker_rgb24
local prof_log, bump_settings_gen
local tb_avail, shortcut_open
local SETTINGS_GROUPS, ALERT_PAGES, COLOR_PAGES, COLOR_ROLES, SENSOR_INFO
local PANEL_SLOT_KEYS, DETAIL_SLOT_KEYS
local fltlog, rf_service, ultidash_settings, ultidash_functions
local SENSOR_OFF, VOLT_AUTO, ESCL_AUTO, RAW_SENTINEL, SCHEME_ULTIDASH
local colors_fn

-- ---- palette snapshot ------------------------------------------------------
-- Pulled fresh at the top of every M.build: reactive closures built into a page
-- capture these values; a scheme/override change always rebuilds the page anyway.
local COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1
local COLOR_THEME_SECONDARY2, COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS
local COLOR_THEME_WARNING, COLOR_THEME_DISABLED
local SEM_GREEN, SEM_YELL, SEM_RED, SEM_NEUT, COLOR_DIM

local function pull_palette()
    COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1,
    COLOR_THEME_SECONDARY2, COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS,
    COLOR_THEME_WARNING, COLOR_THEME_DISABLED,
    SEM_GREEN, SEM_YELL, SEM_RED, SEM_NEUT, COLOR_DIM = colors_fn()
end

function M.init(env)
    init_view_state       = env.init_view_state
    close_settings        = env.close_settings
    for_each_setting_item = env.for_each_setting_item
    build_sensor_list     = env.build_sensor_list
    sensor_pick_label     = env.sensor_pick_label
    is_raw_sensor         = env.is_raw_sensor
    resolve_builtins      = env.resolve_builtins
    role_color            = env.role_color
    role_in_scheme        = env.role_in_scheme
    color_key             = env.color_key
    picker_rgb24          = env.picker_rgb24
    prof_log              = env.prof_log
    bump_settings_gen     = env.bump_settings_gen
    tb_avail              = env.tb_avail
    shortcut_open         = env.shortcut_open
    SETTINGS_GROUPS       = env.SETTINGS_GROUPS
    ALERT_PAGES           = env.ALERT_PAGES
    COLOR_PAGES           = env.COLOR_PAGES
    COLOR_ROLES           = env.COLOR_ROLES
    SENSOR_INFO           = env.SENSOR_INFO
    PANEL_SLOT_KEYS       = env.PANEL_SLOT_KEYS
    DETAIL_SLOT_KEYS      = env.DETAIL_SLOT_KEYS
    fltlog                = env.fltlog
    rf_service            = env.rf_service
    ultidash_settings     = env.ultidash_settings
    ultidash_functions    = env.ultidash_functions
    SENSOR_OFF            = env.SENSOR_OFF
    VOLT_AUTO             = env.VOLT_AUTO
    ESCL_AUTO             = env.ESCL_AUTO
    RAW_SENTINEL          = env.RAW_SENTINEL
    SCHEME_ULTIDASH       = env.SCHEME_ULTIDASH
    colors_fn             = env.colors
end

-- ============================================================================
-- SENSOR CHECK PAGE (menu -> Sensor check)
-- ============================================================================
-- Evaluates the sensors UltiDash relies on and explains what a missing one
-- breaks. READ-ONLY; the scan runs ONLY while the page is open (refresh block,
-- <= 1 Hz), never in the 5 Hz path, no MSP. Existence resolves by RF app-id
-- (rename/duplicate immune, one model.getSensor scan) with a getFieldInfo name
-- fallback for the ELRS/decoder sensors that carry no app-id; the live value is
-- read via read_src. Three states: OK (present + data) / -- (present, no data)
-- / MISS (never discovered). Required MISS = red (counts toward the summary);
-- feature/slot MISS = yellow advisory. This matrix is its OWN static table, NOT
-- SENSOR_INFO: ARM/ARMD/Gov/PID#/RTE#/BAT#/Esc#/EscF are status codes
-- deliberately leaves out of the curated catalog. bit order/app-ids follow
-- rotorflight-firmware + rf2tlm_sensors.lua.
local SENSCHECK_CURR_NAMES = { "Curr", "EscI", "Iesc" }        -- keep in sync with CurrSrc
local SENSCHECK_CURR_APPID = { 0x1012, 0x1042, 0x1090 }

local function senscheck_slot_uses(wgt, name)
    local o = wgt.options
    if not o then return false end
    for i = 1, #PANEL_SLOT_KEYS  do if o[PANEL_SLOT_KEYS[i]]  == name then return true end end
    for i = 1, #DETAIL_SLOT_KEYS do if o[DETAIL_SLOT_KEYS[i]] == name then return true end end
    return false
end

-- Required: MISS here drives the red summary. Order = display order.
local SENSCHECK_REQUIRED = {
    { name = "ARM",  appId = 0x1202, lbl = "Arming state",    hint = "arming state unknown - callouts, stats and flight time will not work" },
    { name = "Vbat", appId = 0x1011, lbl = "Battery voltage", hint = "no battery voltage - voltage alerts and cell check dead" },
    { name = "Bat%", appId = 0x1014, lbl = "Fuel percent",    hint = "no fuel percent - fuel gauge and fuel callouts dead" },
    { name = "Cel#", appId = 0x1020, lbl = "Cell count",      hint = "no cell count - cell voltage display degraded" },
    { name = "Vcel", appId = 0x1021, lbl = "Cell voltage",    hint = "no cell voltage - voltage alerts use pack voltage only" },
    { name = "Hspd", appId = 0x10C0, lbl = "Headspeed",       hint = "no headspeed - flight time will not count, no rpm display" },
    -- hintf (not hint): with gov_mode OFF/LIMIT the Gov sensor is a constant 0 by design
    -- and min/max tracking runs on the armed+headspeed fallback -> not "degraded"
    { name = "Gov",  appId = 0x1205, lbl = "Governor state",
      hintf = function(o, wgt)
          if wgt.values.rf_gov_has_state == false then
              return "governor mode " .. (wgt.values.rf_gov_mode_name or "off") ..
                     " - min/max tracked while armed + rotor spinning"
          end
          return "no governor state - run min/max tracking degraded"
      end },
    { name = "RQly", appId = nil,    lbl = "Link quality",    hint = "no link quality - link bar and link alert dead" },
}

-- Feature: shown only when the owning feature is active (gate(o,wgt) or always).
-- redmiss(o,wgt) true => a MISS counts as required-red (only the current source,
-- and only when ESC-load monitoring needs it). All others are yellow advisories.
local SENSCHECK_FEATURES = {
    { lbl = "Current source", hint = "no current - the Current row, ESC load and current min/max stay blank",
      namef = function(o) return SENSCHECK_CURR_NAMES[(o.CurrSrc or 1)] or "Curr" end,
      idf   = function(o) return SENSCHECK_CURR_APPID[(o.CurrSrc or 1)] or 0x1012 end,
      redmiss = function(o) return o.EscMon == 1 end },
    { name = "Capa", appId = 0x1013, lbl = "Energy used",   hint = "no mAh used - energy display blank" },
    { name = "Vbec", appId = 0x1081, lbl = "BEC voltage",   hint = "no BEC voltage - BEC alert dead",
      gate = function(o, wgt) return o.SndBec == 1 or senscheck_slot_uses(wgt, "Vbec") end },
    { name = "1RSS", appId = nil,    lbl = "RSSI (ant 1)",  hint = "no RSSI - RSSI display/alert dead",
      gate = function(o) return o.SndRssi == 1 or o.ShowRSSI == 1 end },
    { name = "2RSS", appId = nil,    lbl = "RSSI (ant 2)",  hint = "no 2nd-antenna RSSI",
      gate = function(o, wgt) return (o.SndRssi == 1 or o.ShowRSSI == 1) and wgt.values.elrs_diversity end },
    -- altname: the sensor is "*Skp" on newer telemetry, "Skp" on older stacks — the
    -- alert engine accepts either (read_skp's sticky name), so the check must too,
    -- or an older setup shows MISS for a perfectly working skip alert
    { name = "*Skp", altname = "Skp", appId = nil, lbl = "Skipped frames", hint = "no skipped-frame count - skip alert dead",
      gate = function(o) return o.SkpWarn == 1 end },
    { name = "ARMD", appId = 0x1203, lbl = "Arming flags",  hint = "no arming-disable flags - arming reasons blank" },
    { name = "Esc#", appId = 0x104F, lbl = "ESC status",    hint = "no ESC status - ESC fault decoder blank" },
    { name = "EscF", appId = 0x104E, lbl = "ESC faults",    hint = "no ESC fault flags - ESC fault decoder blank" },
    { name = "PID#", appId = 0x1211, lbl = "PID profile",   hint = "no PID profile - profile line blank" },
    { name = "RTE#", appId = 0x1212, lbl = "Rate profile",  hint = "no rate profile - profile line blank" },
    { name = "BAT#", appId = 0x1214, lbl = "Battery profile", hint = "no battery profile - profile line blank" },
    { name = "TQly", appId = nil,    lbl = "Uplink quality", hint = "no uplink quality",
      gate = function(o) return o.ShowTQly == 1 end },
    { name = "TPWR", appId = nil,    lbl = "TX power",       hint = "no TX power",
      gate = function(o) return o.ShowTPWR == 1 end },
    { name = "Tesc", appId = 0x10A0, lbl = "ESC temp",      hint = "no ESC temperature - ESC temp alert dead",
      gate = function(o, wgt) return senscheck_slot_uses(wgt, "Tesc") or (o.SndTemp == 1 and (o.TescWarn or 0) > 0) end },
    { name = "Tmcu", appId = 0x10A3, lbl = "MCU temp",      hint = "no MCU temperature - MCU temp alert dead",
      gate = function(o, wgt) return senscheck_slot_uses(wgt, "Tmcu") or (o.SndTemp == 1 and (o.TmcuWarn or 0) > 0) end },
}

local function senscheck_present(by_id, by_name, name, appId)
    if appId and by_id[appId] then return true end
    if name and by_name[name] then return true end
    if name and appId == nil then
        local ok, fi = pcall(getFieldInfo, name)
        if ok and type(fi) == "table" then return true end
    end
    return false
end

-- "present" (has live data) | "nodata" (discovered, no value now) | "absent" (never discovered)
-- Second return: the live value itself (diagnostic display on the page).
local function senscheck_live(wgt, conn, by_id, by_name, name, appId)
    if not senscheck_present(by_id, by_name, name, appId) then return "absent" end
    if name == nil then return "present" end
    -- disconnected: read_src would serve the last stale/zero reading, so a green OK
    -- contradicted both reality and the page's own "discovered state only" note --
    -- a discovered sensor without a live FC is "--"
    if not conn then return "nodata" end
    local live = ultidash_functions.read_src(wgt, name)
    return (live ~= nil) and "present" or "nodata", live
end

-- Rebuild wgt.senscheck (data model only; the page reads it reactively). One model
-- scan + ~10 name lookups + live reads; runs at most 1 Hz while the page is open.
local function update_sensorcheck(wgt)
    local o = wgt.options or {}
    -- live values are shown only while the FC is connected — disconnected, getValue
    -- would serve stale/zero readings that contradict the "discovered state only" note
    local st = wgt.values.rf_connection_state
    local conn = (st ~= nil and st ~= "disconnected")
    -- compact live-value readout: integers plain, everything else one decimal
    -- (nested: the main chunk sits at the 200-locals limit; this runs at 1 Hz)
    local function senscheck_fmt(v)
        if type(v) ~= "number" then return nil end
        if v % 1 == 0 then return tostring(v) end
        return string.format("%.1f", v)
    end
    local by_id, by_name = {}, {}
    if model ~= nil and type(model.getSensor) == "function" then
        for i = 0, 59 do
            local ok, s = pcall(model.getSensor, i)
            if ok and type(s) == "table" and type(s.name) == "string" and s.name ~= "" then
                by_name[s.name] = true
                if type(s.id) == "number" then by_id[s.id] = true end
            end
        end
    end
    local rows, req_missing = {}, 0
    local function add(r) rows[#rows + 1] = r end
    -- FREEZE the structural identity (gated feature list + slot list) on the FIRST
    -- build of this page-open: the reactive row closures capture their build-time
    -- index into wgt.senscheck.rows, so a gate flipping mid-view (e.g. the diversity
    -- latch discovering 2RSS) would change the row count and shift every closure one
    -- off. Statuses/values stay live; the row SET updates on the next open.
    local prior = wgt.senscheck

    add({ header = "Required" })
    do  -- RFTool present (not a sensor)
        local ok = wgt.rf ~= nil and wgt.rf.available == true
        if not ok then req_missing = req_missing + 1 end
        add({ lbl = "RFTool widget", status = ok and "ok" or "miss",
              hint = "RFTool widget not running - no connection state, no MSP" })
    end
    do  -- RF2 telemetry decoder ran at least once (*Cnt is created unconditionally)
        local present = senscheck_present(by_id, by_name, "*Cnt", nil)
        if not present then req_missing = req_missing + 1 end
        add({ lbl = "RF2 telemetry", status = present and "ok" or "miss",
              hint = "RF2 custom telemetry not discovered - run 'Discover new sensors' with the FC powered" })
    end
    for i = 1, #SENSCHECK_REQUIRED do
        local d = SENSCHECK_REQUIRED[i]
        local live, lv = senscheck_live(wgt, conn, by_id, by_name, d.name, d.appId)
        local status = (live == "present") and "ok" or (live == "nodata") and "nodata" or "miss"
        if status == "miss" then req_missing = req_missing + 1 end
        add({ lbl = d.lbl, name = d.name, status = status,
              hint = (d.hintf ~= nil) and d.hintf(o, wgt) or d.hint,
              val = conn and senscheck_fmt(lv) or nil })
    end

    local feat = prior ~= nil and prior.feat or nil
    if feat == nil then
        feat = {}
        for i = 1, #SENSCHECK_FEATURES do
            local d = SENSCHECK_FEATURES[i]
            if d.gate == nil or d.gate(o, wgt) then feat[#feat + 1] = d end
        end
    end
    if #feat > 0 then
        add({ header = "Active features" })
        for i = 1, #feat do
            local d = feat[i]
            local name  = d.namef and d.namef(o) or d.name
            local appId = d.idf and d.idf(o) or d.appId
            local live, lv = senscheck_live(wgt, conn, by_id, by_name, name, appId)
            -- older telemetry generation: accept the alternate sensor name
            -- ("*Skp" vs "Skp") before reporting the feature's sensor as missing
            if live == "absent" and d.altname ~= nil
                and senscheck_present(by_id, by_name, d.altname, nil) then
                name = d.altname
                live, lv = senscheck_live(wgt, conn, by_id, by_name, d.altname, nil)
            end
            local status
            if live == "present" then status = "ok"
            elseif live == "nodata" then status = "nodata"
            elseif d.redmiss and d.redmiss(o, wgt) then status = "miss"; req_missing = req_missing + 1
            else status = "missopt" end
            add({ lbl = d.lbl, name = name, status = status, hint = d.hint,
                  val = conn and senscheck_fmt(lv) or nil })
        end
    end

    local slots = prior ~= nil and prior.slots or nil
    if slots == nil then
        local seen = {}
        slots = {}
        local function add_slot(key)
            local nm = o[key]
            if nm == nil or nm == "" or seen[nm] then return end
            if nm == SENSOR_OFF or nm == VOLT_AUTO or nm == ESCL_AUTO or nm == RAW_SENTINEL then return end
            seen[nm] = true; slots[#slots + 1] = nm
        end
        for i = 1, #PANEL_SLOT_KEYS  do add_slot(PANEL_SLOT_KEYS[i])  end
        for i = 1, #DETAIL_SLOT_KEYS do add_slot(DETAIL_SLOT_KEYS[i]) end
    end
    if #slots > 0 then
        add({ header = "Value slots" })
        for i = 1, #slots do
            local nm = slots[i]
            local info = SENSOR_INFO[nm]
            local status, lv
            -- Raw picks: the stored name is a SOURCE display string (channel,
            -- TxBt, ...), not a model sensor -- the name lookup below reported MISS for
            -- perfectly working slots. The 5 Hz pass verifies the picker's index in
            -- wgt.raw_src; a verified index IS present, its value reads by index.
            local rs = is_raw_sensor(nm) and wgt.raw_src ~= nil and wgt.raw_src[nm] or nil
            if rs ~= nil and rs.ok then
                if conn then
                    local okv, v = pcall(getSourceValue, rs.v)
                    lv = (okv and type(v) == "number") and v or nil
                    status = (lv ~= nil) and "ok" or "nodata"
                else
                    status = "nodata"
                end
            else
                local live
                live, lv = senscheck_live(wgt, conn, by_id, by_name, nm, info and info.appId or nil)
                status = (live == "present") and "ok" or (live == "nodata") and "nodata" or "missopt"
            end
            add({ lbl = info and info.lbl or "raw pick", name = nm, status = status,
                  hint = "sensor not found - check the slot's raw pick / spelling",
                  val = conn and senscheck_fmt(lv) or nil })
        end
    end

    wgt.senscheck = { rows = rows, req_missing = req_missing, ts = getTime() or 0,
                      feat = feat, slots = slots }   -- feat/slots = the frozen identity
end

-- Scrollable page. Built ONCE per open from a fresh snapshot; the status chips
-- update reactively from wgt.senscheck (pure table reads). MISS/present is
-- structurally stable within a session (discovery does not happen while viewing),
-- so the hint line is reserved at build time only for build-time-absent rows;
-- only OK<->-- (live value) flips reactively.
local function build_sensorcheck_view(wgt, zone)
    if wgt.senscheck == nil then
        -- First open: only the page frame + a scanning note — the first scan runs
        -- in the host's 1 Hz senscheck tick in its OWN cycle; inline it
        -- put the build + ~60 getSensor reads into one call (14.9k connected).
        -- senscheck_next=0 makes the tick due immediately; its first fill flags
        -- the row rebuild, so the note is up for ~2 frames.
        wgt.senscheck_next = 0
        local pg = lvgl.page({
            title = "UltiDash", subtitle = "Sensor check",
            back = function() wgt.menu_view = "menu"; init_view_state(wgt).dirty = true end,
        })
        local _, std_h = lcd.sizeText("Ag", 0)
        pg:label({ x = 10, y = 2, w = zone.w - 24, h = std_h + 4, font = 0,
                   align = LEFT, color = COLOR_DIM, text = "Scanning sensors ..." })
        return
    end
    local w = zone.w
    local pg = lvgl.page({
        title = "UltiDash", subtitle = "Sensor check",
        back = function() wgt.menu_view = "menu"; init_view_state(wgt).dirty = true end,
    })
    -- Row anatomy (readability pass): [ pill badge ] Friendly name ......... code
    -- The badge is a filled rounded rect coloured by status (reactive) instead of a
    -- small coloured text chip, and the name uses the STANDARD font — the all-SMLSIZE
    -- rows were hard to read at arm's length. Hints stay small and dimmed.
    local _, sml_h = lcd.sizeText("Ag", SMLSIZE)
    local _, std_h = lcd.sizeText("Ag", 0)
    local badge_w = lcd.sizeText("MISS", SMLSIZE) + 16
    local badge_h = sml_h + 6
    local white = lcd.RGB(0xFF, 0xFF, 0xFF)
    local name_x = 10 + badge_w + 10
    -- right column: "live value  code" while connected, code alone otherwise — sized
    -- for a worst-case reading so headspeed-length values never clip
    local code_w = lcd.sizeText("2380.5  ARMD", SMLSIZE) + 10
    local name_w = w - name_x - code_w - 22
    local hint_w = w - name_x - 16
    local row_h = math.max(badge_h, std_h) + 8

    pg:label({ x = 10, y = 2, w = w - 24, h = std_h + 4, font = 0, align = LEFT,
        text = function()
            local sc = wgt.senscheck
            local n = sc and sc.req_missing or 0
            if n == 0 then return "All required sensors OK" end
            return n .. " required sensor(s) missing"
        end,
        color = function()
            return (wgt.senscheck and (wgt.senscheck.req_missing or 0) > 0) and SEM_RED or SEM_GREEN
        end })
    pg:label({ x = 10, y = 2 + std_h + 8, w = w - 24, h = sml_h + 2, font = SMLSIZE, color = COLOR_DIM, align = LEFT,
        text = function()
            local st = wgt.values.rf_connection_state
            if st == nil or st == "disconnected" then
                return "FC not connected - showing discovered state only"
            end
            return ""
        end })

    local y = 2 + std_h + 8 + sml_h + 8 + 4
    local rows = wgt.senscheck.rows
    local elems = {}
    for idx = 1, #rows do
        local r = rows[idx]
        if r.header then
            -- section header, underlined across the page (same look as the settings pages)
            y = y + 6
            elems[#elems + 1] = { type = "label", x = 10, y = y, w = w - 24, h = sml_h + 2,
                                  text = r.header, font = SMLSIZE, color = COLOR_THEME_FOCUS, align = LEFT }
            elems[#elems + 1] = { type = "rectangle", x = 10, y = y + sml_h + 4, w = w - 30, h = 1,
                                  filled = true, color = COLOR_THEME_FOCUS }
            y = y + sml_h + 10
        else
            local ri = idx
            local function status()
                local rr = wgt.senscheck and wgt.senscheck.rows[ri]
                return rr and rr.status
            end
            local by = y + math.floor((row_h - 8 - badge_h) / 2) + 2
            elems[#elems + 1] = { type = "rectangle", x = 10, y = by, w = badge_w, h = badge_h,
                filled = true, rounded = math.floor(badge_h / 2),
                color = function()
                    local s = status()
                    if s == "ok" then return SEM_GREEN elseif s == "miss" then return SEM_RED
                    elseif s == "missopt" then return SEM_YELL end
                    return SEM_NEUT
                end }
            elems[#elems + 1] = { type = "label", x = 10, y = by + math.floor((badge_h - sml_h) / 2),
                w = badge_w, h = sml_h + 2, font = SMLSIZE, align = CENTER,
                text = function()
                    local s = status()
                    if s == "ok" then return "OK"
                    elseif s == "miss" or s == "missopt" then return "MISS" end
                    return "--"
                end,
                -- black on the yellow badge, white on the rest
                color = function() return (status() == "missopt") and BLACK or white end }
            elems[#elems + 1] = { type = "label", x = name_x, y = y + math.floor((row_h - 6 - std_h) / 2),
                w = name_w, h = std_h + 2, text = r.lbl or "", font = 0, color = COLOR_THEME_PRIMARY1, align = LEFT }
            if r.name then
                -- reactive "value  code" readout, memoized on the 1 Hz-updated value so
                -- the per-frame closure is a table read, not a string build
                local rc_val, rc_str
                elems[#elems + 1] = { type = "label", x = w - 12 - code_w, y = y + math.floor((row_h - 6 - sml_h) / 2) + 2,
                    w = code_w, h = sml_h + 2, font = SMLSIZE, color = COLOR_DIM, align = RIGHT,
                    text = function()
                        local rr = wgt.senscheck and wgt.senscheck.rows[ri]
                        local v = rr and rr.val
                        if rc_str == nil or v ~= rc_val then
                            rc_val = v
                            local code = (rr and rr.name) or ""
                            rc_str = v and (v .. "  " .. code) or code
                        end
                        return rc_str
                    end }
            end
            y = y + row_h
            if r.status == "miss" or r.status == "missopt" then
                local lines = math.max(1, math.ceil(lcd.sizeText(r.hint, SMLSIZE) / (hint_w * 0.9)))
                local hh = lines * sml_h + 4
                elems[#elems + 1] = { type = "label", x = name_x, y = y - 2, w = hint_w, h = hh,
                                      text = r.hint, font = SMLSIZE, color = COLOR_DIM, align = LEFT }
                y = y + hh
            end
        end
    end
    -- legend: the OK / -- / MISS distinction is not self-explanatory
    local legend = "OK = live data    -- = discovered, no data    MISS = not found"
    local lg_lines = math.max(1, math.ceil(lcd.sizeText(legend, SMLSIZE) / ((w - 24) * 0.9)))
    elems[#elems + 1] = { type = "label", x = 10, y = y + 8, w = w - 24, h = lg_lines * sml_h + 2,
                          text = legend, font = SMLSIZE, color = COLOR_DIM, align = LEFT }
    pg:build(elems)
end

-- Colors submenu: one page per scheme, each listing that scheme's configurable colour roles
-- (grouped by section) as kind="color" rows. Generated from COLOR_ROLES so the keys, defaults
-- and picker all stay in sync from the one table. def = -1 -> "unset" (follow the built-in).
local function build_color_page_items(scheme)
    local items = {}
    local last_grp = nil
    for i = 1, #COLOR_ROLES do
        local role = COLOR_ROLES[i]
        if role_in_scheme(role, scheme) then
            if role.grp ~= last_grp then
                items[#items + 1] = { kind = "section", lbl = role.grp }
                last_grp = role.grp
            end
            items[#items + 1] = { kind = "color", key = color_key(scheme, role),
                                  lbl = role.lbl, def = -1, role = role, scheme = scheme }
        end
    end
    return items
end

--- Build the settings page (lvgl.page scrolls; its back arrow catches RTN, the
--- unfocused-RTN case is handled in refresh). One group per page, opened by name
--- from the menu's group list (back returns there). Rows = name label + REACTIVE value
--- label + plain buttons: bools/choices cycle with [>], numbers use [-]/[+] (long press
--- = big step); the Volume group additionally uses pg:slider. Presses only
--- mutate the working copy — the reactive labels update by themselves, so the
--- page is never rebuilt while editing and the scroll position survives.
--- Back/RTN/arming/fullscreen-exit all AUTOSAVE (see save_pending_settings).
local function build_settings_view(wgt, zone)
    if not wgt.settings_working then
        -- Seed the working copy in its OWN call: the full-catalog walk
        -- costs ~7k instructions, and sharing the call with the page build pushed
        -- the big pages' first-open over the budget (Colors ~16.5k). Seed, flag a
        -- rebuild via the existing rf_data_dirty plumbing (host refresh() turns it
        -- into dirty for any open menu page), and return — the build then runs with
        -- a fresh budget. Costs 2-3 invisible frames (~100-150 ms) at page open;
        -- same staggering idea as settings_apply_pending. Autosave is safe in the
        -- window (save_pending_settings nil-guards settings_working).
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
        -- remember which cfg file these edits belong to: autosave discards
        -- the copy when the target moved mid-edit (model switch / craft rename)
        wgt.settings_target = ultidash_settings.target_path
            and ultidash_settings.target_path() or nil
        wgt.rf_data_dirty = true
        return
    end
    local working = wgt.settings_working

    -- The page to render is a {name, items, back} spec set when it was opened
    -- (a normal group, or one alert sub-page). Fall back to the first group.
    local grp = wgt.settings_page or SETTINGS_GROUPS[1]

    -- one page opened by name from the menu (no blind ‹ › tab cycling); the back
    -- arrow / RTN returns to that list (grp.back) and autosaves.
    local pg = lvgl.page({
        title = grp.name,
        -- breadcrumb: alert sub-pages sit two levels deep, so name the path
        subtitle = (grp.back == "alerts_menu") and "Settings > Alerts"
                or (grp.back == "colors_menu") and "Settings > Colors"
                or (grp.back == "sub_menu") and ("Settings > " .. ((wgt.settings_sub and wgt.settings_sub.name) or ""))
                or "UltiDash settings",
        back = function() close_settings(wgt) end,
    })

    local w = zone.w
    -- index of the trailing ‹ Raw › display entry in the shared sensor list (same
    -- for every row), used to show the raw state in each curated dropdown
    local se_raw_idx = 1
    -- sensor pick list (Off + smart-voltage + known model sensors + ‹ Raw ›): built once
    -- per page build and shared by every kind="sensor" row. build_sensor_list walks all 60
    -- model sensor slots (60 pcall(model.getSensor)) -> a heavy fixed cost. Build it ONLY
    -- when THIS page actually has a sensor row; the many sensor-free pages (Shortcuts,
    -- Colors, Volume, Thresholds ...) skip it entirely. has_sensor is detected in the
    -- width-measure loop just below and the list is built after it.
    local se_labels, se_codes
    -- row height adapts to the screen: EdgeTX toggle switches are ~40 px tall on
    -- the 800x480 TX16S and overlapped each other in 38 px rows. Both supported radios
    -- (800x480 MK3, 480x320 TX15) take the >= 300 branch; the 38-px rows are a reserve
    -- for smaller radios (480x272 class).
    local row_h = (zone.h >= 300) and 50 or 38
    -- measure the STDSIZE label height (rule 8): a hardcoded 24/22 clipped descenders on the
    -- taller TX16S font. Labels are lbl_h + 2 tall, vertically centred in the row.
    local _, lbl_h = lcd.sizeText("Ag", 0)
    local lbl_dy = math.floor((row_h - lbl_h) / 2)
    -- stepper [-]/[+] touch targets scale with the panel (a fixed 40 px was small on the
    -- 800x480 TX16S), capped so they don't crowd the value on the TX15
    local btn_w = math.min(72, math.floor(40 * (lvgl.LCD_SCALE or 1)))
    local right = w - 20            -- keep clear of the scrollbar
    -- COLUMN ALIGNMENT (readability): every control ends flush at `right`, and all rows of a
    -- kind share ONE width across the page, so their left edges line up instead of jittering
    -- from row to row. Both widths are measured once per build (never assume font widths):
    --   val_w    widest formatted stepper value ON THIS PAGE (fmt at both ends of its range;
    --            "until cleared" is fmt(0) of a repeat count, so a fixed 120 px made every
    --            page as wide as the widest one)
    --   uni_cyc_w widest dropdown value on this page
    local val_w, uni_cyc_w = 80, 100
    local has_sensor = false
    for i = 1, #grp.items do
        local it = grp.items[i]
        if it.kind == "num" then
            local f = it.fmt or tostring
            local vw = math.max(lcd.sizeText(f(it.min or 0), 0), lcd.sizeText(f(it.max or 0), 0)) + 8
            if vw > val_w then val_w = vw end
        elseif it.kind == "choice" then
            for vi = 1, #it.vals do
                local tw = lcd.sizeText(it.vals[vi], 0) + 40
                if tw > uni_cyc_w then uni_cyc_w = tw end
            end
        elseif it.kind == "sensor" then
            has_sensor = true
        end
    end
    local cyc_cap = math.floor(w * 0.45)
    if uni_cyc_w > cyc_cap then uni_cyc_w = cyc_cap end
    -- only pages with a sensor row pay for the 60-slot model sensor scan (see above)
    if has_sensor then
        se_labels, se_codes = build_sensor_list(wgt)
        for ci = 1, #se_codes do if se_codes[ci] == RAW_SENTINEL then se_raw_idx = ci; break end end
    end
    -- EdgeTX draws pg:toggle at its own fixed size (no width parameter); this is the measured
    -- footprint per panel, used only to right-align it with the fields above/below it.
    local tgl_w = (w < 600) and 60 or 90
    -- picker boxes (choice / sensor / switch) only need to fit one text line; size to the
    -- actual font height plus a little padding, centred vertically in the row.
    local field_h = math.min(row_h - 4, lbl_h + 8)
    local function field_y(ry) return ry + math.floor((row_h - field_h) / 2) end
    -- info rows wrap to N lines of the small font; the height is computed per row below
    -- (the long ESC hint needs 3 lines on the TX15). section headers get their own height.
    local _, sml_h = lcd.sizeText("Ag", SMLSIZE)
    local elems = {}
    -- resolve_builtins is a handful of lcd.RGB allocations; memoise per scheme so a colour
    -- page (up to 16 rows sharing one scheme) computes it once, not per row (build budget).
    local rb_cache = {}
    local function page_builtins(s)
        local b = rb_cache[s]
        if b == nil then b = resolve_builtins(s); rb_cache[s] = b end
        return b
    end

    -- running vertical cursor: rows have per-kind heights (info rows are taller),
    -- so positions are accumulated rather than derived from the index
    local ry = 2
    for i = 1, #grp.items do
        local it = grp.items[i]
        -- per-kind row height: info wraps to as many small-font lines as its text needs
        -- (10 % safety margin because LVGL breaks on word boundaries); section headers are a
        -- single small line with a little breathing room above; everything else is one row.
        local row_this
        if it.kind == "info" then
            local lines = math.ceil(lcd.sizeText(it.lbl, SMLSIZE) / math.max(1, (right - 10) * 0.9))
            row_this = math.max(1, lines) * sml_h + 8
        elseif it.kind == "section" then
            row_this = sml_h + 10
        else
            row_this = row_h
        end
        local is_num = it.kind == "num"

        -- value text resolver (reactive), memoized on the raw working value: the label runs
        -- per render frame but the value only moves on a tap/step, so re-format only on change.
        -- For switch rows the getSourceName lookup also rides the memo (only on change).
        local vt_last, vt_str, vt_primed
        local function value_text()
            local raw = working[it.key]
            if vt_primed and raw == vt_last then return vt_str end
            local s
            if it.kind == "bool" then s = (raw == 1) and "On" or "Off"
            elseif it.kind == "choice" then s = it.vals[raw or 1] or "?"
            elseif it.kind == "sensor" then s = sensor_pick_label(raw)
            elseif it.kind == "switch" then
                -- fallback-only readout (the native picker renders its own text):
                -- signed source index -> source name, "!" marks the inverted pick
                local v = raw or 0
                if v == 0 then s = "Off"
                else
                    local okn, n = pcall(getSourceName, math.abs(v))
                    local name = (okn and n) and n or tostring(math.abs(v))
                    s = (v < 0) and ("!" .. name) or name
                end
            elseif it.kind == "swpos" then
                -- fallback-only readout: swsrc index -> position name ("SA-up")
                local v = raw or 0
                if v == 0 then s = "---"
                else
                    local okn, n = pcall(getSwitchName, v)
                    s = (okn and n) and n or tostring(v)
                end
            else
                local v = raw or it.min or 0
                s = it.fmt and it.fmt(v) or tostring(v)
            end
            vt_last, vt_str, vt_primed = raw, s, true
            return s
        end

        -- dimmed label colour when this row is inert (depends on another setting). Reads only
        -- the working copy -> cheap per frame. Only LABELS dim; native controls stay usable
        -- (dimming signals "no effect", it does not lock the control). Uses COLOR_DIM (a real
        -- muted grey per scheme) -- NOT COLOR_THEME_DISABLED, which the UltiDash palette
        -- repurposes as an orange accent.
        local label_color = it.dim
            and function() return it.dim(working) and COLOR_DIM or COLOR_THEME_PRIMARY1 end
            or COLOR_THEME_PRIMARY1

        if it.kind == "info" then
            -- non-interactive hint line: muted, small font, wraps to its measured line count
            elems[#elems + 1] = { type = "label", x = 10, y = ry + 2, w = right - 10, h = row_this - 4,
                                  text = it.lbl, font = SMLSIZE, color = COLOR_DIM }
        elseif it.kind == "section" then
            -- section header (structure, not a hint): coloured small label with space above,
            -- underlined across the page so the rows below read as one block
            elems[#elems + 1] = { type = "label", x = 10, y = ry + 8, w = right - 10, h = sml_h + 2,
                                  text = it.lbl, font = SMLSIZE, color = COLOR_THEME_FOCUS }
            elems[#elems + 1] = { type = "rectangle", x = 10, y = ry + row_this - 1, w = right - 10, h = 1,
                                  filled = true, color = COLOR_THEME_FOCUS }
        elseif it.kind == "slider" then
            -- name + reactive % + real LVGL slider (pg:slider — verified 2.12: h is
            -- ignored, w sets the length). Falls back to a -/+ stepper if the
            -- firmware lacks the slider control.
            local sl_w = math.min(300, math.floor(w * 0.40))
            local sl_x = right - sl_w
            local val_w2 = 66
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = sl_x - val_w2 - 16, h = lbl_h + 2,
                                  text = it.lbl, color = label_color }
            elems[#elems + 1] = { type = "label", x = sl_x - val_w2 - 6, y = ry + lbl_dy, w = val_w2, h = lbl_h + 2,
                                  text = value_text, color = label_color, align = RIGHT }
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
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = val_x - 14, h = lbl_h + 2,
                                  text = it.lbl, color = label_color }
            elems[#elems + 1] = { type = "label", x = val_x, y = ry + lbl_dy, w = val_w, h = lbl_h + 2,
                                  text = value_text, color = label_color, align = CENTER }
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
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = right - tgl_w - 24, h = lbl_h + 2,
                                  text = it.lbl, color = label_color }
            local okt = pcall(function()
                pg:toggle({ x = right - tgl_w, y = ry + math.floor((row_h - (lvgl.UI_ELEMENT_HEIGHT or 32)) / 2),
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
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = right - cyc_w - 24, h = lbl_h + 2,
                                  text = it.lbl, color = label_color }
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
                elems[#elems + 1] = { type = "label", x = right - cyc_w - 80, y = ry + lbl_dy, w = cyc_w + 80, h = lbl_h + 2,
                                      text = value_text, color = COLOR_THEME_WARNING, align = RIGHT }
            end
        elseif it.kind == "swpos" then
            -- NATIVE switch-POSITION selection (lvgl.switch = SwitchChoice): one
            -- popup picks switch + position ("SA-up", logical switches included) and
            -- exchanges a swsrc index (0 = none via the clear entry). Read at runtime
            -- with getSwitchValue — no separate position dropdown needed.
            local cyc_w = 140
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = right - cyc_w - 24, h = lbl_h + 2,
                                  text = it.lbl, color = label_color }
            local oks = pcall(function()
                local filt = (lvgl.SW_SWITCH or 0) | (lvgl.SW_LOGICAL_SWITCH or 0)
                    | (lvgl.SW_CLEAR or 0)
                pg:switch({ x = right - cyc_w, y = field_y(ry), w = cyc_w, h = field_h,
                    filter = filt,
                    get = function() return working[it.key] or 0 end,
                    set = function(v) working[it.key] = v or 0 end })
            end)
            if not oks then
                -- firmware without lvgl.switch: read-only display
                elems[#elems + 1] = { type = "label", x = right - cyc_w - 80, y = ry + lbl_dy, w = cyc_w + 80, h = lbl_h + 2,
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
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = cyc_x - 14, h = lbl_h + 2,
                                  text = it.lbl, color = label_color }
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
        elseif it.kind == "color" then
            -- native EdgeTX colour picker (pg:color renders its own swatch button and opens
            -- the colour popup on tap) + a "Def" button that resets this colour to the scheme's
            -- built-in. The picker exchanges an EdgeTX colour value; we store it as 0xRRGGBB
            -- (-1 = unset -> follow the built-in). resolve_builtins for THIS row's scheme is
            -- computed once at build time (the get() closure captures it) — the page may be
            -- editing a scheme other than the one currently rendered.
            local role   = it.role
            local scheme = it.scheme or SCHEME_ULTIDASH
            local b      = page_builtins(scheme)
            local sw_w   = math.min(110, math.floor(w * 0.16))
            local def_w  = btn_w
            local sw_x   = right - sw_w
            local def_x  = sw_x - def_w - 8
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = def_x - 14, h = lbl_h + 2,
                                  text = it.lbl, color = label_color }
            -- "Def" resets to the built-in (working -1); the reactive swatch follows at once.
            -- Same height/baseline as the swatch (field_h/field_y) so the row reads as one unit.
            elems[#elems + 1] = { type = "button", x = def_x, y = field_y(ry), w = def_w, h = field_h,
                                  text = "Def",
                                  press = function() working[it.key] = -1 end }
            local okcol = pcall(function()
                pg:color({ x = sw_x, y = field_y(ry), w = sw_w, h = field_h,
                    get = function() return role_color(b, role, working[it.key]) end,
                    set = function(c) working[it.key] = picker_rgb24(c) end })
            end)
            if not okcol then
                -- firmware without lvgl.color: show the value read-only (RGB hex / "default").
                -- Starts RIGHT of the Def button (the old x = sw_x - 40 overdrew the
                -- button on the TX15) and spans the whole swatch zone instead.
                -- An RGB-slider fallback editor is the planned follow-up if the native picker's
                -- palette proves too limited on hardware.
                local fx = def_x + def_w + 6
                elems[#elems + 1] = { type = "label", x = fx, y = ry + lbl_dy, w = right - fx, h = lbl_h + 2,
                                      align = RIGHT, color = COLOR_DIM,
                                      text = function()
                                          local v = working[it.key]
                                          if type(v) == "number" and v >= 0 then
                                              return string.format("#%06X", v)
                                          end
                                          return "default"
                                      end }
            end
        elseif it.kind == "action" then
            -- label + a right-aligned push button (e.g. "Test callout / Play"): fires
            -- it.act(wgt, working) — the action sees the page's unsaved working values
            local aw = math.max(btn_w + 16, lcd.sizeText(it.btn or "Play", 0) + 24)
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = right - aw - 14, h = lbl_h + 2,
                                  text = it.lbl, color = label_color }
            elems[#elems + 1] = { type = "button", x = right - aw, y = ry, w = aw, h = row_h - 6,
                                  text = it.btn or "Play",
                                  press = function() it.act(wgt, working) end }
        else
            -- real dropdown (lvgl.choice popup picker, 1-based indices like our CHOICE
            -- values); one shared width per page (uni_cyc_w) so the fields line up
            local cyc_w = uni_cyc_w
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = right - cyc_w - 24, h = lbl_h + 2,
                                  text = it.lbl, color = label_color }
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

        -- hairline between consecutive DATA rows: it separates label/value pairs without
        -- boxing them in. Skipped before a section header (which brings its own gap + rule)
        -- and after the last row, so no line ever dangles above the reset divider.
        if it.kind ~= "info" and it.kind ~= "section" then
            local nx = grp.items[i + 1]
            if nx and nx.kind ~= "section" then
                elems[#elems + 1] = { type = "rectangle", x = 10, y = ry + row_this - 1,
                                      w = right - 10, h = 1, filled = true, color = COLOR_DIM }
            end
        end
        ry = ry + row_this
    end

    -- long-press discoverability hint, generic: only on pages with 2+ steppers (so it never
    -- shows on toggle/picker-only pages). Measured line count like the info rows.
    local num_rows = 0
    for i = 1, #grp.items do if grp.items[i].kind == "num" then num_rows = num_rows + 1 end end
    if num_rows >= 2 then
        local hint = "Tip: long press - / + for big steps"
        local lines = math.max(1, math.ceil(lcd.sizeText(hint, SMLSIZE) / math.max(1, (right - 10) * 0.9)))
        elems[#elems + 1] = { type = "label", x = 10, y = ry + 2, w = right - 10, h = lines * sml_h,
                              text = hint, font = SMLSIZE, color = COLOR_DIM }
        ry = ry + lines * sml_h + 8
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
    -- set the destructive reset apart: a divider + extra gap above it, and a warning-coloured
    -- label so it doesn't read like just another navigation button.
    elems[#elems + 1] = { type = "rectangle", x = 10, y = ry + 8, w = right - 10, h = 1, filled = true,
                          color = COLOR_THEME_SECONDARY1 }
    local reset_y = ry + 16
    -- Width tracks the label: a fixed 260 px clipped the longer group names ("Reset Tele
    -- Details to defaults" / "Reset Thresholds to defaults") on both sides because the
    -- button text is centered. Measure it (project rule: never assume font widths) and grow
    -- up to w-20, keeping 260 as a floor so short labels stay visually consistent.
    local reset_text = "Reset " .. grp.name .. " to defaults"
    local reset_tw = lcd.sizeText(reset_text, 0)   -- 0 = STDSIZE, the build-table button font
    local reset_w = math.max(260, math.min(w - 20, reset_tw + 28))
    elems[#elems + 1] = { type = "button", x = 10, y = reset_y, w = reset_w, h = row_h - 6,
        text = reset_text, textColor = COLOR_THEME_WARNING,
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
-- An item may be a section header ({ hdr = "..." }) instead of a button ({ txt, act }):
-- it takes a full row of its own, so the settings grid can group its buttons by theme.
-- reserve = px kept free BELOW the grid (a caller's own hint/button): the grid centers
-- above it and, if too tall, shrinks its rows/gaps toward a floor before overflowing
-- into scroll — otherwise the reserved element sits off-screen (Toolbox armed hint).
local function build_menu_grid(pg, w, h, items, cols, max_btn_w, reserve)
    local big = h >= 300
    local gap = big and math.max(10, math.floor(h * 0.02)) or 6
    local row_h = big and math.max(44, math.floor(h * 0.12)) or 36
    local btn_font = big and MIDSIZE or 0   -- 0 = STDSIZE (default)
    local side = math.max(16, math.floor(w * 0.05))
    local btn_w = math.floor((w - 2 * side - (cols - 1) * gap) / cols)
    -- single-column menus: cap relative to the screen, not just the fixed 460 px the
    -- callers pass — that cap never bit on a 480 px display, leaving edge-to-edge buttons
    if cols == 1 then
        local cap = math.floor(w * 0.65)
        if btn_w > cap then btn_w = cap end
    end
    if max_btn_w and btn_w > max_btn_w then btn_w = max_btn_w end
    -- Pick the largest button font whose widest label still fits: the alerts grid appends an
    -- "On"/"Off" status that overflows the default size on long names (esp. the TX15). Short-
    -- labelled grids keep the default size. Build-time only (menus aren't reactive per frame).
    do
        local pad = 14
        local candidates = (btn_font == MIDSIZE) and { MIDSIZE, 0, SMLSIZE } or { 0, SMLSIZE }
        for _, f in ipairs(candidates) do
            btn_font = f
            local widest = 0
            for i = 1, #items do
                if items[i].txt then
                    local tw = lcd.sizeText(items[i].txt, f)
                    if tw > widest then widest = tw end
                end
            end
            if widest <= btn_w - pad then break end
        end
    end
    local grid_w = cols * btn_w + (cols - 1) * gap
    local x0 = math.floor((w - grid_w) / 2)
    local _, sml_h = lcd.sizeText("Ag", SMLSIZE)
    local hdr_h = sml_h + (big and 6 or 3)
    -- pass 1: place everything relative to y=0 so the true block height (headers included,
    -- last row of a section possibly short) is known before the block is centered
    local function make_plan(rh, gp)
        local plan, cy, col = {}, 0, 0
        for i = 1, #items do
            local it = items[i]
            if it.hdr then
                if col > 0 then cy = cy + rh + gp; col = 0 end     -- finish a partial row
                if #plan > 0 then cy = cy + math.floor(gp / 2) end -- breathing room above
                plan[#plan + 1] = { hdr = it.hdr, y = cy }
                cy = cy + hdr_h
            else
                plan[#plan + 1] = { txt = it.txt, act = it.act, tcol = it.tcol,
                                    x = x0 + col * (btn_w + gp), y = cy }
                col = col + 1
                if col >= cols then col = 0; cy = cy + rh + gp end
            end
        end
        if col > 0 then cy = cy + rh + gp end
        return plan, math.max(0, cy - gp)
    end
    local plan, grid_h = make_plan(row_h, gap)
    -- page header (title + subtitle) eats the top of the zone; center in what's left,
    -- keeping the caller's reserved space free. If the grid overflows that space, shrink
    -- gaps then rows toward a floor (still comfortably tappable) before letting it scroll.
    local header_px = big and 56 or 40
    local min_y = big and 10 or 6
    local avail = h - header_px - (reserve or 0) - min_y
    local min_gap, min_row = (big and 6 or 4), (big and 34 or 28)
    while grid_h > avail and (gap > min_gap or row_h > min_row) do
        if gap > min_gap then gap = gap - 1 else row_h = row_h - 2 end
        plan, grid_h = make_plan(row_h, gap)
    end
    local y0 = math.max(min_y, math.floor((h - header_px - (reserve or 0) - grid_h) / 2))
    local elems = {}
    for i = 1, #plan do
        local p = plan[i]
        if p.hdr then
            elems[#elems + 1] = { type = "label", x = x0 + 2, y = y0 + p.y, w = grid_w - 4, h = hdr_h,
                                  text = p.hdr, font = SMLSIZE, color = COLOR_THEME_FOCUS }
        else
            local e = { type = "button", x = p.x, y = y0 + p.y,
                w = btn_w, h = row_h, text = p.txt, font = btn_font, press = p.act }
            if p.tcol then e.textColor = p.tcol end   -- dimmed (e.g. disarmed-only tools)
            elems[#elems + 1] = e
        end
    end
    pg:build(elems)
    return y0 + grid_h   -- bottom edge of the grid, so a caller can place its own button below
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
        { txt = "Settings",     act = open("settings_menu") },
        { txt = "Status",       act = open("status") },
        { txt = "Sensor check", act = open("sensorcheck") },
        { txt = "Toolbox",      act = open("toolbox") },
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
    -- ALL tools open through the ONE shared open path (env.shortcut_open -> host
    -- shortcut.open): it lazy-loads the module, refuses armed taps
    -- on the disarmed-only tools (sets the ~2 s hint below), clears stale close
    -- flags (lv_/fl_/rf2cfg_close_req — the menu path used to skip that, so a
    -- fresh page could shut itself in its first refresh) and sets tool_back —
    -- opened from THIS submenu, menu_view is "toolbox", so RTN unwinds back here.
    local function open_tool(view)
        return function() shortcut_open(wgt, view) end
    end
    -- availability flags live in the host (they may clear on a failed load) —
    -- pull them fresh per build via the env getter
    local tb_adjmap_avail, tb_adjed_avail, tb_logview_avail, tb_rf2cfg_avail = tb_avail()
    local items = {}
    if tb_adjmap_avail then
        items[#items + 1] = { txt = "Adjust Map",  act = open_tool("tb_adjmap") }
    end
    if tb_adjed_avail then
        items[#items + 1] = { txt = "Adjust Edit", act = open_tool("tb_adjed") }
    end
    -- Unlike the adjust tools, Log Viewer / RF2 Config / Flight Log are
    -- DISARMED-ONLY (targets carry disarmed=true): an armed tap is refused with
    -- the hint. Disarmed-only tools are DIMMED while armed (tcol; proactive
    -- affordance — the armed hint below stays as the explanation for a tap
    -- anyway). The menu is rebuilt on the arm transition while it is open (see
    -- the refresh() hook).
    local dim_armed = wgt.armed_now and COLOR_DIM or nil
    if tb_logview_avail then
        items[#items + 1] = { txt = "Log Viewer", tcol = dim_armed, act = open_tool("tb_logview") }
    end
    if tb_rf2cfg_avail then
        items[#items + 1] = { txt = "RF2 Config", tcol = dim_armed, act = open_tool("tb_rf2cfg") }
    end
    if fltlog.avail then
        items[#items + 1] = { txt = "Flight Log", tcol = dim_armed, act = open_tool("tb_fltlog") }
    end
    wgt.tb_menu_armed = wgt.armed_now   -- arm state this build reflects (rebuild trigger)
    -- reserve room below the grid for the armed hint — without it the 5-button grid
    -- filled the small screen to the bottom edge and the hint rendered off-screen
    local any_hint = tb_logview_avail or tb_rf2cfg_avail or fltlog.avail
    local hint_res = any_hint and (((zone.h >= 300) and 26 or 18) + 8) or 0
    local grid_bottom = build_menu_grid(pg, zone.w, zone.h, items, 1, (zone.h >= 300) and 460 or nil, hint_res)
    -- reactive hint: visible only while the refused armed tap is fresh (~2 s)
    if any_hint then
        pg:build({
            { type = "label", x = 6, y = (grid_bottom or ((zone.h >= 300) and 460 or 220)) + 8,
              w = zone.w - 12, h = (zone.h >= 300) and 26 or 18, font = SMLSIZE, align = CENTER,
              color = COLOR_THEME_WARNING, text = "Available only while disarmed",
              visible = function() return (wgt.lv_armed_hint or 0) > (getTime() or 0) end },
        })
    end
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
    -- page; a group with a submenu (Alerts / Colors / Telemetry / Voice) opens that
    -- picker instead — the generic "sub_menu" view renders whichever group it was
    -- opened from, so it needs the group handed to it.
    local function open_group(gi)
        return function()
            local grp = SETTINGS_GROUPS[gi]
            if grp.submenu then
                wgt.settings_sub = grp
                wgt.menu_view = grp.menu or "alerts_menu"
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
                wgt.cfg_save_failed_text = nil                        -- default banner wording
                wgt.cfg_save_failed_until = (getTime() or 0) + 1000   -- ~10 s sticky warn banner
            end
            ultidash_settings.apply(wgt)
            bump_settings_gen()   -- invalidate palette memo + trip passive rebuild (host-local)
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

    -- 3 columns, one themed row per section (.sections names the runs of groups)
    local items, gi = {}, 0
    for si = 1, #SETTINGS_GROUPS.sections do
        local sec = SETTINGS_GROUPS.sections[si]
        items[#items + 1] = { hdr = sec.hdr }
        for _ = 1, sec.n do
            gi = gi + 1
            local grp = SETTINGS_GROUPS[gi]
            if grp then items[#items + 1] = { txt = grp.name, act = open_group(gi) } end
        end
    end
    -- reserve the reset button's height below the grid so it stays on-screen
    local reset_h = (zone.h >= 300) and 40 or 32
    local grid_bottom = build_menu_grid(pg, zone.w, zone.h, items, 3, nil, reset_h + 12)
    -- "Reset to defaults" wipes the WHOLE model -> keep it OFF the navigation grid; place it
    -- below as a narrower, warning-coloured button so it reads as a destructive action, not
    -- another group. (Confirm dialog unchanged.)
    local rw = math.floor(zone.w * 0.28)
    pg:build({
        { type = "button", x = math.floor((zone.w - rw) / 2), y = grid_bottom + 12,
          w = rw, h = reset_h,
          text = "Reset to defaults", textColor = COLOR_THEME_WARNING, press = reset_defaults },
    })
end

--- Build one alert page's settings rows from its ALERTS_SPEC entry. Called LAZILY on
--- first open (open_page below caches the result on the resident ALERT_PAGES entry) --
--- building all 12 pages eagerly used to run at ultidash.lua's module load, inside
--- create()'s instruction budget. Keep the keys in sync with the page's keys() stub
--- in ultidash.lua (ALERT_PAGES), which feeds for_each_setting_item the defaults.
local function build_alert_items(a)
    local en, rep = a.enKey, a.code .. "Rep"
    -- dim helpers: every row but "Active" is inert while the alert is off; the repeat
    -- count/interval also need Repeat on; the count is now "N total" (it includes the first
    -- announcement) so the number reads honestly.
    local function inactive(w) return w[en] ~= 1 end
    local function no_repeat(w) return w[en] ~= 1 or w[rep] ~= 1 end
    local items = {
        -- behaviour summary first, so the page explains WHAT fires before the knobs
        { kind = "info", lbl = a.desc },
        { key = a.enKey, lbl = "Active", kind = "bool", def = a.enDef },
        { key = rep,     lbl = "Repeat", kind = "bool", def = a.repDef, dim = inactive },
        { key = a.code .. "Cnt", lbl = "Repeat count",       kind = "num", def = a.cntDef, min = 0, max = 20, step = 1, big = 5,
                                 fmt = function(v) return (v == 0) and "until cleared" or (v .. " total") end,
                                 dim = no_repeat },
        { key = a.code .. "Int", lbl = "Repeat interval (s)", kind = "num", def = a.intDef, min = 1, max = 60, step = 1, big = 5,
                                 dim = no_repeat },
    }
    -- Escalation volume only ever does something in the GVAR-volume world, and never for
    -- the one-shot alerts flagged noEsc (Cell check / Arm are one-shot with no escalation
    -- hook) -- omit the dead toggle there instead of offering a switch that does nothing.
    -- Dim it when the alert is off OR no master-volume GVAR is configured (its only effect).
    if not a.noEsc then
        items[#items + 1] = { key = a.code .. "Esc", lbl = "Escalation volume", kind = "bool", def = 0,
                              dim = function(w) return w[en] ~= 1 or (w.VolGvar or 0) == 0 end }
    end
    items[#items + 1] = { key = a.code .. "Vib", lbl = "Vibrate", kind = "bool", def = a.vibDef, dim = inactive }
    -- Fullscreen alert overlay, offered on the critical alerts only (ovl flag:
    -- Main power lost / Voltage / Telemetry). Default off; auto-close is the shared
    -- OvlClose setting on the Voice / mute page.
    if a.ovl then
        items[#items + 1] = { key = a.code .. "Ovl", lbl = "Fullscreen overlay", kind = "bool", def = 0, dim = inactive }
    end
    if a.test then
        items[#items + 1] = { kind = "action", lbl = "Test callout", btn = "Play",
            act = function(wgt, working) ultidash_functions.test_callout(wgt, working, a.test) end }
    end
    return items
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
            -- alert pages build their rows lazily on first open (cached on the
            -- resident ALERT_PAGES entry), like the Shortcuts and Colors pages
            page.items = page.items or (page.spec and build_alert_items(page.spec)) or {}
            wgt.settings_page = { name = page.name, items = page.items, back = "alerts_menu" }
            wgt.menu_view = "settings"
            init_view_state(wgt).dirty = true
        end
    end
    -- one button per page; alert pages append their current on/off state plus compact
    -- feature markers (+R repeat, +E escalation, +V vibrate, +O overlay — only what is
    -- actually EFFECTIVE: E needs the volume GVAR). The grid is rebuilt on every open and
    -- the autosave/apply already ran on the way back, so the state is fresh.
    local items = {}
    for p = 1, #ALERT_PAGES do
        local page = ALERT_PAGES[p]
        local txt = page.name
        local sp = page.spec
        if page.enKey then
            if wgt.options[page.enKey] == 1 then
                txt = txt .. "  On"
                local o, m = wgt.options, ""
                if o[sp.code .. "Rep"] == 1 then m = m .. "R" end
                if not sp.noEsc and o[sp.code .. "Esc"] == 1 and (o.VolGvar or 0) ~= 0 then m = m .. "E" end
                if o[sp.code .. "Vib"] == 1 then m = m .. "V" end
                if sp.ovl and o[sp.code .. "Ovl"] == 1 then m = m .. "O" end
                if m ~= "" then txt = txt .. " +" .. m end
            else
                txt = txt .. "  Off"
            end
        end
        items[#items + 1] = { txt = txt, act = open_page(page) }
    end
    -- marker legend under the grid (reserve keeps the centered grid clear of it)
    local _, leg_h = lcd.sizeText("Ag", SMLSIZE)
    local grid_bottom = build_menu_grid(pg, zone.w, zone.h, items, 2, nil, leg_h + 8)
    pg:build({
        { type = "label", x = 10, y = grid_bottom + 6, w = zone.w - 20, h = leg_h + 2,
          text = "+R repeat   +E escalation volume   +V vibrate   +O fullscreen overlay",
          font = SMLSIZE, color = COLOR_DIM, align = CENTER },
    })
end

--- Colors submenu: one button per scheme, each opening that scheme's colour page (via
--- build_settings_view, back returns here). Opened from the settings submenu's "Colors"
--- entry; back/RTN returns there. Mirrors the alerts submenu.
local function build_colors_menu_view(wgt, zone)
    local pg = lvgl.page({
        title = "UltiDash",
        subtitle = "Colors",
        back = function()
            wgt.menu_view = "settings_menu"
            init_view_state(wgt).dirty = true
        end,
    })
    local function open_page(page)
        return function()
            page.items = page.items or build_color_page_items(page.scheme)   -- lazy build on first open
            wgt.settings_page = { name = page.name, items = page.items, back = "colors_menu" }
            wgt.menu_view = "settings"
            init_view_state(wgt).dirty = true
        end
    end
    local items = {}
    for p = 1, #COLOR_PAGES do
        items[#items + 1] = { txt = COLOR_PAGES[p].name, act = open_page(COLOR_PAGES[p]) }
    end
    build_menu_grid(pg, zone.w, zone.h, items, 1)
end

--- Generic submenu for the plain two-page groups (Telemetry, Voice): one button per page
--- of whichever group opened it (wgt.settings_sub). Alerts and Colors keep their own
--- builders — they append an On/Off status resp. build their rows lazily.
local function build_sub_menu_view(wgt, zone)
    local grp   = wgt.settings_sub
    local pages = (grp and grp.submenu) or {}
    local pg = lvgl.page({
        title = "UltiDash",
        subtitle = (grp and grp.name) or "Settings",
        back = function()
            wgt.menu_view = "settings_menu"
            init_view_state(wgt).dirty = true
        end,
    })
    local function open_page(page)
        return function()
            -- lazy pages (Shortcuts) build their rows on first open, like the colour pages
            page.items = page.items or (page.build and page.build()) or {}
            wgt.settings_page = { name = page.name, items = page.items, back = "sub_menu" }
            wgt.menu_view = "settings"
            init_view_state(wgt).dirty = true
        end
    end
    local items = {}
    for p = 1, #pages do
        items[#items + 1] = { txt = pages[p].name, act = open_page(pages[p]) }
    end
    build_menu_grid(pg, zone.w, zone.h, items, 1, (zone.h >= 300) and 460 or nil)
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

--- Battery query page (flight log / battery management): auto-opened after a
--- fresh connect when batteries.cfg lists packs for the FC-set model name. One
--- two-line button per battery (name / capacity + cycles) in stable
--- batteries.cfg order, plus a skip button. RTN/back = fly without a pack id
--- (flights still log with an empty battery column). Selecting optionally
--- activates the pack's FC battery profile (FltProf; disarmed -> MSP allowed).
local function build_battpick(wgt, zone)
    local pg = lvgl.page({
        title = "Battery",
        subtitle = "Which pack is plugged in?",
        back = function()
            wgt.menu_view = nil
            init_view_state(wgt).dirty = true
        end,
    })
    local w, h = zone.w, zone.h
    local batts = wgt.flt_batts or {}
    local _, fh = lcd.sizeText("Ag", 0)
    local row_h = 2 * fh + 14
    local gap = 8
    local btn_w = math.min((h >= 300) and 460 or 320, w - 32)
    local x0 = math.floor((w - btn_w) / 2)
    local skip_h = fh + 12
    -- ALL packs are selectable: the old fit-above-the-skip-button cap made
    -- packs beyond ~3 rows unreachable on the TX15 — lvgl.page scrolls, so rows past
    -- the fold are a swipe away (the skip button simply ends the list)
    local n = #batts
    local elems = {}
    local y = (h >= 300) and 10 or 6
    for i = 1, n do
        local b = batts[i]
        local line1 = b.name or b.id
        local line2 = (b.cap and (b.cap .. " mAh") or "capacity ?")
            .. " - " .. (b.cycles or 0) .. " cycles"
        elems[#elems + 1] = { type = "button", x = x0, y = y, w = btn_w, h = row_h,
            font = 0, text = line1 .. "\n" .. line2,
            press = function()
                wgt.flt_batt_id = b.id
                wgt.flt_batt_counted = false
                -- (no LastBatt persistence: the key was write-only —
                -- nothing read it, the store drops unknown keys on the next save anyway —
                -- and it cost one SD write per pick)
                -- only RECORD the profile wish -- the MSP write runs deferred, from a
                -- normal refresh cycle with retries (see fltlog.write_profile).
                -- profile= is the explicit override; without it the pack's cap= is
                -- matched against the FC profiles' configured capacities.
                if (wgt.options.FltProf or 0) == 1 then
                    if b.profile ~= nil and b.profile >= 1 and b.profile <= 6 then
                        wgt.flt_prof_req = { idx = b.profile - 1 }
                        prof_log("pick %s -> request profile %d (explicit)", b.id, b.profile)
                    elseif b.cap ~= nil and b.cap > 0 then
                        wgt.flt_prof_req = { cap = b.cap }
                        prof_log("pick %s -> match FC profile by %d mAh", b.id, b.cap)
                    else
                        -- "Battery sets FC profile" is on but this registry line has
                        -- neither profile= nor cap=: nothing to go by. Say so.
                        prof_log("pick %s -> no profile= and no cap= in batteries.cfg", b.id)
                    end
                    if wgt.flt_prof_req ~= nil then
                        wgt.flt_prof_try = 0
                        wgt.flt_prof_at = (getTime() or 0) + fltlog.PROF_DELAY_CS
                    end
                end
                wgt.menu_view = nil
                init_view_state(wgt).dirty = true
            end }
        y = y + row_h + gap
    end
    elems[#elems + 1] = { type = "button", x = x0, y = y, w = btn_w, h = skip_h,
        font = SMLSIZE, text = "No battery / skip",
        press = function()
            wgt.flt_batt_id = nil
            wgt.menu_view = nil
            init_view_state(wgt).dirty = true
        end }
    pg:build(elems)
end

-- ---- module entry points ---------------------------------------------------

--- Build the menu page for `view` (= wgt.menu_view). Called from the host's
--- update() dispatch for every menu-family view; tool pages (tb_*) and the
--- Status page stay in the host.
function M.build(wgt, zone, view)
    pull_palette()
    if view == "settings" then build_settings_view(wgt, zone)
    elseif view == "settings_menu" then build_settings_menu_view(wgt, zone)
    elseif view == "alerts_menu" then build_alerts_menu_view(wgt, zone)
    elseif view == "colors_menu" then build_colors_menu_view(wgt, zone)
    elseif view == "sub_menu" then build_sub_menu_view(wgt, zone)
    elseif view == "sensorcheck" then build_sensorcheck_view(wgt, zone)
    elseif view == "toolbox" then build_toolbox_menu_view(wgt, zone)
    elseif view == "battprofile" then build_battprofile_view(wgt, zone)
    elseif view == "battpick" then build_battpick(wgt, zone)
    else build_menu_view(wgt, zone) end   -- "menu" hub (and any unknown view)
end

--- 1 Hz sensor-check scan while that page is open (host refresh block).
function M.update_sensorcheck(wgt)
    return update_sensorcheck(wgt)
end

return M
