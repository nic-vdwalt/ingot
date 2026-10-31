package fit

import "ingot:ui"

Collapsible_Options :: struct {
	icon:        rune,
	right_label: string,
	motion:      ^Control_Motion_State,
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

surface_app_header :: proc(surface: ^Surface, title: cstring, width: i32) -> i32 {
	u := surface_ui(surface)
	return ui.draw_app_header(u.frame, title, width)
}

surface_debug_overlay :: proc(surface: ^Surface, x, y: i32) -> i32 {
	u := surface_ui(surface)
	return ui.draw_debug_overlay(u.frame, x, y)
}

surface_scale_settings :: proc(
	surface: ^Surface,
	selected: ^int,
	current: f32,
	width, height: i32,
) -> Settings_Panel_Result {
	u := surface_ui(surface)
	result := ui.draw_scale_settings_panel(u.frame, selected, current, width, height)
	return {result.applied, result.ui_scale, result.dismissed}
}

surface_section_header :: proc(surface: ^Surface, rect: Rect, label: string) -> i32 {
	u := surface_ui(surface)
	return ui.section_header_at(u.frame, rect, label)
}

surface_section_header_height :: proc(surface: ^Surface) -> i32 {
	u := surface_ui(surface)
	return ui.section_header_height(u.frame)
}

surface_card_background :: proc(
	surface: ^Surface,
	rect: Rect,
	background: Color,
	accent: Color = {},
	accent_width: i32 = 0,
) {
	u := surface_ui(surface)
	ui.card_bg_at(u.frame, rect, ui.Color(background), ui.Color(accent), accent_width)
}

surface_list_row_background :: proc(surface: ^Surface, rect: Rect, selected, hovered: bool) {
	u := surface_ui(surface)
	ui.list_row_bg_at(u.frame, rect, selected, hovered)
}

surface_listbox_begin :: proc(
	surface: ^Surface,
	state: ^Listbox_State,
	config: Listbox_Config,
) -> Listbox_Result {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_listbox_begin: nil state")
	return ui.listbox_begin(u.frame, &state.inner, config)
}

surface_selectable_row :: proc(
	surface: ^Surface,
	state: ^Listbox_State,
	config: Listbox_Config,
	row: Selectable_Row_Config,
) -> Selectable_Row_Result {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_selectable_row: nil state")
	return ui.selectable_row(u.frame, &state.inner, config, row)
}

surface_listbox_end :: proc(surface: ^Surface, state: ^Listbox_State) {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_listbox_end: nil state")
	ui.listbox_end(u.frame, &state.inner)
}

@(private = "file")
modal_config :: proc(surface: ^Surface, size: [2]i32, options: Modal_Options) -> ui.Modal_Config {
	u := surface_ui(surface)
	dismiss: ui.Modal_Dismiss_Policy
	if options.dismiss_escape do dismiss += {.Escape}
	if options.dismiss_outside do dismiss += {.Outside_Click}
	host := ui.frame_viewport(u.frame)
	if options.scope == .Host {
		assert(options.host.w > 0 && options.host.h > 0, "fit modal: empty host")
		host = options.host
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

surface_modal_open :: proc(
	surface: ^Surface,
	state: ^Modal_State,
	id: Modal_Id,
	options: Modal_Options = {dismiss_escape = true},
) -> bool {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_modal_open: nil state")
	return ui.modal_open(u.frame, &state.inner, id, modal_config(surface, {1, 1}, options))
}

surface_modal_begin :: proc(
	surface: ^Surface,
	state: ^Modal_State,
	title: string,
	size: [2]i32,
	options: Modal_Options = {dismiss_escape = true},
) -> Rect {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_modal_begin: nil state")
	return ui.modal_begin(u.frame, &state.inner, title, modal_config(surface, size, options))
}

surface_modal_end :: proc(surface: ^Surface, state: ^Modal_State) {
	_ = surface_ui(surface)
	assert(state != nil, "fit.surface_modal_end: nil state")
	ui.modal_end(&state.inner)
}

surface_modal_builder_with :: proc(
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
	assert(surface != nil && state != nil, "fit modal builder: invalid state")
	assert(builder != nil && draw != nil, "fit modal builder: invalid body")
	assert(padding >= 0, "fit modal builder: negative padding")
	body := surface_modal_begin(surface, state, title, size, options)
	content := ui.rect_inset(body, ui.insets(padding))
	surface_builder_with(surface, builder, content, draw, user_data)
	surface_modal_end(surface, state)
	return modal_take_close(state)
}

surface_popup_open :: proc(
	surface: ^Surface,
	state: ^Popup_State,
	id: Popup_Id,
	options: Popup_Options,
) {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_popup_open: nil state")
	ui.popup_open(u.frame, &state.inner, id, options)
}

surface_popup_begin :: proc(
	surface: ^Surface,
	state: ^Popup_State,
	options: Popup_Options,
) -> Rect {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_popup_begin: nil state")
	return ui.popup_begin(u.frame, &state.inner, options)
}

surface_popup_end :: proc(surface: ^Surface, state: ^Popup_State) {
	_ = surface_ui(surface)
	assert(state != nil, "fit.surface_popup_end: nil state")
	ui.popup_end(&state.inner)
}

surface_popup_builder_with :: proc(
	surface: ^Surface,
	state: ^Popup_State,
	builder: ^Builder,
	draw: Draw_Proc,
	user_data: rawptr = nil,
	options: Popup_Options,
) -> Popup_Close_Reason {
	assert(surface != nil && state != nil, "fit popup builder: invalid state")
	assert(builder != nil && draw != nil, "fit popup builder: invalid body")
	body := surface_popup_begin(surface, state, options)
	surface_builder_with(surface, builder, body, draw, user_data)
	surface_popup_end(surface, state)
	return popup_take_close(state)
}

region_id_string :: proc(region: ^Region, key: string) -> Widget_Id {
	assert(region != nil && region.inner.open, "fit.region_id: region not open")
	return Widget_Id(ui.id(&region.inner, key))
}

region_id_u64 :: proc(region: ^Region, key: u64) -> Widget_Id {
	assert(region != nil && region.inner.open, "fit.region_id: region not open")
	return Widget_Id(ui.id(&region.inner, key))
}

region_id :: proc {
	region_id_string,
	region_id_u64,
}

region_scope_begin :: proc(region: ^Region, key: string) {
	assert(region != nil && region.inner.open, "fit.region_scope_begin: region not open")
	ui.scope_begin(&region.inner, key)
}

region_scope_end :: proc(region: ^Region) {
	assert(region != nil && region.inner.open, "fit.region_scope_end: region not open")
	ui.scope_end(&region.inner)
}

region_padding :: proc(region: ^Region, space: Space) {
	assert(region != nil && region.inner.open, "fit.region_padding: region not open")
	ui.padding(&region.inner, space)
}

region_separator :: proc(region: ^Region) {
	assert(region != nil && region.inner.open, "fit.region_separator: region not open")
	ui.separator(&region.inner)
}

region_row_begin :: proc(
	region: ^Region,
	height: i32,
	gap: Space = .None,
	align: Cross_Align = .Stretch,
) {
	assert(region != nil && region.inner.open, "fit.region_row_begin: region not open")
	ui.row_begin(&region.inner, height, gap, align)
}

region_row_end :: proc(region: ^Region) {
	assert(region != nil && region.inner.open, "fit.region_row_end: region not open")
	ui.row_end(&region.inner)
}

region_flex_row_begin :: proc(
	region: ^Region,
	height: i32,
	tracks: []Track,
	gap: Space = .None,
	align: Cross_Align = .Stretch,
	justify: Main_Align = .Start,
) {
	assert(region != nil && region.inner.open, "fit.region_flex_row_begin: region not open")
	assert(len(tracks) <= ui.MAX_LAYOUT_FLEX, "fit.region_flex_row_begin: too many tracks")
	inner: [ui.MAX_LAYOUT_FLEX]ui.Track
	for track, index in tracks do inner[index] = track
	ui.flex_row_begin(&region.inner, height, inner[:len(tracks)], gap, align, justify)
}

region_flex_slot_next :: proc(region: ^Region, cross_size: i32) -> Rect {
	assert(region != nil && region.inner.open, "fit.region_flex_slot_next: region not open")
	return ui.flex_slot_next(&region.inner, cross_size)
}

region_flex_row_end :: proc(region: ^Region) {
	assert(region != nil && region.inner.open, "fit.region_flex_row_end: region not open")
	ui.flex_row_end(&region.inner)
}

region_icon_button_id :: proc(region: ^Region, widget: Widget_Id, label: string) -> bool {
	assert(region != nil && region.inner.open, "fit.region_icon_button: region not open")
	return ui.icon_btn(&region.inner, ui.Widget_Id(widget), label)
}

region_icon_button_string :: proc(region: ^Region, key, label: string) -> bool {
	return region_icon_button_id(region, region_id(region, key), label)
}

region_icon_button_u64 :: proc(region: ^Region, key: u64, label: string) -> bool {
	return region_icon_button_id(region, region_id(region, key), label)
}

region_icon_button :: proc {
	region_icon_button_string,
	region_icon_button_u64,
	region_icon_button_id,
}

region_back_button_id :: proc(region: ^Region, widget: Widget_Id, label: string) -> bool {
	assert(region != nil && region.inner.open, "fit.region_back_button: region not open")
	return ui.back_btn(&region.inner, ui.Widget_Id(widget), label)
}

region_back_button_string :: proc(region: ^Region, key, label: string) -> bool {
	return region_back_button_id(region, region_id(region, key), label)
}

region_back_button_u64 :: proc(region: ^Region, key: u64, label: string) -> bool {
	return region_back_button_id(region, region_id(region, key), label)
}

region_back_button :: proc {
	region_back_button_string,
	region_back_button_u64,
	region_back_button_id,
}

region_collapsible_header_id :: proc(
	region: ^Region,
	widget: Widget_Id,
	label: string,
	open: ^bool,
	options: Collapsible_Options = {},
) -> bool {
	assert(region != nil && region.inner.open, "fit.region_collapsible_header: region not open")
	return ui.collapsible_header(
		&region.inner,
		ui.Widget_Id(widget),
		label,
		open,
		{icon = options.icon, right_label = options.right_label, motion = options.motion},
	)
}

region_collapsible_header_string :: proc(
	region: ^Region,
	key, label: string,
	open: ^bool,
	options: Collapsible_Options = {},
) -> bool {
	return region_collapsible_header_id(region, region_id(region, key), label, open, options)
}

region_collapsible_header_u64 :: proc(
	region: ^Region,
	key: u64,
	label: string,
	open: ^bool,
	options: Collapsible_Options = {},
) -> bool {
	return region_collapsible_header_id(region, region_id(region, key), label, open, options)
}

region_collapsible_header :: proc {
	region_collapsible_header_string,
	region_collapsible_header_u64,
	region_collapsible_header_id,
}

region_slider_id :: proc(
	region: ^Region,
	widget: Widget_Id,
	state: ^Slider_State,
	value: ^f32,
	minimum, maximum, step: f32,
	width: i32,
	label: string,
	motion: ^Control_Motion_State = nil,
) -> bool {
	assert(region != nil && region.inner.open && state != nil, "fit.region_slider: invalid state")
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
		motion,
	)
}

region_slider_string :: proc(
	region: ^Region,
	key: string,
	state: ^Slider_State,
	value: ^f32,
	minimum, maximum, step: f32,
	width: i32,
	label: string,
	motion: ^Control_Motion_State = nil,
) -> bool {
	return region_slider_id(
		region,
		region_id(region, key),
		state,
		value,
		minimum,
		maximum,
		step,
		width,
		label,
		motion,
	)
}

region_slider_u64 :: proc(
	region: ^Region,
	key: u64,
	state: ^Slider_State,
	value: ^f32,
	minimum, maximum, step: f32,
	width: i32,
	label: string,
	motion: ^Control_Motion_State = nil,
) -> bool {
	return region_slider_id(
		region,
		region_id(region, key),
		state,
		value,
		minimum,
		maximum,
		step,
		width,
		label,
		motion,
	)
}

region_slider :: proc {
	region_slider_string,
	region_slider_u64,
	region_slider_id,
}

region_dropdown_id :: proc(
	region: ^Region,
	widget: Widget_Id,
	items: []string,
	selected: ^i32,
	state: ^Dropdown_State,
	a11y_label: string = "dropdown",
) -> bool {
	assert(
		region != nil && region.inner.open && state != nil,
		"fit.region_dropdown: invalid state",
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

region_dropdown_string :: proc(
	region: ^Region,
	key: string,
	items: []string,
	selected: ^i32,
	state: ^Dropdown_State,
	a11y_label: string = "dropdown",
) -> bool {
	return region_dropdown_id(region, region_id(region, key), items, selected, state, a11y_label)
}

region_dropdown_u64 :: proc(
	region: ^Region,
	key: u64,
	items: []string,
	selected: ^i32,
	state: ^Dropdown_State,
	a11y_label: string = "dropdown",
) -> bool {
	return region_dropdown_id(region, region_id(region, key), items, selected, state, a11y_label)
}

region_dropdown :: proc {
	region_dropdown_string,
	region_dropdown_u64,
	region_dropdown_id,
}

region_combobox :: proc(
	region: ^Region,
	key: string,
	state: ^Combobox_State,
	items: []Combobox_Item,
	selected: ^u64,
	placeholder, a11y_label: string,
) -> bool {
	assert(
		region != nil && region.inner.open && state != nil,
		"fit.region_combobox: invalid state",
	)
	return ui.combobox(&region.inner, key, &state.inner, items, selected, placeholder, a11y_label)
}

region_date_picker :: proc(
	region: ^Region,
	key: string,
	state: ^Date_Picker_State,
	value: ^Calendar_Date,
	placeholder, a11y_label: string,
) -> bool {
	assert(
		region != nil && region.inner.open && state != nil,
		"fit.region_date_picker: invalid state",
	)
	inner := ui.Calendar_Date{value.year, value.month, value.day}
	changed := ui.date_picker(&region.inner, key, &state.inner, &inner, placeholder, a11y_label)
	value^ = {inner.year, inner.month, inner.day}
	return changed
}

region_spinner :: proc(region: ^Region, diameter: i32, options: Spinner_Options = {}) {
	assert(region != nil && region.inner.open, "fit.region_spinner: region not open")
	ui.spinner(
		&region.inner,
		diameter,
		{style = options.style, dot_radius = options.dot_radius, speed = options.speed},
	)
}

region_status_pill :: proc(region: ^Region, text: string, ink: Ink) -> i32 {
	assert(region != nil && region.inner.open, "fit.region_status_pill: region not open")
	return ui.status_pill(&region.inner, text, ink)
}

region_progress_bar :: proc(region: ^Region, fraction: f32) {
	assert(region != nil && region.inner.open, "fit.region_progress_bar: region not open")
	ui.progress_bar(&region.inner, fraction)
}

region_progress_bar_animated :: proc(region: ^Region, fraction: f32, animation: ^f32, ink: Ink) {
	assert(region != nil && region.inner.open, "fit.region_progress_bar_animated: region not open")
	ui.progress_bar_animated(&region.inner, fraction, animation, ink)
}

region_key_value :: proc(region: ^Region, key, value: string) {
	assert(region != nil && region.inner.open, "fit.region_key_value: region not open")
	ui.kv_row(&region.inner, key, value)
}

region_table_header :: proc(
	region: ^Region,
	key: string,
	columns: []Table_Column,
	sort: ^Table_Sort,
) -> bool {
	assert(
		region != nil && region.inner.open && sort != nil,
		"fit.region_table_header: invalid state",
	)
	assert(len(columns) <= TABLE_COLUMN_COUNT_MAX, "fit.region_table_header: too many columns")
	inner_columns: [TABLE_COLUMN_COUNT_MAX]ui.Table_Column
	for column, index in columns {
		inner_columns[index] = {column.label, column.track, column.numeric}
	}
	inner_sort := ui.Table_Sort{sort.column, sort.descending}
	changed := ui.table_header(&region.inner, key, inner_columns[:len(columns)], &inner_sort)
	sort^ = {inner_sort.column, inner_sort.descending}
	return changed
}

table_tracks :: proc(columns: []Table_Column, buffer: []Track) -> []Track {
	assert(len(columns) > 0 && len(buffer) >= len(columns), "fit.table_tracks: invalid buffer")
	for column, index in columns do buffer[index] = column.track
	return buffer[:len(columns)]
}

// surface_nav_item draws one navigation row at `rect`: accent bar when
// selected, icon, truncated label, optional muted badge. Semantics carry
// .Selected so the current section is announced.
surface_nav_item :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	icon: Icon,
	label: string,
	selected: bool,
	rect: Rect,
	badge: string = "",
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0), "fit.surface_nav_item: zero widget")
	assert(label != "", "fit.surface_nav_item: empty label")
	return ui.nav_item_at(
		u.frame,
		rect,
		icon,
		label,
		selected,
		badge,
		widget = ui.Widget_Id(widget),
	)
}

region_nav_item_id :: proc(
	region: ^Region,
	widget: Widget_Id,
	icon: Icon,
	label: string,
	selected: bool,
	badge: string = "",
) -> bool {
	assert(region != nil && region.inner.open, "fit.region_nav_item: region not open")
	return ui.nav_item(&region.inner, ui.Widget_Id(widget), icon, label, selected, badge)
}

region_nav_item_string :: proc(
	region: ^Region,
	key: string,
	icon: Icon,
	label: string,
	selected: bool,
	badge: string = "",
) -> bool {
	return region_nav_item_id(region, region_id(region, key), icon, label, selected, badge)
}

region_nav_item :: proc {
	region_nav_item_string,
	region_nav_item_id,
}

// surface_command_palette draws an open palette as a modal and returns the
// activated command (or dismissal). `open`, the palette state, and the modal
// are caller-owned; the palette closes itself and clears its query on either
// outcome.
surface_command_palette :: proc(
	surface: ^Surface,
	state: ^Command_Palette_State,
	modal: ^Modal_State,
	items: []Command_Palette_Item,
	open: ^bool,
	options: Command_Palette_Options = {},
) -> Command_Palette_Result {
	u := surface_ui(surface)
	assert(state != nil && modal != nil, "fit.surface_command_palette: nil state")
	assert(open != nil, "fit.surface_command_palette: nil open flag")
	return ui.command_palette_draw(u.frame, state, &modal.inner, items, open, options)
}

command_palette_state_destroy :: proc(state: ^Command_Palette_State) {
	ui.command_palette_state_destroy(state)
}
