#!/usr/bin/env python3
"""Attach our C ABI to a previously patched, pinned upstream Siril checkout."""
from pathlib import Path
import shutil

root = Path.cwd()
source = root / "siril-src"
destination = source / "src/ipados"
destination.mkdir(exist_ok=True)
for name in ("SirilCore.c", "SirilCore.h", "core-link-probe.c"):
    shutil.copy2(root / "native" / name, destination / name)
meson = source / "src/meson.build"
text = meson.read_text()
needle = "siril_lib = static_library('siril',"
assert text.count(needle) == 1, "Pinned upstream static library layout changed"
text = text.replace(needle, "if enable_embedded\n  src_files += files('ipados/SirilCore.c')\nendif\n\n" + needle)
text += """

# Resolve every compiled core symbol against iPadOS and the headless stubs.
# This binary is only link-checked; executing it requires an Apple device.
if enable_embedded
  executable('siril-ipados-link-probe', 'ipados/core-link-probe.c',
    dependencies: siril_dep,
    link_whole: siril_lib,
    link_args: siril_link_arg,
    c_args: siril_c_flag,
    cpp_args: siril_cpp_flag)
endif
"""
meson.write_text(text)
