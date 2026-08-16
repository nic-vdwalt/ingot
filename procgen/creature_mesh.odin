package procgen

import asset "../asset"
import "core:math"

CREATURE_MESH_GENERATOR_VERSION :: u32(1)
CREATURE_MESH_HASH_OFFSET :: u64(0xcbf29ce484222325)
CREATURE_MESH_HASH_PRIME :: u64(0x00000100000001b3)
CREATURE_MESH_EPSILON :: f32(0.000001)

Creature_Axis :: enum u8 {
	Positive_X,
	Positive_Y,
	Positive_Z,
}

Creature_Morphology :: struct {
	maturity:       f32,
	stature:        f32,
	bulk:           f32,
	muscle:         f32,
	head_scale:     f32,
	reach:          f32,
	curvature:      f32,
	surface_detail: f32,
}

Creature_Mesh_Profile :: struct {
	head_front_threshold: f32,
	torso_center:         f32,
	influence_falloff:    f32,
	max_deformation:      f32,
	preserve_ground:      bool,
	forward_axis:         Creature_Axis,
	left_axis:            Creature_Axis,
	up_axis:              Creature_Axis,
}

Creature_Mesh_Recipe :: struct {
	source_identity:      u64,
	creature_seed:        u64,
	progression_revision: u64,
	level:                u32,
	morphology:           Creature_Morphology,
	profile:              Creature_Mesh_Profile,
}

Creature_Mesh_Key :: struct {
	source_mesh:       asset.Mesh_Id,
	generator_version: u32,
	fingerprint:       u64,
}

creature_mesh_key :: proc(
	source: asset.Mesh_View,
	recipe: Creature_Mesh_Recipe,
) -> (
	Creature_Mesh_Key,
	bool,
) {
	if !_creature_mesh_validate(source, recipe) do return {}, false
	fingerprint := _creature_hash_u64(CREATURE_MESH_HASH_OFFSET, u64(source.id))
	fingerprint = _creature_hash_u64(fingerprint, u64(CREATURE_MESH_GENERATOR_VERSION))
	fingerprint = _creature_hash_u64(fingerprint, recipe.source_identity)
	fingerprint = _creature_hash_u64(fingerprint, recipe.creature_seed)
	fingerprint = _creature_hash_u64(fingerprint, recipe.progression_revision)
	fingerprint = _creature_hash_u64(fingerprint, u64(recipe.level))
	values := _creature_morphology_values(recipe.morphology)
	for value in values {
		fingerprint = _creature_hash_f32(fingerprint, value)
	}
	fingerprint = _creature_hash_f32(fingerprint, recipe.profile.head_front_threshold)
	fingerprint = _creature_hash_f32(fingerprint, recipe.profile.torso_center)
	fingerprint = _creature_hash_f32(fingerprint, recipe.profile.influence_falloff)
	fingerprint = _creature_hash_f32(fingerprint, recipe.profile.max_deformation)
	fingerprint = _creature_hash_u64(fingerprint, u64(recipe.profile.preserve_ground))
	fingerprint = _creature_hash_u64(fingerprint, u64(recipe.profile.forward_axis))
	fingerprint = _creature_hash_u64(fingerprint, u64(recipe.profile.left_axis))
	fingerprint = _creature_hash_u64(fingerprint, u64(recipe.profile.up_axis))
	return {source.id, CREATURE_MESH_GENERATOR_VERSION, fingerprint}, true
}

creature_mesh_evolve :: proc(
	source: asset.Mesh_View,
	recipe: Creature_Mesh_Recipe,
	destination: ^asset.Mesh_Buffer,
) -> (
	Creature_Mesh_Key,
	bool,
) {
	assert(destination != nil, "creature_mesh_evolve: nil destination")
	asset.mesh_reset(destination)
	key, valid := creature_mesh_key(source, recipe)
	if !valid do return {}, false
	if len(source.vertices) > len(destination.vertices) do return {}, false
	if len(source.indices) > len(destination.indices) do return {}, false
	assert(source.primitive == .Triangles, "creature_mesh_evolve: validated primitive")
	destination.primitive = source.primitive
	minimum_z := f32(0)
	for index in 0 ..< len(source.vertices) {
		vertex := source.vertices[index]
		vertex.position = _creature_mesh_position(vertex.position, source.bounds, recipe)
		vertex.normal = {}
		destination.vertices[index] = vertex
		if index == 0 || vertex.position.z < minimum_z do minimum_z = vertex.position.z
	}
	if recipe.profile.preserve_ground {
		for index in 0 ..< len(source.vertices) {
			destination.vertices[index].position.z -= minimum_z
		}
	}
	copy(destination.indices, source.indices)
	vertices := destination.vertices[:len(source.vertices)]
	if !_creature_mesh_accumulate_normals(source.indices, vertices) {
		asset.mesh_reset(destination)
		return {}, false
	}
	if !_creature_mesh_normalize_normals(vertices) {
		asset.mesh_reset(destination)
		return {}, false
	}
	_creature_mesh_bounds(vertices, &destination.bounds)
	destination.vertex_count = u32(len(source.vertices))
	destination.index_count = u32(len(source.indices))
	_, ok := asset.mesh_view(destination)
	if !ok {
		asset.mesh_reset(destination)
		return {}, false
	}
	return key, true
}

@(private)
_creature_mesh_validate :: proc(source: asset.Mesh_View, recipe: Creature_Mesh_Recipe) -> bool {
	if !asset.mesh_validate(source) || source.primitive != .Triangles do return false
	if recipe.source_identity == 0 do return false
	values := _creature_morphology_values(recipe.morphology)
	for value in values {
		if !_creature_finite(value) || value < 0 || value > 1 do return false
	}
	profile := recipe.profile
	if !_creature_finite(profile.head_front_threshold) do return false
	if profile.head_front_threshold < 0 || profile.head_front_threshold > 1 do return false
	if !_creature_finite(profile.torso_center) do return false
	if profile.torso_center < 0 || profile.torso_center > 1 do return false
	if !_creature_finite(profile.influence_falloff) do return false
	if profile.influence_falloff <= 0 || profile.influence_falloff > 1 do return false
	if !_creature_finite(profile.max_deformation) do return false
	if profile.max_deformation <= 0 || profile.max_deformation > 1 do return false
	if profile.forward_axis != .Positive_X do return false
	if profile.left_axis != .Positive_Y || profile.up_axis != .Positive_Z do return false
	extent := source.bounds.maximum - source.bounds.minimum
	for value in extent {
		if value <= CREATURE_MESH_EPSILON || !_creature_finite(value) do return false
	}
	return true
}

@(private)
_creature_morphology_values :: proc(morphology: Creature_Morphology) -> [8]f32 {
	return {
		morphology.maturity,
		morphology.stature,
		morphology.bulk,
		morphology.muscle,
		morphology.head_scale,
		morphology.reach,
		morphology.curvature,
		morphology.surface_detail,
	}
}

@(private)
_creature_mesh_position :: proc(
	position: asset.Vec3,
	bounds: asset.Bounds_3D,
	recipe: Creature_Mesh_Recipe,
) -> asset.Vec3 {
	extent := bounds.maximum - bounds.minimum
	center := (bounds.minimum + bounds.maximum) * 0.5
	normalized := (position - bounds.minimum) / extent
	morphology := recipe.morphology
	limit := recipe.profile.max_deformation * morphology.maturity
	stature := 1 + (morphology.stature * 2 - 1) * limit
	bulk := 1 + (morphology.bulk * 2 - 1) * limit
	result := position
	result.z = bounds.minimum.z + (position.z - bounds.minimum.z) * stature
	result.x = center.x + (position.x - center.x) * bulk
	result.y = center.y + (position.y - center.y) * bulk
	torso_distance := abs(normalized.x - recipe.profile.torso_center)
	torso_weight := 1 - _creature_smoothstep(0, recipe.profile.influence_falloff, torso_distance)
	muscle_scale := 1 + morphology.muscle * limit * torso_weight
	result.y = center.y + (result.y - center.y) * muscle_scale
	front_weight := _creature_smoothstep(
		recipe.profile.head_front_threshold - recipe.profile.influence_falloff,
		recipe.profile.head_front_threshold,
		normalized.x,
	)
	head_scale := 1 + (morphology.head_scale * 2 - 1) * limit * front_weight
	head_anchor := bounds.minimum.x + extent.x * recipe.profile.head_front_threshold
	result.x = head_anchor + (result.x - head_anchor) * head_scale
	result.y = center.y + (result.y - center.y) * head_scale
	result.z = bounds.minimum.z + (result.z - bounds.minimum.z) * head_scale
	result.x += (normalized.x - recipe.profile.torso_center) * morphology.reach * limit * extent.x
	curve_noise := noise_2d(recipe.creature_seed, normalized.x * 1.5, normalized.z * 1.5)
	result.y += curve_noise * morphology.curvature * limit * extent.y
	detail_noise := noise_2d(
		recipe.creature_seed ~ 0xD1B54A32D192ED03,
		normalized.x * 4 + normalized.z,
		normalized.y * 4 + normalized.z,
	)
	radial_x := position.x - center.x
	radial_y := position.y - center.y
	radial_length := math.sqrt(radial_x * radial_x + radial_y * radial_y)
	if radial_length > CREATURE_MESH_EPSILON {
		detail := detail_noise * morphology.surface_detail * limit * min(extent.x, extent.y)
		result.x += radial_x / radial_length * detail
		result.y += radial_y / radial_length * detail
	}
	return result
}

@(private)
_creature_smoothstep :: proc(edge_a, edge_b, value: f32) -> f32 {
	assert(edge_b > edge_a, "_creature_smoothstep: reversed edges")
	amount := clamp((value - edge_a) / (edge_b - edge_a), f32(0), f32(1))
	return amount * amount * (3 - 2 * amount)
}

@(private)
_creature_mesh_accumulate_normals :: proc(indices: []u32, vertices: []asset.Vertex) -> bool {
	assert(len(indices) % 3 == 0, "_creature_mesh_accumulate_normals: incomplete triangle")
	for triangle in 0 ..< len(indices) / 3 {
		index_a := int(indices[triangle * 3])
		index_b := int(indices[triangle * 3 + 1])
		index_c := int(indices[triangle * 3 + 2])
		if index_a >= len(vertices) || index_b >= len(vertices) || index_c >= len(vertices) {
			return false
		}
		edge_ab := vertices[index_b].position - vertices[index_a].position
		edge_ac := vertices[index_c].position - vertices[index_a].position
		normal := asset.Vec3 {
			edge_ab.y * edge_ac.z - edge_ab.z * edge_ac.y,
			edge_ab.z * edge_ac.x - edge_ab.x * edge_ac.z,
			edge_ab.x * edge_ac.y - edge_ab.y * edge_ac.x,
		}
		length_squared := normal.x * normal.x + normal.y * normal.y + normal.z * normal.z
		if length_squared <= CREATURE_MESH_EPSILON * CREATURE_MESH_EPSILON do return false
		vertices[index_a].normal += normal
		vertices[index_b].normal += normal
		vertices[index_c].normal += normal
	}
	return true
}

@(private)
_creature_mesh_normalize_normals :: proc(vertices: []asset.Vertex) -> bool {
	assert(len(vertices) > 0, "_creature_mesh_normalize_normals: empty vertices")
	for index in 0 ..< len(vertices) {
		normal := vertices[index].normal
		length := math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
		if length <= CREATURE_MESH_EPSILON || !_creature_finite(length) do return false
		vertices[index].normal = normal / length
	}
	return true
}

@(private)
_creature_mesh_bounds :: proc(vertices: []asset.Vertex, bounds: ^asset.Bounds_3D) {
	assert(len(vertices) > 0, "_creature_mesh_bounds: empty vertices")
	assert(bounds != nil, "_creature_mesh_bounds: nil bounds")
	bounds^ = {
		minimum = vertices[0].position,
		maximum = vertices[0].position,
	}
	for index in 1 ..< len(vertices) {
		for axis in 0 ..< 3 {
			bounds.minimum[axis] = min(bounds.minimum[axis], vertices[index].position[axis])
			bounds.maximum[axis] = max(bounds.maximum[axis], vertices[index].position[axis])
		}
	}
}

@(private)
_creature_hash_u64 :: proc(hash, value: u64) -> u64 {
	assert(hash != 0, "_creature_hash_u64: zero hash")
	result := hash
	remaining := value
	for _ in 0 ..< size_of(value) {
		result ~= remaining & 0xff
		result *= CREATURE_MESH_HASH_PRIME
		remaining >>= 8
	}
	assert(remaining == 0, "_creature_hash_u64: incomplete value")
	return result
}

@(private)
_creature_hash_f32 :: proc(hash: u64, value: f32) -> u64 {
	assert(_creature_finite(value), "_creature_hash_f32: non-finite value")
	assert(hash != 0, "_creature_hash_f32: zero hash")
	return _creature_hash_u64(hash, u64(transmute(u32)value))
}

@(private)
_creature_finite :: proc(value: f32) -> bool {
	return !math.is_nan(value) && !math.is_inf(value, 0)
}
