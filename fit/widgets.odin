package fit

import "ingot:ui"

Vector2 :: ui.Vector2
Rectangle :: ui.Rectangle
Theme :: ui.Theme
Pigment :: ui.Pigment
Visual_State :: ui.Visual_State
Surface_Role :: ui.Surface
Surface_Kind :: ui.Surface
Tint :: ui.Tint

Input_Box :: struct {
	inner: ui.Input_Box,
}
Text_Input_State :: struct {
	inner: ui.Text_Input_State,
}
Text_Input_Options :: struct {
	inner: ui.Text_Input_Options,
}
Text_Input_Semantics :: struct {
	inner: ui.Text_Input_Semantics,
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
	inner: ui.Combobox_Item,
}
Date_Picker_State :: struct {
	inner: ui.Date_Picker_State,
}
Calendar_Date :: struct {
	inner: ui.Calendar_Date,
}
Tooltip_State :: struct {
	inner: ui.Tooltip_State,
}
Listbox_State :: struct {
	inner: ui.Listbox_State,
}
Listbox_Config :: struct {
	inner: ui.Listbox_Config,
}
Table_Sort :: struct {
	inner: ui.Table_Sort,
}
Table_Column :: struct {
	inner: ui.Table_Column,
}
Chart_State :: struct {
	inner: ui.Chart_State,
}
Chart_Series :: struct {
	inner: ui.Chart_Series,
}
Modal_State :: struct {
	inner: ui.Modal_State,
}
Context_Menu_State :: struct {
	inner: ui.Context_Menu_State,
}
Menu_Item :: struct {
	inner: ui.Menu_Item,
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
	return ui.calendar_date_valid(value.inner)
}

Calendar_Format :: proc(value: Calendar_Date) -> string {
	return ui.calendar_format(value.inner)
}

Theme_Dark :: ui.theme_dark
Theme_Light :: ui.theme_light
Theme_Sketch_Warm :: ui.theme_sketch_warm
Theme_Sketch_Grey :: ui.theme_sketch_grey
Theme_High_Contrast :: ui.theme_high_contrast
Theme_Pigment :: ui.theme_pigment
Color_Tinted :: ui.color_tinted
Tint_Alpha :: ui.tint_alpha
Contrast_Ratio :: ui.contrast_ratio
Space_Pixels :: ui.space_pixels
Text_Role_Size :: ui.text_role_size
Text_Role_Line_Height :: ui.text_role_line_height

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
