-- =====================================================================
--  UltiDash Toolbox: adjustment function id -> display name  (T3)
--
--  The flight controller answers MSP_GET_ADJUSTMENT_RANGE with a NUMBER
--  (the adjustment function id), never a name -- so this table is the
--  widget's own and is keyed to the FIRMWARE, not to the pilot.
--
--  Ids are rotorflight-firmware fc/rc_adjustments.h (4.6.0 line):
--  ADJUSTMENT_FUNCTION_COUNT = 83, every id 0..82 exists, and the ids are
--  stable across builds -- the enum carries explicit values and the config
--  array uses designated initialisers, so a compiled-out entry leaves a
--  hole rather than moving its neighbours.
--
--  Wording rule: the 32 ids reachable through the hand table keep
--  toolbox/common.lua's EXACT strings, so nothing a pilot already reads
--  changes; the rest follow the same abbreviations (Gov/Res/Col/Cyc/Cut).
--  Widths are proven against the measured font metrics of all three
--  radios -- keep that check green when editing here.
--
--  Loaded lazily by toolbox/common.lua, only when the FC table source is
--  active (option TbSource). labels.lua overrides apply AFTER this table.
-- =====================================================================

return {
  [0] = "-",
  "Rate Profile", "PID Profile", "LED Profile", "OSD Profile",            -- 1..4
  "Pitch Rate", "Roll Rate", "Yaw Rate",                                  -- 5..7
  "Pitch RC Rate", "Roll RC Rate", "Yaw RC Rate",                         -- 8..10
  "Pitch Expo", "Roll Expo", "Yaw Expo",                                  -- 11..13
  "Pitch P Gain", "Pitch I Gain", "Pitch D Gain", "Pitch F Gain",         -- 14..17
  "Roll P Gain", "Roll I Gain", "Roll D Gain", "Roll F Gain",             -- 18..21
  "Yaw P Gain", "Yaw I Gain", "Yaw D Gain", "Yaw F Gain",                 -- 22..25
  "Yaw CW Gain", "Yaw CCW Gain", "Yaw Cyc FF", "Yaw Col FF",              -- 26..29
  "Yaw Col Dyn", "Yaw Col Decay", "Pitch Col FF",                         -- 30..32
  "Pitch Gyro Cut", "Roll Gyro Cut", "Yaw Gyro Cut",                      -- 33..35
  "Pitch D Cut", "Roll D Cut", "Yaw D Cut",                               -- 36..38
  "Res Climb Col", "Res Hover Col", "Res Hover Alt",                      -- 39..41
  "Res Alt P", "Res Alt I", "Res Alt D",                                  -- 42..44
  "Angle Gain", "Horizon Gain", "Acro Trainer",                           -- 45..47
  "Gov Gain", "Gov P Gain", "Gov I Gain", "Gov D Gain", "Gov F Gain",     -- 48..52
  "Gov TTA Gain", "Gov Cyc FF", "Gov Col FF",                             -- 53..55
  "Pitch B Gain", "Roll B Gain", "Yaw B Gain",                            -- 56..58
  "Pitch O Gain", "Roll O Gain",                                          -- 59..60
  "Cross Cpl Gain", "Cross Cpl Ratio", "Cross Cpl Cut",                   -- 61..63
  "Acc Trim Pitch", "Acc Trim Roll",                                      -- 64..65
  "Inertia Gain", "Inertia Cut",                                          -- 66..67
  "Pitch SP Boost", "Roll SP Boost", "Yaw SP Boost", "Col SP Boost",      -- 68..71
  "Yaw Dyn Ceil", "Yaw Dyn DB", "Yaw Dyn DB Cut",                         -- 72..74
  "Yaw Prec Cut",                                                         -- 75
  "Gov Idle Thr", "Gov Auto Thr", "Gov Max Thr", "Gov Min Thr",           -- 76..79
  "Gov Headspeed", "Gov Yaw FF", "Batt Profile",                          -- 80..82
}
