#+build !js
package ingotnet

import "core:testing"

@(test)
test_query_component_encode :: proc(t: ^testing.T) {
	testing.expect_value(t, query_component_encode(""), "")
	testing.expect_value(t, query_component_encode("AZaz09-._~"), "AZaz09-._~")
	testing.expect_value(t, query_component_encode("a b/c?d=e&f"), "a%20b%2Fc%3Fd%3De%26f")
	testing.expect_value(t, query_component_encode("Málaga"), "M%C3%A1laga")
}

@(test)
test_http_url_parse :: proc(t: ^testing.T) {
	url, err := http_url_parse("https://example.com:8443/a?q=1")
	testing.expect_value(t, err, Http_Error.None)
	testing.expect_value(t, url.scheme, Http_Scheme.Https)
	testing.expect_value(t, url.host, "example.com")
	testing.expect_value(t, url.port, u16(8443))
	testing.expect_value(t, url.request_target, "/a?q=1")
}

@(test)
test_http_url_rejects_injection_and_downgrade :: proc(t: ^testing.T) {
	_, injection := http_url_parse("https://example.com\r\nX: y/")
	testing.expect_value(t, injection, Http_Error.Invalid_URL)
	base, base_err := http_url_parse("https://example.com/")
	testing.expect_value(t, base_err, Http_Error.None)
	_, downgrade := http_url_resolve(base, "http://example.com/")
	testing.expect_value(t, downgrade, Http_Error.Redirect)
}

@(test)
test_ws_url_parse_secure_and_plaintext :: proc(t: ^testing.T) {
	secure, secure_err := ws_url_parse("wss://example.test/chat?room=1")
	testing.expect_value(t, secure_err, WS_URL_Error.None)
	testing.expect_value(t, secure.scheme, WS_Scheme.Wss)
	testing.expect_value(t, secure.port, u16(443))
	testing.expect_value(t, secure.path, "/chat?room=1")
	plain, plain_err := ws_url_parse("ws://127.0.0.1:8080/ws")
	testing.expect_value(t, plain_err, WS_URL_Error.None)
	testing.expect_value(t, plain.port, u16(8080))
}

@(test)
test_ws_url_parse_rejects_unsafe_authority_and_path :: proc(t: ^testing.T) {
	invalid_urls := []string {
		"http://example.test/ws",
		"wss://user@example.test/ws",
		"wss://example.test:0/ws",
		"wss://example.test/ws#fragment",
		"wss://example.test/\r\nInjected: yes",
	}
	for raw_url in invalid_urls {
		_, err := ws_url_parse(raw_url)
		testing.expect(t, err != .None)
	}
}
