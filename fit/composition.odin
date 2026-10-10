package fit

import "ingot:ui"

@(private = "file")
scope_string :: proc(parent: Parent, key: string) -> Parent {
	builder := parent_validate(parent)
	assert(key != "", "fit.scope: empty key")
	result := parent
	result.builder = builder
	result.identity = ui.fit_identity_string(parent.identity, key)
	return result
}

@(private = "file")
scope_u64 :: proc(parent: Parent, key: u64) -> Parent {
	builder := parent_validate(parent)
	assert(key != 0, "fit.scope: zero key")
	result := parent
	result.builder = builder
	result.identity = ui.fit_identity_u64(parent.identity, key)
	return result
}

scope :: proc {
	scope_string,
	scope_u64,
}

region_with :: proc(
	surface: ^Surface,
	rect: Rect,
	body: Region_Build_Proc,
	user_data: rawptr = nil,
	options: Region_Options = {},
) -> i32 {
	assert(surface != nil && body != nil, "fit.region_with: invalid argument")
	region: Region
	opened := region_open(surface, &region, rect, options)
	entry_ids := opened.inner.ids.depth
	body(opened, user_data)
	assert(opened.inner.open, "fit.region_with: body closed region")
	assert(opened.inner.ids.depth == entry_ids, "fit.region_with: body unbalanced")
	return region_close(opened)
}

layer_with :: proc(
	surface: ^Surface,
	z: Z_Order,
	body: Layer_Build_Proc,
	user_data: rawptr = nil,
	claim: Float_Rect = {},
) {
	assert(surface != nil && body != nil, "fit.layer_with: invalid argument")
	u := surface_ui(surface)
	z_depth := u.frame.z_count
	pane_depth := u.frame.pane_count
	layer_begin(surface, z, claim)
	body(surface, user_data)
	assert(u.frame.z_count == z_depth + 1, "fit.layer_with: layer body unbalanced")
	assert(u.frame.pane_count == pane_depth + 1, "fit.layer_with: pane body unbalanced")
	layer_end(surface)
	assert(u.frame.z_count == z_depth && u.frame.pane_count == pane_depth)
}

layer_with_reserved_paint :: proc(
	surface: ^Surface,
	z: Z_Order,
	command_count: int,
	body: Layer_Build_Proc,
	user_data: rawptr = nil,
	claim: Float_Rect = {},
) -> bool {
	assert(surface != nil && body != nil, "fit.layer_with_reserved_paint: invalid argument")
	assert(command_count > 0 && command_count <= PAINT_COMMAND_CAP)
	u := surface_ui(surface)
	z_depth := u.frame.z_count
	pane_depth := u.frame.pane_count
	layer_begin(surface, z, claim)
	accepted := ui.paint_commands_reservation_begin(&u.frame.output.overlay, command_count)
	if accepted {
		body(surface, user_data)
		ui.paint_commands_reservation_end(&u.frame.output.overlay)
	}
	assert(u.frame.z_count == z_depth + 1 && u.frame.pane_count == pane_depth + 1)
	layer_end(surface)
	assert(u.frame.z_count == z_depth && u.frame.pane_count == pane_depth)
	return accepted
}

pane_with :: proc(
	surface: ^Surface,
	state: ^Pane_State,
	rect: Rect,
	body: Pane_Build_Proc,
	user_data: rawptr = nil,
	padding: i32 = 8,
	keyboard: bool = true,
) {
	assert(surface != nil && state != nil && body != nil, "fit.pane_with: invalid argument")
	content_y := pane_begin(surface, state, rect, padding, keyboard)
	assert(state.inner.open, "fit.pane_with: begin failed")
	end_y := body(surface, content_y, user_data)
	assert(state.inner.open, "fit.pane_with: body closed pane")
	assert(end_y >= content_y, "fit.pane_with: content moved backwards")
	pane_end(surface, state, rect, end_y, padding)
	assert(!state.inner.open, "fit.pane_with: close failed")
}

// surface_builder_with runs the declarative builder API inside an existing
// imperative Surface frame, scoped to `rect` (typically a modal panel). The
// Surface API otherwise has no way to reach the declarative row/column/grid
// builder: it can only be driven from App/Session top-level draw callbacks. The
// caller owns `builder` so its node storage persists across frames, mirroring
// how App and Session own theirs. `body` describes one frame of declarative UI
// from the builder root; this binds the builder to the surface's frame at
// `rect`, renders it there, and unbinds again.
surface_builder_with :: proc(
	surface: ^Surface,
	builder: ^Builder,
	rect: Rect,
	body: Draw_Proc,
	user_data: rawptr = nil,
) {
	assert(surface != nil, "fit.surface_builder_with: nil surface")
	assert(builder != nil && !builder.bound, "fit.surface_builder_with: builder already bound")
	assert(body != nil, "fit.surface_builder_with: nil body")
	frame := surface_ui(surface).frame
	assert(frame != nil && frame.open, "fit.surface_builder_with: frame not open")
	builder_open(builder, frame, rect)
	body(builder, user_data)
	assert(builder.inner.prepared.depth == 0, "fit.surface_builder_with: unbalanced builder")
	if !builder.inner.prepared.rendered do _ = render(builder)
	builder_close(builder)
}

@(private = "file")
id_string :: proc(parent: Parent, key: string) -> Widget_Id {
	_ = parent_validate(parent)
	assert(key != "", "fit.id: empty key")
	return Widget_Id(ui.fit_identity_string(parent.identity, key))
}

@(private = "file")
id_u64 :: proc(parent: Parent, key: u64) -> Widget_Id {
	_ = parent_validate(parent)
	assert(key != 0, "fit.id: zero key")
	return Widget_Id(ui.fit_identity_u64(parent.identity, key))
}

id :: proc {
	id_string,
	id_u64,
}
