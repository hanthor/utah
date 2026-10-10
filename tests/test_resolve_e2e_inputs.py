"""Fail-closed coverage for the e2e input trust gate.

scripts/resolve-e2e-inputs.py selects immutable images from one trusted
build run; every refusal branch must keep refusing (projectbluefin/utah#636).
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "resolve-e2e-inputs.py"

spec = importlib.util.spec_from_file_location("resolve_e2e_inputs", SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

REPO = "projectbluefin/utah"
DIGEST = "sha256:" + "a" * 64


def good_run(**overrides):
    run = {
        "conclusion": "success",
        "head_branch": "testing",
        "event": "push",
        "repository": {"full_name": REPO},
        "head_repository": {"full_name": REPO},
        "path": ".github/workflows/build.yml",
        "head_sha": "b" * 40,
    }
    run.update(overrides)
    return run


def artifact_dir(tmp, lines):
    d = Path(tmp) / "artifacts"
    d.mkdir(exist_ok=True)
    (d / "digests.txt").write_text("\n".join(lines) + "\n")
    return str(d)


class ResolveE2EInputsTests(unittest.TestCase):
    def test_happy_path_returns_pinned_refs(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = gate.resolve(
                good_run(), ["utah"],
                artifact_dir(tmp, [f"utah|amd64|{DIGEST}"]), REPO)
        self.assertEqual(out, {"include": [{
            "image": "utah", "digest": DIGEST,
            "ref": f"ghcr.io/projectbluefin/utah@{DIGEST}",
        }]})

    def test_happy_path_tolerates_duplicate_digests_across_legs(self):
        # Mirrors the reusable-build layout: one image-digest-testing-* dir
        # per leg, each repeating the same digest in both line forms.
        nvidia = "sha256:" + "d" * 64
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "digests"
            for leg, name, digest in (("utah", "utah", DIGEST),
                                      ("utah-nvidia", "utah-nvidia", nvidia)):
                d = root / f"image-digest-testing-{leg}"
                d.mkdir(parents=True)
                (d / "digest.txt").write_text(f"{name}={digest}\n")
                (d / "platforms.txt").write_text(f"{name}|amd64|{digest}\n")
            (root / "image-digest-testing-utah" / "all.txt").write_text(
                f"utah={DIGEST}\nutah|amd64|{DIGEST}\n")
            out = gate.resolve(
                good_run(), ["utah", "utah-nvidia"], str(root), REPO)
        self.assertEqual(out, {"include": [
            {"image": "utah", "digest": DIGEST,
             "ref": f"ghcr.io/projectbluefin/utah@{DIGEST}"},
            {"image": "utah-nvidia", "digest": nvidia,
             "ref": f"ghcr.io/projectbluefin/utah-nvidia@{nvidia}"},
        ]})

    def test_rejects_unsuccessful_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, "not a successful trusted"):
                gate.resolve(
                    good_run(conclusion="failure"), ["utah"],
                    artifact_dir(tmp, [f"utah|amd64|{DIGEST}"]), REPO)

    def test_rejects_wrong_branch_and_event(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = artifact_dir(tmp, [f"utah|amd64|{DIGEST}"])
            for bad in ({"head_branch": "main"}, {"event": "pull_request"}):
                with self.assertRaisesRegex(ValueError, "not a successful trusted"):
                    gate.resolve(good_run(**bad), ["utah"], d, REPO)

    def test_rejects_fork_and_foreign_workflow(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = artifact_dir(tmp, [f"utah|amd64|{DIGEST}"])
            for bad in ({"repository": {"full_name": "evil/fork"}},
                        {"head_repository": {"full_name": "evil/fork"}},
                        {"path": ".github/workflows/other.yml"},
                        {"head_sha": "not-a-sha"}):
                with self.assertRaisesRegex(ValueError, "not a successful trusted"):
                    gate.resolve(good_run(**bad), ["utah"], d, REPO)

    def test_rejects_unexpected_arch(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, "unexpected architecture"):
                gate.resolve(
                    good_run(), ["utah"],
                    artifact_dir(tmp, [f"utah|arm64|{DIGEST}"]), REPO)

    def test_rejects_unknown_image_and_bad_digest(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, "unexpected image name or digest"):
                gate.resolve(
                    good_run(), ["utah"],
                    artifact_dir(tmp, [f"other|amd64|{DIGEST}"]), REPO)
            with self.assertRaisesRegex(ValueError, "unexpected image name or digest"):
                gate.resolve(
                    good_run(), ["utah"],
                    artifact_dir(tmp, ["utah=not-a-digest"]), REPO)

    def test_rejects_conflicting_digests(self):
        with tempfile.TemporaryDirectory() as tmp:
            other = "sha256:" + "c" * 64
            with self.assertRaisesRegex(ValueError, "conflicting image digests"):
                gate.resolve(
                    good_run(), ["utah"], artifact_dir(tmp, [
                        f"utah|amd64|{DIGEST}",
                        f"utah|amd64|{other}",
                    ]), REPO)

    def test_cli_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_f = Path(tmp) / "run.json"
            run_f.write_text(json.dumps(good_run()))
            art = Path(tmp) / "artifacts"
            art.mkdir()
            images = json.loads(subprocess.check_output(
                [sys.executable, "scripts/flavors.py", "images"],
                text=True, cwd=ROOT))
            expected = [item["image"] for item in images]
            (art / "digests.txt").write_text("".join(
                f"{name}|amd64|{DIGEST}\n" for name in expected))
            proc = subprocess.run(
                [sys.executable, "scripts/resolve-e2e-inputs.py",
                 str(run_f), str(art), REPO],
                text=True, capture_output=True, cwd=ROOT)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = json.loads(proc.stdout)
        self.assertEqual(
            {item["image"] for item in out["include"]}, set(expected))

    def test_rejects_incomplete_flavor_set(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, "do not cover"):
                gate.resolve(
                    good_run(), ["utah", "utah-nvidia"],
                    artifact_dir(tmp, [f"utah|amd64|{DIGEST}"]), REPO)


if __name__ == "__main__":
    unittest.main()
