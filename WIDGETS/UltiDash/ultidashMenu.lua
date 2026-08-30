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
-- (for_each_setting_item is deliberately NOT imported any more: the page-scoped seed
-- below was its only consumer here, and the host keeps it for the three whole-catalogue
-- jobs that genuinely need it — SETTINGS_DEFAULTS, the orphan drop, the cfg snapshot.)
local init_view_state, close_settings
local build_sensor_list, sensor_pick_label, is_raw_sensor
local resolve_builtins, role_color, role_in_scheme, color_key, picker_rgb24
local prof_log, bump_settings_gen
local tb_avail, shortcut_open
local SETTINGS_GROUPS, ALERT_PAGES, COLOR_PAGES, COLOR_ROLES, SENSOR_INFO
local PANEL_SLOT_KEYS, DETAIL_SLOT_KEYS
local fltlog, rf_service, ultidash_settings, ultidash_functions
local SENSOR_OFF, VOLT_AUTO, ESCL_AUTO, RAW_SENTINEL, SCHEME_DEFAULT
local colors_fn

-- ---- palette snapshot ------------------------------------------------------
-- Pulled fresh at the top of every M.build: reactive closures built into a page
-- capture these values; a scheme/override change always rebuilds the page anyway.
local COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1
local COLOR_THEME_SECONDARY2, COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS
local COLOR_THEME_WARNING, COLOR_THEME_DISABLED
local SEM_GREEN, SEM_YELL, SEM_RED, SEM_NEUT, COLOR_DIM

-- ---- icon glyphs -----------------------------------------------------------
--- The file behind a bare glyph name, in the ONE place that knows the folder. Used by
--- the tile column in build_menu_grid and by every page header (M5: a page carries the
--- SAME glyph as the tile that leads to it). A missing file is firmware behaviour and
--- draws nothing rather than raising, so a card without img/ degrades to plain chrome.
local function icon_path(name)
    if name == nil then return nil end
    return "/WIDGETS/UltiDash/img/ud_" .. name .. ".png"
end

-- ---- sibling paging (M6) ---------------------------------------------------
--- The descriptor a settings page carries when it has siblings: which one of how many,
--- and how to reach a neighbour. build_settings_view turns it into the header's ‹ ›
--- arrows; the menu that opened the page is what knows the set, so it builds this.
--- `open(j)` is the SAME opener the menu's own tile uses, so a page reached by arrow is
--- byte-for-byte the page reached by tap -- lazy row build, cache and all. The jump goes
--- through close_settings first: leaving by arrow autosaves exactly like leaving by the
--- back arrow, and it drops the working copy so the neighbour seeds its own.
--- `icons` is the set's GLYPHS, for the body strip (build_sib_strip) that the encoder
--- pages by: a bare name when every sibling wears the same one (all 13 alert pages are
--- ud_bell), or a table indexed by sibling position when they differ (the 8 flat groups).
local function sib_nav(wgt, i, n, open, icons)
    return { i = i, n = n, icons = icons,
             go = function(j)
                 close_settings(wgt)   -- autosave + drop the working copy
                 open(j)               -- ...and immediately re-target the page
             end }
end

local function pull_palette()
    COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1,
    COLOR_THEME_SECONDARY2, COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS,
    COLOR_THEME_WARNING, COLOR_THEME_DISABLED,
    SEM_GREEN, SEM_YELL, SEM_RED, SEM_NEUT, COLOR_DIM = colors_fn()
end

function M.init(env)
    init_view_state       = env.init_view_state
    close_settings        = env.close_settings
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
    SCHEME_DEFAULT        = env.SCHEME_DEFAULT
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

-- app id -> Rotorflight TELEM id, for the "does the FC even send this row" check below.
-- The FC's own slot list (MSP 73, read once per connect into wgt.rf.crsf_slots) is keyed by
-- TELEM id; every row on this page already carries an app id, so this table is the whole
-- bridge. `SCRIPTS/RF2/rf2tlm_sensors.lua` carries the same pairing -- do NOT dofile it,
-- it builds an entire decoder and costs the budget accordingly. Only the rows this page can
-- actually show are listed: an id that is missing here yields "no claim", never a false N/S.
-- Note 97 -> 0x1214 (BAT#) and 98 -> 0x1213 (LED#): those two are swapped in the firmware's
-- own table, and reading them off the app id in numeric order gets them the wrong way round.
local SENSCHECK_TELEM_BY_APPID = {
    [0x1011] = 3,  [0x1012] = 4,  [0x1013] = 5,  [0x1014] = 6,      -- Vbat Curr Capa Bat%
    [0x1020] = 7,  [0x1021] = 8,                                    -- Cel# Vcel
    [0x1031] = 11, [0x1032] = 12, [0x1033] = 13, [0x1034] = 14, [0x1035] = 15,  -- C* Thr
    [0x1041] = 17, [0x1042] = 18, [0x1043] = 19, [0x1044] = 20,     -- EscV EscI EscC EscR
    [0x1045] = 21, [0x1046] = 22, [0x1047] = 23, [0x1048] = 24,     -- EscP Esc% EscT BecT
    [0x1049] = 25, [0x104A] = 26, [0x104E] = 27, [0x104F] = 28,     -- BecV BecI EscF Esc#
    [0x1051] = 30, [0x1052] = 31, [0x1053] = 32, [0x1054] = 33, [0x1057] = 36, -- Es2*
    [0x1080] = 42, [0x1081] = 43, [0x1082] = 44, [0x1083] = 45,     -- Vesc Vbec Vbus Vmcu
    [0x1090] = 46, [0x1091] = 47, [0x1092] = 48, [0x1093] = 49,     -- Iesc Ibec Ibus Imcu
    [0x10A0] = 50, [0x10A1] = 51, [0x10A3] = 52,                    -- Tesc Tbec Tmcu
    [0x10B1] = 57, [0x10B2] = 58, [0x10B3] = 59,                    -- Hdg Alt Var
    [0x10C0] = 60, [0x10C1] = 61,                                   -- Hspd Tspd
    [0x1101] = 65, [0x1102] = 66, [0x1103] = 67,                    -- Ptch Roll Yaw
    [0x1121] = 73, [0x1126] = 78, [0x1128] = 80, [0x1129] = 81,     -- Sats GAlt GSpd GDis
    [0x1141] = 85, [0x1142] = 86, [0x1143] = 87,                    -- CPU% SYS% RT%
    [0x1202] = 90, [0x1203] = 91, [0x1204] = 92, [0x1205] = 93,     -- ARM ARMD Resc Gov
    [0x1211] = 95, [0x1212] = 96, [0x1214] = 97, [0x1213] = 98,     -- PID# RTE# BAT# LED#
}

-- Does the flight controller SEND this row?
--   nil   = no claim -- no slot list read yet, an unmapped id, or CRSF telemetry in NATIVE
--           mode, where the firmware ignores telemetry_sensors entirely even when the list
--           is populated (the RF service leaves crsf_slots nil in that case, which is what
--           keeps a NATIVE craft from being told every row is missing).
--   false = the craft does not select this row, so a reading here is a model leftover.
-- This is what makes the page's `--` state reachable at all for a dead sensor: EdgeTX
-- serves 0, not nil, for a sensor that exists in the model and is no longer transmitted,
-- so a dropped row used to read a green "OK 0.0" -- worst on EscF, ARMD and Gov, where 0 is
-- also a legitimate value. The FC's own list says so about itself, which is stronger than
-- any freshness heuristic on the radio could be.
local function senscheck_sent(crsf_slots, appId)
    if crsf_slots == nil or appId == nil then return nil end
    local tid = SENSCHECK_TELEM_BY_APPID[appId]
    if tid == nil then return nil end
    return crsf_slots[tid] == true
end

local NOTSENT_HINT = "not in the FC's telemetry slots - the reading is a model leftover; "

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
    -- 0x104F is TELEM_ESC1_MODEL, the vendor SIGNATURE byte -- the status word is the next
    -- row (EscF / 0x104E). The consequence half of the hint is right and stays: without a
    -- signature the decoder is picked as SIG_NONE and get_status() returns nil.
    { name = "Esc#", appId = 0x104F, lbl = "ESC signature", hint = "no ESC signature - ESC fault decoder blank" },
    { name = "EscF", appId = 0x104E, lbl = "ESC faults",    hint = "no ESC fault flags - ESC fault decoder blank" },
    { name = "PID#", appId = 0x1211, lbl = "PID profile",   hint = "no PID profile - profile line blank" },
    { name = "RTE#", appId = 0x1212, lbl = "Rate profile",  hint = "no rate profile - profile line blank" },
    -- B4: NOT "profile line blank". The default skin's third grid column renders
    -- rf_battery_profile_compact_formatted, which PREFERS the MSP capacity and only falls
    -- back to the profile index -- and the capacity comes from mspBatteryConfig indexed by
    -- rf_battery_profile_active, not from this sensor. Observed on a pilot's radio: BAT#
    -- MISS on this page while the flight screen showed "B-Profile 5800" at the same moment.
    -- PID# and RTE# above carry the same wording and are correct; only this row overstated it.
    { name = "BAT#", appId = 0x1214, lbl = "Battery profile",
      hint = "no battery profile from telemetry - the MSP capacity still names the pack" },
    { name = "TQly", appId = nil,    lbl = "Uplink quality", hint = "no uplink quality",
      gate = function(o) return o.ShowTQly == 1 end },
    -- needed for the status-bar TPWR field AND the ELRS detail page's TPWR bar — the
    -- latter is reachable whatever the skin's status bar does, so a configured TX power
    -- limit alone already makes the sensor relevant
    { name = "TPWR", appId = nil,    lbl = "TX power",       hint = "no TX power",
      gate = function(o) return o.ShowTPWR == 1 or (o.TxPwrMax or 0) > 0 end },
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
    -- The FC's own telemetry slot list, read once per connect by the RF service. nil on a
    -- NATIVE craft, on an older API and before the first read has landed -- and nil means
    -- every row below keeps exactly the behaviour it had before this check existed.
    -- NOT called `slots`: the Value-slots block further down already owns that name for the
    -- widget's own display slots, and shadowing it there silently asked the wrong table.
    local crsf_slots = (wgt.rf ~= nil) and wgt.rf.crsf_slots or nil
    local rows, req_missing = {}, 0
    local function add(r) rows[#rows + 1] = r end
    -- FREEZE the structural identity (gated feature list + slot list) on the FIRST
    -- build of this page-open: the reactive row closures capture their build-time
    -- index into wgt.senscheck.rows, so a gate flipping mid-view (e.g. the diversity
    -- latch discovering 2RSS) would change the row count and shift every closure one
    -- off. Statuses/values stay live; the row SET updates on the next open.
    local prior = wgt.senscheck

    add({ header = "Required" })
    do  -- an MSP provider present (not a sensor). EITHER of the two serves; the flag says
        -- only that neither does, so the row must not name one of them as the fix.
        local ok = wgt.rf ~= nil and wgt.rf.available == true
        if not ok then req_missing = req_missing + 1 end
        add({ lbl = "MSP provider", status = ok and "ok" or "miss",
              hint = "Neither the RF Tool widget nor RFSuite's service widget is serving - "
                  .. "no connection state, no MSP. menu > Status names which was seen." })
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
        local hint = (d.hintf ~= nil) and d.hintf(o, wgt) or d.hint
        -- MISS wins: a sensor the model never discovered is the stronger statement and its
        -- own hint already says what breaks. N/S only replaces a chip that would otherwise
        -- have claimed the row was fine.
        if status ~= "miss" and senscheck_sent(crsf_slots, d.appId) == false then
            status = "notsent"
            hint = NOTSENT_HINT .. hint
        end
        if status == "miss" or status == "notsent" then req_missing = req_missing + 1 end
        add({ lbl = d.lbl, name = d.name, status = status, hint = hint,
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
            local status, hint = nil, d.hint
            if live == "present" then status = "ok"
            elseif live == "nodata" then status = "nodata"
            elseif d.redmiss and d.redmiss(o, wgt) then status = "miss"; req_missing = req_missing + 1
            else status = "missopt" end
            -- The reachable instance the item was reopened on: SENSCHECK_CURR_NAMES offers
            -- EscI as the Current source, and on a craft that does not select row 18 that is
            -- a dead leftover reading 0.0. With EscMon = 1 the row is redmiss, i.e. one the
            -- page is trusted to shout about -- and it used to say "OK 0.0" while the Current
            -- row, the ESC load and the current min/max all stayed blank.
            if (status == "ok" or status == "nodata") and senscheck_sent(crsf_slots, appId) == false then
                hint = NOTSENT_HINT .. (d.hint or "")
                if d.redmiss and d.redmiss(o, wgt) then
                    status = "notsent"; req_missing = req_missing + 1
                else
                    status = "notsentopt"
                end
            end
            add({ lbl = d.lbl, name = name, status = status, hint = hint,
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
            local hint = "sensor not found - check the slot's raw pick / spelling"
            if rs ~= nil and rs.ok then
                -- a raw pick is an EdgeTX SOURCE, not a flight-controller row, so the FC's
                -- slot list has nothing to say about it and no N/S may be claimed here
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
                if (status == "ok" or status == "nodata")
                    and senscheck_sent(crsf_slots, info and info.appId or nil) == false then
                    status = "notsentopt"
                    hint = NOTSENT_HINT .. "this slot shows a value the craft no longer sends"
                end
            end
            add({ lbl = info and info.lbl or "raw pick", name = nm, status = status,
                  hint = hint,
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
            title = "UltiDash", subtitle = "Diagnostics > Sensor check", icon = icon_path("check"),
            back = function() wgt.menu_view = "menu"; init_view_state(wgt).dirty = true end,
        })
        local _, std_h = lcd.sizeText("Ag", 0)
        pg:label({ x = 10, y = 2, w = zone.w - 24, h = std_h + 4, font = 0,
                   align = LEFT, color = COLOR_DIM, text = "Scanning sensors ..." })
        return
    end
    local w = zone.w
    local pg = lvgl.page({
        title = "UltiDash", subtitle = "Diagnostics > Sensor check", icon = icon_path("check"),
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
            -- "or not sent" since B3: a required row the FC does not transmit counts here
            -- too, or the headline would read "All required sensors OK" while headspeed is
            -- a leftover zero -- which is the exact defect this count exists to surface.
            return n .. " required sensor(s) missing or not sent"
        end,
        color = function()
            return (wgt.senscheck and (wgt.senscheck.req_missing or 0) > 0) and SEM_RED or SEM_GREEN
        end })
    -- Second line: either the "not connected" caveat, or the TARGET CROSS-CHECK. The two are
    -- mutually exclusive by construction -- the cross-check needs a live link. It states the
    -- observation and not a diagnosis: a model whose sensors were renamed away from their
    -- Rotorflight app-ids and a wrongly declared target are indistinguishable from here.
    -- wgt.caps.norf carries the three conditions the sensor scan can see (sensors present,
    -- app-id base derived, zero curated app-ids resolved); caps.msp is the declared target.
    -- Built in ultidash.lua's resolve_sensor_indices -- absent until the first scan, hence
    -- the nil guard.
    local function target_warn()
        local c = wgt.caps
        return c ~= nil and c.msp == true and c.norf == true
    end
    pg:label({ x = 10, y = 2 + std_h + 8, w = w - 24, h = sml_h + 2, font = SMLSIZE, align = LEFT,
        color = function() return target_warn() and SEM_YELL or COLOR_DIM end,
        text = function()
            local st = wgt.values.rf_connection_state
            if st == nil or st == "disconnected" then
                return "FC not connected - showing discovered state only"
            end
            if target_warn() then return "No Rotorflight sensors found" end
            return ""
        end })

    local y = 2 + std_h + 8 + sml_h + 8 + 4
    local rows = wgt.senscheck.rows
    local elems = {}
    for idx = 1, #rows do
        local r = rows[idx]
        if r.header then
            -- Section header, and since 0.8.0 a FOCUS STOP: an lvgl.page reacts to the
            -- encoder only through focusable objects, so this page could not be scrolled
            -- without a finger either (ultidash_functions.focus_stop carries the mechanism).
            -- The 1 px rule that used to underline the head is gone with it -- the bar's own
            -- border already draws that line, and two of them read as a box.
            -- It goes into `elems` rather than straight onto the page: the rows keep their
            -- single pg:build, and creation order -- which IS focus order -- is preserved
            -- because the stops are the only focusable objects in the table.
            y = y + 6
            local e, eh = ultidash_functions.focus_stop_elem(y, w, r.header,
                                                             SMLSIZE, COLOR_THEME_FOCUS)
            elems[#elems + 1] = e
            y = y + eh + 4
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
                    if s == "ok" then return SEM_GREEN
                    elseif s == "miss" or s == "notsent" then return SEM_RED
                    elseif s == "missopt" or s == "notsentopt" then return SEM_YELL end
                    return SEM_NEUT
                end }
            elems[#elems + 1] = { type = "label", x = 10, y = by + math.floor((badge_h - sml_h) / 2),
                w = badge_w, h = sml_h + 2, font = SMLSIZE, align = CENTER,
                text = function()
                    local s = status()
                    if s == "ok" then return "OK"
                    elseif s == "miss" or s == "missopt" then return "MISS"
                    -- "not sent": the sensor EXISTS in the model and the flight controller
                    -- does not transmit it, which is a different fact from MISS and needs
                    -- its own chip -- the reading behind it is a leftover, not a value.
                    elseif s == "notsent" or s == "notsentopt" then return "N/S" end
                    return "--"
                end,
                -- black on the yellow badge, white on the rest
                color = function()
                    local s = status()
                    return (s == "missopt" or s == "notsentopt") and BLACK or white
                end }
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
            if r.status == "miss" or r.status == "missopt"
                or r.status == "notsent" or r.status == "notsentopt" then
                local lines = math.max(1, math.ceil(lcd.sizeText(r.hint, SMLSIZE) / (hint_w * 0.9)))
                local hh = lines * sml_h + 4
                elems[#elems + 1] = { type = "label", x = name_x, y = y - 2, w = hint_w, h = hh,
                                      text = r.hint, font = SMLSIZE, color = COLOR_DIM, align = LEFT }
                y = y + hh
            end
        end
    end
    -- legend: the OK / -- / MISS distinction is not self-explanatory. It is also the LAST
    -- focus stop, and that is what makes the section above it reachable at all: a stop only
    -- ever reveals what sits ABOVE it (see focus_stop), so without one past the last section
    -- that section's rows stay under the fold for anyone driving the page with the encoder.
    -- `wrap` because it is two lines on every radio -- the bar measures that for itself.
    elems[#elems + 1] = ultidash_functions.focus_stop_elem(y + 8, w,
        "OK = live data    -- = discovered, no data    MISS = not found    "
        .. "N/S = the FC does not send it", SMLSIZE, COLOR_DIM, true)
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

--- The rows of a settings node (a group or one submenu page), BUILT ON FIRST OPEN and
--- cached on the node itself. Since 2026-08-17 (L-3 of the CPU review) the fourteen flat
--- settings groups are lazy as well, not only the Alerts / Colors / Shortcuts pages: a
--- group row is { name, build, keys } and its ~10-30 item rows -- labels, value lists,
--- fmt/dim closures -- are constructed here, inside the call the user's tap already pays
--- for, instead of all fourteen groups at once in the catalogue stage (measured: that
--- stage 10,463 -> 8,621, worst single page build 267 instr, which is noise beside the
--- 2-7k the page build itself costs). Cached, so a second open costs nothing. A node that already
--- carries `items` passes straight through: the "Skin" group's table is refreshed in
--- place by the host, and wgt.settings_page is built with its rows already resolved.
local function page_items(node)
    node.items = node.items or (node.build and node.build()) or {}
    return node.items
end

-- ---- the body icon strip (spec N3/N4) --------------------------------------
--- A row of the page's SIBLING glyphs, built at the very top of the scrolling body of
--- every page that has siblings. It exists because the header's ‹ › paging arrows are
--- compiled under HARDWARE_TOUCH and are therefore unreachable by the encoder: the strip
--- is the encoder's ONLY route between siblings (N3). Consequences that shaped it:
---
---   * N1 -- creation order IS focus order and there is no Lua API to reorder a group,
---     so the caller must invoke this BEFORE it emits any row. The strip's own pg:build
---     runs here, which is what puts its buttons at the head of the page's focus ring.
---   * N4 -- the body is one scrolled Window and nothing pins a child, so the strip
---     scrolls away with the content. Accepted; it comes back for free the moment encoder
---     focus wraps onto it (every FormField carries LV_OBJ_FLAG_SCROLL_ON_FOCUS).
---   * A cell is an ordinary `button` with NO `text` and ONE `image` child -- the Lua API
---     has no image-button. A child image is neither clickable nor focusable, so the
---     encoder still sees exactly one control per cell, the rule this whole file is
---     built around.
---   * Child x/y are CONTENT-relative: EdgeTX's border+padding inset (10/5 px at LCD_W
---     800, 8/4 at 480, per side) is already taken off and CANNOT be turned off, and the
---     child is clipped to the content area. So the cell has to be sized from the icon
---     outwards -- 46 px cell on the MK3 leaves 26 px for a 24 px glyph, a 36 px cell on
---     a 480 leaves 20 px for an 18 px one. Rounding the wrong way clips the glyph.
---   * The CURRENT page is marked with `checked` (the theme paints a checked button with
---     COLOR_THEME_ACTIVE) rather than an underline rectangle: one attribute instead of
---     an extra element per page. The other cells are NOT dimmed -- there is no tint on
---     a StaticImage in this API, and dimming by swapping in a second artwork would
---     double the icon files. The checked cell is the marker; see the report note.
---   * Identical-glyph sets (13 alert pages on ud_bell, 3 telemetry on ud_wave, ...)
---     degrade to POSITION DOTS by design: the checked cell still says where you are and
---     every cell still jumps. Accepted in the spec, not a defect.
---
--- `nav` is the descriptor sib_nav built (i = this page's position, n = how many, go =
--- the jump, icons = a glyph name or a table of them). Returns the vertical space the
--- rows must skip -- 0 when the page has no siblings, so nothing is reserved then.
local function build_sib_strip(pg, w, nav)
    -- no nav = no siblings; n < 2 = a set of one, where a "jump" could only be to self
    if nav == nil or (nav.n or 0) < 2 then return 0 end
    local n = nav.n
    local ins_x = (w >= 800) and 10 or 8     -- the button's own inset, per side
    local ins_y = (w >= 800) and 5 or 4
    local cell_h = (w >= 800) and 39 or 29   -- spec §4: icon + padding
    local icon_max = (w >= 800) and 24 or 18
    -- The rows below run from x = 10 to w - 20 (clear of the scrollbar); the strip keeps
    -- exactly that box so it lines up with them.
    local avail = math.max(1, w - 30)
    local gap = (w >= 800) and 6 or 4
    local function fit(g) return math.min(46, math.floor((avail - (n - 1) * g) / n)) end
    local cell_w = fit(gap)
    -- SPACING GIVES WAY BEFORE THE GLYPH DOES. 13 alert siblings on a 480 need
    -- 13*(18+16) = 442 px of the 450 available, so the gap has to go to 0 there -- and
    -- that is the right trade: a smaller glyph is unreadable, touching cells are only
    -- untidy (the focus ring LVGL draws outside the button grazes its neighbour).
    while gap > 0 and cell_w < icon_max + 2 * ins_x do
        gap = gap - 1
        cell_w = fit(gap)
    end
    cell_w = math.max(1, cell_w)
    -- Never suppress the strip for narrowness: it is the encoder's only sibling route, so
    -- a set too wide to hold full-size glyphs shrinks them instead of losing the route.
    local cw = math.max(1, cell_w - 2 * ins_x)
    local ch = math.max(1, cell_h - 2 * ins_y)
    local icon_px = math.min(icon_max, cw, ch)
    local total = n * cell_w + (n - 1) * gap
    local x0 = math.max(10, math.floor((w - total) / 2))
    local icons = nav.icons
    local elems = {}
    for j = 1, n do
        local glyph = (type(icons) == "table") and icons[j] or icons
        local cell = {
            type = "button", x = x0 + (j - 1) * (cell_w + gap), y = 2,
            w = cell_w, h = cell_h,
            -- Pressing the cell you are already on would run close_settings + a full
            -- reopen of the same page -- an autosave and a scroll reset for no movement.
            press = (j == nav.i) and function() end or function() nav.go(j) end,
            children = { { type = "image", file = icon_path(glyph),
                           x = math.floor((cw - icon_px) / 2),
                           y = math.floor((ch - icon_px) / 2),
                           w = icon_px, h = icon_px, fill = false } },
        }
        if j == nav.i then cell.checked = true end
        elems[#elems + 1] = cell
    end
    pg:build(elems)
    -- cell + a gap before the first row, so the focus ring of either does not paint into
    -- the other. The rows' own cursor starts at 2, which is where the strip sits.
    return cell_h + ((w >= 800) and 6 or 4)
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
        -- Seed the working copy in its OWN call: sharing the call with the page build
        -- pushed the big pages' first-open over the budget (Colors ~16.5k). Seed, flag a
        -- rebuild via the existing rf_data_dirty plumbing (host refresh() turns it
        -- into dirty for any open menu page), and return — the build then runs with
        -- a fresh budget. Costs 2-3 invisible frames (~100-150 ms) at page open;
        -- same staggering idea as settings_apply_pending. Autosave is safe in the
        -- window (save_pending_settings nil-guards settings_working).
        --
        -- PAGE-SCOPED since 2026-08-17, and that is a per-call CAP rather than another
        -- stage. It used to walk the WHOLE catalogue through for_each_setting_item —
        -- ~296 keys plus ~50 synthesised colour keys — for a page that edits 10-30 of
        -- them, which made this seed (not the build) the ~11.6k reported on EVERY
        -- `group:` line and grew it with every release's new rows. Nothing downstream
        -- wants the other keys: only the open page's rows ever WRITE settings_working,
        -- settings_changed() iterates whatever it holds, prepare_save merges only the
        -- keys present (the rest are already in the loaded cfg table), and the
        -- orphan-drop runs off SETTINGS_DEFAULTS rather than the working copy.
        -- One consequence, deliberate: the delta rule's compaction (a value that equals
        -- its default is dropped from the file) now happens per page rather than for the
        -- whole catalogue on any save. The file still converges — every page the user
        -- opens compacts its own keys — and nothing reads a default-valued line
        -- differently from an absent one, because apply() resolves both to the default.
        local grp0  = wgt.settings_page or SETTINGS_GROUPS[1]
        local its   = grp0 and page_items(grp0)
        local t = {}
        if its then
            for i = 1, #its do
                local it = its[i]
                if it.key then
                    t[it.key] = wgt.options[it.key]
                    -- sensor slots carry a shadow key (<key>Raw = the native picker's
                    -- source index of a raw pick) so the raw field can redisplay the
                    -- pick after a restart — seed it alongside the slot itself
                    if it.kind == "sensor" then
                        t[it.key .. "Raw"] = wgt.options[it.key .. "Raw"]
                    end
                end
            end
        end
        wgt.settings_working = t
        -- nil = "not decided yet": the SENSOR PICK LIST gets the NEXT call (stage below).
        -- It used to ride this one, which made the seed of a sensor page the worst single
        -- host call of the whole run (measured 14.2k on Tele Main: ~11k walk + ~3k list).
        wgt.settings_senslist = nil
        -- remember which cfg file these edits belong to: autosave discards
        -- the copy when the target moved mid-edit (model switch / craft rename)
        wgt.settings_target = ultidash_settings.target_path
            and ultidash_settings.target_path() or nil
        wgt.rf_data_dirty = true
        return
    end
    -- Stage 2 of the page open, and only for pages WITH sensor rows: build_sensor_list
    -- walks all 60 model sensor slots and formats a label for every curated one it finds
    -- -- ~3k instructions on a real 50-sensor model. It used to sit inside the page BUILD
    -- (whose budget then had nothing left for the LVGL ref pass -- that is what killed
    -- dash1's Skin page on a TX16S MK3, eleven sensor rows, 2026-08-09), then inside the
    -- SEED call, which made a sensor page's seed the worst host call of the run. Now it is
    -- a call of its own; a page without sensor rows pays nothing and falls through.
    -- Sentinel: nil = undecided, false = decided/no sensor rows, table = the staged list.
    -- Freshness is unchanged either way: close_settings nils settings_working AND the list,
    -- so both stages run on every page open, exactly as often as the build did.
    if wgt.settings_senslist == nil then
        wgt.settings_senslist = false
        local sgrp = wgt.settings_page or SETTINGS_GROUPS[1]
        local sits = sgrp and page_items(sgrp)
        if sits then
            for i = 1, #sits do
                if sits[i].kind == "sensor" then
                    local sl, sc = build_sensor_list(wgt)
                    wgt.settings_senslist = { sl, sc }
                    break
                end
            end
        end
        if wgt.settings_senslist ~= false then
            -- a list was built and took this call's budget; the build gets the next one
            wgt.rf_data_dirty = true
            return
        end
        -- no sensor rows on this page: nothing was spent, build right away
    end
    local working = wgt.settings_working

    -- The page to render is a {name, items, back} spec set when it was opened
    -- (a normal group, or one alert sub-page). Fall back to the first group -- which is
    -- a LAZY group node, so its rows may still have to be built (page_items caches them).
    local grp = wgt.settings_page or SETTINGS_GROUPS[1]
    page_items(grp)

    -- One page opened by name from the menu; the back arrow / RTN returns to that list
    -- (grp.back) and autosaves. `nav` (set by the opening menu, see sib_nav) turns the
    -- header's ‹ › into paging between THIS page's siblings -- the alert pages among
    -- themselves, the flat settings groups among themselves, a submenu's pages among
    -- themselves. Both keys must be TABLES of functions; `active` decides whether the
    -- arrow is drawn live or greyed, and its default when absent is true -- so it is
    -- always passed, or the two ends would offer a jump that does nothing.
    local nav = grp.nav
    local pg = lvgl.page({
        title = "UltiDash",
        icon = icon_path(grp.icon),
        prevButton = nav and {
            press  = function() if nav.i > 1 then nav.go(nav.i - 1) end end,
            active = function() return nav.i > 1 end } or nil,
        nextButton = nav and {
            press  = function() if nav.i < nav.n then nav.go(nav.i + 1) end end,
            active = function() return nav.i < nav.n end } or nil,
        -- BREADCRUMB (the user's decision, 2026-08-18): the title says the app on every
        -- page of the tree and the subtitle carries the FULL chain down to this page, so
        -- the header alone answers "where am I". `grp.back` names the list that opened
        -- this page and is therefore the whole path apart from the group in the middle,
        -- which only the sub_menu case needs (wgt.settings_sub). Separator " > ".
        subtitle = (grp.back == "alerts_menu") and ("Settings > Alerts > " .. grp.name)
                or (grp.back == "colors_menu") and ("Settings > Colors > " .. grp.name)
                or (grp.back == "sub_menu")
                   and ("Settings > " .. ((wgt.settings_sub and wgt.settings_sub.name) or "")
                        .. " > " .. grp.name)
                or ("Settings > " .. grp.name),
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
    -- Row height. The vertical budget may shrink on a short screen (the 38 px branch is
    -- the reserve for the 480x272 class), but a row must NEVER be shorter than the
    -- EdgeTX-drawn control it holds: toggle switches are ~40 px tall on the 800x480 MK3
    -- and overlapped each other in 38 px rows. That height comes from the THEME, not from
    -- zone.h -- keying the whole decision on the height alone would have handed the
    -- 480x272 MK2 exactly the overlap that the 50 px fixed. lvgl.UI_ELEMENT_HEIGHT is the
    -- same number the toggle is centred on further down, so use it as the floor.
    -- The 800x480 MK3 and the 480x320 TX15 are unaffected (both already at 50).
    local row_h = math.max((lvgl.UI_ELEMENT_HEIGHT or 32) + 10, (zone.h >= 300) and 50 or 38)
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
    local vals_done = {}     -- i -> the resolved dynamic `vals`, so the row loop reuses it
    for i = 1, #grp.items do
        local it = grp.items[i]
        if it.kind == "num" then
            local f = it.fmt or tostring
            local vw = math.max(lcd.sizeText(f(it.min or 0), 0), lcd.sizeText(f(it.max or 0), 0)) + 8
            if vw > val_w then val_w = vw end
        elseif it.kind == "choice" then
            -- vals may be a FUNCTION of the working copy (per-skin schemes, stage 3b).
            -- KEPT: the row loop below needs the same list, and resolving a dynamic one
            -- twice per build means building the whole table twice -- for the skin list
            -- that is a walk of the registry.
            local vl = it.vals
            if type(vl) == "function" then vl = vl(working); vals_done[i] = vl end
            for vi = 1, #vl do
                local tw = lcd.sizeText(vl[vi], 0) + 40
                if tw > uni_cyc_w then uni_cyc_w = tw end
            end
        elseif it.kind == "sensor" then
            has_sensor = true
        end
    end
    local cyc_cap = math.floor(w * 0.45)
    if uni_cyc_w > cyc_cap then uni_cyc_w = cyc_cap end
    -- only pages with a sensor row pay for the 60-slot model sensor scan (see above)
    -- se_by_code: the pick list REVERSED, code -> list position, built once for the whole page.
    -- Every sensor row's dropdown needs "where in the list is my current value" ON EVERY FRAME
    -- (a native `get`), and that used to be a linear walk of the list per row per frame. On a
    -- real model the list is ~39 entries and dash1's Skin page has eleven sensor rows, so the
    -- walk alone was 735 of the page's 1864 per-frame instructions -- measured 2026-08-09, on
    -- the page a TX16S MK3 killed with `CPU limit`. One shared table turns all of it into a
    -- hash lookup. It is exact rather than a memo: the list cannot change while the page is
    -- open (the page is never rebuilt while editing, see the header comment).
    local se_by_code
    if has_sensor then
        -- normally handed over by the seed call above; the fallback keeps any path that
        -- reaches a build without one correct rather than sensor-less
        local staged = wgt.settings_senslist
        if staged then
            se_labels, se_codes = staged[1], staged[2]
        else
            se_labels, se_codes = build_sensor_list(wgt)
        end
        se_by_code = {}
        for ci = 1, #se_codes do
            se_by_code[se_codes[ci]] = ci
            if se_codes[ci] == RAW_SENTINEL then se_raw_idx = ci end
        end
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
    -- FOCUS ORDER IS CREATION ORDER, and that is why `elems` is flushed as it fills instead of
    -- once at the end. Verified in the 2.12 source: every control lands in the default lv_group
    -- at construction time (lv_group_add_obj appends), nothing in the Lua binding can reorder a
    -- group afterwards, and `pg:build` only sets a temp parent and creates -- it never clears
    -- (that is `pg:clear()`), so calling it many times APPENDS. Collecting every plain button
    -- into one table and building it after the row loop therefore handed the encoder "every
    -- native control in row order, THEN every button in row order": on a page mixing dropdowns
    -- with steppers the wheel walked to the bottom and jumped back to the top, and the page
    -- scrolled with it because each FormField carries LV_OBJ_FLAG_SCROLL_ON_FOCUS. Flushing
    -- before each native control and at the end of every row makes creation order = reading
    -- order, which is the only thing the pilot can predict.
    local function flush()
        if #elems > 0 then
            pg:build(elems)
            elems = {}
        end
    end
    -- resolve_builtins is a handful of lcd.RGB allocations; memoise per scheme so a colour
    -- page (up to 16 rows sharing one scheme) computes it once, not per row (build budget).
    local rb_cache = {}
    local function page_builtins(s)
        local b = rb_cache[s]
        if b == nil then b = resolve_builtins(s); rb_cache[s] = b end
        return b
    end

    -- THE SIBLING STRIP GOES FIRST (N1). It builds through pg:build right here, i.e.
    -- before a single row element exists, because focus order is creation order and the
    -- encoder has no other way to reach a sibling (N3). It returns 0 -- and reserves
    -- nothing -- on a page without siblings.
    local strip_h = build_sib_strip(pg, w, nav)

    -- running vertical cursor: rows have per-kind heights (info rows are taller),
    -- so positions are accumulated rather than derived from the index
    local ry = 2 + strip_h
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

        -- `vals`/`ids` may be FUNCTIONS of the working copy (dynamic lists: the per-skin
        -- colour schemes, the discovered skin list). Resolve them ONCE per row here -- the
        -- choice branch below and value_text() both need them, and every call builds a
        -- fresh table. With `ids` the stored value is the id STRING at the matching list
        -- position, not the index.
        local vlist, idlist
        if it.kind == "choice" then
            vlist = vals_done[i] or it.vals
            if type(vlist) == "function" then vlist = vlist(working) end
            idlist = it.ids
            if type(idlist) == "function" then idlist = idlist(working) end
        end

        -- value text resolver (reactive), memoized on the raw working value: the label runs
        -- per render frame but the value only moves on a tap/step, so re-format only on change.
        -- For switch rows the getSourceName lookup also rides the memo (only on change).
        local vt_last, vt_str, vt_primed
        local function value_text()
            local raw = working[it.key]
            if vt_primed and raw == vt_last then return vt_str end
            local s
            if it.kind == "bool" then s = (raw == 1) and "On" or "Off"
            elseif it.kind == "choice" then
                if idlist ~= nil then
                    s = "?"
                    for ii = 1, #idlist do
                        if idlist[ii] == raw then s = vlist[ii] or "?" break end
                    end
                else
                    s = vlist[raw or 1] or "?"
                end
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
            -- min/max DEFAULTED, not assumed. These rows can come from a skin's M.items,
            -- i.e. from a third party's file, and a row that omits one used to raise here
            -- (comparison with nil) -- inside a control callback, where it takes the whole
            -- widget with it. A malformed row degrades to unbounded instead.
            local it_min = it.min or 0
            local it_max = it.max or math.huge
            local function set_val(v)
                if it.step and it.step > 1 then v = math.floor(v / it.step + 0.5) * it.step end
                if v < it_min then v = it_min elseif v > it_max then v = it_max end
                working[it.key] = v
            end
            flush()
            local oksl = pcall(function()
                pg:slider({ x = sl_x, y = field_y(ry), w = sl_w, min = it_min, max = it_max,
                    get = function() return working[it.key] or it.def or it_min end,
                    set = set_val })
            end)
            if not oksl then
                local btn_x2 = right - btn_w
                local btn_x1 = btn_x2 - btn_w - 8
                elems[#elems + 1] = { type = "button", x = btn_x1, y = ry, w = btn_w, h = row_h - 6, text = "-",
                                      press = function() set_val((working[it.key] or it_min) - (it.step or 1)) end,
                                      longpress = function() set_val((working[it.key] or it_min) - (it.big or it.step or 1)) end }
                elems[#elems + 1] = { type = "button", x = btn_x2, y = ry, w = btn_w, h = row_h - 6, text = "+",
                                      press = function() set_val((working[it.key] or it_min) + (it.step or 1)) end,
                                      longpress = function() set_val((working[it.key] or it_min) + (it.big or it.step or 1)) end }
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
            -- defaulted for the same reason as the slider row above
            local it_min = it.min or 0
            local it_max = it.max or math.huge
            local function adjust(delta)
                local v = (working[it.key] or it_min) + delta
                if v < it_min then v = it_min elseif v > it_max then v = it_max end
                working[it.key] = v
            end
            elems[#elems + 1] = { type = "button", x = btn_x1, y = ry, w = btn_w, h = row_h - 6, text = "-",
                                  press = function() adjust(-(it.step or 1)) end,
                                  longpress = function() adjust(-(it.big or it.step or 1)) end }
            elems[#elems + 1] = { type = "button", x = btn_x2, y = ry, w = btn_w, h = row_h - 6, text = "+",
                                  press = function() adjust(it.step or 1) end,
                                  longpress = function() adjust(it.big or it.step or 1) end }
        elseif it.kind == "bool" then
            -- real toggle switch (works in fullscreen widgets despite the docs'
            -- one-time-only note — verified in the 2.12 source: no script-type
            -- guard); pcall'd with the old cycle-button as fallback
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = right - tgl_w - 24, h = lbl_h + 2,
                                  text = it.lbl, color = label_color }
            flush()
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
            flush()
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
            flush()
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
            -- REACTIVE, once per frame per row: keep it to one hash lookup. The two branches
            -- are disjoint by construction -- the curated list holds only Off, the two virtual
            -- entries, SENSOR_INFO names and ‹ Raw ›, and `is_raw_sensor` is false for every
            -- one of them -- so testing the list FIRST cannot change the answer, it only stops
            -- the common case (a curated pick, which is what all eleven of dash1's rows have)
            -- from paying for the raw test as well.
            local function cur_index()
                local v = working[it.key] or SENSOR_OFF
                local ci = se_by_code[v]
                if ci then return ci end
                if is_raw_sensor(v) then return se_raw_idx end   -- raw pick -> ‹ Raw ›
                return 1
            end
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = cyc_x - 14, h = lbl_h + 2,
                                  text = it.lbl, color = label_color }
            flush()
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
            flush()
            pcall(function()
                pg:source({ x = right - raw_w, y = field_y(ry), w = raw_w, h = field_h,
                    filter = (lvgl.SRC_TELEM or 0) | (lvgl.SRC_CLEAR or 0),
                    get = function()
                        local nm = working[it.key]
                        -- same reversal as cur_index: a curated pick is in the list, and
                        -- answering it with a hash lookup skips the raw test entirely
                        if se_by_code[nm or SENSOR_OFF] then return 0 end   -- curated -> "---"
                        if not is_raw_sensor(nm) then return 0 end
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
            local scheme = it.scheme or SCHEME_DEFAULT   -- a SCHEMES descriptor since the registry refactor
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
            flush()
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
            -- values); one shared width per page (uni_cyc_w) so the fields line up.
            -- vlist/idlist were resolved once at the top of this row (dynamic lists are
            -- resolved at BUILD time, so a dependent pick made on this very page shows up
            -- on the next page open). With `ids` the row STORES the id string at the
            -- picked list position (stable when the discovered list changes), not the index.
            local function cur_index()
                if idlist == nil then return working[it.key] or 1 end
                local raw = working[it.key]
                for ii = 1, #idlist do
                    if idlist[ii] == raw then return ii end
                end
                return 1
            end
            local cyc_w = uni_cyc_w
            elems[#elems + 1] = { type = "label", x = 10, y = ry + lbl_dy, w = right - cyc_w - 24, h = lbl_h + 2,
                                  text = it.lbl, color = label_color }
            flush()
            local okc = pcall(function()
                pg:choice({ x = right - cyc_w, y = field_y(ry), w = cyc_w, h = field_h,
                    title = it.lbl, values = vlist,
                    get = cur_index,
                    set = function(i)
                        if idlist ~= nil then working[it.key] = idlist[i] or idlist[1]
                        else working[it.key] = i end
                    end })
            end)
            if not okc then
                elems[#elems + 1] = { type = "button", x = right - cyc_w, y = field_y(ry), w = cyc_w, h = field_h,
                                      text = value_text,
                                      press = function()
                                          local nxt = (cur_index() % #vlist) + 1
                                          if idlist ~= nil then working[it.key] = idlist[nxt] or idlist[1]
                                          else working[it.key] = nxt end
                                      end }
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
        -- close the row before the next one opens: whatever this row still holds (its own
        -- [-]/[+], an action button, the hairline) is created NOW, so the next row's control
        -- comes after it in the focus group rather than ahead of it.
        flush()
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
    -- `big` is a VERTICAL budget only (gaps, minimum sizes, font tier): a short screen
    -- gets tighter spacing. Anything that has to clear EdgeTX-drawn chrome must NOT hang
    -- off it -- see row_h's floor and header_px below. The remaining `zone.h >= 300`
    -- tests in this file are all of the vertical kind; a width cap keyed on the height
    -- was a bug (fixed in build_battpick).
    local big = h >= 300
    local gap = big and math.max(10, math.floor(h * 0.02)) or 6
    -- floor at the theme's element height so a button never ends up smaller than the
    -- control EdgeTX draws into it (same reasoning as the settings rows)
    local row_h = math.max(lvgl.UI_ELEMENT_HEIGHT or 32,
                           big and math.max(44, math.floor(h * 0.12)) or 36)
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
    -- ICON COLUMN (spec M7/M8). An item may carry `icon = "<name>"`, drawn as a
    -- type="image" element at the tile's left edge from /WIDGETS/UltiDash/img/ud_<name>.png.
    -- Two rules, both from the spec's reference implementation:
    --   M7 -- the DRAW SIZE is decided by the tile width, not by the radio: 22 px times the
    --         layout scale (30 on an 800 px MK3) where the tile is wide enough to carry it,
    --         16 px below a 160 px tile (the 3-column settings grid on both 480s lands at
    --         137/140 px). The threshold is measured on THIS grid's own btn_w, after the
    --         normal sizing pass -- so the number follows the geometry rather than a radio
    --         name. NB the reference derives ONE size per radio from the settings grid and
    --         reuses it on the hub; here every grid decides for itself, which only differs
    --         on a grid whose tiles straddle 160 px.
    --   M8 -- an item WITHOUT an `icon` field must not reserve the column: no image is drawn
    --         for it, and a grid where no item carries one keeps today's geometry exactly.
    -- A missing FILE is a different case and is firmware behaviour: StaticImage draws
    -- nothing rather than raising, so a card without the img/ folder degrades to text tiles.
    -- The icon costs vertical room (a row is never shorter than icon+10) and horizontal room
    -- (the font-fit budget below loses icon+10 on top of its own padding).
    -- A button PARENTS its children, and their x/y are relative to its CONTENT area --
    -- the border+padding inset EdgeTX applies is already taken off. That inset is 10/5 px
    -- (x/y) at LCD_W 800 and 8/4 px at 480, and it cannot be turned off (borderPad and
    -- flexFlow are silently ignored on a button), so the tile's own geometry has to be
    -- computed inside it. Keyed on width, like LAYOUT_SCALE and header_px above.
    local ins_x = (w >= 800) and 10 or 8
    local ins_y = (w >= 800) and 5 or 4
    local icon_px, icon_inset = 0, 0
    for i = 1, #items do
        if items[i].icon then
            icon_px = (btn_w < 160) and 16 or math.floor(22 * (lvgl.LCD_SCALE or 1) + 0.5)
            -- the row-height floor: content height = row_h - 2*ins_y must still hold the
            -- icon, which on the MK3 (ins_y = 5) is exactly what the spec's icon+10 says.
            icon_inset = icon_px + 10
            if row_h < icon_inset then row_h = icon_inset end
            break
        end
    end
    -- Pick the largest button font whose widest label still fits: the alerts grid appends an
    -- "On"/"Off" status that overflows the default size on long names (esp. the TX15). Short-
    -- labelled grids keep the default size. Build-time only (menus aren't reactive per frame).
    do
        -- The label's real budget. Without an icon this is today's flat 14 px. With one the
        -- label is a CHILD of the button and lives in its content area, so it loses two
        -- content insets plus the gap after the icon: btn_w - icon - 3*ins_x. On the 480s
        -- that is icon+24, exactly the old 14+icon+10; on the MK3 it is 6 px stricter,
        -- which is the inset the old arithmetic did not know about.
        local pad = (icon_px > 0) and (icon_px + 3 * ins_x) or 14
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
    -- Line height of the settled tile font, for the label child's box (measured, rule 8).
    -- Only an icon grid has a label child, and only it pays for the measurement.
    local btn_fh = 0
    if icon_px > 0 then
        local _, fh = lcd.sizeText("Ag", btn_font)
        btn_fh = fh
    end
    local grid_w = cols * btn_w + (cols - 1) * gap
    local x0 = math.floor((w - grid_w) / 2)
    local _, sml_h = lcd.sizeText("Ag", SMLSIZE)
    -- M4: a section head sits TIGHT -- 2 px of padding, and no half-gap lead-in above it
    -- (the reference implementation's hdrPad = 2 / hdrLead = 0). This is not cosmetic: on
    -- the TX15 it is the difference between the settings grid fitting and scrolling, and
    -- with four heads the lead-in alone cost three half-gaps of pure air.
    local hdr_h = sml_h + 2
    -- pass 1: place everything relative to y=0 so the true block height (headers included,
    -- last row of a section possibly short) is known before the block is centered
    -- Alongside the plan this counts the three things the height is made of, because the
    -- overflow shrink below solves for them instead of re-planning per pixel step:
    --   nrow = button rows closed (a full row, a partial row cut short by a header, and a
    --          trailing partial row all count once) -- each costs rh + gp
    --   nhdr = section headers            -- each costs hdr_h
    -- Both depend ONLY on the item sequence and `cols`, never on rh or gp, which is what
    -- makes the height affine in those two. (The third term, a half-gap above every head
    -- that had something over it, went with M4 -- see hdr_h.)
    local function make_plan(rh, gp)
        local plan, cy, col = {}, 0, 0
        local nrow, nhdr = 0, 0
        for i = 1, #items do
            local it = items[i]
            if it.hdr then
                if col > 0 then cy = cy + rh + gp; col = 0; nrow = nrow + 1 end -- finish a partial row
                plan[#plan + 1] = { hdr = it.hdr, y = cy }
                cy = cy + hdr_h
                nhdr = nhdr + 1
            else
                plan[#plan + 1] = { txt = it.txt, act = it.act, tcol = it.tcol, icon = it.icon,
                                    x = x0 + col * (btn_w + gp), y = cy }
                col = col + 1
                if col >= cols then col = 0; cy = cy + rh + gp; nrow = nrow + 1 end
            end
        end
        if col > 0 then cy = cy + rh + gp; nrow = nrow + 1 end
        return plan, math.max(0, cy - gp), nrow, nhdr
    end
    -- The same height, without building anything. Identical by construction to what
    -- make_plan returns for the same (rh, gp) -- it is that function's arithmetic with the
    -- table writes left out.
    local function plan_height(rh, gp, nrow, nhdr)
        return math.max(0, nrow * (rh + gp) + nhdr * hdr_h - gp)
    end
    local plan, grid_h, nrow, nhdr = make_plan(row_h, gap)
    -- page header (title + subtitle) eats the top of the zone; center in what's left,
    -- keeping the caller's reserved space free. If the grid overflows that space, shrink
    -- gaps then rows toward a floor (still comfortably tappable) before letting it scroll.
    -- The lvgl.page title/subtitle header is drawn by EdgeTX and scales with the THEME,
    -- not with zone.h -- so this reserve must not shrink just because the screen is short
    -- (a 480x272 MK2 would have started its first row underneath the header). Menus are
    -- fullscreen-only, so the old 40 px small-zone branch was never reachable anyway.
    -- The header's real height is EdgeTX's MENU_HEADER_HEIGHT = LAYOUT_SCALE(45), and
    -- LAYOUT_SCALE is the identity at LCD_W == 480 and (x*11+4)/8 at LCD_W == 800: 45 px
    -- on the TX15 and the MK2, 62 px on the MK3. There is no radio on which it is 56 --
    -- the old constant left the MK3 6 px of body unused and took 11 px too many off both
    -- 480s. `h` is the full screen height here (menus are fullscreen-only, so the zone is
    -- the screen) while the build table's y is BODY-relative, which is why the header is
    -- subtracted from the budget exactly once and never added to y. Keyed on width, the
    -- way LAYOUT_SCALE itself is -- not on `big`, which is a vertical budget.
    local header_px = (w >= 800) and 62 or 45
    local min_y = big and 10 or 6
    local avail = h - header_px - (reserve or 0) - min_y
    -- The row floor honours the THEME's element height too. Without it the shrink walked
    -- straight past the floor row_h was built with (line ~1143) and produced buttons
    -- smaller than the control EdgeTX draws into them -- the overlap that floor exists to
    -- prevent. Overflowing and scrolling is the designed outcome past this point.
    local min_gap = (big and 6 or 4)
    -- Two floors, and only the first is inviolable: the THEME's element height, without
    -- which the shrink produced buttons smaller than the control EdgeTX draws into them.
    -- The second is the comfort floor a text tile gets (34 on a tall screen, 28 on a short
    -- one). An ICON grid replaces the comfort floor with its own footprint instead of
    -- stacking on top of it, exactly as the spec's reference does -- which on the MK3
    -- RAISES it (icon+10 = 40) and on the 480s lowers it from 34 to the theme's own 32.
    -- Those 2 px are what the TX15's settings grid needs to fit at all: with the comfort
    -- floor it lands at 270 px in 265, i.e. it scrolls to show the last section, and the
    -- whole point of the redesign was that it does not. Text-only grids are untouched.
    local min_row = math.max(lvgl.UI_ELEMENT_HEIGHT or 32,
                             (icon_px > 0) and icon_inset or (big and 34 or 28))
    -- SOLVE, THEN PLAN ONCE. This walked the same one-pixel ladder but called make_plan on
    -- every step -- a full placement rebuild over every item per pixel, and on the 272/320 px
    -- zone classes (exactly the ones that overflow) that is several complete re-plans for a
    -- geometry decision. The ladder is unchanged, step for step and floor for floor; only
    -- the trial heights now come from the arithmetic instead of from a rebuilt plan, and a
    -- single make_plan lays out the settled values. Same outcome including the
    -- scroll-past-the-floor case, no visual change.
    if grid_h > avail then
        local g, r = gap, row_h
        while plan_height(r, g, nrow, nhdr) > avail and (g > min_gap or r > min_row) do
            if g > min_gap then g = g - 1 else r = math.max(min_row, r - 2) end
        end
        if g ~= gap or r ~= row_h then
            gap, row_h = g, r
            plan, grid_h = make_plan(row_h, gap)
        end
    end
    -- THE TILE FONT HAS TO SURVIVE THE SHRINK TOO, and only an icon grid can notice. The
    -- fit above settled the font against btn_w; the shrink then lowers row_h underneath it,
    -- and a text button hides that because EdgeTX centres and clips its own label, while an
    -- icon tile's label is a CHILD with a box we compute. Measured the moment the Toolbox
    -- tiles gained glyphs: on the TX15 that grid (three heads, four rows, the hint reserve)
    -- settles at a 24 px content height with a 29 px MIDSIZE line in it -- eight overflows
    -- in the layout run's sweep, on a grid that had none the day before. Step down until the
    -- line fits. The GUARD is what keeps this free everywhere else: btn_fh is already
    -- measured, so a grid whose line fits pays one comparison and no sizeText -- which is
    -- every icon grid except the TX15's Toolbox.
    do
        local ch = math.max(1, row_h - 2 * ins_y)
        if icon_px > 0 and btn_fh > ch then
            local order = (btn_font == MIDSIZE) and { 0, SMLSIZE } or { SMLSIZE }
            for i = 1, #order do
                btn_font = order[i]
                local _, fh = lcd.sizeText("Ag", btn_font)
                btn_fh = fh
                if fh <= ch then break end
            end
        end
    end
    local y0 = math.max(min_y, math.floor((h - header_px - (reserve or 0) - grid_h) / 2))
    local elems = {}
    for i = 1, #plan do
        local p = plan[i]
        if p.hdr then
            elems[#elems + 1] = { type = "label", x = x0 + 2, y = y0 + p.y, w = grid_w - 4, h = hdr_h,
                                  text = p.hdr, font = SMLSIZE, color = COLOR_THEME_FOCUS }
        elseif p.icon then
            -- ICON TILE: ONE button whose `children` are the glyph and the label. The two
            -- used to be a text button plus a SIBLING image laid over it, which drew the
            -- text centred in the whole tile -- so on the MK3 the label grazed the glyph.
            -- As children they are parented, clipped and moved by the button, and the text
            -- is placed by us instead of by the button's own centring. Omitting `text`
            -- costs one empty internal label and is legal. Neither a label nor an image
            -- child is clickable or focusable, so touch and the encoder still see exactly
            -- one control per tile -- the rule the whole file is built around.
            -- Child coordinates are CONTENT-relative (see ins_x/ins_y): the glyph starting
            -- at x = 0 lands 10 px from the tile edge on the MK3 and 8 px on the 480s,
            -- which is where the old absolute placement put it.
            local cw = math.max(1, btn_w - 2 * ins_x)     -- never 0/absent: that means
            local ch = math.max(1, row_h - 2 * ins_y)     -- LV_SIZE_CONTENT, not "fill"
            local ip = math.min(icon_px, ch)
            local lw = math.max(1, cw - icon_px - ins_x)
            local lh = math.min(btn_fh, ch)
            local lbl = { type = "label", x = icon_px + ins_x,
                          y = math.max(0, math.floor((ch - lh) / 2)),
                          w = lw, h = lh, text = p.txt, font = btn_font, align = LEFT }
            if p.tcol then lbl.color = p.tcol end         -- dimmed (e.g. disarmed-only tools)
            elems[#elems + 1] = { type = "button", x = p.x, y = y0 + p.y,
                w = btn_w, h = row_h, font = btn_font, press = p.act,
                children = {
                    { type = "image", file = icon_path(p.icon),
                      x = 0, y = math.max(0, math.floor((ch - ip) / 2)),
                      w = ip, h = ip, fill = false },
                    lbl,
                } }
        else
            -- M8, and the reason every other menu's geometry is untouched: a grid where no
            -- item carries an icon emits exactly the tile it always did.
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
        icon = icon_path("gear"),
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

    -- TWO columns with icons, and one section head. The two ACTIONS lead the page with no
    -- head over them -- they are what the hub is for; the three READ-OUT pages are grouped
    -- under "Diagnostics", which is what the head buys: a hub that reads as two things
    -- rather than five equal entries. They stay two taps away (the alternative, moving them
    -- into the settings menu as a fifth section, would have made Status three).
    -- No max width: the reference fits both columns edge to edge on all three radios.
    build_menu_grid(pg, zone.w, zone.h, {
        { txt = "Settings",     icon = "gear",    act = open("settings_menu") },
        { txt = "Toolbox",      icon = "wrench",  act = open("toolbox") },
        { hdr = "Diagnostics" },
        { txt = "Status",       icon = "status",  act = open("status") },
        { txt = "ELRS Status",  icon = "antenna", act = open("elrsstatus") },
        { txt = "Sensor check", icon = "check",   act = open("sensorcheck") },
    }, 2)
end

--- Toolbox submenu: on-demand tool pages (RF adjustment map / editor). Opened from the
--- main menu's "Toolbox" entry; back/RTN returns there. The tool pages themselves are
--- drawn by the modular tool modules (tb_adjmap / tb_adjed) and stay open across arming
--- (in-flight tuning is the point), unlike the rest of the menu.
local function build_toolbox_menu_view(wgt, zone)
    local pg = lvgl.page({
        title = "UltiDash",
        subtitle = "Toolbox",
        icon = icon_path("wrench"),
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
    local tb_adjmap_avail, tb_adjed_avail, tb_logview_avail, tb_rf2cfg_avail,
          tb_livemon_avail, tb_rfscfg_avail = tb_avail()
    local items = {}
    -- Grouped by WHAT THE TOOL IS FOR (the six tiles used to be one flat list in load
    -- order, which said nothing): what the pilot adjusts on the model, what he looks at
    -- afterwards, what talks to the flight controller. A section head costs a row of its
    -- own, so an empty one must never be printed -- end_section drops a head that no
    -- available tool followed, which is the normal state of a radio where a tool module
    -- is missing.
    local function end_section()
        if items[#items] ~= nil and items[#items].hdr ~= nil then items[#items] = nil end
    end
    items[#items + 1] = { hdr = "Adjustments" }
    if tb_adjmap_avail then
        items[#items + 1] = { txt = "Adjust Map",  icon = "map",      act = open_tool("tb_adjmap") }
    end
    if tb_adjed_avail then
        items[#items + 1] = { txt = "Adjust Edit", icon = "pencil",   act = open_tool("tb_adjed") }
    end
    end_section()
    items[#items + 1] = { hdr = "Logs" }
    -- Unlike the adjust tools, Log Viewer / RF2 Config / Flight Log are
    -- DISARMED-ONLY (targets carry disarmed=true): an armed tap is refused with
    -- the hint. Disarmed-only tools are DIMMED while armed (tcol; proactive
    -- affordance — the armed hint below stays as the explanation for a tap
    -- anyway). The menu is rebuilt on the arm transition while it is open (see
    -- the refresh() hook).
    local dim_armed = wgt.armed_now and COLOR_DIM or nil
    if tb_logview_avail then
        items[#items + 1] = { txt = "Log Viewer",  icon = "chart",    tcol = dim_armed, act = open_tool("tb_logview") }
    end
    if fltlog.avail then
        items[#items + 1] = { txt = "Flight Log",  icon = "logbook",  tcol = dim_armed, act = open_tool("tb_fltlog") }
    end
    -- M5: the Live Monitor -- deliberately NOT dimmed while armed: in-flight use is
    -- its point (no disarmed flag on the target, exempt from the arm-close)
    if tb_livemon_avail then
        items[#items + 1] = { txt = "Live Monitor", icon = "pulse",   act = open_tool("tb_livemon") }
    end
    end_section()
    items[#items + 1] = { hdr = "Flight controller" }
    -- MSP state, read once for the tiles below: armed, or our provider is not serving
    -- (no RF connection / the gate closed).
    local msp_ok = wgt.rf ~= nil and wgt.rf.msp_allowed
    -- RF2 Config BORROWS RFTool's stack, so it dims for the same reason the battery-profile
    -- tile does. RFSuite LOADS its own -- own MSP runtime, own link -- and we have no
    -- honest reading of THAT link, so it dims on ARM alone. Dimming it by a provider it
    -- does not use would be a lie on exactly the card it exists for.
    local dim_msp = (wgt.armed_now or not msp_ok) and COLOR_DIM or nil
    -- Both FC tiles are gated by the host on the door's own key, not on the adapter file:
    -- `rf2` in this Lua state for RF2 Config, the suite installed for RFSuite (see
    -- tb_avail). Only one of the two is normally passable, which is the point -- they
    -- share one CRSF TX slot and must not both be driven. A radio carrying both gets the
    -- config-warning overlay (ultidash_functions.update_msp_conflict), not a silent choice.
    if tb_rf2cfg_avail then
        items[#items + 1] = { txt = "RF2 Config",  icon = "chip",     tcol = dim_msp, act = open_tool("tb_rf2cfg") }
    end
    -- RFSuite. Disarmed-only. A saved SHORTCUT to this target still opens even where the
    -- tile is gone and still lands on the adapter's own notice page -- that path reads
    -- rfscfg.avail, not this flag.
    if tb_rfscfg_avail then
        -- "(exp.)" is on the TILE and not only on the page behind it: the marker has to be
        -- readable BEFORE the tap, and the page behind it is the last screen we own anyway.
        items[#items + 1] = { txt = "RFSuite (exp.)", icon = "external", tcol = dim_armed, act = open_tool("tb_rfscfg") }
    end
    -- The FC battery-profile picker. ALWAYS present,
    -- never conditional on availability: the whole point is a route no skin can remove, and
    -- a tile that disappears when the FC is not talking is a route that is missing exactly
    -- when the user goes looking for it. Unavailable therefore means DIMMED, like the
    -- disarmed-only tools — armed, or no MSP (no RF connection / the gate closed). The open
    -- path refuses in both states; this is the affordance in front of it.
    items[#items + 1] = { txt = "Battery profile", icon = "battery",
                          tcol = dim_msp,
                          act = open_tool("battprofile") }
    wgt.tb_menu_armed = wgt.armed_now   -- arm state this build reflects (rebuild trigger)
    -- reserve room below the grid for the armed hint — without it the 5-button grid
    -- filled the small screen to the bottom edge and the hint rendered off-screen.
    -- Unconditional since the battery-profile tile joined: it is always there and it is
    -- disarmed-only, so there is always a tile the hint can be about.
    local any_hint = true
    -- hint height MEASURED (rule 8) instead of the old 26/18 guess
    local _, hint_h = lcd.sizeText("Ag", SMLSIZE)
    hint_h = hint_h + 4
    local hint_res = any_hint and (hint_h + 8) or 0
    -- TWO COLUMNS, and the test is the ZONE'S WIDTH -- never its height, which is the
    -- mistake build_battpick already paid for. Two columns are what pays for the three
    -- section heads: on the 480x272 MK2 the six tiles in one column overflowed into
    -- scrolling before this change (246 px of grid into 181 px of room), and heads on top
    -- of that would have made it worse; halving the rows brings the whole thing back to
    -- roughly one screen. Below 400 px there is no room for two readable buttons, so a
    -- narrower zone falls back to the single column.
    local cols = (zone.w >= 400) and 2 or 1
    local grid_bottom = build_menu_grid(pg, zone.w, zone.h, items, cols,
        (cols == 2) and 300 or ((zone.h >= 300) and 460 or nil), hint_res)
    -- reactive hint: visible only while the refused armed tap is fresh (~2 s)
    if any_hint then
        pg:build({
            { type = "label", x = 6, y = (grid_bottom or ((zone.h >= 300) and 460 or 220)) + 8,
              w = zone.w - 12, h = hint_h, font = SMLSIZE, align = CENTER,
              color = COLOR_THEME_WARNING, text = "Available only while disarmed",
              visible = function() return (wgt.lv_armed_hint or 0) > (getTime() or 0) end },
        })
    end
end

--- Settings submenu: the configuration groups (Display / Skin / ... ) as a 3-column
--- icon grid under their four section heads. Opened from the main menu's "Settings"
--- entry; back/RTN returns there. The reset action is no longer here — it is a row on
--- the General page.
local function build_settings_menu_view(wgt, zone)
    local pg = lvgl.page({
        title = "UltiDash",
        subtitle = "Settings",
        icon = icon_path("gear"),
        back = function()
            wgt.menu_view = "menu"
            init_view_state(wgt).dirty = true
        end,
    })

    -- The FLAT groups in SETTINGS_GROUPS order -- the sibling set the header's ‹ › arrows
    -- page through (M6). The five submenu groups are deliberately NOT in it: they open a
    -- LIST, not a page, so an arrow landing on one would change the kind of screen under
    -- the pilot's thumb. Their pages page among themselves, one set per submenu.
    local flat, fpos, ficons = {}, {}, {}
    for g = 1, #SETTINGS_GROUPS do
        if not SETTINGS_GROUPS[g].submenu then
            flat[#flat + 1] = g
            fpos[g] = #flat
            -- the set's glyphs, in sibling order, for the body strip: these eight are the
            -- one sibling set whose icons all DIFFER, so its strip reads as real tabs
            ficons[#flat] = SETTINGS_GROUPS[g].icon
        end
    end
    -- Open the flat group at position fi of that set. NAMED rather than one closure per
    -- tile, because the paging arrows call it again for the neighbour.
    local open_flat
    open_flat = function(fi)
        local grp = SETTINGS_GROUPS[flat[fi]]
        -- a flat group builds its rows on this first open and caches them on the
        -- resident SETTINGS_GROUPS entry (page_items), like every submenu page.
        -- `icon` rides along so the page header wears the tile's own glyph (M5).
        wgt.settings_page = { name = grp.name, items = page_items(grp), back = "settings_menu",
                              icon = grp.icon, nav = sib_nav(wgt, fi, #flat, open_flat, ficons) }
        wgt.menu_view = "settings"
        init_view_state(wgt).dirty = true
    end

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
                init_view_state(wgt).dirty = true
            else
                open_flat(fpos[gi])
            end
        end
    end

    -- 3 columns, one themed row per section (.sections names the runs of groups)
    local items, gi = {}, 0
    for si = 1, #SETTINGS_GROUPS.sections do
        local sec = SETTINGS_GROUPS.sections[si]
        items[#items + 1] = { hdr = sec.hdr }
        for _ = 1, sec.n do
            gi = gi + 1
            local grp = SETTINGS_GROUPS[gi]
            -- grp.icon is the bare glyph name from SETTINGS_GROUPS; build_menu_grid turns it
            -- into the img/ path. A group without one simply gets a text tile (M8).
            if grp then items[#items + 1] = { txt = grp.name, icon = grp.icon, act = open_group(gi) } end
        end
    end
    -- NO reserve any more. "Reset to defaults" left this page for a row of its own at the
    -- bottom of the General group -- same wording, same confirmation, same staggered reset.
    -- Giving the reserve back is what pays for the redesign: the 13 tiles get the whole
    -- body, which lifts the MK3's rows out of the shrink ladder and is what lets the TX15
    -- show all four sections without scrolling.
    build_menu_grid(pg, zone.w, zone.h, items, 3)
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

-- ---- the alert cards' data dependency (spec §3.1) --------------------------------
--- WHICH KEYS EACH ALERT'S VALUE LINE DESCRIBES, keyed by the alert's `code`
--- (ALERTS_SPEC in ultidash.lua). This is the ONE non-presentational part of the card
--- list, and the reason it is written down instead of being implicit in the formatter:
--- the keys belong to OTHER settings groups (Battery, Telemetry thresholds, ESC), so
--- **when a threshold moves, this table and alert_value_line below move with it**.
--- Verbatim from the menu and navigation design spec, §3.1.
---
--- The alert's OWN keys (enKey and <code>Rep / Cnt / Int / Vib / Ovl / Esc) are
--- deliberately absent -- those were always the page's own, and the state glyphs on the
--- left of line 2 read them directly. The one exception is VolGvar, which the escalation
--- glyph consults because escalation volume has no effect without a master-volume GVAR;
--- that is the same effectiveness test the old "+E" text marker used.
---
--- An EMPTY list is data, not an oversight: it is how §3.1 spells "no threshold", and
--- alert_value_line prints exactly that for Armed / disarm and Telemetry.
local ALERT_VALUE_KEYS = {
    Fuel  = { "Reserve", "FuelStart", "FuelStep", "FuelDense", "FuelStepFine" },
    Volt  = { "VSay1", "VSay2", "VSayHold" },
    Cell  = { "CellSource", "CellFull", "CellLow", "CellCritical", "StartupDelay" },
    Arm   = {},
    Telem = {},
    Link  = { "RQlyWarn", "RQlyCrit" },
    Rssi  = { "RssWarn", "RssCrit", "RssHold" },
    Pwr   = { "PwrSrc", "PwrCellV", "PwrWarnV" },
    Bec   = { "BecWarn", "BecCrit" },
    EscL  = { "EscMon", "EscWarn", "EscCrit", "EscGvar" },
    Temp  = { "TescWarn", "TescCrit", "TmcuWarn", "TmcuCrit" },
    Skp   = { "SkpLimit" },
}

-- A missing option renders "-" rather than a repeated default -- the same convention
-- build_status_view uses for the same numbers (its local `num`). Writing `or 20` here
-- would put a second copy of every threshold default in the menu module, where nothing
-- would ever notice it drifting from the settings row that owns it.
local function vnum(v) if v == nil then return "-" end return tostring(v) end
local function vpct(v) if v == nil then return "-" end return v .. "%" end

--- Line 2, right: the alert's LIVE thresholds. Everything numeric is read out of
--- `wgt.options`, which is the very table the alert reads at runtime and the freshest
--- one here (the settings autosave/apply has already run on the way back from a page,
--- while Shared.thresholds is only republished on a dashboard refresh that does not
--- happen with the menu open) -- so the line cannot disagree with behaviour.
---
--- Three rules hold this together:
---   * NO threshold default is written here (see vnum/vpct above).
---   * Every BRANCH is the alert's own, copied from the runtime site named in the
---     comment beside it, so a changed predicate has exactly one place to be found.
---   * The resolved CELL voltages come from the alert's own resolver --
---     wgt.values.vcel_full/warning/alarm_threshold(), which is what the cell check
---     itself calls -- not from a second centivolt division in this file.
--- Unit scaling and the unit strings are display, mirrored from the settings rows' fmt
--- helpers (fmt_centivolt / fmt_decivolt / fmt_pctval / fmt_temp in ultidash.lua),
--- exactly as build_status_view and the battery detail legend already do.
--- Terse on purpose: on a 480 the value shares line 2 with up to five glyphs, and the
--- layout run's overflow sweep is what says the text still fits.
local function alert_value_line(wgt, code)
    local keys = ALERT_VALUE_KEYS[code]
    if keys == nil then return nil end
    if #keys == 0 then return "no threshold" end
    local o = wgt.options or {}
    if code == "Fuel" then
        -- the fuel callout's own reading: FuelStart >= 100 is "from full" (that alert
        -- row's fmt), and the announce step is the coarse one until the fuel reaches
        -- FuelDense, the fine one below it.
        return "res " .. vpct(o.Reserve) .. "  "
            .. (((o.FuelStart or 0) >= 100) and "from full" or ("from " .. vpct(o.FuelStart)))
            .. "  " .. vnum(o.FuelStep) .. "/" .. vnum(o.FuelStepFine) .. "% <" .. vpct(o.FuelDense)
    elseif code == "Volt" then
        -- VSay1/VSay2 are centivolts per cell with 0 = off (their row's fmt); with both
        -- off the alert speaks only at the cell warn / min thresholds, which are the Cell
        -- check card's numbers and not this alert's keys.
        local a, b = o.VSay1 or 0, o.VSay2 or 0
        local hold = ((o.VSayHold or 0) <= 0) and "immediate" or (o.VSayHold .. "s")
        if a <= 0 and b <= 0 then return "extra levels off" end
        local s = (a > 0) and string.format("%.2f", a / 100) or ""
        if b > 0 then s = ((s ~= "") and (s .. "/") or "") .. string.format("%.2f", b / 100) end
        return s .. " V/cell  " .. hold
    elseif code == "Cell" then
        -- use_manual_cell_thresholds (ultidashValues.lua): CellSource == 2 is Manual,
        -- anything else means the FC's own battery config -- which is why the FC case
        -- names its source instead of printing numbers the radio may not have yet.
        local d = (o.StartupDelay == nil) and "-" or (o.StartupDelay .. "s")
        if o.CellSource ~= 2 then return "thresholds from FC config  " .. d end
        local v = wgt.values or {}
        if type(v.vcel_full_threshold) ~= "function" then return "manual thresholds  " .. d end
        return string.format("manual %.2f/%.2f/%.2f V  %s",
                             v.vcel_full_threshold(), v.vcel_warning_threshold(),
                             v.vcel_alarm_threshold(), d)
    elseif code == "Link" then
        return "warn " .. vpct(o.RQlyWarn) .. "  crit " .. vpct(o.RQlyCrit)
    elseif code == "Rssi" then
        return "warn " .. vpct(o.RssWarn) .. "  crit " .. vpct(o.RssCrit)
            .. "  hold " .. vnum(o.RssHold) .. "s"
    elseif code == "Pwr" then
        -- pwr_warn_threshold (ultidashFunctions.lua): PwrSrc 1 multiplies PwrCellV by the
        -- LIVE cell count, anything else takes the fixed total. The card shows the
        -- setting rather than the product, because the cell count is telemetry a menu
        -- page may not have -- and it is what the alert itself falls back to without one.
        if (o.PwrSrc or 1) == 1 then
            return ((o.PwrCellV == nil) and "-" or string.format("below %.1f", o.PwrCellV / 10))
                .. " V/cell (auto)"
        end
        return ((o.PwrWarnV == nil) and "-" or string.format("below %.1f", o.PwrWarnV / 10))
            .. " V (fixed)"
    elseif code == "Bec" then
        -- both are a % DROP against the reference frozen at arm, hence the minus signs
        return "warn -" .. vpct(o.BecWarn) .. "  crit -" .. vpct(o.BecCrit)
    elseif code == "EscL" then
        -- update_esc_load_warning / publish_shared: the feature needs BOTH the monitor
        -- switch and a GVAR carrying the ESC's current limit; with either missing the
        -- alert returns before it ever looks at Warn / Crit. Do not reduce this to
        -- EscMon alone -- that weaker test is the BAR's, and it is a different question.
        if o.EscMon ~= 1 or (o.EscGvar or 0) == 0 then return "monitoring off" end
        return "GV" .. vnum(o.EscGvar) .. "  warn " .. vpct(o.EscWarn)
            .. "  crit " .. vpct(o.EscCrit)
    elseif code == "Temp" then
        -- temp_one (ultidashFunctions.lua) treats 0 as "this step is off", which is what
        -- the rows' fmt_temp already shows as "Off"; a sensor with both off is silent.
        local function pair(a, b, lbl)
            if (a or 0) <= 0 and (b or 0) <= 0 then return lbl .. " off" end
            return lbl .. " " .. vnum(a) .. "/" .. vnum(b) .. "C"
        end
        return pair(o.TescWarn, o.TescCrit, "ESC") .. "  " .. pair(o.TmcuWarn, o.TmcuCrit, "MCU")
    end
    return "limit " .. vnum(o.SkpLimit)     -- Skp
end

--- The Voice / mute card's value line. That page is NOT an alert -- it has no enKey and
--- no threshold -- so it reports the working voice language, and its two master switches
--- ride on the same glyphs the alerts use. The choice LABEL comes from the row that
--- defines it: page_items materialises and caches ALERT_PAGES[1]'s rows exactly as
--- opening the page does, which keeps the second copy of { "English", "Deutsch" } that
--- would otherwise live here out of the file.
local function voice_lang_label(wgt, node)
    local items = page_items(node)
    for i = 1, #items do
        local it = items[i]
        if it.key == "VoiceLang" and it.vals then
            return it.vals[wgt.options.VoiceLang or it.def or 1]
        end
    end
    return nil
end

--- Alerts submenu: one CARD per alert sub-page ("Voice / mute" + each alert).
--- Opened from the settings submenu's "Alerts" entry; back/RTN returns there. Each
--- entry opens that page via build_settings_view (its back returns here).
local function build_alerts_menu_view(wgt, zone)
    local pg = lvgl.page({
        title = "UltiDash",
        subtitle = "Settings > Alerts",
        icon = icon_path("bell"),
        back = function()
            wgt.menu_view = "settings_menu"
            init_view_state(wgt).dirty = true
        end,
    })
    -- Opens alert page pi; the 13 pages are each other's siblings for the ‹ › arrows (M6),
    -- so this is named and re-entered rather than a closure per tile.
    local open_idx
    open_idx = function(pi)
        local page = ALERT_PAGES[pi]
        -- alert pages build their rows lazily on first open (cached on the
        -- resident ALERT_PAGES entry), like the Shortcuts and Colors pages. The
        -- alert pages build from their spec; "Voice / mute" is a plain lazy page
        -- (build = MK.voice) and falls through to page_items.
        page.items = page.items or (page.spec and build_alert_items(page.spec))
        wgt.settings_page = { name = page.name, items = page_items(page), back = "alerts_menu",
                              icon = "bell",
                              -- one glyph for all 13: the strip degrades to position
                              -- dots here by design (spec §4), and still jumps
                              nav = sib_nav(wgt, pi, #ALERT_PAGES, open_idx, "bell") }
        wgt.menu_view = "settings"
        init_view_state(wgt).dirty = true
    end
    local function open_page(pi)
        return function() open_idx(pi) end
    end
    -- ---- the card list (spec §3) -------------------------------------------------
    -- ONE COLUMN of cards, one per page, and the page SCROLLS -- 2.4 screens on the MK3,
    -- 2.6 on the TX15, 3.2 on the MK2, accepted by the user on 2026-08-18. Gone with the
    -- two-column tile grid: the "On +RV" text suffix that made the names too wide for the
    -- tile font, and the legend row that suffix needed. The glyphs on line 2 are the
    -- legend now, and the numbers that used to be one page deeper are on the card.
    --
    -- A CARD IS ONE BUTTON (N5), its labels and glyphs its `children`. As children they
    -- are parented, clipped and moved by the button, and neither a label nor an image is
    -- clickable or focusable -- so the encoder walks exactly 13 controls, top to bottom in
    -- creation order (N1), and press opens the alert's page through the SAME open_page a
    -- tile used. No part of a card is touch-only. The button carries no `text` of its own
    -- (that costs one empty internal label and is legal); the name lives on the first
    -- child, which is also where the budget harness reads the card's name from.
    --
    -- Child x/y are CONTENT-relative: EdgeTX's border+padding inset (10/5 px at LCD_W 800,
    -- 8/4 px at 480) is already taken off and cannot be turned off, so the card's own
    -- geometry is computed INSIDE it -- the arithmetic build_menu_grid's icon tiles use,
    -- and the reason every w/h below is explicit and non-zero (0 or absent is
    -- LV_SIZE_CONTENT, not "fill").
    local w, h  = zone.w, zone.h
    local ins_x = (w >= 800) and 10 or 8
    local ins_y = (w >= 800) and 5 or 4
    local side  = math.max(16, math.floor(w * 0.05))    -- build_menu_grid's own side margin
    local _, std_h = lcd.sizeText("Ag", 0)              -- 0 = STDSIZE, line 1
    local _, sml_h = lcd.sizeText("Ag", SMLSIZE)        -- line 2 and the glyph box
    -- Card height out of the MEASURED fonts, keyed on WIDTH like every other inset here:
    -- 2*inset + STD line + SML line + slack lands on the spec's 66 px (MK3: 10+27+23+6)
    -- and 48 px (both 480s: 8+21+17+2). Derived rather than written as 66/48 so a theme
    -- that moves a font moves the card with it instead of clipping into it.
    local card_w = w - 2 * side
    local card_h = 2 * ins_y + std_h + sml_h + ((w >= 800) and 6 or 2)
    -- The gap is not cosmetic: LVGL draws the focus outline OUTSIDE the button, so a
    -- zero-gap neighbour paints over the very ring an encoder user navigates by.
    local gap  = (w >= 800) and 10 or 8
    local in_w = math.max(1, card_w - 2 * ins_x)
    local in_h = math.max(1, card_h - 2 * ins_y)
    local lead = math.max(0, math.floor((in_h - std_h - sml_h) / 3))
    local l2y  = math.max(0, in_h - lead - sml_h)       -- line 2 sits on the bottom lead
    local gsp  = (w >= 800) and 6 or 4                  -- gap after a state glyph
    -- one state glyph, drawn at the SML line's own size; returns the next free x
    local function glyph(kids, x, name)
        kids[#kids + 1] = { type = "image", file = icon_path(name),
                            x = x, y = l2y, w = sml_h, h = sml_h, fill = false }
        return x + sml_h + gsp
    end
    local o, y = wgt.options, ((h >= 300) and 10 or 6)
    local elems = {}
    for p = 1, #ALERT_PAGES do
        local page, sp = ALERT_PAGES[p], ALERT_PAGES[p].spec
        -- line 1: the name, full inner width, STD font. FIRST child, always.
        local name_lbl = { type = "label", x = 0, y = lead, w = in_w, h = std_h,
                           text = page.name, font = 0, align = LEFT }
        local kids, cx, dim, val = { name_lbl }, 0, false, nil
        if page.enKey then
            -- bell = active, struck bell = off. An off card DIMS but stays pressable and
            -- focusable: its page is where it gets switched back on, so dimmed must not
            -- read as disabled here.
            local en = (o[page.enKey] == 1)
            dim = not en
            cx = glyph(kids, cx, en and "bell" or "belloff")
            if en then
                -- The same EFFECTIVE feature markers the "+R/+E/+V/+O" suffix carried,
                -- as glyphs: escalation only counts where a master-volume GVAR exists,
                -- overlay only on the alerts that offer one.
                if o[sp.code .. "Rep"] == 1 then
                    cx = glyph(kids, cx, "repeat")
                    -- count and interval beside the loop. Count 0 is "until cleared"
                    -- (the alert row's own fmt) -- written "inf" rather than the spec's
                    -- infinity sign because nothing here can prove that codepoint is in
                    -- the radio's font, and the measured metrics only cover ASCII.
                    local cnt, int = o[sp.code .. "Cnt"] or 0, o[sp.code .. "Int"]
                    local t = ((cnt > 0) and (cnt .. "x ") or "inf ")
                              .. ((int == nil) and "-" or (int .. "s"))
                    local tw = lcd.sizeText(t, SMLSIZE) + 2
                    kids[#kids + 1] = { type = "label", x = cx, y = l2y, w = tw, h = sml_h,
                                        text = t, font = SMLSIZE, color = COLOR_DIM, align = LEFT }
                    cx = cx + tw + gsp
                end
                if o[sp.code .. "Vib"] == 1 then cx = glyph(kids, cx, "vibrate") end
                if not sp.noEsc and o[sp.code .. "Esc"] == 1 and (o.VolGvar or 0) ~= 0 then
                    cx = glyph(kids, cx, "loud")
                end
                if sp.ovl and o[sp.code .. "Ovl"] == 1 then cx = glyph(kids, cx, "overlay") end
            end
            val = alert_value_line(wgt, sp.code)
        else
            -- Voice / mute: the masters, on the same two glyphs. "Mute: All" silences
            -- audio, so the bell is struck and the card dims -- vibration has its own
            -- switch and its own mark, exactly as on the page behind it.
            dim = (o.Mute == 2)
            cx = glyph(kids, cx, dim and "belloff" or "bell")
            if o.VibMaster == 1 then cx = glyph(kids, cx, "vibrate") end
            val = voice_lang_label(wgt, page)
        end
        if dim then name_lbl.color = COLOR_DIM end
        -- line 2, right: the value line in whatever the glyphs left of the inner width.
        -- Dimmed either way -- it is the secondary line -- so an off card is told apart
        -- by its NAME going dim, which is what "dimmed, not disabled" has to look like.
        if val and val ~= "" and in_w - cx >= 8 then
            kids[#kids + 1] = { type = "label", x = cx, y = l2y, w = in_w - cx, h = sml_h,
                                text = val, font = SMLSIZE, color = COLOR_DIM, align = RIGHT }
        end
        elems[#elems + 1] = { type = "button", x = side, y = y, w = card_w, h = card_h,
                              press = open_page(p), children = kids }
        y = y + card_h + gap
    end
    pg:build(elems)
end

--- Colors submenu: one button per scheme, each opening that scheme's colour page (via
--- build_settings_view, back returns here). Opened from the settings submenu's "Colors"
--- entry; back/RTN returns there. Mirrors the alerts submenu.
local function build_colors_menu_view(wgt, zone)
    local pg = lvgl.page({
        title = "UltiDash",
        subtitle = "Settings > Colors",
        icon = icon_path("palette"),
        back = function()
            wgt.menu_view = "settings_menu"
            init_view_state(wgt).dirty = true
        end,
    })
    -- One scheme page per entry; the schemes are each other's siblings for the ‹ › arrows.
    -- Since 0.8.0 each page wears its OWN glyph (M1/M5 one level down) -- on the tile, in
    -- the page header and in the sibling strip. The strip therefore stops being a row of
    -- position dots here and becomes a real map: sun / moon / contrast disc are told apart
    -- at a glance, which is the whole reason the icon set was grown rather than excepted.
    local icons = {}
    for p = 1, #COLOR_PAGES do icons[p] = COLOR_PAGES[p].icon end
    local open_idx
    open_idx = function(pi)
        local page = COLOR_PAGES[pi]
        page.items = page.items or build_color_page_items(page.scheme)   -- lazy build on first open
        wgt.settings_page = { name = page.name, items = page.items, back = "colors_menu",
                              icon = page.icon,
                              nav = sib_nav(wgt, pi, #COLOR_PAGES, open_idx, icons) }
        wgt.menu_view = "settings"
        init_view_state(wgt).dirty = true
    end
    local function open_page(pi)
        return function() open_idx(pi) end
    end
    local items = {}
    for p = 1, #COLOR_PAGES do
        items[#items + 1] = { txt = COLOR_PAGES[p].name, icon = COLOR_PAGES[p].icon,
                              act = open_page(p) }
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
        subtitle = "Settings > " .. ((grp and grp.name) or ""),
        icon = icon_path(grp and grp.icon),
        back = function()
            wgt.menu_view = "settings_menu"
            init_view_state(wgt).dirty = true
        end,
    })
    -- The group's pages are each other's siblings for the ‹ › arrows. Since 0.8.0 each page
    -- brings its OWN glyph (M1/M5 one level down) instead of repeating the group's, so this
    -- strip is a MAP rather than a row of position dots. A page without artwork still falls
    -- back to the group's glyph -- a skin-supplied group would otherwise draw nothing.
    local icons = {}
    for p = 1, #pages do icons[p] = pages[p].icon or (grp and grp.icon) end
    local open_idx
    open_idx = function(pi)
        local page = pages[pi]
        -- lazy pages (Shortcuts, and since L-3 the Telemetry / Voice pages too) build
        -- their rows on first open, like the colour pages
        wgt.settings_page = { name = page.name, items = page_items(page), back = "sub_menu",
                              icon = page.icon or (grp and grp.icon),
                              nav = sib_nav(wgt, pi, #pages, open_idx, icons) }
        wgt.menu_view = "settings"
        init_view_state(wgt).dirty = true
    end
    local function open_page(pi)
        return function() open_idx(pi) end
    end
    local items = {}
    for p = 1, #pages do
        items[#items + 1] = { txt = pages[p].name, icon = pages[p].icon or (grp and grp.icon),
                              act = open_page(p) }
    end
    build_menu_grid(pg, zone.w, zone.h, items, 1, (zone.h >= 300) and 460 or nil)
end

--- Battery-profile picker — opened by tapping the B-Profile field, by the Toolbox tile or
--- by a switch shortcut (DISARMED only, and only with MSP allowed).
--- Lists the 6 battery profiles with their per-profile capacity (when the FC reports
--- it) and switches the active one through the RFTool MSP API (write MSP 176, persist
--- without reboot, then re-read). Read-side stays as-is; this is the one place the
--- widget WRITES to the FC, and only when disarmed. Back/RTN returns where it came from.
local function build_battprofile_view(wgt, zone)
    local pg = lvgl.page({
        title = "Battery profile",
        subtitle = "select active profile",
        back = function()
            -- Opened from the Toolbox submenu, RTN unwinds back there — the same trail
            -- shortcut.open records for every other tool page. The tap route clears
            -- tool_back, so it still returns straight to the dashboard.
            wgt.menu_view = (wgt.tool_back == "toolbox") and "toolbox" or nil
            wgt.tool_back = nil
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
    -- EdgeTX page header. The SAME defect build_menu_grid carried until 0.8.0: there is no
    -- radio on which it is 56. MENU_HEADER_HEIGHT is LAYOUT_SCALE(45), and LAYOUT_SCALE is
    -- the identity at LCD_W 480 and (x*11+4)/8 at 800 -- 45 px on TX15/MK2, 62 on the MK3.
    -- `h` is the full screen height here too (this page is fullscreen-only, opened through
    -- the same M.build(wgt, wgt.zone, view) path as the menus), and the build table's y is
    -- body-relative, so the header comes off the budget once and is never added to y.
    -- Keyed on WIDTH, the way LAYOUT_SCALE itself is.
    local header_px = (w >= 800) and 62 or 45
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
                -- A PICK closes to the dashboard from every route (the tap route's
                -- behaviour, and the useful one: the profile is switched, there is nothing
                -- left to do in the Toolbox). Only the back arrow above unwinds the trail --
                -- so clear it here, or the next tap-opened tool inherits it.
                wgt.tool_back = nil
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
    -- ALL packs are selectable: the old fit-above-the-skip-button cap made
    -- packs beyond ~3 rows unreachable on the TX15 — lvgl.page scrolls, so rows past
    -- the fold are a swipe away (the skip button simply ends the list).
    -- From 4 packs up, a 2-COLUMN grid (like the battery-profile picker): full-width
    -- rows fit only ~4 packs above the fold on the TX15 (user request 2026-07-22).
    local n = #batts
    local cols = (n >= 4) and 2 or 1
    local btn_w, x0
    if cols == 2 then
        btn_w = math.floor((w - 24 - gap) / 2)
        x0 = math.floor((w - (2 * btn_w + gap)) / 2)
    else
        -- a WIDTH cap belongs on the width: keying it on zone.h gave the 480x272 MK2
        -- narrower buttons than the equally wide 480x320 TX15 for no reason
        btn_w = math.min(460, w - 32)
        x0 = math.floor((w - btn_w) / 2)
    end
    local grid_w = cols * btn_w + (cols - 1) * gap
    local skip_h = fh + 12
    local elems = {}
    local y0 = (h >= 300) and 10 or 6
    local y = y0
    for i = 1, n do
        local b = batts[i]
        local c = (i - 1) % cols
        local r = math.floor((i - 1) / cols)
        y = y0 + r * (row_h + gap)
        local line1 = b.name or b.id
        local line2 = (b.cap and (b.cap .. " mAh") or "capacity ?")
            .. " - " .. (b.cycles or 0) .. " cycles"
        elems[#elems + 1] = { type = "button",
            x = x0 + c * (btn_w + gap), y = y, w = btn_w, h = row_h,
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
    end
    y = y0 + math.ceil(n / cols) * (row_h + gap)
    elems[#elems + 1] = { type = "button", x = x0, y = y, w = grid_w, h = skip_h,
        font = SMLSIZE, text = "No battery / skip",
        press = function()
            wgt.flt_batt_id = nil
            wgt.menu_view = nil
            init_view_state(wgt).dirty = true
        end }
    -- "+ New battery" (B11): the missing-pack moment happens right here. Opens
    -- the Flight Log's create form (toolbox/fltbatt.lua) with models preset to
    -- the connected craft. Only a REQUEST is recorded -- the registry read for
    -- the id prefill runs in the host's own deferred cycle (fltlog.open_batted),
    -- the same pattern as this page's own registry load. Existing entries keep
    -- their stable file order: a new pack appends at the file end.
    elems[#elems + 1] = { type = "button", x = x0, y = y + skip_h + gap, w = grid_w, h = skip_h,
        font = SMLSIZE, text = "+ New battery",
        press = function()
            wgt.batted_req = true
        end }
    pg:build(elems)
end

-- ---- ELRS Status -----------------------------------------------------------
-- What the TX MODULE is configured to, read over CRSF by ultidashElrs (once per
-- connect), held against what the FLIGHT CONTROLLER was told the link carries
-- (crsf_telemetry_link_rate / _link_ratio, MSP 73, already read by the RF
-- service). The FC's pair is a DECLARATION -- nothing verifies it against the
-- real link -- and it paces every telemetry frame the FC emits, so a mismatch
-- is the difference between "telemetry is laggy" and "telemetry is fine".

-- The parsing and the comparison used to live here, in two local functions, and
-- both were wrong in a way only a GemX module shows: "D500" carries no "Hz" so it
-- parsed to nil (no verdict at all), "D50Hz" parsed to 50 where the link runs at
-- 200, and the two numbers were compared for EQUALITY when the flight controller
-- only ever sees the quotient rate/ratio. They now live in ultidash_functions
-- (elrs_rate_hz / elrs_tlm_ratio / elrs_link_verdict), because the notice overlay
-- needs the same answer in the 5 Hz pass -- and because two copies of a comparison
-- are two chances to fix only one of them. Reasoning and the source citations are
-- in the header of that section.

local function build_elrsstatus_view(wgt, zone)
    local w = zone.w
    local v = wgt.values
    local pg = lvgl.page({
        title = "UltiDash", subtitle = "Diagnostics > ELRS Status", icon = icon_path("antenna"),
        back = function() wgt.menu_view = "menu"; init_view_state(wgt).dirty = true end,
    })

    local dash = function(key) return function() return v[key] or "-" end end

    -- Verdict, computed at BUILD time: both inputs only change on a connect (the
    -- module scan) or a reconnect (MSP 73), and either rebuilds this page through
    -- rf_data_dirty. A per-frame closure would re-parse two strings 20 times a
    -- second for a value that cannot move while the page is open.
    local r = ultidash_functions.elrs_link_verdict(wgt)
    local hz_f, rt_f = v.rf_crsf_rate, v.rf_crsf_ratio
    local verdict, vcol = "-", COLOR_THEME_SECONDARY1
    if r ~= nil and r.off then
        verdict, vcol = "TELEM OFF", SEM_RED
    elseif r ~= nil then
        verdict = r.ok and "ok" or "MISMATCH"
        vcol = r.ok and SEM_GREEN or SEM_RED
    end
    -- The rate the LINK actually runs at, which for a DVDA rate ("D500", "D250",
    -- "D50Hz") is not the number in its name -- see elrs_rate_hz. Shown as its own
    -- row so the FC value below can be read against the same number the verdict used,
    -- and so a "-" here says "this rate name is unknown to us" out loud instead of
    -- leaving the verdict row silently blank.
    local hz_m = ultidash_functions.elrs_rate_hz(v.elrs_cfg_rate)

    local items = {
        { section = "TX module" },
        { lbl = "Module",       val = dash("elrs_cfg_name") },
        { lbl = "Firmware",     val = dash("elrs_cfg_ver") },
        -- The commit is the INFO field's value; the version is its name (see
        -- ultidashElrs). Its own row rather than appended to the line above: together
        -- they run past the value column on a 480 px zone.
        { lbl = "Commit",       val = dash("elrs_cfg_commit"),
          omit = (v.elrs_cfg_commit == nil) },
        { lbl = "Read",         val = dash("elrs_cfg_state") },
        { section = "Link configuration" },
        -- Only a dual-band LR1121 module registers "RF Band"; on a 2.4 GHz
        -- module the "-" this row showed read as a read failure on the
        -- 2026-08-16 radio round. Absent parameter -> no row (the page rebuilds
        -- through rf_data_dirty when the scan fills the value in).
        { lbl = "RF band",      val = dash("elrs_cfg_band"),
          omit = (v.elrs_cfg_band == nil) },
        { lbl = "Packet rate",  val = dash("elrs_cfg_rate") },
        { lbl = "Link rate",    val = (hz_m ~= nil) and (tostring(hz_m) .. " Hz") or "-",
          omit = (v.elrs_cfg_rate == nil) },
        { lbl = "Telem ratio",  val = dash("elrs_cfg_tlm") },
        { lbl = "Antenna mode", val = dash("elrs_cfg_ant") },
        { lbl = "Switch mode",  val = dash("elrs_cfg_switch") },
        { lbl = "Link mode",    val = dash("elrs_cfg_link") },
        { lbl = "Model match",  val = dash("elrs_cfg_mm") },
        { lbl = "Max power",    val = dash("elrs_cfg_pwr") },
        { lbl = "Dynamic power",val = dash("elrs_cfg_dyn") },
        { section = "Flight controller expects" },
        { lbl = "Link rate",    val = (hz_f ~= nil) and (tostring(hz_f) .. " Hz") or "-" },
        { lbl = "Link ratio",   val = (rt_f ~= nil) and ("1:" .. tostring(rt_f)) or "-" },
        { lbl = "Telemetry",    val = dash("rf_crsf_text") },
        { lbl = "Rate/ratio match", val = verdict, vcol = vcol },
    }

    -- Row anatomy and measurement copied from the Status page (host
    -- build_status_view): label left, value right, heights MEASURED, page scrolls.
    -- (No SMLSIZE measurement here any more: the two places that needed it -- the section
    -- heads and the closing note -- are focus stops now, and the bar measures its own text.)
    local _, lbl_h = lcd.sizeText("Ag", 0)
    local row_h = lbl_h + 4
    local lblw = math.floor(w * 0.46)
    local y = 2
    for i = 1, #items do
        local it = items[i]
        if it.omit then
            -- a parameter this module does not register: no row at all
        elseif it.section then
            -- The section head is a FOCUS STOP, not a label. Without one the encoder has
            -- nothing to move to and this page does not scroll at all -- eight detents,
            -- byte-identical picture. ultidash_functions.focus_stop carries the mechanism,
            -- the bar's anatomy and the reason the closing note below gets one too. It
            -- takes the ZONE width and puts the bar in the sibling strip's box (10 to
            -- w - 20, clear of the scrollbar) rather than the rows' own w - 40, so the
            -- bars line up with the strip the menu pages already draw.
            y = y + 6
            y = y + ultidash_functions.focus_stop(pg, y, w, it.section,
                                                  SMLSIZE, COLOR_THEME_FOCUS) + 2
        else
            pg:label({ x = 10, y = y, w = lblw, h = lbl_h + 2, text = it.lbl,
                       color = COLOR_THEME_SECONDARY1, align = LEFT })
            pg:label({ x = 10 + lblw, y = y, w = w - lblw - 34, h = lbl_h + 2,
                       text = it.val, color = it.vcol or COLOR_THEME_PRIMARY1, align = RIGHT })
            y = y + row_h
        end
    end

    -- The scan is deliberately connect-only: every CRSF request replaces one RC
    -- channel frame, so it is not run from a page open and not repeated while the
    -- page is up. Say so, rather than letting a stale page look broken.
    -- It is also the LAST focus stop, which is what makes the section above it reachable:
    -- a stop only ever reveals what sits ABOVE it (see focus_stop), so the "Flight
    -- controller expects" rows -- the ones this release added -- would otherwise stay
    -- under the fold for anyone driving the page with the encoder.
    ultidash_functions.focus_stop(pg, y + 8, w,
                                  "Read once per link connect, disarmed only.",
                                  SMLSIZE, COLOR_DIM)
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
    elseif view == "elrsstatus" then build_elrsstatus_view(wgt, zone)
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
