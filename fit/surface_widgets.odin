package fit

import "core:strings"
import "ingot:ui"

Surface_Button :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	label: string,
	rect: Rect,
	style: Button_Style = .Secondary,
	enabled: bool = true,
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0), "Fit.Surface_Button: zero widget")
	return ui.button_at(
		u.frame,
		to_rect(rect),
		label,
		style,
		enabled = enabled,
		widget = ui.Widget_Id(widget),
	)
}

Surface_Text_Input :: proc(
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
	assert(widget != Widget_Id(0) && box != nil, "Fit.Surface_Text_Input: invalid argument")
	inner_semantics := to_text_semantics(semantics)
	inner_semantics.widget = ui.Widget_Id(widget)
	return ui.text_input_at(
		u.frame,
		to_rect(rect),
		&box.inner,
		placeholder,
		active,
		masked,
		inner_semantics,
	)
}

// to_submit maps the public façade enum explicitly because its declaration
// order is part of Fit's compatibility surface and differs from ui.
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

Surface_Text_Input_State :: proc(
	surface: ^Surface,
	config: Text_Input_Config,
	text: ^strings.Builder,
	state: ^Text_Input_State,
) -> bool {
	u := surface_ui(surface)
	assert(text != nil && state != nil, "Fit.Surface_Text_Input_State: invalid argument")
	return ui.text_input_box(
		u.frame,
		{
			rect = to_rect(config.rect),
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

Surface_Text_Input_Visual_Line_Count :: proc(
	surface: ^Surface,
	state: ^Text_Input_State,
	text: string,
	width, font_size: i32,
) -> int {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Text_Input_Visual_Line_Count: nil state")
	return len(
		ui.input_visual_lines_memo_frame(u.frame, &state.inner.memo, text, width, font_size),
	)
}

Surface_Checkbox :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	label: string,
	value: ^bool,
	rect: Rect,
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0) && value != nil, "Fit.Surface_Checkbox: invalid argument")
	return ui.checkbox_at(u.frame, to_rect(rect), label, value, widget = ui.Widget_Id(widget))
}

Surface_Radio :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	label: string,
	value: i32,
	selected: ^i32,
	rect: Rect,
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0) && selected != nil, "Fit.Surface_Radio: invalid argument")
	return ui.radio_at(
		u.frame,
		to_rect(rect),
		label,
		selected,
		value,
		widget = ui.Widget_Id(widget),
	)
}

Surface_Slider :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	value: ^f32,
	minimum, maximum, step: f32,
	rect: Rect,
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0) && value != nil, "Fit.Surface_Slider: invalid argument")
	assert(minimum <= maximum && step >= 0, "Fit.Surface_Slider: invalid range")
	return ui.slider_at(
		u.frame,
		to_rect(rect),
		value,
		minimum,
		maximum,
		step,
		widget = ui.Widget_Id(widget),
	)
}

Surface_Dropdown :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	items: []string,
	selected: ^i32,
	state: ^Dropdown_State,
	rect: Rect,
	a11y_label: string = "Dropdown",
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0) && selected != nil, "Fit.Surface_Dropdown: invalid argument")
	assert(state != nil && len(items) > 0, "Fit.Surface_Dropdown: invalid state")
	return ui.dropdown_at(
		u.frame,
		to_rect(rect),
		items,
		selected,
		&state.inner,
		u.screen_w,
		u.screen_h,
		a11y_label = a11y_label,
		widget = ui.Widget_Id(widget),
	)
}

Surface_Combobox :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	items: []Combobox_Item,
	selected: ^u64,
	state: ^Combobox_State,
	rect: Rect,
	placeholder: string = "Select",
	a11y_label: string = "Combobox",
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0) && selected != nil, "Fit.Surface_Combobox: invalid argument")
	assert(state != nil, "Fit.Surface_Combobox: nil state")
	return ui.combobox_at(
		u.frame,
		to_rect(rect),
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

Surface_Date_Picker :: proc(
	surface: ^Surface,
	widget: Widget_Id,
	value: ^Calendar_Date,
	state: ^Date_Picker_State,
	rect: Rect,
	placeholder: string = "Select date",
	a11y_label: string = "Date",
) -> bool {
	u := surface_ui(surface)
	assert(widget != Widget_Id(0) && value != nil, "Fit.Surface_Date_Picker: invalid argument")
	assert(state != nil, "Fit.Surface_Date_Picker: nil state")
	inner_value := ui.Calendar_Date{value.year, value.month, value.day}
	changed := ui.date_picker_at(
		u.frame,
		to_rect(rect),
		&state.inner,
		&inner_value,
		placeholder,
		u.screen_w,
		u.screen_h,
		a11y_label = a11y_label,
		widget = ui.Widget_Id(widget),
	)
	value^ = {inner_value.year, inner_value.month, inner_value.day}
	return changed
}

Surface_Line_Chart :: proc(
	surface: ^Surface,
	rect: Rect,
	series: []Chart_Series,
	state: ^Chart_State,
	options: Chart_Options = {},
) -> int {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Line_Chart: nil state")
	assert(len(series) <= ui.CHART_SERIES_COUNT_MAX, "Fit.Surface_Line_Chart: too many series")
	inner_series: [ui.CHART_SERIES_COUNT_MAX]ui.Chart_Series
	for item, index in series do inner_series[index] = {item.name, item.values, ui.Color(item.color)}
	inner_state := ui.Chart_State{state.enter_anim, state.hover_index}
	hovered := ui.line_chart_at(
		u.frame,
		to_rect(rect),
		inner_series[:len(series)],
		&inner_state,
		to_chart_options(options),
	)
	state^ = {inner_state.enter_anim, inner_state.hover_idx}
	return hovered
}

Surface_Bar_Chart :: proc(
	surface: ^Surface,
	rect: Rect,
	series: []Chart_Series,
	state: ^Chart_State,
	options: Chart_Options = {},
) -> int {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Bar_Chart: nil state")
	assert(len(series) <= ui.CHART_SERIES_COUNT_MAX, "Fit.Surface_Bar_Chart: too many series")
	inner_series: [ui.CHART_SERIES_COUNT_MAX]ui.Chart_Series
	for item, index in series do inner_series[index] = {item.name, item.values, ui.Color(item.color)}
	inner_state := ui.Chart_State{state.enter_anim, state.hover_index}
	hovered := ui.bar_chart_at(
		u.frame,
		to_rect(rect),
		inner_series[:len(series)],
		&inner_state,
		to_chart_options(options),
	)
	state^ = {inner_state.enter_anim, inner_state.hover_idx}
	return hovered
}

Surface_Sparkline :: proc(surface: ^Surface, rect: Rect, values: []f32, color: Color = {}) {
	u := surface_ui(surface)
	ui.sparkline_at(u.frame, to_rect(rect), values, ui.Color(color))
}

Surface_Markdown :: proc(
	surface: ^Surface,
	rect: Rect,
	source: string,
	color: Color,
) -> Markdown_Result {
	u := surface_ui(surface)
	ctx := ui.markdown_context(u.frame)
	width: i32
	height := ui.markdown_draw(&ctx, to_rect(rect), source, ui.Color(color), out_w = &width)
	target, activated := ui.markdown_link_activated(&ctx)
	return {height, width, activated, target}
}

Surface_Context_Menu :: proc(
	surface: ^Surface,
	state: ^Context_Menu_State,
	items: []Menu_Item,
) -> int {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Context_Menu: nil state")
	assert(len(items) <= 32, "Fit.Surface_Context_Menu: too many items")
	inner_items: [32]ui.Menu_Item
	for item, index in items do inner_items[index] = {item.label, item.disabled, item.separator}
	return ui.context_menu(
		u.frame,
		&state.inner,
		inner_items[:len(items)],
		ui.frame_viewport(u.frame),
	)
}

Surface_Toasts :: proc(surface: ^Surface, state: ^Toast_State) {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Toasts: nil state")
	ui.toasts_draw(u.frame, &state.inner, ui.frame_viewport(u.frame))
}

Surface_Confirm_Dialog :: proc(
	surface: ^Surface,
	state: ^Confirm_Dialog_State,
	title, message, confirm_label: string,
	danger: bool = true,
) -> Confirm_Choice {
	u := surface_ui(surface)
	assert(state != nil, "Fit.Surface_Confirm_Dialog: nil state")
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

Region_Label :: proc(region: ^Region, text: string, role: Text_Role = .Body, ink: Ink = .Primary) {
	assert(region != nil && region.inner.open, "Fit.Region_Label: region not open")
	ui.label(&region.inner, text, role, ink)
}

Region_Button_String :: proc(
	region: ^Region,
	key, label: string,
	style: Button_Style = .Secondary,
	enabled: bool = true,
) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Button: region not open")
	return ui.button(&region.inner, key, label, style, enabled)
}

Region_Button_Id :: proc(
	region: ^Region,
	widget: Widget_Id,
	label: string,
	style: Button_Style = .Secondary,
	enabled: bool = true,
) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Button: region not open")
	return ui.button(&region.inner, ui.Widget_Id(widget), label, style, enabled)
}

Region_Button_U64 :: proc(
	region: ^Region,
	key: u64,
	label: string,
	style: Button_Style = .Secondary,
	enabled: bool = true,
) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Button: region not open")
	return ui.button(&region.inner, key, label, style, enabled)
}

Region_Button :: proc {
	Region_Button_String,
	Region_Button_Id,
	Region_Button_U64,
}

Region_Checkbox_String :: proc(region: ^Region, key, label: string, value: ^bool) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Checkbox: region not open")
	return ui.checkbox(&region.inner, ui.id(&region.inner, key), label, value)
}

Region_Checkbox_Id :: proc(
	region: ^Region,
	widget: Widget_Id,
	label: string,
	value: ^bool,
) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Checkbox: region not open")
	return ui.checkbox(&region.inner, ui.Widget_Id(widget), label, value)
}

Region_Checkbox :: proc {
	Region_Checkbox_String,
	Region_Checkbox_Id,
}

Region_Radio_String :: proc(
	region: ^Region,
	key, label: string,
	selected: ^i32,
	value: i32,
) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Radio: region not open")
	return ui.radio(&region.inner, ui.id(&region.inner, key), label, selected, value)
}

Region_Radio_Id :: proc(
	region: ^Region,
	widget: Widget_Id,
	label: string,
	selected: ^i32,
	value: i32,
) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Radio: region not open")
	return ui.radio(&region.inner, ui.Widget_Id(widget), label, selected, value)
}

Region_Radio :: proc {
	Region_Radio_String,
	Region_Radio_Id,
}

Region_Text_Input :: proc(
	region: ^Region,
	key: string,
	box: ^Input_Box,
	placeholder: string,
	options: Text_Input_Options,
) -> bool {
	assert(
		region != nil && region.inner.open && box != nil,
		"Fit.Region_Text_Input: invalid argument",
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

Region_Space :: proc(region: ^Region, space: Space) {
	assert(region != nil && region.inner.open, "Fit.Region_Space: region not open")
	ui.space(&region.inner, space)
}

Region_Section_Header :: proc(region: ^Region, title: string) {
	assert(region != nil && region.inner.open, "Fit.Region_Section_Header: region not open")
	_ = ui.section_header(&region.inner, title)
}

Region_Tab_Bar :: proc(region: ^Region, key: string, labels: []string, active: ^i32) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Tab_Bar: region not open")
	return ui.tab_bar(&region.inner, key, labels, active)
}

@(private = "package")
surface_ui :: proc(surface: ^Surface) -> ^ui.Ui {
	assert(surface != nil && surface.inner != nil, "Fit.Surface: invalid surface")
	assert(surface.inner.open && surface.inner.frame != nil, "Fit.Surface: closed surface")
	return surface.inner
}
