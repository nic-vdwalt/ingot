package fit

import "ingot:ui"

Virtual_List_State :: struct {
	inner: ui.Virtual_List_State,
}
Virtual_List_Window :: ui.Virtual_List_Window
Split_Pane_State :: struct {
	inner: ui.Split_Pane_State,
}
Split_Pane_Result :: ui.Split_Pane_Result
Time_Of_Day :: ui.Time_Of_Day

virtual_list_begin :: proc(
	surface: ^Surface,
	key: string,
	state: ^Virtual_List_State,
	row_height: i32,
	count: int,
	visible_height: i32 = 0,
) -> Virtual_List_Window {
	assert(surface != nil && state != nil, "fit.virtual_list_begin: invalid argument")
	return ui.virtual_list_begin(
		surface_ui(surface),
		key,
		&state.inner,
		row_height,
		count,
		visible_height,
	)
}

virtual_list_row :: proc(
	window: Virtual_List_Window,
	state: ^Virtual_List_State,
	index: int,
) -> Rect {
	assert(state != nil, "fit.virtual_list_row: nil state")
	return ui.virtual_list_row(window, &state.inner, index)
}

virtual_list_end :: proc(surface: ^Surface, state: ^Virtual_List_State) {
	assert(surface != nil && state != nil, "fit.virtual_list_end: invalid argument")
	ui.virtual_list_end(surface_ui(surface), &state.inner)
}

split_pane :: proc(
	surface: ^Surface,
	state: ^Split_Pane_State,
	rect: Rect,
	label: string,
	widget: Widget_Id,
	minimum_first: i32 = 0,
	minimum_second: i32 = 0,
) -> Split_Pane_Result {
	assert(surface != nil && state != nil, "fit.split_pane: invalid argument")
	return ui.split_pane(
		surface_ui(surface).frame,
		&state.inner,
		rect,
		label,
		widget,
		minimum_first,
		minimum_second,
	)
}

time_of_day_valid :: proc(value: Time_Of_Day) -> bool {
	return ui.time_of_day_valid(value)
}

time_of_day_format :: proc(value: Time_Of_Day, show_seconds: bool = false) -> string {
	return ui.time_of_day_format(value, show_seconds)
}

time_of_day_parse :: proc(value: string, show_seconds: bool = false) -> (Time_Of_Day, bool) {
	return ui.time_of_day_parse(value, show_seconds)
}

color_format_hex :: proc(value: Color, include_alpha: bool = false) -> string {
	return ui.color_format_hex(value, include_alpha)
}

color_parse_hex :: proc(value: string, allow_alpha: bool = false) -> (Color, bool) {
	return ui.color_parse_hex(value, allow_alpha)
}
