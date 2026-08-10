#!/usr/bin/env python3
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image


def main():
    parser = argparse.ArgumentParser(description="Capture Kobo Libra 2 framebuffer over SSH.")
    parser.add_argument("--host", default=os.environ.get("KOBO_HOST", "192.168.2.2"))
    parser.add_argument("--port", default=os.environ.get("KOBO_PORT", "2222"))
    parser.add_argument("--user", default=os.environ.get("KOBO_USER", "root"))
    parser.add_argument("--key", default=os.environ.get("KOBO_SSH_KEY", ""))
    parser.add_argument("--known-hosts", default=os.environ.get("KOBO_KNOWN_HOSTS", "/tmp/kobo_usb_known_hosts"))
    parser.add_argument("--out-dir", default="captures/kobo")
    parser.add_argument("--name", default="")
    args = parser.parse_args()

    cmd = [
        "ssh",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        f"UserKnownHostsFile={args.known_hosts}",
        "-p",
        args.port,
        f"{args.user}@{args.host}",
        "dd if=/dev/fb0 bs=1280 count=1680 2>/dev/null",
    ]
    if args.key:
        key = Path(args.key).expanduser()
        if key.exists():
            cmd[1:1] = ["-i", str(key)]
        else:
            raise FileNotFoundError(f"SSH key not found: {key}")
    raw = subprocess.check_output(cmd)
    if len(raw) < 1280 * 1680:
        raise RuntimeError(f"short framebuffer read: {len(raw)} bytes")

    width, height, stride = 1264, 1680, 1280
    pixels = bytearray(width * height)
    for y in range(height):
        src = y * stride
        dst = y * width
        pixels[dst : dst + width] = raw[src : src + width]

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    stem = args.name or f"kobo-{stamp}"
    path = out_dir / f"{stem}.png"
    Image.frombytes("L", (width, height), bytes(pixels)).save(path)
    print(path)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"kobo capture failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
