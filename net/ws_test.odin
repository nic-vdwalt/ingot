#+build !js
package ingotnet

import "core:strings"
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
test_ws_parse_rejects_masked_server_frame :: proc(t: ^testing.T) {
	buf := []u8{0x82, 0x83, 1, 2, 3, 4, 'h' ~ 1, 'i' ~ 2, '!' ~ 3}
	_, consumed, status := ws_parse_frame(buf)
	testing.expect_value(t, status, WS_Parse_Status.Too_Big)
	testing.expect_value(t, consumed, 0)
	testing.expect_value(t, ws_stream_parse_action(status, consumed), WS_Stream_Parse_Action.Drop)
}

@(test)
test_ws_stream_parse_action_requires_progress :: proc(t: ^testing.T) {
	testing.expect_value(t, ws_stream_parse_action(.Need_More, 0), WS_Stream_Parse_Action.Wait)
	testing.expect_value(t, ws_stream_parse_action(.Too_Big, 0), WS_Stream_Parse_Action.Drop)
	testing.expect_value(t, ws_stream_parse_action(.Ok, 0), WS_Stream_Parse_Action.Drop)
	testing.expect_value(t, ws_stream_parse_action(.Ok, 2), WS_Stream_Parse_Action.Advance)
}

@(test)
test_ws_connection_configuration_is_explicit :: proc(t: ^testing.T) {
	secure, secure_err := ws_url_parse("wss://example.test:8443/events")
	testing.expect_value(t, secure_err, WS_URL_Error.None)
	testing.expect_value(t, secure.scheme, WS_Scheme.Wss)
	testing.expect_value(t, secure.port, u16(8443))
	plain, plain_err := ws_url_parse("ws://example.test:443/events")
	testing.expect_value(t, plain_err, WS_URL_Error.None)
	testing.expect_value(t, plain.scheme, WS_Scheme.Ws)
}

@(test)
test_ws_invalid_url_fails_synchronously :: proc(t: ^testing.T) {
	ws := ws_init()
	started := ws_start_connect_url(&ws, "https://example.test/ws")
	testing.expect(t, !started)
	testing.expect_value(t, ws_state(&ws), WS_State.Error)
	testing.expect_value(t, ws_error(&ws), WS_Error.Invalid_URL)
	ws_close(&ws)
}

@(test)
test_ws_connection_owns_url_components :: proc(t: ^testing.T) {
	ws := ws_init()
	raw_url := strings.clone("ws://127.0.0.1:65534/session")
	started := ws_start_connect_url(&ws, raw_url, WS_Options{max_attempts = 1})
	delete(raw_url)
	testing.expect(t, started)
	testing.expect_value(t, ws.host, "127.0.0.1")
	testing.expect_value(t, ws.path, "/session")
	ws_close(&ws)
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
	// Server frames carrying the client mask bit are rejected immediately.
	_, masked_consumed, masked_status := ws_parse_frame([]u8{0x81, 0x80, 0xAA, 0xBB})
	testing.expect_value(t, masked_status, WS_Parse_Status.Too_Big)
	testing.expect_value(t, masked_consumed, 0)
	// Mid payload (declared 5 bytes, only 2 present).
	check_need_more(t, []u8{0x81, 0x05, 'h', 'e'})
}

// -- ws_parse_frame: size limits ----------------------------------------------

@(test)
test_ws_parse_too_big :: proc(t: ^testing.T) {
	// Declared 64-bit length just above WS_MAX_PAYLOAD (no payload attached -
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
	// High bit set in the 64-bit length overflows signed int - must be
	// rejected as Too_Big, never treated as a valid (huge) length.
	buf := []u8{0x81, 127, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}
	_, consumed, status := ws_parse_frame(buf)
	testing.expect_value(t, status, WS_Parse_Status.Too_Big)
	testing.expect_value(t, consumed, 0)
}

// -- ws_parse_frame: streams ---------------------------------------------------

@(test)
test_ws_parse_back_to_back_frames :: proc(t: ^testing.T) {
	buf := []u8 {
		0x81,
		0x02,
		'h',
		'i', // text "hi"
		0x89,
		0x01,
		'p', // ping "p"
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

// -- ws_parse_frame: FIN bit ---------------------------------------------------

@(test)
test_ws_parse_fin_bit :: proc(t: ^testing.T) {
	// FIN set: 0x81 = FIN + text.
	frame, _, status := ws_parse_frame([]u8{0x81, 0x02, 'h', 'i'})
	testing.expect_value(t, status, WS_Parse_Status.Ok)
	testing.expect_value(t, frame.fin, true)

	// FIN clear: 0x01 = text fragment start.
	frame2, _, status2 := ws_parse_frame([]u8{0x01, 0x02, 'h', 'i'})
	testing.expect_value(t, status2, WS_Parse_Status.Ok)
	testing.expect_value(t, frame2.fin, false)
	testing.expect_value(t, frame2.opcode, u8(WS_OP_TEXT))

	// FIN set on a continuation frame: 0x80 = FIN + opcode 0.
	frame3, _, status3 := ws_parse_frame([]u8{0x80, 0x01, 'x'})
	testing.expect_value(t, status3, WS_Parse_Status.Ok)
	testing.expect_value(t, frame3.fin, true)
	testing.expect_value(t, frame3.opcode, u8(WS_OP_CONTINUATION))
}

// -- ws_handle_data_frame: fragment reassembly (RFC 6455 §5.4) -----------------

// Drain exactly one message and return it (empty message + false if the
// queue does not hold exactly one).
@(private = "file")
drain_one :: proc(t: ^testing.T, ws: ^WebSocket, loc := #caller_location) -> (WS_Message, bool) {
	msgs := ws_drain(ws)
	testing.expect_value(t, len(msgs), 1, loc = loc)
	if len(msgs) != 1 do return {}, false
	return msgs[0], true
}

@(test)
test_ws_frag_two_part_text :: proc(t: ^testing.T) {
	ws := ws_init()
	defer ws_close(&ws)
	frag: WS_Frag_State
	defer delete(frag.buf)

	testing.expect(
		t,
		ws_handle_data_frame(
			&ws,
			&frag,
			{opcode = WS_OP_TEXT, payload = {'h', 'e', 'l'}, fin = false},
		),
	)
	testing.expect_value(t, frag.active, true)
	testing.expect_value(t, len(ws_drain(&ws)), 0) // nothing until FIN
	// A control frame (PING) may interleave here - it never touches frag
	// state, so reassembly must complete normally afterwards.
	testing.expect(
		t,
		ws_handle_data_frame(
			&ws,
			&frag,
			{opcode = WS_OP_CONTINUATION, payload = {'l', 'o'}, fin = true},
		),
	)
	testing.expect_value(t, frag.active, false)

	if msg, ok := drain_one(t, &ws); ok {
		defer delete(msg.data)
		testing.expect_value(t, msg.data, "hello")
		testing.expect_value(t, msg.binary, false)
	}
}

@(test)
test_ws_frag_three_part_binary :: proc(t: ^testing.T) {
	ws := ws_init()
	defer ws_close(&ws)
	frag: WS_Frag_State
	defer delete(frag.buf)

	testing.expect(
		t,
		ws_handle_data_frame(&ws, &frag, {opcode = WS_OP_BINARY, payload = {1, 2}, fin = false}),
	)
	testing.expect(
		t,
		ws_handle_data_frame(
			&ws,
			&frag,
			{opcode = WS_OP_CONTINUATION, payload = {3}, fin = false},
		),
	)
	testing.expect(
		t,
		ws_handle_data_frame(
			&ws,
			&frag,
			{opcode = WS_OP_CONTINUATION, payload = {4, 5}, fin = true},
		),
	)
	testing.expect_value(t, frag.active, false)

	if msg, ok := drain_one(t, &ws); ok {
		defer delete(msg.data)
		expected := []u8{1, 2, 3, 4, 5}
		testing.expect_value(t, msg.data, string(expected))
		testing.expect_value(t, msg.binary, true)
	}
}

@(test)
test_ws_frag_bare_continuation_rejected :: proc(t: ^testing.T) {
	ws := ws_init()
	defer ws_close(&ws)
	frag: WS_Frag_State
	defer delete(frag.buf)

	// Continuation with no fragment in flight is a protocol error.
	testing.expect_value(
		t,
		ws_handle_data_frame(
			&ws,
			&frag,
			{opcode = WS_OP_CONTINUATION, payload = {'x'}, fin = true},
		),
		false,
	)
	testing.expect_value(t, len(ws_drain(&ws)), 0)
}

@(test)
test_ws_frag_interleaved_data_rejected :: proc(t: ^testing.T) {
	ws := ws_init()
	defer ws_close(&ws)
	frag: WS_Frag_State
	defer delete(frag.buf)

	testing.expect(
		t,
		ws_handle_data_frame(&ws, &frag, {opcode = WS_OP_TEXT, payload = {'a'}, fin = false}),
	)
	// A new data message may not start inside an unfinished sequence -
	// whether or not it is itself fragmented.
	testing.expect_value(
		t,
		ws_handle_data_frame(&ws, &frag, {opcode = WS_OP_TEXT, payload = {'b'}, fin = true}),
		false,
	)
	testing.expect_value(
		t,
		ws_handle_data_frame(&ws, &frag, {opcode = WS_OP_BINARY, payload = {'c'}, fin = false}),
		false,
	)
}

@(test)
test_ws_frag_oversize_rejected :: proc(t: ^testing.T) {
	ws := ws_init()
	defer ws_close(&ws)
	frag: WS_Frag_State
	defer delete(frag.buf)

	// Start a fragment, then inflate the assembled buffer to the ceiling:
	// the next continuation byte must trip the WS_MAX_PAYLOAD bound.
	testing.expect(
		t,
		ws_handle_data_frame(&ws, &frag, {opcode = WS_OP_TEXT, payload = {'a'}, fin = false}),
	)
	resize(&frag.buf, WS_MAX_PAYLOAD)
	testing.expect_value(
		t,
		ws_handle_data_frame(
			&ws,
			&frag,
			{opcode = WS_OP_CONTINUATION, payload = {'b'}, fin = true},
		),
		false,
	)
	testing.expect_value(t, len(ws_drain(&ws)), 0)
}

// -- ws_encode_frame -----------------------------------------------------------

@(test)
test_ws_encode_frame_layout :: proc(t: ^testing.T) {
	mask := [4]u8{1, 2, 3, 4}
	frame := ws_encode_frame(WS_OP_TEXT, {'a', 'b'}, mask, context.temp_allocator)
	testing.expect_value(t, len(frame), 2 + 4 + 2)
	testing.expect_value(t, frame[0], u8(0x80 | WS_OP_TEXT)) // FIN + opcode
	testing.expect_value(t, frame[1], u8(0x80 | 2)) // mask bit + len
	testing.expect_value(t, frame[2], u8(1))
	testing.expect_value(t, frame[6], 'a' ~ u8(1))
	testing.expect_value(t, frame[7], 'b' ~ u8(2))
}

// -- ws_handshake_response_valid ----------------------------------------------

@(private = "file")
handshake_response :: proc(status: string, headers: string) -> string {
	return strings.concatenate({status, "\r\n", headers, "\r\n\r\n"}, context.temp_allocator)
}

@(test)
test_ws_handshake_valid_response_accepted :: proc(t: ^testing.T) {
	key := "dGhlIHNhbXBsZSBub25jZQ=="
	accept := ws_accept_for_key(key)
	headers := strings.concatenate(
		{"UPGRADE: WebSocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: ", accept},
		context.temp_allocator,
	)
	response := handshake_response("HTTP/1.1 101 Switching Protocols", headers)
	testing.expect(t, ws_handshake_response_valid(response, key))
}

@(test)
test_ws_handshake_accept_in_body_rejected :: proc(t: ^testing.T) {
	// The accept token appearing outside the Sec-WebSocket-Accept header must
	// not satisfy the check (the pre-fix substring match accepted this).
	key := "dGhlIHNhbXBsZSBub25jZQ=="
	accept := ws_accept_for_key(key)
	headers := strings.concatenate(
		{"Upgrade: websocket\r\nConnection: Upgrade\r\nX-Echo: ", accept},
		context.temp_allocator,
	)
	response := handshake_response("HTTP/1.1 101 Switching Protocols", headers)
	testing.expect(t, !ws_handshake_response_valid(response, key))
}

@(test)
test_ws_handshake_missing_or_wrong_upgrade_rejected :: proc(t: ^testing.T) {
	key := "dGhlIHNhbXBsZSBub25jZQ=="
	accept := ws_accept_for_key(key)
	missing := strings.concatenate(
		{"Connection: Upgrade\r\nSec-WebSocket-Accept: ", accept},
		context.temp_allocator,
	)
	response := handshake_response("HTTP/1.1 101 Switching Protocols", missing)
	testing.expect(t, !ws_handshake_response_valid(response, key))
	wrong := strings.concatenate(
		{"Upgrade: h2c\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ", accept},
		context.temp_allocator,
	)
	response = handshake_response("HTTP/1.1 101 Switching Protocols", wrong)
	testing.expect(t, !ws_handshake_response_valid(response, key))
}

@(test)
test_ws_handshake_missing_or_wrong_connection_rejected :: proc(t: ^testing.T) {
	key := "dGhlIHNhbXBsZSBub25jZQ=="
	accept := ws_accept_for_key(key)
	missing := strings.concatenate(
		{"Upgrade: websocket\r\nSec-WebSocket-Accept: ", accept},
		context.temp_allocator,
	)
	response := handshake_response("HTTP/1.1 101 Switching Protocols", missing)
	testing.expect(t, !ws_handshake_response_valid(response, key))
	wrong := strings.concatenate(
		{"Upgrade: websocket\r\nConnection: close\r\nSec-WebSocket-Accept: ", accept},
		context.temp_allocator,
	)
	response = handshake_response("HTTP/1.1 101 Switching Protocols", wrong)
	testing.expect(t, !ws_handshake_response_valid(response, key))
}

@(test)
test_ws_handshake_non_101_rejected :: proc(t: ^testing.T) {
	key := "dGhlIHNhbXBsZSBub25jZQ=="
	accept := ws_accept_for_key(key)
	headers := strings.concatenate(
		{"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ", accept},
		context.temp_allocator,
	)
	response := handshake_response("HTTP/1.1 200 OK", headers)
	testing.expect(t, !ws_handshake_response_valid(response, key))
}

@(test)
test_ws_handshake_wrong_accept_rejected :: proc(t: ^testing.T) {
	key := "dGhlIHNhbXBsZSBub25jZQ=="
	headers := "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: bm90LXRoZS1yaWdodC1hbnN3ZXI="
	response := handshake_response("HTTP/1.1 101 Switching Protocols", headers)
	testing.expect(t, !ws_handshake_response_valid(response, key))
}

@(test)
test_ws_handshake_truncated_headers_rejected :: proc(t: ^testing.T) {
	key := "dGhlIHNhbXBsZSBub25jZQ=="
	// No terminating blank line: the response never completed.
	testing.expect(t, !ws_handshake_response_valid("HTTP/1.1 101\r\nUpgrade: websocket", key))
}
