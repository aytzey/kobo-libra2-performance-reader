#!/usr/bin/env python3
import argparse
import os
import struct
import subprocess
import sys
import time
from pathlib import Path


EV_SYN = 0
EV_KEY = 1
EV_ABS = 3
SYN_REPORT = 0
BTN_TOUCH = 330
ABS_PRESSURE = 24
ABS_MT_SLOT = 47
ABS_MT_TOUCH_MAJOR = 48
ABS_MT_POSITION_X = 53
ABS_MT_POSITION_Y = 54
ABS_MT_TRACKING_ID = 57


def event(sec, usec, ev_type, code, value):
    return struct.pack("<llHHi", sec, usec, ev_type, code, value)


def make_tap(screen_x, screen_y, duration_ms, tracking_id):
    # Libra 2 reports touchscreen axes switched relative to KOReader's portrait
    # screen. KOReader then swaps ABS axes without mirroring for Kobo_io.
    touch_x = int(round(screen_y))
    touch_y = int(round(screen_x))
    now = time.time()
    sec = int(now)
    usec = int((now - sec) * 1_000_000)
    up_usec_total = usec + int(duration_ms * 1000)
    up_sec = sec + up_usec_total // 1_000_000
    up_usec = up_usec_total % 1_000_000

    events = [
        event(sec, usec, EV_ABS, ABS_MT_SLOT, 0),
        event(sec, usec, EV_ABS, ABS_MT_TRACKING_ID, tracking_id),
        event(sec, usec, EV_ABS, ABS_MT_POSITION_X, touch_x),
        event(sec, usec, EV_ABS, ABS_MT_POSITION_Y, touch_y),
        event(sec, usec, EV_ABS, ABS_MT_TOUCH_MAJOR, 1),
        event(sec, usec, EV_ABS, ABS_PRESSURE, 800),
        event(sec, usec, EV_KEY, BTN_TOUCH, 1),
        event(sec, usec, EV_SYN, SYN_REPORT, 0),
        event(up_sec, up_usec, EV_ABS, ABS_MT_SLOT, 0),
        event(up_sec, up_usec, EV_ABS, ABS_MT_TOUCH_MAJOR, 0),
        event(up_sec, up_usec, EV_ABS, ABS_PRESSURE, 0),
        event(up_sec, up_usec, EV_ABS, ABS_MT_TRACKING_ID, -1),
        event(up_sec, up_usec, EV_KEY, BTN_TOUCH, 0),
        event(up_sec, up_usec, EV_SYN, SYN_REPORT, 0),
    ]
    return b"".join(events), touch_x, touch_y


def main():
    parser = argparse.ArgumentParser(description="Inject a single Kobo Libra 2 tap over SSH.")
    parser.add_argument("x", type=int, help="portrait screen x coordinate")
    parser.add_argument("y", type=int, help="portrait screen y coordinate")
    parser.add_argument("--host", default=os.environ.get("KOBO_HOST", "192.168.2.2"))
    parser.add_argument("--port", default=os.environ.get("KOBO_PORT", "2222"))
    parser.add_argument("--user", default=os.environ.get("KOBO_USER", "root"))
    parser.add_argument("--key", default=os.environ.get("KOBO_SSH_KEY", ""))
    parser.add_argument("--known-hosts", default=os.environ.get("KOBO_KNOWN_HOSTS", "/tmp/kobo_usb_known_hosts"))
    parser.add_argument("--device", default="/dev/input/event0")
    parser.add_argument("--duration-ms", type=int, default=120)
    parser.add_argument("--tracking-id", type=int, default=91)
    args = parser.parse_args()

    payload, touch_x, touch_y = make_tap(args.x, args.y, args.duration_ms, args.tracking_id)
    cmd = [
        "ssh",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        f"UserKnownHostsFile={args.known_hosts}",
        "-p",
        args.port,
        f"{args.user}@{args.host}",
        f"cat > {args.device}",
    ]
    if args.key:
        key = Path(args.key).expanduser()
        if key.exists():
            cmd[1:1] = ["-i", str(key)]
        else:
            raise FileNotFoundError(f"SSH key not found: {key}")
    subprocess.run(cmd, input=payload, check=True)
    print(f"tap screen=({args.x},{args.y}) touch=({touch_x},{touch_y}) bytes={len(payload)}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        print(f"kobo tap failed: {exc}", file=sys.stderr)
        raise SystemExit(exc.returncode)
