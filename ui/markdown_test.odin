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
md_match_heading :: proc(t: ^testing.T) {
	h1, h1_ok := match_heading("# one")
	testing.expect(t, h1_ok, "H1 should match")
	testing.expect_value(t, h1.level, 1)
	testing.expect_value(t, h1.prefix_len, 2)
	testing.expect_value(t, h1.text, "one")

	h3, h3_ok := match_heading("### three")
	testing.expect(t, h3_ok, "H3 should match before H2 and H1")
	testing.expect_value(t, h3.level, 3)
	testing.expect_value(t, h3.prefix_len, 4)
	testing.expect_value(t, h3.text, "three")

	_, h4_ok := match_heading("#### four")
	testing.expect(t, !h4_ok, "H4 preserves current plain-text behavior")
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
md_spans_unmatched_and_empty_markers :: proc(t: ^testing.T) {
	unmatched_pill := parse_inline_spans_with("a \x02path")
	testing.expect_value(t, spans_display_string_with(unmatched_pill), "a path")
	last := unmatched_pill[len(unmatched_pill) - 1]
	testing.expect_value(t, last.raw_start, 2)
	testing.expect_value(t, last.raw_end, 7)

	unmatched_code := parse_inline_spans_with("a `code")
	testing.expect_value(t, spans_display_string_with(unmatched_code), "a `code")
	testing.expect(t, !unmatched_code[1].code)

	empty_code := parse_inline_spans_with("``")
	testing.expect_value(t, len(empty_code), 1)
	testing.expect(t, empty_code[0].code)
	testing.expect_value(t, empty_code[0].text, "")

	empty_bold := parse_inline_spans_with("****")
	testing.expect_value(t, spans_display_string_with(empty_bold), "****")
	testing.expect(t, !empty_bold[0].bold)

	precedence := parse_inline_spans_with("`http://x.com`")
	testing.expect_value(t, len(precedence), 1)
	testing.expect(t, precedence[0].code)
	testing.expect(t, !precedence[0].link)
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

@(test)
md_block_helpers_and_table_offsets :: proc(t: ^testing.T) {
	testing.expect(t, is_code_fence("```odin"), "opening code fence")
	testing.expect(t, !is_code_fence("  ```odin"), "fence requires column zero")
	testing.expect(t, is_table_separator("|---|:--:|"), "valid table separator")
	testing.expect(t, !is_table_separator("|abc|---|"), "invalid separator text")

	line := "|  alpha | beta  |"
	cells, starts := split_table_row_offsets_with(line, 0, len(line))
	testing.expect_value(t, len(cells), 2)
	testing.expect_value(t, len(starts), 2)
	testing.expect_value(t, cells[0], "alpha")
	testing.expect_value(t, cells[1], "beta")
	testing.expect_value(t, line[starts[0]:starts[0] + len(cells[0])], cells[0])
	testing.expect_value(t, line[starts[1]:starts[1] + len(cells[1])], cells[1])
}
