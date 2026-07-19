UltiDash — debug logs
======================

When "Debug log to SD card" is enabled in the settings, UltiDash writes
rotating session files here:

  debug_NN.log     one per logging session (round-robin, NN = slot)
  debug_seq.txt    tiny counter that drives the rotation

All are plain text and safe to delete at any time. With debug logging off
(the default) nothing is written here.

This folder ships with the widget so it is always present. You can leave
this file in place.
