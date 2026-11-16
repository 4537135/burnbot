#!/usr/bin/env python3
"""Turns Burnbot's own pixel letters into a font the screens can use.

The capitals, digits and a few signs are the 5 x 7 letters the desk screen
draws (desk/burnbot_screen/render.h); the small letters and the rest are drawn
here to match. The result is written to public/pixel.css as the font
"Burnbot Pixel". One pixel is a tenth of the font size, so sizes that are a
multiple of 5px stay sharp on a Retina screen.

    python3 tools/make-font.py

It needs nothing but Python 3.
"""
import base64
import math
import os
import struct

PX = 100            # one pixel, in font units
EM = 10 * PX        # 8 pixels above the baseline (7 of letter, 1 of air) and 2 below
ABOVE = 7           # rows of a letter above the baseline


def bits(values):
    """Rows written as five bits each, as in the desk screen's program."""
    return [''.join('#' if v >> (4 - b) & 1 else '.' for b in range(5)) for v in values]


# letter -> (rows, the row it starts on counting from the top, keep its full width)
GLYPHS = {}


def add(chars, rows, top=0, fixed=False):
    for ch in chars:
        GLYPHS[ord(ch)] = (rows, top, fixed)


# ---- capitals and digits: the desk screen's letters
for ch, rows in {
    'A': [14, 17, 17, 31, 17, 17, 17], 'B': [30, 17, 17, 30, 17, 17, 30], 'C': [14, 17, 16, 16, 16, 17, 14],
    'D': [30, 17, 17, 17, 17, 17, 30], 'E': [31, 16, 16, 30, 16, 16, 31], 'F': [31, 16, 16, 30, 16, 16, 16],
    'G': [14, 17, 16, 23, 17, 17, 15], 'H': [17, 17, 17, 31, 17, 17, 17], 'I': [14, 4, 4, 4, 4, 4, 14],
    'J': [7, 2, 2, 2, 2, 18, 12], 'K': [17, 18, 20, 24, 20, 18, 17], 'L': [16, 16, 16, 16, 16, 16, 31],
    'M': [17, 27, 21, 21, 17, 17, 17], 'N': [17, 17, 25, 21, 19, 17, 17], 'O': [14, 17, 17, 17, 17, 17, 14],
    'P': [30, 17, 17, 30, 16, 16, 16], 'Q': [14, 17, 17, 17, 21, 18, 13], 'R': [30, 17, 17, 30, 20, 18, 17],
    'S': [15, 16, 16, 14, 1, 1, 30], 'T': [31, 4, 4, 4, 4, 4, 4], 'U': [17, 17, 17, 17, 17, 17, 14],
    'V': [17, 17, 17, 17, 17, 10, 4], 'W': [17, 17, 17, 21, 21, 21, 10], 'X': [17, 17, 10, 4, 10, 17, 17],
    'Y': [17, 17, 17, 10, 4, 4, 4], 'Z': [31, 1, 2, 4, 8, 16, 31],
}.items():
    add(ch, bits(rows))
for ch, rows in {
    '0': [14, 17, 19, 21, 25, 17, 14], '1': [4, 12, 4, 4, 4, 4, 14], '2': [14, 17, 1, 2, 4, 8, 31],
    '3': [31, 2, 4, 2, 1, 17, 14], '4': [2, 6, 10, 18, 31, 2, 2], '5': [31, 16, 30, 1, 1, 17, 14],
    '6': [6, 8, 16, 30, 17, 17, 14], '7': [31, 1, 2, 4, 8, 8, 8], '8': [14, 17, 17, 14, 17, 17, 14],
    '9': [14, 17, 17, 15, 1, 2, 12],
}.items():
    add(ch, bits(rows), fixed=True)         # every digit as wide as the next, so columns of numbers line up

# ---- small letters, four pixels wide where they can be
add('a', ['.##.', '...#', '.###', '#..#', '.###'], 2)
add('b', ['#...', '#...', '###.', '#..#', '#..#', '#..#', '###.'])
add('c', ['.##', '#..', '#..', '#..', '.##'], 2)
add('d', ['...#', '...#', '.###', '#..#', '#..#', '#..#', '.###'])
add('e', ['.##.', '#..#', '####', '#...', '.###'], 2)
add('f', ['.##', '#..', '###', '#..', '#..', '#..', '#..'])
add('g', ['.###', '#..#', '#..#', '#..#', '.###', '...#', '.##.'], 2)
add('h', ['#...', '#...', '###.', '#..#', '#..#', '#..#', '#..#'])
add('i', ['#', '.', '#', '#', '#', '#', '#'])
add('j', ['.#', '..', '.#', '.#', '.#', '.#', '.#', '.#', '#.'])
add('k', ['#...', '#...', '#..#', '#.#.', '##..', '#.#.', '#..#'])
add('l', ['#.', '#.', '#.', '#.', '#.', '#.', '.#'])
add('m', ['##.#.', '#.#.#', '#.#.#', '#.#.#', '#.#.#'], 2)
add('n', ['###.', '#..#', '#..#', '#..#', '#..#'], 2)
add('o', ['.##.', '#..#', '#..#', '#..#', '.##.'], 2)
add('p', ['###.', '#..#', '#..#', '#..#', '###.', '#...', '#...'], 2)
add('q', ['.###', '#..#', '#..#', '#..#', '.###', '...#', '...#'], 2)
add('r', ['#.#', '##.', '#..', '#..', '#..'], 2)
add('s', ['.###', '#...', '.##.', '...#', '###.'], 2)
add('t', ['.#.', '.#.', '###', '.#.', '.#.', '.#.', '..#'])
add('u', ['#..#', '#..#', '#..#', '#..#', '.###'], 2)
add('v', ['#...#', '#...#', '.#.#.', '.#.#.', '..#..'], 2)
add('w', ['#...#', '#...#', '#.#.#', '#.#.#', '.#.#.'], 2)
add('x', ['#.#', '#.#', '.#.', '#.#', '#.#'], 2)
add('y', ['#..#', '#..#', '#..#', '#..#', '.###', '...#', '.##.'], 2)
add('z', ['####', '...#', '.##.', '#...', '####'], 2)

# ---- signs
add('!', ['#', '#', '#', '#', '#', '.', '#'])
add('"“”', ['#.#', '#.#'])
add('#', ['.#.#.', '.#.#.', '#####', '.#.#.', '#####', '.#.#.', '.#.#.'])
add('$', ['..#..', '.####', '#.#..', '.###.', '..#.#', '####.', '..#..'])
add('%', bits([24, 25, 2, 4, 8, 19, 3]))
add('&', ['.##..', '#..#.', '#.#..', '.#...', '#.#.#', '#..#.', '.##.#'])
add("'‘’", ['#', '#'])
add('(', ['.#', '#.', '#.', '#.', '#.', '#.', '.#'])
add(')', ['#.', '.#', '.#', '.#', '.#', '.#', '#.'])
add('*', ['#.#', '.#.', '#.#'], 1)
add('+', ['.#.', '###', '.#.'], 2)
add(',', ['.#', '.#', '#.'], 5)
add('-−', ['###'], 3)
add('.', ['#'], 6)
add('/', ['..#', '..#', '.#.', '.#.', '.#.', '#..', '#..'])
add(':', ['#', '.', '.', '#'], 2)
add(';', ['.#', '..', '..', '.#', '.#', '#.'], 2)
add('<', ['..#', '.#.', '#..', '.#.', '..#'], 1)
add('=', ['###', '...', '###'], 2)
add('>', ['#..', '.#.', '..#', '.#.', '#..'], 1)
add('?', ['.##.', '#..#', '...#', '..#.', '.#..', '....', '.#..'])
add('@', ['.###.', '#...#', '#.###', '#.#.#', '#.###', '#....', '.###.'])
add('[', ['##', '#.', '#.', '#.', '#.', '#.', '##'])
add('\\', ['#..', '#..', '.#.', '.#.', '.#.', '..#', '..#'])
add(']', ['##', '.#', '.#', '.#', '.#', '.#', '##'])
add('^', ['.#.', '#.#'])
add('_', ['####'], 7)
add('`', ['#.', '.#'])
add('{', ['..#', '.#.', '.#.', '#..', '.#.', '.#.', '..#'])
add('|', ['#', '#', '#', '#', '#', '#', '#'])
add('}', ['#..', '.#.', '.#.', '..#', '.#.', '.#.', '#..'])
add('~', ['.#...', '#.#.#', '...#.'], 2)
add('·', ['#'], 3)                                         # ·
add('–', ['####'], 3)                                      # –
add('—', ['#####'], 3)                                     # —
add('…', ['#.#.#'], 6)                                     # …
add('×', ['#.#', '.#.', '#.#'], 2)                         # ×
add('▲', ['..#..', '.###.', '#####'], 2)                   # ▲
add('▼', ['#####', '.###.', '..#..'], 2)                   # ▼
add('▶', ['#..', '##.', '###', '##.', '#..'], 1)           # ▶
add('→', ['..#..', '...#.', '#####', '...#.', '..#..'], 1)  # →

SPACE = 4           # pixels a space moves along
NOTDEF = (['#####', '#...#', '#...#', '#...#', '#...#', '#...#', '#####'], 0, True)


def outline(rows, top, fixed):
    """The pixels as closed outlines running clockwise around the ink, and how far the letter moves along."""
    ink = {(x, ABOVE - 1 - (top + r)) for r, row in enumerate(rows) for x, ch in enumerate(row) if ch == '#'}
    if not fixed:                                   # close up to the left edge
        left = min(x for x, _ in ink)
        ink = {(x - left, y) for x, y in ink}
    width = 5 if fixed else max(x for x, _ in ink) + 1
    edges = {}
    for x, y in ink:
        if (x, y + 1) not in ink:
            edges.setdefault((x, y + 1), []).append((x + 1, y + 1))     # along the top, going right
        if (x + 1, y) not in ink:
            edges.setdefault((x + 1, y + 1), []).append((x + 1, y))     # down the right side
        if (x, y - 1) not in ink:
            edges.setdefault((x + 1, y), []).append((x, y))             # along the bottom, going left
        if (x - 1, y) not in ink:
            edges.setdefault((x, y), []).append((x, y + 1))             # up the left side
    contours = []
    while edges:
        start = point = next(iter(edges))
        heading = None
        path = []
        while True:
            ways = edges[point]
            turn = (heading[1], -heading[0]) if heading else None
            # where two pixels touch by a corner, turn right so each keeps its own outline
            nxt = next((w for w in ways if (w[0] - point[0], w[1] - point[1]) == turn), ways[0])
            ways.remove(nxt)
            if not ways:
                del edges[point]
            path.append(point)
            heading = (nxt[0] - point[0], nxt[1] - point[1])
            point = nxt
            if point == start:
                break
        step = lambda a, b: (b[0] - a[0], b[1] - a[1])
        corners = [p for i, p in enumerate(path) if step(path[i - 1], p) != step(p, path[(i + 1) % len(path)])]
        contours.append([(x * PX, y * PX) for x, y in corners])
    return contours, (width + 1) * PX


def glyph_record(contours):
    if not contours:
        return b''
    points = [p for c in contours for p in c]
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    out = struct.pack('>5h', len(contours), min(xs), min(ys), max(xs), max(ys))
    end = -1
    for c in contours:
        end += len(c)
        out += struct.pack('>H', end)
    out += struct.pack('>H', 0)                     # no instructions
    out += bytes([0x01] * len(points))              # every point is on the outline; each step is 16 bits
    last = 0
    for x in xs:
        out += struct.pack('>h', x - last)
        last = x
    last = 0
    for y in ys:
        out += struct.pack('>h', y - last)
        last = y
    return out + b'\0' * (-len(out) % 4)


def checksum(data):
    data += b'\0' * (-len(data) % 4)
    return sum(struct.unpack('>%dI' % (len(data) // 4), data)) & 0xFFFFFFFF


def build():
    codes = sorted(GLYPHS)
    shapes = [outline(*NOTDEF), ([], SPACE * PX), ([], SPACE * PX)]        # .notdef, space, no-break space
    order = [None, 0x20, 0xA0]
    for code in codes:
        shapes.append(outline(*GLYPHS[code]))
        order.append(code)
    count = len(shapes)

    glyf, loca, hmtx = b'', [0], b''
    boxes = []
    most_points = most_contours = 0
    for contours, advance in shapes:
        record = glyph_record(contours)
        glyf += record
        loca.append(len(glyf))
        points = [p for c in contours for p in c]
        left = min((p[0] for p in points), default=0)
        hmtx += struct.pack('>Hh', advance, left)
        if points:
            boxes.append((left, min(p[1] for p in points), max(p[0] for p in points), max(p[1] for p in points), advance))
            most_points = max(most_points, len(points))
            most_contours = max(most_contours, len(contours))
    x_min, y_min = min(b[0] for b in boxes), min(b[1] for b in boxes)
    x_max, y_max = max(b[2] for b in boxes), max(b[3] for b in boxes)
    widest = max(advance for _, advance in shapes)

    # ---- which letter is which glyph: runs of neighbouring codes
    glyph_of = {code: i for i, code in enumerate(order) if code is not None}
    runs = []
    for code in sorted(glyph_of):
        if runs and code == runs[-1][1] + 1 and glyph_of[code] == glyph_of[runs[-1][1]] + 1:
            runs[-1][1] = code
        else:
            runs.append([code, code])
    segs = [(a, b, (glyph_of[a] - a) & 0xFFFF) for a, b in runs] + [(0xFFFF, 0xFFFF, 1)]
    n = len(segs)
    power = 2 ** int(math.log2(n))
    sub = struct.pack('>HHHHHHH', 4, 16 + 8 * n, 0, 2 * n, 2 * power, int(math.log2(n)), 2 * n - 2 * power)
    sub += b''.join(struct.pack('>H', b) for _, b, _ in segs) + struct.pack('>H', 0)
    sub += b''.join(struct.pack('>H', a) for a, _, _ in segs)
    sub += b''.join(struct.pack('>H', d) for _, _, d in segs)
    sub += b''.join(struct.pack('>H', 0) for _ in segs)
    cmap = struct.pack('>HH', 0, 2) + struct.pack('>HHI', 0, 3, 20) + struct.pack('>HHI', 3, 1, 20) + sub

    # ---- names
    names = {1: 'Burnbot Pixel', 2: 'Regular', 3: 'Burnbot Pixel 1.0', 4: 'Burnbot Pixel', 5: 'Version 1.0', 6: 'BurnbotPixel'}
    strings, records = b'', b''
    for name_id, text in sorted(names.items()):
        raw = text.encode('utf-16-be')
        records += struct.pack('>6H', 3, 1, 0x409, name_id, len(raw), len(strings))
        strings += raw
    name = struct.pack('>HHH', 0, len(names), 6 + 12 * len(names)) + records + strings

    stamp = 3_900_000_000        # a fixed date, so the same letters always give the same file
    head = struct.pack('>HHiIIHHqq4hHHhhh', 1, 0, 0x00010000, 0, 0x5F0F3CF5, 0x000B, EM, stamp, stamp,
                       x_min, y_min, x_max, y_max, 0, 8, 2, 1, 0)
    hhea = struct.pack('>i3hH3h3h4hhH', 0x00010000, 8 * PX, -2 * PX, 0, widest, x_min,
                       min(b[4] - b[2] for b in boxes), x_max, 1, 0, 0, 0, 0, 0, 0, 0, count)
    maxp = struct.pack('>iH13H', 0x00010000, count, most_points, most_contours, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0)
    average = round(sum(advance for _, advance in shapes) / count)
    os2 = struct.pack('>HhHHH', 4, average, 400, 5, 0)
    os2 += struct.pack('>10h', 6 * PX, 6 * PX, 0, PX, 6 * PX, 6 * PX, 0, 4 * PX, PX, 3 * PX)
    os2 += struct.pack('>h', 0) + bytes(10) + struct.pack('>4I', 1, 0, 0, 0) + b'BRNB'
    os2 += struct.pack('>HHH', 0x00C0, 0x20, max(c for c in glyph_of if c <= 0xFFFF))
    os2 += struct.pack('>hhhHH', 8 * PX, -2 * PX, 0, 8 * PX, 2 * PX)
    os2 += struct.pack('>II', 1, 0) + struct.pack('>hhHHH', 5 * PX, 7 * PX, 0, 0x20, 0)
    post = struct.pack('>iihhIIIII', 0x00030000, 0, -PX, PX, 0, 0, 0, 0, 0)

    tables = {'OS/2': os2, 'cmap': cmap, 'glyf': glyf, 'head': head, 'hhea': hhea, 'hmtx': hmtx,
              'loca': b''.join(struct.pack('>I', o) for o in loca), 'maxp': maxp, 'name': name, 'post': post}
    tags = sorted(tables)
    power = 2 ** int(math.log2(len(tags)))
    font = struct.pack('>IHHHH', 0x00010000, len(tags), 16 * power, int(math.log2(len(tags))), 16 * len(tags) - 16 * power)
    offset = 12 + 16 * len(tags)
    body = b''
    head_at = 0
    for tag in tags:
        data = tables[tag]
        if tag == 'head':
            head_at = offset
        font += struct.pack('>4sIII', tag.encode(), checksum(data), offset, len(data))
        padded = data + b'\0' * (-len(data) % 4)
        body += padded
        offset += len(padded)
    font += body
    adjust = (0xB1B0AFBA - checksum(font)) & 0xFFFFFFFF
    return font[:head_at + 8] + struct.pack('>I', adjust) + font[head_at + 12:], count


if __name__ == '__main__':
    font, count = build()
    here = os.path.dirname(os.path.abspath(__file__))
    target = os.path.join(here, '..', 'public', 'pixel.css')
    with open(target, 'w') as f:
        f.write('/* Burnbot Pixel: the project\'s own pixel letters as a font. Made by tools/make-font.py; edit the letters there. */\n')
        f.write('@font-face { font-family: "Burnbot Pixel"; font-display: block; src: url(data:font/ttf;base64,%s) format("truetype"); }\n'
                % base64.b64encode(font).decode())
    print('Burnbot Pixel: %d glyphs, %d bytes, written to public/pixel.css' % (count, len(font)))
