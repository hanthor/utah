#!/usr/bin/env bash
set -euo pipefail
image="${1:?image reference required}"
flavor="${IMAGE_FLAVOR:-main}"

podman run --rm --env IMAGE_FLAVOR="$flavor" --entrypoint \
  /usr/local/libexec/utah-verify-rpm-contract "$image" \
  /usr/share/utah/bluefin.toml /usr/share/utah/utah.toml

podman run --rm --env IMAGE_FLAVOR="$flavor" --entrypoint /usr/bin/python3 "$image" - <<'PY'
import os
import subprocess
import tomllib
from pathlib import Path

base = tomllib.loads(Path("/usr/share/utah/bluefin.toml").read_text())
overlay = tomllib.loads(Path("/usr/share/utah/utah.toml").read_text())
contract = Path("/usr/share/utah/contract.txt").read_text().split()
gnome = overlay["gnome"]["packages"]
bluefin = [p for p in contract if p not in set(gnome)]

def rpm_qi(name, packages):
    if not packages:
        raise SystemExit(f"{name}: empty package set")
    print(f"rpm -qi: {name} ({len(packages)} packages)")
    subprocess.run(["rpm", "-qi", *packages], check=True)

# Explicit separate rpm -qi checks for the Bluefin contract and GNOME overlay.
rpm_qi("Bluefin parity", bluefin)
rpm_qi("GNOME 51 overlay", gnome)

for package in gnome:
    release = subprocess.check_output(
        ["rpm", "-q", "--qf", "%{RELEASE}", package], text=True
    ).strip()
    if ".hum" not in release or ".bfin" not in release:
        raise SystemExit(f"{package} is not from Utah packages: {release}")

version = subprocess.check_output(["gnome-shell", "--version"], text=True).strip()
if "51" not in version:
    raise SystemExit(f"GNOME 51 was required, got: {version}")
subprocess.run(["gsettings", "list-schemas"], check=True, stdout=subprocess.DEVNULL)
if not Path("/usr/share/gnome-shell/extensions").is_dir():
    raise SystemExit("GNOME extensions directory is missing")
print(f"Utah health check passed: {version}; flavor={os.environ['IMAGE_FLAVOR']}")
PY
