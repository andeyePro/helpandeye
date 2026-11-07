# Help&I button symbols

Two custom SF Symbols, each a figure from the waist up: `figure.help`, the arm straight up as
high as it goes, and `figure.hand`, the arm bent at the elbow with the hand at head height. The
stock symbols did not work: a raised hand on red reads as a stop sign, and `hands.and.sparkles`
as clapping (TODO, 2026-11-02).

`gen_symbols.py` draws both, stdlib only and deterministic, and writes:

- `app/helpandeye/Symbols.xcassets/<name>.symbolset/<name>.svg`: Apple's custom-symbol template
  (v.5.0, Xcode 15 or later) in its variable form, with the Ultralight-S, Regular-S and Black-S
  variants the system interpolates the other 24 from. The three share one path structure, which
  interpolation needs. Limb thickness and head size follow Apple's own `figure.*` symbols at the
  same weights.
- `svg/<name>.svg`: the Regular weight alone, for the website or for looking at.

Run `python3 gen_symbols.py` to regenerate everything. The catalog is compiled into the phone
app, the watch app and the watch complication (`app/project.yml`); the names are used through
`Image(symbol:)` in `app/helpandeye/Symbols.swift`, which falls back to `Image(systemName:)` for
Apple's names, so a coordinator's choice of a stock symbol still works. Check a change in the SF
Symbols app (File, Open the template) and on a device at the largest text size and in dark mode
before merging.
