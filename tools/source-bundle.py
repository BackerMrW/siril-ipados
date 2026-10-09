#!/usr/bin/env python3
"""Collect exact upstream sources and build scripts for a native binary release."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import urllib.request
import zipfile

GIT_SOURCES = [
    ("Siril", "https://gitlab.com/free-astro/siril.git", "6c0f8f3207b9cb712f7e04249217123a8ca66915", "siril-ipados"),
    ("CFITSIO", "https://github.com/HEASARC/cfitsio.git", "1d2f37b1bc8e6d5e8cf8cd497314680322063468", "cfitsio-upstream"),
    ("GLib", "https://github.com/GNOME/glib.git", "41eca60845d3fc309af361f5e7f801ba339099aa", "glib-ipados-upstream"),
    ("libffi", "https://github.com/mesonbuild/libffi.git", "83d0cfd00d7d37af4b4349511d29f1f0512621b3", "libffi-meson-upstream"),
    ("proxy-libintl", "https://github.com/frida/proxy-libintl.git", "33934de09af6a6627eb44e310a8079df009abdbb", None),
    ("LCMS", "https://github.com/mm2/Little-CMS.git", "453bafeb85b4ef96498866b7a8eadcc74dff9223", "lcms-ipados-upstream"),
    ("libpng", "https://github.com/pnggroup/libpng.git", "872555f4ba910252783af1507f9e7fe1653be252", None),
    ("Cairo", "https://gitlab.freedesktop.org/cairo/cairo.git", "4541e0cd3a751b85e52e2a83d02ac6145a5efa85", "cairo-ipados-upstream"),
    ("HarfBuzz", "https://github.com/harfbuzz/harfbuzz.git", "3ef8709829a5884517ad91a97b32b9435b2f20d1", "harfbuzz-ipados-upstream"),
    ("Pango", "https://github.com/GNOME/pango.git", "5f589a7e0e61dca3f976da172cf55743ace77a38", "pango-ipados-upstream"),
    ("FriBidi", "https://github.com/fribidi/fribidi.git", "24f15eee832eafa5d63319b666d50e488668ce31", None),
    ("GdkPixbuf", "https://github.com/GNOME/gdk-pixbuf.git", "e4315fb8553776e13d39e3f2e0ea8792db61720c", "pixbuf-ipados-upstream"),
    ("OpenCV", "https://github.com/opencv/opencv.git", "31b0eeea0b44b370fd0712312df4214d4ae1b158", None),
]
TAR_SOURCES = [
    ("FFTW", "https://www.fftw.org/fftw-3.3.10.tar.gz", "56c932549852cddcfafdab3820b0200c7742675be92179e59e6215b340e26467", "fftw-3.3.10.tar.gz"),
    ("GSL", "https://ftp.gnu.org/gnu/gsl/gsl-2.8.tar.gz", "6a99eeed15632c6354895b1dd542ed5a855c0f15d9ad1326c6fe2b2c9e423190", "gsl-2.8.tar.gz"),
    ("PCRE2", "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.bz2", "d34f02e113cf7193a1ebf2770d3ac527088d485d4e047ed10e5d217c6ef5de96", "pcre2-10.44.tar.bz2"),
    ("PCRE2-Meson", "https://wrapdb.mesonbuild.com/v2/pcre2_10.44-2/get_patch", "4336d422ee9043847e5e10dbbbd01940d4c9e5027f31ccdc33a7898a1ca94009", "pcre2_10.44-2_patch.zip"),
]


def run(*args):
    return subprocess.check_output([str(a) for a in args])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--workspace", type=Path, default=Path.cwd().parent)
    parser.add_argument("--licenses", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    work = args.output.parent / "source-downloads"
    work.mkdir(parents=True, exist_ok=True)
    manifest = []
    with zipfile.ZipFile(args.output, "w", compression=zipfile.ZIP_STORED) as package:
        def add_source(name, body, filename, revision, url):
            package.writestr("upstream/" + filename, body)
            manifest.append({"name": name, "revision": revision, "url": url, "archive": filename,
                             "sha256": hashlib.sha256(body).hexdigest()})
            if args.licenses and not filename.endswith(".zip"):
                with tarfile.open(fileobj=io.BytesIO(body)) as source:
                    for item in source.getmembers():
                        if item.isfile() and item.size < 1024 * 1024 and (
                            item.name.split("/")[-1].upper().startswith(("LICENSE", "COPYING", "COPYRIGHT", "NOTICE"))):
                            parts = Path(item.name).parts[1:]
                            if not parts or ".." in parts: continue
                            target = root / "ThirdPartyLicenses" / name / Path(*parts)
                            target.parent.mkdir(parents=True, exist_ok=True)
                            target.write_bytes(source.extractfile(item).read())
        for name, url, revision, local in GIT_SOURCES:
            print("Collecting", name, flush=True)
            candidate = args.workspace / local if local else None
            source = candidate if candidate and candidate.exists() else work / name
            if not source.exists():
                source.mkdir()
                run("git", "init", source)
                run("git", "-C", source, "remote", "add", "origin", url)
            try:
                run("git", "-C", source, "cat-file", "-e", revision + "^{commit}")
            except subprocess.CalledProcessError:
                run("git", "-C", source, "fetch", "--depth", "1", "origin", revision)
            body = run("git", "-C", source, "archive", "--format=tar.gz", "--prefix=" + name + "/", revision)
            add_source(name, body, name + ".tar.gz", revision, url)
            if name == "Siril":
                tree = run("git", "-C", source, "ls-tree", revision, "subprojects/librtprocess", "subprojects/yyjson").decode()
                for line in tree.splitlines():
                    commit = line.split()[2]
                    subname = Path(line.split()[3]).name
                    sub = work / subname
                    sub.mkdir(exist_ok=True)
                    run("git", "init", sub)
                    remote = "https://github.com/CarVac/librtprocess.git" if subname == "librtprocess" else "https://github.com/ibireme/yyjson.git"
                    run("git", "-C", sub, "fetch", "--depth", "1", remote, commit)
                    subbody = run("git", "-C", sub, "archive", "--format=tar.gz", "--prefix=" + subname + "/", commit)
                    add_source(subname, subbody, subname + ".tar.gz", commit, remote)
        for name, url, digest, filename in TAR_SOURCES:
            print("Collecting", name, flush=True)
            cached = args.workspace / "dependency-dist" / filename
            body = cached.read_bytes() if cached.exists() else urllib.request.urlopen(url, timeout=120).read()
            if hashlib.sha256(body).hexdigest() != digest:
                raise RuntimeError("Source checksum mismatch: " + name)
            add_source(name, body, filename, digest, url)
        revision = run("git", "-C", root, "rev-parse", "HEAD").decode().strip()
        package.writestr("port-source.tar.gz", run("git", "-C", root, "archive", "--format=tar.gz", "--prefix=siril-ipados/", "HEAD"))
        package.writestr("SOURCES.json", json.dumps({"port_revision": revision, "sources": manifest}, indent=2))
        package.writestr("BUILDING.txt", "Extract port-source.tar.gz. The repository contains all iPadOS modifications and build scripts.\n"
                         "The upstream directory contains original pinned source archives, including engine submodules and dependencies.\n"
                         "Use .github/workflows/ipados-preflight.yml with Xcode 16.4/iOS 18.5 SDK on macOS,\n"
                         "or dispatch that workflow from GitHub on iphoneos/iphonesimulator. Build prerequisites: Xcode, Homebrew, Python, XcodeGen.\n"
                         "The workflow and tools/build-ipados-deps.py/tools/embed-siril.py apply all local adaptations.\n"
                         "To use offline archives, replace the fetch/extract operations in those scripts with the matching archives from upstream.\n"
                         "Apple SDK/system framework sources are supplied by Apple separately. No signing credentials are included.\n")
    print("Source bundle:", args.output, flush=True)

if __name__ == "__main__":
    main()
