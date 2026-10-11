from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/gnome-extension-shell-versions.py"
SPEC = importlib.util.spec_from_file_location("gnome_extension_shell_versions", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ShellVersionReportTests(unittest.TestCase):
    def test_reads_shell_versions_from_root_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            extension = Path(tmp) / "extension'`"
            extension.mkdir()
            (extension / "metadata.json").write_text('{"shell-version": ["50", "51"]}')
            self.assertEqual(MODULE.shell_versions(extension), "50, 51")

    def test_reads_gsconnect_template_location(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            extension = Path(tmp) / "extension'`"
            metadata_dir = extension / "data"
            metadata_dir.mkdir(parents=True)
            (metadata_dir / "metadata.json.in").write_text(
                '{"version": "@PACKAGE_VERSION@", "shell-version": ["51"]}'
            )
            self.assertEqual(MODULE.shell_versions(extension), "51")

    def test_uses_verifier_metadata_location_for_nested_sources(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            extension = base / "tmp/tilingshell@ferrarodomenico.com"
            (extension / "resources").mkdir(parents=True)
            (extension / "resources/metadata.json").write_text('{"shell-version": ["51"]}')
            self.assertEqual(MODULE.shell_versions(extension, base), "51")

    def test_reports_each_extension_in_multi_extension_submodule(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            extension = base / "tmp/bluefin-bling"
            for name, version in (("syncthing-toggle", "50"), ("power-status-color", "51")):
                (extension / "extensions" / name).mkdir(parents=True)
                (extension / "extensions" / name / "metadata.json").write_text(
                    '{"shell-version": ["%s"]}' % version
                )
            self.assertEqual(
                MODULE.shell_versions(extension, base),
                "syncthing-toggle@projectbluefin.io: 50; power-status-color@projectbluefin.io: 51",
            )

    def test_every_submodule_maps_to_verifier_metadata(self) -> None:
        import subprocess

        paths = subprocess.run(
            ["git", "config", "--file", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$"],
            cwd=MODULE.REPO_ROOT, capture_output=True, text=True, check=True,
        ).stdout.split()[1::2]
        for path in paths:
            with self.subTest(path=path):
                files = MODULE.metadata_files(MODULE.REPO_ROOT / path)
                self.assertTrue(files and all(uuid for uuid, _ in files))

    def test_rejects_untrusted_metadata_for_markdown_table(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            extension = Path(tmp)
            (extension / "metadata.json").write_text(
                '{"shell-version": ["51|oops", "52`\\nrow"]}'
            )
            self.assertEqual(MODULE.shell_versions(extension), "?")

    def test_missing_or_invalid_metadata_is_unknown(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            extension = Path(tmp)
            self.assertEqual(MODULE.shell_versions(extension), "?")
            (extension / "metadata.json").write_text("not json")
            self.assertEqual(MODULE.shell_versions(extension), "?")


if __name__ == "__main__":
    unittest.main()
