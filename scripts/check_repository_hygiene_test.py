#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "check_repository_hygiene", Path(__file__).with_name("check-repository-hygiene.py")
)
HYGIENE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HYGIENE)


class RepositoryHygieneTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir=HYGIENE.ROOT)
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(json.dumps({"components": []}))
        self.artifact = self.root / "artifact"
        self.artifact.write_bytes(b"x" * HYGIENE.MAX_UNLISTED_BYTES)

    def run_gate(self, tracked):
        output = io.StringIO()
        with (
            patch.object(HYGIENE, "ROOT", self.root),
            patch.object(HYGIENE, "MANIFEST", self.manifest),
            patch.object(HYGIENE, "git_files", side_effect=[tracked, []]),
            contextlib.redirect_stdout(output),
            contextlib.redirect_stderr(output),
        ):
            result = HYGIENE.main()
        return result, output.getvalue()

    def test_unlisted_large_file_fails(self):
        result, output = self.run_gate(["artifact"])
        self.assertEqual(result, 1)
        self.assertIn("large tracked file lacks provenance approval: artifact", output)

    def test_symlink_target_size_does_not_change_gate(self):
        link = self.root / "link"
        try:
            link.symlink_to("artifact")
        except OSError as error:
            self.skipTest(f"symlinks unavailable: {error}")
        self.assertEqual(self.run_gate(["link"])[0], 0)
        self.artifact.unlink()
        self.assertEqual(self.run_gate(["link"])[0], 0)

    def test_approved_artifact_checksum_remains_enforced(self):
        self.manifest.write_text(json.dumps({"components": [{"artifacts": [{
            "path": "artifact", "sha256": HYGIENE.digest(self.artifact)
        }]}]}))
        self.assertEqual(self.run_gate(["artifact"])[0], 0)
        self.artifact.write_bytes(b"changed")
        result, output = self.run_gate(["artifact"])
        self.assertEqual(result, 1)
        self.assertIn("manifest checksum mismatch: artifact", output)


if __name__ == "__main__":
    unittest.main()
