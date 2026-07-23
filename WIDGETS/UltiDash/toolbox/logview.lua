-- =====================================================================
--  UltiDash Toolbox: Log Viewer
--  Graphs EdgeTX telemetry logs (/LOGS/*.csv) on the radio: up to 4
--  sensor curves, zoom + pan + time cursor, template-based sensor pick,
--  UltiDash look. Disarmed-only (auto-closes on arm). Loaded modular +
--  pcall'd by the host; a missing file just drops the menu entry.
--
--  All file/parse work is chunked over many refresh() ticks against the
--  ~20k EdgeTX instruction budget via FIXED work caps per tick. getUsage()
--  is deliberately NOT used: in useLvglLayout widgets it returns
--  luaScriptManager->refreshInstructionsPercent — a snapshot of the LAST
--  refresh cycle (api_general.cpp, 2.12), constant during the current call,
--  so a "while getUsage() < N" pump never yields and trips "CPU limit".
--  No MSP. Per-instance state on wgt.lv; M.close(wgt) frees it (wgt.lv=nil).
-- =====================================================================

local M = {}

-- ---------------------------------------------------------------------
-- constants (module level holds NO widget state; per-instance -> wgt.lv)
-- ---------------------------------------------------------------------
local CHUNK_SIZE     = 4096      -- io.read chunk size
-- Per-tick work caps (deterministic; getUsage() is a last-cycle snapshot in LVGL
-- widgets and thus USELESS as a live gate — see header). Sized against the 20k
-- instruction budget with the host giving this module exclusive refresh cycles:
local HEADER_ITERS_TICK = 8      -- header pump iterations (line finds / 4k refills)
local HPARSE_COLS_TICK  = 48     -- header columns parsed per tick (~40 instr each)
local SCAN_LINES_TICK   = 100    -- scan-pass lines per tick (~90 instr/line: one
                                 -- string.match head parse instead of find/sub)
local EXTRACT_LINES_TICK = 80    -- extract lines per tick: ONE precompiled
                                 -- string.match per line (a single C call) grabs
                                 -- Date, Time + all wanted columns at once — the
                                 -- old per-comma Lua walk burned ~15 instr per
                                 -- column and capped late-column templates at
                                 -- ~5 lines/tick
local SCAN_FILES_TICK = 120      -- /LOGS dir() names processed per tick (~50 instr
                                 -- each: with 572 logs a one-shot scan blew the 20k
                                 -- budget at ~file 370 — the "CPU limit" landed in
                                 -- the pcall as "Cannot read /LOGS" + a SILENT
                                 -- partial list missing the newest logs)
local IDX_EVERY      = 256       -- sparse index: one entry per N lines
local SESSION_GAP_CS = 3000      -- forward jump > 30 s = new session
local MAX_LINE_LEN   = 1024      -- guard: drop longer lines
local MAX_CURVES     = 4
local MAX_FILES      = 600       -- ring-capped: on overflow the OLDEST seen entries
                                 -- are overwritten (dir() order ~ creation order),
                                 -- so the newest logs always survive the cap
local DAY_CS         = 8640000   -- centiseconds per day
local MIN_SPAN_CS    = 200       -- minimum zoom window: 2 s
local BASE_MULT      = 4         -- base RAM cache resolution = nbuckets x BASE_MULT
                                 -- (the whole session held once at this res; any
                                 -- window coarser than it is served from RAM). Heap
                                 -- scales with this: 4 curves x nbuckets*MULT x 2.
local CACHE_MAX      = 4         -- unified cache entries: base + finer zoom levels
local HUGE           = math.huge
local EMPTY_PTS      = { { 0, 0 }, { 0, 0 } }  -- lvgl.line needs >= 2 pts
local N_GRID         = 6         -- max vertical grid lines (round steps)

-- UI language is ENGLISH (matches the dashboard chrome)
local BUILTIN_TEMPLATES = {
  { name = "Power",    curves = { "Vbat", "Curr", "Hspd", "EscT" } },
  { name = "Battery",  curves = { "Vbat", "Vcel", "Curr", "Capa" } },
  { name = "RF link",  curves = { "1RSS", "2RSS", "RQly", "TPWR" } },
  { name = "Governor", curves = { "Hspd", "Thr",  "Vbat", "Curr" } },
}
local CUSTOM_NAME = "Custom"     -- pseudo template: user-picked sensor set

-- sensor grouping for the picker: EXACTLY the RF Configurator's "Telemetry
-- Sensors" dialog groups (rotorflight-configurator src/tabs/receiver/telemetry/
-- crsf.js), with the EdgeTX short names the RF Lua suite registers per sensor
-- (rotorflight-lua-scripts rf2tlm_sensors.lua) — those are the log-header names.
-- EdgeTX-only columns get their own trailing groups (RF link stats, radio
-- sticks/switches/channels). Ordered; names are the header names WITHOUT the
-- unit. Anything unmatched: SW# -> Switches, CH# -> Channels, DBG# -> Debug,
-- else -> Other. A group with no columns in the log is hidden.
local function nameset(...)
  local t = {}
  for _, n in ipairs({ ... }) do t[n] = true end
  return t
end
local SENSOR_GROUPS = {
  { name = "RF link",     set = nameset("RSNR","ANT","RFMD","TPWR","TRSS","TQly","TSNR",
                                        "1RSS","2RSS","RQly","RSSI","LQ","*Cnt","*Skp") },
  { name = "Battery",     set = nameset("Vbat","Curr","Capa","Bat%","Cel#","Vcel","Cels","RxBt") },
  { name = "Voltage",     set = nameset("Vesc","Vbec","Vbus","Vmcu") },
  { name = "Current",     set = nameset("Iesc","Ibec","Ibus","Imcu") },
  { name = "Temperature", set = nameset("Tesc","Tbec","Tmcu","Temp") },
  { name = "ESC #1",      set = nameset("EscV","EscI","EscC","EscR","EscP","Esc%","EscT",
                                        "BecT","BecV","BecI","EscF","Esc#","ErpM","Espd","PWM") },
  { name = "ESC #2",      set = nameset("Es2V","Es2I","Es2C","Es2R","Es2T","Es2#") },
  { name = "RPM",         set = nameset("Hspd","Tspd","RPM") },
  { name = "Barometer",   set = nameset("Alt","Var","VSpd") },
  { name = "Gyro",        set = nameset("Hdg","Ptch","Roll","Yaw","AccX","AccY","AccZ") },
  { name = "GPS",         set = nameset("Sats","PDOP","GPS","GAlt","GHdg","GSpd","GDis","GDir") },
  { name = "Status",      set = nameset("MDL#","Mode","ARM","ARMD","Resc","Gov","AdjF","AdjV","FM") },
  { name = "Profile",     set = nameset("PID#","RTE#","BAT#","LED#") },
  { name = "Control",     set = nameset("CPtc","CRol","CYaw","CCol","Thr") },  -- Thr(%) only
  { name = "System",      set = nameset("BEAT","CPU%","SYS%","RT%") },
  { name = "Debug",       set = {} },   -- DBG# pattern
  { name = "Sticks",      set = nameset("Rud","Ele","Ail","P1","P2","P3","TxBat") },  -- + unit-less "Thr"
  { name = "Switches",    set = nameset("SA","SB","SC","SD","SE","SF","LSW") },  -- + SW# pattern
  { name = "Channels",    set = {} },   -- CH# pattern
  { name = "Other",       set = {} },   -- catch-all (always last)
}
local G_DEBUG, G_STICKS, G_SWITCHES, G_CHANNELS, G_OTHER = 16, 17, 18, 19, 20

local function group_of(name, unit)
  -- "Thr" is ambiguous: the radio's throttle-STICK column logs without a unit,
  -- the RF Throttle-Control telemetry sensor logs as "Thr(%)"
  if name == "Thr" and (unit == nil or unit == "") then return G_STICKS end
  for gi = 1, #SENSOR_GROUPS do
    if SENSOR_GROUPS[gi].set[name] then return gi end
  end
  if string.match(name, "^SW%d") then return G_SWITCHES end
  if string.match(name, "^CH%d") then return G_CHANNELS end
  if string.match(name, "^DBG%d") then return G_DEBUG end
  return G_OTHER
end

-- build lv.sens_vrows: a flat list of visual rows for the grouped picker, plus
-- lv.sens_buckets (group index -> { colIdx, ... }) for the reactive per-group
-- selected/total counter. Row shapes:
--   { header = groupIndex }                     group divider band (collapsible)
--   { col = colIdx }                            LIST layout: one sensor per row
--   { cols = { colIdx, ... } }                  GRID layout: up to ncols per row
-- A collapsed group (lv.sens_collapsed[gi]) contributes only its header row.
-- Rebuilt whenever layout / ncols / collapse changes (caller nils lv.sens_vrows).
local function build_sensor_vrows(lv, layout, ncols)
  local buckets = {}                       -- group index -> { colIdx, ... }
  for c = 3, #lv.columns do
    local gi = group_of(lv.columns[c].name, lv.columns[c].unit)
    buckets[gi] = buckets[gi] or {}
    buckets[gi][#buckets[gi] + 1] = c
  end
  lv.sens_buckets = buckets
  -- default: ALL groups collapsed (configurator-style overview first); nil
  -- marks "not initialized yet" (open_file resets it per file)
  if lv.sens_collapsed == nil then
    local coll = {}
    for gi = 1, #SENSOR_GROUPS do coll[gi] = true end
    lv.sens_collapsed = coll
  end
  local collapsed = lv.sens_collapsed
  local vrows = {}
  for gi = 1, #SENSOR_GROUPS do
    local cols = buckets[gi]
    if cols ~= nil and #cols > 0 then
      vrows[#vrows + 1] = { header = gi }
      if not (collapsed ~= nil and collapsed[gi]) then
        if layout == "grid" then
          local i = 1
          while i <= #cols do
            local row = { cols = {} }
            for j = 1, ncols do row.cols[j] = cols[i]; i = i + 1 end
            vrows[#vrows + 1] = row
          end
        else
          for i = 1, #cols do vrows[#vrows + 1] = { col = cols[i] } end
        end
      end
    end
  end
  lv.sens_vrows = vrows
  lv.sens_vrows_ncols = ncols
end

-- curve colors; pick dark set when the host palette says dark (tb_pal.dark,
-- set by the host's toolbox_palette for the dark scheme). Tuned via screenshots.
local CURVE_COLORS_LIGHT = {
  lcd.RGB(0x20, 0x60, 0xC0), lcd.RGB(0xC0, 0x30, 0x38),
  lcd.RGB(0x20, 0x90, 0x48), lcd.RGB(0xE0, 0x78, 0x00),
}
local CURVE_COLORS_DARK = {
  lcd.RGB(0x00, 0xE5, 0xFF), lcd.RGB(0x39, 0xFF, 0x14),
  lcd.RGB(0xFF, 0xC4, 0x00), lcd.RGB(0xFF, 0x40, 0xC0),
}

-- ---------------------------------------------------------------------
-- per-instance state, namespaced on the UltiDash widget (adjmap pattern)
-- ---------------------------------------------------------------------
local function ensure(wgt)
  local lv = wgt.lv
  if not lv then
    lv = {
      mode = "browse",   -- "browse"|"filter"|"load"|"sessions"|"templates"|"view"
      tap_block = 0,
      -- filter_model nil = all models. Rotorflight renames the EdgeTX model to
      -- the connected craft's (truncated) name, so a "current model" filter is
      -- arbitrary without a connected FC — instead the user filters by the
      -- model names actually FOUND in /LOGS (the "filter" page).
      filter_model = nil,
      fil_scroll = 0,
      scroll = 0,
      notice = nil,
      progress = 0,
      hit = {},          -- tap targets of the currently built page
      fstat_cache = {},  -- fname -> size (visible rows only)
    }
    wgt.lv = lv
  end
  return lv
end

function M.close(wgt)
  local lv = wgt.lv
  if lv then
    if lv.fh then pcall(io.close, lv.fh) end
    wgt.lv_last_tpl = lv.tpl_name or wgt.lv_last_tpl  -- session memory only
    wgt.lv = nil
  end
end

-- ---------------------------------------------------------------------
-- capped line pump: feeds complete lines to on_line(lv, line, offset) for
-- at most max_iters loop iterations (a fed line OR a 4k chunk refill each
-- count as one), then returns "cap" so the caller yields to the next tick.
-- Buffer state: lv.buf/lv.bufpos; lv.file_pos = bytes consumed from file.
-- offset of buf start = lv.file_pos - #lv.buf (rest bytes were counted).
-- ---------------------------------------------------------------------
local function pump_lines(lv, on_line, max_iters)
  for _ = 1, max_iters do
    local buf = lv.buf
    local nl = nil
    if buf ~= nil then nl = string.find(buf, "\n", lv.bufpos, true) end
    if nl ~= nil then
      local line_off = lv.file_pos - #buf + lv.bufpos - 1
      local line = string.sub(buf, lv.bufpos, nl - 1)
      lv.bufpos = nl + 1
      if string.sub(line, -1) == "\r" then line = string.sub(line, 1, -2) end
      if #line > 0 and #line <= MAX_LINE_LEN then
        if on_line(lv, line, line_off) == false then return "stop" end
      end
    else
      local rest = ""
      if buf ~= nil then rest = string.sub(buf, lv.bufpos) end
      local data = io.read(lv.fh, CHUNK_SIZE)
      if data == nil or data == "" then
        lv.buf, lv.bufpos = nil, 1
        if #rest > 0 and #rest <= MAX_LINE_LEN then
          on_line(lv, rest, lv.file_pos - #rest)  -- file without final \n
        end
        return "eof"
      end
      lv.file_pos = lv.file_pos + #data
      lv.buf = rest .. data
      lv.bufpos = 1
    end
  end
  return "cap"
end

-- ---------------------------------------------------------------------
-- header parsing + templates
-- ---------------------------------------------------------------------
-- Parse ONE column of the header line (lv.header_line) at lv.hparse_pos into
-- lv.columns[lv.hparse_col]; advance the cursors. Returns true when the whole
-- header is consumed. Called in fixed batches (HPARSE_COLS_TICK) by loader_tick's
-- "hparse" phase: a full Rotorflight log header has ~100+ columns, and parsing
-- them all in one call blew the instruction budget in a single shot.
local function parse_header_col(lv)
  local line = lv.header_line
  local L    = #line
  local pos  = lv.hparse_pos
  if pos > L + 1 then return true end
  local comma = string.find(line, ",", pos, true)
  local e = comma and (comma - 1) or L
  local label = string.sub(line, pos, e)
  local par = string.find(label, "(", 1, true)
  if par ~= nil then
    -- strip the trailing ")" via string.sub (NOT gsub: ")" is a Lua pattern
    -- special -> gsub(s, ")", "") raises "invalid pattern capture").
    local unit = string.sub(label, par + 1)
    if string.sub(unit, -1) == ")" then unit = string.sub(unit, 1, -2) end
    lv.columns[lv.hparse_col] = { name = string.sub(label, 1, par - 1), unit = unit }
  else
    lv.columns[lv.hparse_col] = { name = label, unit = "" }
  end
  lv.hparse_col = lv.hparse_col + 1
  lv.hparse_pos = comma and (comma + 1) or (L + 2)
  return lv.hparse_pos > L + 1
end

local function load_user_templates()
  local list, broken = {}, false
  for i = 1, #BUILTIN_TEMPLATES do list[#list + 1] = BUILTIN_TEMPLATES[i] end
  local ok, chunk = pcall(loadScript, "/WIDGETS/UltiDash/toolbox/logtemplates.lua")
  if ok and type(chunk) == "function" then
    local ok2, cfg = pcall(chunk)
    if ok2 and type(cfg) == "table" and type(cfg.templates) == "table" then
      if cfg.replace == true then list = {} end
      for i = 1, #cfg.templates do
        local t = cfg.templates[i]
        if type(t) == "table" and type(t.name) == "string"
            and type(t.curves) == "table" then
          list[#list + 1] = t
        end
      end
      if #list == 0 then  -- replace=true but nothing valid -> fall back
        for i = 1, #BUILTIN_TEMPLATES do list[i] = BUILTIN_TEMPLATES[i] end
        broken = true
      end
    else
      broken = true       -- file present but not a valid template table
    end
  end
  return list, broken
end

-- match a template against the header -> { {name, unit, col}, ... } (<= 4)
local function match_template(lv, tpl)
  local curves = {}
  for i = 1, #tpl.curves do
    if #curves >= MAX_CURVES then break end
    local want = tpl.curves[i]
    for c = 3, #lv.columns do
      if lv.columns[c].name == want then
        curves[#curves + 1] = { name = want, unit = lv.columns[c].unit, col = c }
        break
      end
    end
  end
  return curves
end

-- sorted wanted-column list + column->curve-slot mapping (extraction reads
-- columns left to right, so the walk needs them in ascending order)
local function prepare_wanted(lv)
  local wc, wk = {}, {}
  for k = 1, #lv.curves do
    wc[#wc + 1] = lv.curves[k].col
    wk[#wk + 1] = k
  end
  for i = 2, #wc do            -- insertion sort, max 4 entries
    local c, s, j = wc[i], wk[i], i - 1
    while j >= 1 and wc[j] > c do
      wc[j + 1], wk[j + 1] = wc[j], wk[j]
      j = j - 1
    end
    wc[j + 1], wk[j + 1] = c, s
  end
  lv.want_cols, lv.want_k = wc, wk
  -- precompiled line pattern: ONE string.match (a single C call, ~1 VM
  -- instruction) extracts Date, Time and the (<= 4) wanted columns at once.
  -- Unwanted columns are skipped with capture-less ",[^,]*" segments.
  local parts = { "^([^,]*),([^,]*)" }
  local wi = 1
  for col = 3, wc[#wc] or 2 do
    if wc[wi] == col then
      parts[#parts + 1] = ",([^,]*)"
      wi = wi + 1
    else
      parts[#parts + 1] = ",[^,]*"
    end
  end
  lv.xpat = table.concat(parts)
  lv.extract_cap = EXTRACT_LINES_TICK
end

-- ---------------------------------------------------------------------
-- time parsing + scan pass (phase B: Date+Time only -> cheap)
-- ---------------------------------------------------------------------
-- "HH:MM:SS.mm0" (fixed width, 10 ms resolution) -> integer cs, or nil
local function parse_time_cs(s)
  local h  = tonumber(string.sub(s, 1, 2))
  local mi = tonumber(string.sub(s, 4, 5))
  local se = tonumber(string.sub(s, 7, 8))
  local ms = tonumber(string.sub(s, 10, 12))
  if h == nil or mi == nil or se == nil or ms == nil then return nil end
  return ((h * 60 + mi) * 60 + se) * 100 + math.floor(ms / 10)
end

local function scan_on_line(lv, line, off)
  -- one C call for the head parse (Date + Time) instead of find/find/sub/sub
  local date, ts = string.match(line, "^([^,]*),([^,]*)")
  if date == nil then return end
  local tcs = parse_time_cs(ts)
  if tcs == nil then return end            -- header or garbage line
  if date ~= lv.cur_date then
    if lv.cur_date ~= nil then lv.day = lv.day + 1 end
    lv.cur_date = date
  end
  local t = lv.day * DAY_CS + tcs
  local sessions = lv.sessions
  local s = sessions[#sessions]
  if s == nil or t < lv.prev_t or (t - lv.prev_t) > SESSION_GAP_CS then
    s = { t0 = t, t1 = t, lines = 0 }
    sessions[#sessions + 1] = s
  end
  s.t1 = t
  s.lines = s.lines + 1
  lv.prev_t = t
  lv.nline = lv.nline + 1
  if lv.nline % IDX_EVERY == 1 then
    lv.index[#lv.index + 1] = { off = off, t = t, day = lv.day, date = date }
  end
end

-- capture the header line only; the (expensive, ~100-column) parse is chunked
-- per column in the "hparse" phase so it can yield mid-header.
local function header_on_line(lv, line, off)
  lv.header_line = line
  lv.columns     = {}
  lv.hparse_pos  = 1
  lv.hparse_col  = 1
  return false                              -- stop pump after line 1
end

-- ---------------------------------------------------------------------
-- window extraction (phase C)
-- ---------------------------------------------------------------------
-- accumulate one captured value string into curve slot wi's bucket bi
local function extract_acc(lv, wi, bi, s)
  local v = tonumber(s)
  if v == nil then return end
  local k = lv.want_k[wi]
  local bmin, bmax = lv.tgt_min[k], lv.tgt_max[k]
  if v < bmin[bi] then bmin[bi] = v end
  if v > bmax[bi] then bmax[bi] = v end
end

local function extract_on_line(lv, line, off)
  -- single precompiled match (prepare_wanted): Date, Time + wanted columns in
  -- ONE C call. A line shorter than the pattern (truncated tail) doesn't
  -- match and is skipped — same net effect as the old walker's early break.
  local date, ts, s1, s2, s3, s4 = string.match(line, lv.xpat)
  if date == nil then return end
  local tcs = parse_time_cs(ts)
  if tcs == nil then return end
  if date ~= lv.cur_date then
    lv.day = lv.day + 1
    lv.cur_date = date
  end
  local t = lv.day * DAY_CS + tcs
  if t < lv.ext_t0 then return end
  if t > (lv.extract_stop_t or (lv.ext_t0 + lv.ext_span)) then return false end  -- past edge
  -- bucket index into the EXTRACTION window/resolution (may be the hi-res base);
  -- float math on purpose (int32 would overflow on long spans)
  local bi = math.floor(((t - lv.ext_t0) / lv.ext_span) * (lv.ext_nb - 1)) + 1
  if bi < 1 then bi = 1 elseif bi > lv.ext_nb then bi = lv.ext_nb end
  -- captures arrive in want_cols order (ascending column index)
  if s1 ~= nil then extract_acc(lv, 1, bi, s1) end
  if s2 ~= nil then extract_acc(lv, 2, bi, s2) end
  if s3 ~= nil then extract_acc(lv, 3, bi, s3) end
  if s4 ~= nil then extract_acc(lv, 4, bi, s4) end
end

-- last sparse-index entry with t <= t0 (binary search)
local function index_before(lv, t0)
  local idx = lv.index
  local lo, hi, best = 1, #idx, idx[1]
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if idx[mid].t <= t0 then
      best = idx[mid]
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return best
end

-- format cs relative to session start as m:ss
local function fmt_mmss(cs)
  local s = math.floor(cs / 100)
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- ---------------------------------------------------------------------
-- unified RAM window cache: the whole session held once at hi-res (base) plus a
-- few finer zoom windows. Any request a cached entry CONTAINS at >= display
-- resolution is served by re-bucketing in RAM (no SD read) — this is what makes
-- zoom-out and coarse pan instant. Only a window finer than every cached entry
-- reads the file, and that result is cached too.
-- ---------------------------------------------------------------------
-- allocate an empty cache entry (min = HUGE, max = -HUGE) for all curves at nb
local function cache_alloc(lv, t0, t1, nb)
  local e = { t0 = t0, t1 = t1, nb = nb,
              span = (t1 - t0 > 0) and (t1 - t0) or 1, min = {}, max = {} }
  for k = 1, #lv.curves do e.min[k] = {}; e.max[k] = {} end
  return e
end

-- coarsest cached entry that fully contains [t0,t1] and is at least as fine as
-- the display (bucket width <= display's), so re-bucketing never upsamples/loses
-- peaks. "Coarsest that qualifies" = fewest source buckets to scan. nil if none.
local function cache_find(lv, t0, t1)
  local dbw = (t1 - t0) / (lv.nbuckets - 1)     -- display bucket width
  if dbw <= 0 then dbw = 1 end
  local best, bestbw
  for i = 1, #lv.cache do
    local e = lv.cache[i]
    if e.t0 <= t0 and e.t1 >= t1 then
      local ebw = e.span / (e.nb - 1)
      if ebw <= dbw and (best == nil or ebw > bestbw) then best, bestbw = e, ebw end
    end
  end
  return best
end

-- register an entry: the base (full session, base_nb) sits at slot 1 and is never
-- evicted; finer windows ring at CACHE_MAX (drop the oldest finer one)
local function cache_add(lv, e)
  if e.nb == lv.base_nb then
    lv.cache[1] = e
  else
    lv.cache[#lv.cache + 1] = e
    while #lv.cache > CACHE_MAX do table.remove(lv.cache, 2) end
  end
end

-- re-bucket one curve from a source cache entry into the display scratch
-- (scr_min/scr_max at nbuckets over the current window). RAM only.
local function rebucket_curve(lv, src, k)
  local nb = lv.nbuckets
  local dmn, dmx = lv.scr_min[k], lv.scr_max[k]
  local smn, smx = src.min[k], src.max[k]
  local wt0, wsp = lv.win_t0, lv.win_span
  local snb, st0, ssp = src.nb, src.t0, src.span
  for i = 1, nb do
    local ta = wt0 + (i - 1) / (nb - 1) * wsp
    local tb = wt0 + i       / (nb - 1) * wsp
    local ja = math.floor((ta - st0) / ssp * (snb - 1)) + 1
    local jb = math.floor((tb - st0) / ssp * (snb - 1)) + 1
    if ja < 1 then ja = 1 end
    if jb > snb then jb = snb end
    if jb < ja then jb = ja end
    local mn, mx = HUGE, -HUGE
    for j = ja, jb do
      local a, b = smn[j], smx[j]
      if a < mn then mn = a end
      if b > mx then mx = b end
    end
    dmn[i], dmx[i] = mn, mx
  end
end

-- start a (re-)extraction of window [t0, t1]; work runs chunked in loader_tick.
-- Served from the RAM cache when possible; otherwise the session base (hi-res) is
-- built once, or a finer window is read and cached.
local function begin_extract(lv, t0, t1)
  local s = lv.sessions[lv.session_i]
  lv.win_t0, lv.win_t1 = t0, t1
  lv.win_span = t1 - t0
  if lv.win_span < 1 then lv.win_span = 1 end
  lv.extract_stop_t = t1
  lv.ext_entry = nil
  local src = cache_find(lv, t0, t1)
  if src ~= nil then                            -- RAM hit: re-bucket only
    lv.rb_src, lv.rb_k = src, 1
    lv.load_phase = "rebkt"
    lv.progress = 0
    return
  end
  -- miss: full window -> build the hi-res base once; else a finer window at
  -- display resolution. Extract straight into a fresh cache entry.
  local full = (t0 <= s.t0 and t1 >= s.t1)
  local e0, e1, nb
  if full then e0, e1, nb = s.t0, s.t1, lv.base_nb
  else         e0, e1, nb = t0, t1, lv.nbuckets end
  local e = cache_alloc(lv, e0, e1, nb)
  lv.ext_entry = e
  lv.tgt_min, lv.tgt_max = e.min, e.max
  lv.ext_t0, lv.ext_span, lv.ext_nb = e0, (e1 - e0 > 0) and (e1 - e0) or 1, nb
  lv.extract_stop_t = e1
  lv.seek_to = index_before(lv, e0)
  lv.prog_base = lv.seek_to.off
  lv.reset_k = 1
  lv.load_phase = "reset"
  lv.progress = 0
end

local function fail(wgt, lv, msg)
  if lv.fh then pcall(io.close, lv.fh) end
  lv.fh = nil
  lv.mode = "browse"
  lv.load_phase = nil
  lv.notice = msg
  wgt.lv_dirty = true
end

-- ---------------------------------------------------------------------
-- envelope polyline (zigzag: per bucket max then min) for curve k.
-- Coordinates are ABSOLUTE page integers (>= 0): LvglWidgetLine::setLine
-- (2.12 source) overwrites the object's x/y with the points' minimum, so a
-- passed x/y offset is ignored — points must carry the chart origin
-- themselves. The tables are handed to lvgl.build as STATIC pts.
-- ---------------------------------------------------------------------
local function build_pts(lv, k)
  local B, h = lv.nbuckets, lv.chart_h
  local X0, Y0 = lv.chart_x, lv.chart_y
  local bmin, bmax = lv.tgt_min[k], lv.tgt_max[k]
  local lo, hi = HUGE, -HUGE
  for i = 1, B do
    if bmin[i] < lo then lo = bmin[i] end
    if bmax[i] > hi then hi = bmax[i] end
  end
  if lo > hi then                       -- no sample of this curve in window
    lv.win_lo[k], lv.win_hi[k] = nil, nil
    lv.pts_cache[k] = EMPTY_PTS
    lv.curve_empty[k] = true
    return
  end
  local pad = (hi - lo) * 0.05
  lo, hi = lo - pad, hi + pad
  if hi - lo < 1e-6 then                -- flat curve -> centered line
    lo = lo - 0.5
    hi = hi + 0.5
  end
  local scale = h / (hi - lo)
  local pts, n = {}, 0
  local lmin, lmax = nil, nil
  for i = 1, B do
    local mn, mx = bmin[i], bmax[i]
    if mn > mx then mn, mx = lmin, lmax end   -- empty bucket: carry last
    if mn ~= nil then
      lmin, lmax = mn, mx
      local x = X0 + (i - 1) * lv.px_per_bucket
      local ya = math.floor(h - (mx - lo) * scale + 0.5)
      local yb = math.floor(h - (mn - lo) * scale + 0.5)
      if ya < 0 then ya = 0 elseif ya > h then ya = h end
      if yb < 0 then yb = 0 elseif yb > h then yb = h end
      n = n + 1
      pts[n] = { x, Y0 + ya }
      n = n + 1
      pts[n] = { x, Y0 + yb }
    end
  end
  lv.win_lo[k], lv.win_hi[k] = lo, hi
  if n >= 2 then
    lv.pts_cache[k] = pts
    lv.curve_empty[k] = false
  else
    lv.pts_cache[k] = EMPTY_PTS
    lv.curve_empty[k] = true
  end
end

-- vertical grid at "round" time steps; recomputed with the pts caches.
-- Absolute coordinates, consumed as STATIC line/label params by build_chart
-- (the chart page is rebuilt whenever a (re-)extraction completes).
local function build_grid(lv)
  local span = lv.win_span
  local steps = { 100, 200, 500, 1000, 3000, 6000, 12000, 30000, 60000, 120000, 300000 }
  local step = steps[#steps]
  for i = 1, #steps do
    if span / steps[i] <= N_GRID then step = steps[i] break end
  end
  local n = 0
  local X0, Y0 = lv.chart_x, lv.chart_y
  local s0 = lv.sessions[lv.session_i].t0
  local t = (math.floor((lv.win_t0 - s0) / step) + 1) * step + s0
  while t < lv.win_t1 and n < N_GRID do
    n = n + 1
    local x = X0 + math.floor(((t - lv.win_t0) / span) * lv.chart_w)
    lv.grid_pts[n] = { { x, Y0 }, { x, Y0 + lv.chart_h } }
    lv.grid_lbl[n] = fmt_mmss(t - s0)
    lv.grid_lx[n] = math.max(0, x - 20)     -- static label x (clamped >= 0)
    lv.grid_on[n] = true
    t = t + step
  end
  for i = n + 1, N_GRID do lv.grid_on[i] = false end
end

-- cursor readout: precompute footer strings (reactive labels only read these)
local function update_cursor(lv, t)
  local s = lv.sessions[lv.session_i]
  if t < lv.win_t0 then t = lv.win_t0 end
  if t > lv.win_t1 then t = lv.win_t1 end
  lv.cursor_t = t
  -- absolute x for the cursor RECT (moved per frame via reactive pos= — the
  -- same pcallUpdate2Int mechanism as the loading bar's size=, HW-verified;
  -- no line object / pts involved)
  lv.cursor_x = lv.chart_x
    + math.floor(((t - lv.win_t0) / lv.win_span) * lv.chart_w)
  local bi = math.floor(((t - lv.win_t0) / lv.win_span) * (lv.nbuckets - 1)) + 1
  if bi < 1 then bi = 1 elseif bi > lv.nbuckets then bi = lv.nbuckets end
  for k = 1, #lv.curves do
    local c = lv.curves[k]
    local v = lv.tgt_max[k][bi]
    if lv.curve_empty[k] or v == nil or v == -HUGE then
      lv.readout[k] = c.name .. " --"
    else
      lv.readout[k] = string.format("%s %g%s", c.name, v, c.unit)
    end
  end
  lv.readout_time = fmt_mmss(t - s.t0)
end

-- ---------------------------------------------------------------------
-- geometry + data arrays + curve-set application (template OR custom pick)
-- ---------------------------------------------------------------------
-- geometry shared by extraction and the chart build (fullscreen page ->
-- LCD_W/LCD_H); idempotent, called once per file
local function init_geometry(wgt, lv)
  local W, H = LCD_W, LCD_H
  local _, th = lcd.sizeText("Ag", (H >= 300) and MIDSIZE or SMLSIZE)
  local _, sh = lcd.sizeText("Ag", SMLSIZE)
  lv.head_h  = th + 8
  -- 2 rows live below the chart: grid time labels + the window/cursor line
  -- (the cursor readouts moved into the in-chart legend box, 2026-07-22 —
  -- frees one row, the chart gets taller)
  lv.foot_h  = sh * 2 + 10
  lv.chart_x = 8
  lv.chart_y = lv.head_h + 4
  lv.chart_w = W - 16
  lv.chart_h = H - lv.head_h - lv.foot_h - 8
  -- 4 px/bucket: halves the polyline point count vs 2 px (TX16S: 196 buckets =
  -- max 392 pts/curve) — less LVGL heap/draw load; the min/max envelope still
  -- reads fine at this resolution
  lv.px_per_bucket = 4
  lv.nbuckets = math.floor(lv.chart_w / lv.px_per_bucket)
  lv.base_nb = lv.nbuckets * BASE_MULT          -- hi-res full-session base cache
  -- curve colors from the host palette (tb_pal.dark: host toolbox_palette)
  local P = wgt.tb_pal
  lv.colors = (P ~= nil and P.dark) and CURVE_COLORS_DARK or CURVE_COLORS_LIGHT
end

-- apply a curve set (from a template or the sensor picker): wanted columns,
-- data arrays (full-session cache + zoom scratch; begin_extract just points
-- tgt_min/tgt_max at one of the two sets)
local function apply_curves(wgt, lv, curves, name)
  lv.curves = curves
  lv.tpl_name = name
  prepare_wanted(lv)
  lv.scr_min, lv.scr_max = {}, {}
  lv.pts_cache, lv.win_lo, lv.win_hi = {}, {}, {}
  lv.curve_empty, lv.readout = {}, {}
  lv.grid_pts, lv.grid_lbl, lv.grid_lx, lv.grid_on = {}, {}, {}, {}
  for k = 1, #curves do
    lv.scr_min[k], lv.scr_max[k] = {}, {}
    lv.pts_cache[k] = EMPTY_PTS
    lv.curve_empty[k] = true
  end
  lv.cache, lv.ext_entry = {}, nil              -- unified RAM window cache (reset)
end

-- pick a template (explicit index or auto: last used, else first matching)
local function setup_template(wgt, lv, tpl_index)
  if lv.templates == nil then
    lv.templates, lv.tpl_broken = load_user_templates()
  end
  local pick = tpl_index
  if pick == nil then
    for i = 1, #lv.templates do
      if #match_template(lv, lv.templates[i]) > 0 then
        if pick == nil then pick = i end
        if wgt.lv_last_tpl ~= nil and lv.templates[i].name == wgt.lv_last_tpl then
          pick = i
          break
        end
      end
    end
  end
  if pick == nil then return false end     -- caller: sensor picker instead
  lv.tpl_i = pick
  init_geometry(wgt, lv)
  apply_curves(wgt, lv, match_template(lv, lv.templates[pick]),
               lv.templates[pick].name)
  return true
end

-- collect the sensor-picker selection (lv.custom_sel, keyed by column index)
-- into an ordered curve list; column order = curve color order
local function custom_curves(lv)
  local curves = {}
  for c = 3, #lv.columns do
    if lv.custom_sel ~= nil and lv.custom_sel[c] then
      curves[#curves + 1] = { name = lv.columns[c].name,
                              unit = lv.columns[c].unit, col = c }
    end
  end
  return curves
end

local function count_sel(lv)
  local n = 0
  if lv.custom_sel ~= nil then
    for _ in pairs(lv.custom_sel) do n = n + 1 end
  end
  return n
end

-- ---------------------------------------------------------------------
-- loader state machine: exactly ONE capped work unit per refresh tick.
-- phases: header -> hparse -> scan -> (sessions?) -> reset -> seek ->
--         extract -> pts.  No getUsage() gating anywhere (in LVGL widgets
-- it returns the LAST cycle's percentage — constant during the current
-- call — so a usage-gated loop never yields and trips "CPU limit"). Each
-- phase instead does a fixed, small amount of work and returns; the next
-- refresh tick (fresh 20k budget) continues where it left off.
-- ---------------------------------------------------------------------
local function loader_tick(wgt, lv)
  local ph = lv.load_phase
  if ph == "header" then
    local r = pump_lines(lv, header_on_line, HEADER_ITERS_TICK)
    if lv.header_line ~= nil then
      lv.load_phase = "hparse"   -- chunked column parse (own capped phase)
    elseif r == "eof" then
      fail(wgt, lv, "File is empty")
    end                          -- "cap": try again next tick
  elseif ph == "hparse" then
    -- parse the header columns in fixed batches (never in one shot -> the
    -- ~100-column single call used to blow the whole budget at once)
    local done = false
    for _ = 1, HPARSE_COLS_TICK do
      if parse_header_col(lv) then done = true break end
    end
    if done then
      lv.header_line = nil
      local cols = lv.columns
      if not (cols[1] ~= nil and cols[1].name == "Date"
          and cols[2] ~= nil and cols[2].name == "Time") then
        fail(wgt, lv, "Not an EdgeTX telemetry log (no Date,Time)")
        return
      end
      -- no auto-extraction anymore: after the scan the user picks what to
      -- display (template page incl. "Pick sensors ..."), so just prepare
      -- geometry + the template list here
      init_geometry(wgt, lv)
      if lv.templates == nil then
        lv.templates, lv.tpl_broken = load_user_templates()
      end
      lv.curves = {}
      lv.custom_sel = {}
      lv.tpl_name = nil
      lv.load_phase = "scan"     -- scan starts NEXT tick (fresh budget)
    end
  elseif ph == "scan" then
    local r = pump_lines(lv, scan_on_line, SCAN_LINES_TICK)
    if lv.fsize > 0 then
      lv.progress = math.floor(lv.file_pos * 100 / lv.fsize)
    end
    if r == "eof" then
      if #lv.sessions == 0 then
        fail(wgt, lv, "No data lines")
        return
      end
      lv.session_i = #lv.sessions          -- default: last session
      lv.load_phase = nil
      -- the scan runs exactly once per file (first open): pick the session
      -- first when there are several, then always ASK what to display
      lv.mode = (#lv.sessions > 1) and "sessions" or "templates"
      wgt.lv_dirty = true
      return
    end
  elseif ph == "reset" then
    -- clear the extraction target one curve per tick (the hi-res base is
    -- BASE_MULT x the display bucket count, too heavy to clear all-in-one)
    local k = lv.reset_k or 1
    local bmin, bmax = lv.tgt_min[k], lv.tgt_max[k]
    for i = 1, lv.ext_nb do bmin[i] = HUGE; bmax[i] = -HUGE end
    if k >= #lv.curves then lv.reset_k = nil; lv.load_phase = "seek"
    else lv.reset_k = k + 1 end
  elseif ph == "seek" then
    local e = lv.seek_to
    io.seek(lv.fh, e.off)
    lv.file_pos = e.off
    lv.buf, lv.bufpos = nil, 1
    lv.cur_date, lv.day = e.date, e.day
    lv.load_phase = "extract"
  elseif ph == "extract" then
    local r = pump_lines(lv, extract_on_line, lv.extract_cap or 8)
    if lv.fsize > lv.prog_base then
      lv.progress = math.floor((lv.file_pos - lv.prog_base) * 100
                               / (lv.fsize - lv.prog_base))
    end
    if r == "eof" or r == "stop" then
      if lv.ext_entry ~= nil then               -- extracted into a cache entry
        cache_add(lv, lv.ext_entry)             -- keep for future RAM reuse
        lv.rb_src, lv.rb_k, lv.ext_entry = lv.ext_entry, 1, nil
        lv.load_phase = "rebkt"                 -- entry -> display buckets
      else                                      -- pan filled scr directly
        lv.pts_k = 1
        lv.load_phase = "pts"
      end
    end
  elseif ph == "rebkt" then
    -- re-bucket the source entry into the display scratch, one curve per tick
    local k = lv.rb_k
    if k > #lv.curves then
      lv.tgt_min, lv.tgt_max = lv.scr_min, lv.scr_max
      lv.pts_k = 1
      lv.load_phase = "pts"
    else
      rebucket_curve(lv, lv.rb_src, k)
      lv.rb_k = k + 1
    end
  elseif ph == "pts" then
    local k = lv.pts_k
    if k > #lv.curves then
      build_grid(lv)
      update_cursor(lv, lv.cursor_t or lv.win_t0)
      lv.load_phase = nil
      lv.progress = 100
      lv.mode = "view"
      wgt.lv_dirty = true    -- ALWAYS rebuild: the chart consumes the fresh
      return                 -- pts/grid tables as STATIC layout params
    end
    build_pts(lv, k)                       -- one curve per tick (heaviest unit)
    lv.pts_k = k + 1
  end
end

-- ---------------------------------------------------------------------
-- file browser data
-- ---------------------------------------------------------------------
-- Parse an EdgeTX SD-log filename "<model>-YYYY-MM-DD[-HHMMSS].csv" into
-- (model, sortkey14). Returns nil for anything that is NOT a telemetry log
-- (e.g. a foreign CSV like "log-viewer.csv" whose header is not Date,Time), so
-- the browser lists ONLY real logs. string.match is a single C call -> cheap
-- enough to run for every .csv during the scan. sortkey = "YYYYMMDDHHMMSS"
-- (date-only names get "000000" seconds) -> a plain ascending string sort orders
-- chronologically for BOTH name forms (the old -21..-5 tail was only "roughly"
-- right for date-only names).
local function parse_log_name(fname)
  local base = string.sub(fname, 1, -5)                 -- strip ".csv"
  local model, y, mo, d, hh, mi, ss = string.match(base,
      "^(.-)%-(%d%d%d%d)%-(%d%d)%-(%d%d)%-(%d%d)(%d%d)(%d%d)$")
  if y ~= nil then return model, y .. mo .. d .. hh .. mi .. ss end
  model, y, mo, d = string.match(base, "^(.-)%-(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y ~= nil then return model, y .. mo .. d .. "000000" end
  return nil, nil
end

-- lv.packed = { "SORTKEY\tMODEL\tFNAME", ... } sorted ascending (default C
-- comparator = chronological). Build the visible fname list from it, honoring
-- the model filter; compute_rows renders reversed so the newest log sits on top.
local function apply_filter(lv)
  local files = {}
  local want = lv.filter_model
  local packed = lv.packed
  for i = 1, #packed do
    local p = packed[i]
    local a = string.find(p, "\t", 1, true)
    local b = string.find(p, "\t", a + 1, true)
    if want == nil or string.sub(p, a + 1, b - 1) == want then
      files[#files + 1] = string.sub(p, b + 1)
    end
  end
  lv.files = files
  lv.scroll = 0
end

-- scan /LOGS CHUNKED over refresh ticks. BUDGET-SENSITIVE: a one-shot scan of
-- the whole folder blew the 20k budget at ~370 files (572 logs on the card) —
-- the "CPU limit" error landed in the surrounding pcall as a spurious "Cannot
-- read /LOGS folder" AND the partial list silently missed the NEWEST logs
-- (dir() order ~ creation order). Now: hold the dir() iterator on lv and
-- process at most SCAN_FILES_TICK names per tick. The SINGLE pass collects the
-- packed master list PLUS per-model log counts (the filter page), so changing
-- the filter never re-scans (apply_filter just re-walks lv.packed). Only real
-- telemetry logs are kept (parse_log_name drops foreign CSVs); total_csv counts
-- every .csv for the "0 logs" diagnostic. The list is RING-capped at MAX_FILES:
-- overflow overwrites the oldest seen entries, so the newest logs always
-- survive (scan_finish re-sorts anyway).
local function scan_begin(lv)
  lv.scan_all = {}
  lv.scan_nall = 0
  lv.scan_total = 0
  lv.scan_models = {}                     -- model name -> log count (for filter)
  local ok, it = pcall(dir, "/LOGS")
  lv.scan_iter = (ok and it ~= nil) and it or nil
end

-- one capped scan tick; returns true when the scan is complete (lv.files set).
-- Phases "pump" -> "sort" -> "filter": the finish work is spread over its OWN
-- ticks — stacking the last pump batch + table.sort + the model list + the
-- 571-entry apply_filter walk in one tick blew the 20k budget ("CPU limit"
-- at apply_filter, HW 2026-07-08).
local function scan_tick(lv)
  local ph = lv.scan_phase
  if ph == nil then
    scan_begin(lv)                        -- begin (incl. dir open) = one tick
    lv.scan_failed = (lv.scan_iter == nil)
    lv.scan_phase = lv.scan_failed and "sort" or "pump"
    return false
  end
  if ph == "pump" then
    local it = lv.scan_iter
    local done = false
    local ok = pcall(function()
      for _ = 1, SCAN_FILES_TICK do
        local fname = it()
        if fname == nil then done = true break end
        if string.lower(string.sub(fname, -4)) == ".csv" then
          lv.scan_total = lv.scan_total + 1
          local mdl, key = parse_log_name(fname)
          if mdl ~= nil then
            lv.scan_nall = lv.scan_nall + 1
            lv.scan_all[((lv.scan_nall - 1) % MAX_FILES) + 1] =
              key .. "\t" .. mdl .. "\t" .. fname
            lv.scan_models[mdl] = (lv.scan_models[mdl] or 0) + 1
          end
        end
      end
    end)
    if not ok then lv.scan_failed = true end   -- keep the partial list + notice
    if not ok or done then lv.scan_phase = "sort" end
    return false
  end
  if ph == "sort" then                    -- sort + model list, ALONE in a tick
    if lv.scan_failed then lv.notice = "Cannot read /LOGS folder" end
    table.sort(lv.scan_all)               -- default C comparator = chronological
    lv.packed    = lv.scan_all
    lv.total_csv = lv.scan_total
    lv.trunc     = lv.scan_nall > MAX_FILES
    local ms = {}
    for name, n in pairs(lv.scan_models) do ms[#ms + 1] = { name = name, n = n } end
    table.sort(ms, function(a, b) return a.name < b.name end)
    lv.models = ms
    lv.scan_phase = "filter"
    return false
  end
  -- "filter": the full-list walk (~600 x ~20 instr), ALONE in a tick
  apply_filter(lv)
  lv.scan_all, lv.scan_iter, lv.scan_models, lv.scan_phase = nil, nil, nil, nil
  return true
end

-- split "<model>-YYYY-MM-DD[-HHMMSS].csv" (model may itself contain '-', so parse
-- the date from the END). Returns model, pretty("06.07.2026 14:32"), key(14-digit
-- sortable "YYYYMMDDHHMMSS"). A name that doesn't parse sorts to the bottom.
-- string.match is a C call (~1 VM instruction), so per-file parsing stays cheap.
-- Used only for the (few) VISIBLE rows in compute_rows, never for the full list.
local function parse_fname(fname)
  local base = string.sub(fname, 1, -5)                 -- strip ".csv"
  local model, y, mo, d, hh, mi, ss = string.match(base,
      "^(.-)%-(%d%d%d%d)%-(%d%d)%-(%d%d)%-(%d%d)(%d%d)(%d%d)$")
  if y ~= nil then
    return model, string.format("%s.%s.%s %s:%s", d, mo, y, hh, mi),
           y .. mo .. d .. hh .. mi .. ss
  end
  model, y, mo, d = string.match(base, "^(.-)%-(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y ~= nil then
    return model, string.format("%s.%s.%s", d, mo, y), y .. mo .. d .. "000000"
  end
  return base, base, "00000000000000"
end

-- precompute visible row strings (fstat only here, NEVER in reactive getters)
local function compute_rows(lv)
  lv.rows = {}
  local nf = #lv.files
  for i = 1, lv.vis_rows or 0 do
    local idx = nf - (lv.scroll + i) + 1
    if idx >= 1 then
      local fname = lv.files[idx]
      local size = lv.fstat_cache[fname]
      if size == nil then
        local st = fstat("/LOGS/" .. fname)
        size = (st ~= nil and st.size ~= nil) and st.size or 0
        lv.fstat_cache[fname] = size
      end
      local model, pretty = parse_fname(fname)
      local text
      if lv.filter_model == nil then               -- unfiltered: show which model
        text = string.format("%s   %s   %d KB", pretty, model, math.floor(size / 1024))
      else
        text = string.format("%s   %d KB", pretty, math.floor(size / 1024))
      end
      lv.rows[i] = { fname = fname, text = text }
    end
  end
end

local function open_file(wgt, lv, fname)
  local path = "/LOGS/" .. fname
  local st = fstat(path)
  local fh = io.open(path, "r")
  if fh == nil or st == nil or st.size == nil then
    if fh then pcall(io.close, fh) end
    lv.notice = "Cannot open file"
    wgt.lv_dirty = true
    return
  end
  lv.fh, lv.path, lv.fname, lv.fsize = fh, path, fname, st.size
  lv.file_pos, lv.buf, lv.bufpos = 0, nil, 1
  lv.columns, lv.curves, lv.header_ok = nil, nil, false
  lv.header_line, lv.hparse_pos, lv.hparse_col = nil, 1, 1   -- chunked header parse state
  lv.custom_sel, lv.sens_vrows, lv.sens_scroll = nil, nil, 0  -- sensor-picker state
  lv.sens_collapsed = nil                                    -- re-init: all collapsed
  lv.tpl_scroll = 0                                          -- template list to top
  lv.sessions, lv.index = {}, {}
  lv.cur_date, lv.day, lv.prev_t, lv.nline = nil, 0, nil, 0
  lv.cursor_t = nil
  lv.notice = nil
  lv.mode = "load"
  lv.load_phase = "header"
  lv.progress = 0
  wgt.lv_dirty = true
end

-- ---------------------------------------------------------------------
-- interaction (zoom / pan / cursor / pickers)
-- ---------------------------------------------------------------------
local function zoom_step(wgt, lv, dir)
  if lv.load_phase ~= nil then return end          -- busy: buttons locked
  local s = lv.sessions[lv.session_i]
  local span = lv.win_t1 - lv.win_t0
  local center = lv.cursor_t
  if center == nil then center = lv.win_t0 + math.floor(span / 2) end
  local new_span
  if dir > 0 then
    new_span = math.floor(span / 2)
    if new_span < MIN_SPAN_CS then new_span = MIN_SPAN_CS end
  else
    new_span = span * 2
  end
  if new_span >= (s.t1 - s.t0) then
    begin_extract(lv, s.t0, s.t1)                  -- full view (cache hit)
    return
  end
  local n0 = center - math.floor(new_span / 2)
  if n0 < s.t0 then n0 = s.t0 end
  local n1 = n0 + new_span
  if n1 > s.t1 then
    n1 = s.t1
    n0 = n1 - new_span
  end
  begin_extract(lv, n0, n1)
end

-- jump straight back to the full-session window (undo all zoom in one tap).
-- begin_extract with the full range is a cache hit, so it's cheap; the guard
-- skips a needless reload flash when the view is already showing everything.
local function zoom_reset(wgt, lv)
  if lv.load_phase ~= nil then return end
  local s = lv.sessions[lv.session_i]
  if lv.win_t0 <= s.t0 and lv.win_t1 >= s.t1 then return end
  begin_extract(lv, s.t0, s.t1)
end

-- Pan by ~half a screen while REUSING the overlapping scratch buckets: shift the
-- scr_min/scr_max arrays by a whole-bucket count (so old bucket i+nsh maps exactly
-- onto new bucket i) and re-extract ONLY the newly exposed edge from the SD file —
-- a fraction of a full window read. Returns false (caller re-extracts normally)
-- when there is no usable overlap: at the session edge or degenerate geometry.
local function begin_pan(lv, dir)
  local s   = lv.sessions[lv.session_i]
  local span = lv.win_span
  local nb  = lv.nbuckets
  local bw  = span / (nb - 1)                 -- time per bucket (float, cs)
  if bw <= 0 or nb < 4 then return false end
  local half = math.floor((nb - 1) / 2)       -- shift ~half the screen
  local avail = (dir > 0) and math.floor((s.t1 - lv.win_t1) / bw)
                          or  math.floor((lv.win_t0 - s.t0) / bw)
  local nsh = (half < avail) and half or avail
  if nsh < 1 or nsh >= nb then return false end   -- at edge / no overlap

  local new_t0 = lv.win_t0 + dir * math.floor(nsh * bw + 0.5)
  if new_t0 < s.t0 then new_t0 = s.t0 end
  local new_t1 = new_t0 + span
  if new_t1 > s.t1 then new_t1 = s.t1; new_t0 = new_t1 - span end

  -- shift the scratch buckets in place; clear only the exposed edge buckets
  for k = 1, #lv.curves do
    local mn, mx = lv.scr_min[k], lv.scr_max[k]
    if dir > 0 then
      for i = 1, nb - nsh do mn[i] = mn[i + nsh]; mx[i] = mx[i + nsh] end
      for i = nb - nsh + 1, nb do mn[i] = HUGE; mx[i] = -HUGE end
    else
      for i = nb, nsh + 1, -1 do mn[i] = mn[i - nsh]; mx[i] = mx[i - nsh] end
      for i = 1, nsh do mn[i] = HUGE; mx[i] = -HUGE end
    end
  end

  lv.win_t0, lv.win_t1, lv.win_span = new_t0, new_t1, span
  lv.tgt_min, lv.tgt_max = lv.scr_min, lv.scr_max
  -- pan extracts into the display scratch at the display window/res; no entry ->
  -- the extract-complete step goes straight to pts (not the cache/rebucket path)
  lv.ext_t0, lv.ext_span, lv.ext_nb, lv.ext_entry = new_t0, span, nb, nil
  local seek_t, stop_t
  if dir > 0 then                              -- exposed edge = right side
    seek_t = new_t0 + (nb - nsh - 1) * bw      -- one bucket before the seam
    stop_t = new_t1
  else                                         -- exposed edge = left side
    seek_t = new_t0
    stop_t = new_t0 + (nsh + 1) * bw           -- one bucket into the reused region
  end
  lv.extract_stop_t = math.floor(stop_t)
  lv.seek_to  = index_before(lv, math.floor(seek_t))
  lv.prog_base = lv.seek_to.off
  lv.load_phase = "seek"                        -- partial reset already done inline
  lv.progress = 0
  return true
end

local function pan_step(wgt, lv, dir)
  if lv.load_phase ~= nil then return end
  local s = lv.sessions[lv.session_i]
  local span = lv.win_t1 - lv.win_t0
  if span >= (s.t1 - s.t0) then return end
  local n0 = lv.win_t0 + math.floor(span / 2) * dir
  if n0 < s.t0 then n0 = s.t0 end
  local n1 = n0 + span
  if n1 > s.t1 then n1 = s.t1; n0 = n1 - span end
  if cache_find(lv, n0, n1) ~= nil then begin_extract(lv, n0, n1); return end  -- RAM hit
  if begin_pan(lv, dir) then return end        -- finer than base: reuse + edge re-extract
  begin_extract(lv, n0, n1)                    -- last resort: full re-extract
end

local function chart_tap(wgt, lv, ts)
  local x = ts.x - lv.chart_x                      -- raw coords (fullscreen)
  if x < 0 then x = 0 elseif x > lv.chart_w then x = lv.chart_w end
  update_cursor(lv, lv.win_t0 + math.floor((x / lv.chart_w) * lv.win_span))
end

-- ---------------------------------------------------------------------
-- UI builders (UltiDash already did lvgl.clear(); adjmap conventions)
-- ---------------------------------------------------------------------
local function palette(wgt)
  local opt = wgt.options or {}
  if opt.TbSun == 1 or opt.TbSun == true then
    return { bg = lcd.RGB(255, 255, 255), accent = lcd.RGB(0, 0, 0),
             hint = lcd.RGB(200, 80, 0), line = lcd.RGB(170, 170, 170),
             text = lcd.RGB(0, 0, 0), textDim = lcd.RGB(120, 120, 120),
             valText = lcd.RGB(0, 0, 0), valHi = lcd.RGB(200, 0, 0),
             bannerBg = lcd.RGB(200, 0, 0), bannerFg = lcd.RGB(255, 255, 255) }
  end
  if wgt.tb_pal then return wgt.tb_pal end
  return { bg = lcd.RGB(0, 0, 0), accent = lcd.RGB(0, 229, 255),
           hint = lcd.RGB(255, 122, 26), line = lcd.RGB(56, 60, 64),
           text = lcd.RGB(240, 240, 240), textDim = lcd.RGB(150, 156, 162),
           valText = lcd.RGB(240, 240, 240), valHi = lcd.RGB(255, 176, 0),
           bannerBg = lcd.RGB(255, 68, 56), bannerFg = lcd.RGB(0, 0, 0) }
end

-- register a tap target; fn(wgt, lv, touch_state), cool = debounce in cs
local function add_hit(lv, x, y, w, h, fn, cool)
  lv.hit[#lv.hit + 1] = { x = x, y = y, w = w, h = h, fn = fn, cool = cool }
end

-- plain-rect button (NO focusable type="button": captures PAGE/RTN)
local function button(lv, layout, P, x, y, w, h, txt, font, fn, enabled_fn)
  layout[#layout + 1] = { type = "rectangle", x = x, y = y, w = w, h = h,
    thickness = 1, rounded = 4,
    color = function()
      if enabled_fn ~= nil and not enabled_fn() then return P.textDim end
      return P.line
    end }
  local _, th = lcd.sizeText(txt, font)
  layout[#layout + 1] = { type = "label", x = x, y = y + (h - th) / 2,
    w = w, h = th, font = font, align = CENTER,
    color = function()
      if enabled_fn ~= nil and not enabled_fn() then return P.textDim end
      return P.text
    end,
    text = txt }
  add_hit(lv, x, y, w, h,
    function(wgt2, lv2, ts)
      if enabled_fn == nil or enabled_fn() then fn(wgt2, lv2, ts) end
    end, 30)
end

local function build_browse(wgt, zone, lv, P)
  local W, H = zone.w, zone.h
  -- the scan runs in M.refresh (own budget); until it finishes just show a hint.
  -- Rendering the full page AND scanning hundreds of files in one build() call
  -- overruns the 20k instruction budget ("CPU limit").
  if lv.files == nil then
    local font0 = (H >= 300) and MIDSIZE or SMLSIZE
    local layout0 = {}
    if P.bg then
      layout0[#layout0 + 1] = { type = "rectangle", filled = true,
        x = 0, y = 0, w = W, h = H, color = P.bg }
    end
    layout0[#layout0 + 1] = { type = "label", x = 0, y = math.floor(H / 2) - 12,
      w = W, h = 24, font = font0, align = CENTER, color = P.text,
      text = "Scanning /LOGS ..." }
    lvgl.build(layout0)
    return
  end
  -- title stays readable (MIDSIZE on the big screen); the LIST rows use SMLSIZE so
  -- more logs fit per page (user request). rowH is measured, not hardcoded, so it
  -- tracks the font height on both the 800x480 and 480x320 targets.
  local titleFont = (H >= 300) and MIDSIZE or SMLSIZE
  local _, tth = lcd.sizeText("Ag", titleFont)
  local _, sh  = lcd.sizeText("Ag", SMLSIZE)
  local headH = tth + 8
  local rowH  = sh + ((H >= 300) and 10 or 6)
  local footH = sh + 4
  lv.row_h    = rowH
  lv.vis_rows = math.max(1, math.floor((H - headH - footH) / rowH))
  compute_rows(lv)

  local sbW  = (#lv.files > lv.vis_rows) and 6 or 0     -- scrollbar gutter
  local rowW = W - 20 - sbW

  local layout = {}
  if P.bg then
    layout[#layout + 1] = { type = "rectangle", filled = true,
      x = 0, y = 0, w = W, h = H, color = P.bg }
  end
  layout[#layout + 1] = { type = "label", x = 6, y = (headH - tth) / 2,
    w = W - 160, h = tth, font = titleFont, color = P.accent, text = "Log Viewer" }
  -- filter button (top-right): shows the active filter, opens the model list
  button(lv, layout, P, W - 148, 3, 140, headH - 6,
    (lv.filter_model or "All models"), SMLSIZE,
    function(wgt2, lv2)
      lv2.fil_scroll = 0
      lv2.mode = "filter"
      wgt2.lv_dirty = true
    end, nil)
  layout[#layout + 1] = { type = "rectangle", filled = true,
    x = 0, y = headH - 1, w = W, h = 1, color = P.line }

  for i = 1, lv.vis_rows do
    local ii = i
    local ry = headH + (i - 1) * rowH
    -- selected/last-opened marker: accent border + accent text (reactive, so
    -- the feedback appears the instant a row is tapped, before the rebuild)
    layout[#layout + 1] = { type = "rectangle", x = 2, y = ry + 1,
      w = rowW + 6, h = rowH - 2, thickness = 1, rounded = 4, color = P.accent,
      visible = function()
        local r = lv.rows[ii]
        return r ~= nil and lv.sel_fname ~= nil and r.fname == lv.sel_fname
      end }
    layout[#layout + 1] = { type = "label", x = 10, y = ry + (rowH - sh) / 2,
      w = rowW, h = sh, font = SMLSIZE,
      color = function()
        local r = lv.rows[ii]
        if r ~= nil and r.fname == lv.sel_fname then return P.accent end
        return P.text
      end,
      text = function()
        local r = lv.rows[ii]
        return (r ~= nil) and r.text or ""
      end }
    add_hit(lv, 0, ry, rowW + 10, rowH,
      function(wgt2, lv2)
        local r = lv2.rows[ii]
        if r ~= nil then
          lv2.sel_fname = r.fname          -- visual feedback (reactive marker)
          open_file(wgt2, lv2, r.fname)
        end
      end, 100)
  end

  -- scrollbar (replaces the ▲/▼ buttons; scroll via touch drag). Plain rects ->
  -- no clickable surface. The thumb follows lv.scroll via reactive pos= (the
  -- HW-verified two-int pcallUpdate2Int path) so scrolling needs NO rebuild.
  if sbW > 0 then
    local trackY = headH + 2
    local trackH = lv.vis_rows * rowH - 4
    local maxs   = math.max(1, #lv.files - lv.vis_rows)
    local thumbH = math.max(16, math.floor(trackH * lv.vis_rows / #lv.files))
    local thumbX = W - 6
    layout[#layout + 1] = { type = "rectangle", filled = true,
      x = W - 5, y = trackY, w = 3, h = trackH, color = P.line }
    layout[#layout + 1] = { type = "rectangle", filled = true, rounded = 2,
      x = thumbX, y = trackY, w = 5, h = thumbH, color = P.accent,
      pos = function()
        return thumbX,
          trackY + math.floor((trackH - thumbH) * (lv.scroll or 0) / maxs)
      end }
  end

  layout[#layout + 1] = { type = "label", x = 6, y = H - sh - 2,
    w = W - 12, h = sh, font = SMLSIZE, color = P.textDim,
    -- memoized: the footer concat/format ran on every LVGL frame; the
    -- inputs only move on scan progress / filter change / notice change
    text = (function()
      local k1, k2, k3, k4, s
      return function()
        local n1, n2, n3 = lv.notice, #lv.files, lv.filter_model
        local n4 = (lv.trunc and 1 or 0) + (lv.tpl_broken and 2 or 0) + (lv.total_csv or 0) * 4
        if s == nil or n1 ~= k1 or n2 ~= k2 or n3 ~= k3 or n4 ~= k4 then
          k1, k2, k3, k4 = n1, n2, n3, n4
          if lv.notice ~= nil then
            s = lv.notice
          elseif #lv.files == 0 then
            -- diagnostic: show the raw CSV count so "0 total" (dir/path issue) is
            -- distinguishable from "filtered to 0" (auto-fallback handles that)
            s = string.format(
              "No logs found (%d CSV in /LOGS). Enable logging: Special Function 'SD Logs'.",
              lv.total_csv or 0)
          else
            s = #lv.files .. " logs"
            if lv.filter_model ~= nil then s = s .. "  -  " .. lv.filter_model end
            if lv.trunc then s = s .. " (list truncated)" end
            if lv.tpl_broken then s = s .. "  -  logtemplates.lua invalid, using defaults" end
          end
        end
        return s
      end
    end)() }
  lvgl.build(layout)
end

-- model-filter page: every model name FOUND in /LOGS (+ "All models"), with
-- log counts; the active choice is marked. Rows + scrollbar thumb are reactive
-- on lv.fil_scroll, so drag-scrolling needs no rebuild (browser pattern).
local function build_filter(wgt, zone, lv, P)
  local W, H = zone.w, zone.h
  local titleFont = (H >= 300) and MIDSIZE or SMLSIZE
  local _, tth = lcd.sizeText("Ag", titleFont)
  local _, sh  = lcd.sizeText("Ag", SMLSIZE)
  local headH = tth + 8
  local rowH  = sh + ((H >= 300) and 10 or 6)
  local n = #lv.models + 1                    -- row 1 = "All models"
  lv.fil_row_h = rowH
  lv.fil_total = n
  lv.fil_vis = math.max(1, math.floor((H - headH - sh - 6) / rowH))
  local maxs = math.max(0, n - lv.fil_vis)
  if (lv.fil_scroll or 0) > maxs then lv.fil_scroll = maxs end
  local sbW = (n > lv.fil_vis) and 6 or 0

  local layout = {}
  if P.bg then
    layout[#layout + 1] = { type = "rectangle", filled = true,
      x = 0, y = 0, w = W, h = H, color = P.bg }
  end
  layout[#layout + 1] = { type = "label", x = 6, y = (headH - tth) / 2,
    w = W - 12, h = tth, font = titleFont, color = P.accent,
    text = "Filter by model" }
  layout[#layout + 1] = { type = "rectangle", filled = true,
    x = 0, y = headH - 1, w = W, h = 1, color = P.line }

  for i = 1, lv.fil_vis do
    local ii = i
    local ry = headH + (i - 1) * rowH
    layout[#layout + 1] = { type = "label", x = 10, y = ry + (rowH - sh) / 2,
      w = W - 20 - sbW, h = sh, font = SMLSIZE,
      color = function()
        local idx = (lv.fil_scroll or 0) + ii
        if idx == 1 then
          return (lv.filter_model == nil) and P.accent or P.text
        end
        local m = lv.models[idx - 1]
        if m ~= nil and m.name == lv.filter_model then return P.accent end
        return P.text
      end,
      -- memoized: row content only changes on scroll / filter pick /
      -- rescan — the concat ran per visible row on every LVGL frame before
      text = (function()
        local k1, k2, k3, s
        return function()
          local n1, n2, n3 = (lv.fil_scroll or 0) + ii, lv.filter_model, #(lv.packed or {})
          if s == nil or n1 ~= k1 or n2 ~= k2 or n3 ~= k3 then
            k1, k2, k3 = n1, n2, n3
            if n1 == 1 then
              local mark = (lv.filter_model == nil) and "[x] " or "[  ] "
              s = mark .. "All models (" .. n3 .. ")"
            else
              local m = lv.models[n1 - 1]
              if m == nil then
                s = ""
              else
                local mark = (m.name == lv.filter_model) and "[x] " or "[  ] "
                s = mark .. m.name .. " (" .. m.n .. ")"
              end
            end
          end
          return s
        end
      end)() }
    add_hit(lv, 0, ry, W - sbW, rowH,
      function(wgt2, lv2)
        local idx = (lv2.fil_scroll or 0) + ii
        if idx == 1 then
          lv2.filter_model = nil
        else
          local m = lv2.models[idx - 1]
          if m == nil then return end
          lv2.filter_model = m.name
        end
        apply_filter(lv2)
        lv2.mode = "browse"
        wgt2.lv_dirty = true
      end, 50)
  end

  if sbW > 0 then
    local trackY = headH + 2
    local trackH = lv.fil_vis * rowH - 4
    local thumbH = math.max(16, math.floor(trackH * lv.fil_vis / n))
    local thumbX = W - 6
    layout[#layout + 1] = { type = "rectangle", filled = true,
      x = W - 5, y = trackY, w = 3, h = trackH, color = P.line }
    layout[#layout + 1] = { type = "rectangle", filled = true, rounded = 2,
      x = thumbX, y = trackY, w = 5, h = thumbH, color = P.accent,
      pos = function()
        return thumbX,
          trackY + math.floor((trackH - thumbH) * (lv.fil_scroll or 0) / maxs)
      end }
  end
  layout[#layout + 1] = { type = "label", x = 6, y = H - sh - 2,
    w = W - 12, h = sh, font = SMLSIZE, color = P.textDim,
    text = "Tap to filter - drag to scroll - RTN to cancel" }
  lvgl.build(layout)
end

local function build_loading(wgt, zone, lv, P)
  local W, H = zone.w, zone.h
  local font = (H >= 300) and MIDSIZE or SMLSIZE
  local _, th = lcd.sizeText("Ag", font)
  local _, sh = lcd.sizeText("Ag", SMLSIZE)
  local bw = math.floor(W * 0.7)
  local bx = math.floor((W - bw) / 2)
  local by = math.floor(H / 2)
  -- two SEPARATE lines above the bar (a long raw filename used to wrap into
  -- a second line that the bar overdrew): title, then model + pretty date
  local model, pretty = parse_fname(lv.fname or "")
  local layout = {}
  if P.bg then
    layout[#layout + 1] = { type = "rectangle", filled = true,
      x = 0, y = 0, w = W, h = H, color = P.bg }
  end
  layout[#layout + 1] = { type = "label", x = 0, y = by - th - sh - 20, w = W,
    h = th, font = font, align = CENTER, color = P.text,
    text = "Loading log" }
  layout[#layout + 1] = { type = "label", x = 0, y = by - sh - 10, w = W,
    h = sh, font = SMLSIZE, align = CENTER, color = P.textDim,
    text = (model or "") .. "   " .. (pretty or "") }
  layout[#layout + 1] = { type = "rectangle", x = bx, y = by, w = bw, h = 14,
    thickness = 1, color = P.line }
  -- reactive size= (returns w, h) — HW-VERIFIED 2026-07-08 (bar animates);
  -- pcallUpdate2Int in lua_lvgl_widget.cpp, same mechanism as the chart cursor's pos=
  layout[#layout + 1] = { type = "rectangle", filled = true,
    x = bx + 2, y = by + 2, h = 10, color = P.accent,
    w = 1,
    size = function()
      local p = lv.progress or 0
      local w = math.floor((bw - 4) * p / 100)
      if w < 1 then w = 1 end
      return w, 10
    end }
  layout[#layout + 1] = { type = "label", x = 0, y = by + 22, w = W, h = th,
    font = SMLSIZE, align = CENTER, color = P.textDim,
    text = function() return (lv.progress or 0) .. " %  (RTN cancels)" end }
  lvgl.build(layout)
end

-- generic list page (sessions / templates)
local function build_list(wgt, zone, lv, P, title, count, row_text, on_pick)
  local W, H = zone.w, zone.h
  local font = (H >= 300) and MIDSIZE or SMLSIZE
  local _, th = lcd.sizeText("Ag", font)
  local headH = th + 8
  local rowH = (H >= 300) and 44 or 34
  local layout = {}
  if P.bg then
    layout[#layout + 1] = { type = "rectangle", filled = true,
      x = 0, y = 0, w = W, h = H, color = P.bg }
  end
  layout[#layout + 1] = { type = "label", x = 6, y = (headH - th) / 2,
    w = W - 12, h = th, font = font, color = P.accent, text = title }
  layout[#layout + 1] = { type = "rectangle", filled = true,
    x = 0, y = headH - 1, w = W, h = 1, color = P.line }
  local vis = math.floor((H - headH - 4) / rowH)
  for i = 1, math.min(vis, count) do
    local ii = i
    local ry = headH + (i - 1) * rowH
    local txt, enabled = row_text(ii)
    layout[#layout + 1] = { type = "label", x = 10, y = ry + (rowH - th) / 2,
      w = W - 20, h = th, font = font,
      color = enabled and P.text or P.textDim, text = txt }
    if enabled then
      add_hit(lv, 0, ry, W, rowH,
        function(wgt2, lv2) on_pick(wgt2, lv2, ii) end, 100)
    end
  end
  lvgl.build(layout)
end

local function build_sessions(wgt, zone, lv, P)
  build_list(wgt, zone, lv, P, "Select session", #lv.sessions,
    function(i)
      local s = lv.sessions[i]
      return string.format("Session %d   start %s   length %s   (%d lines)",
        i, fmt_mmss(s.t0 - lv.sessions[1].t0), fmt_mmss(s.t1 - s.t0), s.lines),
        true
    end,
    function(wgt2, lv2, i)
      lv2.session_i = i
      lv2.cache = {}
      lv2.cursor_t = nil
      if lv2.curves ~= nil and #lv2.curves > 0 then
        -- mid-view session switch (chart header): curves already chosen
        local s = lv2.sessions[i]
        lv2.mode = "load"
        begin_extract(lv2, s.t0, s.t1)
      else
        lv2.mode = "templates"             -- first open: pick what to display
      end
      wgt2.lv_dirty = true
    end)
end

-- template chooser as CARDS in a TWO-COLUMN grid (uses the width, halves the
-- rows: the stock 6 cards fit both radios WITHOUT scrolling): each built-in
-- set + a distinct "Custom sensors" card. A card = rounded border + accent
-- side-bar + name + sub-line (how many of its sensors the log has) + a "last
-- used" badge. Disabled (dim, no tap) when none of its sensors are in the log.
-- Cards keep their two-line height; with MANY user templates the page scrolls
-- by ROW (drag + scrollbar; rebuild per step — the hit rects move. NOTE the
-- host gives a dirty rebuild an exclusive tick, so a scroll step costs ~2
-- ticks; acceptable here since scrolling only kicks in past ~8 templates).
local function build_templates(wgt, zone, lv, P)
  local W, H = zone.w, zone.h
  local titleFont = (H >= 300) and MIDSIZE or SMLSIZE
  local nameFont  = (H >= 300) and MIDSIZE or SMLSIZE
  local _, tth = lcd.sizeText("Ag", titleFont)
  local _, nh  = lcd.sizeText("Ag", nameFont)
  local _, sh  = lcd.sizeText("Ag", SMLSIZE)
  local headH  = tth + 8
  local n = #lv.templates + 1                       -- +1 = the custom card
  local gap = (H >= 300) and 8 or 5
  local avail = H - headH - 6
  local nrows = math.ceil(n / 2)
  local cardH = math.floor((avail - (nrows - 1) * gap) / nrows)
  local capH = (H >= 300) and 64 or 48
  if cardH > capH then cardH = capH end
  local minH = nh + sh + ((H >= 300) and 12 or 8)   -- two lines must fit
  if cardH < minH then cardH = minH end
  local step = cardH + gap
  local vis  = math.max(1, math.floor((avail + gap) / step))
  local maxs = math.max(0, nrows - vis)
  lv.tpl_row_h = step
  lv.tpl_total = nrows
  lv.tpl_vis   = vis
  if (lv.tpl_scroll or 0) > maxs then lv.tpl_scroll = maxs end
  local top = lv.tpl_scroll or 0
  local sbW = (nrows > vis) and 8 or 0

  local layout = {}
  if P.bg then
    layout[#layout + 1] = { type = "rectangle", filled = true,
      x = 0, y = 0, w = W, h = H, color = P.bg }
  end
  layout[#layout + 1] = { type = "label", x = 6, y = (headH - tth) / 2,
    w = W - 12, h = tth, font = titleFont, color = P.accent,
    text = "What to display?" }
  layout[#layout + 1] = { type = "rectangle", filled = true,
    x = 0, y = headH - 1, w = W, h = 1, color = P.line }

  local cardW = math.floor((W - 12 - sbW - gap) / 2)
  local wide  = cardW >= 300                        -- room for the long sub text
  for r = 1, vis do
    for c = 1, 2 do
      local idx = (top + r - 1) * 2 + c
      if idx <= n then
        local cx0 = 6 + (c - 1) * (cardW + gap)
        local cy0 = headH + 4 + (r - 1) * step
        local custom = (idx > #lv.templates)
        local name, sub, enabled, accent
        if custom then
          name = "Custom sensors"
          sub  = wide and "pick your own set from the log" or "pick your own set"
          enabled = true
          accent = P.hint
        else
          local t = lv.templates[idx]
          local cnt = #match_template(lv, t)
          name = t.name
          sub  = wide and string.format("%d of %d sensors in this log", cnt, #t.curves)
                 or string.format("%d of %d sensors in log", cnt, #t.curves)
          enabled = (cnt > 0)
          accent = enabled and P.accent or P.textDim
        end
        -- card border + accent side-bar
        layout[#layout + 1] = { type = "rectangle", x = cx0, y = cy0, w = cardW,
          h = cardH, rounded = 6, thickness = 1, color = P.line }
        layout[#layout + 1] = { type = "rectangle", filled = true, rounded = 3,
          x = cx0 + 3, y = cy0 + 4, w = 5, h = cardH - 8, color = accent }
        -- name + sub
        local ty = cy0 + math.floor((cardH - nh - sh) / 2)
        layout[#layout + 1] = { type = "label", x = cx0 + 20, y = ty,
          w = cardW - 26, h = nh, font = nameFont,
          color = enabled and P.text or P.textDim, text = name }
        layout[#layout + 1] = { type = "label", x = cx0 + 20, y = ty + nh,
          w = cardW - 26, h = sh, font = SMLSIZE, color = P.textDim, text = sub }
        if enabled then
          local ti = idx
          add_hit(lv, cx0, cy0, cardW, cardH,
            function(wgt2, lv2)
              if ti > #lv2.templates then
                -- prefill the picker with the currently shown curves
                lv2.custom_sel = {}
                for k = 1, #(lv2.curves or {}) do
                  lv2.custom_sel[lv2.curves[k].col] = true
                end
                lv2.sens_selgen = (lv2.sens_selgen or 0) + 1   -- invalidate the group counters
                lv2.sens_scroll = 0
                lv2.mode = "sensors"
                wgt2.lv_dirty = true
                return
              end
              if not setup_template(wgt2, lv2, ti) then return end
              lv2.cache = {}
              lv2.cursor_t = nil
              local s = lv2.sessions[lv2.session_i]
              lv2.mode = "load"
              begin_extract(lv2, s.t0, s.t1)
              wgt2.lv_dirty = true
            end, 100)
        end
      end
    end
  end

  -- scrollbar (indicator only, like the other pages)
  if sbW > 0 then
    local trackY = headH + 4
    local trackH = vis * step - gap
    local thumbH = math.max(16, math.floor(trackH * vis / nrows))
    local thumbY = trackY + math.floor((trackH - thumbH) * top / maxs)
    layout[#layout + 1] = { type = "rectangle", filled = true,
      x = W - 5, y = trackY, w = 3, h = trackH, color = P.line }
    layout[#layout + 1] = { type = "rectangle", filled = true, rounded = 2,
      x = W - 6, y = thumbY, w = 5, h = thumbH, color = P.accent }
  end
  lvgl.build(layout)
end

-- top-bar layout toggle tab (active = filled accent, like the RF configurator's
-- Sort/Select). Static per build: tapping it flips lv.sens_layout AND rebuilds,
-- so the appearance never needs a reactive color (which is unproven on a FILLED
-- rect here — the switch below uses the verified visible=/pos= path instead).
local function layout_tab(lv, layout, P, x, y, w, h, txt, mine)
  local active = (lv.sens_layout == mine)
  layout[#layout + 1] = { type = "rectangle", filled = true, rounded = 4,
    x = x, y = y, w = w, h = h, color = active and P.accent or (P.btnBg or P.line) }
  local _, th = lcd.sizeText(txt, SMLSIZE)
  layout[#layout + 1] = { type = "label", x = x, y = y + (h - th) / 2, w = w, h = th,
    font = SMLSIZE, align = CENTER,
    color = active and (P.bg or lcd.RGB(0, 0, 0)) or P.text, text = txt }
  add_hit(lv, x, y, w, h,
    function(wgt2, lv2)
      if lv2.sens_layout ~= mine then
        lv2.sens_layout = mine
        wgt2.lv_sens_layout = mine     -- remembered for the next file this session
        lv2.sens_vrows = nil           -- structure changed -> rebuild vrows
        wgt2.lv_dirty = true
      end
    end, 30)
end

-- sensor picker: log columns GROUPED by category (RF link / Battery / Power /
-- ESC / Temperature / ... like the RF configurator). Two layouts, switched by
-- the top [List][Grid] tabs (lv.sens_layout, remembered on wgt.lv_sens_layout):
--   "list"  one sensor per full-width row + a drawn iOS-style toggle switch
--   "grid"  the compact multi-column [x] cells (the original look)
-- Groups are COLLAPSIBLE: tapping a header band folds it away (lv.sens_collapsed);
-- the band shows a live selected/available counter. Max MAX_CURVES picked. A flat
-- "visual row" list is windowed by scroll. Toggle/collapse states are reactive
-- (labels, switch overlay/knob) so toggling needs NO rebuild; changing the
-- layout, collapse set or scroll rebuilds (structure / hit rects change).
local function build_sensors(wgt, zone, lv, P)
  local W, H = zone.w, zone.h
  local titleFont = (H >= 300) and MIDSIZE or SMLSIZE
  local _, tth = lcd.sizeText("Ag", titleFont)
  local _, sh  = lcd.sizeText("Ag", SMLSIZE)
  local headH = tth + 8
  local rowH  = sh + ((H >= 300) and 10 or 6)
  lv.sens_layout = lv.sens_layout or wgt.lv_sens_layout or "list"
  local grid  = (lv.sens_layout == "grid")
  local ncols = grid and ((W >= 700) and 3 or 2) or 1
  if lv.sens_vrows == nil or lv.sens_vrows_ncols ~= ncols then
    build_sensor_vrows(lv, lv.sens_layout, ncols)
  end
  local vrows = lv.sens_vrows
  lv.sens_row_h = rowH
  lv.sens_rows_total = #vrows
  lv.sens_vis = math.max(1, math.floor((H - headH - sh - 6) / rowH))
  local maxs = math.max(0, #vrows - lv.sens_vis)
  if (lv.sens_scroll or 0) > maxs then lv.sens_scroll = maxs end
  local top = lv.sens_scroll or 0

  local band  = P.btnDim or P.line       -- group-header band surface
  local swOff = P.btnBg or P.line        -- switch track when off
  local knobC = P.bg or lcd.RGB(0, 0, 0) -- knob contrasts BOTH track states

  local layout = {}
  if P.bg then
    layout[#layout + 1] = { type = "rectangle", filled = true,
      x = 0, y = 0, w = W, h = H, color = P.bg }
  end
  -- top bar: title | [List][Grid] tabs | count | Show
  local showW = (W >= 700) and 96 or 84
  local showX = W - showW - 8
  local cntW  = 52
  local cntX  = showX - 6 - cntW
  local tabW  = (W >= 700) and 66 or 54
  local tabsX = cntX - 8 - 2 * tabW
  layout[#layout + 1] = { type = "label", x = 6, y = (headH - tth) / 2,
    w = tabsX - 12, h = tth, font = titleFont, color = P.accent, text = "Sensors" }
  layout_tab(lv, layout, P, tabsX,          4, tabW, headH - 8, "List", "list")
  layout_tab(lv, layout, P, tabsX + tabW,   4, tabW, headH - 8, "Grid", "grid")
  layout[#layout + 1] = { type = "label", x = cntX, y = (headH - sh) / 2,
    w = cntW, h = sh, font = SMLSIZE, align = RIGHT, color = P.hint,
    text = function() return count_sel(lv) .. "/" .. MAX_CURVES end }
  -- apply button: extract the picked set (enabled once >= 1 sensor picked)
  button(lv, layout, P, showX, 3, showW, headH - 6, "Show", SMLSIZE,
    function(wgt2, lv2)
      local curves = custom_curves(lv2)
      if #curves == 0 then return end
      apply_curves(wgt2, lv2, curves, CUSTOM_NAME)
      lv2.cache = {}
      lv2.cursor_t = nil
      local s = lv2.sessions[lv2.session_i]
      lv2.mode = "load"
      begin_extract(lv2, s.t0, s.t1)
      wgt2.lv_dirty = true
    end,
    function() return count_sel(lv) > 0 end)
  layout[#layout + 1] = { type = "rectangle", filled = true,
    x = 0, y = headH - 1, w = W, h = 1, color = P.line }

  local sbW = (#vrows > lv.sens_vis) and 8 or 0
  local contentR = W - sbW - 4           -- right edge of row content
  local cellW = math.floor((W - sbW - 8) / ncols)
  for i = 1, lv.sens_vis do
    local vr = vrows[top + i]
    if vr ~= nil then
      local ry = headH + (i - 1) * rowH
      if vr.header ~= nil then
        -- collapsible group header: full-width band, [-]/[+] marker + name on
        -- the left, live selected/available count (reactive) on the right
        local gi = vr.header
        local collapsed = lv.sens_collapsed ~= nil and lv.sens_collapsed[gi]
        layout[#layout + 1] = { type = "rectangle", filled = true,
          x = 0, y = ry, w = W, h = rowH, color = band }
        layout[#layout + 1] = { type = "label", x = 10, y = ry + (rowH - sh) / 2,
          w = W - 90 - sbW, h = sh, font = SMLSIZE, color = P.text,
          text = (collapsed and "[+] " or "[-] ") .. SENSOR_GROUPS[gi].name }
        layout[#layout + 1] = { type = "label", x = W - 74 - sbW,
          y = ry + (rowH - sh) / 2, w = 64, h = sh, font = SMLSIZE,
          align = RIGHT, color = P.textDim,
          -- memoized on the selection GENERATION: the bucket loop +
          -- concat ran per header on every frame; sens_selgen bumps in the tap
          -- handlers that mutate custom_sel, so the recount runs once per toggle
          text = (function()
            local kg, s
            return function()
              local g = lv.sens_selgen or 0
              if s == nil or g ~= kg then
                kg = g
                local b = lv.sens_buckets ~= nil and lv.sens_buckets[gi]
                if b == nil then
                  s = ""
                else
                  local sel = 0
                  for k = 1, #b do
                    if lv.custom_sel ~= nil and lv.custom_sel[b[k]] then sel = sel + 1 end
                  end
                  s = sel .. "/" .. #b
                end
              end
              return s
            end
          end)() }
        add_hit(lv, 0, ry, W - sbW, rowH,
          function(wgt2, lv2)
            lv2.sens_collapsed = lv2.sens_collapsed or {}
            lv2.sens_collapsed[gi] = (not lv2.sens_collapsed[gi]) or nil
            lv2.sens_vrows = nil           -- fold/unfold -> rebuild vrows
            wgt2.lv_dirty = true
          end, 30)
      elseif vr.col ~= nil then
        -- LIST row: sensor name (left) + drawn toggle switch (right). The switch
        -- is off-track (static) + on-overlay (visible= when selected) + knob
        -- (pos= slides left/right) — the HW-verified reactive paths, so toggling
        -- needs no rebuild. No real lvgl.toggle: it would capture PAGE/RTN.
        local cc = vr.col
        local col = lv.columns[cc]
        local lbl = col.name
        if col.unit ~= "" then lbl = lbl .. " (" .. col.unit .. ")" end
        local swH   = math.min(18, rowH - 6)
        local swW   = swH * 2
        local knobD = swH - 4
        local swX   = contentR - swW
        local swY   = ry + math.floor((rowH - swH) / 2)
        layout[#layout + 1] = { type = "label", x = 14, y = ry + (rowH - sh) / 2,
          w = swX - 20, h = sh, font = SMLSIZE,
          color = function()
            return (lv.custom_sel ~= nil and lv.custom_sel[cc]) and P.accent or P.text
          end,
          text = lbl }
        layout[#layout + 1] = { type = "rectangle", filled = true,
          rounded = math.floor(swH / 2), x = swX, y = swY, w = swW, h = swH,
          color = swOff }
        layout[#layout + 1] = { type = "rectangle", filled = true,
          rounded = math.floor(swH / 2), x = swX, y = swY, w = swW, h = swH,
          color = P.accent,
          visible = function()
            return lv.custom_sel ~= nil and lv.custom_sel[cc] == true
          end }
        layout[#layout + 1] = { type = "rectangle", filled = true,
          rounded = math.floor(knobD / 2), x = swX + 2, y = swY + 2,
          w = knobD, h = knobD, color = knobC,
          pos = function()
            local on = lv.custom_sel ~= nil and lv.custom_sel[cc]
            return (on and (swX + swW - knobD - 2) or (swX + 2)), swY + 2
          end }
        add_hit(lv, 0, ry, contentR, rowH,
          function(wgt2, lv2)
            lv2.custom_sel = lv2.custom_sel or {}
            if lv2.custom_sel[cc] then
              lv2.custom_sel[cc] = nil
            elseif count_sel(lv2) < MAX_CURVES then
              lv2.custom_sel[cc] = true
            end
            lv2.sens_selgen = (lv2.sens_selgen or 0) + 1   -- invalidate the group counters
          end, 25)
      else
        -- GRID row: the original compact [x] cells (the "second option")
        for j = 1, ncols do
          local c = vr.cols[j]
          if c ~= nil then
            local cc = c
            local rx = 4 + (j - 1) * cellW
            local col = lv.columns[c]
            local lbl = col.name
            if col.unit ~= "" then lbl = lbl .. " (" .. col.unit .. ")" end
            layout[#layout + 1] = { type = "label", x = rx + 6,
              y = ry + (rowH - sh) / 2, w = cellW - 12, h = sh, font = SMLSIZE,
              color = function()
                return (lv.custom_sel ~= nil and lv.custom_sel[cc]) and P.accent or P.text
              end,
              -- memoized on the selected state: the mark concat ran per
              -- cell on every frame
              text = (function()
                local kb, s
                return function()
                  local on = lv.custom_sel ~= nil and lv.custom_sel[cc] == true
                  if s == nil or on ~= kb then
                    kb = on
                    s = (on and "[x] " or "[  ] ") .. lbl
                  end
                  return s
                end
              end)() }
            add_hit(lv, rx, ry, cellW, rowH,
              function(wgt2, lv2)
                lv2.custom_sel = lv2.custom_sel or {}
                if lv2.custom_sel[cc] then
                  lv2.custom_sel[cc] = nil
                elseif count_sel(lv2) < MAX_CURVES then
                  lv2.custom_sel[cc] = true
                end
                lv2.sens_selgen = (lv2.sens_selgen or 0) + 1   -- invalidate the group counters
              end, 25)
          end
        end
      end
    end
  end

  -- scrollbar (indicator only, like the browser)
  if sbW > 0 then
    local trackY = headH + 2
    local trackH = lv.sens_vis * rowH - 4
    local thumbH = math.max(16, math.floor(trackH * lv.sens_vis / #vrows))
    local thumbY = trackY + math.floor((trackH - thumbH) * top / maxs)
    layout[#layout + 1] = { type = "rectangle", filled = true,
      x = W - 5, y = trackY, w = 3, h = trackH, color = P.line }
    layout[#layout + 1] = { type = "rectangle", filled = true, rounded = 2,
      x = W - 6, y = thumbY, w = 5, h = thumbH, color = P.accent }
  end
  layout[#layout + 1] = { type = "label", x = 6, y = H - sh - 2,
    w = W - 12, h = sh, font = SMLSIZE, color = P.textDim,
    text = "Tap sensor/switch - tap group to fold - drag to scroll - RTN when done" }
  lvgl.build(layout)
end

local function build_chart(wgt, zone, lv, P)
  local W, H = zone.w, zone.h
  local font = (H >= 300) and MIDSIZE or SMLSIZE
  local _, th = lcd.sizeText("Ag", font)
  local _, sh = lcd.sizeText("Ag", SMLSIZE)
  local cx, cy, cw, ch = lv.chart_x, lv.chart_y, lv.chart_w, lv.chart_h
  local thick = (H >= 300) and 2 or 1
  local layout = {}
  if P.bg then
    layout[#layout + 1] = { type = "rectangle", filled = true,
      x = 0, y = 0, w = W, h = H, color = P.bg }
  end

  -- header: model + date/time on the left; template (and session, if any) as
  -- BORDERED CHIPS -- same rounded outline as the zoom buttons so it's clear they
  -- open a picker (was bare orange text, easy to miss) -- then the zoom cluster
  -- (100% / - / +) on the right. Chips are sized to their content (not fixed-wide)
  -- so the name label keeps all remaining room (the time was clipping on the TX15).
  local busy = function() return lv.load_phase == nil end
  local zb = (H >= 300) and 48 or 38
  local rzb = (H >= 300) and 56 or 42               -- "100%" reset button (a bit wider)
  local hy, hh = 2, lv.head_h - 4                    -- chip / button box geometry
  local multi = (#lv.sessions > 1)
  local tplW  = lcd.sizeText("Governor", SMLSIZE) + 16   -- widest builtin label + pad
  local sessW = multi and (lcd.sizeText("S9", SMLSIZE) + 14) or 0
  local cluster_x = W - 2 * zb - rzb - 18            -- left edge of the 100% button
  local sess_x = cluster_x - 8 - sessW
  local tpl_x  = (multi and sess_x or cluster_x) - 8 - tplW
  local model, pretty = parse_fname(lv.fname or "")
  local hdrname = model or (lv.fname or "")
  if pretty ~= nil and pretty ~= "" and pretty ~= model then
    hdrname = model .. "   " .. pretty
  end
  -- guarantee the date+time stays readable: if "model + date time" doesn't fit the
  -- room left of the chips (long model name / narrow TX15), drop the model rather
  -- than clip the time off the end
  local name_w = tpl_x - 12
  if pretty ~= nil and pretty ~= "" and lcd.sizeText(hdrname, SMLSIZE) > name_w then
    hdrname = pretty
  end
  layout[#layout + 1] = { type = "label", x = 6, y = (lv.head_h - sh) / 2,
    w = name_w, h = sh, font = SMLSIZE, color = P.text, text = hdrname }
  -- template chip (bordered; orange = the current selection) -> template picker
  layout[#layout + 1] = { type = "rectangle", x = tpl_x, y = hy, w = tplW, h = hh,
    thickness = 1, rounded = 4, color = P.line }
  layout[#layout + 1] = { type = "label", x = tpl_x, y = (lv.head_h - sh) / 2,
    w = tplW, h = sh, font = SMLSIZE, align = CENTER, color = P.hint,
    text = function() return lv.tpl_name or "?" end }
  add_hit(lv, tpl_x, 0, tplW, lv.head_h,
    function(wgt2, lv2)
      lv2.mode = "templates"
      wgt2.lv_dirty = true
    end, 100)
  if multi then
    layout[#layout + 1] = { type = "rectangle", x = sess_x, y = hy, w = sessW, h = hh,
      thickness = 1, rounded = 4, color = P.line }
    layout[#layout + 1] = { type = "label", x = sess_x, y = (lv.head_h - sh) / 2,
      w = sessW, h = sh, font = SMLSIZE, align = CENTER, color = P.accent,
      text = function() return "S" .. lv.session_i end }
    add_hit(lv, sess_x, 0, sessW, lv.head_h,
      function(wgt2, lv2)
        lv2.mode = "sessions"
        wgt2.lv_dirty = true
      end, 100)
  end
  -- reset-to-full (SMLSIZE so "100%" fits the button on both radios); left of -/+
  button(lv, layout, P, cluster_x, hy, rzb, hh, "100%", SMLSIZE,
    function(wgt2, lv2) zoom_reset(wgt2, lv2) end, busy)
  button(lv, layout, P, W - 2 * zb - 12, hy, zb, hh, "-", font,
    function(wgt2, lv2) zoom_step(wgt2, lv2, -1) end, busy)
  button(lv, layout, P, W - zb - 6, hy, zb, hh, "+", font,
    function(wgt2, lv2) zoom_step(wgt2, lv2, 1) end, busy)
  layout[#layout + 1] = { type = "rectangle", filled = true,
    x = 0, y = lv.head_h - 1, w = W, h = 1, color = P.line }

  -- chart background + horizontal grid (static)
  layout[#layout + 1] = { type = "rectangle", x = cx - 1, y = cy - 1,
    w = cw + 2, h = ch + 2, thickness = 1, color = P.line }
  for i = 1, 3 do
    layout[#layout + 1] = { type = "hline", x = cx,
      y = cy + math.floor(ch * i / 4), w = cw, h = 1, color = P.line,
      opacity = 96 }
  end
  -- vertical grid + curves: STATIC pts tables (absolute coords), rebuilt via
  -- lv_dirty whenever a (re-)extraction completes. Deliberately NOT reactive
  -- pts= functions: their per-frame path (getPts/getPt in lua_lvgl_widget.cpp)
  -- reads the table OUTSIDE any pcall — one luaL_check* hiccup there is a
  -- firmware PANIC (radio "emergency mode", seen 2026-07-08) — and re-hashes /
  -- reallocs hundreds of points every frame. Static params are read once at
  -- build time, inside the protected build call.
  for i = 1, N_GRID do
    if lv.grid_on[i] == true and lv.grid_pts[i] ~= nil then
      layout[#layout + 1] = { type = "line", color = P.line,
        thickness = 1, opacity = 96, pts = lv.grid_pts[i] }
      layout[#layout + 1] = { type = "label", x = lv.grid_lx[i] or cx,
        y = cy + ch + 2, w = 60, h = sh, font = SMLSIZE, color = P.textDim,
        text = lv.grid_lbl[i] or "" }
    end
  end
  for k = 1, #lv.curves do
    if lv.curve_empty[k] ~= true then
      layout[#layout + 1] = { type = "line", color = lv.colors[k],
        thickness = thick, pts = lv.pts_cache[k] }
    end
  end

  -- cursor: a 1-px filled rect moved via reactive pos= (pcallUpdate2Int — the
  -- same verified two-int mechanism as the loading bar's size=). No line/pts.
  layout[#layout + 1] = { type = "rectangle", filled = true,
    x = lv.cursor_x or cx, y = cy, w = 1, h = ch, color = P.valHi,
    pos = function() return (lv.cursor_x or cx), cy end }
  add_hit(lv, cx, cy, cw, ch, chart_tap, 10)

  -- zoom/pan re-extraction progress: a thin bar growing along the chart top
  -- (reactive size= + visible=, both HW-verified). The previous window's
  -- curves stay on screen while the new one loads underneath.
  layout[#layout + 1] = { type = "rectangle", filled = true,
    x = cx, y = cy + 1, w = 1, h = 4, color = P.hint,
    visible = function() return lv.load_phase ~= nil end,
    size = function()
      local w = math.floor(cw * (lv.progress or 0) / 100)
      if w < 1 then w = 1 end
      return w, 4
    end }

  -- in-chart legend box: curve name + cursor value, one line per curve, in
  -- curve color. FOLLOWS THE CURSOR via reactive pos= (pcallUpdate2Int — the
  -- same protected two-int path as the cursor rect; on LABELS it is
  -- unverified -- VERIFY on hardware). Flips to whichever side of the cursor
  -- has room. Semi-transparent fill (opacity, HW-proven on the TX-battery
  -- pill) lets the curves show through; drawn after curves + cursor.
  local lw = 0
  for k = 1, #lv.curves do
    local c = lv.curves[k]
    local w1 = lcd.sizeText(c.name .. " 99999.9" .. c.unit, SMLSIZE)
    if w1 > lw then lw = w1 end
  end
  lw = lw + 12
  local lh = #lv.curves * sh + 6
  local ly0 = cy + 8
  local function legend_x()
    local cur = lv.cursor_x or cx
    local x
    if cur < cx + cw / 2 then x = cur + 12       -- cursor left -> box right
    else x = cur - 12 - lw end                    -- cursor right -> box left
    if x < cx + 2 then x = cx + 2 end
    if x + lw > cx + cw - 2 then x = cx + cw - 2 - lw end
    return x
  end
  local lx0 = legend_x()
  layout[#layout + 1] = { type = "rectangle", filled = true,
    x = lx0, y = ly0, w = lw, h = lh, color = P.bg, opacity = 170,
    rounded = 4,
    pos = function() return legend_x(), ly0 end }
  layout[#layout + 1] = { type = "rectangle", x = lx0, y = ly0, w = lw, h = lh,
    thickness = 1, rounded = 4, color = P.line,
    pos = function() return legend_x(), ly0 end }
  for k = 1, #lv.curves do
    local kk = k
    local lyk = ly0 + 3 + (k - 1) * sh
    layout[#layout + 1] = { type = "label", x = lx0 + 6, y = lyk,
      w = lw - 10, h = sh, font = SMLSIZE, color = lv.colors[kk],
      text = function() return lv.readout[kk] or "" end,
      pos = function() return legend_x() + 6, lyk end }
  end

  -- footer: pan buttons flanking the window range / cursor line
  local fy = cy + ch + sh + 4
  -- ASCII "<"/">" — the ◀▶ glyphs are missing from the EdgeTX fonts
  -- (HW-verified 2026-07-08: buttons rendered empty)
  button(lv, layout, P, 4, fy - 2, zb, sh + 6, "<", SMLSIZE,
    function(wgt2, lv2) pan_step(wgt2, lv2, -1) end, busy)
  button(lv, layout, P, W - zb - 4, fy - 2, zb, sh + 6, ">", SMLSIZE,
    function(wgt2, lv2) pan_step(wgt2, lv2, 1) end, busy)
  layout[#layout + 1] = { type = "label", x = zb + 8, y = fy,
    w = W - 2 * zb - 16,
    h = sh, font = SMLSIZE, align = CENTER, color = P.textDim,
    text = function()
      local s = lv.sessions[lv.session_i]
      local a = fmt_mmss(lv.win_t0 - s.t0)
      local b = fmt_mmss(lv.win_t1 - s.t0)
      local base = a .. " - " .. b .. "  /  " .. fmt_mmss(s.t1 - s.t0)
      if lv.load_phase ~= nil then
        base = base .. "   loading " .. (lv.progress or 0) .. "%"
      elseif lv.cursor_t ~= nil then
        base = base .. "   cursor " .. (lv.readout_time or "")
      end
      return base
    end }
  lvgl.build(layout)
end

-- ---------------------------------------------------------------------
-- host entry points
-- ---------------------------------------------------------------------
function M.build(wgt, zone)
  local lv = ensure(wgt)
  lv.hit = {}
  local P = palette(wgt)
  if lv.mode == "browse" then
    build_browse(wgt, zone, lv, P)
  elseif lv.mode == "filter" then
    build_filter(wgt, zone, lv, P)
  elseif lv.mode == "load" then
    build_loading(wgt, zone, lv, P)
  elseif lv.mode == "sessions" then
    build_sessions(wgt, zone, lv, P)
  elseif lv.mode == "templates" then
    build_templates(wgt, zone, lv, P)
  elseif lv.mode == "sensors" then
    build_sensors(wgt, zone, lv, P)
  else
    build_chart(wgt, zone, lv, P)
  end
end

local function rect_hit(ts, r)
  return ts ~= nil and ts.x ~= nil
     and ts.x >= r.x and ts.x < r.x + r.w
     and ts.y >= r.y and ts.y < r.y + r.h
end

function M.refresh(wgt, event, touch_state)
  local lv = ensure(wgt)

  -- disarmed-only (spec 3.4): auto-close on arm; host clears menu_view
  if wgt.armed_now then
    M.close(wgt)
    wgt.lv_close_req = true
    return
  end
  -- fullscreen exit: release resources; the host's exit-rebuild runs anyway
  if lvgl.isFullScreen ~= nil and not lvgl.isFullScreen() then
    M.close(wgt)
    wgt.lv_close_req = true
    return
  end

  -- browser scan runs HERE (refresh's own budget), CHUNKED over ticks (scan_tick;
  -- a one-shot scan blew the budget on a 572-log folder). The list build is
  -- DEFERRED one further tick: scan + build in one call overran 20k ("CPU limit").
  if lv.mode == "browse" then
    if lv.files == nil then
      if scan_tick(lv) then              -- true = finished; lv.files is set
        lv.render_pending = true
      end
      return                             -- scan ticks do nothing else
    elseif lv.render_pending then
      lv.render_pending = false
      wgt.lv_dirty = true                -- host rebuilds now (this tick did no scan)
      return
    end
  end

  local now = getTime() or 0
  -- new touch gesture: forget the drag anchor + the swipe marker
  if EVT_TOUCH_FIRST ~= nil and event == EVT_TOUCH_FIRST then
    lv.drag_start = nil
    lv.saw_slide = nil
  end
  -- touch BEFORE loader work so taps stay responsive. lv.saw_slide: EdgeTX can
  -- classify a short swipe's release as a TAP -- after any slide in the current
  -- gesture, that release-tap must NOT open a row ("scrollen oeffnet ein Log").
  if EVT_TOUCH_TAP ~= nil and event == EVT_TOUCH_TAP and touch_state ~= nil
      and (touch_state.tapCount == nil or touch_state.tapCount <= 1)
      and lv.saw_slide ~= true
      and now >= (lv.tap_block or 0) then
    local hits = lv.hit
    for i = 1, #hits do
      local r = hits[i]
      if rect_hit(touch_state, r) then
        lv.tap_block = now + (r.cool or 30)
        r.fn(wgt, lv, touch_state)
        break
      end
    end
  end
  -- list scrolling (browser): touch drag (+ wheel codes, kept nil-guarded --
  -- HW-verified 2026-07-08: NO rotary event reaches a fullscreen LVGL widget
  -- with nothing focusable on the page (the encoder indev feeds the LVGL focus
  -- group only), so the wheel stays dead here for now; drag is the way).
  if lv.mode == "browse" and lv.files ~= nil then
    local maxs = math.max(0, #lv.files - (lv.vis_rows or 0))
    local step = 0
    if (EVT_VIRTUAL_NEXT ~= nil and event == EVT_VIRTUAL_NEXT)
        or (EVT_VIRTUAL_INC ~= nil and event == EVT_VIRTUAL_INC)
        or (EVT_ROTARY_RIGHT ~= nil and event == EVT_ROTARY_RIGHT) then
      step = 1
    elseif (EVT_VIRTUAL_PREV ~= nil and event == EVT_VIRTUAL_PREV)
        or (EVT_VIRTUAL_DEC ~= nil and event == EVT_VIRTUAL_DEC)
        or (EVT_ROTARY_LEFT ~= nil and event == EVT_ROTARY_LEFT) then
      step = -1
    end
    -- scrolling does NOT rebuild the page: row texts + the scrollbar thumb are
    -- reactive (they read lv.rows / lv.scroll), so compute_rows alone suffices.
    -- The old rebuild-per-step (full lvgl.build + a dirty-tick of latency) was
    -- what made list scrolling feel sluggish.
    if step ~= 0 then
      local ns = (lv.scroll or 0) + step
      if ns < 0 then ns = 0 elseif ns > maxs then ns = maxs end
      if ns ~= lv.scroll then lv.scroll = ns; compute_rows(lv) end
    end
    -- touch drag: map finger travel since the gesture start to a row offset.
    -- startY is constant within a gesture (also used to detect a fresh gesture).
    -- Every slide arms the swipe marker + a tap cooldown so neither the release
    -- nor a bounce tap right after the swipe opens a row.
    if EVT_TOUCH_SLIDE ~= nil and event == EVT_TOUCH_SLIDE and touch_state ~= nil
        and touch_state.y ~= nil then
      lv.saw_slide = true
      lv.tap_block = now + 50
      local sy = touch_state.startY or touch_state.y
      if lv.drag_start ~= sy then
        lv.drag_start = sy
        lv.drag_scroll0 = lv.scroll or 0
      end
      local ns = (lv.drag_scroll0 or 0)
        + math.floor((sy - touch_state.y) / (lv.row_h or 1))
      if ns < 0 then ns = 0 elseif ns > maxs then ns = maxs end
      if ns ~= lv.scroll then lv.scroll = ns; compute_rows(lv) end
    end
  end
  -- model-filter page: touch drag scrolls the model list (reactive rows +
  -- thumb -> no rebuild, browser pattern)
  if lv.mode == "filter" and EVT_TOUCH_SLIDE ~= nil and event == EVT_TOUCH_SLIDE
      and touch_state ~= nil and touch_state.y ~= nil then
    lv.saw_slide = true
    lv.tap_block = now + 50
    local sy = touch_state.startY or touch_state.y
    if lv.drag_start ~= sy then
      lv.drag_start = sy
      lv.drag_scroll0 = lv.fil_scroll or 0
    end
    local maxs = math.max(0, (lv.fil_total or 1) - (lv.fil_vis or 1))
    local ns = (lv.drag_scroll0 or 0)
      + math.floor((sy - touch_state.y) / (lv.fil_row_h or 1))
    if ns < 0 then ns = 0 elseif ns > maxs then ns = maxs end
    lv.fil_scroll = ns
  end
  -- template chooser: touch drag scrolls the card list (sensor-picker pattern:
  -- rebuild per step, the hit rects move with the window)
  if lv.mode == "templates" and EVT_TOUCH_SLIDE ~= nil and event == EVT_TOUCH_SLIDE
      and touch_state ~= nil and touch_state.y ~= nil then
    lv.saw_slide = true
    lv.tap_block = now + 50
    local sy = touch_state.startY or touch_state.y
    if lv.drag_start ~= sy then
      lv.drag_start = sy
      lv.drag_scroll0 = lv.tpl_scroll or 0
    end
    local maxs = math.max(0, (lv.tpl_total or 1) - (lv.tpl_vis or 1))
    local ns = (lv.drag_scroll0 or 0)
      + math.floor((sy - touch_state.y) / (lv.tpl_row_h or 1))
    if ns < 0 then ns = 0 elseif ns > maxs then ns = maxs end
    if ns ~= lv.tpl_scroll then
      lv.tpl_scroll = ns
      wgt.lv_dirty = true
    end
  end
  -- sensor picker: touch drag scrolls the column list (same pattern as the
  -- browser: startY anchor + swipe marker + tap cooldown; rebuild per step
  -- keeps the scrollbar thumb honest)
  if lv.mode == "sensors" and EVT_TOUCH_SLIDE ~= nil and event == EVT_TOUCH_SLIDE
      and touch_state ~= nil and touch_state.y ~= nil then
    lv.saw_slide = true
    lv.tap_block = now + 50
    local sy = touch_state.startY or touch_state.y
    if lv.drag_start ~= sy then
      lv.drag_start = sy
      lv.drag_scroll0 = lv.sens_scroll or 0
    end
    local maxs = math.max(0, (lv.sens_rows_total or 0) - (lv.sens_vis or 1))
    local ns = (lv.drag_scroll0 or 0)
      + math.floor((sy - touch_state.y) / (lv.sens_row_h or 1))
    if ns < 0 then ns = 0 elseif ns > maxs then ns = maxs end
    if ns ~= lv.sens_scroll then
      lv.sens_scroll = ns
      wgt.lv_dirty = true
    end
  end
  -- chart: slide drags the time cursor (cheap, no file IO). Guarded: the
  -- constant may not exist on all targets. saw_slide stays unset here: the
  -- release tap just re-sets the cursor to the same spot (harmless).
  if EVT_TOUCH_SLIDE ~= nil and event == EVT_TOUCH_SLIDE
      and lv.mode == "view" and touch_state ~= nil and touch_state.x ~= nil
      and lv.load_phase == nil then
    if touch_state.y >= lv.chart_y and touch_state.y < lv.chart_y + lv.chart_h then
      chart_tap(wgt, lv, touch_state)
    end
  end

  -- chunked loader work (budget-capped inside)
  if lv.load_phase ~= nil then loader_tick(wgt, lv) end
end

-- RTN while open: consume internally. Pickers over a LOADED chart return to
-- the chart; everything else steps back to the browser. At browse level
-- return false (host then closes to the toolbox menu).
function M.on_exit_key(wgt)
  local lv = wgt.lv
  if lv == nil then return false end
  if (lv.mode == "sensors" or lv.mode == "templates" or lv.mode == "sessions")
      and lv.win_t0 ~= nil and lv.curves ~= nil and #lv.curves > 0
      and lv.load_phase == nil then
    lv.mode = "view"                    -- picker cancelled -> back to the chart
    wgt.lv_dirty = true
    return true
  end
  if lv.mode ~= "browse" then
    if lv.fh then pcall(io.close, lv.fh) end
    lv.fh = nil
    lv.load_phase = nil
    lv.mode = "browse"
    wgt.lv_dirty = true
    return true
  end
  return false
end

return M
