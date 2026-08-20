package fit

import "ingot:ui"

@(private = "file")
scope_string :: proc(parent: Parent, key: string) -> Parent {
	builder := parent_validate(parent)
	assert(key != "", "Fit.Scope: empty key")
	result := parent
	result.builder = builder
	result.identity = ui.fit_identity_string(parent.identity, key)
	return result
}

@(private = "file")
scope_u64 :: proc(parent: Parent, key: u64) -> Parent {
	builder := parent_validate(parent)
	assert(key != 0, "Fit.Scope: zero key")
	result := parent
	result.builder = builder
	result.identity = ui.fit_identity_u64(parent.identity, key)
	return result
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
id_string :: proc(parent: Parent, key: string) -> Widget_Id {
	_ = parent_validate(parent)
	assert(key != "", "Fit.Id: empty key")
	return Widget_Id(ui.fit_identity_string(parent.identity, key))
}

@(private = "file")
id_u64 :: proc(parent: Parent, key: u64) -> Widget_Id {
	_ = parent_validate(parent)
	assert(key != 0, "Fit.Id: zero key")
	return Widget_Id(ui.fit_identity_u64(parent.identity, key))
}

Id :: proc {
	id_string,
	id_u64,
}
