#+build !js
package ingotnet

import "core:testing"
import "ingot:testx"

// Random opcodes covering data, control, and the unsupported continuation.
@(private = "file")
FUZZ_WS_OPCODES := [?]u8{0x0, WS_OP_TEXT, WS_OP_BINARY, WS_OP_CLOSE, WS_OP_PING, WS_OP_PONG}

// Random payload sized to hit all three header length classes (7-bit,
// 16-bit, 64-bit — the last capped at ~128 KiB so the test stays fast).
@(private = "file")
fuzz_ws_payload :: proc(p: ^testx.Prng) -> []u8 {
	n: int
	switch testx.int_range(p, 0, 3) {
	case 0:
		n = testx.int_range(p, 0, 126)
	case 1:
		n = testx.int_range(p, 126, 65536)
	case:
		n = testx.int_range(p, 65536, 128 * 1024)
	}
	b := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n do b[i] = u8(testx.next_u64(p) & 0xFF)
	return b
}

@(private = "file")
fuzz_ws_mask_key :: proc(p: ^testx.Prng) -> [4]u8 {
	r := testx.next_u64(p)
	return [4]u8{u8(r), u8(r >> 8), u8(r >> 16), u8(r >> 24)}
}

// Shared invariant checks: consumed stays in bounds, Need_More/Too_Big never
// consume, and an accepted payload lies within the consumed frame region and
// respects WS_MAX_PAYLOAD.
@(private = "file")
fuzz_ws_check :: proc(
	t: ^testing.T,
	buf: []u8,
	frame: WS_Frame,
	consumed: int,
	status: WS_Parse_Status,
	loc := #caller_location,
) {
	testing.expect(t, consumed >= 0, loc = loc)
	testing.expect(t, consumed <= len(buf), loc = loc)
	switch status {
	case .Need_More, .Too_Big:
		testing.expect_value(t, consumed, 0, loc = loc)
	case .Ok:
		testing.expect(t, len(frame.payload) <= WS_MAX_PAYLOAD, loc = loc)
		if len(frame.payload) > 0 {
			start := raw_data(buf)
			payload_start := raw_data(frame.payload)
			testing.expect(t, payload_start >= start, loc = loc)
			testing.expect(
				t,
				uintptr(payload_start) + uintptr(len(frame.payload)) <=
				uintptr(start) + uintptr(consumed),
				loc = loc,
			)
		}
	}
}

// Fuzz ws_parse_frame with fully random bytes. The parser must never panic,
// never read past the buffer, and never consume more than it was given.
// Seeds are fixed so failures reproduce deterministically.
@(test)
fuzz_ws_parse_random_bytes :: proc(t: ^testing.T) {
	p := testx.prng_make(0x11)
	for _ in 0 ..< 20_000 {
		buf := testx.random_bytes(&p, 4096)
		frame, consumed, status := ws_parse_frame(buf)
		fuzz_ws_check(t, buf, frame, consumed, status)
		free_all(context.temp_allocator)
	}
}

// Fuzz ws_parse_frame with a valid encoded frame corrupted by random byte
// flips and truncation, to reach deep into the extended-length and
// mask-offset arithmetic.
@(test)
fuzz_ws_parse_mutated_valid :: proc(t: ^testing.T) {
	p := testx.prng_make(0x12)
	for _ in 0 ..< 20_000 {
		opcode := FUZZ_WS_OPCODES[testx.int_range(&p, 0, len(FUZZ_WS_OPCODES))]
		buf := ws_encode_frame(opcode, fuzz_ws_payload(&p), fuzz_ws_mask_key(&p), context.temp_allocator)
		for _ in 0 ..< testx.int_range(&p, 1, 8) {
			buf[testx.int_range(&p, 0, len(buf))] = u8(testx.next_u64(&p) & 0xFF)
		}
		cut := testx.int_range(&p, 0, len(buf) + 1)
		frame, consumed, status := ws_parse_frame(buf[:cut])
		fuzz_ws_check(t, buf[:cut], frame, consumed, status)
		free_all(context.temp_allocator)
	}
}

// Encode with a deterministic mask key, parse back: the frame must round-trip
// exactly (opcode, payload bytes, full consumption).
@(test)
fuzz_ws_encode_parse_round_trip :: proc(t: ^testing.T) {
	p := testx.prng_make(0x13)
	for _ in 0 ..< 10_000 {
		opcode := FUZZ_WS_OPCODES[testx.int_range(&p, 0, len(FUZZ_WS_OPCODES))]
		payload := fuzz_ws_payload(&p)
		original := make([]u8, len(payload), context.temp_allocator)
		copy(original, payload)

		buf := ws_encode_frame(opcode, payload, fuzz_ws_mask_key(&p), context.temp_allocator)
		frame, consumed, status := ws_parse_frame(buf)
		testing.expect_value(t, status, WS_Parse_Status.Ok)
		testing.expect_value(t, consumed, len(buf))
		testing.expect_value(t, frame.opcode, opcode)
		testing.expect_value(t, frame.masked, true)
		testing.expect_value(t, string(frame.payload), string(original))
		free_all(context.temp_allocator)
	}
}

// Concatenate several frames and feed them through a caller-side accumulator
// in random TCP-sized chunks (mirroring ws_recv_loop's acc/remove_range
// pattern). Every frame must be recovered exactly once, in order, with no
// bytes lost or double-consumed.
@(test)
fuzz_ws_stream_reassembly :: proc(t: ^testing.T) {
	p := testx.prng_make(0x14)
	for _ in 0 ..< 5_000 {
		frame_count := testx.int_range(&p, 1, 9)

		opcodes := make([]u8, frame_count, context.temp_allocator)
		payloads := make([][]u8, frame_count, context.temp_allocator)
		stream := make([dynamic]u8, context.temp_allocator)
		for i in 0 ..< frame_count {
			opcodes[i] = FUZZ_WS_OPCODES[testx.int_range(&p, 0, len(FUZZ_WS_OPCODES))]
			// Small payloads keep the stream cheap; length classes are
			// covered by the other fuzz tests.
			n := testx.int_range(&p, 0, 200)
			payload := make([]u8, n, context.temp_allocator)
			for j in 0 ..< n do payload[j] = u8(testx.next_u64(&p) & 0xFF)
			payloads[i] = payload
			encoded := ws_encode_frame(opcodes[i], payload, fuzz_ws_mask_key(&p), context.temp_allocator)
			append(&stream, ..encoded)
		}

		// Feed the stream in random 1-1500 byte chunks through an
		// accumulator, parsing greedily after each chunk.
		acc := make([dynamic]u8, context.temp_allocator)
		got := 0
		fed := 0
		for fed < len(stream) {
			chunk := min(testx.int_range(&p, 1, 1501), len(stream) - fed)
			append(&acc, ..stream[fed:fed + chunk])
			fed += chunk

			offset := 0
			for offset < len(acc) {
				frame, consumed, status := ws_parse_frame(acc[offset:])
				if status == .Need_More do break
				testing.expect_value(t, status, WS_Parse_Status.Ok)
				testing.expect(t, got < frame_count)
				if got < frame_count {
					// Payload was unmasked in place — compare to source.
					testing.expect_value(t, frame.opcode, opcodes[got])
					testing.expect_value(t, string(frame.payload), string(payloads[got]))
				}
				got += 1
				offset += consumed
			}
			if offset > 0 {
				remove_range(&acc, 0, offset)
			}
		}
		testing.expect_value(t, got, frame_count)
		testing.expect_value(t, len(acc), 0)
		free_all(context.temp_allocator)
	}
}

// Property: ws_accept_for_key must produce a 28-character base64 digest for
// ANY key — arbitrary bytes, invalid UTF-8, embedded NULs, 0–256 bytes —
// without reading past the key or corrupting memory (sha1 + base64 over a
// tprintf-combined string).
@(test)
fuzz_ws_accept_for_key :: proc(t: ^testing.T) {
	p := testx.prng_make(0xACC3_9704)
	for _ in 0 ..< 20_000 {
		key := testx.random_bytes(&p, 257)
		accept := ws_accept_for_key(string(key))
		testing.expect_value(t, len(accept), 28) // base64(20-byte sha1) incl. padding
		for ch in transmute([]u8)accept {
			valid := (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
				(ch >= '0' && ch <= '9') || ch == '+' || ch == '/' || ch == '='
			testing.expect(t, valid, "accept digest contains non-base64 byte")
		}
		free_all(context.temp_allocator)
	}
}
