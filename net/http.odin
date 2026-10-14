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
import "ingot:threadhook"

DEFAULT_MAXIMUM_BODY :: 64 * 1024 * 1024
DEFAULT_RECEIVE_TIMEOUT :: 5 * time.Second
MAXIMUM_RECEIVE_TIMEOUT :: 2 * time.Minute
MAXIMUM_HEADER_BYTES :: 64 * 1024
HTTP_RECV_CALLS_MAX :: DEFAULT_MAXIMUM_BODY + MAXIMUM_HEADER_BYTES + 1

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
	method:          Http_Method,
	path:            string,
	headers:         []Http_Header,
	body:            []u8,
	maximum_body:    u64,
	receive_timeout: time.Duration,
}

Fetch_Priority :: enum u8 {
	Normal,
	Priority,
}

Fetch_Options :: struct {
	priority:   Fetch_Priority,
	cache_path: string,
}

Http_Response :: struct {
	status:    u16,
	headers:   []Http_Header,
	body:      []u8,
	allocator: mem.Allocator,
}

http_response_destroy :: proc(response: ^Http_Response) {
	assert(response != nil, "http_response_destroy: nil response")
	allocator := response.allocator
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
		http_response_destroy(&response)
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
		assert(f != nil, "http_get_interruptible: nil f")
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
		http_response_destroy(&response)
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
		if request.maximum_body > u64(max(int) - MAXIMUM_HEADER_BYTES) do return {}, false
		if f != nil do return fetch_request(f, idx, host, port, request, allocator)
		ep, resolve_ok := http_resolve(host, port)
		if !resolve_ok do return {}, false
		sock, dial_ok := http_net_dial(ep)
		if !dial_ok do return {}, false
		defer http_net_close(sock)
		wire := build_request(host, port, request, false)
		if len(wire) == 0 do return {}, false
		if !send_all(sock, wire) do return {}, false
		http_net_set_recv_timeout(sock, resolve_receive_timeout(request.receive_timeout))
		maximum := request_maximum_body(request)
		read, read_ok := http_read_response(sock, maximum, false)
		if !read_ok do return {}, false
		return parse_http_response(read.data, maximum, allocator)
	}

	// fetch_request runs one request on worker `idx`'s kept-alive connection,
	// dialling when there is none. A kept-alive socket the server closed while
	// idle (uvicorn drops them after 5 s) fails before any response byte
	// arrives; an idempotent request then redials and retries once.
	// Non-idempotent requests always use a fresh connection, so they are never
	// replayed against a server that may already have acted on them.
	@(private = "file")
	fetch_request :: proc(
		f: ^Fetcher,
		idx: int,
		host: string,
		port: int,
		request: Http_Request,
		allocator: mem.Allocator,
	) -> (
		Http_Response,
		bool,
	) {
		assert(f != nil, "fetch_request: nil fetcher")
		assert(idx >= 0 && idx < FETCH_WORKERS, "fetch_request: worker index out of range")
		idempotent := request.method != .Post && request.method != .Patch
		maximum := request_maximum_body(request)
		wire := build_request(host, port, request, true)
		if len(wire) == 0 do return {}, false
		for attempt in 0 ..< 2 {
			sock, reused, sock_ok := fetch_socket(f, idx, host, port, !idempotent || attempt > 0)
			if !sock_ok do return {}, false
			sent := send_all(sock, wire)
			read: Http_Read
			read_ok := false
			if sent {
				http_net_set_recv_timeout(sock, resolve_receive_timeout(request.receive_timeout))
				read, read_ok = http_read_response(sock, maximum, true)
			}
			if !read_ok || !read.reusable do fetch_socket_close(f, idx)
			if !read_ok {
				if reused && idempotent && read.received == 0 do continue
				return {}, false
			}
			response, parsed := parse_http_response(read.data, maximum, allocator)
			// An unparseable message leaves the stream position unknown.
			if !parsed do fetch_socket_close(f, idx)
			return response, parsed
		}
		return {}, false
	}

	// fetch_socket returns worker `idx`'s connection, reusing the kept-alive one
	// unless `fresh`. The socket lives in active_socks/active_open so
	// fetcher_stop can close it to unblock a recv and on shutdown. The resolved
	// endpoint is cached; a failed dial forgets it so the next dial resolves
	// again (the host may have moved).
	@(private = "file")
	fetch_socket :: proc(
		f: ^Fetcher,
		idx: int,
		host: string,
		port: int,
		fresh: bool,
	) -> (
		sock: cnet.TCP_Socket,
		reused: bool,
		ok: bool,
	) {
		assert(f != nil, "fetch_socket: nil fetcher")
		assert(idx >= 0 && idx < FETCH_WORKERS, "fetch_socket: worker index out of range")
		sync.mutex_lock(&f.sock_mutex)
		if !sync.atomic_load(&f.running) {
			sync.mutex_unlock(&f.sock_mutex)
			return {}, false, false
		}
		if f.active_open[idx] {
			if !fresh {
				sock = f.active_socks[idx]
				sync.mutex_unlock(&f.sock_mutex)
				return sock, true, true
			}
			http_net_close(f.active_socks[idx])
			f.active_open[idx] = false
		}
		ep, have_ep := f.endpoint, f.endpoint_ok
		sync.mutex_unlock(&f.sock_mutex)
		// Resolve outside the lock: a slow DNS lookup must not block
		// fetcher_stop or other workers' socket bookkeeping.
		if !have_ep {
			resolved, resolve_ok := http_resolve(host, port)
			if !resolve_ok do return {}, false, false
			ep = resolved
		}
		dialed, dial_ok := http_net_dial(ep)
		sync.mutex_lock(&f.sock_mutex)
		defer sync.mutex_unlock(&f.sock_mutex)
		if !dial_ok {
			f.endpoint_ok = false
			return {}, false, false
		}
		if !sync.atomic_load(&f.running) {
			http_net_close(dialed)
			return {}, false, false
		}
		f.endpoint = ep
		f.endpoint_ok = true
		f.active_socks[idx] = dialed
		f.active_open[idx] = true
		return dialed, false, true
	}

	// fetch_socket_close closes worker `idx`'s connection unless fetcher_stop
	// already did.
	@(private = "file")
	fetch_socket_close :: proc(f: ^Fetcher, idx: int) {
		assert(f != nil, "fetch_socket_close: nil fetcher")
		assert(idx >= 0 && idx < FETCH_WORKERS, "fetch_socket_close: worker index out of range")
		sync.mutex_lock(&f.sock_mutex)
		defer sync.mutex_unlock(&f.sock_mutex)
		if f.active_open[idx] {
			http_net_close(f.active_socks[idx])
			f.active_open[idx] = false
		}
	}

	@(private = "file")
	http_resolve :: proc(host: string, port: int) -> (ep: cnet.Endpoint, ok: bool) {
		when HTTP_STRESS {
			return cnet.Endpoint{port = port}, true
		} else {
			if addr, addr_ok := cnet.parse_ip4_address(host); addr_ok {
				return cnet.Endpoint{address = addr, port = port}, true
			}
			resolved, err := cnet.resolve_ip4(host)
			if err != nil do return {}, false
			resolved.port = port
			return resolved, true
		}
	}

	// tigerstyle: pure
	@(private = "file")
	request_maximum_body :: proc(request: Http_Request) -> int {
		assert(request.maximum_body <= u64(max(int) - MAXIMUM_HEADER_BYTES))
		maximum := int(request.maximum_body)
		if maximum <= 0 do maximum = DEFAULT_MAXIMUM_BODY
		return maximum
	}

	// Http_Read is one response's raw bytes off a socket.
	@(private = "file")
	Http_Read :: struct {
		data:     []u8, // context.temp_allocator; exactly one message when framed
		received: int, // bytes received, including on failure
		reusable: bool, // framed and the server did not ask to close
	}

	// http_read_response reads one response. With `framed`, it stops at the
	// end of the message as given by Content-Length, chunked encoding or a
	// bodiless status, so a kept-alive socket is not read to its close. A
	// response with no framing falls back to reading until the server closes,
	// and is then not reusable.
	@(private = "file")
	http_read_response :: proc(
		sock: cnet.TCP_Socket,
		maximum: int,
		framed: bool,
	) -> (
		read: Http_Read,
		ok: bool,
	) {
		buf: [dynamic]u8
		buf.allocator = context.temp_allocator
		chunk: [16384]u8
		recv_calls := 0
		for recv_calls < HTTP_RECV_CALLS_MAX {
			recv_calls += 1
			n, recv_ok := http_net_recv(sock, chunk[:])
			if n > 0 {
				ensure(n <= len(chunk))
				append(&buf, ..chunk[:n])
				if len(buf) > maximum + MAXIMUM_HEADER_BYTES {
					return Http_Read{received = len(buf)}, false
				}
				if framed {
					end, close_after, complete := http_message_end(buf[:])
					if complete {
						assert(end <= len(buf))
						return Http_Read {
								data = buf[:end],
								received = len(buf),
								reusable = !close_after && end == len(buf),
							},
							true
					}
				}
			}
			if !recv_ok || n == 0 do break
		}
		if recv_calls >= HTTP_RECV_CALLS_MAX || len(buf) == 0 {
			return Http_Read{received = len(buf)}, false
		}
		return Http_Read{data = buf[:], received = len(buf)}, true
	}

	// http_message_end finds where the response in `data` ends. `complete` is
	// false while more bytes are needed, and also for an unframed response
	// (read to close). `close_after` reports the server will not reuse the
	// connection (Connection: close, or an HTTP/1.0 reply).
	@(private = "file")
	http_message_end :: proc(data: []u8) -> (end: int, close_after: bool, complete: bool) {
		limit := min(len(data), MAXIMUM_HEADER_BYTES + 4)
		header_end := strings.index(string(data[:limit]), "\r\n\r\n")
		if header_end < 0 do return 0, false, false
		body_start := header_end + 4
		lines := strings.split(string(data[:header_end]), "\r\n", context.temp_allocator)
		if len(lines) == 0 do return 0, false, false
		parts := strings.split(lines[0], " ", context.temp_allocator)
		if len(parts) < 2 do return 0, false, false
		status, status_ok := strconv.parse_int(parts[1])
		if !status_ok do return 0, false, false
		close_after = !strings.has_prefix(lines[0], "HTTP/1.1")
		content_length := -1
		chunked := false
		for line in lines[1:] {
			colon := strings.index(line, ":")
			if colon <= 0 do continue
			name := strings.to_lower(strings.trim_space(line[:colon]), context.temp_allocator)
			value := strings.to_lower(strings.trim_space(line[colon + 1:]), context.temp_allocator)
			switch name {
			case "content-length":
				if parsed, parsed_ok := strconv.parse_int(value); parsed_ok && parsed >= 0 {
					content_length = parsed
				}
			case "transfer-encoding":
				chunked = strings.contains(value, "chunked")
			case "connection":
				if strings.contains(value, "close") do close_after = true
			}
		}
		if status == 204 || status == 304 do return body_start, close_after, true
		if chunked {
			chunk_end, chunk_done := http_chunked_end(data, body_start)
			return chunk_end, close_after, chunk_done
		}
		if content_length < 0 do return 0, false, false
		if len(data) - body_start < content_length do return 0, close_after, false
		return body_start + content_length, close_after, true
	}

	// http_chunked_end walks chunk headers from `start` without copying and
	// returns the offset just past the terminating chunk and trailers. A
	// malformed stream reports incomplete, so the read falls back to waiting
	// for close and parse_http_response rejects it.
	@(private = "file")
	http_chunked_end :: proc(data: []u8, start: int) -> (end: int, complete: bool) {
		assert(start >= 0 && start <= len(data))
		cursor := start
		for _ in 0 ..< len(data) / 3 + 1 {
			rest := string(data[cursor:])
			line_end := strings.index(rest, "\r\n")
			if line_end < 0 do return 0, false
			size_text := rest[:line_end]
			if semi := strings.index(size_text, ";"); semi >= 0 do size_text = size_text[:semi]
			size, parsed := strconv.parse_u64(strings.trim_space(size_text), 16)
			if !parsed do return 0, false
			cursor += line_end + 2
			if size == 0 {
				for _ in 0 ..< len(data) / 2 + 1 {
					trailer := string(data[cursor:])
					trailer_end := strings.index(trailer, "\r\n")
					if trailer_end < 0 do return 0, false
					cursor += trailer_end + 2
					if trailer_end == 0 do return cursor, true
				}
				return 0, false
			}
			if u64(len(data) - cursor) < size + 2 do return 0, false
			cursor += int(size) + 2
		}
		return 0, false
	}

	@(private = "file")
	resolve_receive_timeout :: proc(timeout: time.Duration) -> time.Duration {
		if timeout <= 0 do return DEFAULT_RECEIVE_TIMEOUT
		return min(timeout, MAXIMUM_RECEIVE_TIMEOUT)
	}

	// tigerstyle: pure
	@(private = "file")
	valid_request :: proc(request: Http_Request) -> bool {
		if request.path == "" || request.path[0] != '/' do return false
		if strings.contains(request.path, "\r") || strings.contains(request.path, "\n") do return false
		for header in request.headers {
			if header.name == "" ||
			   strings.contains(header.name, ":") ||
			   strings.contains(header.name, "\r") ||
			   strings.contains(header.name, "\n") {
				return false
			}
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
	build_request :: proc(
		host: string,
		port: int,
		request: Http_Request,
		keep_alive: bool,
	) -> []u8 {
		buf: [dynamic]u8
		buf.allocator = context.temp_allocator
		append(
			&buf,
			..transmute([]u8)fmt.tprintf(
				"%s %s HTTP/1.1\r\nHost: %s:%d\r\nConnection: %s\r\nUser-Agent: ingot-net/0.2\r\n",
				method_name(request.method),
				request.path,
				host,
				port,
				"keep-alive" if keep_alive else "close",
			),
		)
		for header in request.headers {
			append(&buf, ..transmute([]u8)fmt.tprintf("%s: %s\r\n", header.name, header.value))
		}
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
			ensure(n <= len(data) - total)
			total += n
		}
		return true
	}

} // when !INGOT_NET_SIM

@(private = "file")
parse_http_header_line :: proc(line: string, allocator: mem.Allocator) -> (Http_Header, bool) {
	colon := strings.index(line, ":")
	if colon <= 0 do return {}, false
	ensure(colon < len(line))
	return Http_Header {
			name = strings.clone(strings.trim_space(line[:colon]), allocator),
			value = strings.clone(strings.trim_space(line[colon + 1:]), allocator),
		},
		true
}

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
	response.allocator = allocator
	header_array := make([dynamic]Http_Header, 0, len(lines) - 1, allocator)
	for line in lines[1:] {
		header, header_ok := parse_http_header_line(line, allocator)
		if !header_ok {
			// The response remains the single owner across malformed peer input.
			http_response_destroy(&response)
			return {}, false
		}
		append(&header_array, header)
		response.headers = header_array[:]
	}
	response.headers = header_array[:]
	assert(len(response.headers) == len(header_array))
	raw_body := data[header_end + 4:]
	if transfer_chunked(response.headers) {
		decoded, decoded_ok := decode_chunked(raw_body, maximum_body, allocator)
		if !decoded_ok {
			http_response_destroy(&response)
			return {}, false
		}
		response.body = decoded
		return response, true
	}
	if length, has_length := header_content_length(response.headers); has_length {
		if length > maximum_body || len(raw_body) < length {
			http_response_destroy(&response)
			return {}, false
		}
		raw_body = raw_body[:length]
	} else if len(raw_body) > maximum_body {
		http_response_destroy(&response)
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
		name := strings.to_lower(header.name, context.temp_allocator)
		value := strings.to_lower(header.value, context.temp_allocator)
		if name == "transfer-encoding" && strings.contains(value, "chunked") do return true
	}
	return false
}

@(private = "file")
decode_chunked :: proc(data: []u8, maximum_body: int, allocator: mem.Allocator) -> ([]u8, bool) {
	out: [dynamic]u8
	out.allocator = allocator
	cursor := 0
	chunks_max := len(data) / 3 + 1
	for _ in 0 ..< chunks_max {
		line_end := strings.index(string(data[cursor:]), "\r\n")
		if line_end < 0 {delete(out); return nil, false}
		ensure(cursor >= 0 && cursor + line_end <= len(data))
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
	delete(out)
	return nil, false
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
		// Cross-thread stop flag - access with sync.atomic_load / atomic_store.
		running:         bool,
		// Workers park on jobs_cond (under mutex) until a job arrives or
		// fetcher_stop broadcasts - no sleep-polling.
		jobs_cond:       sync.Cond,
		// Optional wake hook, called from a worker after a result is queued so an
		// event-driven-idle frame loop repaints promptly instead of waiting for
		// its idle-floor tick (gfx.request_redraw fits). Set before fetcher_start.
		wake:            proc "contextless" (),
		sock_mutex:      sync.Mutex,
		// Per-worker connection, kept alive across jobs (see fetch_socket).
		// fetcher_stop closes these both to unblock an in-flight recv and to
		// release idle kept-alive sockets.
		active_socks:    [FETCH_WORKERS]cnet.TCP_Socket,
		active_open:     [FETCH_WORKERS]bool,
		// Resolved host, guarded by sock_mutex; cleared when a dial fails.
		endpoint:        cnet.Endpoint,
		endpoint_ok:     bool,
		worker_ctx:      [FETCH_WORKERS]Fetch_Worker_Ctx,
		// Worker threads have their own context, so every cross-thread job/result
		// allocation explicitly uses the allocator captured by fetcher_start.
		allocator:       mem.Allocator,
	}

	fetcher_start :: proc(f: ^Fetcher, host: string, port: int) {
		assert(f != nil)
		assert(!sync.atomic_load(&f.running), "fetcher_start: already running")
		f.host = host
		f.port = port
		f.allocator = context.allocator
		sync.atomic_store(&f.running, true)
		for i in 0 ..< FETCH_WORKERS {
			assert(f.workers[i] == nil)
			f.worker_ctx[i] = Fetch_Worker_Ctx {
				f   = f,
				idx = i,
			}
			f.workers[i] = thread.create(proc(t: ^thread.Thread) {
				context.assertion_failure_proc = threadhook.install(context.assertion_failure_proc)
				ctx := cast(^Fetch_Worker_Ctx)t.data
				fetch_worker(ctx.f, ctx.idx)
			})
			f.workers[i].data = &f.worker_ctx[i]
			thread.start(f.workers[i])
		}
		assert(sync.atomic_load(&f.running))
	}

	fetcher_stop :: proc(f: ^Fetcher) {
		assert(f != nil)
		// Order matters: clear running and wake every parked worker under the job
		// mutex (broadcast under the mutex is never lost against a concurrent
		// cond_wait), then unblock in-flight recvs by closing their sockets, then
		// join.
		sync.mutex_lock(&f.mutex)
		sync.atomic_store(&f.running, false)
		sync.cond_broadcast(&f.jobs_cond)
		sync.mutex_unlock(&f.mutex)
		sync.mutex_lock(&f.sock_mutex)
		for i in 0 ..< FETCH_WORKERS {
			if f.active_open[i] {
				http_net_close(f.active_socks[i])
				f.active_open[i] = false
			}
		}
		sync.mutex_unlock(&f.sock_mutex)
		for i in 0 ..< FETCH_WORKERS {
			if f.workers[i] != nil {
				thread.join(f.workers[i])
				thread.destroy(f.workers[i])
				f.workers[i] = nil
			}
		}
		sync.mutex_lock(&f.mutex)
		assert(f.result_slots == len(f.jobs) + len(f.results))
		assert(f.result_slots <= FETCH_MAXIMUM_RESULTS)
		for &job in f.jobs do fetch_job_destroy(&job, f.allocator)
		delete(f.jobs)
		for result in f.results do delete(result.body, f.allocator)
		delete(f.results)
		// delete() releases the backing store but leaves the slice header's
		// length intact, so without this the fields stay non-empty views onto
		// freed memory and the post-conditions below read a stale length.
		// Reachable whenever stop happens with work still queued, which is
		// what the idle-stop stress exercises.
		f.jobs = nil
		f.results = nil
		f.result_slots = 0
		assert(len(f.jobs) == 0)
		assert(len(f.results) == 0)
		sync.mutex_unlock(&f.mutex)
	}

	fetcher_request_with_options :: proc(
		f: ^Fetcher,
		tag: u64,
		request: Http_Request,
		options: Fetch_Options = {},
	) -> bool {
		assert(f != nil)
		if !valid_request(request) do return false
		assert(options.priority == .Normal || options.priority == .Priority)
		job := Fetch_Job {
			tag        = tag,
			request    = http_request_clone(request, f.allocator),
			cache_path = strings.clone(options.cache_path, f.allocator),
		}
		sync.mutex_lock(&f.mutex)
		defer sync.mutex_unlock(&f.mutex)
		assert(f.result_slots >= len(f.jobs) + len(f.results))
		assert(f.result_slots <= FETCH_MAXIMUM_RESULTS)
		if !sync.atomic_load(&f.running) ||
		   len(f.jobs) >= FETCH_MAXIMUM_PENDING ||
		   f.result_slots >= FETCH_MAXIMUM_RESULTS {
			fetch_job_destroy(&job, f.allocator)
			return false
		}
		f.result_slots += 1
		assert(f.result_slots <= FETCH_MAXIMUM_RESULTS)
		if f.jobs == nil do f.jobs.allocator = f.allocator
		if options.priority == .Priority {
			inject_at(&f.jobs, 0, job)
		} else {
			append(&f.jobs, job)
		}
		assert(len(f.jobs) <= FETCH_MAXIMUM_PENDING)
		assert(f.result_slots >= len(f.jobs) + len(f.results))
		sync.cond_signal(&f.jobs_cond)
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
	// fetcher_cancel removes queued, not-yet-started jobs whose tag is in
	// `tags` and releases their result slots. Jobs already picked up by a
	// worker are unaffected and still deliver a result. Returns the tags that
	// were cancelled (context.temp_allocator).
	fetcher_cancel :: proc(f: ^Fetcher, tags: []u64) -> []u64 {
		assert(f != nil)
		if len(tags) == 0 do return nil
		out := make([dynamic]u64, 0, len(tags), context.temp_allocator)
		sync.mutex_lock(&f.mutex); defer sync.mutex_unlock(&f.mutex)
		assert(f.result_slots >= len(f.jobs) + len(f.results))
		for index := 0; index < len(f.jobs); {
			if !tag_in(tags, f.jobs[index].tag) {
				index += 1
				continue
			}
			append(&out, f.jobs[index].tag)
			fetch_job_destroy(&f.jobs[index], f.allocator)
			ordered_remove(&f.jobs, index)
			f.result_slots -= 1
		}
		assert(f.result_slots >= len(f.jobs) + len(f.results))
		assert(f.result_slots >= 0)
		return out[:]
	}

	// The returned slice uses context.temp_allocator and must not be retained.
	// Every result body transfers to the caller and must be deleted exactly once.
	// fetcher_stop frees only jobs and results still owned by this Fetcher.
	fetcher_drain :: proc(f: ^Fetcher) -> []Fetch_Result {
		assert(f != nil)
		sync.mutex_lock(&f.mutex); defer sync.mutex_unlock(&f.mutex)
		assert(f.result_slots >= 0)
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
	http_request_clone :: proc(request: Http_Request, allocator: mem.Allocator) -> Http_Request {
		assert(valid_request(request))
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
			receive_timeout = request.receive_timeout,
		}
	}

	@(private = "file")
	fetch_job_destroy :: proc(job: ^Fetch_Job, allocator: mem.Allocator) {
		assert(job != nil)
		delete(job.request.path, allocator)
		for header in job.request.headers {
			delete(header.name, allocator)
			delete(header.value, allocator)
		}
		delete(job.request.headers, allocator)
		delete(job.request.body, allocator)
		delete(job.cache_path, allocator)
		job^ = {}
		assert(job.tag == 0)
		assert(len(job.request.path) == 0)
	}

	@(private)
	fetch_cache_read :: proc(
		path: string,
		validate: proc(body: []u8) -> bool,
		allocator: mem.Allocator,
	) -> (
		body: []u8,
		ok: bool,
	) {
		assert(path != "", "fetch_cache_read: empty path")
		cached, read_err := os.read_entire_file_from_path(path, allocator)
		if read_err != nil do return nil, false
		if len(cached) > 0 && (validate == nil || validate(cached)) {
			return cached, true
		}
		delete(cached, allocator)
		if remove_err := os.remove(path); remove_err != nil {
			fmt.eprintfln("net: unable to remove invalid cache %q: %v", path, remove_err)
		}
		return nil, false
	}

	@(private)
	fetch_cache_write :: proc(path: string, body: []u8) {
		assert(path != "", "fetch_cache_write: empty path")
		directory, _ := os.split_path(path)
		if directory != "" {
			if mkdir_err := os.make_directory_all(directory);
			   mkdir_err != nil && !os.is_dir(directory) {
				fmt.eprintfln("net: unable to create cache directory %q: %v", directory, mkdir_err)
				return
			}
		}
		if write_err := os.write_entire_file(path, body); write_err != nil {
			fmt.eprintfln("net: unable to write cache %q: %v", path, write_err)
		}
	}

	@(private = "file")
	fetch_worker :: proc(f: ^Fetcher, idx: int) {
		assert(idx >= 0, "fetch_worker: negative worker index")
		assert(idx < FETCH_WORKERS, "fetch_worker: worker index out of range")
		// tigerstyle: allow-unbounded-loop -- fetcher_stop terminates the worker lifetime
		for {
			sync.mutex_lock(&f.mutex)
			// Park until a job arrives or fetcher_stop broadcasts - blocking on the
			// condvar replaces the old 10 ms sleep-poll, so idle workers cost
			// nothing and job pickup is immediate.
			// tigerstyle: allow-unbounded-loop -- fetcher_stop broadcasts the wait condition
			for len(f.jobs) == 0 && sync.atomic_load(&f.running) {
				sync.cond_wait(&f.jobs_cond, &f.mutex)
			}
			if !sync.atomic_load(&f.running) {
				sync.mutex_unlock(&f.mutex)
				return
			}
			job := f.jobs[0]
			ordered_remove(&f.jobs, 0)
			sync.mutex_unlock(&f.mutex)
			free_all(context.temp_allocator)
			body: []u8
			status: u16
			ok: bool
			validate := f.cache_validator
			if job.cache_path != "" {
				body, ok = fetch_cache_read(job.cache_path, validate, f.allocator)
				if ok do status = 200
			}
			if !ok {
				// Jitter worker scheduling in the native stress build so TSan explores
				// different condvar/result interleavings while production stays exact.
				when HTTP_STRESS do time.sleep(
					time.Duration(rand.int63() % 100) * time.Microsecond,
				)
				response: Http_Response
				response, ok = http_request_impl(f, idx, f.host, f.port, job.request, f.allocator)
				status = response.status
				body = response.body
				response.body = nil
				http_response_destroy(&response)
				cacheable := ok && status >= 200 && status < 300
				cacheable = cacheable && (validate == nil || validate(body))
				if cacheable && job.cache_path != "" {
					fetch_cache_write(job.cache_path, body)
				}
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
