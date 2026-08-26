#!/usr/bin/env python3
"""Assert that Utah actually contains its Bluefin and GNOME 51 RPM contracts."""

from __future__ import annotations

import subprocess
import sys
import tomllib
from pathlib import Path


GNOME_51_PACKAGES = (
    "gnome-control-center",
    "gnome-session",
    "gnome-settings-daemon",
    "gnome-shell",
    "gsettings-desktop-schemas",
    "gtk4",
    "libadwaita",
    "mutter",
    "xdg-desktop-portal",
    "xdg-desktop-portal-gnome",
)


def main() -> int:
    check_only = sys.argv[1] == "--check"
    manifest = Path(sys.argv[2] if check_only else sys.argv[1])
    data = tomllib.loads(manifest.read_text())
    bluefin = data["fedora"]["packages"]
    expected = [*bluefin, *GNOME_51_PACKAGES]
    print(f"Verifying {len(bluefin)} Bluefin packages and {len(GNOME_51_PACKAGES)} GNOME 51 packages")
    if check_only:
        assert len(set(expected)) == len(expected), "RPM contract contains duplicate package names"
        return 0
    return subprocess.run(["rpm", "-qi", *expected], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
