"""The image must ship a reachable NTP fallback pool.

Hummingbird's chrony pool (2.hummingbird.pool.ntp.org) is NXDOMAIN on the
public internet, so chronyd runs with zero sources and the clock never
disciplines. A host whose RTC is behind then fails every TLS handshake with
"certificate is not yet valid", which broke `ujust install-ai-tools` (#594).
The Containerfile appends the public pool while keeping Red Hat's first.
"""
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTAINERFILE = (ROOT / "Containerfile").read_text(encoding="utf-8")


class ChronyFallbackTest(unittest.TestCase):
    def test_public_fallback_pool_is_configured(self):
        self.assertIn("pool pool.ntp.org iburst", CONTAINERFILE)

    def test_fallback_is_appended_idempotently(self):
        self.assertIn("grep -q '^pool pool\\.ntp\\.org' /etc/chrony.conf", CONTAINERFILE)

    def test_hummingbird_pool_is_kept_not_replaced(self):
        # The vendor pool resolves inside Red Hat's network; the fix adds a
        # fallback beside it rather than deleting the shipped line.
        self.assertNotIn("hummingbird.pool.ntp.org.*d", CONTAINERFILE)
        self.assertNotRegex(CONTAINERFILE, r"sed\s+.*hummingbird\.pool")


if __name__ == "__main__":
    unittest.main()
