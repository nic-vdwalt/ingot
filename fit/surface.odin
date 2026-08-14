package fit

import "ingot:ui"

Surface_Viewport :: proc(surface: ^Surface) -> Rect {
	u := surface_ui(surface)
	return from_rect(ui.frame_viewport(u.frame))
}

Surface_Pane_Origin :: proc(surface: ^Surface) -> Point {
	u := surface_ui(surface)
	return from_point(ui.frame_pane_origin(u.frame))
}

Surface_Scale :: proc(surface: ^Surface, value: i32) -> i32 {
	u := surface_ui(surface)
	return ui.ui_frame_sc(u.frame, value)
}

Surface_Scale_Float :: proc(surface: ^Surface, value: f32) -> f32 {
	u := surface_ui(surface)
	return ui.ui_frame_scf(u.frame, value)
}

Surface_Cull_Bounds :: proc(surface: ^Surface) -> (top, bottom: i32) {
	u := surface_ui(surface)
	return u.frame.text_cull_top, u.frame.text_cull_bottom
}

Surface_Metrics :: proc(surface: ^Surface) -> Metrics {
	u := surface_ui(surface)
	metrics := ui.ui_frame_metrics(u.frame)
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
		card_radius = metrics.CARD_RADIUS_PX,
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

Surface_Theme :: proc(surface: ^Surface) -> Theme {
	u := surface_ui(surface)
	return {inner = ui.ui_frame_theme(u.frame)^}
}

Surface_Theme_Tokens :: proc(surface: ^Surface) -> Theme_Tokens {
	theme := Surface_Theme(surface).inner
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
		substrate = Substrate_Kind(theme.substrate.kind),
		margin_rule = theme.substrate.margin_rule,
	}
}

Surface_Theme_Color :: proc(surface: ^Surface, ink: Ink) -> Color {
	u := surface_ui(surface)
	return Color(ui.text_ink(u.frame, ui.Ink(ink)))
}

Surface_Resolve_Colors :: proc(
	surface: ^Surface,
	kind: Surface_Kind,
	state: Visual_State = .Rest,
) -> Surface_Colors {
	u := surface_ui(surface)
	colors := ui.surface_colors(u.frame, ui.Surface(kind), ui.Visual_State(state))
	return {Color(colors.bg), Color(colors.fg), Color(colors.border)}
}

Surface_Pigment :: proc(surface: ^Surface, pigment: Pigment) -> Color {
	theme := Surface_Theme(surface)
	return Theme_Pigment(theme, pigment)
}

Surface_Space :: proc(surface: ^Surface, space: Space) -> i32 {
	u := surface_ui(surface)
	return ui.space_pixels(u.frame, ui.Space(space))
}

Surface_Text_Size :: proc(surface: ^Surface, role: Text_Role) -> i32 {
	u := surface_ui(surface)
	return ui.text_role_size(u.frame, ui.Text_Role(role))
}

Surface_Text_Line_Height :: proc(surface: ^Surface, role: Text_Role) -> i32 {
	u := surface_ui(surface)
	return ui.text_role_line_height(u.frame, ui.Text_Role(role))
}

Surface_Text_Width :: proc(surface: ^Surface, text: string, role: Text_Role = .Body) -> i32 {
	u := surface_ui(surface)
	return ui.text_width(u.frame, text, ui.Text_Role(role))
}

Surface_Text :: proc(
	surface: ^Surface,
	text: string,
	x, y: i32,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) {
	u := surface_ui(surface)
	ui.text(u.frame, text, x, y, ui.Text_Role(role), ui.Ink(ink))
}

Surface_Text_Truncated :: proc(
	surface: ^Surface,
	text: string,
	x, y, width: i32,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) {
	u := surface_ui(surface)
	ui.text_truncated(u.frame, text, x, y, width, ui.Text_Role(role), ui.Ink(ink))
}

Surface_Text_Wrapped :: proc(
	surface: ^Surface,
	text: string,
	x, y, width: i32,
	color: Color,
	font_size, line_height: i32,
) {
	u := surface_ui(surface)
	ui.draw_text_wrapped_frame(u.frame, x, y, width, text, ui.Color(color), font_size, line_height)
}

Surface_Truncate_Path :: proc(surface: ^Surface, path: string, width, font_size: i32) -> string {
	u := surface_ui(surface)
	return ui.truncate_path_middle_frame(u.frame, path, width, font_size)
}

Surface_Fill_Rect :: proc(surface: ^Surface, rect: Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_rectangle(u.frame, rect.x, rect.y, rect.w, rect.h, ui.Color(color))
}

Surface_Fill_Float_Rect :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_rectangle_rec(u.frame, to_float_rect(rect), ui.Color(color))
}

Surface_Stroke_Rect :: proc(surface: ^Surface, rect: Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_rectangle_lines(u.frame, rect.x, rect.y, rect.w, rect.h, ui.Color(color))
}

Surface_Line :: proc(surface: ^Surface, from, to: Point, thickness: f32, color: Color) {
	u := surface_ui(surface)
	ui.draw_line_ex(u.frame, {from.x, from.y}, {to.x, to.y}, thickness, ui.Color(color))
}

Surface_Fill_Rounded_Rect :: proc(
	surface: ^Surface,
	rect: Float_Rect,
	roundness: f32,
	segments: i32,
	color: Color,
) {
	u := surface_ui(surface)
	ui.draw_rectangle_rounded(u.frame, to_float_rect(rect), roundness, segments, ui.Color(color))
}

Surface_Stroke_Rounded_Rect :: proc(
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
		to_float_rect(rect),
		roundness,
		segments,
		thickness,
		ui.Color(color),
	)
}

Surface_Draw_Surface :: proc(
	surface: ^Surface,
	rect: Float_Rect,
	kind: Surface_Kind,
	state: Visual_State = .Rest,
	radius: Radius = .None,
	border: Border = .None,
	elevation: Elevation = .Flat,
) {
	u := surface_ui(surface)
	ui.draw_surface(
		u.frame,
		to_float_rect(rect),
		ui.Surface(kind),
		ui.Visual_State(state),
		ui.Radius(radius),
		ui.Border(border),
		ui.Elevation(elevation),
	)
}

Surface_Interact :: proc(surface: ^Surface, rect: Float_Rect) -> Interaction {
	u := surface_ui(surface)
	result := ui.interact(u.frame, to_float_rect(rect))
	return {result.hovered, result.pressed, result.held, result.released, result.clicked}
}

Surface_Key_Pressed :: proc(surface: ^Surface, key: Key) -> bool {
	u := surface_ui(surface)
	return ui.is_key_pressed(u.frame, ui.Key(key))
}

Surface_Mouse_Pressed :: proc(surface: ^Surface, button: Mouse_Button) -> bool {
	u := surface_ui(surface)
	return ui.is_mouse_button_pressed(u.frame, ui.Mouse_Button(button))
}

Surface_Mouse_Down :: proc(surface: ^Surface, button: Mouse_Button) -> bool {
	u := surface_ui(surface)
	return ui.is_mouse_button_down(u.frame, ui.Mouse_Button(button))
}

Surface_Mouse_Position :: proc(surface: ^Surface) -> Point {
	u := surface_ui(surface)
	return from_point(ui.get_mouse_position(u.frame))
}

Surface_Wheel :: proc(surface: ^Surface) -> f32 {
	u := surface_ui(surface)
	return ui.get_wheel_move(u.frame)
}

Surface_Request_Cursor :: proc(surface: ^Surface, cursor: Cursor) {
	u := surface_ui(surface)
	ui.request_cursor(u.frame, ui.Cursor(cursor))
}

Request_Redraw :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.request_redraw(u.frame)
}

Surface_Settings_Scale_Preset_Index :: proc(value: f32) -> int {
	return ui.settings_scale_preset_index(value)
}

Surface_Region_Begin :: proc(surface: ^Surface, region: ^Region, rect: Rect, gap: Space = .None) {
	u := surface_ui(surface)
	assert(region != nil && !region.inner.open, "Fit.Surface_Region_Begin: invalid region")
	ui.begin(&region.inner, u.frame, to_rect(rect), gap = ui.Space(gap))
}

Surface_Region_End :: proc(region: ^Region) -> i32 {
	assert(region != nil && region.inner.open, "Fit.Surface_Region_End: region not open")
	return ui.end(&region.inner)
}

Surface_Pane_Begin :: proc(
	surface: ^Surface,
	state: ^Pane_State,
	rect: Rect,
	padding: i32 = 8,
	keyboard: bool = true,
) -> i32 {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Pane_Begin: nil state")
	return ui.pane_begin(u.frame, &state.inner, to_rect(rect), pad = padding, keyboard = keyboard)
}

Surface_Pane_End :: proc(
	surface: ^Surface,
	state: ^Pane_State,
	rect: Rect,
	content_y: i32,
	padding: i32 = 8,
) {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Pane_End: nil state")
	ui.pane_end(u.frame, &state.inner, to_rect(rect), content_y, pad = padding)
}

Pane_Reset :: proc(state: ^Pane_State) {
	assert(state != nil, "Fit.Pane_Reset: nil state")
	ui.pane_reset(&state.inner)
}

Surface_Grid_Begin :: proc(
	surface: ^Surface,
	state: ^Grid_State,
	rect: Rect,
	columns, row_height: i32,
	gap_x: i32 = 0,
	gap_y: i32 = 0,
) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Grid_Begin: nil state")
	ui.grid_begin(&state.inner, to_rect(rect), columns, row_height, gap_x, gap_y)
}

Surface_Grid_Next :: proc(surface: ^Surface, state: ^Grid_State) -> Rect {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Grid_Next: nil state")
	return from_rect(ui.grid_next(&state.inner))
}

Surface_Grid_Visible_Range :: proc(
	surface: ^Surface,
	rect: Rect,
	columns, row_height, gap_y, count, top, bottom: i32,
) -> Visible_Range {
	_ = surface_ui(surface)
	first, end := ui.grid_visible_range(
		to_rect(rect),
		columns,
		row_height,
		gap_y,
		count,
		top,
		bottom,
	)
	return {first, end}
}

Surface_Grid_Skip_To :: proc(surface: ^Surface, state: ^Grid_State, index: i32) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Grid_Skip_To: nil state")
	ui.grid_skip_to(&state.inner, index)
}

Surface_Grid_End :: proc(surface: ^Surface, state: ^Grid_State) -> Rect {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Grid_End: nil state")
	return from_rect(ui.grid_end(&state.inner))
}

Surface_Draw_Shadow :: proc(
	surface: ^Surface,
	rect: Float_Rect,
	radius: Radius,
	elevation: Elevation,
) {
	u := surface_ui(surface)
	ui.draw_shadow_hard(u.frame, to_float_rect(rect), ui.Radius(radius), ui.Elevation(elevation))
}

Surface_Draw_Rules :: proc(surface: ^Surface, rect: Float_Rect, spacing: i32, color: Color) {
	u := surface_ui(surface)
	ui.draw_rule_lines(u.frame, to_float_rect(rect), spacing, ui.Color(color))
}

Surface_Draw_Margin_Rule :: proc(surface: ^Surface, rect: Float_Rect, inset: i32, color: Color) {
	u := surface_ui(surface)
	ui.draw_margin_rule(u.frame, to_float_rect(rect), inset, ui.Color(color))
}

Surface_Draw_Hand_Underline :: proc(surface: ^Surface, x, y, width: i32, color: Color) {
	u := surface_ui(surface)
	ui.draw_hand_underline(u.frame, x, y, width, ui.Color(color))
}

Surface_Draw_Dot_Grid :: proc(surface: ^Surface, rect: Float_Rect, spacing: i32, color: Color) {
	u := surface_ui(surface)
	ui.draw_dot_grid(u.frame, to_float_rect(rect), spacing, ui.Color(color))
}

Surface_Draw_Highlight :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_highlight_swipe(u.frame, to_float_rect(rect), ui.Color(color))
}

Surface_Draw_Scribble :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_scribble_fill(u.frame, to_float_rect(rect), ui.Color(color))
}

Surface_Draw_Tape :: proc(surface: ^Surface, rect: Float_Rect, length: f32, color: Color) {
	u := surface_ui(surface)
	ui.draw_tape_strip(u.frame, to_float_rect(rect), length, ui.Color(color))
}

Surface_Draw_Dog_Ear :: proc(surface: ^Surface, rect: Float_Rect, size: f32, fold, shade: Color) {
	u := surface_ui(surface)
	ui.draw_dog_ear(u.frame, to_float_rect(rect), size, ui.Color(fold), ui.Color(shade))
}

Surface_Draw_Paper_Tooth :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_paper_tooth(u.frame, to_float_rect(rect), ui.Color(color))
}

Surface_Draw_Wash :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_wash(u.frame, to_float_rect(rect), ui.Color(color))
}

Surface_Draw_Pigment_Block :: proc(surface: ^Surface, rect: Float_Rect, color: Color) {
	u := surface_ui(surface)
	ui.draw_pigment_block(u.frame, to_float_rect(rect), ui.Color(color))
}

Surface_Draw_Chalk_Highlight :: proc(surface: ^Surface, rect: Float_Rect, radius: Radius) {
	u := surface_ui(surface)
	ui.draw_chalk_highlight(u.frame, to_float_rect(rect), ui.Radius(radius))
}

Surface_Dot_Grid_Fits :: proc(surface: ^Surface, rect: Float_Rect, spacing: i32) -> bool {
	_ = surface_ui(surface)
	return ui.dot_grid_fits(to_float_rect(rect), spacing)
}

Surface_Scatter_Unit :: proc(index, lane: u32) -> f32 {
	return ui.scatter_unit(index, lane)
}

Surface_Layer_Begin :: proc(surface: ^Surface, z: Z_Order, claim: Float_Rect = {}) {
	u := surface_ui(surface)
	ui.layer_begin(u.frame, ui.Z_Order(z), claim = to_float_rect(claim))
}

Surface_Layer_End :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.layer_end(u.frame)
}
