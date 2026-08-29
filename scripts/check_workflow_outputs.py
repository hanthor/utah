#!/usr/bin/env python3
"""Fail if a job output references a step id no step in that job defines.

An output wired to a missing step is empty, not an error. Passed to a reusable
workflow as a matrix it produces no jobs at all, and the only symptom is the
aggregator reporting "build_container: failure" with nothing to look at. That is
exactly what happened when the step meant to resolve config/flavors.json was
never inserted: the outputs block landed, the step did not, and the image build
silently did not exist.
"""
import re
import sys
from pathlib import Path

import yaml

failed = False
for path in sorted(Path(".github/workflows").glob("*.yml")):
    doc = yaml.safe_load(path.read_text())
    for job_name, job in (doc.get("jobs") or {}).items():
        outputs = job.get("outputs") or {}
        if not outputs:
            continue
        defined = {s.get("id") for s in (job.get("steps") or []) if s.get("id")}
        for out, expr in outputs.items():
            for step_id in re.findall(r"steps\.([A-Za-z0-9_-]+)\.outputs", str(expr)):
                if step_id not in defined:
                    print(f"{path}: job {job_name} output {out} reads steps.{step_id}, "
                          f"which no step in that job defines", file=sys.stderr)
                    failed = True
if failed:
    raise SystemExit(1)
print("checked workflow job outputs: every referenced step id exists")
