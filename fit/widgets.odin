package fit

import "ingot:ui"

Theme :: struct {
	inner: ui.Theme,
}
Pigment :: enum u8 {
	Accent,
	Danger,
	Success,
	Tool,
	Earth,
	Leaf,
}
Visual_State :: enum u8 {
	Rest,
	Hover,
	Pressed,
	Selected,
	Disabled,
}
Surface_Kind :: enum u8 {
	App,
	Panel,
	Card,
	Popup,
	Input,
	Row,
	Chip,
	Code,
	Table_Header,
	Button_Primary,
	Button_Secondary,
	Button_Danger,
	Button_Ghost,
}
Tint :: enum u8 {
	Subtle,
	Light,
	Medium,
	Strong,
}
Elevation :: enum u8 {
	Flat,
	Lifted,
	Overlay,
	Modal,
}
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

Input_Box :: struct {
	inner: ui.Input_Box,
}
Text_Input_State :: struct {
	inner: ui.Text_Input_State,
}
Text_Input_Options :: struct {
	height:    i32,
	masked:    bool,
	semantics: Text_Input_Semantics,
}
Text_Input_Semantics :: struct {
	name: string,
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
Combobox_Item :: struct {
	id:    u64,
	label: string,
}
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
Listbox_Keys :: enum u8 {
	Focused,
	Owned,
	Searched,
}
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
Modal_State :: struct {
	inner: ui.Modal_State,
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

TABLE_COLUMN_COUNT_MAX :: ui.TABLE_COLUMN_COUNT_MAX
PAINT_COMMAND_CAP :: ui.PAINT_COMMAND_CAP
PAINT_TEXT_CAP :: ui.PAINT_TEXT_CAP
Z_PANEL :: ui.Z_PANEL
Z_POPUP :: ui.Z_POPUP
ROOT_EXTENT_OPEN :: ui.ROOT_EXTENT_OPEN

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

Theme_Dark :: proc() -> Theme {return {inner = ui.theme_dark()}}
Theme_Light :: proc() -> Theme {return {inner = ui.theme_light()}}
Theme_Sketch_Warm :: proc() -> Theme {return {inner = ui.theme_sketch_warm()}}
Theme_Sketch_Grey :: proc() -> Theme {return {inner = ui.theme_sketch_grey()}}
Theme_High_Contrast :: proc() -> Theme {return {inner = ui.theme_high_contrast()}}
Theme_Pigment :: proc(theme: Theme, pigment: Pigment) -> Color {
	inner := theme.inner
	return Color(ui.theme_pigment(&inner, ui.Pigment(pigment)))
}
Theme_Set_Reduced_Motion :: proc(theme: ^Theme, enabled: bool) {
	assert(theme != nil, "Fit.Theme_Set_Reduced_Motion: nil theme")
	theme.inner.reduced_motion = enabled
}
Theme_Background :: proc(theme: Theme) -> Color {return Color(theme.inner.bg_app)}
Color_Tinted :: proc(color: Color, tint: Tint) -> Color {
	return Color(ui.color_tinted(ui.Color(color), ui.Tint(tint)))
}
Tint_Alpha :: proc(tint: Tint) -> u8 {return ui.tint_alpha(ui.Tint(tint))}
Contrast_Ratio :: proc(a, b: Color) -> f64 {
	return ui.contrast_ratio(ui.Color(a), ui.Color(b))
}

Checkbox_At :: ui.checkbox_at
Radio_At :: ui.radio_at
Slider_At :: ui.slider_at
Slider_At_State :: ui.slider_at_state
Dropdown_At :: ui.dropdown_at
Combobox_At :: ui.combobox_at
Date_Picker_At :: ui.date_picker_at
Text_Input_Box :: ui.text_input_box
Line_Chart_At :: ui.line_chart_at
Bar_Chart_At :: ui.bar_chart_at
Sparkline_At :: ui.sparkline_at
Tooltip_At :: ui.tooltip_wrapped_at
Card_Background_At :: ui.card_bg_at
Section_Header_At :: ui.section_header_at
List_Row_Background_At :: ui.list_row_bg_at

Context_Menu_Open :: ui.context_menu_open
Context_Menu :: ui.context_menu
Confirm_Dialog_Open :: ui.confirm_dialog_open
Confirm_Dialog :: ui.confirm_dialog
Toast_Push :: ui.toast_push

Rect_F32 :: ui.rect_f32
Point_In_Rect :: ui.point_in_rect
