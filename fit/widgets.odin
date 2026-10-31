package fit

import "core:strings"
import "ingot:ui"

Theme :: struct {
	inner: ui.Theme,
}
Theme_Basis :: ui.Theme_Basis
Theme_Palette :: ui.Theme_Palette
Theme_Role :: ui.Theme_Role
Theme_Validation_Code :: ui.Theme_Validation_Code
Theme_Validation :: ui.Theme_Validation
Pigment :: ui.Pigment
Visual_State :: ui.Visual_State
Surface_Kind :: ui.Surface
Tint :: ui.Tint
Elevation :: ui.Elevation
Substrate_Kind :: ui.Substrate_Kind
Font_Face :: ui.Font_Face
Surface_Style :: ui.Surface_Style
Surface_Colors :: struct {
	background: Color,
	foreground: Color,
	border:     Color,
}
Theme_Tokens :: struct {
	background_app:              Color,
	background_chat:             Color,
	background_panel:            Color,
	background_color:            Color,
	background_secondary:        Color,
	background_active:           Color,
	background_hover:            Color,
	background_input:            Color,
	background_code:             Color,
	background_popup:            Color,
	background_selection:        Color,
	background_plan_bar:         Color,
	background_plan_title:       Color,
	background_tool_card:        Color,
	background_tool_card_hover:  Color,
	background_diff_add:         Color,
	background_diff_remove:      Color,
	background_debug_title:      Color,
	background_chip:             Color,
	background_chip_hover:       Color,
	background_user_card:        Color,
	background_band_error:       Color,
	modal_dim:                   Color,
	foreground_primary:          Color,
	foreground_secondary:        Color,
	foreground_accent:           Color,
	foreground_user:             Color,
	foreground_assistant:        Color,
	foreground_error:            Color,
	foreground_success:          Color,
	foreground_tool:             Color,
	foreground_diff_remove:      Color,
	foreground_diff_add:         Color,
	foreground_diff_gutter:      Color,
	foreground_disabled:         Color,
	foreground_plan:             Color,
	foreground_planning:         Color,
	foreground_heading:          Color,
	foreground_debug:            Color,
	foreground_debug_changed:    Color,
	foreground_debug_annotation: Color,
	foreground_label:            Color,
	border:                      Color,
	border_subtle:               Color,
	border_user_card:            Color,
	badge:                       Color,
	merge_link:                  Color,
	button_background:           Color,
	button_hover:                Color,
	wave_a:                      Color,
	wave_b:                      Color,
	drop_zone_background:        Color,
	drop_zone_border:            Color,
	paper_rule:                  Color,
	paper_tooth:                 Color,
	graphite:                    Color,
	chalk:                       Color,
	highlighter:                 Color,
	tape:                        Color,
	substrate:                   Substrate_Kind,
	margin_rule:                 bool,
	square_corners:              bool,
	font_face:                   Font_Face,
	reading_font_face:           Font_Face,
	surface_style:               Surface_Style,
	bevel_light:                 Color,
	bevel_shade:                 Color,
}

Input_Box :: struct {
	inner: ui.Input_Box,
}
Text_Input_State :: struct {
	inner: ui.Text_Input_State,
}
Text_Input_Submit :: enum u8 {
	Default,
	Never,
	Enter,
	Ctrl_Enter,
	Mod_Enter,
}
Text_Input_Semantics :: struct {
	field_id: string,
	name:     string,
}
Text_Input_Config :: struct {
	rect:         Rect,
	placeholder:  string,
	active:       bool,
	masked:       bool,
	enable_pills: bool,
	enable_undo:  bool,
	max_bytes:    int,
	single_line:  bool,
	submit:       Text_Input_Submit,
	semantics:    Text_Input_Semantics,
}
Text_Input_Options :: struct {
	height:    i32,
	masked:    bool,
	semantics: Text_Input_Semantics,
}
Slider_State :: struct {
	inner: ui.Slider_State,
}
Dropdown_State :: struct {
	inner: ui.Dropdown_State,
}
Combobox_State :: struct {
	inner: ui.Combobox_State,
}
Combobox_Item :: ui.Combobox_Item
Date_Picker_State :: struct {
	inner: ui.Date_Picker_State,
}
Calendar_Date :: ui.Calendar_Date
Tooltip_State :: struct {
	inner: ui.Tooltip_State,
}
Listbox_State :: struct {
	inner: ui.Listbox_State,
}
Listbox_Keys :: ui.Listbox_Keys
Listbox_Config :: ui.Listbox_Config
Listbox_Result :: ui.Listbox_Result
Selectable_Row_Config :: ui.Selectable_Row_Config
Selectable_Row_Result :: ui.Selectable_Row_Result
Table_Sort :: ui.Table_Sort
Table_Column :: ui.Table_Column
Chart_State :: struct {
	enter_anim:  f32,
	hover_index: int,
}
Chart_Series :: ui.Chart_Series
Chart_Options :: struct {
	labels:      []string,
	y_min:       f32,
	y_max:       f32,
	y_fixed:     bool,
	show_grid:   bool,
	show_axes:   bool,
	show_legend: bool,
	fill:        bool,
}
Markdown_Result :: struct {
	height:         i32,
	width:          i32,
	link_activated: bool,
	link_target:    string,
}
Confirm_Choice :: ui.Confirm_Choice
Command_Palette_Item :: ui.Command_Palette_Item
Command_Palette_State :: ui.Command_Palette_State
Command_Palette_Result :: ui.Command_Palette_Result
Command_Palette_Options :: ui.Command_Palette_Options
Modal_State :: struct {
	inner: ui.Modal_State,
}
Modal_Id :: ui.Modal_Id
Modal_Close_Reason :: ui.Modal_Close_Reason
Modal_Dismiss_Policy :: ui.Modal_Dismiss_Policy
Modal_Scope :: enum u8 {
	Viewport,
	Host,
}
Modal_Placement :: ui.Modal_Placement
Modal_Options :: struct {
	placement:       Modal_Placement,
	dismiss_escape:  bool,
	dismiss_outside: bool,
	focus_scope:     ui.Focus_Scope_Id,
	initial_focus:   ui.Focus_Opt,
	restore_focus:   ui.Focus_Opt,
	scope:           Modal_Scope,
	host:            Rect,
}
Popup_State :: struct {
	inner: ui.Popup_State,
}
Popup_Id :: ui.Popup_Id
Popup_Close_Reason :: ui.Popup_Close_Reason
Popup_Placement :: ui.Popup_Placement
Popup_Options :: ui.Popup_Config
Context_Menu_State :: struct {
	inner: ui.Context_Menu_State,
}
Menu_Item :: ui.Menu_Item
Toast_State :: struct {
	inner: ui.Toast_State,
}
Toast_Kind :: enum u8 {
	Info,
	Success,
	Warning,
	Error,
}
Confirm_Dialog_State :: struct {
	inner: ui.Confirm_Dialog_State,
}

TABLE_COLUMN_COUNT_MAX :: 32
PAINT_COMMAND_CAP :: 8192
PAINT_TEXT_CAP :: 32768
Z_PANEL :: Z_Order(100)
Z_POPUP :: Z_Order(200)
ROOT_EXTENT_OPEN :: i32(1 << 20)

#assert(TABLE_COLUMN_COUNT_MAX == ui.TABLE_COLUMN_COUNT_MAX)
#assert(PAINT_COMMAND_CAP == ui.PAINT_COMMAND_CAP)
#assert(PAINT_TEXT_CAP == ui.PAINT_TEXT_CAP)
#assert(Z_PANEL == Z_Order(ui.Z_PANEL))
#assert(Z_POPUP == Z_Order(ui.Z_POPUP))
#assert(ROOT_EXTENT_OPEN == ui.ROOT_EXTENT_OPEN)

input_box_init :: proc(box: ^Input_Box) {
	assert(box != nil, "fit.input_box_init: nil box")
	ui.input_box_init(&box.inner)
}

input_box_destroy :: proc(box: ^Input_Box) {
	assert(box != nil, "fit.input_box_destroy: nil box")
	ui.input_box_destroy(&box.inner)
}

input_box_reset :: proc(box: ^Input_Box) {
	assert(box != nil, "fit.input_box_reset: nil box")
	ui.input_box_reset(&box.inner)
}

input_box_set_text :: proc(box: ^Input_Box, text: string) {
	assert(box != nil, "fit.input_box_set_text: nil box")
	ui.input_box_set_text(&box.inner, text)
}

input_box_text :: proc(box: ^Input_Box) -> string {
	assert(box != nil, "fit.input_box_text: nil box")
	return ui.input_box_text(&box.inner)
}

text_input_state_destroy :: proc(state: ^Text_Input_State) {
	assert(state != nil, "fit.text_input_state_destroy: nil state")
	ui.text_input_state_destroy(&state.inner)
}

text_input_state_cursor :: proc(state: ^Text_Input_State) -> int {
	assert(state != nil, "fit.text_input_state_cursor: nil state")
	return state.inner.cursor
}

text_input_state_set_cursor :: proc(state: ^Text_Input_State, cursor: int) {
	assert(state != nil && cursor >= 0, "fit.text_input_state_set_cursor: invalid argument")
	state.inner.cursor = cursor
	state.inner.desired_col = 0
	state.inner.scroll_line = 0
}

text_input_state_clear :: proc(state: ^Text_Input_State) {
	assert(state != nil, "fit.text_input_state_clear: nil state")
	clear(&state.inner.pills)
	ui.text_input_selection_clear(&state.inner)
	ui.input_undo_reset(&state.inner.undo)
	state.inner.cursor = 0
	state.inner.desired_col = 0
	state.inner.scroll_line = 0
}

text_input_state_selecting :: proc(state: ^Text_Input_State) -> bool {
	assert(state != nil, "fit.text_input_state_selecting: nil state")
	return ui.text_input_selecting(&state.inner)
}

text_input_state_spell_menu_active :: proc(
	state: ^Text_Input_State,
	text: ^strings.Builder,
) -> bool {
	assert(state != nil && text != nil, "fit.text_input_state_spell_menu_active: invalid argument")
	return ui.text_input_spell_menu_active(&state.inner, text)
}

text_input_state_record_replace :: proc(
	state: ^Text_Input_State,
	text: ^strings.Builder,
	value: string,
	now: f64,
) {
	assert(state != nil && text != nil, "fit.text_input_state_record_replace: invalid argument")
	ui.input_undo_record(
		&state.inner.undo,
		strings.to_string(text^),
		state.inner.cursor,
		state.inner.pills[:],
		.Other,
		now,
	)
	strings.builder_reset(text)
	strings.write_string(text, value)
	clear(&state.inner.pills)
	state.inner.cursor = strings.builder_len(text^)
	_, state.inner.desired_col = ui.caret_row_col(value, state.inner.cursor)
	state.inner.scroll_line = 0
}

text_input_state_add_pill :: proc(state: ^Text_Input_State, start, end: int) {
	assert(
		state != nil && start >= 0 && end >= start,
		"fit.text_input_state_add_pill: invalid argument",
	)
	ui.pills_shift_after_insert(&state.inner.pills, start, end - start + 1)
	append(&state.inner.pills, ui.Mention_Span{start, end})
}

text_input_state_encode_pills :: proc(state: ^Text_Input_State, text: string) -> string {
	assert(state != nil, "fit.text_input_state_encode_pills: nil state")
	return ui.encode_pills(text, state.inner.pills[:])
}

caret_row_column :: proc(text: string, cursor: int) -> (row, column: int) {
	return ui.caret_row_col(text, cursor)
}

caret_line_count :: proc(text: string) -> int {
	return ui.caret_line_count(text)
}

strip_pill_markers :: proc(text: string) -> string {
	return ui.strip_pill_markers(text)
}

combobox_state_destroy :: proc(state: ^Combobox_State) {
	assert(state != nil, "fit.combobox_state_destroy: nil state")
	ui.combobox_state_destroy(&state.inner)
}

calendar_date_valid :: proc(value: Calendar_Date) -> bool {
	return ui.calendar_date_valid({value.year, value.month, value.day})
}

calendar_format :: proc(value: Calendar_Date) -> string {
	return ui.calendar_format({value.year, value.month, value.day})
}

chart_reset :: proc(state: ^Chart_State) {
	assert(state != nil, "fit.chart_reset: nil state")
	state.enter_anim = 0
	state.hover_index = -1
}

modal_open :: proc(state: ^Modal_State) {
	assert(state != nil, "fit.modal_open: nil state")
	state.inner.open = true
}

modal_is_open :: proc(state: ^Modal_State) -> bool {
	assert(state != nil, "fit.modal_is_open: nil state")
	return ui.modal_is_open(&state.inner)
}

context_menu_is_open :: proc(state: ^Context_Menu_State) -> bool {
	assert(state != nil, "fit.context_menu_is_open: nil state")
	return state.inner.open
}

confirm_dialog_is_open :: proc(state: ^Confirm_Dialog_State) -> bool {
	assert(state != nil, "fit.confirm_dialog_is_open: nil state")
	return state.inner.modal.open
}

modal_close :: proc(state: ^Modal_State) {
	assert(state != nil, "fit.modal_close: nil state")
	ui.modal_close(&state.inner)
}

modal_close_with :: proc(state: ^Modal_State, reason: Modal_Close_Reason) {
	assert(state != nil, "fit.modal_close_with: nil state")
	ui.modal_close(&state.inner, reason)
}

modal_take_close :: proc(state: ^Modal_State) -> Modal_Close_Reason {
	assert(state != nil, "fit.modal_take_close: nil state")
	return ui.modal_take_close(&state.inner)
}

popup_is_open :: proc(state: ^Popup_State) -> bool {
	assert(state != nil, "fit.popup_is_open: nil state")
	return ui.popup_is_open(&state.inner)
}

popup_close :: proc(state: ^Popup_State) {
	assert(state != nil, "fit.popup_close: nil state")
	ui.popup_close(&state.inner)
}

popup_close_with :: proc(state: ^Popup_State, reason: Popup_Close_Reason) {
	assert(state != nil, "fit.popup_close_with: nil state")
	ui.popup_close(&state.inner, ui.Popup_Close_Reason(reason))
}

popup_take_close :: proc(state: ^Popup_State) -> Popup_Close_Reason {
	assert(state != nil, "fit.popup_take_close: nil state")
	return Popup_Close_Reason(ui.popup_take_close(&state.inner))
}

widget_id_from_string :: proc(value: string) -> Widget_Id {
	return Widget_Id(ui.widget_id(value))
}

widget_id_from_u64 :: proc(value: u64) -> Widget_Id {
	return Widget_Id(ui.widget_id(value))
}

theme_dark :: proc() -> Theme {
	return {inner = ui.theme_dark()}
}

theme_light :: proc() -> Theme {
	return {inner = ui.theme_light()}
}

theme_retro_orange :: proc() -> Theme {
	return {inner = ui.theme_retro_orange()}
}

theme_retro_orange_dark :: proc() -> Theme {
	return {inner = ui.theme_retro_orange_dark()}
}

theme_retro_ingot :: proc() -> Theme {
	return {inner = ui.theme_retro_ingot()}
}

theme_retro_ingot_dark :: proc() -> Theme {
	return {inner = ui.theme_retro_ingot_dark()}
}

theme_terra :: proc() -> Theme {
	return {inner = ui.theme_terra()}
}

theme_pixel :: proc() -> Theme {
	return {inner = ui.theme_pixel()}
}

theme_high_contrast :: proc() -> Theme {
	return {inner = ui.theme_high_contrast()}
}
theme_from_palette :: proc(palette: Theme_Palette) -> Theme {
	return {inner = ui.Theme_From_Palette(palette)}
}
theme_get_color :: proc(theme: Theme, role: Theme_Role) -> Color {
	return Color(ui.Theme_Get_Color(theme.inner, role))
}
theme_set_color :: proc(theme: ^Theme, role: Theme_Role, color: Color) {
	assert(theme != nil, "fit.theme_set_color: nil theme")
	ui.Theme_Set_Color(&theme.inner, role, ui.Color(color))
}
theme_validate :: proc(theme: Theme) -> Theme_Validation {
	return ui.Theme_Validate(theme.inner)
}
theme_is_valid :: proc(theme: Theme) -> bool {
	return ui.Theme_Is_Valid(theme.inner)
}
theme_pigment :: proc(theme: Theme, pigment: Pigment) -> Color {
	inner := theme.inner
	return Color(ui.theme_pigment(&inner, pigment))
}
theme_set_pigment :: proc(theme: ^Theme, pigment: Pigment, color: Color) {
	assert(theme != nil, "fit.theme_set_pigment: nil theme")
	ui.Theme_Set_Pigment(&theme.inner, pigment, ui.Color(color))
}
theme_set_substrate :: proc(theme: ^Theme, kind: Substrate_Kind, margin_rule: bool = false) {
	assert(theme != nil, "fit.theme_set_substrate: nil theme")
	ui.Theme_Set_Substrate(&theme.inner, {kind = kind, margin_rule = margin_rule})
}
theme_set_reduced_motion :: proc(theme: ^Theme, enabled: bool) {
	assert(theme != nil, "fit.theme_set_reduced_motion: nil theme")
	theme.inner.reduced_motion = enabled
}
theme_set_square_corners :: proc(theme: ^Theme, enabled: bool) {
	assert(theme != nil, "fit.theme_set_square_corners: nil theme")
	ui.Theme_Set_Square_Corners(&theme.inner, enabled)
}
theme_set_font_face :: proc(theme: ^Theme, face: Font_Face) {
	assert(theme != nil, "fit.theme_set_font_face: nil theme")
	ui.Theme_Set_Font_Face(&theme.inner, face)
	assert(theme.inner.font_face == face, "fit.theme_set_font_face: face not stored")
}
theme_set_reading_font_face :: proc(theme: ^Theme, face: Font_Face) {
	assert(theme != nil, "fit.theme_set_reading_font_face: nil theme")
	ui.Theme_Set_Reading_Font_Face(&theme.inner, face)
	assert(
		theme.inner.reading_font_face == face,
		"fit.theme_set_reading_font_face: face not stored",
	)
}
theme_set_surface_style :: proc(theme: ^Theme, style: Surface_Style) {
	assert(theme != nil, "fit.theme_set_surface_style: nil theme")
	ui.Theme_Set_Surface_Style(&theme.inner, style)
	assert(theme.inner.surface_style == style, "fit.theme_set_surface_style: style not stored")
}
theme_background :: proc(theme: Theme) -> Color {return Color(theme.inner.bg_app)}
color_tinted :: proc(color: Color, tint: Tint) -> Color {
	return Color(ui.color_tinted(ui.Color(color), tint))
}
tint_alpha :: proc(tint: Tint) -> u8 {
	return ui.tint_alpha(tint)
}
contrast_ratio :: proc(a, b: Color) -> f64 {
	return ui.contrast_ratio(ui.Color(a), ui.Color(b))
}

context_menu_open :: proc(state: ^Context_Menu_State, point: Point) {
	assert(state != nil, "fit.context_menu_open: nil state")
	ui.context_menu_open(&state.inner, i32(point.x), i32(point.y))
}

confirm_dialog_open :: proc(state: ^Confirm_Dialog_State) {
	assert(state != nil, "fit.confirm_dialog_open: nil state")
	ui.confirm_dialog_open(&state.inner)
}

toast_push :: proc(state: ^Toast_State, kind: Toast_Kind, message: string) {
	assert(state != nil, "fit.toast_push: nil state")
	inner_kind := ui.Toast_Kind.Info
	switch kind {
	case .Info:
		inner_kind = .Info
	case .Success:
		inner_kind = .Success
	case .Warning:
		inner_kind = .Info
	case .Error:
		inner_kind = .Error
	}
	ui.toast_push(&state.inner, inner_kind, message)
}

point_in_rect :: proc(point: Point, rect: Float_Rect) -> bool {
	return(
		point.x >= rect.x &&
		point.y >= rect.y &&
		point.x < rect.x + rect.width &&
		point.y < rect.y + rect.height \
	)
}
