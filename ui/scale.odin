package ui

// Four type sizes, named by role. There is deliberately no second name for
// any size: duplicate aliases let call sites drift apart while looking
// intentional, which is how on-map and off-map widgets ended up disagreeing.
Ui_Metrics :: struct {
	FONT_SIZE_TITLE: i32,
	FONT_SIZE_BODY:  i32,
	FONT_SIZE_LABEL: i32,
	FONT_SIZE_NOTE:  i32,
	LINE_HEIGHT:     i32,
	TAB_BAR_HEIGHT:  i32,
	CAPTION_BTN_W:   i32,
	PADDING:         i32,
	ROW_H_SM:        i32,
	ROW_H_MD:        i32,
	PANEL_HEADER_H:  i32,
	CARD_RADIUS_PX:  f32,
	CONTROL_BOX:     i32,
	CONTROL_GAP:     i32,
	SLIDER_TRACK_H:  i32,
	SLIDER_KNOB_R:   f32,
	MENU_ITEM_H:     i32,
	MENU_PAD:        i32,
	MENU_MIN_W:      i32,
	TOOLTIP_PAD:     i32,
	CODE_BLOCK_PAD:  i32,
	BULLET_INDENT:   i32,
	TABLE_CELL_PAD:  i32,
	SPLIT_DIVIDER_W: i32,
}

ui_metrics :: proc(scale: f32) -> Ui_Metrics {
	s := clamp(scale, 0.5, 3.0)
	si :: proc(value, factor: f32) -> i32 {return i32(value * factor + 0.5)}
	return {
		FONT_SIZE_TITLE = si(20, s),
		FONT_SIZE_BODY = si(16, s),
		FONT_SIZE_LABEL = si(13, s),
		FONT_SIZE_NOTE = si(11, s),
		LINE_HEIGHT = si(22, s),
		TAB_BAR_HEIGHT = si(35, s),
		CAPTION_BTN_W = si(46, s),
		PADDING = si(10, s),
		ROW_H_SM = si(24, s),
		ROW_H_MD = si(28, s),
		PANEL_HEADER_H = si(34, s),
		CARD_RADIUS_PX = 6 * s,
		CONTROL_BOX = si(18, s),
		CONTROL_GAP = si(8, s),
		SLIDER_TRACK_H = si(4, s),
		SLIDER_KNOB_R = 7 * s,
		MENU_ITEM_H = si(26, s),
		MENU_PAD = si(4, s),
		MENU_MIN_W = si(160, s),
		TOOLTIP_PAD = si(6, s),
		CODE_BLOCK_PAD = si(8, s),
		BULLET_INDENT = si(20, s),
		TABLE_CELL_PAD = si(8, s),
		SPLIT_DIVIDER_W = si(4, s),
	}
}

ui_runtime_scale :: proc(runtime: ^Ui_Runtime) -> f32 {
	assert(runtime != nil && runtime.initialized)
	return runtime.scale
}

ui_runtime_metrics :: proc(runtime: ^Ui_Runtime) -> ^Ui_Metrics {
	assert(runtime != nil && runtime.initialized)
	return &runtime.metrics
}

ui_runtime_sc :: proc(runtime: ^Ui_Runtime, value: i32) -> i32 {
	assert(runtime != nil && runtime.initialized)
	return i32(f32(value) * runtime.scale + 0.5)
}

ui_runtime_scf :: proc(runtime: ^Ui_Runtime, value: f32) -> f32 {
	assert(runtime != nil && runtime.initialized)
	return value * runtime.scale
}

ui_runtime_invalidate_scale_caches :: proc(runtime: ^Ui_Runtime) {
	assert(runtime != nil && runtime.initialized)
	clear_measure_cache_with(&runtime.text)
	clear_wrap_cache_with(&runtime.text)
	if runtime.scale_invalidate_hook != nil do runtime.scale_invalidate_hook()
}
