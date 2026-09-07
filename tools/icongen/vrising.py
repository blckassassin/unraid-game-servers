#!/usr/bin/env python3
"""Generate the V Rising icon: a blood moon over a black castle silhouette.

Same 32x32 pixel-art approach as build.py, whose writers (and background plate
/ blend helpers) we reuse directly.
Outputs v-rising.png (256x256) and v-rising.svg at the repo root.

Usage:  python3 tools/icongen/vrising.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from build import ROOT, S, blend, in_background, write_png, write_svg  # noqa: E402

# ---------------------------------------------------------------------------
# Palette. Night sky, so the light source is the moon itself rather than
# build.py's top-left convention: the castle reads as a flat silhouette and
# takes no shading at all.
# ---------------------------------------------------------------------------
SKY_TOP   = (0x1a, 0x10, 0x2b)
SKY_BOT   = (0x4a, 0x18, 0x2a)

MOON_LIT  = (0xff, 0x8a, 0x7a)
MOON      = (0xd6, 0x2f, 0x2f)
MOON_DARK = (0x8f, 0x1b, 0x24)

CASTLE    = (0x14, 0x0b, 0x18)

MOON_CX, MOON_CY, MOON_R = 20, 11, 7
SKYLINE_Y = 22          # where the castle silhouette starts
TOWER_XS = (4, 15, 26)  # tower centres; each is 5 wide with battlements
TOWER_TOP = 15


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

    # --- blood moon: lit at the upper left of its own disc ------------------
    for dy in range(-MOON_R, MOON_R + 1):
        for dx in range(-MOON_R, MOON_R + 1):
            if dx * dx + dy * dy > MOON_R * MOON_R:
                continue
            x, y = MOON_CX + dx, MOON_CY + dy
            if not in_background(x, y):
                continue
            t = (dx + dy + MOON_R) / (2 * MOON_R)
            put(x, y, blend(MOON_LIT, MOON_DARK, min(1.0, max(0.0, t))))
    put(MOON_CX - 3, MOON_CY - 2, MOON_LIT)
    put(MOON_CX - 2, MOON_CY - 3, MOON)

    # --- castle: one flat silhouette, walls plus battlemented towers --------
    # Worked out as a mask and painted once. Cutting the battlement notches by
    # repainting sky over them instead would also repaint the moon, which sits
    # behind the towers at exactly that height - a red drip under the moon.
    def is_castle(x, y):
        if y >= SKYLINE_Y:
            return True
        for cx in TOWER_XS:
            if cx - 2 <= x <= cx + 2 and TOWER_TOP <= y < SKYLINE_Y:
                # Two notches in each tower's crown.
                return not (y == TOWER_TOP and x in (cx - 1, cx + 1))
        return False

    for x in range(S):
        for y in range(S):
            if is_castle(x, y) and in_background(x, y):
                put(x, y, CASTLE)

    return g


def main():
    grid = build_grid()
    png = write_png(grid, os.path.join(ROOT, "v-rising.png"))
    svg = write_svg(grid, os.path.join(ROOT, "v-rising.svg"),
                    label="Blood moon over a black castle silhouette")
    print(f"  wrote {os.path.relpath(png, ROOT)}")
    print(f"  wrote {os.path.relpath(svg, ROOT)}")


if __name__ == "__main__":
    main()
