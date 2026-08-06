#+build !js
package ingotnet

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"

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

@(private)
curl_initialize :: proc() -> bool {
	sync.mutex_lock(&g_curl_mutex)
	defer sync.mutex_unlock(&g_curl_mutex)
	if g_curl_initialized do return true
	if http_curl_global_init(HTTP_CURL_GLOBAL_ALL) != .OK do return false
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

@(private)
http_request_is_valid :: proc(request: Http_Request) -> bool {
	if request.path == "" ||
	   request.path[0] != '/' ||
	   strings.contains(request.path, "\r") ||
	   strings.contains(request.path, "\n") {
		return false
	}
	for header in request.headers {
		if header.name == "" ||
		   strings.contains(header.name, ":") ||
		   strings.contains(header.name, "\r") ||
		   strings.contains(header.name, "\n") ||
		   strings.contains(header.value, "\r") ||
		   strings.contains(header.value, "\n") {
			return false
		}
	}
	return true
}

HTTP_REQUEST_HEADERS_MAX :: 32
HTTP_REQUEST_HEADER_NAME_BYTES_MAX :: 128
HTTP_REQUEST_HEADER_VALUE_BYTES_MAX :: 8192

@(private)
curl_request_headers :: proc(request: Http_Request) -> (headers: ^Http_Curl_Slist, err: Http_Error) {
	if len(request.headers) > HTTP_REQUEST_HEADERS_MAX do return nil, .Invalid_Request
	for header in request.headers {
		if len(header.name) > HTTP_REQUEST_HEADER_NAME_BYTES_MAX ||
		   len(header.value) > HTTP_REQUEST_HEADER_VALUE_BYTES_MAX {
			if headers != nil do http_curl_slist_free_all(headers)
			return nil, .Invalid_Request
		}
		line := fmt.tprintf("%s: %s", header.name, header.value)
		line_c, clone_err := strings.clone_to_cstring(line, context.temp_allocator)
		if clone_err != nil {
			if headers != nil do http_curl_slist_free_all(headers)
			return nil, .Allocation
		}
		next := http_curl_slist_append(headers, line_c)
		if next == nil {
			if headers != nil do http_curl_slist_free_all(headers)
			return nil, .Allocation
		}
		headers = next
	}
	return headers, .None
}

@(private)
http_request_maximum_body :: proc(request: Http_Request, options: Http_Request_Options) -> u64 {
	maximum := request.maximum_body
	if maximum == 0 do maximum = DEFAULT_MAXIMUM_BODY
	if options.limits.maximum_body_bytes > 0 {
		maximum = min(maximum, options.limits.maximum_body_bytes)
	}
	return maximum
}

@(private)
http_request_method :: proc(method: Http_Method) -> string {
	switch method {
	case .Post:
		return "POST"
	case .Put:
		return "PUT"
	case .Patch:
		return "PATCH"
	case .Delete:
		return "DELETE"
	case .Get:
		return "GET"
	}
	return "GET"
}

@(private = "file")
curl_request_configure_base :: proc(
	handle: $Handle,
	raw_url: string,
	body: ^Curl_Body,
	ca_file: string,
) -> Http_Error {
	url_c, clone_err := strings.clone_to_cstring(raw_url, context.temp_allocator)
	if clone_err != nil do return .Allocation
	if http_curl_easy_setopt(handle, HTTP_CURL_URL, url_c) != .OK do return .Invalid_URL
	if http_curl_easy_setopt(handle, HTTP_CURL_SSL_VERIFYPEER, c.long(1)) != .OK do return .TLS
	if http_curl_easy_setopt(handle, HTTP_CURL_SSL_VERIFYHOST, c.long(2)) != .OK do return .TLS
	if len(ca_file) > 0 {
		ca_c, ca_err := strings.clone_to_cstring(ca_file, context.temp_allocator)
		if ca_err != nil do return .Allocation
		if http_curl_easy_setopt(handle, HTTP_CURL_CAINFO, ca_c) != .OK do return .TLS
	}
	if http_curl_easy_setopt(handle, HTTP_CURL_DISALLOW_USERNAME_IN_URL, c.long(1)) != .OK {
		return .Invalid_URL
	}
	if http_curl_easy_setopt(handle, HTTP_CURL_WRITEFUNCTION, curl_body_write) != .OK do return .Protocol
	if http_curl_easy_setopt(handle, HTTP_CURL_WRITEDATA, body) != .OK do return .Protocol
	return .None
}

@(private = "file")
curl_request_configure_policy :: proc(
	handle: $Handle,
	options: Http_Request_Options,
) -> Http_Error {
	if options.redirects.maximum_redirects > 0 {
		if http_curl_easy_setopt(handle, HTTP_CURL_FOLLOWLOCATION, c.long(1)) != .OK do return .Redirect
		if http_curl_easy_setopt(handle, HTTP_CURL_MAXREDIRS, c.long(options.redirects.maximum_redirects)) !=
		   .OK {
			return .Redirect
		}
	}
	if options.timeouts.connect > 0 {
		milliseconds := c.long(options.timeouts.connect / time.Millisecond)
		if http_curl_easy_setopt(handle, HTTP_CURL_CONNECTTIMEOUT_MS, milliseconds) != .OK do return .Timeout
	}
	if options.timeouts.total > 0 {
		milliseconds := c.long(options.timeouts.total / time.Millisecond)
		if http_curl_easy_setopt(handle, HTTP_CURL_TIMEOUT_MS, milliseconds) != .OK do return .Timeout
	}
	return .None
}

@(private = "file")
curl_request_configure_payload :: proc(handle: $Handle, request: Http_Request) -> Http_Error {
	method_c, clone_err := strings.clone_to_cstring(
		http_request_method(request.method),
		context.temp_allocator,
	)
	if clone_err != nil do return .Allocation
	if http_curl_easy_setopt(handle, HTTP_CURL_CUSTOMREQUEST, method_c) != .OK do return .Invalid_Request
	if len(request.body) == 0 do return .None
	if http_curl_easy_setopt(handle, HTTP_CURL_POSTFIELDS, raw_data(request.body)) != .OK {
		return .Invalid_Request
	}
	if http_curl_easy_setopt(handle, HTTP_CURL_POSTFIELDSIZE, c.long(len(request.body))) != .OK {
		return .Invalid_Request
	}
	return .None
}

@(private = "file")
curl_request_perform :: proc(
	handle: $Handle,
	scheme: Http_Scheme,
	body: ^Curl_Body,
) -> (
	u16,
	Http_Error,
) {
	assert(body != nil, "curl_request_perform: nil body")
	if http_curl_easy_perform(handle) != .OK {
		if body.overflow do return 0, .Body_Too_Large
		return 0, scheme == .Https ? .TLS : .Connect
	}
	status: c.long
	if http_curl_easy_getinfo(handle, HTTP_CURL_RESPONSE_CODE, &status) != .OK do return 0, .Protocol
	if status < 100 || status > 599 do return 0, .Protocol
	return u16(status), .None
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
	if !http_request_is_valid(request) do return {}, .Invalid_Request
	if !curl_initialize() do return {}, .TLS
	handle := http_curl_easy_init()
	if handle == nil do return {}, .Allocation
	defer http_curl_easy_cleanup(handle)
	body := Curl_Body {
		maximum = http_request_maximum_body(request, options),
	}
	body.bytes.allocator = allocator
	defer if err != .None do delete(body.bytes)
	if setup_err := curl_request_configure_base(handle, raw_url, &body, options.ca_file); setup_err != .None {
		return {}, setup_err
	}
	headers, headers_err := curl_request_headers(request)
	if headers_err != .None do return {}, headers_err
	defer if headers != nil do http_curl_slist_free_all(headers)
	if headers != nil && http_curl_easy_setopt(handle, HTTP_CURL_HTTPHEADER, headers) != .OK {
		return {}, .Invalid_Request
	}
	if setup_err := curl_request_configure_policy(handle, options); setup_err != .None {
		return {}, setup_err
	}
	if setup_err := curl_request_configure_payload(handle, request); setup_err != .None {
		return {}, setup_err
	}
	status, perform_err := curl_request_perform(handle, url.scheme, &body)
	if perform_err != .None do return {}, perform_err
	response.status = status
	response.body = body.bytes[:]
	response.allocator = allocator
	return response, .None
}

_ :: mem.Allocator
