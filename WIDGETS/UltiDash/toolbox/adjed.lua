-- =====================================================================
--  UltiDash Toolbox: RF Adjustment Editor  (touch +/- via GVAR pulse)
--  Ported from the standalone RFAdjEd widget into an UltiDash full-screen
--  Toolbox page. A tap pulses a dedicated GVAR onto the value channel for
--  ~PulseMs and back to 0 -> the FC performs one adjustment step. Works in
--  flight (that is the point of RF2 adjustment functions). No focusable LVGL
--  buttons (would capture PAGE/RTN/TELE); the [-]/[+] are plain rects, taps
--  read from touchState. Exit via UltiDash's RTN/back (no own [X]).
--
--  Model setup (once) on the value channel (e.g. CH12): extra line
--  Source MAX, Weight GVx (Add); GVx idle 0; number = option TbGvar.
--  Config/Value channels are configurable (TbConfigCh/TbValueCh, default CH11/CH12);
--  AdjV/PID# are RF-standard by name.
--  Options (wgt.options): TbGvar (GV1..15), TbPulse (ms), TbScale, TbSun, TbBert.
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

--   Pos:        1=P        2=I        3=D       4=F      5=O   6=B
local RANGES = {
  [1] = { "90-150", "85-130", "45-60", "~115", nil, "indiv" },
  [2] = { "30-70",  "85-130", "0-50",  "~115", nil, "0"     },
  [3] = { "120",    "180-450","20",    "8"                   },
  [4] = {},
  [5] = { "180"     },
  [6] = { "165"     },
}

local DEFAULTS = { Config = "ch11", ValueCh = "ch12", AdjVal = "AdjV", Profile = "PID#" }
-- Config/ValueCh come from configurable channel-number options (Toolbox settings TbConfigCh/
-- TbValueCh -> "chN"); AdjVal/Profile stay RF-standard sensors by name.
local CH_OPT = { Config = "TbConfigCh", ValueCh = "TbValueCh" }

-- optional user labels (/WIDGETS/UltiDash/toolbox/labels.lua), applied once
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

local function rowCode(row, up) local mag = (7 - row) * 15; return up and mag or -mag end

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

local function hasFunc(m, row)
  local g = TBL[row][2][activePos(m)]
  return g ~= nil and g ~= ""
end

local function storedVal(m, row, pos)
  local p = m.store[m.profile]
  if not p or not p[row] then return nil end
  return p[row][pos]
end

-- pulse the GVAR to the trim code, start the pulse timer
local function pulse(m, row, up)
  if not m.active then return end
  local gv = (m.options.TbGvar or 1) - 1
  local fm = getFlightMode()
  model.setGlobalVariable(gv, fm, rowCode(row, up))
  m.pulseFm = fm
  m.pulseUntil = getTime() + math.floor((m.options.TbPulse or 150) / 10)
  m.adjRow = row
end

local function ensure(wgt)
  applyOverrides()
  local m = wgt.tb_ed
  if not m then
    m = { active = true, connected = false, adjRow = nil, profile = 0,
          lastRow = nil, lastPos = nil, lastBeat = nil, lastBeatTime = nil,
          pulseUntil = nil, pulseFm = 0, store = {}, btns = {}, _def = {} }
    wgt.tb_ed = m
  end
  m.options = wgt.options
  return m
end

function M.refresh(wgt, event, touchState)
  local m = ensure(wgt)
  local now = getTime()

  -- end pulse: GVAR back to 0
  if m.pulseUntil ~= nil and now >= m.pulseUntil then
    model.setGlobalVariable((m.options.TbGvar or 1) - 1, m.pulseFm, 0)
    m.pulseUntil = nil
  end

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

  -- touch feedback tracking + tap evaluation (screen coords, fullscreen origin 0,0)
  if touchState then m.touchX, m.touchY = touchState.x, touchState.y else m.touchX, m.touchY = nil, nil end
  if event == EVT_TOUCH_TAP and touchState and m.active and m.btns then
    local tx, ty = touchState.x, touchState.y
    for _, b in ipairs(m.btns) do
      if tx >= b.x and tx <= b.x + b.w and ty >= b.y and ty <= b.y + b.h then
        if hasFunc(m, b.row) then pulse(m, b.row, b.up) end
      end
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

function M.build(wgt, zone)
  local m = ensure(wgt)
  m.announce_pending = true   -- speak the current bank once after (re)opening the page
  local W, H = zone.w, zone.h
  local opt = m.options or {}
  m.btns = {}

  local sun  = (opt.TbSun == 1) or (opt.TbSun == true)
  local bert = (opt.TbBert == 1) or (opt.TbBert == true)

  if srcOf(m, "Config") == 0 then
    local msg = {}
    if sun then msg[#msg + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = lcd.RGB(255, 255, 255) } end
    msg[#msg + 1] = { type = "label", x = 4, y = 4, w = W - 8, h = H - 8, font = SMLSIZE,
      color = sun and lcd.RGB(0, 0, 0) or COLOR_THEME_PRIMARY1,
      text = "RF Adjustment Editor\nConfig channel not found" }
    lvgl.build(msg)
    return
  end

  local font = (H / 7 >= 26) and MIDSIZE or SMLSIZE
  local _, th  = lcd.sizeText("Ag", font)
  local _, sth = lcd.sizeText("Ag", SMLSIZE)
  local headH = th + 6
  local rowH  = (H - headH) / #TBL

  local gap    = 6
  local btnW   = math.min(70, math.floor(W * 0.15))
  local valW   = math.min(120, math.floor(W * 0.24))
  local plusX  = W - gap - btnW
  local valX   = plusX - gap - valW
  local minusX = valX - gap - btnW
  local funcX  = 6
  local funcW  = minusX - funcX - gap
  local btnH   = math.floor(rowH - 4)

  local bigFont = font
  for _, f in ipairs({ DBLSIZE, MIDSIZE, SMLSIZE }) do
    local _, fh = lcd.sizeText("Ag", f)
    if fh <= btnH - 2 then bigFont = f; break end
  end
  local _, bth = lcd.sizeText("Ag", bigFont)

  local rangeFont = (font == MIDSIZE) and 0 or SMLSIZE
  local _, rth = lcd.sizeText("Ag", rangeFont)
  local rangeW = bert and (lcd.sizeText("180-450", rangeFont) + 8) or 0
  local nameW  = funcW - (bert and (rangeW + gap) or 0)
  local sc = (opt.TbScale and opt.TbScale >= 1) and opt.TbScale or 1

  -- palette: the host (UltiDash) hands its scheme-matched colours via wgt.tb_pal so the
  -- tool fits the dashboard; the sunlight option overrides to a high-contrast light scheme.
  local P
  if sun then
    P = { bg = lcd.RGB(255,255,255), accent = lcd.RGB(0,0,0), hint = lcd.RGB(200,80,0), line = lcd.RGB(170,170,170),
          text = lcd.RGB(0,0,0), textDim = lcd.RGB(120,120,120),
          btnBg = lcd.RGB(0,60,190), btnPressed = lcd.RGB(60,120,235), btnDim = lcd.RGB(150,150,150),
          btnFg = lcd.RGB(255,255,255), valText = lcd.RGB(0,0,0), valHi = lcd.RGB(200,0,0),
          bannerBg = lcd.RGB(200,0,0), bannerFg = lcd.RGB(255,255,255) }
  elseif wgt.tb_pal then
    P = wgt.tb_pal
  else                       -- fallback dark (host didn't provide one)
    P = { bg = lcd.RGB(0,0,0), accent = lcd.RGB(0,229,255), hint = lcd.RGB(255,122,26), line = lcd.RGB(56,60,64),
          text = lcd.RGB(240,240,240), textDim = lcd.RGB(150,156,162),
          btnBg = lcd.RGB(0,150,180), btnPressed = lcd.RGB(0,200,235), btnDim = lcd.RGB(60,66,72),
          btnFg = lcd.RGB(0,0,0), valText = lcd.RGB(240,240,240), valHi = lcd.RGB(255,176,0),
          bannerBg = lcd.RGB(255,68,56), bannerFg = lcd.RGB(0,0,0) }
  end

  local function txtColor() return m.active and P.text or P.textDim end
  local function btnColor(bx, by, bw, bh)
    if not m.active then return P.btnDim end
    if m.touchX and m.touchX >= bx and m.touchX <= bx + bw and m.touchY >= by and m.touchY <= by + bh then return P.btnPressed end
    return P.btnBg
  end

  local layout = {}
  if P.bg then layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = P.bg } end
  -- header in the UltiDash detail-page style: live position (accent) + a hint on the right
  -- + a thin divider line; no filled header bar, no zebra rows.
  layout[#layout + 1] = { type = "label", x = 6, y = (headH - th) / 2, w = W - 12, h = th, font = font, color = P.accent,
    text = function()
      local p = activePos(m)
      if srcOf(m, "Profile") ~= 0 then return string.format("Pos %d (%s)   PID %d", p, SUB[p], m.profile) end
      return string.format("Pos %d   (%s)", p, SUB[p])
    end }
  layout[#layout + 1] = { type = "label", x = 6, y = (headH - sth) / 2, w = W - 12, h = sth, font = SMLSIZE, align = RIGHT,
    color = P.hint, text = "Adjustment Editor" }
  layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = headH - 1, w = W, h = 1, color = P.line }

  for i, row in ipairs(TBL) do
    local rowY = headH + (i - 1) * rowH
    local ly = rowY + (rowH - th) / 2
    local by = rowY + (rowH - btnH) / 2
    local idx = i
    layout[#layout + 1] = { type = "label", x = funcX, y = ly, w = nameW, h = th, font = font, color = txtColor,
      text = function() local g = TBL[idx][2][activePos(m)]; if g == nil or g == "" then return "-" end return g end }
    local visFunc = function() return hasFunc(m, idx) end
    if bert then
      layout[#layout + 1] = { type = "label", x = funcX + nameW + gap, y = rowY + (rowH - rth) / 2, w = rangeW, h = rth,
        font = rangeFont, align = CENTER, color = P.textDim, visible = visFunc,
        text = function() local r = RANGES[idx] and RANGES[idx][activePos(m)]; return r or "" end }
    end
    layout[#layout + 1] = { type = "rectangle", filled = true, x = minusX, y = by, w = btnW, h = btnH, rounded = 4,
      color = function() return btnColor(minusX, by, btnW, btnH) end, visible = visFunc }
    layout[#layout + 1] = { type = "label", x = minusX, y = by + (btnH - bth) / 2, w = btnW, h = bth, font = bigFont, align = CENTER,
      color = P.btnFg, text = "-", visible = visFunc }
    layout[#layout + 1] = { type = "label", x = valX, y = rowY + (rowH - bth) / 2, w = valW, h = bth, font = bigFont, align = CENTER,
      visible = visFunc,
      color = function()
        if not m.active then return P.textDim end
        if m.lastRow == idx and m.lastPos == activePos(m) then return P.valHi end
        return P.valText
      end,
      text = function()
        local sv = storedVal(m, idx, activePos(m))
        if sv == nil then return "--" end
        return string.format("%g", sv / sc)
      end }
    layout[#layout + 1] = { type = "rectangle", filled = true, x = plusX, y = by, w = btnW, h = btnH, rounded = 4,
      color = function() return btnColor(plusX, by, btnW, btnH) end, visible = visFunc }
    layout[#layout + 1] = { type = "label", x = plusX, y = by + (btnH - bth) / 2, w = btnW, h = bth, font = bigFont, align = CENTER,
      color = P.btnFg, text = "+", visible = visFunc }
    m.btns[#m.btns + 1] = { row = idx, up = false, x = minusX, y = by, w = btnW, h = btnH }
    m.btns[#m.btns + 1] = { row = idx, up = true,  x = plusX,  y = by, w = btnW, h = btnH }
  end

  local bh = th + 8
  local bnY = headH + (H - headH - bh) / 2
  layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = bnY, w = W, h = bh, color = P.bannerBg,
    visible = function() return not m.active end }
  layout[#layout + 1] = { type = "label", x = 0, y = bnY + (bh - th) / 2, w = W, h = th, font = font, align = CENTER,
    color = P.bannerFg, text = "CONFIG INACTIVE", visible = function() return not m.active end }

  lvgl.build(layout)
end

return M
