#+build js
// Web HTTP backend — same public Fetcher API as net/http.odin, backed by the
// browser fetch() API instead of core:net + worker threads. Requests are issued
// to JS (which performs fetch asynchronously) and completed bodies are pulled in
// fetcher_drain. There is no on-disk cache in the browser, so the cached variant
// falls through to a normal request.
package ingotnet

import "base:runtime"
import "core:fmt"
import "core:strings"

// JS bridge (provided by the app web shell). Each request has an integer id.
foreign import httpjs "ingot_http"
@(default_calling_convention = "c")
foreign httpjs {
	ingot_http_get       :: proc(url: [^]byte, url_len: i32) -> i32 --- // -1 fail
	ingot_http_poll      :: proc(id: i32) -> i32 --- // 0 pending,1 ok,2 fail
	ingot_http_body_len  :: proc(id: i32) -> i32 ---
	ingot_http_body_copy :: proc(id: i32, dst: [^]byte, cap: i32) -> i32 --- // frees slot
}

Fetch_Result :: struct {
	tag:  u64,
	body: []u8, // heap-allocated; receiver owns
	ok:   bool,
}

@(private = "file")
In_Flight :: struct {
	id:  i32,
	tag: u64,
}

// MAX_INFLIGHT caps concurrent browser fetch() calls. Browsers serialise more
// than ~6 HTTP/1.1 requests per host; issuing every visible tile at once (base +
// SAR + feasibility can be dozens per frame) left most requests sitting in the
// browser's connection queue while the JS-side 30s timeout ticked, so many
// timed out and the overlays flickered as failed tiles retried. Mirrors the
// native fetcher's FETCH_WORKERS pool (net/http.odin) via a pending queue.
@(private = "file")
MAX_INFLIGHT :: 6

@(private = "file")
Pending :: struct {
	tag:  u64,
	path: string, // owned (cloned at enqueue)
}

Fetcher :: struct {
	host:      string,
	port:      int,
	// Present for API parity with the native Fetcher; unused on web (the
	// browser has no on-disk cache to validate).
	cache_validator: proc(body: []u8) -> bool,
	in_flight: [dynamic]In_Flight,
	pending:   [dynamic]Pending,
}

fetcher_start :: proc(f: ^Fetcher, host: string, port: int) {
	f.host = host
	f.port = port
	f.in_flight = make([dynamic]In_Flight)
	f.pending = make([dynamic]Pending)
}

fetcher_stop :: proc(f: ^Fetcher) {
	// Drain any completed bodies so JS frees its slots, then drop the list.
	for it in f.in_flight {
		if ingot_http_poll(it.id) != 0 {
			n := ingot_http_body_len(it.id)
			if n > 0 {
				buf := make([]byte, int(n))
				ingot_http_body_copy(it.id, raw_data(buf), i32(len(buf)))
				delete(buf)
			}
		}
	}
	delete(f.in_flight)
	f.in_flight = nil
	for p in f.pending do delete(p.path)
	delete(f.pending)
	f.pending = nil
}

// fetcher_request enqueues a GET for `path`. It dispatches immediately when a
// concurrency slot is free, otherwise it waits in the pending queue and is
// started by _pump as in-flight requests complete. Results arrive via
// fetcher_drain.
fetcher_request :: proc(f: ^Fetcher, tag: u64, path: string) {
	append(&f.pending, Pending{tag = tag, path = strings.clone(path)})
	_pump(f)
}

// fetcher_request_priority enqueues a GET at the FRONT of the pending queue so
// it dispatches before the existing backlog. Use for low-volume, user-driven
// API calls (runs list, replay, geocode) that must not wait behind a burst of
// slow tile fetches.
fetcher_request_priority :: proc(f: ^Fetcher, tag: u64, path: string) {
	inject_at(&f.pending, 0, Pending{tag = tag, path = strings.clone(path)})
	_pump(f)
}

// _pump starts queued requests (FIFO) until MAX_INFLIGHT are in flight.
@(private = "file")
_pump :: proc(f: ^Fetcher) {
	for len(f.in_flight) < MAX_INFLIGHT && len(f.pending) > 0 {
		p := f.pending[0]
		ordered_remove(&f.pending, 0)
		url := fmt.tprintf("http://%s:%d%s", f.host, f.port, p.path)
		delete(p.path)
		ub := transmute([]byte)url
		id := ingot_http_get(raw_data(ub), i32(len(ub)))
		if id >= 0 {
			append(&f.in_flight, In_Flight{id = id, tag = p.tag})
		}
		// id < 0: the JS bridge refused the request; drop it (the layer will
		// re-request the tile on a later frame), same as the old direct path.
	}
}

// The browser has no filesystem cache, so the cached variant is a plain request.
fetcher_request_cached :: proc(f: ^Fetcher, tag: u64, path: string, cache_path: string) {
	fetcher_request(f, tag, path)
}

// fetcher_drain returns completed results (temp-allocated slice; bodies are
// heap-allocated and owned by the caller).
fetcher_drain :: proc(f: ^Fetcher) -> []Fetch_Result {
	out: [dynamic]Fetch_Result
	out.allocator = context.temp_allocator

	i := 0
	for i < len(f.in_flight) {
		it := f.in_flight[i]
		st := ingot_http_poll(it.id)
		if st == 0 {
			i += 1 // still pending
			continue
		}
		ok := st == 1
		body: []u8
		if ok {
			n := ingot_http_body_len(it.id)
			if n > 0 {
				body = make([]byte, int(n))
				got := ingot_http_body_copy(it.id, raw_data(body), i32(len(body)))
				if got < 0 { delete(body); body = nil; ok = false }
			} else {
				// zero-length success still frees the JS slot
				ingot_http_body_copy(it.id, nil, 0)
			}
		} else {
			ingot_http_body_copy(it.id, nil, 0) // free the failed slot
		}
		append(&out, Fetch_Result{tag = it.tag, body = body, ok = ok})
		unordered_remove(&f.in_flight, i)
	}

	_pump(f) // fill slots freed by completed requests from the pending queue

	if len(out) == 0 do return nil
	return out[:]
}

// keep imports referenced
_ :: runtime
