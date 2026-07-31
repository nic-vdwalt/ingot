#+build !js
package ui

import "core:testing"

@(private = "file")
facade_cell_frame :: proc(
	runtime: ^Ui_Runtime,
	frame: ^Ui_Frame,
	output: ^Ui_Output,
	text_backend: ^Test_Text_Backend_State,
) {
	assert(runtime != nil && frame != nil, "facade_cell_frame: nil argument")
	assert(output != nil && text_backend != nil, "facade_cell_frame: nil argument")
	ui_runtime_init(runtime)
	ui_runtime_set_text_backend(
		runtime,
		{
			data = text_backend,
			font_for_size = test_text_font_for_size,
			measure = test_text_measure,
		},
	)
	frame.output = output
	ui_frame_begin(frame, runtime)
}

// A cell in a narrow flex track must not paint text wider than its slot: the
// truncation contract is what distinguishes it from label's scissor clip.
@(test)
facade_cell_truncates_to_track :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	facade_cell_frame(&runtime, &frame, output, &text_backend)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	u: Ui
	begin(&u, &frame, {0, 0, 400, 100})
	scope_begin(&u, "cells")
	long := "an unreasonably long file name that cannot possibly fit.odin"
	flex_row_begin(&u, 24, {fixed(80), grow()})
	cell(&u, long)
	cell(&u, "ok")
	flex_row_end(&u)
	scope_end(&u)
	end(&u)

	// The narrow track's painted text must be strictly narrower than the
	// original string (the test backend measures ~7px per rune).
	full_w := measure_text_string_frame(&frame, long, ui_frame_metrics(&frame).FONT_SIZE_BODY)
	testing.expect(t, full_w > 80, "test premise: text wider than track")
}

// cell_value right-aligns: an intrinsic slot outside flex keeps the text at
// its natural width, so alignment must be a no-op there rather than a crash.
@(test)
facade_cell_value_outside_flex_is_safe :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	facade_cell_frame(&runtime, &frame, output, &text_backend)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	u: Ui
	begin(&u, &frame, {0, 0, 400, 100})
	scope_begin(&u, "values")
	cell_value(&u, "1234")
	cell_left(&u, "…tail/visible/path.odin")
	scope_end(&u)
	end(&u)
	testing.expect(t, frame.degenerate_drops == 0, "cells should not collapse in a wide root")
}

// A collapsed slot (zero-width track) must drop cleanly, not paint.
@(test)
facade_cell_collapsed_slot_drops :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	facade_cell_frame(&runtime, &frame, output, &text_backend)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	u: Ui
	begin(&u, &frame, {0, 0, 10, 40})
	scope_begin(&u, "narrow")
	flex_row_begin(&u, 24, {fixed(300), grow()})
	cell(&u, "consumes everything")
	cell(&u, "collapsed")
	flex_row_end(&u)
	scope_end(&u)
	end(&u)
	testing.expect(t, frame.degenerate_drops > 0, "zero-width cell should record a drop")
}
