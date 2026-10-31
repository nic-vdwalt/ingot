// meshcook converts a binary glTF (.glb) into the gallery's bounded IMSH mesh
// plus a downsized JPEG base-color texture.
//
// Usage:
//
//	meshcook <in.glb> <out_dir> [-inspect] [-max-triangles:N] [-max-texture:N]
//	         [-albedo:<image>] [-name:<stem>] [-keep-hidden]
//
// The conversion runs once at cook time so the gallery never parses glTF at
// runtime (docs/rendering.md: importers convert at the import/cook boundary).
// stb_image cannot decode WebP, which EXT_texture_webp assets embed, so
// -albedo accepts a pre-decoded PNG/JPEG of the base-color image instead.
// Triangles no outside viewer can see are dropped before clustering
// (visibility.odin); -keep-hidden disables that.
package meshcook

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

EXIT_OK :: 0
EXIT_FAILED :: 1
EXIT_USAGE :: 2

Options :: struct {
	input:         string,
	output_dir:    string,
	inspect:       bool,
	max_triangles: int,
	max_texture:   int,
	albedo:        string,
	name:          string,
	keep_hidden:   bool,
}

parse_arguments :: proc(args: []string) -> (options: Options, ok: bool) {
	options.max_triangles = COOK_TRIANGLE_DEFAULT
	options.max_texture = COOK_TEXTURE_EDGE_DEFAULT
	options.name = "planet"
	positional := 0
	for arg in args {
		switch {
		case arg == "-inspect":
			options.inspect = true
		case arg == "-keep-hidden":
			options.keep_hidden = true
		case strings.has_prefix(arg, "-max-triangles:"):
			options.max_triangles = strconv.parse_int(arg[len("-max-triangles:"):]) or_return
		case strings.has_prefix(arg, "-max-texture:"):
			options.max_texture = strconv.parse_int(arg[len("-max-texture:"):]) or_return
		case strings.has_prefix(arg, "-albedo:"):
			options.albedo = arg[len("-albedo:"):]
		case strings.has_prefix(arg, "-name:"):
			options.name = arg[len("-name:"):]
		case strings.has_prefix(arg, "-"):
			return {}, false
		case positional == 0:
			options.input = arg
			positional += 1
		case positional == 1:
			options.output_dir = arg
			positional += 1
		case:
			return {}, false
		}
	}
	if options.input == "" do return {}, false
	if !options.inspect && options.output_dir == "" do return {}, false
	if options.max_triangles < 12 || options.max_triangles > imsh_triangle_max() do return {}, false
	if options.max_texture < 16 || options.max_texture > COOK_TEXTURE_EDGE_MAX do return {}, false
	return options, options.name != ""
}

usage :: proc() {
	fmt.eprintln(
		"usage: meshcook <in.glb> <out_dir> [-inspect] [-max-triangles:N] " +
		"[-max-texture:N] [-albedo:<image>] [-name:<stem>] [-keep-hidden]",
	)
}

inspect :: proc(glb: ^Glb, src: ^Source) {
	assert(glb != nil && src != nil, "inspect: nil argument")
	doc := &glb.doc
	fmt.printfln(
		"glb: bin %d bytes, %d nodes, %d meshes, %d materials, %d images",
		len(glb.bin),
		len(doc.nodes),
		len(doc.meshes),
		len(doc.materials),
		len(doc.images),
	)
	for mesh, index in doc.meshes {
		for primitive in mesh.primitives {
			attributes := primitive.attributes
			fmt.printfln(
				"mesh %d: POSITION=%v NORMAL=%v TEXCOORD_0=%v COLOR_0=%v indices=%v material=%v",
				index,
				attributes.POSITION,
				attributes.NORMAL,
				attributes.TEXCOORD_0,
				attributes.COLOR_0,
				primitive.indices,
				primitive.material,
			)
		}
	}
	for material, index in doc.materials {
		pbr := material.pbrMetallicRoughness
		fmt.printfln(
			"material %d: factor=%v baseColorTexture=%v roughness=%v",
			index,
			pbr.baseColorFactor,
			pbr.baseColorTexture,
			pbr.roughnessFactor,
		)
	}
	for image, index in doc.images {
		fmt.printfln("image %d: %s bufferView=%v", index, image.mimeType, image.bufferView)
	}
	fmt.printfln(
		"source: %d vertices, %d triangles, %d submeshes, bounds %v .. %v (ROS)",
		len(src.positions),
		len(src.indices) / 3,
		len(src.submeshes),
		src.bounds_min,
		src.bounds_max,
	)
}

imsh_triangle_max :: proc() -> int {
	return 65_536
}

@(private)
cook_texture_bytes :: proc(
	glb: ^Glb,
	src: ^Source,
	options: Options,
) -> (
	encoded: []u8,
	err: Cook_Error,
) {
	assert(glb != nil && src != nil, "cook_texture_bytes: nil argument")
	if options.albedo != "" {
		data, read_err := os.read_entire_file(options.albedo, context.allocator)
		if read_err != nil do return nil, .Texture_Missing
		return data, .None
	}
	material := src.submeshes[0].material
	bytes, mime, ok := gltf_base_color_image(glb, material)
	if !ok do return nil, .None
	if mime != "image/png" && mime != "image/jpeg" do return nil, .Texture_Unsupported
	return bytes, .None
}

write_file :: proc(dir, name: string, data: []u8) -> bool {
	assert(len(data) > 0, "write_file: empty data")
	path, join_err := filepath.join({dir, name}, context.temp_allocator)
	if join_err != nil do return false
	if err := os.write_entire_file(path, data); err != nil {
		fmt.eprintfln("meshcook: write %s failed: %v", path, err)
		return false
	}
	fmt.printfln("wrote %s (%d bytes)", path, len(data))
	return true
}

run :: proc(options: Options) -> int {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return EXIT_FAILED
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	bytes, read_err := os.read_entire_file(options.input, context.allocator)
	if read_err != nil {
		fmt.eprintfln("meshcook: read %s failed: %v", options.input, read_err)
		return EXIT_FAILED
	}
	glb, glb_err := glb_parse(bytes)
	if glb_err != .None {
		fmt.eprintfln("meshcook: invalid glb: %v", glb_err)
		return EXIT_FAILED
	}
	src: Source
	if gather_err := source_gather(&glb, &src); gather_err != .None {
		fmt.eprintfln("meshcook: unsupported content: %v", gather_err)
		return EXIT_FAILED
	}
	inspect(&glb, &src)
	if options.inspect do return EXIT_OK
	texture_source, texture_err := cook_texture_bytes(&glb, &src, options)
	if texture_err != .None {
		fmt.eprintfln("meshcook: texture: %v (pass -albedo:<png|jpg> for WebP)", texture_err)
		return EXIT_FAILED
	}
	textured := len(texture_source) > 0
	if !options.keep_hidden {
		removed := source_keep_visible(&src)
		fmt.printfln(
			"visible: %d triangles kept, %d hidden removed",
			len(src.indices) / 3,
			removed,
		)
	}
	cooked: Cooked
	if cook_err := cook_mesh(&glb, &src, options.max_triangles, textured, &cooked);
	   cook_err != .None {
		fmt.eprintfln("meshcook: cook failed: %v", cook_err)
		return EXIT_FAILED
	}
	fmt.printfln(
		"cooked: grid %d, %d vertices, %d triangles, %d submeshes",
		cooked.grid,
		len(cooked.vertices),
		len(cooked.indices) / 3,
		len(cooked.submeshes),
	)
	mesh_name := fmt.tprintf("%s.imsh", options.name)
	if !write_file(options.output_dir, mesh_name, cooked.file_bytes) do return EXIT_FAILED
	if textured {
		jpeg, edge, err := cook_texture(texture_source, options.max_texture)
		if err != .None {
			fmt.eprintfln("meshcook: texture cook failed: %v", err)
			return EXIT_FAILED
		}
		fmt.printfln("texture: %d px edge", edge)
		texture_name := fmt.tprintf("%s_albedo.jpg", options.name)
		if !write_file(options.output_dir, texture_name, jpeg) do return EXIT_FAILED
	}
	return EXIT_OK
}

main :: proc() {
	options, ok := parse_arguments(os.args[1:])
	if !ok {
		usage()
		os.exit(EXIT_USAGE)
	}
	os.exit(run(options))
}
