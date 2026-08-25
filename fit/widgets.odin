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
Substrate_Kind :: enum u8 {
	None,
	Ruled,
	Grid,
	Dots,
	Tooth,
}
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
Calendar_Date :: struct {
	year:  i32,
	month: i32,
	day:   i32,
}
Tooltip_State :: struct {
	inner: ui.Tooltip_State,
}
Listbox_State :: struct {
	inner: ui.Listbox_State,
}
Listbox_Keys :: ui.Listbox_Keys
Listbox_Config :: struct {
	rect:         Rect,
	label:        string,
	stable_id:    string,
	count:        int,
	selected:     ^int,
	wrap:         bool,
	hover_select: bool,
	keys:         Listbox_Keys,
	page_rows:    int,
}
Listbox_Result :: struct {
	selection_changed: bool,
	activated:         bool,
	activated_index:   int,
	reveal:            bool,
	reveal_index:      int,
}
Selectable_Row_Config :: struct {
	rect:        Rect,
	label:       string,
	stable_id:   string,
	index:       int,
	disabled:    bool,
	description: string,
}
Selectable_Row_Result :: struct {
	hovered:   bool,
	pressed:   bool,
	held:      bool,
	selected:  bool,
	activated: bool,
}
Table_Sort :: struct {
	column:     i32,
	descending: bool,
}
Table_Column :: struct {
	label:   string,
	track:   Track,
	numeric: bool,
}
Chart_State :: struct {
	enter_anim:  f32,
	hover_index: int,
}
Chart_Series :: struct {
	name:   string,
	values: []f32,
	color:  Color,
}
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
Confirm_Choice :: enum u8 {
	None,
	Confirmed,
	Canceled,
}
Modal_State :: struct {
	inner: ui.Modal_State,
}
Modal_Id :: distinct u64
Modal_Close_Reason :: ui.Modal_Close_Reason
Modal_Dismiss_Policy :: ui.Modal_Dismiss_Policy
Modal_Scope :: enum u8 {
	Viewport,
	Host,
}
Modal_Options :: struct {
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
Popup_Id :: distinct u64
Popup_Close_Reason :: enum u8 {
	None,
	Accepted,
	Escape,
	Outside_Click,
	Programmatic,
}
Popup_Placement :: enum u8 {
	Auto,
	Above,
	Below,
	Point,
}
Popup_Options :: struct {
	anchor:          Rect,
	viewport:        Rect,
	preferred_size:  [2]i32,
	placement:       Popup_Placement,
	dismiss_escape:  bool,
	dismiss_outside: bool,
	focus_scope:     ui.Focus_Scope_Id,
	initial_focus:   ui.Focus_Opt,
	restore_focus:   ui.Focus_Opt,
}
Context_Menu_State :: struct {
	inner: ui.Context_Menu_State,
}
Menu_Item :: struct {
	label:     string,
	disabled:  bool,
	separator: bool,
}
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

Input_Box_Init :: proc(box: ^Input_Box) {
	assert(box != nil, "Fit.Input_Box_Init: nil box")
	ui.input_box_init(&box.inner)
}

Input_Box_Destroy :: proc(box: ^Input_Box) {
	assert(box != nil, "Fit.Input_Box_Destroy: nil box")
	ui.input_box_destroy(&box.inner)
}

Input_Box_Reset :: proc(box: ^Input_Box) {
	assert(box != nil, "Fit.Input_Box_Reset: nil box")
	ui.input_box_reset(&box.inner)
}

Input_Box_Set_Text :: proc(box: ^Input_Box, text: string) {
	assert(box != nil, "Fit.Input_Box_Set_Text: nil box")
	ui.input_box_set_text(&box.inner, text)
}

Input_Box_Text :: proc(box: ^Input_Box) -> string {
	assert(box != nil, "Fit.Input_Box_Text: nil box")
	return ui.input_box_text(&box.inner)
}

Text_Input_State_Destroy :: proc(state: ^Text_Input_State) {
	assert(state != nil, "Fit.Text_Input_State_Destroy: nil state")
	ui.text_input_state_destroy(&state.inner)
}

Text_Input_State_Cursor :: proc(state: ^Text_Input_State) -> int {
	assert(state != nil, "Fit.Text_Input_State_Cursor: nil state")
	return state.inner.cursor
}

Text_Input_State_Set_Cursor :: proc(state: ^Text_Input_State, cursor: int) {
	assert(state != nil && cursor >= 0, "Fit.Text_Input_State_Set_Cursor: invalid argument")
	state.inner.cursor = cursor
	state.inner.desired_col = 0
	state.inner.scroll_line = 0
}

Text_Input_State_Clear :: proc(state: ^Text_Input_State) {
	assert(state != nil, "Fit.Text_Input_State_Clear: nil state")
	clear(&state.inner.pills)
	ui.text_input_selection_clear(&state.inner)
	ui.input_undo_reset(&state.inner.undo)
	state.inner.cursor = 0
	state.inner.desired_col = 0
	state.inner.scroll_line = 0
}

Text_Input_State_Selecting :: proc(state: ^Text_Input_State) -> bool {
	assert(state != nil, "Fit.Text_Input_State_Selecting: nil state")
	return ui.text_input_selecting(&state.inner)
}

Text_Input_State_Spell_Menu_Active :: proc(
	state: ^Text_Input_State,
	text: ^strings.Builder,
) -> bool {
	assert(state != nil && text != nil, "Fit.Text_Input_State_Spell_Menu_Active: invalid argument")
	return ui.text_input_spell_menu_active(&state.inner, text)
}

Text_Input_State_Record_Replace :: proc(
	state: ^Text_Input_State,
	text: ^strings.Builder,
	value: string,
	now: f64,
) {
	assert(state != nil && text != nil, "Fit.Text_Input_State_Record_Replace: invalid argument")
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

Text_Input_State_Add_Pill :: proc(state: ^Text_Input_State, start, end: int) {
	assert(
		state != nil && start >= 0 && end >= start,
		"Fit.Text_Input_State_Add_Pill: invalid argument",
	)
	ui.pills_shift_after_insert(&state.inner.pills, start, end - start + 1)
	append(&state.inner.pills, ui.Mention_Span{start, end})
}

Text_Input_State_Encode_Pills :: proc(state: ^Text_Input_State, text: string) -> string {
	assert(state != nil, "Fit.Text_Input_State_Encode_Pills: nil state")
	return ui.encode_pills(text, state.inner.pills[:])
}

Caret_Row_Column :: proc(text: string, cursor: int) -> (row, column: int) {
	return ui.caret_row_col(text, cursor)
}

Caret_Line_Count :: proc(text: string) -> int {
	return ui.caret_line_count(text)
}

Strip_Pill_Markers :: proc(text: string) -> string {
	return ui.strip_pill_markers(text)
}

Combobox_State_Destroy :: proc(state: ^Combobox_State) {
	assert(state != nil, "Fit.Combobox_State_Destroy: nil state")
	ui.combobox_state_destroy(&state.inner)
}

Calendar_Date_Valid :: proc(value: Calendar_Date) -> bool {
	return ui.calendar_date_valid({value.year, value.month, value.day})
}

Calendar_Format :: proc(value: Calendar_Date) -> string {
	return ui.calendar_format({value.year, value.month, value.day})
}

Chart_Reset :: proc(state: ^Chart_State) {
	assert(state != nil, "Fit.Chart_Reset: nil state")
	state.enter_anim = 0
	state.hover_index = -1
}

Modal_Open :: proc(state: ^Modal_State) {
	assert(state != nil, "Fit.Modal_Open: nil state")
	state.inner.open = true
}

Modal_Is_Open :: proc(state: ^Modal_State) -> bool {
	assert(state != nil, "Fit.Modal_Is_Open: nil state")
	return ui.modal_is_open(&state.inner)
}

Context_Menu_Is_Open :: proc(state: ^Context_Menu_State) -> bool {
	assert(state != nil, "Fit.Context_Menu_Is_Open: nil state")
	return state.inner.open
}

Confirm_Dialog_Is_Open :: proc(state: ^Confirm_Dialog_State) -> bool {
	assert(state != nil, "Fit.Confirm_Dialog_Is_Open: nil state")
	return state.inner.modal.open
}

Modal_Close :: proc(state: ^Modal_State) {
	assert(state != nil, "Fit.Modal_Close: nil state")
	ui.modal_close(&state.inner)
}

Modal_Close_With :: proc(state: ^Modal_State, reason: Modal_Close_Reason) {
	assert(state != nil, "Fit.Modal_Close_With: nil state")
	ui.modal_close(&state.inner, reason)
}

Modal_Take_Close :: proc(state: ^Modal_State) -> Modal_Close_Reason {
	assert(state != nil, "Fit.Modal_Take_Close: nil state")
	return ui.modal_take_close(&state.inner)
}

Popup_Is_Open :: proc(state: ^Popup_State) -> bool {
	assert(state != nil, "Fit.Popup_Is_Open: nil state")
	return ui.popup_is_open(&state.inner)
}

Popup_Close :: proc(state: ^Popup_State) {
	assert(state != nil, "Fit.Popup_Close: nil state")
	ui.popup_close(&state.inner)
}

Popup_Close_With :: proc(state: ^Popup_State, reason: Popup_Close_Reason) {
	assert(state != nil, "Fit.Popup_Close_With: nil state")
	ui.popup_close(&state.inner, ui.Popup_Close_Reason(reason))
}

Popup_Take_Close :: proc(state: ^Popup_State) -> Popup_Close_Reason {
	assert(state != nil, "Fit.Popup_Take_Close: nil state")
	return Popup_Close_Reason(ui.popup_take_close(&state.inner))
}

Widget_Id_From_String :: proc(value: string) -> Widget_Id {
	return Widget_Id(ui.widget_id(value))
}

Widget_Id_From_U64 :: proc(value: u64) -> Widget_Id {
	return Widget_Id(ui.widget_id(value))
}

Theme_Dark :: proc() -> Theme {
	return {inner = ui.theme_dark()}
}

Theme_Light :: proc() -> Theme {
	return {inner = ui.theme_light()}
}

Theme_Retro_Orange :: proc() -> Theme {
	return {inner = ui.theme_retro_orange()}
}

Theme_Retro_Orange_Dark :: proc() -> Theme {
	return {inner = ui.theme_retro_orange_dark()}
}

Theme_Retro_Ingot :: proc() -> Theme {
	return {inner = ui.theme_retro_ingot()}
}

Theme_Retro_Ingot_Dark :: proc() -> Theme {
	return {inner = ui.theme_retro_ingot_dark()}
}

Theme_Terra :: proc() -> Theme {
	return {inner = ui.theme_terra()}
}

Theme_High_Contrast :: proc() -> Theme {
	return {inner = ui.theme_high_contrast()}
}
Theme_From_Palette :: proc(palette: Theme_Palette) -> Theme {
	return {inner = ui.Theme_From_Palette(palette)}
}
Theme_Get_Color :: proc(theme: Theme, role: Theme_Role) -> Color {
	return Color(ui.Theme_Get_Color(theme.inner, role))
}
Theme_Set_Color :: proc(theme: ^Theme, role: Theme_Role, color: Color) {
	assert(theme != nil, "Fit.Theme_Set_Color: nil theme")
	ui.Theme_Set_Color(&theme.inner, role, ui.Color(color))
}
Theme_Validate :: proc(theme: Theme) -> Theme_Validation {
	return ui.Theme_Validate(theme.inner)
}
Theme_Is_Valid :: proc(theme: Theme) -> bool {
	return ui.Theme_Is_Valid(theme.inner)
}
Theme_Pigment :: proc(theme: Theme, pigment: Pigment) -> Color {
	inner := theme.inner
	return Color(ui.theme_pigment(&inner, pigment))
}
Theme_Set_Pigment :: proc(theme: ^Theme, pigment: Pigment, color: Color) {
	assert(theme != nil, "Fit.Theme_Set_Pigment: nil theme")
	ui.Theme_Set_Pigment(&theme.inner, pigment, ui.Color(color))
}
Theme_Set_Substrate :: proc(theme: ^Theme, kind: Substrate_Kind, margin_rule: bool = false) {
	assert(theme != nil, "Fit.Theme_Set_Substrate: nil theme")
	ui.Theme_Set_Substrate(
		&theme.inner,
		{kind = ui.Substrate_Kind(kind), margin_rule = margin_rule},
	)
}
Theme_Set_Reduced_Motion :: proc(theme: ^Theme, enabled: bool) {
	assert(theme != nil, "Fit.Theme_Set_Reduced_Motion: nil theme")
	theme.inner.reduced_motion = enabled
}
Theme_Background :: proc(theme: Theme) -> Color {return Color(theme.inner.bg_app)}
Color_Tinted :: proc(color: Color, tint: Tint) -> Color {
	return Color(ui.color_tinted(ui.Color(color), tint))
}
Tint_Alpha :: proc(tint: Tint) -> u8 {
	return ui.tint_alpha(tint)
}
Contrast_Ratio :: proc(a, b: Color) -> f64 {
	return ui.contrast_ratio(ui.Color(a), ui.Color(b))
}

Context_Menu_Open :: proc(state: ^Context_Menu_State, point: Point) {
	assert(state != nil, "Fit.Context_Menu_Open: nil state")
	ui.context_menu_open(&state.inner, i32(point.x), i32(point.y))
}

Confirm_Dialog_Open :: proc(state: ^Confirm_Dialog_State) {
	assert(state != nil, "Fit.Confirm_Dialog_Open: nil state")
	ui.confirm_dialog_open(&state.inner)
}

Toast_Push :: proc(state: ^Toast_State, kind: Toast_Kind, message: string) {
	assert(state != nil, "Fit.Toast_Push: nil state")
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

Point_In_Rect :: proc(point: Point, rect: Float_Rect) -> bool {
	return(
		point.x >= rect.x &&
		point.y >= rect.y &&
		point.x < rect.x + rect.width &&
		point.y < rect.y + rect.height \
	)
}
