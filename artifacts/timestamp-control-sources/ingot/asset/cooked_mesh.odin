package asset

COOKED_MESH_MAGIC :: [8]u8{'I', 'N', 'G', 'M', 'E', 'S', 'H', '1'}
COOKED_MESH_VERSION :: u32(1)
COOKED_MESH_HEADER_SIZE :: 24
COOKED_MESH_RECORD_SIZE :: 44
COOKED_MESH_VERTEX_SIZE :: size_of(Vertex)
COOKED_MESH_MAX_MESHES :: 256

Cooked_Mesh_Fault :: enum u8 {
	None,
	Bad_Magic,
	Bad_Version,
	Truncated,
	Trailing_Data,
	Capacity,
	Invalid_Record,
	Invalid_Mesh,
	// Version 2 only. Appended rather than interleaved so a stored fault code
	// from an older build still means what it meant then.
	Invalid_Flags,
	Invalid_Lod,
	Invalid_Cluster,
}

Cooked_Mesh_Storage :: struct {
	meshes:   []Mesh_View,
	vertices: []Vertex,
	indices:  []u32,
}

// Version 2 scratch for `cooked_mesh_decode`. It is a separate defaulted
// parameter rather than extra fields on `Cooked_Mesh_Storage` so that every
// existing positional call site keeps compiling unchanged. Leaving it empty
// rejects an INGMESH2 bundle with `.Capacity` instead of degrading to a
// partial read.
Cooked_Mesh_V2_Scratch :: struct {
	chains:   []Cooked_Mesh_Chain,
	lods:     []Mesh_Lod,
	clusters: []Cluster,
	groups:   []Cluster_Group,
}

Cooked_Mesh_Bundle :: struct {
	meshes:       []Mesh_View,
	vertex_count: u32,
	index_count:  u32,
}

Cooked_Mesh_Result :: struct {
	fault:  Cooked_Mesh_Fault,
	offset: u32,
	mesh:   Mesh_Id,
}

@(private)
Cooked_Mesh_Record :: struct {
	id:           Mesh_Id,
	first_vertex: u32,
	vertex_count: u32,
	first_index:  u32,
	index_count:  u32,
	bounds:       Bounds_3D,
}

// cooked_mesh_decode reads a version 1 bundle. A version 2 bundle is accepted
// too and projected onto the same result by exposing each mesh's LOD 0, so a
// caller that predates LOD chains keeps working against re-cooked assets
// without a code change. Callers that want the chain use
// `cooked_mesh_v2_decode` and its larger storage instead.
cooked_mesh_decode :: proc(
	bytes: []u8,
	storage: Cooked_Mesh_Storage,
	scratch: Cooked_Mesh_V2_Scratch = {},
) -> (
	Cooked_Mesh_Bundle,
	Cooked_Mesh_Result,
	bool,
) {
	if cooked_mesh_format(bytes) == .V2 {
		return _cooked_mesh_decode_v2_base(bytes, storage, scratch)
	}
	if len(bytes) < COOKED_MESH_HEADER_SIZE do return _cooked_mesh_fail(.Truncated, len(bytes), 0)
	magic := COOKED_MESH_MAGIC
	for index in 0 ..< len(magic) {
		if bytes[index] != magic[index] do return _cooked_mesh_fail(.Bad_Magic, index, 0)
	}
	version := _cooked_mesh_u32(bytes, 8)
	if version != COOKED_MESH_VERSION do return _cooked_mesh_fail(.Bad_Version, 8, 0)
	mesh_count := _cooked_mesh_u32(bytes, 12)
	vertex_count := _cooked_mesh_u32(bytes, 16)
	index_count := _cooked_mesh_u32(bytes, 20)
	if mesh_count == 0 || mesh_count > COOKED_MESH_MAX_MESHES {
		return _cooked_mesh_fail(.Invalid_Record, 12, 0)
	}
	if int(mesh_count) > len(storage.meshes) ||
	   int(vertex_count) > len(storage.vertices) ||
	   int(index_count) > len(storage.indices) {
		return _cooked_mesh_fail(.Capacity, 12, 0)
	}
	record_bytes := u64(mesh_count) * u64(COOKED_MESH_RECORD_SIZE)
	vertex_bytes := u64(vertex_count) * u64(COOKED_MESH_VERTEX_SIZE)
	index_bytes := u64(index_count) * size_of(u32)
	expected := u64(COOKED_MESH_HEADER_SIZE) + record_bytes + vertex_bytes + index_bytes
	if expected > u64(len(bytes)) do return _cooked_mesh_fail(.Truncated, len(bytes), 0)
	if expected < u64(len(bytes)) do return _cooked_mesh_fail(.Trailing_Data, int(expected), 0)
	records: [COOKED_MESH_MAX_MESHES]Cooked_Mesh_Record
	result, ok := _cooked_mesh_records(bytes, records[:mesh_count], vertex_count, index_count)
	if !ok do return {}, result, false
	vertex_offset := COOKED_MESH_HEADER_SIZE + int(record_bytes)
	index_offset := vertex_offset + int(vertex_bytes)
	_cooked_mesh_vertices(bytes, vertex_offset, storage.vertices[:vertex_count])
	_cooked_mesh_indices(bytes, index_offset, storage.indices[:index_count])
	return _cooked_mesh_views(storage, records[:mesh_count], vertex_count, index_count)
}

cooked_mesh_find :: proc(bundle: Cooked_Mesh_Bundle, id: Mesh_Id) -> (Mesh_View, bool) {
	if id == 0 do return {}, false
	low := 0
	high := len(bundle.meshes)
	for low < high {
		middle := low + (high - low) / 2
		candidate := bundle.meshes[middle]
		if candidate.id < id {
			low = middle + 1
		} else if candidate.id > id {
			high = middle
		} else {
			return candidate, true
		}
	}
	return {}, false
}

// A version 2 bundle carries every level's geometry, so the projection keeps
// the whole payload resident and only narrows the exposed views to LOD 0.
// Reporting the file's totals rather than LOD 0's keeps `vertex_count` meaning
// what it always meant: how much of the caller's storage is in use.
@(private)
_cooked_mesh_decode_v2_base :: proc(
	bytes: []u8,
	storage: Cooked_Mesh_Storage,
	scratch: Cooked_Mesh_V2_Scratch,
) -> (
	Cooked_Mesh_Bundle,
	Cooked_Mesh_Result,
	bool,
) {
	assert(len(bytes) >= 8, "_cooked_mesh_decode_v2_base: magic already matched")
	assert(cooked_mesh_format(bytes) == .V2, "_cooked_mesh_decode_v2_base: wrong format")
	if scratch.chains == nil || scratch.lods == nil {
		return _cooked_mesh_fail(.Capacity, 12, 0)
	}
	v2 := Cooked_Mesh_V2_Storage {
		meshes   = scratch.chains,
		lods     = scratch.lods,
		clusters = scratch.clusters,
		groups   = scratch.groups,
		vertices = storage.vertices,
		indices  = storage.indices,
	}
	bundle, result, ok := cooked_mesh_v2_decode(bytes, v2)
	if !ok do return {}, result, false
	if len(bundle.meshes) > len(storage.meshes) do return _cooked_mesh_fail(.Capacity, 12, 0)
	for index in 0 ..< len(bundle.meshes) {
		chain := bundle.meshes[index]
		assert(len(chain.lods) > 0, "_cooked_mesh_decode_v2_base: validated empty chain")
		storage.meshes[index] = chain.lods[0].view
	}
	base := Cooked_Mesh_Bundle {
		meshes       = storage.meshes[:len(bundle.meshes)],
		vertex_count = bundle.vertex_count,
		index_count  = bundle.index_count,
	}
	return base, {}, true
}

@(private)
_cooked_mesh_records :: proc(
	bytes: []u8,
	records: []Cooked_Mesh_Record,
	vertex_count, index_count: u32,
) -> (
	Cooked_Mesh_Result,
	bool,
) {
	previous_id: Mesh_Id
	previous_vertex, previous_index: u32
	for index in 0 ..< len(records) {
		offset := COOKED_MESH_HEADER_SIZE + index * COOKED_MESH_RECORD_SIZE
		record := _cooked_mesh_record(bytes, offset)
		if record.id == 0 ||
		   record.id <= previous_id ||
		   record.vertex_count == 0 ||
		   record.index_count == 0 ||
		   record.index_count % 3 != 0 {
			return {fault = .Invalid_Record, offset = u32(offset), mesh = record.id}, false
		}
		vertex_end := u64(record.first_vertex) + u64(record.vertex_count)
		index_end := u64(record.first_index) + u64(record.index_count)
		if record.first_vertex != previous_vertex ||
		   record.first_index != previous_index ||
		   vertex_end > u64(vertex_count) ||
		   index_end > u64(index_count) ||
		   !bounds_valid(record.bounds) {
			return {fault = .Invalid_Record, offset = u32(offset), mesh = record.id}, false
		}
		records[index] = record
		previous_id = record.id
		previous_vertex = u32(vertex_end)
		previous_index = u32(index_end)
	}
	if previous_vertex != vertex_count || previous_index != index_count {
		return {fault = .Invalid_Record, offset = 12}, false
	}
	return {}, true
}

@(private)
_cooked_mesh_record :: proc(bytes: []u8, offset: int) -> Cooked_Mesh_Record {
	result: Cooked_Mesh_Record
	result.id = Mesh_Id(_cooked_mesh_u32(bytes, offset))
	result.first_vertex = _cooked_mesh_u32(bytes, offset + 4)
	result.vertex_count = _cooked_mesh_u32(bytes, offset + 8)
	result.first_index = _cooked_mesh_u32(bytes, offset + 12)
	result.index_count = _cooked_mesh_u32(bytes, offset + 16)
	for axis in 0 ..< 3 {
		result.bounds.minimum[axis] = _cooked_mesh_f32(bytes, offset + 20 + axis * 4)
		result.bounds.maximum[axis] = _cooked_mesh_f32(bytes, offset + 32 + axis * 4)
	}
	return result
}

@(private)
_cooked_mesh_vertices :: proc(bytes: []u8, offset: int, vertices: []Vertex) {
	for index in 0 ..< len(vertices) {
		base := offset + index * COOKED_MESH_VERTEX_SIZE
		for axis in 0 ..< 3 {
			vertices[index].position[axis] = _cooked_mesh_f32(bytes, base + axis * 4)
			vertices[index].normal[axis] = _cooked_mesh_f32(bytes, base + 12 + axis * 4)
		}
		vertices[index].scalar = _cooked_mesh_f32(bytes, base + 24)
		vertices[index].uv[0] = _cooked_mesh_f32(bytes, base + 28)
		vertices[index].uv[1] = _cooked_mesh_f32(bytes, base + 32)
	}
}

@(private)
_cooked_mesh_indices :: proc(bytes: []u8, offset: int, indices: []u32) {
	for index in 0 ..< len(indices) {
		indices[index] = _cooked_mesh_u32(bytes, offset + index * size_of(u32))
	}
}

@(private)
_cooked_mesh_views :: proc(
	storage: Cooked_Mesh_Storage,
	records: []Cooked_Mesh_Record,
	vertex_count, index_count: u32,
) -> (
	Cooked_Mesh_Bundle,
	Cooked_Mesh_Result,
	bool,
) {
	for index in 0 ..< len(records) {
		record := records[index]
		vertices := storage.vertices[record.first_vertex:record.first_vertex + record.vertex_count]
		indices := storage.indices[record.first_index:record.first_index + record.index_count]
		mesh := Mesh_View{record.id, vertices, indices, .Triangles, record.bounds}
		if !mesh_validate(mesh) {
			return _cooked_mesh_fail(.Invalid_Mesh, index * COOKED_MESH_RECORD_SIZE, record.id)
		}
		storage.meshes[index] = mesh
	}
	bundle := Cooked_Mesh_Bundle{storage.meshes[:len(records)], vertex_count, index_count}
	return bundle, {}, true
}

@(private)
_cooked_mesh_u32 :: proc(bytes: []u8, offset: int) -> u32 {
	assert(offset >= 0, "_cooked_mesh_u32: negative offset")
	assert(offset + size_of(u32) <= len(bytes), "_cooked_mesh_u32: truncated value")
	return(
		u32(bytes[offset]) |
		u32(bytes[offset + 1]) << 8 |
		u32(bytes[offset + 2]) << 16 |
		u32(bytes[offset + 3]) << 24 \
	)
}

@(private)
_cooked_mesh_f32 :: proc(bytes: []u8, offset: int) -> f32 {
	return transmute(f32)_cooked_mesh_u32(bytes, offset)
}

@(private)
_cooked_mesh_fail :: proc(
	fault: Cooked_Mesh_Fault,
	offset: int,
	mesh: Mesh_Id,
) -> (
	Cooked_Mesh_Bundle,
	Cooked_Mesh_Result,
	bool,
) {
	return {}, {fault = fault, offset = u32(max(offset, 0)), mesh = mesh}, false
}

#assert(COOKED_MESH_VERTEX_SIZE == 36)
#assert(COOKED_MESH_RECORD_SIZE == 5 * size_of(u32) + 6 * size_of(f32))
