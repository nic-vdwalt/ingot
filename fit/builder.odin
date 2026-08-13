package fit

import "ingot:ui"

Begin :: proc(builder: ^Builder) {
	assert(builder != nil && builder.bound, "Fit.Begin: builder not bound")
	assert(builder.root.open, "Fit.Begin: root not open")
	assert(builder.customs_used >= 0 && builder.customs_used <= i32(len(builder.customs)))
	builder.customs_used = 0
	ui.fit_begin(&builder.inner, &builder.root)
}

Set_Storage :: proc(builder: ^Builder, storage: Storage) {
	assert(builder != nil && !builder.bound, "Fit.Set_Storage: builder bound")
	assert(!builder.inner.prepared.open, "Fit.Set_Storage: description open")
	ui.fit_builder_set_storage(&builder.inner, to_storage(storage))
}

Reset_Storage :: proc(builder: ^Builder) {
	assert(builder != nil && !builder.bound, "Fit.Reset_Storage: builder bound")
	assert(!builder.inner.prepared.open, "Fit.Reset_Storage: description open")
	ui.fit_builder_reset_storage(&builder.inner)
}

Storage_Capacity :: proc(builder: ^Builder) -> int {
	assert(builder != nil, "Fit.Storage_Capacity: nil builder")
	assert(!builder.inner.prepared.open || builder.bound, "Fit.Storage_Capacity: invalid state")
	return ui.prepared_capacity(&builder.inner.prepared)
}

Row :: proc(builder: ^Builder, options: Container_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Row: builder not bound")
	ui.fit_builder_row(&builder.inner, to_container_options(options))
}

Column :: proc(builder: ^Builder, options: Container_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Column: builder not bound")
	ui.fit_builder_column(&builder.inner, to_container_options(options))
}

Flow :: proc(builder: ^Builder, options: Flow_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Flow: builder not bound")
	ui.fit_builder_flow(&builder.inner, to_flow_options(options))
}

Grid :: proc(builder: ^Builder, options: Grid_Options) {
	assert(builder != nil && builder.bound, "Fit.Grid: builder not bound")
	ui.fit_builder_grid(&builder.inner, to_grid_options(options))
}

Attachment :: proc(builder: ^Builder, options: Attachment_Options) {
	assert(builder != nil && builder.bound, "Fit.Attachment: builder not bound")
	ui.fit_builder_attachment(&builder.inner, to_attachment_options(options))
}

Label :: proc(builder: ^Builder, text: string, options: Label_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Label: builder not bound")
	ui.fit_builder_label(&builder.inner, text, to_label_options(options))
}

@(private = "package")
button_string :: proc(builder: ^Builder, key, label: string, options: Button_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Button: builder not bound")
	ui.fit_builder_button(&builder.inner, key, label, to_button_options(options))
}

@(private = "package")
button_u64 :: proc(builder: ^Builder, key: u64, label: string, options: Button_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Button: builder not bound")
	ui.fit_builder_button(&builder.inner, key, label, to_button_options(options))
}

@(private = "package")
button_id :: proc(
	builder: ^Builder,
	widget: Widget_Id,
	label: string,
	options: Button_Options = {},
) {
	assert(builder != nil && builder.bound, "Fit.Button: builder not bound")
	ui.fit_builder_button(&builder.inner, ui.Widget_Id(widget), label, to_button_options(options))
}

@(private = "package")
button_string_active :: proc(builder: ^Builder, key, label: string, activated: ^bool) {
	assert(activated != nil, "Fit.Button: nil activation destination")
	button_string(builder, key, label, {activated = activated})
}

@(private = "package")
button_u64_active :: proc(builder: ^Builder, key: u64, label: string, activated: ^bool) {
	assert(activated != nil, "Fit.Button: nil activation destination")
	button_u64(builder, key, label, {activated = activated})
}

@(private = "package")
button_id_active :: proc(builder: ^Builder, widget: Widget_Id, label: string, activated: ^bool) {
	assert(activated != nil, "Fit.Button: nil activation destination")
	button_id(builder, widget, label, {activated = activated})
}

Button :: proc {
	button_string,
	button_string_active,
	button_u64,
	button_u64_active,
	button_id,
	button_id_active,
}

Custom :: proc(builder: ^Builder, spec: Custom_Spec, options: Custom_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Custom: builder not bound")
	assert(spec.measure != nil && spec.render != nil, "Fit.Custom: invalid callbacks")
	assert(builder.customs_used < i32(len(builder.customs)), "Fit.Custom: custom capacity full")
	index := builder.customs_used
	builder.customs[index] = spec
	builder.customs_used += 1
	ui.fit_builder_custom(
		&builder.inner,
		{
			measure = custom_measure_bridge,
			render = custom_render_bridge,
			userdata = &builder.customs[index],
			size = to_size(spec.size),
		},
		to_custom_options(options),
	)
}

Canvas :: Custom

End :: proc(builder: ^Builder) {
	assert(builder != nil && builder.bound, "Fit.End: builder not bound")
	ui.fit_end(&builder.inner)
}

Measure :: proc(builder: ^Builder) -> Size {
	assert(builder != nil && builder.bound, "Fit.Measure: builder not bound")
	return from_size_value(ui.fit_measure(&builder.inner))
}

Render_At :: proc(builder: ^Builder, rect: Rect) {
	assert(builder != nil && builder.bound, "Fit.Render_At: builder not bound")
	ui.fit_render_at(&builder.inner, to_rect(rect))
}

Render :: proc(builder: ^Builder) -> Rect {
	assert(builder != nil && builder.bound, "Fit.Render: builder not bound")
	return from_rect(ui.fit_render(&builder.inner))
}

@(private = "file")
custom_measure_bridge :: proc(
	root: ^ui.Ui,
	constraints: ui.Intrinsic_Constraints,
	userdata: rawptr,
) -> ui.Intrinsic_Size {
	assert(root != nil && userdata != nil, "Fit.Custom: invalid measure bridge")
	spec := cast(^Custom_Spec)userdata
	assert(spec.measure != nil, "Fit.Custom: nil measure callback")
	return to_size_value(spec.measure(from_constraints(constraints), spec.userdata))
}

@(private = "file")
custom_render_bridge :: proc(root: ^ui.Ui, rect: ui.Rect_I32, userdata: rawptr) -> bool {
	assert(root != nil && userdata != nil, "Fit.Custom: invalid render bridge")
	spec := cast(^Custom_Spec)userdata
	assert(spec.render != nil, "Fit.Custom: nil render callback")
	surface := Surface {
		inner = root,
	}
	return spec.render(&surface, from_rect(rect), spec.userdata)
}

@(private = "package")
builder_open :: proc(builder: ^Builder, frame: ^ui.Ui_Frame, rect: Rect) {
	assert(builder != nil && !builder.bound, "fit builder: already bound")
	assert(frame != nil && frame.open, "fit builder: frame not open")
	ui.begin(&builder.root, frame, to_rect(rect))
	builder.bound = true
	Begin(builder)
}

@(private = "package")
builder_close :: proc(builder: ^Builder) {
	assert(builder != nil && builder.bound, "fit builder: not bound")
	assert(builder.root.open, "fit builder: root not open")
	ui.end(&builder.root)
	builder.bound = false
}
