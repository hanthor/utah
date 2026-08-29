#!/usr/bin/env python3
"""The image flavors Utah builds, in the shapes each workflow needs.

There are four places that have to agree about this: the build matrix, the
promote matrix, the release matrix, and whether the kernel cache image is worth
building at all. They were four separate literals, so narrowing the set in one
would have left the others promoting images that no longer exist.

config/flavors.json is the single source. "retired" is not commentary -- it is
what a flavor moves to when it is switched off, so the reason it is off stays
next to the list rather than in a commit message.

    flavors.py list       ["main"]
    flavors.py images     [{"image": "utah"}, ...]         promote
    flavors.py releases   [{"image": "utah", "source_tag": ...}, ...]  release
    flavors.py needs-kernel   true / false
"""
import json
import sys
from pathlib import Path

CONFIG = Path(__file__).resolve().parent.parent / "config" / "flavors.json"
IMAGE = {
    "main": "utah",
    "nvidia": "utah-nvidia",
    "gaming": "utah-gaming",
    "nvidia-gaming": "utah-nvidia-gaming",
}

flavors = json.loads(CONFIG.read_text())["flavors"]
unknown = [f for f in flavors if f not in IMAGE]
if unknown:
    raise SystemExit(f"unknown flavor(s) in {CONFIG.name}: {', '.join(unknown)}")

what = sys.argv[1] if len(sys.argv) > 1 else "list"
if what == "list":
    print(json.dumps(flavors))
elif what == "images":
    print(json.dumps([{"image": IMAGE[f]} for f in flavors]))
elif what == "releases":
    print(json.dumps([{"image": IMAGE[f], "source_tag": "testing", "target_tag": "stable"}
                      for f in flavors]))
elif what == "needs-kernel":
    # Only the OGC and NVIDIA flavors consume the kernel cache image. With
    # neither in the set, building it is 45 minutes spent on nothing.
    print("true" if any(f != "main" for f in flavors) else "false")
else:
    raise SystemExit(f"unknown query: {what}")
