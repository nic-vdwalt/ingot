// ui_scale.odin owns the one rule every screen-space UI call site follows.
//
// ingot's UI scale is pinned to 1.0 on macOS and web, but on Windows it is
// the monitor's DPI factor (ingot/ui/dpi.odin): fit's font roles and metrics
// are multiplied by it, while raw pixel constants written in this client are
// not. A 150 px slot that just fits its label at 100% therefore overflows by
// half its width at 150% display scaling, and plain fit.Text never clips.
//
// The convention: layout constants stay authored at scale 1.0 and are
// converted at the call site with ui_px. Font sizes are never re-declared
// here - fit.Text_Size / fit.Text_Line_Height already report the scaled
// values - and text drawn into a fixed box uses fit.Text_Truncated.
package main

import fit "ingot:fit"

// Matches ui_metrics in ingot/ui/scale.odin, so a clamped ui_px result stays
// consistent with the widget metrics fit reports for the same frame.
UI_SCALE_MIN :: f32(0.5)
UI_SCALE_MAX :: f32(3.0)

// ui_scale_normalize keeps a usable factor for any input. A zero-valued
// Client_State (every field is zero before the first frame publishes a scale)
// and any non-finite value fall back to 1: NaN fails every ordered
// comparison, so the `!(scale > 0)` test rejects it along with zero and
// negatives.
ui_scale_normalize :: proc(scale: f32) -> f32 {
	if !(scale > 0) do return 1
	if scale > UI_SCALE_MAX do return UI_SCALE_MAX
	if scale < UI_SCALE_MIN do return UI_SCALE_MIN
	return scale
}

// ui_px converts a layout constant authored at scale 1.0 into device pixels.
// Pure by design: the layout maths stays testable without a live surface.
// Rounds half away from zero, matching ingot's scale_i32.
ui_px :: proc(scale: f32, size: i32) -> i32 {
	scaled := f64(size) * f64(ui_scale_normalize(scale))
	rounded := scaled + (scaled >= 0 ? 0.5 : -0.5)
	assert(rounded >= f64(min(i32)), "ui_px: result below i32 range")
	assert(rounded <= f64(max(i32)), "ui_px: result above i32 range")
	return i32(rounded)
}

// ui_scale_sync republishes the frame's UI scale onto the client state, so
// layout procedures that never see a surface (hit tests, rect computations
// called from input handling) can still scale their constants.
ui_scale_sync :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil, "ui_scale_sync: nil state")
	assert(surface != nil, "ui_scale_sync: nil surface")
	value.ui_scale = fit.Px(surface, f32(1))
}
