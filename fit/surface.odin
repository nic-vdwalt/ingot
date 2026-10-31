package fit

import "ingot:ui"

Surface_Performance :: struct {
	markdown_preparations: u64,
	markdown_layout_walks: u64,
	scratch_allocations:   u64,
	scratch_bytes:         u64,
	measure_cache_hits:    u64,
	measure_cache_misses:  u64,
}

surface_performance_snapshot :: proc(surface: ^Surface) -> Surface_Performance {
	assert(surface != nil, "fit.surface_performance_snapshot: nil surface")
	widget := surface_ui(surface)
	assert(widget.frame != nil && widget.frame.open)
	frame := widget.frame
	hits, misses, _ := ui.measure_cache_telemetry_with(ui.ui_frame_text(frame))
	return {
		markdown_preparations = frame.markdown_telemetry.preparations,
		markdown_layout_walks = frame.markdown_telemetry.layout_walks,
		scratch_allocations = frame.scratch.allocation_count,
		scratch_bytes = frame.scratch.allocation_request_bytes +
		frame.scratch.resize_request_bytes,
		measure_cache_hits = hits,
		measure_cache_misses = misses,
	}
}

surface_viewport :: proc(surface: ^Surface) -> Rect {
	u := surface_ui(surface)
	return ui.frame_viewport(u.frame)
}

surface_pane_origin :: proc(surface: ^Surface) -> Point {
	u := surface_ui(surface)
	return from_point(ui.frame_pane_origin(u.frame))
}

surface_scale :: proc(surface: ^Surface, value: i32) -> i32 {
	u := surface_ui(surface)
	return ui.ui_frame_sc(u.frame, value)
}

surface_scale_float :: proc(surface: ^Surface, value: f32) -> f32 {
	u := surface_ui(surface)
	return ui.ui_frame_scf(u.frame, value)
}

px :: proc {
	surface_scale,
	surface_scale_float,
}

surface_cull_bounds :: proc(surface: ^Surface) -> (top, bottom: i32) {
	u := surface_ui(surface)
	return u.frame.text_cull_top, u.frame.text_cull_bottom
}

surface_metrics :: proc(surface: ^Surface) -> Metrics {
	u := surface_ui(surface)
	metrics := ui.ui_frame_metrics(u.frame)
	// Callers drawing their own geometry read card_radius directly, so it
	// must agree with radius_pixels under a square-cornered theme.
	card_radius := metrics.CARD_RADIUS_PX
	if ui.ui_frame_theme(u.frame).square_corners do card_radius = 0
	return {
		font_title = metrics.FONT_SIZE_TITLE,
		font_body = metrics.FONT_SIZE_BODY,
		font_label = metrics.FONT_SIZE_LABEL,
		font_note = metrics.FONT_SIZE_NOTE,
		line_height = metrics.LINE_HEIGHT,
		tab_bar_height = metrics.TAB_BAR_HEIGHT,
		caption_button_w = metrics.CAPTION_BTN_W,
		padding = metrics.PADDING,
		row_small = metrics.ROW_H_SM,
		row_medium = metrics.ROW_H_MD,
		panel_header_h = metrics.PANEL_HEADER_H,
		card_radius = card_radius,
		control_box = metrics.CONTROL_BOX,
		control_gap = metrics.CONTROL_GAP,
		slider_track_h = metrics.SLIDER_TRACK_H,
		slider_knob_radius = metrics.SLIDER_KNOB_R,
		menu_item_h = metrics.MENU_ITEM_H,
		menu_padding = metrics.MENU_PAD,
		menu_min_w = metrics.MENU_MIN_W,
		tooltip_padding = metrics.TOOLTIP_PAD,
		code_block_padding = metrics.CODE_BLOCK_PAD,
		bullet_indent = metrics.BULLET_INDENT,
		table_cell_padding = metrics.TABLE_CELL_PAD,
		split_divider_w = metrics.SPLIT_DIVIDER_W,
	}
}

surface_theme :: proc(surface: ^Surface) -> Theme {
	u := surface_ui(surface)
	return {inner = ui.ui_frame_theme(u.frame)^}
}

surface_theme_tokens :: proc(surface: ^Surface) -> Theme_Tokens {
	return theme_tokens(surface_theme(surface).inner)
}

@(private = "package")
theme_tokens :: proc(theme: ui.Theme) -> Theme_Tokens {
	return {
		background_app = Color(theme.bg_app),
		background_chat = Color(theme.bg_chat),
		background_panel = Color(theme.bg_panel),
		background_color = Color(theme.bg_color),
		background_secondary = Color(theme.bg_secondary),
		background_active = Color(theme.bg_active),
		background_hover = Color(theme.bg_hover),
		background_input = Color(theme.bg_input),
		background_code = Color(theme.bg_code),
		background_popup = Color(theme.bg_popup),
		background_selection = Color(theme.bg_selection),
		background_plan_bar = Color(theme.bg_plan_bar),
		background_plan_title = Color(theme.bg_plan_title),
		background_tool_card = Color(theme.bg_tool_card),
		background_tool_card_hover = Color(theme.bg_tool_card_hover),
		background_diff_add = Color(theme.bg_diff_add),
		background_diff_remove = Color(theme.bg_diff_remove),
		background_debug_title = Color(theme.bg_debug_title),
		background_chip = Color(theme.bg_chip),
		background_chip_hover = Color(theme.bg_chip_hover),
		background_user_card = Color(theme.bg_user_card),
		background_band_error = Color(theme.bg_band_error),
		modal_dim = Color(theme.modal_dim),
		foreground_primary = Color(theme.fg_primary),
		foreground_secondary = Color(theme.fg_secondary),
		foreground_accent = Color(theme.fg_accent),
		foreground_user = Color(theme.fg_user),
		foreground_assistant = Color(theme.fg_assistant),
		foreground_error = Color(theme.fg_error),
		foreground_success = Color(theme.fg_success),
		foreground_tool = Color(theme.fg_tool),
		foreground_diff_remove = Color(theme.fg_diff_remove),
		foreground_diff_add = Color(theme.fg_diff_add),
		foreground_diff_gutter = Color(theme.fg_diff_gutter),
		foreground_disabled = Color(theme.fg_disabled),
		foreground_plan = Color(theme.fg_plan),
		foreground_planning = Color(theme.fg_planning),
		foreground_heading = Color(theme.fg_heading),
		foreground_debug = Color(theme.fg_debug),
		foreground_debug_changed = Color(theme.fg_debug_changed),
		foreground_debug_annotation = Color(theme.fg_debug_annotation),
		foreground_label = Color(theme.fg_label),
		border = Color(theme.border_color),
		border_subtle = Color(theme.border_subtle),
		border_user_card = Color(theme.border_user_card),
		badge = Color(theme.badge_color),
		merge_link = Color(theme.merge_link_color),
		button_background = Color(theme.button_bg),
		button_hover = Color(theme.button_hover),
		wave_a = Color(theme.wave_color_a),
		wave_b = Color(theme.wave_color_b),
		drop_zone_background = Color(theme.drop_zone_bg),
		drop_zone_border = Color(theme.drop_zone_border),
		paper_rule = Color(theme.paper_rule),
		paper_tooth = Color(theme.paper_tooth),
		graphite = Color(theme.graphite),
		chalk = Color(theme.chalk),
		highlighter = Color(theme.highlighter),
		tape = Color(theme.tape_color),
		substrate = theme.substrate.kind,
		margin_rule = theme.substrate.margin_rule,
		square_corners = theme.square_corners,
		font_face = theme.font_face,
		reading_font_face = theme.reading_font_face,
		surface_style = theme.surface_style,
		bevel_light = Color(theme.bevel_light),
		bevel_shade = Color(theme.bevel_shade),
	}
}

surface_theme_color :: proc(surface: ^Surface, ink: Ink) -> Color {
	u := surface_ui(surface)
	return Color(ui.text_ink(u.frame, ink))
}

surface_resolve_colors :: proc(
	surface: ^Surface,
	kind: Surface_Kind,
	state: Visual_State = .Rest,
) -> Surface_Colors {
	u := surface_ui(surface)
	colors := ui.surface_colors(u.frame, kind, state)
	return {Color(colors.bg), Color(colors.fg), Color(colors.border)}
}

surface_pigment :: proc(surface: ^Surface, pigment: Pigment) -> Color {
	theme := surface_theme(surface)
	return theme_pigment(theme, pigment)
}

surface_space :: proc(surface: ^Surface, space: Space) -> i32 {
	u := surface_ui(surface)
	return ui.space_pixels(u.frame, space)
}

surface_text_size :: proc(surface: ^Surface, role: Text_Role) -> i32 {
	u := surface_ui(surface)
	return ui.text_role_size(u.frame, role)
}

surface_text_line_height :: proc(surface: ^Surface, role: Text_Role) -> i32 {
	u := surface_ui(surface)
	return ui.text_role_line_height(u.frame, role)
}

surface_text_metrics :: proc(surface: ^Surface, font_size: i32) -> (Text_Metrics, bool) {
	assert(surface != nil, "fit.surface_text_metrics: nil surface")
	assert(font_size > 0, "fit.surface_text_metrics: invalid size")
	u := surface_ui(surface)
	metrics, ok := ui.text_metrics_for_size_frame(u.frame, font_size)
	if !ok do return {}, false
	return {
			ascent = metrics.ascent,
			descent = metrics.descent,
			line_gap = metrics.line_gap,
			line_advance = metrics.line_advance,
		},
		true
}

caret_blink_phase :: proc(
	now: f64,
	epoch: f64,
	interval_seconds: f64,
	reduced_motion: bool,
) -> Caret_Blink {
	blink := ui.caret_blink_phase(now, epoch, interval_seconds, reduced_motion)
	return {
		visible = blink.visible,
		seconds_until_toggle = blink.seconds_until_toggle,
		animate = blink.animate,
	}
}

caret_metrics_or_fallback :: proc(
	metrics: Text_Metrics,
	metrics_ok: bool,
	font_size: f32,
	line_advance: f32,
) -> Text_Metrics {
	resolved := ui.caret_metrics_or_fallback(
		{
			ascent = metrics.ascent,
			descent = metrics.descent,
			line_gap = metrics.line_gap,
			line_advance = metrics.line_advance,
		},
		metrics_ok,
		font_size,
		line_advance,
	)
	return {
		ascent = resolved.ascent,
		descent = resolved.descent,
		line_gap = resolved.line_gap,
		line_advance = resolved.line_advance,
	}
}

caret_rect :: proc(
	line_origin: Point,
	caret_x: f32,
	metrics: Text_Metrics,
	width: f32,
) -> Float_Rect {
	rect := ui.caret_rect(
		{line_origin.x, line_origin.y},
		caret_x,
		{
			ascent = metrics.ascent,
			descent = metrics.descent,
			line_gap = metrics.line_gap,
			line_advance = metrics.line_advance,
		},
		width,
	)
	return {rect.x, rect.y, rect.width, rect.height}
}

surface_reduced_motion :: proc(surface: ^Surface) -> bool {
	u := surface_ui(surface)
	return ui.ui_frame_theme(u.frame).reduced_motion
}

surface_text_width :: proc(surface: ^Surface, text: string, role: Text_Role = .Body) -> i32 {
	u := surface_ui(surface)
	return ui.text_width(u.frame, text, role)
}

surface_text :: proc(
	surface: ^Surface,
	text: string,
	x, y: i32,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) {
	u := surface_ui(surface)
	ui.text(u.frame, text, x, y, role, ink)
}

surface_text_truncated :: proc(
	surface: ^Surface,
	text: string,
	x, y, width: i32,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) {
	u := surface_ui(surface)
	ui.text_truncated(u.frame, text, x, y, width, role, ink)
}

surface_text_wrapped :: proc(
	surface: ^Surface,
	text: string,
	x, y, width: i32,
	color: Color,
	font_size, line_height: i32,
) {
	u := surface_ui(surface)
	ui.draw_text_wrapped_frame(u.frame, x, y, width, text, ui.Color(color), font_size, line_height)
}

surface_text_wrapped_height :: proc(
	surface: ^Surface,
	text: string,
	width, font_size, line_height: i32,
) -> i32 {
	assert(surface != nil)
	assert(width > 0 && font_size > 0 && line_height > 0)
	u := surface_ui(surface)
	return ui.wrapped_height_px_frame(u.frame, text, width, font_size, line_height)
}

surface_truncate_path :: proc(surface: ^Surface, path: string, width, font_size: i32) -> string {
	u := surface_ui(surface)
	return ui.truncate_path_middle_frame(u.frame, path, width, font_size)
}

surface_fill_rect :: proc(surface: ^Surface, rect: Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_rectangle(u.frame, rect.x, rect.y, rect.w, rect.h, ui.Color(color))
}

surface_fill_float_rect :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_rectangle_rec(u.frame, rect, ui.Color(color))
}

surface_stroke_rect :: proc(surface: ^Surface, rect: Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_rectangle_lines(u.frame, rect.x, rect.y, rect.w, rect.h, ui.Color(color))
}

surface_line :: proc(surface: ^Surface, from, to: Point, thickness: f32, color: Color) {
	u := surface_ui(surface)
	ui.draw_line_ex(u.frame, {from.x, from.y}, {to.x, to.y}, thickness, ui.Color(color))
}

surface_fill_rounded_rect :: proc(
	surface: ^Surface,
	rect: Float_Rect,
	roundness: f32,
	segments: i32,
	color: Color,
) {
	u := surface_ui(surface)
	ui.draw_rectangle_rounded(u.frame, rect, roundness, segments, ui.Color(color))
}

surface_stroke_rounded_rect :: proc(
	surface: ^Surface,
	rect: Float_Rect,
	roundness: f32,
	segments: i32,
	thickness: f32,
	color: Color,
) {
	u := surface_ui(surface)
	ui.draw_rectangle_rounded_lines_ex(
		u.frame,
		rect,
		roundness,
		segments,
		thickness,
		ui.Color(color),
	)
}

surface_draw_surface :: proc(
	surface: ^Surface,
	rect: Float_Rect,
	kind: Surface_Kind,
	state: Visual_State = .Rest,
	radius: Radius = .None,
	border: Border = .None,
	elevation: Elevation = .Flat,
) {
	u := surface_ui(surface)
	ui.draw_surface(u.frame, rect, kind, state, radius, border, elevation)
}

surface_interact :: proc(surface: ^Surface, rect: Float_Rect) -> Interaction {
	u := surface_ui(surface)
	result := ui.interact(u.frame, rect)
	return {result.hovered, result.pressed, result.held, result.released, result.clicked}
}

surface_key_pressed :: proc(surface: ^Surface, key: Key) -> bool {
	u := surface_ui(surface)
	return ui.is_key_pressed(u.frame, to_key(key))
}

surface_key_pressed_consume :: proc(surface: ^Surface, key: Key) {
	u := surface_ui(surface)
	ui.key_pressed_consume(u.frame, to_key(key))
}

surface_mouse_pressed :: proc(surface: ^Surface, button: Mouse_Button) -> bool {
	u := surface_ui(surface)
	return ui.is_mouse_button_pressed(u.frame, to_mouse_button(button))
}

surface_mouse_down :: proc(surface: ^Surface, button: Mouse_Button) -> bool {
	u := surface_ui(surface)
	return ui.is_mouse_button_down(u.frame, to_mouse_button(button))
}

surface_mouse_position :: proc(surface: ^Surface) -> Point {
	u := surface_ui(surface)
	return from_point(ui.get_mouse_position(u.frame))
}

surface_wheel_v :: proc(surface: ^Surface) -> Point {
	u := surface_ui(surface)
	return from_point(ui.get_mouse_wheel_move_v(u.frame))
}

surface_wheel :: proc(surface: ^Surface) -> f32 {
	u := surface_ui(surface)
	return ui.get_wheel_move(u.frame)
}

surface_request_cursor :: proc(surface: ^Surface, cursor: Cursor) {
	u := surface_ui(surface)
	ui.request_cursor(u.frame, to_cursor(cursor))
}

request_redraw :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.request_redraw(u.frame)
}

surface_settings_scale_preset_index :: proc(value: f32) -> int {
	return ui.settings_scale_preset_index(value)
}

surface_region_begin :: proc(surface: ^Surface, region: ^Region, rect: Rect, gap: Space = .None) {
	u := surface_ui(surface)
	assert(region != nil && !region.inner.open, "fit.surface_region_begin: invalid region")
	assert(!region.managed_scope, "fit.surface_region_begin: managed scope still open")
	ui.begin(&region.inner, u.frame, rect, gap = gap)
}

surface_region_end :: proc(region: ^Region) -> i32 {
	assert(region != nil && region.inner.open, "fit.surface_region_end: region not open")
	assert(!region.managed_scope, "fit.surface_region_end: use region_close")
	return ui.end(&region.inner)
}

region_open :: proc(
	surface: ^Surface,
	region: ^Region,
	rect: Rect,
	options: Region_Options = {},
) -> ^Region {
	surface_region_begin(surface, region, rect, options.gap)
	if options.scope != "" {
		ui.scope_begin(&region.inner, options.scope)
		region.managed_scope = true
	}
	return region
}

region_close :: proc(region: ^Region) -> i32 {
	assert(region != nil && region.inner.open, "fit.region_close: region not open")
	if region.managed_scope {
		ui.scope_end(&region.inner)
		region.managed_scope = false
	}
	return ui.end(&region.inner)
}

surface_pane_begin :: proc(
	surface: ^Surface,
	state: ^Pane_State,
	rect: Rect,
	padding: i32 = 8,
	keyboard: bool = true,
	keyboard_unhovered: bool = false,
	wheel: bool = true,
) -> i32 {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_pane_begin: nil state")
	return ui.pane_begin(
		u.frame,
		&state.inner,
		rect,
		pad = padding,
		keyboard = keyboard,
		keyboard_unhovered = keyboard_unhovered,
		wheel = wheel,
	)
}

surface_pane_end :: proc(
	surface: ^Surface,
	state: ^Pane_State,
	rect: Rect,
	content_y: i32,
	padding: i32 = 8,
) {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_pane_end: nil state")
	ui.pane_end(u.frame, &state.inner, rect, content_y, pad = padding)
}

pane_reset :: proc(state: ^Pane_State) {
	assert(state != nil, "fit.pane_reset: nil state")
	ui.pane_reset(&state.inner)
}

grid_begin :: proc(
	surface: ^Surface,
	state: ^Grid_State,
	rect: Rect,
	columns, row_height: i32,
	gap_x: i32 = 0,
	gap_y: i32 = 0,
) {
	_ = surface_ui(surface)
	assert(state != nil, "fit.grid_begin: nil state")
	assert(!state.open, "fit.grid_begin: state already open")
	state.surface = surface
	state.open = true
	ui.grid_begin(&state.inner, rect, columns, row_height, gap_x, gap_y)
}

grid_next :: proc(state: ^Grid_State) -> Rect {
	assert(state != nil && state.open, "fit.grid_next: state not open")
	_ = surface_ui(state.surface)
	return ui.grid_next(&state.inner)
}

grid_skip_to :: proc(state: ^Grid_State, index: i32) {
	assert(state != nil && state.open, "fit.grid_skip_to: state not open")
	_ = surface_ui(state.surface)
	ui.grid_skip_to(&state.inner, index)
}

grid_end :: proc(state: ^Grid_State) -> Rect {
	assert(state != nil && state.open, "fit.grid_end: state not open")
	_ = surface_ui(state.surface)
	result := ui.grid_end(&state.inner)
	state.surface = nil
	state.open = false
	return result
}

surface_grid_begin :: proc(
	surface: ^Surface,
	state: ^Grid_State,
	rect: Rect,
	columns, row_height: i32,
	gap_x: i32 = 0,
	gap_y: i32 = 0,
) {
	grid_begin(surface, state, rect, columns, row_height, gap_x, gap_y)
}

surface_grid_next :: proc(surface: ^Surface, state: ^Grid_State) -> Rect {
	assert(state != nil && state.surface == surface, "fit.surface_grid_next: surface mismatch")
	return grid_next(state)
}

surface_grid_visible_range :: proc(
	surface: ^Surface,
	rect: Rect,
	columns, row_height, gap_y, count, top, bottom: i32,
) -> Visible_Range {
	_ = surface_ui(surface)
	first, end := ui.grid_visible_range(rect, columns, row_height, gap_y, count, top, bottom)
	return {first, end}
}

surface_grid_skip_to :: proc(surface: ^Surface, state: ^Grid_State, index: i32) {
	assert(state != nil && state.surface == surface, "fit.surface_grid_skip_to: surface mismatch")
	grid_skip_to(state, index)
}

surface_grid_end :: proc(surface: ^Surface, state: ^Grid_State) -> Rect {
	assert(state != nil && state.surface == surface, "fit.surface_grid_end: surface mismatch")
	return grid_end(state)
}

surface_draw_shadow :: proc(
	surface: ^Surface,
	rect: Float_Rect,
	radius: Radius,
	elevation: Elevation,
) {
	u := surface_ui(surface)
	ui.draw_shadow_hard(u.frame, rect, radius, elevation)
}

surface_draw_rules :: proc(surface: ^Surface, rect: Float_Rect, spacing: i32, color: Color) {
	u := surface_ui(surface)
	ui.draw_rule_lines(u.frame, rect, spacing, ui.Color(color))
}

surface_draw_margin_rule :: proc(surface: ^Surface, rect: Float_Rect, inset: i32, color: Color) {
	u := surface_ui(surface)
	ui.draw_margin_rule(u.frame, rect, inset, ui.Color(color))
}

surface_draw_hand_underline :: proc(surface: ^Surface, x, y, width: i32, color: Color) {
	u := surface_ui(surface)
	ui.draw_hand_underline(u.frame, x, y, width, ui.Color(color))
}

surface_draw_dot_grid :: proc(surface: ^Surface, rect: Float_Rect, spacing: i32, color: Color) {
	u := surface_ui(surface)
	ui.draw_dot_grid(u.frame, rect, spacing, ui.Color(color))
}

surface_draw_highlight :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_highlight_swipe(u.frame, rect, ui.Color(color))
}

surface_draw_scribble :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_scribble_fill(u.frame, rect, ui.Color(color))
}

surface_draw_tape :: proc(surface: ^Surface, rect: Float_Rect, length: f32, color: Color) {
	u := surface_ui(surface)
	ui.draw_tape_strip(u.frame, rect, length, ui.Color(color))
}

surface_draw_dog_ear :: proc(surface: ^Surface, rect: Float_Rect, size: f32, fold, shade: Color) {
	u := surface_ui(surface)
	ui.draw_dog_ear(u.frame, rect, size, ui.Color(fold), ui.Color(shade))
}

surface_draw_paper_tooth :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_paper_tooth(u.frame, rect, ui.Color(color))
}

surface_draw_wash :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_wash(u.frame, rect, ui.Color(color))
}

surface_draw_pigment_block :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_pigment_block(u.frame, rect, ui.Color(color))
}

surface_draw_chalk_highlight :: proc(surface: ^Surface, rect: Float_Rect, radius: Radius) {
	u := surface_ui(surface)
	ui.draw_chalk_highlight(u.frame, rect, radius)
}

surface_dot_grid_fits :: proc(surface: ^Surface, rect: Float_Rect, spacing: i32) -> bool {
	_ = surface_ui(surface)
	return ui.dot_grid_fits(rect, spacing)
}

surface_scatter_unit :: proc(index, lane: u32) -> f32 {
	return ui.scatter_unit(index, lane)
}

surface_layer_begin :: proc(surface: ^Surface, z: Z_Order, claim: Float_Rect = {}) {
	u := surface_ui(surface)
	ui.layer_begin(u.frame, ui.Z_Order(z), claim = claim)
}

surface_layer_end :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.layer_end(u.frame)
}
