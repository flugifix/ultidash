-- =====================================================================
--  UltiDash Toolbox  -  custom labels  (template)
--
--  How to use this file:
--    1. Copy it to  /WIDGETS/UltiDash/toolbox/labels.lua
--    2. In labels.lua, enter only what you want to change.
--    3. Reload the model (or restart the radio) -> the change is live.
--
--  Adjust Map AND Adjust Editor read labels.lua the first time they are
--  opened and lay the entries PARTIALLY over their defaults:
--    * not set (nil)     -> the default stays
--    * empty string ""   -> the slot is cleared (no +/- any more)
--
--  IMPORTANT: labels.lua is NOT overwritten by an update -- an update
--  replaces only the Toolbox/widget files. This .example file, on the
--  other hand, may be replaced.
--
--  So the displayed table is COMPLETELY free to rebuild: every cell
--  (function name per position [1]..[6] per trim row) and the column
--  abbreviations (sub) -- to match your own adjfunc assignment on the FC.
--
--  Structure:
--    rows[rowNo] = { [1] = "...", ... [6] = "..." }   -- function name per pos
--    sub = { "P","I","D","F","O","B" }                -- optional: column labels
--    ranges[rowNo] = { [1] = "...", ... [6] = "..." } -- optional: the editor's
--                                                     --   range hints (TbBert)
--
--  rowNo:     1=Pitch  2=Roll  3=Yaw  4=Throttle  5=Trim 5  6=Trim 6
--  Position:  1..6  corresponds to the columns P / I / D / F / O / B
-- =====================================================================

return {

  -- Column abbreviations (optional). Commented out = default P/I/D/F/O/B.
  -- sub = { "P", "I", "D", "F", "O", "B" },

  rows = {

    ---- Examples: change single things only ----
    -- [3] = { [5] = "Gov Cyc FF (own)" },     -- only cell Yaw / pos 5
    -- [1] = { [1] = "Pitch P (own)" },        -- only cell Pitch / pos 1
    -- [6] = { [4] = "", [5] = "" },           -- clear slots

    ---- The complete defaults, to copy and adapt (commented out) ----
    -- [1] = { "Pitch P Gain", "Pitch I Gain", "Pitch D Gain", "Pitch F Gain", "Pitch O Gain", "Pitch B Gain"  },
    -- [2] = { "Roll P Gain",  "Roll I Gain",  "Roll D Gain",  "Roll F Gain",  "Roll O Gain",  "Roll B Gain"   },
    -- [3] = { "Yaw P Gain",   "Yaw I Gain",   "Yaw D Gain",   "Yaw F Gain",   "Gov Cyc FF",   "Yaw B Gain"    },
    -- [4] = { "Gov P Gain",   "Gov I Gain",   "Gov D Gain",   "Gov F Gain",   "Gov Col FF",   "Gov Gain"      },
    -- [5] = { "Yaw CCW Gain", "Yaw Cyc FF",   "Res Climb Col","",             "",             "Gov Headspeed" },
    -- [6] = { "Yaw CW Gain",  "Yaw Col FF",   "Res Hover Col","",             "",             ""              },

  },

  -- The editor's range hints (option "Adj editor: ranges hint" / TbBert):
  -- same structure as rows, strings only; "" hides a hint.
  -- Cells that are not set keep the built-in default hints.
  -- ranges = {
  --   [1] = { [1] = "90-150" },                -- Pitch / pos 1
  --   [5] = { [1] = "0-50" },                  -- your own hint for your own cell
  -- },
}
