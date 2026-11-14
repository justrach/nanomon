#!/usr/bin/env python3
"""Manifest edits use temporary files only, and retain every platform."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("manifest", Path(__file__).with_name("update-manifest.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ManifestTests(unittest.TestCase):
    def test_merge_and_restaple_preserve_platforms(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"version": "0.1.11", "files": {"nanomon-macos-arm64.zip": {"sha256": "a" * 64}}}))
            linux = root / "nanomon-linux-aarch64.tar.gz"
            linux.write_bytes(b"linux")
            module.merge("0.1.11", manifest, [linux])
            data = json.loads(manifest.read_text())
            self.assertEqual(data["files"][linux.name]["sha256"], hashlib.sha256(b"linux").hexdigest())
            self.assertEqual(data["files"]["nanomon-macos-arm64.zip"]["sha256"], "a" * 64)
            mac = root / "nanomon-macos-arm64.zip"
            mac.write_bytes(b"restapled")
            module.merge("0.1.11", manifest, [mac])
            self.assertEqual(len(json.loads(manifest.read_text())["files"]), 2)
            before = manifest.read_bytes()
            for version in ("0.1.12", "../0.1.11"):
                with self.assertRaises(ValueError):
                    module.merge(version, manifest, [linux])
                self.assertEqual(manifest.read_bytes(), before)
            with self.assertRaises(ValueError):
                module.merge("0.1.11", manifest, [root / "unexpected.zip"])
            self.assertEqual(manifest.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
