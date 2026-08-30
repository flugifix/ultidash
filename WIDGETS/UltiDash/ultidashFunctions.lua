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

-- Multi-vendor ESC status/fault decoder. LAZY-LOADED (same shape as dbg_load below): at
-- module level its 76 instructions sat in create(), which main.lua enters with five module
-- chunks already in it. The first caller is whichever of deferred_init / set_palette runs
-- first -- their order is NOT proven, so both go through the accessor and neither may
-- assume the other ran. NOT pcall'd, unlike dbg_load: a missing ultidashEsc.lua was fatal
-- while this sat at module level and stays fatal -- every read of it is a LEVEL_* constant
-- or the decoder itself, so degrading would only move the error somewhere less legible.
-- 0.8.0 loads it on EVERY craft: its LEVEL_* constants feed the palette, which is not
-- downstream of the craft target, so only the load SITE moved.
local esc = nil
local function get_esc()
    if esc == nil then esc = loadScript("/WIDGETS/UltiDash/ultidashEsc.lua")() end
    return esc
end

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
local ESC_LEVEL_COLORS = {}   -- filled by M.deferred_init (host stage 2a0); see the end of this file

-- swap the theme color shadows (called from ultidash.lua update() with the palette + semantic
-- colours it resolved). scheme (a SCHEMES descriptor since the registry refactor) is kept for
-- future use; colours come from `p` and `sem`.
function ultidash_functions.set_palette(scheme, p, sem)
    COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2 = p[1], p[2], p[3], p[4]
    COLOR_THEME_SECONDARY3, COLOR_THEME_FOCUS, COLOR_THEME_WARNING, COLOR_THEME_DISABLED = p[5], p[6], p[7], p[8]
    -- through the accessor, NOT the bare upvalue: whether deferred_init has run by now is
    -- not proven, and this is one of the two entry points that can be first
    local e = get_esc()
    ESC_LEVEL_COLORS[e.LEVEL_TRACE] = COLOR_THEME_DISABLED
    ESC_LEVEL_COLORS[e.LEVEL_INFO]  = COLOR_THEME_PRIMARY1
    if sem then
        sem_red, sem_yell = sem.red, sem.yell
        ESC_LEVEL_COLORS[e.LEVEL_WARN]  = sem_yell   -- was fixed yellow (BAR_COLOR_LOW)
        ESC_LEVEL_COLORS[e.LEVEL_ERROR] = sem_red    -- was fixed red (BAR_COLOR_CRITICAL)
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
local ARM_DISABLE_DESCS = {}   -- filled by M.deferred_init (host stage 2a0); see the end of this file

-- Patch the version-dependent last entries on the cached table (cheap, no realloc),
-- mirroring get_arming_disable_flag_names() in ultidashValues.lua. API >= 12.09: bit 25 =
-- OVERRIDE, bit 26 = ARMSWITCH; earlier: bit 25 = ARMSWITCH, bit 26 unused (entry 27 nil
-- so #ARM_DISABLE_DESCS drops back to 26 and the iterators skip it).
-- The FC's MSP API version, from whichever suite serves MSP on this radio: RFTool's
-- rf2.apiVersion (a number) or the RFSuite session's (a STRING, "12.09"). RFTool is read
-- first, which is the same order ultidashRf picks a provider in, so a radio carrying both
-- answers the same here as it does there. Duplicated in ultidashValues for the same rule --
-- the two version branches below already mirror each other, and this is the third half.
local function fc_api_version()
    local v = rf2 and rf2.apiVersion
    if type(v) == "number" then return v end
    local s = _G.rfsuite and _G.rfsuite.session
    if type(s) == "table" then return tonumber(s.apiVersion) end
    return nil
end

local function get_arm_disable_descs()
    local api = fc_api_version()
    if api and api >= 12.09 then
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
-- Minimum gap between two descending %-step callouts (centiseconds). Small on purpose:
-- it only stops two announcements treading on each other, it is NOT a cadence. The
-- CRITICAL nag keeps using the configurable FuelInt — that one IS a repeat interval.
-- (Both shared FuelInt until 0.7.0, which swallowed a step whenever the fine steps
-- passed faster than the repeat gap — exactly at the end of the flight, where a 5 %
-- step is a matter of seconds.)
local FUEL_STEP_GAP_CS    = 200
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
-- loaded once; its upvalues are common to every instance). Written by
-- publish_shared in the refresh/background cycle. Three consumers (the
-- second-screen subscribers were removed): the
-- menu ▸ Status page renders its snapshot, the detail builders read bg_filled and
-- thresholds, and owner/ts detect two placed instances (dual publisher).
-- Tables are mutated in place (no per-cycle allocations).
local Shared = {
    ready      = false,   -- true once an instance has published (Status page keys off it)
    ts         = nil,     -- getTime() of the last publish (dual-publisher detection)
    -- The last publisher's ID, not its wgt. It used to be the table itself, and that made this
    -- module-level field PIN a destroyed instance: on a model change the widget is torn down,
    -- nothing publishes on the new model if it places no UltiDash, and the dead instance stayed
    -- reachable with everything hanging off it. Measured 2026-08-18 on the simulator, with a
    -- model change staged against a model that places no UltiDash. An id compares exactly as
    -- well -- the field was only ever tested with `~=`, never dereferenced.
    owner      = nil,     -- pub_id of the last publisher (dual-publisher detection)
    next_id    = 0,       -- hands out pub_id; lives here so no new module-level local is needed
    model_name = nil,     -- FC craft name (cached by the publisher)
    connected  = false,
    bg_filled    = nil,   -- BGFilled as boolean (detail-page backgrounds)
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
-- (the REP_ALERTS fill lives in M.deferred_init; the table itself stays local above)

function ultidash_functions.get_shared()
    return Shared
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

    -- Dual-publisher detection: two placed instances are BOTH publishers (both
    -- write Shared) -> doubled callouts. Display-only; behaviour is otherwise
    -- unchanged. Reads the OLD ts, so this must run before Shared.ts is updated below.
    --
    -- The test is "I WAS the owner and something displaced me", not "somebody else is the
    -- owner". Only a LIVE second instance can displace a publisher; a destroyed one never
    -- publishes again. The old test could not tell those apart, so the first publish after a
    -- MODEL CHANGE -- fresh instance, foreign owner still in Shared, ts a second old -- raised
    -- the banner on a model placing exactly one instance (measured 2026-08-18 on the
    -- simulator, with a model change staged against a single-instance model). A fresh
    -- instance has no
    -- `was_owner`, so it now stays silent until it has actually been displaced once.
    -- Cost: detection arrives one publish cycle later (~200 ms at the 5 Hz publish rate),
    -- against a banner that is sticky for 5 s anyway.
    local now = getTime() or 0
    if wgt.pub_id == nil then
        Shared.next_id = (Shared.next_id or 0) + 1
        wgt.pub_id = Shared.next_id
    end
    if wgt.was_owner and Shared.owner ~= nil and Shared.owner ~= wgt.pub_id
       and (now - (Shared.ts or 0)) < 300 then
        wgt.dual_publisher_until = now + 500   -- sticky ~5 s past the last foreign publish
    end
    Shared.owner = wgt.pub_id
    wgt.was_owner = true

    Shared.ts         = getTime() or 0
    Shared.model_name = v.craft_name
    Shared.connected  = v.rf_connection_state ~= nil and v.rf_connection_state ~= "disconnected"
    Shared.bg_filled  = (o.BGFilled == 1)

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

-- Every utterance through the two players below bumps this. The spoken telemetry
-- report (D3) compares it against the value it saw after its OWN last utterance --
-- a difference means something else (an alert, a switch voice, a bank announce)
-- spoke in between, and the report yields per its TsayPrio setting. The callout
-- engine keeps precedence without knowing the report exists.
local audio_seq = 0

local function play_audio(file)
    if master_muted then return end
    audio_seq = audio_seq + 1
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
    audio_seq = audio_seq + 1
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
    local v = wgt.values.vcel
    local plausible = v ~= nil and v > MIN_PLAUSIBLE_CELL_V
    if o and o.VoltVoice == 2 and plausible then
        play_number(math.floor(v * 100 + 0.5), UNIT_VOLTS, PREC2)
        return
    end
    -- TOTAL voltage, DERIVED from the same latched cell value the callers triggered on --
    -- not from wgt.values.vbat. vbat and vcel are two independent sensors with two
    -- independent latches and different drop constants (VOLT_DROP_CELL * cells against
    -- VOLT_DROP_CELL), so under load one accepts a frame the other rejects and the two hold
    -- readings from different moments. Every caller of this function -- the voltage alert,
    -- VSay1/VSay2 and the startup cell check -- decides on vcel, so speaking vbat announced
    -- a number the decision was not made on: measured once at 3.73 V/cell with 22.38 V fed
    -- and 22.71 V announced. Reconstruction costs at most half a centivolt per cell, which
    -- PREC1 rounds away.
    if plausible then
        local cells = wgt.values.cel_count
        if cells ~= nil and cells > 0 then
            play_number(math.floor(v * cells * 10 + 0.5), UNIT_VOLTS, PREC1)
            return
        end
    end
    -- no plausible cell value, or no cell count yet: the pack latch is all there is, and
    -- saying a slightly stale number beats going silent on an alert.
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
--
-- The tools call this EVERY refresh with the bank they currently read (nil = a dead gap
-- between the FC's windows) plus the "page just opened" flag, and THIS function owns the
-- whole debounce -- the pages keep no announce state of their own. Reason: an announcement
-- queues TWO files and EdgeTX has no Lua API to flush the audio queue, so speaking on every
-- changed position chained -- sweeping the Config channel across all six banks enqueued
-- twelve clips that were still playing long after the knob had settled. Same failure and
-- the same cure as update_switch_voices further down: hold while the bank is moving, then
-- speak only the position that is still current when the window expires. The two constants
-- are its own rather than shared with the switch voices: these calls come from a tool
-- page's refresh, not from the 5 Hz pass, so the rates are not interchangeable.
local TB_VOICE_HOLD = 30    -- cs a bank must hold before it is announced
local TB_VOICE_GAP  = 150   -- cs minimum between two announcements (coalesces a sweep)
local tb_voice = { last = nil, pend = nil, t = 0, at = nil }

function ultidash_functions.tb_announce_pos(pos, arm)
    -- page (re)opened: forget what was last spoken, so the current bank speaks once
    if arm then tb_voice.last = nil end
    if type(pos) ~= "number" then return end   -- dead gap: say nothing, keep the state
    local now = getTime() or 0
    if pos ~= tb_voice.pend then
        tb_voice.pend = pos
        tb_voice.t = now                       -- candidate change, start the hold timer
    elseif pos ~= tb_voice.last and (now - tb_voice.t) >= TB_VOICE_HOLD
        and (tb_voice.at == nil or now - tb_voice.at >= TB_VOICE_GAP) then
        tb_voice.last = pos
        tb_voice.at = now
        play_audio("bank")        -- speaks "Bank" ...
        play_number(pos, 0, 0)    -- ... then the position number -> "Bank 1" ... "Bank 6"
    end
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

-- "Was the craft flying when the link went away?" -- the question the armed-disconnect branch
-- means to ask, and the RF tool's PREVIOUS state cannot answer it. At a real telemetry loss the
-- tool loses the ARM value about 1.3 s after the frames stop and reports "disarmed"; only ~4.9 s
-- later does its own connection timeout make it "disconnected". So the previous_state handed to
-- on_telemetry_state_changed is "disarmed" there and NEVER "armed" -- the gate could not match,
-- and the armed-loss escalation never fired on a real link (it only ever fired against a
-- stand-in that jumped straight from armed to disconnected).
-- The ARM sensor answers it, and is the one signal that survives the gap: read_src reads "ARM"
-- through getSourceValue (the name carries no app-id, so the resolver never maps it to an index),
-- and getSourceValue does NOT age out -- it keeps serving the last received arming word until
-- EdgeTX's own ~30 s sensor expiry, an order of magnitude longer than the tool's timeout.
-- A genuine disarm is untouched by this: there the link is still up, the FC sends the cleared
-- arming word, and the held value therefore reads DISARMED -- so a normal disarm-then-power-off
-- still takes the quiet branch below. previous_state stays in front as the cheaper test and as
-- the path for a model with no ARM sensor at all.
local function disconnected_while_armed(wgt, previous_state)
    if previous_state == "armed" then return true end
    return ultidash_functions.arm_sensor_on(wgt)
end
-- exported for the UI layer's own disconnect branch (the flight-log flush), which has to make
-- the identical judgement one module over
ultidash_functions.disconnected_while_armed = disconnected_while_armed

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
-- that indirection was unreliable: the connection state is pushed by the RFTool when IT
-- notices a change, so a cached value can lag the sensors by a pass or more. (Until
-- 2026-08-15 this said "rfToolState is nil on this RFTool"; the widget no longer reads that
-- field at all — see ultidashRf note_tool_api — but the reason above is unchanged.)
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
    get_esc().reset()
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
    -- ...from whichever suite serves MSP: RFTool's rf2.modelName, else the RFSuite session's
    -- (filled by that suite's own on-connect read, and nil again on disconnect exactly like
    -- RFTool's -- which is what the cache above is for either way).
    local fc_name = rf2 and rf2.modelName
    if fc_name == nil then
        local s = _G.rfsuite and _G.rfsuite.session
        if type(s) == "table" and type(s.modelName) == "string" then fc_name = s.modelName end
    end
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
-- 900MHz 4.x (0-16) collides with 3.x and is NOT disambiguated (rare on a heli).
local RFMD_INFO = {}   -- filled by M.deferred_init (host stage 2a0); see the end of this file
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

-- Diagnostics (Debug log only): trace the voltage path around a fresh connect. The
-- "wrong voltage right after plugging in a new pack" complaint can't be told apart from
-- the state/PERF log alone — what's missing is the RAW sensor reading next to the LATCHED
-- value, the cell count and the link state at that moment. on_telemetry_state_changed
-- opens a BATT_TRACE_CS window on every (re)connect; inside it one line per pass is
-- logged, then it goes quiet by itself. Zero cost with the Debug log off (dbg nil /
-- disabled) or outside the window.
local BATT_TRACE_CS = 2000        -- ~20 s of trace after a connect

local function batt_trace(wgt)
    if dbg == nil or wgt.batt_trace_until == nil then return end
    local now = getTime() or 0
    if now > wgt.batt_trace_until then wgt.batt_trace_until = nil; return end
    if wgt.batt_trace_t == now or not dbg.is_enabled() then return end
    wgt.batt_trace_t = now
    local v = wgt.values
    dbg.logf("BATT", "raw v=%s c=%s cel#=%s | held v=%s c=%s cels=%s | acc v=%s c=%s | rq=%s pl=%s chk=%s",
        tostring(wgt.vbat_raw), tostring(wgt.vcel_raw), tostring(read_src(wgt, "Cel#")),
        tostring(v.vbat), tostring(v.vcel), tostring(v.cel_count),
        tostring(wgt.vbat_acc), tostring(wgt.vcel_acc),
        tostring(read_src(wgt, "RQly")), tostring(wgt.power_lost), tostring(v.batt_checking))
end

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
    wgt.vbat_raw, wgt.vbat_acc = raw, accepted      -- batt_trace (Debug log) only
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
    local raw_cell = read_src(wgt, "Vcel")
    local accepted = latch_voltage(wgt, "vcel", raw_cell, VOLT_DROP_CELL, COLLAPSE_DROP_CELL)
    wgt.vcel_raw, wgt.vcel_acc = raw_cell, accepted  -- batt_trace (Debug log) only
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

-- Ceiling (centiseconds) on deferring the startup cell check while no LIVE reading exists.
-- Beyond it the check concludes on what it has, which is the existing "no value -> warn"
-- path: a pack that never reports is a fault worth a warning, and an indefinite grey
-- progress bar would be a worse answer than a wrong one. On the 2026-08-01 recording the
-- new pack's first frame arrived 7,5 s after the connect, so this is 4x that margin.
local BATT_CHECK_MAX_CS = 3000

-- Is the voltage we are about to judge still the PREVIOUS pack's?
--
-- It cannot be told from the value itself — a carried-over reading is a perfectly live sensor
-- read, which is why gating on "is there a reading" does not work and was tried first. What
-- distinguishes it is that it is *unchanged*: EdgeTX hands Lua the last value it received
-- until the new telemetry session replaces it, so immediately after a fast pack change the
-- sensor still reads, to the hundredth of a volt, what the pack that was just unplugged
-- ended on. `vbat_last_session` is that number, recorded at the disconnect.
--
-- A reading of nothing counts too: on the radio the sensor went to 0 between the two.
--
-- The false positive is a new pack that reads bit-identical to the last one's landing
-- voltage, and it is harmless: the check then waits out BATT_CHECK_MAX_CS and reaches the
-- same verdict, late. The false negative it prevents is a full pack announced as low.
local function pack_reading_is_carried_over(wgt)
    local v = wgt.vbat_raw
    if v == nil or v <= 0 then return true end
    local prev = wgt.vbat_last_session
    return prev ~= nil and math.abs(v - prev) < 0.005
end

-- The verdict below is spoken from `vcel`, not from `vbat` — and with no per-cell value it
-- takes the ONE branch that warns silently: amber bar, no callout. That is the right answer
-- for a pack which never reports and the wrong one for a pack whose CELL COUNT has merely
-- not arrived yet. The count comes from the FC's battery config over MSP, so anything else
-- occupying that queue at plug-in pushes it past this window — which is what the FC-served
-- adjustment table did (ultidashRf adj_may_start now holds the walk back; this is the other
-- half, and the one that does not care WHAT delayed the reply).
--
-- So a missing per-cell value defers exactly like a carried-over vbat, under the same
-- BATT_CHECK_MAX_CS ceiling: a pack that genuinely never reports still reaches the warning,
-- late, and nothing here can silence a callout that is owed.
local function cell_reading_missing(wgt)
    local c = wgt.values.vcel
    return c == nil or c <= 0
end

-- Startup cell-check (after ePowerbar): show a grey progress bar while the
-- battery settles, then warn (colour + audio) if the pack is not fully charged.
function ultidash_functions.update_battery_gauge(wgt)
    batt_trace(wgt)                    -- diagnostics; self-limiting, off unless logging
    local vbat = wgt.values.vbat
    local startup_delay = math.max(1, wgt.options.StartupDelay or 4) * 100
    local cell_full = wgt.values.vcel_full_threshold()   -- from FC (mspBatteryConfig)

    -- arm the check when voltage first appears
    local had_voltage = wgt.prev_vbat ~= nil and wgt.prev_vbat > 0
    local has_voltage = vbat ~= nil and vbat > 0
    if cell_full > 0 and has_voltage and not had_voltage then
        wgt.batt_check_until = getTime() + startup_delay
        wgt.batt_check_expiry = getTime() + BATT_CHECK_MAX_CS   -- see the deferral below
        wgt.batt_check_deferred = false
        wgt.values.batt_checking = true
        wgt.values.batt_check_progress = 0
        wgt.batt_warn = false
        clear_repeat(wgt, "Cell")          -- a new check starts fresh (drop any old nag)
        if dbg and dbg.is_enabled() then
            dbg.logf("CELLCHK", "armed on first voltage: vbat=%s (raw %s) vcel=%s (raw %s) cels=%s full=%s delay=%ss",
                tostring(vbat), tostring(wgt.vbat_raw), tostring(wgt.values.vcel), tostring(wgt.vcel_raw),
                tostring(wgt.values.cel_count), tostring(cell_full), tostring(startup_delay / 100))
        end
    end
    wgt.prev_vbat = vbat

    if wgt.values.batt_checking then
        local now = getTime()
        -- The window is up — but is there anything from THIS pack to judge yet?
        --
        -- After a fast pack change there is not. EdgeTX keeps handing Lua the previous
        -- pack's last reading until the new telemetry session resets its sensors, so the
        -- check arms on a voltage that belongs to the battery the pilot just took off the
        -- helicopter; the latch then correctly protects that value against the zeros which
        -- follow, and the verdict lands before the pack under test has reported at all.
        -- Measured on the radio 2026-08-01: armed on 3.78 V/cell at 12:28:43.41, concluded
        -- "low" at 12:28:47.50, and the pack it was judging first spoke at 12:28:50.85 —
        -- with 4.14 V/cell. A full battery announced as low and the gauge amber, every time
        -- the pack was changed quickly enough.
        --
        -- So: defer rather than decide, and only AT the window's end — asking per pass would
        -- restart the bar on every dropped frame. This is not the power_lost gate that the
        -- announce path below deliberately does without: a deferral cannot silence a real
        -- callout, only make it wait for a value that exists. Bounded by BATT_CHECK_MAX_CS,
        -- so a pack that never reports still reaches the "no value -> warn" verdict.
        -- Same short-circuit as before — the two cheap time compares first, the reading
        -- tests only inside the window, so the steady-state cost per pass is unchanged.
        -- nil | "carried" | "nocell" — a CODE, not a message: this runs at 5 Hz and the
        -- text is built only inside the once-per-check log branch below.
        local waiting
        if now >= (wgt.batt_check_until or 0) and now < (wgt.batt_check_expiry or 0) then
            if pack_reading_is_carried_over(wgt) then waiting = "carried"
            elseif cell_reading_missing(wgt) then waiting = "nocell" end
        end
        if waiting then
            wgt.batt_check_until = now + startup_delay
            wgt.values.batt_check_progress = 0
            -- once per check, not once per pass: the next hardware log should show that the
            -- deferral engaged and for how long, without burying the rest of the session
            if dbg and dbg.is_enabled() and not wgt.batt_check_deferred then
                wgt.batt_check_deferred = true
                if waiting == "carried" then
                    dbg.logf("CELLCHK", "deferred: vbat raw %s still the previous session's %s"
                        .. " — waiting up to %ss for the connected pack to report",
                        tostring(wgt.vbat_raw), tostring(wgt.vbat_last_session),
                        tostring(BATT_CHECK_MAX_CS / 100))
                else
                    dbg.logf("CELLCHK", "deferred: no per-cell value yet (cells=%s) — the FC"
                        .. " battery config has not landed; waiting up to %ss",
                        tostring(wgt.values.cel_count), tostring(BATT_CHECK_MAX_CS / 100))
                end
            end
        elseif now >= (wgt.batt_check_until or 0) then
            wgt.values.batt_checking = false
            wgt.values.batt_check_progress = 100
            local cellv = wgt.values.vcel
            if dbg and dbg.is_enabled() then
                dbg.logf("CELLCHK", "done: vcel=%s (raw %s) vbat=%s (raw %s) full=%s -> %s",
                    tostring(cellv), tostring(wgt.vcel_raw), tostring(wgt.values.vbat), tostring(wgt.vbat_raw),
                    tostring(cell_full),
                    (cellv == nil or cellv <= 0) and "no value (warn)"
                        or (cellv >= cell_full) and "full (silent)" or "low -> announce")
            end
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

-- ============================================================================
-- M5: LIVE TELEMETRY MONITOR -- the host-side data path
-- ============================================================================
-- The ring buffer lives HERE, not in the lazy toolbox/livemon.lua module, because
-- sampling has to run while the page is closed -- opening it after a manoeuvre must
-- show the manoeuvre. The renderer only reads wgt.lm.
--
-- Shape (spec L7/L8): sampled every refresh()/background() pass, folded into 5 Hz
-- min/max BUCKETS -- a plain 5 Hz sample can miss a one-frame spike, a min/max pair
-- cannot see less than the pass rate does. The ring always holds 60 s; the page's
-- window (15/30/60 s) is a view of it. Allocated only while >= 1 sensor is
-- configured (boot-resident heap drags the whole UI through GC, Gotcha 7), flat
-- preallocated arrays, no per-tick allocation.
--
-- The ring is addressed by an ABSOLUTE bucket counter (lm.head) plus a per-slot
-- stamp array: bucket i is valid only while bstamp[i] carries the absolute number
-- last written there. That makes a suspension gap (the widget stopped -- a Tools
-- script ran, the radio sat in a menu) FREE to handle: head jumps by the missed
-- count and the skipped buckets simply fail the stamp check, instead of a catch-up
-- loop writing hundreds of empties inside one call's budget.
local LM_BUCKETS   = 300   -- 60 s x 5 Hz
local LM_BUCKET_CS = 20    -- bucket width in centiseconds
local LM_KEYS = { "LmV1", "LmV2", "LmV3", "LmV4" }

function ultidash_functions.lm_sample(wgt)
    local o = wgt.options
    if o == nil then return end
    local lm = wgt.lm

    -- (re)configure on any slot change: compare the four stored names, no string
    -- building -- this is the whole cost of the feature while it is off
    local cfg = wgt.lm_cfg
    local changed = (cfg == nil)
    if not changed then
        for i = 1, 4 do
            if o[LM_KEYS[i]] ~= cfg[i] then changed = true break end
        end
    end
    if changed then
        cfg = {}
        wgt.lm_cfg = cfg
        local names, keys, srcidx = {}, {}, {}
        for i = 1, 4 do
            local name = o[LM_KEYS[i]]
            cfg[i] = name
            -- "~off" is ultidash.lua's SENSOR_OFF sentinel (the sensor rows' default).
            -- Missing it here configured FOUR ghost slots on every fresh install: the
            -- ring allocated, the chunk allocator rode the early cycles and four failing
            -- name reads rode every one -- found by the budget diff (refresh max
            -- 13.1k -> 16.2k FAIL), not by anything misbehaving visibly.
            if type(name) == "string" and name ~= "" and name ~= "~off" then
                names[#names + 1] = name
                keys[#keys + 1] = LM_KEYS[i]
                -- a raw pick's display name does not round-trip through the label
                -- lookup (the PanelV lesson); its verified source INDEX is in the
                -- <slot>Raw shadow key -- verify once here, read by index below
                local idx = o[LM_KEYS[i] .. "Raw"]
                if type(idx) == "number" and idx ~= 0 then
                    local okn, n = pcall(getSourceName, idx)
                    srcidx[#names] = (okn and n == name) and idx or false
                else
                    srcidx[#names] = false
                end
            end
        end
        if #names == 0 then
            wgt.lm = nil                       -- feature off: no resident state at all
            return
        end
        local now = getTime() or 0
        lm = { n = #names, names = names, keys = keys, srcidx = srcidx,
               -- Curated names resolved to a getValue INDEX, filled below and refreshed
               -- whenever the app-id resolver's generation moves. `false` (not nil) is
               -- the "never resolved" sentinel: wgt.sensor_sig is itself nil until the
               -- first scan, and nil ~= nil would never fire.
               validx = {}, res_sig = false,
               head = 0, deadline = now + LM_BUCKET_CS,
               bstamp = {}, bmin = {}, bmax = {}, rmin = {}, rmax = {},
               arm_bucket = nil, prev_armed = false,
               -- the PAGE's point tables live here too (they survive a page
               -- close, so reopening costs nothing), but they are ALLOCATED by
               -- the page module, chunked across ITS cycles: the worst case is
               -- 2400 tables = ~14k instructions, and chunking that through
               -- lm_sample put ~1.5k on top of the dashboard's heaviest cycles
               -- -- measured straight into a 16.3k FAIL. The open tool page's
               -- cycles carry no dashboard work, so the allocation is free
               -- there. Sampling itself never touches pts.
               pts = {}, alloc_k = 1, alloc_i = 1, pts_done = false }
        for i = 1, LM_BUCKETS do lm.bstamp[i] = -1 end
        for k = 1, lm.n do
            local mn, mx = {}, {}
            for i = 1, LM_BUCKETS do mn[i] = 0 mx[i] = 0 end
            lm.bmin[k], lm.bmax[k] = mn, mx
            lm.pts[k] = {}
        end
        wgt.lm = lm
    end
    if lm == nil then return end

    -- Resolve the curated names to a READ INDEX, once per resolver generation. This runs
    -- every pass (~20 Hz, not 5 Hz -- a peak between two heavy passes is what the ring is
    -- for), so read_src's per-CENTISECOND cache always missed at >= 5 cs frame spacing and
    -- every slot paid its full read: for a name the app-id resolver knows, read_src's own
    -- getValue plus two cache-table writes; for a name it does not, getSourceValue(name),
    -- the C-side source-table SCAN. Resolving here keeps the scan for genuinely unmapped
    -- names only (ELRS sensors and anything outside wgt.sensor_idx) and makes the rest a
    -- bare getValue.
    -- TWO INDEX SPACES, deliberately kept in two arrays: srcidx comes from the <slot>Raw
    -- shadow and is a getSourceName/getSourceValue index; wgt.sensor_idx lives in the
    -- getFieldInfo/getValue space (ultidash.lua, resolve_sensor_indices) and is read with
    -- getValue. Folding them into one array would read a different sensor.
    if lm.res_sig ~= wgt.sensor_sig then
        lm.res_sig = wgt.sensor_sig
        local map = wgt.sensor_idx
        for k = 1, lm.n do
            lm.validx[k] = (map ~= nil and map[lm.names[k]]) or false
        end
    end

    -- fold this pass's readings into the running pair (nil reading = no sample)
    for k = 1, lm.n do
        local idx = lm.srcidx[k]
        local v
        if idx then v = getSourceValue(idx)
        else
            local vi = lm.validx[k]
            if vi then v = getValue(vi)
            else v = read_src(wgt, lm.names[k]) end
        end
        if type(v) == "number" then
            local mn = lm.rmin[k]
            if mn == nil or v < mn then lm.rmin[k] = v end
            local mx = lm.rmax[k]
            if mx == nil or v > mx then lm.rmax[k] = v end
        end
    end

    -- the arm edge, for the page's marker (L9: nothing is cleared across disarm --
    -- a 60 s ring empties itself, the marker just names where the edge sits).
    -- Read from the HOST's cached flag, not is_craft_armed: "ARM" carries no app-id, so
    -- that call is always the C-side name-scan path, and this function runs every pass
    -- (~20 Hz) while any slot is configured. The cache is refreshed by both heavy passes
    -- at 5 Hz (ultidash.lua refresh/background), which cannot lose an edge here -- the
    -- marker records a BUCKET, and a bucket is 20 cs wide.
    local armed = wgt.armed_now
    if armed and not lm.prev_armed then lm.arm_bucket = lm.head end
    lm.prev_armed = armed

    -- bucket tick: close the running pair into the ring. A gap longer than one
    -- bucket advances head PAST the missed buckets (their stamps stay stale).
    local now = getTime() or 0
    if now >= lm.deadline then
        local missed = math.floor((now - lm.deadline) / LM_BUCKET_CS)
        if missed > 0 then lm.head = lm.head + missed end
        local slot = lm.head % LM_BUCKETS + 1
        for k = 1, lm.n do
            local mn = lm.rmin[k]
            if mn ~= nil then
                lm.bmin[k][slot], lm.bmax[k][slot] = mn, lm.rmax[k]
            else
                lm.bmin[k][slot], lm.bmax[k][slot] = 1, 0    -- mn > mx = empty
            end
            lm.rmin[k], lm.rmax[k] = nil, nil
        end
        lm.bstamp[slot] = lm.head
        lm.head = lm.head + 1
        lm.deadline = lm.deadline + (missed + 1) * LM_BUCKET_CS
    end
end


local SWITCH_VOICES = {}   -- filled by M.deferred_init (host stage 2a0); see the end of this file

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
local GOV_VOICE_FILES = {}   -- filled by M.deferred_init (host stage 2a0); see the end of this file
local GOV_VOICE_KEYS = {}   -- filled by M.deferred_init (host stage 2a0); see the end of this file

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

-- ============================================================================
-- SPOKEN TELEMETRY REPORT (D3)
-- ============================================================================
-- The pilot's own readout: up to eight configured sensors (Settings > Alerts >
-- Telemetry report), spoken in the CONFIGURED ORDER, triggered by a shortcut
-- switch (target "Voice: Telemetry report"). A held position slot repeats at
-- TsayInt; a momentary press is one report. It MAY speak while armed -- the
-- user's decision -- and the callout engine keeps precedence: foreign audio
-- (audio_seq) either aborts the report or pauses it (TsayPrio), never the other
-- way round. Default is value-and-unit through EdgeTX's own voice (playNumber
-- speaks the unit); per-sensor NAME wavs are an opt-in (TsayNames) whose missing
-- file falls back to value-and-unit -- never to silence, so an incomplete
-- recording set cannot make the report go quiet.
--
-- The DATA half (value, UNIT const, decimals, wav key per sensor name) is a
-- resolver closure the host installs via telemsay_init -- SENSOR_INFO and
-- SENSOR_VALUE_FIELD are host locals, and this module owns only the audio half.
local TSAY_N = 8
local TSAY_ITEM_GAP  = 200   -- cs between two item utterances (~8 items = the 15-20 s design)
local TSAY_PAUSE_CS  = 250   -- cs the report stands back after foreign audio (pause mode)

local tsay_resolver = nil
function ultidash_functions.telemsay_init(fn) tsay_resolver = fn end

-- name-wav existence, one fstat per (language, key) per session -- wavs do not
-- appear mid-flight, and an SD change comes with a reboot
local tsay_wav_cache = {}
local function tsay_wav_exists(wav)
    local key = audio_lang .. "/" .. wav
    local hit = tsay_wav_cache[key]
    if hit == nil then
        local ok, st = pcall(fstat, "/SOUNDS/" .. audio_lang .. "/ultidash/s_" .. wav .. ".wav")
        hit = (ok and st ~= nil) or false
        tsay_wav_cache[key] = hit
    end
    return hit
end

-- Status-page helper (M4): how many of the CONFIGURED slots have a name wav in the
-- active language. The row exists because the fallback speaks value-and-unit, so an
-- incomplete recording set cannot be HEARD -- this is where it becomes checkable.
function ultidash_functions.tsay_wav_state(wgt)
    local o = wgt.options
    if o == nil or o.TsayNames ~= 1 then return nil end
    local total, found = 0, 0
    for i = 1, TSAY_N do
        local name = o["TsayV" .. i]
        if not (name == nil or name == "~off" or name == "") then
            total = total + 1
            local wav
            if name == "~volt" then
                wav = "volt"
            elseif tsay_resolver ~= nil then
                local _, _, _, w = tsay_resolver(wgt, name)
                wav = w
            end
            if wav and tsay_wav_exists(wav) then found = found + 1 end
        end
    end
    return found, total, audio_lang
end

--- Trigger a report. hold=true (a held position slot) arms the repeat; the release
--- clears it. A report already running just updates the hold flag -- the trigger is
--- edge/hold semantics, not a queue.
function ultidash_functions.telemsay_start(wgt, hold)
    local st = wgt.tsay
    if st == nil then st = {}; wgt.tsay = st end
    st.hold = hold == true
    if st.active then return end
    st.active, st.idx = true, 0
    st.started = getTime() or 0
    st.next_t = 0
    st.seq = audio_seq
end

function ultidash_functions.telemsay_release(wgt)
    local st = wgt.tsay
    if st then st.hold = false end
end

--- One bounded step per 5 Hz pass (refresh AND background, like the alerts).
function ultidash_functions.update_telemetry_report(wgt)
    local st = wgt.tsay
    if st == nil then return end
    local o = wgt.options
    local now = getTime() or 0

    if not st.active then
        -- held switch: the NEXT report starts TsayInt after the last one STARTED
        -- (the 10 s settings floor keeps a report from overtaking itself)
        if st.hold and st.started ~= nil then
            if (now - st.started) >= ((o and o.TsayInt or 30) * 100) then
                st.active, st.idx, st.started, st.next_t, st.seq = true, 0, now, 0, audio_seq
            end
        end
        return
    end

    if now < (st.next_t or 0) then return end

    -- foreign audio since our last utterance = an alert (or any other voice) spoke.
    -- TsayPrio 1 aborts the report; 2 stands back and resumes with the next item.
    -- The third variant -- the warning waiting for the report -- was decided OUT.
    if st.idx > 0 and audio_seq ~= st.seq then
        if (o and o.TsayPrio or 1) == 1 then
            st.active = false
            ultidash_functions.log("TSAY aborted at item %d: an alert spoke", st.idx)
            return
        end
        st.seq = audio_seq
        st.next_t = now + TSAY_PAUSE_CS
        return
    end

    if tsay_resolver == nil then st.active = false return end
    while true do
        st.idx = st.idx + 1
        if st.idx > TSAY_N then
            st.active = false
            return
        end
        local name = o and o["TsayV" .. st.idx]
        if not (name == nil or name == "~off" or name == "") then
            if name == "~volt" then
                -- the smart voltage speaks exactly like the voltage alert does
                -- (latched values, VoltVoice format)
                if o.TsayNames == 1 and tsay_wav_exists("volt") then play_audio("s_volt") end
                announce_voltage(wgt)
                st.seq = audio_seq
                st.next_t = now + TSAY_ITEM_GAP
                return
            end
            local v, unit, dec, wav = tsay_resolver(wgt, name)
            if v ~= nil then
                if o.TsayNames == 1 and wav and tsay_wav_exists(wav) then
                    play_audio("s_" .. wav)
                end
                play_number(math.floor(v * (10 ^ (dec or 0)) + 0.5), unit or 0,
                    (dec == 1) and PREC1 or (dec == 2) and PREC2 or 0)
                st.seq = audio_seq
                st.next_t = now + TSAY_ITEM_GAP
                return
            end
            -- E2: a sensor with no value is SKIPPED, and the log says so -- with the
            -- name option off the pilot infers the sensor from the configured order,
            -- and a silent hole in that order must at least be on record
            ultidash_functions.log("TSAY skip %s: no value", tostring(name))
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
    -- ONE accessor call for the whole function: this runs on every 5 Hz telemetry pass and
    -- reads six ESC constants, so the alternative is six nil-checks per pass for nothing
    local e = get_esc()
    local connected = is_rf_connected(wgt)
    local armed = is_craft_armed(wgt)

    -- throttle. Memoised on the integer reading: the formatted string is identical whenever
    -- the reading is, and this runs at 5 Hz for a whole armed flight. thr_text_key is
    -- cleared on every branch that writes a NON-formatted text, so a return to the same
    -- reading after "Safe" / "**" / "--" still rebuilds. The spec that asked for this (H-4)
    -- prices it as completeness rather than as a lever -- the reading does move on most
    -- passes; what it buys is the steady-throttle case, and it cannot cost anything.
    if not connected then
        wgt.values.throttle_text = "**"
        wgt.thr_text_key = nil
    elseif not armed then
        wgt.values.throttle_text = "Safe"
        wgt.thr_text_key = nil
    else
        local thr = read_src(wgt, "Thr")
        if thr == nil then
            wgt.values.throttle_text = "--"
            wgt.thr_text_key = nil
        elseif thr ~= wgt.thr_text_key then
            wgt.thr_text_key = thr
            wgt.values.throttle_text = string.format("%d%%", thr)
        end
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
    if connected and sig == e.SIG_RESTART then
        status_text = "RESTART ESC"
        status_color = sem_red   -- TEXT colour (theme-aware), not a bar fill
        wgt.esc_status_level = e.LEVEL_ERROR
        estatus_log(wgt, "RESTART ESC", e.LEVEL_ERROR)
    elseif connected then
        -- memo: get_status allocates a result table + concat strings each call, but the
        -- inputs only move on a flag/signature change. Still called with `changed` exactly
        -- when the flags changed, so the YGE SPN counter (which only counts then) is intact.
        if changed or sig ~= wgt.esc_status_sig or wgt.esc_status_st == nil then
            wgt.esc_status_st = e.get_status(sig, flags, changed)
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
            status_color = ESC_LEVEL_COLORS[wgt.esc_status_level or e.LEVEL_INFO]
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
            estatus_log(wgt, armed and "Armed" or "Disarmed", e.LEVEL_INFO)
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

    -- The voltage this telemetry session ended on, kept across the gap so the NEXT session's
    -- startup cell check can tell a carried-over sensor reading from the pack it is meant to
    -- be judging (see pack_reading_is_carried_over). Taken from the latch, which by design
    -- holds the last healthy value rather than the unplug decay. Every disconnect, armed or
    -- not: a pack change after an armed disconnect is the same trap.
    if new_state == "disconnected" then
        local v = wgt.values and wgt.values.vbat
        if v ~= nil and v > 0 then wgt.vbat_last_session = v end
    end

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
        -- open the voltage trace window (Debug log only): a pack swap lands exactly here
        wgt.batt_trace_until = (getTime() or 0) + BATT_TRACE_CS
        wgt.batt_trace_t = nil
        if dbg and dbg.is_enabled() then
            dbg.logf("BATT", "connect (%s -> %s): live values cleared, trace window open",
                tostring(previous_state), tostring(new_state))
        end
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
        -- NOT `previous_state == "armed"`: the RF tool passes through "disarmed" on the way to
        -- "disconnected" at every real link loss, so that test never matched in flight. See
        -- disconnected_while_armed.
        if disconnected_while_armed(wgt, previous_state) then
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
    wgt.vsay_done = nil                   -- fixed-voltage orientation callouts re-arm per flight
    wgt.vsay_pend = nil
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
        -- The "first observation after arming" sentinel is consumed on the FIRST PASS,
        -- not on the first CHANGE. reset_callout_state seeds callout_last_capa = 100, so
        -- arming with a FULL pack left the sentinel standing (capa == last_capa == 100)
        -- until the level actually moved -- and that first real step (100 -> 90) was then
        -- swallowed as "the first observation". Verified against a replayed log: a
        -- 100 % -> 25 % descent used to start announcing at 80 %, now at 90 %; arming on a
        -- half-used pack is unchanged (no callout at arm).
        if wgt.callout_next_capa == 0 then
            wgt.callout_last_capa = capa
            wgt.callout_next_capa = now
        elseif wgt.callout_last_capa ~= capa and now > wgt.callout_next_capa then
            if capa < wgt.callout_last_capa and fuel <= (wgt.options.FuelStart or 100) then
                -- DESCENDING only: a rise (pack recovering off-load, an FC value jumping
                -- back up) re-arms the ladder silently instead of counting its way up.
                if fuel > critical + FUEL_VLOW then play_audio("battry") else play_audio("batlow") end
                play_fuel_value(wgt, capa)
                -- short gap only — the steps are NOT throttled by the nag's repeat
                -- interval any more, which used to swallow one at a fast-falling end
                wgt.callout_next_capa = now + FUEL_STEP_GAP_CS
            end
            wgt.callout_last_capa = capa
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

-- Fixed per-cell voltage orientation callouts, ALONGSIDE the %-based fuel steps. Two
-- configurable thresholds (VSay1/VSay2, centivolt per cell; 0 = that step off). Each is
-- announced ONCE per flight the first time the per-cell voltage STAYS at/below it for
-- VSayHold seconds (so a brief load sag doesn't fire early; 0 = immediate/next tick).
-- Speaks only the voltage, per VoltVoice. Armed-only (the caller gates it); re-armed on
-- disarm/disconnect via reset_callout_state. Independent of the low/critical Voltage alert.
local function vsay_step(wgt, i, thr, cv, now, hold)
    if thr <= 0 or wgt.vsay_done[i] then return false end
    if cv <= thr then
        local p = wgt.vsay_pend[i]
        if p == 0 then
            wgt.vsay_pend[i] = now + hold          -- entered the band: start the hold timer
        elseif now >= p then
            announce_voltage(wgt)
            wgt.vsay_done[i] = true
            wgt.vsay_pend[i] = 0
            return true
        end
    else
        wgt.vsay_pend[i] = 0                        -- recovered above: cancel the pending hold
    end
    return false
end

local function crank_voltage_say(wgt)
    local t1 = wgt.options.VSay1 or 0
    local t2 = wgt.options.VSay2 or 0
    -- feature off, or MAIN POWER LOST (frozen last-good value is no real reading)
    if (t1 <= 0 and t2 <= 0) or wgt.power_lost then return end
    local cellv = wgt.values.vcel
    if cellv == nil or cellv <= MIN_PLAUSIBLE_CELL_V then return end
    local cv = math.floor(cellv * 100)
    local now = getTime()
    local hold = math.max(0, wgt.options.VSayHold or 3) * 100
    if wgt.vsay_done == nil then wgt.vsay_done = { false, false }; wgt.vsay_pend = { 0, 0 } end
    -- announce the HIGHER threshold first; never two voltages back-to-back in one pass
    if t1 >= t2 then
        if vsay_step(wgt, 1, t1, cv, now, hold) then return end
        vsay_step(wgt, 2, t2, cv, now, hold)
    else
        if vsay_step(wgt, 2, t2, cv, now, hold) then return end
        vsay_step(wgt, 1, t1, cv, now, hold)
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
    crank_voltage_say(wgt)
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
                if bec then play_number(math.floor(bec * 10 + 0.5), UNIT_VOLTS, PREC1) end
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
-- AT THE ARM MOMENT (first plausible reading while armed, FROZEN until disarm/
-- disconnect), so it adapts to any 5 V / 6 V / 8.4 V BEC. It warns when
-- the live BEC drops BecWarn % below that reference, critical at BecCrit %. Announced
-- once per level (warn->crit announces again); the per-alert repeat engine handles
-- repeats. Sensor-derived (Vbec, live/un-latched), no MSP -> armed-safe.
function ultidash_functions.update_bec_warning(wgt)
    -- ARMED-gated on the SENSOR, not on the RF tool's armed sub-state. That sub-state is
    -- the right source for the voltage latch and the stats extrema (it has clean edges),
    -- but on the documented setups where the RF tool never reports it, it is never true --
    -- and this alert was then dead for the whole flight. Every other armed-gated alert
    -- reads the sensor.
    if not wgt.options or wgt.options.SndBec ~= 1 or not is_craft_armed(wgt) then
        wgt.bec_ref = nil; wgt.bec_pending = 0; wgt.bec_level = 0; wgt.bec_announced = 0
        clear_repeat(wgt, "Bec")
        return
    end
    local bec = wgt.values.vbec
    if bec == nil or bec <= MIN_PLAUSIBLE_CELL_V then return end
    -- FREEZE the reference at the arm edge (first plausible reading while
    -- armed). The old running max-since-arm slowly ratcheted the reference up on
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
            if b then play_number(math.floor(b * 10 + 0.5), UNIT_VOLTS, PREC1) end
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
    -- the ARM sensor, for the same reason as the BEC alert above
    if not o or o.SndTemp ~= 1 or not is_craft_armed(wgt) then
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
    -- telemetry-lost is judged from its own latch: the latch is set at the loss EDGE and there
    -- is no per-pass condition to re-read while the link is away. (The reason formerly given
    -- here -- "the ARM sensor is gone when the link drops" -- does not hold for the reader
    -- UltiDash uses: read_src takes "ARM" through getSourceValue, which keeps serving the last
    -- arming word through the gap. See disconnected_while_armed.) Coupled to the RUNNING
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
-- Note = the generic NOTICE slot: a message handed in from outside (wgt.ovl_note)
-- rather than derived from a live sensor condition. Its entry here is the DEFAULT
-- title and, just as important, the FITTING string -- the title font is chosen so
-- that the longest entry in this table fits the box, so a notice title longer than
-- this one would clip. Keep the longest title in the table honest.
local OVL_TITLES = { Pwr = "MAIN POWER LOST", Volt = "BATTERY CRITICAL", Telem = "TELEMETRY LOST",
                     Note = "TELEMETRY RATE MISMATCH" }

-- ============================================================================
-- ELRS LINK CONFIGURATION VERDICT
-- ============================================================================
-- What the TX module is actually configured to, held against what the flight
-- controller was TOLD the link carries. It lives here rather than in the ELRS
-- Status page because the notice overlay needs it in the 5 Hz pass with no menu
-- module loaded -- and because one copy is the only way the page and the overlay
-- cannot drift apart.
--
-- THE COMPARISON IS THE TELEMETRY SLOT RATE, NOT THE TWO NUMBERS.
-- Rotorflight fills a token bucket at `rate / (ratio * 1e6)` slots per us
-- (telemetry/crsf.c:1393) and spends `(bytes+9)/5` slots per frame (:118-126), so
-- ONLY the quotient rate/ratio ever reaches the wire. ExpressLRS sizes its own
-- telemetry bandwidth the same way (`hz / ratiodiv`, TXModuleParameters.cpp). A
-- module on 500 Hz 1:16 against an FC told 250 / 1:8 is therefore CORRECT, and
-- comparing the two pairs for equality -- which is what the ELRS Status page did
-- until 0.8.0 -- reports it as a mismatch. Cross-multiplied here, so the test stays
-- integer-exact and needs no float tolerance.

--- ELRS packet-rate option name -> packets per second ON THE LINK.
--- NOT the number in the name. The DVDA rates repeat every packet 2-4x and keep the
--- fast send interval, so their link rate is 1/interval -- which is exactly what
--- ELRS itself uses to size the telemetry ratio (`hz = 1000000 / interval`). From
--- the rate table in ExpressLRS `src/src/common.cpp` (field `interval`, in us):
---   D500   interval 1000 us, 2x sends -> 1000 Hz   (the name says  500)
---   D250   interval 1000 us, 4x sends -> 1000 Hz   (the name says  250)
---   D50Hz  interval 5000 us, 4x sends ->  200 Hz   (the name says   50; 900 MHz)
--- Everything else carries its real rate in the name ("150Hz", "333Hz Full",
--- "F500", "F1000"). An UNKNOWN name yields nil -> no verdict at all, which is the
--- honest answer: a guessed rate would send the pilot off to change a setting that
--- was right.
local ELRS_DVDA_HZ = { ["D250"] = 1000, ["D500"] = 1000, ["D50Hz"] = 200 }

--- "150Hz(-112dBm)" -> 150 . "D500(-104dBm)" -> 1000 . "F1000(-104dBm)" -> 1000.
function ultidash_functions.elrs_rate_hz(s)
    if type(s) ~= "string" then return nil end
    -- The DVDA names go first: "D50Hz" also matches the generic Hz pattern below and
    -- would come out as 50, where the link actually runs at 200.
    local head = string.match(s, "^([%a%d]+)")
    if head == nil then return nil end
    if ELRS_DVDA_HZ[head] ~= nil then return ELRS_DVDA_HZ[head] end
    if string.match(head, "^D%d") then return nil end       -- an unknown DVDA rate: no guess
    local f = tonumber(string.match(s, "^F(%d+)"))           -- FLRC, "F500" / "F1000"
    if f ~= nil then return f end
    return tonumber(string.match(s, "(%d+)%s*[Hh][Zz]"))
end

--- "1:32" -> 32. "Std", "Race", "Dynamic" carry no fixed ratio -> nil, no verdict.
--- "Off" is not a ratio either, but it IS a finding -- see elrs_link_verdict.
function ultidash_functions.elrs_tlm_ratio(s)
    if type(s) ~= "string" then return nil end
    return tonumber(string.match(s, "^1:(%d+)"))
end

--- The verdict, or nil when either side is unknown (no scan yet, an unparsable rate
--- name, a dynamic telemetry ratio). Never guesses.
--- Returns { off = true }                                  -- telemetry ratio is Off
---      or { ok = bool, hz_m, rt_m, hz_f, rt_f, factor }
--- `factor` = the FC's slot rate over the module's: > 1 means the FC paces FASTER
--- than the link carries (frames back up, values read stale), < 1 that it paces
--- slower than the link would allow.
function ultidash_functions.elrs_link_verdict(wgt)
    local v = wgt.values
    if v == nil then return nil end
    -- Telem Ratio = Off takes the whole dashboard out, whatever the FC was told.
    -- Reported on its own rather than folded into the rate comparison.
    if type(v.elrs_cfg_tlm) == "string" and string.match(v.elrs_cfg_tlm, "^[Oo]ff") then
        return { off = true }
    end
    local hz_m = ultidash_functions.elrs_rate_hz(v.elrs_cfg_rate)
    local rt_m = ultidash_functions.elrs_tlm_ratio(v.elrs_cfg_tlm)
    local hz_f, rt_f = v.rf_crsf_rate, v.rf_crsf_ratio
    if hz_m == nil or rt_m == nil or hz_f == nil or rt_f == nil then return nil end
    if hz_m <= 0 or rt_m <= 0 or hz_f <= 0 or rt_f <= 0 then return nil end
    -- slot rate is hz/rt on each side; cross-multiplied so the test is integer-exact
    local ok = (hz_f * rt_m) == (hz_m * rt_f)
    return { ok = ok, hz_m = hz_m, rt_m = rt_m, hz_f = hz_f, rt_f = rt_f,
             factor = (hz_f / rt_f) / (hz_m / rt_m) }
end

--- Turn the verdict into the notice the overlay shows -- or clear it. Cheap enough
--- for the 5 Hz pass because it only RECOMPUTES when one of the four inputs moved;
--- every other pass is four table reads and four comparisons.
--- Clearing is also what makes "once per connect" free: ultidashElrs wipes its
--- values when a scan starts, the verdict goes nil, the episode machine resets, and
--- the next scan that still finds a mismatch opens a NEW episode.
function ultidash_functions.update_elrs_notice(wgt)
    local v = wgt.values
    if v == nil then return end
    local c = wgt.ovl_note_cache
    if c ~= nil and c.a == v.elrs_cfg_rate and c.b == v.elrs_cfg_tlm
        and c.c == v.rf_crsf_rate and c.d == v.rf_crsf_ratio then return end
    if c == nil then c = {}; wgt.ovl_note_cache = c end
    c.a, c.b, c.c, c.d = v.elrs_cfg_rate, v.elrs_cfg_tlm, v.rf_crsf_rate, v.rf_crsf_ratio
    local r = ultidash_functions.elrs_link_verdict(wgt)
    if r == nil or r.ok then
        wgt.ovl_note = nil
        return
    end
    if r.off then
        wgt.ovl_note = {
            title = "TELEMETRY IS OFF",
            body  = "Module telem ratio:  Off",
            hint  = "The module sends no telemetry slots at all -\n"
                 .. "every value on this dashboard stays blank.\n"
                 .. "Set Telem Ratio on the ELRS module.",
        }
        return
    end
    -- "4.0x slower" reads better than a raw quotient, and the DIRECTION is the part a
    -- pilot can act on: too fast = a backlog of stale frames, too slow = bandwidth
    -- the link has and the FC never uses.
    local f = r.factor
    local dir
    if f > 1 then
        dir = string.format("FC paces %.1fx FASTER than the link carries -\nframes back up, values read stale.", f)
    else
        dir = string.format("FC paces %.1fx SLOWER than the link allows -\ntelemetry is sluggish for no reason.", 1 / f)
    end
    wgt.ovl_note = {
        title = "TELEMETRY RATE MISMATCH",
        body  = string.format("Radio sends  %d Hz  1:%d\nFC expects   %d Hz  1:%d",
                              r.hz_m, r.rt_m, r.hz_f, r.rt_f),
        hint  = dir .. string.format("\nSet on the FC:  link_rate %d   link_ratio %d", r.hz_m, r.rt_m),
    }
end

-- ============================================================================
-- TWO MSP STACKS ON ONE RADIO
-- ============================================================================
--- The MSP-conflict notice. It runs AFTER update_elrs_notice and OVERRIDES it, which is
--- the whole reason it is a second function and not a branch inside the first: two MSP
--- stacks fighting over the one CRSF TX slot make every telemetry-timing reading suspect,
--- so a rate mismatch reported on top of it would send the pilot after the wrong setting.
--- While the conflict stands the ELRS notice is suppressed, and it comes back with it.
--- The VERDICT is not computed here. ultidashRf.background already reads both globals on
--- every pass and owns the false-positive guard -- our own Toolbox door leaves exactly the
--- traces a foreign RFSuite does -- so this function only presents what it decided.
--- Cost on a correctly set up radio, which is every pass on every card that has no
--- conflict: two table reads and a return. The message is built once and cached on wgt.
function ultidash_functions.update_msp_conflict(wgt)
    if not (wgt.rf ~= nil and wgt.rf.msp_conflict) then return end
    local n = wgt.ovl_note_conflict
    if n == nil then
        n = {
            -- The title length is not free: add_alert_overlay picks the title font so the
            -- LONGEST entry of OVL_TITLES fits the box, and anything longer than that
            -- clips. This one is shorter, so the fitting string stays where it was.
            title = "TWO MSP TOOLS ACTIVE",
            body  = "RF Tool and RFSuite are\nboth loaded on this radio.",
            hint  = "They share one CRSF telemetry slot\nand will fight over it. Remove one\n"
                 .. "of the two widgets from the screens.",
        }
        wgt.ovl_note_conflict = n
    end
    wgt.ovl_note = n
end

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
    elseif o.NoteOvl ~= 0 and wgt.ovl_note ~= nil and not wgt.armed_now then
        -- The NOTICE slot, deliberately last: the three above are armed, in-flight
        -- safety conditions and must never be pushed aside by a configuration
        -- message. DISARMED ONLY -- a config notice has no business over a flight
        -- screen, and the thing it reports can only be acted on with the blades
        -- stopped anyway. `armed_now` is set one pass (200 ms) after this runs, so
        -- the notice survives arming by that much and no longer; the alternative is
        -- a second is_armed() sensor lookup per pass for no safety gain.
        -- Read as `~= 0` so a cfg written before this key existed (nil) still shows
        -- it rather than silently losing the feature.
        code = "Note"
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
    -- title font: the largest that fits the longest title in the box width. Measured
    -- over OVL_TITLES rather than against one hard-coded string -- the notice slot
    -- added a longer title than "MAIN POWER LOST", and a literal here would have gone
    -- on fitting the box to a title that is no longer the widest.
    local longest = ""
    for _, t in pairs(OVL_TITLES) do
        if #t > #longest then longest = t end
    end
    local title_font, tfh = SMLSIZE, select(2, lcd.sizeText("Ag", SMLSIZE))
    for _, f in ipairs({ DBLSIZE, MIDSIZE, 0, SMLSIZE }) do
        if lcd.sizeText(longest, f) <= bw - 16 then
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
        if c == "Note" then
            local n = wgt.ovl_note
            return (n and n.title) or OVL_TITLES.Note
        end
        return c and OVL_TITLES[c] or ""
    end
    local value = function()
        -- live value line: Pwr = the buffer/BEC voltage, Volt = the cell voltage;
        -- memoized so the format runs only when the reading changes.
        -- Note = the notice's own body, already formatted (and possibly two lines) by
        -- whoever set wgt.ovl_note -- no per-frame work at all.
        local code = wgt.ovl_active
        if code == "Note" then
            local n = wgt.ovl_note
            return (n and n.body) or ""
        end
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
    -- The explanatory line under the value: what the message MEANS and what to do
    -- about it. Empty for the three alert codes -- an empty label draws nothing, so
    -- their box is unchanged. Notices are the reason it exists: a mismatch a pilot
    -- cannot interpret is not a warning, it is a puzzle.
    local hint = function()
        if wgt.ovl_active ~= "Note" then return "" end
        local n = wgt.ovl_note
        return (n and n.hint) or ""
    end
    -- The close control: an X in the box's top-right corner, and SINCE 0.8.0 the only
    -- way this box closes by touch. The tap-anywhere that used to dismiss it is gone --
    -- it was invisible, and on a message the pilot is meant to read and act on, every
    -- mis-tap threw it away before it had been read. Same reasoning, and the same
    -- glyph, as the detail pages (host `close_button`, 0.8.0). Built inline rather
    -- than through `close_control` because every element in this box carries the
    -- overlay's `visible` closure -- a statically built X would stand on the dashboard
    -- with nothing behind it. The auto-close (`OvlClose`) is untouched.
    local xsz = sfh + 8
    local xx, xy = bx + bw - 8 - xsz, by + 6
    -- generous on purpose, exactly as on the detail pages: the glyph is small and the
    -- corner is the one place in the box nothing else can be hit
    wgt.ovl_close_rect = { x = xx - 8, y = xy - 6, w = xsz + 16, h = xsz + 12 }
    -- Vertical layout, computed once at build time and from the BOTTOM up, because
    -- that is the edge the box cannot grow past. The value block is two lines and the
    -- hint four, so on the smallest zone (480x272 -> a 217 px box) the old 8%-of-box
    -- gap under the title no longer fits; it is kept where there IS room and squeezed
    -- to 4 px where there is not. The old "tap to dismiss" line is gone with the
    -- behaviour it described, and the hint inherited its space.
    -- The layout sweep checks this box for overflow at all three sizes.
    local hy = by + bh - 6 - 4 * sfh             -- hint block, four lines, to the bottom
    local gap = math.min(math.floor(bh * 0.08), math.max(4, hy - 4 - (ty + tfh) - 2 * vfh))
    local vy = ty + tfh + gap                    -- value block, two lines
    panel:build({
        { type = "rectangle", x = bx, y = by, w = bw, h = bh, filled = true, rounded = 8,
          color = lcd.RGB(190, 16, 16), visible = vis },
        { type = "rectangle", x = bx, y = by, w = bw, h = bh, thickness = 3, rounded = 8,
          color = white, visible = vis },
        { type = "label", x = bx + 8, y = ty, w = bw - 16, h = tfh, font = title_font,
          align = CENTER, color = white, text = title, visible = vis },
        { type = "label", x = bx + 8, y = vy, w = bw - 16, h = 2 * vfh,
          font = MIDSIZE, align = CENTER, color = white, text = value, visible = vis },
        { type = "label", x = bx + 8, y = hy, w = bw - 16, h = 4 * sfh,
          font = SMLSIZE, align = CENTER, color = white, text = hint, visible = vis },
        -- the close control, last so it sits over the box: a plain capital X, because
        -- the EdgeTX fonts carry no cross glyph (the same gap the status log's scroll
        -- arrows work around)
        { type = "rectangle", x = xx, y = xy, w = xsz, h = xsz, thickness = 1, rounded = 4,
          color = white, visible = vis },
        { type = "label", x = xx, y = xy + math.floor((xsz - sfh) / 2), w = xsz, h = sfh + 2,
          font = SMLSIZE, align = CENTER, color = white, text = "X", visible = vis },
    })
end

-- Dev perf overlay: a small always-on-top strip with the live UI-loop Hz + Lua/free
-- heap (the same metrics as the Status footer), shown on EVERY view while the DebugLog
-- option is on. Built as a TOP-LEVEL object created AFTER the view builders in update()
-- so it stacks over whatever view is active. The text is memoized on the ~1 Hz-sampled
-- metrics -> ~zero per-frame garbage (a perf tool must not itself add GC load).
-- Non-clickable primitives -> steals no touch.
function ultidash_functions.add_perf_overlay(wgt, w, h)
    if not (wgt.options and wgt.options.DebugLog == 1) then return end
    -- ...and the on-screen half has its own switch (`DbgOvl`, default on). The log and the
    -- strip used to be one setting, so a session that wanted the FILE -- a flight, a
    -- screenshot for a report, anything somebody else will look at -- also got the strip
    -- sitting over the layout. Read as `== 0` rather than `~= 1` so a cfg written before this
    -- key existed (nil) keeps the old behaviour rather than losing the overlay silently.
    if wgt.options.DbgOvl == 0 then return end
    local _, sfh = lcd.sizeText("Ag", SMLSIZE)
    local oh = sfh + 4
    -- worst-case width so a long free-heap value never clips. Compact labels:
    -- L = Lua heap (used), F = free heap, both kB.
    local ow = math.min(w, lcd.sizeText("UI 999Hz  L99999k  F999999k", SMLSIZE) + 10)
    local last_hz, last_kb, last_fk, last_s
    local txt = function()
        local hz, kb, fk = wgt.dbg_hz, wgt.dbg_lua_kb, wgt.dbg_free_kb
        -- `last_s == nil` comes FIRST, and it is not belt-and-braces. On the very first
        -- build no perf sample has been taken yet: the three dbg_* fields are assigned in
        -- refresh()'s 1 Hz block (ultidash.lua:5842-5852), so hz/kb/fk are all nil, all
        -- three comparisons are `nil ~= nil` = false, the body never runs and last_s stays
        -- nil. The label below then receives nil as its text and refresh() raises
        -- "bad argument #2 to 'label' (string expected, got nil)" on the first UI build,
        -- taking every pass under it with it: the screen never moves again, no callout is
        -- played, and the debug log keeps its session header for ever.
        -- It can only happen when the overlay is built BEFORE the first sample, i.e. when
        -- DebugLog was ALREADY 1 when the widget started (a stored setting). Toggling it
        -- in the menu never reaches that state -- a pass has run by then and the three
        -- fields are numbers -- which is why it survived so long.
        -- The `or "-"` fallbacks below were written for exactly this case and are
        -- unreachable without this term.
        if last_s == nil or hz ~= last_hz or kb ~= last_kb or fk ~= last_fk then
            last_hz, last_kb, last_fk = hz, kb, fk
            last_s = "UI " .. (hz or "-") .. "Hz  L" .. (kb or "-")
                .. "k  F" .. (fk or "-") .. "k"
        end
        return last_s
    end
    -- Anchored BOTTOM-LEFT. Not top-left: that is the menu glyph / the host's fallback
    -- menu tap region, and covering it hides the only way back into the settings (i.e.
    -- the only way to switch this overlay off again). Not top-right either: the Log
    -- Viewer's zoom/pan buttons live there.
    local p = lvgl.rectangle({ x = 0, y = math.max(0, h - oh), w = ow, h = oh,
        filled = true, color = lcd.RGB(0, 0, 0) })
    p:label({ x = 4, y = 2, w = ow - 8, h = sfh, font = SMLSIZE,
        color = lcd.RGB(0, 255, 128), text = txt })
end

--- Draw the page-close control: a small bordered "X", right-aligned to `right_x` and
--- starting at `top_y`. Returns its left edge and its side length, so the caller can
--- both keep its own content clear of it and build the tap rect.
---
--- DRAWN, not an lvgl.button, and the reason is the same one the detail pages carry
--- in their own comments: a focusable object on a full-screen page captures
--- PAGE/RTN/TELE, so the page can no longer be left with the keys. The tap is
--- hit-tested in refresh() against wgt.close_rect, exactly like the status log's
--- scroll arrows and the menu glyph. The CALLER sets that rect: only it knows the
--- container's own origin, and both call sites deliberately make the rect larger
--- than the glyph (the same trick settings_icon_rect uses for the menu bars).
--- `band_h`, when given, is the height of the row it has to fit into: the control is
--- clamped to it and centred in it (the top bar is 20 px on a 480x272 MK2 and 34 on
--- the MK3, so a size derived from the font alone does not fit both).
function ultidash_functions.close_control(container, right_x, top_y, col_border, col_ink, band_h)
    local _, gh = lcd.sizeText("Ag", SMLSIZE)
    local sz = gh + 8
    local y = top_y
    if band_h ~= nil then
        if band_h < sz then sz = band_h end
        y = top_y + math.floor((band_h - sz) / 2)
    end
    local x = right_x - sz
    -- No panel to draw into: a skin's detail-page hook returns none (docs/SKINS.md D3),
    -- so the host's guarantee has to become its own top-level object -- the same shape
    -- the "skin page failed" banner uses, and for the same reason.
    if container == nil then
        local box = lvgl.rectangle({ x = x, y = y, w = sz, h = sz, thickness = 1,
                                     rounded = 4, color = col_border })
        box:label({ x = 0, y = math.floor((sz - gh) / 2), w = sz, h = gh + 2, text = "X",
                    font = SMLSIZE, color = col_ink, align = CENTER })
        return x, sz
    end
    local els = {}
    -- A border that would cut into the glyph is worse than no border, so below that
    -- size the X stands on its own -- which is the MK2's top bar. The tap rect is the
    -- affordance either way, and it is the caller's, not this box.
    if sz >= gh + 2 then
        els[1] = { type = "rectangle", x = x, y = y, w = sz, h = sz, thickness = 1, rounded = 4, color = col_border }
    end
    -- a plain capital X: the EdgeTX fonts carry no multiplication/cross glyph, the
    -- same gap that made the status log's scroll arrows stacked rectangles
    els[#els + 1] = { type = "label", x = x, y = y + math.floor((sz - gh) / 2), w = sz, h = gh + 2,
                      text = "X", font = SMLSIZE, color = col_ink, align = CENTER }
    container:build(els)
    return x, sz
end

--- A FOCUS STOP on a read-only lvgl.page: the encoder's only route across it.
---
--- The rotary is not an EVENT for a useLvgl widget and never can be. It is an
--- LV_INDEV_TYPE_ENCODER feeding the LVGL focus group, and the editing mode that would
--- translate it into EVT_ROTARY_* is denied to us by LuaWidget::enableFullScreenRE() =
--- !useLvglLayout(). Such a page therefore reacts to the encoder ONLY through focusable
--- objects, and only as focus movement -- which LVGL turns into scrolling by pulling the
--- focused control into view (LV_OBJ_FLAG_SCROLL_ON_FOCUS sits on the CONTROL, never on
--- the page body). A page built from pg:label alone is encoder-dead: measured on the ELRS
--- Status page, eight detents produced a byte-identical picture.
---
--- Hence stops -- ONE PER SECTION HEAD, plus one on the page's closing note. Three things
--- shaped that:
---   * It has to be a `type="button"`. That is the only focusable object the Lua LVGL API
---     offers that carries no value to edit, and its press is a NO-OP -- the sibling
---     strip's own cell is the precedent that already does exactly that.
---   * A button is always theme-painted: border and rounding come from etx_btn_style and
---     there is no parameter to turn either off. So the section head becomes a BAR, and
---     the text keeps its left alignment by riding in a CHILD label -- a button centres
---     its own `text` and takes no `align`. The child is neither focusable nor clickable,
---     so the encoder still sees exactly one control per stop.
---   * The CLOSING NOTE carries the last stop, and that is not decoration. LVGL scrolls
---     the minimum distance, so walking DOWN lands a control on the BOTTOM edge of the
---     viewport: a stop at a section head reveals what is ABOVE it, not the rows below
---     it. Stop k brings section k-1 into view, and without a stop past the LAST section
---     that section's rows stay under the fold -- which on the ELRS Status page is the
---     whole "Flight controller expects" block the 0.8.0 rework is about.
---
--- Child x/y are CONTENT-relative: EdgeTX's border+padding inset is already taken off and
--- cannot be switched off, so the bar is sized from the text outwards. Returns the height
--- the bar occupies, so the caller's row cursor stays free of that arithmetic.
---
--- `zw` is the ZONE width, not the bar's: the bar always spans 10 .. zw - 20 (the sibling
--- strip's box, clear of the scrollbar) and the inset is keyed on the same number. Taking
--- the zone rather than reading LCD_W is not cosmetic -- nothing in this widget keys layout
--- on that global, and the budget harness does not define it.
---
--- Returns the ELEMENT and its height. Pages that emit as they go take focus_stop below;
--- a page that collects into one `elems` table (the sensor check) appends this instead, so
--- its rows keep their single pg:build. `text` may be a function -- it rides in an ordinary
--- label, so a reactive closure works exactly as it does anywhere else.
--- `wrap` = the text is longer than one line and has to be MEASURED (the sensor check's
--- legend). The measurement belongs here rather than in the caller, because it has to run
--- against the CHILD's width -- the bar minus the inset -- which is this function's own
--- arithmetic and nothing the caller can see.
function ultidash_functions.focus_stop_elem(y, zw, text, font, color, wrap)
    -- the button's own inset, per side: 10/5 px at zone width 800, 8/4 at 480. Keyed on
    -- WIDTH, the way LAYOUT_SCALE and the sibling strip's cells already are.
    local ins_x = (zw >= 800) and 10 or 8
    local ins_y = (zw >= 800) and 5 or 4
    local _, th = lcd.sizeText("Ag", font or 0)
    local w = math.max(2 * ins_x + 2, zw - 30)
    local cw = math.max(1, w - 2 * ins_x)
    local lines = 1
    if wrap and type(text) == "string" then
        -- 0.90 because LVGL breaks on word boundaries: a line rarely fills to its last
        -- pixel, so the raw division under-counts. Same correction build_status_view's
        -- `grow` rows make, for the same reason.
        lines = math.max(1, math.ceil(lcd.sizeText(text, font or 0) / (cw * 0.90)))
    end
    local ch = lines * th + 2
    local h = ch + 2 * ins_y
    return { type = "button", x = 10, y = y, w = w, h = h,
             press = function() end,
             children = { { type = "label", x = 0, y = 0, w = cw, h = ch,
                            text = text, font = font, color = color, align = LEFT } } }, h
end

--- The same stop, emitted straight onto the page. Returns its height.
function ultidash_functions.focus_stop(pg, y, zw, text, font, color, wrap)
    local e, h = ultidash_functions.focus_stop_elem(y, zw, text, font, color, wrap)
    pg:build({ e })
    return h
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
    ultidash_functions.update_telemetry_report(wgt)
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
    ultidash_functions.update_telemetry_report(wgt)
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


-- Deferred module data (host stage 2a0): the reference tables above are declared as
-- empty shells and filled here, in the staged cycle's budget instead of the module
-- level's -- module load runs inside create()'s ~20k together with four other chunks.
-- Everything here is module-LOCAL (nothing captures a reference before the stage gates
-- run; set_palette mutates ESC_LEVEL_COLORS only from the apply stage onward, which is
-- strictly after this). Self-clearing: runs exactly once per session.
function ultidash_functions.deferred_init()
    -- the ESC module's load lands HERE on a cold start (this stage runs before the first
    -- palette apply), i.e. in this staged cycle's budget rather than in create()'s
    local e = get_esc()
    ESC_LEVEL_COLORS = {
        [e.LEVEL_TRACE] = COLOR_THEME_DISABLED,
        [e.LEVEL_INFO]  = COLOR_THEME_PRIMARY1,
        [e.LEVEL_WARN]  = BAR_COLOR_LOW,
        [e.LEVEL_ERROR] = BAR_COLOR_CRITICAL,
    }
    ARM_DISABLE_DESCS = {
        "NOGYRO", "FAILSAFE", "RXLOSS", "BADRX", "BOXFAILSAFE", "GOVERNOR", "RPM_SIGNAL",
        "THROTTLE", "ANGLE", "BOOTGRACE", "NOPREARM", "LOAD", "CALIB", "CLI", "CMS",
        "BST", "MSP", "PARALYZE", "GPS", "RESCUE_SW", "RPMFILTER", "REBOOT_REQD",
        "DSHOT_BBANG", "NO_ACC_CAL", "MOTOR_PROTO", "ARMSWITCH",
    }
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
    RFMD_INFO = {
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
    SWITCH_VOICES = {
        { key = "MotorSrc",   on = "motor_on",  off = "motor_off" },
        { key = "RescueSrc",  on = "rescue_on", off = "rescue_off" },
        { key = "GovSrc",     on = "gov_on",    off = "gov_off" },
        { key = "ProfileSrc", profile = true },
    }
    GOV_VOICE_FILES = {
        [0] = "gs_thoff",   [1] = "gs_idle",    [2] = "gs_spool",
        [3] = "gs_recov",   [4] = "gs_active",  [5] = "gs_hold",
        [6] = "gs_fallbk",  [7] = "gs_autorot", [8] = "gs_bailout",
        [9] = "gs_bypass",
    }
    GOV_VOICE_KEYS = {
        [0] = "GvsOff",   [1] = "GvsIdle",    [2] = "GvsSpool",
        [3] = "GvsRecov", [4] = "GvsActive",  [5] = "GvsHold",
        [6] = "GvsFallbk",[7] = "GvsAutorot", [8] = "GvsBailout",
        [9] = "GvsBypass",
    }
    ultidash_functions.deferred_init = nil
end

return ultidash_functions
