#!/usr/bin/env python3
"""Run real FITS arithmetic checks and launch the native App on an iPad simulator."""
import json
from pathlib import Path
import subprocess
import tempfile
import time

root = Path.cwd()
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
available = [device for group in devices["devices"].values() for device in group
             if device["isAvailable"] and device["name"].startswith("iPad")]
if not available:
    raise RuntimeError("No installed iPad simulator runtime")
device = available[0]
udid = device["udid"]
print(f"Testing on {device['name']} ({udid})", flush=True)
if device["state"] != "Booted":
    subprocess.run(["xcrun", "simctl", "boot", udid], check=True)
subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True)
directory = tempfile.mkdtemp(prefix="siril-numeric-")
command = ["xcrun", "simctl", "spawn", udid, str(root / "siril-ios-build/src/siril-ipados-runtime-tests"), directory]
result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
(root / "diagnostics/core-runtime-tests.log").write_text(result.stdout)
print(result.stdout, flush=True)
result.check_returncode()
subprocess.run(["xcrun", "simctl", "install", udid,
                str(root / "app-build/Build/Products/Release-iphonesimulator/SirilPad.app")], check=True)
result = subprocess.run(["xcrun", "simctl", "launch", udid, "com.backermrw.sirilpad"],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True)
print(result.stdout, flush=True)
pid = result.stdout.strip().split(":")[-1].strip()
# Catch immediate process death after the SwiftUI scene starts.
time.sleep(5)
subprocess.run(["xcrun", "simctl", "spawn", udid, "/bin/kill", "-0", pid], check=True)
(root / "diagnostics/app-launch-check.txt").write_text(
    f"PASS: {device['name']}; App launched and remained alive after 5 seconds. File picker and physical-device operation still need device verification.\n")
