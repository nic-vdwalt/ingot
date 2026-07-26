#!/usr/bin/env python3
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "docs" / "provenance" / "third-party-artifacts.json"
MAX_UNLISTED_BYTES = 1_048_576
GENERATED_PATHS = {
    "gallery",
    "chart_demo",
    "idle_demo",
    "fuzz/gfx_frame/fuzz_gfx_frame",
    "fuzz/interact/fuzz_interact",
    "fuzz/net/fuzz_net",
    "fuzz/ui/fuzz_ui",
    "fuzz/wsreconn/fuzz_wsreconn",
    "fuzz/wsreconn/fuzz_wsreconn_tsan",
}
GENERATED_PREFIXES = ("benchmarks/widgets/egui/target/",)


def git_files(*args: str) -> list[str]:
    output = subprocess.check_output(["git", *args], cwd=ROOT, text=True)
    return [line for line in output.splitlines() if line]


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def main() -> int:
    errors: list[str] = []
    tracked = set(git_files("ls-files"))
    ignored = git_files("ls-files", "-ci", "--exclude-standard")
    for path in ignored:
        errors.append(f"tracked ignored file: {path}")
    for path in sorted(tracked):
        if path in GENERATED_PATHS or path.startswith(GENERATED_PREFIXES):
            errors.append(f"tracked generated output: {path}")

    data = json.loads(MANIFEST.read_text())
    approved: dict[str, str] = {}
    for component in data["components"]:
        for artifact in component["artifacts"]:
            path = artifact["path"]
            approved[path] = artifact["sha256"]
            full_path = ROOT / path
            if path not in tracked:
                errors.append(f"manifest artifact is not tracked: {path}")
            elif not full_path.is_file():
                errors.append(f"manifest artifact is missing: {path}")
            elif digest(full_path) != artifact["sha256"]:
                errors.append(f"manifest checksum mismatch: {path}")

    for path in sorted(tracked):
        full_path = ROOT / path
        if full_path.is_file() and full_path.stat().st_size >= MAX_UNLISTED_BYTES and path not in approved:
            errors.append(f"large tracked file lacks provenance approval: {path}")

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("repository hygiene: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
