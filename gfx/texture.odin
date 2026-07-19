// ingot:gfx — image/texture support (raylib-named). Covers what the consumer
// apps use: LoadImageFromMemory/LoadTextureFromImage/LoadTexture, UpdateTexture,
// UnloadTexture, and DrawTexture*/DrawTexturePro, plus SetWindowIcon. Textures
// live in their own registry (ids offset above the font-atlas id space) and
// draw through the batch renderer's `image` pipeline. Non-RGBA source formats
// (grayscale, RGB) are expanded to RGBA8 on upload since WebGPU has no RGB8.
package gfx

import "core:math"
import "vendor:glfw"
import stbi "vendor:stb/image"
import wg "vendor:wgpu"

TEX_ID_BASE :: u32(0x4000_0000)

Tex_Entry :: struct {
	tex:     wg.Texture,
	view:    wg.TextureView,
	sampler: wg.Sampler,
	bind:    wg.BindGroup,
	width:   i32,
	height:  i32,
	filter:  TextureFilter,
}

@(private) g_textures: [dynamic]^Tex_Entry

@(private)
get_texture :: proc(id: u32) -> ^Tex_Entry {
	if id < TEX_ID_BASE do return nil
	idx := int(id - TEX_ID_BASE)
	if idx < 0 || idx >= len(g_textures) do return nil
	return g_textures[idx]
}

// _to_rgba expands `src` (width*height, `format` channels) into a freshly
// allocated RGBA8 buffer for WebGPU upload.
@(private)
_to_rgba :: proc(src: [^]byte, w, h: i32, format: PixelFormat) -> []byte {
	n := int(w) * int(h)
	out := make([]byte, n * 4)
	#partial switch format {
	case .UNCOMPRESSED_R8G8B8A8:
		copy(out, src[:n * 4])
	case .UNCOMPRESSED_R8G8B8:
		for i in 0 ..< n {
			out[i * 4 + 0] = src[i * 3 + 0]
			out[i * 4 + 1] = src[i * 3 + 1]
			out[i * 4 + 2] = src[i * 3 + 2]
			out[i * 4 + 3] = 255
		}
	case .UNCOMPRESSED_GRAYSCALE:
		for i in 0 ..< n {
			v := src[i]
			out[i * 4 + 0] = v; out[i * 4 + 1] = v; out[i * 4 + 2] = v; out[i * 4 + 3] = 255
		}
	case .UNCOMPRESSED_GRAY_ALPHA:
		for i in 0 ..< n {
			v := src[i * 2 + 0]
			out[i * 4 + 0] = v; out[i * 4 + 1] = v; out[i * 4 + 2] = v
			out[i * 4 + 3] = src[i * 2 + 1]
		}
	case:
		// unknown/compressed: leave opaque white
		for i in 0 ..< n {
			out[i * 4 + 0] = 255; out[i * 4 + 1] = 255; out[i * 4 + 2] = 255; out[i * 4 + 3] = 255
		}
	}
	return out
}

LoadTextureFromImage :: proc(image: Image) -> Texture2D {
	if image.data == nil || image.width <= 0 || image.height <= 0 do return Texture2D{}
	rgba := _to_rgba(([^]byte)(image.data), image.width, image.height, image.format)
	defer delete(rgba)

	e := new(Tex_Entry)
	e.width = image.width
	e.height = image.height
	e.filter = .BILINEAR
	e.tex = wg.DeviceCreateTexture(g.device, &{
		usage = {.TextureBinding, .CopyDst},
		dimension = ._2D,
		size = {u32(image.width), u32(image.height), 1},
		format = .RGBA8Unorm,
		mipLevelCount = 1,
		sampleCount = 1,
	})
	wg.QueueWriteTexture(g.queue,
		&{texture = e.tex},
		raw_data(rgba), uint(len(rgba)),
		&{bytesPerRow = u32(image.width) * 4, rowsPerImage = u32(image.height)},
		&{u32(image.width), u32(image.height), 1},
	)
	e.view = wg.TextureCreateView(e.tex, nil)
	_tex_build_bind(e)

	append(&g_textures, e)
	id := TEX_ID_BASE + u32(len(g_textures) - 1)
	return Texture2D{id = id, width = image.width, height = image.height, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
}

@(private)
_tex_build_bind :: proc(e: ^Tex_Entry) {
	if e.sampler != nil do wg.SamplerRelease(e.sampler)
	if e.bind != nil do wg.BindGroupRelease(e.bind)
	filt: wg.FilterMode = e.filter == .POINT ? .Nearest : .Linear
	e.sampler = wg.DeviceCreateSampler(g.device, &{
		magFilter = filt, minFilter = filt, mipmapFilter = .Nearest,
		addressModeU = .ClampToEdge, addressModeV = .ClampToEdge, addressModeW = .ClampToEdge,
		maxAnisotropy = 1,
	})
	entries := [2]wg.BindGroupEntry{
		{binding = 0, textureView = e.view},
		{binding = 1, sampler = e.sampler},
	}
	e.bind = wg.DeviceCreateBindGroup(g.device, &{
		layout = g.rend.tex_layout, entryCount = 2, entries = raw_data(entries[:]),
	})
}

// UpdateTexture replaces the full pixel contents (same dimensions/format as the
// texture was created with; raylib assumes matching size).
UpdateTexture :: proc(texture: Texture2D, pixels: rawptr) {
	e := get_texture(texture.id)
	if e == nil || pixels == nil do return
	// caller passed data matching the source format used at load; the texture
	// itself is RGBA8, so expand assuming R8G8B8 (concord's screen frames) when
	// the byte count differs — otherwise treat as RGBA8.
	rgba := _to_rgba(([^]byte)(pixels), e.width, e.height, .UNCOMPRESSED_R8G8B8)
	defer delete(rgba)
	wg.QueueWriteTexture(g.queue,
		&{texture = e.tex},
		raw_data(rgba), uint(len(rgba)),
		&{bytesPerRow = u32(e.width) * 4, rowsPerImage = u32(e.height)},
		&{u32(e.width), u32(e.height), 1},
	)
}

UnloadTexture :: proc(texture: Texture2D) {
	e := get_texture(texture.id)
	if e == nil do return
	if e.bind != nil do wg.BindGroupRelease(e.bind)
	if e.sampler != nil do wg.SamplerRelease(e.sampler)
	if e.view != nil do wg.TextureViewRelease(e.view)
	if e.tex != nil { wg.TextureDestroy(e.tex); wg.TextureRelease(e.tex) }
	g_textures[texture.id - TEX_ID_BASE] = nil
	free(e)
}

// --- draw ------------------------------------------------------------------

DrawTexture :: proc(texture: Texture2D, posX, posY: i32, tint: Color) {
	DrawTextureV(texture, {f32(posX), f32(posY)}, tint)
}

DrawTextureV :: proc(texture: Texture2D, position: Vector2, tint: Color) {
	e := get_texture(texture.id)
	if e == nil do return
	src := Rectangle{0, 0, f32(e.width), f32(e.height)}
	dst := Rectangle{position.x, position.y, f32(e.width), f32(e.height)}
	DrawTexturePro(texture, src, dst, {0, 0}, 0, tint)
}

DrawTextureEx :: proc(texture: Texture2D, position: Vector2, rotation, scale: f32, tint: Color) {
	e := get_texture(texture.id)
	if e == nil do return
	src := Rectangle{0, 0, f32(e.width), f32(e.height)}
	dst := Rectangle{position.x, position.y, f32(e.width) * scale, f32(e.height) * scale}
	DrawTexturePro(texture, src, dst, {0, 0}, rotation, tint)
}

DrawTextureRec :: proc(texture: Texture2D, source: Rectangle, position: Vector2, tint: Color) {
	dst := Rectangle{position.x, position.y, abs(source.width), abs(source.height)}
	DrawTexturePro(texture, source, dst, {0, 0}, 0, tint)
}

DrawTexturePro :: proc(texture: Texture2D, source, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) {
	e := get_texture(texture.id)
	if e == nil do return
	batch_set(&g.rend, .Image, e.bind)
	col := col_f(tint)

	tw := f32(e.width)
	th := f32(e.height)
	u0 := source.x / tw
	v0 := source.y / th
	u1 := (source.x + source.width) / tw
	v1 := (source.y + source.height) / th

	// dest quad corners relative to top-left, offset by -origin, rotated, then
	// translated to dest.x/dest.y (matches raylib DrawTexturePro).
	w := dest.width
	h := dest.height
	// local corners after subtracting origin
	tl := [2]f32{-origin.x, -origin.y}
	tr := [2]f32{w - origin.x, -origin.y}
	br := [2]f32{w - origin.x, h - origin.y}
	bl := [2]f32{-origin.x, h - origin.y}
	if rotation != 0 {
		rad := rotation * math.PI / 180.0
		c := math.cos(rad)
		s := math.sin(rad)
		rot :: proc(p: [2]f32, c, s: f32) -> [2]f32 {
			return {p.x * c - p.y * s, p.x * s + p.y * c}
		}
		tl = rot(tl, c, s); tr = rot(tr, c, s); br = rot(br, c, s); bl = rot(bl, c, s)
	}
	off := [2]f32{dest.x, dest.y}
	push_quad4(&g.rend,
		{tl.x + off.x, tl.y + off.y}, {tr.x + off.x, tr.y + off.y},
		{br.x + off.x, br.y + off.y}, {bl.x + off.x, bl.y + off.y},
		{u0, v0}, {u1, v0}, {u1, v1}, {u0, v1}, col,
	)
}

// --- image / icon ----------------------------------------------------------

// LoadImageFromMemory decodes a compressed image (PNG/JPG/...) via stb_image.
LoadImageFromMemory :: proc(fileType: cstring, fileData: [^]u8, dataSize: i32) -> Image {
	w, h, comp: i32
	pixels := stbi.load_from_memory(fileData, dataSize, &w, &h, &comp, 4)
	if pixels == nil do return Image{}
	return Image{data = pixels, width = w, height = h, mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8}
}

UnloadImage :: proc(image: Image) {
	if image.data != nil do stbi.image_free(image.data)
}

LoadTexture :: proc(fileName: cstring) -> Texture2D { return Texture2D{} } // path load unsupported (no fs image loader wired)

// SetWindowIcon sets the GLFW window icon from a decoded RGBA image.
SetWindowIcon :: proc(image: Image) {
	if g.win == nil || image.data == nil do return
	img := glfw.Image{width = image.width, height = image.height, pixels = ([^]u8)(image.data)}
	imgs := [1]glfw.Image{img}
	glfw.SetWindowIcon(g.win, imgs[:])
}
