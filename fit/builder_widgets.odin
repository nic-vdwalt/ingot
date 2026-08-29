package fit

import "core:strings"
import "ingot:ui"

@(private = "file")
checkbox_id :: proc(
	parent: Parent,
	widget: Widget_Id,
	label: string,
	checked: ^bool,
	options: Control_Options = {},
) {
	assert(parent.builder != nil, "Fit.Checkbox: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE), "Fit.Checkbox: zero widget")
	assert(label != "" && checked != nil, "Fit.Checkbox: invalid argument")
	builder := parent_select(parent)
	ui.fit_builder_checkbox(
		&builder.inner,
		{id = ui.Widget_Id(widget), label = label, checked = checked},
		to_control_options(options),
	)
	parent_clear(builder)
}

@(private = "file")
checkbox_string :: proc(
	parent: Parent,
	key, label: string,
	checked: ^bool,
	options: Control_Options = {},
) {
	checkbox_id(parent, Id(parent, key), label, checked, options)
}

@(private = "file")
checkbox_u64 :: proc(
	parent: Parent,
	key: u64,
	label: string,
	checked: ^bool,
	options: Control_Options = {},
) {
	checkbox_id(parent, Id(parent, key), label, checked, options)
}

Checkbox :: proc {
	checkbox_string,
	checkbox_u64,
	checkbox_id,
}

@(private = "file")
toggle_id :: proc(
	parent: Parent,
	widget: Widget_Id,
	label: string,
	checked: ^bool,
	options: Control_Options = {},
) {
	assert(parent.builder != nil, "Fit.Toggle: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE), "Fit.Toggle: zero widget")
	assert(label != "" && checked != nil, "Fit.Toggle: invalid argument")
	builder := parent_select(parent)
	ui.fit_builder_composite(
		&builder.inner,
		{kind = .Toggle, toggle = {id = ui.Widget_Id(widget), label = label, checked = checked}},
		to_control_options(options),
	)
	parent_clear(builder)
}

@(private = "file")
toggle_string :: proc(
	parent: Parent,
	key, label: string,
	checked: ^bool,
	options: Control_Options = {},
) {
	toggle_id(parent, Id(parent, key), label, checked, options)
}

@(private = "file")
toggle_u64 :: proc(
	parent: Parent,
	key: u64,
	label: string,
	checked: ^bool,
	options: Control_Options = {},
) {
	toggle_id(parent, Id(parent, key), label, checked, options)
}

Toggle :: proc {
	toggle_string,
	toggle_u64,
	toggle_id,
}

@(private = "file")
radio_id :: proc(
	parent: Parent,
	widget: Widget_Id,
	label: string,
	selected: ^i32,
	value: i32,
	options: Control_Options = {},
) {
	assert(parent.builder != nil, "Fit.Radio: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE), "Fit.Radio: zero widget")
	assert(label != "" && selected != nil, "Fit.Radio: invalid argument")
	builder := parent_select(parent)
	ui.fit_builder_radio(
		&builder.inner,
		{id = ui.Widget_Id(widget), label = label, selected = selected, value = value},
		to_control_options(options),
	)
	parent_clear(builder)
}

@(private = "file")
radio_string :: proc(
	parent: Parent,
	key, label: string,
	selected: ^i32,
	value: i32,
	options: Control_Options = {},
) {
	radio_id(parent, Id(parent, key), label, selected, value, options)
}

@(private = "file")
radio_u64 :: proc(
	parent: Parent,
	key: u64,
	label: string,
	selected: ^i32,
	value: i32,
	options: Control_Options = {},
) {
	radio_id(parent, Id(parent, key), label, selected, value, options)
}

Radio :: proc {
	radio_string,
	radio_u64,
	radio_id,
}

@(private = "file")
slider_id :: proc(
	parent: Parent,
	widget: Widget_Id,
	value: ^f32,
	minimum, maximum, step: f32,
	a11y_label: string,
	options: Control_Options = {},
) {
	assert(parent.builder != nil, "Fit.Slider: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE) && value != nil, "Fit.Slider: invalid argument")
	assert(maximum > minimum && step >= 0 && a11y_label != "", "Fit.Slider: invalid range")
	builder := parent_select(parent)
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
	parent_clear(builder)
}

@(private = "file")
slider_string :: proc(
	parent: Parent,
	key: string,
	value: ^f32,
	minimum, maximum, step: f32,
	a11y_label: string,
	options: Control_Options = {},
) {
	slider_id(parent, Id(parent, key), value, minimum, maximum, step, a11y_label, options)
}

@(private = "file")
slider_u64 :: proc(
	parent: Parent,
	key: u64,
	value: ^f32,
	minimum, maximum, step: f32,
	a11y_label: string,
	options: Control_Options = {},
) {
	slider_id(parent, Id(parent, key), value, minimum, maximum, step, a11y_label, options)
}

Slider :: proc {
	slider_string,
	slider_u64,
	slider_id,
}

@(private = "file")
builder_text_input_id :: proc(
	parent: Parent,
	widget: Widget_Id,
	box: ^Input_Box,
	placeholder: string,
	options: Builder_Text_Input_Options,
) {
	assert(parent.builder != nil, "Fit.Text_Input: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE) && box != nil, "Fit.Text_Input: invalid state")
	assert(options.semantics.name != "", "Fit.Text_Input: empty accessible label")
	builder := parent_select(parent)
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
	parent_clear(builder)
}

@(private = "file")
builder_text_input_string :: proc(
	parent: Parent,
	key: string,
	box: ^Input_Box,
	placeholder: string,
	options: Builder_Text_Input_Options,
) {
	builder_text_input_id(parent, Id(parent, key), box, placeholder, options)
}

@(private = "file")
builder_text_input_u64 :: proc(
	parent: Parent,
	key: u64,
	box: ^Input_Box,
	placeholder: string,
	options: Builder_Text_Input_Options,
) {
	builder_text_input_id(parent, Id(parent, key), box, placeholder, options)
}

// builder_text_input_state binds a declarative text input to caller-owned
// state (strings.Builder + Text_Input_State) instead of a bundled Input_Box,
// so app code can reuse buffers it already maintains. Mirrors the imperative
// Surface_Text_Input_State path through ui.text_input_box.
@(private = "file")
builder_text_input_state :: proc(
	parent: Parent,
	key: string,
	text: ^strings.Builder,
	state: ^Text_Input_State,
	placeholder: string,
	options: Builder_Text_Input_Options,
) {
	assert(parent.builder != nil, "Fit.Text_Input: builder not bound")
	assert(text != nil && state != nil, "Fit.Text_Input: invalid state")
	assert(options.semantics.name != "", "Fit.Text_Input: empty accessible label")
	widget := Id(parent, key)
	builder := parent_select(parent)
	ui.fit_builder_text_input(
		&builder.inner,
		{
			id = ui.Widget_Id(widget),
			text = text,
			state = &state.inner,
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
	parent_clear(builder)
}

Text_Input :: proc {
	builder_text_input_string,
	builder_text_input_u64,
	builder_text_input_id,
	builder_text_input_state,
}

Progress :: proc(parent: Parent, value: f32, options: Progress_Options = {}) {
	assert(parent.builder != nil, "Fit.Progress: builder not bound")
	assert(value >= 0 && value <= 1, "Fit.Progress: value outside 0..1")
	height := options.height
	if height == 0 do height = 8
	builder := parent_select(parent)
	ui.fit_builder_progress(
		&builder.inner,
		{
			value = value,
			ink = options.ink,
			height = height,
			options = {label = options.label, field_id = options.field_id},
		},
		{track = to_track(options.track), size = to_size(options.size)},
	)
	parent_clear(builder)
}

Separator :: proc(parent: Parent, options: Leaf_Options = {}) {
	builder := parent_select(parent)
	ui.fit_builder_separator(&builder.inner, to_leaf_options(options))
	parent_clear(builder)
}

Spacer :: proc(parent: Parent, space: Space, options: Leaf_Options = {}) {
	builder := parent_select(parent)
	ui.fit_builder_spacer(&builder.inner, space, to_leaf_options(options))
	parent_clear(builder)
}
