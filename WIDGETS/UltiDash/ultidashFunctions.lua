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

-- Optional file logger (the "Debug log" diagnostics setting). LAZY-LOADED: the
-- ~11 kB module loads only when the DebugLog option first turns ON (default off
-- costs neither heap nor create() budget); once loaded it stays resident for the
-- session (the log buffer/session state live in it). Exposed as
-- ultidash_functions.dbg for the other modules — nil until loaded, so every call
-- site keeps its existing `if ultidash_functions.dbg then` guard semantics.
local dbg = nil
local dbg_avail = fstat("/WIDGETS/UltiDash/ultidashDebug.lua") ~= nil
function ultidash_functions.dbg_load()
    if dbg == nil and dbg_avail then
        local ok, m = pcall(function() return loadScript("/WIDGETS/UltiDash/ultidashDebug.lua")() end)
        if ok then dbg = m; ultidash_functions.dbg = m
        else dbg_avail = false end   -- broken/missing: never retry (and gates stop asking)
    end
    return dbg
end
function ultidash_functions.dbg_loadable()
    return dbg_avail
end

-- color palette shadows (see ultidash.lua, the single source of the palette tables);
-- the resolved 8-slot palette is HANDED IN via ultidash_functions.set_palette(scheme, p).
local COLOR_THEME_PRIMARY1   = COLOR_THEME_PRIMARY1
local COLOR_THEME_PRIMARY2   = COLOR_THEME_PRIMARY2
local COLOR_THEME_SECONDARY1 = COLOR_THEME_SECONDARY1
local COLOR_THEME_SECONDARY2 = COLOR_THEME_SECONDARY2
local COLOR_THEME_SECONDARY3 = COLOR_THEME_SECONDARY3
local COLOR_THEME_FOCUS      = COLOR_THEME_FOCUS
local COLOR_THEME_WARNING    = COLOR_THEME_WARNING
local COLOR_THEME_DISABLED   = COLOR_THEME_DISABLED

-- ePowerbar-style discrete bar colors (after Rob 'bob00' Gayle)
-- Custom callout WAVs live in /SOUNDS/<lang>/ultidash/. The folder follows the
-- VoiceLang setting (en/de), resolved into audio_lang at each sound entry point
-- (see refresh_audio_volume). Spoken numbers/units still come from EdgeTX's own
-- voice pack, i.e. the radio's system language.
local audio_lang = "en"
local function audio_path() return "/SOUNDS/" .. audio_lang .. "/ultidash/" end
-- Battery-bar fill colours. The literals are only the pre-set_palette fallback: since the
-- Colors settings pages these are per-scheme configurable and arrive via the shared `sem`
-- table in set_palette (sem.bar_* — built-ins match these literals, so the default look is
-- unchanged).
-- FALLBACK COPIES: the ONE authoritative source of these values is the `batt`
-- table in ultidash.lua's resolve_builtins — these literals only cover the window before
-- the first set_palette hands the resolved values over. Change them THERE.
local BAR_COLOR_OK       = lcd.RGB(0x00, 0xff, 0x00)
local BAR_COLOR_WARN     = lcd.RGB(0xf8, 0xc0, 0x00)
local BAR_COLOR_LOW      = lcd.RGB(0xff, 0xff, 0x00)
local BAR_COLOR_CRITICAL = lcd.RGB(0xff, 0x00, 0x00)
local BAR_COLOR_CHECK    = lcd.RGB(0xb8, 0xb8, 0xb8)

-- Semantic red/yellow shadows (theme-aware, set per scheme in set_palette from the handed-in
-- `sem`). Used as TEXT colours (unlike the BAR_COLOR_* fills): the ESC-status severity table
-- and the critical status-line ("MAIN POWER LOST" / "RESTART ESC"). Initial values match the
-- old fixed BAR_COLOR_* for the window before the first set_palette.
local sem_red  = BAR_COLOR_CRITICAL
local sem_yell = BAR_COLOR_LOW

-- ESC status severity colors (eStatus). WARN/ERROR are TEXT -> the semantic colours, refreshed
-- per scheme in set_palette; the literals below are just the pre-set_palette fallback.
local ESC_LEVEL_COLORS = {
    [esc.LEVEL_TRACE] = COLOR_THEME_DISABLED,
    [esc.LEVEL_INFO]  = COLOR_THEME_PRIMARY1,
    [esc.LEVEL_WARN]  = BAR_COLOR_LOW,
    [esc.LEVEL_ERROR] = BAR_COLOR_CRITICAL,
}

-- swap the theme color shadows (called from ultidash.lua update() with the palette + semantic
-- colours it resolved). scheme is kept for future use; colours come from `p` and `sem`.
function ultidash_functions.set_palette(scheme, p, sem)
    COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2 = p[1], p[2], p[3], p[4]
    COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS, COLOR_THEME_WARNING, COLOR_THEME_DISABLED = p[5], p[6], p[7], p[8]
    ESC_LEVEL_COLORS[esc.LEVEL_TRACE] = COLOR_THEME_DISABLED
    ESC_LEVEL_COLORS[esc.LEVEL_INFO]  = COLOR_THEME_PRIMARY1
    if sem then
        sem_red, sem_yell = sem.red, sem.yell
        ESC_LEVEL_COLORS[esc.LEVEL_WARN]  = sem_yell   -- was fixed yellow (BAR_COLOR_LOW)
        ESC_LEVEL_COLORS[esc.LEVEL_ERROR] = sem_red    -- was fixed red (BAR_COLOR_CRITICAL)
        -- battery-bar fills (per-scheme configurable since the Colors settings pages)
        BAR_COLOR_OK       = sem.bar_ok    or BAR_COLOR_OK
        BAR_COLOR_WARN     = sem.bar_warn  or BAR_COLOR_WARN
        BAR_COLOR_LOW      = sem.bar_low   or BAR_COLOR_LOW
        BAR_COLOR_CRITICAL = sem.bar_crit  or BAR_COLOR_CRITICAL
        BAR_COLOR_CHECK    = sem.bar_check or BAR_COLOR_CHECK
    end
end

-- Arming-disable flag names (compact eStatus style), 1-based: entry i = bit (i-1) of the
-- ARMD sensor. bit order = armingDisableFlags_e, rotorflight-firmware release/4.6.0
-- src/main/fc/runtime_config.h; names follow RFTool (SCRIPTS/RF2/PAGES/status.lua). Do NOT
-- copy from the firmware's armingDisableFlagNames[] (CLI table, still carries the Betaflight
-- legacy RUNAWAY/CRASH at bits 5/6). Keep in sync with ARM_DISABLE_FLAG_NAMES in
-- ultidashValues.lua. Entries 26/27 (bits 25/26) are API-version dependent -> patched by
-- get_arm_disable_descs().
local ARM_DISABLE_DESCS = {
    "NOGYRO", "FAILSAFE", "RXLOSS", "BADRX", "BOXFAILSAFE", "GOVERNOR", "RPM_SIGNAL",
    "THROTTLE", "ANGLE", "BOOTGRACE", "NOPREARM", "LOAD", "CALIB", "CLI", "CMS",
    "BST", "MSP", "PARALYZE", "GPS", "RESCUE_SW", "RPMFILTER", "REBOOT_REQD",
    "DSHOT_BBANG", "NO_ACC_CAL", "MOTOR_PROTO", "ARMSWITCH",
}

-- Patch the version-dependent last entries on the cached table (cheap, no realloc),
-- mirroring get_arming_disable_flag_names() in ultidashValues.lua. API >= 12.09: bit 25 =
-- OVERRIDE, bit 26 = ARMSWITCH; earlier: bit 25 = ARMSWITCH, bit 26 unused (entry 27 nil
-- so #ARM_DISABLE_DESCS drops back to 26 and the iterators skip it).
local function get_arm_disable_descs()
    if rf2 and rf2.apiVersion and rf2.apiVersion >= 12.09 then
        ARM_DISABLE_DESCS[26] = "OVERRIDE"
        ARM_DISABLE_DESCS[27] = "ARMSWITCH"
    else
        ARM_DISABLE_DESCS[26] = "ARMSWITCH"
        ARM_DISABLE_DESCS[27] = nil
    end
    return ARM_DISABLE_DESCS
end

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
-- Per-cell single-step drop (V) that marks a SUPPLY COLLAPSE rather than real load sag,
-- applied even while ARMED/operating. A genuine in-flight sag between two 5 Hz frames is
-- bounded (a hard collective punch is ~0.3-0.5 V/cell); a buffer takeover crashes the pack
-- through >1 V/cell in a single frame. Beyond this the reading is REJECTED, so the latch
-- freezes at the last HEALTHY value instead of an intermediate decay value (the old
-- misleading "~11 V" artefact that then got announced). Also the trigger for power_lost.
local COLLAPSE_DROP_CELL = 0.8

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
    owner      = nil,     -- the wgt table of the last publisher (dual-publisher detection)
    model_name = nil,     -- FC craft name (cached by the publisher)
    connected  = false,
    -- style: passive views follow the Dashboard's look (the main widget is the boss)
    color_scheme = nil,   -- ColorScheme option value of the Dashboard instance
    bg_filled    = nil,   -- BGFilled as boolean
    thresholds = {
        source = nil,                                  -- "FC config" / "Manual"
        cell_full = nil, cell_warn = nil, cell_crit = nil,  -- volts (resolved)
        reserve = nil,
        rq_warn = nil, rq_crit = nil,
        rss_warn = nil, rss_crit = nil, rss_hold = nil,
        pwr_warn_v = nil, skp_limit = nil,
        tpwr_max = nil,                                -- TPWR bar 100% ref (publish_shared sets it)
        bec_warn = nil, bec_crit = nil,
        esc_load = nil, esc_gvar = nil, esc_warn = nil, esc_crit = nil, esc_hold = nil, esc_limit = nil,
        temp_on = nil,   -- at least one temperature threshold set (drives the Status "sounds off")
    },
    alerts = {
        mute = nil, escalating = nil, repeat_summary = nil,
        cellchk = nil, fuel = nil, volt = nil, arm = nil,
        telem = nil, link = nil, rssi = nil, pwr = nil, bec = nil, escl = nil, skp = nil, temp = nil,
    },
    volume = {
        callout = nil, gvar = nil, flight = nil, escal = nil, voice = nil,
    },
}

-- Per-alert repeat summary (Status page). The option keys (code..Rep/Cnt/Int) are
-- precomputed once here so publish_shared never concatenates them on its 5 Hz path.
local REP_ALERTS = {}
do
    local defs = {
        { "Fuel", "Fuel" }, { "Volt", "Volt" }, { "Cell", "Cell" }, { "Arm", "Arm" },
        { "Telem", "Telem" }, { "Link", "Link" }, { "Rssi", "Rssi" }, { "Pwr", "Pwr" },
        { "Bec", "Bec" }, { "Skp", "Skp" }, { "EscL", "EscL" }, { "Temp", "Temp" },
    }
    for i = 1, #defs do
        REP_ALERTS[i] = { code = defs[i][1], name = defs[i][2],
            rep = defs[i][1] .. "Rep", cnt = defs[i][1] .. "Cnt", int = defs[i][1] .. "Int" }
    end
end

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

-- Effective main-power-loss threshold in volts: "Cell count (auto)" derives
-- it from the connected pack (Cel# or the FC battery config) x the per-cell value
-- (PwrCellV, default 3.0 V/cell -> 3S = 9.0 V = the old fixed default), so 2S..12S work
-- without configuration. "Fixed voltage" (or no cell count seen yet) -> PwrWarnV.
-- Consumed by update_power_warning and the Status-page threshold readout.
local function pwr_warn_threshold(wgt)
    local o = wgt.options
    if (o.PwrSrc or 1) == 1 then
        local cells = wgt.values.cel_count or wgt.values.rf_battery_cell_count
        if cells ~= nil and cells > 0 then
            return math.floor(cells) * (o.PwrCellV or 30) / 10
        end
    end
    return (o.PwrWarnV or 90) / 10
end

-- Publisher snapshot: called from the Dashboard instance's refresh/background.
function ultidash_functions.publish_shared(wgt)
    local o, v = wgt.options, wgt.values
    if not o or not v then return end
    local t, a = Shared.thresholds, Shared.alerts

    -- Dual-publisher detection: two placed Dashboard instances are BOTH publishers (both
    -- write Shared) -> doubled callouts, flickering passive views. If another instance
    -- published recently (fresh ts, foreign owner), flag BOTH (each sees the other's
    -- publishes). Display-only; behaviour is otherwise unchanged. Reads the OLD ts, so this
    -- must run before Shared.ts is updated below.
    local now = getTime() or 0
    if Shared.owner ~= nil and Shared.owner ~= wgt and (now - (Shared.ts or 0)) < 300 then
        wgt.dual_publisher_until = now + 500   -- sticky ~5 s past the last foreign publish
    end
    Shared.owner = wgt

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
    t.rq_warn     = o.RQlyWarn
    t.rq_crit     = o.RQlyCrit
    t.rss_warn    = o.RssWarn
    t.rss_crit    = o.RssCrit
    t.rss_hold    = o.RssHold
    t.pwr_warn_v  = pwr_warn_threshold(wgt)
    t.skp_limit   = o.SkpLimit
    t.tpwr_max    = o.TxPwrMax
    t.bec_warn    = o.BecWarn
    t.bec_crit    = o.BecCrit
    t.esc_load    = (o.EscMon == 1 and (o.EscGvar or 0) ~= 0)   -- monitoring engaged
    t.esc_gvar    = o.EscGvar
    t.esc_warn    = o.EscWarn
    t.esc_crit    = o.EscCrit
    t.esc_hold    = o.EscHold
    t.esc_limit   = wgt.escl_limit          -- session limit (A), nil until latched
    t.temp_on     = ((o.TescWarn or 0) > 0 or (o.TescCrit or 0) > 0
                     or (o.TmcuWarn or 0) > 0 or (o.TmcuCrit or 0) > 0)

    local vol = Shared.volume
    vol.callout = o.Volume or 0
    vol.gvar    = o.VolGvar or 0
    vol.flight  = o.VolFlight or 80
    vol.escal   = o.VolEscal or 100
    vol.voice   = (o.VoiceLang == 2) and "DE" or "EN"

    a.mute       = (o.Mute == 2)
    a.escalating = (wgt.escalate_active == true)
    -- per-alert repeat summary: "Fuel 6s  Telem 5s x3 …" (x<n> = counted, else
    -- continuous). Rebuilt ONLY when the underlying settings change (they change only
    -- via the settings menu) — a cheap integer signature gates the table+string build,
    -- which used to run on every 5 Hz publish for a value that almost never changes.
    local sig = 0
    for i = 1, #REP_ALERTS do
        local ra = REP_ALERTS[i]
        if o[ra.rep] == 1 then
            sig = sig * 1000003 + i * 100000 + (o[ra.cnt] or 0) * 100 + (o[ra.int] or 5)
        end
    end
    if sig ~= wgt.rep_sig then
        wgt.rep_sig = sig
        local rep = {}
        for i = 1, #REP_ALERTS do
            local ra = REP_ALERTS[i]
            if o[ra.rep] == 1 then
                local cnt = o[ra.cnt] or 0
                local int = o[ra.int] or 5
                rep[#rep + 1] = ra.name .. " " .. int .. "s" .. (cnt > 0 and (" x" .. cnt) or "")
            end
        end
        wgt.rep_summary = (#rep > 0) and table.concat(rep, "  ") or nil
    end
    a.repeat_summary = wgt.rep_summary
    a.cellchk = (o.SndCellChk == 1)
    a.fuel    = (o.SndFuel == 1)
    a.volt    = (o.SndVolt == 1)
    a.arm     = (o.SndArm == 1)
    a.telem   = (o.SndTelem == 1)
    a.link    = (o.SndLink == 1)
    a.rssi    = (o.SndRssi == 1)
    a.pwr     = (o.PwrWarn == 1)
    a.bec     = (o.SndBec == 1)
    a.escl    = (o.EscLoad == 1)
    a.skp     = (o.SkpWarn == 1)
    a.temp    = (o.SndTemp == 1)

    Shared.ready = true
end

local function play_audio(file)
    if master_muted then return end
    if audio_volume then
        playFile(audio_path() .. file .. ".wav", audio_volume)
    else
        playFile(audio_path() .. file .. ".wav")
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

-- Speak the battery voltage per the VoltVoice setting: per-cell voltage (PREC2, e.g.
-- "3.45 volt") when selected AND a plausible cell value exists, else total voltage (PREC1)
-- as before. Reads the LATCHED values (vcel/vbat) so the collapse filtering applies to the
-- voice too. Used by the voltage alert and the startup cell check (both read fresh on repeat).
local function announce_voltage(wgt)
    local o = wgt.options
    if o and o.VoltVoice == 2 then
        local v = wgt.values.vcel
        if v and v > MIN_PLAUSIBLE_CELL_V then
            play_number(math.floor(v * 100 + 0.5), UNIT_VOLTS, PREC2)
            return
        end
        -- no plausible cell value -> fall through to total voltage
    end
    local vbat = wgt.values.vbat
    if vbat then play_number(math.floor(vbat * 10 + 0.5), UNIT_VOLTS, PREC1) end
end

-- Speak the descending %-step fuel callout value per the FuelSay setting: the remaining
-- percent (1, default), the battery/pack voltage (2, PREC1), the per-cell voltage (3, PREC2),
-- or the percent followed by one of those two (4 = +battery, 5 = +cell). Independent of
-- VoltVoice (which scopes only the voltage alert / cell check). Reads the LATCHED vbat/vcel so
-- the collapse filtering applies to the voice too. Never goes silent: a voltage-only choice
-- whose value isn't plausibly available falls back to the percent.
local function play_fuel_value(wgt, capa)
    local say = wgt.options.FuelSay or 1
    local said = false
    if say == 1 or say == 4 or say == 5 then
        if capa and capa >= 0 then play_number(capa, UNIT_PERCENT); said = true end
    end
    if say == 2 or say == 4 then
        local vbat = wgt.values.vbat
        if vbat then play_number(math.floor(vbat * 10 + 0.5), UNIT_VOLTS, PREC1); said = true end
    elseif say == 3 or say == 5 then
        local v = wgt.values.vcel
        if v and v > MIN_PLAUSIBLE_CELL_V then
            play_number(math.floor(v * 100 + 0.5), UNIT_VOLTS, PREC2); said = true
        end
    end
    -- voltage-only choice with no plausible reading -> don't stay silent, speak the percent
    if not said and capa and capa >= 0 then play_number(capa, UNIT_PERCENT) end
end

-- Toolbox bank announcement: speak the active EnCh position (1..6) via the EdgeTX voice
-- pack (honors master mute + the widget volume). Used by the adjustment tool pages.
function ultidash_functions.tb_announce_pos(pos)
    if type(pos) ~= "number" then return end
    play_audio("bank")        -- speaks "Bank" ...
    play_number(pos, 0, 0)    -- ... then the position number -> "Bank 1" ... "Bank 6"
end

-- Per-alert haptic. Each alert passes its code; vibration fires only when that alert's
-- "<code>Vib" option is on. Gated by its OWN master (VibMaster), NOT the audio Mute -- so
-- "Mute: All" silences sound while vibration keeps working (and vice versa).
local function play_vibe(wgt, code)
    if not wgt.options or wgt.options.VibMaster ~= 1 then return end
    if code and wgt.options[code .. "Vib"] == 1 then playHaptic(100, 0, PLAY_NOW) end
end

-- ============================================================================
-- PER-ALERT REPEAT (additive layer)
-- ============================================================================
-- An alert, at its first announce, "arms" a repeat with a replay closure. crank_repeats
-- re-plays it every "<code>Int" seconds, up to "<code>Cnt" total announcements (0 = until
-- cleared), and it is dropped when the condition ends (clear_repeat) or the count is
-- reached. This leaves each alert's own first-announce/debounce logic untouched. Alerts
-- that already repeat continuously (Fuel/Voltage) do NOT arm here — they carry their own
-- interval. State lives in wgt.rep[code] = { replay, n, next }; n counts the initial
-- announce, so Cnt = total callouts including the first.
local function arm_repeat(wgt, code, replay)
    wgt.rep = wgt.rep or {}
    if wgt.options[code .. "Rep"] ~= 1 then wgt.rep[code] = nil; return end
    wgt.rep[code] = { replay = replay, n = 1, next = getTime() + (wgt.options[code .. "Int"] or 5) * 100 }
end

local function clear_repeat(wgt, code)
    if wgt.rep then wgt.rep[code] = nil end
end

function ultidash_functions.crank_repeats(wgt)
    local reps = wgt.rep
    if not reps then return end
    local o, now = wgt.options, getTime()
    for code, st in pairs(reps) do
        local cnt = o[code .. "Cnt"] or 0
        if cnt > 0 and st.n >= cnt then
            reps[code] = nil
        elseif now >= st.next then
            if st.replay then st.replay() end
            st.n = st.n + 1
            st.next = now + (o[code .. "Int"] or 5) * 100
        end
    end
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
    if dbg then dbg.log(tag, formatted_text) end   -- mirror to the file log when enabled
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

-- Adaptive master-volume override (OFF unless the VolGvar option is set). Writes a
-- DEDICATED GVAR that a model-side "Volume" special function reads (the SF can only take a
-- source up to channels, so the GVAR is bridged through an input; gate the SF on
-- "GVAR > -1024"). Sentinel -1024 ("lowest") = OFF -> the pilot's volume pot takes over;
-- otherwise the flight volume as a raw FUNC_VOLUME value (volume = (1024+raw)/2048*max).
-- Writes ONLY on change. Publisher-only side-effect; the GVAR is volume-only, so writing
-- it (even while armed, for a later critical boost) cannot touch control. NOT MSP.
local VOL_GVAR_OFF = -1024
local function pct_to_vol_raw(pct)
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    local raw = math.floor(pct / 100 * 2048 - 1024 + 0.5)
    if raw < -1024 then raw = -1024 elseif raw > 1024 then raw = 1024 end
    return raw
end
function ultidash_functions.refresh_volume_override(wgt)
    local o = wgt.options
    if o == nil or type(model) ~= "table" or type(model.setGlobalVariable) ~= "function" then return end
    local gv = o.VolGvar or 0   -- 0 = Off, 1..15 = GV1..GV15
    -- feature off (or target changed): release the GVAR we last drove back to the pot, once
    if gv == 0 or (wgt.vol_gvar_idx ~= nil and wgt.vol_gvar_idx ~= gv - 1) then
        if wgt.vol_gvar_idx ~= nil then
            pcall(model.setGlobalVariable, wgt.vol_gvar_idx, 0, VOL_GVAR_OFF)
            wgt.vol_gvar_idx = nil
            wgt.vol_gvar_last = nil
        end
        if gv == 0 then return end
    end
    wgt.vol_gvar_idx = gv - 1
    -- normal flight volume, boosted to the escalation volume while a critical alert
    -- (with "Escalation volume" enabled) is active — see update_escalation
    local pct = wgt.escalate_active and (o.VolEscal or 100) or (o.VolFlight or 80)
    -- disconnect releases the GVAR (pot rules again) — EXCEPT while an escalation
    -- boost is active: in a disconnect that can only be the Telem alert
    -- (every other ESC_CODE gates on is_craft_armed in alert_active), i.e. an
    -- in-flight link loss with TelemEsc on. Its repeats must come boosted; the
    -- boost ends with the nag (alert_active couples Telem to the running repeat),
    -- so a crash/power-off can't leave the pot overridden. The normal case
    -- (landed, craft switched off) still releases immediately.
    local raw = (is_rf_connected(wgt) or wgt.escalate_active)
        and pct_to_vol_raw(pct) or VOL_GVAR_OFF
    if raw ~= wgt.vol_gvar_last then
        if pcall(model.setGlobalVariable, gv - 1, 0, raw) then wgt.vol_gvar_last = raw end
    end
end

-- resolve the effective callout volume from the settings (see audio_volume above).
-- Also resolves the voice-language folder (audio_path) from the same options table,
-- since this runs at every sound-capable entry point alongside the mute refresh.
local function refresh_audio_volume(wgt)
    audio_lang = (wgt.options and wgt.options.VoiceLang == 2) and "de" or "en"
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

-- Settings "Play" buttons: preview an alert callout with the page's WORKING (unsaved)
-- values — language, widget volume, master mute and VoltVoice come from the working copy
-- so the preview matches what the page currently shows, before saving. Only reachable
-- from the settings menu, which closes on arm — so this never speaks in flight. This is
-- the one sanctioned direct playFile/playNumber site besides play_audio/play_number:
-- it must NOT read the saved options the way those do.
-- spec = { files = {wav, ...}, num = {value, unit, prec}, voltnum = true }:
-- voltnum speaks a sample voltage in the format the working VoltVoice selects.
function ultidash_functions.test_callout(wgt, working, spec)
    local o = working or (wgt and wgt.options) or {}
    if o.Mute == 2 then return end             -- master mute: the preview stays honest
    local lang = (o.VoiceLang == 2) and "de" or "en"
    local vol = o.Volume or 0
    if vol > 0 and (o.VolWhen or 1) == 2 and not is_rf_connected(wgt) then vol = 0 end
    local path = "/SOUNDS/" .. lang .. "/ultidash/"
    if spec.files then
        for i = 1, #spec.files do
            local f = path .. spec.files[i] .. ".wav"
            if vol > 0 then playFile(f, vol) else playFile(f) end
        end
    end
    local n = spec.num
    if spec.voltnum then
        n = (o.VoltVoice == 2) and { 370, UNIT_VOLTS, PREC2 } or { 222, UNIT_VOLTS, PREC1 }
    end
    if n then
        if vol > 0 then playNumber(n[1], n[2] or 0, n[3] or 0, vol)
        else playNumber(n[1], n[2] or 0, n[3] or 0) end
    end
end

-- Per-tick sensor read cache: within one refresh pass (same getTime centisecond) each
-- sensor NAME is resolved at most once; later callers in the same pass get the cached
-- value (incl. a cached nil). No per-tick table allocation (epoch-tagged entries). Shared
-- by every update_*/alert reader so a pass does ONE lookup per sensor, not several -- ~35
-- name lookups per pass once starved the Lua scheduler (fullscreen taps became a lottery).
-- Negative-result hold while DISCONNECTED (centiseconds): with no craft every read
-- returns nil, and re-probing an unresolvable NAME is the most expensive lookup kind
-- (full source-table scan without a hit). Idle passes re-probe each nil name only
-- every SRC_NEG_TTL instead of every pass — measurably lifts the idle UI Hz while
-- menus/tools are used. The guard tests the LIVE connection state, so the instant
-- RFTool reports anything but "disconnected" (onStateChanged) the hold is void and
-- the next pass reads fresh — no pickup delay on connect, no effect while flying.
local SRC_NEG_TTL = 300

local function read_src(wgt, name)
    local now = getTime() or 0
    local c = wgt.src_cache
    if c == nil then c = { e = {}, v = {} }; wgt.src_cache = c end
    local e = c.e[name]
    if e == now then return c.v[name] end
    if e ~= nil and c.v[name] == nil and (now - e) < SRC_NEG_TTL
        and wgt.values ~= nil and wgt.values.rf_connection_state == "disconnected" then
        return nil
    end
    c.e[name] = now
    -- app-id resolver: if the resolver (ultidash.lua) mapped this curated name to a VERIFIED
    -- telemetry index, read BY INDEX so a same-named native CRSF sensor (duplicate) or a user
    -- rename can't shadow the RF custom sensor. No verified index -> plain name read (the
    -- former behaviour; also the path for ELRS / name-only sensors that carry no app-id).
    local idx = wgt.sensor_idx and wgt.sensor_idx[name]
    -- resolver indices live in the getFieldInfo/getValue space (NOT getSourceName's) -> read
    -- via getValue, the proven pair for these ids (toolbox srcOf pattern)
    if idx then c.v[name] = getValue(idx) else c.v[name] = getSourceValue(name) end
    return c.v[name]
end
ultidash_functions.read_src = read_src   -- update_user_sensors (ultidash.lua) shares the cache

-- The skipped-packet sensor is "*Skp" on newer telemetry, "Skp" on older; resolve the name
-- ONCE (sticky) so a pass never probes both.
local skp_name = nil
local function read_skp(wgt)
    if skp_name then return read_src(wgt, skp_name) end
    local v = read_src(wgt, "*Skp")
    if v ~= nil then skp_name = "*Skp"; return v end
    v = read_src(wgt, "Skp")
    if v ~= nil then skp_name = "Skp" end
    return v
end

-- Armed detection. Prefer the ARM telemetry sensor (Rotorflight arming flags, bit 0 =
-- armed) because it's always available and authoritative; the RFTool connection state
-- ("armed") is only a fallback (it doesn't reliably report the armed sub-state on every
-- setup, which left flight-time tracking at 00:00). Reads via read_src, so the many
-- per-pass callers (nearly every alert) share ONE ARM lookup per centisecond.
local function is_craft_armed(wgt)
    local arm = read_src(wgt, "ARM")
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

-- Raw ARM-sensor state, WITHOUT the rf_connection_state fallback: true only when the
-- ARM telemetry sensor is present AND reports armed; nil telemetry (dropout) -> false.
-- The EdgeTX logs show this sensor is clean (1 -> 0, no flicker) even through a
-- main-power-lost, unlike the connection sub-state — so it's the trustworthy signal for
-- the stats-page dismiss edge (a stale/flaky connection state must not reopen the page).
function ultidash_functions.arm_sensor_on(wgt)
    local arm = read_src(wgt, "ARM")
    if arm == nil then return false end
    arm = math.floor(arm)
    return (arm % 2) == 1 or arm == 1024
end

-- "Operating" = actively flying, taken from the RF TOOL's armed state (its armed/disarmed
-- transitions are clean on this setup — see the debug logs — whereas the ARM telemetry
-- sensor holds a STALE "armed" for ~30 s after a disconnect). This gates the voltage
-- LATCH and the widget's stats extrema ONLY: once the RF tool leaves "armed" (disarm or
-- disconnect) the latch holds the last in-flight value and extrema stop, so a regular
-- disarmed unplug / backup-buffer decay can't pollute the display or the statistics.
-- (is_craft_armed, the MSP-safety gate, deliberately stays on the ARM sensor.)
local function is_operating(wgt)
    return wgt.values.rf_connection_state == "armed"
end

-- headspeed (rpm) above which the rotor counts as "spinning" (flight time + the
-- extrema fallback gate below)
local FLIGHT_TIME_MIN_HEADSPEED = 100

-- gov_state enum (RF 2.2/2.3): 0 off, 1 idle, 2 spooling, 3 recovery, 4 active,
-- 5 throttle-hold, 6 fallback, 7 autorotation, 8 bailout, 9 bypass (RF 2.3, new).
-- "running" = >2 and not 5; 9/Bypass deliberately counts as running (rotor spins,
-- extrema tracking wanted). In gov_mode OFF/LIMIT the firmware never updates
-- gov.state -> the sensor stays constant 0 -> the state gate never engages there.
-- When the FC EXPLICITLY reports such a mode (rf_gov_has_state == false, read from
-- mspGovernorConfig on connect/disarm), fall back to the flight-time pattern:
-- operating (RFTool armed) + rotor spinning; without an Hspd sensor, operating-only.
-- Unknown mode (no FC / old RFTool / failed read) keeps the strict state gate.
local function should_track_governor_run_extrema(wgt)
    local track = false
    local g = wgt.values.gov_state
    if g ~= nil and g > 2 and g ~= 5 then
        track = true
    elseif wgt.values.rf_gov_has_state == false and is_operating(wgt) then
        local hs = wgt.values.headspeed       -- cached by update_headspeed (same 5 Hz pass)
        track = (hs == nil) or hs > FLIGHT_TIME_MIN_HEADSPEED   -- no Hspd sensor -> operating-only
    end
    -- debounce bookkeeping for the stricter MIN gate below: remember when the broad
    -- gate last BECAME true (nil while false). Called several times per 5 Hz pass
    -- (curr + headspeed trackers) — idempotent.
    if track then
        if wgt.gov_track_since == nil then wgt.gov_track_since = getTime() or 0 end
    else
        wgt.gov_track_since = nil
    end
    return track
end

-- MIN extrema use a STRICTER gate (field report: "always spools up in P2 -> P2 min
-- 500 rpm"). The broad gate above also tracks the ramp states RECOVERY/AUTOROTATION/
-- BAILOUT — a re-spool after a throttle hold is RECOVERY and gets tracked from its
-- first (low-rpm) sample; the Hspd telemetry additionally lags the SPOOLUP->ACTIVE
-- transition by a couple of seconds. So the MINIMUM only tracks in the steady states
-- ACTIVE/FALLBACK/BYPASS (4/6/9), and only once the broad gate has been continuously
-- true for ~2 s (kills the telemetry-lag edge; in the OFF/LIMIT fallback world, which
-- has no states, the debounce is the only extra protection). MAX keeps the broad gate
-- on purpose — an overspeed during an autorotation entry or bailout is exactly what a
-- maximum should catch.
local GOV_MIN_TRACK_DEBOUNCE = 200   -- centiseconds (~2 s)
local function should_track_governor_min_extrema(wgt)
    if not should_track_governor_run_extrema(wgt) then return false end
    local since = wgt.gov_track_since
    if since == nil or ((getTime() or 0) - since) < GOV_MIN_TRACK_DEBOUNCE then return false end
    local g = wgt.values.gov_state
    if g == 4 or g == 6 or g == 9 then return true end
    -- broad gate true without a steady state -> either a ramp state (min stays off)
    -- or the state-less OFF/LIMIT fallback world (min tracks, debounce-guarded only)
    return not (g ~= nil and g > 2 and g ~= 5)
end

-- Flight-time tracking: count only while ARMED *and* the rotor is spinning (both in
-- combination). Sensors are read via read_src (fresh sensor read, cached only within the
-- pass), independent of the refresh path / rf_connection_state / any wgt.values caching —
-- that indirection was unreliable (rfToolState is nil on this RFTool, so cached values
-- could be stale).
local function should_track_flight_time(wgt)
    -- On a positively-dead link (RQly == 0 -> telemetry_alive false, set in
    -- maybe_reset_stats) EdgeTX serves the FROZEN last ARM/Hspd values until sensor
    -- expiry (~30 s), which kept the flight clock running after an in-flight RX/
    -- telemetry loss. Stop immediately; nil/unknown RQly keeps the legacy behavior.
    -- (RQly -> 0 on link loss is the long-HW-proven basis of the stats freeze.)
    if wgt.telemetry_alive == false then return false end
    local arm = read_src(wgt, "ARM")
    if arm ~= nil then
        arm = math.floor(arm)
        if (arm % 2) ~= 1 and arm ~= 1024 then return false end   -- ARM bit0 clear = disarmed
    elseif not is_craft_armed(wgt) then
        return false                                              -- no ARM sensor -> cached state
    end
    local hs = read_src(wgt, "Hspd")
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
    wgt.power_lost = nil
    wgt.pwr_lost_latched = nil
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
    wgt.sag_count = nil; wgt.sag_min = nil; wgt.sag_below = nil
    wgt.values.sag_count = nil; wgt.values.sag_min = nil
    wgt.values.capa = nil
    wgt.values.capa_percent = nil
    wgt.values.capa_max = nil
    wgt.values.capa_percent_min = nil
    wgt.values.batt_checking = false
    wgt.values.batt_check_progress = 0
    wgt.batt_warn = false
    clear_repeat(wgt, "Cell")              -- stop any cell-check nag on disconnect
    clear_repeat(wgt, "Arm")               -- ditto the "still armed" reminder
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
    wgt.esc_status_st = nil       -- get_status result memo
    wgt.esc_status_sig = nil
    wgt.arm_txt_cache = nil       -- arming-reason string memo
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
    -- temperature warning state (both sensors' latches + the shared repeat)
    wgt.tesc_pending = 0; wgt.tesc_level = 0; wgt.tesc_announced = 0
    wgt.tmcu_pending = 0; wgt.tmcu_level = 0; wgt.tmcu_announced = 0
    clear_repeat(wgt, "Temp")
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
    v.capa_max, v.capa_percent_min = nil, nil
    v.headspeed_min, v.headspeed_max = nil, nil
    v.sag_count, v.sag_min = nil, nil
    wgt.sag_count, wgt.sag_min, wgt.sag_below = nil, nil, nil
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

    local rqly = read_src(wgt, "RQly")
    wgt.telemetry_alive = (rqly == nil) or (rqly > 0)

    if rqly ~= nil and rqly > 0 and wgt.stats_reset_pending then
        reset_stat_sensors(wgt)
        wgt.stats_reset_pending = false
    end
end

-- ============================================================================
-- GENERAL INFO UPDATES
-- ============================================================================
-- model.getInfo() allocates a fresh table per call and is read by BOTH update_craft_name
-- and update_model_image every 5 Hz pass. Cache it per centisecond (the active model is
-- global, so one module-local cache serves all instances) to drop the duplicate alloc.
local mi_cache, mi_cache_t
local function cached_model_info()
    local now = getTime() or 0
    if mi_cache_t ~= now then mi_cache = model.getInfo(); mi_cache_t = now end
    return mi_cache
end

-- getGeneralSettings() allocates a fresh table per call and was read every 5 Hz pass;
-- the radio's battery limits change only when the user edits radio settings —
-- cache for 10 s (module-local: the settings are global, one cache serves all instances).
local gs_cache, gs_cache_t
local function cached_general_settings()
    local now = getTime() or 0
    if gs_cache == nil or now - (gs_cache_t or 0) >= 1000 then
        gs_cache = getGeneralSettings(); gs_cache_t = now
    end
    return gs_cache
end

function ultidash_functions.update_craft_name(wgt)
    -- Prefer the Rotorflight FC model name and CACHE it, so the stats page (shown
    -- on disconnect, where rf2.modelName goes nil) keeps showing the FC name rather
    -- than falling back to the EdgeTX model/profile name. Only fall back to the
    -- EdgeTX name if no FC name was ever seen. Each gsub runs ONLY when its raw input
    -- changes (it would otherwise allocate a string on every 5 Hz pass).
    local fc_name = rf2 and rf2.modelName
    if fc_name and fc_name ~= "" then
        if fc_name ~= wgt.craft_name_raw then
            wgt.craft_name_raw = fc_name
            wgt.values.rf_craft_name = string.gsub(fc_name, "^>", "")
        end
    end

    local name = wgt.values.rf_craft_name
    if not name then
        local model_info = cached_model_info()
        local raw = (model_info and model_info.name) or "Unknown"
        if raw ~= wgt.model_name_raw then
            wgt.model_name_raw = raw
            wgt.model_name_clean = string.gsub(raw, "^>", "")
        end
        name = wgt.model_name_clean
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
    local mi = cached_model_info()
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
    -- Re-format only when the displayed second actually changes (the 5 Hz pass runs 5x/s
    -- but the mm:ss text moves at most 1x/s). timer_is_negative is derived cheaply every
    -- pass; the string.format is what we skip.
    local t1 = model.getTimer(wgt.options.Timer or 0)
    local tv = t1 and t1.value or nil
    if not wgt.timer_primed or tv ~= wgt.timer_last_val then
        wgt.timer_last_val = tv
        wgt.timer_primed = true
        wgt.values.timer_str = (format_time(t1))
    end
    wgt.values.timer_is_negative = (tv ~= nil) and tv < 0 or false

    local now = getTime() or 0
    if should_track_flight_time(wgt) then
        if wgt.flight_time_last_tick ~= nil and now > wgt.flight_time_last_tick then
            wgt.flight_time_elapsed = (wgt.flight_time_elapsed or 0) + (now - wgt.flight_time_last_tick)
        end
        wgt.flight_time_last_tick = now
    else
        wgt.flight_time_last_tick = nil
    end

    local fsec = math.floor((wgt.flight_time_elapsed or 0) / 100)
    if not wgt.ft_primed or fsec ~= wgt.ft_last_sec then
        wgt.ft_last_sec = fsec
        wgt.ft_primed = true
        wgt.values.flight_time_str = format_elapsed_time(wgt.flight_time_elapsed or 0)
    end
end

function ultidash_functions.update_profiles(wgt)
    wgt.values.profile_id = read_src(wgt, "PID#")
    wgt.values.rate_id = read_src(wgt, "RTE#")
    wgt.values.rf_battery_profile = read_src(wgt, "BAT#")
    if wgt.sync_active_battery_capacity then
        wgt.sync_active_battery_capacity(wgt)
    end
end

-- ============================================================================
-- TRANSMITTER/RADIO UPDATES
-- ============================================================================

function ultidash_functions.update_tx_bat_voltage(wgt)
    wgt.values.vtx_volts = read_src(wgt, "tx-voltage")
    local gs = cached_general_settings()
    wgt.values.vtx_volts_max = gs.battMax
    wgt.values.vtx_volts_min = gs.battMin
    wgt.values.vtx_volts_warn = gs.battWarn

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
        wgt.values.rqly_min = read_src(wgt, "RQly-")
    end
end

function ultidash_functions.update_transmitter_power(wgt)
    -- Only track maximum transmitter power; current value not needed.
    -- read_src, not a bare getValue: shares the per-tick cache and the
    -- verified app-id index like every other sensor read on the pass.
    if wgt.telemetry_alive ~= false then
        wgt.values.tpwr_max = read_src(wgt, "TPWR+")
    end
end

-- ============================================================================
-- ELRS LINK INFO (RFMD rate, RQ/TQ, RSSI headroom, diversity)  -- slice 1: data
-- ============================================================================
-- RFMD enum -> { rate_str, min_rssi_dBm (sensitivity floor), desc, no_snr? }.
-- 4th field true = no-SNR modulation: FLRC *and* FSK/Kernel modes both report SNR
-- constant 0 (LR1121Driver sets LastPacketSNRRaw = 0 for GFSK; signal-health doc
-- confirms it for FLRC) -> the SNR row shows "-" instead of a yellow 0dB bar.
-- Covers ELRS 3.x sequential (1-13, 2.4GHz) + 4.x 2.4GHz (21-41) + GemX (100+).
-- 900MHz 4.x (0-16) collides with 3.x and is NOT disambiguated (rare on a heli) —
-- see ultidash_resourcesandtools/elrs_rfmd_reference.md.
local RFMD_INFO = {
    [1]={"25Hz",-123,"25Hz (LORA)"},   [2]={"50Hz",-115,"50Hz (LORA)"},   [3]={"100Hz",-117,"100Hz (LORA)"},
    [4]={"100HzF",-112,"100Hz (LORA-full)"}, [5]={"150Hz",-112,"150Hz (LORA)"}, [6]={"200Hz",-112,"200Hz (LORA)"},
    [7]={"250Hz",-108,"250Hz (LORA)"}, [8]={"333HzF",-105,"333Hz (LORA-full)"}, [9]={"500Hz",-105,"500Hz (LORA)"},
    [10]={"D250",-104,"250Hz (FLRC-DVDA)",true}, [11]={"D500",-104,"500Hz (FLRC-DVDA)",true}, [12]={"F500",-104,"500Hz (FLRC)",true}, [13]={"F1000",-104,"1000Hz (FLRC)",true},
    -- 3.x additive gaps confirmed against expresslrs.org/info/signal-health (2026-07):
    -- D50/DK500/K1000Full previously fell through to "no link". Floors per that doc; note
    -- the low-index floors are band-dependent (this block is treated 2.4GHz — see .md).
    [14]={"D50",-112,"50Hz (DVDA LoRa)"}, [16]={"DK500",-101,"500Hz (DVDA FSK)",true}, [19]={"K1000F",-101,"1000Hz FSK-full",true},
    [21]={"50Hz",-115,"50Hz (LORA)"},  [23]={"100HzF",-112,"100Hz (LORA-full)"}, [24]={"150Hz",-112,"150Hz (LORA)"},
    [27]={"250Hz",-108,"250Hz (LORA)"}, [28]={"333HzF",-105,"333Hz (LORA-full)"}, [29]={"500Hz",-105,"500Hz (LORA)"},
    [30]={"D250",-104,"250Hz (FLRC-DVDA)",true}, [31]={"D500",-104,"500Hz (FLRC-DVDA)",true}, [32]={"F500",-104,"500Hz (FLRC)",true}, [33]={"F1000",-103,"1000Hz (FLRC)",true},
    -- 34-36 per signal-health 4.x table (2026-07): Kernel/DK modes are FSK+FEC (LR1121),
    -- floors -103; the table lists NO K500 and ends at 36 — [37] kept as a defensive
    -- alias so an unexpected 37 doesn't fall through to "no link".
    [34]={"DK250",-103,"250Hz (DVDA FSK)",true}, [35]={"DK500",-103,"500Hz (DVDA FSK)",true}, [36]={"K1000",-103,"1000Hz (FSK)",true}, [37]={"K1000",-103,"1000Hz (FSK)",true},
    [40]={"AP500",-105,"500Hz (Airport)"}, [41]={"APF1000",-103,"1000Hz FLRC (Airport)",true},
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
        v.elrs_trss  = math.floor(-70 - 15 * sim_wave(22, 0.6))
        v.elrs_tsnr  = math.floor(6 + 5 * sim_wave(30, 0.5))
    else
        v.elrs_rfmd  = read_src(wgt, "RFMD")
        v.elrs_rq    = read_src(wgt, "RQly")
        v.elrs_tq    = read_src(wgt, "TQly")
        v.elrs_r1_dbm = read_src(wgt, "1RSS")
        v.elrs_r2_dbm = read_src(wgt, "2RSS")
        v.elrs_snr   = read_src(wgt, "RSNR")
        v.elrs_tpwr  = read_src(wgt, "TPWR")
        -- Downlink (TX-module-measured) RSSI/SNR: separates downlink issues (telemetry
        -- dropouts, module antenna, too-low telemetry ratio, EU LBT) from uplink/control
        -- problems. nil-tolerant (only present if the sender created the sensors).
        v.elrs_trss  = read_src(wgt, "TRSS")
        v.elrs_tsnr  = read_src(wgt, "TSNR")
        -- cached here so the bottom-bar getters never do per-frame name lookups
        v.skp_raw    = read_skp(wgt)
        local ant = read_src(wgt, "ANT")
        v.elrs_ant   = ant and math.floor(ant) or nil
        -- Diversity LATCH: the LinkStats frame ALWAYS carries ANT (constant 0 on a
        -- single-antenna RX), so the old "ant ~= nil" test was a false positive. Report
        -- diversity only once data proves it (2RSS live, or ANT actually switched to 1)
        -- and keep it latched for the session -- reset only in create() (a mid-session
        -- RX swap without a widget reload is an accepted edge case).
        if (v.elrs_r2_dbm ~= nil and v.elrs_r2_dbm ~= 0)
            or (ant ~= nil and ant ~= 0) then
            v.elrs_diversity = true
        end
    end

    local info = v.elrs_rfmd and RFMD_INFO[math.floor(v.elrs_rfmd)] or nil
    v.elrs_rate_str  = info and info[1] or "-"
    v.elrs_rate_desc = info and info[3] or "no link"
    local floor = info and info[2] or nil
    v.elrs_flrc = (info and info[4]) == true   -- no-SNR mode (FLRC or FSK): SNR constant 0

    v.elrs_r1_pct = rssi_to_pct(v.elrs_r1_dbm, floor)
    v.elrs_r2_pct = rssi_to_pct(v.elrs_r2_dbm, floor)
    -- downlink RSSI headroom: approximated with the SAME per-rate floor (the downlink
    -- runs in the same RF mode as the uplink)
    v.elrs_trss_pct = rssi_to_pct(v.elrs_trss, floor)
end

-- ============================================================================
-- AIRCRAFT TELEMETRY: VOLTAGE & TEMPERATURE
-- ============================================================================

-- Latched voltage update (see the MIN_PLAUSIBLE_CELL_V / VOLT_* notes at the top):
-- ≤ 1 V never overwrites the held value; while disarmed a drop > drop_delta below
-- the held value is only accepted once it stayed stable for VOLT_ACCEPT_CS.
-- Returns true when `raw` was accepted into wgt.values[key].
local function latch_voltage(wgt, key, raw, drop_delta, collapse_delta)
    local pend_key = key .. "_pending"
    if raw == nil or raw <= MIN_PLAUSIBLE_CELL_V then
        wgt[pend_key] = nil                       -- collapse tail / no data
        return false
    end
    local held = wgt.values[key]
    if held == nil then
        wgt.values[key] = raw
        wgt[pend_key] = nil
        return true
    end
    if is_operating(wgt) then
        -- ARMED: accept real load sag live, but REJECT an implausibly large single-step
        -- drop — that is a supply collapse (buffer takeover), not sag. Rejecting freezes
        -- the latch at the last healthy value (see COLLAPSE_DROP_CELL); the caller reads
        -- `not accepted` as supply_collapsed and engages power_lost.
        if collapse_delta == nil or raw >= held - collapse_delta then
            wgt.values[key] = raw
            wgt[pend_key] = nil
            return true
        end
        return false
    end
    if raw >= held - drop_delta then
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
    -- Per-tick guard: called from both refresh_ui and update_battery_callout in the same
    -- pass -- run the latch/collapse/extrema logic exactly ONCE per centisecond.
    local now = getTime() or 0
    if wgt.upd_cell_t == now then return end
    wgt.upd_cell_t = now
    -- Latched (see latch_voltage): the buffer-bridged unplug decay never overwrites
    -- the last good value, so the stats "Latest" column freezes at the real last
    -- battery state instead of 0.00 / a mid-decay value. The collapse itself is still
    -- detected by update_power_warning, which reads the sensor directly.
    local raw = read_src(wgt, "Vbat")
    local cells = wgt.values.cel_count or 6
    local accepted = latch_voltage(wgt, "vbat", raw, VOLT_DROP_CELL * cells, COLLAPSE_DROP_CELL * cells)
    -- Main-supply-collapse flag: a real Vbat reading that the latch rejected while we
    -- already hold a good value means the main supply is collapsing/collapsed (unplug
    -- on a buffer). Fires on the FIRST decay frame — other channels (BEC) use it to
    -- hold their last NORMAL value, because once the buffer feeds the rail their
    -- reading shows the buffer, not their own state. False at session start (no held
    -- value yet) and cleared as soon as a reading is accepted again.
    wgt.supply_collapsed = (raw ~= nil and not accepted and wgt.values.vbat ~= nil)
    -- Sticky MAIN-POWER-LOST mode: engaged the moment a collapse is detected while a good
    -- value is still held (main pack gone, the rail running on the buffer); held through the
    -- ~0 V decay tail and cleared only when a healthy reading is accepted again (power
    -- restored) or a disarm/disconnect resets the callout state. Drives the "only main-power-
    -- lost + BEC" callout suppression, the "--" main-voltage display and the MAIN POWER LOST
    -- status line. A disarmed bench unplug can also set supply_collapsed for one pass, but
    -- update_battery_callout's disarmed guard clears power_lost again in the same cycle.
    if wgt.supply_collapsed then
        wgt.power_lost = true
    elseif accepted then
        wgt.power_lost = false
    end
    -- Widget-tracked min/max, recorded ONLY while ARMED (operating) — like the RPM
    -- extrema gate on the governor run-state. The disarmed unplug decay is excluded
    -- twice over (armed gate + latch).
    if is_operating(wgt) and wgt.values.vbat ~= nil then
        update_tracked_extrema(wgt, "vbat", "vbat_min", "vbat_max")
    end

    if ultidash_functions.simu_mode then
        wgt.values.vbat = sim_vcel() * SIM_CELLS
        wgt.values.vbat_min = 3.70 * SIM_CELLS
        wgt.values.vbat_max = 4.15 * SIM_CELLS
    end
end

function ultidash_functions.update_vcel(wgt)
    -- Per-tick guard (see update_cell): run once per pass even though two callers hit it.
    local now = getTime() or 0
    if wgt.upd_vcel_t == now then return end
    wgt.upd_vcel_t = now
    -- latched like update_cell (fixes "Latest 0.00" after a buffer-bridged unplug)
    local accepted = latch_voltage(wgt, "vcel", read_src(wgt, "Vcel"), VOLT_DROP_CELL, COLLAPSE_DROP_CELL)
    -- widget-tracked, ARMED-only (see update_cell)
    if is_operating(wgt) and wgt.values.vcel ~= nil then
        update_tracked_extrema(wgt, "vcel", "vcel_min", "vcel_max")
    end
    -- Cell count follows the voltage latch: the FC derives Cel# from Vbat, so during a
    -- collapse it reports 0 (or transient counts like 1S mid-decay) — only accept it on
    -- frames whose voltage was accepted too (fixes the "(0S)" header on the stats page).
    local cells = read_src(wgt, "Cel#")
    if (accepted or wgt.values.vcel == nil) and cells ~= nil and cells > 0 then
        wgt.values.cel_count = cells
    end

    -- Voltage-sag tracker: counts episodes where the (latched) cell voltage dips
    -- to/below the CRITICAL threshold -- including the brief load sags the 0.5 s
    -- alert debounce deliberately ignores. Threshold = vcel_alarm_threshold() (FC
    -- config or manual, same source as the voltage alert). +0.05 V hysteresis stops
    -- flutter-counting while hovering around the threshold. Pure reader: no sensor
    -- read, latch/collapse logic untouched; a main-power collapse (power_lost) is
    -- NOT a sag. Reset with the other session extrema (clear_live/reset_stat_sensors).
    if is_craft_armed(wgt) and not wgt.power_lost then
        local vcel = wgt.values.vcel
        local crit = wgt.values.vcel_alarm_threshold()
        if wgt.sag_below then
            if vcel ~= nil and vcel < (wgt.sag_min or 99) then wgt.sag_min = vcel end
            if vcel == nil or vcel > crit + 0.05 then wgt.sag_below = false end
        elseif vcel ~= nil and crit > 0 and vcel <= crit then
            wgt.sag_below = true
            wgt.sag_count = (wgt.sag_count or 0) + 1
            if vcel < (wgt.sag_min or 99) then wgt.sag_min = vcel end
        end
        wgt.values.sag_count = wgt.sag_count
        wgt.values.sag_min = wgt.sag_min
    end

    if ultidash_functions.simu_mode then
        wgt.values.vcel = sim_vcel()
        wgt.values.vcel_max = 4.15
        wgt.values.vcel_min = 3.70
        wgt.values.cel_count = SIM_CELLS
    end
end

function ultidash_functions.update_vbec(wgt)
    -- BEC is shown LIVE (NOT latched, unlike Vbat/Vcel): during a backup event (main pack
    -- gone, the rail running on the buffer) the pilot must see the buffer actually sagging,
    -- not a frozen last-normal value. Only the plausibility floor stays (ignore <=1 V "no
    -- data" so a brief dropout doesn't blank the reading). NB: supply_collapsed is only a
    -- transient collapse-in-progress flag (it clears once the buffer voltage settles and is
    -- accepted as Vbat), so it can't gate this reliably — hence: no latch at all for Vbec.
    local raw = read_src(wgt, "Vbec")
    if raw ~= nil and raw > MIN_PLAUSIBLE_CELL_V then
        wgt.values.vbec = raw
    end
    -- widget-tracked, operating-only (see update_cell / is_operating)
    if is_operating(wgt) and wgt.values.vbec ~= nil then
        update_tracked_extrema(wgt, "vbec", "vbec_min", "vbec_max")
    end

    if ultidash_functions.simu_mode then
        wgt.values.vbec = 8.0
        wgt.values.vbec_max = 8.4
        wgt.values.vbec_min = 7.8
    end
end

function ultidash_functions.update_esc_temperature(wgt)
    wgt.values.esc_temp = read_src(wgt, "Tesc")

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
    if wgt.telemetry_alive ~= false then wgt.values.mcu_temp_max = read_src(wgt, "Tmcu+") end
end

-- ============================================================================
-- AIRCRAFT TELEMETRY: CURRENT & CAPACITY
-- ============================================================================
-- Current source is user-selectable (CurrSrc): FC battery current (Curr) or the
-- ESC-reported current (EscI = ESC1 telemetry group, Iesc = FC single-value group).
-- read_src resolves the name by appId (immune to duplicate/renamed CRSF sensors);
-- all current consumers (Current row, ESC load, curr min/max) follow automatically.
local CURR_SRC_NAMES = { "Curr", "EscI", "Iesc" }   -- keep in sync with the CurrSrc choice

function ultidash_functions.update_curr(wgt)
    local o = wgt.options
    local name = CURR_SRC_NAMES[(o and o.CurrSrc) or 1] or "Curr"
    wgt.values.curr = read_src(wgt, name)

    if ultidash_functions.simu_mode then
        wgt.values.curr = 28 + 12 * sim_wave(20, 0.3)   -- ~28..40 A
    end

    if should_track_governor_run_extrema(wgt) then
        local v = wgt.values.curr
        if v ~= nil then
            if wgt.values.curr_max == nil or v > wgt.values.curr_max then wgt.values.curr_max = v end
            -- min only in steady governor states + after the debounce (see the gate)
            if should_track_governor_min_extrema(wgt)
                and (wgt.values.curr_min == nil or v < wgt.values.curr_min) then
                wgt.values.curr_min = v
            end
        end
    end
end

function ultidash_functions.update_ma_used(wgt)
    local now = getTime() or 0
    if wgt.upd_ma_t == now then return end
    wgt.upd_ma_t = now
    wgt.values.capa = read_src(wgt, "Capa")
    wgt.values.capa_percent = read_src(wgt, "Bat%")

    if ultidash_functions.simu_mode then
        wgt.values.capa_percent = 40 + 40 * sim_wave(150, 0)   -- ~40..80 %, very slow
        wgt.values.capa = math.floor((100 - wgt.values.capa_percent) / 100 * 2500)
    end

    -- Session extrema tracked from the live values (same pattern as curr_max): the
    -- stats-page footer shows these so "mAh Used" is the total consumed and survives a
    -- link loss (Capa is monotonic, so its max == total used; once telemetry drops the
    -- live Capa reads 0 but the tracked max holds). The fuel % keeps its lowest reading;
    -- guard against the 0 a lost sensor reports so a glitch can't pin "lowest %" to 0.
    local cu = wgt.values.capa
    if cu ~= nil and (wgt.values.capa_max == nil or cu > wgt.values.capa_max) then
        wgt.values.capa_max = cu
    end
    local cp = wgt.values.capa_percent
    if cp ~= nil and cp > 0 and (wgt.values.capa_percent_min == nil or cp < wgt.values.capa_percent_min) then
        wgt.values.capa_percent_min = cp
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
        clear_repeat(wgt, "Cell")          -- a new check starts fresh (drop any old nag)
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
                clear_repeat(wgt, "Cell")   -- pack full: stop any nag
            else
                wgt.batt_warn = true
                -- NOT gated on wgt.power_lost: this one-shot check runs 4 s after voltage
                -- first appears (plug-in), where a power_lost is a transient glitch, not a
                -- real main-supply loss -- and the coarse off-screen (background) cadence is
                -- more likely to sample such a glitch exactly at completion, silencing the
                -- callout. cellv is already validated above (a real, latched last-good value),
                -- so a plausible low cell here means the pack is genuinely low -> announce.
                -- The continuous in-flight voltage alert keeps its power_lost gate.
                if wgt.options.SndCellChk == 1 then
                    -- announce + vibrate + hand off to the repeat engine (CellRep/Cnt/Int/
                    -- Vib). The closure reads fresh values so repeats speak the current
                    -- voltage; per VoltVoice it is total or per-cell (announce_voltage).
                    local function speak()
                        play_audio("batlow")
                        announce_voltage(wgt)
                    end
                    speak()
                    play_vibe(wgt, "Cell")
                    arm_repeat(wgt, "Cell", speak)
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
    wgt.values.headspeed = read_src(wgt, "Hspd")

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
            if s.max == nil or v > s.max then s.max = v end
            -- min only in steady governor states + after the debounce (see the gate) --
            -- a P2 re-spool (RECOVERY) must not leave a 500-rpm "minimum" in P2's stats
            if should_track_governor_min_extrema(wgt) and (s.min == nil or v < s.min) then
                s.min = v
            end
        end
    end
    wgt.values.headspeed_min = s.min
    wgt.values.headspeed_max = s.max
end

function ultidash_functions.update_gov_state(wgt)
    wgt.values.gov_state = read_src(wgt, "Gov")
    if ultidash_functions.simu_mode then wgt.values.gov_state = 4 end   -- Gov. Active (stable)
end

-- ============================================================================
-- ARM STATE UPDATES
-- ============================================================================

function ultidash_functions.update_arm(wgt)
    wgt.values.arm_disable_flags = read_src(wgt, "ARMD")
end

-- Compact "* REASON REASON" arming-disable summary (eStatus style), capped in length.
local function build_arm_disable_text(flags)
    if not flags or flags == 0 then return nil end
    local parts = {}
    local len = 0
    local descs = get_arm_disable_descs()
    for i = 1, #descs do
        if bit32.band(flags, bit32.lshift(1, i - 1)) ~= 0 then
            local desc = descs[i]
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

-- Full (uncapped) list of active arming-disable reason names, space-joined — for the
-- Status detail page (which has room to show them all). nil when nothing blocks arming.
local function build_arm_disable_list(flags)
    if not flags or flags == 0 then return nil end
    local parts = {}
    local descs = get_arm_disable_descs()
    for i = 1, #descs do
        if bit32.band(flags, bit32.lshift(1, i - 1)) ~= 0 then
            parts[#parts + 1] = descs[i]
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "  ")
end

-- ============================================================================
-- SWITCH VOICE ANNOUNCEMENTS
-- ============================================================================
-- Speak configured TX-switch positions (motor/rescue/governor on-off + profile
-- 1..3). READ-ONLY getValue on the switch — fully independent of the model's
-- mixer/logical-switch safety chain (which stays in the model) and of telemetry.
-- The stored value is a SIGNED EdgeTX source index of the WHOLE switch, picked
-- with the native lvgl.source popup (negative = the popup's "!" inverted entry,
-- 0 = Off). getValue on a switch source returns -1024/0/1024 -> position 1/2/3;
-- logical switches read as 2-pos (never mid). Legacy list codes are migrated to
-- source indices once in ultidash.lua (legacy_switch_code_to_src).
local function switch_voice_pos(src)
    if type(src) ~= "number" or src == 0 then return nil end   -- 0 = Off
    local ok, v = pcall(getValue, math.abs(src))
    if not ok or v == nil then return nil end
    local p
    if v > 200 then p = 3 elseif v < -200 then p = 1 else p = 2 end
    if src < 0 then p = 4 - p end                              -- inverted pick
    return p
end

-- Exported "is this picked switch POSITION currently held?" for the switch-shortcut
-- engine. The stored value is a swsrc index from the NATIVE switch picker (lvgl.switch:
-- switch + position in one pick, e.g. "SA-up"; 0 = none) — getSwitchValue resolves it
-- directly to a boolean (inversion/logical switches included). pcall guards a stale
-- cfg index after a radio/firmware change.
function ultidash_functions.swpos_active(sw)
    if type(sw) ~= "number" or sw == 0 then return false end
    local ok, v = pcall(getSwitchValue, sw)
    return ok and v == true
end

local SWITCH_VOICES = {
    { key = "MotorSrc",   on = "motor_on",  off = "motor_off" },
    { key = "RescueSrc",  on = "rescue_on", off = "rescue_off" },
    { key = "GovSrc",     on = "gov_on",    off = "gov_off" },
    { key = "ProfileSrc", profile = true },
}

-- Minimum gap between two announcements of the SAME switch (centiseconds). EdgeTX has
-- no Lua API to flush the audio queue, so rapid flipping used to QUEUE one announcement
-- per stable position and they all played back to back. With the gap, a change inside
-- the window is held (the pend/stability logic keeps tracking) and when the gap expires
-- only the CURRENT stable position speaks — flipped back to the announced position, it
-- says nothing. A single ordinary flip is announced with no added latency.
local SWITCH_VOICE_GAP = 150

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
        elseif p ~= nil and p ~= s.last and (now - s.t) >= 30
            and (s.at == nil or now - s.at >= SWITCH_VOICE_GAP) then
            -- stable for 0.3 s (a 3-pos switch passes through mid on its way) AND the
            -- per-switch announce gap has passed (coalesces rapid flipping, see above)
            local first = (s.last == nil)   -- switch just got configured: baseline silently
            s.last = p
            if first then
                -- baseline only, no announcement (and no gap started)
            elseif f.profile then
                s.at = now
                play_audio("profile")
                play_number(p, 0)
            elseif p == 3 then
                s.at = now
                play_audio(f.on)
            elseif p == 1 then
                s.at = now
                play_audio(f.off)
            end
            -- the mid position of on/off functions stays silent on purpose
        end
    end
end

-- ============================================================================
-- GOVERNOR STATE VOICE ANNOUNCEMENTS
-- ============================================================================
-- Speak the governor state (Gov sensor, codes 0..9) on every stable change while
-- ARMED, gated by the GovVoice master toggle plus a per-state enable (Gvs* keys).
-- READ-ONLY: consumes the cached wgt.values.gov_state (updated by update_gov_state),
-- never issues MSP. Debounced by TIME like the switch voices — the spool-up sequence
-- passes through several codes quickly, so a state must hold ~0.3 s before it speaks.
-- The baseline is (re)synced silently whenever the feature is off or the craft is
-- disarmed, so enabling it or arming never fires on the state that was already there.
local GOV_VOICE_DEBOUNCE = 30   -- centiseconds a state must hold before it's announced
local GOV_VOICE_FILES = {
    [0] = "gs_thoff",   [1] = "gs_idle",    [2] = "gs_spool",
    [3] = "gs_recov",   [4] = "gs_active",  [5] = "gs_hold",
    [6] = "gs_fallbk",  [7] = "gs_autorot", [8] = "gs_bailout",
    [9] = "gs_bypass",
}
local GOV_VOICE_KEYS = {
    [0] = "GvsOff",   [1] = "GvsIdle",    [2] = "GvsSpool",
    [3] = "GvsRecov", [4] = "GvsActive",  [5] = "GvsHold",
    [6] = "GvsFallbk",[7] = "GvsAutorot", [8] = "GvsBailout",
    [9] = "GvsBypass",
}

function ultidash_functions.update_gov_voice(wgt)
    local o = wgt.options
    local g = wgt.values.gov_state
    if g == nil then return end                       -- no reading -> hold state, stay silent
    local st = wgt.gvv
    if st == nil then st = {}; wgt.gvv = st end
    -- feature off or disarmed: keep the baseline current, announce nothing
    if o == nil or o.GovVoice ~= 1 or not is_craft_armed(wgt) then
        st.last = g; st.pend = g; st.t = nil
        return
    end
    local now = getTime() or 0
    if st.last == nil then                            -- first armed pass: baseline silently
        st.last = g; st.pend = g; st.t = now
        return
    end
    if g ~= st.pend then
        st.pend = g; st.t = now                       -- candidate change, start the timer
    elseif g ~= st.last and (now - (st.t or 0)) >= GOV_VOICE_DEBOUNCE then
        st.last = g                                   -- held long enough -> commit + announce
        local key = GOV_VOICE_KEYS[g]
        if key and o[key] == 1 then
            play_audio(GOV_VOICE_FILES[g])
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
        local thr = read_src(wgt, "Thr")
        wgt.values.throttle_text = thr and string.format("%d%%", thr) or "--"
    end
    if ultidash_functions.simu_mode then
        connected, armed = true, true
        wgt.values.throttle_text = string.format("%d%%", math.floor(55 + 15 * sim_wave(18, 0.7)))
    end

    -- ESC signature + status flags
    local sig = read_src(wgt, "Esc#") or 0
    local flags = read_src(wgt, "EscF") or 0
    local changed = flags ~= wgt.esc_last_flags
    wgt.esc_last_flags = flags

    local status_text, status_color
    if connected and sig == esc.SIG_RESTART then
        status_text = "RESTART ESC"
        status_color = sem_red   -- TEXT colour (theme-aware), not a bar fill
        wgt.esc_status_level = esc.LEVEL_ERROR
        estatus_log(wgt, "RESTART ESC", esc.LEVEL_ERROR)
    elseif connected then
        -- memo: get_status allocates a result table + concat strings each call, but the
        -- inputs only move on a flag/signature change. Still called with `changed` exactly
        -- when the flags changed, so the YGE SPN counter (which only counts then) is intact.
        if changed or sig ~= wgt.esc_status_sig or wgt.esc_status_st == nil then
            wgt.esc_status_st = esc.get_status(sig, flags, changed)
            wgt.esc_status_sig = sig
        end
        local st = wgt.esc_status_st
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

    -- arming-disable reason strings memoized on the flags value: the compact status-line
    -- form and the full detail list both scan the same bits -> build both once per change
    -- (this runs the whole bench time while disarmed with flags). apiVersion is constant
    -- within a session, so `flags` alone is a valid cache key even though the name table
    -- is api-dependent.
    local reasons
    if connected and not armed then
        local f = wgt.values.arm_disable_flags
        local c = wgt.arm_txt_cache
        if c == nil or c.flags ~= f then
            c = { flags = f, txt = build_arm_disable_text(f), list = build_arm_disable_list(f) }
            wgt.arm_txt_cache = c
        end
        reasons = c
    end

    -- when disarmed with arming-disable flags, show the reasons instead
    if reasons and reasons.txt then
        status_text = reasons.txt
        status_color = COLOR_THEME_WARNING
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

    -- MAIN POWER LOST overrides everything on the status line (highest priority): the
    -- clearest on-screen signal that the rail is on the buffer now (main voltage reads "--",
    -- BEC becomes the interesting value).
    if wgt.power_lost then
        status_text = "MAIN POWER LOST"
        status_color = sem_red   -- TEXT colour (theme-aware), not a bar fill
    end

    wgt.values.status_line_text = status_text or ""
    wgt.values.status_line_color = status_color or COLOR_THEME_PRIMARY1
    -- full arming-disable reason list for the Status page (cached at 5 Hz; the reactive
    -- page closures just read the string, no per-frame bit-scan / allocation)
    wgt.values.arm_reasons_full = reasons and reasons.list or nil

    -- armed/disarm voice on state change (skip the very first sample)
    if connected then
        if wgt.estatus_armed ~= nil and wgt.estatus_armed ~= armed then
            if wgt.options.SndArm == 1 then
                play_audio(armed and "armed" or "disarm")
                play_vibe(wgt, "Arm")
                if armed then
                    -- optional "still armed" reminder (only if Arm repeat is enabled)
                    arm_repeat(wgt, "Arm", function() play_audio("armed"); play_vibe(wgt, "Arm") end)
                else
                    clear_repeat(wgt, "Arm")
                end
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

    -- ESC-load session limit: the FC SETS the limit GVAR after connect but never clears
    -- it, so UltiDash zeroes it when the session really ends — the DISARMED disconnect
    -- (normal power-off; also fires on the initial disconnected state). An ARMED
    -- disconnect is a telemetry blip/crash: keep latch + GVAR so bar/alarm survive a
    -- mid-flight reconnect even if the FC does not re-send. GVAR-only write (no MSP),
    -- same pattern as the volume override -> armed-safe by design anyway.
    if new_state == "disconnected" and previous_state ~= "armed"
            and wgt.options and wgt.options.EscMon == 1
            and (wgt.options.EscGvar or 0) ~= 0 then
        wgt.escl_limit = nil
        wgt.escl_probe_until = nil
        if type(model) == "table" and type(model.setGlobalVariable) == "function" then
            local okfm, fm = pcall(getFlightMode)
            local mode = (okfm and type(fm) == "number") and fm or 0
            pcall(model.setGlobalVariable, (wgt.options.EscGvar or 1) - 1, mode, 0)
        end
    end
    -- every fresh connect opens a fresh ESC-load probe window (see ESCL_PROBE_CS)
    if previous_state == "disconnected" and new_state ~= "disconnected" then
        wgt.escl_probe_until = nil
    end

    if previous_state == "disconnected" and new_state ~= "disconnected" then
        -- Re-probe the skipped-packet sensor name on every fresh connect —
        -- the sticky *Skp/Skp latch survived a model change between telemetry
        -- generations, silently killing the Skip alert until a Lua reload.
        skp_name = nil
        clear_live_telemetry_values(wgt)
        ultidash_functions.reset_telemetry_stats(wgt)
        -- telemetry recovered: announce only if the loss happened while armed (in flight)
        if telem_snd and wgt.link_lost_armed then
            play_audio("telem_ok")
        end
        wgt.link_lost_armed = false
        clear_repeat(wgt, "Telem")
        return
    end

    -- telemetry lost while ARMED (in flight): urgent voice + vibrate.
    -- losses while disarmed / on the bench stay silent (logged only).
    if new_state == "disconnected" then
        -- Stop the main-power-lost nag on the final cut-off: once telemetry is gone
        -- update_power_warning can no longer clear it itself (Vbat reads nil and its armed
        -- gate stays stale ~30 s), so the Pwr repeat would keep cranking. telem_lost below
        -- then communicates that the system is gone.
        wgt.pwr_pending = 0
        wgt.pwr_announced = false
        clear_repeat(wgt, "Pwr")
        -- the "still armed" reminder ends here too: without telemetry
        -- "armed" is a claim, not an observation — and its clear (the observed
        -- armed->disarmed edge in update_estatus) needs a connection it no longer
        -- has, so after a reconnect-in-disarm the nag would never stop.
        clear_repeat(wgt, "Arm")
        if previous_state == "armed" then
            ultidash_functions.log("Connection lost (armed)")
            if telem_snd then
                play_audio("telem_lost")
                play_vibe(wgt, "Telem")
                wgt.link_lost_armed = true
                arm_repeat(wgt, "Telem", function()
                    play_audio("telem_lost")
                    play_vibe(wgt, "Telem")
                end)
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
    wgt.power_lost = false                 -- leave the main-power-lost mode on disarm/disconnect
    wgt.pwr_lost_latched = false           -- so no "restored" mis-fires after a reconnect
    wgt.callout_last_capa = 100
    wgt.callout_next_capa = 0
    wgt.fuel_critical_on = false          -- true while fuel is in the critical (nag) band
    wgt.volt_pending = 0
    wgt.volt_level = ALERTLEVEL_NONE      -- worst level seen during the current debounce
    wgt.volt_announced = ALERTLEVEL_NONE  -- highest level already spoken this episode
    clear_repeat(wgt, "Fuel")
    clear_repeat(wgt, "Volt")
end

-- ePowerbar crankFuelCalls (view A): the descending %-step callouts stay VALUE-driven
-- (announced when the rounded % changes). The step DENSITY is configurable: silent above
-- FuelStart, FuelStep in the coarse range, a finer FuelStepFine below the FuelDense
-- breakpoint (defaults = the historical from-full / 10 % / 1 %-below-10 % cadence). The
-- battry/batlow WORDING stays tied to the real low band (critical + FUEL_VLOW), independent
-- of the density breakpoint. The CRITICAL/empty band is the "nag": announced once on entry,
-- then repeated by the per-alert repeat engine (FuelRep / FuelCnt / FuelInt).
local function crank_fuel_calls(wgt)
    -- bail if fuel callouts are switched off
    if wgt.options.SndFuel ~= 1 then
        wgt.fuel_critical_on = false
        clear_repeat(wgt, "Fuel")
        return
    end
    -- MAIN POWER LOST: the pack is gone (RF then reports the buffer's capacity as fuel %,
    -- which is meaningless). Suppress all fuel callouts + their nag — only main-power-lost
    -- and BEC speak in that state.
    if wgt.power_lost then
        wgt.fuel_critical_on = false
        clear_repeat(wgt, "Fuel")
        return
    end

    local fuel = wgt.values.fuel
    if fuel == nil then return end

    local critical = fuel_critical(wgt)
    local interval = math.max(1, wgt.options.FuelInt or 6) * 100
    local now = getTime()

    if fuel > critical then
        -- ABOVE critical: value-driven step callouts, no repeat engine
        wgt.fuel_critical_on = false
        clear_repeat(wgt, "Fuel")
        -- fallbacks = the real defaults 15/5: they are never active in
        -- practice (set_defaults seeds every key), but a contradicting number here
        -- would silently change the cadence if that ever broke
        local dense = wgt.options.FuelDense or 15
        local step = (fuel <= dense) and math.max(1, wgt.options.FuelStepFine or 5)
                                      or  math.max(1, wgt.options.FuelStep or 10)
        local capa = math.ceil(fuel / step) * step
        if capa > 100 then capa = 100 end
        if wgt.callout_last_capa ~= capa and now > wgt.callout_next_capa then
            -- announce only at/below the start threshold, and skip the very first pass
            -- after arming (callout_next_capa == 0)
            if wgt.callout_next_capa ~= 0 and fuel <= (wgt.options.FuelStart or 100) then
                if fuel > critical + FUEL_VLOW then play_audio("battry") else play_audio("batlow") end
                play_fuel_value(wgt, capa)
            end
            wgt.callout_last_capa = capa
            wgt.callout_next_capa = now + interval
        end
    else
        -- AT/BELOW critical: announce once on entry, then let the repeat engine nag
        local function speak()
            play_audio("batcrt")
            play_vibe(wgt, "Fuel")
            local c = wgt.values.fuel
            if c and c >= 0 then play_number(c, UNIT_PERCENT) end
        end
        if not wgt.fuel_critical_on then
            if wgt.callout_next_capa ~= 0 then       -- not the very first sample after arming
                wgt.fuel_critical_on = true
                speak()
                arm_repeat(wgt, "Fuel", speak)
            end
            wgt.callout_last_capa = fuel
            wgt.callout_next_capa = now + interval
        end
    end
end

-- crankVoltageAlerts (view A): low/critical per-cell voltage. Each level is announced
-- ONCE on crossing (value-driven, with a short debounce so a brief sag doesn't trigger).
-- With Repeat on, the per-alert repeat engine (VoltRep / VoltCnt / VoltInt) then
-- re-announces the CURRENT level (low OR critical) while the condition holds — so a
-- sustained dip in the low band (e.g. through a loop) keeps calling out too, not just
-- critical. Repeat off = the single crossing announce only. Escalation volume stays tied
-- to the critical level (the low band does not boost).
local function crank_voltage_alerts(wgt)
    -- bail if voltage alerts are switched off
    if wgt.options.SndVolt ~= 1 then
        wgt.volt_pending = 0; wgt.volt_level = ALERTLEVEL_NONE; wgt.volt_announced = ALERTLEVEL_NONE
        clear_repeat(wgt, "Volt")
        return
    end
    -- MAIN POWER LOST: the frozen last-good voltage is not a real "critical cell" — suppress
    -- the voltage callouts + nag; only main-power-lost and BEC speak in that state.
    if wgt.power_lost then
        wgt.volt_pending = 0; wgt.volt_level = ALERTLEVEL_NONE; wgt.volt_announced = ALERTLEVEL_NONE
        clear_repeat(wgt, "Volt")
        return
    end

    local cellv = wgt.values.vcel
    -- ignore implausible (<1V) readings -> a collapsed/lost supply is no real "critical"
    if cellv == nil or cellv <= MIN_PLAUSIBLE_CELL_V then return end

    local now = getTime()
    -- thresholds come from the Rotorflight FC (mspBatteryConfig), in centivolts
    local cv = math.floor(cellv * 100)
    local alarm = math.floor(wgt.values.vcel_alarm_threshold() * 100)
    local low = math.floor(wgt.values.vcel_warning_threshold() * 100)
    local level = (cv <= alarm and ALERTLEVEL_CRITICAL) or (cv <= low and ALERTLEVEL_LOW) or ALERTLEVEL_NONE

    -- recovered above the warn threshold: re-arm for the next drop, stop any nag
    if level == ALERTLEVEL_NONE then
        wgt.volt_pending = 0; wgt.volt_level = ALERTLEVEL_NONE; wgt.volt_announced = ALERTLEVEL_NONE
        clear_repeat(wgt, "Volt")
        return
    end

    -- not worse than what was already announced: stay silent, but KEEP the nag running
    -- (it now re-announces the low band too). Track the current level so an in-band
    -- improvement (critical -> low) makes the running closure speak "batlow" instead of a
    -- stale "batcrt", and lower the latch so a renewed worsening re-announces.
    if level <= (wgt.volt_announced or ALERTLEVEL_NONE) then
        wgt.volt_pending = 0
        wgt.volt_level = level
        wgt.volt_announced = level
        return
    end

    -- new or escalated level: debounce (must hold), then announce once
    if (wgt.volt_pending or 0) == 0 then
        wgt.volt_level = level
        wgt.volt_pending = now + ALERT_SAMPLE_CS
        return
    end
    if level > wgt.volt_level then wgt.volt_level = level end

    if now >= wgt.volt_pending then
        local function speak()
            if wgt.volt_level >= ALERTLEVEL_CRITICAL then
                play_audio("batcrt")
                play_vibe(wgt, "Volt")
            else
                play_audio("batlow")
            end
            -- announce the voltage per VoltVoice (total or per-cell); reads fresh latched
            -- values so repeats speak the current value.
            announce_voltage(wgt)
        end
        speak()
        wgt.volt_announced = wgt.volt_level
        wgt.volt_pending = 0
        -- keep nagging the CURRENT level (low or critical) while it holds; the repeat only
        -- actually arms when VoltRep is on (else arm_repeat is a no-op).
        arm_repeat(wgt, "Volt", speak)
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
        clear_repeat(wgt, "Link")
        return
    end
    -- only while armed (in flight); no link callouts on the bench / disarmed
    if not is_craft_armed(wgt) then
        wgt.link_pending = 0
        wgt.link_level = 0
        wgt.link_announced = 0
        clear_repeat(wgt, "Link")
        return
    end

    local rqly = read_src(wgt, "RQly")
    if ultidash_functions.simu_mode then rqly = 99 end
    if rqly == nil then return end

    local now = getTime()
    local warn = wgt.options.RQlyWarn or 80
    local crit = wgt.options.RQlyCrit or 50
    local level = (rqly <= crit and 2) or (rqly <= warn and 1) or 0

    -- recovered above the warn threshold: re-arm so the next drop announces again
    if level == 0 then
        wgt.link_pending = 0
        wgt.link_level = 0
        wgt.link_announced = 0
        clear_repeat(wgt, "Link")
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
        local function speak()
            if wgt.link_level >= 2 then
                play_audio("link_crit")
                play_vibe(wgt, "Link")
            else
                play_audio("link_warn")
            end
            -- announce the actual (current) link quality value
            local q = read_src(wgt, "RQly")
            if q then play_number(q, UNIT_PERCENT) end
        end
        speak()
        wgt.link_announced = wgt.link_level
        wgt.link_pending = 0
        arm_repeat(wgt, "Link", speak)   -- repeat only if LinkRep is on (else a no-op)
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
        clear_repeat(wgt, "Rssi")
        return
    end
    if not is_craft_armed(wgt) then
        wgt.rssi_pending = 0
        wgt.rssi_level = 0
        wgt.rssi_announced = 0
        clear_repeat(wgt, "Rssi")
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
    local warn = wgt.options.RssWarn or 15
    local crit = wgt.options.RssCrit or 8
    local level = (p <= crit and 2) or (p <= warn and 1) or 0

    if level == 0 then
        wgt.rssi_pending = 0
        wgt.rssi_level = 0
        wgt.rssi_announced = 0
        clear_repeat(wgt, "Rssi")
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
        local function speak()
            if wgt.rssi_level >= 2 then
                play_audio("rssi_crit")
                play_vibe(wgt, "Rssi")
            else
                play_audio("rssi_warn")
            end
            -- announce the current signal headroom % (the better antenna on diversity);
            -- built fresh from the caches so repeats speak the current value (rule 4).
            local pv = wgt.values.elrs_r1_pct
            if wgt.values.elrs_diversity and wgt.values.elrs_r2_pct then
                pv = math.max(pv or 0, wgt.values.elrs_r2_pct)
            end
            if pv then play_number(pv, UNIT_PERCENT) end
        end
        speak()
        wgt.rssi_announced = wgt.rssi_level
        wgt.rssi_pending = 0
        arm_repeat(wgt, "Rssi", speak)   -- repeat only if RssiRep is on (else a no-op)
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
        clear_repeat(wgt, "Pwr")
        return
    end
    if not is_craft_armed(wgt) then
        wgt.pwr_pending = 0
        wgt.pwr_announced = false
        clear_repeat(wgt, "Pwr")
        return
    end

    -- MAIN POWER RESTORED: announce once when we leave the power-lost state while STILL
    -- armed & connected (the main pack came back without a full disconnect/reconnect — the
    -- buffer bridged the gap). The pwr_lost_latched flag is armed while power_lost holds and
    -- cleared on disarm/disconnect (reset_callout_state / clear_live_telemetry_values), so a
    -- reconnect after a total loss never mis-fires "restored".
    if wgt.pwr_lost_latched and not wgt.power_lost then
        wgt.pwr_lost_latched = false
        if is_rf_connected(wgt) then
            play_audio("pwr_ok")
            play_vibe(wgt, "Pwr")
        end
    end
    if wgt.power_lost then wgt.pwr_lost_latched = true end

    local vbat = read_src(wgt, "Vbat")
    if vbat == nil then return end

    local thresh = pwr_warn_threshold(wgt)   -- cell-count-relative by default
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
            -- "main power lost" + the current BEC/buffer voltage (live now that Vbec is not
            -- latched) — so a repeated Pwr alert audibly counts the buffer down. Config
            -- (repeat/count/interval/escalation/vibrate) is the per-alert "Main power lost".
            local function speak()
                play_audio("pwr_backup")
                play_vibe(wgt, "Pwr")
                local bec = wgt.values.vbec
                if bec then play_number(bec * 10, UNIT_VOLTS, PREC1) end
            end
            speak()
            wgt.pwr_announced = true
            wgt.pwr_pending = 0
            arm_repeat(wgt, "Pwr", speak)   -- repeat only if PwrRep is on (else a no-op)
        end
    else
        wgt.pwr_pending = 0
        wgt.pwr_announced = false
        clear_repeat(wgt, "Pwr")
    end
end

-- BEC-voltage warning (relative, self-calibrating): the reference is the BEC voltage
-- AT THE ARM MOMENT (first plausible reading while operating, FROZEN until disarm/
-- disconnect), so it adapts to any 5 V / 6 V / 8.4 V BEC. It warns when
-- the live BEC drops BecWarn % below that reference, critical at BecCrit %. Announced
-- once per level (warn->crit announces again); the per-alert repeat engine handles
-- repeats. Sensor-derived (Vbec, live/un-latched), no MSP -> armed-safe.
function ultidash_functions.update_bec_warning(wgt)
    if not wgt.options or wgt.options.SndBec ~= 1 or not is_operating(wgt) then
        wgt.bec_ref = nil; wgt.bec_pending = 0; wgt.bec_level = 0; wgt.bec_announced = 0
        clear_repeat(wgt, "Bec")
        return
    end
    local bec = wgt.values.vbec
    if bec == nil or bec <= MIN_PLAUSIBLE_CELL_V then return end
    -- FREEZE the reference at the arm edge (first plausible reading while
    -- operating). The old running max-since-arm slowly ratcheted the reference up on
    -- noise spikes, tightening the %-drop alarm mid-flight. Reset via the branch above.
    if wgt.bec_ref == nil then wgt.bec_ref = bec end
    local ref = wgt.bec_ref
    if ref == nil or ref <= 0 then return end

    local drop = (ref - bec) / ref * 100
    local warn = wgt.options.BecWarn or 8
    local crit = wgt.options.BecCrit or 15
    local level = (drop >= crit and 2) or (drop >= warn and 1) or 0

    if level == 0 then
        wgt.bec_pending = 0; wgt.bec_level = 0; wgt.bec_announced = 0
        clear_repeat(wgt, "Bec")
        return
    end
    -- already announced this severity (or worse): stay silent (repeats via the engine)
    if level <= (wgt.bec_announced or 0) then
        wgt.bec_pending = 0
        return
    end
    local now = getTime()
    -- new or escalated level: debounce (must hold), then announce once
    if (wgt.bec_pending or 0) == 0 then
        wgt.bec_level = level
        wgt.bec_pending = now + ALERT_SAMPLE_CS
        return
    end
    if level > wgt.bec_level then wgt.bec_level = level end
    if now >= wgt.bec_pending then
        local function speak()
            if wgt.bec_level >= 2 then
                play_audio("bec_crit")
                play_vibe(wgt, "Bec")
            else
                play_audio("bec_low")
            end
            local b = wgt.values.vbec
            if b then play_number(b * 10, UNIT_VOLTS, PREC1) end
        end
        speak()
        wgt.bec_announced = wgt.bec_level
        wgt.bec_pending = 0
        arm_repeat(wgt, "Bec", speak)   -- repeat only if BecRep is on (else a no-op)
    end
end

-- Announce the WORST currently-alerting temperature sensor (used by the shared "Temp"
-- repeat, so a nag speaks the current worst, re-read fresh). ESC wins ties.
local function temp_worst_speak(wgt)
    local o = wgt.options or {}
    local et, mt = read_src(wgt, "Tesc"), read_src(wgt, "Tmcu")
    local ew, ec = o.TescWarn or 0, o.TescCrit or 0
    local mw, mc = o.TmcuWarn or 0, o.TmcuCrit or 0
    local elev = (et and et > 0) and ((ec > 0 and et >= ec and 2) or (ew > 0 and et >= ew and 1) or 0) or 0
    local mlev = (mt and mt > 0) and ((mc > 0 and mt >= mc and 2) or (mw > 0 and mt >= mw and 1) or 0) or 0
    if elev >= mlev and elev > 0 then
        play_audio(elev >= 2 and "esct_crit" or "esct_warn"); play_vibe(wgt, "Temp")
        play_number(math.floor(et + 0.5), UNIT_CELSIUS)
    elseif mlev > 0 then
        play_audio(mlev >= 2 and "mcut_crit" or "mcut_warn"); play_vibe(wgt, "Temp")
        play_number(math.floor(mt + 0.5), UNIT_CELSIUS)
    end
end

-- One temperature sensor: bec-style debounce + announce-once-per-new-level. Separate latches
-- per sensor (prefix tesc_/tmcu_) so an MCU warn never masks an ESC crit. warn/crit = 0 turns
-- that sensor's branch off; a nil or <= 0 reading is "no input" (the ESC reads 0 before it
-- warms up) and keeps the last latched level. Returns (level, just_announced_this_pass).
local function temp_one(wgt, sensor, prefix, warn, crit, wav_warn, wav_crit)
    local pend, lvl, ann = prefix .. "_pending", prefix .. "_level", prefix .. "_announced"
    if warn <= 0 and crit <= 0 then wgt[pend] = 0; wgt[lvl] = 0; wgt[ann] = 0; return 0, false end
    local t = read_src(wgt, sensor)
    if t == nil or t <= 0 then return (wgt[ann] or 0), false end   -- no fresh input -> hold latch
    local level = (crit > 0 and t >= crit and 2) or (warn > 0 and t >= warn and 1) or 0
    if level == 0 then wgt[pend] = 0; wgt[lvl] = 0; wgt[ann] = 0; return 0, false end
    if level <= (wgt[ann] or 0) then wgt[pend] = 0; return level, false end
    local now = getTime()
    if (wgt[pend] or 0) == 0 then wgt[lvl] = level; wgt[pend] = now + ALERT_SAMPLE_CS; return (wgt[ann] or 0), false end
    if level > wgt[lvl] then wgt[lvl] = level end
    if now >= wgt[pend] then
        play_audio(wgt[lvl] >= 2 and wav_crit or wav_warn)
        play_vibe(wgt, "Temp")
        play_number(math.floor(t + 0.5), UNIT_CELSIUS)
        wgt[ann] = wgt[lvl]; wgt[pend] = 0
        return wgt[lvl], true
    end
    return wgt[lvl], false
end

-- ESC/MCU over-temperature alert (armed-only). Two independent sensors, one shared repeat
-- that re-announces the worst. Live sensors: Tesc (0x10A0) and Tmcu (0x10A3 -- the LIVE MCU
-- temp, NOT the Tmcu+ session-max the panel/stats use). Silent with no sensor/thresholds.
function ultidash_functions.update_temp_warning(wgt)
    local o = wgt.options
    if not o or o.SndTemp ~= 1 or not is_operating(wgt) then
        wgt.tesc_pending = 0; wgt.tesc_level = 0; wgt.tesc_announced = 0
        wgt.tmcu_pending = 0; wgt.tmcu_level = 0; wgt.tmcu_announced = 0
        clear_repeat(wgt, "Temp")
        return
    end
    local el, e_new = temp_one(wgt, "Tesc", "tesc", o.TescWarn or 0, o.TescCrit or 0, "esct_warn", "esct_crit")
    local ml, m_new = temp_one(wgt, "Tmcu", "tmcu", o.TmcuWarn or 0, o.TmcuCrit or 0, "mcut_warn", "mcut_crit")
    if e_new or m_new then
        -- (re)arm ONLY on a fresh announce (like the other alerts) so the repeat counter is
        -- not reset every pass; the closure re-announces the worst sensor each interval.
        arm_repeat(wgt, "Temp", function() temp_worst_speak(wgt) end)
    elseif el == 0 and ml == 0 then
        clear_repeat(wgt, "Temp")
    end
end

-- How long after connect the ESC-load monitor keeps polling the limit GVAR before
-- giving up (centiseconds). The FC needs a moment to write the value; if nothing > 0
-- arrived within this window, the feature counts as NOT SET UP on this model for the
-- rest of the session (toggling the alert off/on or reconnecting opens a new window).
local ESCL_PROBE_CS = 1000   -- 10 s

-- ESC continuous-current LOAD monitor: a configurable GVAR (set by the FC) holds the
-- ESC's continuous-current limit in AMPS; load% = Curr / limit * 100. One clear MASTER
-- runs the whole feature: EscMon ("ESC load monitoring") + a configured limit GVAR
-- (EscGvar). Off (or no GVAR) => nothing at all: no bar, no "ESC Load" tile value
-- ("not set"), no colour evaluation, no alarm — and no GVAR probe/zero. When on, the
-- display (bar + tile) always shows; the ALARM (warn at EscWarn %, critical at
-- EscCrit %, level-latched + repeat engine) is an additional opt-in (the "ESC load"
-- alert's Active = EscLoad) that fires only while ARMED — and, being gated by EscMon,
-- goes silent the moment monitoring is switched off. GVAR read is local
-- (getGlobalVariable) -> no MSP -> armed-safe.
function ultidash_functions.update_esc_load_warning(wgt)
    local o = wgt.options
    -- master: monitoring ON and a limit GVAR configured. Off => whole feature off, and
    -- we never probe or zero the GVAR, so a legacy cfg's stale EscGvar can't clobber an
    -- unrelated GVAR.
    if not o or o.EscMon ~= 1 or (o.EscGvar or 0) == 0 then
        wgt.values.esc_load_pct = nil; wgt.values.esc_load_limit = nil
        wgt.escl_limit = nil
        wgt.escl_probe_until = nil
        wgt.escl_warn_since = nil; wgt.escl_crit_since = nil
        wgt.escl_level = 0; wgt.escl_announced = 0
        clear_repeat(wgt, "EscL")
        return
    end

    -- limit (amps): latched ONCE per session from the configured GVAR. The FC writes
    -- the ESC's continuous-current limit there after connect; UltiDash polls only until
    -- the first value > 0 arrives (latched for the whole session, no further GVAR
    -- reads) — but at most for ESCL_PROBE_CS after connect. Still 0 when the window
    -- closes = the feature is not set up on THIS model -> bar hidden, no alarm, no
    -- more polling. Latch + GVAR are reset on the disarmed disconnect in
    -- on_telemetry_state_changed (the FC never zeroes the GVAR itself).
    if wgt.escl_limit == nil and is_rf_connected(wgt) then
        local now = getTime()
        if wgt.escl_probe_until == nil then wgt.escl_probe_until = now + ESCL_PROBE_CS end
        if now < wgt.escl_probe_until
                and type(model) == "table" and type(model.getGlobalVariable) == "function" then
            local okfm, fm = pcall(getFlightMode)
            local mode = (okfm and type(fm) == "number") and fm or 0
            local okgv, gv = pcall(model.getGlobalVariable, (o.EscGvar or 1) - 1, mode)
            if okgv and type(gv) == "number" and gv > 0 then wgt.escl_limit = gv end
        end
    end
    wgt.values.esc_load_limit = wgt.escl_limit

    local curr = wgt.values.curr
    if wgt.escl_limit == nil or curr == nil then
        wgt.values.esc_load_pct = nil
    else
        wgt.values.esc_load_pct = math.floor(curr / wgt.escl_limit * 100 + 0.5)
    end

    -- alarm: additional opt-in (the "ESC load" alert's Active = EscLoad), armed only.
    -- Gated by EscMon above, so turning monitoring off also silences the alarm.
    if o.EscLoad ~= 1 or not is_craft_armed(wgt) then
        wgt.escl_warn_since = nil; wgt.escl_crit_since = nil
        wgt.escl_level = 0; wgt.escl_announced = 0
        clear_repeat(wgt, "EscL")
        return
    end
    local pct = wgt.values.esc_load_pct
    if pct == nil then return end
    local warn = o.EscWarn or 80
    local crit = o.EscCrit or 100
    local now = getTime()

    -- Sustained-load gating (EscHold, seconds): ESCs tolerate SHORT bursts above the
    -- continuous limit, so a level alarms only after the load stayed at/above its
    -- threshold for the WHOLE hold time. Each threshold runs its own clock — a dip
    -- below crit resets only the crit clock, the warn clock keeps running while the
    -- load is still >= warn (unlike the other alerts' max-level sample window, which
    -- would announce a momentary crit spike as critical).
    if pct >= warn then
        if wgt.escl_warn_since == nil then wgt.escl_warn_since = now end
    else
        wgt.escl_warn_since = nil
    end
    if pct >= crit then
        if wgt.escl_crit_since == nil then wgt.escl_crit_since = now end
    else
        wgt.escl_crit_since = nil
    end

    if pct < warn then
        -- fully recovered: re-arm the announcements for the next sustained excursion
        wgt.escl_level = 0; wgt.escl_announced = 0
        clear_repeat(wgt, "EscL")
        return
    end

    local hold_cs = (o.EscHold or 5) * 100
    local level = 0
    if wgt.escl_crit_since ~= nil and (now - wgt.escl_crit_since) >= hold_cs then
        level = 2
    elseif wgt.escl_warn_since ~= nil and (now - wgt.escl_warn_since) >= hold_cs then
        level = 1
    end
    if level == 0 or level <= (wgt.escl_announced or 0) then return end

    wgt.escl_level = level
    local function speak()
        if (wgt.escl_level or 0) >= 2 then
            play_audio("escl_crit"); play_vibe(wgt, "EscL")
        else
            play_audio("escl_warn")
        end
        local p = wgt.values.esc_load_pct
        if p then play_number(p, UNIT_PERCENT) end
    end
    speak()
    wgt.escl_announced = level
    arm_repeat(wgt, "EscL", speak)   -- repeat only if EscLRep is on (else a no-op)
end

-- Skipped-telemetry-packet warning: while ARMED, if the cumulative *Skp counter
-- reaches the configurable limit, speak `skp_high` once. The counter only climbs
-- and is reset on telemetry (re)connect, so it announces once per flight; re-arms
-- when it drops below the limit again (i.e. after a reset). Sensor read only (no
-- MSP) -> armed-safe. Separate on/off via the SkpWarn option.
function ultidash_functions.update_skp_warning(wgt)
    if not wgt.options or wgt.options.SkpWarn ~= 1 then
        wgt.skp_announced = false
        clear_repeat(wgt, "Skp")
        return
    end
    if not is_craft_armed(wgt) then
        wgt.skp_announced = false
        clear_repeat(wgt, "Skp")
        return
    end

    local skp = read_skp(wgt)
    if skp == nil then return end

    local limit = wgt.options.SkpLimit or 50
    if skp >= limit then
        if not wgt.skp_announced then
            -- vibe like every other alert: the SkpVib toggle was offered
            -- in the menu but speak() was the only alert without a play_vibe
            local function speak() play_audio("skp_high"); play_vibe(wgt, "Skp") end
            speak()
            wgt.skp_announced = true
            arm_repeat(wgt, "Skp", speak)   -- repeat only if SkpRep is on (else a no-op)
        end
    else
        wgt.skp_announced = false
        clear_repeat(wgt, "Skp")
    end
end

-- ============================================================================
-- ESCALATION VOLUME
-- ============================================================================
-- Alerts whose "escalation volume" boost is driven by a SUSTAINED critical/active
-- state. One-shot informational alerts (Cell check, Armed/disarm) don't sustain a
-- state, so they don't drive the boost.
local ESC_CODES = { "Volt", "Fuel", "Telem", "Link", "Rssi", "Pwr", "Bec", "EscL", "Skp", "Temp" }

-- Is this alert currently in its escalation-worthy state? Reads cached values / the
-- alert latches only (no extra sensor lookups), so it's cheap to call every pass.
local function alert_active(wgt, code)
    -- telemetry-lost is judged from its own latch (the ARM sensor is gone when the
    -- link drops, so is_craft_armed can't be trusted here). Coupled to the RUNNING
    -- repeat: the latch itself only clears on reconnect, but the boost
    -- must end with the nag — crank_repeats drops rep.Telem once TelemCnt is
    -- reached, so after a crash/power-off the pot gets the volume back by itself
    -- (TelemCnt=0 = nag until reconnect, boost holds with it; TelemRep off = no
    -- repeats = no boost, the first callout always predates the GVAR write anyway).
    if code == "Telem" then
        return wgt.link_lost_armed == true and wgt.rep ~= nil and wgt.rep.Telem ~= nil
    end
    if not is_craft_armed(wgt) then return false end
    if code == "Volt" then return (wgt.volt_announced or 0) >= ALERTLEVEL_CRITICAL
    elseif code == "Fuel" then return wgt.fuel_critical_on == true
    elseif code == "Link" then return (wgt.link_announced or 0) >= 2
    elseif code == "Rssi" then return (wgt.rssi_announced or 0) >= 2
    elseif code == "Pwr"  then return wgt.pwr_announced == true
    elseif code == "Bec"  then return (wgt.bec_announced or 0) >= 2
    elseif code == "EscL" then return (wgt.escl_announced or 0) >= 2
    elseif code == "Skp"  then return wgt.skp_announced == true
    elseif code == "Temp" then return (wgt.tesc_announced or 0) >= 2 or (wgt.tmcu_announced or 0) >= 2
    end
    return false
end

-- Set each 5 Hz pass: true while any alert with "Escalation volume" enabled is active.
-- Drives the escalation branch in refresh_volume_override and the Status readout.
function ultidash_functions.update_escalation(wgt)
    local o = wgt.options
    local esc = false
    if o then
        for i = 1, #ESC_CODES do
            local c = ESC_CODES[i]
            if o[c .. "Esc"] == 1 and alert_active(wgt, c) then esc = true; break end
        end
    end
    wgt.escalate_active = esc
end

function ultidash_functions.reset_telemetry_stats(wgt)
    -- Only auto-reset the model timer for models that actually SHOW it in the widget
    -- (TopLeft = Timer). Otherwise the configured model timer is the pilot's own -- don't
    -- silently zero it on every fresh connect.
    if wgt.options.TopLeft == 2 then model.resetTimer(wgt.options.Timer or 0) end
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
    ultidash_functions.update_gov_voice(wgt)   -- announce gov-state changes while armed
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

-- ============================================================================
-- FULLSCREEN ALERT OVERLAY
-- ============================================================================
-- An inset warning box over the flight/stats view for the critical alerts whose
-- per-alert "Fullscreen overlay" toggle is on (PwrOvl / VoltOvl / TelemOvl, default
-- off). The layer is PREBUILT into the view builders (add_alert_overlay below) and
-- toggled purely via reactive `visible` closures -- showing/hiding never rebuilds
-- (rule: no lvgl.box, build-table primitives only, same pattern as the warn banners).
local OVL_TITLES = { Pwr = "MAIN POWER LOST", Volt = "BATTERY CRITICAL", Telem = "TELEMETRY LOST" }

-- Episode state machine, run in the publisher's 5 Hz foreground pass (display-only,
-- so no background variant). Highest-priority active condition wins (Pwr > Volt >
-- Telem -- matching the callout suppression order). A tap (host tap chain) or the
-- shared auto-close (OvlClose s, 0 = off) dismisses THIS episode; the overlay
-- reopens only after the condition cleared and fired again.
-- State table (code = highest active condition this pass):
--   code nil                      -> full reset (active/dismissed/since nil)
--   code ~= dismissed(non-nil)    -> the dismissed condition is no longer the
--                                    active one (cleared or overtaken by priority):
--                                    forget the dismiss — a LATER re-entry of that
--                                    code is a NEW episode and must show
--   code == dismissed             -> stay hidden (same episode)
--   code ~= active                -> new episode: show, stamp ovl_since
--   auto-close elapsed            -> dismissed = code, hide
function ultidash_functions.update_alert_overlay(wgt)
    local o = wgt.options
    if o == nil then return end
    local code
    if o.PwrOvl == 1 and o.PwrWarn == 1 and wgt.power_lost then
        code = "Pwr"
    elseif o.VoltOvl == 1 and o.SndVolt == 1
        and (wgt.volt_announced or ALERTLEVEL_NONE) >= ALERTLEVEL_CRITICAL then
        code = "Volt"
    elseif o.TelemOvl == 1 and o.SndTelem == 1 and wgt.link_lost_armed then
        code = "Telem"
    end
    if code == nil then                       -- nothing active: reset the episode
        wgt.ovl_active, wgt.ovl_dismissed, wgt.ovl_since = nil, nil, nil
        return
    end
    if wgt.ovl_dismissed ~= nil and wgt.ovl_dismissed ~= code then
        wgt.ovl_dismissed = nil               -- code changed: dismissed episode is over
    end
    if wgt.ovl_dismissed == code then         -- tapped/auto-closed away this episode
        wgt.ovl_active = nil
        return
    end
    local now = getTime() or 0
    if wgt.ovl_active ~= code then
        wgt.ovl_active = code
        wgt.ovl_since = now
    end
    local ac = o.OvlClose or 0
    if ac > 0 and (now - (wgt.ovl_since or now)) >= ac * 100 then
        wgt.ovl_dismissed = code
        wgt.ovl_active = nil
    end
end

-- Build the (hidden) overlay layer onto a view panel: inset box ~80% of the zone,
-- warn-red fill, white border, big title + live value + dismiss hint. Called LAST by
-- build_flight_ui/build_stats_ui so it stacks on top. All elements share one reactive
-- `visible`; texts are memoized per value change (per-frame closures, memoized).
function ultidash_functions.add_alert_overlay(panel, wgt, w, h)
    local bw, bh = math.floor(w * 0.8), math.floor(h * 0.8)
    local bx, by = math.floor((w - bw) / 2), math.floor((h - bh) / 2)
    local vis = function() return wgt.ovl_active ~= nil end
    -- title font: the largest that fits the longest title in the box width
    local title_font, tfh = SMLSIZE, select(2, lcd.sizeText("Ag", SMLSIZE))
    for _, f in ipairs({ DBLSIZE, MIDSIZE, 0, SMLSIZE }) do
        if lcd.sizeText("MAIN POWER LOST", f) <= bw - 16 then
            title_font = f
            tfh = select(2, lcd.sizeText("Ag", f))
            break
        end
    end
    local _, vfh = lcd.sizeText("Ag", MIDSIZE)
    local _, sfh = lcd.sizeText("Ag", SMLSIZE)
    local white = lcd.RGB(255, 255, 255)
    local ty = by + math.floor(bh * 0.22)
    local title = function()
        local c = wgt.ovl_active
        return c and OVL_TITLES[c] or ""
    end
    local value = function()
        -- live value line: Pwr = the buffer/BEC voltage, Volt = the cell voltage;
        -- memoized so the format runs only when the reading changes
        local code = wgt.ovl_active
        local raw
        if code == "Pwr" then raw = wgt.values.vbec
        elseif code == "Volt" then raw = wgt.values.vcel end
        local c = wgt.ovl_vcache
        if c ~= nil and c.code == code and c.raw == raw then return c.s end
        local s = ""
        if code == "Pwr" and raw ~= nil then s = string.format("Buffer  %.1f V", raw)
        elseif code == "Volt" and raw ~= nil then s = string.format("%.2f V/cell", raw) end
        if c ~= nil then c.code = code; c.raw = raw; c.s = s
        else wgt.ovl_vcache = { code = code, raw = raw, s = s } end
        return s
    end
    panel:build({
        { type = "rectangle", x = bx, y = by, w = bw, h = bh, filled = true, rounded = 8,
          color = lcd.RGB(190, 16, 16), visible = vis },
        { type = "rectangle", x = bx, y = by, w = bw, h = bh, thickness = 3, rounded = 8,
          color = white, visible = vis },
        { type = "label", x = bx + 8, y = ty, w = bw - 16, h = tfh, font = title_font,
          align = CENTER, color = white, text = title, visible = vis },
        { type = "label", x = bx + 8, y = ty + tfh + math.floor(bh * 0.08), w = bw - 16, h = vfh,
          font = MIDSIZE, align = CENTER, color = white, text = value, visible = vis },
        { type = "label", x = bx + 8, y = by + bh - sfh - 6, w = bw - 16, h = sfh,
          font = SMLSIZE, align = CENTER, color = white, text = "tap to dismiss", visible = vis },
    })
end

-- Background refresh: runs the same alert cascade as the foreground pass, but off
-- screen (another view is active). It MUST refresh every sensor value the alerts
-- consume first — otherwise EscL/BEC/RSSI would run on frozen values latched by the
-- last on-screen pass. Also keeps flight-time tracking running when UltiDash is NOT
-- the active screen, so the stats-page "Flight Time" reflects the whole flight, not
-- just the time the widget was on screen.
function ultidash_functions.background_refresh(wgt)
    master_muted = wgt.options and wgt.options.Mute == 2   -- CHOICE: 1=None, 2=All
    refresh_audio_volume(wgt)
    ultidash_functions.update_switch_voices(wgt)
    maybe_reset_stats(wgt)

    -- Sensor updates FIRST (the alert cascade below reads these caches; without them
    -- EscL/BEC/RSSI ran off-screen on frozen values). Read unconditionally (not gated
    -- by RFTool state) so headspeed-based flight-time tracking works even if the
    -- connection state isn't feeding through. NOTE: getSourceValue does NOT
    -- go nil the moment telemetry stops — EdgeTX serves the last value until the
    -- sensor expires (~30 s), so tracking runs on frozen values until then.
    ultidash_functions.update_elrs(wgt)        -- elrs_r1/r2_pct, diversity, skp_raw
    ultidash_functions.update_gov_state(wgt)   -- before curr/headspeed extrema trackers
    ultidash_functions.update_gov_voice(wgt)   -- announce gov-state changes while armed (off-screen too)
    ultidash_functions.update_curr(wgt)        -- ESC-load basis
    ultidash_functions.update_cell(wgt)        -- vbat latch (startup cell-check basis)
    ultidash_functions.update_vcel(wgt)        -- vcel latch (startup cell-check basis)
    ultidash_functions.update_vbec(wgt)        -- BEC warning + power callout
    ultidash_functions.update_headspeed(wgt)
    -- profile bucket + ESC temp off-screen too: the headspeed extrema
    -- book per PROFILE, and the Temp alert reads the cached esc_temp — without
    -- these two (1 read_src each) an off-screen profile switch kept booking into
    -- the old bucket and the ESC-temp alert ran on a frozen value.
    -- Deliberately NOT here: update_craft_name/update_arm/update_ma_used are
    -- display-only formatting (their alert-relevant inputs are covered above).
    ultidash_functions.update_profiles(wgt)
    ultidash_functions.update_esc_temperature(wgt)
    -- eStatus off-screen too: the arm/disarm announce (SndArm) and the ESC fault
    -- decode (worst-latch + event log) live here — without it the "armed" callout
    -- fired late on the next screen switch and off-screen ESC faults went unlogged.
    ultidash_functions.update_estatus(wgt)
    -- model image / craft name off-screen too: the FC name arriving while
    -- another screen is up must flag the rebuild (dirty + layout_dirty), or the
    -- stats header keeps the font measured for the boot name and clips after the
    -- screen switch. Cheap steady-state (triple compare inside).
    ultidash_functions.update_model_image(wgt)
    ultidash_functions.update_timer_count(wgt)

    -- startup cell-check + batlow announce off-screen too (plugging a pack in while another
    -- screen is up used to be silent until the dashboard was shown again). The per-tick
    -- guards make update_cell/update_vcel here and inside update_battery_callout collapse to
    -- one read per pass.
    ultidash_functions.update_battery_gauge(wgt)
    ultidash_functions.update_battery_callout(wgt)
    ultidash_functions.update_link_warning(wgt)
    ultidash_functions.update_rssi_warning(wgt)
    ultidash_functions.update_power_warning(wgt)
    ultidash_functions.update_bec_warning(wgt)
    ultidash_functions.update_esc_load_warning(wgt)
    ultidash_functions.update_temp_warning(wgt)
    ultidash_functions.update_skp_warning(wgt)
    ultidash_functions.update_escalation(wgt)   -- after the alert latches are current
    ultidash_functions.crank_repeats(wgt)       -- re-announce armed repeats when due
    -- Volume-GVAR override off-screen too: without it an escalation boost
    -- raised on-screen stayed latched while another screen was up, and the disconnect
    -- release (pot rules again) waited for the next foreground pass. Write on-change
    -- only, GVAR-only (no MSP) — armed-safe by design.
    ultidash_functions.refresh_volume_override(wgt)
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
        -- Alert parity with background_refresh: the cascade must keep
        -- running on the VISIBLE dashboard while disconnected too — an armed link
        -- loss arms the Telem repeat right AT the disconnect, and without
        -- crank_repeats here it only ever nagged when another screen was up.
        -- update_battery_callout first: its disconnected path runs the reset
        -- cascade (power/fuel/volt latches), so stale Fuel/Volt repeats can't nag
        -- on frozen values; update_escalation then keeps the boost state honest.
        ultidash_functions.update_battery_callout(wgt)
        ultidash_functions.update_escalation(wgt)
        ultidash_functions.crank_repeats(wgt)
        return
    end
    ultidash_functions.refresh_ui(wgt)
    ultidash_functions.update_battery_callout(wgt)
    ultidash_functions.update_link_warning(wgt)
    ultidash_functions.update_rssi_warning(wgt)
    ultidash_functions.update_power_warning(wgt)
    ultidash_functions.update_bec_warning(wgt)
    ultidash_functions.update_esc_load_warning(wgt)
    ultidash_functions.update_temp_warning(wgt)
    ultidash_functions.update_skp_warning(wgt)
    ultidash_functions.update_escalation(wgt)   -- after the alert latches are current
    ultidash_functions.crank_repeats(wgt)       -- re-announce armed repeats when due
end

return ultidash_functions
