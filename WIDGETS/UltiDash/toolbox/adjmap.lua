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

-- Shared data + helpers (SUB/TBL/DEFAULTS/CH_OPT, posFromValue/srcOf/applyOverrides/
-- storedVal, the palettes) live in toolbox/common.lua, loaded ONCE by the host and handed
-- in via M.init(common) -- a single source shared with the Adjustment Editor. `C` is nil
-- until init runs (or if common failed to load -> M.build shows a "missing" message).
local C = nil
function M.init(common) C = common end

local function activePos(m)
  local src = C.srcOf(m, "Config")
  if src == 0 then return 1 end
  return C.posFromValue(getValue(src))
end

-- per-instance state, namespaced on the UltiDash widget
local function ensure(wgt)
  local m = wgt.tb_map
  if not m then
    m = { connected = false, adjRow = nil, profile = 0,
          lastRow = nil, lastPos = nil, lastBeat = nil, lastBeatTime = nil,
          store = {}, _def = {}, pos = 1, has_profile = false }
    wgt.tb_map = m
  end
  m.options = wgt.options
  return m
end

-- per-cycle live state (no rebuild; the reactive labels read m.*)
function M.refresh(wgt, event, touchState)
  local m = ensure(wgt)
  if not C then return end   -- common.lua not loaded (partial deploy) -> nothing to do
  local now = getTime()

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

  -- cache the active 6-pos bank ONCE per cycle: the reactive row/header closures run per
  -- LVGL frame (rule 4) and all read m.pos instead of calling activePos()/getValue each.
  -- M.refresh runs every host cycle while the page is open, so m.pos is at most 1 frame old.
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

-- build the page (UltiDash already did lvgl.clear())
function M.build(wgt, zone)
  local m = ensure(wgt)
  local W, H = zone.w, zone.h
  local opt = m.options or {}
  local sun = (opt.TbSun == 1) or (opt.TbSun == true)

  -- graceful degrade if toolbox/common.lua didn't load (partial deploy): a plain message
  -- in the same style as the "Config channel not found" page instead of a crash.
  if not C then
    local msg = {}
    if sun then msg[#msg + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = lcd.RGB(255, 255, 255) } end
    msg[#msg + 1] = { type = "label", x = 4, y = 4, w = W - 8, h = H - 8, font = SMLSIZE,
      color = sun and lcd.RGB(0, 0, 0) or COLOR_THEME_PRIMARY1,
      text = "RF Adjustment Map\ntoolbox/common.lua missing" }
    lvgl.build(msg)
    return
  end

  C.applyOverrides()
  m.announce_pending = true   -- speak the current bank once after (re)opening the page

  if C.srcOf(m, "Config") == 0 then
    local msg = {}
    if sun then msg[#msg + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = lcd.RGB(255, 255, 255) } end
    msg[#msg + 1] = { type = "label", x = 4, y = 4, w = W - 8, h = H - 8, font = SMLSIZE,
      color = sun and lcd.RGB(0, 0, 0) or COLOR_THEME_PRIMARY1,
      text = "RF Adjustment Map\nConfig channel not found" }
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
    P = C.sun_palette()            -- map ignores the extra btn* fields
  elseif wgt.tb_pal then
    P = wgt.tb_pal
  else                             -- fallback dark (host didn't provide one)
    P = C.fallback_palette()
  end

  local layout = {}

  if P.bg then layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = P.bg } end
  -- header in the UltiDash detail-page style: live position (accent), a hint on the right,
  -- and a thin divider line — no filled header bar, no zebra rows.
  layout[#layout + 1] = { type = "label", x = 6, y = (headH - th) / 2, w = W - 12, h = th, font = font, color = P.accent,
    text = function()
      local p = m.pos
      if m.has_profile then return string.format("Pos %d (%s)   PID %d", p, C.SUB[p], m.profile) end
      return string.format("Pos %d   (%s)", p, C.SUB[p])
    end }
  layout[#layout + 1] = { type = "label", x = 6, y = (headH - sth) / 2, w = W - 12, h = sth, font = SMLSIZE, align = RIGHT,
    color = P.hint, text = "Adjustment Map" }
  layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = headH - 1, w = W, h = 1, color = P.line }

  for i, row in ipairs(C.TBL) do
    local rowY = headH + (i - 1) * rowH
    local ly = rowY + (rowH - th) / 2
    local idx = i
    layout[#layout + 1] = { type = "label", x = nameX, y = ly, w = nameW, h = th, font = font, text = row[1], color = P.text }
    layout[#layout + 1] = { type = "label", x = funcX, y = ly, w = funcW, h = th, font = font, color = P.text,
      text = function() local g = C.TBL[idx][2][m.pos]; if g == nil or g == "" then return "-" end return g end }
    layout[#layout + 1] = { type = "label", x = valX, y = rowY + (rowH - bth) / 2, w = valW, h = bth, font = bigFont, align = RIGHT,
      color = function()
        if m.lastRow == idx and m.lastPos == m.pos then return P.valHi end
        return P.valText
      end,
      text = function()
        local sv = C.storedVal(m, idx, m.pos)
        if sv == nil then return "--" end
        local sc = (opt.TbScale and opt.TbScale >= 1) and opt.TbScale or 1
        return string.format("%g", sv / sc)
      end }
  end

  lvgl.build(layout)
end

return M
