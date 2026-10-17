#!/usr/bin/env python3
"""Regenerate tiny synthetic lossless movie fixtures with a host FFmpeg.

The host encoder is a fixture authoring tool, not an App/build dependency.
Apple tests compare every decoded pixel against the analytic source formula.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", required=True, help="Path to a host FFmpeg with PNG, x264 RGB and VP9 encoders")
    args = parser.parse_args()
    output = Path(__file__).resolve().parents[1] / "app/TestAssets"
    pixels = bytes(20 + frame * 7 + y * 2 + x % 13 + channel * 35
                   for frame in range(3) for y in range(49) for x in range(65) for channel in range(3))
    codecs = [
        ("video-png.mov", ["-c:v", "png", "-pix_fmt", "rgb24"]),
        ("video-h264.mp4", ["-c:v", "libx264rgb", "-crf", "0", "-preset", "medium", "-pix_fmt", "rgb24"]),
        ("video-vp9.webm", ["-c:v", "libvpx-vp9", "-lossless", "1", "-pix_fmt", "gbrp", "-colorspace", "rgb", "-color_range", "pc"]),
    ]
    manifest = {"source": "RGB24 top-down, 65x49, 3 frames at 30 fps; pixel = 20 + frame*7 + y*2 + x%13 + channel*35",
                "encoder": subprocess.check_output([args.ffmpeg, "-version"], text=True).splitlines()[0], "files": {}}
    with tempfile.TemporaryDirectory(prefix="siril-video-fixtures-") as temporary:
        raw = Path(temporary) / "source.rgb"
        raw.write_bytes(pixels)
        for name, options in codecs:
            target = output / name
            command = [args.ffmpeg, "-v", "error", "-y", "-f", "rawvideo", "-pixel_format", "rgb24",
                       "-video_size", "65x49", "-framerate", "30", "-i", str(raw), "-frames:v", "3", "-an", *options, str(target)]
            subprocess.run(command, check=True)
            decoded = subprocess.check_output([args.ffmpeg, "-v", "error", "-i", str(target), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
            if decoded != pixels:
                raise RuntimeError("Host lossless verification failed: " + name)
            manifest["files"][name] = {"sha256": hashlib.sha256(target.read_bytes()).hexdigest(), "options": options}
            print("PASS:", name, "independent analytic pixels, all frames")
    (output / "video-codecs.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
