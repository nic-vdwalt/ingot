package ui

import "core:runtime"

Widget_Id :: Focus_Id
WIDGET_ID_NONE :: Widget_Id(FOCUS_ID_NONE)
MAX_ID_DEPTH :: 16

ID_FNV_OFFSET :: u64(0xcbf29ce484222325)
ID_FNV_PRIME :: u64(0x00000100000001b3)
ID_HASH_VERSION :: u64(1)

Id_Context :: struct {
	stack:   [MAX_ID_DEPTH]Widget_Id,
	origins: [MAX_ID_DEPTH]runtime.Source_Code_Location,
	depth:   int,
}

id_hash_byte :: proc(hash: u64, value: u8) -> u64 {
	result := hash ~ u64(value)
	result *= ID_FNV_PRIME
	return result
}

id_hash_u64 :: proc(hash: u64, value: u64) -> u64 {
	result := hash
	for shift: u64 = 0; shift < 64; shift += 8 {
		result = id_hash_byte(result, u8((value >> shift) & 0xff))
	}
	return result
}

id_finish :: proc(hash: u64) -> Widget_Id {
	value := hash & u64(max(int))
	if value == 0 do value = 1
	return Widget_Id(value)
}

widget_id_u64 :: proc(value: u64) -> Widget_Id {
	assert(value != 0, "widget_id: zero is reserved")
	hash := id_hash_u64(id_hash_byte(ID_FNV_OFFSET, 1), ID_HASH_VERSION)
	return id_finish(id_hash_u64(hash, value))
}

widget_id_string :: proc(value: string) -> Widget_Id {
	assert(len(value) > 0, "widget_id: empty value")
	hash := id_hash_u64(id_hash_byte(ID_FNV_OFFSET, 2), ID_HASH_VERSION)
	for byte in transmute([]u8)value do hash = id_hash_byte(hash, byte)
	return id_finish(hash)
}

widget_id :: proc {
	widget_id_u64,
	widget_id_string,
}

id_context_reset :: proc(ids: ^Id_Context) {
	assert(ids != nil, "id_context_reset: nil context")
	ids.depth = 0
}

id_context_parent :: proc(ids: ^Id_Context) -> Widget_Id {
	assert(ids != nil, "id_context_parent: nil context")
	if ids.depth == 0 do return Widget_Id(id_finish(id_hash_u64(ID_FNV_OFFSET, ID_HASH_VERSION)))
	return ids.stack[ids.depth - 1]
}

id_context_derive_u64 :: proc(ids: ^Id_Context, value: u64) -> Widget_Id {
	assert(ids != nil && value != 0, "id_context_id: invalid value")
	hash := id_hash_byte(u64(id_context_parent(ids)), 1)
	return id_finish(id_hash_u64(hash, value))
}

id_context_derive_string :: proc(ids: ^Id_Context, value: string) -> Widget_Id {
	assert(ids != nil && len(value) > 0, "id_context_id: invalid value")
	hash := id_hash_byte(u64(id_context_parent(ids)), 2)
	for byte in transmute([]u8)value do hash = id_hash_byte(hash, byte)
	return id_finish(hash)
}

id_context_id :: proc {
	id_context_derive_u64,
	id_context_derive_string,
}

id_context_push_id :: proc(ids: ^Id_Context, id: Widget_Id, loc := #caller_location) {
	assert(ids != nil && id != WIDGET_ID_NONE, "id_context_push: invalid id")
	assert(ids.depth < MAX_ID_DEPTH, "id_context_push: maximum depth reached")
	ids.stack[ids.depth] = id
	ids.origins[ids.depth] = loc
	ids.depth += 1
}

id_context_push_u64 :: proc(ids: ^Id_Context, value: u64, loc := #caller_location) {
	id_context_push_id(ids, id_context_derive_u64(ids, value), loc)
}

id_context_push_string :: proc(ids: ^Id_Context, value: string, loc := #caller_location) {
	id_context_push_id(ids, id_context_derive_string(ids, value), loc)
}

id_context_push :: proc {
	id_context_push_id,
	id_context_push_u64,
	id_context_push_string,
}

id_context_pop :: proc(ids: ^Id_Context) {
	assert(ids != nil && ids.depth > 0, "id_context_pop: no open scope")
	ids.depth -= 1
	ids.stack[ids.depth] = WIDGET_ID_NONE
	ids.origins[ids.depth] = {}
}

id_context_open_origin :: proc(ids: ^Id_Context) -> runtime.Source_Code_Location {
	assert(ids != nil, "id_context_open_origin: nil context")
	if ids.depth == 0 do return {}
	return ids.origins[0]
}
