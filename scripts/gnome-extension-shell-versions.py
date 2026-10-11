#!/usr/bin/env python3
"""Print shell-version metadata safely for the GNOME extension bump report."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def shell_versions(extension: Path) -> str:
    """Read the known metadata locations and escape values for a Markdown table."""
    candidates = (extension / "metadata.json", extension / "data/metadata.json.in")
    metadata = next((candidate for candidate in candidates if candidate.is_file()), None)
    if metadata is None:
        return "?"

    try:
        data = json.loads(metadata.read_text().replace("@PACKAGE_VERSION@", "0"))
    except (OSError, json.JSONDecodeError):
        return "?"

    versions = data.get("shell-version")
    if not isinstance(versions, list) or not all(
        isinstance(item, str) and re.fullmatch(r"\d+(?:\.\d+)*", item)
        for item in versions
    ):
        return "?"

    # Shell API versions are numeric. Reject anything else because this value
    # is rendered into a Markdown table in a write-enabled automation job.
    return ", ".join(versions) or "?"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: gnome-extension-shell-versions.py EXTENSION_PATH", file=sys.stderr)
        return 2
    print(shell_versions(Path(sys.argv[1])))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
