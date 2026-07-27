package ui

import "core:mem"

INGOT_FRAME_SCRATCH_GUARD :: #config(INGOT_FRAME_SCRATCH_GUARD, true)
Frame_Scratch :: struct {
	arena:                    mem.Dynamic_Arena,
	allocator:                mem.Allocator,
	generation:               u64,
	allocation_count:         u64,
	resize_count:             u64,
	allocation_request_bytes: u64,
	resize_request_bytes:     u64,
	initialized:              bool,
}
Frame_View :: struct($T: typeid) {
	items:      []T,
	generation: u64,
}
Frame_String :: struct {
	value:      string,
	generation: u64,
}

frame_scratch_allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	scratch := cast(^Frame_Scratch)data
	assert(scratch != nil && scratch.initialized, "frame scratch allocator is not initialized")
	if mode == .Free && old_memory != nil {
		panic("individual free of frame memory; memory is released by ui_frame_end", loc = loc)
	}
	when UI_TELEMETRY_ENABLED {
		#partial switch mode {
		case .Alloc:
			scratch.allocation_count += 1
			scratch.allocation_request_bytes += u64(size)
		case .Resize:
			scratch.resize_count += 1
			scratch.resize_request_bytes += u64(size)
		case:
		}
	}
	backing := mem.dynamic_arena_allocator(&scratch.arena)
	return backing.procedure(backing.data, mode, size, alignment, old_memory, old_size, loc)
}
frame_scratch_begin :: proc(scratch: ^Frame_Scratch) {
	assert(scratch != nil)
	previous_generation := scratch.generation
	if !scratch.initialized {mem.dynamic_arena_init(&scratch.arena); scratch.initialized = true}
	scratch.generation += 1
	when UI_TELEMETRY_ENABLED {
		scratch.allocation_count = 0
		scratch.resize_count = 0
		scratch.allocation_request_bytes = 0
		scratch.resize_request_bytes = 0
	}
	when INGOT_FRAME_SCRATCH_GUARD {scratch.allocator = {
			procedure = frame_scratch_allocator_proc,
			data      = scratch,
		}} else {scratch.allocator = mem.dynamic_arena_allocator(&scratch.arena)}
	assert(scratch.initialized)
	assert(scratch.generation > previous_generation)
	assert(scratch.generation > 0)
}
frame_scratch_end :: proc(scratch: ^Frame_Scratch) {assert(scratch != nil && scratch.initialized)
	assert(scratch.generation > 0)
	free_all(scratch.allocator)
	assert(scratch.initialized)}
frame_scratch_destroy :: proc(scratch: ^Frame_Scratch) {assert(scratch != nil)
	if scratch.initialized do mem.dynamic_arena_destroy(&scratch.arena)
	scratch^ = {}
	assert(!scratch.initialized)
	assert(scratch.generation == 0)}
ui_frame_allocator :: proc(frame: ^Ui_Frame) -> mem.Allocator {assert(frame != nil && frame.open)
	return frame.scratch.allocator}
frame_view :: proc(frame: ^Ui_Frame, items: []$T) -> Frame_View(T) {assert(
		frame != nil && frame.open,
	)
	return{items, frame.scratch.generation}}
frame_view_items :: proc(frame: ^Ui_Frame, view: Frame_View($T)) -> []T {assert(
		frame != nil && frame.open,
	)
	assert(view.generation == frame.scratch.generation, "frame view used outside its frame")
	return view.items}
frame_string :: proc(frame: ^Ui_Frame, value: string) -> Frame_String {assert(
		frame != nil && frame.open,
	)
	return{value, frame.scratch.generation}}
frame_string_value :: proc(frame: ^Ui_Frame, value: Frame_String) -> string {assert(
		frame != nil && frame.open,
	)
	assert(value.generation == frame.scratch.generation, "frame string used outside its frame")
	return value.value}
