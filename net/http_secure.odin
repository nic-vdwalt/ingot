#+build !js
package ingotnet

import "base:runtime"
import "core:c"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"
import curl "vendor:curl"

@(private = "file")
Curl_Body :: struct {
	bytes:    [dynamic]u8,
	maximum:  u64,
	overflow: bool,
}

@(private = "file")
g_curl_mutex: sync.Mutex
@(private = "file")
g_curl_initialized: bool

@(private = "file")
curl_initialize :: proc() -> bool {
	sync.mutex_lock(&g_curl_mutex)
	defer sync.mutex_unlock(&g_curl_mutex)
	if g_curl_initialized do return true
	if curl.global_init(curl.GLOBAL_ALL) != .E_OK do return false
	g_curl_initialized = true
	return true
}

@(private = "file")
curl_body_write :: proc "c" (
	buffer: [^]byte,
	size, count: c.size_t,
	userdata: rawptr,
) -> c.size_t {
	context = runtime.default_context()
	body := cast(^Curl_Body)userdata
	if body == nil || size == 0 || count == 0 do return 0
	if count > max(c.size_t) / size do return 0
	total := size * count
	if total > c.size_t(max(int)) || u64(len(body.bytes)) + u64(total) > body.maximum {
		body.overflow = true
		return 0
	}
	append(&body.bytes, ..buffer[:int(total)])
	return total
}

http_request_url :: proc(
	raw_url: string,
	request: Http_Request,
	options: Http_Request_Options = {},
	allocator := context.allocator,
) -> (
	response: Http_Response,
	err: Http_Error,
) {
	url, parse_err := http_url_parse(raw_url)
	if parse_err != .None do return {}, parse_err
	if request.path == "" ||
	   request.path[0] != '/' ||
	   strings.contains(request.path, "\r") ||
	   strings.contains(request.path, "\n") {
		return {}, .Invalid_Request
	}
	for header in request.headers {
		if header.name == "" ||
		   strings.contains(header.name, ":") ||
		   strings.contains(header.name, "\r") ||
		   strings.contains(header.name, "\n") ||
		   strings.contains(header.value, "\r") ||
		   strings.contains(header.value, "\n") {
			return {}, .Invalid_Request
		}
	}
	if !curl_initialize() do return {}, .TLS
	handle := curl.easy_init()
	if handle == nil do return {}, .Allocation
	defer curl.easy_cleanup(handle)
	url_c, url_c_err := strings.clone_to_cstring(raw_url, context.temp_allocator)
	if url_c_err != nil do return {}, .Allocation
	maximum := request.maximum_body
	if maximum == 0 do maximum = DEFAULT_MAXIMUM_BODY
	if options.limits.maximum_body_bytes > 0 do maximum = min(maximum, options.limits.maximum_body_bytes)
	body := Curl_Body {
		maximum = maximum,
	}
	body.bytes.allocator = allocator
	defer if err != .None do delete(body.bytes)
	if curl.easy_setopt(handle, .URL, url_c) != .E_OK do return {}, .Invalid_URL
	if curl.easy_setopt(handle, .SSL_VERIFYPEER, c.long(1)) != .E_OK do return {}, .TLS
	if curl.easy_setopt(handle, .SSL_VERIFYHOST, c.long(2)) != .E_OK do return {}, .TLS
	if curl.easy_setopt(handle, .DISALLOW_USERNAME_IN_URL, c.long(1)) != .E_OK do return {}, .Invalid_URL
	if curl.easy_setopt(handle, .WRITEFUNCTION, curl_body_write) != .E_OK do return {}, .Protocol
	if curl.easy_setopt(handle, .WRITEDATA, &body) != .E_OK do return {}, .Protocol
	if options.redirects.maximum_redirects > 0 {
		if curl.easy_setopt(handle, .FOLLOWLOCATION, c.long(1)) != .E_OK do return {}, .Redirect
		if curl.easy_setopt(handle, .MAXREDIRS, c.long(options.redirects.maximum_redirects)) != .E_OK do return {}, .Redirect
	}
	if options.timeouts.connect > 0 {
		milliseconds := c.long(options.timeouts.connect / time.Millisecond)
		if curl.easy_setopt(handle, .CONNECTTIMEOUT_MS, milliseconds) != .E_OK do return {}, .Timeout
	}
	if options.timeouts.total > 0 {
		milliseconds := c.long(options.timeouts.total / time.Millisecond)
		if curl.easy_setopt(handle, .TIMEOUT_MS, milliseconds) != .E_OK do return {}, .Timeout
	}
	method := "GET"
	switch request.method {
	case .Post:
		method = "POST"
	case .Put:
		method = "PUT"
	case .Patch:
		method = "PATCH"
	case .Delete:
		method = "DELETE"
	case .Get:
	}
	method_c, method_c_err := strings.clone_to_cstring(method, context.temp_allocator)
	if method_c_err != nil do return {}, .Allocation
	if curl.easy_setopt(handle, .CUSTOMREQUEST, method_c) != .E_OK do return {}, .Invalid_Request
	if len(request.body) > 0 {
		if curl.easy_setopt(handle, .POSTFIELDS, raw_data(request.body)) != .E_OK do return {}, .Invalid_Request
		if curl.easy_setopt(handle, .POSTFIELDSIZE, c.long(len(request.body))) != .E_OK do return {}, .Invalid_Request
	}
	perform := curl.easy_perform(handle)
	if perform != .E_OK {
		if body.overflow do return {}, .Body_Too_Large
		return {}, url.scheme == .Https ? .TLS : .Connect
	}
	status: c.long
	if curl.easy_getinfo(handle, .RESPONSE_CODE, &status) != .E_OK do return {}, .Protocol
	if status < 100 || status > 599 do return {}, .Protocol
	response.status = u16(status)
	response.body = body.bytes[:]
	response.allocator = allocator
	return response, .None
}

_ :: mem.Allocator
