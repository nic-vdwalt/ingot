package fit

import "ingot:ui"

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
	return ui.date_picker_at(
		u.frame,
		to_rect(rect),
		&state.inner,
		&value.inner,
		placeholder,
		u.screen_w,
		u.screen_h,
		a11y_label = a11y_label,
		widget = ui.Widget_Id(widget),
	)
}

@(private = "package")
surface_ui :: proc(surface: ^Surface) -> ^ui.Ui {
	assert(surface != nil && surface.inner != nil, "Fit.Surface: invalid surface")
	assert(surface.inner.open && surface.inner.frame != nil, "Fit.Surface: closed surface")
	return surface.inner
}
