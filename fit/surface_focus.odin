package fit

import "ingot:ui"

Focus_Id :: ui.Focus_Id
FOCUS_ID_NONE :: Focus_Id(0)

Focus_State :: ui.Focus_State

Focus_Link :: struct {
	inner: ui.Focus_Opt,
}

Focus_Scope_Id :: distinct u64

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

Semantic_Flag :: enum u8 {
	Checked,
	Disabled,
	Focused,
	Expanded,
	Selected,
	Read_Only,
	Password,
	Multiline,
}

Semantic_State :: distinct bit_set[Semantic_Flag;u8]

Focus_Id_U64 :: proc(value: u64) -> Focus_Id {
	return Focus_Id(ui.focus_id(value))
}

Focus_Id_String :: proc(value: string) -> Focus_Id {
	return Focus_Id(ui.focus_id_string(value))
}

Focus_Clear :: proc(state: ^Focus_State) {
	assert(state != nil, "Fit.Focus_Clear: nil state")
	state.active = FOCUS_ID_NONE
}

Focus_Focused :: proc(state: ^Focus_State, id: Focus_Id) -> bool {
	assert(state != nil, "Fit.Focus_Focused: nil state")
	return state.active == id
}

Focus_Link_To :: proc(state: ^Focus_State, id: Focus_Id) -> Focus_Link {
	assert(state != nil, "Fit.Focus_Link_To: nil state")
	return {inner = ui.focus_link(state, id)}
}

Surface_Focus_Scope_Begin :: proc(surface: ^Surface, id: Focus_Scope_Id, priority: i32) {
	u := surface_ui(surface)
	ui.focus_scope_begin(u.frame, ui.Focus_Scope_Id(id), priority)
}

Surface_Focus_Scope_End :: proc(surface: ^Surface, id: Focus_Scope_Id) {
	u := surface_ui(surface)
	ui.focus_scope_end(u.frame, ui.Focus_Scope_Id(id))
}

Surface_Focus_Cycle :: proc(surface: ^Surface) {
	u := surface_ui(surface)
	ui.focus_scope_cycle(u.frame)
}

Surface_Semantic :: proc(
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
		to_rect(rect),
		label,
		to_semantic_state(state),
		focus.inner,
		field_id,
		description = description,
		position_in_set = position_in_set,
		size_of_set = size_of_set,
	)
}

Surface_Route_Claim :: proc(surface: ^Surface, rect: Float_Rect, z: Z_Order = Z_PANEL) {
	u := surface_ui(surface)
	ui.route_claim(u.frame, to_float_rect(rect), ui.Z_Order(z))
}

Surface_Route_Occluded :: proc(surface: ^Surface, point: Point) -> bool {
	u := surface_ui(surface)
	return ui.route_occluded(u.frame, ui.Vector2{point.x, point.y})
}

Surface_Forget_Interactions :: proc(surface: ^Surface, base: rawptr, size: int) {
	u := surface_ui(surface)
	ui.interact_forget_block(u.frame, base, size)
}
