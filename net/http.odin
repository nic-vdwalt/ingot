#+build !js
// Minimal HTTP/1.1 GET over core:net (plain HTTP to a local backend) plus a
// background fetch worker with a mutex-guarded job/result queue — same
// threading pattern as net/ws.odin. Part of ingot:net; imports only core:*.
package ingotnet

import cnet "core:net"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// http_get performs a blocking GET and returns the response body (allocated
// with the given allocator). Only 200 responses return ok.
http_get :: proc(host: string, port: int, path: string, allocator := context.allocator) -> (body: []u8, ok: bool) {
	return http_get_impl(nil, 0, host, port, path, allocator)
}

// http_get_interruptible is http_get with cancellation: the worker's live
// socket is published in f.active_socks[idx] under f.sock_mutex, so
// fetcher_stop can close it to unblock a parked dial/recv. The same mutex
// guards this worker's own close so the two never double-close the fd.
@(private = "file")
http_get_interruptible :: proc(f: ^Fetcher, idx: int, host: string, port: int, path: string, allocator := context.allocator) -> (body: []u8, ok: bool) {
	return http_get_impl(f, idx, host, port, path, allocator)
}

@(private = "file")
http_get_impl :: proc(f: ^Fetcher, idx: int, host: string, port: int, path: string, allocator := context.allocator) -> (body: []u8, ok: bool) {
	ep: cnet.Endpoint
	if addr, addr_ok := cnet.parse_ip4_address(host); addr_ok {
		ep = cnet.Endpoint{address = addr, port = port}
	} else {
		resolved, err := cnet.resolve_ip4(host)
		if err != nil do return nil, false
		ep = resolved
		ep.port = port
	}
	sock, dial_err := cnet.dial_tcp(ep)
	if dial_err != nil do return nil, false

	// Publish the socket so fetcher_stop can close it to unblock a parked
	// recv; clear + close it under the same mutex on the way out so a
	// concurrent fetcher_stop can never double-close this fd.
	if f != nil {
		sync.mutex_lock(&f.sock_mutex)
		// Stop already requested before we registered: close now and bail.
		if !f.running {
			sync.mutex_unlock(&f.sock_mutex)
			cnet.close(sock)
			return nil, false
		}
		f.active_socks[idx] = sock
		f.active_open[idx] = true
		sync.mutex_unlock(&f.sock_mutex)
	}
	defer if f != nil {
		sync.mutex_lock(&f.sock_mutex)
		if f.active_open[idx] {
			cnet.close(f.active_socks[idx])
			f.active_open[idx] = false
		}
		sync.mutex_unlock(&f.sock_mutex)
	} else {
		cnet.close(sock)
	}

	request := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\nUser-Agent: ingot-net/0.1\r\n\r\n",
		path, host, port,
	)
	if _, send_err := cnet.send(sock, transmute([]u8)request); send_err != nil {
		return nil, false
	}

	// Bound each recv so a wedged server can never park a worker indefinitely
	// (kept short so the whole body still arrives well within it for local
	// responses; a genuinely slow upstream fails fast rather than stalling).
	_ = cnet.set_option(sock, .Receive_Timeout, 5 * time.Second)
	buf: [dynamic]u8
	buf.allocator = context.temp_allocator
	chunk: [16384]u8
	for {
		n, recv_err := cnet.recv(sock, chunk[:])
		if n > 0 do append(&buf, ..chunk[:n])
		if recv_err != nil || n == 0 do break
	}
	if len(buf) == 0 do return nil, false

	response := string(buf[:])
	header_end := strings.index(response, "\r\n\r\n")
	if header_end < 0 do return nil, false
	// status line ends at the first CRLF
	first_crlf := strings.index(response, "\r\n")
	status_line := response[:first_crlf if first_crlf >= 0 else min(len(response), 32)]
	if !strings.contains(status_line, " 200") do return nil, false

	headers := response[:header_end]
	raw_body := buf[header_end + 4:]
	// Validate against Content-Length: a short read means the connection was
	// cut mid-body (common on Windows under load) — treat as failure so a
	// truncated body is never returned or cached.
	if clen, has := content_length(headers); has {
		if len(raw_body) < clen do return nil, false
		raw_body = raw_body[:clen]
	}
	out := make([]u8, len(raw_body), allocator)
	copy(out, raw_body)
	return out, true
}

// content_length parses the Content-Length header value (case-insensitive).
@(private = "file")
content_length :: proc(headers: string) -> (n: int, ok: bool) {
	lower := strings.to_lower(headers, context.temp_allocator)
	idx := strings.index(lower, "content-length:")
	if idx < 0 do return 0, false
	rest := headers[idx + len("content-length:"):]
	if eol := strings.index(rest, "\r\n"); eol >= 0 do rest = rest[:eol]
	rest = strings.trim_space(rest)
	v, parse_ok := strconv.parse_int(rest)
	if !parse_ok || v < 0 do return 0, false
	return v, true
}

// --- background fetcher ------------------------------------------------------

FETCH_WORKERS :: 8

Fetch_Result :: struct {
	tag:  u64,
	body: []u8, // heap-allocated; receiver owns
	ok:   bool,
}

Fetch_Job :: struct {
	tag:        u64,
	path:       string,
	cache_path: string, // owned; "" = no disk cache
}

// Per-worker thread payload: the fetcher plus this worker's index, so the
// worker can register its in-flight socket in the fetcher's per-worker slot.
Fetch_Worker_Ctx :: struct {
	f:   ^Fetcher,
	idx: int,
}

Fetcher :: struct {
	host:    string,
	port:    int,
	// Optional: validate a fetched body before it is written to / served from
	// the on-disk cache (e.g. reject truncated/HTML error bodies). nil = accept
	// any body. Keeps the lib content-type agnostic.
	cache_validator: proc(body: []u8) -> bool,
	jobs:    [dynamic]Fetch_Job,
	results: [dynamic]Fetch_Result,
	mutex:   sync.Mutex,
	workers: [FETCH_WORKERS]^thread.Thread,
	running: bool,

	// In-flight socket registry: each worker publishes its active socket here
	// (guarded by sock_mutex) so fetcher_stop can close it to unblock a parked
	// dial/recv — mirrors the WebSocket sock_mutex/socket_open pattern.
	sock_mutex:   sync.Mutex,
	active_socks: [FETCH_WORKERS]cnet.TCP_Socket,
	active_open:  [FETCH_WORKERS]bool,
	worker_ctx:   [FETCH_WORKERS]Fetch_Worker_Ctx,
}

fetcher_start :: proc(f: ^Fetcher, host: string, port: int) {
	f.host = host
	f.port = port
	f.running = true
	for i in 0 ..< FETCH_WORKERS {
		f.worker_ctx[i] = Fetch_Worker_Ctx{f = f, idx = i}
		f.workers[i] = thread.create(proc(t: ^thread.Thread) {
			ctx := cast(^Fetch_Worker_Ctx)t.data
			fetch_worker(ctx.f, ctx.idx)
		})
		f.workers[i].data = &f.worker_ctx[i]
		thread.start(f.workers[i])
	}
}

fetcher_stop :: proc(f: ^Fetcher) {
	f.running = false

	// Unblock any worker parked in a dial/recv by closing its live socket.
	// The worker guards its own close under the same mutex, so it can never
	// double-close a slot we clear here. This is what removes the shutdown
	// freeze — otherwise the join below waits for the slowest in-flight fetch.
	sync.mutex_lock(&f.sock_mutex)
	for i in 0 ..< FETCH_WORKERS {
		if f.active_open[i] {
			cnet.close(f.active_socks[i])
			f.active_open[i] = false
		}
	}
	sync.mutex_unlock(&f.sock_mutex)

	for i in 0 ..< FETCH_WORKERS {
		if f.workers[i] == nil do continue
		thread.join(f.workers[i])
		thread.destroy(f.workers[i])
		f.workers[i] = nil
	}
	sync.mutex_lock(&f.mutex)
	for job in f.jobs {
		delete(job.path)
		delete(job.cache_path)
	}
	delete(f.jobs)
	for r in f.results do delete(r.body)
	delete(f.results)
	sync.mutex_unlock(&f.mutex)
}

// fetcher_request queues a GET for `path` (cloned). Results arrive via
// fetcher_drain with the same tag.
fetcher_request :: proc(f: ^Fetcher, tag: u64, path: string) {
	fetcher_request_cached(f, tag, path, "")
}

// fetcher_request_priority queues a GET at the FRONT of the job queue so a
// free worker picks it before the existing backlog. Use for low-volume,
// user-driven API calls (runs list, replay, geocode) that must not wait behind
// a burst of slow tile fetches. No on-disk cache.
fetcher_request_priority :: proc(f: ^Fetcher, tag: u64, path: string) {
	sync.mutex_lock(&f.mutex)
	inject_at(&f.jobs, 0, Fetch_Job{
		tag = tag,
		path = strings.clone(path),
		cache_path = strings.clone(""),
	})
	sync.mutex_unlock(&f.mutex)
}

// fetcher_request_cached is fetcher_request with an on-disk cache: if
// `cache_path` exists the file is returned without touching the network;
// otherwise a successful fetch is written there for next time.
fetcher_request_cached :: proc(f: ^Fetcher, tag: u64, path: string, cache_path: string) {
	sync.mutex_lock(&f.mutex)
	append(&f.jobs, Fetch_Job{
		tag = tag,
		path = strings.clone(path),
		cache_path = strings.clone(cache_path),
	})
	sync.mutex_unlock(&f.mutex)
}

// fetcher_drain returns completed results (temp-allocated slice; bodies are
// heap-allocated and owned by the caller).
fetcher_drain :: proc(f: ^Fetcher) -> []Fetch_Result {
	sync.mutex_lock(&f.mutex)
	defer sync.mutex_unlock(&f.mutex)
	if len(f.results) == 0 do return nil
	out := make([]Fetch_Result, len(f.results), context.temp_allocator)
	copy(out, f.results[:])
	clear(&f.results)
	return out
}

@(private = "file")
fetch_worker :: proc(f: ^Fetcher, idx: int) {
	for f.running {
		sync.mutex_lock(&f.mutex)
		if len(f.jobs) == 0 {
			sync.mutex_unlock(&f.mutex)
			time.sleep(10 * time.Millisecond)
			continue
		}
		job := f.jobs[0]
		ordered_remove(&f.jobs, 0)
		sync.mutex_unlock(&f.mutex)

		free_all(context.temp_allocator)

		body: []u8
		ok: bool
		validate := f.cache_validator
		if job.cache_path != "" {
			if cached, read_err := os.read_entire_file_from_path(job.cache_path, context.allocator);
			   read_err == nil && len(cached) > 0 {
				if validate == nil || validate(cached) {
					body = cached
					ok = true
				} else {
					// poisoned cache entry (e.g. a truncated write from an
					// earlier session): drop it and re-fetch from network.
					delete(cached)
					os.remove(job.cache_path)
				}
			}
		}
		if !ok {
			body, ok = http_get_interruptible(f, idx, f.host, f.port, job.path)
			// only cache bodies the app accepts so a transient upstream error
			// page can't poison the on-disk cache
			if ok && (validate == nil || validate(body)) && job.cache_path != "" {
				dir, _ := os.split_path(job.cache_path)
				os.make_directory_all(dir)
				_ = os.write_entire_file(job.cache_path, body)
			}
		}
		delete(job.path)
		delete(job.cache_path)

		sync.mutex_lock(&f.mutex)
		append(&f.results, Fetch_Result{tag = job.tag, body = body, ok = ok})
		sync.mutex_unlock(&f.mutex)
	}
}
