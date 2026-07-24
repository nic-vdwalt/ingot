#+build !js
package ui

import "core:mem"
import "core:strings"
import "core:testing"

@(test)
input_box_zero_value_is_usable :: proc(t: ^testing.T) {
	b: Input_Box
	strings.write_string(&b.sb, "hi")
	testing.expect_value(t, input_box_text(&b), "hi")
	input_box_destroy(&b)
}

@(test)
input_box_init_destroy_leak_free :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		b: Input_Box
		input_box_init(&b)
		strings.write_string(&b.sb, "some text that allocates")
		append(&b.st.pills, Mention_Span{0, 4})
		input_undo_record(&b.st.undo, input_box_text(&b), 4, b.st.pills[:], .Insert, 0)
		input_box_destroy(&b)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
input_box_reset_clears_but_keeps_capacity :: proc(t: ^testing.T) {
	b: Input_Box
	defer input_box_destroy(&b)
	strings.write_string(&b.sb, "hello world")
	b.st.cursor = 5
	append(&b.st.pills, Mention_Span{0, 5})
	input_undo_record(&b.st.undo, "hello world", 5, b.st.pills[:], .Insert, 0)
	cap_before := cap(b.sb.buf)
	input_box_reset(&b)
	testing.expect_value(t, input_box_text(&b), "")
	testing.expect_value(t, b.st.cursor, 0)
	testing.expect_value(t, len(b.st.pills), 0)
	testing.expect_value(t, len(b.st.undo.undo), 0)
	testing.expect(t, !b.st.sel.active)
	testing.expect(t, !b.st.memo.valid)
	testing.expect_value(t, cap(b.sb.buf), cap_before)
}

@(test)
input_box_destroy_is_idempotent :: proc(t: ^testing.T) {
	b: Input_Box
	strings.write_string(&b.sb, "owned text")
	input_box_destroy(&b)
	input_box_destroy(&b)
	testing.expect_value(t, input_box_text(&b), "")
}

@(test)
input_box_reset_clears_wrapped_line_memo :: proc(t: ^testing.T) {
	b: Input_Box
	defer input_box_destroy(&b)
	system: Text_System
	defer text_system_destroy(&system)
	strings.write_string(&b.sb, "wrapped text")
	input_visual_lines_memo_with(&system, &b.st.memo, input_box_text(&b), 40, 16)
	testing.expect(t, b.st.memo.valid)
	input_box_reset(&b)
	testing.expect(t, !b.st.memo.valid)
	testing.expect_value(t, b.st.memo.text, "")
}
