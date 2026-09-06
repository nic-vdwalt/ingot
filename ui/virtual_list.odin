package ui

import "core:math"
import "core:mem"

VIRTUAL_LIST_ITEM_COUNT_MAX :: 1_000_000

Variable_List_Index :: struct {
	heights:   [dynamic]i64,
	tree:      [dynamic]i64,
	total:     i64,
	allocator: mem.Allocator,
}

Variable_List_Window :: struct {
	first, end: int,
	top:        i64,
}

variable_list_init :: proc(index: ^Variable_List_Index, allocator := context.allocator) {
	assert(index != nil)
	assert(index.allocator.procedure == nil)
	index.allocator = allocator
	index.heights = make([dynamic]i64, allocator)
	index.tree = make([dynamic]i64, allocator)
}

variable_list_destroy :: proc(index: ^Variable_List_Index) {
	assert(index != nil)
	assert(len(index.heights) <= VIRTUAL_LIST_ITEM_COUNT_MAX)
	delete(index.heights)
	delete(index.tree)
	index^ = {}
}

variable_list_reset :: proc(index: ^Variable_List_Index, heights: []i64) -> bool {
	assert(index != nil && index.allocator.procedure != nil)
	assert(len(index.heights) <= VIRTUAL_LIST_ITEM_COUNT_MAX)
	if len(heights) > VIRTUAL_LIST_ITEM_COUNT_MAX do return false
	total: i64
	for height in heights {
		if height < 0 || height > max(i64) - total do return false
		total += height
	}
	resize(&index.heights, len(heights))
	resize(&index.tree, len(heights) + 1)
	copy(index.heights[:], heights)
	for &value in index.tree do value = 0
	for height, offset in heights {
		position := offset + 1
		index.tree[position] += height
		parent := position + (position & -position)
		if parent < len(index.tree) do index.tree[parent] += index.tree[position]
	}
	index.total = total
	return true
}

variable_list_update :: proc(index: ^Variable_List_Index, offset: int, height: i64) -> bool {
	assert(index != nil)
	assert(len(index.heights) <= VIRTUAL_LIST_ITEM_COUNT_MAX)
	if offset < 0 || offset >= len(index.heights) || height < 0 do return false
	remaining := index.total - index.heights[offset]
	if height > max(i64) - remaining do return false
	delta := height - index.heights[offset]
	index.heights[offset] = height
	index.total = remaining + height
	for position := offset + 1; position < len(index.tree); position += position & -position {
		index.tree[position] += delta
	}
	return true
}

variable_list_prefix :: proc(index: ^Variable_List_Index, end: int) -> i64 {
	assert(index != nil)
	assert(end >= 0 && end <= len(index.heights))
	total: i64
	for position := end; position > 0; position -= position & -position {
		total += index.tree[position]
	}
	return total
}

variable_list_lower_bound :: proc(index: ^Variable_List_Index, target: f64) -> int {
	assert(index != nil)
	assert(len(index.heights) <= VIRTUAL_LIST_ITEM_COUNT_MAX)
	position := 0
	sum: i64
	bit := 1
	for bit <= len(index.heights) / 2 do bit *= 2
	for bit > 0 {
		candidate := position + bit
		if candidate <= len(index.heights) && f64(sum + index.tree[candidate]) <= target {
			position = candidate
			sum += index.tree[candidate]
		}
		bit /= 2
	}
	return position
}

variable_list_window :: proc(
	index: ^Variable_List_Index,
	scroll: f64,
	height: i32,
) -> Variable_List_Window {
	assert(index != nil)
	assert(len(index.heights) <= VIRTUAL_LIST_ITEM_COUNT_MAX)
	if height <= 0 || len(index.heights) == 0 || math.is_nan(scroll) do return {}
	first := variable_list_lower_bound(index, max(scroll, 0))
	top := variable_list_prefix(index, first)
	end := first
	bottom := scroll + f64(height)
	current := top
	for end < len(index.heights) && f64(current) < bottom {
		current += index.heights[end]
		end += 1
	}
	return {first, end, top}
}

Virtual_List_State :: struct {
	scroll:  f32,
	wheel:   f32,
	sbar:    Scrollbar_State,
	open:    bool,
	region:  Rect_I32,
	count:   int,
	visible: int,
}

Virtual_List_Window :: struct {
	first:        int,
	visible_rows: int,
	row_height:   i32,
	row_width:    i32,
}

virtual_list_begin :: proc(
	u: ^Ui,
	key: string,
	state: ^Virtual_List_State,
	row_height: i32,
	count: int,
	visible_height: i32 = 0,
) -> Virtual_List_Window {
	assert(u != nil && u.open, "virtual_list_begin: frame not open")
	assert(key != "" && state != nil && !state.open, "virtual_list_begin: invalid state")
	assert(row_height > 0, "virtual_list_begin: non-positive row height")
	assert(
		count >= 0 && count <= VIRTUAL_LIST_ITEM_COUNT_MAX,
		"virtual_list_begin: count out of range",
	)
	region := remaining_rect(u)
	if visible_height > 0 do region.h = min(region.h, ui_frame_sc(u.frame, visible_height))
	row_height_px := ui_frame_sc(u.frame, row_height)
	visible_rows := 0
	if region.h > 0 && row_height_px > 0 do visible_rows = int(max(region.h / row_height_px, 1))
	mouse := get_mouse_position(u.frame)
	if point_in_rect_i32(mouse, region) && !route_occluded(u.frame, mouse) {
		state.scroll += f32(wheel_row_steps(u.frame, &state.wheel))
	}
	state.scroll = clamp(state.scroll, 0, f32(max(count - visible_rows, 0)))
	state.region = region
	state.count = count
	state.visible = visible_rows
	state.open = true
	semantic_push(u.frame, .List_Box, region, key, field_id = key)
	begin_scissor_mode(u.frame, region.x, region.y, max(region.w, 0), max(region.h, 0))
	return {
		first = int(state.scroll),
		visible_rows = visible_rows,
		row_height = row_height_px,
		row_width = max(region.w, 0),
	}
}

virtual_list_row :: proc(
	window: Virtual_List_Window,
	state: ^Virtual_List_State,
	index: int,
) -> Rect_I32 {
	assert(state != nil && state.open, "virtual_list_row: list not open")
	assert(index >= window.first && index < state.count, "virtual_list_row: index out of range")
	assert(index - window.first < window.visible_rows, "virtual_list_row: index outside window")
	return {
		state.region.x,
		state.region.y + i32(index - window.first) * window.row_height,
		window.row_width,
		window.row_height,
	}
}

virtual_list_end :: proc(u: ^Ui, state: ^Virtual_List_State) {
	assert(u != nil && u.open, "virtual_list_end: frame not open")
	assert(state != nil && state.open, "virtual_list_end: list not open")
	end_scissor_mode(u.frame)
	if state.count > state.visible && state.region.w > 0 && state.region.h > 0 {
		offset := scrollbar_ex(
			u.frame,
			&state.sbar,
			state.region.x + state.region.w - ui_frame_sc(u.frame, 7),
			state.region.y,
			ui_frame_sc(u.frame, 5),
			state.region.h,
			state.count,
			state.visible,
			int(state.scroll),
		)
		if state.sbar.dragging do state.scroll = f32(offset)
	} else {
		state.sbar = {}
	}
	state.open = false
}
