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
-- Files: /WIDGETS/UltiDash/cfg/cfg_m_<slot>.cfg (per model slot, default)
--        /WIDGETS/UltiDash/cfg/cfg_m_<slot>_<craft>.cfg (per craft, optional)
--        cfg_<model name>.cfg (pre-slot legacy scheme, adopted once)
-- Plain "key=value" lines (values are integers, or strings e.g. sensor names).
-- The cfg/ SUBDIR keeps the widget root tidy. It SHIPS with the widget (the repo
-- carries the folder), so nothing is created at runtime — the widget detects it
-- (fstat) and migrates any cfg_* files left in the root by the old flat layout
-- (rename). If the folder is missing everything falls back to the flat root
-- layout — the user's settings are never at risk.
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
local loaded_slot_path = nil   -- which slot file the cache came from (model-switch reload check)
local loaded_craft_path = nil  -- which craft file the cache came from (reload check)
local defaults = {}

-- Schema version stamped into every file we write (key ClrSchemeV). Bumps here trigger a
-- one-time in-place migration of older cfg files (see migrate_schema). A file that already
-- carries the current version is left untouched.
local SCHEMA_VER = 1

-- Defaults are handed in by ultidash.lua (derived from the settings-page group
-- tables — the single source of truth; the EdgeTX option list only has ViewMode).
function M.set_defaults(t)
    defaults = t or {}
end

-- One-time schema migration on a loaded cfg table, applied IN MEMORY (M.load never writes --
-- it runs inside the create/update instruction budget). Returns true when it changed
-- something. Deterministic from the on-disk value, so it is idempotent across reloads; the
-- new format becomes permanent on the next M.save/M.reset, which stamp ClrSchemeV=SCHEMA_VER
-- (after which this is a no-op).
--   v1: the ColorScheme choice order changed (old 1=UltiDash / 2=EdgeTX theme / 3=UltiDash
--       dark -> new 1=UltiDash / 2=UltiDash dark / 3=EdgeTX theme). Swap the stored 2<->3 so
--       the user keeps the theme they picked.
local function migrate_schema(t)
    if type(t) ~= "table" then return false end
    if (tonumber(t.ClrSchemeV) or 0) >= SCHEMA_VER then return false end
    local cs = tonumber(t.ColorScheme)
    if cs == 2 then t.ColorScheme = 3
    elseif cs == 3 then t.ColorScheme = 2 end
    t.ClrSchemeV = SCHEMA_VER
    return true   -- always persist, to stamp the version even when ColorScheme was absent
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

local ROOT = "/WIDGETS/UltiDash/"
local cfg_dir = nil    -- resolved once: ROOT.."cfg/" when usable, else ROOT (flat fallback)

-- Resolve the cfg/ subdir ONCE per session. The folder SHIPS with the widget, so
-- nothing is created here — we just detect it (fstat) and, when present, migrate any
-- root-level cfg_* files from the old flat layout into it (rename, only when the
-- target doesn't exist yet). read_cfg() additionally adopts per file, so even a
-- partial migration can never lose a model's settings. Everything is pcall'd; if the
-- folder is missing we keep the flat root layout exactly as before.
local function cfg_prefix()
    if cfg_dir ~= nil then return cfg_dir end
    cfg_dir = ROOT
    pcall(function()
        if fstat(ROOT .. "cfg") ~= nil then cfg_dir = ROOT .. "cfg/" end
    end)
    if cfg_dir ~= ROOT then
        pcall(function()                        -- one-time sweep, best-effort
            -- COLLECT first, then rename: moving files out of ROOT WHILE iterating
            -- dir(ROOT) can make FatFS f_readdir skip entries (a partial sweep).
            local move = {}
            for fname in dir(ROOT) do
                if string.match(fname, "^cfg_.+%.cfg$") ~= nil then
                    move[#move + 1] = fname
                end
            end
            for i = 1, #move do
                local fname = move[i]
                if fstat(cfg_dir .. fname) == nil then    -- never clobber a newer copy
                    rename(ROOT .. fname, cfg_dir .. fname)
                end
            end
        end)
    end
    return cfg_dir
end

local function slot_file()
    return "cfg_m_" .. slot_base() .. ".cfg"
end

-- per-craft files are NAMESPACED by the slot too (cfg_m_<slot>_<craft>.cfg): the
-- same craft flown from two different model slots keeps separate configurations,
-- and the files group visibly per slot on the SD card
local function craft_file()
    return "cfg_m_" .. slot_base() .. "_" .. craft_name() .. ".cfg"
end

-- the pre-slot scheme (cfg_<model name>.cfg) — read once for adoption
local function legacy_file()
    return "cfg_" .. craft_name() .. ".cfg"
end

local function slot_path()   return cfg_prefix() .. slot_file()   end
local function craft_path()  return cfg_prefix() .. craft_file()  end
local function legacy_path() return cfg_prefix() .. legacy_file() end

local function read_table(path)
    local f = io.open(path, "r")
    if not f then return nil end
    -- read in chunks until EOF: a single 8 KB read silently truncated cfgs that grew past
    -- 8 KB (more per-alert keys) -> lost settings with no error. EdgeTX io.read returns nil
    -- OR "" at EOF; treat both. Hard cap as a safety net (never expected to be hit).
    local parts, total = {}, 0
    while true do
        local chunk = io.read(f, 4096)
        if chunk == nil or chunk == "" then break end
        parts[#parts + 1] = chunk
        total = total + #chunk
        if total >= 65536 then break end
    end
    io.close(f)
    if #parts == 0 then return nil end
    local data = table.concat(parts)
    local t = {}
    -- values may be integers (legacy) OR strings (e.g. telemetry sensor names like
    -- "Hspd", "Bat%", "~volt"). Capture the rest of the line, trim trailing space,
    -- and keep it numeric only when it looks like a plain integer.
    for k, v in string.gmatch(data, "([%w_]+)%s*=%s*([^\r\n]+)") do
        v = string.gsub(v, "%s+$", "")
        if string.match(v, "^%-?%d+$") then
            t[k] = tonumber(v)
        else
            t[k] = v
        end
    end
    return t
end

local function write_table(path, t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local f = io.open(path, "w")
    if not f then return false end
    local want = 0
    for i = 1, #keys do
        local line = keys[i] .. "=" .. tostring(t[keys[i]]) .. "\n"
        io.write(f, line)
        want = want + #line
    end
    io.close(f)
    -- EdgeTX io.write reports nothing useful on a full/failing card — the on-disk
    -- size against the summed line lengths is the reliable signal (same pattern as
    -- fltdata's atomic replace). A short file -> false -> the save-failed banner.
    if fstat ~= nil then
        local st = fstat(path)
        if st == nil or st.size ~= want then return false end
    end
    return true
end

-- read a cfg by FILE NAME: prefer the cfg/ copy, else adopt a root-level file
-- left by the old flat layout (or an interrupted sweep) and move it over,
-- best-effort — a failed rename still returns the data; the next save writes
-- to the cfg/ path anyway.
local function read_cfg(name)
    local p = cfg_prefix() .. name
    local t = read_table(p)
    if t ~= nil then return t end
    if cfg_prefix() ~= ROOT then
        local old = ROOT .. name
        t = read_table(old)
        if t ~= nil then pcall(rename, old, p) end
    end
    return t
end

-- Deferred adoption writes: do_load runs inside create()/update(), whose ~20k-
-- instruction budget an SD write blows ("CPU limit" — measured: legacy read +
-- adoption write + apply in one call sat at ~19.9k). The load only RECORDS what
-- to persist (path -> table); the host flushes it via M.flush_adoption() in a
-- refresh cycle of its own (same pattern as the cfg-snapshot deferral).
local adopt_pending = nil

local function do_load()
    local slot = read_cfg(slot_file())
    if slot == nil then
        -- one-time adoption of a legacy name-keyed file (the pre-slot scheme): the
        -- file matching the CURRENT model name carries the user's tuning
        local legacy = read_cfg(legacy_file())
        if legacy ~= nil then
            adopt_pending = adopt_pending or {}
            adopt_pending[slot_path()] = legacy
            slot = legacy
        end
    end
    per_craft = (slot ~= nil and slot.CfgPerCraft == 1) or false
    if per_craft then
        loaded_craft_path = craft_path()
        local craft = read_cfg(craft_file())
        if craft == nil then
            -- adopt a legacy name-keyed file as this craft's config (it held the
            -- per-craft tuning from the pre-slot era)
            craft = read_cfg(legacy_file())
            if craft ~= nil then
                adopt_pending = adopt_pending or {}
                adopt_pending[loaded_craft_path] = craft
            end
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

-- Persist any adoption recorded by do_load. Called by the host in its OWN refresh
-- cycle (fresh instruction budget). Returns true when it did SD work this call.
function M.flush_adoption()
    if adopt_pending == nil then return false end
    local p = adopt_pending
    adopt_pending = nil
    -- pcall'd: an io error mid-write must not crash the widget Lua state.
    -- Worst case the adoption is lost for this session; the next session's load
    -- records it again (the legacy file is only read, never removed).
    pcall(function() for path, t in pairs(p) do write_table(path, t) end end)
    return true
end

-- The file a save would land in RIGHT NOW (per-craft aware). build_settings_view
-- stamps this when a page opens; save_pending_settings discards the working copy
-- when it has moved since: a model switch / craft rename mid-edit must
-- not write model A's edits into model B's cfg file.
function M.target_path()
    return per_craft and craft_path() or slot_path()
end

-- Load (once) and return the saved settings, or nil when nothing is stored.
function M.load()
    if cache_loaded then
        -- Reload when the ACTIVE MODEL changed: the slot file is keyed by the model slot
        -- (model.getInfo().filename), so switching models must re-read the target model's
        -- cfg (the cache is module-wide / shared across instances). In per-craft mode the
        -- model NAME also changes at runtime when a craft connects (Rotorflight renames
        -- the TX model) -> reload when that target file moved too.
        if loaded_slot_path ~= slot_path()
            or (per_craft and loaded_craft_path ~= craft_path()) then
            cache_loaded = false
        else
            return cache
        end
    end
    cache_loaded = true
    loaded_slot_path = slot_path()
    local ok, t = pcall(do_load)
    if ok then
        -- one-time schema migration, IN MEMORY ONLY -- never write here: M.load runs inside
        -- create()/update(), whose ~20k-instruction budget (lua_widget.cpp) an SD write blows
        -- ("CPU limit" mid-build). The remap is deterministic from the unchanged file, so it is
        -- idempotent across loads; permanence comes on the next M.save/M.reset, which stamp
        -- ClrSchemeV (after which migrate_schema is a no-op).
        if t ~= nil then migrate_schema(t) end
        cache = t
    end
    return cache
end

-- Merge `values` into the saved settings and persist. Returns true on success.
function M.save(values)
    local t = M.load() or {}
    for k, v in pairs(values) do
        if k ~= "ViewMode" and (type(v) == "number" or type(v) == "string") then
            -- "unset" colour roles (default -1 -> follow the scheme built-in) are NOT persisted:
            -- the autosave/snapshot hands us all ~57 Clr* keys, and writing them as -1 into every
            -- model cfg (~0.7 kB) rebuilds exactly the cfg-parse load that caused the CPU-limit
            -- crashes. Drop the key (also clears a prior override when the user taps "Def").
            if defaults[k] == -1 and v == -1 then
                t[k] = nil
            else
                t[k] = v
            end
        end
    end
    t.ClrSchemeV = SCHEMA_VER   -- stamp so a fresh file is never mistaken for a pre-v1 one
    -- Drop keys no current version knows: orphans (removed features, renamed keys)
    -- otherwise accumulate in the file forever AND flow back into every instance's
    -- options via apply()'s passthrough. Valid = every defaults key (settings rows
    -- incl. the synthesised Clr* roles, SetupSeen, CfgPerCraft, ColorScheme), the
    -- <key>Raw picker shadow of a defaults key, and the ClrSchemeV schema stamp.
    -- Deliberately DOWNGRADE-HOSTILE: an older version's keys are
    -- removed on this version's first save. (Clearing a key during pairs() is legal.)
    for k in pairs(t) do
        if defaults[k] == nil and k ~= "ClrSchemeV" and k ~= "CfgPerCraft"
            and not (string.sub(k, -3) == "Raw" and defaults[string.sub(k, 1, -4)] ~= nil) then
            t[k] = nil
        end
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
    -- a full save just persisted the merged state (which includes any adopted
    -- values) — a still-pending adoption write would clobber it with stale data
    adopt_pending = nil
    cache = t
    cache_loaded = true
    loaded_slot_path = slot_path()
    return true
end

-- Replace the saved settings with the defaults (keeps the storage mode flag).
function M.reset()
    local t = {}
    for k, v in pairs(defaults) do t[k] = v end
    t.ClrSchemeV = SCHEMA_VER   -- reset produces a current-version file (no re-migration)
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
    loaded_slot_path = slot_path()
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
            -- type-coerce against the default: a hand-edited/corrupt line can hand a string
            -- to a numeric key, which later crashes a %d formatter or a +/- stepper. Sensor
            -- slots keep string defaults (e.g. "~volt") and pass through unchanged.
            if type(def) == "number" and type(v) ~= "number" then
                v = tonumber(v) or def
            end
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
