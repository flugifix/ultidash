# Changelog

All notable changes to UltiDash are documented here.

## v0.8.1 — 2026-08-30

### Added

- **A warning when two MSP tools are loaded at once.** The RF Tool widget and an RFSuite
  widget each bring their own MSP stack, and both push through the single CRSF telemetry slot
  the radio has — so having both is a misconfiguration, not a richer setup. UltiDash now says
  so in the **config warning overlay**: *TWO MSP TOOLS ACTIVE*, with what to do about it.
  Unlike the ELRS rate notice it needs **no link** — the fault is in the radio's own setup, so
  it is shown from boot and can be fixed before the heli is even powered — and it takes
  precedence over that notice, because two stacks on one slot make every telemetry-timing
  reading unreliable. Disarmed only, dismissed with the **X**, and it can be switched off with
  the existing *Config warning overlay* setting.
  **It does not accuse you of UltiDash's own doing.** Opening the *RFSuite* Toolbox page loads
  that suite into the same Lua state and leaves exactly the traces a second widget would —
  `_G.rfsuite` and its published MSP service, neither of which is ever removed again. The
  evidence is therefore only collected while that page has never been opened, and is sticky
  once seen. The one case this misses, stated rather than hidden: an RFSuite widget that first
  appears *after* the page was opened is not noticed until the next reboot.

### Changed

- **The Toolbox shows only the flight-controller tool you can actually use.** *RF2 Config*
  appears only where the **RF Tool widget** is loaded, *RFSuite* only where **RFSuite is
  installed** on the card. Both used to appear regardless and open onto a page whose only
  content was "the tool is not there" — the normal state on most radios. Normally exactly one
  of the two is offered, which is also the setup that is correct. A **switch shortcut** bound
  to either still opens and still lands on that explanatory page: a saved shortcut must not
  silently do nothing.
- ***RF2 Config* is dimmed while there is no MSP**, like the *FC battery profile* tile beside
  it — it borrows RF Tool's stack. *RFSuite* is dimmed on **arming alone**: it brings its own
  MSP stack and its own link, and UltiDash has no honest reading of that link to judge it by.

### Fixed

- **"RFTools widget missing" named the wrong tool.** Since 0.8.0 either RF Tool *or* RFSuite's
  service can serve the flight-controller data, but the dashboard's arming-flags line and the
  *Sensor check* page both still reported the absence of **any** provider as RF Tool being
  missing — sending anyone running RFSuite after a widget they had deliberately not installed.
  Both now say **MSP provider**, the same wording **menu ▸ Status** already used, and the
  *Sensor check* hint names both possibilities and points at that row.

- **The Flight Log page answers taps again.** Three defects stacked up to a page that read
  as dead (reported from the radio): the CSV load pulled only 2 KiB per cycle — with the
  per-flight statistics columns that is ~12 flights, so a season's `flights.csv` sat on
  *Reading flight log …* for seconds at every open; **all taps were swallowed until that
  load finished**, the tab chips included, although they were already on screen; and a
  quick second tap on the pager (or a chip) landed inside the radio's double-tap window
  and was **discarded entirely** — paging fast was structurally impossible, every second
  tap vanished. Now the load parses up to 90 lines per cycle (measured well inside the
  CPU budget, ~4× fewer cycles), the tabs respond from the first frame, and the pager and
  tab chips accept quick successive taps, with a short cooldown kept as the guard against
  one physical tap fanning out into several events. Rows (and everything that opens a
  page) keep the stricter single-tap rule.

## v0.8.0 — 2026-08-24

### Added

- **A second MSP provider: RFSuite's service, experimental.** Everything UltiDash reads from
  the flight controller — battery profile and config, governor, lifetime stats, telemetry
  config, SmartFuel, ESC protocol, the adjustment table, and the one write (the
  battery-profile switch) — can now come from **RFSuite for EdgeTX** instead of RFTool, over
  that suite's published **MSP service** (`rfsuite.msp`, consumer contract v1). It fills the
  same rows from the same MSP commands, so no page, skin or callout knows or cares which
  provider answered. **RFTool still wins when both are loaded**, by decision: the radio has
  one CRSF transmit slot and two MSP clients pushing into it lose each other's replies.
  A new **menu ▸ Status ▸ MSP provider** row names who is serving, and tells *present* from
  *active* — a published service that nobody is driving reads **(idle)**, which is the one
  state in which the flight-controller rows stay empty and nothing else looks wrong.
  **The costs are deliberate and small.** The detection is two table reads per pass; the back
  end (`ultidashRfs.lua`) is loaded only on a card where the service is actually published,
  so a card with RFTool — or with neither — pays nothing for it. UltiDash does not *pump*
  that suite's link (pumping ticks its MSP runtime alone, so no sensors and no session fill)
  and does not touch anything on `_G.rfsuite` beyond the contract, which is why the MSP
  replies are decoded here rather than through RFSuite's own parsers. Reply callbacks park
  the bytes and return: they run inside a foreign widget's instruction budget, and the decode
  belongs in ours.
  **Untested against a flight controller** — no card has yet carried both this and the
  service, so treat it as experimental and keep RFTool installed for the proven path.

- **The Rotorflight *RFSuite for EdgeTX* suite opens from the Toolbox.** A new
  **Toolbox ▸ RFSuite** page runs `rotorflight-lua-edgetx-suite` inside UltiDash's
  fullscreen, exactly as *RF2 Config* has run the classic `rotorflight-lua-scripts` tool:
  nothing is copied, the suite loads from `/SCRIPTS/TOOLS/rfsuite-core/` on the card, so the
  install decides the version. **Entirely optional and additive** — RFSuite does not replace
  the RF Tool widget, which is still what UltiDash reads the flight controller through, and a
  card without RFSuite shows a page explaining what is missing and where it goes rather than
  an error. Disarmed-only like the other flight-controller pages, force-closed on arming, and
  bindable to a switch shortcut (*Toolbox: RFSuite*, appended to the shortcut list so no
  existing binding moves). While the page is open UltiDash stops RF Tool's MSP queue, so only
  one client talks to the craft.
  **Marked as experimental in the widget itself, not only here.** The Toolbox tile reads
  **RFSuite (exp.)** (the shortcut entry likewise), and tapping it opens a warning page —
  *HIGHLY EXPERIMENTAL*, the three effects below it, and an **Open anyway** button — before
  the suite is loaded. The page stands in front because it is the last screen UltiDash owns:
  from the first pass on, RFSuite paints the whole screen itself and no marker of ours can
  survive there. It is shown on every open (there is no "don't ask again" setting), RTN goes
  back to the Toolbox, and a card without RFSuite still gets the *not installed* page instead.
  **Two limits, both from how EdgeTX runs Lua and neither a fault of either project.** A
  widget gets 20 000 instructions per call and is killed at that point, while a standalone
  Tools script is suspended and resumed with no such ceiling — and RFSuite's pages are
  written for the second. UltiDash therefore treats a budget kill as a normal event and
  retries instead of closing the tool, which is what lets a page finish across several
  passes; but a kill landing inside RFSuite's own redraw loses that redraw and leaves the
  page **blank** until it is reopened, and EdgeTX may print its own *“Error in widget
  UltiDash widget function: CPU limit”* line — cosmetic, the next pass has a fresh budget,
  and it cannot be suppressed from Lua because EdgeTX resets that counter only when a call
  begins. RTN always works. And the suite's module graph costs
  about 0,7 MB of the shared widget Lua state while open, of which closing returns roughly
  two thirds. Running RFSuite from EdgeTX's own Tools menu is unaffected by both.

- **The craft target is declared, not assumed.** UltiDash gains one **EdgeTX widget option**,
  *Craft target*, set in the widget-settings dialog where the widget is placed. The list has a
  single entry — **Rotorflight** — because that is the only craft firmware UltiDash realises;
  the point is that the widget now says which firmware it reads instead of taking it for
  granted, and only loads the Rotorflight machinery for a Rotorflight craft.
  **Existing placements keep working and need no action.** A widget placed under 0.7.x has no
  stored value for an option that did not exist then; EdgeTX reports it as an out-of-range `0`
  and the widget reads that as *Rotorflight*. Nothing is announced, nothing is reset, no
  setting moves, and the dialog simply shows *Rotorflight* the next time you open it. Any
  unrecognised value — a hand-edited model file, or one written by a later UltiDash offering
  more entries — falls back to *Rotorflight* the same way, and a stray `Target=` line in a
  per-model `cfg_m_*.cfg` is ignored (the dialog owns this one, not the settings store).
  Alongside it, the widget **cross-checks** the declared target against the sensors it
  actually resolved: with the link up, sensors present, the resolver's index base derived and
  **no** Rotorflight sensor recognised, *Sensor check* and **menu ▸ Status** report *"no
  Rotorflight sensors found"*. It reports the observation, not a diagnosis — a model whose
  sensors were renamed away from their Rotorflight IDs looks the same from here — and all
  those conditions must hold together, so a cold radio or a powered-down craft never triggers
  it.

- **Batteries are managed on the radio.** `fltlog/batteries.cfg` no longer needs a PC:
  packs can be **created, edited and deleted** from the Flight Log's *Batteries* tab (tap
  a pack → detail page with **Edit** / **Delete**; **+ New** in the header) — and created
  right on the battery query page (**+ New battery**, below *No battery / skip*), for the
  moment an unknown pack is plugged in at the field: the form opens with *models* preset
  to the connected craft, and after Save the pick list reloads with the new pack
  selectable. Editable fields: id (unique, charset-checked, prefilled with the smallest
  free number), name, capacity, models (all / multi-select over the names seen in the
  flight log plus free text), FC profile and cycles (for stocking a used pack); `last`
  stays widget-maintained. The editor performs **line surgery** — only the edited pack's
  line is rewritten, atomically; comments, unknown fields and every other line stay
  byte-identical, so a hand-maintained file survives radio edits. Renaming an id never
  rewrites `flights.csv` (the editor warns with the flight count instead), deleting asks
  first and names the pack's logged flights, and a registry beyond 64 KiB is refused for
  editing with a visible message. Everything is disarmed-only; arming discards an open
  form unwritten.
- **The Flight Log looks like the rest of the Toolbox.** The page drops the stock
  `lvgl.page` chrome for the detail-page style the other tools already use: own header
  with the three tabs as **chips**, palette-matched colours in both schemes, and a `>`
  chevron on every tappable row — a tap is never dead again: Flights rows open the
  per-flight stats detail (as before, now in the same style), **Batteries rows open the
  pack's detail page**, and **Models rows filter the Flights tab to that model** — a
  `Model: … x` header chip shows the filter (tap or RTN clears it) and the footer counts
  `N of M flights` with the filtered total time. The footer pager stays as it was.

- **The statistics page opens on a tap.** Tapping the flight view's **status panel** (the
  card that already shows the flight counter and total time) opens the statistics page on
  demand, disarmed only — and it works with *Stats page* set to **Never** too: that setting
  governs the automatic route, a deliberate tap is your own. The X closes it as usual.
- **The menu on a switch.** A new shortcut target *Page: Menu / settings* opens the
  settings hub — under exactly the menu glyph's own armed rule (refused only while
  genuinely flying), shared with the glyph rather than copied, so the two can never drift.
- **A Live Monitor: up to four sensors as live curves, in flight.** A new Toolbox tool
  (*Toolbox ▸ Logs ▸ Live Monitor*, also a shortcut target) draws the last **15 / 30 / 60
  seconds** of up to four freely picked sensors as stacked strips — after a manoeuvre one
  glance answers *how deep did the headspeed sag, how high did the current spike, how fast
  did it recover*, without a PC and without waiting for the flight's log. Every reading the
  radio sees is kept as a 0.2 s **min/max band**, so a one-frame spike cannot fall between
  samples; the recorder runs whether the page is open or not, and a thin marker shows where
  you armed. Like the adjustment tools the page **works while armed** and never self-closes —
  and it reads EdgeTX telemetry only, no MSP. Sensors and the default window under
  *Settings ▸ Telemetry ▸ Live monitor*; with none configured the feature costs nothing.
  Two honest limits, stated rather than discovered: a peak shorter than the sensor's own
  telemetry interval never reaches the radio, and sampling is coarser while another screen
  is shown.
- **The menus have icons.** Every tile in the menu hub and the Settings menu carries a glyph
  beside its label, and every menu page opens with **the same glyph in its header** — so a page
  says where you are before you read a word of it. The set is 22 small PNGs under
  `WIDGETS/UltiDash/img/`, single-colour line art drawn for a radio screen: on the header they
  are tinted with the theme colour, on a tile they are drawn as-is and shrink on the narrow
  radios. They install like everything else — **they ride in the main `UltiDash-v0.8.0.zip`**,
  and neither voice download changes (the German pack is still `SOUNDS/de/` and nothing else).
  A missing icon file costs its tile the picture and nothing more: the label is then drawn on
  its own, and no page fails over an image.
- **And every menu page says where it sits.** The header title is **UltiDash** on every page of
  the menu tree, and the line under it carries the **whole path** rather than the last step of
  it: *Settings > Display* on a group page, *Settings > Alerts* on the alert list and *Settings >
  Alerts > Voltage* on one alert, *Settings > Colors > UltiDash dark*, *Settings > Telemetry >
  Tele Main*, and *Diagnostics > Status* · *Diagnostics > ELRS Status* · *Diagnostics > Sensor
  check* for the three read-out pages. Before, a leaf page put its own name in the title and only
  half the path underneath, so two levels of the tree looked alike; now one line answers it. The
  tool pages and the battery pickers are not part of that tree and keep their own titles.
- **The whole settings menu is on one screen.** All 13 groups now fit without scrolling on the
  TX16S MK3 and the TX15, in a 3-column grid of icon tiles under the four section headings
  *Appearance* · *Battery & limits* · *Sound & callouts* · *System* — with **taller rows than
  before** (55 px on the MK3), not smaller ones. What paid for it: headings that sit tight
  instead of reserving a lead-in, and the **whole-model *Reset to defaults*, which is no longer
  a button under the grid but the last row of the *General* group** (same confirmation, and it
  now also drops the page's unsaved edits before returning to the settings menu, so nothing can
  be autosaved back over the fresh defaults). The 480×272 MK2 still scrolls by about one row.
- **The menu hub says which pages are which.** Two columns of icon tiles: **Settings** and
  **Toolbox** — the two things you do — then a **‹ Diagnostics ›** heading over **Status**,
  **ELRS Status** and **Sensor check**, the three pages that only read something out. No page
  moved and nothing costs an extra tap; the heading is what tells the three apart from the two.
- **The alerts list is a list of cards.** One card per alert instead of a two-column tile grid,
  one column, and the list scrolls. The name is on the first line; the second carries the
  alert's state **as glyphs** — bell for on, struck bell for off, the loop with its count and
  interval (`3x 5s`, `inf 5s` for *until cleared*), the vibration mark, and the escalation and
  overlay marks where those are switched on — beside **the values the alert is actually working
  with**, read from the very settings it reads at runtime, so the card cannot disagree with the
  behaviour. Two of them say why there is no number of yours to show: *Cell check* reads
  *"thresholds from FC config"* unless *Cell thresholds from* is set to *Manual*, *ESC load*
  reads *"monitoring off"* until its monitor and its limit GVAR are both set up. **The `+R +E +V +O` markers and the legend row
  under the grid are gone** — the glyphs are the legend, and the numbers that used to be one
  page deeper are now on the card. An alert that is off dims its card but still opens it: its
  page is where it gets switched back on.
- **Pages that belong together can be paged through — with the encoder too.** The eight plain
  settings groups, the 13 alert pages and the *Colors*, *Telemetry*, *Voice* and *Shortcuts*
  pages gained two routes between siblings. In the header, **‹ ›** arrows step one page and
  **grey out at the ends** of the set. At the top of the page body, an **icon strip** shows one
  cell per sibling with the current one highlighted: tap a cell to jump straight there, or turn
  the **rotary encoder** onto it and press. The strip is not decoration for touch users — EdgeTX
  offers the header arrows to touch only, so the strip is the encoder's *only* way across. It
  lives in the scrolling body, which means it scrolls away with the content and comes back by
  itself the moment encoder focus reaches it again. Where a whole set shares one glyph (the 13
  alert pages, the three Telemetry pages) it works as a position indicator and still jumps.
- **The Log Viewer is now in the EdgeTX Tools menu too** — **SYS ▸ Apps ▸ UltiDash Log
  Viewer**, without going through the dashboard. It is the same viewer on the same file with
  the same templates; the menu entry is only a launcher for the installed module, so there is
  no second version to keep in step. Two properties come from EdgeTX and are worth knowing:
  while *any* Tools script runs the widget is suspended (no callouts, no flight-log capture),
  and this entry has **no auto-close on arming** — opening it is your own decision and there
  is no running widget left for a gate to protect. The Toolbox entry inside the widget is
  unchanged. UltiDash has to be installed on the same card; without it the entry says so.

- **The fullscreen overlay becomes a warning surface: the config warning overlay.** The red
  fullscreen box that the Main-power-lost, Voltage and Telemetry alerts use now also carries **messages that are not alerts**. The
  first one: the ExpressLRS module's link rate and telemetry ratio against what the flight
  controller was told the link carries. It names both sides, what the difference *does*
  (frames back up and read stale, or bandwidth the link has and the FC never uses), and the
  two values to set. Until now that verdict existed only for somebody who went looking on
  *menu ▸ Diagnostics ▸ ELRS Status*. Disarmed only, lowest priority in the box, once per
  link connect, a tap dismisses it. Switch: *Alerts ▸ Voice / mute ▸ Config warning overlay*
  (default on).
- **The overlay closes with an X, and only with an X.** The alert overlays and the new config
  warning both carry an X in the box's top-right corner; a tap anywhere else on the box is
  swallowed and does nothing. The tap-anywhere it replaces was invisible and turned every
  mis-tap into a close — which on a message meant to be read throws it away before it has
  been. Same change, and the same reasoning, as the detail pages earlier in 0.8.0.
  *Overlay auto-close* is unchanged.
- **A *Commit* row on the ELRS Status page**, beside *Firmware*.
- **A *Link rate* row on the ELRS Status page** — the packets per second the verdict actually
  used, beside the packet-rate name the module displays. They differ on DVDA rates, and that
  difference is the whole point of the row.
- ***Telem ratio = Off* is reported** as its own verdict (`TELEM OFF`) instead of being folded
  into the rate comparison. It takes every value on the dashboard away, so it is not a
  mismatch — it is the answer to "why is everything blank".

- **The second menu level gets its own icons.** *Toolbox*, the *Colors* list and the
  *Telemetry* / *Voice* / *Shortcuts* lists drew plain text tiles, and every page below them
  wore its parent's glyph in the header and in the sibling strip. Seventeen new glyphs close
  that: one per Toolbox tile, one per colour scheme, one per group page. The sibling strip on
  those pages therefore stops being a row of position dots and becomes a map that can be read.
  Two reuses are deliberate — *Live monitor* wears the same glyph in the Telemetry list and in
  the Toolbox, and a skin-supplied colour scheme that ships no artwork of its own falls back to
  the glyph of the *Skin* group. The thirteen alert pages keep their shared bell, as designed.

- **The read-only pages can be driven with the ENCODER.** *Status*, *ELRS Status* and *Sensor
  check* were built from labels alone, and a page of labels has nothing an LVGL widget's rotary
  can move to — so those pages scrolled by finger and by nothing else, which put the newest
  ELRS rows permanently under the fold on a radio being flown with gloves. Every section head
  and each page's closing line is now a focus stop: turning the encoder walks them and the page
  scrolls itself. The stops do nothing when pressed. *The Toolbox tools are unchanged and stay
  touch-driven — they draw their own controls on purpose, and a focusable one would stand in
  front of the long-RTN exit.*

### Fixed

- **The Log Viewer opened from EdgeTX's own Tools menu wore the wrong colours, and drew the
  wrong curves on top of them.** That entry has no widget behind it, so it fell back to the
  module's built-in dark palette — black with a cyan accent, the look the in-widget tools were
  deliberately moved off — and the chart then chose its curve set from a palette flag that
  fallback does not set, so the *light* curves (deep blue, dark red) were drawn on the black
  background. It now takes a mono palette derived from the **radio's own theme**, which needs
  no model configuration, and the curve set follows the same judgement. Consequence worth
  knowing: this entry follows the radio theme while the same viewer inside the widget follows
  the UltiDash colour scheme — the two look different on purpose. The Toolbox *sunlight* option
  has no meaning in this entry and the radio's light theme replaces it.
- **The in-widget Log Viewer and Live Monitor drew light curves on a dark chart** for anyone on
  colour scheme *EdgeTX theme* with a dark radio theme: that scheme's toolbox palette never
  said whether it was dark, although the widget works the answer out one function earlier.

- **The ELRS *Firmware* row showed a bare commit hash instead of a version.** ExpressLRS
  registers the field as `{version_domain, CRSF_INFO}, commit`: the **name** carries the
  version and the frequency domain (`4.1.0 ISM2G4`), the **value** is only the short build
  commit. UltiDash read the value. Both halves are now kept, as *Firmware* and *Commit*. The
  offline decoder test had the two the wrong way round as well, which is what let it ship.
- **The ELRS mismatch verdict compared the wrong thing.** It held packet rate and telemetry
  ratio against the FC's pair for **equality**. The flight controller only ever sees the
  quotient — it refills a token bucket at `rate ÷ ratio` slots per second — so a module on
  500 Hz 1:16 against an FC told 250 / 1:8 is exactly right and was being reported as a
  mismatch. The comparison is now the slot rate, cross-multiplied so it stays exact.
- **DVDA packet rates were read off their name, which is not their rate.** `D500` and
  `D250` repeat every packet and keep a 1000 µs interval — the link runs at **1000 Hz** in
  both cases — and 900 MHz `D50Hz` runs at **200 Hz**. `D500`, `D250`, `F500` and `F1000`
  carry no `"Hz"` at all, so the old parser returned nothing and the page stayed silent on
  precisely the modules that have those rates; `D50Hz` parsed as 50 and gave a confidently
  wrong verdict. A rate name the widget does not know now reads `-` and produces **no**
  verdict rather than a guess.
- **The Live Monitor's curves are legible on a light colour scheme, and thick enough to
  see.** Three faults, all in how the page drew rather than in what it recorded. The curve
  colours were chosen from the *Toolbox sunlight mode* switch alone, while the background
  comes from the active colour scheme — so on the **shipped light scheme** the page drew the
  bright set meant for a dark background: cyan and, far worse, yellow on near-white. Measured
  on the simulator, the current strip was 791 pixels of pure yellow that could not be seen at
  a glance. The set now follows the scheme, exactly as the Log Viewer's curves already did.
  The curves were also a hairline **1 px on every radio**, where the Log Viewer has long
  drawn 2 px above 300 px of screen height; they now do the same, so the two curve pages
  finally agree. And the **arm marker** — the vertical line naming where you armed — was one
  full-height line drawn straight through every strip's label text; it is now one segment per
  strip, standing in the curve area only, and the same weight as the curves.
- **The menu grids now budget against the real page header height.** The grid builder
  reserved a flat 56 px for the EdgeTX page header, which is right on no radio — the header
  is 62 px on the MK3 and 45 px on both 480-wide radios. The MK3 left 6 px of body unused;
  the TX15 and MK2 gave away 11 px each. Visible effects: the TX15 Toolbox menu stops
  scrolling, the TX15 hub keeps its full row height, and a menu grid no longer paints 2 px
  into whatever sits under it (the MK3 Alerts grid over its legend row was the case that
  showed it — that list has since become the card list described above).
- **No more "2 Dashboard instances active!" after switching models.** Changing the radio's
  model raised the dual-instance banner for about five seconds on a model that places exactly
  **one** dashboard. Every widget on a colour radio shares one Lua state, and that state is
  built once per boot and is *not* reset by a model change — so the freshly created instance
  still found the destroyed one's registration and read it as a second live dashboard. The
  test is now "I was the publisher and something displaced me" rather than "somebody else is
  the publisher": only a genuinely live second instance can displace one, and a destroyed one
  never publishes again. **Two placed dashboards are still detected and still warn**, one
  publish cycle (~200 ms) later than before, against a banner that stays up for five seconds
  anyway.
- **Flight counter and total time now share one font and one baseline** in the flight
  view's status panel. The two fonts were picked independently against the same height,
  so the narrower "Flights" sample regularly came out a size larger and the pair sat
  visibly unaligned ("passt nicht ganz ins Bild") — on all three radios.
- **No more EdgeTX background flashing through while a page loads.** The staged page opens
  that keep the widget under the CPU limit leave the LVGL tree empty for 2–3 frames, and
  what showed through was whatever EdgeTX painted behind the widget. A filled rectangle in
  the widget's own background colour now stands under every rebuild, so the gap shows
  UltiDash's background instead.
- **The startup cell-check is no longer silenced by the FC-served adjust table.** With
  *Adj table from* set to a flight-controller source, that read shares one MSP queue with
  the connect reads and holds it for some 4–5 s — but it was issued **first**, so the
  battery configuration (cell count, full-cell voltage) landed behind it, after the check
  had already concluded. Without a per-cell value the check takes its "no reading" verdict:
  the bar goes amber and **nothing is spoken**. Two changes, either of which would have been
  enough: the adjust-table read now queues **behind** the connect reads, and the check now
  defers its verdict while no per-cell value exists at all — under the same 30 s ceiling
  that already covered a carried-over reading, so a pack that genuinely never reports still
  reaches its warning. Reported from the radio on the first evening the FC source was used.
- **The bank announcement no longer chains on fast selector changes.** In the adjustment
  tools, *Announce bank (voice)* spoke every position the Config channel passed through, and
  since EdgeTX offers Lua no way to flush the sound queue, a sweep from bank 1 to bank 6
  queued six announcements that were still playing long after the knob had stopped. A bank
  now has to hold **0.3 s** before it is spoken and two announcements stay at least **1.5 s**
  apart, so a sweep announces its destination and nothing else. A single ordinary change is
  unaffected. (The option itself was always there — *Settings ▸ Toolbox ▸ Announce bank
  (voice)*, on by default.)

- **A spoken telemetry report, on your own switch.** Bind a shortcut slot (position or
  toggle) to the new target *Voice: Telemetry report* and the radio reads out up to eight
  sensors of your choice, **in the order you configured** (*Settings ▸ Voice ▸ Telemetry
  report*). A press speaks one report; a **held** position switch repeats it at a
  configurable interval (10–120 s). It may speak **in flight** — a warning always wins:
  configurable per setting, the report either stops or stands back and resumes. The default
  speaks **value and unit** through EdgeTX's own voice and needs no sound files; speaking
  the **sensor names** is an opt-in that reads `s_<sensor>.wav` files per language, and a
  missing file falls back to value-and-unit rather than silence — a new Status row
  (*Report name wavs*) counts the coverage, because that fallback would otherwise make an
  incomplete set inaudible by design. **The recordings ship for the whole sensor
  catalogue** — 62 clips per language, English and German, in the same two voices as the
  governor callouts. A spoken name costs ~1.8 s (EN) / ~1.9 s (DE), so a report with names
  on runs roughly twice as long as the value-only default: raise *Repeat (switch held)*
  accordingly if you drive it from a held switch.

- **The Toolbox adjust tools can take their table from the flight controller.** A new
  *Settings ▸ Toolbox ▸ Adj table from* option: **Manual** (the built-in table +
  `labels.lua`, unchanged), **Flight controller**, or **FC + labels.lua** (the craft's
  table with your renames on top). With an FC source selected, UltiDash reads the craft's
  own `adjfunc` configuration once per connect — only then, never on opening a page, and
  never while armed — and the Map and Editor rebuild from it: the cells show what *your*
  craft binds where, named from a built-in table of all 83 adjustment functions. The
  **bank now comes from the FC's real enable windows** instead of an even six-way split:
  the standard layout leaves five dead gaps between banks, and a selector sitting in one
  now reads **`Pos -`** instead of a wrong bank — the boundary error near every window
  edge goes with it. A cell the editor's GVAR pulse cannot reach (adjust channel ≠ the
  configured Value channel) keeps its name and loses its `[-]`/`[+]`. A new **Status row
  (*Adjust table*)** names the source actually in force, because a failed or not-yet-run
  read falls back to the manual table rather than showing an empty grid.
- **The Adjust Editor picks the name column's font by width, not only by row height.**
  On the 480 px radios with the ranges hint on, the name column is 123 px and MIDSIZE
  never fit it — 10 of the 31 shipping names clipped (`Pitch P Gain` among them). The
  build now measures the actual cell texts and drops one font size when any would clip;
  all 83 FC-table names fit the worst case that way.

- **A new *ELRS Status* page reads the transmitter module's own settings** — packet rate,
  telemetry ratio, antenna mode, switch and link mode, model match, power — none of which any
  telemetry sensor carries. It is read out of the module over CRSF, the same parameter
  conversation the stock ELRS tool script has, and it is held against what the **flight
  controller** was told the link carries: the FC's rate and ratio are a declaration nothing
  verifies, and they pace every telemetry frame it sends. Declared faster than the link
  actually is and the FC schedules more than the link drains — telemetry that lags and goes
  stale rather than missing. The page says **ok** or **MISMATCH**, and `-` when it cannot know.
  **Experimental, and deliberately frugal:** every request to the module replaces one RC
  channel frame, so the read happens **once per connect, disarmed only**, one request per
  background pass, and aborts if the craft arms — keeping whatever it already read. Never on
  opening the page. After the first radio round the walk got cheaper still: a field the page
  does not show is dropped after the first chunk named it, and once everything else is in the
  scan jumps straight to the last field (the firmware version) instead of walking the middle.
  The **RF band** row appears only when the module registers the parameter (dual-band
  hardware) instead of showing a `-` that reads like a failed read, and on ExpressLRS 4.x the
  firmware manages the antenna mode itself, so what is shown is the effective value rather
  than the one you picked.

- **The Status page shows what the flight controller itself is set to.** A new *Flight
  controller* section: the voltage and current **meter sources**, the FC's own
  **consumption warning**, its **LVC** and **maximum cell voltage**, the **governor** mode
  with its spool-up / start-up / handover figures and its throttle block, the craft's
  **telemetry mode and slot count**, its **SmartFuel mode** and the **ESC protocol** it is
  configured for. All of it is configuration — it cannot change while you fly, so it is read
  once at connect and never appears on the dashboard, which is for things that move.
  The FC's own fuel warning is there **to look at**: it is shown next to your own thresholds
  and never drives a callout. Your callout thresholds stay yours.
- **The sensor check knows which sensors your helicopter actually sends.** UltiDash now reads
  the flight controller's own telemetry slot list. A sensor that exists on the radio but is
  **not in that list** is marked **N/S** — *the FC does not send it* — instead of the green
  *OK 0.0* it used to get. That zero was a leftover, not a reading, and it was worst exactly
  where a zero is also a legitimate value: ESC faults, arming flags, governor state. A
  required sensor in that state now counts in the summary line as well.
  Two things it deliberately does not do: on a craft running **NATIVE** CRSF telemetry the
  firmware ignores the slot list entirely, so nothing is claimed at all there; and the list is
  read once per connect, so a telemetry setting changed **without** a reboot shows the previous
  answer until the next connect.

- **The Status page names the RFTool this radio carries.** A new *RFTool API* row, showing the
  contract version the tool publishes (`1.00` today). It is there to answer *"why does this
  install behave differently"* and nothing more: **no** feature is switched on or off by that
  number. An RFTool that does not report it at all is a working 2.3.0-RC1 — the row says *not
  reported* and everything keeps running, because locking that install out to enforce a version
  string would break a setup that works today.

- **A page can now come up by itself when you arm** — *Display ▸ Behaviour ▸ "Open page on
  arming"*: pick one of the four detail pages and it opens on the arm, once, a moment later so
  the view switch is out of the way. Close it like any other page and it stays closed until the
  next arm; if you already had something else on screen, nothing happens. It is greyed out
  while *Close detail pages on arm* is on, because that option re-closes any detail page for as
  long as you are armed — the two cannot both hold, and this is the one that would have lost
  silently.

- **Five more ESC families are decoded, and one of them was a defect.** A Scorpion/Tribunus
  **throttle error** used to read as *"Scorpion ESC OK"* — a fault reported as health, because
  the one bit that carries it had no branch. New decoders: **ZTW** and **XDFly** (one protocol
  with OMP since firmware 4.6.0 — same frame, different sync byte — plus ZTW's three extra
  throttle bits), **APD**, **Graupner** and **Kontronik**, whose twenty-four flags are ranked
  so the worst one is what you see. The four OpenYGE braking states are named instead of
  showing a raw `Code x09`. All of it is taken from the bit layouts the flight-controller
  firmware documents, and checked by an offline test — but no helicopter here runs a
  Kontronik, an APD, a Graupner, a ZTW or an XDFly, so those five have never met a real ESC.

### Documentation

- **Every screenshot retaken, on the radio the widget is designed for.** The
  [Illustrated Walkthrough](docs/WALKTHROUGH.md) and the README's two composed figures were
  grabs from a build *before 0.7.0* at **480 × 320**, and the page carried two notices
  listing what they no longer showed — the redesigned menu, the Skin settings group, the
  Toolbox's newer entries, the extra Status rows. All of that is gone: the set is now
  **800 × 480 from a TX16S MK3 running 0.8.0**, taken in one session, and the two notices
  with it.
- **They are one helicopter at one moment, not twenty unrelated screens.** The pictures were
  taken against a real Rotorflight 4.6 flight controller configured as a 700-class machine on
  12S with a YGE ESC, held at a single row of one real flight — so the craft name, the
  governor labels, the battery profiles and the cell thresholds on the Battery page are the
  firmware's own, the Log Viewer graphs that same flight, and the Flight Log lists it.
- **The dashboard's annotated figure is drawn from the widget's own tap rectangles**
  (`wgt.battery_rect`, `wgt.values_rect`, …) instead of by hand, so the six outlined zones
  cannot sit where the panels are not. The showcase animation was rebuilt from the same set.
- **What to do when *Discover new sensors* finds nothing.** Reported from the radio: adding
  rows to a craft's `telemetry_sensors` and discovering again can produce no new sensor and no
  error at all, because EdgeTX caps a model at **60 sensors** and then switches discovery off
  by itself — silently, the *telemetry full* warning being compiled for the monochrome radios
  only. The setup guide's sensor step and a new `docs/REFERENCE.md` §6.2 now name the symptom,
  the two causes that cannot be told apart from the outside, the remedy (clear the Telemetry
  page and let the whole list rebuild in one pass) and what a rebuild costs. The *Sensor check*
  page's hint and the *not sent* paragraph point at it.
- **The ELRS Status page is described rather than shown.** It reads the transmitter module's
  own configuration, and the module is the one thing a simulator cannot supply — a figure
  taken there would be a page of dashes.

### Changed

- **The German voice pack is a separate download.** The release now ships two zips:
  **`UltiDash-v0.8.0.zip`** — the widget plus the English WAVs, everything the dashboard needs
  — and **`UltiDash-v0.8.0-voice-de.zip`**, which carries `SOUNDS/de/ultidash/` and nothing
  else. Nothing changed in the widget: *Voice language* still defaults to **English**, so the
  main download is complete on its own. What made the split worth doing is this release's own
  sensor-name recordings: with the whole catalogue spoken in both languages, the German half
  is now about as large as everything else put together, and most people never switch to it.
  **If you do set *Voice language* to Deutsch without the addon installed, the callouts go
  silent** — EdgeTX ignores a WAV that is not there, so there is no error to see. Install the
  addon, or switch back to English.

- **Detail pages and the stats page now close through a visible button, and only through it.**
  Until now a tap **anywhere** closed them: on the detail pages a grey *"tap to close"* label
  said so and did nothing itself, and the stats page said nothing at all. Both now carry an
  **X** — top-right on the detail pages, in the top bar on the stats page — and a tap that hits
  nothing does nothing. Two things this buys beyond being visible: reading a page no longer
  ends the moment you fumble a touch, and pages whose whole surface was one close button can
  finally carry controls of their own. **RTN, a bound shortcut switch and *Close detail pages
  on arm* are unchanged.** A layout skin cannot remove the button — where a skin draws its own
  header, the host places one anyway.

- **Diversity is two antennas, not a sentence — and the ELRS page says which mode the module
  runs.** The footer spelled out *"Diversity: yes"* / *"Diversity: no"* beside *"Ant 1"* on a
  page that is otherwise bars and colour. Both are now one **pair of antenna symbols** in the
  shape of the icon set's own antenna: a filled head on a mast means that antenna is there, and
  the one currently carrying the link (the `ANT` sensor) is **green and radiating** — a hollow,
  dimmed second antenna means the receiver has only one.
  Beside them the footer names the **antenna mode of the ExpressLRS transmitter module** —
  *Gemini*, *Ant 1*, *Ant 2*, *Switch* — as the module itself reports it during the
  once-per-connect configuration read; a module that has no such setting (any single-radio
  2.4 GHz module) simply shows nothing there rather than a permanent dash. The session's
  *RQ min* keeps the footer's left half and gets the freed width.

- **The Toolbox menu is grouped by what a tool is for** — *Adjustments*, *Logs*, *Flight
  controller* — and laid out in two columns where the screen is wide enough. The headings cost
  a row each, which is exactly what the second column pays for: on a 480×272 MK2 the six tiles
  in one column already ran off the bottom of the page. *Battery profile* is still always
  present and dimmed rather than hidden, and the *"available only while disarmed"* line still
  has its reserved space.

- **Units beside values belong to the layout now.** Whether a unit is worth what it costs in
  font size depends on the layout, so — like the colour scheme before it — the switch moved
  into the **Skin** group, with each skin free to carry its own key and default. The host's own
  row stays and now owns the **detail pages**, which are host-drawn: *Display ▸ Units on detail
  pages*. Under the built-in UltiDash skin both are the same switch, exactly as before, and a
  skin that declares no key of its own keeps following the host's — **nothing to migrate and no
  stored setting moves.**

- **The connection state now comes only from where a radio actually delivers it.** UltiDash used
  to also read a field called `rfToolState` off the RFTool — a field no installable RFTool has
  ever had, so on a radio that read never did anything, while in the test rig it was the only
  channel being exercised. The state now arrives exclusively through RFTool's own callback, the
  way it always did on real hardware. Nothing changes on screen; what changes is that the path
  under test is the path that runs.
- **Reading the config file got about twice as fast.** The parser walked every value three times
  — trimming spaces that were not there, testing whether it looked like a number, then converting
  it. It now does that in one step, unchanged in what it accepts. On a fully populated
  configuration this takes the most expensive startup frame from ~15 000 instructions to
  ~11 000, well clear of the radio's limit.
- **Saving settings can no longer run out of CPU budget, no matter how much you change.**
  The config write used to put the whole file into one widget call, and its cost grew with
  every setting the file carried — it stood close to the radio's per-call instruction limit
  and was the reason a very full configuration could kill the widget with *CPU limit* on
  leaving a settings page. The write now goes to the card in small batches, one per screen
  cycle, into a temporary `.new` file that replaces the real one only after a size check —
  so the cost per call is fixed, and switching the radio off mid-save can never leave a
  half-written config: either the old file or the new one, nothing in between. A full save
  takes a few invisible frames (~a third of a second at worst) instead of one overloaded one.
- **The widget starts lighter.** The settings catalogue — every row of every settings page —
  and the built-in data tables (colour schemes, palettes, the sensor catalogue) used to be
  built the moment the widget loaded, inside the tightest CPU window EdgeTX gives a widget.
  They are now built one screen cycle later, in a budget of their own. Nothing visible
  changes; the CPU cost of the load itself drops to less than a third of what it was.
- **The heaviest layouts build in two steps.** A skin may now hand the host the heavy half
  of its build to run one screen cycle later, with fresh CPU budget (a new, optional part
  of the skin API — see `docs/SKINS.md` §3). Cockpit, Dash1 and Grid use it: rings, the
  sensor column and the tile grid arrive one invisible frame after the rest of the page,
  and no single step of any bundled layout comes near the CPU limit any more — including
  with every option set to its most expensive value.
- **Opening a settings page with sensor pickers is lighter too.** The sensor pick list
  (built from your model's real sensors) gets its own screen cycle instead of sharing one
  with the page's other preparation — the heaviest single step the widget had left. One
  more invisible frame at page open, on those pages only.
- **The config file carries only what you changed.** `cfg_m_<model>.cfg` used to be written
  with the entire settings catalogue (~200 lines) as soon as any settings page was left with
  one edit — every value, changed or not. It now stores only the settings that differ from
  their defaults, plus its bookkeeping stamps; a value put back to its default leaves the
  file on the next save. This cuts the save's CPU cost roughly in half on the radio (the
  write ran close to the widget budget's warn line and grew with every release) and makes the
  file readable as a record of your actual choices. A file written in full by an earlier
  version **compacts page by page**: a save only rewrites the settings of the page you were
  on, so the redundant lines leave as you visit the pages they belong to — nothing waits on
  that, because a line holding a default value and no line at all mean exactly the same
  thing. Behaviour note bought deliberately: an absent line now *means* "follow the default",
  so if a future version changes a default, an untouched setting follows it — the rule colour
  overrides always had, widened to everything. *Reset to defaults* writes a minimal file for
  the same reason, and clears the whole file in one go.

### Fixed

- **The scroll wheel now walks a settings page from top to bottom.** It did not: the wheel
  visited every dropdown, toggle, slider and picker first, in row order, and only then every
  plain button — the `-` / `+` of a stepper, a colour row's *Def*, an action row's button —
  again from the top. On a page that mixes both, the focus ran to the bottom and jumped back
  up, and the page scrolled with it. Pages built from pickers alone were unaffected, which is
  why it only bit sometimes. The order now follows the rows as they are read.

- **The `BAT#` sensor-check hint said the profile line goes blank, and it does not.** The
  default layout's battery-profile field prefers the pack size read over MSP, so with the
  flight controller connected that field keeps showing it. The hint now says so. `PID#` and
  `RTE#` carry the same wording and are correct — only the battery row overstated it.

### Performance

A pass over the whole widget after a CPU-limit review, aimed at the two numbers that had crept
up with every release: what a screen rebuild costs, and what a settings page costs to open.
**Nothing here changes what you see** — the one behaviour consequence is named under *Changed*
above, and it is the config file compacting page by page. Measured with the development budget
harness: the worst rebuild cycle falls from **13,173 to 9,812** of the radio's 20,000-instruction
call limit (connected: 13,276 → 9,915) — the two runs that used to carry a warning are both back
in the clear.

- **The dashboard stops re-reading your settings on every rebuild.** Every rebuild — a flip
  between the flight and statistics views on arming, a detail page opening, each step through
  the menu — re-read the whole ~296-entry settings catalogue and re-resolved every value,
  although nothing had changed since the last time. It is now done once and reused until
  something actually saves a setting, you switch model, or EdgeTX hands the widget a fresh
  options table. That is ~1,800 instructions off *every* one of those calls at once, and it
  is what takes the heaviest cycle back under the warning line.
- **A settings page only loads its own settings.** Opening any settings page copied the entire
  catalogue into the edit buffer — ~296 keys plus ~50 synthesised colour keys — for a page that
  edits ten to thirty of them, and it was that copy, not the page itself, that made every page
  cost the same ~11,600 instructions and grow with every release's new rows. Each page now
  seeds only what it shows: the settings groups measure **~2,300–7,300** instead of
  10,979–11,611, and a new row in a future release costs its own page rather than all of them.
- **The settings catalogue is built page by page.** All fourteen flat settings groups used to
  construct their ~120 rows — labels, value lists, formatters — during startup, in the frame
  that reads the config file, even for pages nobody opens. A group now builds its rows the
  first time it is opened (the shape the Alerts, Colors and Shortcuts pages already used) and
  keeps them. Startup's heaviest frame drops **10,463 → 8,621**; a page open pays at most 267
  instructions more, against the nine-to-fourteen thousand of headroom it has.
- **The menus and the detail pages got cheaper to open** as a consequence of the three above:
  the settings menu **10,045 → 3,129**, the main menu **5,091 → 1,777**, the four detail pages
  5,483–5,804 → 2,160–2,481. On short screens the settings grid also stops re-laying-out the
  whole page once per pixel while it shrinks to fit — it solves for the size and lays out once.
  Same result, same floors, nothing moves visually.
- **Less work per frame while flying.** The Live Monitor's recorder ran a full name lookup for
  every configured sensor on every pass (~20 Hz) and asked the radio for the arming state the
  same way; it now reads resolved sensor indices and the arming flag the widget already keeps.
  The three-second sensor rescan stopped allocating ~40 throwaway tables each time it runs, and
  three texts that were rebuilt on every display frame — the ESC event-log counter, the Status
  page's *FC fuel warn* row, the throttle percentage — are rebuilt only when their value moves.
  A handful of bars and icons dropped closures that recomputed the same build-time position on
  every frame — measured on the simulator, on the link bars, where the resolved rectangle came
  out identical to the pixel with the closure gone. None of this is visible; what it buys is
  frame timing and less garbage-collector drag, which is worst exactly when the flight
  controller is connected.
- **The budget harness gained a correctness check.** Making the settings groups lazy created one
  new way to lose data — a setting the page builds but the catalogue never hears about would be
  deleted from your config file on the next save, silently and with no error anywhere. The
  development check now builds every page on every run and holds it against the catalogue, so
  that mistake fails the check by name on a PC instead of on a radio. It is a check that can go
  red with every instruction count green.

## v0.7.1 — 2026-08-13

### Added

- **The Status page names the config file this radio is using.** A **Config file** row under
  *Version*, showing the `cfg_m_*.cfg` that is actually being read and written. Until now
  nothing on screen answered that question, so settings you never made had no explanation.
  Two markers can follow the file name: **(found)** — the lookup by name missed and this file
  was located by its model-file stamp, i.e. the model is wearing a craft name at the moment;
  and **(! model7)** — the file found by name says it belongs to another model.
- **The debug mode's on-screen overlay has its own switch.** *Settings ▸ General ▸ Show perf
  overlay* (default **on**). The live *UI Hz / Lua heap / free heap* strip and the SD debug log
  used to be one setting, so a session that wanted the **log** — a flight, a screenshot, a
  report somebody else reads — also got the strip sitting over the layout. Switching it off
  leaves the logging completely untouched; the row is dimmed while *Debug log to SD card* is
  off, which is the only state in which nothing is drawn anyway.

### Fixed

- **One helicopter could end up with two config files.** The per-model config is keyed by the
  EdgeTX model name — and that name is not yours to keep: with *"set model name on TX"* on,
  Rotorflight renames the model to the connected craft and puts the name back on disconnect.
  UltiDash latches the name at start, which covers a rename that happens while it runs. It
  could not cover one that had **already happened** when the widget first loaded, i.e. a radio
  booted with the craft powered: the lookup by name then missed and a **second** config was
  born under the craft name — one machine, two files, neither of them looking wrong, and
  settings landing in whichever one that boot had picked. The config is now **found by name
  and identified by model file**: every save stamps it with the model file it belongs to, and
  when the lookup by name misses, UltiDash finds the config carrying this model's stamp and
  uses **that** one — reading and writing it for the rest of the session, rather than copying
  it, which would only postpone the split by one save. **The stamp is written from this
  version on**, so a config last saved by an older one is protected from its next save onward,
  not retroactively. If the file found by name turns out to carry *another* model's stamp —
  two models sharing a name — the name wins, and the contradiction is reported on the Status
  page instead of being repaired behind your back.
- **A switch shortcut no longer swallows the press after you close its page some other way.**
  Reported from the field against 0.6.1: *opening the Log Viewer over a switch does not always
  work.* A **toggle** slot remembers how far along its option chain it is, and that counter
  was only ever reset by a press of the same switch — so leaving the page with **RTN**, tapping
  it away or **arming** left the counter standing. The next press then meant *close what is
  already closed*: with a single-option chain it opened **nothing** (every second flick
  appeared dead), and with a longer chain it opened the option *after* the page you had just
  left. The chain now resynchronises against the page that is actually up, so the next press
  always starts again at option 1. Position slots were never affected — leaving the position
  resets them anyway.

### Changed

- **A shortcut thrown while the widget is not in EdgeTX's *Full screen* now says so.** Tool
  and detail pages have always required full screen (a fullscreen page cannot be built into a
  widget zone), and the switch simply did nothing — with no menu glyph in a zone there was
  nothing on screen to connect the dead switch to a setting. The dashboard now shows a brief
  **"Shortcut needs Full screen"** banner instead.
- **Documented the toggle slot's press length.** Switches are read from the widget's own pass,
  which runs about every 0.2 s, so a press has to last at least that long to be seen. A shorter
  flick of a momentary switch is not filtered out — it is **sometimes** not sampled, which from
  the cockpit is a switch that works most of the time. Measured on the MK3, five presses per
  length: 0.20 s and longer 5/5, 0.15 s 4/5, 0.10 s 4/5, 0.06 s 1/5. Written into
  `docs/REFERENCE.md` §2.7c.

## v0.7.0 — 2026-08-12

### Added

- **Log Viewer templates are made on the radio.** The *"What to display?"* card page is now
  also their manager: an **Edit** chip turns it into one, and a card tap then opens that
  card's actions — **Rename**, **Duplicate**, **Delete** (with a confirmation) and
  **Move forward / Move back**, one position at a time in list order. New ones are created in
  the **sensor picker**: pick your set and tap **Save**, next to *Show* — it saves *and*
  displays. The name is proposed from the picked sensors, can be typed over, and saving under
  a name that already exists asks *"Replace X?"* — that overwrite **is** how you change a
  template, so there is no separate edit function. Names are capped at 16 characters (the
  longest a card can show on the smallest radio, whatever the name is made of) and at most 24
  own templates are kept.
  The four built-ins — *Power / Battery / RF link / Governor* — stay part of the program and
  can be neither renamed nor deleted. Two ways round that: **Duplicate** one and edit the
  copy, or switch **Hide built-ins** on to take all four off the page.
  **Migration:** the file the widget writes is `WIDGETS/UltiDash/cfg/logtemplates.lua`, not
  the old PC-edited `toolbox/logtemplates.lua`. A file at the old path is **adopted once**
  into the new one on the next Log Viewer open and then ignored — it is copied, not moved, so
  nothing of yours is deleted. The move matters: deploying UltiDash overwrites `toolbox\*.lua`
  wholesale, and that directory is now the wrong place for a file the radio writes into.
  Stocking it from a PC still works (the format is unchanged, and
  `toolbox/logtemplates.example.lua` documents it), but the widget rewrites the file whole, so
  comments in it do not survive a change made on the radio. Picking up a change needs no
  restart, only closing and reopening the page — the old *"restart the radio"* note was wrong.

- **Fixed-voltage orientation callouts.** Two new *Settings ▸ Battery ▸ Volt callout 1 / 2
  (V/cell)* thresholds add a second, voltage-triggered gate **alongside** the %-step fuel
  callouts: set a per-cell voltage (e.g. 3.80 / 3.75 V) and UltiDash speaks that voltage
  **once per flight** the first time the cell voltage settles at/below it. A *Volt callout
  delay (s)* setting requires the voltage to hold in-band that long before firing, so a
  brief load sag doesn't trigger it early (0 = immediate). Announced per *Announce voltage
  as*; both thresholds default to *off*; they re-arm each flight and are suppressed during
  MAIN-POWER-LOST. Independent of the low/critical *Voltage* alert.
- **The first tap after the radio has been sitting is no longer lost.** A new
  *Settings ▸ Display ▸ Keep backlight on (full screen)* (default **on**) keeps the screen
  awake while UltiDash owns the whole display. Once the backlight has timed out, EdgeTX spends
  the next press on waking the screen and no widget ever sees it — on the bench that is exactly
  the tap meant to open a detail page, and nothing on screen says why. Your own *Backlight off
  after* setting is deferred rather than overridden, and only in full screen: in a layout zone
  the radio's normal power saving is untouched. Turn it off in one row.

- **The Status page says which build the radio is running.** *menu ▸ Status* gained a
  **Version** row at the top. Until now the version existed only inside the widget's code and
  was drawn nowhere, so the question could not be answered without pulling the card. A
  development build also shows a short commit — written onto the card by the deploy script,
  since a Lua script cannot know its own commit; a trailing `+` means it was built from an
  uncommitted working tree. Release cards show the version alone.

- **The FC battery profile can be reached without a tap zone.** Switching the flight
  controller's battery profile used to have exactly one way in: tapping the *B-Profile* field
  on the dashboard. Whether that field exists at all is up to the active layout — so a layout
  that does not offer the zone removed a whole feature, with nothing on screen to say so. It
  is now also a **Toolbox** entry (*menu ▸ Toolbox ▸ Battery profile*) and a **switch
  shortcut** target (*Settings ▸ Shortcuts*, as *FC battery profile*). All three routes are
  the same page behind the same gate — **disarmed only, and only with an MSP connection** —
  and each re-reads the profile from the flight controller before opening, so the picker never
  shows a value cached at connect time. The tap zone is unchanged. Opened from the Toolbox,
  the back arrow returns to the Toolbox; opened by a tap or a switch it returns to the
  dashboard.

### Added — skin system (the substructure; the layouts are in development)

> ⚠️ **The skin system is in development, and this release carries its substructure rather
> than its skins.** The engine, the skin API, the discovery of `skins/*.lua`, the *Skin*
> settings group and the per-skin colour schemes are all here, and the built-in **UltiDash**
> look is now a skin like any other. The **additional layouts are deliberately held back** —
> they are still being reworked, and holding them back is what keeps the API free to change
> while they settle. Expect the skin API, its cfg keys and its colour-override storage to
> move again: a skin written against this release may need changes on the next one. See
> **[docs/SKINS.md](docs/SKINS.md)**, which describes the contract and says the same thing
> at the top.

- **The flight/stats layout is a swappable module.** A new **Dashboard skin** choice
  (*Settings ▸ Display*) picks the look; the choice lists every skin found on the card.
  The built-in **UltiDash** layout — the original three-panel dashboard (status / battery
  gauge / values + top bar + status bar) — is the default and is unchanged on screen.
- **Skins are self-contained, discovered files.** A skin module in
  `WIDGETS/UltiDash/skins/*.lua` carries everything that makes it up: the layout code
  **and** its manifest — display name, colour schemes, own settings rows, scheme
  persistence. Skins are **discovered automatically** (the file name is the id) —
  dropping the file in is the install; nothing is registered in the host, which only
  requires `skins/default.lua` (the fallback look). A new authoring guide,
  **[docs/SKINS.md](docs/SKINS.md)**, documents the skin API, the value catalog and the
  rules. A broken or missing skin falls back to the built-in look (never a blank screen).
- **Colours and options belong to the skin.** Each skin owns its **colour schemes** and
  its **own settings**, both shown in a new **Skin** settings group:
  - the **Color scheme** choice moved from *Display* into the **Skin** group and now
    lists the *active skin's* schemes. The UltiDash skin keeps its three (UltiDash /
    UltiDash dark / EdgeTX theme, existing keys — nothing to re-pick). Each skin
    remembers its own pick and starts in its own default scheme. *Settings ▸ Colors*
    shows one page per scheme of the active skin, with the usual per-colour picker +
    *Def* reset.
  - the top-bar / left-panel options (**Top-left shows**, **Top bar clock**, **Timer**,
    the **RQ / TQ / RSSI / TX-voltage** toggles and **Link bars quiet**) moved from
    *Display* into the **UltiDash** skin's own options (they describe *its* layout).
  - stored keys are unchanged — **no cfg migration**, and an inactive skin's options and
    colour overrides are preserved when you switch skins.
- **Skin API additions** (all additive — the built-in look and the cfg format are
  untouched):
  - **Sensor slots carry more.** `env.sensor_slot()` now also returns `.label_short` (the
    catalog's new compact caption per sensor — "BEC Voltage" → "BEC" — for card layouts),
    `.unit_raw` (the unit *regardless* of *Display ▸ Units beside values*, for skins that
    put it in a caption row where it costs the value no font size) and
    `.min_formatted` / `.max_formatted` (the sensor's EdgeTX **session extrema**). The
    extrema cost two extra source reads per slot per pass, so a skin opts in with
    **`M.wants_extrema = true`**; without it the 5 Hz pass is unchanged.
  - **The settings-menu tap zone is placeable:** `set_tap(wgt, "menu", rect)` — a skin that
    draws its own header can put the menu button where it likes. Unregistered, the host's
    fixed top-left region stays the fallback, as before.
  - **Contrast helpers** `env.is_dark(color)` / `env.ink_on(color)`: a skin cannot judge a
    colour's luminance itself (it is an opaque RGB565 value), so it could not decide black
    or white ink on a theme-driven fill.
  - **The two *Volt callout* thresholds are published to the skin API**, so a skin drawing
    a cell-voltage scale can mark them on it beside the alarm and warning ticks.
  - **A skin that cannot load now says so, instead of quietly looking like the default.**
    Every rejection path — a chunk error, a wrong `api`, a missing build function, an error
    in `init`, a stored skin id with no file on the card, a `skins/` folder that cannot be
    read, a file dropped by the 16-skin limit — logs one line **naming the reason**. If the
    skin *you picked* is the one that failed, the dashboard carries a
    **"Skin '&lt;id&gt;' failed - using default"** notice, and the *Dashboard skin* choice marks
    the row **"&lt;name&gt; (error)"**. Your pick still stores the plain id, so repairing the
    file needs no re-pick.
  - **A half-copied skin no longer costs you its settings.** The config's unknown-key sweep
    (which retires keys no current version knows) is **suspended for any session in which a
    skin failed to load** — a failed skin never declares its settings rows, so the sweep
    would have deleted every one of its stored values on the next save. The sweep resumes
    once the file is fixed.
  - **The four detail pages are skinnable.** A skin can declare
    `M.build_detail_elrs` / `_estatus` / `_battery` / `_telem` — one, some or none — and draw
    that page itself; anything it leaves out keeps the built-in page. The host keeps opening
    and closing the pages, the taps that get there, the data gating and the arming gates. If a
    skin's page raises, the built-in one is drawn instead, the reason is logged, and a notice
    appears along the bottom **of that page** while it is open; the skin's page is retried the
    next time you open it. The builders themselves moved into a separate file with no visible
    change — verified pixel-identical to the previous release on all four pages.
  - **Thresholds come from the host now: `env.threshold_for(wgt, name)`.** A skin asks for a
    sensor name and gets back a ready bundle — live value, fill percent against the right
    scale, the colour rule, tick positions, and whether the threshold is configured at all.
    Eleven names are served (ESC load, ESC and MCU temperature, cell and pack voltage, fuel,
    RQly, TQly, RSSI, TX power — plus the *Voltage (auto)* sentinel `~volt`, so a slot can be
    asked for by the name that is actually stored in the config). The same warn/crit
    arithmetic used to be written out in
    every layout that drew a bar, and the cell-voltage scale existed twice in code — one
    renamed settings key and they would have drifted apart. A name the host does not fetch
    on its own (MCU temperature) is picked up by the 5 Hz pass **only while a skin asks for
    it**, so nothing costs anything unused.
  - **Sensor slots carry their raw number:** `slot.num()` beside `slot.value`, for a bar or
    ring that needs the value numerically instead of as text.
  - *Fixed in passing:* the top bar's link bars fell back to link-quality and RSSI warning
    levels that matched no setting's declared default (RSSI would have warned permanently
    against a 15 % default). Unreachable in practice — the real defaults are always loaded
    first — but the host may not carry two answers to the same question.
  - **Tap zones report their two silent failures.** `set_tap` stores one rect per zone and
    the last writer wins; it now logs a zone claimed twice in the same build, and a zone
    name it does not know (a typo used to make a dead zone with no evidence at all).
    `docs/SKINS.md` §8 states the contract and the register-the-important-one-last idiom.
  - **A skin can migrate its own config keys: `M.migrate(t)`.** Until now a skin that renamed
    a key, or changed what one of its values *means*, silently reset that setting for everyone
    who had configured it — the host defaults every declared key before a skin ever sees the
    file, and the next save deletes the old key. The new optional manifest function is handed
    the **raw per-model config table** once per model, immediately after it is read and before
    anything is defaulted or drawn, and converts the skin's own keys in place. It has to be
    idempotent and must touch only its own prefixed keys; nothing is written to the SD card
    for it, so the conversion is simply redone on every load until the user next saves. Also
    documented at last: the `choice` row's **`ids`** field, which stores a name instead of a
    list position and is the thing a format migration usually exists for. `docs/SKINS.md`
    §7c, §7 and the §12 box.

### Changed

- **A spoken battery voltage is now the value the callout actually decided on.** The voltage
  alert, the fixed voltage callouts (`VSay1` / `VSay2`) and the startup cell check all trigger
  on the **per-cell** voltage, but the total voltage they announced came from the separately
  read pack voltage. The two are independent sensors, each held by its own filter, so under
  load they can be a moment apart — measured once as a callout that fired at 3.75 V per cell
  and announced a pack voltage a third of a volt higher. The announced total is now derived
  from the same per-cell reading that triggered the callout. Nothing changes while the two
  agree, which is the normal case.
- **The warn/critical boundary is the same everywhere — a value exactly ON a threshold now
  reads the way it sounds.** The top-bar link bars used `value < critical` and the ELRS detail
  page used `value >= warning`, while the voice callouts have always used
  `value <= critical` / `value <= warning`. At a link quality of exactly the configured
  warning threshold the radio said "link warning" while the bar was still green; at exactly
  the critical threshold it said "link critical" while the bar was amber. Both displays now
  follow the callout engine, so the picture and the voice change at the same value. Only
  values *exactly equal* to a threshold are affected — everything else looked and sounded the
  same before.
- **The sensor-check page calls `Esc#` what it is: the ESC *signature*, not the ESC status.**
  The status word is the row below it (`EscF`). What a missing `Esc#` costs is unchanged and
  the hint still says it: without the signature the fault decoder cannot pick a vendor and
  stays blank.
- **Removed: the `ViewMode` second-screen views — the widget now has no EdgeTX options.**
  The passive *ELRS details* / *Status info* instances (a second UltiDash on another
  screen mirroring the dashboard) are gone; the feedback round found no real use, and
  the same data lives on as the dashboard's own detail pages (tap the link bars / the
  status line) and the menu's **Status** entry. The `ViewMode` option went with them, so
  the EdgeTX option list is now empty — every setting lives in the in-widget menu.
  - ⚠️ **Upgrade note:** EdgeTX drops the stored option with the update, so a second
    instance that was set to *ELRS details* or *Status info* silently becomes a **full
    dashboard**. Two dashboards double the callouts and show a **"2 Dashboard instances
    active!"** banner — **delete the second instance** and the banner clears. Nothing
    else changes; per-model cfg files are untouched.
- **Per-model settings are keyed by the model NAME, not by the model file number.** Adding
  or deleting models — above all from **EdgeTX Companion**, which rewrites the whole model
  list — renumbers the surviving `MODELS/modelN.yml` files (EdgeTX hands them out by lowest
  free index), and every UltiDash config was orphaned in one go: the affected models came up
  with defaults and the first-run install hint. The key is now `model.getInfo().name`,
  **latched** when the model becomes active, so Rotorflight's *"set model name on TX"* — which
  renames the EdgeTX model to the connected craft and restores the stored name on disconnect
  — cannot move the file mid-session either. The file is now `cfg/cfg_m_<model-name>.cfg`,
  and it is the only one: the second level (*Config file per craft*) is removed in this same
  release, see below.
  - **Upgrading keeps everything.** A model with no name-keyed file yet reads its old
    `cfg_m_model7.cfg` (and, further back, the flat `cfg_<name>.cfg`) and rewrites it under
    the name on the next save. Nothing is deleted; the old file stays where it is. Config
    lost to a Companion run *before* this version is gone, though — it was already
    unreferenced.
  - **Two models with the same name now share one config file.** EdgeTX has no stable
    per-model identifier, so uniqueness is the user's: a copied model (`Rotorflight`,
    `Rotorflight Test`, …) needs its own name if it needs its own configuration.
- **Removed: *General ▸ Config file per craft*.** The `<craft>` half of
  `cfg_m_<model>_<craft>.cfg` was the model name *as it read at that moment*, so the option
  only ever split anything while Rotorflight was actively renaming the model — with *"set
  model name on TX"* off for the craft (the FC's `MODEL_SET_NAME` flag) both halves of the
  file name were identical and the setting did nothing at all. That precondition was never
  documented, which is most of why the option looked like it worked.
  **Upgrading loses nothing:** per-craft mode always wrote the plain model file too, with the
  same content, so the last saved configuration is in it and is what UltiDash now reads. The
  `CfgPerCraft` key is swept out of the model file on the first save; old `cfg_m_*_*.cfg`
  files stay on the card unread and can be deleted. What is genuinely gone is the split
  itself: someone who flew several crafts from one EdgeTX model *with* the FC flag set now
  has one configuration for all of them — the most recently saved one.
- **Fuel steps are no longer throttled by the repeat interval.** The Fuel alert's *Repeat
  interval* used to double as the minimum gap between two descending %-step callouts, so a
  fast-falling end of flight lost a step — with *dense below 15 %* / *fine step 5 %* the
  15 → 10 → 5 ladder can pass in well under the 6 s default. The steps now use a fixed 2 s
  gap (just enough that two callouts don't tread on each other) and the *Repeat interval*
  applies to the critical nag only, as its name suggests. Steps are also spoken **only on
  the way down**: a rising level (pack recovering off-load, an FC value jumping back up)
  re-arms the ladder silently instead of counting its way back up. Replaying a real flight
  log through the old and new engine at *dense 25 % / fine 2 %*: 12 callouts before, 15
  after — the three swallowed ones were 24 / 20 / 16 %. A **fourth** swallowed step (the
  first one after arming on a full pack) is fixed separately, see *Fixed* below.
- **Unit suffixes are now optional — and off by default.** The small unit beside each value
  (`V`, `A`, `rpm`, `°C` …) is controlled by a new *Settings ▸ Display ▸ **Units beside
  values*** switch, **default off**, which restores the original formatting: the value keeps
  the full column width and therefore the **biggest font that fits**. The units were costing
  font size on every screen and left the flight panel too small to read on the 480×320 TX15
  (and the 480×272 TX16S MK2). The switch covers the flight values panel, the Telemetry
  detail cards and every skin slot fed by the skin API, so a skin's own value slots follow
  it too. Turn it on where there is room.
- **Display holds only skin-independent settings now.** The *Bottom bar* section is gone; its
  two rows sat in the wrong group:
  - ***Bottom bar: TPWR*** → **Skin** group, as ***Status bar: TPWR***, declared by the
    skin. It only toggles a field of the host status bar, and whether that bar is shown at
    all is a per-skin option — so under a skin that draws no status bar, the Display row was
    a dead switch. It greys out when the active skin's bar is off, and (as before) affects
    the **flight** view only: the stats page always prints TX power. The key is shared
    across skins, like the top-bar rows.
  - ***TPWR bar max (mW)*** → **Thresholds ▸ Link & signal**, as ***TX power limit (mW)***.
    It is not a display option but this transmitter's **ELRS dynamic-power ceiling**
    (25 / 100 / 250 / 500 / 1000 mW, region- and config-dependent) — the 100 % reference of
    the inverted TPWR bar on the ELRS detail page, next to the other link limits.
  - Both **stored keys are unchanged** (`ShowTPWR`, `TxPwrMax`) — nothing to re-configure.
  - The *Sensor check* no longer hides the missing-`TPWR` hint when the status-bar field is
    off: the ELRS detail page's TPWR bar needs the sensor regardless, so a configured *TX
    power limit* alone now makes the sensor relevant.

### Fixed

- **The BEC and Temperature alerts were dead in flight on some setups.** Both asked the RF
  tool whether the craft was armed instead of reading the ARM sensor — and on setups where
  the RF tool never reports an armed sub-state, that answer is *never yes*, so neither alert
  could fire at all. They now read the sensor, like every other armed-only alert. Where the
  RF tool's state is the right source — the voltage latch, the session statistics — nothing
  changed.

- **A layout's RSSI bar could go red while the voice stayed silent.** With antenna diversity
  the spoken warning follows the *better* antenna; the colour thresholds a layout asks the
  host for read antenna 1 alone. Both follow the better antenna now — the whole point of
  that service is that the bar and the callout cannot disagree.

- **A faulty layout could take the dashboard down with it, callouts included.** A skin file
  is code you drop onto the card, and its two view builders ran unguarded: an error in one
  killed the widget's Lua state, so the alerts and voice callouts — which have nothing to do
  with how the screen is arranged — went with it. A failing builder now falls back to the
  built-in look with the usual *"failed - using default"* banner, a failing menu page closes
  back to the dashboard, and both say why in the log. Neither is remembered for the session:
  a builder can fail on one odd frame of data, and that must not cost you your layout for
  the rest of the flight.

- **"Reset to defaults" left your colour overrides on screen until the next reboot.** The
  config file was reset correctly — the colours were not, so the page said *defaults* and the
  dashboard still showed the old ones, which reads as the reset not having worked. Overridden
  colour roles are deliberately not written to the file (that is what keeps a config small),
  and nothing put the live ones back. They revert on the spot now.

- **Saving a template over an unreadable template file wiped it.** *Manage templates*
  already refuses to open while your own templates cannot be read — but the sensor picker's
  **Save** never asked, and with the file unreadable the list it writes back holds the
  built-ins alone. One save replaced your templates with nothing; a second one dropped the
  backup copy too. Save now makes the same refusal, and says so where you actually end up —
  the chart — instead of only on a page you have just left.

- **A hand-stocked template with more than four sensors lost the extras on first use.** The
  documented shape of a template file is a *superset*: list as many sensors as you like and
  the log's own header decides which four are drawn. That trimming had moved to load time, so
  the first rename, move or *Hide built-ins* wrote the shortened list back and the rest were
  gone for good. The list is kept whole again and capped only where it is displayed.
  Two smaller ones with it: template names from the file now go through the same clean-up as
  a name typed on the radio (a duplicate gets a number instead of appearing twice, where
  before the second card was unreachable), and a name that already belongs to a built-in is
  refused even while *Hide built-ins* is on — it used to be accepted and then collide the
  moment you switched the built-ins back on.

- **A shortcut could open a detail page you had no way to close.** Detail pages are
  fullscreen pages — the tap that closes them needs touch, and a widget-grid zone gets none.
  The tap and menu routes are fullscreen-only anyway, so a switch shortcut was the one way to
  strand yourself on one. Shortcuts to detail pages now wait for fullscreen exactly as
  shortcuts to Toolbox tools already did, and a shortcut-opened *Status log* starts at the
  top instead of inheriting the scroll position of the last one.

- **A missing detail-page module took the whole widget down.** If `ultidashDetail.lua` did
  not make it onto the card, the log said *"detail pages disabled"* — and then the widget
  died on the next start anyway, because the module was called before that promise could be
  kept. The check now covers everything the host later relies on, taps on the four detail
  zones do nothing while there is nothing to open (they used to eat the following tap and
  leave the menu glyph dead for one press), and a *"Skin page failed"* banner no longer
  lingers after switching to a layout that simply has no page of its own.

- **An empty value in a config file swallowed the next two settings.** The parser read the
  whole file as one stream instead of line by line, so on a line with nothing after the `=`
  the whitespace rule ate the line break and the value rule then took the *following* line as
  the value — one setting lost its value, the next vanished entirely. A comment line
  containing an `=` was read as a setting for the same reason. Every line is now matched on
  its own and anchored to its start. Two more of the same family went with it: a config file
  written by a *newer* UltiDash no longer has its schema stamp pushed backwards by an older
  one (which made the next upgrade migrate a file that was already migrated), and the one-time
  adoption of a pre-0.7.0 file is written through a temporary file and only then renamed into
  place — a write that runs out of card used to leave a stub behind that permanently hid the
  intact original.

- **Deploying UltiDash without the layouts deleted their settings.** Saving anything drops
  config keys that no current setting knows, which is what retires keys from older versions —
  but a layout that is not on the card never gets to say which keys are its own, so one save
  was enough to remove a configuration nobody had touched. Since the layouts ship separately
  this was one forgotten copy step away. The config now remembers which layouts it was written
  with and holds that clean-up while one of them is missing, exactly as it already did for a
  layout that is on the card but broken. Removing a layout for good simply leaves its keys in
  the file.

- **A battery whose line carried a `recycles=` or `ballast=` field had it overwritten.**
  The post-flight stamp looked for `cycles=` and `last=` anywhere in the line, so it found them
  inside longer field names of your own and counted up — or dated — the wrong field. Both are
  now recognised only where a field can actually start.

- **A layout's config migration could fail without a trace.** The host runs it inside a
  guard so a bad one cannot take the dashboard down, but the failure was never logged, and a
  migration that silently never ran is indistinguishable from one with nothing to convert. It
  now names the layout and the error in the log.

- **Opening *Settings ▸ Skin* with the Dash1 layout killed the widget.** On a TX16S MK3 the
  page painted itself and then a red `ERROR in widget: CPU limit` over the top, dimmed
  everything under it and stopped responding — the settings menu could not even be left. It
  needed a model with a normal amount of telemetry to show up, which is why it reached a radio
  rather than a test: the more sensors the model has discovered, the more expensive the page,
  and Dash1's is the widest one in the program at 34 rows with eleven sensor pickers.
  Two things shared one allowance. Every sensor row asked *"where in the pick list is my
  current value?"* on **every frame** and answered it by walking the whole list — eleven rows
  times a ~39-entry list, every frame, for a value that only moves when you tap something. And
  the pick list itself, a scan of all 60 of the model's sensor slots, was built inside the same
  call that builds the page; the live closures of an LVGL page run on whatever instructions
  that call leaves over, so there was nothing left for them. Now the list is built in the
  page's existing preparation call — the one that already stages the working copy, one
  invisible frame earlier — and the rows look their value up in a table instead of searching
  for it. Nothing about the page changes: the same 34 rows, the same values, the same edits.
  This is host-side, so **every** layout with sensor rows got cheaper, not just Dash1. Worst
  measured page cycle on the MK3, build plus its own live closures: Dash1 17469 → 13281,
  Cockpit 15091 → 11484, Grid 13618 → 11463. Reproduced in the simulator harness on the MK3
  from the reporting pilot's own 262-key configuration — red before the change, clean after,
  including with a raw (uncurated) sensor picked.

- **The budget harness could not see per-frame cost at all, and now can.**
  The PC-side instruction-budget check (a development tool, not part of the release)
  collected each page's live closures and ran them *after* the call it was timing, so every
  number it ever printed was build cost only — a page could pass at 13541
  and still die on the radio, which is what happened above. It now invokes each build's own
  closures inside a counted window and reports the **cycle**: build plus frame, which is the
  number EdgeTX's 20000 is actually applied to. Its model also carries 50 telemetry sensors now
  instead of none, so sensor pickers are measured at the size a real model gives them.

- **The Log Viewer's sensor picker could die and stay dead.** Open a log, tap *Custom
  sensors*, fold a group open, and the page could paint a red `ERROR in foreground calRefs
  error` over itself, dim everything under it and stop responding — no tap did anything after
  that, and only leaving the page cleared it. It got likelier with every sensor row shown, and
  the bigger the screen the worse, so the 800×480 MK3 saw it most. It was there before the
  template manager, which merely sat on the wrong side of a limit that was already reached.
  Two things were spending the same budget. The page hung a live closure on each row — three
  per row, twelve rows on the MK3 — and those closures run on whatever instructions are left
  over from building the page that created them, so the build and its own machinery competed
  for one allowance. And the grouping of the log's ~100 columns was recomputed every single
  time a group was folded or unfolded, although it only depends on the file. Now the page
  redraws instead of animating itself — a sensor tap costs the same redraw that folding and
  scrolling always cost, and the picture is identical — and the grouping is worked out once
  per log. Measured in the simulator harness on the MK3, over the folded picker, one-, two-
  and twelve-sensor groups in both List and Grid: red before, clean in four runs of four
  after.

- **The first-run hint clipped its own title on every radio.** The *UltiDash setup* panel that
  greets a fresh placement split its height into four equal lines and then drew the title in a
  larger font than the three lines below it, so the title never had the room it needed — worst
  on the 480×272 TX16S, which has the least to spare. The panel now measures both fonts and
  grows if it has to.

- **Two texts overflowed their box on some radios.** *Diversity: yes/no* in the ELRS page
  footer had a hardcoded height that only fitted the two 480-wide radios, so it was the MK3
  that clipped it; it is measured now. And *Status ▸ Repeat* — the summary of which alerts
  repeat and how often — is a generated line whose length grows with the number of active
  alerts, which wrapped to two lines inside a one-line row on the TX15 and the TX16S. That row
  now takes a second line when it needs one, rather than the summary being shortened: it is a
  diagnostic line and all of it is worth keeping.

- **A *Debug log* left switched on could kill the widget on the next start.** With the option
  already stored when UltiDash starts, the developer perf overlay is built before the first
  performance sample exists, and it handed its label an empty text — which aborts the refresh
  pass and takes everything below it: the screen freezes on the first frame, no callout is
  ever spoken, and the debug log stays at its session header. Switching the option on from the
  menu never reached that state, which is why it stayed hidden. The overlay now shows `-`
  until the first sample arrives, as it was always meant to. Found in the simulator harness;
  on a radio it needs the widget to start within the first second of power-on, so it is
  unlikely to have been seen in the field.

- **An in-flight telemetry dropout lost the whole flight's log line.** Lose the link long
  enough in flight for the RF tool to drop and reconnect, and the flight was missing from
  `flights.csv` afterwards — however long it had been. Same root cause as the callout below,
  one branch over: the flight record is meant to be flushed **at** an armed disconnect,
  precisely because a later reconnect resets the flight-time counter, and that branch asked the
  same impossible question. So the flush waited for the falling ARM edge instead, which arrives
  only when the link comes back — by which time the reconnect had zeroed the clock, and the
  flush computed a flight of 0 seconds and wrote nothing. The widget's own defence against
  exactly that (`counter was reset mid-record`) cannot fire on a session's first flight. Both
  branches now read the ARM sensor. Measured in the simulator harness against a real flight
  controller (`fcfltgap`): a 6.4 s gap in a 33 s armed flight wrote **no row** before and
  writes the flight's row after. Lose telemetry while
  flying and UltiDash was supposed to announce *telemetry lost*, repeat it, and say
  *telemetry ok* on the reconnect. On the bench it did; in the air it never could. The
  escalation asked whether the RF tool's **previous** state was `armed` at the moment it went
  `disconnected` — and at a real loss it never is: the tool loses the ARM value about 1.3
  seconds after the frames stop and reports `disarmed`, and only about 4.9 seconds later does
  its own connection timeout make it `disconnected`. So the gate compared `disarmed` with
  `armed` and the whole alert stayed silent, together with the *telemetry ok* on the
  reconnect and the escalation-volume boost that hangs off the same latch. It had only ever
  been seen working against a stand-in that jumped straight from armed to disconnected.
  UltiDash now asks the **ARM sensor** whether the craft was flying when the link went away.
  That is the one signal that survives the gap — the sensor keeps serving its last received
  arming word for EdgeTX's own ~30 s expiry, an order of magnitude longer than the tool's
  timeout — while a **normal disarm is unaffected**, because there the cleared arming word
  still reaches the radio over the live link and reads as disarmed. Measured end to end
  against a real Rotorflight 4.6.0 and the real RFTool 2.3.0 in the simulator harness
  (`fctelemlost`: three announcements 5.21 / 5.26 s apart and one *telemetry ok*, where the
  same run measured none before), with `fctelemdisarm` as its negative control: land, disarm,
  unplug — and nothing is announced. Plug a fresh pack
  in soon after unplugging the last one and the start-up cell check announced *battery low*
  with the voltage the **previous** flight ended on, and turned the battery gauge amber — on a
  full pack. Reproduced on 2026-08-01 and dated to the millisecond from the widget's own Debug
  log: the check reached its verdict **3.35 seconds before the new pack reported anything at
  all**. The cause is a platform behaviour rather than a stale variable — EdgeTX keeps handing
  Lua the last value it received until the new telemetry session replaces it, so the reading
  the check armed on was a perfectly current read of a battery that was already off the
  helicopter. The check now recognises a reading that is unchanged since the last session and
  **waits** for the connected pack to report (up to 30 s, after which the existing "no value"
  warning stands). Nothing is suppressed: a pack that really is low still announces, at the
  voltage it actually has. Only a *fast* pack change was affected — leave a minute between
  packs and the sensor had already been reset. Covered by a regression test that fails
  without the fix.
- **"CPU limit" when arming with the settings page still open.** Changing any setting and
  then arming (with telemetry connected) could kill the widget with
  `ERROR in widget: .../ultidash.lua: CPU limit`. The autosave wrote the cfg file **and**
  re-resolved it into the options in a single widget call — together most of EdgeTX's ~20k
  instruction budget — and the arm-close path runs that inside the 5 Hz telemetry pass, so
  the call went over (measured 22.4k). The autosave is now staggered like the deferred
  start-up: one cycle writes the file, the next resolves it, neither sharing a call with
  other work (measured 11.1k / 6.5k). Costs two invisible frames; nothing changes for the
  user beyond the crash being gone. Present since the autosave was introduced — reported
  from a v0.6.1 radio, but v0.7.0 had it too. The budget harness now covers both autosave
  callers (RTN close and arm-close) including the deferred stages.
- **The first fuel callout after arming on a FULL pack was swallowed.** With the default
  10 % step the descending ladder started speaking at *80 %*, never at *90 %*. The
  "first observation after arming" is meant to be adopted silently (so arming on a
  half-used pack doesn't fire a callout straight away) — but it was consumed on the first
  *change* of the level rather than on the first *pass*, and on a full pack the first
  change IS the first real step. Replayed through the fuel-callout replay tool (development only): a 100 % → 25 %
  descent now announces 90 / 80 / 70 …; arming on a half-used pack is unchanged.
- **Skin session min/max never updated on the dashboard.** A skin declaring
  `M.wants_extrema` only ever saw its `min`/`max` fill while the *Telemetry* detail page
  was open, and then froze at that state — the manifest flag was read but never copied off
  the skin module, so the opt-in was inert. The budget harness now asserts the effect, not
  just the cost.
- **Reset to defaults** wrote every "unset" colour role into the cfg as `-1` (~57 keys per
  scheme). That inflated the file, rebuilt exactly the cfg-parse load the save path
  deliberately avoids, and made the reset write the single heaviest call in the widget
  (17k of the ~20k budget). It now follows the same rule as a normal save, and — like the
  autosave — is staggered into its own cycles (measured 9.6k / 6.9k).
- **Fixed (tag-less) colour schemes were not actually fixed.** They fell through to the
  UltiDash scheme's override keys and so inherited that scheme's user colours. Documented
  behaviour (docs/SKINS.md §6) now matches the code. Colliding scheme tags between skins
  are reported in the debug log during discovery.
- **Layout: several boxes were sized in fixed pixels for an unmeasured font** — the four
  detail pages' *tap to close* hint, the *Telemetry*/skin-failure placeholder texts and the
  Status page's rows. On the 800×480 MK3, where the fonts are taller, that clipped
  descenders. All measured now, as the rest of the UI already does.
- **Menus and settings on a short screen (480×272 class).** Row heights and the page-header
  reserve were decided purely from `zone.h`, but the EdgeTX controls they must clear
  (toggle switches, the page title bar) scale with the *theme*, not the screen height — so
  on a 480×272 radio the settings rows would have been shorter than their own toggles, the
  exact overlap that the taller rows were introduced to fix. Row heights now take
  `lvgl.UI_ELEMENT_HEIGHT` as a floor and the header reserve is constant. The 800×480 MK3
  and 480×320 TX15 are unaffected. A battery-picker button *width* that was keyed on the
  screen *height* was corrected too.
- Small fixes: the debug perf overlay no longer sits on top of the menu button (it would
  hide the only way to switch itself off again), the Log Viewer's pan checks the RAM cache
  for the window it actually lands on, and the passive-view style signature can no longer
  alias with 16 skins installed.

## v0.6.1 — 2026-07-23

Maintenance release on top of v0.6.0: one small battery-callout option plus Log Viewer
performance and a smoother disconnected idle. Existing behaviour is unchanged by default.

### Added

- **Fuel callout can speak voltage.** A new *Settings ▸ Battery ▸ Fuel callout says* choice
  (**Percent** / **Battery V** / **Cell V** / **% + Battery V** / **% + Cell V**) picks what
  the descending %-step callouts announce. The %-interval triggering is unchanged — only the
  spoken value changes; it reads the latched, collapse-filtered voltage, is independent of
  *Announce voltage as*, and falls back to the percent when a requested voltage isn't
  available (never silent). The critical nag keeps speaking the percent. Default *Percent*
  = unchanged behaviour.

### Changed
- **Faster Log Viewer pan/zoom.** Panning now shifts the existing scratch buckets and only
  re-reads the newly exposed edge, and a unified RAM window cache (a hi-res base plus finer
  zoom levels) backs the view, so zooming and panning stay fluid even on large logs.
- **Cursor readouts follow the chart.** The Log Viewer's value readouts moved into a
  compact legend that tracks the chart line instead of sitting in a fixed corner.
- **Snappier idle UI while disconnected.** `read_src` holds a nil telemetry result for 3 s
  instead of re-hitting the source every cycle, keeping the dashboard responsive when no
  flight controller is connected.

## v0.6.0 — 2026-07-19

Maintenance + feature release on top of v0.5.1. **Experimental — still shaking out in the
field.**

### Added
- **Dedicated "Status text" colors for Armed / Disarmed** (*Settings ▸ Colors*, new
  section on all three scheme pages). The statusbar arm-state text no longer has to share
  the traffic-light green / the Warning-accent palette slot: assign *Armed* and *Disarmed*
  their own colors per scheme. Left unset, both follow the historical colors (armed = the
  effective Good green incl. its override, disarmed = the resolved Warning accent), so the
  default look is unchanged. The Status page's "Armed" connection line follows the Armed
  color too.
- **ESC load display in the battery gauge** (alternative placement). New *Load bar*
  choice in *Settings ▸ ESC load*: keep the classic thin bar under the dashboard's
  Current row, or turn the **free gap** between the battery gauge's fill segments and its
  outline into the load display. The load lights **whole gauge rows bottom-up** (snapped
  to the segment rows, in the warn/critical colours) — so a row is ever fully on or off,
  never a ragged partial edge — following both contours: the outline's rounded corners via
  filled arc sectors, the top/bottom segments' rounding via under-laid fill. The **ring
  closes at 100 %**; beyond that the colour (red ≥ critical) carries the overload. The
  unfilled gap stays transparent. The **Battery detail page** carries a matching gap-ring
  load display along its Current row while monitoring is on.
- **Governor-mode aware statistics.** UltiDash now reads the FC's governor mode at
  connect (`mspGovernorConfig`, MSP — connect/disarm only). In governor modes
  **OFF / LIMIT** the firmware never updates the `Gov` state sensor, which used to keep
  the headspeed/current min-max tracking from ever engaging; in those modes the tracking
  now falls back to **armed + rotor spinning** (`Hspd > 100 rpm`; armed-only without an
  `Hspd` sensor), the governor slot shows **Gov. Off / Gov. Limit** instead of the
  misleading *Throttle off*, and the sensor-check hint for `Gov` explains the fallback.
  Setups with a running governor (DIRECT / ELECTRIC / NITRO) are unchanged; without a
  readable governor config (old RFTool) the previous strict gating remains.
- **Flight log & battery management** (opt-in, *General* settings group). *Log flights to
  SD card* appends one line per flight to `WIDGETS/UltiDash/fltlog/flights.csv`
  (`date,time,model,battery_id,flight_s` — start time, the FC-set model name and the
  tracked flight time; arm cycles under the configurable *Min. flight time*, default 30 s,
  are skipped). *Ask battery on connect* opens a
  selection page after each fresh connect when the PC-edited registry
  `fltlog/batteries.cfg` lists packs for the current model — a commented template
  `fltlog/batteries.example.cfg` ships with the widget (last-used pack first and
  `>`-marked; *No battery / skip* always available); the selected pack's id goes into the
  log and its `cycles`/`last` fields are bumped once per battery session, so usage can be
  matched to an external system by id. *Battery sets FC profile* optionally activates the
  matching FC battery profile on selection — matched by the pack's capacity against the
  FC profiles' configured capacities, or via an explicit `profile=` override (MSP,
  disarmed only, same call as the profile picker; skipped when already active). A new
  Toolbox page **Flight Log** (lazy-loaded, disarmed-only) shows
  the recent flights, per-model totals and the battery usage — three tabs, paged, each
  with a proper column-header line (Date / Model / Battery / Time, Model / Flights /
  Total time, Battery / Capacity / Cycles / Flights / Last use) over plain-number cells.
  An opt-in **Log per-flight stats** (default off) appends the dashboard's
  flight-statistics to each logged flight — cell voltage, per-profile headspeed (P1..P3),
  current, ESC temperature and BEC voltage as min/max, plus the voltage-sag count/deepest
  and the mAh used. **Tap a flight row** to open its detail page (a min/max table mirroring
  the stats view). These are the session min/max at disarm, so they are exact per flight
  when you disconnect between flights (several flights on one link accumulate, like the
  stats view). Extra CSV columns, appended after the existing ones — old logs and the
  5-column format keep working.
- **Configurable theme colors.** New *Colors* settings submenu (under *Settings*) with one
  page per color scheme: for *UltiDash* and *UltiDash dark* every color is adjustable —
  the 8 palette slots (text, backgrounds, accents), the traffic-light set (good / warning /
  critical / neutral) and the chrome colors (panel fill, bar track, tick marks, dim text);
  for *EdgeTX theme* the colors the theme itself does not define (the traffic-light set).
  Each row uses the native EdgeTX color picker plus a *Def* button that reverts that color
  to the scheme's built-in; the per-page reset reverts a whole scheme. Overrides are stored
  per model (0xRRGGBB in the cfg file) and only for colors you actually changed.
- **Battery colors are configurable too.** The main battery bar's five fill colors
  (OK / not-full warn / low / critical / cell-check) and the top-bar TX battery icon
  (OK / low) — historically fixed — now have their own *Battery* section on each Colors
  page. Defaults are unchanged.
- **PC-side instruction-budget check** (a development tool, not part of the release): loads the real
  widget sources with EdgeTX API stubs and counts Lua VM instructions per lifecycle call
  with the same hook mechanism as EdgeTX's ~20k "CPU limit" — so a budget overrun is
  visible before deploying, not as a crash on the radio.
- **Governor-state voice callouts.** New *Gov voice* settings group announces the governor
  state (the `Gov` sensor) on every change **in flight (armed only)** — "spooling up",
  "governor active", "throttle hold", "autorotation", "bailing out", "governor fallback",
  "governor bypass", etc. A master *Announce gov state* toggle (default off) plus a per-state
  enable for each of the ten states, so you pick what gets called out. Debounced (~0.3 s) so
  the spool-up sequence doesn't chatter; the state at arming is the silent baseline. English
  and German voice files included; read-only, issues no MSP.
- **Voltage callouts can announce per-cell voltage.** New *Battery ▸ Announce voltage as*
  (Battery / Cell): the voltage alert and the startup cell check speak either the total
  pack voltage (default — unchanged) or the per-cell voltage. Independent of the on-screen
  *Voltage shown as* display setting, so you can show cells but hear the pack, or vice
  versa. Uses the latched, collapse-filtered value; falls back to pack voltage if no
  per-cell reading is available.
- **On-screen warning when settings can't be saved.** If writing the per-model config to
  the SD card fails (card full, write-protected or removed), a short warning banner now
  appears on the dashboard/stats view for ~10 s — previously the failure was silent and you
  only noticed after a restart lost your changes.
- **Alerts submenu shows each alert's on/off state.** Every alert button now carries an
  "On" / "Off" status, so you can see which alerts are active without opening each page.
- **Fuller telemetry-sensor catalog for the value slots.** The *Tele Main / Tele Details*
  dropdowns now know the second ESC group (`Es2*`), the rail voltages/currents (`Vesc`/`Iesc`/
  `Ibec`/`Ibus`/`Imcu`), extra ESC values (used mAh, RPM, PWM, load), MCU load, and altitude /
  attitude / GPS sensors — each with a friendly label. (The dropdown still lists only the
  sensors your model actually reports.) Fixed three dead entries that named non-existent
  sensors (`Cbec`/`Cbus`/`Cmcu` → the real `Ibec`/`Ibus`/`Imcu`).
- **New alert: ESC / MCU over-temperature.** A *Temperature* alert (under *Alerts*) calls out
  ESC or MCU over-temperature with the value in °C. Separate warn/critical thresholds per
  sensor live under *Thresholds ▸ Temperature* (defaults ESC 90/110 °C, MCU 75/90 °C; set a
  threshold to 0 to disable that branch). Armed-only, with vibrate and repeat like the other
  alerts; a model without the `Tesc`/`Tmcu` sensors stays silent.
- **Warning when two Dashboard instances are placed.** Two placed Dashboard instances both
  drive callouts and the shared state, which doubles announcements and flickers the passive
  views. A "2 Dashboard instances active!" banner now appears on both so the misconfiguration
  is obvious — place exactly one Dashboard (passive ELRS/Status views are fine).
- **Configurable current source.** New *Battery ▸ Current sensor* (Curr / EscI / Iesc) picks
  which sensor feeds the Current row, the ESC-load monitor and the current min/max — so a
  model that reports current only over ESC telemetry (no FC current sensor) can show current
  and use the ESC-load monitor. Default *Curr* keeps the previous behaviour.
- **Sensor check page.** A new *Sensor check* entry in the menu lists the sensors UltiDash
  relies on and flags what is missing: the required sensors (arming, battery, cells,
  headspeed, governor, link) with a one-line note on what a gap breaks, the sensors
  used by the features you have enabled, and your configured value slots. Each row carries a
  colored status badge — green **OK**, red **MISS** (required), yellow **MISS** (optional),
  gray **--** (present but no data — normal with the FC off) — the friendly sensor name in
  the standard font, the sensor code at the right edge, and a hint to run *Discover new
  sensors* when the custom telemetry hasn't been set up; a legend at the bottom explains the
  three states. **While the FC is connected the right column also shows each sensor's live
  value** (1 Hz), which turns the page into a quick diagnostic view. Read-only; it only
  scans while the page is open.
- **Voltage-sag counter in the flight stats.** A new *V sags* row counts how often the cell
  voltage briefly dipped to/below the critical threshold — including the short load sags the
  voltage alert's debounce ignores — and shows the deepest cell voltage seen. Zero-config,
  display-only; resets with the other session stats.
- **Switch shortcuts — open any page hands-free.** A new *Shortcuts* settings group binds
  switches to pages (no touch needed, so it works in flight or with gloves). Targets are the
  detail pages (ELRS / Status log / Battery / Telemetry) **and** the Toolbox tools (Adjust
  Map / Adjust Edit / Log Viewer / RF2 Config / Flight Log). Two mechanisms: **6 position slots** — a
  switch position *holds* its page open (leave the position, it closes), with a configurable
  *Switch delay* so passing through a middle position on the way to another doesn't fire the
  intermediate one; and **2 toggle slots** — each press steps through up to four options, then
  closes. Replaces (and folds in) the old *Display ▸ Detail page switch* and the *Toolbox ▸
  Activation switch* — those single-purpose switches are gone; re-assign under *Shortcuts*.
  A shortcut only closes the page it opened, and *Close detail pages on arm* still applies to
  detail targets; the disarmed-only tools refuse to open while armed. RTN from a
  shortcut-opened tool returns straight to the dashboard (no menu trail to unwind); each
  slot is its own section on the settings page.
- **ELRS page shows the downlink RSSI/SNR.** A new *TRSS* row (downlink RSSI, measured at the
  TX module) helps separate downlink problems — telemetry dropouts, module antenna, too-low
  telemetry ratio — from uplink/control ones. The SNR row now shows uplink / downlink together
  (e.g. "8 / 5dB").
- **Governor "Bypass" state (Rotorflight 2.3).** The governor-state readout now shows
  *Gov. Bypass* for the new bypass state (GOVBYPASS box active, rotor running on the bypass
  throttle curve) instead of the misleading *Gov. Disabled*.
- **Toolbox: Log Viewer (WIP).** A new *Log Viewer* tool page graphs EdgeTX telemetry logs
  (`/LOGS/*.csv`) directly on the radio: up to 4 min/max envelope curves, zoom / pan /
  draggable time cursor, and automatic recording-session split. A **100 %** button resets
  the zoom to the whole session in one tap, and the template / session selectors are
  bordered header chips so it's clear they open a picker. After opening a log you
  choose what to display on a **two-column card page** — a built-in template (**Power /
  Battery / RF link / Governor**, each showing how many of its sensors the log contains)
  **or** your own set from a sensor picker. The picker groups every column **exactly like
  the Rotorflight Configurator's Telemetry Sensors dialog** (Battery, Voltage, Current,
  Temperature, ESC #1/#2, RPM, Barometer, Gyro, GPS, Status, Profile, Control, System,
  Debug — plus RF-link, stick, switch and channel groups for the radio-side columns);
  groups start **collapsed** with a *selected/available* counter and fold open on tap, each
  sensor carries an **on/off toggle switch**, and a **List / Grid** toggle at the top picks
  the roomy one-per-row layout or the compact multi-column grid (up to 4). Own templates
  via `toolbox/logtemplates.lua`
  (copy the `.example`). The file list shows only real telemetry logs (newest first,
  **all models by default** with the model name per row; a header button opens a
  **Filter by model** page built from the model names found in `/LOGS`, each with its
  log count) and is **swipe-scrolled**
  without page rebuilds, so scrolling stays fluid even with hundreds of logs. Folders with
  more than ~370 logs are scanned incrementally (the one-shot scan used to hit the Lua
  instruction budget, silently dropping the **newest** logs and sometimes reporting
  "Cannot read /LOGS folder"); the list cap keeps the newest 600 logs. Log parsing
  extracts all curve columns with a single precompiled pattern match per line, making
  first load and every zoom/pan re-load several times faster. A graphical progress bar
  covers both. English UI throughout. Disarmed-only; still under hardware testing.
  *(Known limitation: the hardware wheel does not scroll the file list yet — EdgeTX
  routes wheel events only to a focused LVGL object.)*
- **Toolbox: RF2 Config — the original Rotorflight configuration tool inside UltiDash.**
  A new *RF2 Config* tool page runs the stock **rotorflight-lua-scripts** configuration
  tool (main menu, all config pages, save, reload/reboot popup) with its original look,
  navigation and key handling, opened straight from the dashboard's Toolbox. Zero-copy:
  nothing is duplicated — the original scripts load from `/SCRIPTS/RF2/` on the SD card,
  so updating the Rotorflight Lua suite updates this page automatically. Requires the RF Tool
  widget (as UltiDash already does). Disarmed-only — it refuses to open and force-closes
  on arming (UltiDash's no-MSP-while-armed rule; the standalone tool has no such guard).

- **Fullscreen overlay for critical alerts** (opt-in, per alert). *Main power lost*,
  *Voltage* (critical level) and *Telemetry* each gained a *Fullscreen overlay* toggle
  (default off): while the alert is active, an unmissable red inset box covers the
  flight/stats view with the alert name in the biggest fitting font plus the live value
  (buffer/BEC voltage, cell voltage). A tap dismisses it for the current episode, and a
  shared *Overlay auto-close (s)* setting (Voice / mute page, default "until tapped")
  can close it hands-free; it comes back only when the condition clears and fires again.
  Drawn as plain build-table primitives toggled by reactive visibility — showing or
  hiding it never rebuilds the view and never blocks the telemetry/callout pass.
- **Explicit "Buffer" readout while main power is lost.** During a main-power loss the
  voltage slot no longer shows a bare "--": it flips to a red **Buffer** readout of the
  live BEC/buffer voltage — mirroring what the repeated callout speaks, so the buffer
  can be watched, not just heard. (The fuel-gauge % still reads "--"; a pack % is
  meaningless on the buffer.)
- **Cell-count-relative main-power-loss threshold.** *Thresholds ▸ Power warn from*
  (new, default **Cell count (auto)**) derives the threshold as cell count × *Power warn
  (V/cell)* (new, default 3.0 V) — a 2S warns at 6.0 V, a 6S at 18.0 V, with 3S exactly
  matching the old fixed 9.0 V default. *Fixed voltage* keeps the manual override (the
  existing *Power warn voltage* value), which is also the fallback until a cell count is
  seen. Replaces the "lower the threshold by hand on a 2S" tip. If you had hand-tuned
  *Power warn voltage*, set *Power warn from* to *Fixed voltage* once.
- **"No FC connected" hint on the flight view.** With no FC link the status bar's center
  text now reads "No FC connected" (dimmed) instead of a stale arming state — previously
  the disconnected state was only recognizable indirectly (empty values, slower updates).
  While disconnected the telemetry pass deliberately idles at 2 Hz.
- **The editor's range hints are overridable.** `toolbox/labels.lua` may now carry a
  `ranges` block (same shape as the label rows) that replaces the built-in
  recommended-value hints (*Adj editor: ranges hint*) per setup — see TOOLBOX.md §6.

- **Test buttons for the voice callouts.** The *Volume* page, the *Alerts ▸ Voice / mute*
  page and every per-alert page now carry a *Test callout ▸ Play* row that previews the
  alert's real announcement — including a sample number where the live callout speaks one
  (Fuel says "70 %", Voltage / Cell check speak a sample voltage in the format your
  *Announce voltage as* selects). The preview uses the page's **current, unsaved** values
  for language, widget volume and master mute, so you hear exactly what you are about to
  save — no flight needed to check loudness or language. (The settings menu closes on
  arming, so a preview can never play in flight.)

### Documentation
- **New [Illustrated Walkthrough](docs/WALKTHROUGH.md)** — a screenshot tour of the flight
  dashboard, the tap-to-open detail pages (Battery / Telemetry / ELRS / Status), the menu,
  Sensor check, and the Toolbox (Log Viewer + Flight Log), in both the light and dark
  colour schemes. Linked from the top of the README.
- **New [Quick Start guide](docs/QUICKSTART.md)** — the shortest path to a working base
  setup (dashboard, views, statistics): copy files, the **one Rotorflight CLI line**
  (`set telemetry_sensors = …`) that enables every FC sensor the built-in features need
  (with an ID→sensor table), install RFTool, discover sensors and place the widget. Notes
  that the ELRS link sensors arrive natively (no FC setup) and that the empty duplicate
  ELRS sensors are best deleted. Linked prominently from the top of the README.
- **New [Optional Features guide](docs/OPTIONAL_FEATURES.md)** — a supplement to the Quick
  Start with the elementary setup steps for the optional features (extra value-slot sensors,
  model image, master-volume GVAR bridge, ESC-load monitor, RF-adjustment tools, Log Viewer,
  flight log & battery management) plus a list of the menu-only features that need no
  external setup. Linked from the README and the Quick Start.
- **Quick Start: placement tip** — put UltiDash in a full-screen zone with the top bar
  hidden, but keep RFTool in a top-bar slot so it stays active without costing screen space.
- **README: a "Key features" summary** near the top for a fast overview, above the
  existing detailed feature list.

### Changed
- **Fuel-callout density defaults relaxed.** *Fuel: dense below* 10 → **15 %** and *Fuel:
  fine step* 1 → **5 %**, so the fine-grained end-of-flight callouts start a touch earlier
  and space out more sensibly by default (the old 1 % spacing was too chatty).
- **Shortcuts pick switch + position in ONE native picker.** The position slots' separate
  *Switch* + *Position (Up/Middle/Down)* rows and the toggle slots' *Switch* row are
  replaced by a single **Switch position** field using EdgeTX's own switch picker
  (`SA↓`-style entries, logical switches included) — the same pattern the radio uses
  everywhere else, and a toggle "press" can now be any position (momentary `SH↓` works
  naturally). *(WIP-only break: shortcut switches picked with an earlier 0.6.0 build use
  new cfg keys — re-pick them once; released versions are unaffected.)*
- **Shortcut targets labelled by kind.** The *Opens* dropdown reads as `Category: Name`
  throughout — `Page: ELRS`, `Page: Battery`, … for detail pages and `Toolbox: Log Viewer`,
  `Toolbox: RF2 Config`, `Toolbox: Flight Log`, … for tools, so it is obvious what kind of
  page a shortcut opens.
- **Alerts overview shows each alert's setup at a glance.** The per-alert buttons in
  *Settings ▸ Alerts* now append compact feature markers to the On/Off state — **+R**
  repeat, **+E** escalation volume, **+V** vibrate, **+O** fullscreen overlay (legend
  under the grid; only effective features appear, e.g. +E needs the volume GVAR).
- **Every alert page explains its trigger.** Each per-alert settings page opens with a
  one-line summary of when the alert fires (armed-only conditions, thresholds, what the
  callout speaks), so the knobs below have context.
- **Settings menu reorganized into a themed grid.** The settings groups now sit in a
  3-column grid under four section headers — *Appearance* (Display / Colors / Telemetry),
  *Battery & limits* (Battery / Thresholds / ESC load), *Sound & callouts* (Volume /
  Alerts / Voice) and *System* (Shortcuts / Toolbox / General). *Tele Main* and *Tele
  Details* moved into a small **Telemetry** submenu, *Switch voice* and *Gov voice* into a
  **Voice** submenu (one extra tap each; all keys and stored settings are unchanged).
- **Settings pages: aligned columns and row separators.** All controls on a page now end
  flush at the same right edge — dropdowns share one width per page (previously each row
  sized its own, so the left edges jittered), the stepper value column is measured from the
  page's actual values instead of a fixed worst case, and toggles line up with the fields
  around them. Thin separator lines between rows and underlined section headers make the
  long pages (Thresholds, Shortcuts) considerably easier to scan.
- **Menus sized for the small radios.** Single-column menu buttons (Menu / Colors /
  Telemetry / Voice / Toolbox) are now capped at ~65 % of the screen width instead of
  running edge-to-edge on a 480 px display, and a menu grid that would overflow the screen
  shrinks its gaps and row heights (still comfortably tappable) before anything scrolls —
  the Toolbox page no longer pushes its "available only while disarmed" hint off-screen,
  and the settings grid keeps its *Reset to defaults* button visible.
- **Toolbox marks the disarmed-only tools while armed.** Log Viewer, RF2 Config and Flight
  Log are drawn dimmed while the craft is armed (the menu redraws on the arm transition);
  tapping one still shows the explanatory hint.
- **Color-scheme list reordered.** *Display ▸ Color scheme* now lists UltiDash /
  **UltiDash dark** / **EdgeTX theme** (dark moved to slot 2, the EdgeTX theme to slot 3).
  Stored settings are remapped automatically by a one-time cfg migration (`ClrSchemeV`
  version stamp), so the scheme you picked stays the scheme you get.
- **Staged widget startup (CPU-limit fix).** EdgeTX gives each widget call ~20k Lua VM
  instructions, and `create()` alone already carries loading all five module chunks
  (~13.5k). The cold per-model cfg read + apply on top tripped "CPU limit" once the cfg
  grew (color overrides). Startup is now staged: create = module load + flag only →
  next cycle = cfg read/apply alone → next cycle = UI build. Costs two invisible frames.
- **Tidier SD layout: per-model configs in `cfg/`, debug logs in `logs/`.** UltiDash no
  longer scatters its data files across the widget root — per-model settings now live in
  `/WIDGETS/UltiDash/cfg/` (`cfg_m_<slot>.cfg`, and the optional per-craft files) and the
  debug logger writes to `/WIDGETS/UltiDash/logs/`. Both folders ship with the widget, so
  nothing is created at runtime; files left in the root by earlier versions are **moved in
  automatically** on start (settings) / on first enable (logs), and settings are also
  adopted per model on load — upgrading loses nothing. If a folder is ever missing UltiDash
  falls back to the old flat root layout, so it can never fail to read your settings.
- **Toolbox Log Viewer and RF2 Config load on demand.** Both modules are now loaded when
  their Toolbox entry is tapped and released again on close, instead of staying resident
  from boot. Keeping the Log Viewer permanently loaded had grown the Lua heap by ~250 KB
  and the extra garbage-collector work measurably slowed the whole UI loop (~19 → ~15
  refreshes/s) — dashboards, menus and detail pages all felt sluggish. Opening a tool now
  has a one-off (imperceptible) load moment; everything else got its speed back.
- **Voltage alert repeats the LOW band too, not just critical** (with *Voltage ▸ Repeat*
  on). A sustained dip below the low threshold — e.g. pulling through a loop — now keeps
  calling out at the repeat interval until it recovers, and switches from "battery
  critical" back to "battery low" if it eases off. Turn *Voltage ▸ Repeat* off for the old
  single-announce-per-level behaviour. (The low band never boosts the escalation volume —
  that stays tied to critical.)
- **Louder defaults for the two safety-critical alerts (fresh configs only).** Main power
  lost now defaults to **Vibrate on** and **Repeat until cleared** (an audible buffer
  countdown); telemetry lost now **repeats** a few times by default. Existing models keep
  their saved settings.
- **RSSI / signal callout now speaks the value** (signal headroom %), like the other
  value-carrying alerts; repeats speak the current value.
- **Settings are only written when you actually change something.** Opening a settings page
  and leaving it without editing no longer rewrites the per-model config file — fewer
  needless SD-card writes.
- **Settings that currently have no effect are dimmed.** A row that depends on another
  setting (e.g. the manual cell thresholds when *Cell thresholds from* is *FC config*, the
  ESC-load rows when monitoring is off, a repeat count when *Repeat* is off, escalation
  volume without a master-volume GVAR) now shows its label greyed out — so it is clear what
  is active. Dimmed rows still work; the greying only signals "no effect right now".
- **Alert "Repeat count" reads as a total.** The count now shows e.g. "3 total" (or "until
  cleared" for 0) and includes the first announcement, instead of a bare number that read
  ambiguously.
- **Vibration has its own master switch, separate from Mute.** New *Voice / mute ▸ Vibration
  (master)* controls haptic feedback independently of *Mute*. Previously *Mute: All* silenced
  vibration too; now *Mute* affects sound only, and vibration keeps working unless you turn
  its own master off. Existing models default to vibration on.
- **The model timer is only auto-reset when the widget actually shows it.** On a fresh
  telemetry connect UltiDash used to zero the configured model timer even when the top-left
  area showed the model image; it now resets that timer only when *Display ▸ Top-left shows*
  is set to *Timer*. If you use the model timer for something else, it is no longer touched.
- **Removed the non-functional "Overlay (prep)" toggle** from the alert pages until the
  full-screen overlay feature actually ships (it never did anything yet).
- **Settings pages are easier to scan.** Long pages now carry **section headers** (Display:
  *Layout & theme* / *Top & bottom bar* / *Behaviour*; Battery: *Fuel callouts* / *Cell
  thresholds* / *Cell check & voice*; Thresholds: *Link & signal* / *Power & BEC*), the two
  telemetry-slot pages explain the **dropdown + raw-source** two-field concept, and pages with
  steppers show a **"long press − / + for big steps"** tip. Row heights, the value column and
  hint wrapping are now measured (no clipped descenders or "until cleared" text on the TX16S,
  no clipped ESC hint on the TX15). The **[−]/[+] touch targets scale up** on the big TX16S.
- **Destructive resets are set apart.** The per-page *Reset … to defaults* now sits below a
  divider in a warning colour, and *Reset to defaults* (whole model) is a separate,
  warning-coloured button under the settings grid instead of one more grid tile — so neither
  reads like an ordinary navigation button. Confirmation dialogs are unchanged.
- **BEC alarm reference is frozen at arming.** The relative BEC warn/critical thresholds
  now measure against the BEC voltage captured **at the moment of arming**, instead of
  the highest value seen since arming — the running maximum could ratchet upward on noise
  spikes and silently tighten the alarm mid-flight. Reset on disarm/disconnect as before.
- **Unknown config keys are dropped on save.** The per-model cfg no longer accumulates
  keys forever: anything the current version doesn't know (typos, keys from another
  version) is removed on the next save. Note this is downgrade-unfriendly — an older
  UltiDash will find the newer version's keys gone; re-check settings after a downgrade.
- **Battery registry updates are atomic.** `fltlog/batteries.cfg` (the PC-maintained pack
  list) is no longer rewritten in place for a cycle-count bump: the new content is
  written to a temp file, size-verified and swapped in, keeping the previous version as
  `batteries.cfg.bak`. A full/failing SD card now leaves the original untouched (and
  skips that cycle count) instead of truncating the file. Duplicate `id`s are ignored
  (first entry wins), and an oversized registry is never written back truncated.
- **Volume-GVAR override keeps working off-screen.** The master-volume bridge (normal /
  escalation volume, the −1024 release on disconnect) is now also maintained while
  another main screen is active — an escalation boost no longer stays latched until the
  Dashboard is brought back up.
- **Dark scheme: the battery identity is readable.** The fuel gauge's empty segments use
  a muted mid-gray on the dark scheme (instead of glaring light gray), the %-and-mAh
  overlays pick black/white ink from the underlying fill's luminance (also with dark
  user color overrides), and the top-bar TX battery icon gets a light track behind its
  fill so the % text stays legible.
- **Status colours adapt to dark radio themes and read better everywhere.** The green /
  yellow / red status colours (battery, link, ESC load, arming) now follow whether the
  surface under the text is dark, so the *EdgeTX theme* colour scheme on a dark radio theme
  gets the bright variant instead of a muted one that sank into the background. Alongside
  this, the voltage-warning yellow, the armed / connected green, and the ESC-status
  warning/error text now use these theme-aware colours instead of raw built-in colours that
  were hard to read on some backgrounds (notably the armed green on the dark scheme). The
  *UltiDash* (light) and *dark* schemes are otherwise unchanged, and all bar/gauge fills are
  unchanged. Note: after switching the radio theme, reload the model (or restart the radio)
  so UltiDash picks up the new theme colours.

### Fixed
- **Flight values panel: wide numbers no longer collide with their unit.** A number is drawn
  in the column width left of its unit suffix, so a wide value plus a wide unit overran on the
  narrow TX15 (a 4-digit *Headspeed* pushed into/under the "rpm" label). Each row now sizes its
  own value font to the biggest that fits its widest value *beside* its unit, so every row keeps
  its unit and stays as large as it can — only a genuinely wide row (4-digit Headspeed + "rpm")
  ends up a touch smaller, instead of one shared font shrinking the whole panel or units being
  dropped.
- **Settings hub: the "General" group (Debug log, Config-per-craft, Flight log) is
  reachable again.** The menu grid lays out group tiles section by section, and the
  section run-lengths still summed to 12 after the *Skin* group was added as a 13th group,
  so the last group ("General") fell off the grid entirely — its settings still worked with
  their saved values but couldn't be opened. The section runs now sum to 13 (Battery &
  limits holds ESC load again), which also re-aligns the shifted section headers.
- **Colour picker: theme/fixed swatch picks no longer come back as dark blue.** The
  native EdgeTX colour popup returns two encodings: RGB/HSV pad picks arrive as an
  RGB565 value, but the *Theme* tab and the fixed swatch buttons return a raw colour
  **index** — which UltiDash decoded as if it were RGB565, turning e.g. the light-brown
  swatch into pure dark blue on the next visit to the Colors page (and on the dashboard).
  Indexed picks are now resolved first (theme colours via `lcd.getColor`, fixed swatches
  via a copy of the firmware's fixed colour table). Colours already saved through the
  broken path keep their wrong value — re-pick them once.
- **Switch voice announcements no longer pile up when flipping quickly.** EdgeTX offers
  no way to flush queued audio, so rapid flipping used to queue one announcement per
  stable position and play them all back to back. Announcements of the same switch are
  now rate-limited (1.5 s): changes inside the window are held and only the *current*
  position speaks when it expires — flipped back to the already-announced position,
  nothing plays. A single ordinary flip is announced with no added delay.
- **Alerts and latches now work while the link is down on the visible dashboard.** With
  the FC link lost, the *visible* dashboard skipped the whole alert machinery (the
  background pass did not) — so the telemetry-lost **repeat** nagged only when another
  screen happened to be active, and the power-lost / fuel / voltage latches and the
  overlay state froze through the outage instead of resetting. The disconnected
  foreground pass now runs the same machinery as the background pass. Also cleaned up:
  after a link loss + reconnect in the disarmed state, a no-longer-observable "armed"
  reminder no longer keeps nagging — it is cleared on the connection reset.
- **FC-read values survive a mid-flight telemetry blip.** A short link loss while armed
  used to throw away everything read from the FC at connect — battery capacity / cell
  count, the FC-config cell thresholds and the governor mode — and the re-read had to
  wait until the disarm: thresholds fell back to defaults, the fuel % lost its basis and
  the *Gov. Off / Limit* stats gate degraded, mid-flight. These caches are now cleared
  only on a **disarmed** disconnect. On top, the connect-time MSP reads are gated by the
  ARM sensor: a blip that reconnects while the model is still flying never fires MSP —
  the read is parked and runs after landing (no-MSP-while-armed, defense in depth).
- **Escalation volume now works for the Telemetry alert.** The volume-override used to
  release the master-volume GVAR on *any* disconnect, so the Telemetry alert's
  *Escalation volume* could never apply — the one alert whose active state IS a
  disconnect. On a link loss **in flight** the boost now holds and the repeats come in
  loud; it ends with the last repeat (*Repeat count*; 0 = until reconnect), handing the
  volume back to the pot / *Normal volume (%)* by itself — also after a crash. Needs
  *Telemetry ▸ Repeat* on (the escalation acts on the repeats — the first announcement
  is already out before the boost can land; that is true for every alert, see
  REFERENCE §5.1). A disarmed disconnect (landing, heli off) still never escalates.
- **Skipped-packets alert: *Vibrate* now fires.** It was the only alert whose
  announcement skipped the haptic pulse — the setting existed but did nothing.
- **Dismissing one alert's fullscreen overlay no longer swallows another alert's
  overlay.** The tap-dismiss is tracked per alert now — e.g. after tapping away a
  Voltage overlay, a Main-power-lost overlay in the same flight still appears.
- **Per-craft configs: a craft change under an open settings page can no longer write
  the old craft's edits into the new craft's file.** The save now re-checks the target
  config before writing.
- **The "settings could not be saved" banner now covers every config write** — including
  the internal snapshot / first-run markers, which used to fail silently — and a failing
  write stops being retried on every pass.
- **Adjustment Editor: the tap lockout follows the configured pulse length.** With a
  long *Adj editor: pulse* a fast second tap could land inside the still-running pulse;
  a new tap is now accepted ~0.1 s after the pulse ends (the fixed 250 ms lockout is
  gone).
- **A Toolbox tool that fails to initialize shows its error on the tool page** instead
  of taking the widget down (the tool init is now error-guarded on every open path —
  menu, shortcut and re-open behave identically).
- **Flight statistics and the flight log now track fully off-screen.** With another main
  screen active, profile changes, the ESC-temperature min/max and the TX-power tracking
  paused, and flight-log arm edges could be missed — off-screen flights were missing or
  shortened in `flights.csv`. The background pass now feeds the same edges and stats as
  the on-screen one.
- **TX battery icon: the percent label stays readable on a dark color override.** The
  label ink now follows the fill's luminance (black on light, white on dark), like the
  fuel gauge's overlay text; the default look is pixel-identical.
- **RF2 Config with no FC connected could trap you.** Opening *Toolbox ▸ RF2 Config* while
  the flight controller was disconnected dropped straight into the stock RF2 runner's
  "connecting" wait screen, which never processes RTN — so you couldn't get back until
  something connected. RF2 Config now checks the link first: with no FC it shows a
  **"No FC connected"** notice (RTN returns to the Toolbox) and opens by itself once the FC
  connects.
- **Menu glyph tap could be dead right after entering full-screen.** The ☰ tap was
  hit-tested only against the built glyph rect, which is `nil` during the staggered
  full-screen-enter build (and the window stretches when a heavy frame — e.g. debug log on —
  starves the rebuild), so the menu wouldn't open until a detail-view visit forced a
  rebuild. Now falls back to a fixed top-left region so the menu opens regardless of build
  timing. *(The underlying debug-log-induced sluggishness is tracked separately.)*
- **Menu glyph stretched on the TX16S MK3.** The fullscreen ☰ settings glyph used a fixed
  20-px width but filled the top bar's height, so on the 800×480 MK3 (tall bar) it drew as
  a stretched vertical rectangle. The box is now **square** and the three bars scale from
  the box height — a clean aspect ratio on both the MK3 and the short 480×320 TX15 bar.
- **Headspeed / current minimum polluted by spool-up ramps** (field report: "always
  starts in P2 — P2 min 500 rpm"). A re-spool after a throttle hold runs in the
  governor's *Recovery* state, which the min/max gate tracked from its first low-rpm
  sample (and the `Hspd` telemetry lags the spool-up→active transition by a couple of
  seconds on top). The **minimum** now only tracks in the steady states (Active /
  Fallback / Bypass) and only after ~2 s of continuous run — ramps and the telemetry
  lag can no longer leave a misleading low min. The **maximum** deliberately keeps the
  broad gate (autorotation / bailout overspeeds stay visible).
- **Leaving fullscreen with the Log Viewer open no longer leaks.** The exit path skipped
  the viewer's cleanup: an open `/LOGS` file handle stayed behind and the ~2000-line
  module stayed resident, whose garbage-collection load measurably slowed the whole UI
  (the ~19 → ~15 Hz class of slowdown). All four tool pages now run one shared close
  path (cleanup + module release) on every way out — RTN, arming, fullscreen exit,
  shortcut close. A bound shortcut switch held in position also no longer loads a tool
  module that its open would then be refused.
- **A shortcut no longer opens a Toolbox tool while not fullscreen.** Tool pages are
  fullscreen UIs; a switch that opened one in normal widget mode built a fullscreen page
  into the small widget zone — the Log Viewer flashed open and shut, the Flight Log threw
  "attempt to index a nil value" (the effect showed up after a reboot, before the tool had
  ever been opened from the menu). Shortcut tool-opens are now gated to fullscreen, exactly
  like the menu path (the menu glyph is fullscreen-only); a held switch opens the tool as
  soon as you are fullscreen.
- **Armed/disarm callout and ESC fault log now run off-screen.** Arming while another
  main screen was active announced "armed" only on the next screen switch, and ESC
  faults that occurred off-screen were missing from the worst-fault latch and event log.
- **A passive view now follows a full scheme change too.** Switching *Color scheme*
  3 → 1 plus save left a passive second-screen instance on the old palette (a style
  signature collision); any scheme/color change now rebuilds passive views.
- **The flight clock stops promptly on a total link loss.** With the RC link positively
  down (RQly 0) EdgeTX serves the last ARM/headspeed values for up to ~30 s until the
  sensors expire — the flight timer (and the flight-log duration) kept counting through
  that window after an in-flight RX/telemetry loss.
- **The skipped-packet sensor follows a model change.** The `*Skp`-vs-`Skp` name choice
  is re-probed on every fresh connect — switching between models with different
  telemetry generations used to silently disable the Skip alert until a Lua reload.
- **Sensor check: no stale green with the FC off, raw slots verified correctly.** With
  the FC disconnected the page now shows "--" chips instead of a stale "OK"; value slots
  picked via the raw source picker are verified by their stored source index (they
  showed a false MISS despite working); a model with old-generation telemetry (`Skp`
  instead of `*Skp`) is recognized; and a mid-view row-set change no longer shifts the
  status badges onto the wrong rows.
- **RTN on a settings submenu page returns to the Settings menu.** On the Telemetry /
  Voice / Shortcuts submenus RTN used to fall through to the dashboard while the back
  arrow correctly returned to the menu — both go to the menu now.
- **A toggle-shortcut switch already "on" at boot no longer auto-opens its page.** The
  first evaluation now seeds the edge detector instead of treating the standing "on" as
  a press (maintained switches).
- **Battery picker: every pack is reachable on the TX15.** The pick list scrolls; packs
  beyond the first ~3 visible rows used to be unselectable on the small screen.
- **ESC-load bar follows the configured current source.** The bar under the Current row
  was tied to the literal `Curr` slot and vanished when *Battery ▸ Current sensor* was
  set to EscI / Iesc.
- **Stats header no longer clips a long FC model name that arrives off-screen.** The
  header font is re-measured when the craft name changes, not just at build time; long
  raw-slot labels in the flight view are also truncated with ".." instead of overflowing.
- **RF2 Config: UltiDash's own connect reads no longer queue into an open tool page**
  (they are parked while the tool owns the MSP queue and run after it closes), and
  framework errors from the embedded tool (restart/registration) are caught into the
  tool's error page instead of taking down the widget state.
- **Sensor reads follow the Rotorflight sensor, not a same-named duplicate or a rename.**
  When you switch a model to custom telemetry but leave the old native CRSF sensors in place,
  EdgeTX ends up with two `Curr` / `Capa` / `Bat%` … sensors, and a name lookup could hit the
  wrong (stale) one — throwing off the fuel callouts, ESC-load and stats. UltiDash now resolves
  its known sensors by their Rotorflight **sensor ID**, so it always reads the right one — and
  a renamed known sensor keeps working and still shows with its friendly label. (Falls back to
  the plain name read on models without custom telemetry — no change there.)
- **Alerts kept working with stale values while another screen was active.** When the
  Dashboard ran in the background (a second screen showing the passive ELRS/Status view),
  the ESC-load, BEC-voltage and link/RSSI warnings evaluated the last on-screen sensor
  readings instead of live ones — so an off-screen ESC-load or BEC drop could go
  unannounced. The background pass now refreshes the same telemetry the on-screen pass
  does before running the alert checks.
- **Toolbox / Adjustment Editor: a pulse could stick when the page was closed mid-pulse.**
  A tap pulses the adjustment GVAR for ~150 ms and then releases it. Leaving the editor
  page (back/RTN, the activation switch, or exiting full-screen) inside that window left
  the GVAR at the trim code — a permanent adjustment command to the flight controller. The
  value channel is now released whenever the editor page closes.
- **Toolbox / Adjustment Editor: a single tap could apply two adjustment steps.** The
  `-`/`+` tap targets now use the same time-based debounce as the rest of the widget, so
  one physical tap = exactly one step (a single tap bounces into several touch events,
  more so on the TX16S). Deliberate fast tapping still works.
- **Wrong arming-disable reason names in the compact status line.** The compact
  `* REASON` arming-disable summary inherited Betaflight legacy names: it showed
  **RUNAWAY** / **CRASH** where Rotorflight means **Governor** / **RPM Signal**, and on
  current firmware a held override read **ARMSWITCH** instead of **Override** (with the
  arm-switch reason missing entirely). The compact line now matches the firmware enum and
  the full reason list on the Status page — both name every reason identically.
- **Cell-check alert: Repeat / Repeat count / Repeat interval / Vibrate now work.** These
  per-alert settings were listed for the startup cell check but had no effect. With Repeat
  on, a not-full pack now re-announces up to the configured count; Vibrate fires if
  enabled. The check clears the repeat when the pack reads full, when a new check starts,
  and on disconnect. The Cell check and Armed/disarm pages no longer show the *Escalation
  volume* toggle — it never did anything for those two one-shot alerts.
- **ESC-load alert is shown in the Status page's repeat summary** (and in "Sounds off"
  while ESC-load monitoring is on) — its repeat was running but wasn't reflected there.
- **Startup cell check now also runs off-screen.** Plugging a battery in while another main
  screen was showing skipped the cell check until the Dashboard was brought back up; it now
  runs in the background pass like the other callouts. It is also no longer silenced by a
  momentary voltage glitch at the moment the check finishes (a transient "main power lost"
  no longer suppresses the low-cell callout, which the off-screen timing made more likely).
- **Config files no longer truncate past ~8 KB.** A config that grew beyond 8 KB (many
  per-alert settings) was read only up to the first 8 KB and the rest was silently dropped,
  losing settings without any error. The whole file is now read.
- **A corrupt config value can no longer crash the widget.** A hand-edited or damaged config
  line that put text where a number was expected could later crash a formatter or a +/-
  stepper; such values now fall back to the default.
- **"CPU limit" errors on busy update cycles / cold boot.** EdgeTX gives a widget a fixed
  CPU budget per call; several things could pile into one call and overrun it, killing the
  widget with a "CPU limit" error: a screen rebuild (view switch, page open/close) landing in
  the same cycle as the telemetry/alert pass; on a cold boot, the first settings-file read
  sharing its cycle with the full UI build (worse with a large config, or with the debug log
  on, which also starts a log session). These one-time / heavy steps now each run in their own
  cycle — in particular the initial UI build is deferred one frame past widget creation, so it
  never shares a cycle with the cold settings read. The first-placement hint is also no longer
  rebuilt once acknowledged. Net effect: a blank frame or two at startup instead of a crash.
- **ELRS "Diversity" no longer reads "yes" on a single-antenna receiver.** The antenna field
  is always present in the link frame (constant 0 without diversity), which made the page
  report "Diversity: yes" for every receiver. It is now reported only once the data proves a
  second antenna and latched for the session.
- **ELRS SNR row is blank in FLRC — and now also FSK/Kernel — modes.** These modulations
  report SNR as a constant 0 (verified against the ELRS signal-health doc and the LR1121
  radio driver), which showed a permanent "0dB" with a yellow bar; the SNR value and bar
  now read "-" in all of them. The FSK mode entries (DK250 / DK500 / K1000) also got their
  official sensitivity floors.
- **A transient connection-handshake state no longer shows an inconsistent state.** During the
  RFTool connect handshake a brief intermediate state could flicker the connection readout and
  skip the one-time battery-profile reset; the connection state is now normalised to the four
  known states, and the profile reset fires on any first connect (including one that settles
  straight into "disarmed").
- **A few rare ELRS 3.x rates show their label instead of "no link".** D50 / DK500 / K1000Full
  now display their rate name (checked against the current ELRS signal-health docs).
- **A passive second-screen view now follows a color override change live.** When the
  Dashboard changed an individual color (not the whole scheme), a passive ELRS/Status
  instance on another screen kept the old color until the scheme was toggled or the radio
  rebooted. Passive views now rebuild on any color change too.
- **Unset colors are no longer written into the model config.** Saving color settings used
  to store all ~57 color slots (as "unset") in every model's cfg file, needlessly bloating
  it; only colors you actually changed are stored now. Tapping *Def* removes a color's
  override from the file again.
- **Dark scheme: the menu/settings pages ignore EdgeTX-theme color overrides.** Because the
  native menu pages can't be repainted dark, they are rendered with the EdgeTX-theme palette
  for readability — but they now use the neutral theme built-ins, not your EdgeTX-theme color
  overrides (which are meant for the actual EdgeTX-theme scheme, not the forced menus).

### Performance
- **~107 kB of cold code moved off the resident Lua heap** (less GC drag on the whole
  UI loop — the same effect that lazy-loading the Log Viewer already proved with a
  measured 15 → 19 Hz recovery). Three steps: (1) the **entire menu/settings UI**
  (menu hub, Toolbox/Settings submenus, all settings pages, sensor check, both battery
  pickers — ~84 kB) now lives in its own module `ultidashMenu.lua`, lazy-loaded when a
  menu opens and released when it closes; (2) the **Adjust Map / Adjust Edit** toolbox
  tools are lazy-loaded/released like the other tools instead of boot-resident (their
  shared `toolbox/common.lua` data stays resident, so labels overrides survive);
  (3) the **debug logger** `ultidashDebug.lua` loads only when the *Debug log* option
  is actually turned on instead of always. Behaviour and looks are unchanged; opening
  a menu now includes a one-time module compile (imperceptible next to the page build).
  Follow-up: the **12 alert settings pages** now build their row tables lazily on
  first open (like the Shortcuts and Colors pages) instead of eagerly at module load —
  together these steps cut the measured `create()` instruction cost from ~15.1k to
  ~13.9k of the 20k budget.
- **The permanently visible views stopped allocating per frame.** The passive Status
  view (the heaviest: ~15 value closures plus a rebuilt "sounds off" list on every LVGL
  frame at ~20 Hz), the Telemetry-detail min/max texts, the eStatus Gov/Throttle lines
  and the Log Viewer's footer/filter rows are all memoized now — text is rebuilt only
  when a value actually changes. Pixel-identical, steady GC pressure gone. The radio's
  general settings (TX battery limits) are also read once per 10 s instead of per pass.
- **The budget check now measures the historically risky paths.** The development-only check
  runs every settings group, the submenus, the detail pages, sensor check and toolbox
  menu, plus a connected-FC pass with a legacy-cfg migration fixture, and reports
  per-chunk module-load costs — the class of overrun that used to surface as a "CPU
  limit" crash on the radio now shows up on the PC first.
- **Settings pages open comfortably within the instruction budget again.** Copying the
  saved settings into a page's edit buffer used to run in the same call as the page
  build — the heaviest first-opens (Colors) measured ~16.5k of the ~20k budget. That
  seeding now runs in its own invisible frame, and the sensor-check page builds its rows
  in a separate cycle from its first scan (a brief "Scanning…" shows instead); the
  periodic sensor re-scan got its own exclusive cycle too. The budget harness now also
  charges the seeding to **every** page's first open (it used to hit only the first page
  measured, hiding ~7k on the rest).
- **Fewer sensor lookups per update pass.** Each telemetry sensor is now resolved at most
  once per 5 Hz pass (a shared per-pass cache), instead of several callers each doing their
  own name lookup — the name lookup is the expensive part, and piling them up used to
  starve the Lua scheduler enough to make full-screen taps laggy. The battery latch/fuel
  bookkeeping also runs exactly once per pass now. The background (off-screen) pass is
  throttled to the same cadence as the on-screen one. No behaviour change.
- **Less per-frame text churn.** The bottom status bar, the stats headspeed rows, the
  detail-page footers/legends and the ESC-status / arming-reason strings now re-format only
  when their value actually changes, instead of rebuilding the text on every display frame.
  The activation-switch poll moved into the throttled pass. Smoother frame timing,
  especially on the TX15; nothing shown changes. No behaviour change.
- **Toolbox tool pages: fewer per-frame reads.** The Adjustment Map/Editor now resolve the
  active 6-position bank once per cycle instead of on every reactive label each frame, and
  the two tools share one code module (single source for the trim mapping / `labels.lua`
  overrides). No behaviour change.
- **Color palette resolved less often.** The per-scheme built-in colors and the config-key
  strings are now computed once and reused instead of being rebuilt on every UI redraw, and
  the effective palette is memoised until the scheme changes or you save a setting. The
  Colors settings pages are also built only when first opened, keeping them off the startup
  instruction budget. No behaviour change.

## v0.5.2 — 2026-07-12

Maintenance release on top of v0.5.1 (backport from the 0.6.0 line).

### Added
- **Governor-mode aware statistics.** UltiDash now reads the FC's governor mode at
  connect (`mspGovernorConfig`, MSP — connect/disarm only). In governor modes
  **OFF / LIMIT** the firmware never updates the `Gov` state sensor, which used to keep
  the headspeed/current min-max tracking from ever engaging; in those modes the tracking
  now falls back to **armed + rotor spinning** (`Hspd > 100 rpm`; armed-only without an
  `Hspd` sensor) and the governor slot shows **Gov. Off / Gov. Limit** instead of the
  misleading *Throttle off*. Setups with a running governor (DIRECT / ELECTRIC / NITRO)
  are unchanged; without a readable governor config (old RFTool) the previous strict
  gating remains.

## v0.5.1 — 2026-07-03

Bugfix release.

### Fixed
- **Crash on first placement without a config file** (`ERROR create(): attempt to get
  length of a nil value (local 'items')`): the one-time migration snapshot that seeds
  `cfg_m_<slot>.cfg` still iterated the settings groups directly and tripped over the
  new *Alerts* submenu (which has sub-pages instead of a flat item list). It now uses
  the submenu-aware iterator, so the per-alert settings are included in the snapshot
  too.
- **Hardening against EdgeTX's 20 000-instruction "CPU limit"**: the migration
  snapshot + cfg file write no longer run inside the same `create()`/`update()` call
  as the full UI build — they are deferred to a `refresh()` cycle of their own (one
  skipped 20 Hz frame, invisible).

## v0.5 — 2026-07-03

Major feature release on top of v0.4: per-alert configuration, master-volume control,
the ESC-load monitor, the Toolbox (RF adjustment map/editor), a main-power-lost flight
mode and a native-picker settings overhaul. **Experimental — still under testing in the
field.**

### ⚠️ Breaking / upgrade notes
- **Switch selections must be re-picked once** (*Settings ▸ Switch voice* and the Toolbox
  activation switch): the rows now use EdgeTX's **native switch picker** and new storage
  keys; old selections are ignored (no auto-migration — an in-widget migration tripped
  the CPU limit on SD remount).
- **Thresholds regrouped:** the ESC-load thresholds moved to the new **ESC load** group
  (with new keys — re-check them if you used the v0.4 ESC-load preview), *TPWR bar max*
  moved to **Display**, and the global *Callout interval* is gone — repeat cadence is now
  **per alert** (Fuel/Voltage default to the historical 6 s continuous cadence).
- The global *Vibrate on critical* switch was replaced by a **per-alert Vibrate** switch
  (defaults reproduce the old behaviour).

### Added
- **Per-alert configuration** (*Settings ▸ Alerts* is now a submenu with one page per
  alert): **Active / Repeat / Repeat count (0 = until cleared) / Repeat interval /
  Escalation volume / Vibrate / Overlay (prep)** for each of the 11 alerts.
- **Volume group** with two loudness worlds: the per-WAV **Callout volume** (moved from
  Alerts) and an optional **master-volume bridge via GVAR** — UltiDash drives the radio's
  master volume to **Normal volume (%)** while connected and boosts it to **Escalation
  volume (%)** while an alert with *Escalation volume* is active (sentinel −1024 releases
  the volume back to the pot). Real LVGL sliders for the two percentages.
- **BEC voltage alert** (relative, self-calibrating): warns when the live BEC drops a
  configurable % below the flight's own reference voltage — works for any 5/6/8.4 V BEC
  without configuration. New sounds `bec_low` / `bec_crit` (en + de).
- **ESC load monitor** (new *ESC load* settings group): a model GVAR holds the ESC's
  continuous-current limit (A); UltiDash computes load % = current/limit, shows a
  green/yellow/red **utilization bar** under the dashboard's Current row plus a new
  **ESC Load (calc)** telemetry slot, and (separate opt-in alert, sustained-load gated
  with a hold time) warns at configurable warn/critical %. One clear **ESC load
  monitoring** master switch; off = feature fully off. New sounds `escl_warn` /
  `escl_crit` (en + de).
- **Main-power-lost mode** (buffer takeover): a collapsed main pack with live telemetry
  flips the dashboard into a dedicated state — status line **MAIN POWER LOST**, main
  voltage `--`, fuel/voltage callouts suppressed; the power callout speaks the **live BEC
  voltage** with every repeat (an audible buffer countdown) and **`pwr_ok`** (new sound,
  en + de) announces recovery if the pack comes back mid-flight.
- **Toolbox** (main-menu entry + activation switch): the **RF Adjustment Map** and
  **RF Adjustment Editor** tool pages integrated as UltiDash tool pages (matching
  palette, sunlight mode, voice bank announce (`bank` sound), configurable
  config/value channels, GVAR pulse editor). Setup guide in `docs/TOOLBOX.md`.
- **Fuel-callout density settings** (*Battery*): announce-below level, coarse step,
  dense-below level and fine step (defaults = the historical cadence).
- **Raw telemetry sensors** in the value slots: each Tele Main / Tele Details row is now
  a **two-field hybrid** — the curated dropdown plus EdgeTX's **native telemetry source
  picker**, so *any* sensor on the radio can be shown (persisted with its source index so
  it survives restarts).
- **Status detail page redesign:** bordered status card (arm/gov/throttle, ESC status,
  arming status with the **full arming-disable reason list**), **scrollable** timestamped
  ESC event log (▲/▼ paging, position readout), footer with free-heap readout.
- **Status/config overview** (menu ▸ Status and the passive *Status info* view): grouped
  sections covering thresholds & their source, per-alert switches with a repeat summary,
  ESC-load state and the volume setup.

### Changed
- **Settings menu:** groups reorganized (Display / Tele Main / Tele Details / Battery /
  Thresholds / **ESC load** / **Volume** / **Alerts** / Switch voice / General /
  **Toolbox**); Thresholds page now has section headers (*Link & signal*, *Power & BEC*).
- **Telemetry detail page shows raw sensor data** (live EdgeTX readings, not the
  dashboard's latched values).
- **BEC value is live** (the latch is gone); it is held through a supply collapse so the
  buffer rail stays readable.
- **Performance:** disconnected idle throttle (2 Hz instead of 5), memoized per-frame
  allocators, deduplicated 5 Hz reads (ARM/settings/model info cached), repeat summary
  rebuilt only when settings change.
- **Debug log:** flushes **in flight** now — incremental appends (only new lines) at a
  conservative 10 s cadence while armed (3 s disarmed), so a crash loses at most the last
  few seconds; per-session file cap (~5000 lines) with a marker line.

### Fixed
- **Raw-sensor slots showed `-`**: raw picks are now read via their verified source
  index (the stored display name doesn't round-trip through EdgeTX's name lookup),
  including the detail page's min/max.
- **Stats page reappearing after dismiss** in the main-power-lost aftermath (an armed
  flicker reset the dismiss flag): arm-clear is debounced and reconnects no longer reset
  the dismissal.
- **ESC-load GVAR hygiene:** the limit GVAR is only probed/zeroed while the feature is
  actually enabled — a stale config value can no longer touch an unrelated GVAR.

## v0.4 — 2026-06-29

Feature + polish + performance release on top of v0.3. **Experimental — still under
testing in the field.**

### Added
- **Voice language option** (*Alerts ▸ Voice language*: English / Deutsch) with a full
  **German voice pack** in `/SOUNDS/de/ultidash/`. Spoken numbers/units still come from the
  EdgeTX voice pack (the radio's system language).
- **"UltiDash dark" color scheme** — a third *Display ▸ Color scheme* option: high-contrast
  **white text on black** with **vivid neon accents** (focus, warning, "tap to close") and
  neon green/yellow/red bars (link bars, ELRS detail, battery gauge) for strong contrast on
  the dark panel.
- **Readable battery-gauge values:** the cell-count and used-mAh now sit on **translucent
  rounded "pills"** so they stay legible over any segment color.
- **Per-page settings reset:** every settings group page has a **Reset <page> to defaults**
  button (with confirmation) that resets only that page — alongside the existing menu-level
  *Reset to defaults* (whole model).
- **New "General" settings group** holding *Config file per craft* (moved from Display) plus
  the new **Debug log** options.
- **Debug log to SD card** (*General ▸ Debug log*, default off): writes rotating session
  files `/WIDGETS/UltiDash/debug_NN.log` for diagnosing runtime issues. **Sessions kept** is
  configurable (1–50). RAM-buffered and throttled (no per-frame IO); not written while armed
  (flushed on disarm/disconnect). ~zero cost when off.

### Changed
- **Connection-state default tuning** (new installs / models without a cfg): clock = *Time
  only*, *Fill background* on, stats page *On disconnected*, *Top bar: TX voltage* off,
  *Link bars: color only on warning* on, *Sound: skipped packets* on, default Telemetry
  detail slots 6–8 now empty.
- **Setting renamed for clarity:** *"Quiet link bars (color only on warn)"* →
  **"Link bars: color only on warning"** (storage key `BarsQuiet` unchanged).

### Fixed
- **Per-model config not reloaded on model switch:** the module-wide settings cache was only
  invalidated in per-craft mode, so switching between two models with UltiDash kept the first
  model's configuration. The cache now also reloads when the model **slot** changes.
- **Performance / GC churn:** the arming-disable-flags status-bar path rebuilt a 27-entry
  name table up to twice per frame; the value formatters re-ran `string.format` every frame;
  the clock re-read `getDateTime()` (a table alloc) every frame. All are now memoized so a
  steady display produces ~zero per-frame garbage.
- **Connect "burst":** the RFTool bounces through several states during the connect
  handshake, which fired the 3-request MSP read **repeatedly**. The read is now **debounced**
  (fired once the state has settled), collapsing the burst into a single read — still
  read-only and only while disarmed/connected.

## v0.3 — 2026-06-26

Feature release on top of v0.2. **Experimental — still under testing in the field.**

### Added
- **Configurable value slots.** The 5 right-hand dashboard values **and** the Telemetry
  detail page are now freely assignable to any model sensor, configured in
  **Settings ▸ Tele Main** (the panel) and **Tele Details** (the detail page). A smart
  **Voltage (auto)** slot keeps the warn-colored cell/battery voltage.
- **Telemetry detail page** (tap the right value panel): a **3-column grid of up to 12**
  freely chosen sensors, each with its **unit** and the EdgeTX session **low/high
  (`min .. max`)** read from the sensor's `-`/`+` variants — uniform for *every* sensor
  (the per-flight/per-profile statistics on the stats page are unchanged). Tap-to-close
  like the other detail pages.
- **Battery-profile picker** (tap the **B-Profile** field, **disarmed only**): pick from
  the 6 Rotorflight battery profiles with their per-profile capacity ("1800 mAh" /
  "undefined") and switch the **active** profile through the RFTool MSP API, persisting
  **without an FC reboot**. This is the **first place the widget writes to the FC** —
  disarmed only (the FC also blocks config writes while armed); everything else stays
  read/announce-only.
- **Per-sensor units** on the Telemetry detail (V, A, °C, mAh, %, rpm, dB, mW).

### Changed
- **Settings menu restructured:** the configuration groups moved one level down under a
  **Settings** submenu; the hub and submenu now use a centered button **grid** (named
  entries instead of ‹ › tab-cycling — and no more stretched full-width buttons on the
  800×480 TX16S).
- The **"Values" group is split** into **Tele Main** (5 panel slots) and **Tele Details**
  (now **12** detail slots).
- **Settings dropdowns flattened** (sized to the font height, not the full row); the
  sensor picker is **wider** on the TX15.
- **Battery-profile field label** `B. Profile` → `B-Profile` (falls back to `B-Prof` when
  the column is too narrow).
- Neutral UI chrome made **theme-aware** for consistent colors across the UltiDash and
  EdgeTX-theme palettes; the menu hub scales to the display size.

### Fixed
- **Battery-profile capacity off by one:** the dashboard B-Profile field showed the
  *previous* profile's mAh for profiles 2–6 (`sync_active_battery_capacity` applied a
  spurious −1 while the picker was already correct). It now indexes the 0-based capacity
  table directly and follows the FC's current profile.
- **Active-profile detection** is re-read fresh when the picker opens (disarmed) instead
  of a value cached at connect — it now tracks external profile switches.
- **Divide-by-zero guard** in the TX-battery percentage when the radio's General-Settings
  battery limits (`battMin`/`battMax`) are equal.

### Notes
- The **EdgeTX-theme color scheme is not the maintainer's personal focus** and relies on
  community feedback — the built-in **UltiDash** palette is the primary, best-tested path.

## v0.2 — 2026-06-11

A large feature release. **Experimental — still under testing in the field.**

### Added
- **In-widget settings menu.** All configuration moved out of the EdgeTX widget-option
  list (which now holds only `ViewMode`) into a full-screen menu: long-press → full
  screen → tap the ☰ menu glyph (top-left, disarmed only). The menu offers **Settings**,
  **Status** and **Reset settings to defaults** (with confirmation). The Settings page has
  five groups (Display / Battery / Thresholds / Alerts / Switch voice) navigated with ‹ ›,
  using real toggle switches, dropdowns and −/+ steppers (long-press = big step). Edits
  **autosave** on exit.
- **Per-model settings storage.** Settings persist on the SD card in
  `/WIDGETS/UltiDash/cfg_m_<slot>.cfg`, keyed by the model **slot** so they survive
  Rotorflight's "set model name on TX" renaming. Optional **per-craft** files
  (*Config file per craft*). Legacy name-keyed files are adopted once.
- **Tap-to-open detail pages** (full-screen):
  - **ELRS link** (tap the top-bar bars): six labelled bars — RQ, TQ, 1RSS, 2RSS, **SNR**
    and **TPWR** — with thresholds and values, rate/mode header, and a footer with SNR /
    active antenna / session RQ-min. New **`TxPwrMax`** sets the TPWR bar's 100 % reference.
  - **Status & events** (tap the ESC/status line): arm/governor/throttle summary, the live
    status line, and a **timestamped ESC event log** (every status change, RESTART,
    arm/disarm). A dev-metrics footer (Lua heap / UI loop Hz / pass ms).
  - **Battery** (tap the gauge): a cell-voltage scale with the active crit/low/full
    thresholds marked, plus the battery in the dashboard look with values inside it.
- **`ViewMode` — second-screen views.** Place UltiDash again on another screen set to
  **ELRS details** or **Status info**; these passive instances mirror the Dashboard
  instance's data (and inherit its palette). They show a notice when no Dashboard runs.
- **Switch voice announcements** (new *Switch voice* settings group): speak motor on/off,
  rescue, governor and profile (1-3) from a configurable TX switch — **physical SA…SH (+
  inverted) or any logical switch** defined in the model. Read-only; independent of the
  model's mixer/arming logic. New voice files `motor_on/off`, `rescue_on/off`, `gov_on/off`,
  `profile`.
- **Callout volume override** (`Volume` 1–5 + *Widget volume applies*): play callouts at a
  fixed level regardless of the radio setting; spoken numbers now honor the master mute.
- **Per-PID-profile headspeed statistics**: min/max tracked per `PID#` profile, shown as
  three fixed rows (P1–P3) so every profile stays visible after disconnect.
- **First-run hint** overlay pointing to the full-screen settings menu (shown until the
  menu is opened once; per model).
- **Detail/stats touch controls**: *Tap zones for detail pages* (on/off), *Close detail
  pages on arm*, manual stats dismiss by tap.
- **Display options** `ClockMode` (date+time / time-only) and `BarsQuiet` (link bars stay
  neutral until warn/crit).
- *(from the prior ELRS round)* ELRS link bars (RQ/TQ/1RSS/2RSS) in the top bar; RSSI/signal
  warning (`rssi_warn`/`rssi_crit`) with `RssWarn`/`RssCrit`/`RssHold`; main-power-loss
  (`pwr_backup`, `PwrWarnV`) and skipped-packet (`skp_high`, `SkpLimit`) warnings; cell
  thresholds from FC or manual.

### Changed
- **Configuration model:** the EdgeTX widget option list is reduced to a single `ViewMode`
  choice; everything else is the in-widget menu (per-event sound switches, `Mute` master,
  `Haptic`, thresholds, etc.).
- **Statistics page restructured:** the three info cards (Flight Time / mAh Used / Batt
  Profile) are replaced by one slim line; the battery-profile card is dropped; headspeed is
  now three per-profile rows; "Actual" → "Latest".
- **Top-bar link bars redesigned** to an outline look matching the battery icon, centered on
  the bar midline, with an optional quiet mode.
- **Default thresholds tuned from real logs:** link `RQlyWarn/Crit` 50/30 → **80/50**; RSSI
  `RssWarn/Crit` default **15/8** (% headroom).
- **All voice WAVs peak-normalized** to match the EdgeTX voice-pack loudness; sounds live in
  `/SOUNDS/en/ultidash/`. Telemetry-lost/link/RSSI now use spoken WAVs, announced once per
  episode.

### Fixed
- **Full-screen touch / widget-menu regression:** after a full-screen cycle the long-press
  menu and taps stopped working — root-caused (EdgeTX keeps `lvgl.box` containers clickable
  when built in full-screen and doesn't rebuild on exit) and fixed by rebuilding once on
  exit. The model image can stay in full-screen.
- **No "battery critical 0 V" on power loss**, and **stats Min/Latest no longer polluted by
  the buffer decay** on unplug: voltages are armed-only, latched against ≤ 1 V readings;
  the BEC value is held through a supply collapse; a collapsing `Vbat` is reported as
  main-power-loss instead.
- **Stats page scoped per connection** (`ever_armed` resets on connect) and **manually
  dismissable**.
- **Touch robustness:** uniform tap cooldown so a late bounce tap can't "click through" onto
  the new view; multi-tap reports ignored.
- **Performance:** bottom-bar getters (Skp/RQly/TQly/TPWR) and the armed state no longer do
  per-frame sensor name lookups; the telemetry pass is throttled to 5 Hz.
- **TX16S (800×480) layout:** adaptive settings row height for the taller toggle switches;
  font-metric (not hardcoded) heights on the battery and event-log pages.
- Earlier fixes: spurious stats 0s, ESC-temp Min ignoring the startup 0.

### Licensing
- **UltiDash is cleanly GPLv3.** The HeliDash base (gismo2004 / HeliWidget) is licensed
  **GPL-3.0 (or later)**; `LICENSE`, `NOTICE.md`, `README.md` and the `main.lua` header
  reflect that the combined work is distributable under GPLv3.

## v0.1 — 2026-05-30

First release. **Experimental — still under testing in the field.**

### Added
- Full-screen LVGL flight dashboard built on **HeliDash** (base) with:
  - In-widget **top bar**: date/time + radio (TX) battery icon (voltage + %, red below
    warning threshold) — replaces the EdgeTX top bar.
  - **Center battery gauge** with the **ePowerbar** reserve/fuel model: reserve-adjusted
    fuel %, discrete green/yellow/red colors, cell count (`NS`), big % and used mAh,
    startup cell-check (grey progress + warning if not full).
  - **Left status panel**: model image (**eBitmap** style), total flights & flight time,
    Governor + Throttle, **eStatus** ESC fault decoder (YGE/OpenYGE, Scorpion, HobbyWing,
    FLYROTOR, OMP, BLHeli_32) + arming-disable reasons, Profile / Rate / Battery-Profile.
  - **Right values panel**: cell/battery voltage, headspeed, current, ESC temp, BEC.
  - **Statistics view** (auto on disarmed/disconnected): Actual/Min/Max table, total
    flights & total flight time (Rotorflight MSP), capacity used.
  - Compact radio-battery icon style adapted from **BattAnalog**.
- **Callouts**: fuel %, low/critical cell voltage, armed/disarm, and ELRS
  link-quality / telemetry-lost warnings.
- Flight-time tracking made governor-independent (headspeed-based) and run in the
  background so it counts off-screen too.
- `Skp` (skipped-telemetry-packet counter) shown in the bottom status bars.

### Notes
- MSP is only read on connect/disarm — never during armed flight.
- No external libraries (no eLib); UltiDash loads only its own files.
