--[[
#########################################################################
#                                                                       #
#  UltiDash v0.3 - Rotorflight LVGL dashboard widget for EdgeTX         #
#  Tested on RadioMaster TX15 and TX16S MK3 (EdgeTX 2.12).              #
#                                                                       #
#  License: GPLv3 or later (http://www.gnu.org/licenses/gpl-3.0.html).  #
#  All components are now GPL-compatible: the HeliDash base (gismo2004) #
#  is GPL-3.0 and the etx-widgets-derived parts are GPLv3.              #
#  See NOTICE.md for the full credits and licensing breakdown.          #
#                                                                       #
#  Distributed in the hope that it will be useful, but WITHOUT ANY      #
#  WARRANTY; without even the implied warranty of MERCHANTABILITY or    #
#  FITNESS FOR A PARTICULAR PURPOSE.                                     #
#                                                                       #
#########################################################################

  UltiDash is a merged/derivative work that builds on and reuses code,
  logic and visual concepts from the following widgets. All credits to
  their respective authors:

  - HeliDash  (gismo2004 - https://github.com/gismo2004/HeliWidget)
      Base widget: overall layout, LVGL UI structure, telemetry handling
      and flight-statistics logic.
      NOTE: the HeliWidget repo is now licensed GPL-3.0 (or later), so this
      base is GPL-compatible and UltiDash as a whole can be distributed under
      GPLv3. (Earlier versions noted it as unlicensed — that is now resolved.)

  The following three are from the etx-widgets collection by Rob 'bob00' Gayle
  (https://github.com/bob01/etx-widgets), licensed GPLv3:

  - ePowerbar                  Copyright Rob 'bob00' Gayle (bob00@rogers.com)
      Battery fuel/reserve model, discrete bar colors, startup cell-check
      and the voice/vibration callout engine.
      Itself based on "Lipo battery from single analog source" by Offer Shmuely.

  - eBitmap                    Copyright Rob 'bob00' Gayle (bob00@rogers.com)
      Model/craft image handling (/images, cell-count specific lookup).

  - eStatus                    Copyright Rob 'bob00' Gayle (bob00@rogers.com)
      Throttle %, multi-vendor ESC status/fault decoder (YGE/OpenYGE,
      Scorpion/Tribunus, HobbyWing, FLYROTOR, OMP, BLHeli_32) and the
      arming-disable reason display.

  - BattAnalog                 Copyright Offer Shmuely  (GPLv2 per its file header;
      the edgetx-x10-widgets repo has no root LICENSE file)
      Only the compact top-bar battery icon *style* was reimplemented here
      (not a verbatim copy of BattAnalog code).

  License summary:
    * The HeliDash base (gismo2004) is now licensed GPL-3.0 (or later).
    * The etx-widgets portions (ePowerbar/eBitmap/eStatus) are GPLv3.
    * BattAnalog (Offer Shmuely) is GPLv2 by file header; only its visual concept
      was reused here, not its code.
  => All reused components are GPL-compatible, so UltiDash as a whole is distributed
     under GPLv3 with the attributions above preserved.
     (This is a plain-language summary, not legal advice.)
]]

local app_name = "UltiDash"
local app_ver = "0.3"
local widg_dir = "/WIDGETS/UltiDash/"

local ultidash = nil
local ultidash_options = loadScript(widg_dir .. "ultidashOptions.lua", "btd")()
---@type WidgetOptions
local widget_options = ultidash_options.options

local function get_ulti_dash()
    ultidash = ultidash or assert(loadScript(widg_dir .. "ultidash.lua", "btd"))()
    return ultidash
end

local function create(zone, options)
    return get_ulti_dash().create(zone, options)
end
local function update(wgt, options) return get_ulti_dash().update(wgt, options) end
local function refresh(wgt, event, touch_state) return get_ulti_dash().refresh(wgt, event, touch_state) end
local function background(wgt) return get_ulti_dash().background(wgt) end

---@type WidgetScript
local script = {
    name = app_name,
    options = widget_options,
    translate = ultidash_options.translate,
    create = create,
    update = update,
    refresh = refresh,
    background = background,
    useLvgl = true,
}

return script
