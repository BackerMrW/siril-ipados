#!/usr/bin/env python3
"""Bundle pinned original spectral data; iPadOS never launches git at runtime."""
from pathlib import Path
import json
import shutil
import subprocess
from pinned_source import fetch_pinned

root = Path.cwd()
source = root / "deps-work/spcc-data"
revision = "87af70a92ec1d0ff780bd3ea833aaa7b3b169cc2"
fetch_pinned(source, "https://gitlab.com/free-astro/siril-spcc-database.git", revision)
actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
assert actual == revision
destination = root / "app/Resources/SPCC"
destination.mkdir(parents=True, exist_ok=True)
count = 0
models = {}
for file in source.rglob("*.json"):
    if ".git" in file.parts or "schema" in file.name:
        continue
    target = destination / file.relative_to(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(file, target)
    for item in json.loads(file.read_text(encoding="utf-8")):
        kind = item["type"]
        key = item["model"] if kind == "OSC_SENSOR" else item["name"]
        if kind == "MONO_FILTER":
            channel = item.get("channel", "")
            for colour in ("RED", "GREEN", "BLUE"):
                if channel == "ALL" or colour in channel:
                    models.setdefault(kind + "_" + colour, set()).add(key)
        else:
            models.setdefault(kind, set()).add(key)
    count += 1
assert count > 0, "Pinned SPCC database contains no spectral files"
(destination / "UPSTREAM-REVISION.txt").write_text(revision + "\n")
(destination / "models-index.schema.json").write_text(json.dumps(
    {kind: sorted(names) for kind, names in models.items()}, ensure_ascii=False, indent=2), encoding="utf-8")
licenses = root / "ThirdPartyLicenses/Siril-SPCC-database"
licenses.mkdir(parents=True, exist_ok=True)
for pattern in ("LICENSE*", "COPYING*", "README*"):
    for file in source.glob(pattern):
        if file.is_file():
            shutil.copy2(file, licenses / file.name)
print(f"PASS: bundled {count} original SPCC database files at {revision}")
