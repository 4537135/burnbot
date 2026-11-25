#!/usr/bin/env python3
"""Turnaround sheet for Burnbot at "Locked in" (level 4 of 5), for image-to-3D tools.

The app only ever draws the robot face-on (public/robot.js, drawRobot). This builds the same
robot as voxels, one canvas pixel to one voxel, using drawRobot's own measurements for a still
frame (t with no blink, no bob), and gives it depth. Then it renders it from every side with the
same scale and centre, so the views line up.

  python3 tools/turnaround.py [out_dir]       default: shots/turnaround/locked-in
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

OUT = sys.argv[1] if len(sys.argv) > 1 else 'shots/turnaround/locked-in'
SIZE = 1024
SS = 2  # supersampling

# ---- colours (robot.js) ----
def hexrgb(h):
    n = int(h[1:], 16)
    return (n >> 16, (n >> 8) & 255, n & 255)

ACCENT = hexrgb('#ff8030')
GLOW = tuple(round(c + (255 - c) * 0.45) for c in ACCENT)  # lighten(accent, 0.45)
SCREEN = hexrgb('#0e131b')
EYEHALO = tuple(round(s + (a - s) * 0.3) for s, a in zip(SCREEN, ACCENT))  # glowBox at 0.3
MAT = {
    1: (hexrgb('#a3b0c2'), False),  # body
    2: (hexrgb('#d2dae5'), False),  # hi (hands, rims)
    3: (hexrgb('#75839a'), False),  # sh (arms, legs, neck, antenna, bolts)
    4: (hexrgb('#4d586b'), False),  # dark (feet, back vents)
    5: (SCREEN, True),
    6: (ACCENT, True),
    7: (GLOW, True),
    8: (EYEHALO, True),
    9: (hexrgb('#232a36'), False),  # headphone band
    10: (hexrgb('#303a49'), False),  # headphone cups
}

# ---- voxel grid: x across (robot's right is +x on screen), Y up from the ground, z toward the viewer ----
X0, Y0, Z0 = -26, 0, -16
grid = np.zeros((52, 60, 32), dtype=np.uint8)

def box(x, ysc, w, h, z, d, m):
    """drawRobot's R(x, y, w, h) with screen y (down, ground at 0), given depth z..z+d."""
    grid[x - X0:x + w - X0, -(ysc + h) - Y0:-ysc - Y0, z - Z0:z + d - Z0] = m

def chamfer(x, ysc, w, h, z, d, m):
    """A box with its twelve edges shaved off, like the 2D head's clipped corners."""
    for i in range(w):
        for j in range(h):
            for k in range(d):
                edges = (i in (0, w - 1)) + (j in (0, h - 1)) + (k in (0, d - 1))
                if edges < 2:
                    grid[x + i - X0, -(ysc + j) - 1 - Y0, z + k - Z0] = m

def face(x, ysc, w, h, zlayer, m):
    """Paint on the front layer zlayer (one voxel deep)."""
    box(x, ysc, w, h, zlayer, 1, m)

gy, hw, hh, b = 0, 16, 22, 4
hy = gy - 21 - hh                    # -43, top of the head
boltY = hy + round(hh / 2) - 3       # -35
cup = boltY - 2                      # -37

# legs and feet (feet reach forward)
box(-9, -5, 5, 5, -3, 6, 3)
box(4, -5, 5, 5, -3, 6, 3)
chamfer(-10, -2, 7, 2, -4, 9, 4)
chamfer(3, -2, 7, 2, -4, 9, 4)

# arms resting at the sides (the still pose; while working they tap at a keyboard)
for x in (-15, 11):
    box(x, -18, 4, 9, -2, 4, 3)
    box(x, -9, 4, 3, -2, 4, 2)

# body, with the chest screen sunk one voxel and its three level lights
chamfer(-11, -19, 22, 14, -6, 12, 1)
box(-11, -19, 22, 1, -5, 10, 2)                  # light top rim
box(-6, -16, 12, 7, 5, 1, 0)                      # recess
box(-6, -16, 12, 7, 4, 1, 5)
for k, h in enumerate((3, 4, 3)):
    face(-5 + k * 4, -10 - h, 2, h, 4, 6)
# back: a hatch with three vents
box(-6, -16, 12, 9, -7, 1, 3)
for r in range(3):
    box(-4, -15 + r * 3, 8, 1, -7, 1, 4)

# neck
box(-3, gy - 21, 6, 2, -3, 6, 3)

# head: a rounded box with the screen sunk into its face
chamfer(-hw, hy, 2 * hw, hh, -10, 20, 1)
box(-hw + 1, hy, 2 * hw - 2, 1, -9, 18, 2)        # light top rim
sx, sy, sw, sH = -hw + b, hy + b, 2 * hw - 2 * b, hh - b - 5
for (x, y, w, h) in ((sx + 1, sy, sw - 2, sH), (sx, sy + 1, sw, sH - 2)):
    box(x, y, w, h, 9, 1, 0)
    box(x, y, w, h, 8, 1, 5)
# eyes: the focused, slanted look
ey, lx = hy + 7, -8
rx = lx + 12
for ex in (lx, rx):
    face(ex - 1, ey, 6, 5, 8, 8)
    face(ex, ey + 1, 4, 3, 8, 7)
face(lx + 3, ey + 1, 1, 1, 8, 8)
face(rx, ey + 1, 1, 1, 8, 8)
face(-3, ey + 7, 6, 1, 8, 7)                      # mouth: a flat, determined line
# back of the head: a vent grille
for r in range(4):
    box(-8, hy + 6 + r * 3, 16, 1, -10, 1, 4)
# ear bolts (under the headphones, they show at the back)
box(-hw - 2, boltY, 2, 6, -3, 6, 3)
box(hw, boltY, 2, 6, -3, 6, 3)

# antenna with its lit bulb
box(-1, hy - 5, 2, 5, -1, 2, 3)
chamfer(-2, hy - 9, 4, 4, -2, 4, 6)

# headphones: band over the top, down the sides, a cup over each ear with a light
box(-hw - 1, hy - 2, 2 * hw + 2, 2, -2, 4, 9)
box(-hw - 2, hy - 1, 2, cup - hy + 2, -2, 4, 9)
box(hw, hy - 1, 2, cup - hy + 2, -2, 4, 9)
for x in (-hw - 4, hw):
    chamfer(x, cup, 4, 11, -5, 10, 10)
    outer = x if x < 0 else x + 3
    face(outer, cup + 4, 1, 3, -1, 6)               # the light, on the cup's outer face
    box(outer, cup + 4, 1, 3, -2, 3, 6)

# ---- render ----
NORMALS = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]
CORNERS = {}
for n in NORMALS:
    ax = [i for i in range(3) if n[i] != 0][0]
    s = n[ax]
    u, v = [i for i in range(3) if i != ax]
    pts = []
    for a, bb in ((0, 0), (1, 0), (1, 1), (0, 1)):
        p = [0, 0, 0]
        p[ax] = 1 if s > 0 else 0
        p[u], p[v] = a, bb
        pts.append(p)
    CORNERS[n] = np.array(pts, dtype=float)

filled = np.argwhere(grid > 0)
quads = []  # (corners (4,3) world, normal, material)
for (i, j, k) in filled:
    m = grid[i, j, k]
    for n in NORMALS:
        ni, nj, nk = i + n[0], j + n[1], k + n[2]
        inside = 0 <= ni < grid.shape[0] and 0 <= nj < grid.shape[1] and 0 <= nk < grid.shape[2]
        if inside and grid[ni, nj, nk] > 0:
            continue
        base = np.array([i + X0, j + Y0, k + Z0], dtype=float)
        quads.append((CORNERS[n] + base, np.array(n, dtype=float), m))
corners = np.stack([q[0] for q in quads])
norms = np.stack([q[1] for q in quads])
mats = np.array([q[2] for q in quads])

lo = corners.reshape(-1, 3).min(0)
hi_ = corners.reshape(-1, 3).max(0)
centre = np.array([0.0, (lo[1] + hi_[1]) / 2, 0.0])
SCALE = SIZE * 0.84 / (hi_[1] - lo[1] + 2)  # same scale in every view


def render(yaw_deg, pitch_deg, path):
    yw, p = math.radians(yaw_deg), math.radians(pitch_deg)
    d = np.array([math.sin(yw) * math.cos(p), math.sin(p), math.cos(yw) * math.cos(p)])  # toward camera
    up = np.array([-math.sin(yw) * math.sin(p), math.cos(p), -math.cos(yw) * math.sin(p)])
    right = np.cross(up, d)
    # light rides with the camera, so every side is lit the same: from above, a little to the left
    L = 0.75 * d + 0.55 * up - 0.3 * right
    L /= np.linalg.norm(L)
    facing = norms @ d > 1e-6
    rel = corners[facing] - centre
    depth = (rel.mean(1) @ d)
    order = np.argsort(depth)
    sxy = np.stack([rel @ right, rel @ up], -1)[order]
    nn = norms[facing][order]
    mm = mats[facing][order]
    W = SIZE * SS
    img = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    dr = ImageDraw.Draw(img)
    for q, n, m in zip(sxy, nn, mm):
        col, emissive = MAT[m]
        if emissive:
            shade = 1.0 if n @ d > 0.5 else 0.82
        else:
            shade = 0.5 + 0.55 * max(0.0, float(n @ L))
        c = tuple(min(255, round(v * shade)) for v in col) + (255,)
        pts = [(W / 2 + x * SCALE * SS, W / 2 - y * SCALE * SS) for x, y in q]
        dr.polygon(pts, fill=c, outline=c)
    img = img.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    img.save(path)
    return img


VIEWS = [
    ('01-front', 0, 0),
    ('02-front-right', 45, 0),
    ('03-right', 90, 0),
    ('04-back-right', 135, 0),
    ('05-back', 180, 0),
    ('06-back-left', 225, 0),
    ('07-left', 270, 0),
    ('08-front-left', 315, 0),
    ('09-top', 0, 89.9),
    ('10-hero-three-quarter', 35, 20),
]

if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    shots = []
    for name, yw, p in VIEWS:
        shots.append((name, render(yw, p, os.path.join(OUT, name + '.png'))))
    # white-background copies, for tools that do not take transparency
    wdir = os.path.join(OUT, 'white-bg')
    os.makedirs(wdir, exist_ok=True)
    for name, im in shots:
        bg = Image.new('RGB', im.size, (255, 255, 255))
        bg.paste(im, mask=im.split()[3])
        bg.save(os.path.join(wdir, name + '.png'))
    # contact sheet
    cell = 384
    sheet = Image.new('RGB', (cell * 5, cell * 2), (236, 238, 242))
    sd = ImageDraw.Draw(sheet)
    for idx, (name, im) in enumerate(shots):
        x, y = (idx % 5) * cell, (idx // 5) * cell
        sheet.paste(im.resize((cell, cell), Image.Resampling.LANCZOS), (x, y), im.resize((cell, cell), Image.Resampling.LANCZOS))
        sd.text((x + 10, y + 8), name, fill=(60, 66, 80))
    sheet.save(os.path.join(OUT, '00-sheet.png'))
    print(f'{len(quads)} faces; wrote {len(shots)} views to {OUT}')
