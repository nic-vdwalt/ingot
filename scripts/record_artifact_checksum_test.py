#!/usr/bin/env python3
"""Unit tests for record-artifact-checksum.py."""

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "record-artifact-checksum.py"
spec = importlib.util.spec_from_file_location("record_artifact_checksum", SCRIPT)
assert spec is not None and spec.loader is not None
record_artifact_checksum = importlib.util.module_from_spec(spec)
spec.loader.exec_module(record_artifact_checksum)

ARTIFACT = "libvterm/lib/windows_amd64/vterm.lib"
OLD = "0" * 64
MANIFEST = {
    "schema_version": 1,
    "components": [
        {
            "name": "libvterm",
            "artifacts": [
                {"path": "libvterm/lib/darwin_arm64/libvterm.a", "sha256": "1" * 64},
                {
                    "path": ARTIFACT,
                    "sha256": OLD,
                    "built_from": "upstream-unpatched",
                    "stale": "Predates patches.",
                },
            ],
        }
    ],
}
NOTICES = f"SHA-256:\n\n```text\n{'1' * 64}  libvterm/lib/darwin_arm64/libvterm.a\n{OLD}  {ARTIFACT}\n```\n"


class RecordTests(unittest.TestCase):
    def test_record_rewrites_manifest_and_notices(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / ARTIFACT
            target.parent.mkdir(parents=True)
            target.write_bytes(b"patched archive")
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(MANIFEST, indent=2) + "\n")
            notices = root / "notices.md"
            notices.write_text(NOTICES)
            sha256 = record_artifact_checksum.record(ARTIFACT, root, manifest, notices)
            self.assertEqual(sha256, hashlib.sha256(b"patched archive").hexdigest())
            updated = json.loads(manifest.read_text())
            artifact = updated["components"][0]["artifacts"][1]
            self.assertEqual(artifact["sha256"], sha256)
            self.assertEqual(artifact["built_from"], "patched")
            self.assertNotIn("stale", artifact)
            self.assertEqual(updated["components"][0]["artifacts"][0]["sha256"], "1" * 64)
            self.assertTrue(manifest.read_text().endswith("}\n"))
            self.assertIn(f"{sha256}  {ARTIFACT}\n", notices.read_text())
            self.assertNotIn(OLD, notices.read_text())

    def test_unknown_artifact_is_rejected(self) -> None:
        text = json.dumps(MANIFEST)
        with self.assertRaises(record_artifact_checksum.RecordError):
            record_artifact_checksum.update_manifest(text, "missing/path.lib", "2" * 64)

    def test_notices_line_must_be_unique(self) -> None:
        duplicated = NOTICES + f"{OLD}  {ARTIFACT}\n"
        with self.assertRaises(record_artifact_checksum.RecordError):
            record_artifact_checksum.update_notices(duplicated, ARTIFACT, "2" * 64)

    def test_missing_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(record_artifact_checksum.RecordError):
                record_artifact_checksum.record(ARTIFACT, root, root / "m.json", root / "n.md")


if __name__ == "__main__":
    unittest.main()
