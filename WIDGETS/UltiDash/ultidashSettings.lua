-- Per-model settings persisted on the SD card.
--
-- EdgeTX gives widgets NO API to write their own options, so values edited via the
-- in-widget settings page live in a file and OVERLAY the EdgeTX options at runtime
-- (file wins for every key it contains).
--
-- FILE KEYING: the store is keyed by the EdgeTX MODEL NAME (model.getInfo().name,
-- sanitized), LATCHED when the active model changes. It is NOT keyed by the model
-- file (model.getInfo().filename, "model7.yml"): EdgeTX hands out MODELS/modelN.yml
-- by LOWEST FREE index (createModel -> findNextFileIndex), so rewriting the model
-- list — Companion does exactly that when models are added or deleted — renumbers the
-- surviving models and orphans every cfg file at once. The name survives that.
--
-- What the name does not survive on its own is Rotorflight's "set model name on TX",
-- which renames the EdgeTX model to the connected craft. That rename is TEMPORARY —
-- RF2's SCRIPTS/RF2/background_init.lua remembers the previous name and restores it on
-- disconnect — so the stored name is the stable one and the LATCH covers the single
-- case that is not: the widget (re)loading WHILE a craft is connected. filename is
-- still read, but only to notice that the active model changed.
--
-- Two models with the SAME name deliberately share one file. There is no stable
-- per-model identifier in EdgeTX (no UUID), so uniqueness is the user's: a copied
-- model needs its own name when it needs its own configuration.
--
-- ONE FILE PER MODEL, no second level. The `CfgPerCraft` option ("Config file per
-- craft", cfg_m_<model>_<craft>.cfg) was REMOVED in 0.7.0: its <craft> half was the
-- UNLATCHED model name, so it only ever split anything while Rotorflight was actively
-- renaming the model — with "set model name on TX" off, both halves of the file name
-- were identical and the option did nothing at all. Upgrading loses nothing: per-craft
-- mode always wrote the model file too, with the same content, so the last saved
-- configuration is in it. Old cfg_m_*_*.cfg files are left on the card, unread; the
-- CfgPerCraft key is swept out of the model file by save()'s unknown-key rule.
--
-- Files: /WIDGETS/UltiDash/cfg/cfg_m_<model>.cfg (the store)
--        cfg_m_<model file>.cfg (pre-0.7.0 slot scheme, adopted once)
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

-- Set by the host once skin discovery has finished, true when any discovered skin failed
-- to load. While it is true M.save skips the unknown-key sweep -- see the comment there.
M.sweep_hold = false

-- The skin ids found on this card, comma-separated, also set by the host once discovery
-- has finished. nil = nobody reported (an older host, or a harness), and the sweep then
-- behaves exactly as it did before. M.save stores it in the file and holds the sweep when
-- a skin the file was written with is not on the card -- see the comment there.
M.skin_roster = nil

local cache = nil
local cache_loaded = false
local loaded_model_path = nil  -- which model file the cache came from (model-switch reload check)
local defaults = {}
local migrators = nil          -- skin-supplied M.migrate functions, nil while none registered
local sealed = false           -- true once every skin has been offered the chance to register

-- Schema version stamped into every file we write (key ClrSchemeV). Bumps here trigger a
-- one-time in-place migration of older cfg files (see migrate_schema). A file that already
-- carries the current version is left untouched.
local SCHEMA_VER = 1

-- Defaults are handed in by ultidash.lua (derived from the settings-page group
-- tables — the single source of truth; the EdgeTX option list is empty).
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

-- A skin's optional M.migrate, handed over by the host while it discovers the skins
-- (docs/SKINS.md §7c). Appended in discovery order; no skin may depend on another's.
function M.add_migrator(fn)
    migrators = migrators or {}
    migrators[#migrators + 1] = fn
end

-- Called by the host once EVERY discovered skin has been loaded, i.e. once the migrator list
-- is complete. Until then run_migrators refuses: running half a list on a cfg would let the
-- skins loaded in a later slice miss their own keys.
--
-- IT DROPS THE CACHE, and that is what buys the migration its ordering for FREE. Anything
-- loaded before the list was complete has not been offered the migrators, so the next load
-- has to be a real one -- and the cold path is the only place run_migrators is called from.
-- The alternative, a per-load "has this model been migrated yet" test, was measured: it costs
-- ~6 instructions in EVERY phase of EVERY session, including the overwhelming majority in
-- which no skin declares a migration at all. This costs one cfg re-read, once, and only in a
-- session that read the store before discovery finished (in the staged startup, none does).
-- Nothing here is a "done" flag: what stops a second run is the cache, which is keyed on the
-- MODEL PATH already (see M.load) -- so a model switch throws it away and the model switched
-- TO gets its own migration, which a boolean would never have done.
function M.seal()
    sealed = true
    cache_loaded = false
end

-- Run every registered skin migrator over the RAW cfg table, once per cfg load.
-- Same contract as migrate_schema above -- in memory, idempotent, never forcing a write --
-- with one difference: the transform belongs to the SKIN, because only the skin knows what
-- its own stored values used to mean and through which frozen table an old one decodes.
-- Mapping a value through a live list here would be the host guessing at a skin's history,
-- and it would overwrite the evidence with the guess.
-- Persistence is opportunistic and needs no write of its own: `t` IS the cache (M.load
-- assigns it), so apply() hands the migrated value to every build from here on, and the
-- next M.save/flush_adoption writes the migrated form out.
-- A raising migrator is skipped rather than allowed to take the dashboard down -- the rule
-- this whole module is written to (see the header): settings never crash the widget.
local function run_migrators(t)
    if not sealed or migrators == nil or type(t) ~= "table" then return end
    for i = 1, #migrators do pcall(migrators[i], t) end
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

-- The latched key and the model file it was latched for. Module-local: the active
-- model is global, so one latch serves every instance (same as the cache below).
local latched_file = nil
local latched_key = nil

-- The cfg key: the model name as it stood when this model became active. Re-latched
-- ONLY when model.getInfo().filename changes, i.e. on a real model switch — never when
-- a connecting craft renames the model underneath us. What the latch buys is that the
-- cfg file cannot MOVE mid-session; it cannot recover the stored name if the rename
-- already happened before the first load (boot with the craft powered and connected).
-- In practice the first load lands in refresh #1, seconds before RF's MSP handshake.
local function model_key()
    local info = model_info()
    local fname = ""
    if info and type(info.filename) == "string" then fname = info.filename end
    if latched_key == nil or fname ~= latched_file then
        latched_file = fname
        latched_key = sanitize(info and info.name or "")
        if latched_key == "" then latched_key = "model" end
    end
    return latched_key
end

-- The pre-0.7.0 key: the model FILE ("model7.yml" -> "model7"). Only used to ADOPT a
-- cfg written before the key moved to the model name. nil when EdgeTX gives no
-- filename — there is nothing to adopt then.
local function old_slot_base()
    local info = model_info()
    if info and type(info.filename) == "string" and info.filename ~= "" then
        -- single-value: gsub also returns a count, which must not leak into a
        -- concatenation or a table constructor further up
        local base = string.gsub(sanitize(info.filename), "_yml$", "")
        return base
    end
    return nil
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

local function model_file()
    return "cfg_m_" .. model_key() .. ".cfg"
end

-- the pre-slot scheme (cfg_<model name>.cfg) — read once for adoption
local function legacy_file()
    return "cfg_" .. model_key() .. ".cfg"
end

-- the pre-0.7.0 slot scheme — read once for adoption, nil when unavailable
local function old_slot_file()
    local base = old_slot_base()
    return base and ("cfg_m_" .. base .. ".cfg") or nil
end

local function model_path()  return cfg_prefix() .. model_file()  end

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
    -- SPLIT INTO LINES FIRST, then anchor the match to the line. One gmatch over the
    -- whole blob could not see a line end: on an EMPTY value ("Key=", which write_table
    -- emits for an empty string) the `%s*` after the `=` ate the newline and the value
    -- pattern then swallowed the WHOLE NEXT LINE -- two settings lost per empty one. The
    -- anchor also stops a comment line ("# note=x") from being read as a setting.
    for line in string.gmatch(data, "[^\r\n]+") do
        local k, v = string.match(line, "^%s*([%w_]+)%s*=%s*(.*)$")
        if k then
            v = string.gsub(v, "%s+$", "")
            if string.match(v, "^%-?%d+$") then
                t[k] = tonumber(v)
            else
                t[k] = v
            end
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

-- The ADOPTION write, atomically: the proven .new -> verify -> rename sequence.
-- write_table above opens the TARGET and truncates it, which is right for a save (the file
-- it overwrites is the very source of what it writes) and wrong here. A short write would
-- leave a stub cfg_m_<model>.cfg on the card, and do_load only reaches the legacy file
-- while the new-scheme one is ABSENT -- so the stub would shadow the intact original
-- permanently, and the user would see the upgrade eat their settings. Every failure exit
-- leaves the target where it was; the legacy source is only ever read, never removed, so
-- the next session simply tries the adoption again.
local function write_table_atomic(path, t)
    local newp = path .. ".new"
    if not write_table(newp, t) then
        if del ~= nil then pcall(del, newp) end
        return false
    end
    if rename == nil then return false end
    if fstat ~= nil and fstat(path) ~= nil then
        -- FatFS rename refuses an existing target. What can be sitting there is the
        -- empty/unreadable file that made this an adoption in the first place.
        if del == nil then return false end
        pcall(del, path)
    end
    return rename(newp, path) == 0
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

-- read the first cfg that exists, in order, and record it for adoption under `into`.
-- `names` may contain nils (a scheme with nothing to offer on this radio).
local function read_or_adopt(into, names)
    for i = 1, #names do
        local n = names[i]
        if n ~= nil then
            local t = read_cfg(n)
            if t ~= nil then
                adopt_pending = adopt_pending or {}
                adopt_pending[into] = t
                return t
            end
        end
    end
    return nil
end

local function do_load()
    local main = read_cfg(model_file())
    if main == nil then
        -- One-time adoption, newest scheme first: the slot-keyed file this model wrote
        -- before the key moved to the model name, then the pre-slot name-keyed file.
        main = read_or_adopt(model_path(), { old_slot_file(), legacy_file() })
    end
    return main
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
    pcall(function() for path, t in pairs(p) do write_table_atomic(path, t) end end)
    return true
end

-- The file a save would land in RIGHT NOW. build_settings_view stamps this when a page
-- opens; save_pending_settings discards the working copy when it has moved since: a
-- model switch mid-edit must not write model A's edits into model B's cfg file.
function M.target_path()
    return model_path()
end

-- Load (once) and return the saved settings, or nil when nothing is stored.
function M.load()
    if cache_loaded then
        -- Reload when the ACTIVE MODEL changed: model_key() re-latches on a model switch,
        -- so the path moves and the target model's cfg must be re-read (the cache is
        -- module-wide / shared across instances). A craft connecting does NOT move it —
        -- that is what the latch is for.
        if loaded_model_path ~= model_path() then
            cache_loaded = false
        else
            -- Deliberately NOTHING here for the skin migrations: this is the hot path (every
            -- update() comes through it) and M.seal drops the cache instead, so the cold path
            -- below is the only one that ever has to run them.
            return cache
        end
    end
    cache_loaded = true
    loaded_model_path = model_path()
    local ok, t = pcall(do_load)
    if ok then
        -- one-time schema migration, IN MEMORY ONLY -- never write here: M.load runs inside
        -- create()/update(), whose ~20k-instruction budget (lua_widget.cpp) an SD write blows
        -- ("CPU limit" mid-build). The remap is deterministic from the unchanged file, so it is
        -- idempotent across loads; permanence comes on the next M.save/M.reset, which stamp
        -- ClrSchemeV (after which migrate_schema is a no-op).
        if t ~= nil then migrate_schema(t) end
        -- ...and the skins' own migrations, on the same table and under the same rules
        -- (in memory, once per load, no write of its own). This is the ONLY call site: a
        -- model switch and M.seal both come back through here, and nothing else has to.
        run_migrators(t)
        cache = t
    end
    return cache
end

-- Merge `values` into the saved settings and persist. Returns true on success.
function M.save(values)
    local t = M.load() or {}
    for k, v in pairs(values) do
        if type(v) == "number" or type(v) == "string" then
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
    -- stamp so a fresh file is never mistaken for a pre-v1 one -- but NEVER BACKWARDS. An
    -- older widget saving a newer file used to write its own lower number over the higher
    -- one, and the migration that had already run would then run a second time on the next
    -- upgrade. The file's own stamp wins whenever it is ahead of us.
    t.ClrSchemeV = math.max(tonumber(t.ClrSchemeV) or 0, SCHEMA_VER)
    -- Drop keys no current version knows: orphans (removed features, renamed keys)
    -- otherwise accumulate in the file forever AND flow back into every instance's
    -- options via apply()'s passthrough. Valid = every defaults key (settings rows
    -- incl. the synthesised Clr* roles, SetupSeen, ColorScheme), the <key>Raw picker
    -- shadow of a defaults key, and the ClrSchemeV schema stamp.
    -- Deliberately DOWNGRADE-HOSTILE: an older version's keys are
    -- removed on this version's first save. (Clearing a key during pairs() is legal.)
    -- This is also what retires the removed `CfgPerCraft` flag from an upgraded file.
    -- HELD while a discovered skin failed to load (M.sweep_hold, set by the host once
    -- discovery finishes): a failed skin never registered its own option keys, so the
    -- sweep's premise -- "defaults hold every valid key" -- is false for that session and
    -- the sweep would delete the user's settings for a skin that is merely half-copied.
    -- Everything else here, the -1 colour drop and the ClrSchemeV stamp included, runs
    -- unchanged; the stamp and the CfgPerCraft retirement resume the next session in
    -- which every skin loads.
    -- The hold is NOT free, contrary to what its spec assumed: the orphans it preserves
    -- are then written, so the cfg write grows with their number. Measured in the budget
    -- harness, whose fixture carries 300 deliberately-orphaned keys, the write goes
    -- 13125 -> 18489 of 20000 -- still inside the radio's limit, but past the harness's
    -- own 16000 warn line. A real file's orphan set is the handful of retired keys plus
    -- the broken skin's own rows, so this is a worst case by construction; it only ever
    -- applies in a session that already has a broken skin.
    -- HELD A SECOND WAY, for the skin that is not on the card AT ALL. To the sweep's test
    -- an absent skin's keys look exactly like a broken one's -- nobody declared them -- but
    -- sweep_hold only ever saw skins that were discovered and then failed. Since the four
    -- layouts moved to their own repo, "deploy without the skins pass, then save once" is
    -- one command away from deleting a cockpit configuration nobody touched. So the file
    -- remembers which skins it was written with: a roster that is missing an entry now
    -- holds the sweep. The roster only ever GROWS here -- a shrink is the thing being
    -- detected, so it is never recorded, and the protection stays until the skin is back.
    local hold = M.sweep_hold
    if not hold and type(M.skin_roster) == "string" then
        local have = {}
        for id in string.gmatch(M.skin_roster, "[^,]+") do have[id] = true end
        local seen = t.SkinsSeen
        if type(seen) == "string" then
            for id in string.gmatch(seen, "[^,]+") do
                if not have[id] then hold = true break end
            end
        end
        if not hold then t.SkinsSeen = M.skin_roster end
    end
    if not hold then
        for k in pairs(t) do
            if defaults[k] == nil and k ~= "ClrSchemeV" and k ~= "SkinsSeen"
                and not (string.sub(k, -3) == "Raw" and defaults[string.sub(k, 1, -4)] ~= nil) then
                t[k] = nil
            end
        end
    end
    local ok, written = pcall(function()
        return write_table(model_path(), t)
    end)
    if not ok or written ~= true then return false end
    -- a full save just persisted the merged state (which includes any adopted
    -- values) — a still-pending adoption write would clobber it with stale data
    adopt_pending = nil
    cache = t
    cache_loaded = true
    loaded_model_path = model_path()
    return true
end

-- Replace the saved settings with the defaults.
function M.reset()
    local t = {}
    for k, v in pairs(defaults) do
        -- Same rule as M.save: "unset" colour roles (default -1 = follow the scheme
        -- built-in) are NOT persisted. Writing all ~57 Clr* roles per scheme as -1 is
        -- what save() deliberately avoids -- it inflates every model cfg and rebuilds
        -- exactly the cfg-parse load that once caused the CPU-limit crashes. Skipping
        -- them also brings the reset WRITE back under budget (measured 17.0k -> 8.5k)
        -- and makes a reset file identical in shape to a saved one.
        if v ~= -1 then t[k] = v end
    end
    t.ClrSchemeV = SCHEMA_VER   -- reset produces a current-version file (no re-migration)
    local ok, written = pcall(function()
        return write_table(model_path(), t)
    end)
    if not ok or written ~= true then return false end
    cache = t
    cache_loaded = true
    loaded_model_path = model_path()
    return true
end

-- The LIVE counterpart of M.reset, called by the host on the same stage: put every "unset"
-- colour role back to its default on an instance's options. Those keys are deliberately not
-- written by reset (see there), and apply() never downgrades a key the file does not carry
-- -- so the file was correct after a reset and the screen was not, until the next boot. That
-- reads as "Reset to defaults does not reset the colours", and it was reported as exactly
-- that. Cheap: one walk of the defaults, once per reset.
function M.reset_options(wgt)
    if wgt == nil or wgt.options == nil then return end
    for k, def in pairs(defaults) do
        if def == -1 then wgt.options[k] = -1 end
    end
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
            if defaults[k] == nil then wgt.options[k] = v end
        end
    end
end

return M
