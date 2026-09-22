#!/usr/bin/env python3
"""Generate the Valheim icon: a round Viking shield with an iron rim and boss.

Same 32x32 pixel-art approach as build.py, whose writers (and background plate
/ blend helpers) we reuse directly.
Outputs valheim.png (256x256) and valheim.svg at the repo root.

Picked over the other two obvious Valheim subjects on silhouette alone, since
that is all 16px leaves you. A longship prow is a spiral, and a spiral at 16px
is a smudge. A runestone is an upright slab, which is exactly what the repo
icon's obelisk already is. The shield is the only concentric, radially
symmetric shape in the set: at 16px it reads as a pale disc with a hard ring
and a dot in the middle. Nothing else here is centred or round at that size -
v-rising's moon is a small disc pushed to the top right of a near-black tile,
and terraria's canopy is a green blob left of centre under a bright sky.

Usage:  python3 tools/icongen/valheim.py

Light source is top-left, same convention as build.py.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from build import ROOT, S, blend, in_background, write_png, write_svg  # noqa: E402

# ---------------------------------------------------------------------------
# Palette. Weathered pine over cold iron on an overcast slate plate. The other
# four icons are all dark tiles with a warm accent - navy and red, dusk green
# and gold, purple-black and red, blue sky and green - so this one inverts
# that: most of the tile is a single pale warm mass. That, and not any of the
# detail, is what picks it out of a Community Applications list at 16px. The
# wood is pulled toward grey on purpose so it does not read as dragonwilds'
# gold band, and the rim stays cool grey so the disc's edge keeps a hard
# boundary against the slate behind it.
# ---------------------------------------------------------------------------
SKY_TOP   = (0x2a, 0x3b, 0x4a)
SKY_BOT   = (0x13, 0x1d, 0x27)

WOOD_LIT  = (0xd8, 0xbd, 0x92)
WOOD_DK   = (0x7e, 0x63, 0x42)
SEAM      = (0x59, 0x43, 0x2d)

IRON_LIT  = (0xd6, 0xde, 0xe6)
IRON_DK   = (0x46, 0x51, 0x5e)

# ---------------------------------------------------------------------------
# Geometry
#
# Centred on a half-pixel so the disc comes out symmetric: an integer centre on
# an even grid puts one more column on one side than the other, and at 16px a
# lopsided circle reads as a mistake rather than as a shield.
# ---------------------------------------------------------------------------
CX = CY = 15.5
R_OUTER = 12.5   # shield edge; leaves a 3px margin on every side of the plate
R_FACE = 10.8    # inside edge of the iron rim, so the rim is ~2px thick
R_BOSS = 2.9     # iron boss over the hand grip, ~6px across

PLANK_XS = (9, 22)   # seams between the three boards, symmetric about CX


def build_grid():
    """Return a 32x32 grid of RGBA tuples (alpha 0 = transparent)."""
    g = [[(0, 0, 0, 0) for _ in range(S)] for _ in range(S)]

    def put(x, y, rgb, a=255):
        if 0 <= x < S and 0 <= y < S:
            g[y][x] = (rgb[0], rgb[1], rgb[2], a)

    def lit(dx, dy, r, a, b):
        """Blend a to b across the shape, light arriving from the top left."""
        return blend(a, b, min(1.0, max(0.0, (dx + dy + r) / (2 * r))))

    # --- overcast sky, same rounded plate as build.py -----------------------
    for y in range(S):
        row = blend(SKY_TOP, SKY_BOT, y / (S - 1))
        for x in range(S):
            if in_background(x, y):
                put(x, y, row)

    # --- the shield, painted outward-in so each ring overwrites the last ----
    for y in range(S):
        for x in range(S):
            if not in_background(x, y):
                continue
            dx, dy = x - CX, y - CY
            d = (dx * dx + dy * dy) ** 0.5
            if d > R_OUTER:
                continue
            if d > R_FACE:
                put(x, y, lit(dx, dy, R_OUTER, IRON_LIT, IRON_DK))
            elif d > R_FACE - 1.0:
                # The board edge sitting in the rim's shadow. Without it the
                # face and the rim's lit side run together at the top left,
                # and the concentric read - the whole point of this shape -
                # is gone at 16px.
                put(x, y, blend(lit(dx, dy, R_FACE, WOOD_LIT, WOOD_DK), SEAM, 0.55))
            elif d > R_BOSS:
                c = lit(dx, dy, R_FACE, WOOD_LIT, WOOD_DK)
                put(x, y, blend(c, SEAM, 0.7) if x in PLANK_XS else c)
            else:
                put(x, y, lit(dx, dy, R_BOSS, IRON_LIT, IRON_DK))

    # Highlight on the upper left of the boss, so the dot in the middle reads
    # as a dome rather than as a hole.
    put(14, 14, IRON_LIT)

    return g


def main():
    grid = build_grid()
    png = write_png(grid, os.path.join(ROOT, "valheim.png"))
    svg = write_svg(grid, os.path.join(ROOT, "valheim.svg"),
                    label="Round Viking shield with an iron rim and boss")
    print(f"  wrote {os.path.relpath(png, ROOT)}")
    print(f"  wrote {os.path.relpath(svg, ROOT)}")


if __name__ == "__main__":
    main()
