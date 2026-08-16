package procgen

import asset "../asset"
import "core:math"

// Working parts of the quadric simplifier: position grouping, quadric
// accumulation, edge extraction, collapse selection, and compaction. Split from
// `mesh_simplify.odin` so the policy (how far to simplify, when to stop) stays
// separate from the mechanism (what a collapse costs).

// Vertices split by normal or UV seam occupy the same position, so topology has
// to be resolved positionally or a seam would pin the whole surface. The table
// is open-addressed and probed in vertex order, which makes the representative
// chosen for each position deterministic.
@(private)
_simplify_groups :: proc(vertices: []asset.Vertex, table: []u32, group: []u32) -> bool {
	assert(len(group) >= len(vertices), "_simplify_groups: group storage too small")
	assert(len(table) >= len(vertices) * 2, "_simplify_groups: table too small")
	slots := _simplify_table_size(len(vertices))
	for index in 0 ..< slots do table[index] = max(u32)
	mask := u32(slots - 1)
	for index in 0 ..< len(vertices) {
		position := vertices[index].position
		bits := [3]u32 {
			transmute(u32)position[0],
			transmute(u32)position[1],
			transmute(u32)position[2],
		}
		slot := _simplify_hash(bits[0], bits[1], bits[2]) & mask
		placed := false
		for _ in 0 ..< slots {
			candidate := table[slot]
			if candidate == max(u32) {
				table[slot] = u32(index)
				group[index] = u32(index)
				placed = true
				break
			}
			if vertices[candidate].position == position {
				group[index] = candidate
				placed = true
				break
			}
			slot = (slot + 1) & mask
		}
		if !placed do return false
	}
	return true
}

// A group is immovable if any vertex sharing its position is, because collapsing
// the group would move all of them. Bit 0 records that base lock; bit 1 is the
// derived fan protection applied by `_simplify_lock_fans`.
@(private)
_simplify_group_flags :: proc(group: []u32, locked: []bool, flags: []u8) {
	assert(len(flags) <= len(group), "_simplify_group_flags: flag storage too large")
	assert(locked == nil || len(locked) >= len(flags), "_simplify_group_flags: short mask")
	for index in 0 ..< len(flags) do flags[index] = 0
	if locked == nil do return
	for index in 0 ..< len(flags) {
		if !locked[index] do continue
		flags[group[index]] |= SIMPLIFY_FLAG_LOCKED
	}
}

// Pinning a vertex is not enough on its own. A locked vertex whose entire
// incident fan contracts loses every triangle that references it and vanishes
// from the output - a crack, exactly what the lock existed to prevent. So every
// triangle touching a locked vertex is frozen whole: with all three corners
// unmovable, none of its edges is ever a collapse candidate, and the triangle
// cannot become degenerate.
//
// The protection is re-derived from the base lock every pass rather than
// accumulated, so the frozen region tracks the current geometry instead of
// growing without bound.
@(private)
_simplify_lock_fans :: proc(indices: []u32, group: []u32, flags: []u8) {
	assert(len(indices) % 3 == 0, "_simplify_lock_fans: incomplete triangle")
	assert(len(flags) <= len(group), "_simplify_lock_fans: flag storage too large")
	for triangle in 0 ..< len(indices) / 3 {
		corners := [3]u32 {
			group[indices[triangle * 3]],
			group[indices[triangle * 3 + 1]],
			group[indices[triangle * 3 + 2]],
		}
		touched := false
		for corner in corners {
			if flags[corner] & SIMPLIFY_FLAG_LOCKED != 0 do touched = true
		}
		if !touched do continue
		for corner in corners do flags[corner] |= SIMPLIFY_FLAG_PROTECTED
	}
}

// Edges are collected into an open-addressed table keyed on the ordered group
// pair, so a shared edge is counted once and an edge used by a single triangle
// is recognisable as mesh boundary.
@(private)
_simplify_edges :: proc(indices: []u32, scratch: Simplify_Scratch) -> int {
	assert(len(indices) % 3 == 0, "_simplify_edges: incomplete triangle")
	assert(len(scratch.edges) >= len(indices), "_simplify_edges: edge storage too small")
	slots := _simplify_table_size(len(indices))
	for index in 0 ..< slots do scratch.edge_table[index] = max(u32)
	mask := u32(slots - 1)
	count := 0
	for triangle in 0 ..< len(indices) / 3 {
		for corner in 0 ..< 3 {
			first := scratch.group[indices[triangle * 3 + corner]]
			second := scratch.group[indices[triangle * 3 + (corner + 1) % 3]]
			if first == second do continue
			low, high := min(first, second), max(first, second)
			slot := _simplify_hash(low, high, 0) & mask
			for _ in 0 ..< slots {
				stored := scratch.edge_table[slot]
				if stored == max(u32) {
					scratch.edge_table[slot] = u32(count)
					scratch.edges[count] = {low, high, 1, u32(triangle)}
					count += 1
					break
				}
				edge := &scratch.edges[stored]
				if edge.low == low && edge.high == high {
					edge.count += 1
					break
				}
				slot = (slot + 1) & mask
			}
		}
	}
	return count
}

@(private)
_simplify_quadrics :: proc(
	vertices: []asset.Vertex,
	indices: []u32,
	scratch: Simplify_Scratch,
	options: Simplify_Options,
	edge_count: int,
) {
	assert(len(indices) % 3 == 0, "_simplify_quadrics: incomplete triangle")
	assert(edge_count <= len(scratch.edges), "_simplify_quadrics: edge count overflow")
	for index in 0 ..< len(vertices) do scratch.quadrics[index] = {}
	for triangle in 0 ..< len(indices) / 3 {
		corners := [3]u32 {
			scratch.group[indices[triangle * 3]],
			scratch.group[indices[triangle * 3 + 1]],
			scratch.group[indices[triangle * 3 + 2]],
		}
		normal, area, ok := _simplify_plane(vertices, corners)
		if !ok do continue
		point := _simplify_point(vertices[corners[0]].position)
		offset := -(normal[0] * point[0] + normal[1] * point[1] + normal[2] * point[2])
		plane := _simplify_quadric(normal, offset, area)
		for corner in corners do _simplify_quadric_add(&scratch.quadrics[corner], plane)
	}
	_simplify_boundary(vertices, indices, scratch, options, edge_count)
}

// An open edge gets a constraint plane through the edge and perpendicular to
// its triangle. Without it the silhouette of a foliage card or a terrain chunk
// border erodes long before the interior does.
@(private)
_simplify_boundary :: proc(
	vertices: []asset.Vertex,
	indices: []u32,
	scratch: Simplify_Scratch,
	options: Simplify_Options,
	edge_count: int,
) {
	assert(edge_count >= 0, "_simplify_boundary: negative edge count")
	assert(len(indices) % 3 == 0, "_simplify_boundary: incomplete triangle")
	for index in 0 ..< edge_count {
		edge := scratch.edges[index]
		if edge.count != 1 do continue
		if options.lock_boundary {
			scratch.flags[edge.low] |= SIMPLIFY_FLAG_LOCKED
			scratch.flags[edge.high] |= SIMPLIFY_FLAG_LOCKED
			continue
		}
		corners := [3]u32 {
			scratch.group[indices[edge.triangle * 3]],
			scratch.group[indices[edge.triangle * 3 + 1]],
			scratch.group[indices[edge.triangle * 3 + 2]],
		}
		face, area, ok := _simplify_plane(vertices, corners)
		if !ok do continue
		low := _simplify_point(vertices[edge.low].position)
		high := _simplify_point(vertices[edge.high].position)
		direction := [3]f64{high[0] - low[0], high[1] - low[1], high[2] - low[2]}
		normal, normal_ok := _simplify_normalize(_simplify_cross(face, direction))
		if !normal_ok do continue
		offset := -(normal[0] * low[0] + normal[1] * low[1] + normal[2] * low[2])
		weight := area * SIMPLIFY_BOUNDARY_WEIGHT
		plane := _simplify_quadric(normal, offset, weight)
		_simplify_quadric_add(&scratch.quadrics[edge.low], plane)
		_simplify_quadric_add(&scratch.quadrics[edge.high], plane)
	}
}

// Each surviving edge yields one candidate: the cheaper of its two directions
// whose source is movable. Moving onto an existing vertex is what keeps a
// locked position bit-identical after the collapse.
@(private)
_simplify_candidates :: proc(
	vertices: []asset.Vertex,
	scratch: Simplify_Scratch,
	edge_count: int,
) -> int {
	assert(edge_count >= 0, "_simplify_candidates: negative edge count")
	assert(edge_count <= len(scratch.candidates), "_simplify_candidates: storage too small")
	count := 0
	for index in 0 ..< edge_count {
		edge := scratch.edges[index]
		if edge.low == edge.high do continue
		combined := scratch.quadrics[edge.low]
		_simplify_quadric_add(&combined, scratch.quadrics[edge.high])
		low_locked := scratch.flags[edge.low] != 0
		high_locked := scratch.flags[edge.high] != 0
		if low_locked && high_locked do continue
		low_cost := _simplify_quadric_error(
			combined,
			_simplify_point(vertices[edge.high].position),
		)
		high_cost := _simplify_quadric_error(
			combined,
			_simplify_point(vertices[edge.low].position),
		)
		source, destination, cost := edge.low, edge.high, low_cost
		if low_locked || (!high_locked && high_cost < low_cost) {
			source, destination, cost = edge.high, edge.low, high_cost
		}
		scratch.candidates[count] = {max(cost, 0), source, destination}
		count += 1
	}
	return count
}

// Both endpoints are stamped so a pass never chains collapses. Chaining would
// make the outcome depend on how far a transitive walk ran, and the next pass
// picks the follow-on collapse up anyway with fresh quadrics.
@(private)
_simplify_apply :: proc(
	scratch: Simplify_Scratch,
	candidate_count: int,
	stamp: u32,
	state: ^Simplify_State,
) -> int {
	assert(state != nil, "_simplify_apply: nil state")
	assert(candidate_count > 0, "_simplify_apply: no candidates")
	budget := max(1, int(f64(candidate_count) * SIMPLIFY_PASS_RATIO))
	applied := 0
	for index in 0 ..< candidate_count {
		if applied >= budget do break
		candidate := scratch.candidates[index]
		if state.max_error > 0 && candidate.cost > state.max_error * state.max_error do break
		if scratch.touched[candidate.source] == stamp do continue
		if scratch.touched[candidate.destination] == stamp do continue
		if scratch.collapse[candidate.source] != candidate.source do continue
		if scratch.collapse[candidate.destination] != candidate.destination do continue
		if scratch.flags[candidate.source] != 0 do continue
		scratch.collapse[candidate.source] = candidate.destination
		_simplify_quadric_add(
			&scratch.quadrics[candidate.destination],
			scratch.quadrics[candidate.source],
		)
		scratch.touched[candidate.source] = stamp
		scratch.touched[candidate.destination] = stamp
		state.error = max(state.error, candidate.cost)
		applied += 1
	}
	return applied
}

// Rewrites indices through the collapse map and drops triangles that lost an
// edge. A vertex whose group survived keeps its own attributes; one that moved
// inherits the destination group's representative.
@(private)
_simplify_rebuild :: proc(indices: []u32, scratch: Simplify_Scratch) -> int {
	assert(len(indices) % 3 == 0, "_simplify_rebuild: incomplete triangle")
	assert(len(scratch.collapse) > 0, "_simplify_rebuild: empty collapse map")
	write := 0
	for triangle in 0 ..< len(indices) / 3 {
		corners: [3]u32
		for corner in 0 ..< 3 {
			original := indices[triangle * 3 + corner]
			group := scratch.group[original]
			destination := scratch.collapse[group]
			corners[corner] = original if destination == group else destination
		}
		resolved := [3]u32 {
			scratch.group[corners[0]],
			scratch.group[corners[1]],
			scratch.group[corners[2]],
		}
		if resolved[0] == resolved[1] || resolved[1] == resolved[2] do continue
		if resolved[0] == resolved[2] do continue
		for corner in 0 ..< 3 do indices[write + corner] = corners[corner]
		write += 3
	}
	return write
}

// Final pass: drop vertices no surviving triangle references and renumber.
//
// The move must run in increasing source order. Compacting in index-buffer
// order instead would let a vertex be written into a slot whose original
// contents had not been read yet, which silently corrupts exactly the
// lowest-numbered vertices - on a grid, its entire first row.
@(private)
_simplify_compact :: proc(
	vertices: []asset.Vertex,
	indices: []u32,
	scratch: Simplify_Scratch,
) -> int {
	assert(len(indices) % 3 == 0, "_simplify_compact: incomplete triangle")
	assert(len(scratch.compact) >= len(vertices), "_simplify_compact: map too small")
	used := max(u32) - 1
	for index in 0 ..< len(vertices) do scratch.compact[index] = max(u32)
	for index in 0 ..< len(indices) do scratch.compact[indices[index]] = used
	write := 0
	for index in 0 ..< len(vertices) {
		if scratch.compact[index] != used do continue
		scratch.compact[index] = u32(write)
		vertices[write] = vertices[index]
		write += 1
	}
	for index in 0 ..< len(indices) do indices[index] = scratch.compact[indices[index]]
	return write
}

@(private)
_simplify_hash :: proc(first, second, third: u32) -> u32 {
	result := u32(2166136261)
	values := [3]u32{first, second, third}
	for value in values {
		result = (result ~ value) * 16777619
		result = result ~ (result >> 13)
	}
	return result
}

@(private)
_simplify_point :: proc(position: asset.Vec3) -> [3]f64 {
	return {f64(position[0]), f64(position[1]), f64(position[2])}
}

@(private)
_simplify_cross :: proc(first, second: [3]f64) -> [3]f64 {
	return {
		first[1] * second[2] - first[2] * second[1],
		first[2] * second[0] - first[0] * second[2],
		first[0] * second[1] - first[1] * second[0],
	}
}

@(private)
_simplify_normalize :: proc(value: [3]f64) -> ([3]f64, bool) {
	length_squared := value[0] * value[0] + value[1] * value[1] + value[2] * value[2]
	if length_squared <= SIMPLIFY_EPSILON do return {}, false
	length := math.sqrt(length_squared)
	return {value[0] / length, value[1] / length, value[2] / length}, true
}

// Returns the unit face normal and twice the triangle area, which is the
// natural quadric weight: a sliver contributes almost nothing, a large face
// dominates.
@(private)
_simplify_plane :: proc(
	vertices: []asset.Vertex,
	corners: [3]u32,
) -> (
	[3]f64,
	f64,
	bool,
) {
	assert(len(vertices) > 0, "_simplify_plane: empty vertices")
	assert(int(corners[0]) < len(vertices), "_simplify_plane: corner out of range")
	first := _simplify_point(vertices[corners[0]].position)
	second := _simplify_point(vertices[corners[1]].position)
	third := _simplify_point(vertices[corners[2]].position)
	edge_a := [3]f64{second[0] - first[0], second[1] - first[1], second[2] - first[2]}
	edge_b := [3]f64{third[0] - first[0], third[1] - first[1], third[2] - first[2]}
	crossed := _simplify_cross(edge_a, edge_b)
	normal, ok := _simplify_normalize(crossed)
	if !ok do return {}, 0, false
	area := math.sqrt(
		crossed[0] * crossed[0] + crossed[1] * crossed[1] + crossed[2] * crossed[2],
	)
	return normal, area, true
}

@(private)
_simplify_quadric :: proc(normal: [3]f64, offset, weight: f64) -> Quadric {
	a, b, c := normal[0], normal[1], normal[2]
	return Quadric {
		{
			a * a * weight,
			a * b * weight,
			a * c * weight,
			a * offset * weight,
			b * b * weight,
			b * c * weight,
			b * offset * weight,
			c * c * weight,
			c * offset * weight,
			offset * offset * weight,
		},
	}
}

@(private)
_simplify_quadric_add :: proc(target: ^Quadric, source: Quadric) {
	assert(target != nil, "_simplify_quadric_add: nil target")
	assert(len(target.m) == 10, "_simplify_quadric_add: unexpected quadric width")
	for index in 0 ..< 10 do target.m[index] += source.m[index]
}

@(private)
_simplify_quadric_error :: proc(quadric: Quadric, point: [3]f64) -> f64 {
	x, y, z := point[0], point[1], point[2]
	result := quadric.m[0] * x * x + 2 * quadric.m[1] * x * y + 2 * quadric.m[2] * x * z
	result += 2 * quadric.m[3] * x + quadric.m[4] * y * y + 2 * quadric.m[5] * y * z
	result += 2 * quadric.m[6] * y + quadric.m[7] * z * z + 2 * quadric.m[8] * z
	return result + quadric.m[9]
}

// Heapsort: in place, iterative, and O(n log n) regardless of input, so a
// pathological candidate order cannot blow the pass budget. It is parametric
// because the cluster builder needs the same guarantees for Morton keys.
@(private)
_heap_sort :: proc(items: []$T, less: proc(first, second: T) -> bool) {
	assert(less != nil, "_heap_sort: nil comparator")
	assert(len(items) >= 0, "_heap_sort: negative length")
	count := len(items)
	if count < 2 do return
	for offset := count / 2 - 1; offset >= 0; offset -= 1 do _heap_sift(items, offset, count, less)
	for end := count - 1; end > 0; end -= 1 {
		items[0], items[end] = items[end], items[0]
		_heap_sift(items, 0, end, less)
	}
}

@(private)
_heap_sift :: proc(items: []$T, start, count: int, less: proc(first, second: T) -> bool) {
	assert(start >= 0, "_heap_sift: negative start")
	assert(count <= len(items), "_heap_sift: count past storage")
	root := start
	// The heap is at most log2(count) deep, so `count` iterations is a loose
	// but certain bound on the sift.
	for _ in 0 ..< count {
		child := root * 2 + 1
		if child >= count do return
		if child + 1 < count && less(items[child], items[child + 1]) do child += 1
		if !less(items[root], items[child]) do return
		items[root], items[child] = items[child], items[root]
		root = child
	}
}

@(private)
_simplify_sort :: proc(items: []Simplify_Candidate) {
	assert(len(items) >= 0, "_simplify_sort: negative length")
	assert(len(items) <= SIMPLIFY_MAX_INDICES, "_simplify_sort: candidate overflow")
	_heap_sort(items, _simplify_less)
}

// A total order, not merely a cost comparison: ties broken by vertex index keep
// the sort's output independent of the algorithm's internal swaps.
@(private)
_simplify_less :: proc(first, second: Simplify_Candidate) -> bool {
	if first.cost != second.cost do return first.cost < second.cost
	if first.source != second.source do return first.source < second.source
	return first.destination < second.destination
}
