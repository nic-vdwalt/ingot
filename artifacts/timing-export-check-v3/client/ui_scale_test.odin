package main

import "core:math"
import "core:testing"

@(test)
ui_px_is_identity_at_unit_scale :: proc(t: ^testing.T) {
	testing.expect_value(t, ui_px(1, 150), i32(150))
	testing.expect_value(t, ui_px(1, 0), i32(0))
	testing.expect_value(t, ui_px(1, -8), i32(-8))
}

// The reported Windows bug is exactly this case: a 150 px note slot has to
// grow to 225 px at 150% display scaling or its text escapes the panel.
@(test)
ui_px_rounds_half_away_from_zero :: proc(t: ^testing.T) {
	testing.expect_value(t, ui_px(1.5, 150), i32(225))
	testing.expect_value(t, ui_px(1.25, 150), i32(188))
	testing.expect_value(t, ui_px(1.5, 11), i32(17))
	testing.expect_value(t, ui_px(1.5, -11), i32(-17))
}

// A zero-valued Client_State lays out before the first frame publishes a
// scale, so degenerate factors must not collapse or explode the layout.
@(test)
ui_px_clamps_degenerate_scales :: proc(t: ^testing.T) {
	testing.expect_value(t, ui_px(0, 120), i32(120))
	testing.expect_value(t, ui_px(-2, 120), i32(120))
	testing.expect_value(t, ui_px(math.nan_f32(), 120), i32(120))
	testing.expect_value(t, ui_px(math.inf_f32(1), 120), ui_px(UI_SCALE_MAX, 120))
	testing.expect_value(t, ui_px(10, 120), ui_px(UI_SCALE_MAX, 120))
	testing.expect_value(t, ui_px(0.01, 120), ui_px(UI_SCALE_MIN, 120))
}

@(test)
ui_scale_normalize_passes_through_the_usable_band :: proc(t: ^testing.T) {
	testing.expect_value(t, ui_scale_normalize(1), f32(1))
	testing.expect_value(t, ui_scale_normalize(1.5), f32(1.5))
	testing.expect_value(t, ui_scale_normalize(UI_SCALE_MIN), UI_SCALE_MIN)
	testing.expect_value(t, ui_scale_normalize(UI_SCALE_MAX), UI_SCALE_MAX)
}

// The toolbar must widen with the UI scale, because its text does. Both the
// mode-dependent segment and the whole panel are checked: the panel is what
// the note used to escape from.
@(test)
toolbar_width_grows_with_ui_scale :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	value.toolbar_note_width = 150
	for mode in Mode {
		value.mode = mode
		value.ui_scale = 1
		unit := toolbar_options_width(value)
		value.ui_scale = 1.5
		scaled := toolbar_options_width(value)
		testing.expect(t, scaled > unit, "option segment must widen with the UI scale")
	}
}

// The measured note width feeds the panel width directly; a wider note has
// to make the inspect segment wider or the text has nowhere to go.
@(test)
toolbar_option_segment_follows_measured_note :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	value.ui_scale = 1
	value.mode = .Inspect
	value.toolbar_note_width = 150
	narrow := toolbar_options_width(value)
	value.toolbar_note_width = 400
	wide := toolbar_options_width(value)
	testing.expect(t, wide > narrow, "inspect segment must follow the measured note")
	testing.expect(t, wide >= 400, "inspect segment must fit the measured note")
}

// A zero measurement (first frame, or a caller that never drew the note)
// still has to leave a usable slot rather than collapsing the segment.
@(test)
toolbar_option_segment_has_a_floor :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	value.ui_scale = 1
	value.mode = .Inspect
	value.toolbar_note_width = 0
	testing.expect(
		t,
		toolbar_options_width(value) >= TOOLBAR_NOTE_MIN_WIDTH,
		"inspect segment must keep its minimum width",
	)
}
