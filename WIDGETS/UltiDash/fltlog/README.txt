UltiDash - flight log & battery management
============================================

When "Flight log" is enabled in the settings (General group), UltiDash
writes flight data here:

  flights.csv      one line per flight, appended after each disarm:
                   date,time,model,battery_id,flight_s
                   (start time of the flight; model = the FC-set model
                   name; flight_s = tracked flight time in seconds,
                   armed AND rotor spinning; arm cycles shorter than
                   "Min. flight time" are not logged)

  batteries.cfg    YOUR battery registry, edited on the PC. Start from
                   the shipped template: copy batteries.example.cfg to
                   batteries.cfg and edit it (only batteries.cfg is read,
                   so a widget update never overwrites your list). One
                   battery per line, a leading '#' marks a comment line:

    id=1;name=Tattu 6S 3700;cap=3700;models=Goblin 580,Logo 550;profile=2;cycles=0;last=

                   id       unique id, any string (1, 2, ... or an id
                            from an external system, e.g. 96dded9b2f4b43f0)
                   name     display name shown on the radio
                   cap      capacity in mAh (display only)
                   models   comma list of model names this battery is
                            offered for (the FC-set model name, case-
                            insensitive); '*' or empty = all models
                   profile  optional override: FC battery profile 1..6
                            activated on selection. Usually NOT needed -
                            with "Battery sets FC profile" on, the pack's
                            cap is matched against the FC profiles'
                            configured capacities automatically.
                   cycles / last are maintained by the widget: +1 and
                   the date once per battery session (first real flight)

With "Ask battery on connect" enabled, UltiDash opens a selection page
after each fresh connect when batteries.cfg lists packs for the current
model. The Toolbox page "Flight Log" shows the recent flights, per-model
totals and the battery usage.

All files are plain text and safe to back up or edit on the PC (edit
only while disconnected from the radio). This folder ships with the
widget so it is always present.
