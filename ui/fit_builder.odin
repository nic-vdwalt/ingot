package ui

Fit_Action_Proc :: #type proc(userdata: rawptr)
Fit_Tagged_Action_Proc :: #type proc(userdata: rawptr, tag: u64)

Fit_Action :: struct {
	procedure:        Fit_Action_Proc,
	tagged_procedure: Fit_Tagged_Action_Proc,
	userdata:         rawptr,
	tag:              u64,
}

Fit_Label_Options :: struct {
	role:  Text_Role,
	ink:   Ink,
	wrap:  bool,
	track: Track,
	size:  Prepared_Size,
}

Fit_Button_Options :: struct {
	style:       Btn_Style,
	disabled:    bool,
	web_form_id: string,
	track:       Track,
	size:        Prepared_Size,
	// activated is written during fit_render/fit_render_at, after the build
	// code has run. It must point to storage that outlives the build (global
	// or app state, never a build-scope local), and is typically consumed
	// and cleared at the start of the next build.
	activated:   ^bool,
	action:      Fit_Action,
}

Fit_Control_Options :: struct {
	track:   Track,
	size:    Prepared_Size,
	// changed follows the activated lifetime contract on Fit_Button_Options.
	changed: ^bool,
}

Fit_Leaf_Options :: struct {
	track: Track,
	size:  Prepared_Size,
}

Fit_Custom_Options :: struct {
	track:     Track,
	size:      Prepared_Size,
	// activated follows the lifetime contract on Fit_Button_Options.
	activated: ^bool,
}

Fit_Storage :: struct {
	nodes:   []Prepared_Node,
	outputs: []^bool,
}

Fit_Builder :: struct {
	prepared:        Prepared_Ui,
	outputs:         [MAX_PREPARED_NODES]^bool,
	external:        []^bool,
	output_count:    i32,
	direct_children: [MAX_LAYOUT_DEPTH]i32,
	container_kinds: [MAX_LAYOUT_DEPTH]Prepared_Kind,
}

fit_builder_set_storage :: proc(builder: ^Fit_Builder, storage: Fit_Storage) {
	assert(builder != nil && !builder.prepared.open, "fit_builder_set_storage: builder open")
	fit_storage_assert_valid(storage)
	prepared_set_storage(&builder.prepared, {nodes = storage.nodes})
	builder.external = storage.outputs
}

fit_builder_reset_storage :: proc(builder: ^Fit_Builder) {
	assert(builder != nil && !builder.prepared.open, "fit_builder_reset_storage: builder open")
	assert(builder.output_count >= 0, "fit_builder_reset_storage: invalid count")
	prepared_reset_storage(&builder.prepared)
	builder.external = nil
}

@(private = "package")
fit_storage_assert_valid :: proc(storage: Fit_Storage) {
	assert(storage.nodes != nil && storage.outputs != nil, "fit storage: nil slices")
	assert(len(storage.nodes) == len(storage.outputs), "fit storage: capacity mismatch")
	assert(len(storage.nodes) >= MAX_LAYOUT_DEPTH, "fit storage: capacity too small")
	assert(len(storage.nodes) <= MAX_PREPARED_NODES_HARD, "fit storage: capacity too large")
}

@(private = "package")
fit_builder_outputs :: proc(builder: ^Fit_Builder) -> []^bool {
	assert(builder != nil, "fit_builder_outputs: nil builder")
	if builder.external != nil do return builder.external
	return builder.outputs[:]
}

fit_begin :: proc(builder: ^Fit_Builder, u: ^Ui) {
	assert(builder != nil, "fit_begin: nil builder")
	assert(u != nil && u.open && u.frame != nil, "fit_begin: invalid UI")
	assert(!builder.prepared.open, "fit_begin: builder already open")
	outputs := fit_builder_outputs(builder)
	assert(len(outputs) == prepared_capacity(&builder.prepared), "fit_begin: capacity mismatch")
	assert(builder.output_count >= 0 && builder.output_count <= i32(len(outputs)))
	for index in 0 ..< builder.output_count do outputs[index] = nil
	builder.output_count = 0
	remaining := remaining_rect(u)
	prepared_begin(
		&builder.prepared,
		intrinsic_constraints(max_w = remaining.w, max_h = remaining.h),
	)
	builder.prepared.u = u
}

fit_parent_select :: proc(builder: ^Fit_Builder, parent: Prepared_Handle) {
	fit_builder_assert_open(builder)
	assert(builder.prepared.depth == 0, "fit parent: selection already active")
	index := i32(parent)
	assert(index >= 0 && index < builder.prepared.count, "fit parent: invalid handle")
	node := prepared_nodes(&builder.prepared)[index]
	assert(prepared_kind_is_container(node.kind), "fit parent: handle is not container")
	builder.prepared.stack[0] = index
	builder.prepared.depth = 1
	builder.direct_children[0] = node.child_count
	builder.container_kinds[0] = node.kind
}

fit_parent_created :: proc(builder: ^Fit_Builder) -> Prepared_Handle {
	fit_builder_assert_open(builder)
	depth := builder.prepared.depth
	assert(depth == 1 || depth == 2, "fit parent: invalid creation depth")
	stack_index := depth - 1
	assert(
		stack_index >= 0 && stack_index < len(builder.prepared.stack),
		"fit parent: invalid stack index",
	)
	handle := Prepared_Handle(builder.prepared.stack[stack_index])
	builder.prepared.depth = 0
	return handle
}

fit_parent_clear :: proc(builder: ^Fit_Builder) {
	fit_builder_assert_open(builder)
	assert(builder.prepared.depth == 1, "fit parent: invalid selection depth")
	builder.prepared.depth = 0
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

fit_builder_row :: proc(builder: ^Fit_Builder, options: Prepared_Container_Options = {}) {
	assert(builder != nil, "fit_builder_row: nil builder")
	fit_row_builder(builder, options)
}

fit_builder_column :: proc(builder: ^Fit_Builder, options: Prepared_Container_Options = {}) {
	assert(builder != nil, "fit_builder_column: nil builder")
	fit_column_builder(builder, options)
}

fit_builder_flow :: proc(builder: ^Fit_Builder, options: Prepared_Flow_Options = {}) {
	assert(builder != nil, "fit_builder_flow: nil builder")
	fit_builder_container_begin_special(builder, .Flow, options, {})
}

fit_builder_grid :: proc(builder: ^Fit_Builder, options: Prepared_Grid_Options) {
	fit_builder_container_begin_special(builder, .Grid, {}, options)
}

fit_builder_attachment :: proc(builder: ^Fit_Builder, options: Prepared_Attachment_Options) {
	assert(builder != nil, "fit_builder_attachment: nil builder")
	fit_builder_assert_open(builder)
	assert(builder.prepared.depth > 0, "fit_builder_attachment: attachment cannot be root")
	fit_builder_add_child(builder)
	_ = prepared_attachment_begin(&builder.prepared, options)
	depth := builder.prepared.depth - 1
	builder.direct_children[depth] = 0
	builder.container_kinds[depth] = .Attachment
}

fit_builder_scroll :: proc(builder: ^Fit_Builder, options: Prepared_Scroll_Options) {
	assert(builder != nil, "fit_builder_scroll: nil builder")
	assert(options.state != nil, "fit_builder_scroll: nil state")
	fit_builder_assert_open(builder)
	if builder.prepared.depth == 0 {
		assert(builder.prepared.count == 0, "fit_builder_scroll: root already closed")
		fit_builder_prepare_node(builder)
	} else {
		fit_builder_add_child(builder)
	}
	_ = prepared_scroll_begin(&builder.prepared, options)
	depth := builder.prepared.depth - 1
	assert(depth >= 0 && depth < MAX_LAYOUT_DEPTH, "fit_builder_scroll: invalid depth")
	builder.direct_children[depth] = 0
	builder.container_kinds[depth] = .Scroll
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

fit_builder_label :: proc(builder: ^Fit_Builder, text: string, options: Fit_Label_Options = {}) {
	assert(builder != nil, "fit_builder_label: nil builder")
	fit_label_builder(builder, text, options)
}

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
	node := &prepared_nodes(&builder.prepared)[i32(handle)]
	node.sizing = options.size
	fit_builder_action_set(node, options.activated, options.action)
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
	node := &prepared_nodes(&builder.prepared)[i32(handle)]
	node.sizing = options.size
	fit_builder_action_set(node, options.activated, options.action)
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
	node := &prepared_nodes(&builder.prepared)[i32(handle)]
	node.sizing = options.size
	fit_builder_action_set(node, options.activated, options.action)
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
	node := &prepared_nodes(&builder.prepared)[i32(handle)]
	fit_builder_action_set(node, activated, {})
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

fit_builder_checkbox :: proc(
	builder: ^Fit_Builder,
	spec: Checkbox_Spec,
	options: Fit_Control_Options = {},
) {
	assert(builder != nil, "fit_builder_checkbox: nil builder")
	fit_builder_add_child(builder)
	handle := prepared_checkbox(&builder.prepared, spec, options.track)
	prepared_nodes(&builder.prepared)[i32(handle)].sizing = options.size
	fit_builder_output(builder, handle, options.changed)
}

fit_builder_radio :: proc(
	builder: ^Fit_Builder,
	spec: Radio_Spec,
	options: Fit_Control_Options = {},
) {
	assert(builder != nil, "fit_builder_radio: nil builder")
	fit_builder_add_child(builder)
	handle := prepared_radio(&builder.prepared, spec, options.track)
	prepared_nodes(&builder.prepared)[i32(handle)].sizing = options.size
	fit_builder_output(builder, handle, options.changed)
}

fit_builder_slider :: proc(
	builder: ^Fit_Builder,
	spec: Slider_Spec,
	options: Fit_Control_Options = {},
) {
	assert(builder != nil, "fit_builder_slider: nil builder")
	fit_builder_add_child(builder)
	handle := prepared_slider(&builder.prepared, spec, options.track)
	prepared_nodes(&builder.prepared)[i32(handle)].sizing = options.size
	fit_builder_output(builder, handle, options.changed)
}

fit_builder_text_input :: proc(
	builder: ^Fit_Builder,
	spec: Prepared_Text_Input,
	options: Fit_Control_Options = {},
) {
	assert(builder != nil, "fit_builder_text_input: nil builder")
	assert(
		spec.id != WIDGET_ID_NONE && prepared_text_input_source_ok(spec),
		"fit_builder_text_input: invalid spec",
	)
	fit_builder_add_child(builder)
	handle := prepared_text_input(&builder.prepared, spec, options.track)
	prepared_nodes(&builder.prepared)[i32(handle)].sizing = options.size
	fit_builder_output(builder, handle, options.changed)
}

fit_builder_progress :: proc(
	builder: ^Fit_Builder,
	spec: Prepared_Progress,
	options: Fit_Leaf_Options = {},
) {
	assert(builder != nil, "fit_builder_progress: nil builder")
	assert(spec.value >= 0 && spec.value <= 1, "fit_builder_progress: invalid value")
	fit_builder_add_child(builder)
	handle := prepared_progress(&builder.prepared, spec, options.track)
	prepared_nodes(&builder.prepared)[i32(handle)].sizing = options.size
}

fit_builder_separator :: proc(builder: ^Fit_Builder, options: Fit_Leaf_Options = {}) {
	assert(builder != nil, "fit_builder_separator: nil builder")
	fit_builder_add_child(builder)
	handle := prepared_separator(&builder.prepared, options.track)
	prepared_nodes(&builder.prepared)[i32(handle)].sizing = options.size
}

fit_builder_spacer :: proc(builder: ^Fit_Builder, space: Space, options: Fit_Leaf_Options = {}) {
	assert(builder != nil, "fit_builder_spacer: nil builder")
	fit_builder_assert_open(builder)
	assert(builder.prepared.depth > 0, "fit_builder_spacer: no parent")
	depth := builder.prepared.depth - 1
	assert(depth >= 0 && depth < len(builder.container_kinds), "fit_builder_spacer: invalid depth")
	parent := builder.container_kinds[depth]
	assert(parent == .Row || parent == .Column, "fit_builder_spacer: invalid parent")
	fit_builder_add_child(builder)
	handle := prepared_spacer(&builder.prepared, {space, parent == .Row}, options.track)
	index := i32(handle)
	assert(index >= 0 && index < builder.prepared.count, "fit_builder_spacer: invalid handle")
	prepared_nodes(&builder.prepared)[index].sizing = options.size
}

fit_builder_table_cell :: proc(
	builder: ^Fit_Builder,
	spec: Prepared_Table_Cell,
	options: Fit_Leaf_Options = {},
) {
	assert(builder != nil, "fit_builder_table_cell: nil builder")
	assert(spec.text != "", "fit_builder_table_cell: empty text")
	fit_builder_add_child(builder)
	handle := prepared_table_cell(&builder.prepared, spec, options.track)
	prepared_nodes(&builder.prepared)[i32(handle)].sizing = options.size
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

fit_builder_custom :: proc(
	builder: ^Fit_Builder,
	spec: Prepared_Custom,
	options: Fit_Custom_Options = {},
) {
	assert(builder != nil, "fit_builder_custom: nil builder")
	fit_custom_builder(builder, spec, options)
}

fit_measure :: proc(builder: ^Fit_Builder) -> Intrinsic_Size {
	fit_builder_assert_balanced(builder)
	return prepared_measure(builder.prepared.u, &builder.prepared)
}

fit_render_at :: proc(builder: ^Fit_Builder, rect: Rect_I32) {
	assert(builder != nil && builder.prepared.measured, "fit_render_at: builder not measured")
	assert(!builder.prepared.rendered, "fit_render_at: builder already rendered")
	outputs := fit_builder_outputs(builder)
	clear_started := prepared_phase_begin(builder.prepared.u.frame, .Output_Clear)
	fit_outputs_clear(outputs, builder.output_count)
	prepared_phase_end(builder.prepared.u.frame, .Output_Clear, clear_started)
	prepared_render_at(builder.prepared.u, &builder.prepared, rect)
	fit_actions_dispatch(builder)
}

fit_render :: proc(builder: ^Fit_Builder) -> Rect_I32 {
	assert(builder != nil, "fit_render: nil builder")
	fit_builder_assert_balanced(builder)
	outputs := fit_builder_outputs(builder)
	clear_started := prepared_phase_begin(builder.prepared.u.frame, .Output_Clear)
	fit_outputs_clear(outputs, builder.output_count)
	prepared_phase_end(builder.prepared.u.frame, .Output_Clear, clear_started)
	rect := prepared_fit(builder.prepared.u, &builder.prepared)
	fit_actions_dispatch(builder)
	return rect
}

@(private = "file")
fit_builder_action_set :: proc(node: ^Prepared_Node, activated: ^bool, action: Fit_Action) {
	assert(node != nil && node.kind == .Button, "fit action: invalid node")
	has_simple := action.procedure != nil
	has_tagged := action.tagged_procedure != nil
	assert(!has_simple || !has_tagged, "fit action: ambiguous procedure")
	assert(activated == nil || (!has_simple && !has_tagged), "fit action: duplicate delivery")
	node.action = action
}

@(private = "file")
fit_actions_dispatch :: proc(builder: ^Fit_Builder) {
	assert(builder != nil && builder.prepared.rendered, "fit actions: builder not rendered")
	nodes := prepared_nodes(&builder.prepared)
	assert(builder.prepared.count >= 0 && builder.prepared.count <= i32(len(nodes)))
	dispatched := false
	for index in 0 ..< builder.prepared.count {
		node := &nodes[index]
		if !node.activated do continue
		action := node.action
		if action.procedure == nil && action.tagged_procedure == nil do continue
		node.activated = false
		if action.procedure != nil {
			action.procedure(action.userdata)
		} else {
			action.tagged_procedure(action.userdata, action.tag)
		}
		dispatched = true
	}
	if dispatched do request_redraw(builder.prepared.u.frame)
}

@(private = "file")
fit_outputs_clear :: proc(outputs: []^bool, used: i32) {
	assert(outputs != nil, "fit_outputs_clear: nil outputs")
	assert(used >= 0 && used <= i32(len(outputs)), "fit_outputs_clear: invalid count")
	for index in 0 ..< used {
		destination := outputs[index]
		if destination != nil do destination^ = false
	}
}

@(private = "file")
fit_builder_assert_balanced :: proc(builder: ^Fit_Builder) {
	fit_builder_assert_open(builder)
	assert(builder.prepared.depth == 0, "fit builder: container still open")
	assert(builder.prepared.count > 0, "fit builder: empty builder")
	assert(builder.prepared.root >= 0, "fit builder: missing root")
	assert(builder.output_count >= 0, "fit builder: invalid output count")
	nodes := prepared_nodes(&builder.prepared)
	for index in 0 ..< builder.prepared.count {
		node := nodes[index]
		if node.kind == .Attachment || node.kind == .Scroll {
			assert(node.child_count == 1, "fit builder: special container requires one child")
		}
	}
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
	if kind == .Flow || kind == .Grid do limit = i32(prepared_capacity(&builder.prepared) - 1)
	if kind == .Attachment || kind == .Scroll do limit = 1
	assert(builder.direct_children[depth] < limit, "fit builder: children full")
	fit_builder_prepare_node(builder)
	builder.direct_children[depth] += 1
}

@(private = "file")
fit_builder_prepare_node :: proc(builder: ^Fit_Builder) {
	assert(builder != nil, "fit builder: nil builder")
	index := builder.prepared.count
	assert(index >= 0, "fit builder: negative node index")
	assert(index < i32(prepared_capacity(&builder.prepared)), "fit builder: nodes full")
}

@(private = "file")
fit_builder_output :: proc(builder: ^Fit_Builder, handle: Prepared_Handle, destination: ^bool) {
	assert(builder != nil, "fit builder: nil builder")
	index := i32(handle)
	assert(index >= 0 && index < builder.prepared.count, "fit builder: invalid handle")
	if destination == nil do return
	outputs := fit_builder_outputs(builder)
	assert(builder.output_count < i32(len(outputs)), "fit builder: outputs full")
	outputs[builder.output_count] = destination
	prepared_nodes(&builder.prepared)[index].activation = destination
	builder.output_count += 1
}

@(private = "file")
fit_button_options :: proc(options: Fit_Button_Options) -> Button_Options {
	return {style = options.style, disabled = options.disabled, web_form_id = options.web_form_id}
}
