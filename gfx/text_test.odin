#+build !js
// ingot:gfx - text-metric regression test. A live raylib baseline can't be
// linked headlessly, so instead of a cross-library diff we lock the invariants
// that keep MeasureTextEx faithful to raylib's model: empty == 0, width is
// exactly linear in font size, a monospace advance is uniform, newlines add
// exactly one line of height, spacing widens text, and a fixed corpus stays
// positive. A headless wgpu device backs the atlas so no window is needed.
package gfx

import "core:c"
import "core:math"
import "core:testing"
import tt "vendor:stb/truetype"
import wg "vendor:wgpu"

FONT_TTF := #load("../assets/fonts/JetBrainsMono-Regular.ttf")
TEXT_TARGET_SIZE :: 64
TEXT_TARGET_PIXEL_COUNT :: TEXT_TARGET_SIZE * TEXT_TARGET_SIZE
TEXT_CODEPOINT_RANGES := [14][2]rune {
	{0x0020, 0x007E},
	{0x00A0, 0x00FF},
	{0x0100, 0x024F},
	{0x2000, 0x206F},
	{0x2190, 0x21FF},
	{0x2200, 0x22FF},
	{0x2300, 0x23FF},
	{0x2500, 0x257F},
	{0x2580, 0x259F},
	{0x25A0, 0x25FF},
	{0x2600, 0x26FF},
	{0x2700, 0x27BF},
	{0x2800, 0x28FF},
	{0x2B00, 0x2B73},
}

text_test_codepoints :: proc() -> []rune {
	count := 0
	for value in TEXT_CODEPOINT_RANGES {
		count += int(value[1] - value[0]) + 1
	}
	result := make([]rune, count)
	index := 0
	for value in TEXT_CODEPOINT_RANGES {
		for codepoint := value[0]; codepoint <= value[1]; codepoint += 1 {
			result[index] = codepoint
			index += 1
		}
	}
	return result
}

@(test)
text_atlas_upload_stride_is_aligned_and_bounded :: proc(t: ^testing.T) {
	testing.expect_value(t, _atlas_upload_stride(1), ATLAS_UPLOAD_ALIGN)
	testing.expect_value(t, _atlas_upload_stride(ATLAS_UPLOAD_ALIGN), ATLAS_UPLOAD_ALIGN)
	testing.expect_value(t, _atlas_upload_stride(ATLAS_UPLOAD_ALIGN + 1), ATLAS_UPLOAD_ALIGN * 2)
	for width_int in 1 ..= ATLAS_DIM {
		width := i32(width_int)
		stride := _atlas_upload_stride(width)
		testing.expect(t, stride >= width)
		testing.expect(t, stride - width < ATLAS_UPLOAD_ALIGN)
	}
}

@(test)
text_public_limits_are_named_and_consistent :: proc(t: ^testing.T) {
	testing.expect(t, FONT_DATA_BYTES_MAX > 0)
	testing.expect(t, FONT_CODEPOINTS_MAX > 0)
	testing.expect(t, FONT_PIXEL_SIZE_MAX > 0)
	testing.expect(t, FONT_GLYPHS_MAX > 0)
	testing.expect(t, FONT_GLYPHS_MAX <= FONT_CODEPOINTS_MAX)
	testing.expect(t, FONT_GLYPHS_MAX < max(int))
}

text_test_atlas_accounting :: proc(t: ^testing.T, pixel_size: i32) {
	codepoints := text_test_codepoints()
	defer delete(codepoints)
	font := LoadFontFromMemory(
		".ttf",
		raw_data(FONT_TTF),
		i32(len(FONT_TTF)),
		pixel_size,
		raw_data(codepoints),
		i32(len(codepoints)),
	)
	defer UnloadFont(font)
	atlas := context_get_atlas(g, font._atlas)
	testing.expect(t, atlas != nil, "accounting font should own an atlas")
	if atlas == nil do return
	valid, missing, zero_area, packing_failed := 0, 0, 0, 0
	for codepoint in codepoints {
		glyph := atlas.glyphs[codepoint]
		glyph_index := tt.FindGlyphIndex(&atlas.info, codepoint)
		if glyph_index == 0 && codepoint != ' ' {
			missing += 1
		} else {
			ix0, iy0, ix1, iy1: c.int
			tt.GetCodepointBitmapBox(
				&atlas.info,
				codepoint,
				atlas.scale,
				atlas.scale,
				&ix0,
				&iy0,
				&ix1,
				&iy1,
			)
			if ix1 <= ix0 || iy1 <= iy0 {
				zero_area += 1
			} else if glyph.valid {
				valid += 1
			} else {
				packing_failed += 1
			}
		}
	}
	for codepoint := rune(0x20); codepoint <= 0x7E; codepoint += 1 {
		glyph := atlas.glyphs[codepoint]
		if codepoint == ' ' {
			testing.expect(t, glyph.xadvance > 0, "ASCII space should retain advance")
		} else {
			testing.expectf(
				t,
				glyph.valid,
				"ASCII U+%04X should be drawable at %dpx",
				codepoint,
				pixel_size,
			)
		}
	}
	testing.expectf(
		t,
		packing_failed == 0,
		"%dpx atlas exhausted: requested=%d valid=%d missing=%d zero=%d " +
		"packing_failed=%d cursor=(%d,%d) shelf=%d",
		pixel_size,
		len(codepoints),
		valid,
		missing,
		zero_area,
		packing_failed,
		atlas.cur_x,
		atlas.cur_y,
		atlas.shelf_h,
	)
}

text_target_has_non_clear_pixel :: proc(pixels: []u8, clear: Color) -> bool {
	assert(len(pixels) == TEXT_TARGET_PIXEL_COUNT * 4)
	for pixel_index in 0 ..< TEXT_TARGET_PIXEL_COUNT {
		byte_index := pixel_index * 4
		if pixels[byte_index + 0] != clear.r ||
		   pixels[byte_index + 1] != clear.g ||
		   pixels[byte_index + 2] != clear.b ||
		   pixels[byte_index + 3] != clear.a {
			return true
		}
	}
	return false
}

text_target_region_has_non_clear_pixel :: proc(
	pixels: []u8,
	clear: Color,
	x0, y0, width, height: int,
) -> bool {
	assert(len(pixels) == TEXT_TARGET_PIXEL_COUNT * 4)
	assert(x0 >= 0 && y0 >= 0 && width > 0 && height > 0)
	assert(x0 + width <= TEXT_TARGET_SIZE && y0 + height <= TEXT_TARGET_SIZE)
	for y in y0 ..< y0 + height {
		for x in x0 ..< x0 + width {
			byte_index := (y * TEXT_TARGET_SIZE + x) * 4
			if pixels[byte_index + 0] != clear.r ||
			   pixels[byte_index + 1] != clear.g ||
			   pixels[byte_index + 2] != clear.b ||
			   pixels[byte_index + 3] != clear.a {
				return true
			}
		}
	}
	return false
}

test_lazy_glyph_first_target_paint :: proc(t: ^testing.T) {
	initial_codepoints := [1]rune{' '}
	font := LoadFontFromMemory(
		".ttf",
		raw_data(FONT_TTF),
		i32(len(FONT_TTF)),
		32,
		raw_data(initial_codepoints[:]),
		len(initial_codepoints),
	)
	defer {
		UnloadFont(font)
		if !g.frame.has_frame do _flush_retired(g)
	}
	testing.expect(t, font.glyphCount == 1, "font should contain only the initial glyph")

	atlas := context_get_atlas(g, font._atlas)
	testing.expect(t, atlas != nil, "font should own an atlas")
	if atlas == nil do return
	_, was_baked := atlas.glyphs['→']
	testing.expect(t, !was_baked, "test glyph should begin unbaked")
	width := MeasureTextEx(font, "→", 32, 0).x
	testing.expect(t, width > 0, "measurement should use the lazy glyph advance")
	testing.expect(t, atlas.glyphs['→'].valid, "measurement should bake and upload the glyph")

	restore_initialized := g.initialized
	g.initialized = true
	defer {g.initialized = restore_initialized}
	frame_ready := renderer_frame_begin(g, &g.rend)
	testing.expect(t, frame_ready, "text target test should acquire a stream slot")
	if !frame_ready do return
	g.frame.has_frame = true
	defer {
		g.frame.has_frame = false
		_stream_slot_abandon(&g.rend)
		_flush_retired(g)
	}

	target := LoadRenderTexture(TEXT_TARGET_SIZE, TEXT_TARGET_SIZE)
	testing.expect(t, target.texture.id != 0, "text target should load")
	if target.texture.id == 0 do return
	defer UnloadRenderTexture(target)
	clear := Color{17, 31, 47, 255}

	BeginTextureMode(target)
	ClearBackground(clear)
	EndTextureMode()
	clear_pixels, clear_ok := context_screenshot_pixels(g, target)
	testing.expect(t, clear_ok, "clear target should be readable")
	if clear_ok {
		testing.expect(t, !text_target_has_non_clear_pixel(clear_pixels, clear))
		delete(clear_pixels)
	}

	BeginTextureMode(target)
	DrawTextCodepoint(font, '→', {4, 4}, 32, WHITE)
	EndTextureMode()
	painted_pixels, painted_ok := context_screenshot_pixels(g, target)
	testing.expect(t, painted_ok, "painted target should be readable")
	if painted_ok {
		testing.expect(t, text_target_has_non_clear_pixel(painted_pixels, clear))
	}

	BeginTextureMode(target)
	ClearBackground(clear)
	DrawTextCodepoint(font, '→', {4, 4}, 32, WHITE)
	EndTextureMode()
	repainted_pixels, repainted_ok := context_screenshot_pixels(g, target)
	testing.expect(t, repainted_ok, "repainted target should be readable")
	if painted_ok && repainted_ok {
		testing.expect_value(t, len(repainted_pixels), len(painted_pixels))
		for index in 0 ..< len(painted_pixels) {
			testing.expect_value(t, repainted_pixels[index], painted_pixels[index])
		}
	}
	if painted_ok do delete(painted_pixels)
	if repainted_ok do delete(repainted_pixels)
}

test_lazy_glyph_batch_boundary :: proc(t: ^testing.T, font: Font) {
	atlas := context_get_atlas(g, font._atlas)
	testing.expect(t, atlas != nil, "boundary font should own an atlas")
	if atlas == nil do return
	cold: rune = '→'
	delete_key(&atlas.glyphs, cold)

	restore_initialized := g.initialized
	g.initialized = true
	defer {g.initialized = restore_initialized}
	frame_ready := renderer_frame_begin(g, &g.rend)
	testing.expect(t, frame_ready, "boundary test should acquire a stream slot")
	if !frame_ready do return
	g.frame.has_frame = true
	defer {
		g.frame.has_frame = false
		_stream_slot_abandon(&g.rend)
		_flush_retired(g)
	}
	target := LoadRenderTexture(TEXT_TARGET_SIZE, TEXT_TARGET_SIZE)
	testing.expect(t, target.texture.id != 0, "boundary target should load")
	if target.texture.id == 0 do return
	defer UnloadRenderTexture(target)
	clear := Color{23, 37, 53, 255}
	BeginTextureMode(target)
	ClearBackground(clear)
	for _ in 0 ..< BATCH_MAX_VERTICES / 4 {
		DrawTextCodepoint(font, 'A', {-128, -128}, 32, WHITE)
	}
	testing.expect_value(t, len(g.rend.verts), BATCH_MAX_VERTICES)
	DrawTextCodepoint(font, cold, {4, 4}, 32, WHITE)
	testing.expect(t, atlas.glyphs[cold].valid, "boundary glyph should bake and upload")
	EndTextureMode()

	pixels, ok := context_screenshot_pixels(g, target)
	testing.expect(t, ok, "boundary target should be readable")
	if ok {
		testing.expect(t, text_target_region_has_non_clear_pixel(pixels, clear, 0, 0, 48, 48))
		delete(pixels)
	}
}

test_font_measure_invariants :: proc(t: ^testing.T, font: Font) {
	testing.expect(t, font.glyphCount > 0, "font should bake glyphs")
	testing.expect(t, MeasureTextEx(font, "", 16, 0).x == 0, "empty width == 0")

	w14 := MeasureTextEx(font, "The quick brown fox", 14, 0).x
	w20 := MeasureTextEx(font, "The quick brown fox", 20, 0).x
	testing.expect(t, w14 > 0 && w20 > 0, "widths positive")
	ratio := w20 / w14
	testing.expectf(
		t,
		math.abs(ratio - 20.0 / 14.0) < 1e-4,
		"width should scale linearly with size, got ratio %v",
		ratio,
	)

	one := MeasureTextEx(font, "m", 16, 0).x
	five := MeasureTextEx(font, "mmmmm", 16, 0).x
	testing.expectf(
		t,
		math.abs(five - 5 * one) < 1e-3,
		"monospace advance should be uniform: 1=%v 5=%v",
		one,
		five,
	)

	h1 := MeasureTextEx(font, "abc", 16, 0).y
	h2 := MeasureTextEx(font, "abc\ndef", 16, 0).y
	testing.expectf(
		t,
		math.abs(h2 - 2 * h1) < 1e-3,
		"two lines == 2x one line: h1=%v h2=%v",
		h1,
		h2,
	)

	base := MeasureTextEx(font, "abcd", 16, 0).x
	spaced := MeasureTextEx(font, "abcd", 16, 2).x
	testing.expect(t, spaced > base, "positive spacing widens text")

	corpus := []cstring{"ingot", "WebGPU", "raylib", "func main() {}", "AaBb 0123"}
	for size in ([]f32{14, 16, 20}) {
		for text in corpus {
			testing.expectf(
				t,
				MeasureTextEx(font, text, size, 0).x > 0,
				"corpus width positive for %v @ %v",
				text,
				size,
			)
		}
	}
}

@(test)
test_measure_metrics :: proc(t: ^testing.T) {
	gfx_shared_test_lock()
	defer gfx_shared_test_unlock()
	// --- headless device bring-up (no window/surface) ---
	g.instance = wg.CreateInstance()
	ares: Adapter_Res
	wg.InstanceRequestAdapter(
		g.instance,
		nil,
		{mode = .AllowProcessEvents, callback = _on_adapter, userdata1 = &ares},
	)
	// tigerstyle: allow-unbounded-loop -- adapter callback ends test device setup
	for !ares.done {wg.InstanceProcessEvents(g.instance)}
	g.adapter = ares.adapter

	dres: Device_Res
	wg.AdapterRequestDevice(
		g.adapter,
		nil,
		{mode = .AllowProcessEvents, callback = _on_device, userdata1 = &dres},
	)
	// tigerstyle: allow-unbounded-loop -- device callback ends test device setup
	for !dres.done {wg.InstanceProcessEvents(g.instance)}
	g.device = dres.device
	g.queue = wg.DeviceGetQueue(g.device)
	g.format = .BGRA8Unorm
	_submission_init(&g.submissions, g)
	renderer_ready := false
	defer {
		_flush_retired(g)
		delete(g.resources.retire)
		if renderer_ready do renderer_shutdown(&g.rend)
		testing.expect(t, _submission_shutdown(&g.submissions))
		wg.QueueRelease(g.queue)
		wg.DeviceRelease(g.device)
		wg.AdapterRelease(g.adapter)
		wg.InstanceRelease(g.instance)
		g.queue = nil
		g.device = nil
		g.adapter = nil
		g.instance = nil
	}
	// The test's device is real, so the stream pools must allocate; a false
	// here means the harness itself is broken, not that a device degraded.
	renderer_ready = renderer_init(g, &g.rend)
	testing.expect(t, renderer_ready, "text test harness: renderer_init failed")
	if !renderer_ready do return

	cps: [95]rune
	for i in 0 ..< 95 {cps[i] = rune(32 + i)}
	f := LoadFontFromMemory(
		".ttf",
		raw_data(FONT_TTF),
		i32(len(FONT_TTF)),
		32,
		raw_data(cps[:]),
		95,
	)
	defer UnloadFont(f)

	test_font_measure_invariants(t, f)
	metrics, metrics_ok := context_font_metrics(g, f, 32)
	testing.expect(t, metrics_ok, "loaded font should expose metrics")
	testing.expect(t, metrics.ascent > 0 && metrics.descent >= 0)
	testing.expect(t, metrics.line_gap >= 0 && metrics.line_advance > 0)
	_, stale_ok := context_font_metrics(g, Font{}, 32)
	testing.expect(t, !stale_ok, "invalid font metrics must fail")
	text_test_atlas_accounting(t, 32)
	text_test_atlas_accounting(t, 64)
	atlas := context_get_atlas(g, f._atlas)
	testing.expect(t, atlas != nil, "font should own an atlas")
	for codepoint in ([]rune{'A', 'é', '→', '─', '█'}) {
		testing.expectf(
			t,
			_bake_glyph(g, atlas, codepoint),
			"font should contain U+%04X",
			codepoint,
		)
		testing.expectf(t, atlas.glyphs[codepoint].valid, "glyph U+%04X should render", codepoint)
	}
	missing: rune = 0xE000
	testing.expect(t, !_bake_glyph(g, atlas, missing), "unbundled icon glyph should be absent")
	testing.expect(t, !atlas.glyphs[missing].valid, "missing glyph should use fallback metrics")

	test_lazy_glyph_first_target_paint(t)
	test_lazy_glyph_batch_boundary(t, f)
	test_default_font_is_real(t)
	test_batched_bake_matches_per_glyph(t)
	test_unbaked_glyph_reads_as_present(t)
	_flush_retired(g)
}

// test_batched_bake_matches_per_glyph pins the load-time batched bake (one
// staging image, one texture write) to the per-glyph lazy path: both must
// pack every glyph at the same cell with the same metrics, or text laid out
// from one would sample the wrong texels of the other.
test_batched_bake_matches_per_glyph :: proc(t: ^testing.T) {
	cps := make([dynamic]rune, context.temp_allocator)
	for cp in rune(0x20) ..= rune(0x7E) do append(&cps, cp)
	for cp in rune(0xA0) ..= rune(0xFF) do append(&cps, cp)
	for cp in rune(0x2500) ..= rune(0x257F) do append(&cps, cp)
	append(&cps, rune(0xE000))

	batched := LoadFontFromMemory(
		".ttf",
		raw_data(FONT_TTF),
		i32(len(FONT_TTF)),
		40,
		raw_data(cps[:]),
		i32(len(cps)),
	)
	defer UnloadFont(batched)
	lazy := LoadFontFromMemory(".ttf", raw_data(FONT_TTF), i32(len(FONT_TTF)), 40, nil, 0)
	defer UnloadFont(lazy)

	batched_atlas := context_get_atlas(g, batched._atlas)
	lazy_atlas := context_get_atlas(g, lazy._atlas)
	testing.expect(t, batched_atlas != nil && lazy_atlas != nil, "both fonts should own an atlas")
	if batched_atlas == nil || lazy_atlas == nil do return
	testing.expect(
		t,
		len(lazy_atlas.glyphs) == 0,
		"a font loaded without codepoints bakes nothing",
	)

	baked: i32 = 0
	for cp in cps {
		if _bake_glyph(g, lazy_atlas, cp) do baked += 1
	}
	testing.expectf(
		t,
		batched.glyphCount == baked,
		"baked count %d != %d",
		batched.glyphCount,
		baked,
	)
	testing.expect(t, len(batched_atlas.glyphs) == len(lazy_atlas.glyphs))
	for cp in cps {
		want, want_ok := lazy_atlas.glyphs[cp]
		got, got_ok := batched_atlas.glyphs[cp]
		testing.expectf(t, want_ok && got_ok, "U+%04X missing from a glyph table", cp)
		testing.expectf(t, got == want, "U+%04X: batched %v != per-glyph %v", cp, got, want)
	}
	testing.expect(
		t,
		batched_atlas.cur_x == lazy_atlas.cur_x && batched_atlas.cur_y == lazy_atlas.cur_y,
	)
	testing.expect(t, batched_atlas.shelf_h == lazy_atlas.shelf_h)
	testing.expect(t, !batched_atlas.glyphs[0xE000].valid, "a missing glyph stays invalid")
}

// test_unbaked_glyph_reads_as_present covers the web eager/lazy split: a
// codepoint outside the eager ranges is not baked at load, but the font
// still has it, so fallback selection must not skip this face.
test_unbaked_glyph_reads_as_present :: proc(t: ^testing.T) {
	cps: [95]rune
	for i in 0 ..< 95 {cps[i] = rune(32 + i)}
	f := LoadFontFromMemory(
		".ttf",
		raw_data(FONT_TTF),
		i32(len(FONT_TTF)),
		24,
		raw_data(cps[:]),
		95,
	)
	defer UnloadFont(f)
	atlas := context_get_atlas(g, f._atlas)
	testing.expect(t, atlas != nil, "font should own an atlas")
	if atlas == nil do return
	box: rune = 0x2500
	_, baked := atlas.glyphs[box]
	testing.expect(t, !baked, "box drawing must not be baked by an ASCII-only load")
	testing.expect(
		t,
		context_font_has_glyph_impl(g, f, box),
		"an unbaked glyph the font has must read as present",
	)
	testing.expect(
		t,
		!context_font_has_glyph_impl(g, f, 0xE000),
		"a glyph the font lacks must read as absent",
	)
	testing.expect(t, _bake_glyph(g, atlas, box), "the lazy path must still bake it on demand")
	testing.expect(t, atlas.glyphs[box].valid)
}

// test_default_font_is_real checks that DrawText/MeasureText are backed by an
// actual baked atlas rather than the stub they replaced, which drew nothing and
// guessed width as len(text)*fontSize/2. It shares this test's headless device
// instead of standing up a second one, because gfx tests run concurrently
// against the same default context.
test_default_font_is_real :: proc(t: ^testing.T) {
	// _default_font refuses to bake until the context reports a live device.
	restore_initialized := g.initialized
	g.initialized = true
	defer {
		if font := g.resources.default_font; font.glyphCount > 0 do UnloadFont(font)
		g.resources.default_font = {}
		g.resources.default_font_baked = false
		g.initialized = restore_initialized
	}

	font, ok := _default_font(g)
	testing.expect(t, ok, "default font should bake")
	testing.expect(t, font.glyphCount > 0, "default font should bake glyphs")
	testing.expect(t, context_get_atlas(g, font._atlas) != nil, "default font should own an atlas")

	again, ok_again := _default_font(g)
	testing.expect(t, ok_again, "cached default font should stay valid")
	testing.expect_value(t, again._atlas, font._atlas)

	// The old stub returned len(text)*fontSize/2 for any input, so an empty
	// string measured 0 by coincidence while every real string was fiction.
	testing.expect_value(t, MeasureText("", 16), i32(0))

	width := MeasureText("The quick brown fox", 16)
	testing.expect(t, width > 0, "default-font width should be positive")

	// MeasureText must describe what DrawText renders: both read this atlas.
	expected := MeasureTextEx(font, "The quick brown fox", 16, 0).x
	testing.expect_value(t, width, i32(expected))

	// A proportional measurement tracks the font, not the character count.
	narrow := MeasureText("iiii", 16)
	wide := MeasureText("MMMM", 16)
	testing.expect(t, narrow > 0 && wide > 0, "both widths positive")
	testing.expectf(
		t,
		MeasureText("The quick brown fox", 32) > width,
		"width should grow with font size, got %v at 16",
		width,
	)
}
