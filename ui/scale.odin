package ui

Ui_Metrics :: struct {
	FONT_SIZE:                 i32,
	FONT_SIZE_LARGE:           i32,
	FONT_SIZE_SMALL:           i32,
	LINE_HEIGHT:               i32,
	FONT_SIZE_TITLE:           i32,
	FONT_SIZE_BODY:            i32,
	FONT_SIZE_LABEL:           i32,
	FONT_SIZE_NOTE:            i32,
	NVIM_FONT_SIZE:            i32,
	NVIM_CELL_PAD:             i32,
	NVIM_MARGIN:               i32,
	TAB_BAR_HEIGHT:            i32,
	CAPTION_BTN_W:             i32,
	INPUT_BAR_HEIGHT:          i32,
	PADDING:                   i32,
	TAB_WIDTH:                 i32,
	TAB_MIN_WIDTH:             i32,
	TAB_CLOSE_SIZE:            i32,
	TAB_ICON_SIZE:             i32,
	COMMAND_ITEM_HEIGHT:       i32,
	POPUP_MAX_WIDTH:           i32,
	SCROLL_SPEED:              f32,
	CHAT_MAX_W:                i32,
	MSG_GAP:                   i32,
	USER_CARD_PAD_H:           i32,
	USER_CARD_PAD_V:           i32,
	USER_CARD_RADIUS_PX:       f32,
	USER_CARD_MIN_W:           i32,
	ROW_H_SM:                  i32,
	ROW_H_MD:                  i32,
	PANEL_HEADER_H:            i32,
	CARD_RADIUS_PX:            f32,
	CONTROL_BOX:               i32,
	CONTROL_GAP:               i32,
	SLIDER_TRACK_H:            i32,
	SLIDER_KNOB_R:             f32,
	MENU_ITEM_H:               i32,
	MENU_PAD:                  i32,
	MENU_MIN_W:                i32,
	TOOLTIP_PAD:               i32,
	ATTACHMENT_CHIP_ROW_H:     i32,
	DROP_ZONE_H:               i32,
	TOOL_BORDER_W:             i32,
	TOOL_CARD_PAD_V:           i32,
	TOOL_CARD_PAD_H:           i32,
	TOOL_CARD_GAP:             i32,
	CODE_BLOCK_PAD:            i32,
	BULLET_INDENT:             i32,
	TABLE_CELL_PAD:            i32,
	PLAN_SIDEBAR_W:            i32,
	PLAN_SIDEBAR_COLLAPSED_W:  i32,
	PLAN_SIDEBAR_ROW_H:        i32,
	PLAN_TITLE_ACCENT_W:       i32,
	PLAN_TITLE_PAD:            i32,
	DEBUG_SIDEBAR_W:           i32,
	DEBUG_SIDEBAR_COLLAPSED_W: i32,
	DEBUG_SIDEBAR_ROW_H:       i32,
	DEBUG_TITLE_ACCENT_W:      i32,
	DEBUG_TITLE_PAD:           i32,
	SHELLS_PANEL_W:            i32,
	SPLIT_DIVIDER_W:           i32,
	VORTEX_RADIUS:             f32,
	VORTEX_INNER:              f32,
	WAVE_BAR_W:                i32,
	WAVE_BAR_GAP:              i32,
	WAVE_BAR_MAX_H:            i32,
	WAVE_BAR_MIN_H:            i32,
}

ui_metrics :: proc(scale: f32) -> Ui_Metrics {
	s := clamp(scale, 0.5, 3.0)
	si :: proc(value, factor: f32) -> i32 {return i32(value * factor + 0.5)}
	return {
		FONT_SIZE = si(16, s),
		FONT_SIZE_LARGE = si(20, s),
		FONT_SIZE_SMALL = si(13, s),
		LINE_HEIGHT = si(22, s),
		FONT_SIZE_TITLE = si(20, s),
		FONT_SIZE_BODY = si(16, s),
		FONT_SIZE_LABEL = si(13, s),
		FONT_SIZE_NOTE = si(11, s),
		NVIM_FONT_SIZE = si(16, s),
		NVIM_CELL_PAD = si(6, s),
		NVIM_MARGIN = si(10, s),
		TAB_BAR_HEIGHT = si(35, s),
		CAPTION_BTN_W = si(46, s),
		INPUT_BAR_HEIGHT = si(50, s),
		PADDING = si(10, s),
		TAB_WIDTH = si(180, s),
		TAB_MIN_WIDTH = si(70, s),
		TAB_CLOSE_SIZE = si(16, s),
		TAB_ICON_SIZE = si(18, s),
		COMMAND_ITEM_HEIGHT = si(28, s),
		POPUP_MAX_WIDTH = si(400, s),
		SCROLL_SPEED = 15 * s,
		CHAT_MAX_W = si(860, s),
		MSG_GAP = si(14, s),
		USER_CARD_PAD_H = si(12, s),
		USER_CARD_PAD_V = si(8, s),
		USER_CARD_RADIUS_PX = 8 * s,
		USER_CARD_MIN_W = si(48, s),
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
		ATTACHMENT_CHIP_ROW_H = si(28, s),
		DROP_ZONE_H = si(56, s),
		TOOL_BORDER_W = si(2, s),
		TOOL_CARD_PAD_V = si(4, s),
		TOOL_CARD_PAD_H = si(8, s),
		TOOL_CARD_GAP = si(4, s),
		CODE_BLOCK_PAD = si(8, s),
		BULLET_INDENT = si(20, s),
		TABLE_CELL_PAD = si(8, s),
		PLAN_SIDEBAR_W = si(300, s),
		PLAN_SIDEBAR_COLLAPSED_W = si(30, s),
		PLAN_SIDEBAR_ROW_H = si(22, s),
		PLAN_TITLE_ACCENT_W = si(3, s),
		PLAN_TITLE_PAD = si(8, s),
		DEBUG_SIDEBAR_W = si(320, s),
		DEBUG_SIDEBAR_COLLAPSED_W = si(30, s),
		DEBUG_SIDEBAR_ROW_H = si(28, s),
		DEBUG_TITLE_ACCENT_W = si(3, s),
		DEBUG_TITLE_PAD = si(8, s),
		SHELLS_PANEL_W = si(360, s),
		SPLIT_DIVIDER_W = si(4, s),
		VORTEX_RADIUS = 56 * s,
		VORTEX_INNER = 12 * s,
		WAVE_BAR_W = si(3, s),
		WAVE_BAR_GAP = si(3, s),
		WAVE_BAR_MAX_H = si(18, s),
		WAVE_BAR_MIN_H = si(3, s),
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
