#+build !js
package ingotnet

import "core:testing"
import "ingot:testx"

// Fuzz parse_http_response with fully random bytes. The parser must never
// panic and must respect maximum_body on any input. Seeds are fixed so
// failures reproduce deterministically.
@(test)
fuzz_parse_http_response_random_bytes :: proc(t: ^testing.T) {
	p := testx.prng_make(0x1)
	for _ in 0 ..< 20_000 {
		data := testx.random_bytes(&p, 2048)
		response, ok := parse_http_response(data, 64 * 1024, context.temp_allocator)
		if ok {
			testing.expect(t, len(response.body) <= 64 * 1024)
		}
		free_all(context.temp_allocator)
	}
}

// Fuzz parse_http_response with a valid chunked response corrupted by random
// byte flips and truncation, to reach deep into decode_chunked and
// header_content_length.
@(test)
fuzz_parse_http_response_mutated_valid :: proc(t: ^testing.T) {
	base := "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-A: b\r\n\r\n5;ext\r\nhello\r\n3\r\nabc\r\n0\r\n\r\n"
	p := testx.prng_make(0x2)
	for _ in 0 ..< 20_000 {
		buf := make([]u8, len(base), context.temp_allocator)
		copy(buf, base)
		for _ in 0 ..< testx.int_range(&p, 1, 8) {
			buf[testx.int_range(&p, 0, len(buf))] = u8(testx.next_u64(&p) & 0xFF)
		}
		cut := testx.int_range(&p, 0, len(buf) + 1)
		response, ok := parse_http_response(buf[:cut], 64 * 1024, context.temp_allocator)
		if ok {
			testing.expect(t, len(response.body) <= 64 * 1024)
		}
		free_all(context.temp_allocator)
	}
}
