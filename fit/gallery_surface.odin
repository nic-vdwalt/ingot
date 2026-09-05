package fit

import "ingot:ui"

Collapsible_Options :: struct {
	icon:        rune,
	right_label: string,
}

Spinner_Style :: ui.Spinner_Style

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

Surface_Section_Header_Height :: proc(surface: ^Surface) -> i32 {
	u := surface_ui(surface)
	return ui.section_header_height(u.frame)
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
		keys         = config.keys,
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
		keys         = config.keys,
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

modal_config :: proc(surface: ^Surface, size: [2]i32, options: Modal_Options) -> ui.Modal_Config {
	u := surface_ui(surface)
	dismiss: ui.Modal_Dismiss_Policy
	if options.dismiss_escape do dismiss += {.Escape}
	if options.dismiss_outside do dismiss += {.Outside_Click}
	host := ui.frame_viewport(u.frame)
	if options.scope == .Host {
		assert(options.host.w > 0 && options.host.h > 0, "Fit modal: empty host")
		host = to_rect(options.host)
	}
	return {
		placement = options.placement,
		size = size,
		screen = host,
		dismiss = dismiss,
		focus_scope = options.focus_scope,
		initial_focus = options.initial_focus,
		restore_focus = options.restore_focus,
		host_scoped = options.scope == .Host,
	}
}

Surface_Modal_Open :: proc(
	surface: ^Surface,
	state: ^Modal_State,
	id: Modal_Id,
	options: Modal_Options = {dismiss_escape = true},
) -> bool {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Modal_Open: nil state")
	return ui.modal_open(
		u.frame,
		&state.inner,
		ui.Modal_Id(id),
		modal_config(surface, {1, 1}, options),
	)
}

Surface_Modal_Begin :: proc(
	surface: ^Surface,
	state: ^Modal_State,
	title: string,
	size: [2]i32,
	options: Modal_Options = {dismiss_escape = true},
) -> Rect {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Modal_Begin: nil state")
	return from_rect(
		ui.modal_begin(u.frame, &state.inner, title, modal_config(surface, size, options)),
	)
}

Surface_Modal_End :: proc(surface: ^Surface, state: ^Modal_State) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Modal_End: nil state")
	ui.modal_end(&state.inner)
}

Surface_Modal_Builder_With :: proc(
	surface: ^Surface,
	state: ^Modal_State,
	title: string,
	size: [2]i32,
	builder: ^Builder,
	draw: Draw_Proc,
	user_data: rawptr = nil,
	options: Modal_Options = {dismiss_escape = true},
	padding: i32 = 8,
) -> Modal_Close_Reason {
	assert(surface != nil && state != nil, "Fit modal builder: invalid state")
	assert(builder != nil && draw != nil, "Fit modal builder: invalid body")
	assert(padding >= 0, "Fit modal builder: negative padding")
	body := Surface_Modal_Begin(surface, state, title, size, options)
	content := from_rect(ui.rect_inset(to_rect(body), ui.insets(padding)))
	Surface_Builder_With(surface, builder, content, draw, user_data)
	Surface_Modal_End(surface, state)
	return Modal_Take_Close(state)
}

popup_config :: proc(options: Popup_Options) -> ui.Popup_Config {
	return {
		anchor = to_rect(options.anchor),
		viewport = to_rect(options.viewport),
		preferred_size = options.preferred_size,
		placement = ui.Popup_Placement(options.placement),
		dismiss_escape = options.dismiss_escape,
		dismiss_outside = options.dismiss_outside,
		focus_scope = options.focus_scope,
		initial_focus = options.initial_focus,
		restore_focus = options.restore_focus,
	}
}

Surface_Popup_Open :: proc(
	surface: ^Surface,
	state: ^Popup_State,
	id: Popup_Id,
	options: Popup_Options,
) {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Popup_Open: nil state")
	ui.popup_open(u.frame, &state.inner, ui.Popup_Id(id), popup_config(options))
}

Surface_Popup_Begin :: proc(
	surface: ^Surface,
	state: ^Popup_State,
	options: Popup_Options,
) -> Rect {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Popup_Begin: nil state")
	return from_rect(ui.popup_begin(u.frame, &state.inner, popup_config(options)))
}

Surface_Popup_End :: proc(surface: ^Surface, state: ^Popup_State) {
	_ = surface_ui(surface)
	assert(state != nil, "Fit.Surface_Popup_End: nil state")
	ui.popup_end(&state.inner)
}

Surface_Popup_Builder_With :: proc(
	surface: ^Surface,
	state: ^Popup_State,
	builder: ^Builder,
	draw: Draw_Proc,
	user_data: rawptr = nil,
	options: Popup_Options,
) -> Popup_Close_Reason {
	assert(surface != nil && state != nil, "Fit popup builder: invalid state")
	assert(builder != nil && draw != nil, "Fit popup builder: invalid body")
	body := Surface_Popup_Begin(surface, state, options)
	Surface_Builder_With(surface, builder, body, draw, user_data)
	Surface_Popup_End(surface, state)
	return Popup_Take_Close(state)
}

Region_Id_String :: proc(region: ^Region, key: string) -> Widget_Id {
	assert(region != nil && region.inner.open, "Fit.Region_Id: region not open")
	return Widget_Id(ui.id(&region.inner, key))
}

Region_Id_U64 :: proc(region: ^Region, key: u64) -> Widget_Id {
	assert(region != nil && region.inner.open, "Fit.Region_Id: region not open")
	return Widget_Id(ui.id(&region.inner, key))
}

Region_Id :: proc {
	Region_Id_String,
	Region_Id_U64,
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
	ui.padding(&region.inner, space)
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
	ui.row_begin(&region.inner, height, gap, align)
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
	ui.flex_row_begin(&region.inner, height, inner[:len(tracks)], gap, align, justify)
}

Region_Flex_Slot_Next :: proc(region: ^Region, cross_size: i32) -> Rect {
	assert(region != nil && region.inner.open, "Fit.Region_Flex_Slot_Next: region not open")
	return from_rect(ui.flex_slot_next(&region.inner, cross_size))
}

Region_Flex_Row_End :: proc(region: ^Region) {
	assert(region != nil && region.inner.open, "Fit.Region_Flex_Row_End: region not open")
	ui.flex_row_end(&region.inner)
}

Region_Icon_Button_Id :: proc(region: ^Region, widget: Widget_Id, label: string) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Icon_Button: region not open")
	return ui.icon_btn(&region.inner, ui.Widget_Id(widget), label)
}

Region_Icon_Button_String :: proc(region: ^Region, key, label: string) -> bool {
	return Region_Icon_Button_Id(region, Region_Id(region, key), label)
}

Region_Icon_Button_U64 :: proc(region: ^Region, key: u64, label: string) -> bool {
	return Region_Icon_Button_Id(region, Region_Id(region, key), label)
}

Region_Icon_Button :: proc {
	Region_Icon_Button_String,
	Region_Icon_Button_U64,
	Region_Icon_Button_Id,
}

Region_Back_Button_Id :: proc(region: ^Region, widget: Widget_Id, label: string) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Back_Button: region not open")
	return ui.back_btn(&region.inner, ui.Widget_Id(widget), label)
}

Region_Back_Button_String :: proc(region: ^Region, key, label: string) -> bool {
	return Region_Back_Button_Id(region, Region_Id(region, key), label)
}

Region_Back_Button_U64 :: proc(region: ^Region, key: u64, label: string) -> bool {
	return Region_Back_Button_Id(region, Region_Id(region, key), label)
}

Region_Back_Button :: proc {
	Region_Back_Button_String,
	Region_Back_Button_U64,
	Region_Back_Button_Id,
}

Region_Collapsible_Header_Id :: proc(
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

Region_Collapsible_Header_String :: proc(
	region: ^Region,
	key, label: string,
	open: ^bool,
	options: Collapsible_Options = {},
) -> bool {
	return Region_Collapsible_Header_Id(region, Region_Id(region, key), label, open, options)
}

Region_Collapsible_Header_U64 :: proc(
	region: ^Region,
	key: u64,
	label: string,
	open: ^bool,
	options: Collapsible_Options = {},
) -> bool {
	return Region_Collapsible_Header_Id(region, Region_Id(region, key), label, open, options)
}

Region_Collapsible_Header :: proc {
	Region_Collapsible_Header_String,
	Region_Collapsible_Header_U64,
	Region_Collapsible_Header_Id,
}

Region_Slider_Id :: proc(
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

Region_Slider_String :: proc(
	region: ^Region,
	key: string,
	state: ^Slider_State,
	value: ^f32,
	minimum, maximum, step: f32,
	width: i32,
	label: string,
) -> bool {
	return Region_Slider_Id(
		region,
		Region_Id(region, key),
		state,
		value,
		minimum,
		maximum,
		step,
		width,
		label,
	)
}

Region_Slider_U64 :: proc(
	region: ^Region,
	key: u64,
	state: ^Slider_State,
	value: ^f32,
	minimum, maximum, step: f32,
	width: i32,
	label: string,
) -> bool {
	return Region_Slider_Id(
		region,
		Region_Id(region, key),
		state,
		value,
		minimum,
		maximum,
		step,
		width,
		label,
	)
}

Region_Slider :: proc {
	Region_Slider_String,
	Region_Slider_U64,
	Region_Slider_Id,
}

Region_Dropdown_Id :: proc(
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

Region_Dropdown_String :: proc(
	region: ^Region,
	key: string,
	items: []string,
	selected: ^i32,
	state: ^Dropdown_State,
	a11y_label: string = "Dropdown",
) -> bool {
	return Region_Dropdown_Id(region, Region_Id(region, key), items, selected, state, a11y_label)
}

Region_Dropdown_U64 :: proc(
	region: ^Region,
	key: u64,
	items: []string,
	selected: ^i32,
	state: ^Dropdown_State,
	a11y_label: string = "Dropdown",
) -> bool {
	return Region_Dropdown_Id(region, Region_Id(region, key), items, selected, state, a11y_label)
}

Region_Dropdown :: proc {
	Region_Dropdown_String,
	Region_Dropdown_U64,
	Region_Dropdown_Id,
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
	return ui.combobox(&region.inner, key, &state.inner, items, selected, placeholder, a11y_label)
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
		{style = options.style, dot_radius = options.dot_radius, speed = options.speed},
	)
}

Region_Status_Pill :: proc(region: ^Region, text: string, ink: Ink) -> i32 {
	assert(region != nil && region.inner.open, "Fit.Region_Status_Pill: region not open")
	return ui.status_pill(&region.inner, text, ink)
}

Region_Progress_Bar :: proc(region: ^Region, fraction: f32) {
	assert(region != nil && region.inner.open, "Fit.Region_Progress_Bar: region not open")
	ui.progress_bar(&region.inner, fraction)
}

Region_Progress_Bar_Animated :: proc(region: ^Region, fraction: f32, animation: ^f32, ink: Ink) {
	assert(region != nil && region.inner.open, "Fit.Region_Progress_Bar_Animated: region not open")
	ui.progress_bar_animated(&region.inner, fraction, animation, ink)
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
