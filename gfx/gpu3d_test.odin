#+build !js
// Headless GPU-3D coverage: everything testable without a WebGPU device —
// sphere geometry generation (counts, bounds, normals, index validity),
// parameter rejection, and pool-handle mapping. On-device behavior (depth
// test, per-backend rendering) is validated by examples/render_fixture; see
// docs/rendering.md "GPU 3D validation matrix".
package gfx

import "core:math"
import "core:testing"

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
