#!/usr/bin/env python3
"""Record a rebuilt third-party artifact's checksum in the provenance manifest.

Usage: python3 scripts/record-artifact-checksum.py <repo-relative artifact path>

Hashes the file, rewrites its ``sha256`` in
``docs/provenance/third-party-artifacts.json``, marks it ``built_from:
patched``, drops any ``stale`` note, and rewrites the matching checksum line in
``THIRD_PARTY_NOTICES.md`` so ``scripts/check-repository-hygiene.py`` accepts
the new archive.
"""

import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "docs" / "provenance" / "third-party-artifacts.json"
NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"


class RecordError(Exception):
    pass


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def update_manifest(text: str, artifact_path: str, sha256: str) -> str:
    manifest = json.loads(text)
    matches = [
        artifact
        for component in manifest.get("components", [])
        for artifact in component.get("artifacts", [])
        if artifact.get("path") == artifact_path
    ]
    if len(matches) != 1:
        raise RecordError(
            f"expected exactly one manifest artifact for {artifact_path}, found {len(matches)}"
        )
    artifact = matches[0]
    artifact["sha256"] = sha256
    artifact["built_from"] = "patched"
    artifact.pop("stale", None)
    return json.dumps(manifest, indent=2) + "\n"


def update_notices(text: str, artifact_path: str, sha256: str) -> str:
    pattern = re.compile(rf"^[0-9a-f]{{64}}  {re.escape(artifact_path)}$", re.MULTILINE)
    found = pattern.findall(text)
    if len(found) != 1:
        raise RecordError(
            f"expected exactly one notices checksum line for {artifact_path}, found {len(found)}"
        )
    return pattern.sub(f"{sha256}  {artifact_path}", text)


def record(artifact_path: str, root: Path, manifest: Path, notices: Path) -> str:
    target = root / artifact_path
    if not target.is_file():
        raise RecordError(f"artifact not found: {target}")
    sha256 = digest(target)
    manifest.write_text(update_manifest(manifest.read_text(), artifact_path, sha256))
    notices.write_text(update_notices(notices.read_text(), artifact_path, sha256))
    return sha256


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        sha256 = record(argv[1], ROOT, MANIFEST, NOTICES)
    except RecordError as error:
        print(f"record-artifact-checksum: {error}", file=sys.stderr)
        return 1
    print(f"{sha256}  {argv[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
