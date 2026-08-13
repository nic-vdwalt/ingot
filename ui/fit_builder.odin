package ui

Fit_Builder :: struct {
	prepared:        Prepared_Ui,
	outputs:         [MAX_PREPARED_NODES]^bool,
	direct_children: [MAX_LAYOUT_DEPTH]i32,
}

fit_begin :: proc(builder: ^Fit_Builder, u: ^Ui) {
	assert(builder != nil, "fit_begin: nil builder")
	assert(u != nil && u.open && u.frame != nil, "fit_begin: invalid UI")
	assert(!builder.prepared.open, "fit_begin: builder already open")
	builder^ = Fit_Builder{}
	prepared_begin(&builder.prepared, intrinsic_constraints(max_w = remaining_rect(u).w))
	builder.prepared.u = u
}

@(private = "package")
fit_row_builder :: proc(builder: ^Fit_Builder, options: Prepared_Container_Options = {}) {
	fit_builder_container_begin(builder, .Row, options)
}

@(private = "package")
fit_column_builder :: proc(builder: ^Fit_Builder, options: Prepared_Container_Options = {}) {
	fit_builder_container_begin(builder, .Column, options)
}

fit_builder_row :: fit_row_builder
fit_builder_column :: fit_column_builder

fit_end :: proc(builder: ^Fit_Builder) {
	fit_builder_assert_open(builder)
	assert(builder.prepared.depth > 0, "fit_end: no open container")
	prepared_container_end(&builder.prepared)
}

@(private = "package")
fit_label_builder :: proc(builder: ^Fit_Builder, text: string, options: Fit_Label_Options = {}) {
	fit_builder_add_child(builder)
	assert(text != "", "fit_label: empty text")
	_ = prepared_label(
		&builder.prepared,
		Label_Spec{text = text, role = options.role, ink = options.ink, wrap = options.wrap},
		options.track,
	)
}

fit_builder_label :: fit_label_builder

@(private = "package")
fit_button_builder_string :: proc(
	builder: ^Fit_Builder,
	key, label: string,
	options: Fit_Button_Options = {},
) {
	fit_builder_add_child(builder)
	assert(key != "" && label != "", "fit_button: invalid button")
	handle := prepared_button(
		&builder.prepared,
		key,
		label,
		fit_button_options(options),
		options.track,
	)
	fit_builder_output(builder, handle, options.activated)
}

@(private = "package")
fit_button_builder_u64 :: proc(
	builder: ^Fit_Builder,
	key: u64,
	label: string,
	options: Fit_Button_Options = {},
) {
	fit_builder_add_child(builder)
	assert(key != 0 && label != "", "fit_button: invalid button")
	handle := prepared_button(
		&builder.prepared,
		key,
		label,
		fit_button_options(options),
		options.track,
	)
	fit_builder_output(builder, handle, options.activated)
}

@(private = "package")
fit_button_builder_id :: proc(
	builder: ^Fit_Builder,
	widget: Widget_Id,
	label: string,
	options: Fit_Button_Options = {},
) {
	fit_builder_add_child(builder)
	assert(widget != WIDGET_ID_NONE && label != "", "fit_button: invalid button")
	handle := prepared_button(
		&builder.prepared,
		widget,
		label,
		fit_button_options(options),
		options.track,
	)
	fit_builder_output(builder, handle, options.activated)
}

@(private = "package")
fit_button_builder_spec :: proc(
	builder: ^Fit_Builder,
	spec: Button_Spec,
	track: Track = {},
	activated: ^bool = nil,
) {
	fit_builder_add_child(builder)
	assert(spec.id != WIDGET_ID_NONE && spec.label != "", "fit_button: invalid spec")
	handle := prepared_button(&builder.prepared, spec, track)
	fit_builder_output(builder, handle, activated)
}

@(private = "package")
fit_button_builder_string_active :: proc(
	builder: ^Fit_Builder,
	key, label: string,
	activated: ^bool,
) {
	assert(activated != nil, "fit_button: nil activation destination")
	fit_button_builder_string(builder, key, label, {activated = activated})
}

@(private = "package")
fit_button_builder_string_styled_active :: proc(
	builder: ^Fit_Builder,
	key, label: string,
	style: Btn_Style,
	activated: ^bool,
) {
	assert(activated != nil, "fit_button: nil activation destination")
	fit_button_builder_string(builder, key, label, {style = style, activated = activated})
}

@(private = "package")
fit_button_builder_u64_active :: proc(
	builder: ^Fit_Builder,
	key: u64,
	label: string,
	activated: ^bool,
) {
	assert(activated != nil, "fit_button: nil activation destination")
	fit_button_builder_u64(builder, key, label, {activated = activated})
}

@(private = "package")
fit_button_builder_u64_styled_active :: proc(
	builder: ^Fit_Builder,
	key: u64,
	label: string,
	style: Btn_Style,
	activated: ^bool,
) {
	assert(activated != nil, "fit_button: nil activation destination")
	fit_button_builder_u64(builder, key, label, {style = style, activated = activated})
}

@(private = "package")
fit_button_builder_id_active :: proc(
	builder: ^Fit_Builder,
	widget: Widget_Id,
	label: string,
	activated: ^bool,
) {
	assert(activated != nil, "fit_button: nil activation destination")
	fit_button_builder_id(builder, widget, label, {activated = activated})
}

@(private = "package")
fit_button_builder_id_styled_active :: proc(
	builder: ^Fit_Builder,
	widget: Widget_Id,
	label: string,
	style: Btn_Style,
	activated: ^bool,
) {
	assert(activated != nil, "fit_button: nil activation destination")
	fit_button_builder_id(builder, widget, label, {style = style, activated = activated})
}

fit_builder_button :: proc {
	fit_button_builder_string,
	fit_button_builder_string_active,
	fit_button_builder_string_styled_active,
	fit_button_builder_u64,
	fit_button_builder_u64_active,
	fit_button_builder_u64_styled_active,
	fit_button_builder_id,
	fit_button_builder_id_active,
	fit_button_builder_id_styled_active,
	fit_button_builder_spec,
}

@(private = "package")
fit_custom_builder :: proc(
	builder: ^Fit_Builder,
	spec: Prepared_Custom,
	options: Fit_Custom_Options = {},
) {
	fit_builder_add_child(builder)
	assert(spec.measure != nil && spec.render != nil, "fit_custom: invalid callbacks")
	handle := prepared_custom(&builder.prepared, spec, options.track)
	fit_builder_output(builder, handle, options.activated)
}

fit_builder_custom :: fit_custom_builder

fit_render :: proc(builder: ^Fit_Builder) -> Rect_I32 {
	fit_builder_assert_open(builder)
	assert(builder.prepared.depth == 0, "fit_render: container still open")
	assert(builder.prepared.count > 0, "fit_render: empty builder")
	assert(builder.prepared.root >= 0, "fit_render: missing root")
	root := &builder.prepared.nodes[builder.prepared.root]
	assert(root.kind == .Row || root.kind == .Column, "fit_render: root must be a container")
	fit_outputs_clear(&builder.outputs)
	rect := prepared_fit(builder.prepared.u, &builder.prepared)
	fit_outputs_publish(&builder.prepared, &builder.outputs)
	return rect
}

@(private = "file")
fit_builder_assert_open :: proc(builder: ^Fit_Builder) {
	assert(builder != nil && builder.prepared.open, "fit builder: builder not open")
	assert(builder.prepared.u != nil && builder.prepared.u.open, "fit builder: invalid UI")
	assert(
		!builder.prepared.measured && !builder.prepared.rendered,
		"fit builder: already consumed",
	)
}

@(private = "file")
fit_builder_container_begin :: proc(
	builder: ^Fit_Builder,
	kind: Prepared_Kind,
	options: Prepared_Container_Options,
) {
	fit_builder_assert_open(builder)
	assert(kind == .Row || kind == .Column, "fit builder: invalid container")
	if builder.prepared.depth == 0 {
		assert(builder.prepared.count == 0, "fit builder: root already closed")
	} else {
		fit_builder_add_child(builder)
	}
	assert(builder.prepared.depth < MAX_LAYOUT_DEPTH, "fit builder: depth full")
	if kind == .Row {
		_ = prepared_row_begin(&builder.prepared, options)
	} else {
		_ = prepared_column_begin(&builder.prepared, options)
	}
	builder.direct_children[builder.prepared.depth - 1] = 0
}

@(private = "file")
fit_builder_add_child :: proc(builder: ^Fit_Builder) {
	fit_builder_assert_open(builder)
	assert(builder.prepared.depth > 0, "fit builder: no open container")
	depth := builder.prepared.depth - 1
	assert(builder.direct_children[depth] < MAX_LAYOUT_FLEX, "fit builder: children full")
	builder.direct_children[depth] += 1
}

@(private = "file")
fit_builder_output :: proc(builder: ^Fit_Builder, handle: Prepared_Handle, destination: ^bool) {
	assert(builder != nil, "fit builder: nil builder")
	index := i32(handle)
	assert(index >= 0 && index < builder.prepared.count, "fit builder: invalid handle")
	builder.outputs[index] = destination
}

@(private = "file")
fit_button_options :: proc(options: Fit_Button_Options) -> Button_Options {
	return {style = options.style, disabled = options.disabled, web_form_id = options.web_form_id}
}
