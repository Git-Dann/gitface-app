"""Rasterises the lens props over a photo, so they can be seen before shipping.

A companion to `preview_lens.py`, which does the warp and skin. This does the
3D: it mirrors the geometry `RollerHair`, `ProceduralMasks.curlerCrown` and
`readingGlasses` build, projects it with the measured eye separation, and draws
it over an already-warped frame.

Three things it copies from the device that a naive rasteriser gets wrong, each
of which produced a misleading render before it was added:

* **+z is toward the nose**, so larger z is nearer the camera. Sorting the
  other way puts the scalp in front of the glasses.
* **RealityKit back-face culls.** Without it you see the inside of the far side
  of the scalp through the opening the face sits in.
* **The app puts ARKit's face mesh in the scene with `OcclusionMaterial`**, so
  anything behind the head is hidden. Approximated here with a head ellipsoid;
  without it the back of the scalp draws straight over the face.

Geometry here is duplicated from the Swift. It only keeps predicting anything
while both move together.
"""

import numpy as np
from PIL import Image

# MARK: - Mirrors RollerHair

COUNT, ARC = 13, 2.35
BARREL_LENGTH, BARREL_RADIUS = 0.0383, 0.0152
RIM_RADIUS, RIM_LENGTH = BARREL_RADIUS * 1.12, 0.0042
SLEEVE_RADIUS, SLEEVE_LENGTH = BARREL_RADIUS * 1.45, BARREL_LENGTH * 0.80

SCALP_RADII = np.float32([0.094, 0.094, 0.098])
SCALP_CENTRE = np.float32([0.0, 0.044, -0.014])
FRONT_LIMIT = 0.040
HAIRLINE_FRONT = (0.040, 0.098)
HAIRLINE_BACK = (-0.050, 0.005)

# The head, for the occlusion the face mesh performs on device.
HEAD_CENTRE = np.float32([0.0, 0.035, -0.010])
HEAD_RADII = np.float32([0.078, 0.085, 0.090])

# FaceLandmark puts the eyes at +-0.033, so an eye span is this many metres.
EYE_SPAN = 0.066
EYE_HEIGHT = 0.028

GREY = (0.79, 0.79, 0.81)
WHITE = (0.93, 0.91, 0.91)
PINK = (0.84, 0.30, 0.53)
FRAME = (0.07, 0.07, 0.09)


def hairline(z):
    span = HAIRLINE_FRONT[0] - HAIRLINE_BACK[0]
    t = np.clip((z - HAIRLINE_BACK[0]) / span, 0, 1)
    return HAIRLINE_BACK[1] + (HAIRLINE_FRONT[1] - HAIRLINE_BACK[1]) * t


def scalp(rings=30, segments=40):
    def point(u, v):
        return SCALP_CENTRE + SCALP_RADII * np.float32(
            [np.sin(u) * np.cos(v), np.cos(u), np.sin(u) * np.sin(v)]
        )

    faces = []
    for i in range(rings):
        for j in range(segments):
            u0, u1 = np.pi * i / rings, np.pi * (i + 1) / rings
            v0, v1 = 2 * np.pi * j / segments, 2 * np.pi * (j + 1) / segments
            quad = [point(u0, v0), point(u1, v0), point(u1, v1), point(u0, v1)]
            if not any(p[2] <= FRONT_LIMIT and p[1] >= hairline(p[2]) for p in quad):
                continue
            faces += [[quad[0], quad[1], quad[2]], [quad[0], quad[2], quad[3]]]
    return np.array(faces, np.float32)


def cylinder(length, radius, segments=22):
    a = np.linspace(0, 2 * np.pi, segments, endpoint=False)
    ring = np.stack([np.cos(a) * radius, np.sin(a) * radius], 1)
    lo = np.column_stack([np.full(segments, -length / 2), ring])
    hi = np.column_stack([np.full(segments, length / 2), ring])
    faces = []
    for i in range(segments):
        j = (i + 1) % segments
        faces += [[lo[i], lo[j], hi[j]], [lo[i], hi[j], hi[i]]]
    return np.array(faces, np.float32)


def cuboid(w, h, d):
    x, y, z = w / 2, h / 2, d / 2
    v = np.float32([[-x,-y,-z],[x,-y,-z],[x,y,-z],[-x,y,-z],
                    [-x,-y,z],[x,-y,z],[x,y,z],[-x,y,z]])
    f = [(0,1,2),(0,2,3),(4,6,5),(4,7,6),(0,4,5),(0,5,1),
         (3,2,6),(3,6,7),(0,3,7),(0,7,4),(1,5,6),(1,6,2)]
    return np.array([[v[a], v[b], v[c]] for a, b, c in f], np.float32)


def placement(index):
    t = index / (COUNT - 1)
    angle = -ARC + ARC * 2 * t
    return np.float32([
        np.sin(angle) * 0.112,
        0.078 + np.cos(angle) * 0.068,
        0.012 - (1 - np.cos(angle)) * 0.016,
    ]), angle


def lens_geometry():
    faces, colours = [], []

    def add(geometry, colour, position=(0, 0, 0), rotation=None):
        g = geometry.reshape(-1, 3)
        if rotation is not None:
            g = g @ rotation.T
        g = (g + np.float32(position)).reshape(-1, 3, 3)
        faces.append(g)
        colours.append(np.repeat(np.float32(colour)[None], len(g), 0))

    add(scalp(), GREY)

    for index in range(COUNT):
        position, angle = placement(index)
        c, s = np.cos(angle), np.sin(angle)
        rotation = np.float32([[c, -s, 0], [s, c, 0], [0, 0, 1]])
        add(cylinder(BARREL_LENGTH, BARREL_RADIUS), WHITE, position, rotation)
        for end in (-1, 1):
            rim = cylinder(RIM_LENGTH, RIM_RADIUS)
            rim[:, :, 0] += (BARREL_LENGTH / 2 + RIM_LENGTH / 2) * end
            add(rim, PINK, position, rotation)
        add(cylinder(SLEEVE_LENGTH, SLEEVE_RADIUS), GREY, position, rotation)

    wisp = cuboid(0.0022, 0.030, 0.0022)
    for index in range(14):
        t = index / 13
        around = (t - 0.5) * 2.6
        jitter = np.sin(index * 12.9898) * 0.5
        c, s = np.cos(around * 0.6 + jitter * 0.3), np.sin(around * 0.6 + jitter * 0.3)
        add(wisp, GREY,
            (np.sin(around) * 0.070 + jitter * 0.010,
             0.128 + np.cos(around) * 0.012 + jitter * 0.008,
             -0.030 + jitter * 0.022),
            np.float32([[c, -s, 0], [s, c, 0], [0, 0, 1]]))

    width, height, bar, brow = 0.052, 0.058, 0.0052, 0.0082
    for side in (-1, 1):
        cx, cy, cz = side * 0.039, 0.024, 0.062
        for v in (-1, 1):
            t = brow if v > 0 else bar
            add(cuboid(width, t, 0.008), FRAME, (cx, cy + (height - t) / 2 * v, cz))
        for h in (-1, 1):
            add(cuboid(bar, height, 0.008), FRAME, (cx + (width - bar) / 2 * h, cy, cz))
        add(cuboid(0.005, 0.005, 0.068), FRAME, (cx + 0.028 * side, cy + 0.012, cz - 0.034))
    add(cuboid(0.020, 0.005, 0.006), FRAME, (0, 0.013, 0.062))

    return np.concatenate(faces), np.concatenate(colours)


def draw(image, left_eye, right_eye):
    V, C = lens_geometry()
    N = np.cross(V[:, 1] - V[:, 0], V[:, 2] - V[:, 0])
    N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-9)

    l, r = np.array(left_eye, float), np.array(right_eye, float)
    mid = (l + r) / 2
    ppm = np.linalg.norm(l - r) / EYE_SPAN

    xs = mid[0] + V[:, :, 0] * ppm
    ys = mid[1] - (V[:, :, 1] - EYE_HEIGHT) * ppm
    depth = -V[:, :, 2]                       # +z is toward the nose

    light = np.float32([0.25, 0.55, 0.8])
    light /= np.linalg.norm(light)
    rgb = np.clip(C * (0.42 + 0.58 * np.clip(np.abs(N @ light), 0, 1))[:, None], 0, 1)
    facing = N[:, 2] > 0

    out = np.asarray(image.convert("RGB"), np.float32) / 255.0
    H, W, _ = out.shape
    zbuffer = np.full((H, W), 1e9, np.float32)

    x0s = np.clip(np.floor(xs.min(1)).astype(int), 0, W - 1)
    x1s = np.clip(np.ceil(xs.max(1)).astype(int), 0, W - 1)
    y0s = np.clip(np.floor(ys.min(1)).astype(int), 0, H - 1)
    y1s = np.clip(np.ceil(ys.max(1)).astype(int), 0, H - 1)

    for i in np.argsort(-depth.mean(1)):
        if not facing[i]:
            continue
        x0, x1, y0, y1 = x0s[i], x1s[i], y0s[i], y1s[i]
        if x1 < x0 or y1 < y0:
            continue
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1), np.arange(y0, y1 + 1))
        ax, ay = xs[i, 0], ys[i, 0]
        bx, by = xs[i, 1], ys[i, 1]
        cx, cy = xs[i, 2], ys[i, 2]
        den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(den) < 1e-9:
            continue
        w0 = ((by - cy) * (gx - cx) + (cx - bx) * (gy - cy)) / den
        w1 = ((cy - ay) * (gx - cx) + (ax - cx) * (gy - cy)) / den
        w2 = 1 - w0 - w1
        covered = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
        if not covered.any():
            continue

        z = w0 * depth[i, 0] + w1 * depth[i, 1] + w2 * depth[i, 2]

        # The occlusion mesh, as a head ellipsoid: anything behind it is hidden.
        fx = (gx - mid[0]) / ppm
        fy = (mid[1] - gy) / ppm + EYE_HEIGHT
        fz = w0 * V[i, 0, 2] + w1 * V[i, 1, 2] + w2 * V[i, 2, 2]
        inside = ((fx - HEAD_CENTRE[0]) / HEAD_RADII[0]) ** 2 \
            + ((fy - HEAD_CENTRE[1]) / HEAD_RADII[1]) ** 2
        head_z = np.where(inside < 1,
                          HEAD_CENTRE[2] + HEAD_RADII[2] * np.sqrt(np.clip(1 - inside, 0, None)),
                          -1e9)

        window = zbuffer[y0:y1 + 1, x0:x1 + 1]
        hit = covered & (z < window) & (fz >= head_z)
        if not hit.any():
            continue
        window[hit] = z[hit]
        out[y0:y1 + 1, x0:x1 + 1][hit] = rgb[i]

    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8))
