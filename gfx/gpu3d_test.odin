#+build !js
// Headless GPU-3D coverage: everything testable without a WebGPU device -
// sphere geometry generation (counts, bounds, normals, UVs, index validity),
// parameter rejection, pool-handle mapping, light normalization, uniform
// layout locks, and instanced-draw chunk arithmetic. On-device behavior
// (depth test, lighting, textures, instancing, per-backend rendering) is
// validated by examples/render_fixture; see docs/rendering.md "GPU 3D
// validation matrix".
package gfx

import "core:math"
import "core:math/linalg"
import "core:testing"
import wg "vendor:wgpu"

// -- _sphere_mesh_geometry -----------------------------------------------------

@(test)
test_sphere_geometry_counts :: proc(t: ^testing.T) {
	cases := [?]struct {
		rings, slices: u32,
	}{{2, 3}, {8, 12}, {16, 24}, {3, 64}}
	for c in cases {
		vertices := make([dynamic]Gpu_3D_Vertex, context.temp_allocator)
		indices := make([dynamic]u32, context.temp_allocator)
		_sphere_mesh_geometry(1, c.rings, c.slices, &vertices, &indices)
		testing.expect_value(t, len(vertices), int((c.rings + 1) * (c.slices + 1)))
		testing.expect_value(t, len(indices), int(c.rings * c.slices * 6))
		// Triangle list: index count divisible by 3.
		testing.expect_value(t, len(indices) % 3, 0)
	}
}

@(test)
test_sphere_geometry_bounds_and_normals :: proc(t: ^testing.T) {
	radius: f32 = 2.5
	vertices := make([dynamic]Gpu_3D_Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	_sphere_mesh_geometry(radius, 8, 12, &vertices, &indices)

	testing.expect_value(t, vertices[0].position, Vector3{0, 0, radius})
	testing.expect(t, abs(vertices[len(vertices) - 1].position.z + radius) < 1e-4)
	equator := vertices[4 * 13].position
	testing.expect(t, abs(equator.z) < 1e-4)

	for v in vertices {
		pos_len := math.sqrt(
			v.position.x * v.position.x +
			v.position.y * v.position.y +
			v.position.z * v.position.z,
		)
		nrm_len := math.sqrt(
			v.normal.x * v.normal.x + v.normal.y * v.normal.y + v.normal.z * v.normal.z,
		)
		// Every vertex lies on the sphere surface; every normal is unit.
		testing.expect(t, abs(pos_len - radius) < 1e-4, "vertex off the sphere surface")
		testing.expect(t, abs(nrm_len - 1) < 1e-4, "non-unit normal")
	}
	// Every index addresses a real vertex.
	for index in indices {
		testing.expect(t, int(index) < len(vertices), "index out of range")
	}
}

@(test)
test_sphere_geometry_winding_faces_outward :: proc(t: ^testing.T) {
	vertices := make([dynamic]Gpu_3D_Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	_sphere_mesh_geometry(1, 8, 12, &vertices, &indices)
	// Skip pole cells because their duplicate vertices form intentional
	// zero-area triangles; every interior face must remain outward and CCW.
	for triangle := 24; triangle < len(indices) - 24; triangle += 3 {
		a := vertices[indices[triangle]].position
		b := vertices[indices[triangle + 1]].position
		c := vertices[indices[triangle + 2]].position
		face := linalg.cross(b - a, c - a)
		if linalg.dot(face, face) <= 1e-12 do continue
		center := (a + b + c) / 3
		testing.expect(t, linalg.dot(face, center) > 0, "sphere triangle faces inward")
	}
}

// -- create_sphere_mesh: parameter/uninitialized rejection ---------------------

@(test)
test_create_sphere_mesh_rejects_headless :: proc(t: ^testing.T) {
	// No device in unit tests (g.initialized == false): must refuse with the
	// invalid handle rather than touching wgpu. Degenerate ring/slice counts
	// are rejected the same way once a device exists.
	mesh, ok := create_sphere_mesh(1, 16, 24)
	testing.expect_value(t, ok, false)
	testing.expect_value(t, mesh.id, u32(0))
}

@(test)
test_gpu_3d_geometry_validation :: proc(t: ^testing.T) {
	vertices := [?]Gpu_3D_Vertex {
		{position = {0, 0, 0}, normal = CAMERA_WORLD_UP, scalar = 0},
		{position = {1, 0, 0}, normal = CAMERA_WORLD_UP, scalar = 0.5},
		{position = {0, 1, 0}, normal = CAMERA_WORLD_UP, scalar = 1},
	}
	triangles := [?]u32{0, 1, 2}
	lines := [?]u32{0, 1, 1, 2}
	points := [?]u32{0, 1, 2}
	bad_index := [?]u32{0, 1, 3}

	testing.expect(t, _gpu_3d_geometry_valid(vertices[:], triangles[:], .Triangles))
	testing.expect(t, _gpu_3d_geometry_valid(vertices[:], lines[:], .Lines))
	testing.expect(t, _gpu_3d_geometry_valid(vertices[:], points[:], .Points))
	testing.expect(t, !_gpu_3d_geometry_valid(vertices[:], lines[:], .Triangles))
	testing.expect(t, !_gpu_3d_geometry_valid(vertices[:], bad_index[:], .Triangles))
	testing.expect(t, !_gpu_3d_geometry_valid(nil, triangles[:], .Triangles))
}

@(test)
test_create_gpu_mesh_rejects_headless :: proc(t: ^testing.T) {
	vertices := [?]Gpu_3D_Vertex {
		{position = {0, 0, 0}, normal = CAMERA_WORLD_UP},
		{position = {1, 0, 0}, normal = CAMERA_WORLD_UP},
		{position = {0, 1, 0}, normal = CAMERA_WORLD_UP},
	}
	indices := [?]u32{0, 1, 2}
	mesh, ok := create_gpu_mesh(vertices[:], indices[:])
	testing.expect_value(t, ok, false)
	testing.expect_value(t, mesh.id, u32(0))
}

@(test)
test_gpu_3d_opaque_overlay_policy :: proc(t: ^testing.T) {
	default := _gpu_3d_material_policy(.Default)
	overlay := _gpu_3d_material_policy(.Opaque_Overlay)
	testing.expect(t, default.blend)
	testing.expect_value(t, default.depth_bias, i32(0))
	testing.expect(t, !overlay.blend)
	testing.expect(t, overlay.depth_write)
	testing.expect_value(t, overlay.depth_compare, wg.CompareFunction.Less)
	testing.expect(t, overlay.depth_bias < 0)
}

@(test)
test_gpu_3d_antialiasing_sample_count :: proc(t: ^testing.T) {
	testing.expect_value(t, _gpu_3d_sample_count(.None), u32(1))
	testing.expect_value(t, _gpu_3d_sample_count(.MSAA_4X), u32(4))
}

@(test)
test_gpu_3d_pipeline_identity_includes_compatibility_fields :: proc(t: ^testing.T) {
	entry := Gpu_3D_Pipeline_Entry {
		format       = .RGBA8Unorm,
		primitive    = .Triangles,
		style        = .Default,
		sample_count = 4,
	}
	testing.expect(t, _gpu_3d_pipeline_matches(entry, .RGBA8Unorm, .Triangles, .Default, 4))
	testing.expect(
		t,
		!_gpu_3d_pipeline_matches(entry, .RGBA8Unorm, .Triangles, .Opaque_Overlay, 4),
	)
	testing.expect(t, !_gpu_3d_pipeline_matches(entry, .RGBA8Unorm, .Triangles, .Default, 1))
}

// -- pool handle mapping -------------------------------------------------------

@(test)
test_gpu_3d_mesh_handle_mapping :: proc(t: ^testing.T) {
	resources: Gpu_3D_Resources
	testing.expect(t, _gpu_3d_mesh_slot(&resources, Gpu_Mesh{}) == nil)

	entry: Gpu_3D_Mesh_Entry
	slot := &resources.meshes[0]
	slot.generation = _resource_generation_next(slot.generation)
	slot.entry = &entry
	slot.occupied = true
	old_mesh := Gpu_Mesh {
		id = _resource_handle_make(0, slot.generation),
	}
	testing.expect(t, _gpu_3d_mesh_slot(&resources, old_mesh) == slot)

	slot.generation = _resource_generation_next(slot.generation)
	new_mesh := Gpu_Mesh {
		id = _resource_handle_make(0, slot.generation),
	}
	testing.expect(t, _gpu_3d_mesh_slot(&resources, old_mesh) == nil)
	testing.expect(t, _gpu_3d_mesh_slot(&resources, new_mesh) == slot)
}

// -- lighting, uniforms, textures, instancing ----------------------------------

@(test)
test_gpu_3d_uniforms_layout_locked :: proc(t: ^testing.T) {
	// The Odin structs are copied raw into the uniform stream and read back
	// through the WGSL views, so their sizes are load-bearing contracts.
	testing.expect(t, size_of(Gpu_3D_Uniforms) >= 208, "uniforms smaller than WGSL view")
	testing.expect_value(t, size_of(Gpu_3D_Uniforms) % 16, 0)
	testing.expect_value(t, size_of(Gpu_3D_Vertex), 36)
	testing.expect_value(t, size_of(Matrix), 64)
	testing.expect_value(
		t,
		size_of(Gpu_3D_Instance_Uniforms),
		GPU_3D_MAX_INSTANCES_PER_DRAW * size_of(Matrix),
	)
	testing.expect(t, size_of(Gpu_3D_Instance_Uniforms) <= 65536, "over uniform-binding floor")
}

@(test)
test_gpu_3d_default_light_matches_legacy_shader :: proc(t: ^testing.T) {
	// These values were the hard-coded shader constants before lighting
	// became configurable; default rendering must stay bit-identical.
	testing.expect_value(t, GPU_3D_DEFAULT_LIGHT.direction, Vector3{0.4, 0.8, 0.3})
	testing.expect_value(t, GPU_3D_DEFAULT_LIGHT.ambient, f32(0.25))
	testing.expect_value(t, GPU_3D_DEFAULT_LIGHT.diffuse, f32(0.75))
}

@(test)
test_light_normalize_contract :: proc(t: ^testing.T) {
	normalized, ok := _light_normalize({direction = {0, 0, 10}, ambient = -1, diffuse = 7})
	testing.expect(t, ok)
	testing.expect_value(t, normalized.direction, Vector3{0, 0, 1})
	testing.expect_value(t, normalized.ambient, f32(0))
	testing.expect_value(t, normalized.diffuse, f32(1))

	kept, kept_ok := _light_normalize({direction = {1, 0, 0}, ambient = 0.4, diffuse = 0.5})
	testing.expect(t, kept_ok)
	testing.expect_value(t, kept.ambient, f32(0.4))
	testing.expect_value(t, kept.diffuse, f32(0.5))

	// Degenerate direction is rejected, not silently defaulted.
	_, zero_ok := _light_normalize({direction = {}, ambient = 0.5, diffuse = 0.5})
	testing.expect(t, !zero_ok)
}

@(test)
test_sphere_mesh_uvs_cover_unit_square :: proc(t: ^testing.T) {
	vertices := make([dynamic]Gpu_3D_Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	_sphere_mesh_geometry(1, 8, 12, &vertices, &indices)
	u_min, v_min := f32(1), f32(1)
	u_max, v_max := f32(0), f32(0)
	for v in vertices {
		testing.expect(t, v.uv.x >= 0 && v.uv.x <= 1, "u outside [0, 1]")
		testing.expect(t, v.uv.y >= 0 && v.uv.y <= 1, "v outside [0, 1]")
		u_min = min(u_min, v.uv.x)
		u_max = max(u_max, v.uv.x)
		v_min = min(v_min, v.uv.y)
		v_max = max(v_max, v.uv.y)
	}
	// The parametric grid must span the full square including the wrap seam.
	testing.expect_value(t, u_min, f32(0))
	testing.expect_value(t, u_max, f32(1))
	testing.expect_value(t, v_min, f32(0))
	testing.expect_value(t, v_max, f32(1))
}

@(test)
test_gpu_3d_chunk_count_boundaries :: proc(t: ^testing.T) {
	testing.expect_value(t, _gpu_3d_chunk_count(0), 0)
	testing.expect_value(t, _gpu_3d_chunk_count(1), 1)
	testing.expect_value(t, _gpu_3d_chunk_count(GPU_3D_MAX_INSTANCES_PER_DRAW - 1), 1)
	testing.expect_value(t, _gpu_3d_chunk_count(GPU_3D_MAX_INSTANCES_PER_DRAW), 1)
	testing.expect_value(t, _gpu_3d_chunk_count(GPU_3D_MAX_INSTANCES_PER_DRAW + 1), 2)
	testing.expect_value(t, _gpu_3d_chunk_count(2 * GPU_3D_MAX_INSTANCES_PER_DRAW + 1), 3)
}

@(test)
test_draw_gpu_mesh_instanced_rejects_headless :: proc(t: ^testing.T) {
	// Without a device there is no active pass; both the nil pass and the
	// empty transform list must be quiet no-ops, never crashes.
	transforms := [?]Matrix{1}
	draw_gpu_mesh_instanced(nil, Gpu_Mesh{}, transforms[:], {})
	pass: Gpu_3D_Pass
	draw_gpu_mesh_instanced(&pass, Gpu_Mesh{}, nil, {})
	testing.expect(t, !pass.active)
}
