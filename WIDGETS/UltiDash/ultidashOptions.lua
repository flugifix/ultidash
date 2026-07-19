-- The EdgeTX widget-option list carries ONLY the per-instance ViewMode now.
-- Everything else is configured via the in-widget settings page (fullscreen →
-- menu glyph) and persisted per model in /WIDGETS/UltiDash/cfg/cfg_m_<slot>.cfg —
-- see ultidashSettings.lua. Defaults live in the settings-page group tables
-- (SETTINGS_* in ultidash.lua); ultidash_settings.apply() resolves
-- file > stored option > default on every update().
local M = {

    options = {
        -- Dashboard = full widget incl. all side effects (MSP/audio/stats = publisher).
        -- ELRS details / Status info = passive extra views for a SECOND instance on
        -- another screen (no MSP, no audio, no stats — they mirror the Dashboard
        -- instance via the shared state). Place exactly ONE Dashboard instance.
        { "ViewMode", CHOICE, 1, { "Dashboard", "ELRS details", "Status info" } },
    },

    translate = function(name)
        local translations = {
            ViewMode = "This instance shows",
        }
        return translations[name]
    end
}

return M
