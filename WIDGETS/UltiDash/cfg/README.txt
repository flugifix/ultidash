UltiDash — the widget's own data
=================================

Two things live here, and neither is ever overwritten by an update or by a
deploy: this folder is created and then left alone.

  cfg_m_<model>.cfg            one file per EdgeTX model NAME (settings)
  logtemplates.lua             the Log Viewer's own sensor sets

logtemplates.lua is written BY THE RADIO (Log Viewer ▸ the card page ▸ Edit),
whole, every time you change something there — so comments you add to it by
hand do not survive. You can still stock it from a PC; the commented template
is WIDGETS\UltiDash\toolbox\logtemplates.example.lua. A logtemplates.lua left
over in toolbox\ from before 0.7.0 is copied in here once and then ignored.

Per-model settings
------------------

The key is the model NAME, not its model7.yml number -- the number changes
whenever the model list is rewritten (EdgeTX Companion does that on every add
or delete), the name does not. Two models with the SAME name therefore share
one config file: give a copied model its own name if it needs its own config.

These are plain text (key=value). Safe to back up or copy between cards.
Deleting a model's file just resets that model to defaults on next start.

The file lists only the settings you actually changed, plus a couple of
bookkeeping lines UltiDash needs. A setting you never touched has no line
at all, and one you put back to its default loses its line again the next
time that model saves -- a line that is not there simply means "default".
So the file is short and reads as a record of your own choices: open it on
a PC to see what you changed on that model, compare two models with a diff,
or edit a value by hand. Delete a line and that setting returns to its
default.

A file ending in .new is a save that was interrupted (radio switched off
mid-write). It is harmless: your real config file is untouched, nothing
reads the .new file, and the next save replaces it. Delete it or leave it.

Files named cfg_m_model7.cfg are from UltiDash before 0.7.0. They are read
once and rewritten under the model name; the old file is left in place.

Files named cfg_m_<model>_<craft>.cfg are from the "Config file per craft"
option, which was removed in 0.7.0 -- it only ever did anything while
Rotorflight was renaming the model, and did nothing at all otherwise. They
are no longer read. Your settings are not in them alone: that mode always
wrote the plain model file too, with the same content. Delete them if you
like.

This folder ships with the widget so it is always present; older versions
stored the same files directly in WIDGETS\UltiDash\ and UltiDash moves them
in here automatically. You can leave this file in place.
