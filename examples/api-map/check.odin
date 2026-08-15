#+build !js
package main

import "core:fmt"
import "core:os"
import fit "ingot:fit"

CHECK_WIDTHS := [?]i32{320, 760, 1180, 1920, 2560}

layout_check :: proc() {
	assert(len(MAP_NODES) == NODE_COUNT)
	assert(len(MAP_EDGES) == EDGE_COUNT)
	assert(len(STAGE_LABELS) == STAGE_COUNT)
	map_check_topology()
	for width in CHECK_WIDTHS {
		height := map_content_height(width)
		layout := map_layout({0, 0, width, height}, 12, 62, 88)
		map_check_layout(&layout)
		fmt.printfln("layout-check: width %d ok", width)
	}
	map_check_animation()
	fmt.println("layout-check: ok")
	os.exit(0)
}

map_check_topology :: proc() {
	seen := [STAGE_COUNT]bool{}
	for edge in MAP_EDGES {
		assert(edge.from >= 0 && edge.from < NODE_COUNT)
		assert(edge.to >= 0 && edge.to < NODE_COUNT)
		assert(edge.stage >= 1 && edge.stage <= STAGE_COUNT)
	}
	for node in MAP_NODES {
		assert(node.title != "" && node.contract != "")
		if node.stage > 0 do seen[node.stage - 1] = true
	}
	for value in seen do assert(value)
}

map_check_layout :: proc(layout: ^Map_Layout) {
	assert(layout != nil && layout.bounds.w > 0 && layout.bounds.h > 0)
	for rect, index in layout.nodes {
		assert(rect.w > 0 && rect.h > 0)
		assert(rect.x >= layout.bounds.x && rect.y >= layout.bounds.y)
		assert(rect.x + rect.w <= layout.bounds.x + layout.bounds.w)
		assert(rect.y + rect.h <= layout.bounds.y + layout.bounds.h)
		for other_index in index + 1 ..< NODE_COUNT {
			assert(!rects_overlap(rect, layout.nodes[other_index]))
		}
	}
	for edge in MAP_EDGES {
		from := rect_center(layout.nodes[edge.from])
		to := rect_center(layout.nodes[edge.to])
		assert(point_in_rect(from, layout.bounds))
		assert(point_in_rect(to, layout.bounds))
	}
}

rects_overlap :: proc(a, b: fit.Rect) -> bool {
	assert(a.w > 0 && a.h > 0 && b.w > 0 && b.h > 0)
	return a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y
}

point_in_rect :: proc(point: fit.Point, rect: fit.Rect) -> bool {
	assert(rect.w > 0 && rect.h > 0)
	return(
		point.x >= f32(rect.x) &&
		point.x <= f32(rect.x + rect.w) &&
		point.y >= f32(rect.y) &&
		point.y <= f32(rect.y + rect.h) \
	)
}

map_check_animation :: proc() {
	assert(map_ease(0) == 0)
	assert(map_ease(1) == 1)
	assert(map_ease(0.5) > 0 && map_ease(0.5) < 1)
	assert(map_advance_progress(0, 0) == 0)
	assert(map_advance_progress(0, 10) == 1)
	assert(map_advance_progress(0.75, -1) == 0.75)
}
