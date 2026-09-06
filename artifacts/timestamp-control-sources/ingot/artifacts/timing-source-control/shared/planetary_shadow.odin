package shared

import "base:runtime"
import "core:mem"

// A planetary shadow is a second Planetary_State whose slices have their own
// backing but whose grid (immutable topology) and worker team are shared
// with the live state. The client prepares the next tick's planetary step
// on the shadow from a worker thread while the render thread keeps reading
// the live state, then swaps the two structs at the tick boundary.
//
// The slice discovery is type-driven (base:runtime type info) rather than a
// hand-written field list, so a state array added to any planetary
// subsystem is copied automatically; the round-trip is pinned by tests that
// compare a shadow-prepared world with a synchronously ticked one byte for
// byte.

// Fields of Planetary_State that are shared, not copied.
@(private = "file")
PLANETARY_SHADOW_SHARED_FIELDS :: [?]string{"grid", "workers", "workers_owned"}

@(private = "file")
Planetary_Slice_Visitor :: #type proc(
	slice: ^runtime.Raw_Slice,
	elem_size, elem_align: int,
	data: rawptr,
)

@(private = "file")
_planetary_walk_slices :: proc(
	base: rawptr,
	info: ^runtime.Type_Info,
	visit: Planetary_Slice_Visitor,
	data: rawptr,
) {
	#partial switch variant in info.variant {
	case runtime.Type_Info_Named:
		_planetary_walk_slices(base, variant.base, visit, data)
	case runtime.Type_Info_Struct:
		for field in 0 ..< int(variant.field_count) {
			_planetary_walk_slices(
				rawptr(uintptr(base) + variant.offsets[field]),
				variant.types[field],
				visit,
				data,
			)
		}
	case runtime.Type_Info_Array:
		for element in 0 ..< variant.count {
			_planetary_walk_slices(
				rawptr(uintptr(base) + uintptr(element * variant.elem_size)),
				variant.elem,
				visit,
				data,
			)
		}
	case runtime.Type_Info_Enumerated_Array:
		for element in 0 ..< variant.count {
			_planetary_walk_slices(
				rawptr(uintptr(base) + uintptr(element * variant.elem_size)),
				variant.elem,
				visit,
				data,
			)
		}
	case runtime.Type_Info_Slice:
		visit((^runtime.Raw_Slice)(base), variant.elem_size, variant.elem.align, data)
	case runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Map:
		panic("planetary shadow: dynamic containers are not supported in Planetary_State")
	}
}

// planetary_shadow_walk visits every slice header inside the simulated
// (non-shared) fields of a Planetary_State.
planetary_shadow_walk :: proc(state: ^Planetary_State, visit: Planetary_Slice_Visitor, data: rawptr) {
	assert(state != nil && visit != nil, "planetary_shadow_walk: nil argument")
	info := runtime.type_info_base(type_info_of(Planetary_State))
	fields := info.variant.(runtime.Type_Info_Struct)
	field_loop: for field in 0 ..< int(fields.field_count) {
		for shared_name in PLANETARY_SHADOW_SHARED_FIELDS {
			if fields.names[field] == shared_name do continue field_loop
		}
		_planetary_walk_slices(
			rawptr(uintptr(state) + fields.offsets[field]),
			fields.types[field],
			visit,
			data,
		)
	}
}

@(private = "file")
_shadow_alloc_visit :: proc(slice: ^runtime.Raw_Slice, elem_size, elem_align: int, data: rawptr) {
	allocator := (^mem.Allocator)(data)^
	if slice.len == 0 {
		slice.data = nil
		return
	}
	backing, error := mem.alloc_bytes(slice.len * elem_size, elem_align, allocator)
	assert(error == nil && len(backing) == slice.len * elem_size, "planetary shadow: allocation failed")
	// The header still aliases the live backing: copy it before re-pointing.
	mem.copy_non_overlapping(raw_data(backing), slice.data, slice.len * elem_size)
	slice.data = raw_data(backing)
}

@(private = "file")
_shadow_free_visit :: proc(slice: ^runtime.Raw_Slice, elem_size, elem_align: int, data: rawptr) {
	allocator := (^mem.Allocator)(data)^
	if slice.data != nil do mem.free_bytes(mem.byte_slice(slice.data, slice.len * elem_size), allocator)
	slice.data = nil
	slice.len = 0
}

// planetary_shadow_init makes `shadow` a full copy of `live` with its own
// slice backing and the live grid and worker team shared by pointer.
planetary_shadow_init :: proc(shadow, live: ^Planetary_State, allocator := context.allocator) {
	assert(shadow != nil && live != nil && shadow != live, "planetary_shadow_init: bad states")
	shadow^ = live^
	shadow.workers_owned = false
	allocator := allocator
	planetary_shadow_walk(shadow, _shadow_alloc_visit, &allocator)
}

planetary_shadow_deinit :: proc(shadow: ^Planetary_State, allocator := context.allocator) {
	assert(shadow != nil, "planetary_shadow_deinit: nil shadow")
	assert(!shadow.workers_owned, "planetary_shadow_deinit: not a shadow")
	allocator := allocator
	planetary_shadow_walk(shadow, _shadow_free_visit, &allocator)
	shadow^ = {}
}

@(private = "file")
Shadow_Copy_Cursor :: struct {
	headers: [dynamic]runtime.Raw_Slice,
	next:    int,
}

@(private = "file")
_shadow_record_visit :: proc(slice: ^runtime.Raw_Slice, elem_size, elem_align: int, data: rawptr) {
	cursor := (^Shadow_Copy_Cursor)(data)
	append(&cursor.headers, slice^)
}

@(private = "file")
_shadow_restore_visit :: proc(slice: ^runtime.Raw_Slice, elem_size, elem_align: int, data: rawptr) {
	cursor := (^Shadow_Copy_Cursor)(data)
	own := cursor.headers[cursor.next]
	cursor.next += 1
	// `slice` currently holds the source header (from the struct assignment).
	assert(own.len == slice.len, "planetary_shadow_copy: slice length drift")
	if slice.len > 0 do mem.copy_non_overlapping(own.data, slice.data, slice.len * elem_size)
	slice^ = own
}

// planetary_shadow_copy makes `shadow` equal to `source` in every simulated
// field: scalars and fixed arrays by struct assignment, slices by content
// into the shadow's own backing. Both must have been created from the same
// live world (identical slice lengths, shared grid and team).
planetary_shadow_copy :: proc(shadow, source: ^Planetary_State) {
	assert(shadow != nil && source != nil && shadow != source, "planetary_shadow_copy: bad states")
	assert(shadow.grid.neighbours != nil && raw_data(shadow.grid.neighbours) == raw_data(source.grid.neighbours), "planetary_shadow_copy: grids differ")
	cursor: Shadow_Copy_Cursor
	cursor.headers = make([dynamic]runtime.Raw_Slice, 0, 256, context.temp_allocator)
	planetary_shadow_walk(shadow, _shadow_record_visit, &cursor)
	owned := shadow.workers_owned
	shadow^ = source^
	shadow.workers_owned = owned
	planetary_shadow_walk(shadow, _shadow_restore_visit, &cursor)
	assert(cursor.next == len(cursor.headers), "planetary_shadow_copy: walk drift")
}

// planetary_shadow_swap exchanges the simulated contents of two states
// created from the same live world. Slice headers travel with their
// backing, the shared grid and team are identical on both sides, and the
// ownership flag stays with the struct that created the team.
planetary_shadow_swap :: proc(first, second: ^Planetary_State, scratch: ^Planetary_State) {
	assert(first != nil && second != nil && scratch != nil, "planetary_shadow_swap: nil state")
	assert(first != second && scratch != first && scratch != second, "planetary_shadow_swap: aliasing")
	assert(first.workers == second.workers, "planetary_shadow_swap: different teams")
	first_owned, second_owned := first.workers_owned, second.workers_owned
	scratch^ = first^
	first^ = second^
	second^ = scratch^
	first.workers_owned = first_owned
	second.workers_owned = second_owned
}
