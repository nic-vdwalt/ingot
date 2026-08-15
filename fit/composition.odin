package fit

import "base:runtime"
import "ingot:ui"

Row_With :: proc(
	builder: ^Builder,
	body: Build_Proc,
	userdata: rawptr = nil,
	options: Container_Options = {},
	loc: runtime.Source_Code_Location = #caller_location,
) {
	Row(builder, options)
	build_container_body(builder, body, userdata, loc)
}

Column_With :: proc(
	builder: ^Builder,
	body: Build_Proc,
	userdata: rawptr = nil,
	options: Container_Options = {},
	loc: runtime.Source_Code_Location = #caller_location,
) {
	Column(builder, options)
	build_container_body(builder, body, userdata, loc)
}

Flow_With :: proc(
	builder: ^Builder,
	body: Build_Proc,
	userdata: rawptr = nil,
	options: Flow_Options = {},
	loc: runtime.Source_Code_Location = #caller_location,
) {
	Flow(builder, options)
	build_container_body(builder, body, userdata, loc)
}

Grid_With :: proc(
	builder: ^Builder,
	options: Grid_Options,
	body: Build_Proc,
	userdata: rawptr = nil,
	loc: runtime.Source_Code_Location = #caller_location,
) {
	Grid(builder, options)
	build_container_body(builder, body, userdata, loc)
}

Attachment_With :: proc(
	builder: ^Builder,
	options: Attachment_Options,
	body: Build_Proc,
	userdata: rawptr = nil,
	loc: runtime.Source_Code_Location = #caller_location,
) {
	Attachment(builder, options)
	build_container_body(builder, body, userdata, loc)
}

Scroll_With :: proc(
	builder: ^Builder,
	state: ^Scroll_State,
	body: Build_Proc,
	userdata: rawptr = nil,
	options: Scroll_Options = {},
	loc: runtime.Source_Code_Location = #caller_location,
) {
	assert(state != nil, "Fit.Scroll_With: nil state", loc)
	Scroll(builder, state, options)
	build_container_body(builder, body, userdata, loc)
}

Card_With :: proc(
	builder: ^Builder,
	body: Build_Proc,
	userdata: rawptr = nil,
	options: Card_Options = {},
	loc: runtime.Source_Code_Location = #caller_location,
) {
	Card(builder, options)
	build_container_body(builder, body, userdata, loc)
}

Section_With :: proc(
	builder: ^Builder,
	title: string,
	body: Build_Proc,
	userdata: rawptr = nil,
	options: Section_Options = {},
	loc: runtime.Source_Code_Location = #caller_location,
) {
	Section(builder, title, options)
	build_container_body(builder, body, userdata, loc)
}

@(private = "file")
build_container_body :: proc(
	builder: ^Builder,
	body: Build_Proc,
	userdata: rawptr,
	loc: runtime.Source_Code_Location,
) {
	assert(builder != nil && builder.bound, "Fit container: builder not bound", loc)
	assert(body != nil, "Fit container: nil body", loc)
	entry_depth := builder.inner.prepared.depth
	assert(entry_depth > 0, "Fit container: container not opened", loc)
	body(builder, userdata)
	assert(builder.inner.prepared.depth == entry_depth, "Fit container: body unbalanced", loc)
	End(builder)
	assert(builder.inner.prepared.depth == entry_depth - 1, "Fit container: close failed", loc)
}

@(private = "file")
scope_string :: proc(
	builder: ^Builder,
	key: string,
	body: Build_Proc,
	userdata: rawptr = nil,
	loc: runtime.Source_Code_Location = #caller_location,
) {
	assert(builder != nil && builder.bound, "Fit.Scope: builder not bound", loc)
	assert(key != "" && body != nil, "Fit.Scope: invalid argument", loc)
	entry_depth := builder.inner.prepared.depth
	ui.scope_begin(&builder.root, key, loc)
	defer ui.scope_end(&builder.root)
	body(builder, userdata)
	assert(builder.inner.prepared.depth == entry_depth, "Fit.Scope: body unbalanced", loc)
}

@(private = "file")
scope_u64 :: proc(
	builder: ^Builder,
	key: u64,
	body: Build_Proc,
	userdata: rawptr = nil,
	loc: runtime.Source_Code_Location = #caller_location,
) {
	assert(builder != nil && builder.bound, "Fit.Scope: builder not bound", loc)
	assert(key != 0 && body != nil, "Fit.Scope: invalid argument", loc)
	entry_depth := builder.inner.prepared.depth
	ui.scope_begin(&builder.root, key, loc)
	defer ui.scope_end(&builder.root)
	body(builder, userdata)
	assert(builder.inner.prepared.depth == entry_depth, "Fit.Scope: body unbalanced", loc)
}

Scope :: proc {
	scope_string,
	scope_u64,
}

Region_With :: proc(
	surface: ^Surface,
	rect: Rect,
	body: Region_Build_Proc,
	userdata: rawptr = nil,
	options: Region_Options = {},
) -> i32 {
	assert(surface != nil && body != nil, "Fit.Region_With: invalid argument")
	region: Region
	opened := Region_Open(surface, &region, rect, options)
	entry_ids := opened.inner.ids.depth
	body(opened, userdata)
	assert(opened.inner.open, "Fit.Region_With: body closed region")
	assert(opened.inner.ids.depth == entry_ids, "Fit.Region_With: body unbalanced")
	return Region_Close(opened)
}

Layer_With :: proc(
	surface: ^Surface,
	z: Z_Order,
	body: Layer_Build_Proc,
	userdata: rawptr = nil,
	claim: Float_Rect = {},
) {
	assert(surface != nil && body != nil, "Fit.Layer_With: invalid argument")
	u := surface_ui(surface)
	z_depth := u.frame.z_count
	pane_depth := u.frame.pane_count
	Layer_Begin(surface, z, claim)
	body(surface, userdata)
	assert(u.frame.z_count == z_depth + 1, "Fit.Layer_With: layer body unbalanced")
	assert(u.frame.pane_count == pane_depth + 1, "Fit.Layer_With: pane body unbalanced")
	Layer_End(surface)
	assert(u.frame.z_count == z_depth && u.frame.pane_count == pane_depth)
}

Pane_With :: proc(
	surface: ^Surface,
	state: ^Pane_State,
	rect: Rect,
	body: Pane_Build_Proc,
	userdata: rawptr = nil,
	padding: i32 = 8,
	keyboard: bool = true,
) {
	assert(surface != nil && state != nil && body != nil, "Fit.Pane_With: invalid argument")
	content_y := Pane_Begin(surface, state, rect, padding, keyboard)
	assert(state.inner.open, "Fit.Pane_With: begin failed")
	end_y := body(surface, content_y, userdata)
	assert(state.inner.open, "Fit.Pane_With: body closed pane")
	assert(end_y >= content_y, "Fit.Pane_With: content moved backwards")
	Pane_End(surface, state, rect, end_y, padding)
	assert(!state.inner.open, "Fit.Pane_With: close failed")
}

@(private = "file")
id_string :: proc(builder: ^Builder, key: string) -> Widget_Id {
	assert(builder != nil && builder.bound, "Fit.Id: builder not bound")
	assert(key != "", "Fit.Id: empty key")
	return Widget_Id(ui.id(&builder.root, key))
}

@(private = "file")
id_u64 :: proc(builder: ^Builder, key: u64) -> Widget_Id {
	assert(builder != nil && builder.bound, "Fit.Id: builder not bound")
	assert(key != 0, "Fit.Id: zero key")
	return Widget_Id(ui.id(&builder.root, key))
}

Id :: proc {
	id_string,
	id_u64,
}
