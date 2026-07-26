#+build !js
package ingotnet

// Tests for the deterministic simulated transport. Only compiled when the sim
// is enabled: odin test net -collection:ingot=. -define:INGOT_NET_SIM=true

import "core:testing"

when INGOT_NET_SIM {

	@(private = "file")
	test_respond :: proc(request: Http_Request, prng: ^Sim_Prng) -> Fetch_Result {
		body := make([]u8, 8)
		for i in 0 ..< len(body) do body[i] = u8(sim_next_u64(prng) & 0xFF)
		return Fetch_Result{status = 200, body = body, ok = true}
	}

	@(private = "file")
	Run_Record :: struct {
		tags:     [dynamic]u64,
		statuses: [dynamic]u16,
		stats:    Sim_Stats,
	}

	// Drive a fixed workload through the sim and record every delivery in order.
	@(private = "file")
	run_workload :: proc(seed: u64, fault_rate: f32, record: ^Run_Record) {
		f: Fetcher
		sim_fetcher_init(&f, seed, fault_rate, test_respond)
		fetcher_start(&f, "sim", 0)
		defer fetcher_stop(&f)

		next_tag: u64 = 1
		for tick in 0 ..< 2_000 {
			if tick % 3 == 0 {
				if fetcher_request(&f, next_tag, "/projects") do next_tag += 1
			}
			sim_tick(&f)
			results := fetcher_drain(&f)
			for result in results {
				append(&record.tags, result.tag)
				append(&record.statuses, result.status)
				delete(result.body)
			}
			free_all(context.temp_allocator)
		}
		record.stats = f.stats
	}

	@(test)
	test_sim_same_seed_is_identical :: proc(t: ^testing.T) {
		first, second: Run_Record
		defer {delete(first.tags); delete(first.statuses); delete(second.tags)
			delete(second.statuses)}
		run_workload(0xDEAD_BEEF, 0.3, &first)
		run_workload(0xDEAD_BEEF, 0.3, &second)

		testing.expect_value(t, len(first.tags), len(second.tags))
		for tag, i in first.tags do testing.expect_value(t, second.tags[i], tag)
		for status, i in first.statuses do testing.expect_value(t, second.statuses[i], status)
		testing.expect_value(t, second.stats, first.stats)
	}

	@(test)
	test_sim_different_seeds_diverge :: proc(t: ^testing.T) {
		first, second: Run_Record
		defer {delete(first.tags); delete(first.statuses); delete(second.tags)
			delete(second.statuses)}
		run_workload(1, 0.5, &first)
		run_workload(2, 0.5, &second)
		testing.expect(
			t,
			first.stats != second.stats,
			"distinct seeds should produce distinct fault schedules",
		)
	}

	@(test)
	test_sim_in_flight_bound_respected :: proc(t: ^testing.T) {
		f: Fetcher
		sim_fetcher_init(&f, 7, 0, test_respond)
		fetcher_start(&f, "sim", 0)
		defer fetcher_stop(&f)

		accepted := 0
		for i in 0 ..< SIM_MAX_IN_FLIGHT * 2 {
			request := Http_Request {
				method       = .Get,
				path         = "/x",
				maximum_body = 1024,
			}
			if fetcher_request_http(&f, u64(i + 1), request) do accepted += 1
		}
		maximum_accepted := min(SIM_MAX_IN_FLIGHT, FETCH_MAXIMUM_RESULTS / SIM_RESULT_RESERVATION)
		testing.expect_value(t, accepted, maximum_accepted)
		testing.expect_value(t, len(f.in_flight), maximum_accepted)
		testing.expect_value(t, f.result_slots, FETCH_MAXIMUM_RESULTS)
		testing.expect_value(t, f.stats.rejected, u64(SIM_MAX_IN_FLIGHT * 2 - maximum_accepted))
	}

	@(test)
	test_sim_zero_fault_rate_delivers_everything :: proc(t: ^testing.T) {
		record: Run_Record
		defer {delete(record.tags); delete(record.statuses)}
		run_workload(42, 0, &record)
		testing.expect_value(t, record.stats.dropped, u64(0))
		testing.expect_value(t, record.stats.corrupted, u64(0))
		testing.expect_value(t, record.stats.errored, u64(0))
		testing.expect(t, record.stats.sent > 0)
		// Everything sent early enough to clear SIM_MAX_LATENCY_TICKS is delivered.
		testing.expect(t, record.stats.delivered > 0)
		for status in record.statuses do testing.expect_value(t, status, u16(200))
	}

	@(test)
	test_sim_faults_occur_at_high_rate :: proc(t: ^testing.T) {
		record: Run_Record
		defer {delete(record.tags); delete(record.statuses)}
		run_workload(1337, 1.0, &record)
		faulted :=
			record.stats.dropped +
			record.stats.corrupted +
			record.stats.errored +
			record.stats.truncated +
			record.stats.duplicated
		testing.expect(t, faulted > 0, "fault_rate=1 must inject faults")
	}

	@(test)
	test_sim_rejects_invalid_path :: proc(t: ^testing.T) {
		f: Fetcher
		sim_fetcher_init(&f, 9, 0, test_respond)
		fetcher_start(&f, "sim", 0)
		defer fetcher_stop(&f)
		testing.expect(
			t,
			!fetcher_request_http(&f, 1, Http_Request{method = .Get, path = "no-slash"}),
		)
		testing.expect(t, !fetcher_request_http(&f, 2, Http_Request{method = .Get, path = ""}))
		testing.expect_value(t, len(f.in_flight), 0)
	}

	@(test)
	test_sim_convenience_requests_report_backpressure :: proc(t: ^testing.T) {
		f: Fetcher
		sim_fetcher_init(&f, 10, 0, test_respond)
		fetcher_start(&f, "sim", 0)
		maximum_accepted := FETCH_MAXIMUM_RESULTS / SIM_RESULT_RESERVATION
		for tag in 1 ..= maximum_accepted {
			testing.expect(t, fetcher_request(&f, u64(tag), "/x"))
		}
		testing.expect(t, !fetcher_request_priority(&f, 65, "/priority"))
		testing.expect(t, !fetcher_request_cached(&f, 66, "/cached", "ignored"))
		fetcher_stop(&f)
		testing.expect(t, !fetcher_request(&f, 67, "/after-stop"))
		fetcher_stop(&f)
	}

	@(test)
	test_sim_request_options_are_independent :: proc(t: ^testing.T) {
		f: Fetcher
		sim_fetcher_init(&f, 12, 0, test_respond)
		fetcher_start(&f, "sim", 0)
		defer fetcher_stop(&f)
		request := Http_Request {
			method       = .Get,
			path         = "/options",
			maximum_body = DEFAULT_MAXIMUM_BODY,
		}
		testing.expect(
			t,
			fetcher_request_with_options(
				&f,
				1,
				request,
				Fetch_Options{priority = .Priority, cache_path = "ignored"},
			),
		)
		testing.expect_value(t, len(f.in_flight), 1)
		testing.expect_value(t, f.in_flight[0].tag, 1)
		testing.expect_value(t, f.in_flight[0].request.path, "/options")
	}

	@(test)
	test_sim_priority_inserts_before_normal :: proc(t: ^testing.T) {
		f: Fetcher
		sim_fetcher_init(&f, 13, 0, test_respond)
		fetcher_start(&f, "sim", 0)
		defer fetcher_stop(&f)
		testing.expect(t, fetcher_request(&f, 1, "/normal"))
		testing.expect(t, fetcher_request_priority(&f, 2, "/priority"))
		testing.expect_value(t, len(f.in_flight), 2)
		testing.expect_value(t, f.in_flight[0].tag, 2)
		testing.expect_value(t, f.in_flight[1].tag, 1)
	}

	@(test)
	test_sim_result_bound_releases_after_drain :: proc(t: ^testing.T) {
		f: Fetcher
		sim_fetcher_init(&f, 11, 0, test_respond)
		fetcher_start(&f, "sim", 0)
		defer fetcher_stop(&f)
		accepted := FETCH_MAXIMUM_RESULTS / SIM_RESULT_RESERVATION
		for tag in 1 ..= accepted do testing.expect(t, fetcher_request(&f, u64(tag), "/x"))
		testing.expect(t, !fetcher_request(&f, 999, "/full"))
		for len(f.in_flight) > 0 do sim_tick(&f)
		testing.expect_value(t, len(f.results), accepted)
		testing.expect_value(t, f.result_slots, accepted)
		for result in fetcher_drain(&f) do delete(result.body)
		free_all(context.temp_allocator)
		testing.expect_value(t, f.result_slots, 0)
		testing.expect(t, fetcher_request(&f, 1000, "/after-drain"))
	}

} // when INGOT_NET_SIM

_ :: testing
