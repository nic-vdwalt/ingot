// LIB-CANDIDATE: imports only core:* and vendor:raylib.
package ui

// g_ui_scale is the current UI scale factor:
//   1.0 = 96 DPI (100 %), 2.0 = 192 DPI (200 % / typical 4K).
@(private)
g_ui_scale: f32 = 1.0

// set_ui_scale rescales all pixel-dimension variables declared in theme.odin.
// Safe to call at runtime; callers that change the scale after startup must
// also call invalidate_scale_caches(). Clamped to [0.5, 3.0].
set_ui_scale :: proc(scale: f32) {
	s := clamp(scale, 0.5, 3.0)
	if s == g_ui_scale do return
	g_ui_scale = s

	// Font sizes.
	FONT_SIZE       = i32(16.0 * s + 0.5)
	FONT_SIZE_LARGE = i32(20.0 * s + 0.5)
	FONT_SIZE_SMALL = i32(13.0 * s + 0.5)
	LINE_HEIGHT     = i32(22.0 * s + 0.5)

	// General layout.
	PADDING          = i32(10.0 * s + 0.5)
	INPUT_BAR_HEIGHT = i32(50.0 * s + 0.5)
	SCROLL_SPEED     = 15.0 * s

	// Unified panel/list metrics.
	ROW_H_SM       = i32(24.0 * s + 0.5)
	ROW_H_MD       = i32(32.0 * s + 0.5)
	PANEL_HEADER_H = i32(48.0 * s + 0.5)
	CARD_RADIUS_PX = 6.0 * s

	// Markdown.
	CODE_BLOCK_PAD = i32(8.0 * s + 0.5)
	BULLET_INDENT  = i32(20.0 * s + 0.5)
	TABLE_CELL_PAD = i32(8.0 * s + 0.5)
}

// sc scales an integer pixel literal by the current UI scale factor.
sc :: proc(x: i32) -> i32 {
	return i32(f32(x) * g_ui_scale + 0.5)
}

// scf scales a float pixel literal by the current UI scale factor.
scf :: proc(x: f32) -> f32 {
	return x * g_ui_scale
}

// ui_scale returns the current DPI scale factor (1.0 = standard 96 DPI).
ui_scale :: proc() -> f32 {
	return g_ui_scale
}

// invalidate_scale_caches drops every cache whose contents depend on the UI
// scale (font sizes / layout metrics). Call after set_ui_scale() changes the
// scale at runtime.
invalidate_scale_caches :: proc() {
	clear_measure_cache()
	clear_wrap_cache()
	invalidate_input_visual_lines()
}
