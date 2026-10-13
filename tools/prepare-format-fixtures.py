#!/usr/bin/env python3
"""Create an independent uncompressed Bayer DNG with exact known samples."""
from pathlib import Path
import struct
import zlib
from datetime import datetime

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
colored_dng = bytearray(body[:pixel_offset])
for y in range(size):
    for x in range(size):
        colored_dng.extend(shorts(10000 if not (y % 2 or x % 2) else 40000 if y % 2 and x % 2 else 20000))
Path("app/TestAssets/linear-cfa-color.dng").write_bytes(colored_dng)

# Independent XISF 1.0 attachments, written without the reader under test.
def xisf_fixture(name, sample_format, channels, pixels, storage="planar", shuffle=0, cfa=False, width=8, height=6):
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
           f'<Image geometry="{width}:{height}:{channels}" sampleFormat="{sample_format}"'
           f' colorSpace="{"Gray" if channels == 1 else "RGB"}" pixelStorage="{storage.capitalize()}"'
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
normal_xisf = Path("app/TestAssets/xisf-rgb-normal.xisf").read_bytes()
Path("app/TestAssets/xisf-truncated.xisf").write_bytes(normal_xisf[:-7])
Path("app/TestAssets/xisf-corrupt-zlib.xisf").write_bytes(normal_xisf[:-8] + b"\0" * 8)
xml_size = struct.unpack("<I", normal_xisf[8:12])[0]
invalid_xml = normal_xisf[16:16 + xml_size].replace(b'geometry="8:6:3"', b'geometry="bad:6:3"')
invalid_header = b"XISF0100" + struct.pack("<II", len(invalid_xml), 0) + invalid_xml
Path("app/TestAssets/xisf-invalid-geometry.xisf").write_bytes(invalid_header.ljust(2048, b"\0") + normal_xisf[2048:])
xisf_fixture("xisf-colored-cfa", "UInt16", 1,
             b"".join(shorts(10000 if not (y % 2 or x % 2) else 40000 if y % 2 and x % 2 else 20000) for y in range(32) for x in range(32)),
             cfa=True, width=32, height=32)
print("PASS: generated independent UInt16 CFA, planar RGB Float32, byte-shuffled zlib interleaved RGB and invalid XISF fixtures")

def ser_fixture(name, color, depth, big_endian=False, width=8, height=6, colored=False):
    epoch = datetime(2020, 1, 1) - datetime(1, 1, 1)
    ticks = epoch.days * 86400 * 10000000
    header = b"LUCAM-RECORDER" + struct.pack("<7I", 0, color, int(big_endian), width, height, depth, 3)
    header += b"Independent observer".ljust(40, b"\0") + b"Independent camera".ljust(40, b"\0") + b"Independent telescope".ljust(40, b"\0")
    header += struct.pack("<QQ", ticks, ticks)
    assert len(header) == 178
    pixels = bytearray()
    for frame in range(3):
        for y in range(height):
            for x in range(width):
                order = (2, 1, 0) if color == 101 else (0, 1, 2) if color == 100 else (0,)
                for c in order:
                    value = 10 + c * 40 + frame * 10 + y * 3 + x if depth == 8 else 1000 + c * 100 + frame * 20 + y * 8 + x
                    if colored: value = 10000 if not (y % 2 or x % 2) else 40000 if y % 2 and x % 2 else 20000
                    pixels.extend(bytes([value]) if depth == 8 else struct.pack(">H" if big_endian else "<H", value))
    trailer = struct.pack("<3Q", ticks, ticks + 10000000, ticks + 20000000)
    body = header + pixels + trailer
    Path("app/TestAssets", name + ".ser").write_bytes(body)
    return body

ser_fixture("ser-mono8", 0, 8)
ser_fixture("ser-cfa16", 8, 16)
ser_fixture("ser-rgb8", 100, 8)
bgr = ser_fixture("ser-bgr16be", 101, 16, True)
Path("app/TestAssets/ser-truncated.ser").write_bytes(bgr[:178 + 8 * 6 * 3 * 2 + 10])
ser_fixture("ser-colored-cfa", 8, 16, width=32, height=32, colored=True)
print("PASS: generated independent three-frame SER mono/CFA/RGB/BGR fixtures, both byte orders, timestamps and a truncated sequence")
