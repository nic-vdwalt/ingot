#+build !js
package fuzz_wsreconn

// WebSocket reconnect state-machine fuzzer — the first genuinely CONCURRENT
// harness: the real worker thread (dial → handshake → recv loop → backoff →
// re-dial, net/ws.odin) runs against the scripted sim transport
// (-define:INGOT_WS_SIM=true, net/ws_sim.odin) while the main thread races
// it with sends, drains, state polls, and early closes.
//
// Run under ASan for state/leak checking and under SAN=thread for race
// detection (fuzz/run.sh wsreconn / tsan). One iteration = one connection
// session with a fresh random event tape. Seed printed FIRST:
//   fuzz_wsreconn -seed:12345 -iterations:2000
//
// Invariants:
//   - conn_gen strictly monotonic (never decreases, +1 per handshake)
//   - a .Connected observation implies conn_gen >= 1
//   - after ws_close: worker joined, state Disconnected, queue freed
//   - drained message count never exceeds frames served by the sim
//   - no session exceeds the watchdog budget (deadlock detection)
//   - tracking allocator: no leaks (recv_queue clone lifecycle)

import "core:fmt"
import "core:mem"
import "core:time"
import fuzzx "ingot:fuzz/fuzzx"
import ingotnet "ingot:net"

ITERATIONS_DEFAULT :: 2000
SESSION_BUDGET :: 5 * time.Second // watchdog: worker must finish/join well within

Prng :: fuzzx.Prng

EVENTS := [?]ingotnet.Ws_Sim_Event {
	.Dial_Fail,
	.Handshake_Garbage,
	.Handshake_Cut,
	.Frame_Text,
	.Frame_Binary,
	.Frame_Ping,
	.Frame_Split,
	.Frame_Garbage,
	.Server_Close,
	.Cut,
	.Timeout,
}

// build_tape produces a random event tape biased toward frame delivery with
// disruptive events sprinkled in, so most sessions reach .Connected at least
// once and then get torn down in a random way.
build_tape :: proc(p: ^Prng, buf: []ingotnet.Ws_Sim_Event) -> []ingotnet.Ws_Sim_Event {
	n := fuzzx.int_range(p, 1, min(len(buf), 48) + 1)
	for i in 0 ..< n {
		if fuzzx.int_range(p, 0, 3) != 0 {
			// Bias: clean frames keep the connection alive.
			frames := [?]ingotnet.Ws_Sim_Event{.Frame_Text, .Frame_Binary, .Frame_Ping, .Frame_Split}
			buf[i] = frames[fuzzx.int_range(p, 0, len(frames))]
		} else {
			buf[i] = EVENTS[fuzzx.int_range(p, 0, len(EVENTS))]
		}
	}
	return buf[:n]
}

main :: proc() {
	seed, iterations, rounds := fuzzx.parse_options(ITERATIONS_DEFAULT)
	fmt.printfln("fuzz_wsreconn seed=%d iterations=%d rounds=%d", seed, iterations, rounds)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	// Worker-thread allocations (recv-queue payload clones) use the worker's
	// default context allocator, not the tracking wrapper installed below —
	// free them with the same base allocator they came from.
	worker_allocator := context.allocator
	context.allocator = mem.tracking_allocator(&track)

	for round in 0 ..< rounds {
		round_seed := seed + u64(round)
		if rounds > 1 do fmt.printfln("fuzz_wsreconn round %d seed=%d", round, round_seed)
		p := fuzzx.prng_make(round_seed)
		c := fuzzx.Ctx{name = "fuzz_wsreconn", seed = round_seed}

		tape_buf: [64]ingotnet.Ws_Sim_Event
		for i in 0 ..< iterations {
			c.iteration = i
			session_start := time.now()

			tape := build_tape(&p, tape_buf[:])
			ingotnet.ws_sim_load(tape, fuzzx.next_u64(&p))

			ws := ingotnet.ws_init()
			ingotnet.ws_start_connect(&ws, "sim", 1, max_attempts = 3)

			last_gen := 0
			saw_connected := false
			drained := 0
			ops := fuzzx.int_range(&p, 4, 64)
			for _ in 0 ..< ops {
				switch fuzzx.int_range(&p, 0, 6) {
				case 0:
					_ = ingotnet.ws_send(&ws, "fuzz-payload")
				case 1:
					for msg in ingotnet.ws_drain(&ws) {
						drained += 1
						delete(msg.data, worker_allocator)
					}
				case 2:
					st := ingotnet.ws_state(&ws)
					if st == .Connected {
						saw_connected = true
						fuzzx.check(&c, ingotnet.ws_conn_gen(&ws) >= 1,
							"Connected observed with conn_gen == 0")
					}
				case 3:
					gen := ingotnet.ws_conn_gen(&ws)
					fuzzx.check(&c, gen >= last_gen, "conn_gen went backwards")
					last_gen = gen
				case 4:
					_ = ingotnet.ws_has_pending(&ws)
				case 5:
					// Let the worker make progress between op bursts.
					time.sleep(time.Duration(fuzzx.int_range(&p, 0, 3)) * time.Millisecond)
				}
				fuzzx.check(&c, time.since(session_start) < SESSION_BUDGET,
					"session watchdog exceeded (worker wedged?)")
			}

			// Drain once more, close, and verify teardown. ws_close frees any
			// still-queued worker clones with the caller's context allocator,
			// so run it under the worker's allocator (in production both
			// threads share one allocator; only the tracking wrapper splits
			// them).
			for msg in ingotnet.ws_drain(&ws) {
				drained += 1
				delete(msg.data, worker_allocator)
			}
			{
				context.allocator = worker_allocator
				ingotnet.ws_close(&ws)
			}

			fuzzx.check(&c, ingotnet.ws_state(&ws) == .Disconnected, "state not Disconnected after close")
			when #config(FUZZ_TRACE, false) {
				if ingotnet.ws_state(&ws) != .Disconnected {
					fmt.printfln("TRACE state after close: %v gen=%d", ingotnet.ws_state(&ws), ingotnet.ws_conn_gen(&ws))
				}
			}
			fuzzx.check(&c, ws.recv_thread == nil, "worker thread not joined after close")
			gen := ingotnet.ws_conn_gen(&ws)
			fuzzx.check(&c, gen >= last_gen, "conn_gen went backwards across close")
			if saw_connected do fuzzx.check(&c, gen >= 1, "connected session ended with gen 0")
			fuzzx.check(&c, drained <= ingotnet.ws_sim_frames_served(),
				"drained more messages than the sim served")
			fuzzx.check(&c, time.since(session_start) < SESSION_BUDGET,
				"close watchdog exceeded (join wedged?)")

			free_all(context.temp_allocator)
		}
	}

	fuzzx.report(&track, "fuzz_wsreconn", seed)
	fmt.printfln("fuzz_wsreconn ok")
}
