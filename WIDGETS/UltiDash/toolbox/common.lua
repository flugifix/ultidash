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

-- optional user labels (/WIDGETS/UltiDash/toolbox/labels.lua), applied once to SUB/TBL
local overridesApplied = false
function C.applyOverrides()
  if overridesApplied then return end
  overridesApplied = true
  local ok1, chunk = pcall(loadScript, "/WIDGETS/UltiDash/toolbox/labels.lua")
  if not ok1 or type(chunk) ~= "function" then return end
  local ok2, cfg = pcall(chunk)
  if not ok2 or type(cfg) ~= "table" then return end
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
function C.sun_palette()
  return { bg = lcd.RGB(255,255,255), accent = lcd.RGB(0,0,0), hint = lcd.RGB(200,80,0), line = lcd.RGB(170,170,170),
           text = lcd.RGB(0,0,0), textDim = lcd.RGB(120,120,120),
           btnBg = lcd.RGB(0,60,190), btnPressed = lcd.RGB(60,120,235), btnDim = lcd.RGB(150,150,150),
           btnFg = lcd.RGB(255,255,255), valText = lcd.RGB(0,0,0), valHi = lcd.RGB(200,0,0),
           bannerBg = lcd.RGB(200,0,0), bannerFg = lcd.RGB(255,255,255) }
end

function C.fallback_palette()
  return { bg = lcd.RGB(0,0,0), accent = lcd.RGB(0,229,255), hint = lcd.RGB(255,122,26), line = lcd.RGB(56,60,64),
           text = lcd.RGB(240,240,240), textDim = lcd.RGB(150,156,162),
           btnBg = lcd.RGB(0,150,180), btnPressed = lcd.RGB(0,200,235), btnDim = lcd.RGB(60,66,72),
           btnFg = lcd.RGB(0,0,0), valText = lcd.RGB(240,240,240), valHi = lcd.RGB(255,176,0),
           bannerBg = lcd.RGB(255,68,56), bannerFg = lcd.RGB(0,0,0) }
end

return C
