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

-- Shared data + helpers (SUB/TBL/DEFAULTS/CH_OPT, posFromValue/srcOf/applyOverrides/
-- storedVal, the palettes) live in toolbox/common.lua, loaded ONCE by the host and handed
-- in via M.init(common) -- a single source shared with the Adjustment Map. `C` is nil until
-- init runs (or if common failed to load -> M.build shows a "missing" message). RANGES stays
-- here (editor-specific); labels.lua may override it via a `ranges` block (C.RANGES_OVR,
-- merged once in ensure()).
local C = nil
function M.init(common) C = common end

--   Pos:        1=P        2=I        3=D       4=F      5=O   6=B
local RANGES = {
  [1] = { "90-150", "85-130", "45-60", "~115", nil, "indiv" },
  [2] = { "30-70",  "85-130", "0-50",  "~115", nil, "0"     },
  [3] = { "120",    "180-450","20",    "8"                   },
  [4] = {},
  [5] = { "180"     },
  [6] = { "165"     },
}

local function rowCode(row, up) local mag = (7 - row) * 15; return up and mag or -mag end

local function activePos(m)
  local src = C.srcOf(m, "Config")
  if src == 0 then return 1 end
  return C.posFromValue(getValue(src))
end

local function hasFunc(m, row)
  local g = C.TBL[row][2][m.pos]   -- m.pos cached per cycle (see M.refresh)
  return g ~= nil and g ~= ""
end

-- pulse the GVAR to the trim code, start the pulse timer
local function pulse(m, row, up)
  local gv = (m.options.TbGvar or 1) - 1
  local fm = getFlightMode()
  model.setGlobalVariable(gv, fm, rowCode(row, up))
  m.pulseFm = fm
  m.pulseUntil = getTime() + math.floor((m.options.TbPulse or 150) / 10)
  m.adjRow = row
end

-- Reset an in-flight pulse. Called by the host on EVERY transition away from the
-- editor page (RTN, switch falling edge, fullscreen exit) -- without it a close
-- inside the ~150 ms pulse window left the GVAR at the trim code = a permanent
-- adjust command to the FC.
function M.cleanup(wgt)
  local m = wgt.tb_ed
  if m and m.pulseUntil ~= nil then
    pcall(model.setGlobalVariable, ((m.options and m.options.TbGvar) or 1) - 1, m.pulseFm or 0, 0)
    m.pulseUntil = nil
  end
end

-- labels.lua `ranges` block: same shape as RANGES ([row 1..6][pos 1..6] = text), merged
-- once over the defaults ("" blanks a hint). Parsed/validated by common.applyOverrides.
local rangesMerged = false
local function mergeRanges()
  if rangesMerged then return end
  rangesMerged = true
  local ovr = C and C.RANGES_OVR
  if type(ovr) ~= "table" then return end
  for i = 1, #RANGES do
    local r = ovr[i]
    if type(r) == "table" then
      for pos = 1, 6 do if r[pos] ~= nil then RANGES[i][pos] = r[pos] end end
    end
  end
end

local function ensure(wgt)
  if C then C.applyOverrides(); mergeRanges() end   -- guarded: common may not be loaded yet
  local m = wgt.tb_ed
  if not m then
    m = { connected = false, adjRow = nil, profile = 0,
          lastRow = nil, lastPos = nil, lastBeat = nil, lastBeatTime = nil,
          pulseUntil = nil, pulseFm = 0, store = {}, btns = {}, _def = {},
          pos = 1, has_profile = false }
    wgt.tb_ed = m
    m.options = wgt.options
    -- Defensive GVAR zero on the FIRST open of this instance: if the last
    -- session died INSIDE the ~150 ms pulse window (Lua state loss, power-off), the
    -- GVAR is still latched at a trim code = a standing adjust command at the FC.
    -- One setGlobalVariable(0) is neutral when it already is 0, disarmed or armed.
    pcall(model.setGlobalVariable, ((wgt.options and wgt.options.TbGvar) or 1) - 1,
        getFlightMode(), 0)
    return m
  end
  m.options = wgt.options
  return m
end

function M.refresh(wgt, event, touchState)
  local m = ensure(wgt)
  if not C then return end   -- common.lua not loaded (partial deploy) -> nothing to do
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

  local pr = C.srcOf(m,"Profile")
  if pr and pr ~= 0 then m.profile = math.floor(getValue(pr) + 0.5) else m.profile = 0 end
  m.has_profile = (pr ~= 0)

  -- cache the active 6-pos bank ONCE per cycle: the reactive row/header closures (and
  -- hasFunc) run per LVGL frame (rule 4) and all read m.pos instead of calling activePos()/
  -- getValue each. Set before the tap path below so a tap resolves against the fresh bank.
  m.pos = activePos(m)

  local vc = C.srcOf(m,"ValueCh")
  if vc and vc ~= 0 then
    local mag = math.abs(getValue(vc) / 10.24)
    if mag >= 7.5 then
      local r = 7 - math.floor(mag / 15 + 0.5)
      if r < 1 then r = 1 elseif r > 6 then r = 6 end
      m.adjRow = r
    end
  end

  local av = C.srcOf(m,"AdjVal")
  if av and av ~= 0 and m.connected and m.adjRow ~= nil then
    local v = getValue(av)
    if v ~= 0 then
      local pos = m.pos
      m.store[m.profile] = m.store[m.profile] or {}
      m.store[m.profile][m.adjRow] = m.store[m.profile][m.adjRow] or {}
      m.store[m.profile][m.adjRow][pos] = v
      m.lastRow, m.lastPos = m.adjRow, pos
    end
  end

  -- touch feedback tracking + tap evaluation (screen coords, fullscreen origin 0,0)
  if touchState then m.touchX, m.touchY = touchState.x, touchState.y else m.touchX, m.touchY = nil, nil end
  -- TIME-based tap debounce (never state/event-based): one physical tap bounces into
  -- several TAP events, spread wider on the TX16S -- without the cooldown that meant
  -- double adjustment steps. tapCount > 1 is ignored; the cooldown is armed ONLY on a
  -- successful hit so a miss never blocks an immediate correction.
  if event == EVT_TOUCH_TAP and touchState and m.btns then
    local tc = touchState.tapCount
    if (tc == nil or tc <= 1) and now >= (m.tapBlock or 0) then
      local tx, ty = touchState.x, touchState.y
      for _, b in ipairs(m.btns) do
        if tx >= b.x and tx <= b.x + b.w and ty >= b.y and ty <= b.y + b.h and hasFunc(m, b.row) then
          pulse(m, b.row, b.up)
          -- cooldown follows the CONFIGURED pulse duration: the fixed
          -- 250 ms only out-lasted the DEFAULT 150 ms pulse — with TbPulse raised
          -- (up to 500 ms) a second tap could land mid-pulse and overlap GVAR
          -- pulses. +100 ms margin, floor at the proven 250 ms debounce.
          m.tapBlock = now + math.max(25, math.floor((m.options.TbPulse or 150) / 10) + 10)
        end
      end
    end
  end

  -- voice: announce the active EnCh bank (1..6) on open and on change (gated by TbVoice;
  -- the host provides wgt.tb_announce, which honors master mute + widget volume)
  if wgt.options and wgt.options.TbVoice == 1 and wgt.tb_announce then
    local pos = m.pos
    if m.announce_pending or (m.lastSpokenPos ~= nil and pos ~= m.lastSpokenPos) then
      wgt.tb_announce(pos)
    end
    m.lastSpokenPos = pos
    m.announce_pending = false
  end
end

function M.build(wgt, zone)
  local m = ensure(wgt)
  local W, H = zone.w, zone.h
  local opt = m.options or {}
  m.btns = {}

  local sun  = (opt.TbSun == 1) or (opt.TbSun == true)
  local bert = (opt.TbBert == 1) or (opt.TbBert == true)

  -- graceful degrade if toolbox/common.lua didn't load (partial deploy): a plain message
  -- in the same style as the "Config channel not found" page instead of a crash.
  if not C then
    local msg = {}
    if sun then msg[#msg + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = lcd.RGB(255, 255, 255) } end
    msg[#msg + 1] = { type = "label", x = 4, y = 4, w = W - 8, h = H - 8, font = SMLSIZE,
      color = sun and lcd.RGB(0, 0, 0) or COLOR_THEME_PRIMARY1,
      text = "RF Adjustment Editor\ntoolbox/common.lua missing" }
    lvgl.build(msg)
    return
  end

  m.announce_pending = true   -- speak the current bank once after (re)opening the page

  if C.srcOf(m, "Config") == 0 then
    local msg = {}
    if sun then msg[#msg + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = lcd.RGB(255, 255, 255) } end
    msg[#msg + 1] = { type = "label", x = 4, y = 4, w = W - 8, h = H - 8, font = SMLSIZE,
      color = sun and lcd.RGB(0, 0, 0) or COLOR_THEME_PRIMARY1,
      text = "RF Adjustment Editor\nConfig channel not found" }
    lvgl.build(msg)
    return
  end

  -- seed the per-cycle cache so the very first frame (before the next M.refresh) is correct
  m.pos = activePos(m)
  m.has_profile = (C.srcOf(m, "Profile") ~= 0)

  local font = (H / 7 >= 26) and MIDSIZE or SMLSIZE
  local _, th  = lcd.sizeText("Ag", font)
  local _, sth = lcd.sizeText("Ag", SMLSIZE)
  local headH = th + 6
  local rowH  = (H - headH) / #C.TBL

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
    P = C.sun_palette()
  elseif wgt.tb_pal then
    P = wgt.tb_pal
  else                       -- fallback dark (host didn't provide one)
    P = C.fallback_palette()
  end

  local function btnColor(bx, by, bw, bh)
    if m.touchX and m.touchX >= bx and m.touchX <= bx + bw and m.touchY >= by and m.touchY <= by + bh then return P.btnPressed end
    return P.btnBg
  end

  local layout = {}
  if P.bg then layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = P.bg } end
  -- header in the UltiDash detail-page style: live position (accent) + a hint on the right
  -- + a thin divider line; no filled header bar, no zebra rows.
  layout[#layout + 1] = { type = "label", x = 6, y = (headH - th) / 2, w = W - 12, h = th, font = font, color = P.accent,
    text = function()
      local p = m.pos
      if m.has_profile then return string.format("Pos %d (%s)   PID %d", p, C.SUB[p], m.profile) end
      return string.format("Pos %d   (%s)", p, C.SUB[p])
    end }
  layout[#layout + 1] = { type = "label", x = 6, y = (headH - sth) / 2, w = W - 12, h = sth, font = SMLSIZE, align = RIGHT,
    color = P.hint, text = "Adjustment Editor" }
  layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = headH - 1, w = W, h = 1, color = P.line }

  for i, row in ipairs(C.TBL) do
    local rowY = headH + (i - 1) * rowH
    local ly = rowY + (rowH - th) / 2
    local by = rowY + (rowH - btnH) / 2
    local idx = i
    layout[#layout + 1] = { type = "label", x = funcX, y = ly, w = nameW, h = th, font = font, color = P.text,
      text = function() local g = C.TBL[idx][2][m.pos]; if g == nil or g == "" then return "-" end return g end }
    local visFunc = function() return hasFunc(m, idx) end
    if bert then
      layout[#layout + 1] = { type = "label", x = funcX + nameW + gap, y = rowY + (rowH - rth) / 2, w = rangeW, h = rth,
        font = rangeFont, align = CENTER, color = P.textDim, visible = visFunc,
        text = function() local r = RANGES[idx] and RANGES[idx][m.pos]; return r or "" end }
    end
    layout[#layout + 1] = { type = "rectangle", filled = true, x = minusX, y = by, w = btnW, h = btnH, rounded = 4,
      color = function() return btnColor(minusX, by, btnW, btnH) end, visible = visFunc }
    layout[#layout + 1] = { type = "label", x = minusX, y = by + (btnH - bth) / 2, w = btnW, h = bth, font = bigFont, align = CENTER,
      color = P.btnFg, text = "-", visible = visFunc }
    layout[#layout + 1] = { type = "label", x = valX, y = rowY + (rowH - bth) / 2, w = valW, h = bth, font = bigFont, align = CENTER,
      visible = visFunc,
      color = function()
        if m.lastRow == idx and m.lastPos == m.pos then return P.valHi end
        return P.valText
      end,
      text = function()
        local sv = C.storedVal(m, idx, m.pos)
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

  lvgl.build(layout)
end

return M
