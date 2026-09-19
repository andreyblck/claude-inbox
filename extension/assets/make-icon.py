#!/usr/bin/env python3
"""Regenerate assets/icon.png. Analytic coverage AA, no dependencies.

A dark squircle, three bars (the inbox), one accent dot (someone needs you).
Reads at 16px in the menu bar, which is the only size that matters.
"""
import math, pathlib, struct, zlib

S = 512
BG = (0x1C, 0x1C, 0x1E)
FG = (0xF2, 0xF2, 0xF7)
ACCENT = (0xFF, 0xD6, 0x0A)


def squircle(x, y, cx, cy, r, n=4.0):
    return (abs(x - cx) / r) ** n + (abs(y - cy) / r) ** n - 1.0


def rounded_bar(x, y, x0, x1, cy, h):
    """Signed distance to a horizontal capsule."""
    px = min(max(x, x0), x1)
    return math.hypot(x - px, y - cy) - h


def cov(sd, soft=1.2):
    """Signed distance -> coverage, one pixel of feather."""
    return min(1.0, max(0.0, 0.5 - sd / soft))


def blend(dst, src, a):
    return tuple(round(d + (s - d) * a) for d, s in zip(dst, src))


rows = []
for y in range(S):
    row = bytearray()
    for x in range(S):
        px, py = x + 0.5, y + 0.5
        a_bg = cov(squircle(px, py, S / 2, S / 2, S * 0.47) * S * 0.24)
        if a_bg <= 0.002:
            row += bytes((0, 0, 0, 0))
            continue
        c = BG
        for i, (w, cy) in enumerate(((0.52, 0.34), (0.52, 0.50), (0.32, 0.66))):
            x0 = S * 0.24
            a = cov(rounded_bar(px, py, x0, x0 + S * w, S * cy, S * 0.035))
            if a > 0:
                c = blend(c, FG, a)
        a_dot = cov(math.hypot(px - S * 0.74, py - S * 0.30) - S * 0.115)
        if a_dot > 0:
            c = blend(c, BG, a_dot)  # knock a hole in the bar first
            a_in = cov(math.hypot(px - S * 0.74, py - S * 0.30) - S * 0.082)
            if a_in > 0:
                c = blend(c, ACCENT, a_in)
        row += bytes((*c, round(a_bg * 255)))
    rows.append(bytes(row))

raw = b"".join(b"\x00" + r for r in rows)


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))
out = pathlib.Path(__file__).with_name("icon.png")
out.write_bytes(png)
print(f"wrote {out} ({len(png)} bytes)")
