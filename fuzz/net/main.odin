package fuzz_net

// Memory-safety fuzzer for ingot:net (TigerBeetle VOPR style).
//
// Structured-random hostile input is driven through the public parsing surface
// (parse_http_response + ws_parse_frame) and — when built with
// -define:INGOT_NET_SIM=true — through the full simulated Fetcher loop. Every
// allocation is tracked; a leak or bad free fails the run. Build with
// -sanitize:address for use-after-free / out-of-bounds detection on top.
//
// Beyond byte flips, inputs come from a structure-aware mutation engine
// (fuzz/fuzzx): template splicing, insert/delete/duplicate, boundary bytes,
// and digit-run injection. Extreme-value probes claim 64-bit lengths far past
// any allocation cap, and a rare large class breaks the old 128 KiB bound.
//
// The seed is printed FIRST so any crash reproduces exactly:
//   fuzz_net -seed:12345 -iterations:100000 [-rounds:N]

import "core:fmt"
import "core:mem"
import fuzzx "ingot:fuzz/fuzzx"
import ingotnet "ingot:net"

ITERATIONS_DEFAULT :: 100_000
MAXIMUM_WIRE_BYTES :: 4096 // hostile response size cap — parser must bound its own work
MAXIMUM_WIRE_BYTES_LARGE :: 256 * 1024 // rare large class (~1 in 200)
MAXIMUM_WS_PAYLOAD_LARGE :: 1024 * 1024 // rare large class (~1 in 200)
MAXIMUM_BODY_LIMIT :: 64 * 1024

Prng :: fuzzx.Prng

// HTTP response templates reaching different parser paths: content-length,
// chunked (+extensions), no-body statuses, many headers, malformed
// whitespace, out-of-range status, and integer-overflow length claims.
HTTP_TEMPLATES := [?]string {
	"HTTP/1.1 200 OK\r\nContent-Length: 11\r\nX-A: b\r\n\r\nhello world",
	"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-A: b\r\n\r\n" + "5;ext\r\nhello\r\n3\r\nabc\r\n0\r\n\r\n",
	"HTTP/1.1 204 No Content\r\nX-A: b\r\n\r\n",
	"HTTP/1.1 304 Not Modified\r\nETag: \"abc\"\r\n\r\n",
	"HTTP/1.1  200  OK \r\n Content-Length : 5\r\n" + "X-A:b\r\n\r\nhello",
	"HTTP/1.1 99999 Enhance Your Calm\r\nContent-Length: 3\r\n\r\nabc",
	// Extreme length claims — must be rejected or bounded, never allocated.
	"HTTP/1.1 200 OK\r\nContent-Length: 18446744073709551615\r\n\r\nx",
	"HTTP/1.1 200 OK\r\nContent-Length: 9223372036854775808\r\n\r\nx",
	"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFF\r\nx\r\n0\r\n\r\n",
	"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7FFFFFFFFFFFFFFF;ext\r\nx\r\n0\r\n\r\n",
}

// many_headers_response builds a 32-header response (temp-allocated) to
// stress header-array growth and repeated name/value slicing.
many_headers_response :: proc(p: ^Prng) -> []u8 {
	buf := make([dynamic]u8, 0, 1024, context.temp_allocator)
	append(&buf, "HTTP/1.1 200 OK\r\n")
	for i in 0 ..< 32 {
		append(&buf, fmt.tprintf("X-Header-%02d: value-%02d\r\n", i, i))
	}
	append(&buf, "Content-Length: 5\r\n\r\nhello")
	return buf[:]
}

// mutated_response picks a template, applies the full mutator set, sometimes
// splices in a slice of another template (chunked framing into content-length
// responses and vice versa), and truncates at a random point.
mutated_response :: proc(p: ^Prng) -> []u8 {
	base: []u8
	if fuzzx.int_range(p, 0, 8) == 0 {
		base = many_headers_response(p)
	} else {
		base = transmute([]u8)HTTP_TEMPLATES[fuzzx.int_range(p, 0, len(HTTP_TEMPLATES))]
	}
	buf := fuzzx.mutate(p, base)
	if fuzzx.int_range(p, 0, 3) == 0 {
		other := transmute([]u8)HTTP_TEMPLATES[fuzzx.int_range(p, 0, len(HTTP_TEMPLATES))]
		buf = fuzzx.splice(p, buf, other)
	}
	cut := fuzzx.int_range(p, 0, len(buf) + 1)
	return buf[:cut]
}

exercise_parse :: proc(c: ^fuzzx.Ctx, p: ^Prng) {
	data: []u8
	if fuzzx.int_range(p, 0, 3) == 0 {
		// Rare large class: 256 KiB wire buffers (~1 in 200 overall).
		maximum :=
			MAXIMUM_WIRE_BYTES_LARGE if fuzzx.int_range(p, 0, 67) == 0 else MAXIMUM_WIRE_BYTES
		data = fuzzx.random_bytes(p, maximum)
	} else {
		data = mutated_response(p)
	}
	c.input = data
	response, ok := ingotnet.parse_http_response(data, MAXIMUM_BODY_LIMIT, context.temp_allocator)
	if ok {
		// The parser must respect the caller's body budget on ANY input.
		fuzzx.check(c, len(response.body) <= MAXIMUM_BODY_LIMIT, "parser exceeded maximum_body")
		fuzzx.check(c, response.status >= 100, "parser accepted an invalid status")
		fuzzx.check(c, response.status <= 599, "parser accepted an invalid status")
	}
}

WS_OPCODES := [?]u8 {
	0x0,
	ingotnet.WS_OP_TEXT,
	ingotnet.WS_OP_BINARY,
	ingotnet.WS_OP_CLOSE,
	ingotnet.WS_OP_PING,
	ingotnet.WS_OP_PONG,
}

ws_mask_key :: proc(p: ^Prng) -> [4]u8 {
	r := fuzzx.next_u64(p)
	return [4]u8{u8(r), u8(r >> 8), u8(r >> 16), u8(r >> 24)}
}

// A valid frame corrupted by the full mutator set reaches deep into the
// extended-length and mask-offset arithmetic of ws_parse_frame.
mutated_ws_frame :: proc(p: ^Prng) -> []u8 {
	opcode := WS_OPCODES[fuzzx.int_range(p, 0, len(WS_OPCODES))]
	// Payload sized to hit all three header length classes; the rare large
	// class (~1 in 200 overall) goes up to 1 MiB.
	n: int
	switch fuzzx.int_range(p, 0, 3) {
	case 0:
		n = fuzzx.int_range(p, 0, 126)
	case 1:
		n = fuzzx.int_range(p, 126, 65536)
	case:
		if fuzzx.int_range(p, 0, 67) == 0 {
			n = fuzzx.int_range(p, 128 * 1024, MAXIMUM_WS_PAYLOAD_LARGE)
		} else {
			n = fuzzx.int_range(p, 65536, 128 * 1024)
		}
	}
	payload := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n do payload[i] = u8(fuzzx.next_u64(p) & 0xFF)
	buf := ingotnet.ws_encode_frame(opcode, payload, ws_mask_key(p), context.temp_allocator)
	buf = fuzzx.mutate(p, buf)
	cut := fuzzx.int_range(p, 0, len(buf) + 1)
	return buf[:cut]
}

// extreme_ws_header hand-crafts a frame header claiming a 64-bit payload
// length far beyond any allocation (up to 1<<63). The parser must classify
// it (Need_More / Too_Big) without allocating or consuming — this exercises
// the overflow paths that bounded payload generation can never reach.
extreme_ws_header :: proc(p: ^Prng) -> []u8 {
	buf := make([dynamic]u8, 0, 32, context.temp_allocator)
	opcode := WS_OPCODES[fuzzx.int_range(p, 0, len(WS_OPCODES))]
	fin: u8 = fuzzx.int_range(p, 0, 2) == 0 ? 0x80 : 0x00
	append(&buf, fin | opcode)
	masked: u8 = fuzzx.int_range(p, 0, 2) == 0 ? 0x80 : 0x00
	append(&buf, masked | 127) // 64-bit extended length follows
	exponent := uint(fuzzx.int_range(p, 25, 64)) // 32 MiB .. 1<<63
	claim := (u64(1) << exponent) | (fuzzx.next_u64(p) & ((u64(1) << exponent) - 1))
	for shift := 56; shift >= 0; shift -= 8 {
		append(&buf, u8(claim >> uint(shift)))
	}
	if masked != 0 {
		key := ws_mask_key(p)
		append(&buf, ..key[:])
	}
	// A few payload bytes — never enough to satisfy the claim.
	trailing := fuzzx.random_bytes(p, 32)
	append(&buf, ..trailing)
	return buf[:]
}

exercise_ws_parse :: proc(c: ^fuzzx.Ctx, p: ^Prng) {
	data: []u8
	extreme := false
	switch fuzzx.int_range(p, 0, 6) {
	case 0, 1:
		data = fuzzx.random_bytes(p, MAXIMUM_WIRE_BYTES)
	case 2:
		data = extreme_ws_header(p)
		extreme = true
	case:
		data = mutated_ws_frame(p)
	}
	c.input = data
	frame, consumed, status := ingotnet.ws_parse_frame(data)
	fuzzx.check(c, consumed >= 0, "ws parser reported negative consumed")
	fuzzx.check(c, consumed <= len(data), "ws parser consumed past the buffer")
	if extreme {
		// The claimed length always exceeds the buffer, so a successful
		// parse would mean the length arithmetic overflowed.
		fuzzx.check(c, status != .Ok, "ws parser accepted an unsatisfiable 64-bit length claim")
	}
	switch status {
	case .Need_More, .Too_Big:
		fuzzx.check(c, consumed == 0, "ws parser consumed bytes without a complete frame")
	case .Ok:
		fuzzx.check(
			c,
			len(frame.payload) <= ingotnet.WS_MAX_PAYLOAD,
			"ws parser exceeded WS_MAX_PAYLOAD",
		)
		if len(frame.payload) > 0 {
			start := uintptr(raw_data(data))
			payload_start := uintptr(raw_data(frame.payload))
			fuzzx.check(c, payload_start >= start, "ws payload starts before the buffer")
			fuzzx.check(
				c,
				payload_start + uintptr(len(frame.payload)) <= start + uintptr(consumed),
				"ws payload extends past the consumed frame",
			)
		}
	}
}

// exercise_ws_stream concatenates several valid frames and reassembles them
// from random 1–1500-byte TCP-like chunks, mirroring ws_recv_loop's
// accumulator — under ASan and the tracking allocator, unlike the odin-test
// mirror in net/ws_fuzz_test.odin.
ws_server_frame :: proc(opcode: u8, payload: []u8) -> []u8 {
	body := payload
	if opcode >= ingotnet.WS_OP_CLOSE && len(body) > 125 do body = body[:125]
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
		for i := 7; i >= 0; i -= 1 {
			frame[2 + (7 - i)] = u8((len(body) >> uint(i * 8)) & 0xFF)
		}
	}
	copy(frame[header_size:], body)
	return frame
}

exercise_ws_stream :: proc(c: ^fuzzx.Ctx, p: ^Prng) {
	frame_count := fuzzx.int_range(p, 1, 9)
	opcodes := make([]u8, frame_count, context.temp_allocator)
	payloads := make([][]u8, frame_count, context.temp_allocator)
	stream := make([dynamic]u8, context.temp_allocator)
	for i in 0 ..< frame_count {
		opcodes[i] = WS_OPCODES[fuzzx.int_range(p, 0, len(WS_OPCODES))]
		n := fuzzx.int_range(p, 0, 300)
		if opcodes[i] >= ingotnet.WS_OP_CLOSE do n = min(n, 125)
		payload := make([]u8, n, context.temp_allocator)
		for j in 0 ..< n do payload[j] = u8(fuzzx.next_u64(p) & 0xFF)
		encoded := ws_server_frame(opcodes[i], payload)
		payloads[i] = payload
		append(&stream, ..encoded)
	}
	c.input = stream[:]

	acc := make([dynamic]u8, context.temp_allocator)
	got := 0
	fed := 0
	for fed < len(stream) {
		chunk := min(fuzzx.int_range(p, 1, 1501), len(stream) - fed)
		append(&acc, ..stream[fed:fed + chunk])
		fed += chunk

		offset := 0
		for offset < len(acc) {
			frame, consumed, status := ingotnet.ws_parse_frame(acc[offset:])
			if status == .Need_More do break
			fuzzx.check(c, status == .Ok, "valid stream frame rejected")
			fuzzx.check(c, got < frame_count, "stream produced more frames than encoded")
			fuzzx.check(c, frame.opcode == opcodes[got], "stream frame opcode mismatch")
			fuzzx.check(
				c,
				string(frame.payload) == string(payloads[got]),
				"stream frame payload mismatch",
			)
			got += 1
			offset += consumed
		}
		if offset > 0 {
			remove_range(&acc, 0, offset)
		}
	}
	fuzzx.check(c, got == frame_count, "stream lost frames")
	fuzzx.check(c, len(acc) == 0, "stream left unconsumed bytes")
}

main :: proc() {
	seed, iterations, rounds := fuzzx.parse_options(ITERATIONS_DEFAULT)
	fmt.printfln("fuzz_net seed=%d iterations=%d rounds=%d", seed, iterations, rounds)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	for round in 0 ..< rounds {
		round_seed := seed + u64(round)
		if rounds > 1 do fmt.printfln("fuzz_net round %d seed=%d", round, round_seed)
		p := fuzzx.prng_make(round_seed)
		c := fuzzx.Ctx {
			name = "fuzz_net",
			seed = round_seed,
		}
		for i in 0 ..< iterations {
			c.iteration = i
			exercise_parse(&c, &p)
			exercise_ws_parse(&c, &p)
			if i % 16 == 0 do exercise_ws_stream(&c, &p)
			free_all(context.temp_allocator)
		}

		when ingotnet.INGOT_NET_SIM {
			exercise_sim_fetcher(&p, round_seed)
		}
	}

	fuzzx.report(&track, "fuzz_net", seed)
	fmt.printfln("fuzz_net ok")
}

when ingotnet.INGOT_NET_SIM {
	// Drive the full simulated Fetcher at maximum fault rate: every request is
	// cloned, faulted, delivered, and freed. Leaks here are transport bugs.
	exercise_sim_fetcher :: proc(p: ^Prng, seed: u64) {
		f: ingotnet.Fetcher
		respond := proc(
			request: ingotnet.Http_Request,
			prng: ^ingotnet.Sim_Prng,
		) -> ingotnet.Fetch_Result {
			body := make([]u8, ingotnet.sim_int_range(prng, 0, 256))
			for i in 0 ..< len(body) do body[i] = u8(ingotnet.sim_next_u64(prng) & 0xFF)
			return ingotnet.Fetch_Result{status = 200, body = body, ok = true}
		}
		ingotnet.sim_fetcher_init(&f, seed, 1.0, respond)
		ingotnet.fetcher_start(&f, "sim", 0)
		defer ingotnet.fetcher_stop(&f)

		tag: u64 = 1
		for _ in 0 ..< 50_000 {
			header_value := fuzzx.random_bytes(p, 64)
			request := ingotnet.Http_Request {
				method       = ingotnet.Http_Method(fuzzx.int_range(p, 0, 5)),
				path         = "/fuzz",
				headers      = []ingotnet.Http_Header {
					{name = "X-Fuzz", value = string(header_value)},
				},
				body         = fuzzx.random_bytes(p, 128),
				maximum_body = u64(fuzzx.int_range(p, 0, MAXIMUM_BODY_LIMIT)),
			}
			_ = ingotnet.fetcher_request_http(&f, tag, request)
			tag += 1
			ingotnet.sim_tick(&f)
			for result in ingotnet.fetcher_drain(&f) do delete(result.body)
			free_all(context.temp_allocator)
		}
	}
}
