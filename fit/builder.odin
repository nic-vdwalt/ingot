package fit

import "ingot:ui"

Begin :: proc(builder: ^Builder) {
	assert(builder != nil && builder.bound, "Fit.Begin: builder not bound")
	assert(builder.root.open, "Fit.Begin: root not open")
	assert(builder.customs_used >= 0 && builder.customs_used <= i32(custom_capacity(builder)))
	assert(builder.generation < max(u64), "Fit.Begin: generation exhausted")
	builder.customs_used = 0
	builder.generation += 1
	ui.fit_begin(&builder.inner, &builder.root)
}

Set_Storage :: proc(builder: ^Builder, storage: Storage) {
	assert(builder != nil && !builder.bound, "Fit.Set_Storage: builder bound")
	assert(!builder.inner.prepared.open, "Fit.Set_Storage: description open")
	ui.fit_builder_set_storage(&builder.inner, to_storage(storage))
	builder.custom_storage = storage.customs
}

Reset_Storage :: proc(builder: ^Builder) {
	assert(builder != nil && !builder.bound, "Fit.Reset_Storage: builder bound")
	assert(!builder.inner.prepared.open, "Fit.Reset_Storage: description open")
	ui.fit_builder_reset_storage(&builder.inner)
	builder.custom_storage = nil
}

Storage_Capacity :: proc(builder: ^Builder) -> int {
	assert(builder != nil, "Fit.Storage_Capacity: nil builder")
	assert(!builder.inner.prepared.open || builder.bound, "Fit.Storage_Capacity: invalid state")
	return ui.prepared_capacity(&builder.inner.prepared)
}

Custom_Capacity :: proc(builder: ^Builder) -> int {
	assert(builder != nil, "Fit.Custom_Capacity: nil builder")
	return custom_capacity(builder)
}

@(private = "file")
custom_capacity :: proc(builder: ^Builder) -> int {
	assert(builder != nil, "fit custom capacity: nil builder")
	if builder.custom_storage != nil do return len(builder.custom_storage)
	return len(builder.customs)
}

@(private = "file")
custom_at :: proc(builder: ^Builder, index: int) -> ^Custom_Spec {
	assert(builder != nil && index >= 0 && index < custom_capacity(builder))
	if builder.custom_storage != nil do return &builder.custom_storage[index]
	return &builder.customs[index]
}

@(private = "package")
parent_validate :: proc(parent: Parent) -> ^Builder {
	builder := parent.builder
	assert(builder != nil && builder.bound, "Fit.Parent: builder not bound")
	assert(
		parent.generation != 0 && parent.generation == builder.generation,
		"Fit.Parent: stale handle",
	)
	assert(parent.identity != ui.WIDGET_ID_NONE, "Fit.Parent: invalid identity")
	index := i32(parent.handle)
	assert(index >= 0 && index < builder.inner.prepared.count, "Fit.Parent: invalid handle")
	return builder
}

@(private = "file")
parent_root :: proc(builder: ^Builder, handle: ui.Prepared_Handle) -> Parent {
	assert(builder != nil && builder.bound && builder.generation != 0, "Fit.Parent: invalid root")
	return {builder, builder.generation, handle, ui.fit_identity_root()}
}

@(private = "file")
parent_child :: proc(parent: Parent, handle: ui.Prepared_Handle) -> Parent {
	builder := parent_validate(parent)
	return {builder, builder.generation, handle, parent.identity}
}

@(private = "package")
parent_select :: proc(parent: Parent) -> ^Builder {
	builder := parent_validate(parent)
	ui.fit_parent_select(&builder.inner, parent.handle)
	return builder
}

@(private = "package")
parent_clear :: proc(builder: ^Builder) {
	assert(builder != nil && builder.bound, "Fit.Parent: builder not bound")
	ui.fit_parent_clear(&builder.inner)
}

@(private = "file")
row_root :: proc(builder: ^Builder, options: Container_Options = {}) -> Parent {
	assert(builder != nil && builder.bound, "Fit.Row: builder not bound")
	ui.fit_builder_row(&builder.inner, to_container_options(options))
	handle := ui.fit_parent_created(&builder.inner)
	return parent_root(builder, handle)
}

@(private = "file")
row_child :: proc(parent: Parent, options: Container_Options = {}) -> Parent {
	builder := parent_select(parent)
	ui.fit_builder_row(&builder.inner, to_container_options(options))
	handle := ui.fit_parent_created(&builder.inner)
	return parent_child(parent, handle)
}

Row :: proc {
	row_root,
	row_child,
}

@(private = "file")
column_root :: proc(builder: ^Builder, options: Container_Options = {}) -> Parent {
	assert(builder != nil && builder.bound, "Fit.Column: builder not bound")
	ui.fit_builder_column(&builder.inner, to_container_options(options))
	handle := ui.fit_parent_created(&builder.inner)
	return parent_root(builder, handle)
}

@(private = "file")
column_child :: proc(parent: Parent, options: Container_Options = {}) -> Parent {
	builder := parent_select(parent)
	ui.fit_builder_column(&builder.inner, to_container_options(options))
	handle := ui.fit_parent_created(&builder.inner)
	return parent_child(parent, handle)
}

Column :: proc {
	column_root,
	column_child,
}

Center :: proc(builder: ^Builder, options: Container_Options = {}) -> Parent {
	assert(builder != nil && builder.bound, "Fit.Center: builder not bound")
	assert(builder.inner.prepared.count == 0, "Fit.Center: root already declared")
	resolved := options
	resolved.align = .Center
	resolved.justify = .Center
	resolved.size = {
		width  = Grow(),
		height = Grow(),
	}
	return column_root(builder, resolved)
}

@(private = "file")
flow_root :: proc(builder: ^Builder, options: Flow_Options = {}) -> Parent {
	assert(builder != nil && builder.bound, "Fit.Flow: builder not bound")
	ui.fit_builder_flow(&builder.inner, to_flow_options(options))
	handle := ui.fit_parent_created(&builder.inner)
	return parent_root(builder, handle)
}

@(private = "file")
flow_child :: proc(parent: Parent, options: Flow_Options = {}) -> Parent {
	builder := parent_select(parent)
	ui.fit_builder_flow(&builder.inner, to_flow_options(options))
	handle := ui.fit_parent_created(&builder.inner)
	return parent_child(parent, handle)
}

Flow :: proc {
	flow_root,
	flow_child,
}

@(private = "file")
grid_root :: proc(builder: ^Builder, options: Grid_Options) -> Parent {
	assert(builder != nil && builder.bound, "Fit.Grid: builder not bound")
	ui.fit_builder_grid(&builder.inner, to_grid_options(options))
	handle := ui.fit_parent_created(&builder.inner)
	return parent_root(builder, handle)
}

@(private = "file")
grid_child :: proc(parent: Parent, options: Grid_Options) -> Parent {
	builder := parent_select(parent)
	ui.fit_builder_grid(&builder.inner, to_grid_options(options))
	handle := ui.fit_parent_created(&builder.inner)
	return parent_child(parent, handle)
}

Grid :: proc {
	grid_root,
	grid_child,
}

Attachment :: proc(parent: Parent, options: Attachment_Options) -> Parent {
	builder := parent_select(parent)
	ui.fit_builder_attachment(&builder.inner, to_attachment_options(options))
	handle := ui.fit_parent_created(&builder.inner)
	return parent_child(parent, handle)
}

@(private = "package")
scroll_string :: proc(
	parent: Parent,
	key: string,
	state: ^Scroll_State,
	options: Scroll_Options = {},
) -> Parent {
	assert(key != "" && state != nil, "Fit.Scroll: invalid state")
	return scroll_id(parent, Id(parent, key), state, options)
}

@(private = "package")
scroll_u64 :: proc(
	parent: Parent,
	key: u64,
	state: ^Scroll_State,
	options: Scroll_Options = {},
) -> Parent {
	assert(key != 0 && state != nil, "Fit.Scroll: invalid state")
	return scroll_id(parent, Id(parent, key), state, options)
}

@(private = "package")
scroll_id :: proc(
	parent: Parent,
	widget: Widget_Id,
	state: ^Scroll_State,
	options: Scroll_Options = {},
) -> Parent {
	assert(widget != Widget_Id(0) && state != nil, "Fit.Scroll: invalid state")
	builder := parent_select(parent)
	ui.fit_builder_scroll(&builder.inner, to_scroll_options(widget, state, options))
	handle := ui.fit_parent_created(&builder.inner)
	return parent_child(parent, handle)
}

@(private = "package")
scroll_compat :: proc(
	parent: Parent,
	state: ^Scroll_State,
	options: Scroll_Options = {},
) -> Parent {
	assert(state != nil, "Fit.Scroll: nil state")
	return scroll_id(parent, Id(parent, u64(0x7363726f6c6c)), state, options)
}

Scroll :: proc {
	scroll_string,
	scroll_u64,
	scroll_id,
	scroll_compat,
}

Scroll_Reset :: proc(state: ^Scroll_State) {
	assert(state != nil, "Fit.Scroll_Reset: nil state")
	state.inner = {}
}

Scroll_Offset :: proc(state: ^Scroll_State) -> f32 {
	assert(state != nil, "Fit.Scroll_Offset: nil state")
	return state.inner.offset
}

Scroll_Viewport_Height :: proc(state: ^Scroll_State) -> i32 {
	assert(state != nil, "Fit.Scroll_Viewport_Height: nil state")
	return state.inner.viewport_h
}

Scroll_Reveal_Range :: proc(state: ^Scroll_State, top, bottom: i32) {
	assert(state != nil, "Fit.Scroll_Reveal_Range: nil state")
	assert(top >= 0 && bottom >= top, "Fit.Scroll_Reveal_Range: invalid range")
	viewport := state.inner.viewport_h
	if viewport <= 0 do return
	if f32(top) < state.inner.offset {
		state.inner.offset = f32(top)
	} else if f32(bottom) > state.inner.offset + f32(viewport) {
		state.inner.offset = f32(bottom - viewport)
	}
	maximum := max(state.inner.content_h - viewport, 0)
	state.inner.offset = clamp(state.inner.offset, 0, f32(maximum))
}

Scroll_Content_Height :: proc(state: ^Scroll_State) -> i32 {
	assert(state != nil, "Fit.Scroll_Content_Height: nil state")
	return state.inner.content_h
}

Label :: proc(parent: Parent, text: string, options: Label_Options = {}) {
	builder := parent_select(parent)
	ui.fit_builder_label(&builder.inner, text, to_label_options(options))
	parent_clear(builder)
}

Signal_Peek :: proc(signal: ^Signal) -> bool {
	assert(signal != nil, "Fit.Signal_Peek: nil signal")
	return signal.pending
}

Signal_Take :: proc(signal: ^Signal) -> bool {
	assert(signal != nil, "Fit.Signal_Take: nil signal")
	pending := signal.pending
	signal.pending = false
	return pending
}

Signal_Reset :: proc(signal: ^Signal) {
	assert(signal != nil, "Fit.Signal_Reset: nil signal")
	signal.pending = false
}

@(private = "package")
action_plain :: proc(procedure: Action_Proc, user_data: rawptr = nil) -> Action {
	assert(procedure != nil, "fit.action: nil procedure")
	return {procedure = procedure, user_data = user_data}
}

@(private = "package")
action_tagged :: proc(procedure: Tagged_Action_Proc, user_data: rawptr, tag: u64) -> Action {
	assert(procedure != nil, "fit.action: nil tagged procedure")
	return {tagged_procedure = procedure, user_data = user_data, tag = tag}
}

action :: proc {
	action_plain,
	action_tagged,
}

@(private = "package")
button_string :: proc(parent: Parent, key, label: string, options: Button_Options = {}) {
	button_id(parent, Id(parent, key), label, options)
}

@(private = "package")
button_u64 :: proc(parent: Parent, key: u64, label: string, options: Button_Options = {}) {
	button_id(parent, Id(parent, key), label, options)
}

@(private = "package")
button_id :: proc(parent: Parent, widget: Widget_Id, label: string, options: Button_Options = {}) {
	builder := parent_select(parent)
	ui.fit_builder_button(&builder.inner, ui.Widget_Id(widget), label, to_button_options(options))
	parent_clear(builder)
}

@(private = "package")
button_string_action :: proc(parent: Parent, key, label: string, action: Action) {
	button_string(parent, key, label, {action = action})
}

@(private = "package")
button_string_active :: proc(parent: Parent, key, label: string, activated: ^bool) {
	assert(activated != nil, "Fit.Button: nil activation destination")
	button_string(parent, key, label, {activated = activated})
}

@(private = "package")
button_u64_action :: proc(parent: Parent, key: u64, label: string, action: Action) {
	button_u64(parent, key, label, {action = action})
}

@(private = "package")
button_u64_active :: proc(parent: Parent, key: u64, label: string, activated: ^bool) {
	assert(activated != nil, "Fit.Button: nil activation destination")
	button_u64(parent, key, label, {activated = activated})
}

@(private = "package")
button_id_action :: proc(parent: Parent, widget: Widget_Id, label: string, action: Action) {
	button_id(parent, widget, label, {action = action})
}

@(private = "package")
button_id_active :: proc(parent: Parent, widget: Widget_Id, label: string, activated: ^bool) {
	assert(activated != nil, "Fit.Button: nil activation destination")
	button_id(parent, widget, label, {activated = activated})
}

@(private = "package")
button_string_signal :: proc(parent: Parent, key, label: string, signal: ^Signal) -> bool {
	assert(signal != nil, "Fit.Button: nil signal")
	activated := Signal_Take(signal)
	button_string(parent, key, label, {activated = &signal.pending})
	return activated
}

@(private = "package")
button_u64_signal :: proc(parent: Parent, key: u64, label: string, signal: ^Signal) -> bool {
	assert(signal != nil, "Fit.Button: nil signal")
	activated := Signal_Take(signal)
	button_u64(parent, key, label, {activated = &signal.pending})
	return activated
}

@(private = "package")
button_id_signal :: proc(
	parent: Parent,
	widget: Widget_Id,
	label: string,
	signal: ^Signal,
) -> bool {
	assert(signal != nil, "Fit.Button: nil signal")
	activated := Signal_Take(signal)
	button_id(parent, widget, label, {activated = &signal.pending})
	return activated
}

Button :: proc {
	button_string,
	button_string_action,
	button_string_active,
	button_u64,
	button_u64_action,
	button_u64_active,
	button_id,
	button_id_action,
	button_id_active,
}

Button_Delayed :: proc {
	button_string_signal,
	button_u64_signal,
	button_id_signal,
}

Custom :: proc(parent: Parent, spec: Custom_Spec, options: Custom_Options = {}) {
	assert(spec.measure != nil && spec.render != nil, "Fit.Custom: invalid callbacks")
	custom_add(parent, spec, options)
}

@(private = "package")
custom_intrinsic :: proc(parent: Parent, spec: Custom_Spec, options: Custom_Options) {
	assert(spec.render != nil, "fit custom intrinsic: nil render callback")
	assert(spec.intrinsic.w >= 0 && spec.intrinsic.h >= 0, "fit custom intrinsic: invalid size")
	value := spec
	value.measure = custom_intrinsic_measure
	custom_add(parent, value, options)
}

@(private = "file")
custom_add :: proc(parent: Parent, spec: Custom_Spec, options: Custom_Options) {
	builder := parent_select(parent)
	assert(spec.measure != nil && spec.render != nil, "fit custom add: invalid callbacks")
	assert(builder.customs_used < i32(custom_capacity(builder)), "fit custom add: capacity full")
	index := int(builder.customs_used)
	stored := custom_at(builder, index)
	stored^ = spec
	builder.customs_used += 1
	ui.fit_builder_custom(
		&builder.inner,
		{
			measure = custom_measure_bridge,
			render = custom_render_bridge,
			userdata = stored,
			size = to_size(spec.size),
		},
		to_custom_options(options),
	)
	parent_clear(builder)
}

Canvas :: proc(builder: ^Builder, render: Render_Proc, user_data: rawptr = nil) {
	assert(builder != nil && builder.bound, "Fit.Canvas: builder not bound")
	assert(render != nil, "Fit.Canvas: nil render callback")
	assert(builder.inner.prepared.count == 0, "Fit.Canvas: root already declared")
	root := Column(builder)
	Custom(
		root,
		{measure = canvas_measure, render = render, user_data = user_data},
		{size = {width = Grow(), height = Grow()}},
	)
}

@(private = "file")
canvas_measure :: proc(constraints: Constraints, user_data: rawptr) -> Size {
	_ = user_data
	return {w = max(constraints.max_w, 1), h = max(constraints.max_h, 1)}
}

@(private = "file")
custom_intrinsic_measure :: proc(constraints: Constraints, user_data: rawptr) -> Size {
	assert(user_data != nil, "fit custom intrinsic measure: nil context")
	assert(
		constraints.max_w >= 0 && constraints.max_h >= 0,
		"fit custom intrinsic measure: invalid bounds",
	)
	spec := cast(^Custom_Spec)user_data
	return spec.intrinsic
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
	assert(!builder.inner.prepared.rendered, "Fit.Render: builder already rendered")
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
	measure_user_data := spec.user_data
	if spec.measure == custom_intrinsic_measure do measure_user_data = spec
	return to_size_value(spec.measure(from_constraints(constraints), measure_user_data))
}

@(private = "file")
custom_render_bridge :: proc(root: ^ui.Ui, rect: ui.Rect_I32, userdata: rawptr) -> bool {
	assert(root != nil && userdata != nil, "Fit.Custom: invalid render bridge")
	spec := cast(^Custom_Spec)userdata
	assert(spec.render != nil, "Fit.Custom: nil render callback")
	surface := Surface {
		inner = root,
	}
	return spec.render(&surface, from_rect(rect), spec.user_data)
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
