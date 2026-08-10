#!/usr/bin/env python3
"""Portable build and deploy entry point for the Kobo Libra 2 overlay."""

from __future__ import annotations

import argparse
import os
import shutil
import string
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent


def _windows_bash_candidates() -> list[Path]:
    candidates: list[Path] = []
    for variable in ("ProgramFiles", "ProgramW6432", "LOCALAPPDATA"):
        value = os.environ.get(variable)
        if not value:
            continue
        base = Path(value)
        candidates.extend((base / "Git" / "bin" / "bash.exe", base / "Git" / "usr" / "bin" / "bash.exe"))
    return candidates


def find_bash() -> str:
    if os.name == "nt":
        candidates = _windows_bash_candidates()
        path_bash = shutil.which("bash")
        if path_bash:
            candidates.append(Path(path_bash))
    else:
        candidates = [Path(shutil.which("bash") or "/bin/bash")]

    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)

    if os.name == "nt":
        raise RuntimeError("Bash was not found. Install Git for Windows, then run this command again.")
    raise RuntimeError("Bash was not found on PATH.")


def _cygpath_for(bash: str) -> str | None:
    candidates = []
    path_cygpath = shutil.which("cygpath")
    if path_cygpath:
        candidates.append(Path(path_cygpath))
    bash_path = Path(bash)
    candidates.extend(
        (
            bash_path.parent / "cygpath.exe",
            bash_path.parent.parent / "usr" / "bin" / "cygpath.exe",
            bash_path.parent.parent / "bin" / "cygpath.exe",
        )
    )
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    return None


def bash_path(path: Path, bash: str) -> str:
    resolved = str(path.resolve())
    if os.name != "nt":
        return resolved

    cygpath = _cygpath_for(bash)
    if cygpath:
        result = subprocess.run(
            [cygpath, "-u", resolved],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    return resolved.replace("\\", "/")


def run_script(script_name: str, args: list[str], env_updates: dict[str, str] | None = None) -> int:
    bash = find_bash()
    command = [bash, bash_path(ROOT / "scripts" / script_name, bash), *args]
    environment = os.environ.copy()
    if env_updates:
        environment.update(env_updates)
    return subprocess.run(command, cwd=ROOT, env=environment, check=False).returncode


def is_kobo_mount(path: Path) -> bool:
    return (path / ".adds" / "koreader").is_dir()


def find_kobo_mount() -> Path | None:
    configured = os.environ.get("KOBO_MOUNT")
    if configured:
        path = Path(configured).expanduser()
        if is_kobo_mount(path):
            return path

    candidates: list[Path] = []
    if os.name == "nt":
        candidates.extend(Path(f"{drive}:\\") for drive in string.ascii_uppercase)
    else:
        user = os.environ.get("USER") or os.environ.get("USERNAME") or ""
        parents = [Path("/Volumes"), Path("/media") / user, Path("/run/media") / user, Path("/mnt")]
        for parent in parents:
            if not parent.is_dir():
                continue
            candidates.extend(child for child in parent.iterdir() if child.is_dir())

    for candidate in candidates:
        if is_kobo_mount(candidate):
            return candidate
    return None


def build(_: argparse.Namespace) -> int:
    return run_script("package-libra2-overlay.sh", [])


def deploy(args: argparse.Namespace) -> int:
    if args.mount and args.usb_ssh:
        raise RuntimeError("Choose either --mount or --usb-ssh, not both.")

    environment: dict[str, str] = {}
    if args.host:
        environment["KOBO_USB_HOST"] = args.host
    if args.port:
        environment["KOBO_USB_PORT"] = str(args.port)
    if args.user:
        environment["KOBO_USB_USER"] = args.user

    if args.usb_ssh:
        script_args: list[str] = []
        if args.zip:
            bash = find_bash()
            script_args.extend(("--zip", bash_path(args.zip, bash)))
        if args.no_package:
            script_args.append("--no-package")
        return run_script("deploy-libra2-overlay-usb-ssh.sh", script_args, environment)

    mount = Path(args.mount).expanduser() if args.mount else find_kobo_mount()
    if not mount:
        raise RuntimeError(
            "Kobo mount not found. Mount the device or use --mount PATH; "
            "for USB/Wi-Fi SSH use --usb-ssh."
        )
    bash = find_bash()
    return run_script("deploy-libra2-overlay.sh", [bash_path(mount, bash)], environment)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(
        prog="kobo",
        description="Build and deploy the Kobo Libra 2 performance overlay.",
    )
    root.add_argument("--version", action="version", version="kobo-libra2-performance-reader 0.1.0")
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("build", help="Build the source overlay ZIP in dist/")

    deploy_parser = commands.add_parser("deploy", help="Deploy to a mounted Kobo or over USB/Wi-Fi SSH")
    deploy_parser.add_argument("--mount", help="Kobo storage mount point; auto-detected when omitted")
    deploy_parser.add_argument("--usb-ssh", action="store_true", help="Deploy through the existing USB/Wi-Fi SSH path")
    deploy_parser.add_argument("--zip", type=Path, default=None, help="Overlay ZIP for SSH deploy")
    deploy_parser.add_argument("--host", help="SSH host, or set KOBO_USB_HOST")
    deploy_parser.add_argument("--port", type=int, help="SSH port, or set KOBO_USB_PORT")
    deploy_parser.add_argument("--user", help="SSH user, or set KOBO_USB_USER")
    deploy_parser.add_argument("--no-package", action="store_true", help="Do not rebuild the overlay for SSH deploy")
    return root


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "build":
            return build(args)
        if args.command == "deploy":
            return deploy(args)
    except (OSError, RuntimeError) as error:
        print(f"kobo: {error}", file=sys.stderr)
        return 2
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
