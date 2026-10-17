#!/usr/bin/env python3
"""Regenerate tiny synthetic movie fixtures with a host FFmpeg.

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
    codecs = [
        ("video-png.mov", 65, 49, 0, ["-c:v", "png", "-pix_fmt", "rgb24"]),
        ("video-h264.mp4", 65, 49, 0, ["-c:v", "libx264rgb", "-crf", "0", "-preset", "medium", "-pix_fmt", "rgb24"]),
        ("video-vp9.webm", 65, 49, 0, ["-c:v", "libvpx-vp9", "-lossless", "1", "-pix_fmt", "gbrp", "-colorspace", "rgb", "-color_range", "pc"]),
        ("video-h264-yuv420.mp4", 66, 50, 2, ["-vf", "scale=out_color_matrix=bt709:out_range=tv",
            "-c:v", "libx264", "-crf", "0", "-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_range", "tv"]),
    ]
    manifest = {"source": "RGB24 top-down, 3 frames at 30 fps; pixel = 20 + frame*7 + y*2 + x%13 + channel*35",
                "encoder": subprocess.check_output([args.ffmpeg, "-version"], text=True).splitlines()[0], "files": {}}
    with tempfile.TemporaryDirectory(prefix="siril-video-fixtures-") as temporary:
        raw = Path(temporary) / "source.rgb"
        for name, width, height, tolerance, options in codecs:
            pixels = bytes(20 + frame * 7 + y * 2 + x % 13 + channel * 35
                           for frame in range(3) for y in range(height) for x in range(width) for channel in range(3))
            raw.write_bytes(pixels)
            target = output / name
            command = [args.ffmpeg, "-v", "error", "-y", "-f", "rawvideo", "-pixel_format", "rgb24",
                       "-video_size", f"{width}x{height}", "-framerate", "30", "-i", str(raw), "-frames:v", "3", "-an", *options, str(target)]
            subprocess.run(command, check=True)
            decoded = subprocess.check_output([args.ffmpeg, "-v", "error", "-i", str(target), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
            worst = max(abs(a - b) for a, b in zip(decoded, pixels))
            if len(decoded) != len(pixels) or worst > tolerance:
                raise RuntimeError(f"Host verification failed: {name}, maximum error {worst}")
            manifest["files"][name] = {"sha256": hashlib.sha256(target.read_bytes()).hexdigest(), "options": options,
                                       "width": width, "height": height, "maximum_sample_error": tolerance}
            print("PASS:", name, "independent analytic pixels, all frames; maximum sample error", worst)
    (output / "video-codecs.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
