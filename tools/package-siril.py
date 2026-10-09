#!/usr/bin/env python3
"""Package only the static archives actually used by the proven core link."""
import json
from pathlib import Path
import shlex
import shutil
import subprocess

root = Path.cwd()
build = root / "siril-ios-build"
stage = root / "ipados-stage"
out = root / "dist"
headers = out / "Headers"
headers.mkdir(parents=True, exist_ok=True)
commands = subprocess.check_output(
    ["ninja", "-C", str(build), "-t", "commands", "src/siril-ipados-link-probe"], text=True)
link = commands.strip().splitlines()[-1]
tokens = shlex.split(link)
search = [stage / "lib"]
search.extend(Path(token[2:]) for token in tokens if token.startswith("-L"))
archives = []

def add(path):
    path = Path(path)
    if not path.is_absolute():
        path = build / path
    path = path.resolve()
    if not path.is_file():
        raise RuntimeError(f"Link archive missing: {path}")
    if not (path.is_relative_to(build) or path.is_relative_to(stage)):
        raise RuntimeError(f"Unexpected host archive: {path}")
    if path not in archives:
        archives.append(path)

for token in tokens:
    for part in token.split(","):
        if part.endswith(".a"):
            add(part)
    if token.startswith("-l") and len(token) > 2:
        for directory in search:
            candidate = directory / f"lib{token[2:]}.a"
            if candidate.exists():
                add(candidate)
                break
if not any(p.name == "libsiril.a" for p in archives):
    raise RuntimeError("The verified upstream Siril archive is absent")
library = out / "libSirilCore.a"
subprocess.run(["xcrun", "libtool", "-static", "-o", str(library), *map(str, archives)], check=True)
for name in ("SirilCore.h", "module.modulemap"):
    shutil.copy2(root / "native" / name, headers / name)
framework = out / "SirilCore.xcframework"
subprocess.run(["xcodebuild", "-create-xcframework", "-library", str(library),
                "-headers", str(headers), "-output", str(framework)], check=True)
(out / "BUILD.json").write_text(json.dumps({
    "siril_commit": (root / "diagnostics/siril-commit.txt").read_text().strip(),
    "platform": "iOS", "architecture": "arm64", "minimum_os": "17.0",
    "verification": "All compiled upstream core symbols device-linked; not executed on device",
    "archives": [str(p.relative_to(root)) for p in archives],
}, indent=2))
licenses = out / "Licenses"
licenses.mkdir(exist_ok=True)
for name in ("COPYING", "AUTHORS"):
    path = root / "siril-src" / name
    if path.exists():
        shutil.copy2(path, licenses / f"Siril-{name}")
for source in (root / "deps-work").iterdir():
    if source.is_dir() and not source.name.endswith("-build"):
        for pattern in ("COPYING*", "LICENSE*", "Copyright*", "copyright*"):
            for path in source.glob(pattern):
                if path.is_file():
                    shutil.copy2(path, licenses / f"{source.name}-{path.name}")
