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
