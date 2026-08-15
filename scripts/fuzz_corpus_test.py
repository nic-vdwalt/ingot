#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import tempfile
import unittest

MODULE_PATH = pathlib.Path(__file__).with_name("fuzz-corpus.py")
SPEC = importlib.util.spec_from_file_location("fuzz_corpus", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CorpusTests(unittest.TestCase):
    def fixture(self, target="net", path="net/case.ingtape"):
        temporary = tempfile.TemporaryDirectory()
        root = pathlib.Path(temporary.name)
        corpus = root / "testdata" / "seeds"
        tape = corpus / path
        tape.parent.mkdir(parents=True)
        target_bytes = target.encode("ascii")
        header = b"INGTAPE\0" + (1).to_bytes(2, "little") + len(target_bytes).to_bytes(2, "little") + (0).to_bytes(4, "little") + (7).to_bytes(8, "little")
        tape.write_bytes(header + target_bytes)
        entry = {"id": "case", "target": target, "path": path, "seed": 7, "discovered": "2026-08-15", "fixed": "2026-08-15", "expected": "pass", "timeout_seconds": 30}
        (corpus / "manifest.json").write_text(json.dumps({"version": 1, "entries": [entry]}), encoding="utf-8")
        return temporary, root, corpus, entry

    def test_valid_manifest(self):
        temporary, root, _, _ = self.fixture()
        with temporary:
            self.assertEqual(len(MODULE.validate(root)), 1)

    def test_duplicate_id_rejected(self):
        temporary, root, corpus, entry = self.fixture()
        with temporary:
            (corpus / "manifest.json").write_text(json.dumps({"version": 1, "entries": [entry, entry]}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate"):
                MODULE.validate(root)

    def test_traversal_and_missing_rejected(self):
        temporary, root, corpus, entry = self.fixture()
        with temporary:
            entry["path"] = "../escape.ingtape"
            (corpus / "manifest.json").write_text(json.dumps({"version": 1, "entries": [entry]}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unsafe"):
                MODULE.validate(root)

    def test_target_mismatch_rejected(self):
        temporary, root, corpus, entry = self.fixture()
        with temporary:
            entry["target"] = "interact"
            (corpus / "manifest.json").write_text(json.dumps({"version": 1, "entries": [entry]}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "mismatch"):
                MODULE.validate(root)

    def test_orphan_rejected(self):
        temporary, root, corpus, _ = self.fixture()
        with temporary:
            (corpus / "extra.ingtape").write_bytes(b"INGTAPE\0")
            with self.assertRaisesRegex(ValueError, "orphaned"):
                MODULE.validate(root)


if __name__ == "__main__":
    unittest.main()
