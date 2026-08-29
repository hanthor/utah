#!/usr/bin/env python3
"""Assert that Utah actually contains its Bluefin and GNOME 51 RPM contracts.

Mirrors assert_packages_present from projectbluefin/bluefin's
build_files/shared/package-lib.sh: name every missing package, once.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tomllib
from pathlib import Path

NVIDIA_PACKAGES = (
    "nvidia-driver",
    "nvidia-driver-cuda",
    "nvidia-container-toolkit",
)


def section(path: Path, name: str) -> list[str]:
    data = tomllib.loads(path.read_text())
    return list(data.get(name, {}).get("packages", []))


def is_installed(pkg: str) -> bool:
    return subprocess.run(
        ["rpm", "-q", pkg], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    ).returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("overlay", type=Path, nargs="?", default=None)
    args = parser.parse_args()
    overlay = args.overlay or args.manifest.with_name("utah.toml")

    flavor = os.environ.get("IMAGE_FLAVOR", "main")
    unavailable = set(section(overlay, "unavailable"))
    bluefin = [p for p in section(args.manifest, "fedora") if p not in unavailable]
    gnome = section(overlay, "gnome")
    nvidia = list(NVIDIA_PACKAGES) if "nvidia" in flavor else []
    expected = [*bluefin, *gnome, *nvidia]

    print(
        f"Verifying {len(bluefin)} Bluefin packages, {len(gnome)} GNOME desktop packages"
        f", and {len(nvidia)} NVIDIA packages",
        flush=True,
    )
    if args.check:
        assert len(set(expected)) == len(expected), "RPM contract contains duplicate package names"
        return 0

    missing = [pkg for pkg in expected if not is_installed(pkg)]
    if missing:
        print(
            f"ERROR: {len(missing)} of {len(expected)} contract packages are not installed:",
            file=sys.stderr,
        )
        for pkg in missing:
            print(f"  - {pkg}", file=sys.stderr)
        return 1
    print(f"All {len(expected)} contract packages are present.")

    if "nvidia" not in flavor:
        return 0
    if flavor == "nvidia-gaming":
        release = Path("/usr/lib/utah/ogc-kernel-release").read_text().strip()
        module = Path(f"/usr/lib/modules/{release}/extra/nvidia/nvidia.ko")
        if not module.exists():
            print(f"ERROR: NVIDIA module missing for OGC kernel {release}", file=sys.stderr)
            return 1
        return 0
    if not is_installed("kmod-nvidia"):
        print("ERROR: kmod-nvidia is not installed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
