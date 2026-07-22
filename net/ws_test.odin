#+build !js
package ingotnet

import "core:testing"

// -- ws_parse_frame: header classes ------------------------------------------

@(test)
test_ws_parse_7bit_unmasked :: proc(t: ^testing.T) {
	// FIN + text, unmasked, 5-byte payload.
	buf := []u8{0x81, 0x05, 'h', 'e', 'l', 'l', 'o'}
	frame, consumed, status := ws_parse_frame(buf)
	testing.expect_value(t, status, WS_Parse_Status.Ok)
	testing.expect_value(t, consumed, 7)
	testing.expect_value(t, frame.opcode, u8(WS_OP_TEXT))
	testing.expect_value(t, frame.masked, false)
	testing.expect_value(t, string(frame.payload), "hello")
}

@(test)
test_ws_parse_7bit_masked :: proc(t: ^testing.T) {
	mask := [4]u8{0xA1, 0xB2, 0xC3, 0xD4}
	payload := []u8{'h', 'i', '!'}
	buf := make([dynamic]u8, context.temp_allocator)
	append(&buf, 0x82, 0x80 | 0x03, mask[0], mask[1], mask[2], mask[3])
	for b, i in payload do append(&buf, b ~ mask[i % 4])

	frame, consumed, status := ws_parse_frame(buf[:])
	testing.expect_value(t, status, WS_Parse_Status.Ok)
	testing.expect_value(t, consumed, 9)
	testing.expect_value(t, frame.opcode, u8(WS_OP_BINARY))
	testing.expect_value(t, frame.masked, true)
	testing.expect_value(t, string(frame.payload), "hi!")
}

@(test)
test_ws_parse_16bit_length :: proc(t: ^testing.T) {
	n := 300
	buf := make([dynamic]u8, context.temp_allocator)
	append(&buf, 0x81, 126, u8(n >> 8), u8(n & 0xFF))
	for i in 0 ..< n do append(&buf, u8(i & 0xFF))

	frame, consumed, status := ws_parse_frame(buf[:])
	testing.expect_value(t, status, WS_Parse_Status.Ok)
	testing.expect_value(t, consumed, 4 + n)
	testing.expect_value(t, len(frame.payload), n)
	testing.expect_value(t, frame.payload[299], u8(299 & 0xFF))
}

@(test)
test_ws_parse_64bit_length :: proc(t: ^testing.T) {
	n := 70_000
	buf := make([dynamic]u8, context.temp_allocator)
	append(&buf, 0x82, 127)
	for i := 7; i >= 0; i -= 1 {
		append(&buf, u8((n >> uint(i * 8)) & 0xFF))
	}
	for i in 0 ..< n do append(&buf, u8(i & 0xFF))

	frame, consumed, status := ws_parse_frame(buf[:])
	testing.expect_value(t, status, WS_Parse_Status.Ok)
	testing.expect_value(t, consumed, 10 + n)
	testing.expect_value(t, len(frame.payload), n)
}

// -- ws_parse_frame: truncation points ----------------------------------------

@(test)
test_ws_parse_need_more :: proc(t: ^testing.T) {
	// Empty and 1-byte header.
	check_need_more :: proc(t: ^testing.T, buf: []u8, loc := #caller_location) {
		_, consumed, status := ws_parse_frame(buf)
		testing.expect_value(t, status, WS_Parse_Status.Need_More, loc = loc)
		testing.expect_value(t, consumed, 0, loc = loc)
	}
	check_need_more(t, nil)
	check_need_more(t, []u8{0x81})
	// Mid 16-bit extended length.
	check_need_more(t, []u8{0x81, 126, 0x01})
	// Mid 64-bit extended length.
	check_need_more(t, []u8{0x81, 127, 0, 0, 0, 0, 0, 0, 0})
	// Mid mask key (masked, len 0, only 2 of 4 key bytes).
	check_need_more(t, []u8{0x81, 0x80, 0xAA, 0xBB})
	// Mid payload (declared 5 bytes, only 2 present).
	check_need_more(t, []u8{0x81, 0x05, 'h', 'e'})
}

// -- ws_parse_frame: size limits ----------------------------------------------

@(test)
test_ws_parse_too_big :: proc(t: ^testing.T) {
	// Declared 64-bit length just above WS_MAX_PAYLOAD (no payload attached —
	// the limit must trip before completeness is considered).
	n := u64(WS_MAX_PAYLOAD) + 1
	buf := make([dynamic]u8, context.temp_allocator)
	append(&buf, 0x81, 127)
	for i := 7; i >= 0; i -= 1 {
		append(&buf, u8((n >> uint(i * 8)) & 0xFF))
	}
	_, consumed, status := ws_parse_frame(buf[:])
	testing.expect_value(t, status, WS_Parse_Status.Too_Big)
	testing.expect_value(t, consumed, 0)
}

@(test)
test_ws_parse_negative_64bit_length :: proc(t: ^testing.T) {
	// High bit set in the 64-bit length overflows signed int — must be
	// rejected as Too_Big, never treated as a valid (huge) length.
	buf := []u8{0x81, 127, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}
	_, consumed, status := ws_parse_frame(buf)
	testing.expect_value(t, status, WS_Parse_Status.Too_Big)
	testing.expect_value(t, consumed, 0)
}

// -- ws_parse_frame: streams ---------------------------------------------------

@(test)
test_ws_parse_back_to_back_frames :: proc(t: ^testing.T) {
	buf := []u8{
		0x81, 0x02, 'h', 'i', // text "hi"
		0x89, 0x01, 'p', // ping "p"
	}
	frame, consumed, status := ws_parse_frame(buf)
	testing.expect_value(t, status, WS_Parse_Status.Ok)
	testing.expect_value(t, consumed, 4)
	testing.expect_value(t, frame.opcode, u8(WS_OP_TEXT))
	testing.expect_value(t, string(frame.payload), "hi")

	frame2, consumed2, status2 := ws_parse_frame(buf[consumed:])
	testing.expect_value(t, status2, WS_Parse_Status.Ok)
	testing.expect_value(t, consumed2, 3)
	testing.expect_value(t, frame2.opcode, u8(WS_OP_PING))
	testing.expect_value(t, string(frame2.payload), "p")
}

// -- ws_encode_frame -----------------------------------------------------------

@(test)
test_ws_encode_frame_layout :: proc(t: ^testing.T) {
	mask := [4]u8{1, 2, 3, 4}
	frame := ws_encode_frame(WS_OP_TEXT, {'a', 'b'}, mask, context.temp_allocator)
	testing.expect_value(t, len(frame), 2 + 4 + 2)
	testing.expect_value(t, frame[0], u8(0x80 | WS_OP_TEXT)) // FIN + opcode
	testing.expect_value(t, frame[1], u8(0x80 | 2))          // mask bit + len
	testing.expect_value(t, frame[2], u8(1))
	testing.expect_value(t, frame[6], 'a' ~ u8(1))
	testing.expect_value(t, frame[7], 'b' ~ u8(2))
}
