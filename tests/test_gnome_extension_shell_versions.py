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
