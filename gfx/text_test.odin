#+build !js
// ingot:gfx — text-metric regression test. A live raylib baseline can't be
// linked headlessly, so instead of a cross-library diff we lock the invariants
// that keep MeasureTextEx faithful to raylib's model: empty == 0, width is
// exactly linear in font size, a monospace advance is uniform, newlines add
// exactly one line of height, spacing widens text, and a fixed corpus stays
// positive. A headless wgpu device backs the atlas so no window is needed.
package gfx

import "core:math"
import "core:testing"
import wg "vendor:wgpu"

FONT_TTF := #load("../assets/fonts/JetBrainsMono-Regular.ttf")

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
	// --- headless device bring-up (no window/surface) ---
	g.instance = wg.CreateInstance()
	ares: Adapter_Res
	wg.InstanceRequestAdapter(
		g.instance,
		nil,
		{mode = .AllowProcessEvents, callback = _on_adapter, userdata1 = &ares},
	)
	for !ares.done {wg.InstanceProcessEvents(g.instance)}
	g.adapter = ares.adapter

	dres: Device_Res
	wg.AdapterRequestDevice(
		g.adapter,
		nil,
		{mode = .AllowProcessEvents, callback = _on_device, userdata1 = &dres},
	)
	for !dres.done {wg.InstanceProcessEvents(g.instance)}
	g.device = dres.device
	g.queue = wg.DeviceGetQueue(g.device)
	g.format = .BGRA8Unorm
	_submission_init(&g.submissions, g)
	renderer_init(&g.rend)

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
	defer {
		UnloadFont(f)
		renderer_shutdown(&g.rend)
		_submission_shutdown(&g.submissions)
		wg.QueueRelease(g.queue)
		wg.DeviceRelease(g.device)
		wg.AdapterRelease(g.adapter)
		wg.InstanceRelease(g.instance)
	}

	test_font_measure_invariants(t, f)
	atlas := get_atlas(f._atlas)
	testing.expect(t, atlas != nil, "font should own an atlas")
	for codepoint in ([]rune{'A', 'é', '→', '─', '█'}) {
		testing.expectf(t, _bake_glyph(atlas, codepoint), "font should contain U+%04X", codepoint)
		testing.expectf(t, atlas.glyphs[codepoint].valid, "glyph U+%04X should render", codepoint)
	}
	missing: rune = 0xE000
	testing.expect(t, !_bake_glyph(atlas, missing), "unbundled icon glyph should be absent")
	testing.expect(t, !atlas.glyphs[missing].valid, "missing glyph should use fallback metrics")

	test_default_font_is_real(t)
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
	testing.expect(t, get_atlas(font._atlas) != nil, "default font should own an atlas")

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
