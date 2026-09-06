#+build !js
package ui

import "core:mem"
import "core:testing"

Variable_List_Test_Allocator :: struct {
	backing:   mem.Allocator,
	remaining: int,
}

variable_list_test_allocator_proc :: proc(
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
	state := cast(^Variable_List_Test_Allocator)data
	assert(state != nil)
	assert(state.backing.procedure != nil)
	if (mode == .Alloc || mode == .Resize) && size > 0 {
		if state.remaining == 0 do return nil, .Out_Of_Memory
		if state.remaining > 0 do state.remaining -= 1
	}
	return state.backing.procedure(
		state.backing.data,
		mode,
		size,
		alignment,
		old_memory,
		old_size,
		loc,
	)
}

@(test)
variable_list_allocation_failure_preserves_snapshot :: proc(t: ^testing.T) {
	for budget in 0 ..< 3 {
		allocator := Variable_List_Test_Allocator{context.allocator, -1}
		index: Variable_List_Index
		variable_list_init(&index, {variable_list_test_allocator_proc, &allocator})
		defer variable_list_destroy(&index)
		testing.expect(t, variable_list_reset(&index, []i64{7, 11}))
		previous := raw_data(index.heights)
		allocator.remaining = budget
		ok := variable_list_reset(&index, []i64{2, 3, 5})
		testing.expect_value(t, ok, budget == 2)
		if !ok {
			testing.expect_value(t, raw_data(index.heights), previous)
			testing.expect_value(t, index.total, i64(18))
			testing.expect_value(t, variable_list_prefix(&index, 1), i64(7))
		}
		allocator.remaining = -1
		testing.expect(t, variable_list_reset(&index, index.heights[1:]))
		testing.expect_value(t, index.heights[0], i64(3 if ok else 11))
	}
	for budget in 0 ..< 3 {
		allocator := Variable_List_Test_Allocator{context.allocator, budget}
		index: Variable_List_Index
		variable_list_init(&index, {variable_list_test_allocator_proc, &allocator})
		defer variable_list_destroy(&index)
		ok := variable_list_append(&index, 9)
		testing.expect_value(t, ok, budget == 2)
		testing.expect_value(t, index.total, i64(9 if ok else 0))
		testing.expect_value(t, len(index.heights), 1 if ok else 0)
		allocator.remaining = -1
		testing.expect(t, variable_list_append(&index, 4))
		testing.expect_value(t, variable_list_prefix(&index, len(index.heights)), index.total)
	}
}

@(test)
variable_list_incremental_build_matches_reset :: proc(t: ^testing.T) {
	index, oracle: Variable_List_Index
	variable_list_init(&index)
	variable_list_init(&oracle)
	defer variable_list_destroy(&index)
	defer variable_list_destroy(&oracle)
	heights: [1000]i64
	for &height, offset in heights {
		height = i64(offset % 71)
		testing.expect(t, variable_list_append(&index, height))
		testing.expect(t, variable_list_reset(&oracle, heights[:offset + 1]))
		testing.expect_value(t, index.total, oracle.total)
		for position in 0 ..= offset + 1 {
			testing.expect_value(
				t,
				variable_list_prefix(&index, position),
				variable_list_prefix(&oracle, position),
			)
		}
	}
	total := index.total
	testing.expect(t, !variable_list_append(&index, -1))
	testing.expect(t, !variable_list_append(&index, max(i64)))
	testing.expect_value(t, index.total, total)
	testing.expect_value(t, len(index.heights), len(heights))
}

@(test)
variable_list_append_after_reset_and_update :: proc(t: ^testing.T) {
	index: Variable_List_Index
	variable_list_init(&index)
	defer variable_list_destroy(&index)
	for iteration in 0 ..< 4 {
		testing.expect(t, variable_list_reset(&index, nil))
		testing.expect(t, variable_list_append(&index, 7))
		testing.expect_value(t, len(index.tree), 2)
		testing.expect_value(t, variable_list_prefix(&index, 1), i64(7))
		testing.expect(t, variable_list_update(&index, 0, 11))
		testing.expect(t, variable_list_append(&index, 5))
		testing.expect_value(t, variable_list_prefix(&index, 2), i64(16))
		testing.expect(t, variable_list_reset(&index, []i64{2, 3, 4}))
		testing.expect(t, variable_list_update(&index, 1, 8))
		testing.expect(t, variable_list_append(&index, 6))
		testing.expect_value(t, len(index.tree), 5)
		testing.expect_value(t, variable_list_prefix(&index, 4), i64(20))
		testing.expect_value(
			t,
			variable_list_window(&index, 10, 5),
			Variable_List_Window{2, 4, 10},
		)
	}
}

@(test)
variable_list_matches_naive_prefix_and_window :: proc(t: ^testing.T) {
	index: Variable_List_Index
	variable_list_init(&index)
	defer variable_list_destroy(&index)
	heights: [257]i64
	for &height, offset in heights do height = i64((offset * 17) % 43)
	testing.expect(t, variable_list_reset(&index, heights[:]))
	for iteration in 0 ..< 500 {
		offset := (iteration * 31) % len(heights)
		heights[offset] = i64((iteration * 13) % 71)
		testing.expect(t, variable_list_update(&index, offset, heights[offset]))
		total: i64
		for height, position in heights {
			testing.expect_value(t, variable_list_prefix(&index, position), total)
			total += height
		}
		testing.expect_value(t, index.total, total)
		scroll := i64((iteration * 127) % int(total + 200))
		first, end := 0, 0
		top: i64
		for first < len(heights) && top + heights[first] <= scroll {
			top += heights[first]
			first += 1
		}
		end = first
		bottom := top
		for end < len(heights) && bottom < scroll + 120 {
			bottom += heights[end]
			end += 1
		}
		window := variable_list_window(&index, f64(scroll), 120)
		testing.expect_value(t, window, Variable_List_Window{first, end, top})
	}
}

@(test)
variable_list_rejects_overflow_and_preserves_index :: proc(t: ^testing.T) {
	index: Variable_List_Index
	variable_list_init(&index)
	defer variable_list_destroy(&index)
	heights := [?]i64{0, i64(max(i32)) + 10, 20}
	testing.expect(t, variable_list_reset(&index, heights[:]))
	testing.expect_value(t, variable_list_window(&index, f64(heights[1]), 10).first, 2)
	testing.expect(t, !variable_list_update(&index, 2, max(i64)))
	testing.expect(t, !variable_list_reset(&index, []i64{max(i64), 1}))
	testing.expect(t, !variable_list_update(&index, 0, -1))
	testing.expect_value(t, index.total, heights[1] + 20)
	testing.expect(t, variable_list_reset(&index, nil))
	testing.expect_value(t, variable_list_window(&index, 0, 100), Variable_List_Window{})
}

@(test)
virtual_list_window_geometry_is_bounded :: proc(t: ^testing.T) {
	state := Virtual_List_State {
		open    = true,
		region  = {10, 20, 200, 120},
		count   = 100,
		visible = 6,
	}
	window := Virtual_List_Window {
		first        = 40,
		visible_rows = 6,
		row_height   = 20,
		row_width    = 200,
	}
	first := virtual_list_row(window, &state, 40)
	last := virtual_list_row(window, &state, 45)
	testing.expect_value(t, first, Rect_I32{10, 20, 200, 20})
	testing.expect_value(t, last, Rect_I32{10, 120, 200, 20})
}

@(test)
virtual_list_count_bound_is_named :: proc(t: ^testing.T) {
	testing.expect(t, VIRTUAL_LIST_ITEM_COUNT_MAX >= 100_000)
	testing.expect(t, VIRTUAL_LIST_ITEM_COUNT_MAX < max(int))
}
