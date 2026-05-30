# NOTICE — Credits & Licensing

UltiDash is a **merged/derivative work** that builds on and reuses code, logic and
visual concepts from several EdgeTX widgets. All credit to their respective authors.

## Sources

| Component | Author / Source | License | Reused in UltiDash |
|-----------|-----------------|---------|--------------------|
| **HeliDash** | gismo2004 — [HeliWidget](https://github.com/gismo2004/HeliWidget) | **none** (see below) | Base: layout, LVGL UI, telemetry handling, flight statistics |
| **ePowerbar** | Rob 'bob00' Gayle — [etx-widgets](https://github.com/bob01/etx-widgets) | GPLv3 | Battery fuel/reserve model, discrete bar colors, startup cell-check, voice/vibration callout engine (itself based on "Lipo battery from single analog source" by Offer Shmuely) |
| **eBitmap** | Rob 'bob00' Gayle — etx-widgets | GPLv3 | Model/craft image handling (`/images`) |
| **eStatus** | Rob 'bob00' Gayle — etx-widgets | GPLv3 | Throttle %, multi-vendor ESC status/fault decoder, arming-disable reasons |
| **BattAnalog** | Offer Shmuely — [edgetx-x10-widgets](https://github.com/offer-shmuely/edgetx-x10-widgets) | GPLv2 (file header) | Only the **style** of the compact top-bar battery icon (not a verbatim code copy) |

## Licensing status (verified May 2026)

- **etx-widgets** (ePowerbar / eBitmap / eStatus): the repository `LICENSE` is
  **GPL-3.0** (the individual file headers still say "GPLv2", but the repo LICENSE is
  authoritative).
- **HeliWidget / HeliDash** (gismo2004) — the **base**, i.e. the bulk of the code —
  has **no license file**. The author describes it as *"a personal hobby project
  shared freely with the community"* (as-is). That is **not** a formal open-source
  license. "No license" defaults to **all rights reserved** — it does **not** mean the
  code may be relicensed. Only gismo2004 can license that code.
- **BattAnalog** (Offer Shmuely): no repository LICENSE file; only a "GPLv2" file
  header. Only the icon's visual concept was reimplemented here — no code was copied.

## What this means

- GPLv3 (see [`LICENSE`](LICENSE)) is the **intended** license for UltiDash's own code
  and the etx-widgets-derived parts.
- The combined work is **not yet cleanly GPLv3** because the HeliDash base is currently
  unlicensed. A **formal public release** should first obtain a license for that base
  (ideally GPLv3, or "GPLv2 or later", or explicit permission from gismo2004).
- **Private use** of this widget is unaffected by the above.

*This is a plain-language summary, not legal advice.*
