package fit

import "ingot:ui"

Focus_Id :: ui.Focus_Id
FOCUS_ID_NONE :: Focus_Id(0)

Focus_State :: ui.Focus_State

Focus_Link :: struct {
	inner: ui.Focus_Opt,
}

Focus_Scope_Id :: ui.Focus_Scope_Id

Semantic_Role :: enum u8 {
	None,
	Button,
	Checkbox,
	Radio,
	Slider,
	Text_Input,
	Dropdown,
	Menu_Item,
	Label,
	Pane,
	Modal,
	Tab,
	Tab_Panel,
	List,
	List_Item,
	Option,
	Status,
	Progress,
	List_Box,
}
// Why assert: to_semantic_role transmutes this enum into ui.Sem_Role, so the
// backing type must agree and fit may only omit trailing members (.Link).
#assert(size_of(Semantic_Role) == size_of(ui.Sem_Role))
#assert(len(Semantic_Role) <= len(ui.Sem_Role))
#assert(u8(Semantic_Role.List_Box) == u8(ui.Sem_Role.List_Box))

Semantic_Flag :: ui.Sem_Flag
Semantic_State :: ui.Sem_State

focus_id_u64 :: proc(value: u64) -> Focus_Id {
	return Focus_Id(ui.focus_id(value))
}

focus_id_string :: proc(value: string) -> Focus_Id {
	return Focus_Id(ui.focus_id_string(value))
}

focus_clear :: proc(state: ^Focus_State) {
	assert(state != nil, "fit.focus_clear: nil state")
	state.active = FOCUS_ID_NONE
}

focus_focused :: proc(state: ^Focus_State, id: Focus_Id) -> bool {
	assert(state != nil, "fit.focus_focused: nil state")
	return state.active == id
}

focus_link_to :: proc(state: ^Focus_State, id: Focus_Id) -> Focus_Link {
	assert(state != nil, "fit.focus_link_to: nil state")
	return {inner = ui.focus_link(state, id)}
}

surface_focus_scope_begin :: proc(surface: ^Surface, id: Focus_Scope_Id, priority: i32) {
	u := surface_ui(surface)
	ui.focus_scope_begin(u.frame, ui.Focus_Scope_Id(id), priority)
}

surface_focus_scope_end :: proc(surface: ^Surface, id: Focus_Scope_Id) {
	u := surface_ui(surface)
	ui.focus_scope_end(u.frame, ui.Focus_Scope_Id(id))
}

surface_focus_cycle :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.focus_scope_cycle(u.frame)
}

surface_semantic :: proc(
	surface: ^Surface,
	role: Semantic_Role,
	rect: Rect,
	label: string,
	state: Semantic_State = {},
	focus: Focus_Link = {},
	field_id: string = "",
	description: string = "",
	position_in_set: int = 0,
	size_of_set: int = 0,
) {
	u := surface_ui(surface)
	_ = ui.semantic_push(
		u.frame,
		to_semantic_role(role),
		rect,
		label,
		state,
		focus.inner,
		field_id,
		description = description,
		position_in_set = position_in_set,
		size_of_set = size_of_set,
	)
}

surface_route_claim :: proc(surface: ^Surface, rect: Float_Rect, z: Z_Order = Z_PANEL) {
	u := surface_ui(surface)
	ui.route_claim(u.frame, rect, ui.Z_Order(z))
}

surface_route_occluded :: proc(surface: ^Surface, point: Point) -> bool {
	u := surface_ui(surface)
	return ui.route_occluded(u.frame, ui.Vector2{point.x, point.y})
}

surface_forget_interactions :: proc(surface: ^Surface, base: rawptr, size: int) {
	u := surface_ui(surface)
	ui.interact_forget_block(u.frame, base, size)
}
