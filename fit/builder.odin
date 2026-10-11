package fit

import "ingot:ui"

begin :: proc(builder: ^Builder) {
	assert(builder != nil && builder.bound, "fit.begin: builder not bound")
	assert(builder.root.open, "fit.begin: root not open")
	assert(builder.customs_used >= 0 && builder.customs_used <= i32(custom_slot_capacity(builder)))
	assert(builder.generation < max(u64), "fit.begin: generation exhausted")
	builder.customs_used = 0
	builder.generation += 1
	ui.fit_begin(&builder.inner, &builder.root)
}

set_storage :: proc(builder: ^Builder, storage: Storage) {
	assert(builder != nil && !builder.bound, "fit.set_storage: builder bound")
	assert(!builder.inner.prepared.open, "fit.set_storage: description open")
	ui.fit_builder_set_storage(&builder.inner, to_storage(storage))
	builder.custom_storage = storage.customs
}

reset_storage :: proc(builder: ^Builder) {
	assert(builder != nil && !builder.bound, "fit.reset_storage: builder bound")
	assert(!builder.inner.prepared.open, "fit.reset_storage: description open")
	ui.fit_builder_reset_storage(&builder.inner)
	builder.custom_storage = nil
}

storage_capacity :: proc(builder: ^Builder) -> int {
	assert(builder != nil, "fit.storage_capacity: nil builder")
	assert(!builder.inner.prepared.open || builder.bound, "fit.storage_capacity: invalid state")
	return ui.prepared_capacity(&builder.inner.prepared)
}

custom_capacity :: proc(builder: ^Builder) -> int {
	assert(builder != nil, "fit.custom_capacity: nil builder")
	return custom_slot_capacity(builder)
}

@(private = "file")
custom_slot_capacity :: proc(builder: ^Builder) -> int {
	assert(builder != nil, "fit custom capacity: nil builder")
	if builder.custom_storage != nil do return len(builder.custom_storage)
	return len(builder.customs)
}

@(private = "file")
custom_at :: proc(builder: ^Builder, index: int) -> ^Custom_Spec {
	assert(builder != nil && index >= 0 && index < custom_slot_capacity(builder))
	if builder.custom_storage != nil do return &builder.custom_storage[index]
	return &builder.customs[index]
}

@(private = "package")
parent_validate :: proc(parent: Parent) -> ^Builder {
	builder := parent.builder
	assert(builder != nil && builder.bound, "fit.Parent: builder not bound")
	assert(
		parent.generation != 0 && parent.generation == builder.generation,
		"fit.Parent: stale handle",
	)
	assert(ui.ui_frame_ticket_valid(builder.frame_ticket), "fit.Parent: expired frame")
	assert(ui.ui_frame_phase(builder.frame_ticket) == .Build, "fit.Parent: invalid phase")
	assert(parent.identity != ui.WIDGET_ID_NONE, "fit.Parent: invalid identity")
	index := i32(parent.handle)
	assert(index >= 0 && index < builder.inner.prepared.count, "fit.Parent: invalid handle")
	return builder
}

debug_frame_access_get :: proc(builder: ^Builder) -> Debug_Frame_Access {
	assert(builder != nil && builder.bound, "fit.debug_frame_access_get: builder not bound")
	assert(
		ui.ui_frame_ticket_valid(builder.frame_ticket),
		"fit.debug_frame_access_get: expired frame",
	)
	return {builder = builder, generation = builder.generation, frame = builder.frame_ticket}
}

debug_frame_access_valid :: proc(access: Debug_Frame_Access) -> bool {
	return(
		access.builder != nil &&
		access.builder.bound &&
		access.generation != 0 &&
		access.builder.generation == access.generation &&
		ui.ui_frame_ticket_valid(access.frame) \
	)
}

debug_async_begin :: proc(builder: ^Builder) -> (Debug_Async_Ticket, bool) {
	assert(builder != nil && builder.owner.alive, "fit.debug_async_begin: retired owner")
	if builder.owner.outstanding == max(u32) do return {}, false
	builder.owner.outstanding += 1
	return {owner = &builder.owner, epoch = builder.owner.epoch}, true
}

debug_async_complete :: proc(ticket: Debug_Async_Ticket) {
	assert(ticket.owner != nil, "fit.debug_async_complete: nil owner")
	assert(
		ticket.owner.alive && ticket.owner.epoch == ticket.epoch,
		"fit.debug_async_complete: completion into destroyed owner",
	)
	assert(ticket.owner.outstanding > 0, "fit.debug_async_complete: duplicate completion")
	ticket.owner.outstanding -= 1
}

@(private = "package")
debug_owner_assert_quiescent :: proc(builder: ^Builder) {
	assert(builder != nil && builder.owner.alive, "fit debug owner: invalid owner")
	assert(builder.owner.outstanding == 0, "fit debug owner: callbacks outstanding")
}

@(private = "package")
debug_owner_retire :: proc(builder: ^Builder) {
	assert(builder != nil, "fit debug owner: nil builder")
	if !builder.owner.alive {
		assert(builder.owner.outstanding == 0, "fit debug owner: invalid retired owner")
		return
	}
	debug_owner_assert_quiescent(builder)
	ui.fit_results_reset(&builder.inner)
	builder.owner.alive = false
}

@(private = "package")
debug_owner_prepare :: proc(builder: ^Builder) {
	assert(builder != nil, "fit debug owner: nil builder")
	if builder.owner.alive do return
	assert(builder.owner.epoch < max(u64), "fit debug owner: epoch exhausted")
	ui.fit_results_reset(&builder.inner)
	builder.owner.epoch += 1
	builder.owner.alive = true
}

@(private = "file")
parent_root :: proc(builder: ^Builder, handle: ui.Prepared_Handle) -> Parent {
	assert(builder != nil && builder.bound && builder.generation != 0, "fit.Parent: invalid root")
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
	assert(builder != nil && builder.bound, "fit.Parent: builder not bound")
	ui.fit_parent_clear(&builder.inner)
}

@(private = "file")
row_root :: proc(builder: ^Builder, options: Container_Options = {}) -> Parent {
	assert(builder != nil && builder.bound, "fit.row: builder not bound")
	effects_validate(options.effects)
	ui.fit_builder_row(&builder.inner, options)
	handle := ui.fit_parent_created(&builder.inner)
	return parent_root(builder, handle)
}

@(private = "file")
row_child :: proc(parent: Parent, options: Container_Options = {}) -> Parent {
	builder := parent_select(parent)
	effects_validate(options.effects)
	ui.fit_builder_row(&builder.inner, options)
	handle := ui.fit_parent_created(&builder.inner)
	return parent_child(parent, handle)
}

row :: proc {
	row_root,
	row_child,
}

@(private = "file")
column_root :: proc(builder: ^Builder, options: Container_Options = {}) -> Parent {
	assert(builder != nil && builder.bound, "fit.column: builder not bound")
	effects_validate(options.effects)
	ui.fit_builder_column(&builder.inner, options)
	handle := ui.fit_parent_created(&builder.inner)
	return parent_root(builder, handle)
}

@(private = "file")
column_child :: proc(parent: Parent, options: Container_Options = {}) -> Parent {
	builder := parent_select(parent)
	effects_validate(options.effects)
	ui.fit_builder_column(&builder.inner, options)
	handle := ui.fit_parent_created(&builder.inner)
	return parent_child(parent, handle)
}

column :: proc {
	column_root,
	column_child,
}

center :: proc(builder: ^Builder, options: Container_Options = {}) -> Parent {
	assert(builder != nil && builder.bound, "fit.center: builder not bound")
	assert(builder.inner.prepared.count == 0, "fit.center: root already declared")
	resolved := options
	resolved.align = .Center
	resolved.justify = .Center
	resolved.size = {
		width  = grow(),
		height = grow(),
	}
	return column_root(builder, resolved)
}

@(private = "file")
flow_root :: proc(builder: ^Builder, options: Flow_Options = {}) -> Parent {
	assert(builder != nil && builder.bound, "fit.flow: builder not bound")
	effects_validate(options.effects)
	ui.fit_builder_flow(&builder.inner, options)
	handle := ui.fit_parent_created(&builder.inner)
	return parent_root(builder, handle)
}

@(private = "file")
flow_child :: proc(parent: Parent, options: Flow_Options = {}) -> Parent {
	builder := parent_select(parent)
	effects_validate(options.effects)
	ui.fit_builder_flow(&builder.inner, options)
	handle := ui.fit_parent_created(&builder.inner)
	return parent_child(parent, handle)
}

flow :: proc {
	flow_root,
	flow_child,
}

@(private = "file")
grid_root :: proc(builder: ^Builder, options: Grid_Options) -> Parent {
	assert(builder != nil && builder.bound, "fit.grid: builder not bound")
	grid_options_validate(options)
	ui.fit_builder_grid(&builder.inner, options)
	handle := ui.fit_parent_created(&builder.inner)
	return parent_root(builder, handle)
}

@(private = "file")
grid_child :: proc(parent: Parent, options: Grid_Options) -> Parent {
	builder := parent_select(parent)
	grid_options_validate(options)
	ui.fit_builder_grid(&builder.inner, options)
	handle := ui.fit_parent_created(&builder.inner)
	return parent_child(parent, handle)
}

grid :: proc {
	grid_root,
	grid_child,
}

grid_cell :: proc(parent: Parent, options: Grid_Cell_Options = {}) -> Parent {
	builder := parent_select(parent)
	ui.fit_builder_grid_cell(&builder.inner, to_grid_cell_options(options))
	handle := ui.fit_parent_created(&builder.inner)
	return parent_child(parent, handle)
}

attachment :: proc(parent: Parent, options: Attachment_Options) -> Parent {
	builder := parent_select(parent)
	ui.fit_builder_attachment(&builder.inner, options)
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
	assert(key != "" && state != nil, "fit.scroll: invalid state")
	return scroll_id(parent, id(parent, key), state, options)
}

@(private = "package")
scroll_u64 :: proc(
	parent: Parent,
	key: u64,
	state: ^Scroll_State,
	options: Scroll_Options = {},
) -> Parent {
	assert(key != 0 && state != nil, "fit.scroll: invalid state")
	return scroll_id(parent, id(parent, key), state, options)
}

@(private = "package")
scroll_id :: proc(
	parent: Parent,
	widget: Widget_Id,
	state: ^Scroll_State,
	options: Scroll_Options = {},
) -> Parent {
	assert(widget != Widget_Id(0) && state != nil, "fit.scroll: invalid state")
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
	assert(state != nil, "fit.scroll: nil state")
	return scroll_id(parent, id(parent, u64(0x7363726f6c6c)), state, options)
}

scroll :: proc {
	scroll_string,
	scroll_u64,
	scroll_id,
	scroll_compat,
}

scroll_reset :: proc(state: ^Scroll_State) {
	assert(state != nil, "fit.scroll_reset: nil state")
	state.inner = {}
}

scroll_offset :: proc(state: ^Scroll_State) -> f32 {
	assert(state != nil, "fit.scroll_offset: nil state")
	return state.inner.offset
}

scroll_viewport_height :: proc(state: ^Scroll_State) -> i32 {
	assert(state != nil, "fit.scroll_viewport_height: nil state")
	return state.inner.viewport_h
}

scroll_reveal_range :: proc(state: ^Scroll_State, top, bottom: i32) {
	assert(state != nil, "fit.scroll_reveal_range: nil state")
	assert(top >= 0 && bottom >= top, "fit.scroll_reveal_range: invalid range")
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

scroll_content_height :: proc(state: ^Scroll_State) -> i32 {
	assert(state != nil, "fit.scroll_content_height: nil state")
	return state.inner.content_h
}

label :: proc(parent: Parent, text: string, options: Label_Options = {}) {
	builder := parent_select(parent)
	ui.fit_builder_label(&builder.inner, text, options)
	parent_clear(builder)
}

signal_peek :: proc(signal: ^Signal) -> bool {
	assert(signal != nil, "fit.signal_peek: nil signal")
	return signal.pending
}

signal_take :: proc(signal: ^Signal) -> bool {
	assert(signal != nil, "fit.signal_take: nil signal")
	pending := signal.pending
	signal.pending = false
	return pending
}

signal_reset :: proc(signal: ^Signal) {
	assert(signal != nil, "fit.signal_reset: nil signal")
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
Button_Key :: union {
	string,
	u64,
	Widget_Id,
}

@(private = "package")
button_key_resolve :: proc(parent: Parent, key: Button_Key) -> Widget_Id {
	switch k in key {
	case string:
		return id(parent, k)
	case u64:
		return id(parent, k)
	case Widget_Id:
		return k
	}
	unreachable()
}

@(private = "package")
button_impl :: proc(parent: Parent, key: Button_Key, label: string, options: Button_Options) {
	builder := parent_select(parent)
	widget := button_key_resolve(parent, key)
	ui.fit_builder_button(&builder.inner, ui.Widget_Id(widget), label, options)
	parent_clear(builder)
}

@(private = "package")
button_active_impl :: proc(parent: Parent, key: Button_Key, label: string, activated: ^bool) {
	assert(activated != nil, "fit.button: nil activation destination")
	button_impl(parent, key, label, {activated = activated})
}

@(private = "package")
button_signal_impl :: proc(
	parent: Parent,
	key: Button_Key,
	label: string,
	signal: ^Signal,
) -> bool {
	assert(signal != nil, "fit.button: nil signal")
	activated := signal_take(signal)
	button_impl(parent, key, label, {activated = &signal.pending})
	return activated
}

@(private = "package")
button_string :: proc(parent: Parent, key, label: string, options: Button_Options = {}) {
	button_impl(parent, key, label, options)
}

@(private = "package")
button_u64 :: proc(parent: Parent, key: u64, label: string, options: Button_Options = {}) {
	button_impl(parent, key, label, options)
}

@(private = "package")
button_id :: proc(parent: Parent, widget: Widget_Id, label: string, options: Button_Options = {}) {
	button_impl(parent, widget, label, options)
}

@(private = "package")
button_string_action :: proc(parent: Parent, key, label: string, action: Action) {
	button_impl(parent, key, label, {action = action})
}

@(private = "package")
button_string_active :: proc(parent: Parent, key, label: string, activated: ^bool) {
	button_active_impl(parent, key, label, activated)
}

@(private = "package")
button_u64_action :: proc(parent: Parent, key: u64, label: string, action: Action) {
	button_impl(parent, key, label, {action = action})
}

@(private = "package")
button_u64_active :: proc(parent: Parent, key: u64, label: string, activated: ^bool) {
	button_active_impl(parent, key, label, activated)
}

@(private = "package")
button_id_action :: proc(parent: Parent, widget: Widget_Id, label: string, action: Action) {
	button_impl(parent, widget, label, {action = action})
}

@(private = "package")
button_id_active :: proc(parent: Parent, widget: Widget_Id, label: string, activated: ^bool) {
	button_active_impl(parent, widget, label, activated)
}

@(private = "package")
button_string_signal :: proc(parent: Parent, key, label: string, signal: ^Signal) -> bool {
	return button_signal_impl(parent, key, label, signal)
}

@(private = "package")
button_u64_signal :: proc(parent: Parent, key: u64, label: string, signal: ^Signal) -> bool {
	return button_signal_impl(parent, key, label, signal)
}

@(private = "package")
button_id_signal :: proc(
	parent: Parent,
	widget: Widget_Id,
	label: string,
	signal: ^Signal,
) -> bool {
	return button_signal_impl(parent, widget, label, signal)
}

button :: proc {
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

@(private = "package")
button_output_impl :: proc(
	parent: Parent,
	key: Button_Key,
	label: string,
	activated: ^bool,
	options: Button_Options,
) {
	assert(activated != nil, "fit.button_output: nil destination")
	assert(options.activated == nil, "fit.button_output: duplicate output")
	assert(options.action.procedure == nil, "fit.button_output: conflicting action")
	assert(options.action.tagged_procedure == nil, "fit.button_output: conflicting tagged action")
	resolved := options
	resolved.activated = activated
	button_impl(parent, key, label, resolved)
}

@(private = "package")
button_output_string :: proc(
	parent: Parent,
	key, label: string,
	activated: ^bool,
	options: Button_Options = {},
) {
	button_output_impl(parent, key, label, activated, options)
}

@(private = "package")
button_output_u64 :: proc(
	parent: Parent,
	key: u64,
	label: string,
	activated: ^bool,
	options: Button_Options = {},
) {
	button_output_impl(parent, key, label, activated, options)
}

@(private = "package")
button_output_id :: proc(
	parent: Parent,
	key: Widget_Id,
	label: string,
	activated: ^bool,
	options: Button_Options = {},
) {
	button_output_impl(parent, key, label, activated, options)
}

button_output :: proc {
	button_output_string,
	button_output_u64,
	button_output_id,
}

button_delayed :: proc {
	button_string_signal,
	button_u64_signal,
	button_id_signal,
}

custom :: proc(parent: Parent, spec: Custom_Spec, options: Custom_Options = {}) {
	assert(spec.measure != nil && spec.render != nil, "fit.custom: invalid callbacks")
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
	assert(
		builder.customs_used < i32(custom_slot_capacity(builder)),
		"fit custom add: capacity full",
	)
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
			size = spec.size,
		},
		options,
	)
	parent_clear(builder)
}

canvas :: proc(builder: ^Builder, render: Render_Proc, user_data: rawptr = nil) {
	assert(builder != nil && builder.bound, "fit.canvas: builder not bound")
	assert(render != nil, "fit.canvas: nil render callback")
	assert(builder.inner.prepared.count == 0, "fit.canvas: root already declared")
	root := column(builder)
	custom(
		root,
		{measure = canvas_measure, render = render, user_data = user_data},
		{size = {width = grow(), height = grow()}},
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

measure :: proc(builder: ^Builder) -> Size {
	assert(builder != nil && builder.bound, "fit.measure: builder not bound")
	return ui.fit_measure(&builder.inner)
}

render_at :: proc(builder: ^Builder, rect: Rect) {
	assert(builder != nil && builder.bound, "fit.render_at: builder not bound")
	ui.fit_render_at(&builder.inner, rect)
}

render :: proc(builder: ^Builder) -> Rect {
	assert(builder != nil && builder.bound, "fit.render: builder not bound")
	assert(!builder.inner.prepared.rendered, "fit.render: builder already rendered")
	return ui.fit_render(&builder.inner)
}

@(private = "file")
custom_measure_bridge :: proc(
	root: ^ui.Ui,
	constraints: ui.Intrinsic_Constraints,
	userdata: rawptr,
) -> ui.Intrinsic_Size {
	assert(root != nil && userdata != nil, "fit.custom: invalid measure bridge")
	spec := cast(^Custom_Spec)userdata
	assert(spec.measure != nil, "fit.custom: nil measure callback")
	measure_user_data := spec.user_data
	if spec.measure == custom_intrinsic_measure do measure_user_data = spec
	return spec.measure(constraints, measure_user_data)
}

@(private = "file")
custom_render_bridge :: proc(root: ^ui.Ui, rect: ui.Rect_I32, userdata: rawptr) -> bool {
	assert(root != nil && userdata != nil, "fit.custom: invalid render bridge")
	spec := cast(^Custom_Spec)userdata
	assert(spec.render != nil, "fit.custom: nil render callback")
	surface := Surface {
		inner = root,
	}
	return spec.render(&surface, rect, spec.user_data)
}

@(private = "package")
builder_open :: proc(builder: ^Builder, frame: ^ui.Ui_Frame, rect: Rect) {
	assert(builder != nil && !builder.bound, "fit builder: already bound")
	assert(frame != nil && frame.open, "fit builder: frame not open")
	debug_owner_prepare(builder)
	builder.frame_ticket = ui.ui_frame_ticket(frame)
	ui.begin(&builder.root, frame, rect)
	builder.bound = true
	begin(builder)
}

@(private = "package")
builder_close :: proc(builder: ^Builder) {
	assert(builder != nil && builder.bound, "fit builder: not bound")
	assert(builder.root.open, "fit builder: root not open")
	ui.end(&builder.root)
	builder.bound = false
	builder.frame_ticket = {}
}
