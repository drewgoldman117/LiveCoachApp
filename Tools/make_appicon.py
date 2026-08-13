#!/usr/bin/env python3
"""Render the app icon: the court in perspective with the bisector beam.

The mark is the product's actual signal rather than a generic tennis ball - the
shot-cone bisector, the line the opponent should be standing on, glowing on a
dark court. Nothing else on a home screen looks like it.

Drawn in code (not exported from a design tool) so it can be re-rendered at any
size, and so every constant here is inspectable and tweakable. Requires Pillow
+ numpy; the tennis-beeper Python venv already has both:

    source ../tennis-beeper/venv/bin/activate
    python Tools/make_appicon.py

Writes Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png. iOS applies the
rounded-rect mask itself, so this is a full-bleed square with no alpha and no
content near the corners.
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

OUT = (Path(__file__).resolve().parent.parent
       / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png")

SIZE = 1024
SS = 4                      # supersample factor - draw big, downsample for clean edges
S = SIZE * SS

# Palette - the same tokens as DesignSystem.swift.
NAVY_TOP = (8, 12, 20)
NAVY_BOTTOM = (14, 26, 44)
ACCENT = (216, 255, 62)     # DS.Color.accent
LINE = (255, 255, 255)

# Court geometry in meters (mirrors Court.swift; only the lines that survive at
# 40px are drawn - the full line set turns to mush).
LENGTH_M, HALF_WIDTH_M = 23.77, 4.115
NET_Y = LENGTH_M / 2
FAR_SERVICE_Y = NET_Y + 6.40

# Perspective. Same projective form as CourtDiagram.swift: one term drives both
# the width scale and the depth position, so the trapezoid stays consistent.
# The court is kept well inside the frame: iOS masks the icon to a squircle, so
# anything out at the corners gets cut, and a first render with a full-bleed
# court lost both near-baseline corners to the mask.
K = 1.5
NEAR_HALF_SPAN = 0.355 * S   # half-width of the near baseline on canvas
TOP = 0.295 * S              # y of the far baseline
BOTTOM = 0.795 * S           # y of the near baseline


def project(x_m, y_m):
    t = y_m / LENGTH_M
    s = 1.0 / (1.0 + K * t)
    f = t * (1.0 + K) * s
    return (S / 2 + (x_m / HALF_WIDTH_M) * NEAR_HALF_SPAN * s,
            BOTTOM - f * (BOTTOM - TOP))


def background():
    """Vertical navy gradient with a soft glow rising off the court."""
    top = np.array(NAVY_TOP, dtype=float)
    bottom = np.array(NAVY_BOTTOM, dtype=float)
    ramp = np.linspace(0, 1, S)[:, None]
    img = (top[None, None, :] * (1 - ramp[..., None]) +
           bottom[None, None, :] * ramp[..., None])
    img = np.repeat(img, S, axis=1)
    return Image.fromarray(img.astype(np.uint8), "RGB")


def add_glow(base, layer, blur, gain=1.0):
    """Screen-composite a blurred copy of `layer` onto `base` - light adds,
    rather than painting over, which is what makes the beam read as emitting."""
    glow = layer.filter(ImageFilter.GaussianBlur(blur))
    if gain != 1.0:
        glow = Image.eval(glow, lambda v: min(255, int(v * gain)))
    return ImageChops.screen(base, glow)


def main():
    img = background()

    # --- court surface: a shade lighter than the field, so the shape reads
    # even before any line does ---
    surface = Image.new("RGB", (S, S), (0, 0, 0))
    d = ImageDraw.Draw(surface)
    quad = [project(-HALF_WIDTH_M, 0), project(HALF_WIDTH_M, 0),
            project(HALF_WIDTH_M, LENGTH_M), project(-HALF_WIDTH_M, LENGTH_M)]
    d.polygon(quad, fill=(17, 31, 52))
    img = ImageChops.screen(img, surface)

    # --- court lines. Only outline + net + far service line: at 40px anything
    # more collapses into gray. Line weight tapers with depth. ---
    lines = Image.new("RGB", (S, S), (0, 0, 0))
    d = ImageDraw.Draw(lines)
    w_near, w_far = int(0.012 * S), int(0.007 * S)
    d.line(quad + [quad[0]], fill=LINE, width=w_near, joint="curve")
    d.line([project(-HALF_WIDTH_M, FAR_SERVICE_Y), project(HALF_WIDTH_M, FAR_SERVICE_Y)],
           fill=tuple(int(c * 0.5) for c in LINE), width=w_far)
    img = ImageChops.screen(img, Image.eval(lines, lambda v: int(v * 0.78)))

    # --- the net: the heaviest line, and the thing the ball must clear ---
    net = Image.new("RGB", (S, S), (0, 0, 0))
    d = ImageDraw.Draw(net)
    d.line([project(-HALF_WIDTH_M - 0.55, NET_Y), project(HALF_WIDTH_M + 0.55, NET_Y)],
           fill=LINE, width=int(0.014 * S))
    img = ImageChops.screen(img, Image.eval(net, lambda v: int(v * 0.85)))

    # --- the bisector beam: apex near the left of your baseline, running deep
    # cross-court, exactly as the diagram on the home screen draws it ---
    # The node sits INSIDE the far court, not on the baseline: on the line it
    # read as a ball sitting on the paint rather than a position in the court.
    apex = project(-2.7, 1.1)
    far = project(1.5, LENGTH_M - 2.6)

    beam = Image.new("RGB", (S, S), (0, 0, 0))
    d = ImageDraw.Draw(beam)
    d.line([apex, far], fill=ACCENT, width=int(0.022 * S))
    img = add_glow(img, beam, blur=0.045 * S, gain=1.25)     # wide halo
    img = add_glow(img, beam, blur=0.012 * S, gain=1.0)      # tight halo
    img = ImageChops.screen(img, beam)                       # crisp core

    # --- the target: a bright node where the opponent should be standing ---
    node = Image.new("RGB", (S, S), (0, 0, 0))
    d = ImageDraw.Draw(node)
    r = int(0.052 * S)
    d.ellipse([far[0] - r, far[1] - r, far[0] + r, far[1] + r], fill=ACCENT)
    img = add_glow(img, node, blur=0.05 * S, gain=1.4)
    img = ImageChops.screen(img, node)
    # White-hot center keeps the node from reading as a flat dot at small sizes.
    core = Image.new("RGB", (S, S), (0, 0, 0))
    d = ImageDraw.Draw(core)
    rc = int(r * 0.42)
    d.ellipse([far[0] - rc, far[1] - rc, far[0] + rc, far[1] + rc], fill=(255, 255, 255))
    img = ImageChops.screen(img, core)

    # --- the striker: a small solid dot at the apex, the counterweight ---
    striker = Image.new("RGB", (S, S), (0, 0, 0))
    d = ImageDraw.Draw(striker)
    rs = int(0.026 * S)
    d.ellipse([apex[0] - rs, apex[1] - rs, apex[0] + rs, apex[1] + rs], fill=ACCENT)
    img = add_glow(img, striker, blur=0.02 * S, gain=1.1)
    img = ImageChops.screen(img, striker)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB").save(OUT)
    print(f"wrote {OUT} ({SIZE}x{SIZE}, opaque RGB)")


if __name__ == "__main__":
    main()
