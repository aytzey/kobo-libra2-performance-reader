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
CONTAINERFILE = ROOT / "Dockerfile.kobo-build"
CONTAINER_IMAGE = "kobo-libra2-performance-reader-build:2025.05"


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


def use_container() -> bool:
    requested = os.environ.get("KOBO_USE_CONTAINER")
    if requested is not None:
        return requested.lower() not in {"0", "false", "no"}
    if os.environ.get("KOBO_SKIP_NATIVE") == "1":
        return False
    return sys.platform != "linux"


def container_runtime() -> str:
    for candidate in ("docker", "podman"):
        executable = shutil.which(candidate)
        if executable:
            return executable
    raise RuntimeError(
        "Native Kobo builds require Docker Desktop or WSL2 on this host. "
        "Install one, or set KOBO_SKIP_NATIVE=1 for a source-only overlay."
    )


def container_mount(path: Path, destination: str) -> list[str]:
    return ["--mount", f"type=bind,src={path.resolve()},dst={destination}"]


def run_container_script(
    script_name: str,
    args: list[str],
    env_updates: dict[str, str] | None,
    extra_mounts: list[tuple[Path, str]],
) -> int:
    runtime = container_runtime()
    build = subprocess.run(
        [runtime, "build", "--tag", CONTAINER_IMAGE, "--file", str(CONTAINERFILE), str(ROOT)],
        cwd=ROOT,
        check=False,
    )
    if build.returncode:
        return build.returncode

    environment = os.environ.copy()
    if env_updates:
        environment.update(env_updates)
    command = [runtime, "run", "--rm", *container_mount(ROOT, "/workspace"), "-w", "/workspace"]
    for mount_path, destination in extra_mounts:
        command.extend(container_mount(mount_path, destination))
    if os.name != "nt" and hasattr(os, "getuid"):
        command.extend(("--user", f"{os.getuid()}:{os.getgid()}"))
    for name in ("KOBO_SKIP_NATIVE", "KOBO_TOOLCHAIN_AUTO_FETCH", "KOBO_TOOLCHAIN_URL", "KOBO_TOOLCHAIN_SHA256"):
        value = environment.get(name)
        if value is not None:
            command.extend(("--env", f"{name}={value}"))
    command.extend((CONTAINER_IMAGE, "bash", f"scripts/{script_name}", *args))
    return subprocess.run(command, cwd=ROOT, check=False).returncode


def run_script(
    script_name: str,
    args: list[str],
    env_updates: dict[str, str] | None = None,
    extra_mounts: list[tuple[Path, str]] | None = None,
) -> int:
    if use_container():
        return run_container_script(script_name, args, env_updates, extra_mounts or [])
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
        extra_mounts: list[tuple[Path, str]] = []
        if args.zip:
            zip_path = args.zip.resolve()
            try:
                relative_zip = zip_path.relative_to(ROOT)
            except ValueError:
                if use_container():
                    extra_mounts.append((zip_path.parent, "/overlay-input"))
                    script_args.extend(("--zip", f"/overlay-input/{zip_path.name}"))
                else:
                    bash = find_bash()
                    script_args.extend(("--zip", bash_path(zip_path, bash)))
            else:
                script_args.extend(("--zip", f"/workspace/{relative_zip.as_posix()}" if use_container() else bash_path(zip_path, find_bash())))
        if args.no_package:
            script_args.append("--no-package")
        return run_script("deploy-libra2-overlay-usb-ssh.sh", script_args, environment, extra_mounts)

    mount = Path(args.mount).expanduser() if args.mount else find_kobo_mount()
    if not mount:
        raise RuntimeError(
            "Kobo mount not found. Mount the device or use --mount PATH; "
            "for USB/Wi-Fi SSH use --usb-ssh."
        )
    if use_container():
        return run_script("deploy-libra2-overlay.sh", ["/kobo"], environment, [(mount, "/kobo")])
    bash = find_bash()
    return run_script("deploy-libra2-overlay.sh", [bash_path(mount, bash)], environment)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(
        prog="kobo",
        description="Build and deploy the Kobo Libra 2 performance overlay.",
    )
    root.add_argument("--version", action="version", version="kobo-libra2-performance-reader 0.1.2")
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
