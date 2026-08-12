-- The EdgeTX widget-option list is EMPTY: everything is configured via the
-- in-widget settings page (fullscreen → menu glyph) and persisted per model in
-- /WIDGETS/UltiDash/cfg/cfg_m_<model>.cfg — see ultidashSettings.lua. Defaults
-- live in the settings-page group tables (SETTINGS_* in ultidash.lua);
-- ultidash_settings.apply() resolves file > stored option > default on every
-- update(). (The former per-instance option and its second-screen views were
-- removed.)
local M = {

    options = {},

    translate = function(name)
        return name
    end
}

return M
