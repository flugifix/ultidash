local toolName = "TNS|UltiDash Log Viewer|TNE"

-- UltiDash Log Viewer -- standalone entry in EdgeTX's Tools/Apps menu (SYS key).
--
-- A LAUNCHER, not a second implementation: it loads the INSTALLED widget's
-- /WIDGETS/UltiDash/toolbox/logview.lua unchanged and drives it exactly the way the
-- UltiDash host does -- build alone in one cycle, refresh alone in the next. The module
-- owns everything it draws; this file knows nothing about its internals beyond the four
-- entry points (build / refresh / on_exit_key / close) and the wgt.tb_pal / wgt.lv* slots
-- the host fills for it, both of which are below. If a
-- later module change breaks this stub, the stub is the thing that follows.
--
-- Requires UltiDash on the same card -- the module and its cfg/logtemplates.lua both live
-- in the widget tree. A missing module is a readable page, never a crash.
--
-- NO ARM GATE, on purpose: opening a Tools script is the pilot's own decision, and EdgeTX
-- suspends every widget (callouts, flight log, MSP) for as long as one runs, so a gate here
-- would protect nothing the menu has not already taken. The viewer reads files and nothing
-- else. The WIDGET-side Log Viewer keeps its arm-close; only this entry differs.
--
-- The per-cycle discipline (build alone / refresh alone) is kept even though a standalone
-- script has a larger budget than a widget cycle: it costs nothing and keeps this file the
-- same shape as the host branch it mirrors (ultidash.lua, the tb_logview branch).

local LV_PATH = "/WIDGETS/UltiDash/toolbox/logview.lua"

local logview = nil
local load_err = nil
local err_drawn = false
-- `tb_pal` is the slot the WIDGET hands its tool pages their palette in, and this file is a
-- host substitute, so it fills that slot too (in init(), below). It used to be left empty on
-- purpose, and that was wrong twice over: logview.lua then falls back to its own hard-coded
-- table -- black background, cyan accent, orange hint -- which is precisely the look the
-- widget's tools were moved OFF, and the chart's curve set is chosen from `wgt.tb_pal.dark`
-- read DIRECTLY (logview.lua, prepare_layout), bypassing that fallback. No slot, no `dark`,
-- so the LIGHT curve set -- deep blue, dark red, dark green, tuned for white -- was drawn on
-- that black background.
local wgt = { options = {} }

-- Below this luminance the surface under the chart counts as dark. Same number and same
-- purpose as the host's DARK_LUMA_THRESHOLD; there is no way to share it -- this entry
-- deliberately has no host.
local DARK_LUMA = 96

--- Is the RADIO's own theme dark? COLOR_THEME_* is an INDEX flag (COLOR2FLAGS: the
--- LcdColorIndex in bits 16.., no RGB_FLAG), NOT an RGB565 value, so it has to be resolved
--- through lcd.getColor before anything can be read off it -- decoding the bare index as if
--- it were RGB565 yields near-black for every theme, i.e. "dark" always.
--- SECONDARY3 is the surface the tool pages paint (`bg` below), so it is the one to judge.
local function theme_is_dark()
  local ok, c = pcall(lcd.getColor, COLOR_THEME_SECONDARY3)
  if not ok or type(c) ~= "number" then return false end
  local v = (c >> 16) & 0xFFFF
  local r = ((v >> 11) & 0x1F) * 255 // 31
  local g = ((v >> 5)  & 0x3F) * 255 // 63
  local b = ( v        & 0x1F) * 255 // 31
  return (0.299 * r + 0.587 * g + 0.114 * b) < DARK_LUMA
end

--- The Toolbox palette a HOST-LESS caller can build: the mono, theme-following set, the
--- same shape and the same roles toolbox_palette() returns for the "EdgeTX theme" scheme.
--- It needs no per-model cfg, no model name and no widget -- which is why it was chosen
--- over reading the cfg or refactoring the host.
---
--- The consequence is deliberate and worth stating: this entry follows the RADIO's theme,
--- while the very same module inside the widget follows the UltiDash colour SCHEME. The two
--- look different on purpose. It also settles the sunlight option (TbSun), which cannot work
--- here for the same reason -- there is no cfg to read it from -- and whose job the radio's
--- own light theme now does.
local function theme_palette()
  return { bg = COLOR_THEME_SECONDARY3, accent = COLOR_THEME_PRIMARY1,
           hint = COLOR_THEME_DISABLED, line = COLOR_THEME_SECONDARY1,
           text = COLOR_THEME_PRIMARY1, textDim = COLOR_THEME_DISABLED,
           valText = COLOR_THEME_FOCUS, valHi = COLOR_THEME_WARNING,
           bannerBg = COLOR_THEME_WARNING, bannerFg = COLOR_THEME_PRIMARY2,
           btnBg = COLOR_THEME_SECONDARY2, btnPressed = COLOR_THEME_SECONDARY1,
           btnDim = COLOR_THEME_SECONDARY3, btnFg = COLOR_THEME_PRIMARY2,
           -- the curve set rides in the same table, or the chrome would be fixed and the
           -- curves left broken
           dark = theme_is_dark() or nil }
end

local function init()
  wgt.tb_pal = theme_palette()
  local ok, m = pcall(function() return loadScript(LV_PATH)() end)
  if ok and type(m) == "table" then
    logview = m
  else
    load_err = tostring(m)       -- keep it: the page below shows it instead of exiting blind
  end
end

local function rebuild()
  lvgl.clear()
  logview.build(wgt, { x = 0, y = 0, w = LCD_W, h = LCD_H })
end

-- UltiDash is not on this card (or the module failed to load): one plain page in the same
-- style as the toolbox pages' own degrade message, RTN leaves.
local function draw_missing()
  lvgl.clear()
  lvgl.build({
    { type = "label", x = 8, y = 8, w = LCD_W - 16, h = LCD_H - 16, font = SMLSIZE,
      color = COLOR_THEME_PRIMARY1,
      text = "UltiDash Log Viewer\n\nUltiDash is not installed on this card.\n"
             .. LV_PATH .. "\n\n" .. (load_err or "") },
  })
end

local function run(event, touchState)
  if logview == nil then
    if not err_drawn then err_drawn = true; draw_missing() end
    if event == EVT_VIRTUAL_EXIT then return 2 end
    return 0
  end
  if wgt.lv == nil then
    rebuild()                          -- first cycle: build alone
    return 0
  end
  if event == EVT_VIRTUAL_EXIT then
    -- the module unwinds its own levels first (chart -> browse); false = nothing left
    if not logview.on_exit_key(wgt) then
      logview.close(wgt)
      return 2
    end
  end
  if wgt.lv_dirty then
    wgt.lv_dirty = nil
    rebuild()                          -- mode/page change: rebuild alone in this cycle
    return 0
  end
  logview.refresh(wgt, event, touchState)
  if wgt.lv_close_req then             -- the module closed itself (M.close already ran)
    wgt.lv_close_req = nil
    return 2
  end
  return 0
end

return { useLvgl = true, init = init, run = run }
