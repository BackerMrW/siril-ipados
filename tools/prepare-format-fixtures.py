#!/usr/bin/env python3
"""Create an independent uncompressed Bayer DNG with exact known samples."""
from pathlib import Path
import struct
import zlib
import json
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

# Author-supplied independent codec fixtures from a pinned libheif release.
# Downloaded bytes must match the recorded digest before entering the App.
import hashlib
import urllib.request
heif_fixtures = [
    ("heif-padded.heic", "rainbow-451x461.heic", "4b2ce727f093944975f143ba2b39c4c64511b766d94552f8d51a755916e7f983"),
    ("heif-alpha.heic", "with-alpha-512x512.heic", "dac399d3bf1019baaf5f88eef8b277087d0643e735db947c42355237bb9d0221"),
    ("heif-av1.avif", "simple_osm_tile_alpha.avif", "6d78af07fbad358f4240820331074fff215ae8559bf4756ec480c6a6be2a68d9"),
    ("heif-16bit.heif", "uncompressed_row_B16R16G16.heif", "f9aa3e065c1973df1e3d540e0cfb5d157b2f3bf078c0efc0122671c4d3671cbc"),
]
for target, name, digest in heif_fixtures:
    output = Path("app/TestAssets") / target
    candidate = Path("deps-work/libheif/tests/data") / name
    body = output.read_bytes() if output.exists() else candidate.read_bytes() if candidate.exists() else urllib.request.urlopen(
        "https://raw.githubusercontent.com/strukturag/libheif/f81f28ac014b1c28dee483ac45b72c6b05bc421a/tests/data/" + name, timeout=60).read()
    if hashlib.sha256(body).hexdigest() != digest: raise RuntimeError("HEIF fixture checksum mismatch: " + name)
    output.write_bytes(body)
Path("app/TestAssets/heif-invalid.heic").write_bytes(b"not a HEIF image")
print("PASS: verified pinned HEIC/AVIF/16-bit HEIF codec fixtures, padding and alpha")

# Independent uncompressed AVI: odd RGB/gray row widths exercise both DIB
# padding and FFMS2's aligned output stride without a host video encoder.
def avi_fixture(name, rgb, frames=3):
    width, height = 65, 49
    channels = 3 if rgb else 1
    pitch = (width * channels + 3) // 4 * 4
    frame_size = pitch * height

    def chunk(tag, payload):
        return tag + struct.pack("<I", len(payload)) + payload + (b"\0" if len(payload) % 2 else b"")

    avih = struct.pack("<14I", 33333, frame_size * 30, 0, 0x10, frames, 0, 1,
                       frame_size, width, height, 0, 0, 0, 0)
    strh = struct.pack("<4s4sIHH8I4h", b"vids", b"DIB ", 0, 0, 0,
                       0, 1, 30, 0, frames, frame_size, 0xffffffff, 0, 0, 0, width, height)
    strf = struct.pack("<IiiHHIIiiII", 40, width, height, 1, channels * 8, 0,
                       frame_size, 0, 0, 0 if rgb else 256, 0)
    if not rgb:
        strf += b"".join(bytes((v, v, v, 0)) for v in range(256))
    hdrl = chunk(b"LIST", b"hdrl" + chunk(b"avih", avih) +
                 chunk(b"LIST", b"strl" + chunk(b"strh", strh) + chunk(b"strf", strf)))
    movi, index, offset = bytearray(), bytearray(), 4
    for frame in range(frames):
        pixels = bytearray()
        for y in reversed(range(height)):
            for x in range(width):
                for channel in ((2, 1, 0) if rgb else (0,)):
                    pixels.append(20 + frame * 7 + y * 2 + x % 13 + channel * 35)
            pixels.extend(b"\xd5" * (pitch - width * channels))
        packet = chunk(b"00db", pixels)
        index.extend(struct.pack("<4sIII", b"00db", 0x10, offset, len(pixels)))
        movi.extend(packet)
        offset += len(packet)
    body = b"AVI " + hdrl + chunk(b"LIST", b"movi" + movi) + chunk(b"idx1", index)
    Path("app/TestAssets", name + ".avi").write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)


avi_fixture("video-rgb", True)
avi_fixture("video-mono", False)
avi_fixture("video-single", True, 1)
Path("app/TestAssets/video-invalid.avi").write_bytes(b"not a video")
print("PASS: independent odd-width RGB/gray AVI, single-frame and invalid video fixtures")

# Compressed fixtures are committed synthetic data. A host encoder is needed
# only to regenerate them; normal Apple builds verify the recorded bytes.
video_manifest = json.loads(Path("app/TestAssets/video-codecs.json").read_text(encoding="utf-8"))
for name, entry in video_manifest["files"].items():
    body = Path("app/TestAssets", name).read_bytes()
    if hashlib.sha256(body).hexdigest() != entry["sha256"]:
        raise RuntimeError("Compressed video fixture checksum mismatch: " + name)
print("PASS: verified synthetic lossless PNG MOV, H.264 RGB MP4 and VP9 RGB WebM fixtures")
