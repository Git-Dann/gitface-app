"""Generates facetrkr's app icon as a 1024x1024 PNG.

Written by hand rather than with an image library because none is installed
here. Colour type 2 (truecolour, no alpha) is deliberate: App Store Connect
rejects an app icon carrying an alpha channel.

The mark is a domino mask — a white band across the eyes with two holes cut
back to the background. It reads at 40pt, which a detailed face would not.
"""

import struct
import zlib

SIZE = 1024
SAMPLES = 3  # per axis, for antialiasing

# Matches AccentColor in the asset catalogue, falling to a deep purple.
TOP = (249, 74, 93)
BOTTOM = (58, 30, 92)
MASK = (255, 255, 255)

# Geometry in normalised coordinates.
CENTRE_Y = 0.50
OFFSET_X = 0.185
LOBE_RX, LOBE_RY = 0.255, 0.170
EYE_RX, EYE_RY = 0.100, 0.072


def inside_ellipse(x, y, cx, cy, rx, ry):
    dx = (x - cx) / rx
    dy = (y - cy) / ry
    return dx * dx + dy * dy <= 1.0


def mask_coverage(x, y):
    """1.0 inside the mask band, 0.0 in a cut-out eye or outside."""
    for sign in (-1.0, 1.0):
        cx = 0.5 + sign * OFFSET_X
        if inside_ellipse(x, y, cx, CENTRE_Y, EYE_RX, EYE_RY):
            return 0.0
    for sign in (-1.0, 1.0):
        cx = 0.5 + sign * OFFSET_X
        if inside_ellipse(x, y, cx, CENTRE_Y, LOBE_RX, LOBE_RY):
            return 1.0
    return 0.0


def background(t):
    """Vertical gradient, eased so the midtone sits a little high."""
    e = t * t * (3.0 - 2.0 * t)
    return tuple(int(round(TOP[i] + (BOTTOM[i] - TOP[i]) * e)) for i in range(3))


def build_rows():
    rows = []
    step = 1.0 / (SIZE * SAMPLES)
    for py in range(SIZE):
        row = bytearray()
        base = background((py + 0.5) / SIZE)
        for px in range(SIZE):
            hits = 0
            for sy in range(SAMPLES):
                y = (py * SAMPLES + sy + 0.5) * step
                for sx in range(SAMPLES):
                    x = (px * SAMPLES + sx + 0.5) * step
                    if mask_coverage(x, y) > 0.0:
                        hits += 1
            if hits == 0:
                row += bytes(base)
            else:
                a = hits / (SAMPLES * SAMPLES)
                row += bytes(
                    int(round(base[i] + (MASK[i] - base[i]) * a)) for i in range(3)
                )
        rows.append(row)
    return rows


def write_png(path, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


if __name__ == "__main__":
    import sys

    write_png(sys.argv[1], build_rows())
    print("wrote", sys.argv[1])
