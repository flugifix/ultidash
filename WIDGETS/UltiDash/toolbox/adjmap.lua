-- =====================================================================
--  UltiDash Toolbox: RF Adjustment Map  (read-only)
--  Ported from the standalone RFAdjMap widget into an UltiDash full-screen
--  Toolbox page. Read-only: shows which adjustment function each trim maps
--  to (per the 6-pos Config channel) plus the last AdjV value per cell.
--
--  Hosted by UltiDash: UltiDash clears the screen and calls M.build(wgt, zone);
--  M.refresh(wgt, event, touch) runs every cycle for live state. The Config/Value
--  channels are configurable (TbConfigCh/TbValueCh, default CH11/CH12); AdjV/PID# are
--  RF-standard by name. Options: TbScale (AdjV divider), TbSun (sunlight high-contrast).
-- =====================================================================

local M = {}

local SUB = { "P", "I", "D", "F", "O", "B" }

local TBL = {
  { "Trim Pitch",    { "Pitch P Gain", "Pitch I Gain", "Pitch D Gain", "Pitch F Gain", "Pitch O Gain", "Pitch B Gain" } },
  { "Trim Roll",     { "Roll P Gain",  "Roll I Gain",  "Roll D Gain",  "Roll F Gain",  "Roll O Gain",  "Roll B Gain"  } },
  { "Trim Yaw",      { "Yaw P Gain",   "Yaw I Gain",   "Yaw D Gain",   "Yaw F Gain",   "Gov Cyc FF",   "Yaw B Gain"   } },
  { "Trim Throttle", { "Gov P Gain",   "Gov I Gain",   "Gov D Gain",   "Gov F Gain",   "Gov Col FF",   "Gov Gain"     } },
  { "Trim 5",        { "Yaw CCW Gain", "Yaw Cyc FF",   "Res Climb Col","",             "",             "Gov Headspeed" } },
  { "Trim 6",        { "Yaw CW Gain",  "Yaw Col FF",   "Res Hover Col","",             "",             ""             } },
}

local DEFAULTS = { Config = "ch11", ValueCh = "ch12", AdjVal = "AdjV", Profile = "PID#" }
-- Config/ValueCh come from configurable channel-number options (Toolbox settings TbConfigCh/
-- TbValueCh -> "chN"); AdjVal/Profile stay RF-standard sensors by name.
local CH_OPT = { Config = "TbConfigCh", ValueCh = "TbValueCh" }

-- optional user labels (/WIDGETS/UltiDash/toolbox/labels.lua), applied once — the SAME
-- overrides the Adjust Editor uses, so both tools always show the same custom mapping
local overridesApplied = false
local function applyOverrides()
  if overridesApplied then return end
  overridesApplied = true
  local ok1, chunk = pcall(loadScript, "/WIDGETS/UltiDash/toolbox/labels.lua")
  if not ok1 or type(chunk) ~= "function" then return end
  local ok2, cfg = pcall(chunk)
  if not ok2 or type(cfg) ~= "table" then return end
  if type(cfg.sub) == "table" then
    for i = 1, #SUB do if cfg.sub[i] ~= nil then SUB[i] = cfg.sub[i] end end
  end
  if type(cfg.rows) == "table" then
    for i, r in pairs(cfg.rows) do
      local def = TBL[i]
      if def and type(r) == "table" then
        for pos = 1, #def[2] do if r[pos] ~= nil then def[2][pos] = r[pos] end end
      end
    end
  end
end

local function posFromValue(v)
  local idx = math.floor((v + 1024) / 409.6 + 0.5)
  if idx < 0 then idx = 0 elseif idx > 5 then idx = 5 end
  return idx + 1
end

-- resolve a source to an id/name getValue accepts. Config/ValueCh use the configurable
-- channel number (TbConfigCh/TbValueCh -> "chN"); the rest fall back to DEFAULTS by name.
local function srcOf(m, optName)
  local o = m.options or {}
  local key
  local chOpt = CH_OPT[optName]
  if chOpt and type(o[chOpt]) == "number" and o[chOpt] >= 1 then
    key = "ch" .. o[chOpt]
  else
    local direct = o[optName]
    if direct and direct ~= 0 then return direct end
    key = DEFAULTS[optName]
    if not key then return 0 end
  end
  m._def = m._def or {}
  if m._def[key] == nil then
    local fi = getFieldInfo(key)
    m._def[key] = (fi and fi.id) or key
  end
  return m._def[key]
end

local function activePos(m)
  local src = srcOf(m, "Config")
  if src == 0 then return 1 end
  return posFromValue(getValue(src))
end

local function storedVal(m, row, pos)
  local p = m.store[m.profile]
  if not p or not p[row] then return nil end
  return p[row][pos]
end

-- per-instance state, namespaced on the UltiDash widget
local function ensure(wgt)
  local m = wgt.tb_map
  if not m then
    m = { active = true, connected = false, adjRow = nil, profile = 0,
          lastRow = nil, lastPos = nil, lastBeat = nil, lastBeatTime = nil,
          store = {}, _def = {} }
    wgt.tb_map = m
  end
  m.options = wgt.options
  return m
end

-- per-cycle live state (no rebuild; the reactive labels read m.*)
function M.refresh(wgt, event, touchState)
  local m = ensure(wgt)
  local now = getTime()

  -- connection comes from UltiDash's own state (no separate heartbeat sensor needed)
  m.connected = (wgt.values ~= nil) and (wgt.values.rf_connection_state ~= "disconnected") or false
  -- a FRESH (re)connect clears the per-session value store -> values start empty again
  if m.connected and m.was_connected == false then
    m.store = {}; m.lastRow = nil; m.lastPos = nil
  end
  m.was_connected = m.connected

  -- active gate from the host's resolved activation switch (nil = no switch -> always on)
  local hs = wgt.tb_switch_on
  m.active = (hs == nil) or (hs == true)

  local pr = srcOf(m, "Profile")
  if pr and pr ~= 0 then m.profile = math.floor(getValue(pr) + 0.5) else m.profile = 0 end

  local vc = srcOf(m, "ValueCh")
  if vc and vc ~= 0 then
    local mag = math.abs(getValue(vc) / 10.24)
    if mag >= 7.5 then
      local r = 7 - math.floor(mag / 15 + 0.5)
      if r < 1 then r = 1 elseif r > 6 then r = 6 end
      m.adjRow = r
    end
  end

  local av = srcOf(m, "AdjVal")
  if av and av ~= 0 and m.connected and m.adjRow ~= nil then
    local v = getValue(av)
    if v ~= 0 then
      local pos = activePos(m)
      m.store[m.profile] = m.store[m.profile] or {}
      m.store[m.profile][m.adjRow] = m.store[m.profile][m.adjRow] or {}
      m.store[m.profile][m.adjRow][pos] = v
      m.lastRow, m.lastPos = m.adjRow, pos
    end
  end

  -- voice: announce the active EnCh bank (1..6) on open and on change (gated by TbVoice;
  -- the host provides wgt.tb_announce, which honors master mute + widget volume)
  if wgt.options and wgt.options.TbVoice == 1 and wgt.tb_announce then
    local pos = activePos(m)
    if m.announce_pending or (m.lastSpokenPos ~= nil and pos ~= m.lastSpokenPos) then
      wgt.tb_announce(pos)
    end
    m.lastSpokenPos = pos
    m.announce_pending = false
  end
end

-- build the page (UltiDash already did lvgl.clear())
function M.build(wgt, zone)
  local m = ensure(wgt)
  applyOverrides()
  m.announce_pending = true   -- speak the current bank once after (re)opening the page
  local W, H = zone.w, zone.h
  local opt = m.options or {}
  local sun = (opt.TbSun == 1) or (opt.TbSun == true)

  if srcOf(m, "Config") == 0 then
    local msg = {}
    if sun then msg[#msg + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = lcd.RGB(255, 255, 255) } end
    msg[#msg + 1] = { type = "label", x = 4, y = 4, w = W - 8, h = H - 8, font = SMLSIZE,
      color = sun and lcd.RGB(0, 0, 0) or COLOR_THEME_PRIMARY1,
      text = "RF Adjustment Map\nConfig channel not found" }
    lvgl.build(msg)
    return
  end

  local font = (H / 7 >= 26) and MIDSIZE or SMLSIZE
  local _, th  = lcd.sizeText("Ag", font)
  local _, sth = lcd.sizeText("Ag", SMLSIZE)
  local headH = th + 6
  local rowH  = (H - headH) / #TBL
  local nameX, nameW = 4, math.floor(W * 0.34)
  local funcX = nameX + nameW
  local funcW = math.floor(W * 0.42)
  local valX  = funcX + funcW
  local valW  = W - valX - 4

  -- value font: use the biggest that fits the row height (matches the editor's value size,
  -- which is larger than the label font)
  local bigFont = font
  for _, f in ipairs({ DBLSIZE, MIDSIZE, SMLSIZE }) do
    local _, fh = lcd.sizeText("Ag", f)
    if fh <= rowH - 4 then bigFont = f; break end
  end
  local _, bth = lcd.sizeText("Ag", bigFont)

  -- palette: the host (UltiDash) hands its scheme-matched colours via wgt.tb_pal so the
  -- tool fits the dashboard; the sunlight option overrides to a high-contrast light scheme.
  local P
  if sun then
    P = { bg = lcd.RGB(255,255,255), accent = lcd.RGB(0,0,0), hint = lcd.RGB(200,80,0), line = lcd.RGB(170,170,170),
          text = lcd.RGB(0,0,0), textDim = lcd.RGB(120,120,120),
          valText = lcd.RGB(0,0,0), valHi = lcd.RGB(200,0,0), bannerBg = lcd.RGB(200,0,0), bannerFg = lcd.RGB(255,255,255) }
  elseif wgt.tb_pal then
    P = wgt.tb_pal
  else                       -- fallback dark (host didn't provide one)
    P = { bg = lcd.RGB(0,0,0), accent = lcd.RGB(0,229,255), hint = lcd.RGB(255,122,26), line = lcd.RGB(56,60,64),
          text = lcd.RGB(240,240,240), textDim = lcd.RGB(150,156,162),
          valText = lcd.RGB(240,240,240), valHi = lcd.RGB(255,176,0), bannerBg = lcd.RGB(255,68,56), bannerFg = lcd.RGB(0,0,0) }
  end

  local function txtColor() return m.active and P.text or P.textDim end
  local layout = {}

  if P.bg then layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = P.bg } end
  -- header in the UltiDash detail-page style: live position (accent), a hint on the right,
  -- and a thin divider line — no filled header bar, no zebra rows.
  layout[#layout + 1] = { type = "label", x = 6, y = (headH - th) / 2, w = W - 12, h = th, font = font, color = P.accent,
    text = function()
      local p = activePos(m)
      if srcOf(m, "Profile") ~= 0 then return string.format("Pos %d (%s)   PID %d", p, SUB[p], m.profile) end
      return string.format("Pos %d   (%s)", p, SUB[p])
    end }
  layout[#layout + 1] = { type = "label", x = 6, y = (headH - sth) / 2, w = W - 12, h = sth, font = SMLSIZE, align = RIGHT,
    color = P.hint, text = "Adjustment Map" }
  layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = headH - 1, w = W, h = 1, color = P.line }

  for i, row in ipairs(TBL) do
    local rowY = headH + (i - 1) * rowH
    local ly = rowY + (rowH - th) / 2
    local idx = i
    layout[#layout + 1] = { type = "label", x = nameX, y = ly, w = nameW, h = th, font = font, text = row[1], color = txtColor }
    layout[#layout + 1] = { type = "label", x = funcX, y = ly, w = funcW, h = th, font = font, color = txtColor,
      text = function() local g = TBL[idx][2][activePos(m)]; if g == nil or g == "" then return "-" end return g end }
    layout[#layout + 1] = { type = "label", x = valX, y = rowY + (rowH - bth) / 2, w = valW, h = bth, font = bigFont, align = RIGHT,
      color = function()
        if not m.active then return P.textDim end
        if m.lastRow == idx and m.lastPos == activePos(m) then return P.valHi end
        return P.valText
      end,
      text = function()
        local sv = storedVal(m, idx, activePos(m))
        if sv == nil then return "--" end
        local sc = (opt.TbScale and opt.TbScale >= 1) and opt.TbScale or 1
        return string.format("%g", sv / sc)
      end }
  end

  local bh = th + 8
  local by = headH + (H - headH - bh) / 2
  layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = by, w = W, h = bh, color = P.bannerBg,
    visible = function() return not m.active end }
  layout[#layout + 1] = { type = "label", x = 0, y = by + (bh - th) / 2, w = W, h = th, font = font, align = CENTER,
    color = P.bannerFg, text = "CONFIG INACTIVE", visible = function() return not m.active end }

  lvgl.build(layout)
end

return M
