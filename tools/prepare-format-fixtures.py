#!/usr/bin/env python3
"""Create an independent uncompressed Bayer DNG with exact known samples."""
from pathlib import Path
import struct
import zlib

size = 256
tags = {}
def tag(number, kind, count, body):
    tags[number] = (kind, count, body)
def shorts(*values):
    return struct.pack("<" + "H" * len(values), *values)
def longs(*values):
    return struct.pack("<" + "I" * len(values), *values)
def rationals(*values):
    return b"".join(struct.pack("<ii", int(value), 1) for value in values)
for number, value in [(256, size), (257, size), (278, size), (279, size * size * 2), (50717, 65535)]:
    tag(number, 4, 1, longs(value))
for number, value in [(258, 16), (259, 1), (262, 32803), (274, 1), (277, 1), (284, 1), (50711, 1), (50778, 21)]:
    tag(number, 3, 1, shorts(value))
for number, value in [(271, "Siril"), (272, "Independent CFA fixture"), (50708, "Siril Independent CFA")]:
    body = value.encode() + b"\0"
    tag(number, 2, len(body), body)
tag(33421, 3, 2, shorts(2, 2))
tag(33422, 1, 4, bytes([0, 1, 1, 2]))
tag(50706, 1, 4, bytes([1, 4, 0, 0]))
tag(50707, 1, 4, bytes([1, 1, 0, 0]))
tag(50710, 1, 3, bytes([0, 1, 2]))
tag(50713, 3, 2, shorts(1, 1))
tag(50714, 5, 1, rationals(0))
tag(50718, 5, 2, rationals(1, 1))
tag(50719, 4, 2, longs(0, 0))
tag(50720, 4, 2, longs(size, size))
tag(50721, 10, 9, rationals(1, 0, 0, 0, 1, 0, 0, 0, 1))
tag(50728, 5, 3, rationals(1, 1, 1))
tag(50829, 4, 4, longs(0, 0, size, size))
tag(273, 4, 1, longs(0))
offset = 8 + 2 + 12 * len(tags) + 4
extra = bytearray()
entries = []
for number, (kind, count, body) in sorted(tags.items()):
    if len(body) <= 4:
        value = body.ljust(4, b"\0")
    else:
        value = longs(offset + len(extra))
        extra.extend(body)
        if len(extra) % 2: extra.append(0)
    entries.append((number, kind, count, value))
pixel_offset = offset + len(extra)
entries = [(n, k, c, longs(pixel_offset) if n == 273 else v) for n, k, c, v in entries]
body = bytearray(b"II*\0" + longs(8) + shorts(len(entries)))
for number, kind, count, value in entries:
    body.extend(struct.pack("<HHI", number, kind, count) + value)
body.extend(longs(0) + extra)
assert len(body) == pixel_offset
for y in range(size):
    for x in range(size):
        body.extend(shorts(1000 + 16 * y + x))
path = Path("app/TestAssets/linear-cfa.dng")
path.parent.mkdir(parents=True, exist_ok=True)
path.write_bytes(body)
print(f"PASS: generated {size}x{size} independent RGGB DNG with exact 16-bit samples")

# Independent XISF 1.0 attachments, written without the reader under test.
def xisf_fixture(name, sample_format, channels, pixels, storage="planar", shuffle=0, cfa=False):
    uncompressed = len(pixels)
    compression = ""
    if shuffle:
        pixels = b"".join(pixels[i::shuffle] for i in range(shuffle))
        pixels = zlib.compress(pixels)
        compression = f' compression="zlib+sh:{uncompressed}:{shuffle}"'
    metadata = '<FITSKeyword name="EXPTIME" value="120.0" comment="Independent fixture"/>'
    if cfa:
        metadata += '<ColorFilterArray pattern="RGGB" width="2" height="2"/>'
    xml = (f'<?xml version="1.0" encoding="UTF-8"?>'
           f'<xisf version="1.0" xmlns="http://www.pixinsight.com/xisf">'
           f'<Image geometry="8:6:{channels}" sampleFormat="{sample_format}"'
           f' colorSpace="{"Gray" if channels == 1 else "RGB"}" pixelStorage="{storage}"'
           f' location="attachment:2048:{len(pixels)}"{compression}>{metadata}</Image></xisf>').encode()
    header = b"XISF0100" + struct.pack("<II", len(xml), 0) + xml
    assert len(header) < 2048
    Path("app/TestAssets", name + ".xisf").write_bytes(header.ljust(2048, b"\0") + pixels)

xisf_fixture("xisf-cfa", "UInt16", 1,
             b"".join(shorts(1000 + 16 * y + x) for y in range(6) for x in range(8)), cfa=True)
for storage in ("planar", "normal"):
    coords = ((c, y, x) for c in range(3) for y in range(6) for x in range(8)) if storage == "planar" else (
        (c, y, x) for y in range(6) for x in range(8) for c in range(3))
    pixels = b"".join(struct.pack("<f", (c + 1) * .1 + y * .01 + x * .001) for c, y, x in coords)
    xisf_fixture("xisf-rgb-" + storage, "Float32", 3, pixels, storage, shuffle=4 if storage == "normal" else 0)
Path("app/TestAssets/xisf-invalid.xisf").write_bytes(b"invalid XISF signature")
print("PASS: generated independent UInt16 CFA, planar RGB Float32, byte-shuffled zlib interleaved RGB and invalid XISF fixtures")
