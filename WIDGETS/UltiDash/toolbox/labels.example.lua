-- =====================================================================
--  UltiDash Toolbox  -  Nutzer-Beschriftungen  (Vorlage)
--
--  So benutzt du die Datei:
--    1. Diese Datei nach  /WIDGETS/UltiDash/toolbox/labels.lua  kopieren.
--    2. In labels.lua nur das eintragen, was du aendern willst.
--    3. Modell neu laden (oder Funke neu starten) -> Aenderung aktiv.
--
--  Adjust Map UND Adjust Editor lesen labels.lua beim ersten Oeffnen
--  ein und legen die Eintraege PARTIELL ueber ihre Defaults:
--    * nicht gesetzt (nil) -> Default bleibt
--    * leerer String ""    -> Slot wird geleert (kein +/- mehr)
--
--  WICHTIG: labels.lua wird bei einem Update NICHT ueberschrieben --
--  ein Update ersetzt nur die Toolbox-/Widget-Dateien. Diese
--  .example-Datei darf dagegen ersetzt werden.
--
--  Damit ist die dargestellte Tabelle KOMPLETT frei umbaubar: jede
--  Zelle (Funktionsname je Position [1]..[6] pro Trim-Zeile) und die
--  Spalten-Kuerzel (sub) -- passend zu einer eigenen adjfunc-Belegung
--  auf dem FC.
--
--  Aufbau:
--    rows[ZeilenNr] = { [1] = "...", ... [6] = "..." }  -- Funktionsname je Pos
--    sub = { "P","I","D","F","O","B" }                  -- optional: Spalten-Kuerzel
--
--  ZeilenNr:  1=Pitch  2=Roll  3=Yaw  4=Throttle  5=Trim 5  6=Trim 6
--  Position:  1..6  entspricht den Spalten P / I / D / F / O / B
-- =====================================================================

return {

  -- Spalten-Kuerzel (optional). Auskommentiert = Default P/I/D/F/O/B.
  -- sub = { "P", "I", "D", "F", "O", "B" },

  rows = {

    ---- Beispiele: nur einzelne Dinge aendern ----
    -- [3] = { [5] = "Gov Cyc FF (eigen)" },   -- nur Zelle Yaw / Pos 5
    -- [1] = { [1] = "Pitch P (eigen)" },      -- nur Zelle Pitch / Pos 1
    -- [6] = { [4] = "", [5] = "" },           -- Slots leeren

    ---- Vollstaendige Defaults zum Kopieren & Anpassen (auskommentiert) ----
    -- [1] = { "Pitch P Gain", "Pitch I Gain", "Pitch D Gain", "Pitch F Gain", "Pitch O Gain", "Pitch B Gain"  },
    -- [2] = { "Roll P Gain",  "Roll I Gain",  "Roll D Gain",  "Roll F Gain",  "Roll O Gain",  "Roll B Gain"   },
    -- [3] = { "Yaw P Gain",   "Yaw I Gain",   "Yaw D Gain",   "Yaw F Gain",   "Gov Cyc FF",   "Yaw B Gain"    },
    -- [4] = { "Gov P Gain",   "Gov I Gain",   "Gov D Gain",   "Gov F Gain",   "Gov Col FF",   "Gov Gain"      },
    -- [5] = { "Yaw CCW Gain", "Yaw Cyc FF",   "Res Climb Col","",             "",             "Gov Headspeed" },
    -- [6] = { "Yaw CW Gain",  "Yaw Col FF",   "Res Hover Col","",             "",             ""              },

  },
}
