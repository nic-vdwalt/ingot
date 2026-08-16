#+build !js
package asset

import "core:math"
import "core:testing"

_packed_test_quantization :: proc() -> Vertex_Quantization {
	return Vertex_Quantization {
		bounds = {minimum = {-2, -3, 0}, maximum = {5, 1, 9}},
		uv_bounds = {minimum = {0, 0}, maximum = {1, 1}},
	}
}

@(test)
vertex_packed_is_sixteen_bytes :: proc(t: ^testing.T) {
	// The 36 to 16 byte reduction is the whole reason the packed form exists;
	// if a field is added without a plan the ratio silently regresses.
	testing.expect_value(t, size_of(Vertex_Packed), 16)
	testing.expect_value(t, size_of(Vertex), 36)
}

@(test)
vertex_pack_round_trips_within_half_a_step :: proc(t: ^testing.T) {
	quantization := _packed_test_quantization()
	tolerance := vertex_position_tolerance(quantization)
	samples := [?]Vec3 {
		{-2, -3, 0},
		{5, 1, 9},
		{0, 0, 0},
		{1.5, -0.25, 4.125},
		{4.999, 0.999, 8.999},
	}
	for position in samples {
		source := Vertex {
			position = position,
			normal   = {0, 0, 1},
			scalar   = 1.5,
			uv       = {0.25, 0.75},
		}
		restored := vertex_unpack(vertex_pack(source, quantization), quantization)
		for axis in 0 ..< 3 {
			delta := abs(restored.position[axis] - position[axis])
			testing.expectf(
				t,
				delta <= tolerance[axis],
				"axis %v drifted %v beyond %v",
				axis,
				delta,
				tolerance[axis],
			)
		}
	}
}

@(test)
vertex_pack_preserves_normal_direction :: proc(t: ^testing.T) {
	quantization := _packed_test_quantization()
	samples := [?]Vec3 {
		{0, 0, 1},
		{0, 0, -1},
		{1, 0, 0},
		{0, -1, 0},
		{0.57735, 0.57735, 0.57735},
		{-0.57735, 0.57735, -0.57735},
	}
	for normal in samples {
		source := Vertex {
			position = {0, 0, 0},
			normal   = normal,
			scalar   = 0,
			uv       = {0, 0},
		}
		restored := vertex_unpack(vertex_pack(source, quantization), quantization)
		dot :=
			restored.normal[0] * normal[0] +
			restored.normal[1] * normal[1] +
			restored.normal[2] * normal[2]
		// An 8-bit octahedral pair is accurate to roughly two degrees, so a
		// cosine above 0.999 is the honest bar rather than an exact match.
		testing.expectf(t, dot > 0.999, "normal %v decoded to %v", normal, restored.normal)
	}
}

@(test)
vertex_pack_clamps_the_scalar_channel :: proc(t: ^testing.T) {
	quantization := _packed_test_quantization()
	cases := [?]f32{0, 1, 1.5, 2}
	for value in cases {
		source := Vertex {
			position = {0, 0, 0},
			normal   = {0, 0, 1},
			scalar   = value,
			uv       = {0, 0},
		}
		restored := vertex_unpack(vertex_pack(source, quantization), quantization)
		testing.expect(t, abs(restored.scalar - value) <= VERTEX_PACKED_SCALAR_MAX / 255)
	}
	over := Vertex {
		position = {0, 0, 0},
		normal   = {0, 0, 1},
		scalar   = 99,
		uv       = {0, 0},
	}
	restored := vertex_unpack(vertex_pack(over, quantization), quantization)
	testing.expect_value(t, restored.scalar, VERTEX_PACKED_SCALAR_MAX)
}

@(test)
quantization_from_mesh_measures_uv_bounds :: proc(t: ^testing.T) {
	vertices := [3]Vertex {
		{position = {0, 0, 0}, normal = {0, 0, 1}, scalar = 0, uv = {0.25, 0.5}},
		{position = {1, 0, 0}, normal = {0, 0, 1}, scalar = 0, uv = {0.75, 0.5}},
		{position = {0, 1, 0}, normal = {0, 0, 1}, scalar = 0, uv = {0.25, 0.9}},
	}
	indices := [3]u32{0, 1, 2}
	mesh := Mesh_View {
		id = 1,
		vertices = vertices[:],
		indices = indices[:],
		primitive = .Triangles,
		bounds = {minimum = {0, 0, 0}, maximum = {1, 1, 0}},
	}
	quantization, ok := quantization_from_mesh(mesh)
	testing.expect(t, ok)
	testing.expect_value(t, quantization.uv_bounds.minimum, Vec2{0.25, 0.5})
	testing.expect_value(t, quantization.uv_bounds.maximum, Vec2{0.75, 0.9})
	// A measured UV frame means an atlas-repacked mesh keeps full precision
	// instead of spending most of its range on empty margin.
	restored := vertex_unpack(vertex_pack(vertices[2], quantization), quantization)
	testing.expect(t, abs(restored.uv[1] - 0.9) < 1.0e-4)
}

@(test)
quantization_rejects_degenerate_frames :: proc(t: ^testing.T) {
	bad := Vertex_Quantization {
		bounds = {minimum = {1, 0, 0}, maximum = {0, 0, 0}},
	}
	testing.expect(t, !quantization_valid(bad))
	nan := Vertex_Quantization {
		uv_bounds = {minimum = {math.nan_f32(), 0}, maximum = {1, 1}},
	}
	testing.expect(t, !quantization_valid(nan))
}

// A zero-extent axis is legitimate: a flat plane has no thickness. Packing must
// collapse it to a single code rather than divide by zero.
@(test)
vertex_pack_handles_flat_axes :: proc(t: ^testing.T) {
	quantization := Vertex_Quantization {
		bounds = {minimum = {0, 0, 3}, maximum = {1, 1, 3}},
		uv_bounds = {minimum = {0, 0}, maximum = {0, 0}},
	}
	source := Vertex {
		position = {0.5, 0.5, 3},
		normal   = {0, 0, 1},
		scalar   = 0,
		uv       = {0, 0},
	}
	packed := vertex_pack(source, quantization)
	testing.expect_value(t, packed.position[2], u16(0))
	restored := vertex_unpack(packed, quantization)
	testing.expect_value(t, restored.position[2], f32(3))
	testing.expect_value(t, restored.uv, Vec2{0, 0})
}
