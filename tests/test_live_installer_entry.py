"""Every Icon= written by the live installer setup must resolve.

The live dock pins utah-installer.desktop. Its entries once used
Icon=bluefin, which nothing provides (no manifest package, no installed
file — only a differently-named bluefin-gdm-logo.png exists), so the dock
showed a broken icon. This test statically asserts that each Icon= value
the script writes has a provider the script installs.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "iso/live/src/configure-live.sh"

# Destinations whose basename (sans extension) satisfies Icon=<name>.
ICON_DIRS = ("/usr/share/pixmaps/", "/usr/share/icons/")


def written_icons(text):
    """Icon= values from .desktop entries the script writes."""
    return re.findall(r"^Icon=(\S+)\s*$", text, re.MULTILINE)


def installed_icon_names(text):
    """Icon names provided by install/cp lines targeting icon directories."""
    names = set()
    for line in text.splitlines():
        line = line.strip()
        if not (line.startswith("install ") or line.startswith("cp ")):
            continue
        # Last token is the destination (flags precede the sources).
        dest = line.split()[-1].strip("\"'")
        if any(d in dest for d in ICON_DIRS):
            names.add(Path(dest).stem)
    return names


class LiveInstallerIconTests(unittest.TestCase):
    def test_every_written_icon_has_a_provider(self):
        text = SCRIPT.read_text()
        icons = written_icons(text)
        self.assertTrue(icons, "no Icon= entries found; parser out of date?")
        providers = installed_icon_names(text)
        orphaned = sorted(set(icons) - providers)
        self.assertFalse(
            orphaned,
            f"icons with no provider installed by the script: {orphaned} "
            f"(providers: {sorted(providers)})",
        )


if __name__ == "__main__":
    unittest.main()
