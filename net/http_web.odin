#+build js
package ingotnet

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

DEFAULT_MAXIMUM_BODY :: 64 * 1024 * 1024
FETCH_MAXIMUM_PENDING :: 64
FETCH_MAXIMUM_DRAIN :: 64

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
Fetch_Priority :: enum u8 {
	Normal,
	Priority,
}
Fetch_Options :: struct {
	priority:   Fetch_Priority,
	cache_path: string,
}
Http_Response :: struct {
	status:  u16,
	headers: []Http_Header,
	body:    []u8,
}

// The real JS-interop transport below is compiled out when the deterministic
// simulated transport (http_sim.odin) is enabled via -define:INGOT_NET_SIM=true.
when !INGOT_NET_SIM {

	foreign import httpjs "ingot_http"
	@(default_calling_convention = "c")
	foreign httpjs {
		ingot_http_request :: proc(method: i32, url: [^]byte, url_len: i32, headers: [^]byte, headers_len: i32, body: [^]byte, body_len: i32, maximum_body: i32) -> i32 ---
		ingot_http_poll :: proc(id: i32) -> i32 ---
		ingot_http_status :: proc(id: i32) -> i32 ---
		ingot_http_body_len :: proc(id: i32) -> i32 ---
		ingot_http_body_copy :: proc(id: i32, dst: [^]byte, cap: i32) -> i32 ---
		ingot_http_cancel :: proc(id: i32) -> i32 ---
	}

} // when !INGOT_NET_SIM

http_response_destroy :: proc(response: ^Http_Response) {
	delete(response.body)
	response^ = {}
}

http_get :: proc(
	host: string,
	port: int,
	path: string,
	allocator := context.allocator,
) -> (
	body: []u8,
	ok: bool,
) {
	_ = allocator
	response, request_ok := http_request(
		host,
		port,
		Http_Request{method = .Get, path = path, maximum_body = DEFAULT_MAXIMUM_BODY},
	)
	if !request_ok || response.status != 200 do return nil, false
	return response.body, true
}

http_request :: proc(
	host: string,
	port: int,
	request: Http_Request,
	allocator := context.allocator,
) -> (
	response: Http_Response,
	ok: bool,
) {
	_ = host; _ = port; _ = request; _ = allocator
	return {}, false
}

when !INGOT_NET_SIM {

	Fetch_Result :: struct {
		tag:    u64,
		status: u16,
		body:   []u8,
		ok:     bool,
	}
	@(private = "file")
	In_Flight :: struct {
		id:  i32,
		tag: u64,
	}
	@(private = "file")
	Pending :: struct {
		tag:     u64,
		request: Http_Request,
	}
	@(private = "file")
	MAX_INFLIGHT :: 6

	Fetcher :: struct {
		host:            string,
		port:            int,
		cache_validator: proc(body: []u8) -> bool,
		in_flight:       [dynamic]In_Flight,
		pending:         [dynamic]Pending,
		// API parity with the native Fetcher so app code can set a wake hook on
		// every target; the web backend is single-threaded (JS completions are
		// polled from the rAF-driven loop) and never calls it.
		wake:            proc "contextless" (),
		running:         bool,
	}

	fetcher_start :: proc(f: ^Fetcher, host: string, port: int) {
		if f.running do return
		f.host = host; f.port = port
		f.in_flight = make([dynamic]In_Flight)
		f.pending = make([dynamic]Pending)
		f.running = true
	}

	fetcher_stop :: proc(f: ^Fetcher) {
		if !f.running do return
		f.running = false
		for it in f.in_flight do _ = ingot_http_cancel(it.id)
		delete(f.in_flight); f.in_flight = nil
		for &pending in f.pending do pending_destroy(&pending)
		delete(f.pending); f.pending = nil
	}

	fetcher_request_with_options :: proc(
		f: ^Fetcher,
		tag: u64,
		request: Http_Request,
		options: Fetch_Options = {},
	) -> bool {
		if !f.running || request.path == "" || request.path[0] != '/' || len(f.pending) >= FETCH_MAXIMUM_PENDING do return false
		assert(options.priority == .Normal || options.priority == .Priority)
		pending := Pending{tag = tag, request = request_clone(request)}
		if options.priority == .Priority {
			inject_at(&f.pending, 0, pending)
		} else {
			append(&f.pending, pending)
		}
		pump(f)
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

	@(private = "file")
	request_clone :: proc(request: Http_Request) -> Http_Request {
		headers := make([]Http_Header, len(request.headers))
		for header, i in request.headers do headers[i] = Http_Header {
			name  = strings.clone(header.name),
			value = strings.clone(header.value),
		}
		body := make([]u8, len(request.body)); copy(body, request.body)
		return Http_Request {
			method = request.method,
			path = strings.clone(request.path),
			headers = headers,
			body = body,
			maximum_body = request.maximum_body,
		}
	}

	@(private = "file")
	pending_destroy :: proc(pending: ^Pending) {
		delete(pending.request.path)
		for header in pending.request.headers {delete(header.name); delete(header.value)}
		delete(pending.request.headers); delete(pending.request.body)
		pending^ = {}
	}

	@(private = "file")
	encode_headers_json :: proc(headers: []Http_Header) -> []u8 {
		values := make(map[string]string, context.temp_allocator)
		for header in headers do values[header.name] = header.value
		encoded, err := json.marshal(values, allocator = context.temp_allocator)
		if err != nil do return nil
		return encoded
	}

	@(private = "file")
	pump :: proc(f: ^Fetcher) {
		for len(f.in_flight) < MAX_INFLIGHT && len(f.pending) > 0 {
			pending := f.pending[0]; ordered_remove(&f.pending, 0)
			url := pending.request.path
			if f.host != "" do url = fmt.tprintf("http://%s:%d%s", f.host, f.port, pending.request.path)
			bytes := transmute([]byte)url
			headers := encode_headers_json(pending.request.headers)
			maximum_body := pending.request.maximum_body
			if maximum_body == 0 do maximum_body = DEFAULT_MAXIMUM_BODY
			id := ingot_http_request(
				i32(pending.request.method),
				raw_data(bytes),
				i32(len(bytes)),
				raw_data(headers),
				i32(len(headers)),
				raw_data(pending.request.body),
				i32(len(pending.request.body)),
				i32(maximum_body),
			)
			if id < 0 {
				inject_at(&f.pending, 0, pending)
				return
			}
			tag := pending.tag; pending_destroy(&pending)
			append(&f.in_flight, In_Flight{id = id, tag = tag})
		}
	}

	// The returned slice uses context.temp_allocator and must not be retained.
	// Every result body transfers to the caller and must be deleted exactly once.
	// fetcher_stop frees only requests still owned by this Fetcher.
	fetcher_drain :: proc(f: ^Fetcher) -> []Fetch_Result {
		out: [dynamic]Fetch_Result; out.allocator = context.temp_allocator
		i := 0
		for i < len(f.in_flight) && len(out) < FETCH_MAXIMUM_DRAIN {
			item := f.in_flight[i]; state := ingot_http_poll(item.id)
			if state == 0 {i += 1; continue}
			status := ingot_http_status(item.id)
			request_ok := state == 1
			body: []u8
			n := ingot_http_body_len(item.id)
			if n >
			   0 {body = make([]byte, int(n)); got := ingot_http_body_copy(item.id, raw_data(body), i32(len(body))); if got < 0 {delete(body); body = nil; request_ok = false}} else {ingot_http_body_copy(item.id, nil, 0)}
			append(
				&out,
				Fetch_Result{tag = item.tag, status = u16(status), body = body, ok = request_ok},
			); unordered_remove(&f.in_flight, i)
		}
		pump(f)
		if len(out) == 0 do return nil
		return out[:]
	}

} // when !INGOT_NET_SIM

_ :: runtime
_ :: json
_ :: fmt
_ :: strings
