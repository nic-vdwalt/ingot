#+build !js
package asset

import "core:testing"

@(test)
mesh_view_rejects_out_of_range_indices :: proc(t: ^testing.T) {
	vertices := [3]Vertex{}
	indices := [?]u32{0, 1, 3}
	mesh := Mesh_View {
		id        = 1,
		vertices  = vertices[:],
		indices   = indices[:],
		primitive = .Triangles,
		bounds    = {{0, 0, 0}, {1, 1, 1}},
	}
	testing.expect(t, !mesh_validate(mesh))
}

@(test)
mesh_buffer_exposes_only_written_storage :: proc(t: ^testing.T) {
	vertices := [8]Vertex{}
	indices := [12]u32{}
	mesh := Mesh_Buffer {
		id           = 7,
		vertices     = vertices[:],
		indices      = indices[:],
		vertex_count = 3,
		index_count  = 3,
		primitive    = .Triangles,
		bounds       = {{0, 0, 0}, {1, 1, 1}},
	}
	view, ok := mesh_view(&mesh)
	testing.expect(t, ok)
	testing.expect_value(t, len(view.vertices), 3)
	testing.expect_value(t, len(view.indices), 3)
}

@(test)
mesh_reset_clears_written_ranges :: proc(t: ^testing.T) {
	mesh := Mesh_Buffer {
		vertex_count = 3,
		index_count  = 3,
		bounds       = {{-1, -1, -1}, {1, 1, 1}},
	}
	mesh_reset(&mesh)
	testing.expect_value(t, mesh.vertex_count, 0)
	testing.expect_value(t, mesh.index_count, 0)
}
