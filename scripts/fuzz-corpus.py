#!/usr/bin/env python3
import argparse
import json
import pathlib
import subprocess
import sys

MAGIC = b"INGTAPE\0"
MAX_TAPE_BYTES = 64 * 1024 * 1024
TARGETS = {
    "net": ("fuzz/net", ["-define:INGOT_NET_SIM=true"]),
    "interact": ("fuzz/interact", ["-define:INGOT_INPUT_SIM=true"]),
}


def validate(root: pathlib.Path):
    corpus = root / "testdata" / "seeds"
    manifest_path = corpus / "manifest.json"
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    if data.get("version") != 1 or not isinstance(data.get("entries"), list):
        raise ValueError("unsupported corpus manifest")
    ids = set()
    listed = set()
    entries = []
    for entry in data["entries"]:
        required = {"id", "target", "path", "seed", "discovered", "fixed", "expected", "timeout_seconds"}
        if not required.issubset(entry):
            raise ValueError("corpus entry is missing required fields")
        if entry["id"] in ids:
            raise ValueError(f"duplicate corpus id: {entry['id']}")
        ids.add(entry["id"])
        if entry["target"] not in TARGETS or entry["expected"] != "pass":
            raise ValueError(f"invalid corpus target/result: {entry['id']}")
        timeout = entry["timeout_seconds"]
        if not isinstance(timeout, int) or timeout <= 0 or timeout > 300:
            raise ValueError(f"invalid corpus timeout: {entry['id']}")
        relative = pathlib.PurePosixPath(entry["path"])
        if relative.is_absolute() or ".." in relative.parts or relative.suffix != ".ingtape":
            raise ValueError(f"unsafe corpus path: {entry['path']}")
        path = corpus.joinpath(*relative.parts)
        if not path.is_file():
            raise ValueError(f"missing corpus tape: {entry['path']}")
        if path.stat().st_size > MAX_TAPE_BYTES:
            raise ValueError(f"oversized corpus tape: {entry['path']}")
        header = path.read_bytes()[:24]
        if len(header) < 24 or header[:8] != MAGIC or int.from_bytes(header[8:10], "little") != 1:
            raise ValueError(f"invalid corpus tape header: {entry['path']}")
        target_len = int.from_bytes(header[10:12], "little")
        with path.open("rb") as tape:
            tape.seek(24)
            target = tape.read(target_len).decode("ascii", "strict")
        if target != entry["target"]:
            raise ValueError(f"corpus target mismatch: {entry['path']}")
        listed.add(path.resolve())
        entries.append((entry, path))
    present = {path.resolve() for path in corpus.rglob("*.ingtape")}
    if present != listed:
        extras = sorted(str(path.relative_to(corpus.resolve())) for path in present - listed)
        raise ValueError(f"orphaned corpus tapes: {extras}")
    return entries


def run(root: pathlib.Path, entries):
    output = root / ".fuzz-corpus-bin"
    output.mkdir(exist_ok=True)
    built = {}
    try:
        for entry, tape in entries:
            target = entry["target"]
            if target not in built:
                package, defines = TARGETS[target]
                binary = output / (target + (".exe" if sys.platform == "win32" else ""))
                command = ["odin", "build", str(root / package), f"-collection:ingot={root}", *defines, f"-out:{binary}"]
                subprocess.run(command, check=True, cwd=root)
                built[target] = binary
            subprocess.run([str(built[target]), f"-replay:{tape}"], check=True, cwd=root, timeout=entry["timeout_seconds"])
    finally:
        for path in output.glob("*"):
            path.unlink()
        output.rmdir()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=pathlib.Path(__file__).resolve().parents[1], type=pathlib.Path)
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        entries = validate(root)
        if not args.validate_only:
            run(root, entries)
    except (ValueError, OSError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        print(f"fuzz corpus: {error}", file=sys.stderr)
        return 1
    print(f"fuzz corpus: {len(entries)} entries valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
