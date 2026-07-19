# NOTICE — Credits & Licensing

UltiDash is a **merged/derivative work** that builds on and reuses code, logic and
visual concepts from several EdgeTX widgets. All credit to their respective authors.

## Sources

| Component | Author / Source | License | Reused in UltiDash |
|-----------|-----------------|---------|--------------------|
| **HeliDash** | gismo2004 — [HeliWidget](https://github.com/gismo2004/HeliWidget) | **GPL-3.0** (or later) | Base: layout, LVGL UI, telemetry handling, flight statistics |
| **ePowerbar** | Rob 'bob00' Gayle — [etx-widgets](https://github.com/bob01/etx-widgets) | GPLv3 | Battery fuel/reserve model, discrete bar colors, startup cell-check, voice/vibration callout engine (itself based on "Lipo battery from single analog source" by Offer Shmuely) |
| **eBitmap** | Rob 'bob00' Gayle — etx-widgets | GPLv3 | Model/craft image handling (`/images`) |
| **eStatus** | Rob 'bob00' Gayle — etx-widgets | GPLv3 | Throttle %, multi-vendor ESC status/fault decoder, arming-disable reasons |
| **BattAnalog** | Offer Shmuely — [edgetx-x10-widgets](https://github.com/offer-shmuely/edgetx-x10-widgets) | GPLv2 (file header) | Only the **style** of the compact top-bar battery icon (not a verbatim code copy) |

## Licensing status (updated July 2026)

- **HeliWidget / HeliDash** (gismo2004) — the **base**, i.e. the bulk of the code — is
  now licensed **GPL-3.0 (or later)**. This resolves the earlier blocker (the repo
  previously had no license file); the base is now GPL-compatible.
- **etx-widgets** (ePowerbar / eBitmap / eStatus): the repository `LICENSE` is
  **GPL-3.0** (the individual file headers still say "GPLv2", but the repo LICENSE is
  authoritative).
- **BattAnalog** (Offer Shmuely): no repository LICENSE file; only a "GPLv2" file
  header. Only the icon's visual concept was reimplemented here — no code was copied.

## What this means

- All reused components are now **GPL-compatible** (HeliDash base GPL-3.0; etx-widgets
  parts GPL-3.0), so UltiDash as a whole is distributed under **GPLv3** (see
  [`LICENSE`](LICENSE)).
- The combined work can therefore be released and redistributed under GPLv3, with the
  attributions in this file preserved.
- **No warranty:** the software is provided *as-is*; use is at your own risk (see the
  warranty disclaimer in `LICENSE` and the `main.lua` header).

*This is a plain-language summary, not legal advice.*
