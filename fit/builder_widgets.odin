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

@(private = "file")
builder_text_input_id :: proc(
	builder: ^Builder,
	widget: Widget_Id,
	box: ^Input_Box,
	placeholder: string,
	options: Builder_Text_Input_Options,
) {
	assert(builder != nil && builder.bound, "Fit.Text_Input: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE) && box != nil, "Fit.Text_Input: invalid state")
	assert(options.semantics.name != "", "Fit.Text_Input: empty accessible label")
	ui.fit_builder_text_input(
		&builder.inner,
		{
			id = ui.Widget_Id(widget),
			box = &box.inner,
			placeholder = placeholder,
			height = options.height,
			masked = options.masked,
			semantics = to_text_semantics(options.semantics),
		},
		{
			track = to_track(options.track),
			size = to_size(options.size),
			changed = options.submitted,
		},
	)
}

@(private = "file")
builder_text_input_string :: proc(
	builder: ^Builder,
	key: string,
	box: ^Input_Box,
	placeholder: string,
	options: Builder_Text_Input_Options,
) {
	builder_text_input_id(builder, Id(builder, key), box, placeholder, options)
}

@(private = "file")
builder_text_input_u64 :: proc(
	builder: ^Builder,
	key: u64,
	box: ^Input_Box,
	placeholder: string,
	options: Builder_Text_Input_Options,
) {
	builder_text_input_id(builder, Id(builder, key), box, placeholder, options)
}

Text_Input :: proc {
	builder_text_input_string,
	builder_text_input_u64,
	builder_text_input_id,
}

Progress :: proc(builder: ^Builder, value: f32, options: Progress_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Progress: builder not bound")
	assert(value >= 0 && value <= 1, "Fit.Progress: value outside 0..1")
	height := options.height
	if height == 0 do height = 8
	ui.fit_builder_progress(
		&builder.inner,
		{
			value = value,
			ink = ui.Ink(options.ink),
			height = height,
			options = {label = options.label, field_id = options.field_id},
		},
		{track = to_track(options.track), size = to_size(options.size)},
	)
}

Separator :: proc(builder: ^Builder, options: Leaf_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Separator: builder not bound")
	assert(builder.inner.prepared.depth > 0, "Fit.Separator: no parent")
	ui.fit_builder_separator(&builder.inner, to_leaf_options(options))
}

Spacer :: proc(builder: ^Builder, space: Space, options: Leaf_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Spacer: builder not bound")
	assert(builder.inner.prepared.depth > 0, "Fit.Spacer: no parent")
	ui.fit_builder_spacer(&builder.inner, ui.Space(space), to_leaf_options(options))
}
