#+build js
package ingotnet

import "base:runtime"
import "core:fmt"
import "core:strings"

DEFAULT_MAXIMUM_BODY :: 64 * 1024 * 1024

Http_Method :: enum u8 { Get, Post, Put, Patch, Delete }
Http_Header :: struct { name: string, value: string }
Http_Request :: struct { method: Http_Method, path: string, headers: []Http_Header, body: []u8, maximum_body: u64 }
Http_Response :: struct { status: u16, headers: []Http_Header, body: []u8 }

foreign import httpjs "ingot_http"
@(default_calling_convention = "c")
foreign httpjs {
	ingot_http_request :: proc(method: i32, url: [^]byte, url_len: i32, headers: [^]byte, headers_len: i32, body: [^]byte, body_len: i32, maximum_body: i32) -> i32 ---
	ingot_http_poll :: proc(id: i32) -> i32 ---
	ingot_http_status :: proc(id: i32) -> i32 ---
	ingot_http_body_len :: proc(id: i32) -> i32 ---
	ingot_http_body_copy :: proc(id: i32, dst: [^]byte, cap: i32) -> i32 ---
}

http_response_destroy :: proc(response: ^Http_Response) {
	delete(response.body)
	response^ = {}
}

http_get :: proc(host: string, port: int, path: string, allocator := context.allocator) -> (body: []u8, ok: bool) {
	_ = allocator
	response, request_ok := http_request(host, port, Http_Request{method = .Get, path = path, maximum_body = DEFAULT_MAXIMUM_BODY})
	if !request_ok || response.status != 200 do return nil, false
	return response.body, true
}

http_request :: proc(host: string, port: int, request: Http_Request, allocator := context.allocator) -> (response: Http_Response, ok: bool) {
	_ = host; _ = port; _ = request; _ = allocator
	return {}, false
}

Fetch_Result :: struct { tag: u64, body: []u8, ok: bool }
@(private = "file") In_Flight :: struct { id: i32, tag: u64 }
@(private = "file") Pending :: struct { tag: u64, path: string }
@(private = "file") MAX_INFLIGHT :: 6

Fetcher :: struct {
	host: string,
	port: int,
	cache_validator: proc(body: []u8) -> bool,
	in_flight: [dynamic]In_Flight,
	pending: [dynamic]Pending,
}

fetcher_start :: proc(f: ^Fetcher, host: string, port: int) {
	f.host = host; f.port = port
	f.in_flight = make([dynamic]In_Flight)
	f.pending = make([dynamic]Pending)
}

fetcher_stop :: proc(f: ^Fetcher) {
	for it in f.in_flight {
		if ingot_http_poll(it.id) != 0 {
			n := ingot_http_body_len(it.id)
			if n > 0 { buf := make([]byte, int(n)); ingot_http_body_copy(it.id, raw_data(buf), i32(len(buf))); delete(buf) } else { ingot_http_body_copy(it.id, nil, 0) }
		}
	}
	delete(f.in_flight); f.in_flight = nil
	for pending in f.pending do delete(pending.path)
	delete(f.pending); f.pending = nil
}

fetcher_request :: proc(f: ^Fetcher, tag: u64, path: string) { append(&f.pending, Pending{tag = tag, path = strings.clone(path)}); pump(f) }
fetcher_request_priority :: proc(f: ^Fetcher, tag: u64, path: string) { inject_at(&f.pending, 0, Pending{tag = tag, path = strings.clone(path)}); pump(f) }
fetcher_request_cached :: proc(f: ^Fetcher, tag: u64, path: string, cache_path: string) { _ = cache_path; fetcher_request(f, tag, path) }

@(private = "file")
pump :: proc(f: ^Fetcher) {
	for len(f.in_flight) < MAX_INFLIGHT && len(f.pending) > 0 {
		pending := f.pending[0]; ordered_remove(&f.pending, 0)
		url := fmt.tprintf("http://%s:%d%s", f.host, f.port, pending.path); delete(pending.path)
		bytes := transmute([]byte)url
		id := ingot_http_request(i32(Http_Method.Get), raw_data(bytes), i32(len(bytes)), nil, 0, nil, 0, DEFAULT_MAXIMUM_BODY)
		if id >= 0 do append(&f.in_flight, In_Flight{id = id, tag = pending.tag})
	}
}

fetcher_drain :: proc(f: ^Fetcher) -> []Fetch_Result {
	out: [dynamic]Fetch_Result; out.allocator = context.temp_allocator
	i := 0
	for i < len(f.in_flight) {
		item := f.in_flight[i]; state := ingot_http_poll(item.id)
		if state == 0 { i += 1; continue }
		status := ingot_http_status(item.id)
		request_ok := state == 1 && status >= 200 && status < 300
		body: []u8
		if request_ok {
			n := ingot_http_body_len(item.id)
			if n > 0 { body = make([]byte, int(n)); got := ingot_http_body_copy(item.id, raw_data(body), i32(len(body))); if got < 0 { delete(body); body = nil; request_ok = false } } else { ingot_http_body_copy(item.id, nil, 0) }
		} else { ingot_http_body_copy(item.id, nil, 0) }
		append(&out, Fetch_Result{tag = item.tag, body = body, ok = request_ok}); unordered_remove(&f.in_flight, i)
	}
	pump(f)
	if len(out) == 0 do return nil
	return out[:]
}

_ :: runtime
