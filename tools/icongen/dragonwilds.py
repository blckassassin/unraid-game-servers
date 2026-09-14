#!/usr/bin/env python3
"""Generate the RuneScape: Dragonwilds icon: a green dragon head over a
RuneScape-gold horizon.

Same 32x32 pixel-art approach as build.py, whose writers (and background plate
/ blend helpers) we reuse directly.
Outputs dragonwilds.png (256x256) and dragonwilds.svg at the repo root.

Usage:  python3 tools/icongen/dragonwilds.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from build import ROOT, S, blend, in_background, write_png, write_svg  # noqa: E402

# ---------------------------------------------------------------------------
# Palette. Dusk sky over a gold horizon band, with the dragon as a silhouette
# lit from the top left the way build.py's convention wants. Green scales and
# gold are the two colours the game's own art leans on hardest, which is what
# makes this readable at 16px next to the other three icons.
# ---------------------------------------------------------------------------
SKY_TOP   = (0x14, 0x22, 0x2c)
SKY_BOT   = (0x2c, 0x44, 0x3a)

GOLD_LIT  = (0xff, 0xd9, 0x6b)
GOLD      = (0xd9, 0xa0, 0x2e)

SCALE_LIT = (0x7a, 0xd6, 0x6b)
SCALE     = (0x4f, 0xa3, 0x4c)
SCALE_DK  = (0x2c, 0x6b, 0x33)
HORN      = (0xe8, 0xdc, 0xbe)
EYE       = (0xff, 0x6b, 0x2e)

HORIZON_Y = 25          # top of the gold band


# ---------------------------------------------------------------------------
# The head, in profile facing right, as explicit inclusive x spans per row.
#
# Written out rather than computed because the shape has to survive being seen
# at 16px in a Community Applications list, and the two cues that carry it there
# are the open jaw and the swept-back horns. Both are a handful of pixels; a
# formula that "looks about right" at 256px loses them. Read top to bottom:
# skull, brow, snout tapering right, then the mouth gap, then the lower jaw, then
# the neck running off the bottom of the tile.
# ---------------------------------------------------------------------------
SKULL = [
    (8,   9, 16),
    (9,   7, 17),
    (10,  6, 19),
    (11,  6, 24),   # brow, and the upper snout begins
    (12,  6, 26),   # snout tip
    (13,  6, 25),   # underside of the upper jaw
]
JAW = [
    (14,  6, 18),   # the gap from 19 rightwards is the open mouth
    (15,  6, 23),   # lower jaw, reaching back out under the gap
    (16,  6, 20),
    (17,  7, 17),
]
NECK = [
    (18,  8, 15),
    (19,  8, 15),
    (20,  9, 15),
    (21,  9, 16),
    (22, 10, 16),
    (23, 10, 17),
    (24, 11, 17),
]

# Two horns sweeping up and back off the skull, which is what stops the
# silhouette reading as a lizard. Solid bands rather than single-pixel diagonals:
# a one-pixel horn survives neither the 16px downscale nor the eye, where it
# reads as an antenna rather than as part of the animal.
HORNS = [
    (7,   7, 11),
    (6,   5,  9),
    (5,   4,  7),
    (4,   3,  5),
    (7,  13, 15),
    (6,  12, 14),
    (5,  12, 13),
]

EYE_X, EYE_Y = 13, 11


def build_grid():
    """Return a 32x32 grid of RGBA tuples (alpha 0 = transparent)."""
    g = [[(0, 0, 0, 0) for _ in range(S)] for _ in range(S)]

    def put(x, y, rgb, a=255):
        if 0 <= x < S and 0 <= y < S:
            g[y][x] = (rgb[0], rgb[1], rgb[2], a)

    # --- sky: vertical gradient inside the same rounded plate ---------------
    for y in range(S):
        row = blend(SKY_TOP, SKY_BOT, y / (S - 1))
        for x in range(S):
            if in_background(x, y):
                put(x, y, row)

    # --- gold horizon band, brightest at its top edge -----------------------
    for y in range(HORIZON_Y, S):
        t = (y - HORIZON_Y) / max(1, (S - 1 - HORIZON_Y))
        row = blend(GOLD_LIT, GOLD, t)
        for x in range(S):
            if in_background(x, y):
                put(x, y, row)

    # --- the head ------------------------------------------------------------
    # Painted from a mask rather than cut out of the sky afterwards, for the same
    # reason vrising.py does it that way: repainting background over the mouth
    # notch would repaint whatever sits behind it, and here that is the gold band.
    head = set()
    for y, x0, x1 in SKULL + JAW + NECK:
        for x in range(x0, x1 + 1):
            head.add((x, y))

    for (x, y) in sorted(head):
        if not in_background(x, y):
            continue
        # Light from the top left, ramped across the head's own bounding box
        # rather than the whole tile, so the full range of the ramp gets used.
        t = ((x - 4) / 22.0) * 0.5 + ((y - 8) / 16.0) * 0.5
        put(x, y, blend(SCALE_LIT, SCALE_DK, min(1.0, max(0.0, t))))

    # A mid-tone ridge along the top of the snout: at 16px the head needs one
    # internal line or it flattens into a single shape.
    for x in range(9, 25):
        y = 10 + (x - 9) // 8
        if (x, y) in head and in_background(x, y):
            put(x, y, SCALE)

    # The underside of the upper jaw, darkened so the open mouth reads as depth
    # rather than as a chip out of the silhouette.
    for x in range(16, 27):
        if (x, 13) in head and in_background(x, 13):
            put(x, 13, SCALE_DK)
    # Nostril, at the end of the snout.
    if in_background(24, 12):
        put(24, 12, SCALE_DK)

    for y, x0, x1 in HORNS:
        for x in range(x0, x1 + 1):
            if in_background(x, y):
                put(x, y, HORN)

    put(EYE_X, EYE_Y, EYE)

    return g


def main():
    grid = build_grid()
    png = write_png(grid, os.path.join(ROOT, "dragonwilds.png"))
    svg = write_svg(grid, os.path.join(ROOT, "dragonwilds.svg"),
                    label="Green dragon head over a gold horizon")
    print(f"  wrote {os.path.relpath(png, ROOT)}")
    print(f"  wrote {os.path.relpath(svg, ROOT)}")


if __name__ == "__main__":
    main()
