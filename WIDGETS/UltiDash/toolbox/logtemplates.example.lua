-- =====================================================================
--  UltiDash Toolbox - Log Viewer: own sensor templates (example)
--
--  SINCE 0.7.0 THE RADIO MAINTAINS THIS FILE. You do not have to edit
--  anything here: the Log Viewer's card page has an "Edit" mode that
--  creates, renames, duplicates, deletes and reorders templates, and the
--  sensor picker's "Save" button makes one out of whatever you picked.
--
--  This file is for INITIAL STOCKING - putting a set of templates on a
--  card in one go, from a PC.
--
--  How to use it:
--    1. Copy it to  /WIDGETS/UltiDash/cfg/logtemplates.lua
--       (NOT to toolbox/ - see below)
--    2. Add your templates.
--    3. Close and reopen the Log Viewer. NO RESTART IS NEEDED.
--
--  THREE THINGS TO KNOW:
--
--  * The widget REWRITES this file whole whenever you change anything on
--    the radio. Comments and formatting you put in it are lost at that
--    point. That is the price of the radio being able to delete an entry.
--
--  * It belongs in cfg/, not in toolbox/. Deploying UltiDash copies
--    toolbox\*.lua over the card, so a file of this name living there
--    would be overwritten by an update. cfg/ is never written to by the
--    deploy. A logtemplates.lua left in toolbox/ from an older UltiDash
--    is read ONCE, copied into cfg/, and then ignored - the old file is
--    left in place and does nothing.
--
--  * replace = false  -> your templates are ADDED to the built-in ones
--                        (Power / Battery / RF link / Governor)
--    replace = true   -> ONLY your templates are offered. The "Hide
--                        built-ins" switch in Edit mode writes this.
--
--  A curve = the sensor name from the log header (without the unit),
--  i.e. exactly as the sensor is named on the radio: "Vbat", "Curr",
--  "Hspd", "EscT", "1RSS", "RQly", ...  "Rud" or "CH1" work too (note:
--  channel columns sit far right in the CSV and slow loading down a
--  little). At most 4 curves per template are shown; curves missing
--  from a log are skipped. Names are capped at 16 characters and at
--  most 24 templates are kept.
-- =====================================================================

return {

  replace = false,

  templates = {

    ---- examples (commented out) ----
    -- { name = "Temperature", curves = { "EscT", "Tmcu", "Curr" } },
    -- { name = "Vibration",   curves = { "Vibe", "Hspd" } },
    -- { name = "Reception",   curves = { "1RSS", "2RSS", "RSNR", "RFMD" } },

  },
}
