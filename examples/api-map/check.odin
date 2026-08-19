#+build !js
package main

import "core:fmt"
import "core:os"
import fit "ingot:fit"

CHECK_WIDTHS := [?]i32{320, 760, 1180, 1920, 2560}

// Fixed metrics stand in for one scale so the sweep is deterministic; every
// field is positive and the breakpoints match the runtime logical constants.
CHECK_METRICS := Map_Metrics {
	gap        = 12,
	margin     = 36,
	header_h   = 24,
	entry_h    = 56,
	card_h     = 92,
	narrow_max = NARROW_WIDTH_MAX,
	wide_min   = WIDE_WIDTH_MIN,
}

layout_check :: proc() {
	assert(len(MAP_NODES) == NODE_COUNT)
	assert(len(MAP_EDGES) == EDGE_COUNT)
	assert(len(STAGE_LABELS) == STAGE_COUNT)
	map_check_topology()
	for width in CHECK_WIDTHS {
		height := map_content_height(width, CHECK_METRICS)
		layout := map_layout({0, 0, width, height}, CHECK_METRICS)
		map_check_layout(&layout)
		map_check_edges(&layout)
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
	map_check_tiers(layout)
}

map_check_tiers :: proc(layout: ^Map_Layout) {
	assert(layout != nil && layout.metrics.header_h > 0)
	for bounds, tier in layout.tier_bounds {
		assert(bounds.w > 0 && bounds.h > 0)
		for other_index in tier + 1 ..< TIER_COUNT {
			assert(!rects_overlap(bounds, layout.tier_bounds[other_index]))
		}
	}
	for node, index in MAP_NODES {
		rect := layout.nodes[index]
		band := layout.tier_bounds[node.tier]
		assert(rect.x >= band.x && rect.x + rect.w <= band.x + band.w)
		assert(rect.y >= band.y + layout.metrics.header_h)
		assert(rect.y + rect.h <= band.y + band.h)
	}
}

map_check_edges :: proc(layout: ^Map_Layout) {
	assert(layout != nil && layout.bounds.w > 0)
	for edge, index in MAP_EDGES {
		path := map_edge_path(layout, i32(index))
		assert(path.count >= 2 && path.count <= MAX_EDGE_POINTS)
		assert(path_length(&path) > 0)
		for point_index in 0 ..< path.count {
			assert(point_in_rect(path.points[point_index], layout.bounds))
		}
		for segment_index in 0 ..< path.count - 1 {
			start := path.points[segment_index]
			finish := path.points[segment_index + 1]
			assert(map_segment_clear(layout, start, finish, edge.from, edge.to))
		}
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
