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

NVIDIA_PACKAGES = (
    "nvidia-driver",
    "nvidia-driver-cuda",
    "nvidia-container-toolkit",
)


def main() -> int:
    check_only = sys.argv[1] == "--check"
    manifest = Path(sys.argv[2] if check_only else sys.argv[1])
    data = tomllib.loads(manifest.read_text())
    bluefin = data["fedora"]["packages"]
    flavor = __import__("os").environ.get("IMAGE_FLAVOR", "main")
    nvidia = NVIDIA_PACKAGES if "nvidia" in flavor else ()
    expected = [*bluefin, *GNOME_51_PACKAGES, *nvidia]
    print(
        f"Verifying {len(bluefin)} Bluefin packages, {len(GNOME_51_PACKAGES)} GNOME 51 packages"
        f", and {len(nvidia)} NVIDIA packages"
    )
    if check_only:
        assert len(set(expected)) == len(expected), "RPM contract contains duplicate package names"
        return 0
    result = subprocess.run(["rpm", "-qi", *expected], check=False).returncode
    if result or "nvidia" not in flavor:
        return result
    if flavor == "nvidia-gaming":
        release = Path("/usr/lib/utah/ogc-kernel-release").read_text().strip()
        module = Path(f"/usr/lib/modules/{release}/extra/nvidia/nvidia.ko")
        return 0 if module.exists() else 1
    return subprocess.run(["rpm", "-qi", "kmod-nvidia"], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
