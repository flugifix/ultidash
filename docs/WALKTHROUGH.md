# UltiDash — Illustrated Walkthrough

A visual tour of what UltiDash looks like in use — the flight dashboard, the tap-to-open
detail pages, the menu and the Toolbox, in both the light and the dark colour scheme.

> New here? Get it running first with the **[Quick Start guide](QUICKSTART.md)**, then add
> the extras from the **[Optional Features guide](OPTIONAL_FEATURES.md)**. The full spec is
> **[REFERENCE.md](REFERENCE.md)**.

> 📷 **About the screenshots.** Every picture on this page is an unscaled **800 × 480** grab
> from a **TX16S MK3** running **0.8.0**, taken in one session against a real Rotorflight
> 4.6 flight controller configured as an **iLGoblin 700 Pro** — a 700-class machine on 12S
> with a YGE ESC. The readings are one moment of one real flight, held still: 3.94 V per
> cell, 856 mAh used, 1698 rpm, 23.6 A, ESC 37 °C, both receiver aerials live. The Log
> Viewer graphs that same flight and the Flight Log lists it.
>
> On the TX15 (480 × 320) and the TX16S MK2 (480 × 272) the same screens lay out for the
> smaller display — fewer rows, tighter chips, the same content.
>
> Two settings in these shots are not at their defaults, because at their defaults the
> pictures would document a setup step: *Link ▸ TX power limit* is set (without it the ELRS
> page draws a hint across its TPWR bar instead of a reading), and all twelve Telemetry
> slots are assigned (five ship assigned).

---

## The flight dashboard

The main view — everything on one screen.

![Flight dashboard](../images/walkthrough/01-dashboard.png)

- **Top bar:** the **☰ menu glyph** (full-screen, disarmed) · the clock · the **ELRS link**
  as stacked bars · the radio battery.
- **Left panel:** the model image, **Flights / Total time**, **Governor + Throttle** state,
  the **ESC status** line, and **Profile / Rate / B-Profile** — the last read from the
  flight controller, here the 5000 mAh battery profile the pack is flown on.
- **Centre:** the reserve-adjusted **battery gauge** (cell count, fuel %, used mAh).
- **Right panel:** five freely assignable value slots (cell voltage, headspeed, current,
  ESC temp, BEC…).
- **Bottom bar:** craft name, arm state, TX power, skipped-packet count.

The model picture is resolved from the **craft name the flight controller reports** — put a
`<craft name>.png` in the radio's `/IMAGES` and it appears by itself. In flight the same
view goes live, governor spooling up, headspeed, throttle and current all updating:

![Dashboard armed](../images/walkthrough/02-dashboard-armed.png)

---

## Tap a panel → detail pages

In full-screen, tapping a panel drills into it. Tap the **X** (or **RTN**) to close.

### Battery — tap the gauge
Cell-voltage scale with the active thresholds (crit / low / full), read from the **FC
config** and labelled as such, plus the battery in the dashboard look with the reserve.

![Battery detail](../images/walkthrough/03-battery.png)

### Telemetry — tap the value panel
A grid of up to 12 chosen sensors, each with its unit and the EdgeTX session **low..high**.

![Telemetry detail](../images/walkthrough/04-telemetry.png)

### ELRS link — tap the top-bar bars
RQ, TQ, 1RSS, 2RSS, downlink RSSI (TRSS), SNR and TPWR as labelled bars, plus the receiver
antenna pair (green = the antenna carrying the link, hollow = there is no second one) and
the session RQ-min.

![ELRS detail](../images/walkthrough/05-elrs.png)

### Status & events — tap the status line
Arm / governor / throttle summary, the live status line and a timestamped ESC event log.

![Status & events](../images/walkthrough/06-status-events.png)

---

## The menu

Tap the **☰ glyph** (disarmed) to open the menu hub. Two actions lead it; the three
read-only pages are grouped under **Diagnostics**.

![Menu](../images/walkthrough/07-menu.png)

### Settings
All 13 groups on one screen, in four sections — *Appearance*, *Battery & limits*,
*Sound & callouts*, *System* — each opening its own page of real toggles, dropdowns and
steppers. Saved per EdgeTX model. *(Reset to defaults lives in **General**.)*

![Settings](../images/walkthrough/08-settings.png)

### Diagnostics ▸ Status
A read-only summary of the active configuration: version, craft target, which config file is
in force, the link and MSP provider, the cell thresholds **and their source**, and what the
flight controller itself is set to.

![Status overview](../images/walkthrough/09-status-overview.png)

### Diagnostics ▸ Sensor check
Lists every sensor UltiDash needs and flags each **OK / no data / missing** with its live
reading — the fastest way to confirm your telemetry is complete.

![Sensor check](../images/walkthrough/10-sensor-check.png)

### Diagnostics ▸ ELRS Status
Reads the **transmitter module's own** configuration over CRSF: module and firmware, packet
rate, telemetry ratio, antenna and switch mode, model match, max and dynamic power. *(No
screenshot here — this page asks the ELRS module itself, and the simulator these pictures
were taken on has none, so every row would read `-` under `Read: no module`.)*

---

## Toolbox

On-demand tool pages (disarmed), lazy-loaded so they cost no memory while flying. The
exception is the **Live Monitor**, whose purpose is in-flight use.

![Toolbox](../images/walkthrough/11-toolbox.png)

### Log Viewer
Graph the radio's own `/LOGS` telemetry CSVs on-screen. Open a log, then pick from a card
grid — the four built-in sets **Power / Battery / RF link / Governor**, each showing how many
of its sensors this log actually contains, plus **Custom sensors** for your own pick:

![Log Viewer — what to display](../images/walkthrough/12-logviewer-pick.png)

…then zoom, pan and drag a time cursor over up to four curves. Your own card sets can be
saved, renamed and reordered on the radio (**Edit**, top-right):

![Log Viewer — chart](../images/walkthrough/13-logviewer-chart.png)

*The chart above is the same flight the dashboard shots are frozen in — 9:42 on 11 July.*

### Flight Log
Browse the flight history UltiDash records on the SD card — three tabs, every row tappable:

| Flights | Per model | Batteries |
|---|---|---|
| ![Flights](../images/walkthrough/14-flightlog-flights.png) | ![Models](../images/walkthrough/15-flightlog-models.png) | ![Batteries](../images/walkthrough/16-flightlog-batteries.png) |

*Also in the Toolbox:* the **RF Adjustment** Map / Editor, **RF2 Config** (the full
Rotorflight FC configuration, run right on the radio), the **Live Monitor**, a **Battery
profile** picker and an experimental door to **RFSuite** — see [TOOLBOX.md](TOOLBOX.md).

---

## Dark theme

Every screen also comes in the high-contrast **UltiDash dark** palette (and an EdgeTX-theme
option). Switch it under *Settings ▸ Skin ▸ Color scheme* — the colour scheme belongs to the
active skin since 0.7.0. The Log Viewer picks its own neon curve colours from it.

| | |
|---|---|
| ![Dark dashboard](../images/walkthrough/17-dark-dashboard.png) | ![Dark battery](../images/walkthrough/18-dark-battery.png) |
| ![Dark telemetry](../images/walkthrough/19-dark-telemetry.png) | ![Dark Log Viewer](../images/walkthrough/20-dark-logviewer.png) |

---

That's the tour. For the how and why behind each screen, see **[REFERENCE.md](REFERENCE.md)**.
