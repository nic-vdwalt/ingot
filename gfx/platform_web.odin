#+build js
// ingot:gfx — browser (WASM + WebGPU) platform backend.
//
// Compiled only on the JS/WASM target. Provides the same platform seam the
// native backend does, but sourced from the browser: a canvas surface instead
// of a GLFW window, DOM events instead of GLFW callbacks, performance.now
// instead of the monotonic OS clock. This file is filled in across the web
// milestones:
//   - Step 2: real canvas surface + performance.now timing
//   - Step 4: DOM input marshalling
// The stubs below keep the shared gfx core compiling on web from Step 1.
package gfx

import "base:runtime"
import wg "vendor:wgpu"

// JS runtime bridges (provided by web/ingot_web.js as the "ingot" import
// module). Timing + canvas geometry.
foreign import dom "ingot"
@(default_calling_convention = "c")
foreign dom {
	@(link_name = "ingot_perf_now")           _js_perf_now   :: proc() -> f64 ---
	@(link_name = "ingot_canvas_css_width")    _js_css_width  :: proc() -> f64 ---
	@(link_name = "ingot_canvas_css_height")   _js_css_height :: proc() -> f64 ---
	@(link_name = "ingot_device_pixel_ratio")  _js_dpr        :: proc() -> f64 ---
	@(link_name = "ingot_set_cursor")          _js_set_cursor :: proc(cur: i32) ---
}

// A non-nil sentinel so the shared `g.win == nil` guards treat the web target as
// "window present" (there is no OS window; the canvas plays that role).
@(private) WEB_WIN_SENTINEL :: Window_Handle(uintptr(1))

// Captured Odin context for the "c" GPU callbacks (they run from the browser
// event loop, where Odin's implicit context isn't available). Set in
// platform_create_window, which runs under main's context.
@(private) g_web_ctx: runtime.Context

// --- window / surface / lifecycle ------------------------------------------

@(private)
platform_create_window :: proc(width, height: i32, title: cstring, flags: ConfigFlags) -> bool {
	g_web_ctx = context
	g.win = WEB_WIN_SENTINEL
	g.width, g.height = width, height
	g.fb_width, g.fb_height = width, height
	g.dpi = 1
	return true
}

@(private)
platform_create_surface :: proc(instance: wg.Instance) -> wg.Surface {
	return wg.InstanceCreateSurface(instance, &wg.SurfaceDescriptor{
		nextInChain = &wg.SurfaceSourceCanvasHTMLSelector{
			chain    = {sType = .SurfaceSourceCanvasHTMLSelector},
			selector = "#ingot-canvas",
		},
	})
}

// platform_start_gpu kicks off the async adapter→device request chain and
// returns immediately. The browser resolves the requests on its event loop; the
// device callback calls _gpu_finish, which flips g.initialized to true. The web
// frame loop skips drawing until then.
@(private)
platform_start_gpu :: proc() {
	wg.InstanceRequestAdapter(g.instance, &{compatibleSurface = g.surface}, {
		callback = _web_on_adapter,
	})
}

@(private)
_web_on_adapter :: proc "c" (status: wg.RequestAdapterStatus, adapter: wg.Adapter, msg: wg.StringView, u1, u2: rawptr) {
	context = g_web_ctx
	g.adapter = adapter
	wg.AdapterRequestDevice(g.adapter, nil, {callback = _web_on_device})
}

@(private)
_web_on_device :: proc "c" (status: wg.RequestDeviceStatus, device: wg.Device, msg: wg.StringView, u1, u2: rawptr) {
	context = g_web_ctx
	g.device = device
	g.queue = wg.DeviceGetQueue(g.device)
	_gpu_finish()
}

// On web the adapter/device requests resolve on the browser event loop, not via
// a synchronous pump. No-op.
@(private)
platform_process_events :: proc(instance: wg.Instance) {}

@(private)
platform_framebuffer_size :: proc() -> (i32, i32) {
	// Physical pixels = CSS size × devicePixelRatio (mirrors macOS HiDPI: the
	// swapchain is at physical resolution, logical layout stays in points).
	dpr := _js_dpr()
	if dpr <= 0 do dpr = 1
	w := i32(_js_css_width() * dpr + 0.5)
	h := i32(_js_css_height() * dpr + 0.5)
	if w <= 0 do w = g.width
	if h <= 0 do h = g.height
	return w, h
}

@(private)
platform_window_size :: proc() -> (i32, i32) {
	// Logical (point) size = CSS pixels.
	w := i32(_js_css_width() + 0.5)
	h := i32(_js_css_height() + 0.5)
	if w <= 0 do w = g.width
	if h <= 0 do h = g.height
	return w, h
}

@(private)
platform_content_scale :: proc() -> f32 {
	dpr := _js_dpr()
	return dpr <= 0 ? 1 : f32(dpr)
}

@(private)
platform_should_close :: proc() -> bool {
	return false
}

@(private)
platform_poll_events :: proc() {
	_input_drain()
}

@(private)
platform_terminate :: proc() {}

@(private)
platform_now :: proc() -> f64 {
	return _js_perf_now() / 1000.0
}

// The browser paces frames via requestAnimationFrame; a busy-sleep would block
// the event loop. No-op.
@(private)
platform_sleep :: proc(seconds: f64) {}

@(private)
platform_set_window_min_size :: proc(w, h: i32) {}

@(private)
platform_set_window_size :: proc(w, h: i32) {}

@(private)
platform_monitor_refresh_rate :: proc() -> i32 {
	return 60
}

@(private)
platform_window_focused :: proc() -> bool {
	return true
}

@(private)
platform_set_window_icon :: proc(image: Image) {}

// --- input: DOM → shared Input struct --------------------------------------
//
// Browser input events fire asynchronously (between frames), whereas the native
// backend fills g.inp synchronously inside PollEvents (which input_poll calls
// after resetting frame-scoped state). To preserve identical timing, the JS
// event entry points (input_web.odin) write into a STAGING buffer here; the web
// platform_poll_events drains staging into g.inp at the exact point native
// fills it — so edge (pressed/released) semantics match frame-for-frame.

@(private) st_pressed:  [KEY_COUNT]bool
@(private) st_released: [KEY_COUNT]bool
@(private) st_repeat:   [KEY_COUNT]bool
@(private) st_held:     [KEY_COUNT]bool   // sticky held state for IsKeyDown
@(private) st_keys:   [CHAR_Q]KeyboardKey // ring of pressed keys (GetKeyPressed)
@(private) st_key_h, st_key_t: int
@(private) st_chars:  [CHAR_Q]rune        // ring of typed runes (GetCharPressed)
@(private) st_char_h, st_char_t: int
@(private) st_wheel:  Vector2
@(private) st_mouse:  Vector2
@(private) st_mb:     [8]bool
@(private) st_hovered: bool

@(private)
_st_push_key :: proc "contextless" (k: KeyboardKey) {
	nt := (st_key_t + 1) % CHAR_Q
	if nt == st_key_h do return
	st_keys[st_key_t] = k
	st_key_t = nt
}

@(private)
_st_push_char :: proc "contextless" (r: rune) {
	nt := (st_char_t + 1) % CHAR_Q
	if nt == st_char_h do return
	st_chars[st_char_t] = r
	st_char_t = nt
}

// _input_drain merges staged events into g.inp. Called from platform_poll_events
// (i.e. from input_poll, right after it clears the per-frame edge/queue state).
@(private)
_input_drain :: proc() {
	for i in 0 ..< KEY_COUNT {
		if st_pressed[i]  { g.inp.pressed[i]  = true }
		if st_released[i] { g.inp.released[i] = true }
		if st_repeat[i]   { g.inp.repeat[i]   = true }
		st_pressed[i], st_released[i], st_repeat[i] = false, false, false
	}
	for st_key_h != st_key_t {
		_push_key(st_keys[st_key_h])
		st_key_h = (st_key_h + 1) % CHAR_Q
	}
	for st_char_h != st_char_t {
		_push_char(st_chars[st_char_h])
		st_char_h = (st_char_h + 1) % CHAR_Q
	}
	g.inp.wheel_pending.x += st_wheel.x
	g.inp.wheel_pending.y += st_wheel.y
	st_wheel = {0, 0}
}

@(private)
platform_input_init :: proc() {}

@(private)
platform_cursor_pos :: proc() -> (f64, f64) {
	return f64(st_mouse.x), f64(st_mouse.y)
}

@(private)
platform_mouse_button :: proc(button: i32) -> bool {
	if button < 0 || button >= 8 do return false
	return st_mb[button]
}

@(private)
platform_window_hovered :: proc() -> bool {
	return st_hovered
}

@(private)
platform_key_down :: proc(key: i32) -> bool {
	if key < 0 || key >= KEY_COUNT do return false
	return st_held[key]
}

@(private)
platform_set_mouse_cursor :: proc(cursor: MouseCursor) {
	_js_set_cursor(i32(cursor))
}

@(private)
platform_get_clipboard :: proc() -> string {
	return ""
}

@(private)
platform_set_clipboard :: proc(text: cstring) {}

@(private)
platform_drop_init :: proc() {}

// --- public window procs (native equivalents live in window_native/extra) --

GetWindowHandle    :: proc() -> rawptr { return nil }
IsWindowMinimized  :: proc() -> bool   { return false }
IsWindowHidden     :: proc() -> bool   { return false }
IsWindowFullscreen :: proc() -> bool   { return false }
RestoreWindow      :: proc() {}

IsFileDropped :: proc() -> bool { return false }
LoadDroppedFiles :: proc() -> FilePathList { return FilePathList{} }
UnloadDroppedFiles :: proc(files: FilePathList) {}
