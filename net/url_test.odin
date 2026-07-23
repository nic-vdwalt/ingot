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
