#!/usr/bin/env python3

import re
import subprocess
import sys
from pathlib import Path

PIN_PATTERN = re.compile(r"dev-[0-9]{4}-[0-9]{2}:[0-9a-f]+")


def read_pin(path: Path) -> str:
    pin = path.read_text(encoding="utf-8").strip()
    if not PIN_PATTERN.fullmatch(pin):
        raise ValueError(f"invalid Odin revision in {path}: {pin!r}")
    return pin


def version_matches(output: str, expected: str) -> bool:
    return expected in output.split()


def check_toolchain(root: Path) -> int:
    pin_path = root / "ODIN_VERSION"
    try:
        expected = read_pin(pin_path)
    except (OSError, ValueError) as error:
        print(f"toolchain check failed: {error}", file=sys.stderr)
        return 1

    try:
        result = subprocess.run(
            ["odin", "version"],
            capture_output=True,
            check=False,
            text=True,
        )
    except FileNotFoundError:
        print(
            f"toolchain check failed: odin not found on PATH; install {expected}",
            file=sys.stderr,
        )
        return 1

    output = (result.stdout + result.stderr).strip()
    if result.returncode != 0:
        print(f"toolchain check failed: odin version exited {result.returncode}", file=sys.stderr)
        if output:
            print(output, file=sys.stderr)
        return 1
    if not version_matches(output, expected):
        actual = output or "no version output"
        print(
            f"toolchain check failed: expected Odin {expected}; got {actual}",
            file=sys.stderr,
        )
        return 1

    print(f"Odin toolchain: {expected}")
    return 0


def main() -> int:
    return check_toolchain(Path(__file__).resolve().parent.parent)


if __name__ == "__main__":
    raise SystemExit(main())
