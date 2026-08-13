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

Rect_F32 :: ui.rect_f32
Point_In_Rect :: ui.point_in_rect
