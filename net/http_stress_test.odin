#+build !js
package ingotnet

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

_ :: sync
_ :: testing
_ :: thread
_ :: time

when HTTP_STRESS {
	stress_wakes: int

	stress_wake :: proc "contextless" () {
		sync.atomic_add(&stress_wakes, 1)
	}

	@(test)
	http_fetch_pool_condvar_stress :: proc(t: ^testing.T) {
		for round in 0 ..< 100 {
			http_stress_reset()
			sync.atomic_store(&stress_wakes, 0)
			f: Fetcher
			f.wake = stress_wake
			fetcher_start(&f, "stress", 1)

			// Workers start with an empty queue and park on jobs_cond. The pause
			// makes the request signal exercise the parked-worker path instead of
			// merely racing startup.
			time.sleep(100 * time.Microsecond)
			accepted := 0
			for i in 0 ..< FETCH_MAXIMUM_PENDING * 2 {
				was_accepted := fetcher_request_http(&f, u64(i), Http_Request{
					method = .Get,
					path = "/stress",
					maximum_body = 64,
				})
				if was_accepted do accepted += 1
			}
			testing.expect(t, accepted > 0)

			completion_start := time.now()
			completed := 0
			for completed < accepted && time.since(completion_start) < 2 * time.Second {
				for result in fetcher_drain(&f) {
					completed += 1
					testing.expect_value(t, result.status, u16(200))
					testing.expect_value(t, string(result.body), "ok")
					delete(result.body)
				}
				thread.yield()
			}
			testing.expect_value(t, completed, accepted)
			testing.expect(t, sync.atomic_load(&stress_wakes) >= completed)

			fetcher_stop(&f)
			for worker in f.workers do testing.expect(t, worker == nil)
			testing.expect(t, !fetcher_request_http(&f, 999, Http_Request{
				method = .Get,
				path = "/after-stop",
				maximum_body = 64,
			}))
			requests, completions, closes := http_stress_counts()
			testing.expect(t, requests >= completed)
			testing.expect_value(t, completions, completed)
			testing.expect(t, closes >= completed)
		}
	}

	http_fetch_pool_result_backpressure_stress :: proc(t: ^testing.T) {
		http_stress_reset()
		f: Fetcher
		fetcher_start(&f, "stress", 1)
		for tag in 0 ..< FETCH_MAXIMUM_RESULTS {
			testing.expect(t, fetcher_request(&f, u64(tag), "/stress"))
		}
		testing.expect(t, !fetcher_request(&f, 999, "/full"))
		started := time.now()
		for {
			sync.mutex_lock(&f.mutex)
			completed := len(f.results)
			sync.mutex_unlock(&f.mutex)
			if completed == FETCH_MAXIMUM_RESULTS || time.since(started) >= 2 * time.Second do break
			thread.yield()
		}
		sync.mutex_lock(&f.mutex)
		testing.expect_value(t, len(f.results), FETCH_MAXIMUM_RESULTS)
		testing.expect_value(t, f.result_slots, FETCH_MAXIMUM_RESULTS)
		sync.mutex_unlock(&f.mutex)
		for result in fetcher_drain(&f) do delete(result.body)
		free_all(context.temp_allocator)
		testing.expect(t, fetcher_request(&f, 1000, "/after-drain"))
		fetcher_stop(&f)
	}

	@(test)
	http_fetch_pool_idle_stop_stress :: proc(t: ^testing.T) {
		for round in 0 ..< 500 {
			f: Fetcher
			fetcher_start(&f, "stress", 1)
			// Alternate immediate stop with a pause that lets every worker park;
			// both broadcast-before-wait and broadcast-to-waiters must terminate.
			if round % 2 == 0 do time.sleep(50 * time.Microsecond)
			started := time.now()
			fetcher_stop(&f)
			testing.expect(t, time.since(started) < time.Second)
			for worker in f.workers do testing.expect(t, worker == nil)
		}
		http_fetch_pool_result_backpressure_stress(t)
	}
}
