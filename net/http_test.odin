#+build !js
package ingotnet

import "core:testing"

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
