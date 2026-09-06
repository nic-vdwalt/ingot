#+build !js
package ui

// Viewport culling for widget painting.
//
// A scrollable Pane pushes a GPU scissor, so off-screen widgets were always
// *invisible* - but every one of them still built its geometry, copied it into
// the stream shadow buffer, and uploaded it, only for the rasteriser to throw
// it away. The gallery's 1000-button stress grid made that roughly 11 MB of
// vertex data per frame for ~25 visible buttons.
//
// pane_begin now narrows the frame's cull band to the pane's visible rows and
// pane_end restores it, so leaf painters can skip that work. These tests pin
// the three properties that make the optimisation safe:
//
//   1. Off-screen widgets emit no paint commands.
//   2. Widgets straddling an edge still paint in full - partial visibility is
//      exactly where an over-eager cull shows up as clipped controls.
//   3. Interaction, focus, and semantics are unaffected: a scrolled-away
//      control keeps its identity, tab order, and screen-reader record.
//
// Nesting is covered too, since a pane inside a pane must not widen the band
// its parent narrowed.

import "core:testing"

@(private = "file")
cull_frame :: proc(
	runtime: ^Ui_Runtime,
	frame: ^Ui_Frame,
	output: ^Ui_Output,
	text_backend: ^Test_Text_Backend_State,
) {
	assert(runtime != nil && frame != nil, "cull_frame: nil argument")
	assert(output != nil && text_backend != nil, "cull_frame: nil argument")
	ui_runtime_init(runtime)
	ui_runtime_set_text_backend(
		runtime,
		{
			data = text_backend,
			font_for_size = test_text_font_for_size,
			measure = test_text_measure,
		},
	)
	sem_enable(runtime, true)
	frame.output = output
	ui_frame_begin(frame, runtime)
}

// PANE is the visible viewport every test scrolls content through.
@(private = "file")
PANE :: Rect_I32{0, 100, 400, 200}

@(test)
rect_culled_frame_bounds_the_band :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	cull_frame(&runtime, &frame, output, &text_backend)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	// No band set: nothing is ever culled, which is the pre-existing
	// behaviour every non-pane caller still relies on.
	testing.expect(t, !rect_culled_frame(&frame, {0, -10_000, 50, 20}))
	testing.expect(t, !rect_culled_frame(&frame, {0, 10_000, 50, 20}))

	set_text_cull_band_frame(&frame, 100, 300)
	// Fully above and fully below.
	testing.expect(t, rect_culled_frame(&frame, {0, 40, 50, 20}))
	testing.expect(t, rect_culled_frame(&frame, {0, 340, 50, 20}))
	// Inside.
	testing.expect(t, !rect_culled_frame(&frame, {0, 150, 50, 20}))
	// Straddling either edge, and exactly touching either edge: all visible.
	testing.expect(t, !rect_culled_frame(&frame, {0, 90, 50, 20}))
	testing.expect(t, !rect_culled_frame(&frame, {0, 290, 50, 20}))
	testing.expect(t, !rect_culled_frame(&frame, {0, 80, 50, 20}))
	testing.expect(t, !rect_culled_frame(&frame, {0, 300, 50, 20}))
	// A degenerate rect is never culled: callers already special-case those
	// and silently dropping them would be a behaviour change.
	testing.expect(t, !rect_culled_frame(&frame, {0, -500, 50, 0}))

	clear_text_cull_band_frame(&frame)
	testing.expect(t, !rect_culled_frame(&frame, {0, -10_000, 50, 20}))
}

@(test)
pane_culls_offscreen_widget_painting :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	cull_frame(&runtime, &frame, output, &text_backend)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	pane: Pane
	_ = pane_begin(&frame, &pane, PANE)
	before := frame.output.main.count
	// Far below the pane's 100..300 band: the scissor would discard it.
	_ = button_at(&frame, {10, 5_000, 100, 24}, "offscreen")
	culled_commands := frame.output.main.count - before

	visible_before := frame.output.main.count
	_ = button_at(&frame, {10, 150, 100, 24}, "visible")
	visible_commands := frame.output.main.count - visible_before
	pane_end(&frame, &pane, PANE, 5_100)

	testing.expect_value(t, culled_commands, 0)
	testing.expect(t, visible_commands > 0)
}

@(test)
pane_paints_widgets_straddling_the_edges :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	cull_frame(&runtime, &frame, output, &text_backend)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	pane: Pane
	_ = pane_begin(&frame, &pane, PANE)
	// Half above the top edge: an over-eager cull would clip this control,
	// which is the visible symptom this test exists to catch.
	top_before := frame.output.main.count
	_ = button_at(&frame, {10, 88, 100, 24}, "top straddle")
	top_commands := frame.output.main.count - top_before

	bottom_before := frame.output.main.count
	_ = button_at(&frame, {10, 288, 100, 24}, "bottom straddle")
	bottom_commands := frame.output.main.count - bottom_before
	pane_end(&frame, &pane, PANE, 320)

	testing.expect(t, top_commands > 0)
	testing.expect(t, bottom_commands > 0)
}

@(test)
culled_widgets_keep_semantics_and_focus :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	cull_frame(&runtime, &frame, output, &text_backend)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	// Culling is a painting decision only. Assistive tech reads the semantic
	// buffer, and Tab order walks the focus registry - both must contain the
	// off-screen button exactly as they would if it were visible.
	focus_slot: int
	pane: Pane
	_ = pane_begin(&frame, &pane, PANE)
	_ = button_at(&frame, {10, 5_000, 100, 24}, "offscreen", focus = {&focus_slot, 1})
	pane_end(&frame, &pane, PANE, 5_100)

	testing.expect_value(t, frame.semantics.cur.count, 1)
	testing.expect_value(t, frame.semantics.cur.nodes[0].role, Sem_Role.Button)
	testing.expect_value(t, sem_node_label(&frame.semantics.cur.nodes[0]), "offscreen")
	testing.expect_value(t, frame.semantics.focus_cur.count, 1)
}

@(test)
nested_panes_restore_the_outer_cull_band :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	cull_frame(&runtime, &frame, output, &text_backend)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	outer: Pane
	inner: Pane
	_ = pane_begin(&frame, &outer, PANE)
	testing.expect_value(t, frame.text_cull_top, i32(100))
	testing.expect_value(t, frame.text_cull_bottom, i32(300))

	// An inner pane taller than its parent must not widen the band: content
	// outside the outer pane is still invisible, so it must still be culled.
	INNER :: Rect_I32{0, 50, 400, 600}
	_ = pane_begin(&frame, &inner, INNER)
	testing.expect(t, frame.text_cull_top >= 100)
	testing.expect(t, frame.text_cull_bottom <= 300)
	pane_end(&frame, &inner, INNER, 120)

	// The outer band is back exactly as it was.
	testing.expect_value(t, frame.text_cull_top, i32(100))
	testing.expect_value(t, frame.text_cull_bottom, i32(300))
	pane_end(&frame, &outer, PANE, 320)

	// And the frame's default band is restored once the outermost pane ends,
	// so a later non-pane draw is never culled.
	testing.expect_value(t, frame.text_cull_top, min(i32))
	testing.expect_value(t, frame.text_cull_bottom, max(i32))
}
