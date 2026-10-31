// Package imsh is the gallery's cooked mesh format: the one bounded,
// little-endian layout that tools/meshcook writes and the gallery reads.
//
// The source glTF is converted exactly once, at cook time (ROS basis, decimated,
// quantized), so the runtime never parses JSON or walks a node graph. Every
// count is checked against a named limit and the exact file length before any
// section is read, which keeps a corrupted or truncated asset an operating
// error rather than an out-of-bounds read.
//
// Layout (all little-endian):
//
//	Header  60 bytes   magic u32, version u16, submesh_count u16, vertex_count u32,
//	                   index_count u32, index_u16 u8, pad [3]u8, bounds_min [3]f32,
//	                   bounds_max [3]f32, uv_min [2]f32, uv_max [2]f32
//	Submesh 16 bytes   index_offset u32, index_count u32, base_color [4]u8, flags u8,
//	                   roughness u8, texture_slot i8, pad u8
//	Vertex  16 bytes   position [3]u16 unorm in bounds, normal [2]i16 octahedral,
//	                   uv [2]u16 unorm in uv range, scalar u16 unorm
//	Index    2 bytes   u16
package imsh

import "core:encoding/endian"
import "core:math"

// MAGIC is the bytes 'I' 'M' 'S' 'H' read as a little-endian u32.
MAGIC :: u32(0x48534D49)
VERSION :: u16(1)
HEADER_SIZE :: 60
SUBMESH_SIZE :: 16
VERTEX_SIZE :: 16
INDEX_SIZE :: 2
SUBMESH_MAX :: 8
// VERTEX_MAX is the u16 index ceiling; the format has no u32 index path.
VERTEX_MAX :: 65_535
INDEX_MAX :: 3 * 65_536
// FILE_BYTE_MAX keeps every cooked asset under the repository's 1 MiB
// provenance threshold.
FILE_BYTE_MAX :: 1_000_000

Error :: enum u8 {
	None,
	Too_Small,
	Too_Large,
	Bad_Magic,
	Bad_Version,
	Bad_Counts,
	Size_Mismatch,
	Bad_Bounds,
	Bad_Submesh,
	Bad_Index,
	Buffer_Too_Small,
}

Submesh_Flag :: enum u8 {
	Textured,
	Vertex_Color,
}
Submesh_Flags :: bit_set[Submesh_Flag;u8]

Submesh :: struct {
	index_offset: u32,
	index_count:  u32,
	base_color:   [4]u8,
	flags:        Submesh_Flags,
	roughness:    u8,
	texture_slot: i8,
}

Info :: struct {
	vertex_count:  u32,
	index_count:   u32,
	submesh_count: u16,
	bounds_min:    [3]f32,
	bounds_max:    [3]f32,
	uv_min:        [2]f32,
	uv_max:        [2]f32,
	submeshes:     [SUBMESH_MAX]Submesh,
}

// Vertex mirrors gfx.Gpu_3D_Vertex field for field so the gallery can copy
// without this package importing gfx (the cooker must stay graphics-free).
// A vertex-colored submesh stores linear RGB as uv = {r, g}, scalar = b.
Vertex :: struct {
	position: [3]f32,
	normal:   [3]f32,
	scalar:   f32,
	uv:       [2]f32,
}

file_size :: proc(submesh_count, vertex_count, index_count: int) -> int {
	assert(submesh_count >= 0 && vertex_count >= 0, "imsh.file_size: negative count")
	assert(index_count >= 0, "imsh.file_size: negative index count")
	return(
		HEADER_SIZE +
		SUBMESH_SIZE * submesh_count +
		VERTEX_SIZE * vertex_count +
		INDEX_SIZE * index_count \
	)
}

@(private)
read_f32 :: proc(data: []u8, offset: int) -> f32 {
	assert(offset >= 0 && offset + 4 <= len(data), "imsh.read_f32: out of range")
	return transmute(f32)endian.unchecked_get_u32le(data[offset:])
}

@(private)
write_f32 :: proc(data: []u8, offset: int, value: f32) {
	assert(offset >= 0 && offset + 4 <= len(data), "imsh.write_f32: out of range")
	_ = endian.put_u32(data[offset:], .Little, transmute(u32)value)
}

@(private)
finite :: proc(value: f32) -> bool {
	class := math.classify(value)
	return class != .Inf && class != .Neg_Inf && class != .NaN
}

@(private)
decode_range :: proc(data: []u8, info: ^Info) -> Error {
	assert(info != nil && len(data) >= HEADER_SIZE, "imsh.decode_range: invalid header")
	for axis in 0 ..< 3 {
		info.bounds_min[axis] = read_f32(data, 20 + 4 * axis)
		info.bounds_max[axis] = read_f32(data, 32 + 4 * axis)
		low, high := info.bounds_min[axis], info.bounds_max[axis]
		if !finite(low) || !finite(high) || low > high do return .Bad_Bounds
	}
	for axis in 0 ..< 2 {
		info.uv_min[axis] = read_f32(data, 44 + 4 * axis)
		info.uv_max[axis] = read_f32(data, 52 + 4 * axis)
		low, high := info.uv_min[axis], info.uv_max[axis]
		if !finite(low) || !finite(high) || low > high do return .Bad_Bounds
	}
	return .None
}

@(private)
decode_submeshes :: proc(data: []u8, info: ^Info) -> Error {
	assert(info != nil, "imsh.decode_submeshes: nil info")
	assert(int(info.submesh_count) <= SUBMESH_MAX, "imsh.decode_submeshes: count unchecked")
	for index in 0 ..< int(info.submesh_count) {
		offset := HEADER_SIZE + SUBMESH_SIZE * index
		submesh := Submesh {
			index_offset = endian.unchecked_get_u32le(data[offset:]),
			index_count  = endian.unchecked_get_u32le(data[offset + 4:]),
			base_color   = {
				data[offset + 8],
				data[offset + 9],
				data[offset + 10],
				data[offset + 11],
			},
			flags        = transmute(Submesh_Flags)data[offset + 12],
			roughness    = data[offset + 13],
			texture_slot = i8(data[offset + 14]),
		}
		if submesh.index_count == 0 || submesh.index_count % 3 != 0 do return .Bad_Submesh
		if submesh.index_offset % 3 != 0 do return .Bad_Submesh
		if u64(submesh.index_offset) + u64(submesh.index_count) > u64(info.index_count) {
			return .Bad_Submesh
		}
		if submesh.flags - {.Textured, .Vertex_Color} != {} do return .Bad_Submesh
		if submesh.texture_slot < -1 do return .Bad_Submesh
		info.submeshes[index] = submesh
	}
	return .None
}

// decode_info validates the header, every count, the exact file length, and
// each submesh range. Only after it returns .None may the vertex and index
// sections be decoded.
decode_info :: proc(data: []u8) -> (info: Info, err: Error) {
	if len(data) < HEADER_SIZE do return {}, .Too_Small
	if len(data) > FILE_BYTE_MAX do return {}, .Too_Large
	if endian.unchecked_get_u32le(data[0:]) != MAGIC do return {}, .Bad_Magic
	if endian.unchecked_get_u16le(data[4:]) != VERSION || data[16] != 1 do return {}, .Bad_Version
	info.submesh_count = endian.unchecked_get_u16le(data[6:])
	info.vertex_count = endian.unchecked_get_u32le(data[8:])
	info.index_count = endian.unchecked_get_u32le(data[12:])
	counts_ok :=
		info.submesh_count >= 1 &&
		info.submesh_count <= SUBMESH_MAX &&
		info.vertex_count >= 3 &&
		info.vertex_count <= VERTEX_MAX &&
		info.index_count >= 3 &&
		info.index_count <= INDEX_MAX &&
		info.index_count % 3 == 0
	if !counts_ok do return {}, .Bad_Counts
	expected := file_size(int(info.submesh_count), int(info.vertex_count), int(info.index_count))
	if len(data) != expected do return {}, .Size_Mismatch
	if range_err := decode_range(data, &info); range_err != .None do return {}, range_err
	if sub_err := decode_submeshes(data, &info); sub_err != .None do return {}, sub_err
	return info, .None
}

@(private)
unorm16 :: proc(value: u16, low, high: f32) -> f32 {
	return low + (f32(value) / 65535) * (high - low)
}

@(private)
quantize_unorm16 :: proc(value, low, high: f32) -> u16 {
	assert(low <= high, "imsh.quantize_unorm16: inverted range")
	if high <= low do return 0
	t := clamp((value - low) / (high - low), 0, 1)
	return u16(t * 65535 + 0.5)
}

// oct_encode maps a unit normal onto the octahedron and unfolds the lower
// hemisphere, giving two snorm16 values with near-uniform angular error.
oct_encode :: proc(normal: [3]f32) -> [2]i16 {
	length := abs(normal.x) + abs(normal.y) + abs(normal.z)
	if length <= 0 || !finite(length) do return {0, 0}
	n := normal / length
	x, y := n.x, n.y
	if n.z < 0 {
		x = (1 - abs(n.y)) * (1 if n.x >= 0 else -1)
		y = (1 - abs(n.x)) * (1 if n.y >= 0 else -1)
	}
	return {i16(clamp(x, -1, 1) * 32767), i16(clamp(y, -1, 1) * 32767)}
}

oct_decode :: proc(encoded: [2]i16) -> [3]f32 {
	x := f32(encoded.x) / 32767
	y := f32(encoded.y) / 32767
	v := [3]f32{x, y, 1 - abs(x) - abs(y)}
	t := max(-v.z, 0)
	v.x += -t if v.x >= 0 else t
	v.y += -t if v.y >= 0 else t
	length := math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if length <= 0 do return {0, 0, 1}
	return v / length
}

decode_vertices :: proc(data: []u8, info: Info, out: []Vertex) -> Error {
	assert(
		len(data) ==
		file_size(int(info.submesh_count), int(info.vertex_count), int(info.index_count)),
		"imsh.decode_vertices: info does not describe data",
	)
	assert(info.vertex_count <= VERTEX_MAX, "imsh.decode_vertices: unchecked count")
	if len(out) < int(info.vertex_count) do return .Buffer_Too_Small
	base := HEADER_SIZE + SUBMESH_SIZE * int(info.submesh_count)
	for index in 0 ..< int(info.vertex_count) {
		offset := base + VERTEX_SIZE * index
		vertex: Vertex
		for axis in 0 ..< 3 {
			raw := endian.unchecked_get_u16le(data[offset + 2 * axis:])
			vertex.position[axis] = unorm16(raw, info.bounds_min[axis], info.bounds_max[axis])
		}
		normal := [2]i16 {
			i16(endian.unchecked_get_u16le(data[offset + 6:])),
			i16(endian.unchecked_get_u16le(data[offset + 8:])),
		}
		vertex.normal = oct_decode(normal)
		for axis in 0 ..< 2 {
			raw := endian.unchecked_get_u16le(data[offset + 10 + 2 * axis:])
			vertex.uv[axis] = unorm16(raw, info.uv_min[axis], info.uv_max[axis])
		}
		vertex.scalar = f32(endian.unchecked_get_u16le(data[offset + 14:])) / 65535
		out[index] = vertex
	}
	return .None
}

decode_indices :: proc(data: []u8, info: Info, out: []u32) -> Error {
	assert(
		len(data) ==
		file_size(int(info.submesh_count), int(info.vertex_count), int(info.index_count)),
		"imsh.decode_indices: info does not describe data",
	)
	assert(info.index_count <= INDEX_MAX, "imsh.decode_indices: unchecked count")
	if len(out) < int(info.index_count) do return .Buffer_Too_Small
	base :=
		HEADER_SIZE + SUBMESH_SIZE * int(info.submesh_count) + VERTEX_SIZE * int(info.vertex_count)
	for index in 0 ..< int(info.index_count) {
		value := u32(endian.unchecked_get_u16le(data[base + INDEX_SIZE * index:]))
		if value >= info.vertex_count do return .Bad_Index
		out[index] = value
	}
	return .None
}

@(private)
vertex_ranges :: proc(vertices: []Vertex) -> (low, high: [3]f32, uv_low, uv_high: [2]f32) {
	assert(len(vertices) > 0, "imsh.vertex_ranges: empty vertices")
	low, high = vertices[0].position, vertices[0].position
	uv_low, uv_high = vertices[0].uv, vertices[0].uv
	for vertex in vertices {
		for axis in 0 ..< 3 {
			low[axis] = min(low[axis], vertex.position[axis])
			high[axis] = max(high[axis], vertex.position[axis])
		}
		for axis in 0 ..< 2 {
			uv_low[axis] = min(uv_low[axis], vertex.uv[axis])
			uv_high[axis] = max(uv_high[axis], vertex.uv[axis])
		}
	}
	return
}

@(private)
encode_header :: proc(
	out: []u8,
	submesh_count, vertex_count, index_count: int,
	vertices: []Vertex,
) {
	assert(len(out) >= HEADER_SIZE, "imsh.encode_header: short output")
	assert(len(vertices) == vertex_count, "imsh.encode_header: vertex count mismatch")
	_ = endian.put_u32(out[0:], .Little, MAGIC)
	_ = endian.put_u16(out[4:], .Little, VERSION)
	_ = endian.put_u16(out[6:], .Little, u16(submesh_count))
	_ = endian.put_u32(out[8:], .Little, u32(vertex_count))
	_ = endian.put_u32(out[12:], .Little, u32(index_count))
	out[16] = 1
	low, high, uv_low, uv_high := vertex_ranges(vertices)
	for axis in 0 ..< 3 {
		write_f32(out, 20 + 4 * axis, low[axis])
		write_f32(out, 32 + 4 * axis, high[axis])
	}
	for axis in 0 ..< 2 {
		write_f32(out, 44 + 4 * axis, uv_low[axis])
		write_f32(out, 52 + 4 * axis, uv_high[axis])
	}
}

@(private)
encode_vertex :: proc(
	out: []u8,
	offset: int,
	vertex: Vertex,
	low, high: [3]f32,
	uv_low, uv_high: [2]f32,
) {
	assert(offset + VERTEX_SIZE <= len(out), "imsh.encode_vertex: out of range")
	assert(finite(vertex.scalar), "imsh.encode_vertex: non-finite scalar")
	for axis in 0 ..< 3 {
		raw := quantize_unorm16(vertex.position[axis], low[axis], high[axis])
		_ = endian.put_u16(out[offset + 2 * axis:], .Little, raw)
	}
	normal := oct_encode(vertex.normal)
	_ = endian.put_u16(out[offset + 6:], .Little, u16(normal.x))
	_ = endian.put_u16(out[offset + 8:], .Little, u16(normal.y))
	for axis in 0 ..< 2 {
		raw := quantize_unorm16(vertex.uv[axis], uv_low[axis], uv_high[axis])
		_ = endian.put_u16(out[offset + 10 + 2 * axis:], .Little, raw)
	}
	_ = endian.put_u16(out[offset + 14:], .Little, quantize_unorm16(vertex.scalar, 0, 1))
}

// encode writes a complete file. Bounds and uv range are derived from the
// vertices, so the caller cannot describe a range the data does not fill.
encode :: proc(
	submeshes: []Submesh,
	vertices: []Vertex,
	indices: []u32,
	allocator := context.allocator,
) -> (
	[]u8,
	Error,
) {
	counts_ok :=
		len(submeshes) >= 1 &&
		len(submeshes) <= SUBMESH_MAX &&
		len(vertices) >= 3 &&
		len(vertices) <= VERTEX_MAX &&
		len(indices) >= 3 &&
		len(indices) <= INDEX_MAX &&
		len(indices) % 3 == 0
	if !counts_ok do return nil, .Bad_Counts
	size := file_size(len(submeshes), len(vertices), len(indices))
	if size > FILE_BYTE_MAX do return nil, .Too_Large
	for value in indices {
		if int(value) >= len(vertices) do return nil, .Bad_Index
	}
	out := make([]u8, size, allocator)
	encode_header(out, len(submeshes), len(vertices), len(indices), vertices)
	for submesh, index in submeshes {
		offset := HEADER_SIZE + SUBMESH_SIZE * index
		_ = endian.put_u32(out[offset:], .Little, submesh.index_offset)
		_ = endian.put_u32(out[offset + 4:], .Little, submesh.index_count)
		for channel in 0 ..< 4 do out[offset + 8 + channel] = submesh.base_color[channel]
		out[offset + 12] = transmute(u8)submesh.flags
		out[offset + 13] = submesh.roughness
		out[offset + 14] = u8(submesh.texture_slot)
	}
	low, high, uv_low, uv_high := vertex_ranges(vertices)
	base := HEADER_SIZE + SUBMESH_SIZE * len(submeshes)
	for vertex, index in vertices {
		encode_vertex(out, base + VERTEX_SIZE * index, vertex, low, high, uv_low, uv_high)
	}
	base += VERTEX_SIZE * len(vertices)
	for value, index in indices {
		_ = endian.put_u16(out[base + INDEX_SIZE * index:], .Little, u16(value))
	}
	if _, err := decode_info(out); err != .None {
		delete(out, allocator)
		return nil, err
	}
	return out, .None
}
