#!/usr/bin/env python3
"""Check the package contract against Fedora Rawhide before building an image.

Every package Utah claims parity on is looked up in Rawhide's repodata.  A
package that is neither available nor listed under [unavailable] in
packages/utah.toml fails here, in the seconds-long preflight job, instead of
twenty minutes into a container build.

This is how the pipewire-libs-extra breakage was found: it is a negativo17
fedora-multimedia subpackage that Bluefin installs from that repo, and
negativo17 publishes no Rawhide branch.
"""

from __future__ import annotations

import argparse
import io
import re
import sys
import tomllib
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

RAWHIDE = (
    "https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide"
    "/Everything/x86_64/os/"
)


def section(path: Path, name: str) -> list[str]:
    data = tomllib.loads(path.read_text())
    return list(data.get(name, {}).get("packages", []))


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=120) as response:
        return response.read()


def rawhide_package_names() -> set[str]:
    repomd = ET.fromstring(fetch(RAWHIDE + "repodata/repomd.xml"))
    ns = {"repo": "http://linux.duke.edu/metadata/repo"}
    href = next(
        location.get("href")
        for data in repomd.findall("repo:data", ns)
        if data.get("type") == "primary"
        for location in data.findall("repo:location", ns)
    )
    raw = fetch(RAWHIDE + href)
    if href.endswith(".zst"):
        try:
            import zstandard
        except ModuleNotFoundError:
            print(
                "ERROR: python3-zstandard is required to read Rawhide repodata",
                file=sys.stderr,
            )
            raise SystemExit(2)
        stream = zstandard.ZstdDecompressor().stream_reader(io.BytesIO(raw))
    else:
        import gzip

        stream = gzip.GzipFile(fileobj=io.BytesIO(raw))

    names = set()
    # Stream the ~16 MiB of metadata rather than holding a parse tree for
    # 66k packages; only <name> at package scope matters here.
    for line in io.TextIOWrapper(stream, encoding="utf-8", errors="replace"):
        match = re.match(r"\s*<name>([^<]+)</name>", line)
        if match:
            names.add(match.group(1))
    return names


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("overlay", type=Path, nargs="?", default=None)
    args = parser.parse_args()
    overlay = args.overlay or args.manifest.with_name("utah.toml")

    unavailable = set(section(overlay, "unavailable"))
    wanted = sorted(
        set(section(args.manifest, "fedora"))
        | set(section(overlay, "gnome"))
        | set(section(overlay, "build"))
    )
    names = rawhide_package_names()
    print(f"Fedora Rawhide publishes {len(names)} binary packages")

    missing = [pkg for pkg in wanted if pkg not in names and pkg not in unavailable]
    resolved = sorted(pkg for pkg in unavailable if pkg in names)

    for pkg in resolved:
        print(f"NOTE: {pkg} is now in Rawhide and can be removed from [unavailable]")
    if missing:
        print(
            f"ERROR: {len(missing)} contract packages are not in Fedora Rawhide.",
            file=sys.stderr,
        )
        print(
            "Add each to [unavailable] in packages/utah.toml with a tracking "
            "issue, or fix the name:",
            file=sys.stderr,
        )
        for pkg in missing:
            print(f"  - {pkg}", file=sys.stderr)
        return 1
    print(
        f"All {len(wanted) - len(unavailable)} contract packages are available in "
        f"Rawhide ({len(unavailable)} documented as unavailable)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
