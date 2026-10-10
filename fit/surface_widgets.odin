package fit

import "core:strings"
import "ingot:ui"

surface_button :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	label: string,
	rect: Rect,
	style: Button_Style = .Secondary,
	enabled: bool = true,
	focus: Focus_Link = {},
	interaction_rect: ^Rect = nil,
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0), "fit.surface_button: zero widget")
	hit: ^ui.Rect_I32
	if interaction_rect != nil {
		converted := interaction_rect^
		hit = &converted
	}
	return ui.button_at(
		u.frame,
		rect,
		label,
		style,
		enabled = enabled,
		focus = focus.inner,
		widget = ui.Widget_Id(widget),
		interaction_rect = hit,
	)
}

surface_icon_button :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	icon: Icon,
	accessible_label: string,
	rect: Rect,
	enabled: bool = true,
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0), "fit.surface_icon_button: zero widget")
	assert(accessible_label != "", "fit.surface_icon_button: empty accessible label")
	return ui.icon_button_at(
		u.frame,
		rect,
		icon,
		accessible_label,
		enabled,
		widget = ui.Widget_Id(widget),
	)
}

surface_text_input :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	box: ^Input_Box,
	rect: Rect,
	placeholder: string,
	active: bool,
	masked: bool = false,
	semantics: Text_Input_Semantics = {},
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0) && box != nil, "fit.surface_text_input: invalid argument")
	inner_semantics := to_text_semantics(semantics)
	inner_semantics.widget = ui.Widget_Id(widget)
	return ui.text_input_at(
		u.frame,
		rect,
		&box.inner,
		placeholder,
		active,
		masked,
		inner_semantics,
	)
}

// to_submit maps the public façade enum explicitly because its declaration
// order is part of fit's compatibility surface and differs from ui.
@(private)
to_submit :: proc(mode: Text_Input_Submit) -> ui.Text_Input_Submit {
	switch mode {
	case .Default, .Enter:
		return .Enter
	case .Never:
		return .Never
	case .Ctrl_Enter:
		return .Ctrl_Enter
	case .Mod_Enter:
		return .Mod_Enter
	}
	unreachable()
}

surface_text_input_state :: proc(
	surface: ^Surface,
	config: Text_Input_Config,
	text: ^strings.Builder,
	state: ^Text_Input_State,
) -> bool {
	u := surface_ui(surface)
	assert(text != nil && state != nil, "fit.surface_text_input_state: invalid argument")
	return ui.text_input_box(
		u.frame,
		{
			rect = config.rect,
			placeholder = config.placeholder,
			active = config.active,
			masked = config.masked,
			enable_pills = config.enable_pills,
			enable_undo = config.enable_undo,
			max_bytes = config.max_bytes,
			single_line = config.single_line,
			submit = to_submit(config.submit),
			semantics = {field_id = config.semantics.field_id, name = config.semantics.name},
		},
		text,
		&state.inner,
	)
}

surface_text_input_visual_line_count :: proc(
	surface: ^Surface,
	state: ^Text_Input_State,
	text: string,
	width, font_size: i32,
) -> int {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_text_input_visual_line_count: nil state")
	return len(
		ui.input_visual_lines_memo_frame(u.frame, &state.inner.memo, text, width, font_size),
	)
}

surface_checkbox :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	label: string,
	value: ^bool,
	rect: Rect,
	interaction_rect: ^Rect = nil,
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0) && value != nil, "fit.surface_checkbox: invalid argument")
	hit: ^ui.Rect_I32
	if interaction_rect != nil {
		converted := interaction_rect^
		hit = &converted
	}
	return ui.checkbox_at(
		u.frame,
		rect,
		label,
		value,
		widget = ui.Widget_Id(widget),
		interaction_rect = hit,
	)
}

surface_radio :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	label: string,
	value: i32,
	selected: ^i32,
	rect: Rect,
	focus: Focus_Link = {},
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0) && selected != nil, "fit.surface_radio: invalid argument")
	return ui.radio_at(
		u.frame,
		rect,
		label,
		selected,
		value,
		focus = focus.inner,
		widget = ui.Widget_Id(widget),
	)
}

surface_slider :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	value: ^f32,
	minimum, maximum, step: f32,
	rect: Rect,
	interaction_rect: ^Rect = nil,
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0) && value != nil, "fit.surface_slider: invalid argument")
	assert(minimum <= maximum && step >= 0, "fit.surface_slider: invalid range")
	hit: ^ui.Rect_I32
	if interaction_rect != nil {
		converted := interaction_rect^
		hit = &converted
	}
	return ui.slider_at(
		u.frame,
		rect,
		value,
		minimum,
		maximum,
		step,
		widget = ui.Widget_Id(widget),
		interaction_rect = hit,
	)
}

surface_dropdown :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	items: []string,
	selected: ^i32,
	state: ^Dropdown_State,
	rect: Rect,
	a11y_label: string = "dropdown",
	interaction_rect: ^Rect = nil,
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0) && selected != nil, "fit.surface_dropdown: invalid argument")
	assert(state != nil && len(items) > 0, "fit.surface_dropdown: invalid state")
	hit: ^ui.Rect_I32
	if interaction_rect != nil {
		converted := interaction_rect^
		hit = &converted
	}
	return ui.dropdown_at(
		u.frame,
		rect,
		items,
		selected,
		&state.inner,
		u.screen_w,
		u.screen_h,
		a11y_label = a11y_label,
		widget = ui.Widget_Id(widget),
		interaction_rect = hit,
	)
}

surface_combobox :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	items: []Combobox_Item,
	selected: ^u64,
	state: ^Combobox_State,
	rect: Rect,
	placeholder: string = "Select",
	a11y_label: string = "combobox",
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0) && selected != nil, "fit.surface_combobox: invalid argument")
	assert(state != nil, "fit.surface_combobox: nil state")
	return ui.combobox_at(
		u.frame,
		rect,
		&state.inner,
		items,
		selected,
		placeholder,
		u.screen_w,
		u.screen_h,
		a11y_label = a11y_label,
		widget = ui.Widget_Id(widget),
	)
}

surface_date_picker :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	value: ^Calendar_Date,
	state: ^Date_Picker_State,
	rect: Rect,
	placeholder: string = "Select date",
	a11y_label: string = "Date",
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0) && value != nil, "fit.surface_date_picker: invalid argument")
	assert(state != nil, "fit.surface_date_picker: nil state")
	return ui.date_picker_at(
		u.frame,
		rect,
		&state.inner,
		value,
		placeholder,
		u.screen_w,
		u.screen_h,
		a11y_label = a11y_label,
		widget = ui.Widget_Id(widget),
	)
}

surface_line_chart :: proc(
	surface: ^Surface,
	rect: Rect,
	series: []Chart_Series,
	state: ^Chart_State,
	options: Chart_Options = {},
) -> int {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_line_chart: nil state")
	assert(len(series) <= ui.CHART_SERIES_COUNT_MAX, "fit.surface_line_chart: too many series")
	inner_state := ui.Chart_State{state.enter_anim, state.hover_index}
	hovered := ui.line_chart_at(u.frame, rect, series, &inner_state, to_chart_options(options))
	state^ = {inner_state.enter_anim, inner_state.hover_idx}
	return hovered
}

surface_bar_chart :: proc(
	surface: ^Surface,
	rect: Rect,
	series: []Chart_Series,
	state: ^Chart_State,
	options: Chart_Options = {},
) -> int {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_bar_chart: nil state")
	assert(len(series) <= ui.CHART_SERIES_COUNT_MAX, "fit.surface_bar_chart: too many series")
	inner_state := ui.Chart_State{state.enter_anim, state.hover_index}
	hovered := ui.bar_chart_at(u.frame, rect, series, &inner_state, to_chart_options(options))
	state^ = {inner_state.enter_anim, inner_state.hover_idx}
	return hovered
}

surface_sparkline :: proc(surface: ^Surface, rect: Rect, values: []f32, color: Color = {}) {
	u := surface_ui(surface)
	ui.sparkline_at(u.frame, rect, values, ui.Color(color))
}

surface_markdown :: proc(
	surface: ^Surface,
	rect: Rect,
	source: string,
	color: Color,
) -> Markdown_Result {
	u := surface_ui(surface)
	ctx := ui.markdown_context(u.frame)
	width: i32
	height := ui.markdown_draw(&ctx, rect, source, ui.Color(color), out_w = &width)
	target, activated := ui.markdown_link_activated(&ctx)
	return {height, width, activated, target}
}

surface_context_menu :: proc(
	surface: ^Surface,
	state: ^Context_Menu_State,
	items: []Menu_Item,
) -> int {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_context_menu: nil state")
	assert(len(items) <= 32, "fit.surface_context_menu: too many items")
	inner_items: [32]ui.Menu_Item
	for item, index in items do inner_items[index] = {item.label, item.disabled, item.separator}
	return ui.context_menu(
		u.frame,
		&state.inner,
		inner_items[:len(items)],
		ui.frame_viewport(u.frame),
	)
}

surface_toasts :: proc(surface: ^Surface, state: ^Toast_State) {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_toasts: nil state")
	ui.toasts_draw(u.frame, &state.inner, ui.frame_viewport(u.frame))
}

surface_confirm_dialog :: proc(
	surface: ^Surface,
	state: ^Confirm_Dialog_State,
	title, message, confirm_label: string,
	danger: bool = true,
) -> Confirm_Choice {
	u := surface_ui(surface)
	assert(state != nil, "fit.surface_confirm_dialog: nil state")
	result := ui.confirm_dialog(
		u.frame,
		&state.inner,
		title,
		message,
		confirm_label,
		ui.frame_viewport(u.frame),
		danger,
	)
	return Confirm_Choice(result)
}

region_label :: proc(region: ^Region, text: string, role: Text_Role = .Body, ink: Ink = .Primary) {
	assert(region != nil && region.inner.open, "fit.region_label: region not open")
	ui.label(&region.inner, text, role, ink)
}

region_button_string :: proc(
	region: ^Region,
	key, label: string,
	style: Button_Style = .Secondary,
	enabled: bool = true,
	motion: ^Control_Motion_State = nil,
) -> bool {
	assert(region != nil && region.inner.open, "fit.region_button: region not open")
	return ui.button(
		&region.inner,
		key,
		label,
		ui.Button_Options{style = style, disabled = !enabled, motion = motion},
	)
}

region_button_id :: proc(
	region: ^Region,
	widget: Widget_Id,
	label: string,
	style: Button_Style = .Secondary,
	enabled: bool = true,
	motion: ^Control_Motion_State = nil,
) -> bool {
	assert(region != nil && region.inner.open, "fit.region_button: region not open")
	return ui.button(
		&region.inner,
		ui.Widget_Id(widget),
		label,
		ui.Button_Options{style = style, disabled = !enabled, motion = motion},
	)
}

region_button_u64 :: proc(
	region: ^Region,
	key: u64,
	label: string,
	style: Button_Style = .Secondary,
	enabled: bool = true,
	motion: ^Control_Motion_State = nil,
) -> bool {
	assert(region != nil && region.inner.open, "fit.region_button: region not open")
	return ui.button(
		&region.inner,
		key,
		label,
		ui.Button_Options{style = style, disabled = !enabled, motion = motion},
	)
}

region_button :: proc {
	region_button_string,
	region_button_id,
	region_button_u64,
}

region_toggle_id :: proc(
	region: ^Region,
	widget: Widget_Id,
	label: string,
	value: ^bool,
	motion: ^Control_Motion_State = nil,
) -> bool {
	assert(region != nil && region.inner.open, "fit.region_toggle: region not open")
	assert(value != nil && label != "", "fit.region_toggle: invalid value")
	spec := ui.Toggle_Spec {
		id      = ui.Widget_Id(widget),
		label   = label,
		checked = value,
		motion  = motion,
	}
	return ui.toggle(&region.inner, spec)
}

region_toggle_string :: proc(
	region: ^Region,
	key, label: string,
	value: ^bool,
	motion: ^Control_Motion_State = nil,
) -> bool {
	assert(region != nil && region.inner.open, "fit.region_toggle: region not open")
	assert(key != "", "fit.region_toggle: empty key")
	return region_toggle_id(region, Widget_Id(ui.id(&region.inner, key)), label, value, motion)
}

region_toggle_u64 :: proc(
	region: ^Region,
	key: u64,
	label: string,
	value: ^bool,
	motion: ^Control_Motion_State = nil,
) -> bool {
	assert(region != nil && region.inner.open, "fit.region_toggle: region not open")
	assert(value != nil && label != "", "fit.region_toggle: invalid value")
	return region_toggle_id(region, Widget_Id(ui.id(&region.inner, key)), label, value, motion)
}

region_toggle :: proc {
	region_toggle_string,
	region_toggle_u64,
	region_toggle_id,
}

region_checkbox_string :: proc(region: ^Region, key, label: string, value: ^bool) -> bool {
	assert(region != nil && region.inner.open, "fit.region_checkbox: region not open")
	return ui.checkbox(&region.inner, ui.id(&region.inner, key), label, value)
}

region_checkbox_id :: proc(
	region: ^Region,
	widget: Widget_Id,
	label: string,
	value: ^bool,
) -> bool {
	assert(region != nil && region.inner.open, "fit.region_checkbox: region not open")
	return ui.checkbox(&region.inner, ui.Widget_Id(widget), label, value)
}

region_checkbox :: proc {
	region_checkbox_string,
	region_checkbox_id,
}

region_radio_string :: proc(
	region: ^Region,
	key, label: string,
	selected: ^i32,
	value: i32,
) -> bool {
	assert(region != nil && region.inner.open, "fit.region_radio: region not open")
	return ui.radio(&region.inner, ui.id(&region.inner, key), label, selected, value)
}

region_radio_id :: proc(
	region: ^Region,
	widget: Widget_Id,
	label: string,
	selected: ^i32,
	value: i32,
) -> bool {
	assert(region != nil && region.inner.open, "fit.region_radio: region not open")
	return ui.radio(&region.inner, ui.Widget_Id(widget), label, selected, value)
}

region_radio :: proc {
	region_radio_string,
	region_radio_id,
}

region_text_input :: proc(
	region: ^Region,
	key: string,
	box: ^Input_Box,
	placeholder: string,
	options: Text_Input_Options,
) -> bool {
	assert(
		region != nil && region.inner.open && box != nil,
		"fit.region_text_input: invalid argument",
	)
	return ui.text_input(
		&region.inner,
		key,
		&box.inner,
		placeholder,
		ui.Text_Input_Options {
			height = options.height,
			masked = options.masked,
			semantics = to_text_semantics(options.semantics),
		},
	)
}

region_space :: proc(region: ^Region, space: Space) {
	assert(region != nil && region.inner.open, "fit.region_space: region not open")
	ui.space(&region.inner, space)
}

region_section_header :: proc(region: ^Region, title: string) {
	assert(region != nil && region.inner.open, "fit.region_section_header: region not open")
	_ = ui.section_header(&region.inner, title)
}

region_tab_bar :: proc(
	region: ^Region,
	key: string,
	labels: []string,
	active: ^i32,
	motion: ^Control_Motion_State = nil,
) -> bool {
	assert(region != nil && region.inner.open, "fit.region_tab_bar: region not open")
	return ui.tab_bar(&region.inner, key, labels, active, motion = motion)
}

@(private = "package")
surface_ui :: proc(surface: ^Surface) -> ^ui.Ui {
	assert(surface != nil && surface.inner != nil, "fit.Surface: invalid surface")
	assert(surface.inner.open && surface.inner.frame != nil, "fit.Surface: closed surface")
	return surface.inner
}
