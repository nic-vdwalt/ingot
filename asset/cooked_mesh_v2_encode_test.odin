#+build !js
package asset

import "core:testing"

_V2_ENCODE_MAX_BYTES :: 4096

_V2_Encode_Storage :: struct {
	bytes:     [_V2_ENCODE_MAX_BYTES]u8,
	reference: [_V2_ENCODE_MAX_BYTES]u8,
	chains:    [4]Cooked_Mesh_Chain,
	lods:      [8]Mesh_Lod,
	clusters:  [8]Cluster,
	groups:    [4]Cluster_Group,
	vertices:  [64]Vertex,
	indices:   [128]u32,
}

// The encoder and the decoder are only trustworthy together, so the oracle is
// the round trip rather than either side's own opinion of the bytes.
@(test)
cooked_mesh_v2_encode_round_trips_through_the_decoder :: proc(t: ^testing.T) {
	storage := new(_V2_Encode_Storage)
	defer free(storage)
	source_vertices, source_indices, chain := _v2_encode_test_chain(storage, 1)
	size, fault, ok := cooked_mesh_v2_encode({chain}, 0, storage.bytes[:])
	testing.expectf(t, ok, "encode rejected a valid chain with %v", fault.fault)
	expected, _ := cooked_mesh_v2_encoded_size({chain}, 0)
	testing.expect_value(t, size, expected)
	bundle, result, decode_ok := cooked_mesh_v2_decode(
		storage.bytes[:size],
		_v2_encode_test_storage(storage),
	)
	testing.expectf(t, decode_ok, "decode rejected encoder output with %v", result.fault)
	testing.expect_value(t, len(bundle.meshes), 1)
	testing.expect_value(t, bundle.flags, u32(0))
	decoded := bundle.meshes[0]
	testing.expect_value(t, decoded.id, chain.id)
	testing.expect_value(t, decoded.bounds, chain.bounds)
	testing.expect_value(t, decoded.uv_bounds, chain.uv_bounds)
	testing.expect_value(t, len(decoded.lods), len(chain.lods))
	for lod, level in decoded.lods {
		source := chain.lods[level]
		testing.expect_value(t, lod.error, source.error)
		testing.expect_value(t, lod.screen_height_threshold, source.screen_height_threshold)
		testing.expect_value(t, len(lod.view.vertices), len(source.view.vertices))
		testing.expect_value(t, len(lod.view.indices), len(source.view.indices))
		// Unpacked vertices survive exactly; anything less would mean the
		// writer and reader disagree about the layout.
		for vertex, index in lod.view.vertices {
			testing.expect_value(t, vertex, source.view.vertices[index])
		}
		for index, position in lod.view.indices {
			testing.expect_value(t, index, source.view.indices[position])
		}
	}
	testing.expect_value(t, int(bundle.vertex_count), len(source_vertices))
	testing.expect_value(t, int(bundle.index_count), len(source_indices))
}

// Packing is lossy by construction, so the contract is the bound the format
// already publishes rather than equality.
@(test)
cooked_mesh_v2_encode_packed_stays_inside_the_published_tolerance :: proc(t: ^testing.T) {
	storage := new(_V2_Encode_Storage)
	defer free(storage)
	_, _, chain := _v2_encode_test_chain(storage, 1)
	flags := u32(COOKED_MESH_V2_FLAG_PACKED_VERTICES)
	size, fault, ok := cooked_mesh_v2_encode({chain}, flags, storage.bytes[:])
	testing.expectf(t, ok, "packed encode rejected a valid chain with %v", fault.fault)
	// Sixteen bytes a vertex against thirty-six is the whole point of packing.
	unpacked, _ := cooked_mesh_v2_encoded_size({chain}, 0)
	testing.expect(t, size < unpacked)
	bundle, result, decode_ok := cooked_mesh_v2_decode(
		storage.bytes[:size],
		_v2_encode_test_storage(storage),
	)
	testing.expectf(t, decode_ok, "decode rejected packed output with %v", result.fault)
	testing.expect_value(t, bundle.flags, flags)
	tolerance := vertex_position_tolerance({chain.bounds, chain.uv_bounds})
	for lod, level in bundle.meshes[0].lods {
		for vertex, index in lod.view.vertices {
			source := chain.lods[level].view.vertices[index]
			for axis in 0 ..< 3 {
				drift := abs(vertex.position[axis] - source.position[axis])
				testing.expectf(
					t,
					drift <= tolerance[axis],
					"axis %d drifted %v past the %v the format promises",
					axis,
					drift,
					tolerance[axis],
				)
			}
		}
	}
}

// The test writer was assembled independently of the encoder, so agreeing with
// it byte for byte is evidence the encoder follows the format rather than its
// own reading of it.
@(test)
cooked_mesh_v2_encode_matches_the_independent_test_writer :: proc(t: ^testing.T) {
	storage := new(_V2_Encode_Storage)
	defer free(storage)
	reference := _v2_test_bundle(storage.reference[:], nil)
	chain := _v2_encode_test_quad(storage)
	size, fault, ok := cooked_mesh_v2_encode({chain}, 0, storage.bytes[:])
	testing.expectf(t, ok, "encode rejected the reference chain with %v", fault.fault)
	testing.expect_value(t, size, len(reference))
	for value, index in reference {
		testing.expectf(
			t,
			storage.bytes[index] == value,
			"byte %d is %d where the reference writer put %d",
			index,
			storage.bytes[index],
			value,
		)
	}
}

@(test)
cooked_mesh_v2_encode_rejects_what_the_decoder_would :: proc(t: ^testing.T) {
	storage := new(_V2_Encode_Storage)
	defer free(storage)
	_, _, chain := _v2_encode_test_chain(storage, 1)
	_v2_encode_expect_fault(t, storage, {}, 0, .Invalid_Record, "an empty bundle")
	unknown := chain
	_v2_encode_expect_fault(t, storage, {unknown}, 1 << 5, .Invalid_Flags, "an unknown flag")
	// A cluster flag with no DAG, and a DAG with no flag, are both a file that
	// contradicts itself.
	_v2_encode_expect_fault(
		t,
		storage,
		{chain},
		COOKED_MESH_V2_FLAG_CLUSTERS,
		.Invalid_Flags,
		"a cluster flag without clusters",
	)
	zero_id := chain
	zero_id.id = 0
	_v2_encode_expect_fault(t, storage, {zero_id}, 0, .Invalid_Record, "a zero mesh id")
	_, second, second_chain := _v2_encode_test_chain(storage, 2)
	_ = second
	descending := [2]Cooked_Mesh_Chain{second_chain, chain}
	_v2_encode_expect_fault(t, storage, descending[:], 0, .Invalid_Record, "descending mesh ids")
	flat := chain
	flat_lods := storage.lods[:len(chain.lods)]
	copy(flat_lods, chain.lods)
	flat_lods[1].error = flat_lods[0].error
	flat.lods = flat_lods
	_v2_encode_expect_fault(t, storage, {flat}, 0, .Invalid_Lod, "a non-monotonic error")
	rising := chain
	rising_lods := storage.lods[:len(chain.lods)]
	copy(rising_lods, chain.lods)
	rising_lods[1].screen_height_threshold = rising_lods[0].screen_height_threshold
	rising.lods = rising_lods
	_v2_encode_expect_fault(t, storage, {rising}, 0, .Invalid_Lod, "a non-decreasing threshold")
}

@(test)
cooked_mesh_v2_encode_reports_capacity_without_writing :: proc(t: ^testing.T) {
	storage := new(_V2_Encode_Storage)
	defer free(storage)
	_, _, chain := _v2_encode_test_chain(storage, 1)
	size, _, ok := cooked_mesh_v2_encode({chain}, 0, storage.bytes[:])
	testing.expect(t, ok)
	for index in 0 ..< size do storage.bytes[index] = 0xAB
	short, fault, short_ok := cooked_mesh_v2_encode({chain}, 0, storage.bytes[:size - 1])
	testing.expect(t, !short_ok)
	testing.expect_value(t, short, 0)
	testing.expect_value(t, fault.fault, Cooked_Mesh_Fault.Capacity)
	// Nothing may be written when the answer is "not enough room".
	for index in 0 ..< size {
		testing.expect_value(t, storage.bytes[index], u8(0xAB))
	}
}

// _v2_encode_test_chain builds a two-level chain: a unit quad, then a single
// triangle standing in for its simplification.
@(private = "file")
_v2_encode_test_chain :: proc(
	storage: ^_V2_Encode_Storage,
	id: u32,
) -> (
	[]Vertex,
	[]u32,
	Cooked_Mesh_Chain,
) {
	assert(storage != nil, "_v2_encode_test_chain: nil storage")
	positions := [7]Vec3 {
		{0, 0, 0},
		{2, 0, 0},
		{0, 3, 0},
		{2, 3, 1},
		{0, 0, 0},
		{2, 0, 0},
		{0, 3, 0},
	}
	uvs := [7]Vec2{{0, 0}, {1, 0}, {0, 1}, {1, 1}, {0, 0}, {1, 0}, {0, 1}}
	for position, index in positions {
		storage.vertices[index] = {
			position = position,
			normal   = {0, 0, 1},
			scalar   = f32(index) * 0.25,
			uv       = uvs[index],
		}
	}
	source_indices := [9]u32{0, 1, 2, 1, 3, 2, 0, 1, 2}
	for value, index in source_indices do storage.indices[index] = value
	storage.lods[0] = {
		view = {
			id = Mesh_Id(id),
			vertices = storage.vertices[0:4],
			indices = storage.indices[0:6],
			primitive = .Triangles,
			bounds = {{0, 0, 0}, {2, 3, 1}},
		},
		error = 0,
		screen_height_threshold = 1024,
	}
	storage.lods[1] = {
		view = {
			id = Mesh_Id(id),
			vertices = storage.vertices[4:7],
			indices = storage.indices[6:9],
			primitive = .Triangles,
			bounds = {{0, 0, 0}, {2, 3, 1}},
		},
		error = 0.5,
		screen_height_threshold = 256,
	}
	chain := Cooked_Mesh_Chain {
		id        = Mesh_Id(id),
		lods      = storage.lods[0:2],
		bounds    = {{0, 0, 0}, {2, 3, 1}},
		uv_bounds = {{0, 0}, {1, 1}},
	}
	return storage.vertices[0:7], storage.indices[0:9], chain
}

// _v2_encode_test_quad mirrors `_v2_test_bundle` exactly so the two writers can
// be compared byte for byte.
@(private = "file")
_v2_encode_test_quad :: proc(storage: ^_V2_Encode_Storage) -> Cooked_Mesh_Chain {
	assert(storage != nil, "_v2_encode_test_quad: nil storage")
	positions := [7]Vec3 {
		{0, 0, 0},
		{1, 0, 0},
		{0, 1, 0},
		{1, 1, 0},
		{0, 0, 0},
		{1, 0, 0},
		{0, 1, 0},
	}
	for position, index in positions {
		storage.vertices[index] = {
			position = position,
			normal   = {0, 0, 1},
			scalar   = 0,
			uv       = {0, 0},
		}
	}
	source_indices := [9]u32{0, 1, 2, 1, 3, 2, 0, 1, 2}
	for value, index in source_indices do storage.indices[index] = value
	bounds := Bounds_3D{{0, 0, 0}, {1, 1, 0}}
	storage.lods[0] = {
		view = {
			id = 1,
			vertices = storage.vertices[0:4],
			indices = storage.indices[0:6],
			primitive = .Triangles,
			bounds = bounds,
		},
		error = 0,
		screen_height_threshold = 512,
	}
	storage.lods[1] = {
		view = {
			id = 1,
			vertices = storage.vertices[4:7],
			indices = storage.indices[6:9],
			primitive = .Triangles,
			bounds = bounds,
		},
		error = 0.25,
		screen_height_threshold = 64,
	}
	return {id = 1, lods = storage.lods[0:2], bounds = bounds, uv_bounds = {{0, 0}, {1, 1}}}
}

@(private = "file")
_v2_encode_test_storage :: proc(storage: ^_V2_Encode_Storage) -> Cooked_Mesh_V2_Storage {
	assert(storage != nil, "_v2_encode_test_storage: nil storage")
	return {
		meshes = storage.chains[:],
		lods = storage.lods[4:],
		clusters = storage.clusters[:],
		groups = storage.groups[:],
		vertices = storage.vertices[16:],
		indices = storage.indices[16:],
	}
}

@(private = "file")
_v2_encode_expect_fault :: proc(
	t: ^testing.T,
	storage: ^_V2_Encode_Storage,
	meshes: []Cooked_Mesh_Chain,
	flags: u32,
	expected: Cooked_Mesh_Fault,
	label: string,
) {
	assert(t != nil && storage != nil, "_v2_encode_expect_fault: nil argument")
	size, fault, ok := cooked_mesh_v2_encode(meshes, flags, storage.bytes[:])
	testing.expectf(t, !ok, "encode accepted %s", label)
	testing.expect_value(t, size, 0)
	testing.expectf(
		t,
		fault.fault == expected,
		"%s reported %v where %v was expected",
		label,
		fault.fault,
		expected,
	)
}
