#+build js
// ingot:gfx - web stub for the render-target readback path.
//
// The capture path exists to produce reproducible media and visual-regression
// fences from a desktop build; the browser has no filesystem to write a PNG to.
// Keeping the signature present means gallery and example code that captures
// compiles unchanged for WASM instead of needing its own `when` guards.
package gfx

import wg "vendor:wgpu"

// Mirrors the native record so Context has the same layout on every target.
// The web path never registers a screenshot map, so nothing is ever armed.
Screenshot_Map :: struct {
	staging: wg.Buffer,
	status:  wg.MapAsyncStatus,
	armed:   bool,
	done:    bool,
	stray:   u32,
}

@(private)
_screenshot_retire :: proc(ctx: ^Context, wait: bool) -> bool {
	assert(ctx != nil, "_screenshot_retire: nil context")
	assert(!ctx.screenshot.armed, "_screenshot_retire: web context armed a screenshot map")
	return true
}

// save_render_texture_png always fails on web: there is no filesystem destination.
// Native behaviour is documented in screenshot.odin.
save_render_texture_png :: proc(target: RenderTexture2D, path: string) -> bool {
	assert(len(path) >= 0, "save_render_texture_png: invalid path slice")
	assert(target.id == target.texture.id, "save_render_texture_png: torn target handle")
	return false
}
