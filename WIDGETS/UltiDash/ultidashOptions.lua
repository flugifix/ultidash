-- The EdgeTX widget-option list holds exactly ONE key, `Target` -- the declared craft
-- target, chosen where the widget is PLACED (the EdgeTX widget-settings dialog) and never
-- from the in-widget settings page. Everything else is configured there (fullscreen ->
-- menu glyph) and persisted per model in /WIDGETS/UltiDash/cfg/cfg_m_<model>.cfg -- see
-- ultidashSettings.lua. Defaults for those live in the settings-page group tables
-- (SETTINGS_* in ultidash.lua); ultidash_settings.apply() resolves file > default on every
-- update() -- the file carries only the values that differ from their defaults. `Target`
-- is NOT among them and apply() must never write it: the two key sets are disjoint on
-- purpose, so the dialog and the cfg file can never fight over one value.
local M = {

    -- Positional declaration -- lua_widget_factory.cpp parses field 1 = name, 2 = type,
    -- 3 = default, 4 = the choice list for a CHOICE. The stored value is a 1-based INDEX
    -- into that list, so APPEND later entries at the END: `Rotorflight` has to stay entry
    -- 1 forever or every model file in the field would point at a different target.
    options = {
        { "Target", CHOICE, 1, { "Rotorflight" } }
    },

    translate = function(name)
        if name == "Target" then return "Craft target" end
        return name
    end
}

-- The realised targets, as the values EdgeTX stores. One entry today: the widget supports
-- exactly one craft firmware and now says so out loud instead of assuming it.
M.TARGET_RF = 1     -- Rotorflight
M.TARGET_N  = 1     -- number of declared choice entries

--- Resolve a stored option value to a realised target. The ONE place the stored value's
--- meaning is defined -- a second reading elsewhere would be free to drift from this one.
---
--- EdgeTX stores a CHOICE 1-based: widget_settings.cpp:193-202 reads
--- `getUnsignedValue(optIdx) - 1` into the control and writes `newValue + 1` back, so the
--- first entry reaches Lua as 1 and never as 0.
---
--- The value outside 1..TARGET_N is the load-bearing case, not a defensive nicety. A
--- widget that was ALREADY PLACED when this option was added reads **0**, not the declared
--- default: widget.cpp:60-68 (`addEntry`) creates the missing slot as
--- `{ WOV_Unsigned, 0 }`, and `setDefault` overwrites only when the stored TYPE differs --
--- Choice maps to WOV_Unsigned as well, so the types match and the 0 stands. The re-seed
--- that would fix it (`clear()` + the declared defaults) runs only for a FRESH placement.
--- Every UltiDash instance placed under 0.7.x therefore arrives here as 0, and without
--- this branch the update would break every installed instance. The same branch absorbs a
--- model file written by a LATER UltiDash that declared more entries, and a hand-edited
--- non-number.
function M.normalize_target(v)
    if type(v) == "number" and v % 1 == 0 and v >= 1 and v <= M.TARGET_N then
        return v
    end
    return M.TARGET_RF
end

--- The display name of a normalised target, straight out of the declared choice list --
--- so the name a page shows and the name the dialog offers cannot drift apart.
function M.target_name(v)
    return M.options[1][4][M.normalize_target(v)]
end

return M
