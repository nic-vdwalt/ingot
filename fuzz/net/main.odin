package fuzz_net

// Memory-safety fuzzer for ingot:net (TigerBeetle VOPR style).
//
// Structured-random hostile input is driven through the public parsing surface
// (parse_http_response + ws_parse_frame) and — when built with
// -define:INGOT_NET_SIM=true — through the full simulated Fetcher loop. Every
// allocation is tracked; a leak or bad free fails the run. Build with
// -sanitize:address for use-after-free / out-of-bounds detection on top.
//
// The seed is printed FIRST so any crash reproduces exactly:
//   fuzz_net -seed:12345 -iterations:100000

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import ingotnet "ingot:net"

ITERATIONS_DEFAULT :: 100_000
MAXIMUM_WIRE_BYTES :: 4096 // hostile response size cap — parser must bound its own work
MAXIMUM_BODY_LIMIT :: 64 * 1024

// xorshift64* — same generator as the sim transport, duplicated so this
// harness has zero non-core dependencies beyond ingot:net.
Prng :: struct {
	state: u64,
}

prng_make :: proc(seed: u64) -> Prng {
	return Prng{state = seed == 0 ? 0x9E3779B97F4A7C15 : seed}
}

next_u64 :: proc(p: ^Prng) -> u64 {
	x := p.state
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	p.state = x
	return x * 0x2545F4914F6CDD1D
}

// int_range returns a value in [lo, hi).
int_range :: proc(p: ^Prng, lo, hi: int) -> int {
	if hi <= lo do return lo
	return lo + int(next_u64(p) % u64(hi - lo))
}

parse_options :: proc() -> (seed: u64, iterations: int) {
	seed = u64(time.now()._nsec) // replaced by -seed:N for reproduction runs
	iterations = ITERATIONS_DEFAULT
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "-seed:") {
			if value, ok := strconv.parse_u64(arg[len("-seed:"):]); ok do seed = value
		}
		if strings.has_prefix(arg, "-iterations:") {
			if value, ok := strconv.parse_int(arg[len("-iterations:"):]); ok do iterations = value
		}
	}
	assert(iterations > 0)
	return seed, iterations
}

random_bytes :: proc(p: ^Prng, maximum: int) -> []u8 {
	n := int_range(p, 0, maximum)
	b := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n do b[i] = u8(next_u64(p) & 0xFF)
	return b
}

// A valid-ish response template mutated by byte flips and truncation reaches
// deep into header parsing, content-length handling, and chunked decoding.
mutated_response :: proc(p: ^Prng) -> []u8 {
	base := "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-A: b\r\n\r\n5;ext\r\nhello\r\n3\r\nabc\r\n0\r\n\r\n"
	buf := make([]u8, len(base), context.temp_allocator)
	copy(buf, base)
	for _ in 0 ..< int_range(p, 1, 8) {
		buf[int_range(p, 0, len(buf))] = u8(next_u64(p) & 0xFF)
	}
	cut := int_range(p, 0, len(buf) + 1)
	return buf[:cut]
}

exercise_parse :: proc(p: ^Prng) {
	data := random_bytes(p, MAXIMUM_WIRE_BYTES) if int_range(p, 0, 2) == 0 else mutated_response(p)
	response, ok := ingotnet.parse_http_response(data, MAXIMUM_BODY_LIMIT, context.temp_allocator)
	if ok {
		// The parser must respect the caller's body budget on ANY input.
		ensure(len(response.body) <= MAXIMUM_BODY_LIMIT, "parser exceeded maximum_body")
		ensure(response.status >= 100, "parser accepted an invalid status")
		ensure(response.status <= 599, "parser accepted an invalid status")
	}
}

WS_OPCODES := [?]u8{0x0, ingotnet.WS_OP_TEXT, ingotnet.WS_OP_BINARY, ingotnet.WS_OP_CLOSE, ingotnet.WS_OP_PING, ingotnet.WS_OP_PONG}

// A valid frame corrupted by byte flips and truncation reaches deep into the
// extended-length and mask-offset arithmetic of ws_parse_frame.
mutated_ws_frame :: proc(p: ^Prng) -> []u8 {
	opcode := WS_OPCODES[int_range(p, 0, len(WS_OPCODES))]
	// Payload sized to hit all three header length classes.
	n: int
	switch int_range(p, 0, 3) {
	case 0:
		n = int_range(p, 0, 126)
	case 1:
		n = int_range(p, 126, 65536)
	case:
		n = int_range(p, 65536, 128 * 1024)
	}
	payload := make([]u8, n, context.temp_allocator)
	for i in 0 ..< n do payload[i] = u8(next_u64(p) & 0xFF)
	r := next_u64(p)
	mask_key := [4]u8{u8(r), u8(r >> 8), u8(r >> 16), u8(r >> 24)}
	buf := ingotnet.ws_encode_frame(opcode, payload, mask_key, context.temp_allocator)
	for _ in 0 ..< int_range(p, 1, 8) {
		buf[int_range(p, 0, len(buf))] = u8(next_u64(p) & 0xFF)
	}
	cut := int_range(p, 0, len(buf) + 1)
	return buf[:cut]
}

exercise_ws_parse :: proc(p: ^Prng) {
	data := random_bytes(p, MAXIMUM_WIRE_BYTES) if int_range(p, 0, 2) == 0 else mutated_ws_frame(p)
	frame, consumed, status := ingotnet.ws_parse_frame(data)
	ensure(consumed >= 0, "ws parser reported negative consumed")
	ensure(consumed <= len(data), "ws parser consumed past the buffer")
	switch status {
	case .Need_More, .Too_Big:
		ensure(consumed == 0, "ws parser consumed bytes without a complete frame")
	case .Ok:
		ensure(len(frame.payload) <= ingotnet.WS_MAX_PAYLOAD, "ws parser exceeded WS_MAX_PAYLOAD")
		if len(frame.payload) > 0 {
			start := uintptr(raw_data(data))
			payload_start := uintptr(raw_data(frame.payload))
			ensure(payload_start >= start, "ws payload starts before the buffer")
			ensure(payload_start + uintptr(len(frame.payload)) <= start + uintptr(consumed), "ws payload extends past the consumed frame")
		}
	}
}

main :: proc() {
	seed, iterations := parse_options()
	fmt.printfln("fuzz_net seed=%d iterations=%d", seed, iterations)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	p := prng_make(seed)
	for _ in 0 ..< iterations {
		exercise_parse(&p)
		exercise_ws_parse(&p)
		free_all(context.temp_allocator)
	}

	when ingotnet.INGOT_NET_SIM {
		exercise_sim_fetcher(&p, seed)
	}

	if len(track.allocation_map) > 0 {
		for _, entry in track.allocation_map {
			fmt.eprintfln("LEAK %v bytes @ %v", entry.size, entry.location)
		}
		fmt.eprintfln("fuzz_net FAILED: %d leaks — reproduce with -seed:%d", len(track.allocation_map), seed)
		os.exit(1)
	}
	if len(track.bad_free_array) > 0 {
		fmt.eprintfln("fuzz_net FAILED: %d bad frees — reproduce with -seed:%d", len(track.bad_free_array), seed)
		os.exit(1)
	}
	fmt.printfln("fuzz_net ok")
}

when ingotnet.INGOT_NET_SIM {
	// Drive the full simulated Fetcher at maximum fault rate: every request is
	// cloned, faulted, delivered, and freed. Leaks here are transport bugs.
	exercise_sim_fetcher :: proc(p: ^Prng, seed: u64) {
		f: ingotnet.Fetcher
		ingotnet.sim_fetcher_init(&f, seed, 1.0, proc(request: ingotnet.Http_Request, prng: ^ingotnet.Sim_Prng) -> ingotnet.Fetch_Result {
			body := make([]u8, ingotnet.sim_int_range(prng, 0, 256))
			for i in 0 ..< len(body) do body[i] = u8(ingotnet.sim_next_u64(prng) & 0xFF)
			return ingotnet.Fetch_Result{status = 200, body = body, ok = true}
		})
		ingotnet.fetcher_start(&f, "sim", 0)
		defer ingotnet.fetcher_stop(&f)

		tag: u64 = 1
		for _ in 0 ..< 50_000 {
			header_value := random_bytes(p, 64)
			request := ingotnet.Http_Request {
				method       = ingotnet.Http_Method(int_range(p, 0, 5)),
				path         = "/fuzz",
				headers      = []ingotnet.Http_Header{{name = "X-Fuzz", value = string(header_value)}},
				body         = random_bytes(p, 128),
				maximum_body = u64(int_range(p, 0, MAXIMUM_BODY_LIMIT)),
			}
			_ = ingotnet.fetcher_request_http(&f, tag, request)
			tag += 1
			ingotnet.sim_tick(&f)
			for result in ingotnet.fetcher_drain(&f) do delete(result.body)
			free_all(context.temp_allocator)
		}
	}
}
