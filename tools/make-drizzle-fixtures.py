#!/usr/bin/env python3
"""Deterministic FITS fixtures: subpixel dithers, RGGB colors and detector flat.

Only Python's standard library is used. Physical expectation before output
normalization: sky * mean(flat) * drizzle_scale**2 (Siril's native convention).
"""
import math
from pathlib import Path
import struct

root = Path(__file__).resolve().parent.parent / "app/TestAssets"
side = 256

def write(name, pixels, bayer=False):
    cards = ["SIMPLE  =                    T", "BITPIX  =                  -32",
             "NAXIS   =                    2", f"NAXIS1  = {side:20}", f"NAXIS2  = {side:20}",
             "EXPTIME =                  120", "ROWORDER= 'TOP-DOWN'"]
    if bayer:
        cards.append("BAYERPAT= 'RGGB'")
    header = "".join(card.ljust(80) for card in cards + ["END"]).encode("ascii")
    header += b" " * (-len(header) % 2880)
    data = struct.pack(f">{len(pixels)}f", *pixels)
    (root / name).write_bytes(header + data + b"\0" * (-len(data) % 2880))

state = 987321
stars = []
for i in range(30):
    state = (state * 1664525 + 1013904223) & 0xffffffff
    x = 25 + (i % 6) * 40 + state % 13
    state = (state * 1664525 + 1013904223) & 0xffffffff
    y = 25 + (i // 6) * 44 + state % 13
    stars.append((x, y, (0.15 + (i % 7) * 0.025) * 0.2))
stars[0] = (30, 31, 0.14)
flat = [0.6 + 0.2 * x / 255 + 0.1 * y / 255 for y in range(side) for x in range(side)]
write("drizzle-flat.fits", [p + 0.001 for p in flat], True)
write("drizzle-bias.fits", [0.001] * side**2, True)
for frame, (dx, dy) in enumerate(((0, 0), (0.7, 1.1), (1.5, -0.6), (-0.4, 1.6))):
    pixels = []
    for y in range(side):
        for x in range(side):
            value = 0.004 + 0.00002 * math.sin(x * 1.3 + y * 0.7)
            for sx, sy, amplitude in stars:
                value += amplitude * math.exp(-((x - sx - dx)**2 + (y - sy - dy)**2) / (2 * 1.8**2))
            color = 1 if not x % 2 and not y % 2 else 0.25 if x % 2 and y % 2 else 0.5
            pixels.append(value * color * flat[y * side + x] + 0.001)
    write(f"drizzle-bayer-{frame}.fits", pixels, True)

print("Wrote four dithered Bayer lights, a nonuniform flat and a bias")
