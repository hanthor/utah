#!/usr/bin/env python3
"""Install Bluefin's Fedora package contract from the checked-in TOML manifest."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path


def packages(path: Path) -> list[str]:
    data = tomllib.loads(path.read_text())
    return list(data["fedora"]["packages"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    selected = packages(args.manifest)
    if not selected:
        raise ValueError("Bluefin package manifest is empty")
    if args.check:
        print(f"validated {len(selected)} Bluefin parity packages")
        return 0
    dnf = shutil.which("dnf5") or shutil.which("dnf")
    if not dnf:
        raise RuntimeError("Hummingbird base does not provide dnf or dnf5")
    return subprocess.run([dnf, "-y", "install", *selected], check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
