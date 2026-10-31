#!/usr/bin/env python3
"""Bake the gallery Showcase albedo in the cc-php-app landing-page cortex palette.

The landing page shades its brain procedurally (neural-graph.js cortexShader):
rgb = mix(cool, pearl, 0.16 + 0.28 * diffuse) with a faint noise grain. The
gallery renderer supplies its own diffuse term, so the albedo carries only the
view-independent base: mix(cool, pearl, PEARL_MIX) plus a seeded grain. The
result is a flat material, so UV atlas seams cannot show.

Usage: bake-cortex-albedo.py <out.png> [edge]
"""

import random
import struct
import sys
import zlib

COOL = (0.38, 0.62, 0.66)
PEARL = (0.86, 0.93, 0.92)
PEARL_MIX = 0.30
GRAIN = 0.025
SEED = 0x1C0A7E


def linear_to_srgb(value: float) -> float:
    value = min(max(value, 0.0), 1.0)
    if value <= 0.0031308:
        return value * 12.92
    return 1.055 * value ** (1 / 2.4) - 0.055


def write_png(path: str, edge: int, rows: list[bytes]) -> None:
    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(kind: bytes, data: bytes) -> bytes:
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    header = struct.pack(">IIBBBBB", edge, edge, 8, 2, 0, 0, 0)
    with open(path, "wb") as out:
        out.write(b"\x89PNG\r\n\x1a\n")
        out.write(chunk(b"IHDR", header))
        out.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        out.write(chunk(b"IEND", b""))


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    edge = int(argv[2]) if len(argv) == 3 else 1024
    if not 16 <= edge <= 4096:
        print("edge must be in 16..4096", file=sys.stderr)
        return 2
    base = [c + (p - c) * PEARL_MIX for c, p in zip(COOL, PEARL)]
    rng = random.Random(SEED)
    rows = []
    for _ in range(edge):
        row = bytearray()
        for _ in range(edge):
            grain = (rng.random() - 0.5) * GRAIN
            for channel in base:
                row.append(round(linear_to_srgb(channel + grain) * 255))
        rows.append(bytes(row))
    write_png(argv[1], edge, rows)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
