package procgen

import asset "../asset"
import "core:math"

// Index-order optimisation: the last thing that happens to a level's geometry
// before it is stored. Three passes in a fixed order.
//
//   * Vertex cache - reorder triangles so a GPU's post-transform cache is
//     reused. Tom Forsyth's linear-speed heuristic.
//   * Overdraw - sort runs of that order front to back, giving back a little
//     cache efficiency for a lot of early-z.
//   * Vertex fetch - renumber vertices into first-use order so the fetch walks
//     forward through memory.
//
// All three are pure permutations of the triangle set plus a renumber: the
// surface is untouched, no vertex moves, and nothing here can fail on geometry
// the simplifier accepted.
//
// This mirrors `tools/mesh_cook.py` decision for decision. The pair exists
// because the offline cook runs inside Blender's bundled interpreter and the
// runtime cook runs here, so neither can call the other;
// `docs/cooked-mesh-v2.md` is the contract they both answer to and
// `mesh_optimize_test.odin` pins a golden index order that
// `tools/test_mesh_cook.py` asserts as well. A divergence fails a test rather
// than shipping two different index orders for one asset.
//
// This is initialization or worker-residency work, the same contract the rest
// of the cooking path carries. It must not run per frame.

// Forsyth's cache model. The size is a modelled post-transform cache rather
// than any particular GPU's, which is the point: an order tuned for 32 is good
// on hardware with more and no worse on hardware with less.
OPTIMIZE_CACHE_SIZE :: 32
// The three most recent vertices score flat, so the corners of the triangle
// just emitted do not compete with each other for the front of the cache.
OPTIMIZE_CACHE_RECENT :: 3
OPTIMIZE_CACHE_RECENT_SCORE :: f64(0.75)
OPTIMIZE_VALENCE_SCALE :: f64(2)
// A run shorter than this would sort near-individual triangles and undo the
// cache pass outright. The divisor is the offline tool's and is a quality knob,
// not a correctness one.
OPTIMIZE_OVERDRAW_THRESHOLD :: f64(1.05)
OPTIMIZE_OVERDRAW_RUN_DIVISOR :: f64(8)

// A vertex enters the ring before the ring is truncated, so three corners can
// briefly push it past its modelled size.
OPTIMIZE_RING_CAPACITY :: OPTIMIZE_CACHE_SIZE + 3

OPTIMIZE_SCRATCH_ALIGNMENT :: SIMPLIFY_SCRATCH_ALIGNMENT
OPTIMIZE_SCRATCH_PADDING :: SIMPLIFY_SCRATCH_PADDING

Optimize_Result :: struct {
	vertex_count: int,
	index_count:  int,
	// True when the cache walk could not consume every triangle and the input
	// order was passed through instead. Unreachable for a mesh that validates -
	// a live triangle always has three vertices with work left, so it always
	// outscores the rejection floor - but passing the input order through is
	// always correct where emitting a short index buffer never is.
	fallback:     bool,
}

Optimize_Scratch :: struct {
	// Triangle adjacency in compressed-row form. A vertex of unbounded valence
	// is normal in cooked geometry, so a per-vertex list would be a per-vertex
	// allocation; the offsets plus one flat array are the same information
	// with a bound that is a pure function of the index count.
	adjacency_offset: []u32,
	adjacency_cursor: []u32,
	adjacency:        []u32,
	remaining:        []u32,
	cache_position:   []i32,
	vertex_scores:    []f64,
	vertex_mark:      []u32,
	remap:            []u32,
	triangle_scores:  []f64,
	heap_items:       []u32,
	heap_slots:       []i32,
	touched:          []u32,
	touched_mark:     []u32,
	runs:             []Optimize_Run,
	order:            []u32,
}

@(private)
Optimize_Run :: struct {
	key:   f64,
	start: u32,
	count: u32,
}

// optimize_mesh reorders `input` into caller storage. Every pass is a
// permutation, so `out_vertices` and `out_indices` sized for the input are
// always sufficient; the vertex count can only shrink, and only by dropping
// vertices no triangle referenced.
optimize_mesh :: proc(
	input: asset.Mesh_View,
	out_vertices: []asset.Vertex,
	out_indices: []u32,
	scratch: Optimize_Scratch,
) -> (
	Optimize_Result,
	bool,
) {
	if !_optimize_inputs_ok(input, out_vertices, out_indices, scratch) do return {}, false
	vertex_count := len(input.vertices)
	index_count := len(input.indices)
	result := Optimize_Result {
		index_count = index_count,
		fallback    = _optimize_cache(input.indices, vertex_count, scratch),
	}
	// Overdraw reads the cache order and the original vertices, so it cannot
	// run in place; fetch only renumbers, so it can. That is why the cache pass
	// lands in scratch and the other two land in the caller's buffer.
	_optimize_overdraw(input.vertices, scratch.order[:index_count], out_indices, scratch)
	result.vertex_count = _optimize_fetch(
		input.vertices,
		out_indices[:index_count],
		out_vertices,
		scratch.remap[:vertex_count],
	)
	return result, result.vertex_count > 0
}

// optimize_scratch_size reports the bytes a caller must reserve, following the
// same rule as `simplify_scratch_size` so a cook step has one number per pass
// to allocate rather than a table of array lengths.
optimize_scratch_size :: proc(vertex_count, index_count: int) -> int {
	assert(vertex_count > 0, "optimize_scratch_size: empty vertices")
	assert(index_count >= 3, "optimize_scratch_size: empty indices")
	assert(index_count % 3 == 0, "optimize_scratch_size: incomplete triangle")
	triangle_count := index_count / 3
	total := _simplify_align((vertex_count + 1) * size_of(u32))
	total += _simplify_align(vertex_count * size_of(u32)) * 4
	total += _simplify_align(vertex_count * size_of(i32))
	total += _simplify_align(vertex_count * size_of(f64))
	total += _simplify_align(index_count * size_of(u32)) * 2
	total += _simplify_align(triangle_count * size_of(u32)) * 3
	total += _simplify_align(triangle_count * size_of(i32))
	total += _simplify_align(triangle_count * size_of(f64))
	total += _simplify_align(triangle_count * size_of(Optimize_Run))
	return total
}

// optimize_scratch_make carves a caller-owned byte block into the typed scratch
// `optimize_mesh` expects. The block may start unaligned, which is why it must
// be `OPTIMIZE_SCRATCH_PADDING` bytes larger than `optimize_scratch_size`
// reports - a caller handing in a static array should not have to reason about
// where the linker put it.
optimize_scratch_make :: proc(
	block: []u8,
	vertex_count, index_count: int,
) -> (
	Optimize_Scratch,
	bool,
) {
	assert(vertex_count > 0, "optimize_scratch_make: empty vertices")
	assert(index_count >= 3, "optimize_scratch_make: empty indices")
	required := optimize_scratch_size(vertex_count, index_count) + OPTIMIZE_SCRATCH_PADDING
	if len(block) < required do return {}, false
	triangles := index_count / 3
	address := uintptr(raw_data(block))
	carve := Simplify_Carve {
		block  = block,
		offset = int(
			(OPTIMIZE_SCRATCH_ALIGNMENT - (address & OPTIMIZE_SCRATCH_PADDING)) &
			OPTIMIZE_SCRATCH_PADDING,
		),
	}
	scratch := Optimize_Scratch {
		adjacency_offset = _simplify_carve(&carve, u32, vertex_count + 1),
		adjacency_cursor = _simplify_carve(&carve, u32, vertex_count),
		adjacency        = _simplify_carve(&carve, u32, index_count),
		remaining        = _simplify_carve(&carve, u32, vertex_count),
		cache_position   = _simplify_carve(&carve, i32, vertex_count),
		vertex_scores    = _simplify_carve(&carve, f64, vertex_count),
		vertex_mark      = _simplify_carve(&carve, u32, vertex_count),
		remap            = _simplify_carve(&carve, u32, vertex_count),
		triangle_scores  = _simplify_carve(&carve, f64, triangles),
		heap_items       = _simplify_carve(&carve, u32, triangles),
		heap_slots       = _simplify_carve(&carve, i32, triangles),
		touched          = _simplify_carve(&carve, u32, triangles),
		touched_mark     = _simplify_carve(&carve, u32, triangles),
		runs             = _simplify_carve(&carve, Optimize_Run, triangles),
		order            = _simplify_carve(&carve, u32, index_count),
	}
	assert(carve.offset <= len(block), "optimize_scratch_make: carve overran the block")
	return scratch, true
}

@(private)
_optimize_inputs_ok :: proc(
	input: asset.Mesh_View,
	out_vertices: []asset.Vertex,
	out_indices: []u32,
	scratch: Optimize_Scratch,
) -> bool {
	assert(len(out_vertices) >= 0, "_optimize_inputs_ok: negative vertex storage")
	assert(len(out_indices) >= 0, "_optimize_inputs_ok: negative index storage")
	if !asset.mesh_validate(input) || input.primitive != .Triangles do return false
	vertex_count := len(input.vertices)
	index_count := len(input.indices)
	if index_count < 3 || index_count % 3 != 0 do return false
	if vertex_count > SIMPLIFY_MAX_VERTICES || index_count > SIMPLIFY_MAX_INDICES do return false
	if len(out_vertices) < vertex_count || len(out_indices) < index_count do return false
	triangles := index_count / 3
	if len(scratch.adjacency_offset) < vertex_count + 1 do return false
	if len(scratch.adjacency_cursor) < vertex_count do return false
	if len(scratch.remaining) < vertex_count || len(scratch.remap) < vertex_count do return false
	if len(scratch.cache_position) < vertex_count do return false
	if len(scratch.vertex_scores) < vertex_count do return false
	if len(scratch.vertex_mark) < vertex_count do return false
	if len(scratch.adjacency) < index_count || len(scratch.order) < index_count do return false
	if len(scratch.triangle_scores) < triangles do return false
	if len(scratch.heap_items) < triangles || len(scratch.heap_slots) < triangles do return false
	if len(scratch.touched) < triangles || len(scratch.touched_mark) < triangles do return false
	if len(scratch.runs) < triangles do return false
	return true
}

// -- vertex cache -------------------------------------------------------------

// _optimize_vertex_score is Forsyth's score, spelled so another language
// reproduces it bit for bit.
//
// `sqrt` is correctly rounded per IEEE-754 where `pow` is not, and equal-valence
// vertices produce exactly tied scores often enough that a last-ulp
// disagreement between two libms would flip a tie and diverge the whole output
// order. So x^1.5 is written x*sqrt(x) and 2*n^-0.5 is written 2/sqrt(n) - the
// same values, reproducible on every platform. `tools/mesh_cook.py` spells them
// the same way, and that is the only reason the golden order is shareable.
@(private)
_optimize_vertex_score :: proc(cache_position, remaining: int) -> f64 {
	assert(cache_position >= -1, "_optimize_vertex_score: bad cache position")
	assert(cache_position < OPTIMIZE_CACHE_SIZE, "_optimize_vertex_score: position past ring")
	assert(remaining >= 0, "_optimize_vertex_score: negative valence")
	// A vertex with no triangles left is worthless, and scoring it below every
	// reachable score is what lets the walk detect a starved mesh.
	if remaining <= 0 do return -1
	score := f64(0)
	if cache_position >= 0 {
		if cache_position < OPTIMIZE_CACHE_RECENT {
			score = OPTIMIZE_CACHE_RECENT_SCORE
		} else {
			offset := f64(cache_position - OPTIMIZE_CACHE_RECENT)
			ramp := 1 - offset / f64(OPTIMIZE_CACHE_SIZE - OPTIMIZE_CACHE_RECENT)
			score = ramp * math.sqrt(ramp)
		}
	}
	return score + OPTIMIZE_VALENCE_SCALE / math.sqrt(f64(remaining))
}

@(private)
_optimize_triangle_score :: proc(
	indices: []u32,
	scratch: Optimize_Scratch,
	triangle: int,
) -> f64 {
	assert(triangle >= 0, "_optimize_triangle_score: negative triangle")
	total := f64(0)
	for corner in 0 ..< 3 do total += scratch.vertex_scores[indices[triangle * 3 + corner]]
	return total
}

@(private)
_optimize_cache :: proc(indices: []u32, vertex_count: int, scratch: Optimize_Scratch) -> bool {
	index_count := len(indices)
	assert(index_count % 3 == 0, "_optimize_cache: incomplete triangle")
	if index_count / 3 < 2 {
		copy(scratch.order[:index_count], indices)
		return false
	}
	_optimize_adjacency(indices, vertex_count, scratch)
	heap := _optimize_heap_seed(indices, vertex_count, scratch)
	if _optimize_cache_walk(indices, &heap, scratch) == index_count do return false
	copy(scratch.order[:index_count], indices)
	return true
}

@(private)
_optimize_adjacency :: proc(indices: []u32, vertex_count: int, scratch: Optimize_Scratch) {
	offsets := scratch.adjacency_offset[:vertex_count + 1]
	for slot in 0 ..< len(offsets) do offsets[slot] = 0
	for index in indices do offsets[int(index) + 1] += 1
	for slot in 1 ..< len(offsets) do offsets[slot] += offsets[slot - 1]
	assert(int(offsets[vertex_count]) == len(indices), "_optimize_adjacency: entry count")
	for vertex in 0 ..< vertex_count {
		scratch.adjacency_cursor[vertex] = offsets[vertex]
		scratch.remaining[vertex] = offsets[vertex + 1] - offsets[vertex]
	}
	for triangle in 0 ..< len(indices) / 3 {
		for corner in 0 ..< 3 {
			vertex := indices[triangle * 3 + corner]
			scratch.adjacency[scratch.adjacency_cursor[vertex]] = u32(triangle)
			scratch.adjacency_cursor[vertex] += 1
		}
	}
}

@(private)
_optimize_heap_seed :: proc(
	indices: []u32,
	vertex_count: int,
	scratch: Optimize_Scratch,
) -> Optimize_Heap {
	triangle_count := len(indices) / 3
	for vertex in 0 ..< vertex_count {
		scratch.cache_position[vertex] = -1
		scratch.vertex_mark[vertex] = max(u32)
		remaining := int(scratch.remaining[vertex])
		scratch.vertex_scores[vertex] = _optimize_vertex_score(-1, remaining)
	}
	heap := Optimize_Heap {
		items  = scratch.heap_items[:triangle_count],
		slots  = scratch.heap_slots[:triangle_count],
		scores = scratch.triangle_scores[:triangle_count],
		count  = triangle_count,
	}
	for triangle in 0 ..< triangle_count {
		heap.scores[triangle] = _optimize_triangle_score(indices, scratch, triangle)
		heap.items[triangle] = u32(triangle)
		heap.slots[triangle] = i32(triangle)
		scratch.touched_mark[triangle] = max(u32)
	}
	for start := triangle_count / 2 - 1; start >= 0; start -= 1 {
		_optimize_heap_down(&heap, start)
	}
	return heap
}

@(private)
_optimize_cache_walk :: proc(
	indices: []u32,
	heap: ^Optimize_Heap,
	scratch: Optimize_Scratch,
) -> int {
	assert(heap != nil, "_optimize_cache_walk: nil heap")
	triangle_count := len(indices) / 3
	ring := Optimize_Ring{}
	written := 0
	for step in 0 ..< triangle_count {
		best, ok := _optimize_heap_pop(heap)
		if !ok do break
		// The rejection floor. Reaching it means every remaining triangle has a
		// vertex with no work left, which a validated mesh cannot produce.
		if heap.scores[best] <= -1 do break
		corners: [3]u32
		for corner in 0 ..< 3 {
			corners[corner] = indices[int(best) * 3 + corner]
			scratch.order[written] = corners[corner]
			written += 1
		}
		_optimize_ring_insert(&ring, corners, scratch)
		_optimize_rescore(indices, heap, scratch, &ring, corners, u32(step))
	}
	return written
}

// -- modelled cache ring ------------------------------------------------------

@(private)
Optimize_Ring :: struct {
	slots:         [OPTIMIZE_RING_CAPACITY]u32,
	length:        int,
	evicted:       [OPTIMIZE_CACHE_RECENT]u32,
	evicted_count: int,
}

@(private)
_optimize_ring_insert :: proc(
	ring: ^Optimize_Ring,
	corners: [3]u32,
	scratch: Optimize_Scratch,
) {
	assert(ring != nil, "_optimize_ring_insert: nil ring")
	ring.evicted_count = 0
	for vertex in corners {
		assert(scratch.remaining[vertex] > 0, "_optimize_ring_insert: valence underflow")
		scratch.remaining[vertex] -= 1
		_optimize_ring_front(ring, vertex)
	}
	// Three insertions can push at most three vertices off the end. Their
	// modelled position has to be cleared: leaving the stale slot behind would
	// keep the cache bonus in an evicted vertex's score indefinitely and
	// inflate every triangle that still references it.
	for ring.length > OPTIMIZE_CACHE_SIZE {
		ring.length -= 1
		dropped := ring.slots[ring.length]
		scratch.cache_position[dropped] = -1
		assert(ring.evicted_count < len(ring.evicted), "_optimize_ring_insert: eviction burst")
		ring.evicted[ring.evicted_count] = dropped
		ring.evicted_count += 1
	}
	for slot in 0 ..< ring.length do scratch.cache_position[ring.slots[slot]] = i32(slot)
}

@(private)
_optimize_ring_front :: proc(ring: ^Optimize_Ring, vertex: u32) {
	assert(ring != nil, "_optimize_ring_front: nil ring")
	found := ring.length
	for slot in 0 ..< ring.length {
		if ring.slots[slot] == vertex {
			found = slot
			break
		}
	}
	if found == ring.length {
		assert(ring.length < len(ring.slots), "_optimize_ring_front: ring overflow")
		ring.length += 1
	}
	for slot := found; slot > 0; slot -= 1 do ring.slots[slot] = ring.slots[slot - 1]
	ring.slots[0] = vertex
}

// _optimize_rescore updates every vertex whose score just changed - the emitted
// corners, everything still resident, and everything evicted - then rebuilds
// the score of each triangle those vertices touch. The two mark arrays make the
// union a set without a set: `stamp` is the step number, so a mark from an
// earlier step is stale by construction and nothing needs clearing between
// steps.
@(private)
_optimize_rescore :: proc(
	indices: []u32,
	heap: ^Optimize_Heap,
	scratch: Optimize_Scratch,
	ring: ^Optimize_Ring,
	corners: [3]u32,
	stamp: u32,
) {
	assert(heap != nil, "_optimize_rescore: nil heap")
	assert(ring != nil, "_optimize_rescore: nil ring")
	count := 0
	for vertex in corners do count = _optimize_mark(scratch, vertex, stamp, count)
	for slot in 0 ..< ring.length {
		vertex := ring.slots[slot]
		count = _optimize_mark(scratch, vertex, stamp, count)
	}
	for slot in 0 ..< ring.evicted_count {
		vertex := ring.evicted[slot]
		count = _optimize_mark(scratch, vertex, stamp, count)
	}
	for slot in 0 ..< count {
		triangle := scratch.touched[slot]
		if heap.slots[triangle] < 0 do continue
		heap.scores[triangle] = _optimize_triangle_score(indices, scratch, int(triangle))
		_optimize_heap_refresh(heap, triangle)
	}
}

@(private)
_optimize_mark :: proc(
	scratch: Optimize_Scratch,
	vertex: u32,
	stamp: u32,
	count: int,
) -> int {
	if scratch.vertex_mark[vertex] == stamp do return count
	scratch.vertex_mark[vertex] = stamp
	position := int(scratch.cache_position[vertex])
	remaining := int(scratch.remaining[vertex])
	scratch.vertex_scores[vertex] = _optimize_vertex_score(position, remaining)
	written := count
	for slot in scratch.adjacency_offset[vertex] ..< scratch.adjacency_offset[vertex + 1] {
		triangle := scratch.adjacency[slot]
		if scratch.touched_mark[triangle] == stamp do continue
		scratch.touched_mark[triangle] = stamp
		scratch.touched[written] = triangle
		written += 1
	}
	return written
}

// -- selection heap -----------------------------------------------------------

// An indexed binary max-heap over live triangles.
//
// The offline tool scans every live triangle on every step, which is O(T^2) and
// fine for the small props Blender cooks. The runtime cook has to survive a
// terrain chunk, so the same selection is made in O(T log T) here. The
// comparator below is a total order, and the maximum under a total order is
// unique, so this is a data-structure change and not an algorithm change: both
// implementations pick the same triangle at every step.
@(private)
Optimize_Heap :: struct {
	items:  []u32,
	// Position of each triangle within `items`, or -1 once it has been emitted.
	// Keeping it lets a rescore reposition one triangle instead of pushing a
	// duplicate, which is what bounds the heap at one entry per triangle.
	slots:  []i32,
	scores: []f64,
	count:  int,
}

// Ties resolve to the lowest triangle index. The offline scan walks upward
// taking a strictly better score, so it too keeps the lowest index among
// equals; encoding that here makes the two selections identical rather than
// merely equivalent.
@(private)
_optimize_heap_better :: proc(heap: ^Optimize_Heap, first, second: u32) -> bool {
	assert(heap != nil, "_optimize_heap_better: nil heap")
	left := heap.scores[first]
	right := heap.scores[second]
	if left != right do return left > right
	return first < second
}

@(private)
_optimize_heap_swap :: proc(heap: ^Optimize_Heap, first, second: int) {
	assert(heap != nil, "_optimize_heap_swap: nil heap")
	assert(first >= 0 && first < len(heap.items), "_optimize_heap_swap: first past storage")
	assert(second >= 0 && second < len(heap.items), "_optimize_heap_swap: second past storage")
	heap.items[first], heap.items[second] = heap.items[second], heap.items[first]
	assert(int(heap.items[first]) < len(heap.slots), "_optimize_heap_swap: triangle past slots")
	assert(int(heap.items[second]) < len(heap.slots), "_optimize_heap_swap: triangle past slots")
	heap.slots[heap.items[first]] = i32(first)
	heap.slots[heap.items[second]] = i32(second)
}

@(private)
_optimize_heap_up :: proc(heap: ^Optimize_Heap, start: int) {
	assert(heap != nil, "_optimize_heap_up: nil heap")
	assert(start >= 0, "_optimize_heap_up: negative start")
	position := start
	// The heap is at most log2(count) deep, so `count` iterations is a loose
	// but certain bound on the walk.
	for _ in 0 ..< heap.count {
		if position == 0 do return
		parent := (position - 1) / 2
		if !_optimize_heap_better(heap, heap.items[position], heap.items[parent]) do return
		_optimize_heap_swap(heap, position, parent)
		position = parent
	}
}

@(private)
_optimize_heap_down :: proc(heap: ^Optimize_Heap, start: int) {
	assert(heap != nil, "_optimize_heap_down: nil heap")
	assert(start >= 0, "_optimize_heap_down: negative start")
	position := start
	for _ in 0 ..< heap.count {
		child := position * 2 + 1
		if child >= heap.count do return
		if child + 1 < heap.count {
			if _optimize_heap_better(heap, heap.items[child + 1], heap.items[child]) {
				child += 1
			}
		}
		if !_optimize_heap_better(heap, heap.items[child], heap.items[position]) do return
		_optimize_heap_swap(heap, position, child)
		position = child
	}
}

@(private)
_optimize_heap_pop :: proc(heap: ^Optimize_Heap) -> (u32, bool) {
	assert(heap != nil, "_optimize_heap_pop: nil heap")
	if heap.count == 0 do return 0, false
	best := heap.items[0]
	heap.count -= 1
	heap.items[0] = heap.items[heap.count]
	heap.slots[heap.items[0]] = 0
	heap.slots[best] = -1
	if heap.count > 0 do _optimize_heap_down(heap, 0)
	return best, true
}

@(private)
_optimize_heap_refresh :: proc(heap: ^Optimize_Heap, triangle: u32) {
	assert(heap != nil, "_optimize_heap_refresh: nil heap")
	position := heap.slots[triangle]
	if position < 0 do return
	// A changed score moves an entry in exactly one direction, but which one
	// depends on the neighbours, so both are attempted and at most one acts.
	_optimize_heap_up(heap, int(position))
	_optimize_heap_down(heap, int(heap.slots[triangle]))
}

// -- overdraw -----------------------------------------------------------------

// _optimize_overdraw splits the cache order into fixed runs and sorts those
// runs front to back by mean squared distance from the mesh centroid. It is a
// weaker heuristic than a true depth sort and it is allowed to give back a
// little cache efficiency, bounded by keeping whole runs intact rather than
// resorting individual triangles.
@(private)
_optimize_overdraw :: proc(
	vertices: []asset.Vertex,
	indices: []u32,
	output: []u32,
	scratch: Optimize_Scratch,
) {
	index_count := len(indices)
	triangle_count := index_count / 3
	assert(index_count % 3 == 0, "_optimize_overdraw: incomplete triangle")
	if triangle_count < 2 {
		copy(output[:index_count], indices)
		return
	}
	center := _optimize_centroid(vertices)
	divisor := max(f64(1), OPTIMIZE_OVERDRAW_THRESHOLD * OPTIMIZE_OVERDRAW_RUN_DIVISOR)
	run_length := max(1, int(f64(triangle_count) / divisor))
	run_count := 0
	for start := 0; start < triangle_count; start += run_length {
		count := min(run_length, triangle_count - start)
		scratch.runs[run_count] = Optimize_Run {
			key   = _optimize_run_key(vertices, indices, center, start, count),
			start = u32(start),
			count = u32(count),
		}
		run_count += 1
	}
	_heap_sort(scratch.runs[:run_count], _optimize_run_less)
	written := 0
	for run in scratch.runs[:run_count] {
		first := int(run.start) * 3
		last := first + int(run.count) * 3
		copy(output[written:], indices[first:last])
		written += last - first
	}
	assert(written == index_count, "_optimize_overdraw: runs did not cover the mesh")
}

@(private)
_optimize_centroid :: proc(vertices: []asset.Vertex) -> [3]f64 {
	assert(len(vertices) > 0, "_optimize_centroid: empty mesh")
	center := [3]f64{}
	for axis in 0 ..< 3 {
		total := f64(0)
		for vertex in vertices do total += f64(vertex.position[axis])
		center[axis] = total / f64(len(vertices))
	}
	return center
}

@(private)
_optimize_run_key :: proc(
	vertices: []asset.Vertex,
	indices: []u32,
	center: [3]f64,
	start, count: int,
) -> f64 {
	assert(count > 0, "_optimize_run_key: empty run")
	distance := f64(0)
	for triangle in start ..< start + count {
		for corner in 0 ..< 3 {
			vertex := vertices[indices[triangle * 3 + corner]]
			total := f64(0)
			for axis in 0 ..< 3 {
				offset := f64(vertex.position[axis]) - center[axis]
				total += offset * offset
			}
			distance += total
		}
	}
	return distance / f64(count * 3)
}

// A total order, not merely a distance comparison: runs start at distinct
// offsets, so ties broken by start keep the sort's output independent of the
// algorithm's internal swaps.
@(private)
_optimize_run_less :: proc(first, second: Optimize_Run) -> bool {
	if first.key != second.key do return first.key < second.key
	return first.start < second.start
}

// -- vertex fetch -------------------------------------------------------------

// _optimize_fetch renumbers vertices into first-use order so the post-transform
// stage walks the vertex buffer forward. It runs in place on the index buffer
// and drops any vertex no surviving triangle referenced, which is why the
// result's vertex count can be below the input's.
@(private)
_optimize_fetch :: proc(
	vertices: []asset.Vertex,
	indices: []u32,
	out_vertices: []asset.Vertex,
	remap: []u32,
) -> int {
	assert(len(remap) == len(vertices), "_optimize_fetch: remap does not cover the mesh")
	for slot in 0 ..< len(remap) do remap[slot] = max(u32)
	written := 0
	for index, slot in indices {
		if remap[index] == max(u32) {
			remap[index] = u32(written)
			out_vertices[written] = vertices[index]
			written += 1
		}
		indices[slot] = remap[index]
	}
	return written
}
