package meshcook

import "core:encoding/endian"
import "core:encoding/json"
import "core:math/linalg"

// Bounds on every input-derived quantity. Exceeding any of them is an
// operating error reported to the user; the cook never trusts a count it read.
GLB_BYTE_MAX :: 64 * 1024 * 1024
GLB_JSON_BYTE_MAX :: 4 * 1024 * 1024
GLB_NODE_MAX :: 1024
GLB_PRIMITIVE_MAX :: 16
GLB_ACCESSOR_ELEMENT_MAX :: 4 * 1024 * 1024

GLB_MAGIC :: u32(0x46546C67)
GLB_CHUNK_JSON :: u32(0x4E4F534A)
GLB_CHUNK_BIN :: u32(0x004E4942)

GL_BYTE :: 5120
GL_UNSIGNED_BYTE :: 5121
GL_UNSIGNED_SHORT :: 5123
GL_UNSIGNED_INT :: 5125
GL_FLOAT :: 5126
GL_TRIANGLES :: 4

Glb_Error :: enum u8 {
	None,
	Too_Small,
	Too_Large,
	Bad_Magic,
	Bad_Version,
	Bad_Length,
	Bad_Chunk,
	Bad_Json,
	Missing_Bin,
	Too_Many_Nodes,
	Node_Cycle,
	Bad_Node,
	Too_Many_Primitives,
	Bad_Accessor,
	Unsupported_Accessor,
	Unsupported_Primitive,
	Missing_Position,
}

Gltf_Accessor :: struct {
	bufferView:    int,
	byteOffset:    int,
	componentType: int,
	normalized:    bool,
	count:         int,
	type:          string,
}

Gltf_Buffer_View :: struct {
	buffer:     int,
	byteOffset: int,
	byteLength: int,
	byteStride: int,
}

Gltf_Attributes :: struct {
	POSITION:   Maybe(int),
	NORMAL:     Maybe(int),
	TEXCOORD_0: Maybe(int),
	COLOR_0:    Maybe(int),
}

Gltf_Primitive :: struct {
	attributes: Gltf_Attributes,
	indices:    Maybe(int),
	material:   Maybe(int),
	mode:       Maybe(int),
}

Gltf_Mesh :: struct {
	name:       string,
	primitives: []Gltf_Primitive,
}

Gltf_Node :: struct {
	name:        string,
	mesh:        Maybe(int),
	children:    []int,
	transform:   []f32 `json:"matrix"`,
	translation: []f32,
	rotation:    []f32,
	scale:       []f32,
}

Gltf_Texture_Ref :: struct {
	index: int,
}

Gltf_Pbr :: struct {
	baseColorFactor:  []f32,
	baseColorTexture: Maybe(Gltf_Texture_Ref),
	roughnessFactor:  Maybe(f32),
	metallicFactor:   Maybe(f32),
}

Gltf_Material :: struct {
	name:                 string,
	pbrMetallicRoughness: Gltf_Pbr,
}

Gltf_Webp_Source :: struct {
	source: int,
}

Gltf_Texture_Extensions :: struct {
	EXT_texture_webp: Maybe(Gltf_Webp_Source),
}

Gltf_Texture :: struct {
	source:     Maybe(int),
	extensions: Gltf_Texture_Extensions,
}

Gltf_Image :: struct {
	bufferView: Maybe(int),
	mimeType:   string,
	uri:        string,
}

Gltf_Scene :: struct {
	nodes: []int,
}

Gltf :: struct {
	accessors:   []Gltf_Accessor,
	bufferViews: []Gltf_Buffer_View,
	meshes:      []Gltf_Mesh,
	nodes:       []Gltf_Node,
	scenes:      []Gltf_Scene,
	scene:       Maybe(int),
	materials:   []Gltf_Material,
	textures:    []Gltf_Texture,
	images:      []Gltf_Image,
}

Glb :: struct {
	doc: Gltf,
	bin: []u8,
}

// glb_parse validates the container and decodes the JSON chunk. The returned
// document borrows `bytes` for the BIN chunk; JSON strings and arrays live in
// `allocator` (callers use an arena so a failed parse frees in one step).
glb_parse :: proc(bytes: []u8, allocator := context.allocator) -> (glb: Glb, err: Glb_Error) {
	if len(bytes) < 20 do return {}, .Too_Small
	if len(bytes) > GLB_BYTE_MAX do return {}, .Too_Large
	if endian.unchecked_get_u32le(bytes[0:]) != GLB_MAGIC do return {}, .Bad_Magic
	if endian.unchecked_get_u32le(bytes[4:]) != 2 do return {}, .Bad_Version
	if int(endian.unchecked_get_u32le(bytes[8:])) != len(bytes) do return {}, .Bad_Length
	json_length := int(endian.unchecked_get_u32le(bytes[12:]))
	if endian.unchecked_get_u32le(bytes[16:]) != GLB_CHUNK_JSON do return {}, .Bad_Chunk
	if json_length <= 0 || json_length > GLB_JSON_BYTE_MAX do return {}, .Bad_Chunk
	if 20 + json_length > len(bytes) do return {}, .Bad_Chunk
	json_bytes := bytes[20:20 + json_length]
	if json.unmarshal(json_bytes, &glb.doc, allocator = allocator) != nil do return {}, .Bad_Json
	bin_header := 20 + json_length
	if bin_header + 8 > len(bytes) do return {}, .Missing_Bin
	bin_length := int(endian.unchecked_get_u32le(bytes[bin_header:]))
	if endian.unchecked_get_u32le(bytes[bin_header + 4:]) != GLB_CHUNK_BIN do return {}, .Missing_Bin
	if bin_length < 0 || bin_header + 8 + bin_length > len(bytes) do return {}, .Bad_Chunk
	glb.bin = bytes[bin_header + 8:bin_header + 8 + bin_length]
	if len(glb.doc.nodes) > GLB_NODE_MAX do return {}, .Too_Many_Nodes
	return glb, .None
}

Accessor_View :: struct {
	data:       []u8,
	count:      int,
	components: int,
	component:  int,
	normalized: bool,
	stride:     int,
}

@(private)
type_components :: proc(type: string) -> int {
	switch type {
	case "SCALAR":
		return 1
	case "VEC2":
		return 2
	case "VEC3":
		return 3
	case "VEC4":
		return 4
	}
	return 0
}

@(private)
component_size :: proc(component: int) -> int {
	switch component {
	case GL_BYTE, GL_UNSIGNED_BYTE:
		return 1
	case GL_UNSIGNED_SHORT:
		return 2
	case GL_UNSIGNED_INT, GL_FLOAT:
		return 4
	}
	return 0
}

// accessor_view resolves an accessor to a bounds-checked byte window. Every
// later element read stays inside `data`, so a hostile offset or count is
// rejected here rather than discovered as a fault mid-cook.
accessor_view :: proc(glb: ^Glb, index: int) -> (view: Accessor_View, err: Glb_Error) {
	assert(glb != nil, "accessor_view: nil glb")
	if index < 0 || index >= len(glb.doc.accessors) do return {}, .Bad_Accessor
	accessor := glb.doc.accessors[index]
	if accessor.bufferView < 0 || accessor.bufferView >= len(glb.doc.bufferViews) {
		return {}, .Bad_Accessor
	}
	buffer_view := glb.doc.bufferViews[accessor.bufferView]
	if buffer_view.buffer != 0 do return {}, .Unsupported_Accessor
	components := type_components(accessor.type)
	size := component_size(accessor.componentType)
	if components == 0 || size == 0 do return {}, .Unsupported_Accessor
	if accessor.count <= 0 || accessor.count > GLB_ACCESSOR_ELEMENT_MAX do return {}, .Bad_Accessor
	element := components * size
	stride := buffer_view.byteStride if buffer_view.byteStride > 0 else element
	if stride < element || stride > 252 do return {}, .Bad_Accessor
	start := i64(buffer_view.byteOffset) + i64(accessor.byteOffset)
	view_end := i64(buffer_view.byteOffset) + i64(buffer_view.byteLength)
	end := start + i64(accessor.count - 1) * i64(stride) + i64(element)
	if buffer_view.byteOffset < 0 || accessor.byteOffset < 0 do return {}, .Bad_Accessor
	if end > view_end || view_end > i64(len(glb.bin)) do return {}, .Bad_Accessor
	return {
			data = glb.bin[start:end],
			count = accessor.count,
			components = components,
			component = accessor.componentType,
			normalized = accessor.normalized,
			stride = stride,
		},
		.None
}

// accessor_read returns component `c` of element `i` as f32, applying the
// glTF normalization rules for integer components.
accessor_read :: proc(view: Accessor_View, i, c: int) -> f32 {
	assert(i >= 0 && i < view.count, "accessor_read: element out of range")
	assert(c >= 0 && c < view.components, "accessor_read: component out of range")
	offset := i * view.stride + c * component_size(view.component)
	bytes := view.data[offset:]
	switch view.component {
	case GL_FLOAT:
		return transmute(f32)endian.unchecked_get_u32le(bytes)
	case GL_UNSIGNED_BYTE:
		value := f32(bytes[0])
		return value / 255 if view.normalized else value
	case GL_BYTE:
		value := f32(i8(bytes[0]))
		return max(value / 127, -1) if view.normalized else value
	case GL_UNSIGNED_SHORT:
		value := f32(endian.unchecked_get_u16le(bytes))
		return value / 65535 if view.normalized else value
	case GL_UNSIGNED_INT:
		return f32(endian.unchecked_get_u32le(bytes))
	}
	return 0
}

accessor_read_index :: proc(view: Accessor_View, i: int) -> u32 {
	assert(i >= 0 && i < view.count, "accessor_read_index: element out of range")
	assert(view.components == 1, "accessor_read_index: not scalar")
	bytes := view.data[i * view.stride:]
	switch view.component {
	case GL_UNSIGNED_BYTE:
		return u32(bytes[0])
	case GL_UNSIGNED_SHORT:
		return u32(endian.unchecked_get_u16le(bytes))
	case GL_UNSIGNED_INT:
		return endian.unchecked_get_u32le(bytes)
	}
	return max(u32)
}

@(private)
node_local_matrix :: proc(node: Gltf_Node) -> (matrix[4, 4]f32, bool) {
	if len(node.transform) == 16 {
		result: matrix[4, 4]f32
		// glTF stores matrices column-major.
		for column in 0 ..< 4 {
			for row in 0 ..< 4 {
				result[row, column] = node.transform[column * 4 + row]
			}
		}
		return result, true
	}
	if len(node.transform) != 0 do return {}, false
	translation := [3]f32{0, 0, 0}
	rotation := quaternion128(1)
	scale := [3]f32{1, 1, 1}
	if len(node.translation) == 3 {
		translation = {node.translation[0], node.translation[1], node.translation[2]}
	} else if len(node.translation) != 0 {
		return {}, false
	}
	if len(node.rotation) == 4 {
		rotation = quaternion128(
			quaternion(
				w = node.rotation[3],
				x = node.rotation[0],
				y = node.rotation[1],
				z = node.rotation[2],
			),
		)
	} else if len(node.rotation) != 0 {
		return {}, false
	}
	if len(node.scale) == 3 {
		scale = {node.scale[0], node.scale[1], node.scale[2]}
	} else if len(node.scale) != 0 {
		return {}, false
	}
	return linalg.matrix4_from_trs_f32(translation, rotation, scale), true
}

Mesh_Instance :: struct {
	mesh:  int,
	world: matrix[4, 4]f32,
}

// glb_mesh_instances walks the default scene with an explicit stack (no
// recursion) bounded by GLB_NODE_MAX. A node reached twice is a cycle or a
// shared subtree; both are rejected because neither is needed for this cook.
glb_mesh_instances :: proc(
	glb: ^Glb,
	out: ^[GLB_NODE_MAX]Mesh_Instance,
) -> (
	count: int,
	err: Glb_Error,
) {
	assert(glb != nil && out != nil, "glb_mesh_instances: nil argument")
	Frame :: struct {
		node:   int,
		parent: matrix[4, 4]f32,
	}
	stack: [GLB_NODE_MAX]Frame
	visited: [GLB_NODE_MAX]bool
	depth := 0
	scene_index := glb.doc.scene.? or_else 0
	roots: []int
	if scene_index >= 0 && scene_index < len(glb.doc.scenes) {
		roots = glb.doc.scenes[scene_index].nodes
	}
	for root in roots {
		if depth >= GLB_NODE_MAX do return 0, .Too_Many_Nodes
		stack[depth] = {root, 1}
		depth += 1
	}
	for steps := 0; depth > 0; steps += 1 {
		assert(steps <= GLB_NODE_MAX, "glb_mesh_instances: walk exceeded node bound")
		depth -= 1
		frame := stack[depth]
		if frame.node < 0 || frame.node >= len(glb.doc.nodes) do return 0, .Bad_Node
		if visited[frame.node] do return 0, .Node_Cycle
		visited[frame.node] = true
		node := glb.doc.nodes[frame.node]
		local, local_ok := node_local_matrix(node)
		if !local_ok do return 0, .Bad_Node
		world := frame.parent * local
		if mesh, has_mesh := node.mesh.?; has_mesh {
			if mesh < 0 || mesh >= len(glb.doc.meshes) do return 0, .Bad_Node
			out[count] = {mesh, world}
			count += 1
		}
		for child in node.children {
			if depth >= GLB_NODE_MAX do return 0, .Too_Many_Nodes
			stack[depth] = {child, world}
			depth += 1
		}
	}
	return count, .None
}
