// ingot:gfx — image/texture support (raylib-named). Covers what the consumer
// apps use: LoadImageFromMemory/LoadTextureFromImage/LoadTexture, UpdateTexture,
// UnloadTexture, and DrawTexture*/DrawTexturePro, plus SetWindowIcon. Textures
// live in the active context's bounded pool above the font-atlas ID domain and
// draw through the batch renderer's `image` pipeline. Non-RGBA source formats
// (grayscale, RGB) are expanded to RGBA8 on upload since WebGPU has no RGB8.
package gfx

import "core:math"
import stbi "vendor:stb/image"
import wg "vendor:wgpu"

TEX_ID_BASE :: u32(0x4000_0000)
MAX_TEXTURES :: RESOURCE_SLOT_COUNT

Tex_Entry :: struct {
	tex:      wg.Texture,
	view:     wg.TextureView,
	sampler:  wg.Sampler,
	bind:     wg.BindGroup,
	width:    i32,
	height:   i32,
	filter:   TextureFilter,
	wgformat: wg.TextureFormat, // backing wgpu format (for render-target pipelines)
}

@(private)
Texture_Slot :: struct {
	entry:      ^Tex_Entry,
	generation: u32,
	occupied:   bool,
}

Texture_Resources :: struct {
	slots:          [MAX_TEXTURES]Texture_Slot,
	count:          u32,
	upload_scratch: [dynamic]byte,
}

@(private)
_texture_register_context :: proc(
	context_id: u32,
	resources: ^Texture_Resources,
	entry: ^Tex_Entry,
) -> u32 {
	assert(resources != nil && entry != nil, "_texture_register_context: invalid arguments")
	if resources.count >= MAX_TEXTURES do return 0
	for &slot, index in resources.slots {
		if slot.occupied do continue
		slot.generation = _resource_generation_next(slot.generation)
		slot.entry = entry
		slot.occupied = true
		resources.count += 1
		handle := _resource_handle_make_context(context_id, index, slot.generation)
		return TEX_ID_BASE | handle
	}
	assert(false, "_texture_register_context: count mismatch")
	return 0
}

@(private)
_texture_register :: proc(resources: ^Texture_Resources, entry: ^Tex_Entry) -> u32 {
	return _texture_register_context(1, resources, entry)
}

@(private)
_texture_slot_context :: proc(
	context_id: u32,
	resources: ^Texture_Resources,
	id: u32,
) -> ^Texture_Slot {
	assert(resources != nil, "_texture_slot_context: nil resources")
	if id & TEX_ID_BASE == 0 do return nil
	raw_id := id & ~TEX_ID_BASE
	handle_context := (raw_id >> RESOURCE_SLOT_BITS) & RESOURCE_CONTEXT_MASK
	if handle_context != context_id do return nil
	index, generation, ok := _resource_handle_decode(raw_id, len(resources.slots))
	if !ok do return nil
	slot := &resources.slots[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot
}

@(private)
_texture_slot :: proc(resources: ^Texture_Resources, id: u32) -> ^Texture_Slot {
	return _texture_slot_context(1, resources, id)
}

@(private)
get_texture :: proc(id: u32) -> ^Tex_Entry {
	slot := _texture_slot_context(g.id, &g.resources.textures, id)
	if slot == nil do return nil
	return slot.entry
}

@(private)
_to_rgba_into :: proc(out: []byte, src: [^]byte, w, h: i32, format: PixelFormat) -> bool {
	n := int(w) * int(h)
	if src == nil || n <= 0 || len(out) != n * 4 do return false
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
	return true
}

// _to_rgba expands source pixels into an owned RGBA8 buffer for one-time uploads.
@(private)
_to_rgba :: proc(src: [^]byte, w, h: i32, format: PixelFormat) -> []byte {
	n := int(w) * int(h)
	out := make([]byte, n * 4)
	assert(_to_rgba_into(out, src, w, h, format))
	return out
}

// _new_rt_color creates a sampleable colour texture usable as a render-target
// attachment, registered in the texture registry, and returns its Texture2D.
// Backs LoadRenderTexture (color-only) and the rlgl framebuffer path.
@(private)
_new_rt_color :: proc(w, h: i32, format: wg.TextureFormat) -> Texture2D {
	e := new(Tex_Entry)
	e.width = w
	e.height = h
	e.filter = .BILINEAR
	e.wgformat = format
	e.tex = wg.DeviceCreateTexture(
		g.device,
		&{
			usage = {.RenderAttachment, .TextureBinding, .CopyDst},
			dimension = ._2D,
			size = {u32(max(w, 1)), u32(max(h, 1)), 1},
			format = format,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	e.view = wg.TextureCreateView(e.tex, nil)
	_tex_build_bind(e)
	id := _texture_register_context(g.id, &g.resources.textures, e)
	if id == 0 {
		_texture_entry_destroy(e)
		return {}
	}
	pf: PixelFormat = .UNCOMPRESSED_R8G8B8A8
	#partial switch format {
	case .R32Float:
		pf = .UNCOMPRESSED_R32
	case .RGBA16Float:
		pf = .UNCOMPRESSED_R16G16B16A16
	}
	return Texture2D{id = id, width = w, height = h, mipmaps = 1, format = pf}
}

// _texture_view returns the wgpu view backing a registered texture id (used as
// a render-target attachment). nil if not found.
@(private)
_texture_view :: proc(id: u32) -> wg.TextureView {
	e := get_texture(id)
	if e == nil do return nil
	return e.view
}

// _new_rt_depth creates a Depth24Plus depth attachment registered in the
// texture registry (no sampler/bind — never sampled). Returns its Texture2D.
@(private)
_new_rt_depth :: proc(w, h: i32) -> Texture2D {
	e := new(Tex_Entry)
	e.width = w
	e.height = h
	e.wgformat = .Depth24Plus
	e.tex = wg.DeviceCreateTexture(
		g.device,
		&{
			usage = {.RenderAttachment},
			dimension = ._2D,
			size = {u32(max(w, 1)), u32(max(h, 1)), 1},
			format = .Depth24Plus,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	e.view = wg.TextureCreateView(e.tex, nil)
	id := _texture_register_context(g.id, &g.resources.textures, e)
	if id == 0 {
		_texture_entry_destroy(e)
		return {}
	}
	return Texture2D{id = id, width = w, height = h, mipmaps = 1, format = .UNCOMPRESSED_R32}
}

// _unload_depth releases a depth texture created by _new_rt_depth.
@(private)
_unload_depth :: proc(depth: Texture2D) {
	UnloadTexture(depth)
}

LoadTextureFromImage :: proc(image: Image) -> Texture2D {
	if image.data == nil || image.width <= 0 || image.height <= 0 do return Texture2D{}
	rgba := _to_rgba(([^]byte)(image.data), image.width, image.height, image.format)
	defer delete(rgba)

	e := new(Tex_Entry)
	e.width = image.width
	e.height = image.height
	e.filter = .BILINEAR
	e.wgformat = .RGBA8Unorm
	e.tex = wg.DeviceCreateTexture(
		g.device,
		&{
			usage = {.TextureBinding, .CopyDst},
			dimension = ._2D,
			size = {u32(image.width), u32(image.height), 1},
			format = .RGBA8Unorm,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	wg.QueueWriteTexture(
		g.queue,
		&{texture = e.tex},
		raw_data(rgba),
		uint(len(rgba)),
		&{bytesPerRow = u32(image.width) * 4, rowsPerImage = u32(image.height)},
		&{u32(image.width), u32(image.height), 1},
	)
	e.view = wg.TextureCreateView(e.tex, nil)
	_tex_build_bind(e)

	id := _texture_register_context(g.id, &g.resources.textures, e)
	if id == 0 {
		_texture_entry_destroy(e)
		return {}
	}
	return Texture2D {
		id = id,
		width = image.width,
		height = image.height,
		mipmaps = 1,
		format = .UNCOMPRESSED_R8G8B8A8,
	}
}

@(private)
_tex_build_bind :: proc(e: ^Tex_Entry) {
	if e.sampler != nil do wg.SamplerRelease(e.sampler)
	if e.bind != nil do wg.BindGroupRelease(e.bind)
	filt: wg.FilterMode = e.filter == .POINT ? .Nearest : .Linear
	e.sampler = wg.DeviceCreateSampler(
		g.device,
		&{
			magFilter = filt,
			minFilter = filt,
			mipmapFilter = .Nearest,
			addressModeU = .ClampToEdge,
			addressModeV = .ClampToEdge,
			addressModeW = .ClampToEdge,
			maxAnisotropy = 1,
		},
	)
	entries := [2]wg.BindGroupEntry {
		{binding = 0, textureView = e.view},
		{binding = 1, sampler = e.sampler},
	}
	e.bind = wg.DeviceCreateBindGroup(
		g.device,
		&{layout = g.rend.tex_layout, entryCount = 2, entries = raw_data(entries[:])},
	)
}

// UpdateTexture replaces the full pixel contents (same dimensions/format as the
// texture was created with; raylib assumes matching size).
UpdateTexture :: proc(texture: Texture2D, pixels: rawptr) {
	e := get_texture(texture.id)
	if e == nil || pixels == nil do return
	// caller passed data matching the source format used at load; the texture
	// itself is RGBA8, so expand assuming R8G8B8 (concord's screen frames) when
	// the byte count differs — otherwise treat as RGBA8.
	pixel_count := int(e.width) * int(e.height)
	ensure(pixel_count > 0)
	resources := &g.resources.textures
	if len(resources.upload_scratch) < pixel_count * 4 {
		resize(&resources.upload_scratch, pixel_count * 4)
	}
	rgba := resources.upload_scratch[:pixel_count * 4]
	ensure(_to_rgba_into(rgba, ([^]byte)(pixels), e.width, e.height, .UNCOMPRESSED_R8G8B8))
	wg.QueueWriteTexture(
		g.queue,
		&{texture = e.tex},
		raw_data(rgba),
		uint(len(rgba)),
		&{bytesPerRow = u32(e.width) * 4, rowsPerImage = u32(e.height)},
		&{u32(e.width), u32(e.height), 1},
	)
}

@(private)
_texture_entry_destroy :: proc(entry: ^Tex_Entry) {
	assert(entry != nil, "_texture_entry_destroy: nil entry")
	_retire_texture(entry.bind, entry.sampler, entry.view, entry.tex)
	free(entry)
}

@(private)
_texture_resources_destroy :: proc(resources: ^Texture_Resources) {
	assert(resources != nil, "_texture_resources_destroy: nil resources")
	for &slot in resources.slots {
		if !slot.occupied do continue
		_texture_entry_destroy(slot.entry)
		slot.entry = nil
		slot.occupied = false
	}

	delete(resources.upload_scratch)

	resources^ = {}
}

UnloadTexture :: proc(texture: Texture2D) {
	slot := _texture_slot_context(g.id, &g.resources.textures, texture.id)
	if slot == nil do return
	_texture_entry_destroy(slot.entry)
	slot.entry = nil
	slot.occupied = false
	assert(g.resources.textures.count > 0, "UnloadTexture: count underflow")
	g.resources.textures.count -= 1
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

DrawTexturePro :: proc(
	texture: Texture2D,
	source, dest: Rectangle,
	origin: Vector2,
	rotation: f32,
	tint: Color,
) {
	e := get_texture(texture.id)
	if e == nil do return
	batch_set(&g.rend, .Image, e.bind)
	col := col_f(tint)

	tw := f32(e.width)
	th := f32(e.height)
	// Replicate raylib's negative-source-dimension handling: a negative width or
	// height flips the sampled region (used by RenderTexture blits which pass a
	// negative source height to compensate for the flipped-Y target).
	src := source
	flipX := false
	if src.width < 0 {
		flipX = true
		src.width = -src.width
	}
	if src.height < 0 {
		src.y -= src.height // keep height negative; shift origin to stay in-range
	}
	u0 := src.x / tw
	v0 := src.y / th
	u1 := (src.x + src.width) / tw
	v1 := (src.y + src.height) / th
	if flipX {
		u0, u1 = u1, u0
	}

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
	push_quad4(
		&g.rend,
		{tl.x + off.x, tl.y + off.y},
		{tr.x + off.x, tr.y + off.y},
		{br.x + off.x, br.y + off.y},
		{bl.x + off.x, bl.y + off.y},
		{u0, v0},
		{u1, v0},
		{u1, v1},
		{u0, v1},
		col,
	)
}

// --- image / icon ----------------------------------------------------------

// LoadImageFromMemory decodes a compressed image (PNG/JPG/...) via stb_image.
LoadImageFromMemory :: proc(fileType: cstring, fileData: [^]u8, dataSize: i32) -> Image {
	w, h, comp: i32
	pixels := stbi.load_from_memory(fileData, dataSize, &w, &h, &comp, 4)
	if pixels == nil do return Image{}
	return Image {
		data = pixels,
		width = w,
		height = h,
		mipmaps = 1,
		format = .UNCOMPRESSED_R8G8B8A8,
	}
}

UnloadImage :: proc(image: Image) {
	if image.data != nil do stbi.image_free(image.data)
}

// SetWindowIcon sets the window icon from a decoded RGBA image (native only;
// no-op on web where the browser owns the tab/favicon).
SetWindowIcon :: proc(image: Image) {
	platform_set_window_icon(image)
}
