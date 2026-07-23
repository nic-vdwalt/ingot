#+build !js
package ingotnet

import "core:fmt"
import "core:math/rand"
import "core:mem"
import cnet "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

DEFAULT_MAXIMUM_BODY :: 64 * 1024 * 1024
MAXIMUM_HEADER_BYTES :: 64 * 1024

Http_Method :: enum u8 {
	Get,
	Post,
	Put,
	Patch,
	Delete,
}

Http_Header :: struct {
	name:  string,
	value: string,
}

Http_Request :: struct {
	method:       Http_Method,
	path:         string,
	headers:      []Http_Header,
	body:         []u8,
	maximum_body: u64,
}

Http_Response :: struct {
	status:  u16,
	headers: []Http_Header,
	body:    []u8,
}

http_response_destroy :: proc(response: ^Http_Response, allocator := context.allocator) {
	for header in response.headers {
		delete(header.name, allocator)
		delete(header.value, allocator)
	}
	delete(response.headers, allocator)
	delete(response.body, allocator)
	response^ = {}
}

// The real native transport below is compiled out when the deterministic
// simulated transport (http_sim.odin) is enabled via -define:INGOT_NET_SIM=true.
when !INGOT_NET_SIM {

	http_get :: proc(
		host: string,
		port: int,
		path: string,
		allocator := context.allocator,
	) -> (
		body: []u8,
		ok: bool,
	) {
		response, request_ok := http_request(
			host,
			port,
			Http_Request{method = .Get, path = path, maximum_body = DEFAULT_MAXIMUM_BODY},
			allocator,
		)
		if !request_ok || response.status != 200 {
			http_response_destroy(&response)
			return nil, false
		}
		body = response.body
		response.body = nil
		for header in response.headers {
			delete(header.name)
			delete(header.value)
		}
		delete(response.headers)
		return body, true
	}

	http_request :: proc(
		host: string,
		port: int,
		request: Http_Request,
		allocator := context.allocator,
	) -> (
		Http_Response,
		bool,
	) {
		return http_request_impl(nil, 0, host, port, request, allocator)
	}

	@(private = "file")
	http_get_interruptible :: proc(
		f: ^Fetcher,
		idx: int,
		host: string,
		port: int,
		path: string,
		allocator := context.allocator,
	) -> (
		body: []u8,
		ok: bool,
	) {
		response, request_ok := http_request_impl(
			f,
			idx,
			host,
			port,
			Http_Request{method = .Get, path = path, maximum_body = DEFAULT_MAXIMUM_BODY},
			allocator,
		)
		if !request_ok || response.status != 200 {
			http_response_destroy(&response)
			return nil, false
		}
		body = response.body
		response.body = nil
		for header in response.headers {
			delete(header.name)
			delete(header.value)
		}
		delete(response.headers)
		return body, true
	}

	@(private = "file")
	http_request_impl :: proc(
		f: ^Fetcher,
		idx: int,
		host: string,
		port: int,
		request: Http_Request,
		allocator := context.allocator,
	) -> (
		response: Http_Response,
		ok: bool,
	) {
		if !valid_request(request) do return {}, false
		ep: cnet.Endpoint
		when HTTP_STRESS {
			ep = cnet.Endpoint {
				port = port,
			}
		} else {
			if addr, addr_ok := cnet.parse_ip4_address(host); addr_ok {
				ep = cnet.Endpoint {
					address = addr,
					port    = port,
				}
			} else {
				resolved, err := cnet.resolve_ip4(host)
				if err != nil do return {}, false
				ep = resolved
				ep.port = port
			}
		}
		sock, dial_ok := http_net_dial(ep)
		if !dial_ok do return {}, false
		if f != nil {
			sync.mutex_lock(&f.sock_mutex)
			if !sync.atomic_load(&f.running) {
				sync.mutex_unlock(&f.sock_mutex)
				http_net_close(sock)
				return {}, false
			}
			f.active_socks[idx] = sock
			f.active_open[idx] = true
			sync.mutex_unlock(&f.sock_mutex)
		}
		defer if f != nil {
			sync.mutex_lock(&f.sock_mutex)
			if f.active_open[idx] {
				http_net_close(f.active_socks[idx])
				f.active_open[idx] = false
			}
			sync.mutex_unlock(&f.sock_mutex)
		} else {
			http_net_close(sock)
		}

		wire := build_request(host, port, request)
		if len(wire) == 0 do return {}, false
		if !send_all(sock, wire) do return {}, false
		http_net_set_recv_timeout(sock, 5 * time.Second)
		maximum := int(request.maximum_body)
		if maximum <= 0 do maximum = DEFAULT_MAXIMUM_BODY
		buf: [dynamic]u8
		buf.allocator = context.temp_allocator
		chunk: [16384]u8
		for {
			n, recv_ok := http_net_recv(sock, chunk[:])
			if n > 0 {
				append(&buf, ..chunk[:n])
				if len(buf) > maximum + MAXIMUM_HEADER_BYTES do return {}, false
			}
			if !recv_ok || n == 0 do break
		}
		if len(buf) == 0 do return {}, false
		return parse_http_response(buf[:], maximum, allocator)
	}

	@(private = "file")
	valid_request :: proc(request: Http_Request) -> bool {
		if request.path == "" || request.path[0] != '/' do return false
		if strings.contains(request.path, "\r") || strings.contains(request.path, "\n") do return false
		for header in request.headers {
			if header.name == "" || strings.contains(header.name, ":") || strings.contains(header.name, "\r") || strings.contains(header.name, "\n") do return false
			if strings.contains(header.value, "\r") || strings.contains(header.value, "\n") do return false
		}
		return true
	}

	@(private = "file")
	method_name :: proc(method: Http_Method) -> string {
		switch method {
		case .Get:
			return "GET"
		case .Post:
			return "POST"
		case .Put:
			return "PUT"
		case .Patch:
			return "PATCH"
		case .Delete:
			return "DELETE"
		}
		return "GET"
	}

	@(private = "file")
	build_request :: proc(host: string, port: int, request: Http_Request) -> []u8 {
		buf: [dynamic]u8
		buf.allocator = context.temp_allocator
		append(
			&buf,
			..transmute([]u8)fmt.tprintf(
				"%s %s HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\nUser-Agent: ingot-net/0.2\r\n",
				method_name(request.method),
				request.path,
				host,
				port,
			),
		)
		for header in request.headers do append(&buf, ..transmute([]u8)fmt.tprintf("%s: %s\r\n", header.name, header.value))
		append(&buf, ..transmute([]u8)fmt.tprintf("Content-Length: %d\r\n\r\n", len(request.body)))
		append(&buf, ..request.body)
		return buf[:]
	}

	@(private = "file")
	send_all :: proc(sock: cnet.TCP_Socket, data: []u8) -> bool {
		total := 0
		for total < len(data) {
			n, ok := http_net_send(sock, data[total:])
			if !ok || n <= 0 do return false
			total += n
		}
		return true
	}

} // when !INGOT_NET_SIM

parse_http_response :: proc(
	data: []u8,
	maximum_body := DEFAULT_MAXIMUM_BODY,
	allocator := context.allocator,
) -> (
	response: Http_Response,
	ok: bool,
) {
	text := string(data)
	header_end := strings.index(text, "\r\n\r\n")
	if header_end < 0 || header_end > MAXIMUM_HEADER_BYTES do return {}, false
	lines := strings.split(text[:header_end], "\r\n", context.temp_allocator)
	if len(lines) == 0 do return {}, false
	parts := strings.split(lines[0], " ", context.temp_allocator)
	if len(parts) < 2 || !strings.has_prefix(parts[0], "HTTP/1.") do return {}, false
	status_value, status_ok := strconv.parse_int(parts[1])
	if !status_ok || status_value < 100 || status_value > 599 do return {}, false
	response.status = u16(status_value)
	header_array := make([dynamic]Http_Header, 0, len(lines) - 1, allocator)
	for line in lines[1:] {
		colon := strings.index(line, ":")
		if colon <= 0 {
			// Free with the SAME allocator we allocated with — the caller may
			// have passed a temp allocator (pair-asserted by the fuzz harness).
			http_response_destroy(&response, allocator)
			return {}, false
		}
		append(
			&header_array,
			Http_Header {
				name = strings.clone(strings.trim_space(line[:colon]), allocator),
				value = strings.clone(strings.trim_space(line[colon + 1:]), allocator),
			},
		)
	}
	response.headers = header_array[:]
	raw_body := data[header_end + 4:]
	if transfer_chunked(response.headers) {
		decoded, decoded_ok := decode_chunked(raw_body, maximum_body, allocator)
		if !decoded_ok {
			http_response_destroy(&response, allocator)
			return {}, false
		}
		response.body = decoded
		return response, true
	}
	if length, has_length := header_content_length(response.headers); has_length {
		if length > maximum_body || len(raw_body) < length {
			http_response_destroy(&response, allocator)
			return {}, false
		}
		raw_body = raw_body[:length]
	} else if len(raw_body) > maximum_body {
		http_response_destroy(&response, allocator)
		return {}, false
	}
	response.body = make([]u8, len(raw_body), allocator)
	copy(response.body, raw_body)
	return response, true
}

@(private = "file")
header_content_length :: proc(headers: []Http_Header) -> (int, bool) {
	for header in headers {
		if strings.to_lower(header.name, context.temp_allocator) != "content-length" do continue
		value, parsed := strconv.parse_int(header.value)
		if !parsed || value < 0 do return 0, false
		return value, true
	}
	return 0, false
}

@(private = "file")
transfer_chunked :: proc(headers: []Http_Header) -> bool {
	for header in headers {
		if strings.to_lower(header.name, context.temp_allocator) == "transfer-encoding" && strings.contains(strings.to_lower(header.value, context.temp_allocator), "chunked") do return true
	}
	return false
}

@(private = "file")
decode_chunked :: proc(data: []u8, maximum_body: int, allocator: mem.Allocator) -> ([]u8, bool) {
	out: [dynamic]u8
	out.allocator = allocator
	cursor := 0
	for {
		line_end := strings.index(string(data[cursor:]), "\r\n")
		if line_end < 0 {delete(out); return nil, false}
		size_text := string(data[cursor:cursor + line_end])
		if extension := strings.index(size_text, ";"); extension >= 0 do size_text = size_text[:extension]
		size, parsed := strconv.parse_u64(strings.trim_space(size_text), 16)
		if !parsed {delete(out); return nil, false}
		cursor += line_end + 2
		if size == 0 do return out[:], true
		if size > u64(maximum_body) ||
		   u64(len(out)) + size > u64(maximum_body) ||
		   cursor + int(size) + 2 > len(data) {
			delete(out)
			return nil, false
		}
		append(&out, ..data[cursor:cursor + int(size)])
		cursor += int(size)
		if data[cursor] != '\r' || data[cursor + 1] != '\n' {delete(out); return nil, false}
		cursor += 2
	}
}

FETCH_WORKERS :: 8
FETCH_MAXIMUM_PENDING :: 64
FETCH_MAXIMUM_RESULTS :: 64
FETCH_MAXIMUM_DRAIN :: 64

when !INGOT_NET_SIM {

	Fetch_Result :: struct {
		tag:    u64,
		status: u16,
		body:   []u8,
		ok:     bool,
	}
	Fetch_Job :: struct {
		tag:        u64,
		request:    Http_Request,
		cache_path: string,
	}
	Fetch_Worker_Ctx :: struct {
		f:   ^Fetcher,
		idx: int,
	}
	Fetcher :: struct {
		host:            string,
		port:            int,
		cache_validator: proc(body: []u8) -> bool,
		jobs:            [dynamic]Fetch_Job,
		results:         [dynamic]Fetch_Result,
		result_slots:    int,
		mutex:           sync.Mutex,
		workers:         [FETCH_WORKERS]^thread.Thread,
		// Cross-thread stop flag — access with sync.atomic_load / atomic_store.
		running:         bool,
		// Workers park on jobs_cond (under mutex) until a job arrives or
		// fetcher_stop broadcasts — no sleep-polling.
		jobs_cond:       sync.Cond,
		// Optional wake hook, called from a worker after a result is queued so an
		// event-driven-idle frame loop repaints promptly instead of waiting for
		// its idle-floor tick (gfx.RequestRedraw fits). Set before fetcher_start.
		wake:            proc "contextless" (),
		sock_mutex:      sync.Mutex,
		active_socks:    [FETCH_WORKERS]cnet.TCP_Socket,
		active_open:     [FETCH_WORKERS]bool,
		worker_ctx:      [FETCH_WORKERS]Fetch_Worker_Ctx,
		// Worker threads have their own context, so every cross-thread job/result
		// allocation explicitly uses the allocator captured by fetcher_start.
		allocator:       mem.Allocator,
	}

	fetcher_start :: proc(f: ^Fetcher, host: string, port: int) {
		f.host = host
		f.port = port
		f.allocator = context.allocator
		sync.atomic_store(&f.running, true)
		for i in 0 ..< FETCH_WORKERS {
			f.worker_ctx[i] = Fetch_Worker_Ctx {
				f   = f,
				idx = i,
			}
			f.workers[i] = thread.create(
				proc(t: ^thread.Thread) {ctx := cast(^Fetch_Worker_Ctx)t.data; fetch_worker(
						ctx.f,
						ctx.idx,
					)},
			)
			f.workers[i].data = &f.worker_ctx[i]
			thread.start(f.workers[i])
		}
	}

	fetcher_stop :: proc(f: ^Fetcher) {
		// Order matters: clear running and wake every parked worker under the job
		// mutex (broadcast under the mutex is never lost against a concurrent
		// cond_wait), then unblock in-flight recvs by closing their sockets, then
		// join.
		sync.mutex_lock(&f.mutex)
		sync.atomic_store(&f.running, false)
		sync.cond_broadcast(&f.jobs_cond)
		sync.mutex_unlock(&f.mutex)
		sync.mutex_lock(&f.sock_mutex)
		for i in 0 ..< FETCH_WORKERS {if f.active_open[i] {http_net_close(f.active_socks[i]); f.active_open[i] = false}}
		sync.mutex_unlock(&f.sock_mutex)
		for i in 0 ..< FETCH_WORKERS {if f.workers[i] != nil {thread.join(f.workers[i]); thread.destroy(f.workers[i]); f.workers[i] = nil}}
		sync.mutex_lock(&f.mutex)
		assert(f.result_slots == len(f.jobs) + len(f.results))
		assert(f.result_slots <= FETCH_MAXIMUM_RESULTS)
		for &job in f.jobs do fetch_job_destroy(&job, f.allocator)
		delete(f.jobs)
		for result in f.results do delete(result.body, f.allocator)
		delete(f.results)
		f.result_slots = 0
		sync.mutex_unlock(&f.mutex)
	}

	fetcher_request_http :: proc(f: ^Fetcher, tag: u64, request: Http_Request) -> bool {
		if !valid_request(request) do return false
		job := Fetch_Job {
			tag     = tag,
			request = http_request_clone(request, f.allocator),
		}
		sync.mutex_lock(&f.mutex)
		defer sync.mutex_unlock(&f.mutex)
		if !sync.atomic_load(&f.running) ||
		   len(f.jobs) >= FETCH_MAXIMUM_PENDING ||
		   f.result_slots >= FETCH_MAXIMUM_RESULTS {
			fetch_job_destroy(&job, f.allocator)
			return false
		}
		f.result_slots += 1
		assert(f.result_slots <= FETCH_MAXIMUM_RESULTS)
		if f.jobs == nil do f.jobs.allocator = f.allocator
		append(&f.jobs, job)
		sync.cond_signal(&f.jobs_cond)
		return true
	}
	fetcher_request :: proc(f: ^Fetcher, tag: u64, path: string) -> bool {
		return fetcher_request_http(
			f,
			tag,
			Http_Request{method = .Get, path = path, maximum_body = DEFAULT_MAXIMUM_BODY},
		)
	}
	fetcher_request_priority :: proc(f: ^Fetcher, tag: u64, path: string) -> bool {
		request := Http_Request {
			method       = .Get,
			path         = path,
			maximum_body = DEFAULT_MAXIMUM_BODY,
		}
		if !valid_request(request) do return false
		job := Fetch_Job {
			tag     = tag,
			request = http_request_clone(request, f.allocator),
		}
		sync.mutex_lock(&f.mutex)
		defer sync.mutex_unlock(&f.mutex)
		if !sync.atomic_load(&f.running) ||
		   len(f.jobs) >= FETCH_MAXIMUM_PENDING ||
		   f.result_slots >= FETCH_MAXIMUM_RESULTS {
			fetch_job_destroy(&job, f.allocator)
			return false
		}
		f.result_slots += 1
		assert(f.result_slots <= FETCH_MAXIMUM_RESULTS)
		if f.jobs == nil do f.jobs.allocator = f.allocator
		inject_at(&f.jobs, 0, job)
		sync.cond_signal(&f.jobs_cond)
		return true
	}
	fetcher_request_cached :: proc(
		f: ^Fetcher,
		tag: u64,
		path: string,
		cache_path: string,
	) -> bool {
		request := Http_Request {
			method       = .Get,
			path         = path,
			maximum_body = DEFAULT_MAXIMUM_BODY,
		}
		if !valid_request(request) do return false
		job := Fetch_Job {
			tag        = tag,
			request    = http_request_clone(request, f.allocator),
			cache_path = strings.clone(cache_path, f.allocator),
		}
		sync.mutex_lock(&f.mutex)
		defer sync.mutex_unlock(&f.mutex)
		if !sync.atomic_load(&f.running) ||
		   len(f.jobs) >= FETCH_MAXIMUM_PENDING ||
		   f.result_slots >= FETCH_MAXIMUM_RESULTS {
			fetch_job_destroy(&job, f.allocator)
			return false
		}
		f.result_slots += 1
		assert(f.result_slots <= FETCH_MAXIMUM_RESULTS)
		if f.jobs == nil do f.jobs.allocator = f.allocator
		append(&f.jobs, job)
		sync.cond_signal(&f.jobs_cond)
		return true
	}
	// The returned slice uses context.temp_allocator and must not be retained.
	// Every result body transfers to the caller and must be deleted exactly once.
	// fetcher_stop frees only jobs and results still owned by this Fetcher.
	fetcher_drain :: proc(f: ^Fetcher) -> []Fetch_Result {
		sync.mutex_lock(&f.mutex); defer sync.mutex_unlock(&f.mutex)
		assert(len(f.results) <= f.result_slots)
		assert(f.result_slots <= FETCH_MAXIMUM_RESULTS)
		if len(f.results) == 0 do return nil
		count := min(len(f.results), FETCH_MAXIMUM_DRAIN)
		out := make([]Fetch_Result, count, context.temp_allocator)
		copy(out, f.results[:count])
		copy(f.results[:], f.results[count:])
		resize(&f.results, len(f.results) - count)
		f.result_slots -= count
		assert(len(f.results) <= f.result_slots)
		return out
	}

	@(private = "file")
	http_request_clone :: proc(request: Http_Request, allocator: mem.Allocator) -> Http_Request {
		headers := make([]Http_Header, len(request.headers), allocator)
		for header, i in request.headers do headers[i] = Http_Header {
			name  = strings.clone(header.name, allocator),
			value = strings.clone(header.value, allocator),
		}
		body := make([]u8, len(request.body), allocator)
		copy(body, request.body)
		return Http_Request {
			method = request.method,
			path = strings.clone(request.path, allocator),
			headers = headers,
			body = body,
			maximum_body = request.maximum_body,
		}
	}

	@(private = "file")
	fetch_job_destroy :: proc(job: ^Fetch_Job, allocator: mem.Allocator) {
		delete(job.request.path, allocator)
		for header in job.request.headers {
			delete(header.name, allocator)
			delete(header.value, allocator)
		}
		delete(job.request.headers, allocator)
		delete(job.request.body, allocator)
		delete(job.cache_path, allocator)
		job^ = {}
	}

	@(private = "file")
	fetch_worker :: proc(f: ^Fetcher, idx: int) {
		assert(idx >= 0 && idx < FETCH_WORKERS, "worker index out of range")
		for {
			sync.mutex_lock(&f.mutex)
			// Park until a job arrives or fetcher_stop broadcasts — blocking on the
			// condvar replaces the old 10 ms sleep-poll, so idle workers cost
			// nothing and job pickup is immediate.
			for len(f.jobs) == 0 && sync.atomic_load(&f.running) {
				sync.cond_wait(&f.jobs_cond, &f.mutex)
			}
			if !sync.atomic_load(&f.running) {
				sync.mutex_unlock(&f.mutex)
				return
			}
			job := f.jobs[0]; ordered_remove(&f.jobs, 0); sync.mutex_unlock(&f.mutex)
			free_all(context.temp_allocator)
			body: []u8; status: u16; ok: bool; validate := f.cache_validator
			if job.cache_path != "" {
				if cached, read_err := os.read_entire_file_from_path(job.cache_path, f.allocator);
				   read_err == nil && len(cached) > 0 {
					if validate == nil ||
					   validate(
						   cached,
					   ) {body = cached; status = 200; ok = true} else {delete(cached); os.remove(job.cache_path)}
				}
			}
			if !ok {
				// Jitter worker scheduling in the native stress build so TSan explores
				// different condvar/result interleavings while production stays exact.
				when HTTP_STRESS do time.sleep(
					time.Duration(rand.int63() % 100) * time.Microsecond,
				)
				response: Http_Response
				response, ok = http_request_impl(f, idx, f.host, f.port, job.request, f.allocator)
				status = response.status; body = response.body; response.body = nil
				http_response_destroy(&response, f.allocator)
				if ok &&
				   status >= 200 &&
				   status < 300 &&
				   (validate == nil || validate(body)) &&
				   job.cache_path !=
					   "" {dir, _ := os.split_path(job.cache_path); os.make_directory_all(dir); _ = os.write_entire_file(job.cache_path, body)}
			}
			tag := job.tag
			fetch_job_destroy(&job, f.allocator)
			sync.mutex_lock(&f.mutex)
			assert(len(f.results) < f.result_slots)
			assert(f.result_slots <= FETCH_MAXIMUM_RESULTS)
			if f.results == nil do f.results.allocator = f.allocator
			append(&f.results, Fetch_Result{tag = tag, status = status, body = body, ok = ok})
			assert(len(f.results) <= FETCH_MAXIMUM_RESULTS)
			sync.mutex_unlock(&f.mutex)
			// Nudge the frame loop so the result is drained promptly even when the
			// app idles in event-driven frame mode.
			if f.wake != nil do f.wake()
		}
	}

} // when !INGOT_NET_SIM

// Suppress unused-import errors when the sim compiles the transport out.
_ :: fmt
_ :: rand
_ :: cnet
_ :: os
_ :: sync
_ :: thread
_ :: time
