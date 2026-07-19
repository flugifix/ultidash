-- =====================================================================
--  UltiDash Toolbox - Log Viewer: custom sensor templates (example)
--
--  How to use this file:
--    1. Copy it to  /WIDGETS/UltiDash/toolbox/logtemplates.lua
--    2. Add your own templates (examples below).
--    3. Restart the radio -> changes take effect.
--
--  The Log Viewer reads logtemplates.lua when it first opens:
--    * replace = false  -> your templates are ADDED to the built-in ones
--                          (Power / Battery / RF link / Governor)
--    * replace = true   -> ONLY your templates are offered
--
--  A curve = the sensor name from the log header (without the unit),
--  i.e. exactly as the sensor is named on the radio: "Vbat", "Curr",
--  "Hspd", "EscT", "1RSS", "RQly", ...  "Rud" or "CH1" work too (note:
--  channel columns sit far right in the CSV and slow loading down a
--  little). At most 4 curves per template are shown; curves missing
--  from a log are skipped.
--
--  Tip: you can also pick sensors ad hoc on the radio — template page
--  -> "Pick sensors ..." — without editing this file.
--
--  IMPORTANT: logtemplates.lua is NOT overwritten by an update — an
--  update only replaces this .example file.
-- =====================================================================

return {

  replace = false,

  templates = {

    ---- examples (commented out) ----
    -- { name = "Temperature", curves = { "EscT", "MCU", "Curr" } },
    -- { name = "Vibration",   curves = { "Vibe", "Hspd" } },
    -- { name = "Reception",   curves = { "1RSS", "2RSS", "RSNR", "RFMD" } },

  },
}
