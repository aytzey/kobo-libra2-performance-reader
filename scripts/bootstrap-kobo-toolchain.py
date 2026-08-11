#!/usr/bin/env python3
"""Provision the pinned Linux-hosted Kobo Libra 2 cross toolchain."""

from __future__ import annotations

import hashlib
import os
import platform
import shutil
import stat
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERSION = "2025.05"
TARGET = "arm-kobov4-linux-gnueabihf"
DEFAULT_URL = (
    "https://github.com/koreader/koxtoolchain/releases/download/"
    f"{VERSION}/kobov4.tar.gz"
)
DEFAULT_SHA256 = "d0a3a450eebf6b67961f5b7302b71deac64db676ca45a6b8210854dceb7a8f7d"


def error(message: str) -> int:
    print(f"kobo toolchain: {message}", file=sys.stderr)
    return 1


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: Path) -> None:
    temporary = destination.with_suffix(destination.suffix + ".part")
    print(f"kobo toolchain: downloading {url}", file=sys.stderr)
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "kobo-libra2-performance-reader"})
        with urllib.request.urlopen(request, timeout=30) as response, temporary.open("wb") as output:
            shutil.copyfileobj(response, output, length=1024 * 1024)
    except OSError as exc:
        temporary.unlink(missing_ok=True)
        raise RuntimeError(f"download failed: {exc}") from exc
    temporary.replace(destination)


def safe_extract(archive: Path, destination: Path) -> None:
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            member_path = Path(member.name)
            if member_path.is_absolute() or ".." in member_path.parts:
                raise RuntimeError(f"unsafe archive entry: {member.name}")
        tar.extractall(destination)


def make_directories_writable(path: Path) -> None:
    for current, _, _ in os.walk(path):
        current_path = Path(current)
        current_path.chmod(current_path.stat().st_mode | stat.S_IWUSR)


def main() -> int:
    if platform.system() != "Linux" or platform.machine().lower() not in {"x86_64", "amd64"}:
        return error(
            "the pinned toolchain runs on Linux x86_64. Use Docker Desktop or WSL2, "
            "or provide KOBO_CC."
        )

    cache = Path(os.environ.get("KOBO_TOOLCHAIN_CACHE", ROOT / "external" / "toolchains"))
    toolchain = Path(
        os.environ.get(
            "KOBO_TOOLCHAIN_DIR",
            cache / f"koxtoolchain-{VERSION}" / TARGET,
        )
    )
    compiler = toolchain / "bin" / f"{TARGET}-gcc"
    if compiler.is_file() and os.access(compiler, os.X_OK):
        print(compiler)
        return 0

    if os.environ.get("KOBO_TOOLCHAIN_AUTO_FETCH", "1") == "0":
        return error(f"compiler not found at {compiler}; unset KOBO_TOOLCHAIN_AUTO_FETCH or set KOBO_CC")
    if toolchain.exists():
        return error(f"incomplete toolchain directory at {toolchain}; remove it and run the command again")

    archive_override = "KOBO_TOOLCHAIN_ARCHIVE" in os.environ
    archive = Path(
        os.environ.get(
            "KOBO_TOOLCHAIN_ARCHIVE",
            cache / "downloads" / f"kobov4-{VERSION}.tar.gz",
        )
    )
    url = os.environ.get("KOBO_TOOLCHAIN_URL", DEFAULT_URL)
    expected_sha256 = os.environ.get("KOBO_TOOLCHAIN_SHA256", DEFAULT_SHA256).lower()
    archive.parent.mkdir(parents=True, exist_ok=True)

    actual_sha256 = sha256(archive) if archive.is_file() else None
    if actual_sha256 is not None and actual_sha256 != expected_sha256 and archive_override:
        return error(f"SHA-256 mismatch for {archive}")
    if actual_sha256 != expected_sha256:
        if not archive_override:
            archive.unlink(missing_ok=True)
        try:
            download(url, archive)
        except RuntimeError as exc:
            return error(str(exc))
        actual_sha256 = sha256(archive)
    if actual_sha256 != expected_sha256:
        if not archive_override:
            archive.unlink(missing_ok=True)
        return error(f"SHA-256 mismatch for {archive.name}: got {actual_sha256}")

    toolchain.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".koxtoolchain-", dir=toolchain.parent) as temporary:
        temporary_path = Path(temporary)
        try:
            safe_extract(archive, temporary_path)
            make_directories_writable(temporary_path)
        except (OSError, tarfile.TarError, RuntimeError) as exc:
            return error(f"extract failed: {exc}")
        extracted = temporary_path / "x-tools" / TARGET
        extracted_compiler = extracted / "bin" / f"{TARGET}-gcc"
        if not extracted_compiler.is_file():
            return error(f"archive does not contain {TARGET}")
        os.replace(extracted, toolchain)

    if not compiler.is_file() or not os.access(compiler, os.X_OK):
        return error(f"compiler was not installed at {compiler}")
    print(compiler)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
