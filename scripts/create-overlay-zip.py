#!/usr/bin/env python3
"""Create the overlay archive without requiring a host zip executable."""

from __future__ import annotations

import sys
import zipfile
from pathlib import Path


def main() -> int:
    source = Path(sys.argv[1])
    output = Path(sys.argv[2])
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(source.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(source).as_posix())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
