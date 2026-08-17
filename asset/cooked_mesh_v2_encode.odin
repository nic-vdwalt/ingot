package asset

// Encoding is the reader in `cooked_mesh_v2.odin` run backwards, and it lives
// beside it so a layout change cannot be made on one side alone. The oracle is
// the round trip: encode, decode, compare. Bytes are written one at a time,
// little-endian, mirroring how the reader takes them apart -- no struct casts,
// so host endianness and struct padding cannot leak into the file.
//
// The production offline writer is `tools/mesh_cook.py`. This exists so a
// procedurally generated mesh can be cooked at runtime without shelling out to
// Python, and the two are checked against each other byte for byte.

// cooked_mesh_v2_encoded_size reports the exact byte count `cooked_mesh_v2_encode`
// will write, so a caller can size storage before committing to the encode.
cooked_mesh_v2_encoded_size :: proc(meshes: []Cooked_Mesh_Chain, flags: u32) -> (int, bool) {
	lod_count, cluster_count, group_count := 0, 0, 0
	vertex_count, index_count := 0, 0
	for mesh in meshes {
		lod_count += len(mesh.lods)
		cluster_count += len(mesh.dag.clusters)
		group_count += len(mesh.dag.groups)
		for lod in mesh.lods {
			vertex_count += len(lod.view.vertices)
			index_count += len(lod.view.indices)
		}
	}
	if len(meshes) == 0 || vertex_count == 0 || index_count == 0 do return 0, false
	vertex_size := COOKED_MESH_V2_VERTEX_SIZE_FAT
	if flags & COOKED_MESH_V2_FLAG_PACKED_VERTICES != 0 {
		vertex_size = COOKED_MESH_V2_VERTEX_SIZE_PACKED
	}
	total :=
		COOKED_MESH_V2_HEADER_SIZE +
		len(meshes) * COOKED_MESH_V2_RECORD_SIZE +
		lod_count * COOKED_MESH_V2_LOD_SIZE +
		cluster_count * COOKED_MESH_V2_CLUSTER_SIZE +
		group_count * COOKED_MESH_V2_GROUP_SIZE +
		vertex_count * vertex_size +
		index_count * 4
	if total > COOKED_MESH_V2_MAX_BYTES do return 0, false
	return total, true
}

// cooked_mesh_v2_encode writes an INGMESH2 bundle into caller storage. It
// refuses everything `cooked_mesh_v2_decode` refuses and reports the same
// `Cooked_Mesh_Fault`, so a producer and a consumer describe a bad bundle
// identically instead of in two private vocabularies. On failure nothing in
// `destination` is meaningful.
cooked_mesh_v2_encode :: proc(
	meshes: []Cooked_Mesh_Chain,
	flags: u32,
	destination: []u8,
) -> (
	int,
	Cooked_Mesh_Result,
	bool,
) {
	if result, ok := _cooked_v2_encode_valid(meshes, flags); !ok do return 0, result, false
	size, size_ok := cooked_mesh_v2_encoded_size(meshes, flags)
	if !size_ok do return 0, {fault = .Capacity}, false
	if len(destination) < size do return 0, {fault = .Capacity}, false
	cursor := _Cooked_V2_Cursor_Out {
		record  = COOKED_MESH_V2_HEADER_SIZE,
		vertex_size = COOKED_MESH_V2_VERTEX_SIZE_FAT,
	}
	if flags & COOKED_MESH_V2_FLAG_PACKED_VERTICES != 0 {
		cursor.vertex_size = COOKED_MESH_V2_VERTEX_SIZE_PACKED
	}
	_cooked_v2_encode_layout(meshes, &cursor)
	_cooked_v2_encode_header(destination, meshes, flags, cursor)
	for mesh in meshes {
		_cooked_v2_encode_mesh(destination, mesh, flags, &cursor)
	}
	assert(cursor.index == size, "cooked_mesh_v2_encode: cursor did not reach the end")
	return size, {}, true
}

COOKED_MESH_V2_VERTEX_SIZE_FAT :: size_of(Vertex)
COOKED_MESH_V2_VERTEX_SIZE_PACKED :: size_of(Vertex_Packed)

// _Cooked_V2_Cursor_Out tracks one write offset per section. The sections are
// filled in parallel rather than in file order because a mesh's records, LODs,
// clusters, vertices and indices are all known at the same moment.
@(private)
_Cooked_V2_Cursor_Out :: struct {
	record:       int,
	lod:          int,
	cluster:      int,
	group:        int,
	vertex:       int,
	index:        int,
	vertex_size:  int,
	first_lod:    u32,
	first_cluster: u32,
	first_group:  u32,
	first_vertex: u32,
	first_index:  u32,
}

@(private)
_cooked_v2_encode_layout :: proc(meshes: []Cooked_Mesh_Chain, cursor: ^_Cooked_V2_Cursor_Out) {
	assert(cursor != nil, "_cooked_v2_encode_layout: nil cursor")
	lod_count, cluster_count, group_count, vertex_count := 0, 0, 0, 0
	for mesh in meshes {
		lod_count += len(mesh.lods)
		cluster_count += len(mesh.dag.clusters)
		group_count += len(mesh.dag.groups)
		for lod in mesh.lods do vertex_count += len(lod.view.vertices)
	}
	cursor.lod = cursor.record + len(meshes) * COOKED_MESH_V2_RECORD_SIZE
	cursor.cluster = cursor.lod + lod_count * COOKED_MESH_V2_LOD_SIZE
	cursor.group = cursor.cluster + cluster_count * COOKED_MESH_V2_CLUSTER_SIZE
	cursor.vertex = cursor.group + group_count * COOKED_MESH_V2_GROUP_SIZE
	cursor.index = cursor.vertex + vertex_count * cursor.vertex_size
}

@(private)
_cooked_v2_encode_header :: proc(
	destination: []u8,
	meshes: []Cooked_Mesh_Chain,
	flags: u32,
	cursor: _Cooked_V2_Cursor_Out,
) {
	assert(len(destination) >= COOKED_MESH_V2_HEADER_SIZE, "_cooked_v2_encode_header: capacity")
	lod_count, cluster_count, group_count := 0, 0, 0
	vertex_count, index_count := 0, 0
	for mesh in meshes {
		lod_count += len(mesh.lods)
		cluster_count += len(mesh.dag.clusters)
		group_count += len(mesh.dag.groups)
		for lod in mesh.lods {
			vertex_count += len(lod.view.vertices)
			index_count += len(lod.view.indices)
		}
	}
	for value, index in COOKED_MESH_V2_MAGIC do destination[index] = value
	_cooked_v2_put_u32(destination, 8, COOKED_MESH_V2_VERSION)
	_cooked_v2_put_u32(destination, 12, u32(len(meshes)))
	_cooked_v2_put_u32(destination, 16, u32(lod_count))
	_cooked_v2_put_u32(destination, 20, u32(cluster_count))
	_cooked_v2_put_u32(destination, 24, u32(group_count))
	_cooked_v2_put_u32(destination, 28, u32(vertex_count))
	_cooked_v2_put_u32(destination, 32, u32(index_count))
	_cooked_v2_put_u32(destination, 36, flags)
	_cooked_v2_put_u32(destination, 40, 0)
	_cooked_v2_put_u32(destination, 44, 0)
}

@(private)
_cooked_v2_encode_mesh :: proc(
	destination: []u8,
	mesh: Cooked_Mesh_Chain,
	flags: u32,
	cursor: ^_Cooked_V2_Cursor_Out,
) {
	assert(cursor != nil, "_cooked_v2_encode_mesh: nil cursor")
	assert(len(mesh.lods) > 0, "_cooked_v2_encode_mesh: empty chain")
	offset := cursor.record
	_cooked_v2_put_u32(destination, offset, u32(mesh.id))
	_cooked_v2_put_u32(destination, offset + 4, cursor.first_lod)
	_cooked_v2_put_u32(destination, offset + 8, u32(len(mesh.lods)))
	_cooked_v2_put_u32(destination, offset + 12, cursor.first_cluster)
	_cooked_v2_put_u32(destination, offset + 16, u32(len(mesh.dag.clusters)))
	_cooked_v2_put_u32(destination, offset + 20, cursor.first_group)
	_cooked_v2_put_u32(destination, offset + 24, u32(len(mesh.dag.groups)))
	for axis in 0 ..< 3 {
		_cooked_v2_put_f32(destination, offset + 28 + axis * 4, mesh.bounds.minimum[axis])
		_cooked_v2_put_f32(destination, offset + 40 + axis * 4, mesh.bounds.maximum[axis])
	}
	for axis in 0 ..< 2 {
		_cooked_v2_put_f32(destination, offset + 52 + axis * 4, mesh.uv_bounds.minimum[axis])
		_cooked_v2_put_f32(destination, offset + 60 + axis * 4, mesh.uv_bounds.maximum[axis])
	}
	cursor.record += COOKED_MESH_V2_RECORD_SIZE
	// The cluster table addresses indices file-globally, because the decoder
	// validates a DAG against the whole file's index count and nests cluster
	// spans inside file-global LOD spans. Capture the base before the LOD walk
	// advances it.
	index_base := cursor.first_index
	quantization := Vertex_Quantization{mesh.bounds, mesh.uv_bounds}
	for lod in mesh.lods do _cooked_v2_encode_lod(destination, lod, flags, quantization, cursor)
	_cooked_v2_encode_dag(destination, mesh.dag, index_base, cursor)
	cursor.first_lod += u32(len(mesh.lods))
	cursor.first_cluster += u32(len(mesh.dag.clusters))
	cursor.first_group += u32(len(mesh.dag.groups))
}

@(private)
_cooked_v2_encode_lod :: proc(
	destination: []u8,
	lod: Mesh_Lod,
	flags: u32,
	quantization: Vertex_Quantization,
	cursor: ^_Cooked_V2_Cursor_Out,
) {
	assert(cursor != nil, "_cooked_v2_encode_lod: nil cursor")
	offset := cursor.lod
	_cooked_v2_put_u32(destination, offset, cursor.first_vertex)
	_cooked_v2_put_u32(destination, offset + 4, u32(len(lod.view.vertices)))
	_cooked_v2_put_u32(destination, offset + 8, cursor.first_index)
	_cooked_v2_put_u32(destination, offset + 12, u32(len(lod.view.indices)))
	_cooked_v2_put_f32(destination, offset + 16, lod.error)
	_cooked_v2_put_f32(destination, offset + 20, lod.screen_height_threshold)
	cursor.lod += COOKED_MESH_V2_LOD_SIZE
	packed := flags & COOKED_MESH_V2_FLAG_PACKED_VERTICES != 0
	for vertex in lod.view.vertices {
		if packed {
			_cooked_v2_put_vertex_packed(destination, cursor.vertex, vertex, quantization)
		} else {
			_cooked_v2_put_vertex_fat(destination, cursor.vertex, vertex)
		}
		cursor.vertex += cursor.vertex_size
	}
	// Indices stay local to their own level's vertex span, exactly as version 1
	// stores them local to a mesh.
	for index in lod.view.indices {
		_cooked_v2_put_u32(destination, cursor.index, index)
		cursor.index += 4
	}
	cursor.first_vertex += u32(len(lod.view.vertices))
	cursor.first_index += u32(len(lod.view.indices))
}

@(private)
_cooked_v2_encode_dag :: proc(
	destination: []u8,
	dag: Cluster_Dag,
	index_base: u32,
	cursor: ^_Cooked_V2_Cursor_Out,
) {
	assert(cursor != nil, "_cooked_v2_encode_dag: nil cursor")
	for cluster in dag.clusters {
		offset := cursor.cluster
		_cooked_v2_put_u32(destination, offset, cluster.first_index + index_base)
		_cooked_v2_put_u32(destination, offset + 4, cluster.index_count)
		for axis in 0 ..< 3 do _cooked_v2_put_f32(destination, offset + 8 + axis * 4, cluster.center[axis])
		_cooked_v2_put_f32(destination, offset + 20, cluster.radius)
		_cooked_v2_put_f32(destination, offset + 24, cluster.error)
		_cooked_v2_put_f32(destination, offset + 28, cluster.parent_error)
		_cooked_v2_put_u32(destination, offset + 32, cluster.group)
		_cooked_v2_put_u32(destination, offset + 36, u32(cluster.level))
		cursor.cluster += COOKED_MESH_V2_CLUSTER_SIZE
	}
	for group in dag.groups {
		offset := cursor.group
		_cooked_v2_put_u32(destination, offset, group.first_child)
		_cooked_v2_put_u32(destination, offset + 4, group.child_count)
		for axis in 0 ..< 3 do _cooked_v2_put_f32(destination, offset + 8 + axis * 4, group.center[axis])
		_cooked_v2_put_f32(destination, offset + 20, group.radius)
		_cooked_v2_put_f32(destination, offset + 24, group.error)
		_cooked_v2_put_u32(destination, offset + 28, u32(group.level))
		cursor.group += COOKED_MESH_V2_GROUP_SIZE
	}
}

@(private)
_cooked_v2_put_vertex_fat :: proc(destination: []u8, offset: int, vertex: Vertex) {
	for axis in 0 ..< 3 do _cooked_v2_put_f32(destination, offset + axis * 4, vertex.position[axis])
	for axis in 0 ..< 3 do _cooked_v2_put_f32(destination, offset + 12 + axis * 4, vertex.normal[axis])
	_cooked_v2_put_f32(destination, offset + 24, vertex.scalar)
	for axis in 0 ..< 2 do _cooked_v2_put_f32(destination, offset + 28 + axis * 4, vertex.uv[axis])
}

@(private)
_cooked_v2_put_vertex_packed :: proc(
	destination: []u8,
	offset: int,
	vertex: Vertex,
	quantization: Vertex_Quantization,
) {
	packed := vertex_pack(vertex, quantization)
	for axis in 0 ..< 3 do _cooked_v2_put_u16(destination, offset + axis * 2, packed.position[axis])
	destination[offset + 6] = u8(packed.normal[0])
	destination[offset + 7] = u8(packed.normal[1])
	for axis in 0 ..< 2 do _cooked_v2_put_u16(destination, offset + 8 + axis * 2, packed.uv[axis])
	destination[offset + 12] = packed.scalar
	// The decoder asserts the padding is zero, so it cannot be left as
	// whatever the caller's storage happened to hold.
	destination[offset + 13] = 0
	destination[offset + 14] = 0
	destination[offset + 15] = 0
}

@(private)
_cooked_v2_put_u16 :: proc(destination: []u8, offset: int, value: u16) {
	assert(offset >= 0, "_cooked_v2_put_u16: negative offset")
	assert(offset + size_of(u16) <= len(destination), "_cooked_v2_put_u16: truncated value")
	destination[offset] = u8(value)
	destination[offset + 1] = u8(value >> 8)
}

@(private)
_cooked_v2_put_u32 :: proc(destination: []u8, offset: int, value: u32) {
	assert(offset >= 0, "_cooked_v2_put_u32: negative offset")
	assert(offset + size_of(u32) <= len(destination), "_cooked_v2_put_u32: truncated value")
	destination[offset] = u8(value)
	destination[offset + 1] = u8(value >> 8)
	destination[offset + 2] = u8(value >> 16)
	destination[offset + 3] = u8(value >> 24)
}

@(private)
_cooked_v2_put_f32 :: proc(destination: []u8, offset: int, value: f32) {
	_cooked_v2_put_u32(destination, offset, transmute(u32)value)
}
