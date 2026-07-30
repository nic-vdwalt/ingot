#!/usr/bin/env python3
"""Guard against zero-filled data segments in a wasm module.

WebAssembly memory is zero-initialised by specification, so an active data
segment consisting only of zeros writes nothing. LLVM still emits one for any
global placed in `.data` rather than `.bss`, and a global lands in `.data` the
moment it has a static initialiser - however small.

That is not a theoretical concern. `gfx.default_context_storage` is roughly
11 MB (mostly the batch vertex and index arrays) and carried a single
`= {id = 1}` initialiser. Those four bytes pushed the whole struct into
`.data`, adding 11.1 MB of zeros to every demo module: 12.3 MB shipped where
1.2 MB was needed. Browsers download and parse all of it, and on a slow
connection a transfer that size can be cut short, surfacing only as an opaque
"unexpected end of data" wasm parse error.

The fix is to leave such globals uninitialised and assign in an `@(init)`
procedure. This script exists so a future initialiser cannot quietly undo it.

Usage:
    check_wasm_bloat.py MODULE [--max-zero-ratio 0.5] [--report]
"""

import argparse
import sys
from pathlib import Path

# Segments below this size are ignored: small zero runs are ordinary padding
# and alignment, not a mis-placed global.
SEGMENT_BYTES_MIN = 64 * 1024

SECTION_DATA = 11
SECTION_MEMORY = 5


def read_uleb(data: bytes, pos: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7


def read_segments(data: bytes) -> list[tuple[int, int, int]]:
    """Return (offset, length, zero_count) for each active data segment."""
    if data[:4] != b"\x00asm":
        raise SystemExit("not a wasm module")
    segments: list[tuple[int, int, int]] = []
    pos = 8
    while pos < len(data):
        section = data[pos]
        pos += 1
        size, pos = read_uleb(data, pos)
        if section == SECTION_DATA:
            cursor = pos
            count, cursor = read_uleb(data, cursor)
            for _ in range(count):
                flags, cursor = read_uleb(data, cursor)
                if flags != 0:
                    # Passive or memory-indexed segment: not our concern, and
                    # its encoding differs. Stop rather than misparse.
                    break
                if data[cursor] != 0x41:  # i32.const
                    break
                cursor += 1
                offset, cursor = read_uleb(data, cursor)
                if data[cursor] != 0x0B:  # end
                    break
                cursor += 1
                length, cursor = read_uleb(data, cursor)
                body = data[cursor : cursor + length]
                segments.append((offset, length, body.count(0)))
                cursor += length
        pos += size
    return segments


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("module")
    parser.add_argument(
        "--max-zero-ratio",
        type=float,
        default=0.5,
        help="fail if a large segment is more than this fraction zeros",
    )
    parser.add_argument("--report", action="store_true", help="print every segment")
    arguments = parser.parse_args()

    path = Path(arguments.module)
    if not path.is_file():
        raise SystemExit(f"module not found: {path}")
    data = path.read_bytes()
    segments = read_segments(data)

    total = sum(length for _, length, _ in segments)
    zeros = sum(zero for _, _, zero in segments)
    if arguments.report:
        print(f"{path.name}: {len(data):,} bytes, data section {total:,} bytes")
        for offset, length, zero in segments:
            share = zero * 100 / length if length else 0
            print(f"  offset {offset:>10,}  len {length:>10,}  zeros {share:5.1f}%")
        if total:
            print(f"  data section is {zeros * 100 / total:.1f}% zeros overall")

    failures = []
    for offset, length, zero in segments:
        if length < SEGMENT_BYTES_MIN:
            continue
        ratio = zero / length
        if ratio > arguments.max_zero_ratio:
            failures.append(
                f"segment at offset {offset:,} is {length:,} bytes and "
                f"{ratio * 100:.1f}% zeros"
            )

    for failure in failures:
        print(f"{path.name}: {failure}", file=sys.stderr)
    if failures:
        print(
            "\nA large zero-filled data segment means a big global has a static\n"
            "initialiser and landed in .data instead of .bss. Leave the global\n"
            "uninitialised and assign its fields in an @(init) procedure - see\n"
            "gfx/context.odin's default_context_storage for the pattern.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
