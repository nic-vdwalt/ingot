#+build js
// ingot:gfx - browser frame loop (inversion of control).
//
// Native code owns its loop (`for !WindowShouldClose()`), but a browser will not
// allow an infinite loop - it owns the loop and calls back once per animation
// frame. So on web, run() stores the app's frame callback and returns; the JS
// shell's requestAnimationFrame drives the exported `step` below, which runs one
// frame once the GPU device has finished resolving (see platform_web.odin's
// async init). This keeps the *same* app source (main → run(frame)) working on
// both targets.
package gfx

@(private)
g_web_callback: Run_Callback

run_data :: proc(frame: Run_Data_Proc, userdata: rawptr) -> bool {
	if frame == nil || g_web_callback.active do return false
	g_web_callback = {
		frame    = frame,
		userdata = userdata,
		active   = true,
	}
	return true
}

@(private)
run_compat_frame :: proc(userdata: rawptr) {
	frame := cast(Run_Proc)userdata
	assert(frame != nil, "run_compat_frame: nil frame")
	frame()
}

// run stores the per-frame callback and returns immediately. The browser's
// requestAnimationFrame loop calls `step` each tick.
run :: proc(frame: Run_Proc) {
	assert(frame != nil, "run: nil frame")
	_ = run_data(run_compat_frame, cast(rawptr)frame)
}

// step is exported to WASM and invoked once per animation frame by the JS shell
// (web/ingot_web.js). It runs one frame of the app callback once the device is
// ready; before then it no-ops so the browser keeps polling. Returning true
// keeps the RAF loop alive.
//
// Event-driven idle gate: when the app opted into .Event_Driven and no settle
// frames or due deadlines remain, the app frame is skipped entirely (no
// BeginDrawing, no GPU work) while rAF keeps ticking cheaply. Input exports
// (input_web.odin) mark activity, so the next tick after an event runs a real
// frame. A periodic floor frame still runs every IDLE_MAX_WAIT seconds
// (_idle_web_gate) so data arriving outside the input path — WS messages
// queued JS-side, HTTP completions — becomes visible without user input,
// matching the native pump's bounded-wait floor. Returning false instead
// would end the module permanently (odin.js stops scheduling), so the loop
// always stays alive.
@(private)
web_step_context :: proc(ctx: ^Context, now: f64) -> bool {
	assert(ctx != nil, "web_step_context: nil context")
	if !ctx.initialized do return true
	if !_idle_web_gate(&ctx.idle, now) do return true
	input_poll(ctx)
	if g_web_callback.active {
		assert(g_web_callback.frame != nil, "web_step_context: active callback has no frame")
		g_web_callback.frame(g_web_callback.userdata)
	}
	return true
}

@(export)
step :: proc(dt: f32) -> bool {
	context = g_web_ctx
	ctx := default_context()
	return web_step_context(ctx, platform_now() - ctx.start_time_s)
}
