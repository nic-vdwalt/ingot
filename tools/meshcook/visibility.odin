package meshcook

import "core:math"
import "core:math/linalg"

// Some generated meshes are built from nested thin-walled shells: every
// surface point has several layers a few millimetres apart. A cluster cell is
// far coarser than that gap, so clustering mixes the layers and the cooked
// surface z-fights between them. source_keep_visible drops every triangle
// that no outside viewer can see before clustering runs.
//
// Visibility is sampled by orthographic depth renders from directions spread
// evenly over the sphere. A triangle survives when any of its corners or its
// centroid lies within VISIBILITY_DEPTH_SLACK of the front-most depth at that
// pixel in any view. Testing sample points against the depth buffer, rather
// than requiring a triangle to own a pixel, keeps sub-pixel slivers on the
// outer surface.
VISIBILITY_VIEWS :: 128
VISIBILITY_RESOLUTION :: 1536
// Fraction of the bounding diameter. Must sit below the gap between nested
// layers (about 0.2% of the diameter on the gallery anvil) and above the
// depth error of sampling a pixel-centre depth at a corner.
VISIBILITY_DEPTH_SLACK :: f32(0.0006)

@(private)
Visibility_View :: struct {
	right:   [3]f32,
	up:      [3]f32,
	forward: [3]f32,
}

// visibility_view returns the basis for view `index` of `count`, on a
// Fibonacci sphere so the directions cover it evenly and deterministically.
@(private)
visibility_view :: proc(index, count: int) -> Visibility_View {
	assert(count > 0 && index >= 0 && index < count, "visibility_view: index out of range")
	golden := f32(math.PI) * (3 - math.sqrt(f32(5)))
	z := 1 - 2 * (f32(index) + 0.5) / f32(count)
	ring := math.sqrt(max(1 - z * z, 0))
	angle := golden * f32(index)
	forward := [3]f32{ring * math.cos(angle), ring * math.sin(angle), z}
	helper := [3]f32{0, 0, 1} if abs(forward.z) < 0.9 else [3]f32{1, 0, 0}
	right := linalg.normalize(linalg.cross(helper, forward))
	return {right = right, up = linalg.cross(forward, right), forward = forward}
}

@(private)
edge_function :: proc(a, b, p: [2]f32) -> f32 {
	return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
}

// visibility_render fills `depth` with the nearest depth per pixel for one
// view. `screen` holds each vertex as {pixel x, pixel y, depth}.
@(private)
visibility_render :: proc(src: ^Source, screen: [][3]f32, depth: []f32) {
	for &value in depth do value = max(f32)
	edge := VISIBILITY_RESOLUTION
	for t := 0; t < len(src.indices); t += 3 {
		a := screen[src.indices[t]]
		b := screen[src.indices[t + 1]]
		c := screen[src.indices[t + 2]]
		area := edge_function(a.xy, b.xy, c.xy)
		if abs(area) < 1e-12 do continue
		x0 := max(int(math.floor(min(a.x, b.x, c.x))), 0)
		x1 := min(int(math.ceil(max(a.x, b.x, c.x))), edge - 1)
		y0 := max(int(math.floor(min(a.y, b.y, c.y))), 0)
		y1 := min(int(math.ceil(max(a.y, b.y, c.y))), edge - 1)
		for y in y0 ..= y1 {
			for x in x0 ..= x1 {
				p := [2]f32{f32(x) + 0.5, f32(y) + 0.5}
				w0 := edge_function(b.xy, c.xy, p) / area
				w1 := edge_function(c.xy, a.xy, p) / area
				w2 := 1 - w0 - w1
				if w0 < 0 || w1 < 0 || w2 < 0 do continue
				z := w0 * a.z + w1 * b.z + w2 * c.z
				slot := y * edge + x
				if z < depth[slot] do depth[slot] = z
			}
		}
	}
}

@(private)
visibility_sample :: proc(depth: []f32, point: [3]f32, slack: f32) -> bool {
	x := int(point.x)
	y := int(point.y)
	if x < 0 || y < 0 || x >= VISIBILITY_RESOLUTION || y >= VISIBILITY_RESOLUTION do return false
	return point.z <= depth[y * VISIBILITY_RESOLUTION + x] + slack
}

// source_triangle_visibility marks each source triangle seen from outside.
source_triangle_visibility :: proc(src: ^Source, visible: []bool) {
	assert(len(visible) * 3 == len(src.indices), "source_triangle_visibility: length mismatch")
	center := (src.bounds_min + src.bounds_max) * 0.5
	radius := max(linalg.length(src.bounds_max - src.bounds_min) * 0.5, 1e-6)
	// Slightly inside the edge so a touching vertex still maps to a pixel.
	scale := f32(VISIBILITY_RESOLUTION) * 0.499 / radius
	slack := VISIBILITY_DEPTH_SLACK * 2 * radius
	screen := make([][3]f32, len(src.positions), context.temp_allocator)
	depth := make([]f32, VISIBILITY_RESOLUTION * VISIBILITY_RESOLUTION, context.temp_allocator)
	for &flag in visible do flag = false
	half := f32(VISIBILITY_RESOLUTION) * 0.5
	for view_index in 0 ..< VISIBILITY_VIEWS {
		view := visibility_view(view_index, VISIBILITY_VIEWS)
		for position, v in src.positions {
			local := position - center
			screen[v] = {
				linalg.dot(local, view.right) * scale + half,
				linalg.dot(local, view.up) * scale + half,
				linalg.dot(local, view.forward),
			}
		}
		visibility_render(src, screen, depth)
		for t := 0; t < len(src.indices); t += 3 {
			if visible[t / 3] do continue
			a := screen[src.indices[t]]
			b := screen[src.indices[t + 1]]
			c := screen[src.indices[t + 2]]
			centroid := (a + b + c) / 3
			if visibility_sample(depth, centroid, slack) ||
			   visibility_sample(depth, a, slack) ||
			   visibility_sample(depth, b, slack) ||
			   visibility_sample(depth, c, slack) {
				visible[t / 3] = true
			}
		}
	}
}

// source_keep_visible removes hidden triangles and the vertices only they
// used, keeping submesh order, and refreshes the bounds. It returns the
// number of triangles removed.
source_keep_visible :: proc(src: ^Source) -> int {
	assert(src != nil && len(src.indices) % 3 == 0, "source_keep_visible: bad source")
	visible := make([]bool, len(src.indices) / 3, context.temp_allocator)
	source_triangle_visibility(src, visible)
	remap := make([]i32, len(src.positions), context.temp_allocator)
	for &value in remap do value = -1
	kept: Source
	for part in src.submeshes {
		offset := len(kept.indices)
		for t := part.index_offset; t < part.index_offset + part.index_count; t += 3 {
			if !visible[t / 3] do continue
			for corner in src.indices[t:t + 3] {
				if remap[corner] < 0 {
					remap[corner] = i32(len(kept.positions))
					append(&kept.positions, src.positions[corner])
					append(&kept.normals, src.normals[corner])
					append(&kept.uvs, src.uvs[corner])
					append(&kept.colors, src.colors[corner])
					append(&kept.submesh_of, u8(len(kept.submeshes)))
				}
				append(&kept.indices, u32(remap[corner]))
			}
		}
		count := len(kept.indices) - offset
		if count == 0 do continue
		append(&kept.submeshes, Source_Submesh {
			index_offset = offset,
			index_count = count,
			material = part.material,
			has_color = part.has_color,
		})
	}
	removed := (len(src.indices) - len(kept.indices)) / 3
	if len(kept.indices) == 0 do return 0
	kept.bounds_min = kept.positions[0]
	kept.bounds_max = kept.positions[0]
	for p in kept.positions {
		kept.bounds_min = linalg.min(kept.bounds_min, p)
		kept.bounds_max = linalg.max(kept.bounds_max, p)
	}
	delete(src.positions)
	delete(src.normals)
	delete(src.uvs)
	delete(src.colors)
	delete(src.submesh_of)
	delete(src.indices)
	delete(src.submeshes)
	src^ = kept
	return removed
}
