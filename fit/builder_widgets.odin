package fit

import "ingot:ui"

@(private = "file")
checkbox_id :: proc(
	builder: ^Builder,
	widget: Widget_Id,
	label: string,
	checked: ^bool,
	options: Control_Options = {},
) {
	assert(builder != nil && builder.bound, "Fit.Checkbox: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE), "Fit.Checkbox: zero widget")
	assert(label != "" && checked != nil, "Fit.Checkbox: invalid argument")
	ui.fit_builder_checkbox(
		&builder.inner,
		{id = ui.Widget_Id(widget), label = label, checked = checked},
		to_control_options(options),
	)
}

@(private = "file")
checkbox_string :: proc(
	builder: ^Builder,
	key, label: string,
	checked: ^bool,
	options: Control_Options = {},
) {
	checkbox_id(builder, Id(builder, key), label, checked, options)
}

@(private = "file")
checkbox_u64 :: proc(
	builder: ^Builder,
	key: u64,
	label: string,
	checked: ^bool,
	options: Control_Options = {},
) {
	checkbox_id(builder, Id(builder, key), label, checked, options)
}

Checkbox :: proc {
	checkbox_string,
	checkbox_u64,
	checkbox_id,
}

@(private = "file")
radio_id :: proc(
	builder: ^Builder,
	widget: Widget_Id,
	label: string,
	selected: ^i32,
	value: i32,
	options: Control_Options = {},
) {
	assert(builder != nil && builder.bound, "Fit.Radio: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE), "Fit.Radio: zero widget")
	assert(label != "" && selected != nil, "Fit.Radio: invalid argument")
	ui.fit_builder_radio(
		&builder.inner,
		{id = ui.Widget_Id(widget), label = label, selected = selected, value = value},
		to_control_options(options),
	)
}

@(private = "file")
radio_string :: proc(
	builder: ^Builder,
	key, label: string,
	selected: ^i32,
	value: i32,
	options: Control_Options = {},
) {
	radio_id(builder, Id(builder, key), label, selected, value, options)
}

@(private = "file")
radio_u64 :: proc(
	builder: ^Builder,
	key: u64,
	label: string,
	selected: ^i32,
	value: i32,
	options: Control_Options = {},
) {
	radio_id(builder, Id(builder, key), label, selected, value, options)
}

Radio :: proc {
	radio_string,
	radio_u64,
	radio_id,
}

@(private = "file")
slider_id :: proc(
	builder: ^Builder,
	widget: Widget_Id,
	value: ^f32,
	minimum, maximum, step: f32,
	a11y_label: string,
	options: Control_Options = {},
) {
	assert(builder != nil && builder.bound, "Fit.Slider: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE) && value != nil, "Fit.Slider: invalid argument")
	assert(maximum > minimum && step >= 0 && a11y_label != "", "Fit.Slider: invalid range")
	ui.fit_builder_slider(
		&builder.inner,
		{
			id = ui.Widget_Id(widget),
			value = value,
			minimum = minimum,
			maximum = maximum,
			step = step,
			a11y_label = a11y_label,
		},
		to_control_options(options),
	)
}

@(private = "file")
slider_string :: proc(
	builder: ^Builder,
	key: string,
	value: ^f32,
	minimum, maximum, step: f32,
	a11y_label: string,
	options: Control_Options = {},
) {
	slider_id(builder, Id(builder, key), value, minimum, maximum, step, a11y_label, options)
}

@(private = "file")
slider_u64 :: proc(
	builder: ^Builder,
	key: u64,
	value: ^f32,
	minimum, maximum, step: f32,
	a11y_label: string,
	options: Control_Options = {},
) {
	slider_id(builder, Id(builder, key), value, minimum, maximum, step, a11y_label, options)
}

Slider :: proc {
	slider_string,
	slider_u64,
	slider_id,
}
