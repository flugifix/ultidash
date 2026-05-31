--[[
#########################################################################
#                                                                       #
#  UltiDash v0.1 - Rotorflight LVGL dashboard widget for EdgeTX         #
#  Tested on RadioMaster TX15 and TX16S MK3 (EdgeTX 2.12).              #
#                                                                       #
#  Intended license: GPLv3 (http://www.gnu.org/licenses/gpl-3.0.html)   #
#  NOT yet cleanly licensable as a whole - see the license notes below: #
#  the HeliDash base (gismo2004) currently carries no license, so       #
#  formal redistribution is pending that base being licensed.           #
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
      NOTE: that repo carries NO explicit license file; the author describes it
      as "a personal hobby project shared freely with the community" (as-is).
      It is therefore not formally GPL — for any formal redistribution of
      UltiDash the licensing of this base should be clarified with gismo2004.

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
    * The etx-widgets portions (ePowerbar/eBitmap/eStatus) are GPLv3 - those parts
      and any new UltiDash code are intended to be GPLv3.
    * The HeliDash base (gismo2004) has NO license. "No license" means all rights
      reserved by default - it does NOT mean free to relicense. Only gismo2004 can
      license that code; it cannot be unilaterally placed under GPLv3 here.
    * BattAnalog (Offer Shmuely) is GPLv2 by file header; only its visual concept
      was reused, not its code.
  => The whole work is therefore NOT cleanly GPLv3 yet. GPLv3 is the intended target,
     but a formal public release first requires gismo2004 to license the HeliDash
     base (ideally GPLv3 or "GPLv2 or later"). Private use is unaffected.
     (This is a plain-language summary, not legal advice.)
]]

local app_name = "UltiDash"
local app_ver = "0.1"
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
