package ui

// g_ui_scale is the current UI scale factor:
//   1.0 = 96 DPI (100 %)
//   1.5 = 144 DPI (150 %)
//   2.0 = 192 DPI (200 % / typical 4K)
// Initialised at startup from the OS DPI (or a persisted user override) and
// may be changed at runtime via the settings panel.
@(private)
g_ui_scale: f32 = 1.0

// set_ui_scale rescales all pixel-dimension variables declared in theme.odin
// to match the given scale factor. Safe to call at runtime; callers that
// change the scale after startup must also call invalidate_scale_caches() and
// reset cached per-message/tool render heights so the new metrics take effect.
// The factor is clamped to [0.5, 3.0].
set_ui_scale :: proc(scale: f32) {
	s := clamp(scale, 0.5, 3.0)
	if s == g_ui_scale do return
	g_ui_scale = s

	// Font sizes.
	FONT_SIZE = i32(16.0 * s + 0.5)
	FONT_SIZE_LARGE = i32(20.0 * s + 0.5)
	FONT_SIZE_SMALL = i32(13.0 * s + 0.5)
	LINE_HEIGHT = i32(22.0 * s + 0.5)

	// Embedded terminal / nvim grid metrics.
	NVIM_FONT_SIZE = i32(16.0 * s + 0.5)
	NVIM_CELL_PAD = i32(6.0 * s + 0.5)
	NVIM_MARGIN = i32(10.0 * s + 0.5)

	// General layout.
	TAB_BAR_HEIGHT = i32(35.0 * s + 0.5)
	CAPTION_BTN_W = i32(46.0 * s + 0.5)
	INPUT_BAR_HEIGHT = i32(50.0 * s + 0.5)
	PADDING = i32(10.0 * s + 0.5)
	TAB_WIDTH = i32(180.0 * s + 0.5)
	TAB_MIN_WIDTH = i32(70.0 * s + 0.5)
	TAB_CLOSE_SIZE = i32(16.0 * s + 0.5)
	TAB_ICON_SIZE = i32(18.0 * s + 0.5)
	COMMAND_ITEM_HEIGHT = i32(28.0 * s + 0.5)
	POPUP_MAX_WIDTH = i32(400.0 * s + 0.5)
	SCROLL_SPEED = 15.0 * s

	// Flat chat messages.
	CHAT_MAX_W = i32(860.0 * s + 0.5)
	MSG_GAP = i32(14.0 * s + 0.5)
	USER_CARD_PAD_H = i32(12.0 * s + 0.5)
	USER_CARD_PAD_V = i32(8.0 * s + 0.5)
	USER_CARD_RADIUS_PX = 8.0 * s
	USER_CARD_MIN_W = i32(48.0 * s + 0.5)

	// Unified panel/list metrics.
	ROW_H_SM = i32(24.0 * s + 0.5)
	ROW_H_MD = i32(28.0 * s + 0.5)
	PANEL_HEADER_H = i32(34.0 * s + 0.5)
	CARD_RADIUS_PX = 6.0 * s

	// Form controls and popups.
	CONTROL_BOX = i32(18.0 * s + 0.5)
	CONTROL_GAP = i32(8.0 * s + 0.5)
	SLIDER_TRACK_H = i32(4.0 * s + 0.5)
	SLIDER_KNOB_R = 7.0 * s
	MENU_ITEM_H = i32(26.0 * s + 0.5)
	MENU_PAD = i32(4.0 * s + 0.5)
	MENU_MIN_W = i32(160.0 * s + 0.5)
	TOOLTIP_PAD = i32(6.0 * s + 0.5)

	// Attachment / drop zone.
	ATTACHMENT_CHIP_ROW_H = i32(28.0 * s + 0.5)
	DROP_ZONE_H = i32(56.0 * s + 0.5)

	// Tool cards and markdown.
	TOOL_BORDER_W = i32(2.0 * s + 0.5)
	TOOL_CARD_PAD_V = i32(4.0 * s + 0.5)
	TOOL_CARD_PAD_H = i32(8.0 * s + 0.5)
	TOOL_CARD_GAP = i32(4.0 * s + 0.5)
	CODE_BLOCK_PAD = i32(8.0 * s + 0.5)
	BULLET_INDENT = i32(20.0 * s + 0.5)
	TABLE_CELL_PAD = i32(8.0 * s + 0.5)

	// Plan sidebar.
	PLAN_SIDEBAR_W = i32(300.0 * s + 0.5)
	PLAN_SIDEBAR_COLLAPSED_W = i32(30.0 * s + 0.5)
	PLAN_SIDEBAR_ROW_H = i32(22.0 * s + 0.5)
	PLAN_TITLE_ACCENT_W = i32(3.0 * s + 0.5)
	PLAN_TITLE_PAD = i32(8.0 * s + 0.5)

	// Debug sidebar.
	DEBUG_SIDEBAR_W = i32(320.0 * s + 0.5)
	DEBUG_SIDEBAR_COLLAPSED_W = i32(30.0 * s + 0.5)
	DEBUG_SIDEBAR_ROW_H = i32(28.0 * s + 0.5)
	DEBUG_TITLE_ACCENT_W = i32(3.0 * s + 0.5)
	DEBUG_TITLE_PAD = i32(8.0 * s + 0.5)

	// Shells panel.
	SHELLS_PANEL_W = i32(360.0 * s + 0.5)

	// Split divider.
	SPLIT_DIVIDER_W = i32(4.0 * s + 0.5)

	// Vortex connecting animation.
	VORTEX_RADIUS = 56.0 * s
	VORTEX_INNER = 12.0 * s

	// Wave-bar animation.
	WAVE_BAR_W = i32(3.0 * s + 0.5)
	WAVE_BAR_GAP = i32(3.0 * s + 0.5)
	WAVE_BAR_MAX_H = i32(18.0 * s + 0.5)
	WAVE_BAR_MIN_H = i32(3.0 * s + 0.5)

	// App-owned view metrics (git/nvim/terminal panels) live outside the
	// library; the host app rescales them via this hook.
	if scale_metrics_hook != nil do scale_metrics_hook(s)
}

// sc scales an integer pixel literal by the current UI scale factor.
// Use for any locally hard-coded pixel value not covered by a theme variable.
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
// scale at runtime. Size-keyed caches (measure_cache, wrap_cache) are flushed
// for memory hygiene; the composer memo and the terminal/nvim cell-width
// caches are reset because their keys omit the font size and would otherwise
// go stale. Per-message/tool render heights are reset separately by the
// caller (they live in the state package).
// scale_metrics_hook lets the host app rescale its own view metrics
// (git/nvim/terminal panels) that live outside the library.
scale_metrics_hook: proc(s: f32)

// scale_invalidate_hook lets the host app clear its own scale-derived caches
// without ingot importing app code.
scale_invalidate_hook: proc()

invalidate_scale_caches :: proc() {
	clear_measure_cache()
	clear_wrap_cache()
	invalidate_input_visual_lines()
	if scale_invalidate_hook != nil do scale_invalidate_hook()
}
