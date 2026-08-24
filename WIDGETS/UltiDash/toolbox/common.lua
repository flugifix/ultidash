-- =====================================================================
--  UltiDash Toolbox: shared data + helpers for the Adjustment Map/Editor
--  tool pages. Loaded ONCE by the host (ultidash.lua) and handed to both
--  tools via their M.init(common) -> both share ONE SUB/TBL instance, so a
--  labels.lua override applies identically to both (previously each tool
--  applied the same file separately, which only happened to match).
--  RANGES stays in adjed (editor-specific); labels.lua may carry a `ranges`
--  block, which is validated here (C.RANGES_OVR) and merged by the editor.
-- =====================================================================

local C = {}

C.SUB = { "P", "I", "D", "F", "O", "B" }

C.TBL = {
  { "Trim Pitch",    { "Pitch P Gain", "Pitch I Gain", "Pitch D Gain", "Pitch F Gain", "Pitch O Gain", "Pitch B Gain" } },
  { "Trim Roll",     { "Roll P Gain",  "Roll I Gain",  "Roll D Gain",  "Roll F Gain",  "Roll O Gain",  "Roll B Gain"  } },
  { "Trim Yaw",      { "Yaw P Gain",   "Yaw I Gain",   "Yaw D Gain",   "Yaw F Gain",   "Gov Cyc FF",   "Yaw B Gain"   } },
  { "Trim Throttle", { "Gov P Gain",   "Gov I Gain",   "Gov D Gain",   "Gov F Gain",   "Gov Col FF",   "Gov Gain"     } },
  { "Trim 5",        { "Yaw CCW Gain", "Yaw Cyc FF",   "Res Climb Col","",             "",             "Gov Headspeed" } },
  { "Trim 6",        { "Yaw CW Gain",  "Yaw Col FF",   "Res Hover Col","",             "",             ""             } },
}

C.DEFAULTS = { Config = "ch11", ValueCh = "ch12", AdjVal = "AdjV", Profile = "PID#" }
-- Config/ValueCh come from configurable channel-number options (Toolbox settings TbConfigCh/
-- TbValueCh -> "chN"); AdjVal/Profile stay RF-standard sensors by name.
C.CH_OPT = { Config = "TbConfigCh", ValueCh = "TbValueCh" }

-- The ACTIVE table both tools render: the hand table (above, incl. labels.lua) or the
-- FC-served one built by C.applyFcTable. C.cur/C.curSUB are what adjmap/adjed read;
-- C.WIN (nil = even six-way split) carries the FC's real enable windows for C.posFor.
C.cur, C.curSUB, C.WIN, C.DRIVE = C.TBL, C.SUB, nil, nil

-- Pristine snapshots, taken BEFORE labels.lua can mutate SUB/TBL: the FC-table builder
-- compares against these to recognise the standard assignment (and only then keeps the
-- familiar row/column labels), and labels applied earlier would defeat the compare.
local SUB0, TBL0 = {}, {}
for i = 1, #C.SUB do SUB0[i] = C.SUB[i] end
for i = 1, #C.TBL do
  local cells = {}
  for p = 1, 6 do cells[p] = C.TBL[i][2][p] end
  TBL0[i] = cells
end

-- optional user labels (/WIDGETS/UltiDash/toolbox/labels.lua), applied once to SUB/TBL.
-- The parsed config is KEPT (labelsCfg): the FC-served table (TbSource = 3) applies the
-- same rows/sub overrides on top of its own build, and re-reading the file there would
-- make the two applications drift.
local overridesApplied = false
local labelsCfg = nil
function C.applyOverrides()
  if overridesApplied then return end
  overridesApplied = true
  local ok1, chunk = pcall(loadScript, "/WIDGETS/UltiDash/toolbox/labels.lua")
  if not ok1 or type(chunk) ~= "function" then return end
  local ok2, cfg = pcall(chunk)
  if not ok2 or type(cfg) ~= "table" then return end
  labelsCfg = cfg
  if type(cfg.sub) == "table" then
    for i = 1, #C.SUB do if cfg.sub[i] ~= nil then C.SUB[i] = cfg.sub[i] end end
  end
  if type(cfg.rows) == "table" then
    for i, r in pairs(cfg.rows) do
      local def = C.TBL[i]
      if def and type(r) == "table" then
        for pos = 1, #def[2] do if r[pos] ~= nil then def[2][pos] = r[pos] end end
      end
    end
  end
  -- optional `ranges` block (per-setup override of the editor's range hints):
  -- rows 1..6, [pos 1..6] = string ("" blanks a hint). Only strings are kept;
  -- the editor (adjed) merges C.RANGES_OVR over its RANGES defaults once.
  if type(cfg.ranges) == "table" then
    local ovr = {}
    for i = 1, 6 do
      local r = cfg.ranges[i]
      if type(r) == "table" then
        local row = {}
        for pos = 1, 6 do if type(r[pos]) == "string" then row[pos] = r[pos] end end
        ovr[i] = row
      end
    end
    C.RANGES_OVR = ovr
  end
end

function C.posFromValue(v)
  local idx = math.floor((v + 1024) / 409.6 + 0.5)
  if idx < 0 then idx = 0 elseif idx > 5 then idx = 5 end
  return idx + 1
end

-- The active bank for a Config-channel value. With the FC's real enable windows (C.WIN,
-- from MSP 156) the answer is exact and a value in one of the dead gaps returns NIL --
-- "no bank" -- where the even split invented one (the gaps are real: the standard layout
-- is 200/200/100/150/150/150 us wide with five of them). Without windows: the even split,
-- unchanged. Channel value -> us is the CRSF identity (1500 + v/2: -1024 -> 988,
-- +1024 -> 2012), measured on the wire 2026-08-15 (GV 5 -> 1525 us, GV 90 -> 1961 us).
function C.posFor(v)
  local win = C.WIN
  if win == nil then return C.posFromValue(v) end
  local us = 1500 + v / 2
  for i = 1, #win do
    -- half-open [start, end), exactly the firmware's isRangeActive
    if us >= win[i].s and us < win[i].e then return i end
  end
  return nil
end

-- ---------------------------------------------------------------------
-- FC-served table (TbSource >= 2): build C.cur/C.curSUB/C.WIN/C.DRIVE out of the
-- records the RF service read at connect (MSP 167 + 156, wgt.rf.adj_table).
-- ---------------------------------------------------------------------
local adjNames = nil        -- id -> name (toolbox/adjnames.lua), loaded on first use
local function name_of(id)
  if adjNames == nil then
    local ok, chunk = pcall(loadScript, "/WIDGETS/UltiDash/toolbox/adjnames.lua")
    local ok2, t = false, nil
    if ok and type(chunk) == "function" then ok2, t = pcall(chunk) end
    adjNames = (ok2 and type(t) == "table") and t or {}
  end
  return adjNames[id] or ("#" .. tostring(id))
end

local fcKey = nil           -- what the current C.cur was built from (change -> rebuild)

--- (Re)build the active table. Called per cycle from both tools' ensure(); cheap when
--- nothing changed (one string compare). Returns TRUE when the active table changed --
--- the host uses that as its page-rebuild signal.
--- The channel fields on the wire are rcData slots minus 5, so wire CHn = field n-6 for
--- everything from AUX4 up (identity map); below CH9 the craft's rcmap could permute and
--- this build would group nothing -- the fallback then IS the hand table, logged by the
--- RF service's walk rather than silently.
function C.applyFcTable(wgt)
  local o = wgt.options or {}
  local rf = wgt.rf
  local tbl = rf and rf.adj_table
  local src = o.TbSource or 1
  local active = (src >= 2) and (tbl ~= nil)
  local key = active
    and string.format("%d/%d/%d/%d", rf.adj_gen or 0, src, o.TbConfigCh or 11, o.TbValueCh or 12)
    or "hand"
  if key == fcKey then return false end
  fcKey = key

  if not active then
    C.cur, C.curSUB, C.WIN, C.DRIVE = C.TBL, C.SUB, nil, nil
    return true
  end

  local cfgField = (o.TbConfigCh or 11) - 6
  local valField = (o.TbValueCh or 12) - 6

  -- pass 1: the distinct enable windows on the Config channel, sorted by start = the
  -- physical switch order. More than 6 cannot be rendered in this grid; slots gated on
  -- other channels (incl. 255 = always on, the profile selectors) are not grid content.
  local wins = {}
  for i = 1, #tbl do
    local r = tbl[i]
    if r.enaCh == cfgField and r.step > 0 then
      local seen = false
      for w = 1, #wins do
        if wins[w].s == r.enaS and wins[w].e == r.enaE then seen = true break end
      end
      if not seen and #wins < 6 then wins[#wins + 1] = { s = r.enaS, e = r.enaE } end
    end
  end
  for i = 2, #wins do        -- insertion sort, 6 entries at most
    local w, j = wins[i], i - 1
    while j >= 1 and wins[j].s > w.s do
      wins[j + 1] = wins[j]
      j = j - 1
    end
    wins[j + 1] = w
  end

  -- pass 2: place each slot -- bank = its enable window, row = the trim magnitude whose
  -- value-channel code lands inside its dec/inc windows (row r drives +/-(7-r)*15 %).
  local cells, drive = {}, {}
  for r = 1, 6 do cells[r] = {} drive[r] = {} end
  for i = 1, #tbl do
    local rec = tbl[i]
    if rec.enaCh == cfgField and rec.step > 0 then
      local bank = nil
      for w = 1, #wins do
        if wins[w].s == rec.enaS and wins[w].e == rec.enaE then bank = w break end
      end
      if bank then
        for r = 1, 6 do
          local mag = (7 - r) * 15
          local dus, ius = 1500 - 5.12 * mag, 1500 + 5.12 * mag
          if dus >= rec.r1s and dus < rec.r1e and ius >= rec.r2s and ius < rec.r2e then
            if cells[r][bank] == nil then
              cells[r][bank] = name_of(rec.fn)
              drive[r][bank] = (rec.adjCh == valField)
            end
            break
          end
        end
      end
    end
  end

  -- row/column labels: where a row reproduces the standard assignment exactly, keep the
  -- familiar label ("Trim Pitch", P/I/D/F/O/B) -- on the fleet's standard layout the FC
  -- view then reads like the hand table, which is the point. Anything else is honest:
  -- "Trim r" and bank numbers.
  local allMatch = true
  local fc = {}
  for r = 1, 6 do
    local rowMatch = true
    for p = 1, 6 do
      local a, b = cells[r][p] or "", TBL0[r][p] or ""
      if a ~= b then rowMatch = false break end
    end
    if not rowMatch then allMatch = false end
    fc[r] = { rowMatch and C.TBL[r][1] or ("Trim " .. r), cells[r] }
  end
  local sub = {}
  for p = 1, 6 do sub[p] = allMatch and SUB0[p] or tostring(p) end

  -- TbSource = 3: the pilot's labels.lua on top of the FC's answer (rows/sub only; the
  -- `ranges` block already applies through C.RANGES_OVR regardless of the source)
  if src >= 3 and labelsCfg ~= nil then
    if type(labelsCfg.sub) == "table" then
      for p = 1, 6 do if labelsCfg.sub[p] ~= nil then sub[p] = labelsCfg.sub[p] end end
    end
    if type(labelsCfg.rows) == "table" then
      for r, lr in pairs(labelsCfg.rows) do
        if fc[r] and type(lr) == "table" then
          for p = 1, 6 do if lr[p] ~= nil then fc[r][2][p] = lr[p] end end
        end
      end
    end
  end

  C.cur, C.curSUB, C.WIN, C.DRIVE = fc, sub, wins, drive
  return true
end

-- resolve a source to an id/name getValue accepts. Config/ValueCh use the configurable
-- channel number (TbConfigCh/TbValueCh -> "chN"); the rest fall back to DEFAULTS by name.
function C.srcOf(m, optName)
  local o = m.options or {}
  local key
  local chOpt = C.CH_OPT[optName]
  if chOpt and type(o[chOpt]) == "number" and o[chOpt] >= 1 then
    key = "ch" .. o[chOpt]
  else
    local direct = o[optName]
    if direct and direct ~= 0 then return direct end
    key = C.DEFAULTS[optName]
    if not key then return 0 end
  end
  m._def = m._def or {}
  if m._def[key] == nil then
    local fi = getFieldInfo(key)
    m._def[key] = (fi and fi.id) or key
  end
  return m._def[key]
end

function C.storedVal(m, row, pos)
  local p = m.store[m.profile]
  if not p or not p[row] then return nil end
  return p[row][pos]
end

-- Palettes shared by both tools (the map ignores the extra btn* fields the editor uses for
-- its +/- buttons). sunlight = high-contrast light override; fallback = dark, used only when
-- the host didn't hand a scheme-matched palette via wgt.tb_pal.
--
-- Both carry `dark` since 2026-08-19, and it is not decoration: the curve pages pick their
-- colour set off P.dark (logview, livemon), and the host's toolbox_palette sets it. These
-- two did NOT, so a page falling back to the dark palette here read `nil` and chose the
-- LIGHT-background curve set on black -- the mirror image of the bug that made livemon draw
-- the dark-background set on the shipped white scheme.
function C.sun_palette()
  return { dark = false,
           bg = lcd.RGB(255,255,255), accent = lcd.RGB(0,0,0), hint = lcd.RGB(200,80,0), line = lcd.RGB(170,170,170),
           text = lcd.RGB(0,0,0), textDim = lcd.RGB(120,120,120),
           btnBg = lcd.RGB(0,60,190), btnPressed = lcd.RGB(60,120,235), btnDim = lcd.RGB(150,150,150),
           btnFg = lcd.RGB(255,255,255), valText = lcd.RGB(0,0,0), valHi = lcd.RGB(200,0,0),
           bannerBg = lcd.RGB(200,0,0), bannerFg = lcd.RGB(255,255,255) }
end

function C.fallback_palette()
  return { dark = true,
           bg = lcd.RGB(0,0,0), accent = lcd.RGB(0,229,255), hint = lcd.RGB(255,122,26), line = lcd.RGB(56,60,64),
           text = lcd.RGB(240,240,240), textDim = lcd.RGB(150,156,162),
           btnBg = lcd.RGB(0,150,180), btnPressed = lcd.RGB(0,200,235), btnDim = lcd.RGB(60,66,72),
           btnFg = lcd.RGB(0,0,0), valText = lcd.RGB(240,240,240), valHi = lcd.RGB(255,176,0),
           bannerBg = lcd.RGB(255,68,56), bannerFg = lcd.RGB(0,0,0) }
end

return C
