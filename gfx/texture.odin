// ingot:gfx - image/texture support (raylib-named). Covers what the consumer
// apps use: LoadImageFromMemory/LoadTextureFromImage/LoadTexture, UpdateTexture,
// UnloadTexture, and DrawTexture*/DrawTexturePro, plus SetWindowIcon. Textures
// live in their owner's bounded pool above the font-atlas ID domain and
// draw through the batch renderer's `image` pipeline. Non-RGBA source formats
// (grayscale, RGB) are expanded to RGBA8 on upload since WebGPU has no RGB8.
package gfx

import "core:math"
import stbi "vendor:stb/image"
import wg "vendor:wgpu"

TEX_ID_BASE :: u32(0x4000_0000)
MAX_TEXTURES :: RESOURCE_SLOT_COUNT

Tex_Entry :: struct {
	tex:          wg.Texture,
	view:         wg.TextureView,
	sampler:      wg.Sampler,
	bind:         wg.BindGroup,
	width:        i32,
	height:       i32,
	filter:       TextureFilter,
	wgformat:     wg.TextureFormat, // backing wgpu format (for render-target pipelines)
	sample_count: u32,
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
	// A zero context id never matches a packed handle, because
	// _resource_handle_make_context refuses to mint one. Looking up with zero
	// would therefore miss every slot and read as an ordinary stale handle.
	// The only way to get here with zero is an unassigned context id - see the
	// note above _default_context_init in context.odin.
	assert(context_id != 0, "_texture_slot_context: unassigned context id")
	if id & TEX_ID_BASE == 0 do return nil
	raw_id := id & ~TEX_ID_BASE
	handle_context := (raw_id >> RESOURCE_SLOT_BITS) & RESOURCE_CONTEXT_MASK
	if handle_context != context_id do return nil
	index, generation, ok := _resource_handle_decode(raw_id, len(resources.slots))
	if !ok do return nil
	assert(
		index >= 0 && index < len(resources.slots),
		"_texture_slot_context: decoded index out of range",
	)
	slot := &resources.slots[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot
}

@(private)
_texture_slot :: proc(resources: ^Texture_Resources, id: u32) -> ^Texture_Slot {
	return _texture_slot_context(1, resources, id)
}

@(private)
context_get_texture :: proc(ctx: ^Context, id: u32) -> ^Tex_Entry {
	assert(ctx != nil, "context_get_texture: nil context")
	slot := _texture_slot_context(ctx.id, &ctx.resources.textures, id)
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
_new_rt_color :: proc(ctx: ^Context, w, h: i32, format: wg.TextureFormat) -> Texture2D {
	assert(ctx != nil, "_new_rt_color: nil context")
	e := new(Tex_Entry)
	e.width = w
	e.height = h
	e.filter = .BILINEAR
	e.wgformat = format
	e.sample_count = 1
	// CopySrc is what makes SaveRenderTexturePng (screenshot.odin) possible: the
	// swapchain is configured RenderAttachment-only (context.odin), so every
	// readback must route through a render target. The flag is free on an
	// already-renderable colour format.
	e.tex = wg.DeviceCreateTexture(
		ctx.device,
		&{
			usage = {.RenderAttachment, .TextureBinding, .CopyDst, .CopySrc},
			dimension = ._2D,
			size = {u32(max(w, 1)), u32(max(h, 1)), 1},
			format = format,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	e.view = wg.TextureCreateView(e.tex, nil)
	_tex_build_bind(ctx, e)
	id := _texture_register_context(ctx.id, &ctx.resources.textures, e)
	if id == 0 {
		_texture_entry_destroy(ctx, e)
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

@(private)
_new_rt_attachment :: proc(
	ctx: ^Context,
	w, h: i32,
	format: wg.TextureFormat,
	sample_count: u32,
) -> ^Tex_Entry {
	assert(ctx != nil && ctx.device != nil, "_new_rt_attachment: invalid context")
	assert(w > 0 && h > 0, "_new_rt_attachment: invalid dimensions")
	assert(sample_count == 1 || sample_count == 4, "_new_rt_attachment: unsupported sample count")
	entry := new(Tex_Entry)
	entry.width = w
	entry.height = h
	entry.wgformat = format
	entry.sample_count = sample_count
	entry.tex = wg.DeviceCreateTexture(
		ctx.device,
		&{
			usage = {.RenderAttachment},
			dimension = ._2D,
			size = {u32(w), u32(h), 1},
			format = format,
			mipLevelCount = 1,
			sampleCount = sample_count,
		},
	)
	if entry.tex == nil {
		free(entry)
		return nil
	}
	entry.view = wg.TextureCreateView(entry.tex, nil)
	if entry.view == nil {
		wg.TextureRelease(entry.tex)
		free(entry)
		return nil
	}
	return entry
}

@(private)
_destroy_rt_attachment :: proc(ctx: ^Context, entry: ^Tex_Entry) {
	assert(ctx != nil, "_destroy_rt_attachment: nil context")
	if entry == nil do return
	_texture_entry_destroy(ctx, entry)
}

// _texture_view returns the wgpu view backing a registered texture id (used as
// a render-target attachment). nil if not found.
@(private)
context_texture_view :: proc(ctx: ^Context, id: u32) -> wg.TextureView {
	assert(ctx != nil, "context_texture_view: nil context")
	e := context_get_texture(ctx, id)
	if e == nil do return nil
	return e.view
}

// _new_rt_depth creates a Depth24Plus depth attachment registered in the
// texture registry. TextureBinding permits read-only depth consumers while
// existing render-target callers continue using it only as an attachment.
@(private)
_new_rt_depth :: proc(ctx: ^Context, w, h: i32) -> Texture2D {
	assert(ctx != nil, "_new_rt_depth: nil context")
	e := new(Tex_Entry)
	e.width = w
	e.height = h
	e.wgformat = .Depth24Plus
	e.sample_count = 1
	e.tex = wg.DeviceCreateTexture(
		ctx.device,
		&{
			usage = {.RenderAttachment, .TextureBinding},
			dimension = ._2D,
			size = {u32(max(w, 1)), u32(max(h, 1)), 1},
			format = .Depth24Plus,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	e.view = wg.TextureCreateView(e.tex, nil)
	id := _texture_register_context(ctx.id, &ctx.resources.textures, e)
	if id == 0 {
		_texture_entry_destroy(ctx, e)
		return {}
	}
	return Texture2D{id = id, width = w, height = h, mipmaps = 1, format = .UNCOMPRESSED_R32}
}

// _unload_depth releases a depth texture created by _new_rt_depth.
@(private)
_unload_depth :: proc(ctx: ^Context, depth: Texture2D) {
	context_unload_texture(ctx, depth)
}

// LoadTextureFromImage uploads `image` and registers it in the context's
// texture pool. Returns a zero Texture2D when the pool is full (see
// TextureSlotsUsed) or the image is empty - a full pool is an operating
// condition, so callers must check IsTextureValid rather than assume success.
context_load_texture_from_image :: proc(ctx: ^Context, image: Image) -> Texture2D {
	assert(ctx != nil, "context_load_texture_from_image: nil context")
	if image.data == nil || image.width <= 0 || image.height <= 0 do return Texture2D{}
	rgba := _to_rgba(([^]byte)(image.data), image.width, image.height, image.format)
	defer delete(rgba)

	e := new(Tex_Entry)
	e.width = image.width
	e.height = image.height
	e.filter = .BILINEAR
	e.wgformat = .RGBA8Unorm
	e.sample_count = 1
	e.tex = wg.DeviceCreateTexture(
		ctx.device,
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
		ctx.queue,
		&{texture = e.tex},
		raw_data(rgba),
		uint(len(rgba)),
		&{bytesPerRow = u32(image.width) * 4, rowsPerImage = u32(image.height)},
		&{u32(image.width), u32(image.height), 1},
	)
	e.view = wg.TextureCreateView(e.tex, nil)
	_tex_build_bind(ctx, e)

	id := _texture_register_context(ctx.id, &ctx.resources.textures, e)
	if id == 0 {
		_texture_entry_destroy(ctx, e)
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

LoadTextureFromImage :: proc(image: Image) -> Texture2D {
	return context_load_texture_from_image(default_context(), image)
}

@(private)
_tex_build_bind :: proc(ctx: ^Context, e: ^Tex_Entry) {
	assert(ctx != nil, "_tex_build_bind: nil context")
	if e.sampler != nil do wg.SamplerRelease(e.sampler)
	if e.bind != nil do wg.BindGroupRelease(e.bind)
	filt: wg.FilterMode = e.filter == .POINT ? .Nearest : .Linear
	e.sampler = wg.DeviceCreateSampler(
		ctx.device,
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
		ctx.device,
		&{layout = ctx.rend.tex_layout, entryCount = 2, entries = raw_data(entries[:])},
	)
}

// UpdateTexture replaces the full pixel contents (same dimensions/format as the
// texture was created with; raylib assumes matching size).
context_update_texture :: proc(ctx: ^Context, texture: Texture2D, pixels: rawptr) {
	assert(ctx != nil, "context_update_texture: nil context")
	e := context_get_texture(ctx, texture.id)
	if e == nil || pixels == nil do return
	// caller passed data matching the source format used at load; the texture
	// itself is RGBA8, so expand assuming R8G8B8 (concord's screen frames) when
	// the byte count differs - otherwise treat as RGBA8.
	pixel_count := int(e.width) * int(e.height)
	ensure(pixel_count > 0)
	resources := &ctx.resources.textures
	if len(resources.upload_scratch) < pixel_count * 4 {
		resize(&resources.upload_scratch, pixel_count * 4)
	}
	rgba := resources.upload_scratch[:pixel_count * 4]
	ensure(_to_rgba_into(rgba, ([^]byte)(pixels), e.width, e.height, .UNCOMPRESSED_R8G8B8))
	wg.QueueWriteTexture(
		ctx.queue,
		&{texture = e.tex},
		raw_data(rgba),
		uint(len(rgba)),
		&{bytesPerRow = u32(e.width) * 4, rowsPerImage = u32(e.height)},
		&{u32(e.width), u32(e.height), 1},
	)
}

UpdateTexture :: proc(texture: Texture2D, pixels: rawptr) {
	context_update_texture(default_context(), texture, pixels)
}

@(private)
_texture_entry_destroy :: proc(ctx: ^Context, entry: ^Tex_Entry) {
	assert(ctx != nil, "_texture_entry_destroy: nil context")
	assert(entry != nil, "_texture_entry_destroy: nil entry")
	_retire_texture(ctx, entry.bind, entry.sampler, entry.view, entry.tex)
	free(entry)
}

@(private)
_texture_resources_destroy :: proc(ctx: ^Context, resources: ^Texture_Resources) {
	assert(ctx != nil, "_texture_resources_destroy: nil context")
	assert(resources != nil, "_texture_resources_destroy: nil resources")
	for &slot in resources.slots {
		if !slot.occupied do continue
		_texture_entry_destroy(ctx, slot.entry)
		slot.entry = nil
		slot.occupied = false
	}

	delete(resources.upload_scratch)

	resources^ = {}
}

context_unload_texture :: proc(ctx: ^Context, texture: Texture2D) {
	assert(ctx != nil, "context_unload_texture: nil context")
	slot := _texture_slot_context(ctx.id, &ctx.resources.textures, texture.id)
	if slot == nil do return
	_texture_entry_destroy(ctx, slot.entry)
	slot.entry = nil
	slot.occupied = false
	assert(ctx.resources.textures.count > 0, "context_unload_texture: count underflow")
	ctx.resources.textures.count -= 1
}

UnloadTexture :: proc(texture: Texture2D) {
	context_unload_texture(default_context(), texture)
}

// TextureSlotsUsed reports how many of the context's texture slots are
// occupied. Consumers that cache many textures (tile maps, sprite streamers)
// need this to size their own budget: the pool is shared with fonts, UI icons
// and render targets (capacity is MAX_TEXTURES), and LoadTextureFromImage
// returns an invalid handle once it is full.
context_texture_slots_used :: proc(ctx: ^Context) -> int {
	assert(ctx != nil, "context_texture_slots_used: nil context")
	count := int(ctx.resources.textures.count)
	// Why assert: the pool hands out a bounded number of slots, so a count
	// above the bound means a register/unregister pair drifted.
	assert(count <= MAX_TEXTURES, "context_texture_slots_used: count exceeds pool")
	return count
}

TextureSlotsUsed :: proc() -> int {
	return context_texture_slots_used(default_context())
}

// IsTextureValid reports whether `texture` refers to a live slot. A loader
// returning id == 0 means the pool was full - an operating condition callers
// must handle, not a programmer error, so this is a query and not an assert.
context_is_texture_valid :: proc(ctx: ^Context, texture: Texture2D) -> bool {
	if ctx == nil || texture.id == 0 do return false
	return context_get_texture(ctx, texture.id) != nil
}

IsTextureValid :: proc(texture: Texture2D) -> bool {
	return context_is_texture_valid(default_context(), texture)
}

// --- draw ------------------------------------------------------------------

DrawTexture :: proc(texture: Texture2D, posX, posY: i32, tint: Color) {
	context_draw_texture_v(default_context(), texture, {f32(posX), f32(posY)}, tint)
}

context_draw_texture_v :: proc(ctx: ^Context, texture: Texture2D, position: Vector2, tint: Color) {
	assert(ctx != nil, "context_draw_texture_v: nil context")
	e := context_get_texture(ctx, texture.id)
	if e == nil do return
	src := Rectangle{0, 0, f32(e.width), f32(e.height)}
	dst := Rectangle{position.x, position.y, f32(e.width), f32(e.height)}
	context_draw_texture_pro(ctx, texture, src, dst, {0, 0}, 0, tint)
}

DrawTextureV :: proc(texture: Texture2D, position: Vector2, tint: Color) {
	context_draw_texture_v(default_context(), texture, position, tint)
}

context_draw_texture_ex :: proc(
	ctx: ^Context,
	texture: Texture2D,
	position: Vector2,
	rotation, scale: f32,
	tint: Color,
) {
	assert(ctx != nil, "context_draw_texture_ex: nil context")
	e := context_get_texture(ctx, texture.id)
	if e == nil do return
	src := Rectangle{0, 0, f32(e.width), f32(e.height)}
	dst := Rectangle{position.x, position.y, f32(e.width) * scale, f32(e.height) * scale}
	context_draw_texture_pro(ctx, texture, src, dst, {0, 0}, rotation, tint)
}

DrawTextureEx :: proc(texture: Texture2D, position: Vector2, rotation, scale: f32, tint: Color) {
	context_draw_texture_ex(default_context(), texture, position, rotation, scale, tint)
}

context_draw_texture_rec :: proc(
	ctx: ^Context,
	texture: Texture2D,
	source: Rectangle,
	position: Vector2,
	tint: Color,
) {
	assert(ctx != nil, "context_draw_texture_rec: nil context")
	dst := Rectangle{position.x, position.y, abs(source.width), abs(source.height)}
	context_draw_texture_pro(ctx, texture, source, dst, {0, 0}, 0, tint)
}

DrawTextureRec :: proc(texture: Texture2D, source: Rectangle, position: Vector2, tint: Color) {
	context_draw_texture_rec(default_context(), texture, source, position, tint)
}

context_draw_texture_pro :: proc(
	ctx: ^Context,
	texture: Texture2D,
	source, dest: Rectangle,
	origin: Vector2,
	rotation: f32,
	tint: Color,
) {
	assert(ctx != nil, "context_draw_texture_pro: nil context")
	e := context_get_texture(ctx, texture.id)
	if e == nil do return
	batch_set(ctx, &ctx.rend, .Image, e.bind)
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
		ctx,
		&ctx.rend,
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

DrawTexturePro :: proc(
	texture: Texture2D,
	source, dest: Rectangle,
	origin: Vector2,
	rotation: f32,
	tint: Color,
) {
	context_draw_texture_pro(default_context(), texture, source, dest, origin, rotation, tint)
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
context_set_window_icon :: proc(ctx: ^Context, image: Image) {
	platform_set_window_icon(ctx, image)
}

SetWindowIcon :: proc(image: Image) {
	context_set_window_icon(default_context(), image)
}
