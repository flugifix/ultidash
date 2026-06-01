local M = {

    options = {
        { "Timer",          TIMER,  0 },
        { "BGFilled",       BOOL,   0 },
        { "Reserve",        VALUE,  20, 0, 40 },
        { "CalloutInt",     VALUE,  6,  1, 60 },
        { "Haptic",         BOOL,   1 },
        { "Mute",           CHOICE, 1,  { "None", "Voltage alerts", "Voltage and fuel alerts" } },
        { "StatsViewMode",  CHOICE, 2,  { "Never", "On disarmed", "On disconnected" } },
        { "VoltageDisplay", CHOICE, 1,  { "Cell voltage", "Battery voltage" } },
        { "StartupDelay",   VALUE,  4,  1, 20 },
        { "LinkWarn",       BOOL,   1 },
        { "RQlyWarn",       VALUE,  50, 0, 100 },
        { "RQlyCrit",       VALUE,  30, 0, 100 },
        { "TopLeft",        CHOICE, 1,  { "Model image", "Timer" } },
        { "ColorScheme",    CHOICE, 1,  { "UltiDash", "by EdgeTX Theme" } },
    },

    translate = function(name)
        local translations = {
            Timer = "Which timer to display",
            BGFilled = "Fill background color",
            Reserve = "Reserve capacity (%)",
            CalloutInt = "Callout interval (sec)",
            Haptic = "Vibrate on critical alerts",
            Mute = "Mute (voice and vibration)",
            StatsViewMode = "When to show statistics page",
            VoltageDisplay = "Voltage shown as",
            StartupDelay = "Startup cell-check delay (s)",
            LinkWarn = "Link/telemetry warnings",
            RQlyWarn = "Link quality warn (%)",
            RQlyCrit = "Link quality critical (%)",
            TopLeft = "Top-left area shows",
            ColorScheme = "Color scheme",
        }
        return translations[name]
    end
}

return M
