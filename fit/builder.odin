package fit

import "ingot:ui"

Begin :: proc(builder: ^Builder) {
	assert(builder != nil && builder.bound, "Fit.Begin: builder not bound")
	assert(builder.root.open, "Fit.Begin: root not open")
	ui.fit_begin(&builder.inner, &builder.root)
}

Row :: proc(builder: ^Builder, options: Container_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Row: builder not bound")
	ui.fit_builder_row(&builder.inner, options)
}

Column :: proc(builder: ^Builder, options: Container_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Column: builder not bound")
	ui.fit_builder_column(&builder.inner, options)
}

Flow :: proc(builder: ^Builder, options: Flow_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Flow: builder not bound")
	ui.fit_builder_flow(&builder.inner, options)
}

Grid :: proc(builder: ^Builder, options: Grid_Options) {
	assert(builder != nil && builder.bound, "Fit.Grid: builder not bound")
	ui.fit_builder_grid(&builder.inner, options)
}

Attachment :: proc(builder: ^Builder, options: Attachment_Options) {
	assert(builder != nil && builder.bound, "Fit.Attachment: builder not bound")
	ui.fit_builder_attachment(&builder.inner, options)
}

Label :: proc(builder: ^Builder, text: string, options: Label_Options = {}) {
	assert(builder != nil && builder.bound, "Fit.Label: builder not bound")
	ui.fit_builder_label(&builder.inner, text, options)
}

@(private = "package")
button_string :: proc(
	builder: ^Builder,
	key, label: string,
	options: Button_Options = {},
) {
	assert(builder != nil && builder.bound, "Fit.Button: builder not bound")
	ui.fit_builder_button(&builder.inner, key, label, options)
}

@(private = "package")
button_u64 :: proc(
	builder: ^Builder,
	key: u64,
	label: string,
	options: Button_Options = {},
) {
	assert(builder != nil && builder.bound, "Fit.Button: builder not bound")
	ui.fit_builder_button(&builder.inner, key, label, options)
}

@(private = "package")
button_id :: proc(
	builder: ^Builder,
	widget: Widget_Id,
	label: string,
	options: Button_Options = {},
) {
	assert(builder != nil && builder.bound, "Fit.Button: builder not bound")
	ui.fit_builder_button(&builder.inner, widget, label, options)
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
	ui.fit_builder_custom(&builder.inner, spec, options)
}

End :: proc(builder: ^Builder) {
	assert(builder != nil && builder.bound, "Fit.End: builder not bound")
	ui.fit_end(&builder.inner)
}

Measure :: proc(builder: ^Builder) -> Size {
	assert(builder != nil && builder.bound, "Fit.Measure: builder not bound")
	return ui.fit_measure(&builder.inner)
}

Render_At :: proc(builder: ^Builder, rect: Rect) {
	assert(builder != nil && builder.bound, "Fit.Render_At: builder not bound")
	ui.fit_render_at(&builder.inner, rect)
}

Render :: proc(builder: ^Builder) -> Rect {
	assert(builder != nil && builder.bound, "Fit.Render: builder not bound")
	return ui.fit_render(&builder.inner)
}

@(private = "package")
builder_open :: proc(builder: ^Builder, frame: ^ui.Ui_Frame, rect: Rect) {
	assert(builder != nil && !builder.bound, "fit builder: already bound")
	assert(frame != nil && frame.open, "fit builder: frame not open")
	ui.begin(&builder.root, frame, rect)
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
