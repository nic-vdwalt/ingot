"""Tie a timing capture to the frozen build inputs that produced it."""
import hashlib
import json
import re
from pathlib import Path

SHADER_PATTERN = re.compile(r"BATCH_SHADER := `(.*?)`", re.S)
MANIFEST_FILES_MAX = 4096


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_build_manifest(payload, build_dir, capture_path=None):
    """Return the verified manifest summary or raise ValueError.

    Checks that every frozen compile input still hashes as recorded before the
    build, that the capture's exported shader text is the frozen batch shader,
    and, when an identity audit exists, that the built library and capture
    file on disk are the ones it recorded."""
    if type(payload) is not dict:
        raise ValueError("expected evidence object")
    build_dir = Path(build_dir)
    manifest_path = build_dir / "prebuild-inputs.json"
    if not manifest_path.is_file():
        raise ValueError("prebuild-inputs.json missing")
    manifest = json.loads(manifest_path.read_text())
    hashes = manifest.get("sha256")
    if type(hashes) is not dict or not 0 < len(hashes) <= MANIFEST_FILES_MAX:
        raise ValueError("invalid prebuild hash table")
    for relative, expected in hashes.items():
        file = build_dir / relative
        if not file.is_file() or sha256(file) != expected:
            raise ValueError(f"frozen input changed: {relative}")
    batch = build_dir / "ingot/gfx/batch.odin"
    if str(Path("ingot/gfx/batch.odin")) not in hashes:
        raise ValueError("frozen batch.odin not in manifest")
    match = SHADER_PATTERN.search(batch.read_text())
    if match is None or match.group(1) != payload.get("batch_shader"):
        raise ValueError("captured shader text differs from the frozen source")
    summary = dict(files=len(hashes), repositories=manifest.get("repositories"),
                   compiler=manifest.get("compiler", {}).get("sha256"),
                   wgpu_archive=manifest.get("wgpu_archive", {}).get("sha256"))
    audit_path = build_dir / "identity-audit.json"
    if audit_path.is_file():
        audit = json.loads(audit_path.read_text())
        recorded = audit.get("sha256")
        if type(recorded) is not dict:
            raise ValueError("invalid identity audit")
        for relative, expected in recorded.items():
            file = build_dir.parent / relative
            if not file.is_file() or sha256(file) != expected:
                raise ValueError(f"audited artifact changed: {relative}")
        if capture_path is not None:
            capture_hash = sha256(Path(capture_path))
            if capture_hash not in recorded.values():
                raise ValueError("capture file is not the audited capture")
        summary["audited"] = sorted(recorded)
    return summary
