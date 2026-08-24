-- =====================================================================
--  UltiDash Toolbox: Flight-log data core
--  Small companion module for the flight log / battery management:
--    * fltlog/batteries.cfg  -- user-maintained battery registry, editable on
--      the radio (Flight Log > Batteries / battpick "+ New") and on the PC
--    * fltlog/flights.csv    -- append-only flight log (one line per flight)
--  LAZY-loaded by the host on first use (a few KB; unlike the big viewer it
--  may stay resident for the session -- the disarm write needs it while the
--  craft is still connected). All io work runs in its OWN host cycle
--  (never shares the call budget with the heavy pass); callers pcall-wrap.
--  ONLY function-style string calls (method style crashes the widget state).
--
--  batteries.cfg line format (one battery per line, '#' = comment):
--    id=<unique>;name=<label>;cap=<mAh>;models=<name,name|*>;profile=<1-6>;cycles=<n>;last=<date>
--  id      any string (1, 2, ... or an external system id like 96dded9b2f4b43f0)
--  models  comma list of model names the battery is offered for (the FC-set
--          model name, case-insensitive); '*' or an EMPTY/missing list = all
--  profile optional FC battery profile activated on selection (FltProf on)
--  cycles/last are maintained by the widget (one count per battery session)
--
--  flights.csv columns: date,time,model,battery_id,flight_s
-- =====================================================================

local M = {}

local ROOT = "/WIDGETS/UltiDash/"
local dir_resolved = nil

-- data dir: the fltlog/ subdir when it exists (ships with the widget /
-- created by the deploy script), else the widget root as a fallback
local function data_dir()
    if dir_resolved == nil then
        if fstat ~= nil and fstat(ROOT .. "fltlog") ~= nil then
            dir_resolved = ROOT .. "fltlog/"
        else
            dir_resolved = ROOT
        end
    end
    return dir_resolved
end

function M.registry_path() return data_dir() .. "batteries.cfg" end
function M.csv_path() return data_dir() .. "flights.csv" end

local function trim(s) return string.match(tostring(s or ""), "^%s*(.-)%s*$") end

-- One read budget for the registry (browse AND rewrite guard). Reads are CHUNKED
-- up to this cap — a single fixed-size io.read silently truncated files that
-- outgrew it. mark_used additionally refuses to touch a file larger than the cap
-- (fstat), so a partial read can never be written back as the whole file.
local READ_CAP = 65536

-- read a whole file in 4 KB chunks (up to cap); nil when missing/empty.
-- EdgeTX io.read returns nil OR "" at EOF; treat both.
local function read_all(path, cap)
    local f = io.open(path, "r")
    if f == nil then return nil end
    local parts, total = {}, 0
    while total < cap do
        local chunk = io.read(f, 4096)
        if chunk == nil or chunk == "" then break end
        parts[#parts + 1] = chunk
        total = total + #chunk
    end
    io.close(f)
    if #parts == 0 then return nil end
    return table.concat(parts)
end

function M.fmt_date(dt)
    if type(dt) ~= "table" then return "" end
    return string.format("%04d-%02d-%02d", dt.year or 0, dt.mon or 0, dt.day or 0)
end

function M.fmt_time(dt)
    if type(dt) ~= "table" then return "" end
    return string.format("%02d:%02d:%02d", dt.hour or 0, dt.min or 0, dt.sec or 0)
end

-- Parse batteries.cfg -> array of { id, name, cap, models (lower-case list),
-- profile, cycles, last }. Missing file -> empty list. Duplicate ids: the FIRST
-- entry wins (matches the example.cfg contract "id must be unique"); the old
-- keep-both behaviour showed two buttons and stamped only the first line, so the
-- second one displayed cycles=0 forever. Caller pcall-wraps.
function M.load_registry()
    local list = {}
    local seen = {}
    local data = read_all(M.registry_path(), READ_CAP) or ""
    for line in string.gmatch(data, "[^\r\n]+") do
        if string.match(line, "^%s*#") == nil and string.find(line, "=", 1, true) ~= nil then
            local e = {}
            -- rk/rv are the loop's control variables and must not be reassigned: Lua 5.5
            -- makes them const (EdgeTX's older Lua tolerates it, but `luac -p` -- the
            -- project's syntax gate -- rejects the file). Normalise into own locals.
            for rk, rv in string.gmatch(line, "([%w_]+)%s*=%s*([^;]*)") do
                local k = string.lower(rk)
                local v = trim(rv)
                if k == "id" then e.id = v
                elseif k == "name" then e.name = v
                elseif k == "cap" then e.cap = tonumber(v)
                elseif k == "models" then
                    local mm = {}
                    for m in string.gmatch(v, "[^,]+") do
                        local mt = string.lower(trim(m))
                        if mt ~= "" then mm[#mm + 1] = mt end
                    end
                    e.models = mm
                elseif k == "profile" then e.profile = tonumber(v)
                elseif k == "cycles" then e.cycles = tonumber(v) or 0
                elseif k == "last" then e.last = v
                end
            end
            if e.id ~= nil and e.id ~= "" and not seen[e.id] then
                seen[e.id] = true
                list[#list + 1] = e
            end
        end
    end
    return list
end

-- Batteries offered for a model: an entry matches when its models list contains
-- the (FC-set) model name case-insensitively, contains "*", or is empty/missing
-- (= offered for every model).
function M.for_model(reg, model_name)
    local want = string.lower(trim(model_name))
    local out = {}
    for i = 1, #reg do
        local e = reg[i]
        local mm = e.models
        local hit = (mm == nil or #mm == 0)
        if not hit then
            for j = 1, #mm do
                if mm[j] == "*" or (want ~= "" and mm[j] == want) then hit = true; break end
            end
        end
        if hit then out[#out + 1] = e end
    end
    return out
end

-- Per-flight stats columns appended after flight_s (see M.append_flight). Mirrors the
-- dashboard's flight-statistics view: cell voltage, per-profile headspeed (P1..P3),
-- current, ESC temperature and BEC voltage as min/max, plus voltage-sag count + deepest
-- sag and the mAh used. Kept as ONE ordered list so the writer, the header and the
-- viewer's parser stay in sync.
M.STAT_KEYS = { "mah",
    "vcel_min", "vcel_max",
    "hs1_min", "hs1_max", "hs2_min", "hs2_max", "hs3_min", "hs3_max",
    "curr_min", "curr_max", "tesc_min", "tesc_max",
    "vbec_min", "vbec_max", "sags", "sag_min" }
local STAT_FMT = {
    mah = "%d",
    vcel_min = "%.2f", vcel_max = "%.2f",
    hs1_min = "%.0f", hs1_max = "%.0f", hs2_min = "%.0f", hs2_max = "%.0f", hs3_min = "%.0f", hs3_max = "%.0f",
    curr_min = "%.1f", curr_max = "%.1f", tesc_min = "%.0f", tesc_max = "%.0f",
    vbec_min = "%.2f", vbec_max = "%.2f", sags = "%d", sag_min = "%.2f",
}
local FULL_HEADER = "date,time,model,battery_id,flight_s,"
    .. table.concat(M.STAT_KEYS, ",") .. "\n"

-- one CSV stats field: formatted number, or "" when the value is missing
local function stat_field(stats, key)
    local v = stats and stats[key]
    if type(v) ~= "number" then return "" end
    return string.format(STAT_FMT[key] or "%s", v)
end

-- Append one flight line to flights.csv (full header written on file creation).
-- dt = getDateTime() snapshot taken at ARM (the flight's start time). `stats` is nil
-- (per-flight stats off) -> a lean 5-column line; else the STAT_KEYS columns follow.
function M.append_flight(dt, model_name, batt_id, secs, stats)
    local path = M.csv_path()
    local st = fstat ~= nil and fstat(path) or nil
    local before = (st and st.size) or 0
    local f = io.open(path, "a")
    if f == nil then return false end
    local want = before
    if before == 0 then
        io.write(f, FULL_HEADER)
        want = want + #FULL_HEADER
    end
    -- commas would break the CSV columns -> flatten them out of free-text fields
    local m = string.gsub(tostring(model_name or ""), ",", " ")
    local b = string.gsub(tostring(batt_id or ""), ",", " ")
    local line = string.format("%s,%s,%s,%s,%d",
        M.fmt_date(dt), M.fmt_time(dt), m, b, math.floor(secs or 0))
    if stats ~= nil then
        for i = 1, #M.STAT_KEYS do line = line .. "," .. stat_field(stats, M.STAT_KEYS[i]) end
    end
    line = line .. "\n"
    io.write(f, line)
    io.close(f)
    -- io.write is silent on a full card -> verify the appended bytes landed (fstat);
    -- a short file returns false so the caller can log the lost line (DebugLog on)
    if fstat ~= nil then
        st = fstat(path)
        if st == nil or st.size ~= want + #line then return false end
    end
    return true
end

-- Parse the stats columns (everything after flight_s) into a { key = number } table
-- following STAT_KEYS order; nil when there is nothing usable (old / stats-off rows).
-- Used by the viewer's per-flight detail page. Empty fields stay nil (value missing).
function M.parse_stats(rest)
    if type(rest) ~= "string" or rest == "" then return nil end
    local out, i, any = {}, 1, false
    for field in string.gmatch(rest .. ",", "([^,]*),") do
        local key = M.STAT_KEYS[i]
        if key == nil then break end
        local n = (field ~= "") and tonumber(field) or nil
        if n ~= nil then out[key] = n; any = true end
        i = i + 1
    end
    if not any then return nil end
    return out
end

-- ATOMIC replace, shared by every registry writer (factored out of mark_used).
-- batteries.cfg is the user's hand-maintained file: a plain in-place "w"
-- rewrite truncates it FIRST, so SD-full / card removal / power loss in the
-- post-flight moment left an empty or partial file (total loss). Instead:
-- write batteries.new -> verify the size landed (fstat) -> park the original
-- as batteries.bak -> rename new into place. Every failure exit leaves the
-- original untouched; on a failed final rename the .bak still holds the data.
-- `allow_create` (create_battery only): a MISSING original skips the .bak
-- parking instead of failing -- the file is created with the first pack.
local function atomic_replace(path, out, allow_create)
    local newp = path .. ".new"
    local bakp = path .. ".bak"
    local f = io.open(newp, "w")       -- truncates a stale .new from an earlier failure
    if f == nil then return false end
    io.write(f, out)
    io.close(f)
    -- verify the full content landed BEFORE touching the original (io.write on a
    -- full card reports no error here; the size check is the reliable signal)
    local st = fstat ~= nil and fstat(newp) or nil
    if st == nil or st.size ~= #out then return false end
    if rename == nil then return false end
    local parked = not (allow_create and fstat ~= nil and fstat(path) == nil)
    if parked then
        -- del/rename return FRESULT (0 = FR_OK) — verified against the 2.12 source
        -- (api_filesystem.cpp: lua_pushinteger/lua_pushunsigned of f_unlink/f_rename)
        if del ~= nil then del(bakp) end   -- FatFS rename refuses an existing target
        if rename(path, bakp) ~= 0 then return false end
    end
    if rename(newp, path) ~= 0 then
        if parked then rename(bakp, path) end  -- restore; on failure .bak still holds the data
        return false
    end
    return true
end

-- Bump a battery's usage counter (cycles+1) and stamp last=<date> in
-- batteries.cfg, keeping every other byte of the user's file as-is (comments
-- and unknown fields survive; missing cycles/last fields are appended).
function M.mark_used(batt_id, dt)
    local path = M.registry_path()
    -- NEVER rewrite from a truncated read: a registry beyond the read cap would
    -- come back shortened — skip the stamp instead (cycles are cosmetic)
    local st = fstat ~= nil and fstat(path) or nil
    if st ~= nil and (st.size or 0) > READ_CAP then return false end
    local data = read_all(path, READ_CAP)
    if data == nil then return false end
    local want = trim(batt_id)
    if want == "" then return false end
    local lines = {}
    local changed = false
    -- the id= field is anchored to the line start or a ';' so a name/id that merely
    -- CONTAINS "id=" in another field can never be mistaken for the key
    -- ...and the two fields we REWRITE are anchored the same way, by a frontier: the
    -- match may only start where a word character does not precede it. Unanchored, the
    -- stamp reached inside the user's own fields -- "recycles=7" was counted up as if it
    -- were the cycle count, and "ballast=1" had its value replaced by the flight date.
    -- The frontier costs nothing and covers both the line start and any ";" or space
    -- before the key, which is every position a real field can begin at.
    local CYCLES = "%f[%w_][cC][yY][cC][lL][eE][sS]%s*="
    local LAST = "%f[%w_][lL][aA][sS][tT]%s*="
    for line in string.gmatch(data, "[^\r\n]+") do
        -- edit a COPY: `line` is the loop's control variable and is const in Lua 5.5
        -- (see the note further up), so it must not be reassigned
        local out = line
        if not changed and string.match(out, "^%s*#") == nil then
            local id = string.match(out, "^%s*[iI][dD]%s*=%s*([^;]*)")
                or string.match(out, ";%s*[iI][dD]%s*=%s*([^;]*)")
            if id ~= nil and trim(id) == want then
                local cyc = tonumber(string.match(out, CYCLES .. "%s*(%d+)")) or 0
                if string.match(out, CYCLES) ~= nil then
                    out = string.gsub(out, CYCLES .. "%s*%d*", "cycles=" .. (cyc + 1), 1)
                else
                    out = out .. ";cycles=" .. (cyc + 1)
                end
                local date = M.fmt_date(dt)
                if string.match(out, LAST) ~= nil then
                    out = string.gsub(out, LAST .. "%s*[^;]*", "last=" .. date, 1)
                else
                    out = out .. ";last=" .. date
                end
                changed = true
            end
        end
        lines[#lines + 1] = out
    end
    if not changed then return false end
    -- atomic replace via the shared helper (see atomic_replace above); a failed
    -- stamp just loses the cycle count (cosmetic)
    local out = table.concat(lines, "\n") .. "\n"
    return atomic_replace(path, out)
end

-- ---------------------------------------------------------------------
-- Registry EDITING (Flight Log battery editor / battpick "+ New").
-- Line surgery, never file generation: only the edited pack's line is
-- rewritten; comments, unknown fields and every other line stay
-- byte-identical (the promise mark_used has always made). All writers:
--   * refuse a file above READ_CAP with the DISTINCT value "toobig" (a
--     truncated read must never be written back as the whole file, and
--     unlike mark_used's silent skip an edit needs an explanation);
--   * return "notfound" when the id's line is gone (file replaced between
--     open and save), "collision" when an id would stop being unique,
--     plain false on an io failure, true on success;
--   * go through atomic_replace, so a failure exit loses nothing.
-- ---------------------------------------------------------------------

-- read the registry for a rewrite; second return is the distinct refusal
local function guarded_read(path)
    local st = fstat ~= nil and fstat(path) or nil
    if st ~= nil and (st.size or 0) > READ_CAP then return nil, "toobig" end
    return read_all(path, READ_CAP), nil
end

-- Walk physical lines by byte offset and find the first non-comment line whose
-- id= field equals `want` (trimmed). Returns content start, content end
-- (EXCLUDING the \r\n / \n terminator) and line end INCLUDING the terminator --
-- offsets, not extracted strings, so the splice around them preserves the
-- file's own line endings verbatim (mark_used's gmatch loop normalises them;
-- an editor must not).
local function find_line(data, want)
    local pos = 1
    while pos <= #data do
        local nl = string.find(data, "\n", pos, true)
        local lend = nl ~= nil and nl or #data
        local cend = nl ~= nil and nl - 1 or #data
        if cend >= pos and string.sub(data, cend, cend) == "\r" then cend = cend - 1 end
        local line = string.sub(data, pos, cend)
        if string.match(line, "^%s*#") == nil then
            -- id= anchored to the line start or a ';' (same as mark_used): a field
            -- that merely CONTAINS "id=" can never be mistaken for the key
            local id = string.match(line, "^%s*[iI][dD]%s*=%s*([^;]*)")
                or string.match(line, ";%s*[iI][dD]%s*=%s*([^;]*)")
            if id ~= nil and trim(id) == want then return pos, cend, lend end
        end
        if nl == nil then break end
        pos = nl + 1
    end
    return nil
end

-- serialised field values: ';' would end the field, CR/LF the line -- strip
-- them here so no caller can corrupt the file format (the UI sanitises more)
local function clean_val(v)
    if type(v) == "number" then return string.format("%d", math.floor(v)) end
    return string.gsub(tostring(v or ""), "[;\r\n]", "")
end

-- the known keys, in the order create/append serialise them
local WKEYS = { "id", "name", "cap", "models", "profile", "cycles", "last" }

-- Rewrite ONE line's content. `e` maps a lower-case known key to: a value to
-- WRITE (string/number), false to REMOVE the key, or nil/absent to leave the
-- field verbatim -- callers pass only the touched fields, so an untouched
-- field keeps its exact bytes (spacing and case included). Fields are split
-- on ';' and a value can never contain ';' (parser contract), so unlike a
-- pattern search this can never mistake text INSIDE a value for a key.
-- Unknown keys and the line's own key order survive verbatim; known-but-new
-- keys append at the end. Duplicate keys: the first occurrence is the one
-- edited, later ones stay verbatim (mark_used's gsub-count-1 behaviour).
local function edit_line(line, e)
    local segs, done = {}, {}
    local pos = 1
    while true do
        local sep = string.find(line, ";", pos, true)
        local seg = string.sub(line, pos, sep ~= nil and sep - 1 or #line)
        local k = string.match(seg, "^%s*([%w_]+)%s*=")
        if k ~= nil then k = string.lower(k) end
        if k ~= nil and not done[k] and e[k] ~= nil then
            done[k] = true
            if e[k] ~= false then
                segs[#segs + 1] = k .. "=" .. clean_val(e[k])
            end
            -- false: segment dropped -> the key is removed
        else
            segs[#segs + 1] = seg
        end
        if sep == nil then break end
        pos = sep + 1
    end
    for i = 1, #WKEYS do
        local k = WKEYS[i]
        if e[k] ~= nil and e[k] ~= false and not done[k] then
            segs[#segs + 1] = k .. "=" .. clean_val(e[k])
        end
    end
    return table.concat(segs, ";")
end

-- one new registry line: id=..;name=..[;cap=..][;models=..][;profile=..];cycles=..
-- (no last= at creation; optional fields are simply absent when unset)
local function serialize_entry(e)
    local line = "id=" .. clean_val(e.id) .. ";name=" .. clean_val(e.name)
    if type(e.cap) == "number" and e.cap > 0 then line = line .. ";cap=" .. clean_val(e.cap) end
    if e.models ~= nil and e.models ~= false and clean_val(e.models) ~= "" then
        line = line .. ";models=" .. clean_val(e.models)
    end
    if type(e.profile) == "number" and e.profile >= 1 then line = line .. ";profile=" .. clean_val(e.profile) end
    line = line .. ";cycles=" .. clean_val(type(e.cycles) == "number" and e.cycles or 0)
    return line
end

-- Append a new pack at EOF. e = { id, name, cap?, models? (the serialised
-- comma list, or nil for "all"), profile?, cycles? }. A MISSING file is not
-- an error: it is created with the first pack (append_flight's behaviour).
function M.create_battery(e)
    local path = M.registry_path()
    local data, err = guarded_read(path)
    if err ~= nil then return err end
    local id = trim(e ~= nil and e.id or "")
    if id == "" then return false end
    if data ~= nil and find_line(data, id) ~= nil then return "collision" end
    local line = serialize_entry(e)
    local out
    if data == nil then
        out = line .. "\n"
    else
        out = data .. (string.sub(data, -1) == "\n" and "" or "\n") .. line .. "\n"
    end
    return atomic_replace(path, out, true)
end

-- Line surgery on the pack whose id= is old_id. `e` follows edit_line's
-- touched-fields contract (value / false = remove / nil = keep verbatim);
-- an id change is e.id, refused with "collision" when the new id already
-- belongs to another line.
function M.update_battery(old_id, e)
    local path = M.registry_path()
    local data, err = guarded_read(path)
    if err ~= nil then return err end
    if data == nil then return "notfound" end
    local want = trim(old_id)
    if want == "" then return "notfound" end
    if type(e) ~= "table" then return false end
    local new_id = (e.id ~= nil and e.id ~= false) and trim(e.id) or nil
    if new_id ~= nil and new_id ~= want and find_line(data, new_id) ~= nil then
        return "collision"
    end
    local s, c = find_line(data, want)
    if s == nil then return "notfound" end
    local out = string.sub(data, 1, s - 1)
        .. edit_line(string.sub(data, s, c), e)
        .. string.sub(data, c + 1)
    return atomic_replace(path, out)
end

-- Plain line removal (B12) -- the line and its terminator go, everything else
-- stays byte-identical. No tombstone: sync semantics are the sync tool's.
function M.delete_battery(id)
    local path = M.registry_path()
    local data, err = guarded_read(path)
    if err ~= nil then return err end
    if data == nil then return "notfound" end
    local want = trim(id)
    if want == "" then return "notfound" end
    local s, _, t = find_line(data, want)
    if s == nil then return "notfound" end
    local out = string.sub(data, 1, s - 1) .. string.sub(data, t + 1)
    return atomic_replace(path, out)
end

return M
