#+build !js
package ui

import "core:testing"
import "ingot:testx"

@(test)
md_spans_examples :: proc(t: ^testing.T) {
	spans := parse_inline_spans_with("a **bold** `code` http://x.com.")
	// Display strips ** and ` markers. The URL span itself trims the trailing
	// '.', but that '.' remains as ordinary trailing text.
	testing.expect_value(t, spans_display_string_with(spans), "a bold code http://x.com.")
}

@(test)
md_match_url :: proc(t: ^testing.T) {
	// Trailing sentence punctuation is trimmed from the URL.
	src := "see http://x.com."
	end, ok := match_url(src, 4)
	testing.expect(t, ok, "http:// URL should match")
	testing.expect_value(t, src[4:end], "http://x.com")
	// Non-URL prefix does not match.
	_, ok2 := match_url("not a url", 0)
	testing.expect(t, !ok2, "plain text is not a URL")
}

@(test)
md_spans_flags :: proc(t: ^testing.T) {
	spans := parse_inline_spans_with("**b** and `c`")
	bold_seen, code_seen := false, false
	for sp in spans {
		if sp.bold do bold_seen = true
		if sp.code do code_seen = true
	}
	testing.expect(t, bold_seen, "bold span present")
	testing.expect(t, code_seen, "code span present")
}

@(test)
md_spans_pill_with_trailing_text :: proc(t: ^testing.T) {
	encoded := "\x02src/main.odin\x03 "
	spans := parse_inline_spans_with(encoded)
	testing.expect_value(t, len(spans), 2)
	testing.expect(t, spans[0].pill, "mention path should remain a pill")
	testing.expect_value(t, spans[0].text, "src/main.odin")
	testing.expect_value(t, spans_display_string_with(spans), "src/main.odin ")
	testing.expect_value(t, raw_to_display(spans, len(encoded)), len("src/main.odin "))
}

@(test)
md_spans_contiguous_fuzz :: proc(t: ^testing.T) {
	p := testx.prng_make(0xBEEF)
	for _ in 0 ..< 3000 {
		s := testx.ascii_string(&p, 48)
		spans := parse_inline_spans_with(s)
		cur := 0
		for sp in spans {
			testing.expect(t, sp.raw_start == cur, "span raw ranges must be contiguous")
			cur = sp.raw_end
		}
		testing.expect_value(t, cur, len(s))
		free_all(context.temp_allocator)
	}
}
