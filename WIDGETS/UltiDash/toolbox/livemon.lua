-- =====================================================================
--  UltiDash Toolbox: Live Telemetry Monitor (M5)
--
--  Stacked per-sensor strips of the last 15/30/60 s, drawn as min/max
--  strokes from the HOST's 5 Hz bucket ring (wgt.lm, ultidashFunctions
--  lm_sample) -- the data is sampled whether this page is open or not,
--  so opening it after a manoeuvre shows the manoeuvre. This module only
--  READS wgt.lm; it owns no data and does no MSP. NOT disarmed-gated and
--  exempt from the arm-close: in-flight use is the point.
--
--  Rendering: one lvgl.line per strip with a FUNCTION-valued pts=
--  returning a host-owned, preallocated table -- the in-place path the
--  2026-08-17 spike proved at exactly this worst case (4 x 600 points,
--  5 Hz, planted-defect control red). The discipline that keeps it safe
--  (the per-point parse in the firmware is UNPROTECTED, Gotcha 6):
--  every point always {x, y} with non-negative integers, and contents
--  rewritten in place. The pair count is CONSTANT at 300 per strip
--  whatever the window: a shorter window maps several consecutive pairs
--  onto one bucket, so switching windows re-writes x once and never
--  changes the table shape.
--
--  Per bucket tick, ONE strip gets a full rescan+rewrite (round robin)
--  and every other strip only its newest stroke -- a full rewrite of all
--  four at once (~2400 point writes + 1200 scan steps) would not fit a
--  widget call's budget beside anything else.
-- =====================================================================

local M = {}

local C = nil
function M.init(common) C = common end

local LM_BUCKETS = 300
local PAIRS = LM_BUCKETS            -- drawn pairs per strip, constant (see header)
local WIN_BUCKETS = { 75, 150, 300 }   -- LmWin 1/2/3 = 15 / 30 / 60 s
local WIN_LABEL = { "15 s", "30 s", "60 s" }

-- curve colours; the sun palette gets darker variants (bright cyan on white is gone)
local CURVES = {
  { lcd.RGB(0x30, 0xC0, 0xFF), lcd.RGB(0xF0, 0xC0, 0x00),
    lcd.RGB(0x20, 0xC0, 0x20), lcd.RGB(0xFF, 0x60, 0x60) },
  { lcd.RGB(0x00, 0x50, 0xA0), lcd.RGB(0xA0, 0x60, 0x00),
    lcd.RGB(0x00, 0x70, 0x00), lcd.RGB(0xB0, 0x00, 0x00) },
}

local function fmt(v)
  if v == nil then return "-" end
  return string.format("%.4g", v)
end

-- A strip's full repaint is a JOB in bounded phases -- ~2k instructions each --
-- because this page shares its cycles with the LIVE dashboard pass: unlike the
-- Log Viewer it may not go exclusive (it runs armed, and the callouts under it
-- must keep running). The unchunked version scanned + rewrote a whole strip in
-- one call and was killed by the CPU limit the first time that landed on the
-- same cycle as the 5 Hz heavy pass -- found by the simulator leg, at 32 s in.
-- The window is PINNED at job start (j.first), so a tick landing mid-job cannot
-- shear the strip; the next pass draws the newer window.
local SCAN_CHUNK  = 150
local WRITE_CHUNK = 75

local function job_start(m, lm, k)
  m.job = { k = k, phase = "scan", i = 0, lo = nil, hi = nil,
            first = lm.head - m.wb }
end

local function job_step(m, lm)
  local j = m.job
  local k, wb, first = j.k, m.wb, j.first
  local bmin, bmax, bst = lm.bmin[k], lm.bmax[k], lm.bstamp
  if j.phase == "scan" then
    local i1 = math.min(j.i + SCAN_CHUNK, wb)
    local lo, hi = j.lo, j.hi
    for x = j.i, i1 - 1 do
      local b = first + x
      if b >= 0 then
        local slot = b % LM_BUCKETS + 1
        if bst[slot] == b then
          local mn, mx = bmin[slot], bmax[slot]
          if mn <= mx then
            if lo == nil or mn < lo then lo = mn end
            if hi == nil or mx > hi then hi = mx end
          end
        end
      end
    end
    j.lo, j.hi = lo, hi
    j.i = i1
    if i1 < wb then return end
    m.dlo[k], m.dhi[k] = lo, hi
    if lo == nil then                      -- nothing in the window yet
      m.scale[k] = nil
      m.job = nil
      return
    end
    -- auto-scale with a minimum span (L4's guard): pure auto-scale makes a 2 %
    -- ripple look like a collapse, so noise never fills the strip
    local span = hi - lo
    local floor_span = 0.03 * math.max(math.abs(lo), math.abs(hi), 1)
    if span < floor_span then
      local mid = (lo + hi) / 2
      lo, hi = mid - floor_span / 2, mid + floor_span / 2
      span = floor_span
    end
    local pad = span * 0.05
    lo = lo - pad
    span = span + 2 * pad
    m.lo[k], m.scale[k] = lo, m.ph[k] / span
    j.phase = "write"
    j.i = 1
    j.la, j.lb = m.py[k] + m.ph[k], m.py[k] + m.ph[k]   -- baseline = bottom edge
    return
  end
  -- write phase: WRITE_CHUNK pairs per call, carrying the last drawn pair so an
  -- empty bucket (stamp mismatch or mn > mx) repeats it across chunk borders
  local pts = lm.pts[k]
  local y0, h, lo, scale = m.py[k], m.ph[k], m.lo[k], m.scale[k]
  local p1 = math.min(j.i + WRITE_CHUNK - 1, PAIRS)
  local la, lb = j.la, j.lb
  for p = j.i, p1 do
    local x = math.floor((p - 1) * wb / PAIRS)
    local b = first + x
    local ya, yb = la, lb
    if b >= 0 then
      local slot = b % LM_BUCKETS + 1
      if bst[slot] == b then
        local mn, mx = bmin[slot], bmax[slot]
        if mn <= mx then
          ya = y0 + math.floor(h - (mx - lo) * scale + 0.5)
          yb = y0 + math.floor(h - (mn - lo) * scale + 0.5)
          if ya < y0 then ya = y0 elseif ya > y0 + h then ya = y0 + h end
          if yb < y0 then yb = y0 elseif yb > y0 + h then yb = y0 + h end
          la, lb = ya, yb
        end
      end
    end
    pts[2 * p - 1][2] = ya
    pts[2 * p][2] = yb
  end
  j.la, j.lb = la, lb
  j.i = p1 + 1
  if p1 >= PAIRS then m.job = nil end
end

-- newest stroke only, with the strip's LAST full-pass scale -- a value beyond
-- it clamps to the edge until this strip's next full pass (<= n ticks away)
local function touch_newest(m, lm, k)
  local scale = m.scale[k]
  if scale == nil then return end
  local b = lm.head - 1
  if b < 0 then return end
  local slot = b % LM_BUCKETS + 1
  if lm.bstamp[slot] ~= b then return end
  local mn, mx = lm.bmin[k][slot], lm.bmax[k][slot]
  if mn > mx then return end
  local pts = lm.pts[k]
  local npair = math.floor(#pts / 2)
  if npair < PAIRS then return end
  local y0, h, lo = m.py[k], m.ph[k], m.lo[k]
  local ya = y0 + math.floor(h - (mx - lo) * scale + 0.5)
  local yb = y0 + math.floor(h - (mn - lo) * scale + 0.5)
  if ya < y0 then ya = y0 elseif ya > y0 + h then ya = y0 + h end
  if yb < y0 then yb = y0 elseif yb > y0 + h then yb = y0 + h end
  pts[2 * PAIRS - 1][2] = ya
  pts[2 * PAIRS][2] = yb
end

-- x positions after a REBUILD (window switch / reopen), chunked like everything
-- else: doing all 1200 writes inside the build call put them beside lvgl.build
-- and was the second CPU kill this page produced in the simulator (the first
-- was the unchunked repaint). Until the sweep finishes the strips draw with
-- their previous x -- valid points, briefly the old geometry.
local function xmap_step(m, lm)
  local x0, pw = m.px, m.pw
  local st = m.xmap
  local k = st.k
  if k > lm.n then m.xmap = nil return end
  local pts = lm.pts[k]
  local npair = math.floor(#pts / 2)
  local p1 = math.min(st.p + 149, npair)
  for p = st.p, p1 do
    local x = x0 + math.floor((p - 1) * (pw - 1) / (PAIRS - 1))
    pts[2 * p - 1][1] = x
    pts[2 * p][1] = x
  end
  if p1 >= npair then
    st.k, st.p = k + 1, 1
  else
    st.p = p1 + 1
  end
end

-- Chunked point allocation, run from THIS page's cycles -- they carry no
-- dashboard work, so ~150 pairs a call is nothing here, while the same chunks
-- riding lm_sample landed on the dashboard's heaviest cycles and measured
-- straight into a budget FAIL. Every created point is immediately well-formed
-- ({x, baseline}) for the firmware's unprotected per-point parse (Gotcha 6),
-- and the count only ever GROWS -- the one realloc path the C side has.
local function alloc_step(m, lm)
  local k, i, left = lm.alloc_k, lm.alloc_i, 60
  local x0, pw = m.px, m.pw
  while left > 0 do
    if k > lm.n then lm.pts_done = true break end
    if i > PAIRS then
      k = k + 1
      i = 1
    else
      local x = x0 + math.floor((i - 1) * (pw - 1) / (PAIRS - 1))
      local base = m.py[k] + m.ph[k]
      local pts = lm.pts[k]
      pts[2 * i - 1] = { x, base }
      pts[2 * i]     = { x, base }
      i = i + 1
      left = left - 1
    end
  end
  lm.alloc_k, lm.alloc_i = k, i
end

function M.refresh(wgt, event, touchState)
  local m, lm = wgt.lmv, wgt.lm
  if m == nil then return end
  local now = getTime() or 0

  -- window chip tap (time-based debounce, the adjed pattern). The change goes
  -- through the normal staged cfg write -- an SD write, legal armed -- and the
  -- apply stage rebuilds the page, which re-runs the x remap for the new window.
  if event == EVT_TOUCH_TAP and touchState and m.chip then
    local tc = touchState.tapCount
    if (tc == nil or tc <= 1) and now >= (m.tapBlock or 0) then
      local tx, ty = touchState.x, touchState.y
      local c = m.chip
      if tx >= c.x and tx <= c.x + c.w and ty >= c.y and ty <= c.y + c.h then
        m.tapBlock = now + 25
        local o = wgt.options
        o.LmWin = ((o.LmWin or 2) % 3) + 1
        wgt.settings_save_pending = wgt.options
      end
    end
  end

  if lm == nil then return end
  if not lm.pts_done then
    alloc_step(m, lm)
    return                       -- allocation owns this cycle's share
  end

  -- exactly ONE bounded piece of repaint work per cycle: the post-rebuild x
  -- sweep, a running job's next phase, or -- on a fresh bucket tick -- the
  -- cheap per-strip updates plus the START of the next round-robin job.
  if m.xmap then
    xmap_step(m, lm)
  elseif m.job then
    job_step(m, lm)
  elseif lm.head ~= m.drawn_head then
    m.drawn_head = lm.head
    local k = m.rr
    if k > lm.n then k = 1 end
    m.rr = k + 1
    job_start(m, lm, k)
    for i = 1, lm.n do
      touch_newest(m, lm, i)
      -- label: name, the latest reading, and the window's real min/max
      local nowv = lm.rmax[i]
      if nowv == nil then
        local b = lm.head - 1
        if b >= 0 then
          local slot = b % LM_BUCKETS + 1
          if lm.bstamp[slot] == b and lm.bmin[i][slot] <= lm.bmax[i][slot] then
            nowv = lm.bmax[i][slot]
          end
        end
      end
      m.lbl[i] = string.format("%s   %s   [%s .. %s]",
        lm.names[i], fmt(nowv), fmt(m.dlo[i]), fmt(m.dhi[i]))
    end
    -- arm marker: visible while the edge is inside the window (L9)
    local ab = lm.arm_bucket
    if ab ~= nil then
      local age = lm.head - ab
      if age >= 0 and age < m.wb then
        local p = PAIRS - 1 - math.floor(age * PAIRS / m.wb)
        if p < 0 then p = 0 end
        m.mark_x = m.px + math.floor(p * (m.pw - 1) / (PAIRS - 1))
        m.mark_on = true
      else
        m.mark_on = false
      end
    end
  end
end

function M.build(wgt, zone)
  local lm = wgt.lm
  local W, H = zone.w, zone.h
  local opt = wgt.options or {}
  local sun = (opt.TbSun == 1) or (opt.TbSun == true)

  local P
  if C ~= nil then
    P = sun and C.sun_palette() or (wgt.tb_pal or C.fallback_palette())
  else                                  -- partial deploy: readable, not pretty
    P = { dark = true,                  -- says so, or the curve set below picks the wrong one
          bg = lcd.RGB(0, 0, 0), accent = lcd.RGB(0, 229, 255),
          hint = lcd.RGB(255, 122, 26), line = lcd.RGB(56, 60, 64),
          text = lcd.RGB(240, 240, 240), textDim = lcd.RGB(150, 156, 162) }
  end

  if lm == nil then
    local msg = {}
    if P.bg then msg[#msg + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = P.bg } end
    msg[#msg + 1] = { type = "label", x = 8, y = 8, w = W - 16, h = H - 16, font = SMLSIZE,
      color = P.text,
      text = "Live Monitor\n\nNo sensors configured.\nSettings > Telemetry > Live monitor" }
    lvgl.build(msg)
    wgt.lmv = nil
    return
  end

  local win = opt.LmWin or 2
  if win < 1 or win > 3 then win = 2 end

  local _, sth = lcd.sizeText("Ag", SMLSIZE)
  local headH = sth + 8
  local m = { wb = WIN_BUCKETS[win], rr = 1, drawn_head = -1,
              px = 4, pw = W - 8, py = {}, ph = {},
              lo = {}, scale = {}, dlo = {}, dhi = {}, lbl = {},
              mark_x = 0, mark_on = false,
              chip = nil, tapBlock = 0 }
  wgt.lmv = m

  local layout = {}
  if P.bg then layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = 0, w = W, h = H, color = P.bg } end

  -- header: the window chip (a tap target) left, the page hint right
  local chipW = lcd.sizeText("Window: 60 s", SMLSIZE) + 14
  m.chip = { x = 4, y = 2, w = chipW, h = headH - 4 }
  layout[#layout + 1] = { type = "rectangle", x = m.chip.x, y = m.chip.y, w = m.chip.w, h = m.chip.h,
    thickness = 1, rounded = 4, color = P.accent }
  layout[#layout + 1] = { type = "label", x = m.chip.x + 7, y = (headH - sth) / 2, w = chipW - 14, h = sth,
    font = SMLSIZE, color = P.accent,
    text = function() return "Window: " .. (WIN_LABEL[wgt.options and wgt.options.LmWin or win] or "?") end }
  layout[#layout + 1] = { type = "label", x = 6, y = (headH - sth) / 2, w = W - 12, h = sth,
    font = SMLSIZE, align = RIGHT, color = P.hint, text = "Live Monitor" }
  layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = headH - 1, w = W, h = 1, color = P.line }

  -- CURVES[1] is the set for a DARK background, CURVES[2] the darker variants for a light
  -- one. This followed opt.TbSun ALONE until 2026-08-19 -- but the background comes from
  -- tb_pal, which follows the colour scheme, so the shipped LIGHT scheme got the
  -- dark-background set on white: the Curr strip was measured at 791 px of pure #F0C000
  -- that could not be seen at a glance. The set now comes from the same place the
  -- background does, exactly as toolbox/logview.lua does it. TbSun needs no case of its
  -- own any more -- its palette is light and now says so (common.lua sun_palette).
  local curves = CURVES[P.dark and 1 or 2]
  -- 1 px hairlines were the user's first note on this page, and logview had already
  -- settled the same question the same way (its curves are 2 px above 300 px of height).
  local thick = (H >= 300) and 2 or 1
  local n = lm.n
  local sh = math.floor((H - headH) / n)
  for k = 1, n do
    local sy = headH + (k - 1) * sh
    m.py[k] = sy + sth + 3
    m.ph[k] = sh - sth - 6
    local kk = k
    layout[#layout + 1] = { type = "label", x = 6, y = sy + 1, w = W - 12, h = sth,
      font = SMLSIZE, color = P.text,
      text = function() return m.lbl[kk] or (lm.names[kk] .. "   -") end }
    layout[#layout + 1] = { type = "line", color = curves[(kk - 1) % 4 + 1], thickness = thick,
      pts = function() return lm.pts[kk] end }
    -- The arm-edge marker, ONE SEGMENT PER STRIP: it spans this strip's plot area only, so
    -- it can no longer strike through the label line the way the single full-height
    -- rectangle did. Moved per frame via reactive pos= and gated by visible= -- the Log
    -- Viewer's cursor pattern, and the reason it is n cheap rectangles rather than one
    -- expensive redraw. `my` is a fresh local per iteration, so each closure keeps its own.
    local my = m.py[k]
    layout[#layout + 1] = { type = "rectangle", filled = true,
      x = m.px, y = my, w = thick, h = m.ph[k], color = P.hint,
      pos = function() return (m.mark_x or m.px), my end,
      visible = function() return m.mark_on == true end }
    if k < n then
      layout[#layout + 1] = { type = "rectangle", filled = true, x = 0, y = sy + sh - 1, w = W, h = 1, color = P.line }
    end
  end

  lvgl.build(layout)
  m.xmap = { k = 1, p = 1 }      -- x sweep for the new window, chunked in refresh
end

return M
