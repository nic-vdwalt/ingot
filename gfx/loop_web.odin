#+build js
// ingot:gfx — browser frame loop (inversion of control).
//
// Native code owns its loop (`for !WindowShouldClose()`), but a browser will not
// allow an infinite loop — it owns the loop and calls back once per animation
// frame. So on web, run() stores the app's frame callback and returns; the JS
// shell's requestAnimationFrame drives the exported `step` below, which runs one
// frame once the GPU device has finished resolving (see platform_web.odin's
// async init). This keeps the *same* app source (main → run(frame)) working on
// both targets.
package gfx

@(private) g_web_frame: Run_Proc

// run stores the per-frame callback and returns immediately. The browser's
// requestAnimationFrame loop calls `step` each tick.
run :: proc(frame: Run_Proc) {
	g_web_frame = frame
}

// step is exported to WASM and invoked once per animation frame by the JS shell
// (web/ingot_web.js). It runs one frame of the app callback once the device is
// ready; before then it no-ops so the browser keeps polling. Returning true
// keeps the RAF loop alive.
@(export)
step :: proc(dt: f32) -> bool {
	context = g_web_ctx
	if !g.initialized {
		return true // GPU device still resolving; retry next frame
	}
	if g_web_frame != nil {
		g_web_frame()
	}
	return true
}
