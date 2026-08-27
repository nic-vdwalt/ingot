package fit

import "ingot:ui"

Virtual_List_State :: struct {
	inner: ui.Virtual_List_State,
}
Virtual_List_Window :: struct {
	first:        int,
	visible_rows: int,
	row_height:   i32,
	row_width:    i32,
}
Split_Pane_State :: struct {
	inner: ui.Split_Pane_State,
}
Split_Pane_Result :: struct {
	first:   Rect,
	divider: Rect,
	second:  Rect,
	changed: bool,
}
Time_Of_Day :: struct {
	hour:   i32,
	minute: i32,
	second: i32,
	set:    bool,
}

Virtual_List_Begin :: proc(
	surface: ^Surface,
	key: string,
	state: ^Virtual_List_State,
	row_height: i32,
	count: int,
	visible_height: i32 = 0,
) -> Virtual_List_Window {
	assert(surface != nil && state != nil, "Fit.Virtual_List_Begin: invalid argument")
	inner := ui.virtual_list_begin(
		surface_ui(surface),
		key,
		&state.inner,
		row_height,
		count,
		visible_height,
	)
	return {inner.first, inner.visible_rows, inner.row_height, inner.row_width}
}

Virtual_List_Row :: proc(
	window: Virtual_List_Window,
	state: ^Virtual_List_State,
	index: int,
) -> Rect {
	assert(state != nil, "Fit.Virtual_List_Row: nil state")
	inner := ui.Virtual_List_Window {
		window.first,
		window.visible_rows,
		window.row_height,
		window.row_width,
	}
	return from_rect(ui.virtual_list_row(inner, &state.inner, index))
}

Virtual_List_End :: proc(surface: ^Surface, state: ^Virtual_List_State) {
	assert(surface != nil && state != nil, "Fit.Virtual_List_End: invalid argument")
	ui.virtual_list_end(surface_ui(surface), &state.inner)
}

Split_Pane :: proc(
	surface: ^Surface,
	state: ^Split_Pane_State,
	rect: Rect,
	label: string,
	widget: Widget_Id,
	minimum_first: i32 = 0,
	minimum_second: i32 = 0,
) -> Split_Pane_Result {
	assert(surface != nil && state != nil, "Fit.Split_Pane: invalid argument")
	inner := ui.split_pane(
		surface_ui(surface).frame,
		&state.inner,
		to_rect(rect),
		label,
		ui.Widget_Id(widget),
		minimum_first,
		minimum_second,
	)
	return {
		from_rect(inner.first),
		from_rect(inner.divider),
		from_rect(inner.second),
		inner.changed,
	}
}

Time_Of_Day_Valid :: proc(value: Time_Of_Day) -> bool {
	return ui.time_of_day_valid(ui.Time_Of_Day{value.hour, value.minute, value.second, value.set})
}

Time_Of_Day_Format :: proc(value: Time_Of_Day, show_seconds: bool = false) -> string {
	inner := ui.Time_Of_Day{value.hour, value.minute, value.second, value.set}
	return ui.time_of_day_format(inner, show_seconds)
}

Time_Of_Day_Parse :: proc(value: string, show_seconds: bool = false) -> (Time_Of_Day, bool) {
	inner, ok := ui.time_of_day_parse(value, show_seconds)
	return {inner.hour, inner.minute, inner.second, inner.set}, ok
}

Color_Format_Hex :: proc(value: Color, include_alpha: bool = false) -> string {
	return ui.color_format_hex(ui.Color(value), include_alpha)
}

Color_Parse_Hex :: proc(value: string, allow_alpha: bool = false) -> (Color, bool) {
	result, ok := ui.color_parse_hex(value, allow_alpha)
	return Color(result), ok
}
