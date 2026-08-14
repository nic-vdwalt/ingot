#+build !js
package gfx

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "core:time"
import "ingot:testx"

INGOT_GPU3D_FUZZ_ITER :: #config(INGOT_GPU3D_FUZZ_ITER, 500)
INGOT_GPU3D_FUZZ_SEED :: #config(INGOT_GPU3D_FUZZ_SEED, 0)

@(private = "file")
gpu3d_fuzz_scalar :: proc(p: ^testx.Prng, minimum, maximum: f32) -> f32 {
	assert(p != nil, "gpu3d_fuzz_scalar: nil PRNG")
	assert(minimum <= maximum, "gpu3d_fuzz_scalar: reversed range")
	fraction := f32(testx.next_u64(p) & 0xFFFFFF) / f32(0xFFFFFF)
	result := minimum + (maximum - minimum) * fraction
	assert(_f32_is_finite(result), "gpu3d_fuzz_scalar: non-finite result")
	return result
}

@(private = "file")
gpu3d_fuzz_sphere :: proc(t: ^testing.T, p: ^testx.Prng) -> bool {
	radius := gpu3d_fuzz_scalar(p, 0.01, 100)
	rings := u32(testx.int_range(p, 2, 33))
	slices := u32(testx.int_range(p, 3, 65))
	vertices := make([dynamic]Gpu_3D_Vertex, context.temp_allocator)
	indices := make([dynamic]u32, context.temp_allocator)
	_sphere_mesh_geometry(radius, rings, slices, &vertices, &indices)
	ok := len(vertices) == int((rings + 1) * (slices + 1))
	ok &&= len(indices) == int(rings * slices * 6)
	for vertex in vertices {
		position_length := math.sqrt(linalg.dot(vertex.position, vertex.position))
		normal_length := math.sqrt(linalg.dot(vertex.normal, vertex.normal))
		ok &&= abs(position_length - radius) <= max(radius * 1e-4, f32(1e-5))
		ok &&= abs(normal_length - 1) <= 1e-4
		ok &&= vertex.uv.x >= 0 && vertex.uv.x <= 1
		ok &&= vertex.uv.y >= 0 && vertex.uv.y <= 1
		if !ok do break
	}
	for index in indices {
		ok &&= int(index) < len(vertices)
		if !ok do break
	}
	testing.expect(t, ok, "generated sphere violated its geometry contract")
	return ok
}

@(private = "file")
gpu3d_fuzz_geometry :: proc(t: ^testing.T, p: ^testx.Prng) -> bool {
	vertex_count := testx.int_range(p, 1, 65)
	vertices := make([]Gpu_3D_Vertex, vertex_count, context.temp_allocator)
	primitive := Gpu_Primitive(testx.int_range(p, 0, 3))
	stride := 1
	if primitive == .Lines do stride = 2
	if primitive == .Triangles do stride = 3
	primitive_count := testx.int_range(p, 1, 65)
	indices := make([]u32, primitive_count * stride, context.temp_allocator)
	for &index in indices do index = u32(testx.int_range(p, 0, vertex_count))
	ok := _gpu_3d_geometry_valid(vertices, indices, primitive)
	if !ok {
		testing.expect(t, false, "valid generated geometry was rejected")
		return false
	}
	corrupt := testx.int_range(p, 0, len(indices))
	indices[corrupt] = u32(vertex_count)
	ok = !_gpu_3d_geometry_valid(vertices, indices, primitive)
	testing.expect(t, ok, "out-of-range generated index was accepted")
	return ok
}

@(private = "file")
gpu3d_fuzz_camera :: proc(t: ^testing.T, p: ^testx.Prng) -> bool {
	camera := Camera3D {
		position   = {-10, 0, 0},
		target     = {},
		up         = CAMERA_WORLD_UP,
		fovy       = gpu3d_fuzz_scalar(p, 10, 150),
		projection = CameraProjection(testx.int_range(p, 0, 2)),
	}
	if camera.projection == .ORTHOGRAPHIC do camera.fovy = gpu3d_fuzz_scalar(p, 1, 100)
	width := i32(testx.int_range(p, 1, 4097))
	height := i32(testx.int_range(p, 1, 4097))
	frustum := camera_frustum(camera, width, height)
	ray := screen_to_world_ray({f32(width) / 2, f32(height) / 2}, camera, width, height)
	distance := gpu3d_fuzz_scalar(p, 0.2, 900)
	center := ray.origin + ray.direction * distance
	radius := min(gpu3d_fuzz_scalar(p, 0.01, 10), distance / 2)
	hit, hit_ok := intersect_sphere(ray, {center = center, radius = radius})
	ok := hit_ok && abs(hit.distance - (distance - radius)) <= max(distance * 1e-4, f32(1e-4))
	ok &&= frustum_contains_point(frustum, center)
	bounds := Bounds_3D {
		minimum = center - radius,
		maximum = center + radius,
	}
	ok &&= frustum_intersects_bounds(frustum, bounds)
	behind := Sphere_3D {
		center = ray.origin - ray.direction * distance,
		radius = radius,
	}
	_, behind_hit := intersect_sphere(ray, behind)
	ok &&= !behind_hit
	testing.expect(t, ok, "camera, frustum, and picking contracts diverged")
	return ok
}

@(private = "file")
gpu3d_fuzz_handles :: proc(t: ^testing.T, p: ^testx.Prng) -> bool {
	resources: Gpu_3D_Resources
	context_id := u32(2)
	entries: [GPU_3D_MAX_MESHES]Gpu_3D_Mesh_Entry
	live: [GPU_3D_MAX_MESHES]Gpu_Mesh
	for _ in 0 ..< 64 {
		index := testx.int_range(p, 0, GPU_3D_MAX_MESHES)
		slot := &resources.meshes[index]
		stale := live[index]
		if slot.occupied {
			slot.occupied = false
			slot.entry = nil
			live[index] = {}
			testing.expect(t, _gpu_3d_mesh_slot(context_id, &resources, stale) == nil)
		} else {
			slot.generation = _resource_generation_next(slot.generation)
			slot.entry = &entries[index]
			slot.occupied = true
			live[index] = {
				id = _resource_handle_make_context(context_id, index, slot.generation),
			}
			testing.expect(t, _gpu_3d_mesh_slot(context_id, &resources, live[index]) == slot)
			if stale.id != 0 do testing.expect(t, _gpu_3d_mesh_slot(context_id, &resources, stale) == nil)
		}
	}
	return !testing.failed(t)
}

@(test)
gpu_3d_deterministic_simulation :: proc(t: ^testing.T) {
	seed := u64(INGOT_GPU3D_FUZZ_SEED)
	if seed == 0 do seed = u64(time.now()._nsec)
	log.infof("gpu_3d_dts seed=%d iterations=%d", seed, INGOT_GPU3D_FUZZ_ITER)
	prng := testx.prng_make(seed)
	for iteration in 0 ..< INGOT_GPU3D_FUZZ_ITER {
		ok := gpu3d_fuzz_sphere(t, &prng)
		ok &&= gpu3d_fuzz_geometry(t, &prng)
		ok &&= gpu3d_fuzz_camera(t, &prng)
		ok &&= gpu3d_fuzz_handles(t, &prng)
		if !ok {
			log.errorf("gpu_3d_dts FAILED seed=%d iteration=%d", seed, iteration)
			return
		}
		free_all(context.temp_allocator)
	}
}
