package ingotnet

// Deterministic simulated transport (TigerBeetle VOPR style).
//
// Same public surface as the real Fetcher, but requests are queued into an
// in-memory network advanced one step at a time by sim_tick. A seeded
// xorshift64* PRNG is the sole source of entropy, so one seed reproduces one
// exact run — identical native and on js_wasm32 (no sockets, no JS, no
// threads, no clock).
//
// Enable with: -define:INGOT_NET_SIM=true
// The real transports (http.odin native, http_web.odin js) compile out
// entirely when the sim is enabled; application code using fetcher_request /
// fetcher_drain is untouched.

import "core:strings"

// When true, this file provides the Fetcher API for every target.
INGOT_NET_SIM :: #config(INGOT_NET_SIM, false)

when INGOT_NET_SIM {

	SIM_MAX_IN_FLIGHT :: 64 // Tiger Style: every queue has a fixed upper bound.
	SIM_RESULT_RESERVATION :: 2
	SIM_MAX_LATENCY_TICKS :: 120 // worst-case base delivery delay (~2 s at 60 ticks/s)
	SIM_EXTRA_DELAY_TICKS :: 240 // additional delay applied by .Delay / .Slow_Trickle
	SIM_MAX_CORRUPT_FLIPS :: 8 // maximum byte flips applied by .Corrupt_Body

	Sim_Fault :: enum u8 {
		None,
		Drop, // message vanishes; the app must tolerate a request never answered
		Delay, // extra latency on top of the base random latency
		Duplicate, // response delivered twice with independently generated bodies
		Corrupt_Body, // random byte flips in an otherwise valid response
		Error_500, // synthetic server failure
		Error_401, // synthetic auth failure (session-expiry paths)
		Truncate, // response body cut at a random point
		Slow_Trickle, // very large extra latency (still delivered eventually)
	}

	Sim_Stats :: struct {
		sent, delivered, dropped, corrupted, duplicated, errored, truncated, rejected: u64,
	}

	Sim_Message :: struct {
		tag:          u64,
		request:      Http_Request, // cloned; the sim owns and frees it
		sent_tick:    u64, // for visualizers: animation progress along the channel
		deliver_tick: u64,
		fault:        Sim_Fault,
		result_slots: int,
	}

	Fetch_Result :: struct {
		tag:    u64,
		status: u16,
		body:   []u8,
		ok:     bool,
	}

	// The server model: given a request, produce a response. The body must be
	// allocated with context.allocator — the app deletes it after handling, the
	// same contract as the real transports. The model may draw randomness only
	// from the provided PRNG so runs stay seed-reproducible.
	Sim_Respond :: #type proc(request: Http_Request, prng: ^Sim_Prng) -> Fetch_Result

	Fetcher :: struct {
		host:            string,
		port:            int,
		cache_validator: proc(body: []u8) -> bool,
		prng:            Sim_Prng, // sole entropy source — seed via sim_fetcher_init
		tick:            u64,
		fault_rate:      f32, // 0..1 probability that a message gets a fault
		respond:         Sim_Respond,
		in_flight:       [dynamic]Sim_Message,
		results:         [dynamic]Fetch_Result,
		result_slots:    int,
		stats:           Sim_Stats,
		running:         bool,
		// API parity with the native Fetcher so app code can set a wake hook on
		// every target; the sim is single-threaded and never calls it.
		wake:            proc "contextless" (),
	}

	// xorshift64* — deterministic, identical on every target (mirrors testx.Prng,
	// duplicated here so ingot:net stays dependency-free).
	Sim_Prng :: struct {
		state: u64,
	}

	sim_prng_make :: proc(seed: u64) -> Sim_Prng {
		return Sim_Prng{state = seed == 0 ? 0x9E3779B97F4A7C15 : seed}
	}

	sim_next_u64 :: proc(p: ^Sim_Prng) -> u64 {
		x := p.state
		x ~= x >> 12
		x ~= x << 25
		x ~= x >> 27
		p.state = x
		return x * 0x2545F4914F6CDD1D
	}

	// sim_int_range returns a value in [lo, hi).
	sim_int_range :: proc(p: ^Sim_Prng, lo, hi: int) -> int {
	assert(p != nil, "sim_int_range: nil p")
		if hi <= lo do return lo
		return lo + int(sim_next_u64(p) % u64(hi - lo))
	}

	sim_fetcher_init :: proc(f: ^Fetcher, seed: u64, fault_rate: f32, respond: Sim_Respond) {
		assert(respond != nil, "sim fetcher requires a respond server model")
		assert(fault_rate >= 0)
		assert(fault_rate <= 1)
		f.prng = sim_prng_make(seed)
		f.fault_rate = fault_rate
		f.respond = respond
	}

	fetcher_start :: proc(f: ^Fetcher, host: string, port: int) {
		assert(f != nil)
		assert(!f.running, "fetcher_start: already running")
		f.host = host
		f.port = port
		f.running = true
		if f.prng.state == 0 do f.prng = sim_prng_make(1)
		assert(f.prng.state != 0)
	}

	fetcher_stop :: proc(f: ^Fetcher) {
		assert(f != nil)
		f.running = false
		reserved := 0
		for &message in f.in_flight {
			reserved += message.result_slots
			sim_message_destroy(&message)
		}
		assert(f.result_slots == reserved + len(f.results))
		assert(f.result_slots <= FETCH_MAXIMUM_RESULTS)
		delete(f.in_flight)
		f.in_flight = nil
		for result in f.results do delete(result.body)
		delete(f.results)
		f.results = nil
		f.result_slots = 0
		assert(len(f.in_flight) == 0)
		assert(len(f.results) == 0)
	}

	fetcher_request_with_options :: proc(
		f: ^Fetcher,
		tag: u64,
		request: Http_Request,
		options: Fetch_Options = {},
	) -> bool {
		assert(f != nil)
		if request.path == "" || request.path[0] != '/' do return false
		assert(options.priority == .Normal || options.priority == .Priority)
		if !f.running ||
		   len(f.in_flight) >= SIM_MAX_IN_FLIGHT ||
		   f.result_slots + SIM_RESULT_RESERVATION > FETCH_MAXIMUM_RESULTS {
			f.stats.rejected += 1
			return false
		}
		fault := sim_pick_fault(&f.prng, f.fault_rate)
		latency := u64(sim_int_range(&f.prng, 1, SIM_MAX_LATENCY_TICKS + 1))
		#partial switch fault {
		case .Delay, .Slow_Trickle:
			latency += u64(sim_int_range(&f.prng, 1, SIM_EXTRA_DELAY_TICKS + 1))
		}
		message := Sim_Message {
			tag          = tag,
			request      = sim_request_clone(request),
			sent_tick    = f.tick,
			deliver_tick = f.tick + latency,
			fault        = fault,
			result_slots = SIM_RESULT_RESERVATION,
		}
		if options.priority == .Priority {
			inject_at(&f.in_flight, 0, message)
		} else {
			append(&f.in_flight, message)
		}
		f.result_slots += SIM_RESULT_RESERVATION
		f.stats.sent += 1
		assert(len(f.in_flight) <= SIM_MAX_IN_FLIGHT)
		assert(f.result_slots <= FETCH_MAXIMUM_RESULTS)
		return true
	}

	fetcher_request_http :: proc(f: ^Fetcher, tag: u64, request: Http_Request) -> bool {
		return fetcher_request_with_options(f, tag, request)
	}

	fetcher_request :: proc(f: ^Fetcher, tag: u64, path: string) -> bool {
		return fetcher_request_with_options(
			f,
			tag,
			Http_Request{method = .Get, path = path, maximum_body = DEFAULT_MAXIMUM_BODY},
		)
	}

	fetcher_request_priority :: proc(f: ^Fetcher, tag: u64, path: string) -> bool {
		return fetcher_request_with_options(
			f,
			tag,
			Http_Request{method = .Get, path = path, maximum_body = DEFAULT_MAXIMUM_BODY},
			Fetch_Options{priority = .Priority},
		)
	}

	fetcher_request_cached :: proc(
		f: ^Fetcher,
		tag: u64,
		path: string,
		cache_path: string,
	) -> bool {
		return fetcher_request_with_options(
			f,
			tag,
			Http_Request{method = .Get, path = path, maximum_body = DEFAULT_MAXIMUM_BODY},
			Fetch_Options{cache_path = cache_path},
		)
	}

	// Advance simulated time one tick: deliver every due message through the
	// server model, applying its chosen fault.
	sim_tick :: proc(f: ^Fetcher) {
	assert(f != nil, "sim_tick: nil f")
		f.tick += 1
		scanned := 0
		for index := 0; index < len(f.in_flight); {
			scanned += 1
			assert(scanned <= 2 * SIM_MAX_IN_FLIGHT, "sim_tick scan must terminate")
			if f.in_flight[index].deliver_tick > f.tick {
				index += 1
				continue
			}
			message := f.in_flight[index]
			ordered_remove(&f.in_flight, index)
			produced := 0
			switch message.fault {
			case .Drop:
				f.stats.dropped += 1
			case .Error_500:
				sim_result_append(f, Fetch_Result{tag = message.tag, status = 500, ok = true})
				f.stats.errored += 1
				f.stats.delivered += 1
				produced = 1
			case .Error_401:
				sim_result_append(f, Fetch_Result{tag = message.tag, status = 401, ok = true})
				f.stats.errored += 1
				f.stats.delivered += 1
				produced = 1
			case .Duplicate:
				sim_deliver(f, &message)
				sim_deliver(f, &message)
				f.stats.duplicated += 1
				produced = 2
			case .None, .Delay, .Slow_Trickle, .Corrupt_Body, .Truncate:
				sim_deliver(f, &message)
				produced = 1
			}
			assert(produced <= message.result_slots)
			f.result_slots -= message.result_slots - produced
			assert(len(f.results) <= f.result_slots)
			sim_message_destroy(&message)
		}
	}

	// The returned slice uses context.temp_allocator and must not be retained.
	// Every result body transfers to the caller and must be deleted exactly once.
	// fetcher_stop frees only messages and results still owned by this Fetcher.
	fetcher_drain :: proc(f: ^Fetcher) -> []Fetch_Result {
		assert(f != nil)
		assert(len(f.results) <= f.result_slots)
		assert(f.result_slots <= FETCH_MAXIMUM_RESULTS)
		if len(f.results) == 0 do return nil
		count := min(len(f.results), FETCH_MAXIMUM_DRAIN)
		assert(count > 0)
		assert(count <= FETCH_MAXIMUM_DRAIN)
		out := make([]Fetch_Result, count, context.temp_allocator)
		copy(out, f.results[:count])
		copy(f.results[:], f.results[count:])
		resize(&f.results, len(f.results) - count)
		f.result_slots -= count
		assert(f.result_slots >= 0)
		assert(len(f.results) <= f.result_slots)
		assert(len(out) == count)
		return out
	}

	@(private = "file")
	sim_pick_fault :: proc(p: ^Sim_Prng, fault_rate: f32) -> Sim_Fault {
	assert(p != nil, "sim_pick_fault: nil p")
		assert(fault_rate >= 0)
		assert(fault_rate <= 1)
		roll := f32(sim_next_u64(p) % 10_000) / 10_000
		if roll >= fault_rate do return .None
		faults := [?]Sim_Fault {
			.Drop,
			.Delay,
			.Duplicate,
			.Corrupt_Body,
			.Error_500,
			.Error_401,
			.Truncate,
			.Slow_Trickle,
		}
		return faults[sim_int_range(p, 0, len(faults))]
	}

	@(private = "file")
	sim_deliver :: proc(f: ^Fetcher, message: ^Sim_Message) {
		assert(f.respond != nil, "sim fetcher requires a respond server model")
		result := f.respond(message.request, &f.prng)
		result.tag = message.tag
		#partial switch message.fault {
		case .Corrupt_Body:
			if len(result.body) > 0 {
				flips := sim_int_range(&f.prng, 1, SIM_MAX_CORRUPT_FLIPS + 1)
				for _ in 0 ..< flips {
					position := sim_int_range(&f.prng, 0, len(result.body))
					result.body[position] = u8(sim_next_u64(&f.prng) & 0xFF)
				}
			}
			f.stats.corrupted += 1
		case .Truncate:
			if len(result.body) > 0 {
				keep := sim_int_range(&f.prng, 0, len(result.body))

				truncated := make([]u8, keep)
				copy(truncated, result.body[:keep])
				delete(result.body)
				result.body = truncated
			}
			f.stats.truncated += 1
		}
		sim_result_append(f, result)
		f.stats.delivered += 1
	}

	@(private = "file")
	sim_result_append :: proc(f: ^Fetcher, result: Fetch_Result) {
	assert(f != nil, "sim_result_append: nil f")
		assert(len(f.results) < f.result_slots)
		assert(f.result_slots <= FETCH_MAXIMUM_RESULTS)
		append(&f.results, result)
		assert(len(f.results) <= FETCH_MAXIMUM_RESULTS)
	}

	@(private = "file")
	sim_request_clone :: proc(request: Http_Request) -> Http_Request {
		headers := make([]Http_Header, len(request.headers))
		for header, i in request.headers do headers[i] = Http_Header {
			name  = strings.clone(header.name),
			value = strings.clone(header.value),
		}
		body := make([]u8, len(request.body))
		copy(body, request.body)
		return Http_Request {
			method = request.method,
			path = strings.clone(request.path),
			headers = headers,
			body = body,
			maximum_body = request.maximum_body,
		}
	}

	@(private = "file")
	sim_message_destroy :: proc(message: ^Sim_Message) {
	assert(message != nil, "sim_message_destroy: nil message")
		delete(message.request.path)
		for header in message.request.headers {
			delete(header.name)
			delete(header.value)
		}
		delete(message.request.headers)
		delete(message.request.body)
		message^ = {}
	}

} // when INGOT_NET_SIM

_ :: strings
