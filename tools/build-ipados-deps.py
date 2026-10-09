#!/usr/bin/env python3
"""Build Siril's remaining core dependencies for arm64 iPadOS, never host libraries."""
import hashlib
import inspect
import json
import os
import re
from pathlib import Path
import shlex
import subprocess
import tarfile
import urllib.request

ROOT = Path.cwd()
STAGE = ROOT / "ipados-stage"
LOGS = ROOT / "diagnostics"
WORK = ROOT / "deps-work"
CROSS = ROOT / "ipados-cross.ini"
STATE = STAGE / ".build-state"
for directory in (STAGE, LOGS, WORK, STATE):
    directory.mkdir(parents=True, exist_ok=True)
SDK = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
SDK_VERSION = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], text=True).strip()
ENV = dict(os.environ, PKG_CONFIG_PATH="", PKG_CONFIG_LIBDIR=f"{STAGE}/lib/pkgconfig:{STAGE}/share/pkgconfig")


def run(command, label, cwd=None, env=None):
    print(f"::group::{label}", flush=True)
    with (LOGS / f"{label}.log").open("w") as log:
        log.write(shlex.join(map(str, command)) + "\n")
        log.flush()
        process = subprocess.Popen(list(map(str, command)), cwd=cwd, env=env or ENV,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            print(line, end="", flush=True)
            log.write(line)
        code = process.wait()
    print("::endgroup::", flush=True)
    if code:
        raise subprocess.CalledProcessError(code, command)


def checkout(name, url, revision):
    source = WORK / name
    run(["git", "init", source], f"{name}-init")
    run(["git", "remote", "add", "origin", url], f"{name}-remote", cwd=source)
    run(["git", "fetch", "--depth", "1", "origin", revision], f"{name}-fetch", cwd=source)
    run(["git", "checkout", "--detach", "FETCH_HEAD"], f"{name}-checkout", cwd=source)
    return source


def ready(name, identity):
    stamp = STATE / f"{name}.json"
    expected = {"identity": identity, "sdk": SDK_VERSION, "prefix": str(STAGE), "schema": 1}
    if stamp.exists() and json.loads(stamp.read_text()) == expected:
        print(f"Reusing completed {name} build", flush=True)
        return True
    return False


def mark(name, identity):
    (STATE / f"{name}.json").write_text(json.dumps(
        {"identity": identity, "sdk": SDK_VERSION, "prefix": str(STAGE), "schema": 1}, indent=2))


def build_archives(build, name):
    data = json.loads(subprocess.check_output(["meson", "introspect", "--targets", str(build)], env=ENV, text=True))
    outputs = []
    for target in data:
        if target["type"] == "static library" and target.get("installed", False):
            for filename in target["filename"]:
                path = Path(filename)
                if not path.is_absolute():
                    path = build / path
                outputs.append(str(path.relative_to(build)))
    if not outputs:
        raise RuntimeError(f"{name} declared no static libraries")
    (LOGS / f"{name}-static-targets.json").write_text(json.dumps(outputs, indent=2))
    run(["ninja", "-C", build, "-j", "3", *outputs], f"{name}-build")


def meson(name, url, revision, options, patch=None):
    identity = {"revision": revision, "options": options,
                "patch": hashlib.sha256(inspect.getsource(patch).encode()).hexdigest() if patch else None}
    if ready(name, identity):
        return
    source = checkout(name, url, revision)
    if patch:
        patch(source)
        run(["git", "diff", "--check"], f"{name}-patch-check", cwd=source)
        diff = subprocess.check_output(["git", "diff"], cwd=source, text=True)
        (LOGS / f"{name}-ipados.patch").write_text(diff)
    build = WORK / f"{name}-build"
    try:
        run(["meson", "setup", build, source, "--cross-file", CROSS,
             "--native-file", ROOT / "macos-tools.ini",
             "--prefix", STAGE, "--libdir", "lib", "--buildtype", "release",
             "-Ddefault_library=static", "-Dprefer_static=false", *options], f"{name}-configure")
        build_archives(build, name)
        run(["meson", "install", "-C", build, "--no-rebuild", "--tags", "devel"], f"{name}-install")
        mark(name, identity)
    finally:
        if (build / "meson-logs/meson-log.txt").exists():
            (LOGS / f"{name}-meson.log").write_bytes((build / "meson-logs/meson-log.txt").read_bytes())


def ios_frameworks(source):
    """Replace macOS umbrella frameworks with the public iOS component frameworks."""
    for p in source.rglob("*"):
        if p.is_file() and (p.suffix in (".c", ".h") or p.name == "meson.build") and ".git" not in p.parts:
            text = p.read_text(errors="strict")
            components = ("#include <CoreText/CoreText.h>" if p.name == "meson.build" else
                          "#include <CoreGraphics/CoreGraphics.h>\n#include <CoreText/CoreText.h>")
            text = text.replace("#include <ApplicationServices/ApplicationServices.h>", components)
            text = text.replace("#include <Carbon/Carbon.h>",
                                "#include <CoreGraphics/CoreGraphics.h>\n#include <CoreText/CoreText.h>")
            # Meson probe strings must remain single-line.
            text = text.replace("modules : ['CoreFoundation', 'ApplicationServices']",
                                "modules : ['CoreFoundation', 'CoreGraphics', 'CoreText']")
            text = text.replace("modules: 'ApplicationServices'", "modules: ['CoreGraphics', 'CoreText']")
            text = text.replace("modules: [ 'CoreFoundation', 'ApplicationServices' ]",
                                "modules: [ 'CoreFoundation', 'CoreGraphics', 'CoreText' ]")
            p.write_text(text)
    # ATSUI and desktop display enumeration are unavailable on iOS. Keep
    # CoreText/CGFont rendering and use an explicit RGB space for image surfaces.
    quartz = source / "src/cairo-quartz.h"
    if quartz.exists():
        text = quartz.read_text().replace(
            "cairo_public cairo_font_face_t *\ncairo_quartz_font_face_create_for_atsu_font_id (ATSUFontID font_id);", "")
        quartz.write_text(text)
        font = source / "src/cairo-quartz-font.c"
        text = font.read_text()
        text = text.replace("static ATSFontRef (*FMGetATSFontRefFromFontPtr) (FMFont iFont) = NULL;", "")
        text = text.replace('    FMGetATSFontRefFromFontPtr = dlsym(RTLD_DEFAULT, "FMGetATSFontRefFromFont");', "")
        text = text.replace("#if MAC_OS_X_VERSION_MIN_REQUIRED < 1080", "#if 0 /* iOS uses the current CoreText names */")
        text = text.split("/*\n * compat with old ATSUI backend\n */")[0]
        font.write_text(text)
        for name in ("cairo-quartz-surface.c", "cairo-quartz-image-surface.c"):
            p = source / "src" / name
            text = p.read_text().replace("CGDisplayCopyColorSpace (CGMainDisplayID ())",
                                         "CGColorSpaceCreateWithName (kCGColorSpaceSRGB)")
            text = "#include <ImageIO/ImageIO.h>\n" + text
            p.write_text(text)
        meson_file = source / "meson.build"
        text = meson_file.read_text().replace("['CoreGraphics', 'CoreText']",
                                               "['CoreGraphics', 'CoreText', 'ImageIO']")
        meson_file.write_text(text)
    coretext = source / "pango/pangocoretext-fontmap.c"
    if coretext.exists():
        text = coretext.read_text().replace(
            "#if !defined(MAC_OS_X_VERSION_10_8) || MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_8",
            "#if 0 /* iOS uses the public CTFontCopyDefaultCascadeListForLanguages */")
        text = text.replace(
            "#if defined(MAC_OS_X_VERSION_10_8) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_8",
            "#if 1 /* iOS 17 supports the current public CoreText API */")
        coretext.write_text("#include <strings.h>\n" + text)


def ios_opencv_metadata(source):
    # Upstream suppresses pkg-config output for iOS. Siril's Meson build needs
    # that metadata even though we intentionally build static archives.
    p = source / "cmake/OpenCVGenPkgconfig.cmake"
    text = p.read_text()
    assert "if(MSVC OR IOS OR XROS)" in text
    text = text.replace("if(MSVC OR IOS OR XROS)", "if(MSVC OR XROS)")
    text = re.sub(r"cmake_minimum_required\(VERSION 2\.[^)]+\)",
                  "cmake_minimum_required(VERSION 3.5)", text)
    p.write_text(text)


def cmake(name, url, revision, options, patch=None):
    identity = {"revision": revision, "options": options,
                "patch": hashlib.sha256(inspect.getsource(patch).encode()).hexdigest() if patch else None}
    if ready(name, identity):
        return
    source = checkout(name, url, revision)
    if patch:
        patch(source)
    build = WORK / f"{name}-build"
    run(["cmake", "-S", source, "-B", build, "-G", "Ninja",
         "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DCMAKE_SYSTEM_NAME=iOS",
         f"-DCMAKE_OSX_SYSROOT={SDK}", "-DCMAKE_OSX_ARCHITECTURES=arm64",
         "-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0", "-DCMAKE_BUILD_TYPE=Release",
         f"-DCMAKE_INSTALL_PREFIX={STAGE}", f"-DCMAKE_FIND_ROOT_PATH={STAGE};{SDK}",
         "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY", "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY",
         "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY", "-DBUILD_SHARED_LIBS=OFF", *options], f"{name}-configure")
    run(["cmake", "--build", build, "--parallel", "3"], f"{name}-build")
    run(["cmake", "--install", build], f"{name}-install")
    mark(name, identity)


def autotools(name, url, digest, options):
    identity = {"sha256": digest, "options": options}
    if ready(name, identity):
        return
    archive = WORK / f"{name}.tar.gz"
    with urllib.request.urlopen(url, timeout=90) as response:
        body = response.read()
    if hashlib.sha256(body).hexdigest() != digest:
        raise RuntimeError(f"{name} source checksum mismatch")
    archive.write_bytes(body)
    source = WORK / f"{name}-src"
    source.mkdir()
    with tarfile.open(archive) as tar:
        tar.extractall(source, filter="data")
    folders = [p for p in source.iterdir() if p.is_dir()]
    if len(folders) != 1:
        raise RuntimeError(f"Unexpected source archive layout: {name}")
    source = folders[0]
    build = WORK / f"{name}-build"
    build.mkdir()
    flags = shlex.join(["-target", "arm64-apple-ios17.0", "-isysroot", SDK, "-O2", "-fPIC"])
    cc = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--find", "clang"], text=True).strip()
    cpp = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--find", "clang++"], text=True).strip()
    env = dict(ENV, CC=cc, CXX=cpp, CFLAGS=flags, CXXFLAGS=flags, LDFLAGS=flags,
               AR="/usr/bin/ar", RANLIB="/usr/bin/ranlib")
    run([source / "configure", f"--prefix={STAGE}", "--host=aarch64-apple-darwin",
         "--disable-shared", "--enable-static", *options], f"{name}-configure", cwd=build, env=env)
    run(["make", "-j3"], f"{name}-build", cwd=build, env=env)
    run(["make", "install"], f"{name}-install", cwd=build, env=env)
    mark(name, identity)


def main():
    # The SDK supplies libz.tbd and headers, but no pkg-config metadata. Give
    # target-only packages their required zlib entry without using host Homebrew.
    version = re.search(r'^#define ZLIB_VERSION "([^"]+)"',
                        (Path(SDK) / "usr/include/zlib.h").read_text(), re.MULTILINE).group(1)
    pcdir = STAGE / "lib/pkgconfig"
    pcdir.mkdir(parents=True, exist_ok=True)
    (pcdir / "zlib.pc").write_text(
        f"Name: zlib\nDescription: Apple iPhoneOS SDK zlib\nVersion: {version}\nLibs: -lz\nCflags:\n")
    meson("lcms", "https://github.com/mm2/Little-CMS.git", "453bafeb85b4ef96498866b7a8eadcc74dff9223",
          ["-Djpeg=disabled", "-Dtiff=disabled", "-Dutils=false", "-Dsamples=false"])
    autotools("fftw", "https://www.fftw.org/fftw-3.3.10.tar.gz",
              "56c932549852cddcfafdab3820b0200c7742675be92179e59e6215b340e26467",
              ["--enable-float", "--enable-threads", "--disable-fortran"])
    autotools("gsl", "https://ftp.gnu.org/gnu/gsl/gsl-2.8.tar.gz",
              "6a99eeed15632c6354895b1dd542ed5a855c0f15d9ad1326c6fe2b2c9e423190", [])
    cmake("libpng", "https://github.com/pnggroup/libpng.git", "872555f4ba910252783af1507f9e7fe1653be252",
          ["-DPNG_SHARED=OFF", "-DPNG_STATIC=ON", "-DPNG_TESTS=OFF", "-DPNG_TOOLS=OFF"])
    meson("cairo", "https://gitlab.freedesktop.org/cairo/cairo.git", "4541e0cd3a751b85e52e2a83d02ac6145a5efa85",
          ["-Dtests=disabled", "-Dxlib=disabled", "-Dxcb=disabled", "-Dfontconfig=disabled",
           "-Dfreetype=disabled", "-Dquartz=enabled", "-Dpng=enabled", "-Dglib=enabled",
           "-Dlzo=disabled", "-Dspectre=disabled", "-Dsymbol-lookup=disabled", "-Dgtk_doc=false"], ios_frameworks)
    meson("harfbuzz", "https://github.com/harfbuzz/harfbuzz.git", "3ef8709829a5884517ad91a97b32b9435b2f20d1",
          ["-Dglib=enabled", "-Dcoretext=enabled", "-Dcairo=disabled", "-Dfreetype=disabled",
           "-Dgobject=disabled", "-Dicu=disabled", "-Dtests=disabled", "-Ddocs=disabled",
           "-Dutilities=disabled", "-Dintrospection=disabled"])
    meson("pango", "https://github.com/GNOME/pango.git", "5f589a7e0e61dca3f976da172cf55743ace77a38",
          ["-Dbuild-testsuite=false", "-Dbuild-examples=false", "-Dintrospection=disabled",
           "-Ddocumentation=false", "-Dman-pages=false", "-Dfontconfig=disabled", "-Dfreetype=disabled",
           "-Dlibthai=disabled", "-Dxft=disabled", "-Dsysprof=disabled"], ios_frameworks)
    meson("gdk-pixbuf", "https://github.com/GNOME/gdk-pixbuf.git", "e4315fb8553776e13d39e3f2e0ea8792db61720c",
          ["-Dpng=enabled", "-Djpeg=disabled", "-Dtiff=disabled", "-Dgif=disabled", "-Dothers=disabled",
           "-Dbuiltin_loaders=all", "-Dtests=false", "-Dinstalled_tests=false", "-Dintrospection=disabled",
           "-Dgtk_doc=false", "-Dman=false", "-Drelocatable=true"])
    cmake("opencv", "https://github.com/opencv/opencv.git", "31b0eeea0b44b370fd0712312df4214d4ae1b158",
          ["-DBUILD_LIST=core,imgproc,calib3d,stitching", "-DBUILD_TESTS=OFF", "-DBUILD_PERF_TESTS=OFF",
           "-DBUILD_EXAMPLES=OFF", "-DBUILD_opencv_apps=OFF", "-DBUILD_JAVA=OFF", "-DBUILD_opencv_python2=OFF",
           "-DBUILD_opencv_python3=OFF", "-DWITH_IPP=OFF", "-DWITH_OPENCL=OFF", "-DWITH_OPENMP=OFF",
           "-DWITH_TBB=OFF", "-DWITH_FFMPEG=OFF", "-DWITH_AVFOUNDATION=OFF", "-DWITH_GSTREAMER=OFF",
           "-DWITH_GTK=OFF", "-DWITH_QT=OFF", "-DWITH_JPEG=OFF", "-DWITH_PNG=OFF", "-DWITH_TIFF=OFF",
           "-DWITH_WEBP=OFF", "-DWITH_OPENEXR=OFF", "-DWITH_JASPER=OFF", "-DWITH_OPENJPEG=OFF",
           "-DWITH_ITT=OFF", "-DWITH_PROTOBUF=OFF", "-DOPENCV_GENERATE_PKGCONFIG=ON", "-DIOS_INSTALL_COMBINED=OFF"], ios_opencv_metadata)
    run(["pkg-config", "--modversion", "glib-2.0", "gio-2.0", "cairo", "pango", "pangocairo",
         "gdk-pixbuf-2.0", "gsl", "lcms2", "fftw3f", "cfitsio", "opencv4"], "core-dependency-versions")


if __name__ == "__main__":
    main()
