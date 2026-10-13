#!/usr/bin/env python3
"""Fetch an exact source commit with bounded retries for transient server errors."""
import argparse
from pathlib import Path
import re
import subprocess
import time

def fetch_pinned(directory, url, revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Source revision must be a full commit SHA")
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", str(directory)], check=True)
    command = ["git", "-C", str(directory), "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=30",
               "fetch", "--depth", "1", url, revision]
    for attempt in range(3):
        try:
            subprocess.run(command, check=True, timeout=90)
            break
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            if attempt == 2:
                raise
            print(f"Pinned source download failed; retry {attempt + 2}/3", flush=True)
            time.sleep(2 * (attempt + 1))
    actual = subprocess.check_output(["git", "-C", str(directory), "rev-parse", "FETCH_HEAD"], text=True).strip()
    if actual != revision:
        raise RuntimeError(f"Pinned source mismatch: expected {revision}, received {actual}")
    subprocess.run(["git", "-C", str(directory), "checkout", "--detach", revision], check=True)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--url", required=True)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    fetch_pinned(args.directory, args.url, args.revision)
