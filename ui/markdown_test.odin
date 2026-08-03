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

// A heading must be measured at the size it is drawn at. Deriving the size
// twice let the measure (TITLE, or BODY for level 3) drift from the draw
// (TITLE+6 / TITLE+2 / TITLE), so every heading wrapped as if it were smaller
// than it renders.
@(test)
md_heading_measure_matches_draw_size :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	ctx := markdown_context(&frame)
	metrics := ui_frame_metrics(&frame)

	testing.expect_value(t, heading_font_size(&ctx, 1), metrics.FONT_SIZE_TITLE + 6)
	testing.expect_value(t, heading_font_size(&ctx, 2), metrics.FONT_SIZE_TITLE + 2)
	testing.expect_value(t, heading_font_size(&ctx, 3), metrics.FONT_SIZE_TITLE)

	// Heading line advance follows the heading's own size, not body text.
	for level in 1 ..= 3 {
		size := heading_font_size(&ctx, level)
		advance := heading_line_height(&ctx, level)
		testing.expectf(
			t,
			advance > size,
			"level %d advance %d must exceed its %d px glyphs",
			level,
			advance,
			size,
		)
	}
	// A level-1 heading is larger than body text, so it must not reuse the
	// body line height.
	testing.expect(
		t,
		heading_line_height(&ctx, 1) > metrics.LINE_HEIGHT,
		"H1 must not advance by the body line height",
	)
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

// [label](target) must produce one link span showing the label and pointing at
// the target.
//
// Before this was parsed, the syntax failed in the worst possible way: parsing
// began at the 'h' of the scheme, so the reader saw the literal text
// "[docs](", then a live link reading the raw URL, then ")". The markup was
// visible, the label was not, and the link text was the thing the author had
// written the label to replace.
@(test)
markdown_parses_reference_link :: proc(t: ^testing.T) {
	spans := parse_inline_spans_with("see [docs](https://example.com) now", context.allocator)
	defer delete(spans)
	testing.expect_value(t, len(spans), 3)
	testing.expect_value(t, spans[0].text, "see ")
	testing.expect(t, !spans[0].link)
	testing.expect_value(t, spans[1].text, "docs")
	testing.expect(t, spans[1].link)
	testing.expect_value(t, spans[1].href, "https://example.com")
	testing.expect_value(t, spans[2].text, " now")
	testing.expect(t, !spans[2].link)
}

// The raw range must span the whole [label](target) source, or selection
// offsets drift out of step with the document the user is selecting from.
@(test)
markdown_reference_link_covers_its_source :: proc(t: ^testing.T) {
	line := "a [b](c) d"
	spans := parse_inline_spans_with(line, context.allocator)
	defer delete(spans)
	testing.expect_value(t, len(spans), 3)
	testing.expect_value(t, spans[1].raw_start, 2)
	testing.expect_value(t, spans[1].raw_end, 8)
	testing.expect_value(t, line[spans[1].raw_start:spans[1].raw_end], "[b](c)")
}

// A bare URL is its own target, so display and destination coincide and a
// consumer never has to ask which spelling produced the span.
@(test)
markdown_bare_url_is_its_own_href :: proc(t: ^testing.T) {
	spans := parse_inline_spans_with("go https://example.com now", context.allocator)
	defer delete(spans)
	testing.expect_value(t, len(spans), 3)
	testing.expect(t, spans[1].link)
	testing.expect_value(t, spans[1].text, "https://example.com")
	testing.expect_value(t, spans[1].href, spans[1].text)
}

// A relative target needs no scheme: [spec](#anchor) is a valid link, and the
// application decides how to follow it.
@(test)
markdown_reference_link_allows_relative_targets :: proc(t: ^testing.T) {
	spans := parse_inline_spans_with("[spec](#anchor)", context.allocator)
	defer delete(spans)
	testing.expect_value(t, len(spans), 1)
	testing.expect(t, spans[0].link)
	testing.expect_value(t, spans[0].text, "spec")
	testing.expect_value(t, spans[0].href, "#anchor")
}

// Negative space: shapes that are not links must stay plain text rather than
// being half-consumed. Each of these is a way the parser could run off the end
// of a line or swallow ordinary prose.
@(test)
markdown_non_links_stay_plain :: proc(t: ^testing.T) {
	Case :: struct {
		line: string,
		why:  string,
	}
	cases := [?]Case {
		{"an [unclosed label", "no closing bracket"},
		{"an [label] alone", "no target follows"},
		{"an [label] (spaced)", "the parenthesis must follow immediately"},
		{"an [label](unclosed", "no closing parenthesis"},
		{"an [](target)", "empty label would be unclickable"},
		{"an [label]()", "empty target goes nowhere"},
		{"array[0] indexing", "ordinary bracket use"},
	}
	for item in cases {
		spans := parse_inline_spans_with(item.line, context.allocator)
		defer delete(spans)
		for span in spans {
			testing.expectf(t, !span.link, "%q produced a link span (%s)", item.line, item.why)
		}
	}
}

// A link inside emphasis must not swallow the bold markers, and a bracket in
// the middle of a line must not disturb the spans around it.
@(test)
markdown_reference_link_composes_with_bold :: proc(t: ^testing.T) {
	spans := parse_inline_spans_with("**bold** and [a](b)", context.allocator)
	defer delete(spans)
	found_bold := false
	found_link := false
	for span in spans {
		if span.bold && span.text == "bold" do found_bold = true
		if span.link && span.text == "a" && span.href == "b" do found_link = true
	}
	testing.expect(t, found_bold)
	testing.expect(t, found_link)
}

// A press must not survive the draw that follows it.
//
// Link state is per-draw, and nothing cleared it originally: a click recorded
// on one frame stayed set, so the application re-opened the URL on every
// subsequent frame until the pointer moved off the link. One click became a
// stream of browser tabs.
@(test)
markdown_link_state_does_not_survive_a_redraw :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	defer ui_frame_destroy(&frame)
	frame.output = output
	ui_frame_begin(&frame, &runtime)

	ctx := markdown_context(&frame)
	// Stand in for a click the previous frame recorded.
	ctx.hovered_link = "https://example.com"
	ctx.link_pressed = true
	url, activated := markdown_link_activated(&ctx)
	testing.expect(t, activated)
	testing.expect_value(t, url, "https://example.com")

	// The next pass must clear it. Measuring rather than drawing keeps this a
	// unit test - it takes the same entry point and the same reset, without
	// needing a text backend to rasterise with.
	_ = markdown_draw(
		&ctx,
		{0, 0, 400, 0},
		"see https://example.com",
		Color{0, 0, 0, 255},
		draw = false,
	)
	_, still_activated := markdown_link_activated(&ctx)
	testing.expect(t, !still_activated)
	ui_frame_end(&frame)
}

// Reporting activation must not abort on a state a caller can legitimately
// produce.
//
// This previously asserted that a press implied a hovered link. That reads
// like an invariant but is not one: a caller drawing the same context twice -
// a measure pass after a draw pass, or two documents sharing a context - can
// clear hovered_link while link_pressed is still set. Crashing on an ordinary
// sequence of events is the operating-error-as-assertion mistake
// TIGER_STYLE.md warns about, and it would have taken the whole application
// down.
@(test)
markdown_link_activated_handles_a_cleared_link :: proc(t: ^testing.T) {
	ctx := Markdown_Context {
		link_pressed = true,
		hovered_link = "",
	}
	url, activated := markdown_link_activated(&ctx)
	testing.expect(t, !activated)
	testing.expect_value(t, len(url), 0)
}
