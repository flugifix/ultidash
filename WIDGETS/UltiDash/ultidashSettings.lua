-- Per-model settings persisted on the SD card.
--
-- EdgeTX gives widgets NO API to write their own options, so values edited via the
-- in-widget settings page live in a file and OVERLAY the EdgeTX options at runtime
-- (file wins for every key it contains; `ViewMode` stays EdgeTX-only because it
-- identifies the placed instance).
--
-- FILE KEYING: the default store is keyed by the model SLOT (model.getInfo().filename,
-- e.g. "model23" — stable forever), NOT by the model name: Rotorflight's "set model
-- name on TX" renames the EdgeTX model to the connected craft's name at runtime,
-- which used to spawn one cfg file per craft unintentionally. The `CfgPerCraft`
-- setting (stored in the slot file itself) opts back into name-keyed files — then
-- each craft flown from this slot keeps its own configuration; the slot file holds
-- the mode flag plus a fallback copy for crafts without their own file yet.
--
-- Files: /WIDGETS/UltiDash/cfg_m_<slot>.cfg (per model slot, default)
--        /WIDGETS/UltiDash/cfg_<model name>.cfg (per craft, optional / legacy)
-- Plain "key=value" lines (all values are integers). Kept in the widget folder on
-- purpose: EdgeTX Lua has no mkdir.
--
-- HARDENING (learned on hardware): ONLY function-style string calls — method style
-- (s:gsub(...)) raises "attempt to index a string value" in the widget Lua state.
-- Every io operation is wrapped in pcall: settings must NEVER take the dashboard
-- down; on failure the layer degrades to EdgeTX options + defaults.
--
-- The module-local state below is shared by ALL instances (one loaded chunk).

local M = {}

local cache = nil
local cache_loaded = false
local per_craft = false        -- CfgPerCraft flag (from the slot file)
local loaded_craft_path = nil  -- which craft file the cache came from (reload check)
local defaults = {}

-- Defaults are handed in by ultidash.lua (derived from the settings-page group
-- tables — the single source of truth; the EdgeTX option list only has ViewMode).
function M.set_defaults(t)
    defaults = t or {}
end

local function sanitize(s)
    return string.gsub(tostring(s or ""), "[^%w%-_]", "_")
end

local function model_info()
    if model ~= nil and type(model.getInfo) == "function" then
        local ok, info = pcall(model.getInfo)
        if ok and type(info) == "table" then return info end
    end
    return nil
end

local function slot_base()
    local info = model_info()
    local base = nil
    if info and type(info.filename) == "string" and info.filename ~= "" then
        base = string.gsub(sanitize(info.filename), "_yml$", "")
    end
    if not base or base == "" then
        base = sanitize(info and info.name or "model")
    end
    return base
end

local function craft_name()
    local info = model_info()
    local name = sanitize(info and info.name or "model")
    if name == "" then name = "model" end
    return name
end

local function slot_path()
    return "/WIDGETS/UltiDash/cfg_m_" .. slot_base() .. ".cfg"
end

-- per-craft files are NAMESPACED by the slot too (cfg_m_<slot>_<craft>.cfg): the
-- same craft flown from two different model slots keeps separate configurations,
-- and the files group visibly per slot on the SD card
local function craft_path()
    return "/WIDGETS/UltiDash/cfg_m_" .. slot_base() .. "_" .. craft_name() .. ".cfg"
end

-- the pre-slot scheme (cfg_<model name>.cfg) — read once for adoption
local function legacy_path()
    return "/WIDGETS/UltiDash/cfg_" .. craft_name() .. ".cfg"
end

local function read_table(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = io.read(f, 8192)
    io.close(f)
    if not data or data == "" then return nil end
    local t = {}
    for k, v in string.gmatch(data, "([%w_]+)%s*=%s*(%-?%d+)") do
        t[k] = tonumber(v)
    end
    return t
end

local function write_table(path, t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local f = io.open(path, "w")
    if not f then return false end
    for i = 1, #keys do
        io.write(f, keys[i] .. "=" .. tostring(t[keys[i]]) .. "\n")
    end
    io.close(f)
    return true
end

local function do_load()
    local slot = read_table(slot_path())
    if slot == nil then
        -- one-time adoption of a legacy name-keyed file (the pre-slot scheme): the
        -- file matching the CURRENT model name carries the user's tuning
        local legacy = read_table(legacy_path())
        if legacy ~= nil then
            write_table(slot_path(), legacy)
            slot = legacy
        end
    end
    per_craft = (slot ~= nil and slot.CfgPerCraft == 1) or false
    if per_craft then
        loaded_craft_path = craft_path()
        local craft = read_table(loaded_craft_path)
        if craft == nil then
            -- adopt a legacy name-keyed file as this craft's config (it held the
            -- per-craft tuning from the pre-slot era)
            craft = read_table(legacy_path())
            if craft ~= nil then write_table(loaded_craft_path, craft) end
        end
        if craft ~= nil then
            craft.CfgPerCraft = 1
            return craft
        end
        return slot   -- craft has no own file yet: use the slot copy
    end
    loaded_craft_path = nil
    return slot
end

-- Load (once) and return the saved settings, or nil when nothing is stored.
function M.load()
    if cache_loaded then
        -- per-craft mode: the model NAME changes at runtime when a craft connects
        -- (Rotorflight renames the TX model) -> reload when the target file moved
        if per_craft and loaded_craft_path ~= craft_path() then
            cache_loaded = false
        else
            return cache
        end
    end
    cache_loaded = true
    local ok, t = pcall(do_load)
    if ok then cache = t end
    return cache
end

-- Merge `values` into the saved settings and persist. Returns true on success.
function M.save(values)
    local t = M.load() or {}
    for k, v in pairs(values) do
        if k ~= "ViewMode" and type(v) == "number" then t[k] = v end
    end
    per_craft = t.CfgPerCraft == 1
    local ok, written = pcall(function()
        if per_craft then
            -- settings live in the craft file; the slot file keeps the mode flag
            -- plus a full fallback copy for crafts without their own file yet
            loaded_craft_path = craft_path()
            if not write_table(loaded_craft_path, t) then return false end
            return write_table(slot_path(), t)
        end
        loaded_craft_path = nil
        return write_table(slot_path(), t)
    end)
    if not ok or written ~= true then return false end
    cache = t
    cache_loaded = true
    return true
end

-- Replace the saved settings with the defaults (keeps the storage mode flag).
function M.reset()
    local t = {}
    for k, v in pairs(defaults) do t[k] = v end
    if per_craft then t.CfgPerCraft = 1 end
    local ok, written = pcall(function()
        if per_craft then
            if not write_table(craft_path(), t) then return false end
            return write_table(slot_path(), t)
        end
        return write_table(slot_path(), t)
    end)
    if not ok or written ~= true then return false end
    cache = t
    cache_loaded = true
    return true
end

-- Resolve this instance's effective options: file value > existing option value >
-- default. Call after wgt.options is (re)assigned (i.e. in update()). Never raises.
function M.apply(wgt)
    if wgt.options == nil then return end
    local ok, t = pcall(M.load)
    if not ok then t = nil end
    for k, def in pairs(defaults) do
        local v = t and t[k]
        if v ~= nil then
            wgt.options[k] = v
        elseif wgt.options[k] == nil then
            wgt.options[k] = def
        end
    end
    if t then
        for k, v in pairs(t) do
            if k ~= "ViewMode" and defaults[k] == nil then wgt.options[k] = v end
        end
    end
end

return M
