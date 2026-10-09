#!/usr/bin/env python3
"""Run real FITS arithmetic checks and launch the native App on an iPad simulator."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

root = Path.cwd()
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
sdk_version = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip()
expected_runtime = "iOS-" + sdk_version.replace(".", "-")
available = [(runtime, device) for runtime, group in devices["devices"].items() for device in group
             if device["isAvailable"] and device["name"].startswith("iPad")]
if not available:
    raise RuntimeError("No installed iPad simulator runtime")
available.sort(key=lambda pair: (not pair[0].endswith(expected_runtime), pair[1]["state"] != "Booted"))
runtime, device = available[0]
udid = device["udid"]
print(f"Testing on {device['name']} ({udid}), runtime {runtime}, SDK {sdk_version}", flush=True)
if device["state"] != "Booted":
    subprocess.run(["xcrun", "simctl", "boot", udid], check=True, timeout=90)
try:
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, timeout=180)
except subprocess.TimeoutExpired:
    # Some CI images leave bootstatus waiting for unrelated data migration.
    # A Booted device can still execute the engine and App checks below.
    state = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"], text=True))
    booted = any(d["udid"] == udid and d["state"] == "Booted"
                 for group in state["devices"].values() for d in group)
    if not booted:
        raise RuntimeError("iPad simulator did not boot within 180 seconds")
    print("bootstatus timed out; testing the Booted device directly", flush=True)
directory = tempfile.mkdtemp(prefix="siril-numeric-")
command = ["xcrun", "simctl", "spawn", udid, str(root / "siril-ios-build/src/siril-ipados-runtime-tests"), directory]
result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
(root / "diagnostics/core-runtime-tests.log").write_text(result.stdout)
print(result.stdout, flush=True)
result.check_returncode()
subprocess.run(["xcrun", "simctl", "install", udid,
                str(root / "app-build/Build/Products/Release-iphonesimulator/SirilPad.app")], check=True, timeout=90)
result = subprocess.run(["xcrun", "simctl", "launch", udid, "com.backermrw.sirilpad"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True,
                        env=dict(os.environ, SIMCTL_CHILD_SIRIL_SELF_TEST="1"), timeout=90)
print(result.stdout, flush=True)
pid = result.stdout.strip().split(":")[-1].strip()
container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", udid,
                                         "com.backermrw.sirilpad", "data"], text=True).strip())
report = container / "Documents/simulator-app-selftest.txt"
deadline = time.monotonic() + 60
while not report.exists() and time.monotonic() < deadline:
    os.kill(int(pid), 0)
    time.sleep(1)
if not report.exists():
    raise RuntimeError("Native App did not finish its FITS/preview check within 60 seconds")
text = report.read_text()
print(text, flush=True)
(root / "diagnostics/app-launch-check.txt").write_text(text)
if not text.startswith("PASS:"):
    raise RuntimeError(text)
subprocess.run(["xcrun", "simctl", "io", udid, "screenshot",
                str(root / "diagnostics/native-app-simulator.png")], check=True)
