package fit

import "ingot:ui"

Collapsible_Options :: struct {
	icon:        rune,
	right_label: string,
}

Spinner_Style :: enum u8 {
	Arc,
	Orbit_Dots,
}

Spinner_Options :: struct {
	style:      Spinner_Style,
	dot_radius: f32,
	speed:      f32,
}

Settings_Panel_Result :: struct {
	applied:   bool,
	ui_scale:  f32,
	dismissed: bool,
}

Surface_App_Header :: proc(surface: ^Surface, title: cstring, width: i32) -> i32 {
	u := surface_ui(surface)
	return ui.draw_app_header(u.frame, title, width)
}

Surface_Debug_Overlay :: proc(surface: ^Surface, x, y: i32) -> i32 {
	u := surface_ui(surface)
	return ui.draw_debug_overlay(u.frame, x, y)
}

Surface_Scale_Settings :: proc(
	surface: ^Surface,
	selected: ^int,
	current: f32,
	width, height: i32,
) -> Settings_Panel_Result {
	u := surface_ui(surface)
	result := ui.draw_scale_settings_panel(u.frame, selected, current, width, height)
	return {result.applied, result.ui_scale, result.dismissed}
}

Surface_Section_Header :: proc(surface: ^Surface, rect: Rect, label: string) -> i32 {
	u := surface_ui(surface)
	return ui.section_header_at(u.frame, to_rect(rect), label)
}

Surface_Card_Background :: proc(
	surface: ^Surface,
	rect: Rect,
	background: Color,
	accent: Color = {},
	accent_width: i32 = 0,
) {
	u := surface_ui(surface)
	ui.card_bg_at(u.frame, to_rect(rect), ui.Color(background), ui.Color(accent), accent_width)
}

Surface_List_Row_Background :: proc(surface: ^Surface, rect: Rect, selected, hovered: bool) {
	u := surface_ui(surface)
	ui.list_row_bg_at(u.frame, to_rect(rect), selected, hovered)
}

Surface_Listbox_Begin :: proc(
	surface: ^Surface,
	state: ^Listbox_State,
	config: Listbox_Config,
) -> Listbox_Result {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Listbox_Begin: nil state")
	inner := ui.Listbox_Config {
		rect         = to_rect(config.rect),
		label        = config.label,
		stable_id    = config.stable_id,
		count        = config.count,
		selected     = config.selected,
		wrap         = config.wrap,
		hover_select = config.hover_select,
		keys         = ui.Listbox_Keys(config.keys),
		page_rows    = config.page_rows,
	}
	return from_listbox_result(ui.listbox_begin(u.frame, &state.inner, inner))
}

Surface_Selectable_Row :: proc(
	surface: ^Surface,
	state: ^Listbox_State,
	config: Listbox_Config,
	row: Selectable_Row_Config,
) -> Selectable_Row_Result {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Selectable_Row: nil state")
	inner_config := ui.Listbox_Config {
		rect         = to_rect(config.rect),
		label        = config.label,
		stable_id    = config.stable_id,
		count        = config.count,
		selected     = config.selected,
		wrap         = config.wrap,
		hover_select = config.hover_select,
		keys         = ui.Listbox_Keys(config.keys),
		page_rows    = config.page_rows,
	}
	inner_row := ui.Selectable_Row_Config {
		rect        = to_rect(row.rect),
		label       = row.label,
		stable_id   = row.stable_id,
		index       = row.index,
		disabled    = row.disabled,
		description = row.description,
	}
	return from_selectable_row_result(
		ui.selectable_row(u.frame, &state.inner, inner_config, inner_row),
	)
}

Surface_Listbox_End :: proc(surface: ^Surface, state: ^Listbox_State) {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Listbox_End: nil state")
	ui.listbox_end(u.frame, &state.inner)
}

Surface_Modal_Begin :: proc(
	surface: ^Surface,
	state: ^Modal_State,
	title: string,
	size: [2]i32,
) -> Rect {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Modal_Begin: nil state")
	return from_rect(
		ui.modal_begin(
			u.frame,
			&state.inner,
			title,
			{size = size, screen = ui.frame_viewport(u.frame)},
		),
	)
}

Surface_Modal_End :: proc(surface: ^Surface, state: ^Modal_State) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Modal_End: nil state")
	ui.modal_end(&state.inner)
}

Region_Id :: proc(region: ^Region, key: string) -> Widget_Id {
	assert(region != nil && region.inner.open, "Fit.Region_Id: region not open")
	return Widget_Id(ui.id(&region.inner, key))
}

Region_Scope_Begin :: proc(region: ^Region, key: string) {
	assert(region != nil && region.inner.open, "Fit.Region_Scope_Begin: region not open")
	ui.scope_begin(&region.inner, key)
}

Region_Scope_End :: proc(region: ^Region) {
	assert(region != nil && region.inner.open, "Fit.Region_Scope_End: region not open")
	ui.scope_end(&region.inner)
}

Region_Padding :: proc(region: ^Region, space: Space) {
	assert(region != nil && region.inner.open, "Fit.Region_Padding: region not open")
	ui.padding(&region.inner, ui.Space(space))
}

Region_Separator :: proc(region: ^Region) {
	assert(region != nil && region.inner.open, "Fit.Region_Separator: region not open")
	ui.separator(&region.inner)
}

Region_Row_Begin :: proc(
	region: ^Region,
	height: i32,
	gap: Space = .None,
	align: Cross_Align = .Stretch,
) {
	assert(region != nil && region.inner.open, "Fit.Region_Row_Begin: region not open")
	ui.row_begin(&region.inner, height, ui.Space(gap), ui.Cross_Align(align))
}

Region_Row_End :: proc(region: ^Region) {
	assert(region != nil && region.inner.open, "Fit.Region_Row_End: region not open")
	ui.row_end(&region.inner)
}

Region_Flex_Row_Begin :: proc(
	region: ^Region,
	height: i32,
	tracks: []Track,
	gap: Space = .None,
	align: Cross_Align = .Stretch,
	justify: Main_Align = .Start,
) {
	assert(region != nil && region.inner.open, "Fit.Region_Flex_Row_Begin: region not open")
	assert(len(tracks) <= ui.MAX_LAYOUT_FLEX, "Fit.Region_Flex_Row_Begin: too many tracks")
	inner: [ui.MAX_LAYOUT_FLEX]ui.Track
	for track, index in tracks do inner[index] = to_track(track)
	ui.flex_row_begin(
		&region.inner,
		height,
		inner[:len(tracks)],
		ui.Space(gap),
		ui.Cross_Align(align),
		ui.Main_Align(justify),
	)
}

Region_Flex_Slot_Next :: proc(region: ^Region, cross_size: i32) -> Rect {
	assert(region != nil && region.inner.open, "Fit.Region_Flex_Slot_Next: region not open")
	return from_rect(ui.flex_slot_next(&region.inner, cross_size))
}

Region_Flex_Row_End :: proc(region: ^Region) {
	assert(region != nil && region.inner.open, "Fit.Region_Flex_Row_End: region not open")
	ui.flex_row_end(&region.inner)
}

Region_Icon_Button :: proc(region: ^Region, widget: Widget_Id, label: string) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Icon_Button: region not open")
	return ui.icon_btn(&region.inner, ui.Widget_Id(widget), label)
}

Region_Back_Button :: proc(region: ^Region, widget: Widget_Id, label: string) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Back_Button: region not open")
	return ui.back_btn(&region.inner, ui.Widget_Id(widget), label)
}

Region_Collapsible_Header :: proc(
	region: ^Region,
	widget: Widget_Id,
	label: string,
	open: ^bool,
	options: Collapsible_Options = {},
) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Collapsible_Header: region not open")
	return ui.collapsible_header(
		&region.inner,
		ui.Widget_Id(widget),
		label,
		open,
		{icon = options.icon, right_label = options.right_label},
	)
}

Region_Slider :: proc(
	region: ^Region,
	widget: Widget_Id,
	state: ^Slider_State,
	value: ^f32,
	minimum, maximum, step: f32,
	width: i32,
	label: string,
) -> bool {
	assert(region != nil && region.inner.open && state != nil, "Fit.Region_Slider: invalid state")
	return ui.slider_state(
		&region.inner,
		ui.Widget_Id(widget),
		&state.inner,
		value,
		minimum,
		maximum,
		step,
		width,
		label,
	)
}

Region_Dropdown :: proc(
	region: ^Region,
	widget: Widget_Id,
	items: []string,
	selected: ^i32,
	state: ^Dropdown_State,
	a11y_label: string = "Dropdown",
) -> bool {
	assert(
		region != nil && region.inner.open && state != nil,
		"Fit.Region_Dropdown: invalid state",
	)
	return ui.dropdown(
		&region.inner,
		ui.Widget_Id(widget),
		items,
		selected,
		&state.inner,
		a11y_label = a11y_label,
	)
}

Region_Combobox :: proc(
	region: ^Region,
	key: string,
	state: ^Combobox_State,
	items: []Combobox_Item,
	selected: ^u64,
	placeholder, a11y_label: string,
) -> bool {
	assert(
		region != nil && region.inner.open && state != nil,
		"Fit.Region_Combobox: invalid state",
	)
	return ui.combobox(
		&region.inner,
		key,
		&state.inner,
		transmute([]ui.Combobox_Item)items,
		selected,
		placeholder,
		a11y_label,
	)
}

Region_Date_Picker :: proc(
	region: ^Region,
	key: string,
	state: ^Date_Picker_State,
	value: ^Calendar_Date,
	placeholder, a11y_label: string,
) -> bool {
	assert(
		region != nil && region.inner.open && state != nil,
		"Fit.Region_Date_Picker: invalid state",
	)
	inner := ui.Calendar_Date{value.year, value.month, value.day}
	changed := ui.date_picker(&region.inner, key, &state.inner, &inner, placeholder, a11y_label)
	value^ = {inner.year, inner.month, inner.day}
	return changed
}

Region_Spinner :: proc(region: ^Region, diameter: i32, options: Spinner_Options = {}) {
	assert(region != nil && region.inner.open, "Fit.Region_Spinner: region not open")
	ui.spinner(
		&region.inner,
		diameter,
		{
			style = ui.Spinner_Style(options.style),
			dot_radius = options.dot_radius,
			speed = options.speed,
		},
	)
}

Region_Status_Pill :: proc(region: ^Region, text: string, ink: Ink) -> i32 {
	assert(region != nil && region.inner.open, "Fit.Region_Status_Pill: region not open")
	return ui.status_pill(&region.inner, text, ui.Ink(ink))
}

Region_Progress_Bar :: proc(region: ^Region, fraction: f32) {
	assert(region != nil && region.inner.open, "Fit.Region_Progress_Bar: region not open")
	ui.progress_bar(&region.inner, fraction)
}

Region_Progress_Bar_Animated :: proc(region: ^Region, fraction: f32, animation: ^f32, ink: Ink) {
	assert(region != nil && region.inner.open, "Fit.Region_Progress_Bar_Animated: region not open")
	ui.progress_bar_animated(&region.inner, fraction, animation, ui.Ink(ink))
}

Region_Key_Value :: proc(region: ^Region, key, value: string) {
	assert(region != nil && region.inner.open, "Fit.Region_Key_Value: region not open")
	ui.kv_row(&region.inner, key, value)
}

Region_Table_Header :: proc(
	region: ^Region,
	key: string,
	columns: []Table_Column,
	sort: ^Table_Sort,
) -> bool {
	assert(
		region != nil && region.inner.open && sort != nil,
		"Fit.Region_Table_Header: invalid state",
	)
	assert(len(columns) <= TABLE_COLUMN_COUNT_MAX, "Fit.Region_Table_Header: too many columns")
	inner_columns: [TABLE_COLUMN_COUNT_MAX]ui.Table_Column
	for column, index in columns {
		inner_columns[index] = {column.label, to_track(column.track), column.numeric}
	}
	inner_sort := ui.Table_Sort{sort.column, sort.descending}
	changed := ui.table_header(&region.inner, key, inner_columns[:len(columns)], &inner_sort)
	sort^ = {inner_sort.column, inner_sort.descending}
	return changed
}

Table_Tracks :: proc(columns: []Table_Column, buffer: []Track) -> []Track {
	assert(len(columns) > 0 && len(buffer) >= len(columns), "Fit.Table_Tracks: invalid buffer")
	for column, index in columns do buffer[index] = column.track
	return buffer[:len(columns)]
}
