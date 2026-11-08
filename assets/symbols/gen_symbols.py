#!/usr/bin/env python3
"""Help&I's own button symbols, in Apple's custom SF Symbol template.

Two figures from the waist up, each a head and a torso with one arm:
figure.help with the arm straight up as high as it goes, and figure.hand with
the arm bent at the elbow, the hand at head height.  Stock symbols read as a
stop sign or as clapping (TODO, 2026-11-02); these read as a person.

Stdlib only, deterministic.  Each symbol is written as one SF Symbols
template (v.5.0, the variable form: Ultralight-S, Regular-S and Black-S, from
which the system interpolates the other 24 variants) into the app's
Symbols.xcassets, and as a plain SVG of the Regular weight into svg/.

    python3 gen_symbols.py

The three variants are built from the same path commands in the same order,
with only the measurements changed, which interpolation requires.
"""
import json
import math
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
CATALOG = os.path.join(HERE, '..', '..', 'app', 'helpandeye', 'Symbols.xcassets')

# --------------------------------------------------------------- weights --
# Limb thickness and head radius follow Apple's figure.wave at the same
# weights; everything else scales by k, so the heavier figure is also a
# little taller, as Apple's are.  Units are the template's, at 100 points,
# with a cap height of 70.459.
WEIGHTS = [
    # name, column centre, k, limb, head radius
    ('Ultralight-S', 559.711, 0.95, 5.0, 7.4),
    ('Regular-S', 1449.84, 1.0, 7.0, 8.5),
    ('Black-S', 2933.4, 1.07, 9.6, 9.8),
]
BEARING = 9.77                             # Apple's side bearing on figure.*
BASELINE_S = 696


class Path:
    """Absolute SVG path commands, arcs as cubics, numbers to four places."""

    def __init__(self):
        self.d = []

    def move(self, x, y):
        self.d.append('M%s %s' % (_n(x), _n(y)))

    def line(self, x, y):
        self.d.append('L%s %s' % (_n(x), _n(y)))

    def arc(self, cx, cy, r, a0, a1):
        """From angle a0 to a1 (degrees, screen coordinates, y down), in
        quarter-circle cubics; a0 must be where the path already is."""
        steps = max(1, int(math.ceil(abs(a1 - a0) / 90 - 1e-9)))
        for i in range(steps):
            b0 = math.radians(a0 + (a1 - a0) * i / steps)
            b1 = math.radians(a0 + (a1 - a0) * (i + 1) / steps)
            k = 4 / 3 * math.tan((b1 - b0) / 4)
            p0 = (cx + r * math.cos(b0), cy + r * math.sin(b0))
            p3 = (cx + r * math.cos(b1), cy + r * math.sin(b1))
            p1 = (p0[0] - k * r * math.sin(b0), p0[1] + k * r * math.cos(b0))
            p2 = (p3[0] + k * r * math.sin(b1), p3[1] - k * r * math.cos(b1))
            self.d.append('C%s %s %s %s %s %s' % tuple(_n(v) for v in p1 + p2 + p3))

    def close(self):
        self.d.append('Z')

    def circle(self, cx, cy, r):
        self.move(cx + r, cy)
        self.arc(cx, cy, r, 0, -360)
        self.close()

    def __str__(self):
        return ''.join(self.d)


def _n(v):
    s = ('%.4f' % v).rstrip('0').rstrip('.')
    return '0' if s in ('-0', '') else s


# -------------------------------------------------------------- figures --
def frame(k, t, r):
    """The torso and head shared by both figures: the waist on the baseline,
    rounded shoulders, the head just above them, and the torso wide enough
    for the raised arm to clear the head and still rise from the shoulder."""
    T = -38 * k
    rs = 14 * k
    W = r + 2.5 * k + t + 3 * k
    return dict(
        B=0,                               # waist
        T=T,                               # shoulder line
        W=W,                               # half width
        rb=3.5 * k,                        # waist corners
        rs=rs,                             # the shoulders' curve
        f=2 * k,                           # the small inside corners
        cx=W - rs, cs=T + rs,              # the right shoulder's centre
        cy=T - 3 * k - r,                  # head centre
    )


def waist_and_right_side(p, g):
    B, W, rb = g['B'], g['W'], g['rb']
    p.move(-W + rb, B)
    p.line(W - rb, B)
    p.arc(W - rb, B - rb, rb, 90, 0)
    p.line(W, g['cs'])


def shoulders_and_left_side(p, g):
    """From the top of the right shoulder back round to the start."""
    B, T, W, rb, rs = g['B'], g['T'], g['W'], g['rb'], g['rs']
    p.line(-W + rs, T)
    p.arc(-W + rs, T + rs, rs, -90, -180)
    p.line(-W, B - rb)
    p.arc(-W + rb, B - rb, rb, 180, 90)
    p.close()


def at_x(g, x):
    """The angle on the right shoulder's curve at this x, above its centre."""
    return -math.degrees(math.acos((x - g['cx']) / g['rs']))


def at_y(g, y):
    return math.degrees(math.asin((y - g['cs']) / g['rs']))


def figure_help(k, t, r):
    """The arm straight up from the shoulder, the hand well above the head."""
    g = frame(k, t, r)
    xi = r + 2.5 * k
    xo = xi + t
    top = -76 * k
    p = Path()
    waist_and_right_side(p, g)
    p.arc(g['cx'], g['cs'], g['rs'], 0, at_x(g, xo))
    p.line(xo, top + t / 2)
    p.arc(xo - t / 2, top + t / 2, t / 2, 0, -180)
    p.line(xi, g['cs'] + g['rs'] * math.sin(math.radians(at_x(g, xi))))
    p.arc(g['cx'], g['cs'], g['rs'], at_x(g, xi), -90)
    shoulders_and_left_side(p, g)
    p.circle(0, g['cy'], r)
    return str(p)


def figure_hand(k, t, r):
    """The upper arm out from the shoulder, the forearm up beside the torso,
    the hand level with the top of the head."""
    g = frame(k, t, r)
    ta = g['T'] + 2 * k                    # the upper arm's top edge
    lo = ta + t
    E = g['W'] + 4 * k + t                 # the forearm's outer edge
    top = g['cy'] - r
    f = g['f']
    p = Path()
    waist_and_right_side(p, g)
    p.arc(g['cx'], g['cs'], g['rs'], 0, at_y(g, lo))
    p.line(E - t / 2, lo)
    p.arc(E - t / 2, lo - t / 2, t / 2, 90, 0)
    p.line(E, top + t / 2)
    p.arc(E - t / 2, top + t / 2, t / 2, 0, -180)
    p.line(E - t, ta - f)
    p.arc(E - t - f, ta - f, f, 0, 90)
    p.line(g['cx'] + g['rs'] * math.cos(math.radians(at_y(g, ta))), ta)
    p.arc(g['cx'], g['cs'], g['rs'], at_y(g, ta), -90)
    shoulders_and_left_side(p, g)
    p.circle(0, g['cy'], r)
    return str(p)


SYMBOLS = {'figure.help': figure_help, 'figure.hand': figure_hand}


# ------------------------------------------------------------- template --
NUMBER = r'-?\d+\.?\d*'


def bounds(d):
    nums = [float(v) for v in re.findall(NUMBER, d)]
    return min(nums[0::2]), min(nums[1::2]), max(nums[0::2]), max(nums[1::2])


def shifted(d, dx):
    """The path moved right by dx, so its left edge sits at the bearing."""
    out = []
    for cmd in re.findall(r'[MLCZ][^MLCZ]*', d):
        nums = [float(v) for v in re.findall(NUMBER, cmd)]
        out.append(cmd[0] + ' '.join(_n(v + dx if i % 2 == 0 else v) for i, v in enumerate(nums)))
    return ''.join(out)


def template(name, draw):
    variants, margins = [], []
    for vname, centre, k, t, r in WEIGHTS:
        d = draw(k, t, r)
        x0, _, x1, _ = bounds(d)
        d = shifted(d, BEARING - x0)
        width = x1 - x0 + 2 * BEARING
        tx = centre - width / 2
        variants.append('  <g id="%s" transform="matrix(1 0 0 1 %s %d)">\n   <path d="%s"/>\n  </g>\n'
                        % (vname, _n(tx), BASELINE_S, d))
        for side, x in (('left', tx), ('right', tx + width)):
            margins.append('  <line id="%s-margin-%s" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" '
                           'x1="%s" x2="%s" y1="600.785" y2="720.121"/>\n' % (side, vname, _n(x), _n(x)))
    return (HEAD + NOTES.replace('{name}', name) + GUIDES + ''.join(margins) + ' </g>\n <g id="Symbols">\n'
            + ''.join(variants) + ' </g>\n</svg>\n')


def plain(draw):
    """The Regular weight alone, for the website and for looking at."""
    _, _, k, t, r = WEIGHTS[1]
    d = draw(k, t, r)
    x0, y0, x1, y1 = bounds(d)
    m = 4
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s %s %s %s">\n <path d="%s"/>\n</svg>\n'
            % (_n(x0 - m), _n(y0 - m), _n(x1 - x0 + 2 * m), _n(y1 - y0 + 2 * m), d))


HEAD = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg
PUBLIC "-//W3C//DTD SVG 1.1//EN"
       "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
'''

_TEXT = ('style="stroke:none;fill:black;font-family:-apple-system,&quot;SF Pro Display&quot;,'
         '&quot;SF Pro Text&quot;,Helvetica,sans-serif;')
_WEIGHT_LABELS = [('Ultralight', 559.711), ('Thin', 856.422), ('Light', 1153.13), ('Regular', 1449.84),
                  ('Medium', 1746.56), ('Semibold', 2043.27), ('Bold', 2339.98), ('Heavy', 2636.69), ('Black', 2933.4)]
_NOTE_LINES = [
    ('font-weight:bold;', 263, 1953, 'Design Variations'),
    ('', 263, 1971, 'Symbols are supported in up to nine weights and three scales.'),
    ('', 263, 1989, 'For optimal layout with text and other symbols, vertically align'),
    ('', 263, 2007, 'symbols with the adjacent text.'),
    ('font-weight:bold;', 776, 1953, 'Margins'),
    ('', 776, 1971, 'Leading and trailing margins on the left and right side of each symbol'),
    ('', 776, 1989, 'can be adjusted by modifying the x-location of the margin guidelines.'),
    ('', 776, 2007, 'Modifications are automatically applied proportionally to all'),
    ('', 776, 2025, 'scales and weights.'),
    ('font-weight:bold;', 1289, 1953, 'Exporting'),
    ('', 1289, 1971, 'Symbols should be outlined when exporting to ensure the'),
    ('', 1289, 1989, 'design is preserved when submitting to Xcode.'),
    ('text-anchor:end;', 3036, 1951, 'Requires Xcode 15 or greater'),
    ('text-anchor:end;', 3036, 1987, 'Typeset at 100.0 points'),
    ('', 263, 726, 'Small'),
    ('', 263, 1156, 'Medium'),
    ('', 263, 1586, 'Large'),
]


def _text(style, x, y, words, id=''):
    return '  <text %s%s" transform="matrix(1 0 0 1 %s %s)">%s</text>\n' % (id, _TEXT + style, x, y, words)


NOTES = (' <g id="Notes">\n'
         '  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>\n'
         '  <line style="fill:none;stroke:black;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="292" y2="292"/>\n'
         + _text('font-weight:bold;', 263, 322, 'Weight/Scale Variations')
         + ''.join(_text('text-anchor:middle;', x, 322, w) for w, x in _WEIGHT_LABELS)
         + '  <line style="fill:none;stroke:black;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1903" y2="1903"/>\n'
         + ''.join(_text(*line) for line in _NOTE_LINES)
         + _text('text-anchor:end;', 3036, 1933, 'Template v.5.0', 'id="template-version" ')
         + _text('text-anchor:end;', 3036, 1969, 'Generated from {name}', 'id="descriptive-name" ')
         + ' </g>\n')

_H = ('M0.993654 0L3.63775 0L29.3281-67.1323L30.0303-67.1323L30.0303-70.459L28.1226-70.459ZM11.6885-24.4799L46.9815-24.4799'
      'L46.2315-26.7285L12.4385-26.7285ZM55.1196 0L57.7637 0L30.6382-70.459L29.4326-70.459L29.4326-67.1323Z')
_GUIDE = ('  <line id="%s-%s" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" '
          'x1="263" x2="3036" y1="%s" y2="%s"/>\n')
GUIDES = (' <g id="Guides">\n'
          + ''.join('  <g id="H-reference" style="fill:#27AAE1;stroke:none;" transform="matrix(1 0 0 1 339 %d)">\n'
                    '   <path d="%s"/>\n  </g>\n' % (y, _H) for y in (696, 1126, 1556))
          + ''.join(_GUIDE % ('Baseline', s, y, y) + _GUIDE % ('Capline', s, _n(y - 70.459), _n(y - 70.459))
                    for s, y in (('S', 696), ('M', 1126), ('L', 1556))))


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(text)
    print(os.path.relpath(path, HERE))


def main():
    info = {'info': {'author': 'xcode', 'version': 1}}
    write(os.path.join(CATALOG, 'Contents.json'), json.dumps(info, indent=2) + '\n')
    for name, draw in SYMBOLS.items():
        folder = os.path.join(CATALOG, name + '.symbolset')
        write(os.path.join(folder, 'Contents.json'),
              json.dumps(dict(info, symbols=[{'filename': name + '.svg', 'idiom': 'universal'}]), indent=2) + '\n')
        write(os.path.join(folder, name + '.svg'), template(name, draw))
        write(os.path.join(HERE, 'svg', name + '.svg'), plain(draw))


if __name__ == '__main__':
    main()
