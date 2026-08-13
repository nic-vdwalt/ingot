package ui

Fit_Builder :: struct {
	prepared:        Prepared_Ui,
	outputs:         [MAX_PREPARED_NODES]^bool,
	outputs_used:    i32,
	direct_children: [MAX_LAYOUT_DEPTH]i32,
	container_kinds: [MAX_LAYOUT_DEPTH]Prepared_Kind,
}

fit_begin :: proc(builder: ^Fit_Builder, u: ^Ui) {
	assert(builder != nil, "fit_begin: nil builder")
	assert(u != nil && u.open && u.frame != nil, "fit_begin: invalid UI")
	assert(!builder.prepared.open, "fit_begin: builder already open")
	assert(builder.outputs_used >= 0 && builder.outputs_used <= MAX_PREPARED_NODES)
	for index in 0 ..< builder.outputs_used do builder.outputs[index] = nil
	builder.outputs_used = 0
	prepared_begin(&builder.prepared, intrinsic_constraints(max_w = remaining_rect(u).w))
	builder.prepared.u = u
}

@(private = "package")
fit_row_builder :: proc(builder: ^Fit_Builder, options: Prepared_Container_Options = {}) {
	assert(builder != nil, "fit_builder_row: nil builder")
	fit_builder_container_begin(builder, .Row, options)
}

@(private = "package")
fit_column_builder :: proc(builder: ^Fit_Builder, options: Prepared_Container_Options = {}) {
	assert(builder != nil, "fit_builder_column: nil builder")
	fit_builder_container_begin(builder, .Column, options)
}

fit_builder_row :: fit_row_builder
fit_builder_column :: fit_column_builder

fit_builder_flow :: proc(builder: ^Fit_Builder, options: Prepared_Flow_Options = {}) {
	assert(builder != nil, "fit_builder_flow: nil builder")
	fit_builder_container_begin_special(builder, .Flow, options, {})
}

fit_builder_grid :: proc(builder: ^Fit_Builder, options: Prepared_Grid_Options) {
	fit_builder_container_begin_special(builder, .Grid, {}, options)
}

fit_end :: proc(builder: ^Fit_Builder) {
	fit_builder_assert_open(builder)
	assert(builder.prepared.depth > 0, "fit_end: no open container")
	prepared_container_end(&builder.prepared)
}

@(private = "package")
fit_label_builder :: proc(builder: ^Fit_Builder, text: string, options: Fit_Label_Options = {}) {
	assert(builder != nil, "fit_builder_label: nil builder")
	fit_builder_add_child(builder)
	assert(text != "", "fit_label: empty text")
	_ = prepared_label(
		&builder.prepared,
		Label_Spec{text = text, role = options.role, ink = options.ink, wrap = options.wrap},
		options.track,
		options.size,
	)
}

fit_builder_label :: fit_label_builder

@(private = "package")
fit_button_builder_string :: proc(
	builder: ^Fit_Builder,
	key, label: string,
	options: Fit_Button_Options = {},
) {
	assert(builder != nil, "fit_builder_button: nil builder")
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
	assert(builder != nil, "fit_builder_button: nil builder")
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
	assert(builder != nil, "fit_builder_button: nil builder")
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
	assert(builder != nil, "fit_builder_button: nil builder")
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
	value := spec
	if options.size != (Prepared_Size{}) do value.size = options.size
	handle := prepared_custom(&builder.prepared, value, options.track)
	fit_builder_output(builder, handle, options.activated)
}

fit_builder_custom :: fit_custom_builder

fit_measure :: proc(builder: ^Fit_Builder) -> Intrinsic_Size {
	fit_builder_assert_balanced(builder)
	return prepared_measure(builder.prepared.u, &builder.prepared)
}

fit_render_at :: proc(builder: ^Fit_Builder, rect: Rect_I32) {
	assert(builder != nil && builder.prepared.measured, "fit_render_at: builder not measured")
	assert(!builder.prepared.rendered, "fit_render_at: builder already rendered")
	fit_outputs_clear(&builder.outputs, builder.outputs_used)
	prepared_render_at(builder.prepared.u, &builder.prepared, rect)
	fit_outputs_publish(&builder.prepared, &builder.outputs, builder.outputs_used)
}

fit_render :: proc(builder: ^Fit_Builder) -> Rect_I32 {
	assert(builder != nil, "fit_render: nil builder")
	fit_builder_assert_balanced(builder)
	fit_outputs_clear(&builder.outputs, builder.outputs_used)
	rect := prepared_fit(builder.prepared.u, &builder.prepared)
	fit_outputs_publish(&builder.prepared, &builder.outputs, builder.outputs_used)
	return rect
}

@(private = "file")
fit_builder_assert_balanced :: proc(builder: ^Fit_Builder) {
	fit_builder_assert_open(builder)
	assert(builder.prepared.depth == 0, "fit builder: container still open")
	assert(builder.prepared.count > 0, "fit builder: empty builder")
	assert(builder.prepared.root >= 0, "fit builder: missing root")
	assert(builder.outputs_used == builder.prepared.count, "fit builder: output count mismatch")
}

@(private = "file")
fit_builder_assert_open :: proc(builder: ^Fit_Builder) {
	assert(builder != nil && builder.prepared.open, "fit builder: builder not open")
	assert(builder.prepared.u != nil && builder.prepared.u.open, "fit builder: invalid UI")
	assert(!builder.prepared.rendered, "fit builder: already rendered")
}

@(private = "file")
fit_builder_container_begin :: proc(
	builder: ^Fit_Builder,
	kind: Prepared_Kind,
	options: Prepared_Container_Options,
) {
	assert(builder != nil, "fit builder: nil builder")
	fit_builder_assert_open(builder)
	assert(kind == .Row || kind == .Column, "fit builder: invalid container")
	if builder.prepared.depth == 0 {
		assert(builder.prepared.count == 0, "fit builder: root already closed")
		fit_builder_prepare_node(builder)
	} else {
		fit_builder_add_child(builder)
	}
	assert(builder.prepared.depth < MAX_LAYOUT_DEPTH, "fit builder: depth full")
	if kind == .Row {
		_ = prepared_row_begin(&builder.prepared, options)
	} else {
		_ = prepared_column_begin(&builder.prepared, options)
	}
	depth := builder.prepared.depth - 1
	builder.direct_children[depth] = 0
	builder.container_kinds[depth] = kind
}

@(private = "file")
fit_builder_container_begin_special :: proc(
	builder: ^Fit_Builder,
	kind: Prepared_Kind,
	flow: Prepared_Flow_Options,
	grid: Prepared_Grid_Options,
) {
	assert(builder != nil, "fit builder: nil builder")
	fit_builder_assert_open(builder)
	assert(kind == .Flow || kind == .Grid, "fit builder: invalid special container")
	if builder.prepared.depth == 0 {
		assert(builder.prepared.count == 0, "fit builder: root already closed")
		fit_builder_prepare_node(builder)
	} else {
		fit_builder_add_child(builder)
	}
	if kind == .Flow {
		_ = prepared_flow_begin(&builder.prepared, flow)
	} else {
		_ = prepared_grid_begin(&builder.prepared, grid)
	}
	depth := builder.prepared.depth - 1
	assert(depth >= 0 && depth < MAX_LAYOUT_DEPTH, "fit builder: invalid depth")
	builder.direct_children[depth] = 0
	builder.container_kinds[depth] = kind
}

@(private = "file")
fit_builder_add_child :: proc(builder: ^Fit_Builder) {
	assert(builder != nil, "fit builder: nil builder")
	fit_builder_assert_open(builder)
	assert(builder.prepared.depth > 0, "fit builder: no open container")
	depth := builder.prepared.depth - 1
	limit := i32(MAX_LAYOUT_FLEX)
	kind := builder.container_kinds[depth]
	if kind == .Flow || kind == .Grid do limit = MAX_PREPARED_NODES - 1
	assert(builder.direct_children[depth] < limit, "fit builder: children full")
	fit_builder_prepare_node(builder)
	builder.direct_children[depth] += 1
}

@(private = "file")
fit_builder_prepare_node :: proc(builder: ^Fit_Builder) {
	assert(builder != nil, "fit builder: nil builder")
	index := builder.prepared.count
	assert(index >= 0 && index < MAX_PREPARED_NODES, "fit builder: nodes full")
	assert(index == builder.outputs_used, "fit builder: output mismatch")
	builder.outputs[index] = nil
	builder.outputs_used += 1
}

@(private = "file")
fit_builder_output :: proc(builder: ^Fit_Builder, handle: Prepared_Handle, destination: ^bool) {
	assert(builder != nil, "fit builder: nil builder")
	index := i32(handle)
	assert(index >= 0 && index < builder.prepared.count, "fit builder: invalid handle")
	assert(index < builder.outputs_used, "fit builder: unused output")
	builder.outputs[index] = destination
}

@(private = "file")
fit_button_options :: proc(options: Fit_Button_Options) -> Button_Options {
	return {style = options.style, disabled = options.disabled, web_form_id = options.web_form_id}
}
