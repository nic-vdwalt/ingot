package fit

import "ingot:ui"

@(private = "file")
dropdown_id :: proc(
	parent: Parent,
	widget: Widget_Id,
	items: []string,
	selected: ^i32,
	state: ^Dropdown_State,
	a11y_label: string,
	options: Control_Options = {},
) {
	assert(parent.builder != nil, "Fit.Dropdown: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE), "Fit.Dropdown: zero widget")
	assert(selected != nil && state != nil && a11y_label != "", "Fit.Dropdown: invalid state")
	builder := parent_select(parent)
	ui.fit_builder_composite(
		&builder.inner,
		{
			kind = .Dropdown,
			dropdown = {
				id = ui.Widget_Id(widget),
				items = items,
				selected = selected,
				state = &state.inner,
				a11y_label = a11y_label,
			},
		},
		to_control_options(options),
	)
	parent_clear(builder)
}

@(private = "file")
dropdown_string :: proc(
	parent: Parent,
	key: string,
	items: []string,
	selected: ^i32,
	state: ^Dropdown_State,
	a11y_label: string,
	options: Control_Options = {},
) {
	dropdown_id(parent, Id(parent, key), items, selected, state, a11y_label, options)
}

@(private = "file")
dropdown_u64 :: proc(
	parent: Parent,
	key: u64,
	items: []string,
	selected: ^i32,
	state: ^Dropdown_State,
	a11y_label: string,
	options: Control_Options = {},
) {
	dropdown_id(parent, Id(parent, key), items, selected, state, a11y_label, options)
}

Dropdown :: proc {
	dropdown_string,
	dropdown_u64,
	dropdown_id,
}

@(private = "file")
combobox_id :: proc(
	parent: Parent,
	widget: Widget_Id,
	state: ^Combobox_State,
	items: []Combobox_Item,
	selected: ^u64,
	placeholder, a11y_label: string,
	options: Control_Options = {},
) {
	assert(parent.builder != nil, "Fit.Combobox: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE), "Fit.Combobox: zero widget")
	assert(state != nil && selected != nil && a11y_label != "", "Fit.Combobox: invalid state")
	builder := parent_select(parent)
	ui.fit_builder_composite(
		&builder.inner,
		{
			kind = .Combobox,
			combobox = {
				id = ui.Widget_Id(widget),
				state = &state.inner,
				items = items,
				selected = selected,
				placeholder = placeholder,
				a11y_label = a11y_label,
			},
		},
		to_control_options(options),
	)
	parent_clear(builder)
}

@(private = "file")
combobox_string :: proc(
	parent: Parent,
	key: string,
	state: ^Combobox_State,
	items: []Combobox_Item,
	selected: ^u64,
	placeholder, a11y_label: string,
	options: Control_Options = {},
) {
	combobox_id(parent, Id(parent, key), state, items, selected, placeholder, a11y_label, options)
}

@(private = "file")
combobox_u64 :: proc(
	parent: Parent,
	key: u64,
	state: ^Combobox_State,
	items: []Combobox_Item,
	selected: ^u64,
	placeholder, a11y_label: string,
	options: Control_Options = {},
) {
	combobox_id(parent, Id(parent, key), state, items, selected, placeholder, a11y_label, options)
}

Combobox :: proc {
	combobox_string,
	combobox_u64,
	combobox_id,
}

@(private = "file")
tabs_id :: proc(
	parent: Parent,
	widget: Widget_Id,
	labels: []string,
	active: ^i32,
	height: i32 = 36,
	options: Control_Options = {},
) {
	assert(parent.builder != nil, "Fit.Tabs: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE), "Fit.Tabs: zero widget")
	assert(active != nil && len(labels) > 0, "Fit.Tabs: invalid state")
	builder := parent_select(parent)
	ui.fit_builder_composite(
		&builder.inner,
		{
			kind = .Tabs,
			tabs = {id = ui.Widget_Id(widget), labels = labels, active = active, height = height},
		},
		to_control_options(options),
	)
	parent_clear(builder)
}

@(private = "file")
tabs_string :: proc(
	parent: Parent,
	key: string,
	labels: []string,
	active: ^i32,
	height: i32 = 36,
	options: Control_Options = {},
) {
	tabs_id(parent, Id(parent, key), labels, active, height, options)
}

@(private = "file")
tabs_u64 :: proc(
	parent: Parent,
	key: u64,
	labels: []string,
	active: ^i32,
	height: i32 = 36,
	options: Control_Options = {},
) {
	tabs_id(parent, Id(parent, key), labels, active, height, options)
}

Tabs :: proc {
	tabs_string,
	tabs_u64,
	tabs_id,
}
