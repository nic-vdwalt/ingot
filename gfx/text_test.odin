#+build !js
// ingot:gfx — text-metric regression test. A live raylib baseline can't be
// linked headlessly, so instead of a cross-library diff we lock the invariants
// that keep MeasureTextEx faithful to raylib's model: empty == 0, width is
// exactly linear in font size, a monospace advance is uniform, newlines add
// exactly one line of height, spacing widens text, and a fixed corpus stays
// positive. A headless wgpu device backs the atlas so no window is needed.
package gfx

import "core:testing"
import "core:math"
import wg "vendor:wgpu"

FONT_TTF := #load("../assets/fonts/JetBrainsMonoNerdFontMono-Regular.ttf")

@(test)
test_measure_metrics :: proc(t: ^testing.T) {
	// --- headless device bring-up (no window/surface) ---
	g.instance = wg.CreateInstance()
	ares: Adapter_Res
	wg.InstanceRequestAdapter(g.instance, nil, {
		mode = .AllowProcessEvents, callback = _on_adapter, userdata1 = &ares,
	})
	for !ares.done { wg.InstanceProcessEvents(g.instance) }
	g.adapter = ares.adapter

	dres: Device_Res
	wg.AdapterRequestDevice(g.adapter, nil, {
		mode = .AllowProcessEvents, callback = _on_device, userdata1 = &dres,
	})
	for !dres.done { wg.InstanceProcessEvents(g.instance) }
	g.device = dres.device
	g.queue = wg.DeviceGetQueue(g.device)
	g.format = .BGRA8Unorm
	_submission_init(&g.submissions)
	renderer_init(&g.rend)

	cps: [95]rune
	for i in 0 ..< 95 { cps[i] = rune(32 + i) }
	f := LoadFontFromMemory(".ttf", raw_data(FONT_TTF), i32(len(FONT_TTF)), 32, raw_data(cps[:]), 95)
	defer {
		UnloadFont(f)
		renderer_shutdown(&g.rend)
		_submission_shutdown(&g.submissions)
		wg.QueueRelease(g.queue)
		wg.DeviceRelease(g.device)
		wg.AdapterRelease(g.adapter)
		wg.InstanceRelease(g.instance)
	}

	testing.expect(t, f.glyphCount > 0, "font should bake glyphs")

	// empty string measures to zero width
	testing.expect(t, MeasureTextEx(f, "", 16, 0).x == 0, "empty width == 0")

	// width is exactly linear in font size (advance * fontSize/px)
	w14 := MeasureTextEx(f, "The quick brown fox", 14, 0).x
	w20 := MeasureTextEx(f, "The quick brown fox", 20, 0).x
	testing.expect(t, w14 > 0 && w20 > 0, "widths positive")
	ratio := w20 / w14
	testing.expectf(t, math.abs(ratio - 20.0 / 14.0) < 1e-4,
		"width should scale linearly with size, got ratio %v", ratio)

	// monospace: N glyphs advance to N * single-glyph width
	one := MeasureTextEx(f, "m", 16, 0).x
	five := MeasureTextEx(f, "mmmmm", 16, 0).x
	testing.expectf(t, math.abs(five - 5 * one) < 1e-3,
		"monospace advance should be uniform: 1=%v 5=%v", one, five)

	// newline adds exactly one line of height
	h1 := MeasureTextEx(f, "abc", 16, 0).y
	h2 := MeasureTextEx(f, "abc\ndef", 16, 0).y
	testing.expectf(t, math.abs(h2 - 2 * h1) < 1e-3,
		"two lines == 2x one line: h1=%v h2=%v", h1, h2)

	// positive spacing widens text
	base := MeasureTextEx(f, "abcd", 16, 0).x
	spaced := MeasureTextEx(f, "abcd", 16, 2).x
	testing.expect(t, spaced > base, "positive spacing widens text")

	// fixed corpus stays positive at each size
	corpus := []cstring{"ingot", "WebGPU", "raylib", "func main() {}", "AaBb 0123"}
	for s in ([]f32{14, 16, 20}) {
		for c in corpus {
			testing.expectf(t, MeasureTextEx(f, c, s, 0).x > 0,
				"corpus width positive for %v @ %v", c, s)
		}
	}
}