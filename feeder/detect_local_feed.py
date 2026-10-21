#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Dataero ADSB
#
# Find a local decoder output the Dataero forwarder can READ, without touching
# the decoder: connect to 127.0.0.1:<port> as one more reader (exactly what
# fr24feed, piaware and every other feeder do), look at the bytes for a few
# seconds, disconnect. Nothing is written to the socket.
#
# The format is decided from the data actually received, never from the port
# number alone:
#   beast  - Beast binary frames: 0x1a followed by '1', '2', '3' or '4'
#   raw    - AVR text frames: lines like *8D4840D6202CC371C32CE0576098;
#
# Order: Beast 30005 first (full timing, MLAT possible), then AVR raw 30002
# (Flightradar24's "raw" output; no MLAT). Ports can be overridden:
#   detect_local_feed.py [--host 127.0.0.1] [--beast 30005] [--raw 30002] [--seconds 6]
#
# Prints ONE line on stdout and exits 0:  "beast <port>" | "raw <port>" | "none"
# A port that is open but silent (no aircraft in range yet) is reported as
#   "silent-beast <port>" / "silent-raw <port>" - the caller decides.
import argparse
import re
import socket
import time

AVR_LINE = re.compile(rb"^[*@][0-9A-Fa-f]{14,40};\s*$")


def sample(host, port, seconds):
    """Return (opened, bytes) read from host:port within `seconds`."""
    try:
        s = socket.create_connection((host, port), timeout=2)
    except OSError:
        return False, b""
    data = b""
    s.settimeout(0.5)
    end = time.monotonic() + seconds
    try:
        while time.monotonic() < end and len(data) < 65536:
            try:
                chunk = s.recv(8192)
            except socket.timeout:
                continue
            if not chunk:
                break
            data += chunk
            if looks_beast(data) or looks_raw(data):
                break
    finally:
        s.close()
    return True, data


def looks_beast(data):
    # At least 3 frame starts: escape byte followed by a Beast frame type.
    return len(re.findall(rb"\x1a[1-4]", data)) >= 3


def looks_raw(data):
    lines = [ln for ln in data.split(b"\n") if ln.strip()]
    good = [ln for ln in lines if AVR_LINE.match(ln.strip())]
    return len(good) >= 3 and len(good) * 2 >= len(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--beast", type=int, default=30005)
    ap.add_argument("--raw", type=int, default=30002)
    ap.add_argument("--seconds", type=float, default=6.0)
    a = ap.parse_args()

    silent = None
    opened, data = sample(a.host, a.beast, a.seconds)
    if opened:
        if looks_beast(data):
            print(f"beast {a.beast}")
            return
        if not data:
            silent = f"silent-beast {a.beast}"
    opened, data = sample(a.host, a.raw, a.seconds)
    if opened:
        if looks_raw(data):
            print(f"raw {a.raw}")
            return
        if not data and silent is None:
            silent = f"silent-raw {a.raw}"
    print(silent or "none")


if __name__ == "__main__":
    main()
