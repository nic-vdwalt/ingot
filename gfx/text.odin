// ingot:gfx - glyph-atlas text stack over WebGPU. Mirrors the raylib text API
// ingot uses: LoadFontFromMemory / UnloadFont / DrawTextEx / MeasureTextEx /
// DrawTextCodepoint / SetTextureFilter, plus DrawText/MeasureText/DrawTextPro
// over the embedded default font (font_default.odin).
// Each font bakes its requested codepoints once (stb_truetype) into a single
// R8 atlas texture; glyphs draw as textured quads through the batch renderer's
// `text` pipeline (atlas red channel = coverage).
package gfx

import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import tt "vendor:stb/truetype"
import wg "vendor:wgpu"

ATLAS_DIM :: 2048
ATLAS_PAD :: 1
ATLAS_UPLOAD_ALIGN :: 256
MAX_ATLASES :: 256

// The atlas dimension stays a compile-time constant because glyph UVs, the
// bitmap stride, and the copy layout all derive from it. WebGPU guarantees
// maxTextureDimension2D >= 8192, so every conformant device - mobile included
// - can host it; the negotiated budget (limits.odin) only has to confirm that
// before the atlas is created, which _atlas_dim_supported does.
#assert(ATLAS_DIM % 256 == 0)
#assert(u32(ATLAS_DIM) <= GPU_BUDGET_ATLAS_DIM_DEFAULT)

@(private)
_atlas_dim_supported :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "_atlas_dim_supported: nil context")
	return gpu_budget_context(ctx).atlas_dim >= u32(ATLAS_DIM)
}

Glyph :: struct {
	x, y, w, h: u16, // atlas cell (pixels)
	xoff, yoff: f32, // draw offset from pen (baked px, top-left of cell)
	xadvance:   f32, // baked px
	valid:      bool,
}

Atlas :: struct {
	info:                  tt.fontinfo,
	data:                  []byte, // owned copy of the TTF (InitFont holds a pointer)
	px:                    f32, // baked pixel size
	scale:                 f32,
	ascent:                f32, // baked px
	line_adv:              f32, // baked px (ascent - descent + line gap)
	glyphs:                map[rune]Glyph,
	cur_x, cur_y, shelf_h: i32,
	tex:                   wg.Texture,
	view:                  wg.TextureView,
	sampler:               wg.Sampler,
	bind:                  wg.BindGroup,
	filter:                TextureFilter,
}

@(private)
Atlas_Slot :: struct {
	entry:      ^Atlas,
	generation: u32,
	occupied:   bool,
}

Atlas_Resources :: struct {
	slots: [MAX_ATLASES]Atlas_Slot,
	count: u32,
}

@(private)
_atlas_register :: proc(context_id: u32, resources: ^Atlas_Resources, entry: ^Atlas) -> u32 {
	assert(context_id != 0, "_atlas_register: unassigned context id")
	assert(resources != nil && entry != nil, "_atlas_register: invalid arguments")
	if resources.count >= MAX_ATLASES do return 0
	for &slot, index in resources.slots {
		if slot.occupied do continue
		slot.generation = _resource_generation_next(slot.generation)
		slot.entry = entry
		slot.occupied = true
		resources.count += 1
		return _resource_handle_make_context(context_id, index, slot.generation)
	}
	assert(false, "_atlas_register: count mismatch")
	return 0
}

@(private)
_atlas_slot :: proc(context_id: u32, resources: ^Atlas_Resources, id: u32) -> ^Atlas_Slot {
	assert(context_id != 0, "_atlas_slot: unassigned context id")
	assert(resources != nil, "_atlas_slot: nil resources")
	handle_context := (id >> RESOURCE_SLOT_BITS) & RESOURCE_CONTEXT_MASK
	if handle_context != context_id do return nil
	index, generation, ok := _resource_handle_decode(id, len(resources.slots))
	if !ok do return nil
	assert(index >= 0 && index < len(resources.slots), "_atlas_slot: decoded index out of range")
	slot := &resources.slots[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot
}

@(private)
context_get_atlas :: proc(ctx: ^Context, id: u32) -> ^Atlas {
	assert(ctx != nil, "context_get_atlas: nil context")
	slot := _atlas_slot(ctx.id, &ctx.resources.atlases, id)
	if slot == nil do return nil
	return slot.entry
}

context_load_font_from_memory_impl :: proc(
	ctx: ^Context,
	fileType: cstring,
	fileData: [^]u8,
	dataSize: i32,
	fontSize: i32,
	codepoints: [^]rune,
	codepointCount: i32,
) -> Font {
	assert(ctx != nil, "context_load_font_from_memory_impl: nil context")
	// Why assert: a public entry taking a raw multipointer alongside a separate
	// length, so the two can disagree. A negative dataSize reaches make() and
	// then slices fileData[:dataSize]; a nil fileData with a positive length
	// slices nothing valid. _to_rgba_into guards its equivalent inputs
	// (texture.odin:99) - this one did not.
	assert(fileData != nil, "LoadFontFromMemory: nil font data")
	assert(dataSize > 0, "LoadFontFromMemory: non-positive font data size")
	assert(codepointCount >= 0, "LoadFontFromMemory: negative codepoint count")
	if codepointCount > 0 do assert(codepoints != nil, "LoadFontFromMemory: nil codepoints")
	if !_atlas_dim_supported(ctx) {
		// A device below the WebGPU-guaranteed texture ceiling cannot host
		// the atlas. Return an empty font (callers already handle
		// glyphCount == 0) instead of creating an invalid texture.
		fmt.eprintfln(
			"gfx: device texture limit %d below atlas dimension %d; font not loaded",
			ctx.budget.atlas_dim,
			ATLAS_DIM,
		)
		return Font{}
	}
	a := new(Atlas)
	a.data = make([]byte, int(dataSize))
	copy(a.data, fileData[:dataSize])
	if !tt.InitFont(&a.info, raw_data(a.data), 0) {
		delete(a.data)
		free(a)
		return Font{}
	}
	a.px = f32(fontSize)
	a.scale = tt.ScaleForPixelHeight(&a.info, a.px)
	asc, desc, gap: c.int
	tt.GetFontVMetrics(&a.info, &asc, &desc, &gap)
	a.ascent = math.round(f32(asc) * a.scale)
	a.line_adv = math.round(f32(asc - desc + gap) * a.scale)
	a.glyphs = make(map[rune]Glyph)
	a.filter = .BILINEAR
	if !_atlas_gpu_init(ctx, a) {
		_atlas_entry_destroy(ctx, a)
		return {}
	}

	baked: i32 = 0
	for i in 0 ..< int(codepointCount) {
		cp := codepoints[i]
		if _bake_glyph(ctx, a, cp) do baked += 1
	}

	id := _atlas_register(ctx.id, &ctx.resources.atlases, a)
	if id == 0 {
		_atlas_entry_destroy(ctx, a)
		return {}
	}

	f: Font
	f.baseSize = fontSize
	f.glyphCount = baked
	f.glyphPadding = ATLAS_PAD
	f._atlas = id
	f.texture = Texture {
		id      = id,
		width   = ATLAS_DIM,
		height  = ATLAS_DIM,
		mipmaps = 1,
		format  = .UNCOMPRESSED_GRAYSCALE,
	}
	return f
}

LoadFontFromMemory :: proc(
	fileType: cstring,
	fileData: [^]u8,
	dataSize: i32,
	fontSize: i32,
	codepoints: [^]rune,
	codepointCount: i32,
) -> Font {
	return context_load_font_from_memory_impl(
		default_context(),
		fileType,
		fileData,
		dataSize,
		fontSize,
		codepoints,
		codepointCount,
	)
}

@(private)
_bake_glyph :: proc(ctx: ^Context, a: ^Atlas, cp: rune) -> bool {
	assert(ctx != nil, "_bake_glyph: nil context")
	assert(a != nil, "_bake_glyph: nil a")
	if _, ok := a.glyphs[cp]; ok do return true

	gi := tt.FindGlyphIndex(&a.info, cp)
	adv, lsb: c.int
	tt.GetCodepointHMetrics(&a.info, cp, &adv, &lsb)
	xadvance := f32(adv) * a.scale

	if gi == 0 && cp != ' ' {
		// no glyph in font; still record advance so layout matches
		a.glyphs[cp] = Glyph {
			xadvance = xadvance,
			valid    = false,
		}
		return false
	}

	ix0, iy0, ix1, iy1: c.int
	tt.GetCodepointBitmapBox(&a.info, cp, a.scale, a.scale, &ix0, &iy0, &ix1, &iy1)
	gw := i32(ix1 - ix0)
	gh := i32(iy1 - iy0)
	if gw <= 0 || gh <= 0 {
		a.glyphs[cp] = Glyph {
			xadvance = xadvance,
			valid    = false,
		}
		return true // e.g. space
	}

	px, py, ok := _atlas_pack(a, gw, gh)
	if !ok {
		a.glyphs[cp] = Glyph {
			xadvance = xadvance,
			valid    = false,
		}
		return false
	}

	if !_atlas_upload_glyph(ctx, a, cp, px, py, gw, gh) {
		a.glyphs[cp] = Glyph {
			xadvance = xadvance,
			valid    = false,
		}
		return false
	}

	a.glyphs[cp] = Glyph {
		x        = u16(px),
		y        = u16(py),
		w        = u16(gw),
		h        = u16(gh),
		xoff     = f32(ix0),
		yoff     = a.ascent + f32(iy0),
		xadvance = xadvance,
		valid    = true,
	}
	return true
}

@(private)
_atlas_pack :: proc(a: ^Atlas, w, h: i32) -> (x, y: i32, ok: bool) {
	assert(a != nil, "_atlas_pack: nil a")
	if a.cur_x + w + ATLAS_PAD > ATLAS_DIM {
		a.cur_x = 0
		a.cur_y += a.shelf_h + ATLAS_PAD
		a.shelf_h = 0
	}
	if a.cur_y + h + ATLAS_PAD > ATLAS_DIM {
		return 0, 0, false
	}
	x = a.cur_x
	y = a.cur_y
	a.cur_x += w + ATLAS_PAD
	if h > a.shelf_h do a.shelf_h = h
	return x, y, true
}

@(private)
_atlas_upload_stride :: proc(width: i32) -> i32 {
	assert(width > 0, "_atlas_upload_stride: non-positive width")
	assert(ATLAS_UPLOAD_ALIGN > 0, "_atlas_upload_stride: invalid alignment")
	stride := (width + ATLAS_UPLOAD_ALIGN - 1) / ATLAS_UPLOAD_ALIGN * ATLAS_UPLOAD_ALIGN
	assert(stride >= width)
	assert(stride % ATLAS_UPLOAD_ALIGN == 0)
	return stride
}

@(private)
_atlas_upload_glyph :: proc(ctx: ^Context, a: ^Atlas, cp: rune, x, y, width, height: i32) -> bool {
	assert(ctx != nil, "_atlas_upload_glyph: nil context")
	assert(a != nil && a.tex != nil, "_atlas_upload_glyph: invalid atlas")
	assert(width > 0 && height > 0, "_atlas_upload_glyph: invalid glyph size")
	assert(x >= 0 && y >= 0 && x + width <= ATLAS_DIM && y + height <= ATLAS_DIM)
	stride := _atlas_upload_stride(width)
	pixels := make([]byte, stride * height)
	tt.MakeCodepointBitmap(
		&a.info,
		raw_data(pixels),
		c.int(width),
		c.int(height),
		c.int(stride),
		a.scale,
		a.scale,
		cp,
	)
	wg.QueueWriteTexture(
		ctx.queue,
		&{texture = a.tex, origin = {u32(x), u32(y), 0}},
		raw_data(pixels),
		uint(len(pixels)),
		&{bytesPerRow = u32(stride), rowsPerImage = u32(height)},
		&{u32(width), u32(height), 1},
	)
	delete(pixels)
	return true
}

@(private)
_atlas_gpu_init :: proc(ctx: ^Context, a: ^Atlas) -> bool {
	assert(ctx != nil, "_atlas_gpu_init: nil context")
	assert(a != nil, "_atlas_gpu_init: nil atlas")
	assert(ctx.device != nil && ctx.queue != nil, "_atlas_gpu_init: invalid context")
	a.tex = wg.DeviceCreateTexture(
		ctx.device,
		&{
			usage = {.TextureBinding, .CopyDst},
			dimension = ._2D,
			size = {ATLAS_DIM, ATLAS_DIM, 1},
			format = .R8Unorm,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	if a.tex == nil do return false
	zeros := make([]byte, ATLAS_DIM * ATLAS_DIM)
	wg.QueueWriteTexture(
		ctx.queue,
		&{texture = a.tex},
		raw_data(zeros),
		uint(len(zeros)),
		&{bytesPerRow = ATLAS_DIM, rowsPerImage = ATLAS_DIM},
		&{ATLAS_DIM, ATLAS_DIM, 1},
	)
	delete(zeros)
	a.view = wg.TextureCreateView(a.tex, nil)
	if a.view == nil do return false
	_atlas_build_bind(ctx, a)
	return a.bind != nil
}

@(private)
_atlas_build_bind :: proc(ctx: ^Context, a: ^Atlas) {
	assert(ctx != nil, "_atlas_build_bind: nil context")
	if a.sampler != nil do wg.SamplerRelease(a.sampler)
	if a.bind != nil do wg.BindGroupRelease(a.bind)
	filt: wg.FilterMode = a.filter == .POINT ? .Nearest : .Linear
	a.sampler = wg.DeviceCreateSampler(
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
		{binding = 0, textureView = a.view},
		{binding = 1, sampler = a.sampler},
	}
	a.bind = wg.DeviceCreateBindGroup(
		ctx.device,
		&{layout = ctx.rend.tex_layout, entryCount = 2, entries = raw_data(entries[:])},
	)
}

@(private)
_atlas_entry_destroy :: proc(ctx: ^Context, entry: ^Atlas) {
	assert(ctx != nil, "_atlas_entry_destroy: nil context")
	assert(entry != nil, "_atlas_entry_destroy: nil entry")
	if entry.bind != nil || entry.sampler != nil || entry.view != nil || entry.tex != nil {
		_retire_texture(ctx, entry.bind, entry.sampler, entry.view, entry.tex)
	}
	delete(entry.glyphs)
	delete(entry.data)
	free(entry)
}

@(private)
_atlas_resources_destroy :: proc(ctx: ^Context, resources: ^Atlas_Resources) {
	assert(ctx != nil, "_atlas_resources_destroy: nil context")
	assert(resources != nil, "_atlas_resources_destroy: nil resources")
	for &slot in resources.slots {
		if !slot.occupied do continue
		_atlas_entry_destroy(ctx, slot.entry)
		slot.entry = nil
		slot.occupied = false
	}
	resources^ = {}
}

context_unload_font_impl :: proc(ctx: ^Context, font: Font) {
	assert(ctx != nil, "context_unload_font_impl: nil context")
	slot := _atlas_slot(ctx.id, &ctx.resources.atlases, font._atlas)
	if slot == nil do return
	_atlas_entry_destroy(ctx, slot.entry)
	slot.entry = nil
	slot.occupied = false
	assert(ctx.resources.atlases.count > 0, "context_unload_font_impl: count underflow")
	ctx.resources.atlases.count -= 1
}

UnloadFont :: proc(font: Font) {
	context_unload_font_impl(default_context(), font)
}

context_set_texture_filter_impl :: proc(ctx: ^Context, texture: Texture2D, filter: TextureFilter) {
	assert(ctx != nil, "context_set_texture_filter_impl: nil context")
	if e := context_get_texture(ctx, texture.id); e != nil {
		if e.filter != filter {
			e.filter = filter
			_tex_build_bind(ctx, e)
		}
		return
	}
	a := context_get_atlas(ctx, texture.id)
	if a == nil do return
	if a.filter == filter do return
	a.filter = filter
	_atlas_build_bind(ctx, a)
}

SetTextureFilter :: proc(texture: Texture2D, filter: TextureFilter) {
	context_set_texture_filter_impl(default_context(), texture, filter)
}

// DrawTextEx draws `text` at `position` scaled from the baked px size down to
// `fontSize` (raylib semantics: the atlas may be baked larger for HiDPI).
context_draw_text_ex :: proc(
	ctx: ^Context,
	font: Font,
	text: cstring,
	position: Vector2,
	fontSize, spacing: f32,
	tint: Color,
) {
	assert(ctx != nil, "context_draw_text_ex: nil context")
	a := context_get_atlas(ctx, font._atlas)
	if a == nil do return
	sf := fontSize / a.px
	col := col_f(tint)
	batch_set(ctx, &ctx.rend, .Solid, a.bind)

	pen_x := position.x
	pen_y := position.y
	for cp in string(text) {
		if cp == '\n' {
			pen_x = position.x
			pen_y += a.line_adv * sf
			continue
		}
		gl, ok := a.glyphs[cp]
		if !ok {
			_bake_glyph(ctx, a, cp)
			gl = a.glyphs[cp]
		}
		if gl.valid {
			dx := pen_x + gl.xoff * sf
			dy := pen_y + gl.yoff * sf
			dw := f32(gl.w) * sf
			dh := f32(gl.h) * sf
			uv := Rectangle {
				f32(gl.x) / ATLAS_DIM,
				f32(gl.y) / ATLAS_DIM,
				f32(gl.w) / ATLAS_DIM,
				f32(gl.h) / ATLAS_DIM,
			}
			push_quad(ctx, &ctx.rend, {dx, dy, dw, dh}, uv, col, .Text)
		}
		pen_x += gl.xadvance * sf + spacing
	}
}

DrawTextEx :: proc(
	font: Font,
	text: cstring,
	position: Vector2,
	fontSize, spacing: f32,
	tint: Color,
) {
	context_draw_text_ex(default_context(), font, text, position, fontSize, spacing, tint)
}

context_draw_text_codepoint :: proc(
	ctx: ^Context,
	font: Font,
	codepoint: rune,
	position: Vector2,
	fontSize: f32,
	tint: Color,
) {
	assert(ctx != nil, "context_draw_text_codepoint: nil context")
	buf: [8]byte
	n := 0
	// encode rune to a temporary cstring-ish; simplest is a small local string
	s := utf8_encode(codepoint, buf[:], &n)
	context_draw_text_ex(ctx, font, cstring(raw_data(s)), position, fontSize, 0, tint)
}

DrawTextCodepoint :: proc(
	font: Font,
	codepoint: rune,
	position: Vector2,
	fontSize: f32,
	tint: Color,
) {
	context_draw_text_codepoint(default_context(), font, codepoint, position, fontSize, tint)
}

// DrawTextPro draws text rotated by `rotation` degrees about `origin`, which
// is given relative to `position`.
//
// It composes onto the batch model transform rather than rotating glyph quads
// itself, so a rotated label inside a BeginMode2D camera rotates with the
// camera instead of fighting it. No flush is needed around the change: the
// transform is baked into each vertex as it is emitted, so geometry already in
// the batch keeps the transform it was drawn under.
context_draw_text_pro :: proc(
	ctx: ^Context,
	font: Font,
	text: cstring,
	position, origin: Vector2,
	rotation, fontSize, spacing: f32,
	tint: Color,
) {
	assert(ctx != nil, "context_draw_text_pro: nil context")
	assert(text != nil, "context_draw_text_pro: nil text")
	if rotation == 0 {
		context_draw_text_ex(
			ctx,
			font,
			text,
			{position.x - origin.x, position.y - origin.y},
			fontSize,
			spacing,
			tint,
		)
		return
	}
	// Paired save/restore across the draw: the transform is process state, so
	// an early return inside DrawTextEx must not leak the pivot to the next
	// caller. The defer is the restore half of that pair.
	saved := ctx.rend.model_xf
	defer {
		ctx.rend.model_xf = saved
		assert(ctx.rend.model_xf == saved, "context_draw_text_pro: model transform not restored")
	}

	// Rotate about `position`, then place the text so `origin` lands there.
	pivot := _affine_from_camera_2d(
		Camera2D{offset = position, target = position, rotation = rotation, zoom = 1},
	)
	ctx.rend.model_xf = _affine_compose(saved, pivot)
	context_draw_text_ex(
		ctx,
		font,
		text,
		{position.x - origin.x, position.y - origin.y},
		fontSize,
		spacing,
		tint,
	)
}

DrawTextPro :: proc(
	font: Font,
	text: cstring,
	position, origin: Vector2,
	rotation, fontSize, spacing: f32,
	tint: Color,
) {
	context_draw_text_pro(
		default_context(),
		font,
		text,
		position,
		origin,
		rotation,
		fontSize,
		spacing,
		tint,
	)
}

context_measure_text_ex :: proc(
	ctx: ^Context,
	font: Font,
	text: cstring,
	fontSize, spacing: f32,
) -> Vector2 {
	assert(ctx != nil, "context_measure_text_ex: nil context")
	a := context_get_atlas(ctx, font._atlas)
	if a == nil do return {0, 0}
	sf := fontSize / a.px
	max_w: f32 = 0
	line_w: f32 = 0
	lines: f32 = 1
	for cp in string(text) {
		if cp == '\n' {
			if line_w > max_w do max_w = line_w
			line_w = 0
			lines += 1
			continue
		}
		gl, ok := a.glyphs[cp]
		if !ok {
			_bake_glyph(ctx, a, cp)
			gl = a.glyphs[cp]
		}
		line_w += gl.xadvance * sf + spacing
	}
	if line_w > max_w do max_w = line_w
	return {max_w, lines * a.line_adv * sf}
}

MeasureTextEx :: proc(font: Font, text: cstring, fontSize, spacing: f32) -> Vector2 {
	return context_measure_text_ex(default_context(), font, text, fontSize, spacing)
}

// DrawText and MeasureText live in font_default.odin: they are the default-font
// entry points and exist only when the embedded face is compiled in.

// utf8_encode writes `r` into buf as null-terminated UTF-8, returns the slice.
@(private)
utf8_encode :: proc(r: rune, buf: []byte, n: ^int) -> []byte {
	assert(n != nil)
	assert(len(buf) >= 5)
	assert(r >= 0 && r <= 0x10FFFF && !(r >= 0xD800 && r <= 0xDFFF))
	cp := u32(r)
	i := 0
	switch {
	case cp < 0x80:
		buf[i] = u8(cp); i += 1
	case cp < 0x800:
		buf[i] = u8(0xC0 | (cp >> 6)); i += 1
		buf[i] = u8(0x80 | (cp & 0x3F)); i += 1
	case cp < 0x10000:
		buf[i] = u8(0xE0 | (cp >> 12)); i += 1
		buf[i] = u8(0x80 | ((cp >> 6) & 0x3F)); i += 1
		buf[i] = u8(0x80 | (cp & 0x3F)); i += 1
	case:
		buf[i] = u8(0xF0 | (cp >> 18)); i += 1
		buf[i] = u8(0x80 | ((cp >> 12) & 0x3F)); i += 1
		buf[i] = u8(0x80 | ((cp >> 6) & 0x3F)); i += 1
		buf[i] = u8(0x80 | (cp & 0x3F)); i += 1
	}
	buf[i] = 0
	n^ = i
	return buf[:i + 1]
}

// silence unused import if strings not otherwise referenced
_ :: strings
