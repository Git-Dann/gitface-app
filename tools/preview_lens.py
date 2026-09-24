"""Renders the lens offline, so it can be looked at without a TestFlight round.

This exists because every visual change so far has been a guess. CI proves the
code compiles; it says nothing about whether a warp is too strong or a roller
is the wrong shape, and each guess has cost a build and a test on a real phone.

The warp and skin maths here are a direct port of `facetrkr/Render/Shaders.metal`,
and the anchor positions are a direct port of `session(_:didUpdate frame:)` in
`facetrkr/AR/FaceSessionCoordinator.swift`. When either changes, change both, or
this stops predicting anything.

Two simplifications against the real thing, both safe for a front-on selfie:

* Everything is in pixels rather than normalised UV, so the shader's aspect
  correction is unnecessary — pixel space is already isotropic. This is exactly
  equivalent, and it is why the eye span must be measured in the same space the
  radii are (see the scale bug this project already shipped once).
* Props project orthographically from the face-anchor metres `FaceLandmark`
  uses, scaled by the measured eye separation. A real camera is perspective, so
  expect a little difference at the edges of the head and none in the middle.

Usage:
    python3 tools/preview_lens.py face.jpg --eyes 460,1180 800,1180 -o out.png
"""

import argparse
import math

import numpy as np
from PIL import Image

# MARK: - Lens definition, mirrored from FaceUniforms.swift

MAGNIFY, WIDEN, SQUASH, SWIRL, PULL = 1, 2, 3, 4, 5

# (anchor, kind, radius in eye-spans, weight, direction)
GRANDMA_REGIONS = [
    ("leftCheek", MAGNIFY, 0.85, 0.75, (0, 1)),
    ("rightCheek", MAGNIFY, 0.85, 0.75, (0, 1)),
    ("mouth", WIDEN, 1.00, 0.80, (0, 1)),
    ("leftEye", SQUASH, 0.45, 0.35, (0, 1)),
    ("rightEye", SQUASH, 0.45, 0.35, (0, 1)),
    ("brow", PULL, 0.90, 0.22, (0, 1)),
    ("leftJowl", PULL, 0.70, 0.38, (0, 1)),
    ("rightJowl", PULL, 0.70, 0.38, (0, 1)),
    ("chin", SQUASH, 0.60, 0.30, (0, 1)),
    ("noseTip", MAGNIFY, 0.40, 0.25, (0, 1)),
    ("faceCentre", MAGNIFY, 2.00, 0.12, (0, 1)),
]

SKIN = dict(creases=0.55, ridge=0.45, desaturate=0.22, sallow=0.18,
            blotch=0.28, browGrey=0.70, jawShade=0.30)

HULL_RADIUS = 2.00       # eye-spans
BROW_RADIUS = 0.52
FACE_ASPECT = 1.35       # kFaceAspect
LUMA = np.float32([0.299, 0.587, 0.114])


def anchors(left_eye, right_eye):
    """Screen-space anchors, ported from the coordinator.

    The 3D offsets there are in face-anchor space where +Y is up; screen y grows
    downward, so every vertical offset flips sign on the way here.
    """
    left = np.array(left_eye, np.float64)
    right = np.array(right_eye, np.float64)
    mid = (left + right) / 2
    span = float(np.linalg.norm(left - right))

    def outward(eye):
        v = eye - mid
        n = np.linalg.norm(v)
        return v / n if n > 1e-9 else np.array([0.0, 0.0])

    def offset(x, y):
        return mid + np.array([x, y]) * span

    def cheek(eye):
        return eye + (eye - mid) * 0.22 + np.array([0, 0.58]) * span

    def jowl(eye):
        return mid + outward(eye) * (span * 0.80) + np.array([0, 1.30]) * span

    return {
        "leftEye": left, "rightEye": right,
        "leftCheek": cheek(left), "rightCheek": cheek(right),
        "leftJowl": jowl(left), "rightJowl": jowl(right),
        "mouth": offset(0, 1.15),
        "chin": offset(0, 1.95),
        "noseTip": offset(0, 0.45),
        "brow": offset(0, -0.52),
        "faceCentre": offset(0, 0.40),
        "browLeft": left + np.array([0, -0.42]) * span,
        "browRight": right + np.array([0, -0.42]) * span,
    }, mid, span


# MARK: - The kernel, ported from Shaders.metal

def falloff(distance, radius):
    t = np.clip(1.0 - distance / max(radius, 1e-9), 0.0, 1.0)
    return np.where(distance < radius, t * t, 0.0)


def apply_region(px, py, centre, kind, radius, weight, direction):
    lx = px - centre[0]
    ly = py - centre[1]
    amount = falloff(np.sqrt(lx * lx + ly * ly), radius)
    live = amount > 0

    if kind == MAGNIFY:
        k = 1.0 - weight * amount
        nx, ny = lx * k, ly * k
    elif kind == WIDEN:
        w = weight * amount
        nx, ny = lx / (1.0 + w), ly * (1.0 + w * 0.65)
    elif kind == SQUASH:
        nx, ny = lx, ly * (1.0 + weight * amount)
    elif kind == SWIRL:
        a = weight * amount
        nx, ny = lx * np.cos(a) - ly * np.sin(a), lx * np.sin(a) + ly * np.cos(a)
    elif kind == PULL:
        k = weight * amount * radius
        nx, ny = lx - direction[0] * k, ly - direction[1] * k
    else:
        nx, ny = lx, ly

    return np.where(live, centre[0] + nx, px), np.where(live, centre[1] + ny, py)


def face_hull(px, py, centre, radius):
    lx = px - centre[0]
    ly = (py - centre[1]) / FACE_ASPECT
    d = np.sqrt(lx * lx + ly * ly)
    t = np.clip((d - radius * 0.80) / (radius * 1.20 - radius * 0.80), 0, 1)
    return 1.0 - (t * t * (3 - 2 * t))


def creases(mid, span, anchor):
    """Ported from FaceSessionCoordinator.creases, flattened to screen space."""
    lines = []

    def line(a, b, width, strength):
        lines.append((np.array(a, np.float64), np.array(b, np.float64),
                      width * span, strength))

    def offset(x, y):
        return mid + np.array([x, y]) * span

    for key in ("leftEye", "rightEye"):
        eye = anchor[key]
        out = eye - mid
        out = out / max(np.linalg.norm(out), 1e-9)
        corner = eye + out * (span * 0.42)
        for index, rise in enumerate((-0.18, 0.0, 0.18)):
            length = span * (0.26 - index * 0.03)
            line(corner, corner + out * length + np.array([0, rise]) * span,
                 0.016, 0.75)
        line(eye + np.array([0, 0.34]) * span - out * (span * 0.22),
             eye + np.array([0, 0.30]) * span + out * (span * 0.28), 0.018, 0.60)
        side = out * span
        line(offset(0, 0.70) + side * 0.24, offset(0, 1.22) + side * 0.46, 0.024, 0.90)
        line(offset(0, 1.30) + side * 0.44, offset(0, 1.78) + side * 0.40, 0.020, 0.62)

    for index in range(3):
        height = -(0.62 + index * 0.22)
        width = 0.78 - index * 0.08
        line(offset(-width, height), offset(width, height), 0.019, 0.55 - index * 0.08)
    return lines


def wrinkle_shade(px, py, lines):
    valley = np.zeros_like(px)
    ridge = np.zeros_like(px)
    for start, end, width, strength in lines:
        sx = px - start[0]
        sy = py - start[1]
        ex = end[0] - start[0]
        ey = end[1] - start[1]
        length2 = ex * ex + ey * ey
        if length2 < 1e-10:
            continue
        t = np.clip((sx * ex + sy * ey) / length2, 0, 1)
        ox = sx - ex * t
        oy = sy - ey * t
        d = np.sqrt(ox * ox + oy * oy)

        def smooth(edge, x):
            v = np.clip(x / edge, 0, 1)
            return v * v * (3 - 2 * v)

        taper = smooth(0.22, t) * smooth(0.22, 1 - t)
        s = taper * strength

        f = np.clip(1.0 - d / width, 0, 1)
        valley = np.maximum(valley, np.where(d < width, f * f * s, 0))

        nx, ny = -ey, ex
        n = math.hypot(nx, ny)
        upper = (ox * (nx / n) + oy * (ny / n)) < 0
        rc, rw = width * 1.15, width * 0.85
        rd = np.abs(d - rc)
        fr = np.clip(1.0 - rd / rw, 0, 1)
        ridge = np.maximum(ridge, np.where(upper & (rd < rw), fr * fr * s, 0))
    return valley, ridge


def value_noise(px, py):
    def hash21(ix, iy):
        x = np.modf(ix * 123.34)[0]
        y = np.modf(iy * 456.21)[0]
        d = x * x + y * y + 45.32 * (x + y)
        return np.modf((x + d) * (y + d))[0]

    ix, iy = np.floor(px), np.floor(py)
    fx, fy = px - ix, py - iy
    fx = fx * fx * (3 - 2 * fx)
    fy = fy * fy * (3 - 2 * fy)
    a, b = hash21(ix, iy), hash21(ix + 1, iy)
    c, d = hash21(ix, iy + 1), hash21(ix + 1, iy + 1)
    return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy


def render(image, left_eye, right_eye, regions, skin, scale_skin=1.0):
    src = np.asarray(image.convert("RGB"), np.float32) / 255.0
    h, w, _ = src.shape
    anchor, mid, span = anchors(left_eye, right_eye)

    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    wx, wy = xx.copy(), yy.copy()
    for name, kind, radius, weight, direction in regions:
        wx, wy = apply_region(wx, wy, anchor[name], kind, radius * span,
                              weight, direction)

    hull = face_hull(xx, yy, anchor["faceCentre"], HULL_RADIUS * span)
    sx = xx + (wx - xx) * hull
    sy = yy + (wy - yy) * hull

    gx = np.clip(np.round(sx).astype(int), 0, w - 1)
    gy = np.clip(np.round(sy).astype(int), 0, h - 1)
    out = src[gy, gx].copy()

    if scale_skin > 0:
        s = {k: v * scale_skin for k, v in skin.items()}
        lines = creases(mid, span, anchor)
        valley, ridge = wrinkle_shade(sx, sy, lines)
        out *= (1.0 - valley * s["creases"] * hull)[..., None]
        out += (ridge * s["ridge"] * hull * 0.22)[..., None]

        luma = out @ LUMA
        grey = s["desaturate"] * hull
        out = out + (luma[..., None] - out) * grey[..., None]
        out = out + ((out * 0.88 + 0.10) - out) * grey[..., None]

        warm = (s["sallow"] * hull)[..., None]
        out *= np.stack([1 + warm[..., 0] * 0.07,
                         1 + warm[..., 0] * 0.03,
                         1 - warm[..., 0] * 0.08], -1)

        mottle = value_noise(sx / span * 34, sy / span * 34) * 0.65 \
            + value_noise(sx / span * 91, sy / span * 91) * 0.35
        out *= (1 - (mottle - 0.5) * s["blotch"] * hull * 0.55)[..., None]

        out = np.clip(out, 0, 1)

    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("image")
    parser.add_argument("--eyes", nargs=2, required=True,
                        help="left and right eye centres as x,y in image pixels")
    parser.add_argument("-o", "--out", default="preview.png")
    parser.add_argument("--skin", type=float, default=1.0,
                        help="multiplier on the whole skin treatment")
    parser.add_argument("--warp", type=float, default=1.0,
                        help="multiplier on every region weight")
    args = parser.parse_args()

    left, right = (tuple(float(v) for v in e.split(",")) for e in args.eyes)
    regions = [(n, k, r, wt * args.warp, d)
               for n, k, r, wt, d in GRANDMA_REGIONS]

    image = Image.open(args.image)
    result = render(image, left, right, regions, SKIN, args.skin)

    side = Image.new("RGB", (image.width * 2, image.height))
    side.paste(image.convert("RGB"), (0, 0))
    side.paste(result, (image.width, 0))
    side.save(args.out)
    print(f"wrote {args.out}  (before | after, eye span {np.linalg.norm(np.array(left)-np.array(right)):.0f}px)")


if __name__ == "__main__":
    main()
