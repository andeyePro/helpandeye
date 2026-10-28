# Help&I brand mark

The andeye mark with a Help&I iris: a first-aid cross (a Greek cross of five equal squares, as in
ISO 7010 E003) in safety green `#009A44`, the usual screen value for ISO 3864 safety green. The red
cross emblem is protected, so Help&I never uses it.

`gen_mark.py` is derived from andeye.com `assets/brand/mail/gen_mark.py` and uses the
same andeye geometry, so the marks cannot drift. Run `python3 gen_mark.py` to regenerate `svg/`.
`svg/icon-whatsapp.svg` is the mark at 74% width on white, so a circular crop keeps it whole.

## Exports used by the site

`gen_mark.py` writes SVG only. These are separate exports, made by hand and not byte-reproducible:

- `site/favicon.svg` is `mark_body(None, GREEN, 'f')` from `gen_mark.py` inside the 365 x 235 `<svg>`
  wrapper of `mark()`, so the cross is cut clean through to the browser tab.
- `site/apple-touch-icon.png` is `svg/icon-ios-any.svg` rendered at 180 x 180 (RGBA, white ground).
- `site/og.png` is the mark on `#0c0f16`, about 480 px wide and centred, at 1200 x 630.

Any SVG renderer will do, for example ImageMagick:
`convert -background none svg/icon-ios-any.svg -resize 180x180 apple-touch-icon.png`. Check the
result by eye, and that no colour other than `#009A44`, white and the ground appears.
