package asset

// INGMESH2 adds what version 1 explicitly deferred: a per-mesh LOD chain, an
// optional cluster DAG, and 16-byte packed vertices. Version 1 files stay
// readable through the same entry point - `cooked_mesh_decode` dispatches on
// the magic's last byte and projects a version 2 file's LOD 0 into the old
// `Cooked_Mesh_Bundle`, so callers that never asked for LODs never change.
//
// Layout, all little-endian:
//
//   header            48 bytes
//   mesh records      mesh_count    * 68
//   lod records       lod_count     * 24
//   cluster records   cluster_count * 40
//   group records     group_count   * 32
//   vertices          vertex_count  * (16 packed | 36 fat)
//   indices           index_count   * 4

COOKED_MESH_V2_MAGIC :: [8]u8{'I', 'N', 'G', 'M', 'E', 'S', 'H', '2'}
COOKED_MESH_V2_VERSION :: u32(2)
COOKED_MESH_V2_HEADER_SIZE :: 48
COOKED_MESH_V2_RECORD_SIZE :: 68
COOKED_MESH_V2_LOD_SIZE :: 24
COOKED_MESH_V2_CLUSTER_SIZE :: 40
COOKED_MESH_V2_GROUP_SIZE :: 32

// Version 1's 256-mesh ceiling was chosen for a single hand-authored bundle.
// A LOD-cooked bundle multiplies records by its chain depth, so the mesh bound
// rises and the real limit becomes total bytes, which is what actually
// constrains an upload.
COOKED_MESH_V2_MAX_MESHES :: 1024
COOKED_MESH_V2_MAX_MESH_LODS :: 8
COOKED_MESH_V2_MAX_LODS :: COOKED_MESH_V2_MAX_MESHES * COOKED_MESH_V2_MAX_MESH_LODS
COOKED_MESH_V2_MAX_CLUSTERS :: 262_144
COOKED_MESH_V2_MAX_GROUPS :: COOKED_MESH_V2_MAX_CLUSTERS
COOKED_MESH_V2_MAX_BYTES :: 256 * 1024 * 1024

COOKED_MESH_V2_FLAG_PACKED_VERTICES :: u32(1 << 0)
COOKED_MESH_V2_FLAG_CLUSTERS :: u32(1 << 1)
COOKED_MESH_V2_FLAG_MASK :: COOKED_MESH_V2_FLAG_PACKED_VERTICES | COOKED_MESH_V2_FLAG_CLUSTERS

Mesh_Lod :: struct {
	view:                    Mesh_View,
	// Geometric error this level introduced against LOD 0, in mesh units.
	error:                   f32,
	// Projected height in pixels below which this level is preferred. Coarser
	// levels carry smaller thresholds, so a runtime walks the chain forward
	// and stops at the first level whose threshold the mesh still exceeds.
	screen_height_threshold: f32,
}

Cooked_Mesh_Chain :: struct {
	id:        Mesh_Id,
	lods:      []Mesh_Lod,
	dag:       Cluster_Dag,
	bounds:    Bounds_3D,
	uv_bounds: Bounds_2D,
}

Cooked_Mesh_V2_Storage :: struct {
	meshes:   []Cooked_Mesh_Chain,
	lods:     []Mesh_Lod,
	clusters: []Cluster,
	groups:   []Cluster_Group,
	vertices: []Vertex,
	indices:  []u32,
}

Cooked_Mesh_V2_Bundle :: struct {
	meshes:       []Cooked_Mesh_Chain,
	vertex_count: u32,
	index_count:  u32,
	flags:        u32,
}

Cooked_Mesh_Format :: enum u8 {
	Unknown,
	V1,
	V2,
}

@(private)
Cooked_V2_Layout :: struct {
	mesh_count:     u32,
	lod_count:      u32,
	cluster_count:  u32,
	group_count:    u32,
	vertex_count:   u32,
	index_count:    u32,
	flags:          u32,
	lod_offset:     int,
	cluster_offset: int,
	group_offset:   int,
	vertex_offset:  int,
	index_offset:   int,
	vertex_size:    int,
}

@(private)
Cooked_V2_Mesh_Record :: struct {
	id:            Mesh_Id,
	lod_first:     u32,
	lod_count:     u32,
	cluster_first: u32,
	cluster_count: u32,
	group_first:   u32,
	group_count:   u32,
	bounds:        Bounds_3D,
	uv_bounds:     Bounds_2D,
}

// cooked_mesh_format identifies a bundle without decoding it, so a loader can
// size its storage before committing to a read.
cooked_mesh_format :: proc(bytes: []u8) -> Cooked_Mesh_Format {
	assert(len(bytes) >= 0, "cooked_mesh_format: negative length")
	if len(bytes) < 8 do return .Unknown
	v1 := COOKED_MESH_MAGIC
	v2 := COOKED_MESH_V2_MAGIC
	matches_v1, matches_v2 := true, true
	for index in 0 ..< 8 {
		if bytes[index] != v1[index] do matches_v1 = false
		if bytes[index] != v2[index] do matches_v2 = false
	}
	if matches_v1 do return .V1
	if matches_v2 do return .V2
	return .Unknown
}

cooked_mesh_v2_decode :: proc(
	bytes: []u8,
	storage: Cooked_Mesh_V2_Storage,
) -> (
	Cooked_Mesh_V2_Bundle,
	Cooked_Mesh_Result,
	bool,
) {
	layout, header_result, header_ok := _cooked_v2_layout(bytes)
	if !header_ok do return {}, header_result, false
	if int(layout.mesh_count) > len(storage.meshes) ||
	   int(layout.lod_count) > len(storage.lods) ||
	   int(layout.cluster_count) > len(storage.clusters) ||
	   int(layout.group_count) > len(storage.groups) ||
	   int(layout.vertex_count) > len(storage.vertices) ||
	   int(layout.index_count) > len(storage.indices) {
		return {}, {fault = .Capacity, offset = 12}, false
	}
	_cooked_v2_read_clusters(bytes, layout, storage.clusters[:layout.cluster_count])
	_cooked_v2_read_groups(bytes, layout, storage.groups[:layout.group_count])
	_cooked_mesh_indices(bytes, layout.index_offset, storage.indices[:layout.index_count])
	if result, ok := _cooked_v2_read_vertices(bytes, layout, storage); !ok {
		return {}, result, false
	}
	return _cooked_v2_chains(bytes, layout, storage)
}

@(private)
_cooked_v2_layout :: proc(bytes: []u8) -> (Cooked_V2_Layout, Cooked_Mesh_Result, bool) {
	assert(len(bytes) >= 0, "_cooked_v2_layout: negative length")
	if len(bytes) < COOKED_MESH_V2_HEADER_SIZE {
		return {}, {fault = .Truncated, offset = u32(max(len(bytes), 0))}, false
	}
	if len(bytes) > COOKED_MESH_V2_MAX_BYTES {
		return {}, {fault = .Capacity, offset = 0}, false
	}
	magic := COOKED_MESH_V2_MAGIC
	for index in 0 ..< len(magic) {
		if bytes[index] != magic[index] {
			return {}, {fault = .Bad_Magic, offset = u32(index)}, false
		}
	}
	if _cooked_mesh_u32(bytes, 8) != COOKED_MESH_V2_VERSION {
		return {}, {fault = .Bad_Version, offset = 8}, false
	}
	result := Cooked_V2_Layout {
		mesh_count    = _cooked_mesh_u32(bytes, 12),
		lod_count     = _cooked_mesh_u32(bytes, 16),
		cluster_count = _cooked_mesh_u32(bytes, 20),
		group_count   = _cooked_mesh_u32(bytes, 24),
		vertex_count  = _cooked_mesh_u32(bytes, 28),
		index_count   = _cooked_mesh_u32(bytes, 32),
		flags         = _cooked_mesh_u32(bytes, 36),
	}
	return _cooked_v2_layout_spans(bytes, result)
}

@(private)
_cooked_v2_layout_spans :: proc(
	bytes: []u8,
	input: Cooked_V2_Layout,
) -> (
	Cooked_V2_Layout,
	Cooked_Mesh_Result,
	bool,
) {
	assert(len(bytes) >= COOKED_MESH_V2_HEADER_SIZE, "_cooked_v2_layout_spans: short header")
	assert(input.vertex_size == 0, "_cooked_v2_layout_spans: layout already sized")
	result := input
	if result.flags & ~u32(COOKED_MESH_V2_FLAG_MASK) != 0 {
		return {}, {fault = .Invalid_Flags, offset = 36}, false
	}
	if result.mesh_count == 0 ||
	   result.mesh_count > COOKED_MESH_V2_MAX_MESHES ||
	   result.lod_count == 0 ||
	   result.lod_count > COOKED_MESH_V2_MAX_LODS ||
	   result.cluster_count > COOKED_MESH_V2_MAX_CLUSTERS ||
	   result.group_count > COOKED_MESH_V2_MAX_GROUPS ||
	   result.vertex_count == 0 ||
	   result.index_count == 0 ||
	   result.index_count % 3 != 0 {
		return {}, {fault = .Invalid_Record, offset = 12}, false
	}
	has_clusters := result.flags & COOKED_MESH_V2_FLAG_CLUSTERS != 0
	if has_clusters != (result.cluster_count > 0) {
		return {}, {fault = .Invalid_Flags, offset = 36}, false
	}
	result.vertex_size = size_of(Vertex)
	if result.flags & COOKED_MESH_V2_FLAG_PACKED_VERTICES != 0 {
		result.vertex_size = size_of(Vertex_Packed)
	}
	result.lod_offset =
		COOKED_MESH_V2_HEADER_SIZE + int(result.mesh_count) * COOKED_MESH_V2_RECORD_SIZE
	result.cluster_offset = result.lod_offset + int(result.lod_count) * COOKED_MESH_V2_LOD_SIZE
	result.group_offset =
		result.cluster_offset + int(result.cluster_count) * COOKED_MESH_V2_CLUSTER_SIZE
	result.vertex_offset =
		result.group_offset + int(result.group_count) * COOKED_MESH_V2_GROUP_SIZE
	result.index_offset = result.vertex_offset + int(result.vertex_count) * result.vertex_size
	expected := u64(result.index_offset) + u64(result.index_count) * size_of(u32)
	if expected > u64(len(bytes)) {
		return {}, {fault = .Truncated, offset = u32(len(bytes))}, false
	}
	if expected < u64(len(bytes)) {
		return {}, {fault = .Trailing_Data, offset = u32(expected)}, false
	}
	return result, {}, true
}

@(private)
_cooked_v2_read_vertices :: proc(
	bytes: []u8,
	layout: Cooked_V2_Layout,
	storage: Cooked_Mesh_V2_Storage,
) -> (
	Cooked_Mesh_Result,
	bool,
) {
	assert(layout.vertex_count > 0, "_cooked_v2_read_vertices: empty vertices")
	assert(layout.vertex_size > 0, "_cooked_v2_read_vertices: unsized layout")
	if layout.flags & COOKED_MESH_V2_FLAG_PACKED_VERTICES == 0 {
		_cooked_mesh_vertices(bytes, layout.vertex_offset, storage.vertices[:layout.vertex_count])
		return {}, true
	}
	// Packed vertices are quantized inside their owning mesh's bounds, so the
	// unpack has to be driven per mesh record rather than over the flat array.
	for index in 0 ..< int(layout.mesh_count) {
		offset := COOKED_MESH_V2_HEADER_SIZE + index * COOKED_MESH_V2_RECORD_SIZE
		record := _cooked_v2_mesh_record(bytes, offset)
		quantization := Vertex_Quantization{record.bounds, record.uv_bounds}
		if !quantization_valid(quantization) {
			return {fault = .Invalid_Record, offset = u32(offset), mesh = record.id}, false
		}
		span, span_ok := _cooked_v2_mesh_vertex_span(bytes, layout, record)
		if !span_ok {
			return {fault = .Invalid_Lod, offset = u32(offset), mesh = record.id}, false
		}
		_cooked_v2_unpack_span(bytes, layout, quantization, span, storage.vertices)
	}
	return {}, true
}

@(private)
_cooked_v2_unpack_span :: proc(
	bytes: []u8,
	layout: Cooked_V2_Layout,
	quantization: Vertex_Quantization,
	span: [2]u32,
	vertices: []Vertex,
) {
	assert(span[1] >= span[0], "_cooked_v2_unpack_span: inverted span")
	assert(int(span[1]) <= len(vertices), "_cooked_v2_unpack_span: span past storage")
	for index in span[0] ..< span[1] {
		base := layout.vertex_offset + int(index) * layout.vertex_size
		packed: Vertex_Packed
		for axis in 0 ..< 3 do packed.position[axis] = _cooked_mesh_u16(bytes, base + axis * 2)
		packed.normal[0] = i8(bytes[base + 6])
		packed.normal[1] = i8(bytes[base + 7])
		for axis in 0 ..< 2 do packed.uv[axis] = _cooked_mesh_u16(bytes, base + 8 + axis * 2)
		packed.scalar = bytes[base + 12]
		vertices[index] = vertex_unpack(packed, quantization)
	}
}

// A mesh's vertices are the union of its LOD spans, which the record table
// guarantees is contiguous. Recovering it from the first and last LOD avoids
// storing a redundant span in the mesh record.
@(private)
_cooked_v2_mesh_vertex_span :: proc(
	bytes: []u8,
	layout: Cooked_V2_Layout,
	record: Cooked_V2_Mesh_Record,
) -> (
	[2]u32,
	bool,
) {
	assert(layout.lod_offset > 0, "_cooked_v2_mesh_vertex_span: unsized layout")
	assert(len(bytes) > layout.lod_offset, "_cooked_v2_mesh_vertex_span: short bytes")
	if record.lod_count == 0 || record.lod_count > COOKED_MESH_V2_MAX_MESH_LODS do return {}, false
	last := u64(record.lod_first) + u64(record.lod_count)
	if last > u64(layout.lod_count) do return {}, false
	first := _cooked_v2_lod_record(bytes, layout, record.lod_first)
	final := _cooked_v2_lod_record(bytes, layout, u32(last) - 1)
	end := u64(final[0]) + u64(final[1])
	if end > u64(layout.vertex_count) || u64(first[0]) > end do return {}, false
	return {first[0], u32(end)}, true
}

@(private)
_cooked_v2_read_clusters :: proc(bytes: []u8, layout: Cooked_V2_Layout, clusters: []Cluster) {
	assert(len(clusters) == int(layout.cluster_count), "_cooked_v2_read_clusters: size mismatch")
	assert(layout.cluster_offset >= layout.lod_offset, "_cooked_v2_read_clusters: bad layout")
	for index in 0 ..< len(clusters) {
		base := layout.cluster_offset + index * COOKED_MESH_V2_CLUSTER_SIZE
		clusters[index] = Cluster {
			first_index  = _cooked_mesh_u32(bytes, base),
			index_count  = _cooked_mesh_u32(bytes, base + 4),
			center       = {
				_cooked_mesh_f32(bytes, base + 8),
				_cooked_mesh_f32(bytes, base + 12),
				_cooked_mesh_f32(bytes, base + 16),
			},
			radius       = _cooked_mesh_f32(bytes, base + 20),
			error        = _cooked_mesh_f32(bytes, base + 24),
			parent_error = _cooked_mesh_f32(bytes, base + 28),
			group        = _cooked_mesh_u32(bytes, base + 32),
			level        = u8(_cooked_mesh_u32(bytes, base + 36) & 0xFF),
		}
	}
}

@(private)
_cooked_v2_read_groups :: proc(bytes: []u8, layout: Cooked_V2_Layout, groups: []Cluster_Group) {
	assert(len(groups) == int(layout.group_count), "_cooked_v2_read_groups: size mismatch")
	assert(layout.group_offset >= layout.cluster_offset, "_cooked_v2_read_groups: bad layout")
	for index in 0 ..< len(groups) {
		base := layout.group_offset + index * COOKED_MESH_V2_GROUP_SIZE
		groups[index] = Cluster_Group {
			first_child = _cooked_mesh_u32(bytes, base),
			child_count = _cooked_mesh_u32(bytes, base + 4),
			center      = {
				_cooked_mesh_f32(bytes, base + 8),
				_cooked_mesh_f32(bytes, base + 12),
				_cooked_mesh_f32(bytes, base + 16),
			},
			radius      = _cooked_mesh_f32(bytes, base + 20),
			error       = _cooked_mesh_f32(bytes, base + 24),
			level       = u8(_cooked_mesh_u32(bytes, base + 28) & 0xFF),
		}
	}
}

@(private)
_cooked_v2_mesh_record :: proc(bytes: []u8, offset: int) -> Cooked_V2_Mesh_Record {
	assert(offset >= COOKED_MESH_V2_HEADER_SIZE, "_cooked_v2_mesh_record: offset in header")
	assert(offset + COOKED_MESH_V2_RECORD_SIZE <= len(bytes), "_cooked_v2_mesh_record: truncated")
	result := Cooked_V2_Mesh_Record {
		id            = Mesh_Id(_cooked_mesh_u32(bytes, offset)),
		lod_first     = _cooked_mesh_u32(bytes, offset + 4),
		lod_count     = _cooked_mesh_u32(bytes, offset + 8),
		cluster_first = _cooked_mesh_u32(bytes, offset + 12),
		cluster_count = _cooked_mesh_u32(bytes, offset + 16),
		group_first   = _cooked_mesh_u32(bytes, offset + 20),
		group_count   = _cooked_mesh_u32(bytes, offset + 24),
	}
	for axis in 0 ..< 3 {
		result.bounds.minimum[axis] = _cooked_mesh_f32(bytes, offset + 28 + axis * 4)
		result.bounds.maximum[axis] = _cooked_mesh_f32(bytes, offset + 40 + axis * 4)
	}
	for axis in 0 ..< 2 {
		result.uv_bounds.minimum[axis] = _cooked_mesh_f32(bytes, offset + 52 + axis * 4)
		result.uv_bounds.maximum[axis] = _cooked_mesh_f32(bytes, offset + 60 + axis * 4)
	}
	return result
}

// Returns the raw LOD span as {first_vertex, vertex_count, first_index,
// index_count} plus the two float fields, kept as a small array so the record
// can be read twice without materializing a struct table on the stack.
@(private)
_cooked_v2_lod_record :: proc(bytes: []u8, layout: Cooked_V2_Layout, index: u32) -> [4]u32 {
	assert(index < layout.lod_count, "_cooked_v2_lod_record: index out of range")
	assert(layout.lod_offset > 0, "_cooked_v2_lod_record: unsized layout")
	base := layout.lod_offset + int(index) * COOKED_MESH_V2_LOD_SIZE
	return {
		_cooked_mesh_u32(bytes, base),
		_cooked_mesh_u32(bytes, base + 4),
		_cooked_mesh_u32(bytes, base + 8),
		_cooked_mesh_u32(bytes, base + 12),
	}
}

@(private)
_cooked_v2_lod_thresholds :: proc(
	bytes: []u8,
	layout: Cooked_V2_Layout,
	index: u32,
) -> (
	f32,
	f32,
) {
	assert(index < layout.lod_count, "_cooked_v2_lod_thresholds: index out of range")
	assert(layout.lod_offset > 0, "_cooked_v2_lod_thresholds: unsized layout")
	base := layout.lod_offset + int(index) * COOKED_MESH_V2_LOD_SIZE
	return _cooked_mesh_f32(bytes, base + 16), _cooked_mesh_f32(bytes, base + 20)
}

@(private)
_cooked_mesh_u16 :: proc(bytes: []u8, offset: int) -> u16 {
	assert(offset >= 0, "_cooked_mesh_u16: negative offset")
	assert(offset + size_of(u16) <= len(bytes), "_cooked_mesh_u16: truncated value")
	return u16(bytes[offset]) | u16(bytes[offset + 1]) << 8
}
