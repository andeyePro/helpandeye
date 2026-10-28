#!/usr/bin/env python3
"""Help&I brand marks, drawn from the original andeye geometry.

Stdlib only, deterministic: every path here is computed from the same cubics
the live website engine uses (sites/andeye.com/public/andeye-eye.js), which
are in turn assets/brand/andeye.svg transcribed verbatim — viewBox 365x235,
stroke 17, translate 18.0915,17.9436.  Nothing is redrawn by hand, so the
website mark and the app icon cannot drift.

    python3 gen_mark.py            # writes svg/ and the icon SVGs

PNGs are rendered from those SVGs (see README.md); this script never
rasterises, so it needs nothing installed.
"""
import os

# --------------------------------------------------------------- geometry --
T = (18.0915, 17.9436)
def P(x, y):
    return (x + T[0], y + T[1])

OPEN = [                                   # the open pose, four cubics
    [P(145, 157), P(-95, -27),      P(177, -2), P(59, 76)],
    [P(59, 76),   P(-37.95, 140.08), P(54, 236), P(122, 137)],
    [P(122, 137), P(205.86, 14.91), P(311, 137), P(311, 137)],
    [P(311, 137), P(311, 137),      P(232, 221), P(145, 157)],
]
W = 17.0                                   # the brand stroke width

def _seg(c):
    return ('C%.2f,%.2f %.2f,%.2f %.2f,%.2f'
            % (c[1][0], c[1][1], c[2][0], c[2][1], c[3][0], c[3][1]))

def _path(c):
    return 'M%.2f,%.2f' % (c[0][0], c[0][1]) + _seg(c)

def _aperture():
    """The lens between the two lids — what clips the iris."""
    return ('M%.2f,%.2f' % (OPEN[2][0][0], OPEN[2][0][1]) + _seg(OPEN[2])
            + _seg(OPEN[3]) + 'Z')

def _point_on(c, u):
    v = 1 - u
    a, b, d, e = v*v*v, 3*v*v*u, 3*v*u*u, u*u*u
    return (a*c[0][0] + b*c[1][0] + d*c[2][0] + e*c[3][0],
            a*c[0][1] + b*c[1][1] + d*c[2][1] + e*c[3][1])

# The iris: centred between the aperture's corners, its circle's top and bottom
# meeting the lids' high and low points.
_hi = min(_point_on(OPEN[2], i / 48.0)[1] for i in range(49))
_lo = max(_point_on(OPEN[3], i / 48.0)[1] for i in range(49))
CX = (OPEN[2][0][0] + OPEN[2][3][0]) / 2
CY = (_hi + _lo) / 2
R = (_lo - _hi) / 2                        # 234.59, 149.83, r 49.15

# ------------------------------------------------------------ the cross --
# A first-aid cross: a Greek cross of five equal squares (ISO 7010 E003), so
# each arm is a third of the span, with square ends.  It spans 0.62r either
# side of the centre, the same reach as the other <X>&I glyphs.
A = 0.62 * R
ARM = 2 * A / 3.0

def cross():
    """The cross as one closed outline, filled in the page colour."""
    h = ARM / 2.0
    pts = [(-h, -A), (h, -A), (h, -h), (A, -h), (A, h), (h, h),
           (h, A), (-h, A), (-h, h), (-A, h), (-A, -h), (-h, -h)]
    return 'M' + ' L'.join('%.2f,%.2f' % (CX + x, CY + y) for x, y in pts) + 'Z'

GREEN = '#009A44'                          # safety green, the usual screen value for ISO 3864 first-aid green; never the protected red cross

# ------------------------------------------------------------- the drawing --
def mark_body(bg, colour, uid):
    """The mark inside its own 365x235 space.  bg=None knocks the glyph clean
    through to whatever is behind (the tinted app-icon appearance)."""
    o = ['<defs><clipPath id="ap%s"><path d="%s"/></clipPath>' % (uid, _aperture())]
    if bg is None:
        o.append('<mask id="ir%s" maskUnits="userSpaceOnUse" x="0" y="0" '
                 'width="365" height="235"><circle cx="%.2f" cy="%.2f" r="%.2f" fill="#fff"/>'
                 % (uid, CX, CY, R))
        o.append('<path d="%s" fill="#000"/>' % cross())
        o.append('</mask>')
    o.append('</defs>')
    o.append('<g clip-path="url(#ap%s)">' % uid)
    if bg is None:
        o.append('<rect x="0" y="0" width="365" height="235" fill="%s" mask="url(#ir%s)"/>'
                 % (colour, uid))
    else:
        o.append('<circle cx="%.2f" cy="%.2f" r="%.2f" fill="%s"/>' % (CX, CY, R, colour))
        o.append('<path d="%s" fill="%s"/>' % (cross(), bg))
    o.append('</g>')
    o.append('<g stroke="%s" stroke-width="%d" stroke-linecap="round" fill="none">'
             % (colour, W))
    for c in OPEN:
        o.append('<path d="%s"/>' % _path(c))
    o.append('</g>')
    return o

def mark(bg='#131826', colour=GREEN, uid='m'):
    """The website mark: one <svg>, viewBox 0 0 365 235, on a known ground."""
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 365 235" fill="none" '
            'role="img" aria-label="Help&amp;I">\n' + '\n'.join(mark_body(bg, colour, uid))
            + '\n</svg>\n')

CANVAS = 1024
MARK_W = 0.90        # the mark's share of the icon's width — as wide as Apple's
                     # widest first-party marks sit in theirs
WHATSAPP_W = 0.74    # narrower, so WhatsApp's circular crop keeps the whole mark
MAC_PLATE = 824      # Apple's macOS icon grid: the rounded square inside 1024

def icon(appearance='any', platform='ios', canvas=CANVAS, mark_w=MARK_W, uid=None):
    """appearance: any (white ground) | dark (black) | tinted (grayscale,
    transparent — the system supplies ground and tint).
    platform: ios (full bleed, the system masks it) | mac (draws its own
    rounded square, inset on Apple's grid)."""
    bg = {'any': '#FFFFFF', 'dark': '#000000', 'tinted': None}[appearance]
    colour = GREEN if bg is not None else '#FFFFFF'
    plate = canvas if platform == 'ios' else round(canvas * MAC_PLATE / 1024.0)
    off = (canvas - plate) / 2.0
    mw = plate * mark_w
    x = off + (plate - mw) / 2.0
    y = off + (plate - mw * 235 / 365.0) / 2.0
    o = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" '
         'height="%d" fill="none">' % (canvas, canvas, canvas, canvas)]
    if bg is not None:
        if platform == 'ios':
            o.append('<rect width="%d" height="%d" fill="%s"/>' % (canvas, canvas, bg))
        else:
            o.append('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.2f" fill="%s"/>'
                     % (off, off, plate, plate, plate * 0.2247, bg))
    o.append('<g transform="translate(%.3f,%.3f) scale(%.6f)">' % (x, y, mw / 365.0))
    o += mark_body(bg, colour, uid or appearance[0] + platform[0])
    o.append('</g></svg>')
    return '\n'.join(o) + '\n'

if __name__ == '__main__':
    here = os.path.dirname(os.path.abspath(__file__))
    svg = os.path.join(here, 'svg')
    os.makedirs(svg, exist_ok=True)
    open(os.path.join(svg, 'help-mark-panel.svg'), 'w').write(mark('#131826'))
    open(os.path.join(svg, 'help-mark-white.svg'), 'w').write(mark('#FFFFFF'))
    for ap in ('any', 'dark', 'tinted'):
        open(os.path.join(svg, 'icon-ios-%s.svg' % ap), 'w').write(icon(ap, 'ios'))
    for ap in ('any', 'dark'):
        open(os.path.join(svg, 'icon-mac-%s.svg' % ap), 'w').write(icon(ap, 'mac'))
    open(os.path.join(svg, 'icon-whatsapp.svg'), 'w').write(icon('any', 'ios', mark_w=WHATSAPP_W, uid='w'))
    print('iris %.2f,%.2f r%.2f | cross reach %.2fr, arm %.2f' % (CX, CY, R, A / R, ARM))
