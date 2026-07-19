UltiDash — per-model settings
==============================

UltiDash stores each model's settings here:

  cfg_m_<slot>.cfg            one file per model slot (default)
  cfg_m_<slot>_<craft>.cfg    optional, when "Config file per craft" is on

These are plain text (key=value). Safe to back up or copy between cards.
Deleting a model's file just resets that model to defaults on next start.

This folder ships with the widget so it is always present; older versions
stored the same files directly in WIDGETS\UltiDash\ and UltiDash moves them
in here automatically. You can leave this file in place.
