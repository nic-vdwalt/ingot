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

@(private = "file")
fuzz_ws_server_frame :: proc(opcode: u8, payload: []u8) -> []u8 {
	body := payload
	if opcode >= WS_OP_CLOSE && len(body) > 125 do body = body[:125]
	header_size := 2
	if len(body) >= 65536 {
		header_size = 10
	} else if len(body) >= 126 {
		header_size = 4
	}
	frame := make([]u8, header_size + len(body), context.temp_allocator)
	frame[0] = 0x80 | opcode
	if len(body) < 126 {
		frame[1] = u8(len(body))
	} else if len(body) < 65536 {
		frame[1] = 126
		frame[2] = u8(len(body) >> 8)
		frame[3] = u8(len(body))
	} else {
		frame[1] = 127
		for index in 0 ..< 8 do frame[2 + index] = u8(len(body) >> uint((7 - index) * 8))
	}
	copy(frame[header_size:], body)
	return frame
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
		buf := ws_encode_frame(
			opcode,
			fuzz_ws_payload(&p),
			fuzz_ws_mask_key(&p),
			context.temp_allocator,
		)
		for _ in 0 ..< testx.int_range(&p, 1, 8) {
			buf[testx.int_range(&p, 0, len(buf))] = u8(testx.next_u64(&p) & 0xFF)
		}
		cut := testx.int_range(&p, 0, len(buf) + 1)
		frame, consumed, status := ws_parse_frame(buf[:cut])
		fuzz_ws_check(t, buf[:cut], frame, consumed, status)
		free_all(context.temp_allocator)
	}
}

// Encode valid unmasked server frames and parse them back exactly.
@(test)
fuzz_ws_encode_parse_round_trip :: proc(t: ^testing.T) {
	p := testx.prng_make(0x13)
	for _ in 0 ..< 10_000 {
		opcode := FUZZ_WS_OPCODES[testx.int_range(&p, 0, len(FUZZ_WS_OPCODES))]
		payload := fuzz_ws_payload(&p)
		buf := fuzz_ws_server_frame(opcode, payload)
		frame, consumed, status := ws_parse_frame(buf)
		testing.expect_value(t, status, WS_Parse_Status.Ok)
		testing.expect_value(t, consumed, len(buf))
		testing.expect_value(t, frame.opcode, opcode)
		testing.expect_value(t, frame.masked, false)
		testing.expect_value(t, string(frame.payload), string(payload[:len(frame.payload)]))
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
			encoded := fuzz_ws_server_frame(opcodes[i], payload)
			payloads[i] = payload[:min(len(payload), len(encoded) - 2)]
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

// Property: any valid fragmentation of a message (TEXT/BINARY with FIN=0
// followed by 0..n continuations, last one FIN=1) reassembles into exactly
// one logical message whose bytes equal the concatenated parts, with frag
// state fully reset afterwards.
@(test)
fuzz_ws_fragment_reassembly :: proc(t: ^testing.T) {
	p := testx.prng_make(0x15)
	ws := ws_init()
	defer ws_close(&ws)
	frag: WS_Frag_State
	defer delete(frag.buf)

	for _ in 0 ..< 5_000 {
		parts := testx.int_range(&p, 1, 6)
		binary := testx.int_range(&p, 0, 2) == 1
		expected := make([dynamic]u8, context.temp_allocator)

		for part in 0 ..< parts {
			n := testx.int_range(&p, 0, 64)
			payload := make([]u8, n, context.temp_allocator)
			for j in 0 ..< n do payload[j] = u8(testx.next_u64(&p) & 0xFF)
			append(&expected, ..payload)

			opcode := u8(WS_OP_CONTINUATION)
			if part == 0 do opcode = binary ? u8(WS_OP_BINARY) : u8(WS_OP_TEXT)
			frame := WS_Frame {
				opcode  = opcode,
				payload = payload,
				fin     = part == parts - 1,
			}
			testing.expect(t, ws_handle_data_frame(&ws, &frag, frame))
		}

		testing.expect_value(t, frag.active, false)
		msgs := ws_drain(&ws)
		testing.expect_value(t, len(msgs), 1)
		if len(msgs) == 1 {
			testing.expect_value(t, msgs[0].data, string(expected[:]))
			testing.expect_value(t, msgs[0].binary, binary)
			delete(msgs[0].data)
		}
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
			valid :=
				(ch >= 'A' && ch <= 'Z') ||
				(ch >= 'a' && ch <= 'z') ||
				(ch >= '0' && ch <= '9') ||
				ch == '+' ||
				ch == '/' ||
				ch == '='
			testing.expect(t, valid, "accept digest contains non-base64 byte")
		}
		free_all(context.temp_allocator)
	}
}
