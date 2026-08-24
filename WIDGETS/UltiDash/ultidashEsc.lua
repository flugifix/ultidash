-- Multi-vendor ESC status/fault decoder, ported from eStatus (Rob 'bob00' Gayle).
-- Returns { text, level } for a given ESC signature + status code.

local M = {}

M.LEVEL_TRACE = 0
M.LEVEL_INFO  = 1
M.LEVEL_WARN  = 2
M.LEVEL_ERROR = 3

-- ESC signatures (from the Esc# / EscModel sensor)
M.SIG_NONE     = 0x00
M.SIG_BLHELI32 = 0xC8
M.SIG_HW4      = 0x9B
M.SIG_KON      = 0x4B
M.SIG_OMP      = 0xD0
M.SIG_ZTW      = 0xDD
M.SIG_APD      = 0xA0
M.SIG_PL5      = 0xFD
M.SIG_TRIB     = 0x53
M.SIG_OPENYGE  = 0xA5
M.SIG_XDFLY    = 0xA6
M.SIG_FLY      = 0x73
M.SIG_GRAUPNER = 0xC0
M.SIG_RESTART  = 0xFF

-- Highest-severity-wins scan over a status word. `name(bit)` returns (text, level)
-- for a set bit or nil for one that carries no fault -- a state flag (APD "motor
-- started", KON "programming permitted") must not read as a problem. Ties keep the
-- LOWEST bit, so a family's own bit order decides between two faults of equal rank.
-- The four decoders ported from eStatus keep their own loops: their being unchanged
-- is what makes them still comparable with the upstream they came from.
local function scan_bits(code, nbits, name, ok_text)
    local text, level = ok_text, M.LEVEL_INFO
    for b = 0, nbits - 1 do
        if bit32.band(code, bit32.lshift(1, b)) ~= 0 then
            local t, lv = name(b)
            if t ~= nil and lv > level then text, level = t, lv end
        end
    end
    return { text = text, level = level }
end

local YGE_SPN_IGNORE_MAX = 32
local ygeSpnEvents = 0

-- YGE / OpenYGE -------------------------------------------------------------
local STATE_MASK          = 0x0F
local STATE_POWER_CUT     = 0x01
local STATE_STARTING      = 0x08
local EVENT_MASK          = 0x70
local WARN_DEVICE_MASK    = 0xC0
local WARN_DEVICE_BEC     = 0x80
local WARN_OK             = 0x00
local WARN_UNDERVOLTAGE   = 0x10
local WARN_OVERTEMP       = 0x20
local WARN_OVERAMP        = 0x40
local WARN_SETPOINT_NOISE = 0xC0

-- The sixteen motor states of status1's low nibble (esc_sensor.c, "Motor states").
-- The four BRAKEING_* states used to fall through as "Code x06"/"x09" -- they are
-- ordinary running states on a helicopter (autorotation bailout, brake on shutdown),
-- so a raw code there looked like a fault that was not one. _FINI = the brake has
-- finished; the reserved states stay absent on purpose, so a firmware that starts
-- sending one still shows its code rather than a name we invented.
local ygeState = {
    [0x00] = "OK",
    [0x01] = "Shutdown",
    [0x02] = "Bailout",
    [0x04] = "Positioning",
    [0x06] = "Brake End",
    [0x07] = "Brake End",
    [0x08] = "Starting",
    [0x09] = "Braking",
    [0x0A] = "Braking",
    [0x0C] = "Idle",
    [0x0E] = "Running",
}

local ygeEvent = {
    [WARN_UNDERVOLTAGE] = "Under Voltage",
    [WARN_OVERTEMP]     = "Over Temp",
    [WARN_OVERAMP]      = "Current Limit",
}

local function ygeGetStatus(code, changed)
    local text, level
    local scode = bit32.band(code, 0xFF)
    local dev = bit32.band(scode, WARN_DEVICE_MASK)
    local state = bit32.band(scode, STATE_MASK)
    if scode == 0 then
        text = "YGE ESC OK"
        level = M.LEVEL_INFO
    elseif dev == WARN_SETPOINT_NOISE then
        text = "ESC Setpoint Noise"
        if changed then
            ygeSpnEvents = ygeSpnEvents + 1
        end
        level = (state == STATE_POWER_CUT and M.LEVEL_ERROR) or
                (ygeSpnEvents < YGE_SPN_IGNORE_MAX and M.LEVEL_TRACE) or
                M.LEVEL_WARN
    else
        if dev == WARN_DEVICE_BEC then
            text = "BEC "
        else
            text = "ESC "
        end

        local stateText = ygeState[state] or string.format("Code x%02X", state)

        local event = bit32.band(scode, EVENT_MASK)
        if event == WARN_OK then
            if state == STATE_POWER_CUT then
                text = text .. "Over Voltage"
                level = M.LEVEL_ERROR
            else
                text = text .. stateText
                level = M.LEVEL_INFO
            end
        else
            text = text .. (ygeEvent[event] or "** unexpected **")
            if event == WARN_UNDERVOLTAGE then
                level = state < STATE_STARTING and M.LEVEL_ERROR or M.LEVEL_WARN
            else
                level = state == STATE_POWER_CUT and M.LEVEL_ERROR or M.LEVEL_WARN
            end
        end
    end
    text = (level == M.LEVEL_ERROR) and string.upper(text) or text
    return { text = text, level = level }
end

-- Scorpion / Tribunus -------------------------------------------------------
-- Bit 7 (throttle error) was MISSING: the firmware documents it (esc_sensor.c,
-- "Error Code bits"), the loop already walked as far as 7, and with no branch for
-- it a throttle error read out as "Scorpion ESC OK" -- a fault reported as health.
-- Bits 0 and 6 are the two the firmware itself marks N/A.
local function tribGetStatus(code)
    local text = "Scorpion ESC OK"
    local level = M.LEVEL_INFO
    for bit = 0, 7 do
        if bit32.band(code, bit32.lshift(1, bit)) ~= 0 then
            local fault = nil
            if bit == 1 then fault = "BEC Voltage"
            elseif bit == 2 then fault = "ESC Temperature"
            elseif bit == 3 then fault = "ESC Consumption"
            elseif bit == 4 then fault = "ESC Voltage"
            elseif bit == 5 then fault = "ESC Current"
            elseif bit == 7 then fault = "ESC Throttle"
            end
            if fault then
                text = fault
                level = M.LEVEL_ERROR
            end
        end
    end
    return { text = text, level = level }
end

-- HobbyWing HW5 / Platinum --------------------------------------------------
local function pl5GetStatus(code)
    local text = "HobbyWing ESC OK"
    local level = M.LEVEL_INFO
    for bit = 0, 7 do
        if bit32.band(code, bit32.lshift(1, bit)) ~= 0 then
            local fault = nil
            if bit == 0 then fault = "ESC Motor Locked"
            elseif bit == 1 then fault = "ESC Over Temp"
            elseif bit == 2 then fault = "ESC Throttle Error"
            elseif bit == 3 then fault = "ESC Throttle Signal"
            elseif bit == 4 then fault = "ESC Over Current"
            elseif bit == 5 then fault = "ESC Low Voltage"
            elseif bit == 6 then fault = "ESC Input Voltage"
            elseif bit == 7 then fault = "ESC Motor Connection"
            end
            if fault then
                text = fault
                level = M.LEVEL_ERROR
            end
        end
    end
    return { text = text, level = level }
end

-- FLYROTOR ------------------------------------------------------------------
local function flyGetStatus(code)
    local text = "FLYROTOR ESC OK"
    local level = M.LEVEL_INFO
    for bit = 0, 7 do
        if bit32.band(code, bit32.lshift(1, bit)) ~= 0 then
            if bit == 0 then text = "ESC Over Temp"; level = M.LEVEL_ERROR; break
            elseif bit == 1 then text = "ESC Low Voltage"; level = M.LEVEL_ERROR; break
            elseif bit == 2 then text = "ESC Overcurrent"; level = M.LEVEL_ERROR; break
            elseif bit == 3 then text = "ESC Short Circuit"; level = M.LEVEL_ERROR; break
            elseif bit == 4 then text = "ESC Throttle Signal"; level = M.LEVEL_WARN; break
            elseif bit == 7 then text = "ESC Fan Status"; level = M.LEVEL_INFO; break
            end
        end
    end
    return { text = text, level = level }
end

-- OMP / OFW, ZTW and XDFly --------------------------------------------------
-- ONE decoder for three signatures, because 4.6.0 made them one protocol: the
-- frame is 0xDD 0x01 0x20 with the status word at buffer[13..14] and only the sync
-- byte differs (xdfly_sync_header -- 0xA4 OMP, 0xA3 ZTW, 0xA5 XDFly). Bits 0-8 and
-- 12 are OMP's published map; 9-11 are ZTW's three extra throttle bits. XDFly
-- publishes no map of its own -- that it shares this one is INFERRED from the
-- shared frame and the shared firmware decoder, which is why the brand name is a
-- parameter: a wrong text says which ESC it came from.
local function ompGetStatus(code, brand)
    local text = (brand or "OMP") .. " ESC OK"
    local level = M.LEVEL_INFO
    for bit = 0, 12 do
        if bit32.band(code, bit32.lshift(1, bit)) ~= 0 then
            if bit == 0 then text = "ESC Short Circuit"; level = M.LEVEL_ERROR; break
            elseif bit == 1 then text = "ESC Motor Connection"; level = M.LEVEL_ERROR; break
            elseif bit == 2 then text = "ESC Throttle Lost"; level = M.LEVEL_WARN; break
            elseif bit == 3 then text = "ESC Throttle Startup"; level = M.LEVEL_ERROR; break
            elseif bit == 4 then text = "ESC Low Voltage"; level = M.LEVEL_ERROR; break
            elseif bit == 5 then text = "ESC Over Temp"; level = M.LEVEL_ERROR; break
            elseif bit == 6 then text = "ESC Startup"; level = M.LEVEL_ERROR; break
            elseif bit == 7 then text = "ESC Overcurrent"; level = M.LEVEL_ERROR; break
            elseif bit == 8 then text = "ESC Throttle Signal"; level = M.LEVEL_WARN; break
            elseif bit == 9 then text = "UART Throttle Error"; level = M.LEVEL_ERROR; break
            elseif bit == 10 then text = "UART Throttle Lost"; level = M.LEVEL_WARN; break
            elseif bit == 11 then text = "CAN Throttle Lost"; level = M.LEVEL_WARN; break
            elseif bit == 12 then text = "ESC Battery Voltage"; level = M.LEVEL_ERROR; break
            end
        end
    end
    return { text = text, level = level }
end

-- Advanced Power Drives ------------------------------------------------------
-- Six flags, esc_sensor.c "Status Flags". Bit 0 is a STATE, not a fault -- it says
-- the motor is started -- and it is deliberately NOT reported: every other bit-flag
-- family here reads "<brand> ESC OK" while running, the arm/throttle state has its
-- own row on the Status page, and putting a running motor into the ESC status line
-- would make the one line that is supposed to mean "something is wrong" say
-- something for the whole flight. Bits 6 and 7 are unused by the protocol.
local function apdBit(bit)
    if bit == 1 then return "ESC Motor Saturation", M.LEVEL_WARN
    elseif bit == 2 then return "ESC Over Temp", M.LEVEL_ERROR
    elseif bit == 3 then return "ESC Over Voltage", M.LEVEL_ERROR
    elseif bit == 4 then return "ESC Low Voltage", M.LEVEL_ERROR
    elseif bit == 5 then return "ESC Startup Error", M.LEVEL_ERROR
    end
end

local function apdGetStatus(code)
    return scan_bits(code, 6, apdBit, "APD ESC OK")
end

-- Graupner --------------------------------------------------------------------
-- Seven flags, esc_sensor.c "Warning flags". The firmware calls all seven
-- warnings; the four that name a hard limit being EXCEEDED are raised to ERROR
-- here, in line with how every other decoder ranks over-temp / over-current /
-- low-voltage. The three "limit" ones stay warnings.
local function graupnerBit(bit)
    if bit == 0 then return "ESC Low Voltage", M.LEVEL_ERROR
    elseif bit == 1 then return "ESC Over Temp", M.LEVEL_ERROR
    elseif bit == 2 then return "Motor Over Temp", M.LEVEL_ERROR
    elseif bit == 3 then return "ESC Over Current", M.LEVEL_ERROR
    elseif bit == 4 then return "ESC RPM Low", M.LEVEL_WARN
    elseif bit == 5 then return "ESC Capacity", M.LEVEL_WARN
    elseif bit == 6 then return "ESC Current Limit", M.LEVEL_WARN
    end
end

local function graupnerGetStatus(code)
    return scan_bits(code, 7, graupnerBit, "Graupner ESC OK")
end

-- Kontronik --------------------------------------------------------------------
-- Twenty-four flags (esc_sensor.c "Error flags", Kontronik Telemetry V4), and the
-- only family whose word does not fit one status line -- hence the severity scan
-- rather than a first-bit-wins loop. The firmware's own wording separates error
-- from warning and that separation is kept: bits 3, 4, 13 and 18-23 are its
-- warnings and limits, the rest are errors. Bit 10 (switched off by rudder) is a
-- deliberate pilot action but worth showing, so it is a warning. Bit 17
-- (programming still permitted) is a state and carries no fault.
local function konBit(bit)
    if bit == 0 then return "Battery Low Voltage", M.LEVEL_ERROR
    elseif bit == 1 then return "Battery Over Voltage", M.LEVEL_ERROR
    elseif bit == 2 then return "ESC Over Current", M.LEVEL_ERROR
    elseif bit == 3 then return "ESC Current Warning", M.LEVEL_WARN
    elseif bit == 4 then return "ESC Temp Warning", M.LEVEL_WARN
    elseif bit == 5 then return "ESC Over Temp", M.LEVEL_ERROR
    elseif bit == 6 then return "BEC Low Voltage", M.LEVEL_ERROR
    elseif bit == 7 then return "BEC Over Voltage", M.LEVEL_ERROR
    elseif bit == 8 then return "BEC Over Current", M.LEVEL_ERROR
    elseif bit == 9 then return "BEC Over Temp", M.LEVEL_ERROR
    elseif bit == 10 then return "ESC Switched Off", M.LEVEL_WARN
    elseif bit == 11 then return "ESC Capacity Limit", M.LEVEL_WARN
    elseif bit == 12 then return "ESC Operation Error", M.LEVEL_ERROR
    elseif bit == 13 then return "ESC Operation Warning", M.LEVEL_WARN
    elseif bit == 14 then return "ESC Self Test Error", M.LEVEL_ERROR
    elseif bit == 15 then return "ESC EEPROM Error", M.LEVEL_ERROR
    elseif bit == 16 then return "ESC Watchdog Error", M.LEVEL_ERROR
    elseif bit == 18 then return "Battery Limit", M.LEVEL_WARN
    elseif bit == 19 then return "ESC Current Limit", M.LEVEL_WARN
    elseif bit == 20 then return "ESC Temp Limit", M.LEVEL_WARN
    elseif bit == 21 then return "BEC Temp Limit", M.LEVEL_WARN
    elseif bit == 22 then return "ESC Current Limit", M.LEVEL_WARN
    elseif bit == 23 then return "ESC Capacity Limit", M.LEVEL_WARN
    end
end

local function konGetStatus(code)
    return scan_bits(code, 24, konBit, "Kontronik ESC OK")
end

-- BLHeli_32 -----------------------------------------------------------------
local function blheli32GetStatus(code)
    local text = "BLHeli_32 ESC OK"
    if code ~= 0 then
        text = string.format("ESC status code (%04X)", code)
    end
    return { text = text, level = M.LEVEL_INFO }
end

-- Unknown / unrecognized ----------------------------------------------------
local function unkGetStatus(code)
    local text = "ESC"
    if code ~= 0 then
        text = string.format("ESC status code (%04X)", code)
    end
    return { text = text, level = M.LEVEL_INFO }
end

--- Decode an ESC status code for the given signature.
-- Returns { text, level } or nil when the signature carries no decodable status.
function M.get_status(sig, code, changed)
    if sig == M.SIG_OPENYGE then
        return ygeGetStatus(code, changed)
    elseif sig == M.SIG_TRIB then
        return tribGetStatus(code)
    elseif sig == M.SIG_PL5 then
        return pl5GetStatus(code)
    elseif sig == M.SIG_FLY then
        return flyGetStatus(code)
    elseif sig == M.SIG_OMP then
        return ompGetStatus(code, "OMP")
    elseif sig == M.SIG_ZTW then
        return ompGetStatus(code, "ZTW")
    elseif sig == M.SIG_XDFLY then
        return ompGetStatus(code, "XDFly")
    elseif sig == M.SIG_APD then
        return apdGetStatus(code)
    elseif sig == M.SIG_GRAUPNER then
        return graupnerGetStatus(code)
    elseif sig == M.SIG_KON then
        return konGetStatus(code)
    elseif sig == M.SIG_BLHELI32 then
        return blheli32GetStatus(code)
    elseif sig ~= M.SIG_NONE and sig ~= M.SIG_RESTART then
        return unkGetStatus(code)
    end
    return nil
end

function M.reset()
    ygeSpnEvents = 0
end

return M
