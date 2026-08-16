package procgen

import asset "../asset"
import "core:math"

// Quadric edge-collapse simplification.
//
// This is the offline half of cluster LOD: `mesh_cluster.odin` locks a group's
// outer boundary and calls in here to halve the interior. It is written to the
// same rules as the rest of `ingot:procgen` - deterministic for a given input,
// no recursion, and no allocation beyond a caller-supplied scratch block whose
// size is a pure function of the input dimensions.
//
// Two deliberate simplifications against a textbook Garland-Heckbert:
//
//   * Collapses always move a vertex onto an existing vertex rather than to an
//     optimal point. That costs a little quality and buys a large amount of
//     safety - no matrix inversion, no vertices drifting off the surface, and
//     locked positions stay bit-identical, which is what makes the group
//     borders crack-free.
//   * Topology is resolved over position groups, so a mesh split by normal or
//     UV seam still simplifies. Attributes of a collapsed vertex are inherited
//     from the destination group's representative.

SIMPLIFY_MAX_VERTICES :: 65_536
SIMPLIFY_MAX_INDICES :: SIMPLIFY_MAX_VERTICES * 3
// Each pass rebuilds the edge set from scratch, so a bound on passes is a bound
// on total work. Collapsing at most a fifth of the surviving groups per pass
// keeps the greedy order meaningful; 32 passes takes any mesh below one part in
// a thousand of its original size, far past any useful LOD target.
SIMPLIFY_MAX_PASSES :: 32
SIMPLIFY_PASS_RATIO :: f64(0.2)
SIMPLIFY_EPSILON :: f64(1e-12)
// Boundary planes are weighted well above face planes so an open edge is
// preserved unless the alternative is far worse. The value is the usual
// Garland-Heckbert choice and is a quality knob, not a correctness one.
SIMPLIFY_BOUNDARY_WEIGHT :: f64(1000)
// Vertex flag bits. `LOCKED` is the caller's mask plus any boundary the options
// ask to pin; `PROTECTED` is the frozen fan derived from it every pass.
SIMPLIFY_FLAG_LOCKED :: u8(1 << 0)
SIMPLIFY_FLAG_PROTECTED :: u8(1 << 1)

Simplify_Options :: struct {
	// Stop once the index count reaches or falls below this. Zero means
	// "collapse as far as the error budget allows".
	target_index_count: int,
	// Hard ceiling on the geometric error any single collapse may introduce,
	// in mesh units. Zero means unbounded.
	max_error:          f32,
	// Treat every mesh boundary edge as immovable instead of merely expensive.
	// Cluster group simplification uses the `locked` mask for this instead,
	// because it needs to pin a subset of the boundary, not all of it.
	lock_boundary:      bool,
}

Simplify_Result :: struct {
	vertex_count: int,
	index_count:  int,
	// The largest error any accepted collapse introduced, in mesh units. This
	// is what becomes a cluster's `error` and drives runtime LOD selection.
	error:        f32,
	passes:       int,
	collapses:    int,
}

@(private)
Quadric :: struct {
	// Upper triangle of the symmetric 4x4 error matrix, row major -
	// a00 a01 a02 a03 a11 a12 a13 a22 a23 a33 - followed by the total plane
	// weight accumulated into it. Dividing the raw form by that weight turns
	// the metric back into a mean squared distance, which is what a LOD error
	// has to be: the boundary planes are weighted a thousand times a face, so
	// without the normalisation the reported error would be a function of how
	// much boundary a cluster happened to contain.
	m: [11]f64,
}

@(private)
Simplify_Edge :: struct {
	low:      u32,
	high:     u32,
	count:    u32,
	// Any one triangle using this edge, needed to orient a boundary plane.
	triangle: u32,
}

@(private)
Simplify_Candidate :: struct {
	cost:        f64,
	source:      u32,
	destination: u32,
}

Simplify_Scratch :: struct {
	quadrics:     []Quadric,
	group:        []u32,
	collapse:     []u32,
	touched:      []u32,
	compact:      []u32,
	vertex_table: []u32,
	edge_table:   []u32,
	edges:        []Simplify_Edge,
	candidates:   []Simplify_Candidate,
	flags:        []u8,
}

// simplify_mesh reduces `input` toward `options.target_index_count`, writing the
// result into caller storage. It never grows the mesh, so `out_vertices` and
// `out_indices` sized for the input are always sufficient.
simplify_mesh :: proc(
	input: asset.Mesh_View,
	options: Simplify_Options,
	locked: []bool,
	out_vertices: []asset.Vertex,
	out_indices: []u32,
	scratch: Simplify_Scratch,
) -> (
	Simplify_Result,
	bool,
) {
	assert(options.target_index_count >= 0, "simplify_mesh: negative target")
	assert(options.max_error >= 0, "simplify_mesh: negative error budget")
	if !_simplify_inputs_ok(input, locked, out_vertices, out_indices, scratch) do return {}, false
	vertex_count := len(input.vertices)
	copy(out_vertices[:vertex_count], input.vertices)
	copy(out_indices[:len(input.indices)], input.indices)
	if !_simplify_groups(input.vertices, scratch.vertex_table, scratch.group) do return {}, false
	for index in 0 ..< vertex_count {
		scratch.collapse[index] = u32(index)
		scratch.touched[index] = max(u32)
	}
	state := Simplify_State {
		index_count = len(input.indices),
		target      = options.target_index_count,
		max_error   = f64(options.max_error),
	}
	_simplify_run(input.vertices, out_indices, options, locked, scratch, &state)
	result := Simplify_Result {
		index_count = state.index_count,
		error       = f32(math.sqrt(state.error)),
		passes      = state.passes,
		collapses   = state.collapses,
	}
	result.vertex_count = _simplify_compact(out_vertices, out_indices[:state.index_count], scratch)
	return result, result.vertex_count > 0 && result.index_count > 0
}

// simplify_scratch_size reports the bytes a caller must reserve. Callers that
// prefer typed storage can size the individual arrays from the same rule; the
// byte form exists so a cook tool has one number to allocate.
simplify_scratch_size :: proc(vertex_count, index_count: int) -> int {
	assert(vertex_count > 0, "simplify_scratch_size: empty vertices")
	assert(index_count > 0, "simplify_scratch_size: empty indices")
	vertex_slots := _simplify_table_size(vertex_count)
	edge_slots := _simplify_table_size(index_count)
	total := _simplify_align(vertex_count * size_of(Quadric))
	total += _simplify_align(vertex_count * size_of(u32)) * 4
	total += _simplify_align(vertex_slots * size_of(u32))
	total += _simplify_align(edge_slots * size_of(u32))
	total += _simplify_align(index_count * size_of(Simplify_Edge))
	total += _simplify_align(index_count * size_of(Simplify_Candidate))
	total += _simplify_align(vertex_count * size_of(u8))
	return total
}

// simplify_scratch_make carves a caller-owned byte block into the typed scratch
// `simplify_mesh` expects.
//
// The scratch's element types are package private, so without this a caller
// outside `ingot:procgen` has no way to build one: it can name the struct but
// not the types of its fields. The block is allowed to start unaligned, which
// is why it must be `SIMPLIFY_SCRATCH_PADDING` bytes larger than
// `simplify_scratch_size` reports - a caller handing in a static array should
// not have to reason about where the linker put it.
simplify_scratch_make :: proc(
	block: []u8,
	vertex_count, index_count: int,
) -> (
	Simplify_Scratch,
	bool,
) {
	assert(vertex_count > 0, "simplify_scratch_make: empty vertices")
	assert(index_count > 0, "simplify_scratch_make: empty indices")
	required := simplify_scratch_size(vertex_count, index_count) + SIMPLIFY_SCRATCH_PADDING
	if len(block) < required do return {}, false
	address := uintptr(raw_data(block))
	carve := Simplify_Carve {
		block  = block,
		offset = int(
			(SIMPLIFY_SCRATCH_ALIGNMENT - (address & SIMPLIFY_SCRATCH_PADDING)) &
			SIMPLIFY_SCRATCH_PADDING,
		),
	}
	scratch := Simplify_Scratch {
		quadrics     = _simplify_carve(&carve, Quadric, vertex_count),
		group        = _simplify_carve(&carve, u32, vertex_count),
		collapse     = _simplify_carve(&carve, u32, vertex_count),
		touched      = _simplify_carve(&carve, u32, vertex_count),
		compact      = _simplify_carve(&carve, u32, vertex_count),
		vertex_table = _simplify_carve(&carve, u32, _simplify_table_size(vertex_count)),
		edge_table   = _simplify_carve(&carve, u32, _simplify_table_size(index_count)),
		edges        = _simplify_carve(&carve, Simplify_Edge, index_count),
		candidates   = _simplify_carve(&carve, Simplify_Candidate, index_count),
		flags        = _simplify_carve(&carve, u8, vertex_count),
	}
	assert(carve.offset <= len(block), "simplify_scratch_make: carve overran the block")
	return scratch, true
}

SIMPLIFY_SCRATCH_ALIGNMENT :: 8
SIMPLIFY_SCRATCH_PADDING :: SIMPLIFY_SCRATCH_ALIGNMENT - 1

@(private)
Simplify_Carve :: struct {
	block:  []u8,
	offset: int,
}

@(private)
_simplify_carve :: proc(carve: ^Simplify_Carve, $T: typeid, count: int) -> []T {
	assert(carve != nil, "_simplify_carve: nil carve")
	assert(count > 0, "_simplify_carve: empty request")
	size := _simplify_align(count * size_of(T))
	assert(carve.offset + size <= len(carve.block), "_simplify_carve: block overflow")
	items := cast([^]T)raw_data(carve.block[carve.offset:])
	carve.offset += size
	return items[:count]
}

@(private)
Simplify_State :: struct {
	index_count: int,
	target:      int,
	max_error:   f64,
	error:       f64,
	passes:      int,
	collapses:   int,
}

@(private)
_simplify_run :: proc(
	vertices: []asset.Vertex,
	indices: []u32,
	options: Simplify_Options,
	locked: []bool,
	scratch: Simplify_Scratch,
	state: ^Simplify_State,
) {
	assert(state != nil, "_simplify_run: nil state")
	assert(state.index_count > 0, "_simplify_run: empty mesh")
	for pass in 0 ..< SIMPLIFY_MAX_PASSES {
		if state.target > 0 && state.index_count <= state.target do return
		live := indices[:state.index_count]
		_simplify_group_flags(scratch.group, locked, scratch.flags[:len(vertices)])
		edge_count := _simplify_edges(live, scratch)
		if edge_count == 0 do return
		_simplify_quadrics(vertices, live, scratch, options, edge_count)
		_simplify_lock_fans(live, scratch.group, scratch.flags[:len(vertices)])
		candidate_count := _simplify_candidates(vertices, scratch, edge_count)
		if candidate_count == 0 do return
		_simplify_sort(scratch.candidates[:candidate_count])
		applied := _simplify_apply(scratch, candidate_count, u32(pass), state)
		if applied == 0 do return
		state.passes = pass + 1
		state.collapses += applied
		state.index_count = _simplify_rebuild(indices[:state.index_count], scratch)
		if state.index_count == 0 do return
	}
}

@(private)
_simplify_inputs_ok :: proc(
	input: asset.Mesh_View,
	locked: []bool,
	out_vertices: []asset.Vertex,
	out_indices: []u32,
	scratch: Simplify_Scratch,
) -> bool {
	assert(len(out_vertices) >= 0, "_simplify_inputs_ok: negative vertex storage")
	assert(len(out_indices) >= 0, "_simplify_inputs_ok: negative index storage")
	if !asset.mesh_validate(input) || input.primitive != .Triangles do return false
	vertex_count := len(input.vertices)
	index_count := len(input.indices)
	if vertex_count > SIMPLIFY_MAX_VERTICES || index_count > SIMPLIFY_MAX_INDICES do return false
	if len(out_vertices) < vertex_count || len(out_indices) < index_count do return false
	if locked != nil && len(locked) < vertex_count do return false
	if len(scratch.quadrics) < vertex_count || len(scratch.group) < vertex_count do return false
	if len(scratch.collapse) < vertex_count || len(scratch.touched) < vertex_count do return false
	if len(scratch.compact) < vertex_count || len(scratch.flags) < vertex_count do return false
	if len(scratch.edges) < index_count || len(scratch.candidates) < index_count do return false
	if len(scratch.vertex_table) < _simplify_table_size(vertex_count) do return false
	if len(scratch.edge_table) < _simplify_table_size(index_count) do return false
	return true
}

@(private)
_simplify_align :: proc(size: int) -> int {
	assert(size >= 0, "_simplify_align: negative size")
	assert(size <= max(int) - 8, "_simplify_align: size overflow")
	return (size + 7) & ~int(7)
}

// Open addressing needs slack to stay near O(1), so the table is the smallest
// power of two at least twice the entry count.
@(private)
_simplify_table_size :: proc(count: int) -> int {
	assert(count > 0, "_simplify_table_size: empty input")
	assert(count <= SIMPLIFY_MAX_INDICES, "_simplify_table_size: count overflow")
	size := 1
	for _ in 0 ..< 32 {
		if size >= count * 2 do break
		size *= 2
	}
	return size
}
