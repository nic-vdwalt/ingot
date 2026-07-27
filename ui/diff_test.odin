#+build !js
package ui

import "core:testing"

@(test)
diff_hunk_header_accepts_omitted_counts :: proc(t: ^testing.T) {
	old_start, new_start, ok := diff_parse_hunk_header("@@ -12 +34 @@")
	testing.expect(t, ok)
	testing.expect_value(t, old_start, 12)
	testing.expect_value(t, new_start, 34)
}

@(test)
diff_hunk_header_rejects_malformed_numbers :: proc(t: ^testing.T) {
	old_start, new_start, ok := diff_parse_hunk_header("@@ -bad +also-bad @@")
	testing.expect(t, !ok)
	testing.expect_value(t, old_start, 0)
	testing.expect_value(t, new_start, 0)
}

@(test)
unified_diff_parser_handles_crlf_metadata_and_bounds :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)
	parsed := parse_unified_diff(
		&frame,
		"--- a/file\r\n+++ b/file\r\n@@ -1 +1 @@\r\n-old\r\n+new\r\n\\ No newline at end of file\r\n",
		{max_rows = 3},
	)
	rows := frame_view_items(&frame, parsed.rows)
	testing.expect_value(t, len(rows), 3)
	testing.expect(t, parsed.truncated)
	testing.expect_value(t, rows[0].kind, Diff_Row_Kind.Hunk)
	testing.expect_value(t, rows[1].old_no, 1)
	testing.expect_value(t, rows[2].new_no, 1)
}

@(test)
unified_diff_parser_marks_malformed_input :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)
	parsed := parse_unified_diff(&frame, "@@ malformed @@\nraw line\n")
	testing.expect(t, parsed.malformed)
	rows := frame_view_items(&frame, parsed.rows)
	testing.expect_value(t, len(rows), 2)
}
