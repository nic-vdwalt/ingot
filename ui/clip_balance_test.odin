#+build !js
package ui

// Clip-stack depth and balance.
//
// Two distinct failure modes are covered, and they are deliberately treated
// differently:
//
//   - Exceeding PAINT_CLIP_CAP is a *resource limit*, not an invariant. Alloy
//     nests chat > markdown block > code block > split pane > sidebar, and a
//     deep enough document reaches 64. That must degrade the way command and
//     text overflow already do in this file's sibling paths — drop and count —
//     rather than abort the app.
//
//   - Ending a clip that was never begun, or leaving one open at frame end, is
//     a genuine programmer error: some view took an early return between
//     begin_scissor_mode and end_scissor_mode. That stays loud, and
//     clip_origin names the exact call site that leaked.

import "core:testing"

@(private = "file")
new_list :: proc() -> ^Paint_List {
	return new(Paint_List)
}

@(test)
clip_overflow_is_dropped_and_counted :: proc(t: ^testing.T) {
	list := new_list()
	defer free(list)
	// Fill to capacity, then push well past it.
	for i in 0 ..< PAINT_CLIP_CAP {
		paint_clip_begin(list, {f32(i), f32(i), 100, 100})
	}
	testing.expect_value(t, list.clip_count, PAINT_CLIP_CAP)
	before_drops := list.dropped_commands

	overflow :: 16
	for i in 0 ..< overflow {
		paint_clip_begin(list, {f32(i), f32(i), 50, 50})
	}
	// Depth must not grow past the cap, and every rejected clip must be
	// counted so the overflow is visible rather than silent.
	testing.expect_value(t, list.clip_count, PAINT_CLIP_CAP)
	testing.expect_value(t, list.dropped_commands, before_drops + overflow)

	// The matching ends must unwind cleanly: a dropped begin must not consume
	// a real stack slot, or the frame can never balance again.
	for _ in 0 ..< overflow do paint_clip_end(list)
	testing.expect_value(t, list.clip_count, PAINT_CLIP_CAP)
	for _ in 0 ..< PAINT_CLIP_CAP do paint_clip_end(list)
	testing.expect_value(t, list.clip_count, 0)
}

@(test)
clip_overflow_keeps_the_outer_clip_effective :: proc(t: ^testing.T) {
	// Dropping the innermost clips must never *widen* the clip region: the
	// outermost clip still has to bound the drawing, or overflow would leak
	// pixels outside the pane.
	list := new_list()
	defer free(list)
	paint_clip_begin(list, {10, 10, 100, 100})
	for _ in 1 ..< PAINT_CLIP_CAP {
		paint_clip_begin(list, {10, 10, 100, 100})
	}
	paint_clip_begin(list, {0, 0, 1000, 1000}) // dropped
	testing.expect_value(t, list.clip_stack[list.clip_count - 1], Rect{10, 10, 100, 100})
	for _ in 0 ..< PAINT_CLIP_CAP + 1 do paint_clip_end(list)
	testing.expect_value(t, list.clip_count, 0)
}

@(test)
clip_end_without_begin_is_ignored :: proc(t: ^testing.T) {
	// An unmatched end must not drive the depth negative, which would turn one
	// view's bug into an out-of-bounds index in the next.
	list := new_list()
	defer free(list)
	paint_clip_end(list)
	testing.expect_value(t, list.clip_count, 0)
	paint_clip_begin(list, {0, 0, 10, 10})
	paint_clip_end(list)
	paint_clip_end(list)
	testing.expect_value(t, list.clip_count, 0)
}

@(test)
clip_depth_is_zero_after_a_balanced_frame :: proc(t: ^testing.T) {
	runtime := new(Ui_Runtime)
	defer free(runtime)
	ui_runtime_init(runtime)
	defer ui_runtime_destroy(runtime)
	output := new(Ui_Output)
	defer free(output)
	frame := new(Ui_Frame)
	defer free(frame)
	frame.output = output

	ui_frame_begin(frame, runtime)
	begin_scissor_mode(frame, 0, 0, 100, 100)
	begin_scissor_mode(frame, 10, 10, 50, 50)
	end_scissor_mode(frame)
	end_scissor_mode(frame)
	testing.expect_value(t, frame.output.main.clip_count, 0)
	ui_frame_end(frame)
}

@(test)
clip_depth_survives_degenerate_scissor_rects :: proc(t: ^testing.T) {
	// A pane clipped to nothing is what a collapsed sidebar produces. The clip
	// must still push and pop so the stack stays balanced.
	runtime := new(Ui_Runtime)
	defer free(runtime)
	ui_runtime_init(runtime)
	defer ui_runtime_destroy(runtime)
	output := new(Ui_Output)
	defer free(output)
	frame := new(Ui_Frame)
	defer free(frame)
	frame.output = output

	ui_frame_begin(frame, runtime)
	begin_scissor_mode(frame, 0, 0, 0, 0)
	end_scissor_mode(frame)
	begin_scissor_mode(frame, 0, 0, -10, -10)
	end_scissor_mode(frame)
	testing.expect_value(t, frame.output.main.clip_count, 0)
	ui_frame_end(frame)
}

@(test)
clip_overflow_within_a_frame_still_balances :: proc(t: ^testing.T) {
	// End-to-end: a frame that nests past the cap must still finalize, because
	// ui_frame_finalize asserts a zero depth and that assertion is the one we
	// keep.
	runtime := new(Ui_Runtime)
	defer free(runtime)
	ui_runtime_init(runtime)
	defer ui_runtime_destroy(runtime)
	output := new(Ui_Output)
	defer free(output)
	frame := new(Ui_Frame)
	defer free(frame)
	frame.output = output

	ui_frame_begin(frame, runtime)
	depth :: PAINT_CLIP_CAP + 8
	for i in 0 ..< depth {
		begin_scissor_mode(frame, i32(i), i32(i), 100, 100)
	}
	for _ in 0 ..< depth {
		end_scissor_mode(frame)
	}
	testing.expect_value(t, frame.output.main.clip_count, 0)
	testing.expect(t, output.main.dropped_commands > 0, "overflow must be recorded")
	ui_frame_end(frame)
}

@(test)
clip_leak_origin_names_the_open_clip :: proc(t: ^testing.T) {
	// The whole point of tracking origins: the depth alone does not say which
	// view forgot to pop.
	list := new_list()
	defer free(list)
	paint_clip_begin(list, {0, 0, 10, 10})
	origin := paint_clip_leak_origin(list)
	testing.expect(t, origin.line > 0, "leak origin must carry a source line")
	paint_clip_end(list)
}
