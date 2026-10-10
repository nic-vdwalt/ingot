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
	assert(parent.builder != nil, "fit.dropdown: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE), "fit.dropdown: zero widget")
	assert(selected != nil && state != nil && a11y_label != "", "fit.dropdown: invalid state")
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
		options,
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
	dropdown_id(parent, id(parent, key), items, selected, state, a11y_label, options)
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
	dropdown_id(parent, id(parent, key), items, selected, state, a11y_label, options)
}

dropdown :: proc {
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
	assert(parent.builder != nil, "fit.combobox: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE), "fit.combobox: zero widget")
	assert(state != nil && selected != nil && a11y_label != "", "fit.combobox: invalid state")
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
		options,
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
	combobox_id(parent, id(parent, key), state, items, selected, placeholder, a11y_label, options)
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
	combobox_id(parent, id(parent, key), state, items, selected, placeholder, a11y_label, options)
}

combobox :: proc {
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
	assert(parent.builder != nil, "fit.tabs: builder not bound")
	assert(widget != Widget_Id(ui.WIDGET_ID_NONE), "fit.tabs: zero widget")
	assert(active != nil && len(labels) > 0, "fit.tabs: invalid state")
	builder := parent_select(parent)
	ui.fit_builder_composite(
		&builder.inner,
		{
			kind = .Tabs,
			tabs = {id = ui.Widget_Id(widget), labels = labels, active = active, height = height},
		},
		options,
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
	tabs_id(parent, id(parent, key), labels, active, height, options)
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
	tabs_id(parent, id(parent, key), labels, active, height, options)
}

tabs :: proc {
	tabs_string,
	tabs_u64,
	tabs_id,
}
