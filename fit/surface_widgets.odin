package fit

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
		ui.Btn_Style(style),
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
		transmute([]ui.Combobox_Item)items,
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

Region_Label :: proc(region: ^Region, text: string, role: Text_Role = .Body, ink: Ink = .Primary) {
	assert(region != nil && region.inner.open, "Fit.Region_Label: region not open")
	ui.label(&region.inner, text, ui.Text_Role(role), ui.Ink(ink))
}

Region_Button :: proc(
	region: ^Region,
	key, label: string,
	style: Button_Style = .Secondary,
	enabled: bool = true,
) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Button: region not open")
	return ui.button(&region.inner, key, label, ui.Btn_Style(style), enabled)
}

Region_Checkbox :: proc(region: ^Region, key, label: string, value: ^bool) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Checkbox: region not open")
	return ui.checkbox(&region.inner, ui.id(&region.inner, key), label, value)
}

Region_Radio :: proc(region: ^Region, key, label: string, selected: ^i32, value: i32) -> bool {
	assert(region != nil && region.inner.open, "Fit.Region_Radio: region not open")
	return ui.radio(&region.inner, ui.id(&region.inner, key), label, selected, value)
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
	ui.space(&region.inner, ui.Space(space))
}

Region_Section_Header :: proc(region: ^Region, title: string) {
	assert(region != nil && region.inner.open, "Fit.Region_Section_Header: region not open")
	_ = ui.section_header(&region.inner, title)
}

@(private = "package")
surface_ui :: proc(surface: ^Surface) -> ^ui.Ui {
	assert(surface != nil && surface.inner != nil, "Fit.Surface: invalid surface")
	assert(surface.inner.open && surface.inner.frame != nil, "Fit.Surface: closed surface")
	return surface.inner
}
