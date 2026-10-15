#!/usr/bin/env python3
"""Run real FITS arithmetic checks and launch the native App on an iPad simulator."""
import json
import http.server
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading
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
device_type = device.get("deviceTypeIdentifier")
if not device_type:
    types = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devicetypes", "--json"], text=True, timeout=60))
    device_type = next((t["identifier"] for t in types["devicetypes"] if t["name"] == device["name"]), None)
if not device_type:
    raise RuntimeError("Cannot identify the installed iPad device type")
# CI snapshots can have a Booted preinstalled device whose app-launch service
# stalls even while simctl spawn runs C tests. Use fresh data for this job.
udid = subprocess.check_output(["xcrun", "simctl", "create", "Siril regression", device_type, runtime], text=True, timeout=60).strip()
print(f"Testing on {device['name']} ({udid}), runtime {runtime}, SDK {sdk_version}", flush=True)
subprocess.run(["xcrun", "simctl", "boot", udid], check=True, timeout=90)
subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, timeout=180)
directory = tempfile.mkdtemp(prefix="siril-numeric-")
tls = Path(directory)
(tls / "openssl.cnf").write_text("""[req]
distinguished_name = dn
x509_extensions = extensions
prompt = no
[dn]
CN = localhost
[extensions]
subjectAltName = DNS:localhost
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage = serverAuth
""")
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(tls / "key.pem"), "-out", str(tls / "root.pem"),
                "-days", "1", "-config", str(tls / "openssl.cnf")], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
class CatalogFixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"siril-catalog-tls-fixture\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), CatalogFixture)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(tls / "root.pem", tls / "key.pem")
server.socket = context.wrap_socket(server.socket, server_side=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
command = ["xcrun", "simctl", "spawn", udid, str(root / "siril-ios-build/src/siril-ipados-runtime-tests"), directory]
try:
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180,
        env=dict(os.environ, SIMCTL_CHILD_CURL_CA_BUNDLE=str(tls / "root.pem"),
                 SIMCTL_CHILD_XDG_DATA_HOME=str(tls / "data"),
                 SIMCTL_CHILD_XDG_CONFIG_HOME=str(tls / "config"),
                 SIMCTL_CHILD_XDG_CACHE_HOME=str(tls / "cache"),
                 SIMCTL_CHILD_SIRIL_SPCC_DIR=str(root / "app/Resources/SPCC"),
                 SIMCTL_CHILD_SIRIL_FORMAT_FIXTURES=str(root / "app/TestAssets"),
                 SIMCTL_CHILD_SIRIL_TLS_TEST_URL=f"https://localhost:{server.server_port}/catalog",
                 SIMCTL_CHILD_SIRIL_TLS_WRONG_HOST=f"https://127.0.0.1:{server.server_port}/catalog",
                 SIMCTL_CHILD_SIRIL_TLS_UNTRUSTED_CA=str(root / "app/Resources/cacert.pem")))
finally:
    server.shutdown()
    server.server_close()
(root / "diagnostics/core-runtime-tests.log").write_text(result.stdout)
print(result.stdout, flush=True)
result.check_returncode()
subprocess.run(["xcrun", "simctl", "install", udid,
                str(root / "app-build/Build/Products/Release-iphonesimulator/SirilPad.app")], check=True, timeout=90)
container = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", udid,
                                         "com.backermrw.sirilpad", "data"], text=True, timeout=45).strip())
for name in ("simulator-app-selftest.txt", "simulator-app-selftest-progress.txt", "simulator-background-ready.txt", "simulator-analysis-ready.txt"):
    (container / "Documents" / name).unlink(missing_ok=True)
report = container / "Documents/simulator-app-selftest.txt"
def capture_selftest_progress():
    progress = container / "Documents/simulator-app-selftest-progress.txt"
    if progress.exists():
        (root / "diagnostics/simulator-app-selftest-progress.txt").write_bytes(progress.read_bytes())
        print(progress.read_text(), flush=True)

launch_outputs = []
for attempt, seconds in enumerate((90, 180), start=1):
    launch = subprocess.Popen(["xcrun", "simctl", "launch", udid, "com.backermrw.sirilpad"],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                              env=dict(os.environ, SIMCTL_CHILD_SIRIL_SELF_TEST="1"))
    deadline = time.monotonic() + seconds
    while not report.exists() and time.monotonic() < deadline:
        if launch.poll() is not None and launch.returncode != 0:
            break
        time.sleep(1)
    try:
        output, _ = launch.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        # Stop only the stalled simctl client. Do not restart an executing App
        # or overwrite its report; an actual FAIL remains a hard failure.
        launch.terminate()
        output, _ = launch.communicate(timeout=10)
    launch_outputs.append(output)
    print(output, flush=True)
    if report.exists():
        break
    crashes = list((Path.home() / "Library/Logs/DiagnosticReports").glob("SirilPad*.ips"))
    if crashes:
        capture_selftest_progress()
        progress = container / "Documents/native-tool-tests.log"
        if progress.exists():
            (root / "diagnostics/native-tool-tests.log").write_bytes(progress.read_bytes())
            print(progress.read_text(), flush=True)
        for path in crashes:
            (root / "diagnostics" / path.name).write_bytes(path.read_bytes())
        raise RuntimeError("Native App crashed before producing its self-check report")
    if attempt == 1:
        print("First CoreSimulator launch did not produce a report; retrying the launch client once", flush=True)
(root / "diagnostics/app-launch-client.log").write_text("\n".join(launch_outputs))
capture_selftest_progress()
if not report.exists():
    progress = container / "Documents/native-tool-tests.log"
    if progress.exists():
        (root / "diagnostics/native-tool-tests.log").write_bytes(progress.read_bytes())
        print(progress.read_text(), flush=True)
    # Capture actual native stacks on a timeout instead of guessing which
    # worker or event-loop dependency blocked the application.
    try:
        pids = subprocess.check_output(["pgrep", "-x", "SirilPad"], text=True, timeout=10).split()
        for pid in pids[:2]:
            subprocess.run(["sample", pid, "3", "1", "-file", str(root / f"diagnostics/app-hang-{pid}.txt")], timeout=15)
    except (subprocess.SubprocessError, OSError):
        pass
    try:
        system_log = subprocess.run(["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "5m", "--style", "compact",
            "--predicate", 'process == "SirilPad" OR process == "SpringBoard" OR eventMessage CONTAINS[c] "com.backermrw.sirilpad"'],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
        (root / "diagnostics/app-system-log.txt").write_text(system_log.stdout)
    except (subprocess.SubprocessError, OSError) as error:
        (root / "diagnostics/app-system-log.txt").write_text(str(error))
    subprocess.run(["xcrun", "simctl", "io", udid, "screenshot",
                    str(root / "diagnostics/app-launch-failure.png")], timeout=30)
    for path in (Path.home() / "Library/Logs/DiagnosticReports").glob("SirilPad*.ips"):
        (root / "diagnostics" / path.name).write_bytes(path.read_bytes())
    raise RuntimeError("Native App did not produce its numerical self-check report within 180 seconds")
text = report.read_text()
tool_report = container / "Documents/native-tool-tests.log"
if tool_report.exists():
    (root / "diagnostics/native-tool-tests.log").write_bytes(tool_report.read_bytes())
print(text, flush=True)
(root / "diagnostics/app-launch-check.txt").write_text(text)
if not text.startswith("PASS:"):
    if tool_report.exists():
        print(tool_report.read_text(), flush=True)
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
for tab, screenshot in ((0, "native-analysis-simulator.png"), (1, "native-histogram-simulator.png"), (2, "native-header-simulator.png"), (3, "native-stars-simulator.png"), (2, "native-keyword-editor-simulator.png")):
    subprocess.run(["xcrun", "simctl", "terminate", udid, "com.backermrw.sirilpad"], check=True, timeout=30)
    editor_check = "keyword-editor" in screenshot
    ready = container / ("Documents/simulator-keyword-ready.txt" if editor_check else "Documents/simulator-analysis-ready.txt")
    ready.unlink(missing_ok=True)
    launch = subprocess.Popen(["xcrun", "simctl", "launch", udid, "com.backermrw.sirilpad"],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                              env=dict(os.environ, SIMCTL_CHILD_SIRIL_SELF_TEST="0", SIMCTL_CHILD_SIRIL_ANALYSIS_VIEW_CHECK="1",
                                       SIMCTL_CHILD_SIRIL_ANALYSIS_TAB=str(tab), SIMCTL_CHILD_SIRIL_KEYWORD_VIEW_CHECK="1" if editor_check else "0"))
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
        raise RuntimeError(f"Native selected-image analysis workspace tab {tab} did not load")
    text = ready.read_text()
    if not text.startswith("PASS: native FITS keyword editor" if editor_check else f"PASS: native analysis workspace tab {tab} "):
        raise RuntimeError(text)
    print(text, flush=True)
    (root / ("diagnostics/keyword-editor-check.txt" if editor_check else f"diagnostics/analysis-workspace-{tab}-check.txt")).write_text(text)
    time.sleep(1)
    subprocess.run(["xcrun", "simctl", "io", udid, "screenshot",
                    str(root / "diagnostics" / screenshot)], check=True, timeout=30)

# Load deletion/restore controls and the processing undo workspace in the real App.
for feature in ("workspace", "storage", "batch", "batch-registration", "batch-stacking", "batch-drizzle", "sequence-frames", "sequence-crop", "sequence-pattern", "sequence-pattern-kombat", "sequence-pattern-single-star", "sequence-quality", "sequence-registration", "sequence-apply", "sequence-background", "sequence-photometry", "sequence-outputs", "sequence-results", "tools-ghs", "tools-masks", "tools-filters", "tools-geometry", "tools-curves", "tools-pixelmath", "tools-fft", "tools-fft-phase", "tools-fft-inverse", "tools-deconv", "tools-deconv-psf", "tools-platesolve", "tools-pcc", "tools-spcc", "tools-icc", "tools-icc-plot", "tools-linear-match", "tools-color-calibration", "tools-roi", "tools-rotational-gradient"):
    subprocess.run(["xcrun", "simctl", "terminate", udid, "com.backermrw.sirilpad"], check=True, timeout=30)
    ready = container / f"Documents/simulator-{feature}-ready.txt"
    ready.unlink(missing_ok=True)
    environment = dict(os.environ, SIMCTL_CHILD_SIRIL_SELF_TEST="0", SIMCTL_CHILD_SIRIL_ANALYSIS_VIEW_CHECK="0")
    if feature.startswith("tools-"):
        environment["SIMCTL_CHILD_SIRIL_NATIVE_TOOL_VIEW_CHECK"] = "1"
        environment["SIMCTL_CHILD_SIRIL_NATIVE_TOOL_SECTION"] = feature.removeprefix("tools-")
    elif feature.startswith("batch"):
        environment["SIMCTL_CHILD_SIRIL_BATCH_VIEW_CHECK"] = "1"
        environment["SIMCTL_CHILD_SIRIL_BATCH_SECTION"] = feature
    elif feature.startswith("sequence-"):
        environment["SIMCTL_CHILD_SIRIL_SEQUENCE_VIEW_CHECK"] = "1"
        environment["SIMCTL_CHILD_SIRIL_SEQUENCE_SECTION"] = feature.removeprefix("sequence-")
    else:
        environment["SIMCTL_CHILD_SIRIL_" + feature.upper() + "_VIEW_CHECK"] = "1"
    launch = subprocess.Popen(["xcrun", "simctl", "launch", udid, "com.backermrw.sirilpad"],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=environment)
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
    if not ready.exists() or not ready.read_text().startswith("PASS:"):
        raise RuntimeError(f"Native {feature} view failed to load")
    (root / f"diagnostics/{feature}-view-check.txt").write_text(ready.read_text())
    time.sleep(1)
    subprocess.run(["xcrun", "simctl", "io", udid, "screenshot",
                    str(root / f"diagnostics/native-{feature}-simulator.png")], check=True, timeout=30)
