#!/usr/bin/env python3

"""Tests for the wasm zero-segment guard.

The guard's whole value is catching a specific regression: a large global
gaining a static initialiser, moving from .bss to .data, and adding megabytes
of zeros to the module. These tests build minimal wasm modules by hand so the
parser and the threshold are exercised without needing a real 12 MB binary.
"""

import unittest

import check_wasm_bloat


def uleb(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def module(segments: list[tuple[int, bytes]]) -> bytes:
    """Build a wasm module carrying only a data section."""
    body = uleb(len(segments))
    for offset, payload in segments:
        body += uleb(0)  # active, memory 0
        body += b"\x41" + uleb(offset) + b"\x0b"  # i32.const <offset> end
        body += uleb(len(payload)) + payload
    return b"\x00asm\x01\x00\x00\x00" + bytes([11]) + uleb(len(body)) + body


class WasmBloatGuardTest(unittest.TestCase):
    def test_reads_offsets_lengths_and_zero_counts(self):
        data = module([(1024, b"\x01\x02\x00\x00"), (4096, b"\x00" * 8)])
        self.assertEqual(
            check_wasm_bloat.read_segments(data),
            [(1024, 4, 2), (4096, 8, 8)],
        )

    def test_rejects_input_that_is_not_wasm(self):
        with self.assertRaises(SystemExit):
            check_wasm_bloat.read_segments(b"not a wasm module at all")

    def test_a_module_with_no_data_section_has_no_segments(self):
        self.assertEqual(check_wasm_bloat.read_segments(b"\x00asm\x01\x00\x00\x00"), [])

    def test_small_zero_segments_are_ignored(self):
        # Padding and alignment produce small all-zero runs constantly; only
        # a segment large enough to matter is worth failing over.
        small = check_wasm_bloat.SEGMENT_BYTES_MIN - 1
        data = module([(1024, b"\x00" * small)])
        segments = check_wasm_bloat.read_segments(data)
        self.assertEqual(segments, [(1024, small, small)])

    def test_a_large_zero_segment_is_the_regression_it_must_catch(self):
        # This is the shape of the real bug: gfx.default_context_storage was
        # 11.1 MB of zeros because of a single `= {id = 1}` initialiser.
        big = check_wasm_bloat.SEGMENT_BYTES_MIN * 2
        data = module([(1024, b"\x00" * big)])
        offset, length, zeros = check_wasm_bloat.read_segments(data)[0]
        self.assertEqual((offset, length), (1024, big))
        self.assertEqual(zeros / length, 1.0)

    def test_a_large_segment_of_real_data_is_not_a_regression(self):
        # Fonts and shader source are legitimately large and mostly non-zero;
        # flagging those would make the guard noise.
        big = check_wasm_bloat.SEGMENT_BYTES_MIN * 2
        payload = bytes((index % 255) + 1 for index in range(big))
        _, length, zeros = check_wasm_bloat.read_segments(module([(1024, payload)]))[0]
        self.assertEqual(zeros, 0)
        self.assertEqual(length, big)

    def test_passive_segments_do_not_misparse(self):
        # Passive segments encode differently. The parser must stop rather
        # than read garbage offsets out of the following bytes.
        body = uleb(1) + uleb(1) + uleb(4) + b"\x01\x02\x03\x04"
        data = b"\x00asm\x01\x00\x00\x00" + bytes([11]) + uleb(len(body)) + body
        self.assertEqual(check_wasm_bloat.read_segments(data), [])


if __name__ == "__main__":
    unittest.main()
