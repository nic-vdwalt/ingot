#+build !js
package ingotnet

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
test_http_request_validation_helpers :: proc(t: ^testing.T) {
	testing.expect(t, http_request_is_valid(Http_Request{path = "/"}))
	testing.expect(
		t,
		http_request_is_valid(
			Http_Request {
				path = "/resource?q=1",
				headers = {Http_Header{name = "Accept", value = "application/json"}},
			},
		),
	)
	testing.expect(t, !http_request_is_valid(Http_Request{path = ""}))
	testing.expect(t, !http_request_is_valid(Http_Request{path = "resource"}))
	testing.expect(t, !http_request_is_valid(Http_Request{path = "/resource\rvalue"}))
	testing.expect(
		t,
		!http_request_is_valid(
			Http_Request {
				path = "/",
				headers = {Http_Header{name = "X:Injected", value = "value"}},
			},
		),
	)
	testing.expect(
		t,
		!http_request_is_valid(
			Http_Request {
				path = "/",
				headers = {Http_Header{name = "X-Test", value = "value\nInjected"}},
			},
		),
	)
}

@(test)
test_http_request_method_and_body_limit_helpers :: proc(t: ^testing.T) {
	testing.expect_value(t, http_request_method(.Get), "GET")
	testing.expect_value(t, http_request_method(.Post), "POST")
	testing.expect_value(t, http_request_method(.Put), "PUT")
	testing.expect_value(t, http_request_method(.Patch), "PATCH")
	testing.expect_value(t, http_request_method(.Delete), "DELETE")

	request := Http_Request {
		maximum_body = 128,
	}
	options := Http_Request_Options{}
	testing.expect_value(t, http_request_maximum_body(request, options), u64(128))
	options.limits.maximum_body_bytes = 64
	testing.expect_value(t, http_request_maximum_body(request, options), u64(64))
	request.maximum_body = 0
	options.limits.maximum_body_bytes = 0
	testing.expect_value(t, http_request_maximum_body(request, options), DEFAULT_MAXIMUM_BODY)
}

@(test)
test_parse_response_status_headers_and_body :: proc(t: ^testing.T) {
	text := "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
	response, ok := parse_http_response(transmute([]u8)text)
	testing.expect(t, ok)
	testing.expect_value(t, response.status, u16(404))
	testing.expect_value(t, string(response.body), "{}")
	testing.expect_value(t, len(response.headers), 2)
	http_response_destroy(&response)
}

@(test)
test_parse_chunked_response :: proc(t: ^testing.T) {
	text := "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"
	response, ok := parse_http_response(transmute([]u8)text)
	testing.expect(t, ok)
	testing.expect_value(t, string(response.body), "Wikipedia")
	http_response_destroy(&response)
}

@(test)
test_request_rejects_invalid_headers_and_oversized_body :: proc(t: ^testing.T) {
	text := "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n12345"
	response, ok := parse_http_response(transmute([]u8)text, 4)
	testing.expect(t, !ok)
	http_response_destroy(&response)
}

@(test)
test_parse_response_releases_headers_on_late_failures :: proc(t: ^testing.T) {
	cases := [?]string {
		"HTTP/1.1 200 OK\r\nGood: one\r\nmalformed\r\n\r\n",
		"HTTP/1.1 200 OK\r\nGood: one\r\nTransfer-Encoding: chunked\r\n\r\nxyz",
		"HTTP/1.1 200 OK\r\nGood: one\r\nContent-Length: 5\r\n\r\n1234",
	}
	for text in cases {
		response, ok := parse_http_response(transmute([]u8)text)
		testing.expect(t, !ok)
		testing.expect_value(t, len(response.headers), 0)
	}
}

@(test)
test_fetch_result_preserves_http_status :: proc(t: ^testing.T) {
	text := "forbidden"
	result := Fetch_Result {
		tag    = 7,
		status = 403,
		body   = transmute([]u8)text,
		ok     = true,
	}
	testing.expect_value(t, result.status, u16(403))
	testing.expect(t, result.ok)
}

@(test)
test_fetch_cache_read_write_and_failures :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/ingot_http_cache_%d", os.get_pid())
	_ = os.remove_all(root)
	defer os.remove_all(root)

	path := fmt.tprintf("%s/cache/body", root)
	payload := transmute([]u8)string("cached")
	fetch_cache_write(path, payload)
	body, ok := fetch_cache_read(path, nil, context.allocator)
	testing.expect(t, ok, "cache hit succeeds")
	testing.expect_value(t, string(body), "cached")
	delete(body)

	invalid := fmt.tprintf("%s/cache/invalid", root)
	testing.expect(t, os.write_entire_file(invalid, payload) == nil, "write invalid cache")
	body, ok = fetch_cache_read(
		invalid,
		proc(body: []u8) -> bool {return false},
		context.allocator,
	)
	testing.expect(t, !ok, "invalid cache is a miss")
	_, stat_err := os.stat(invalid, context.temp_allocator)
	testing.expect(t, stat_err != nil, "invalid cache is removed")

	missing := fmt.tprintf("%s/cache/missing", root)
	body, ok = fetch_cache_read(missing, nil, context.allocator)
	testing.expect(t, !ok, "missing cache is a miss")

	blocked := fmt.tprintf("%s/blocked", root)
	testing.expect(t, os.write_entire_file(blocked, payload) == nil, "create cache blocker")
	fetch_cache_write(fmt.tprintf("%s/body", blocked), payload)
}
