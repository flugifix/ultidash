local M = {

    options = {
        -- display / layout
        { "Timer",          TIMER,  0 },
        { "BGFilled",       BOOL,   0 },
        { "TopLeft",        CHOICE, 1,  { "Model image", "Timer" } },
        { "ColorScheme",    CHOICE, 1,  { "UltiDash", "by EdgeTX Theme" } },
        { "StatsViewMode",  CHOICE, 2,  { "Never", "On disarmed", "On disconnected" } },
        { "VoltageDisplay", CHOICE, 1,  { "Cell voltage", "Battery voltage" } },
        { "ShowRQly",       BOOL,   1 },
        { "ShowTQly",       BOOL,   1 },
        { "ShowTPWR",       BOOL,   1 },
        { "ShowTxV",        BOOL,   1 },
        -- battery / fuel
        { "Reserve",        VALUE,  20, 0, 40 },
        { "CellSource",     CHOICE, 1,  { "FC config", "Manual" } },
        { "CellFull",       VALUE,  412, 0, 480 },
        { "CellLow",        VALUE,  345, 0, 440 },
        { "CellCritical",   VALUE,  330, 0, 440 },
        { "StartupDelay",   VALUE,  4,  1, 20 },
        -- alert thresholds
        { "CalloutInt",     VALUE,  6,  1, 60 },
        { "RQlyWarn",       VALUE,  50, 0, 100 },
        { "RQlyCrit",       VALUE,  30, 0, 100 },
        { "PwrWarnV",       VALUE,  90, 30, 500 },
        { "SkpLimit",       VALUE,  50, 1, 2000 },
        -- alerts on/off (Mute = master kill-switch for all; each event individually below)
        { "Mute",           CHOICE, 1,  { "None", "All" } },
        { "Haptic",         BOOL,   1 },
        { "SndCellChk",     BOOL,   1 },
        { "SndFuel",        BOOL,   1 },
        { "SndVolt",        BOOL,   1 },
        { "SndArm",         BOOL,   1 },
        { "SndTelem",       BOOL,   1 },
        { "SndLink",        BOOL,   1 },
        { "PwrWarn",        BOOL,   1 },
        { "SkpWarn",        BOOL,   0 },
    },

    translate = function(name)
        local translations = {
            Timer = "Which timer to display",
            BGFilled = "Fill background color",
            TopLeft = "Top-left area shows",
            ColorScheme = "Color scheme",
            StatsViewMode = "When to show statistics page",
            VoltageDisplay = "Voltage shown as",
            ShowRQly = "Top bar: show RQly",
            ShowTQly = "Top bar: show TQly",
            ShowTPWR = "Bottom bar: show TPWR",
            ShowTxV = "Top bar: show TX voltage",
            Reserve = "Reserve capacity (%)",
            CellSource = "Cell thresholds from",
            CellFull = "Full cell voltage (cv, manual)",
            CellLow = "Low cell voltage (cv, manual)",
            CellCritical = "Critical cell voltage (cv, manual)",
            StartupDelay = "Startup cell-check delay (s)",
            CalloutInt = "Callout interval (sec)",
            RQlyWarn = "Link quality warn (%)",
            RQlyCrit = "Link quality critical (%)",
            PwrWarnV = "Power warn voltage (0.1V)",
            SkpLimit = "Skipped-packet limit",
            Mute = "Mute (master): None / All",
            Haptic = "Vibrate on critical alerts",
            SndCellChk = "Sound: startup cell-check",
            SndFuel = "Sound: fuel callouts",
            SndVolt = "Sound: voltage alerts",
            SndArm = "Sound: armed/disarm",
            SndTelem = "Sound: telemetry lost/ok",
            SndLink = "Sound: low link quality",
            PwrWarn = "Sound: main power lost",
            SkpWarn = "Sound: skipped packets",
        }
        return translations[name]
    end
}

return M
