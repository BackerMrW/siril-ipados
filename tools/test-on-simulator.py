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
container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", udid,
                                         "com.backermrw.sirilpad", "data"], text=True, timeout=45).strip())
for name in ("simulator-app-selftest.txt", "simulator-background-ready.txt", "simulator-analysis-ready.txt"):
    (container / "Documents" / name).unlink(missing_ok=True)
launch = subprocess.Popen(["xcrun", "simctl", "launch", udid, "com.backermrw.sirilpad"],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                          env=dict(os.environ, SIMCTL_CHILD_SIRIL_SELF_TEST="1"))
report = container / "Documents/simulator-app-selftest.txt"
deadline = time.monotonic() + 180
while not report.exists() and time.monotonic() < deadline:
    if launch.poll() is not None and launch.returncode != 0:
        break
    time.sleep(1)
try:
    output, _ = launch.communicate(timeout=10)
except subprocess.TimeoutExpired:
    # CoreSimulator's launch client can stall after starting the App. The App's
    # own numerical report and loaded-view marker are the required success gates.
    launch.terminate()
    output, _ = launch.communicate(timeout=10)
print(output, flush=True)
if not report.exists():
    subprocess.run(["xcrun", "simctl", "io", udid, "screenshot",
                    str(root / "diagnostics/app-launch-failure.png")], timeout=30)
    for path in (Path.home() / "Library/Logs/DiagnosticReports").glob("SirilPad*.ips"):
        (root / "diagnostics" / path.name).write_bytes(path.read_bytes())
    raise RuntimeError("Native App did not produce its numerical self-check report within 180 seconds")
text = report.read_text()
print(text, flush=True)
(root / "diagnostics/app-launch-check.txt").write_text(text)
if not text.startswith("PASS:"):
    raise RuntimeError(text)
ready = container / "Documents/simulator-background-ready.txt"
deadline = time.monotonic() + 30
while not ready.exists() and time.monotonic() < deadline:
    time.sleep(1)
if not ready.exists():
    raise RuntimeError("Interactive background view did not load its image and sample overlay")
print(ready.read_text(), flush=True)
# Let the displayed sample overlay finish a layout pass before capturing it.
time.sleep(1)
subprocess.run(["xcrun", "simctl", "io", udid, "screenshot",
                str(root / "diagnostics/native-app-simulator.png")], check=True)
# Open the shared analysis workspace on the persisted gradient, with a visible
# selection. This launch checks its real SwiftUI/Canvas layout separately from
# the numerical actor checks above, without re-running the processing pipeline.
subprocess.run(["xcrun", "simctl", "terminate", udid, "com.backermrw.sirilpad"], check=True, timeout=30)
launch = subprocess.Popen(["xcrun", "simctl", "launch", udid, "com.backermrw.sirilpad"],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                          env=dict(os.environ, SIMCTL_CHILD_SIRIL_SELF_TEST="0", SIMCTL_CHILD_SIRIL_ANALYSIS_VIEW_CHECK="1"))
ready = container / "Documents/simulator-analysis-ready.txt"
deadline = time.monotonic() + 90
while not ready.exists() and time.monotonic() < deadline:
    if launch.poll() is not None and launch.returncode != 0:
        break
    time.sleep(1)
try:
    output, _ = launch.communicate(timeout=10)
except subprocess.TimeoutExpired:
    launch.terminate()
    output, _ = launch.communicate(timeout=10)
print(output, flush=True)
if not ready.exists():
    subprocess.run(["xcrun", "simctl", "io", udid, "screenshot",
                    str(root / "diagnostics/analysis-launch-failure.png")], timeout=30)
    raise RuntimeError("Native selected-image analysis workspace did not load its statistics, histogram and image")
text = ready.read_text()
print(text, flush=True)
(root / "diagnostics/analysis-workspace-check.txt").write_text(text)
time.sleep(1)
subprocess.run(["xcrun", "simctl", "io", udid, "screenshot",
                str(root / "diagnostics/native-analysis-simulator.png")], check=True, timeout=30)
