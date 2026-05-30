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
M.SIG_FLY      = 0x73
M.SIG_RESTART  = 0xFF

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

local ygeState = {
    [0x00] = "OK",
    [0x01] = "Shutdown",
    [0x02] = "Bailout",
    [0x08] = "Starting",
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

-- OMP / OFW -----------------------------------------------------------------
local function ompGetStatus(code)
    local text = "OMP ESC OK"
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
            elseif bit == 12 then text = "ESC Battery Voltage"; level = M.LEVEL_ERROR; break
            end
        end
    end
    return { text = text, level = level }
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
        return ompGetStatus(code)
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
