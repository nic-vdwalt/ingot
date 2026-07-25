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
