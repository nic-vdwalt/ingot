#+build js
// ingot:gfx - web stub for the render-target readback path.
//
// The capture path exists to produce reproducible media and visual-regression
// fences from a desktop build; the browser has no filesystem to write a PNG to.
// Keeping the signature present means gallery and example code that captures
// compiles unchanged for WASM instead of needing its own `when` guards.
package gfx

// SaveRenderTexturePng always fails on web: there is no filesystem destination.
// Native behaviour is documented in screenshot.odin.
SaveRenderTexturePng :: proc(target: RenderTexture2D, path: string) -> bool {
	assert(len(path) >= 0, "SaveRenderTexturePng: invalid path slice")
	assert(target.id == target.texture.id, "SaveRenderTexturePng: torn target handle")
	return false
}
