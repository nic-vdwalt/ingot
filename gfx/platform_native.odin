#+build !js
// ingot:gfx — native (desktop) platform backend.
//
// Every GLFW call in the engine lives in this file so the shared gfx core stays
// windowing-backend-agnostic. Compiled on all non-JS targets (macOS/Windows/
// Linux); the browser target compiles platform_web.odin instead. The logic here
// is the same GLFW code that previously lived inline in context.odin /
// input.odin — moved verbatim behind the platform seam, so native behaviour is
// unchanged.
package gfx

import "core:strings"
import "core:time"
import "vendor:glfw"
import wg "vendor:wgpu"
import wgglue "vendor:wgpu/glfwglue"

// Native cursor handles. Kept as a package global (not in the shared Input
// struct) so Input carries no glfw type.
@(private) g_cursors: [11]glfw.CursorHandle

// Monotonic clock epoch for platform_now(); the caller-side offset cancels, so
// this only needs to be a stable monotonic base.
@(private) _mono_epoch := time.tick_now()

// _win returns g.win as a glfw handle for the native calls below.
@(private)
_win :: proc "contextless" () -> glfw.WindowHandle {
	return glfw.WindowHandle(g.win)
}

// --- window / surface / lifecycle ------------------------------------------

@(private)
platform_create_window :: proc(width, height: i32, title: cstring, flags: ConfigFlags) -> bool {
	if !glfw.Init() {
		return false
	}
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, .WINDOW_RESIZABLE in flags ? 1 : 0)
	if .WINDOW_TRANSPARENT in flags {
		glfw.WindowHint(glfw.TRANSPARENT_FRAMEBUFFER, 1)
	}
	if .WINDOW_UNDECORATED in flags {
		glfw.WindowHint(glfw.DECORATED, 0)
	}
	win := glfw.CreateWindow(width, height, title, nil, nil)
	if win == nil {
		return false
	}
	g.win = Window_Handle(win)
	return true
}

@(private)
platform_create_surface :: proc(instance: wg.Instance) -> wg.Surface {
	return wgglue.GetSurface(instance, _win())
}

// platform_start_gpu acquires the adapter+device synchronously (wgpu-native
// resolves the async requests via InstanceProcessEvents) and finishes context
// setup before returning. g.instance and g.surface are already set.
@(private)
platform_start_gpu :: proc() {
	ares: Adapter_Res
	wg.InstanceRequestAdapter(g.instance, &{compatibleSurface = g.surface}, {
		mode = .AllowProcessEvents, callback = _on_adapter, userdata1 = &ares,
	})
	for !ares.done { wg.InstanceProcessEvents(g.instance) }
	g.adapter = ares.adapter

	dres: Device_Res
	dev_desc := wg.DeviceDescriptor{
		uncapturedErrorCallbackInfo = {callback = _on_uncaptured_error},
	}
	wg.AdapterRequestDevice(g.adapter, &dev_desc, {
		mode = .AllowProcessEvents, callback = _on_device, userdata1 = &dres,
	})
	for !dres.done { wg.InstanceProcessEvents(g.instance) }
	g.device = dres.device
	g.queue = wg.DeviceGetQueue(g.device)

	_gpu_finish()
}

// platform_process_events pumps the backend event loop while gfx busy-waits for
// the async adapter/device requests to resolve (native: wgpu-native resolves
// them synchronously via InstanceProcessEvents).
@(private)
platform_process_events :: proc(instance: wg.Instance) {
	wg.InstanceProcessEvents(instance)
}

@(private)
platform_framebuffer_size :: proc() -> (i32, i32) {
	return glfw.GetFramebufferSize(_win())
}

@(private)
platform_window_size :: proc() -> (i32, i32) {
	return glfw.GetWindowSize(_win())
}

@(private)
platform_content_scale :: proc() -> f32 {
	sx, _ := glfw.GetWindowContentScale(_win())
	return sx
}

@(private)
platform_should_close :: proc() -> bool {
	if g.win == nil do return true
	return bool(glfw.WindowShouldClose(_win()))
}

@(private)
platform_poll_events :: proc() {
	glfw.PollEvents()
}

@(private)
platform_terminate :: proc() {
	if g.win != nil do glfw.DestroyWindow(_win())
	glfw.Terminate()
}

// platform_now returns a monotonic time in seconds. gfx stores the value at
// InitWindow and subtracts it, so only monotonicity matters.
@(private)
platform_now :: proc() -> f64 {
	return time.duration_seconds(time.tick_since(_mono_epoch))
}

@(private)
platform_sleep :: proc(seconds: f64) {
	time.sleep(time.Duration(seconds * f64(time.Second)))
}

@(private)
platform_set_window_min_size :: proc(w, h: i32) {
	if g.win != nil do glfw.SetWindowSizeLimits(_win(), w, h, glfw.DONT_CARE, glfw.DONT_CARE)
}

@(private)
platform_set_window_size :: proc(w, h: i32) {
	if g.win != nil do glfw.SetWindowSize(_win(), w, h)
}

@(private)
platform_monitor_refresh_rate :: proc() -> i32 {
	m := glfw.GetPrimaryMonitor()
	if m == nil do return 60
	mode := glfw.GetVideoMode(m)
	if mode == nil do return 60
	return mode.refresh_rate
}

@(private)
platform_window_focused :: proc() -> bool {
	if g.win == nil do return false
	return glfw.GetWindowAttrib(_win(), glfw.FOCUSED) != 0
}

@(private)
platform_set_window_icon :: proc(image: Image) {
	if g.win == nil || image.data == nil do return
	img := glfw.Image{width = image.width, height = image.height, pixels = ([^]u8)(image.data)}
	imgs := [1]glfw.Image{img}
	glfw.SetWindowIcon(_win(), imgs[:])
}

// --- input -----------------------------------------------------------------

@(private)
platform_input_init :: proc() {
	if g.win == nil do return
	glfw.SetKeyCallback(_win(), _key_cb)
	glfw.SetCharCallback(_win(), _char_cb)
	glfw.SetScrollCallback(_win(), _scroll_cb)

	g_cursors[MouseCursor.DEFAULT]       = glfw.CreateStandardCursor(glfw.ARROW_CURSOR)
	g_cursors[MouseCursor.ARROW]         = glfw.CreateStandardCursor(glfw.ARROW_CURSOR)
	g_cursors[MouseCursor.IBEAM]         = glfw.CreateStandardCursor(glfw.IBEAM_CURSOR)
	g_cursors[MouseCursor.CROSSHAIR]     = glfw.CreateStandardCursor(glfw.CROSSHAIR_CURSOR)
	g_cursors[MouseCursor.POINTING_HAND] = glfw.CreateStandardCursor(glfw.POINTING_HAND_CURSOR)
	g_cursors[MouseCursor.RESIZE_EW]     = glfw.CreateStandardCursor(glfw.RESIZE_EW_CURSOR)
	g_cursors[MouseCursor.RESIZE_NS]     = glfw.CreateStandardCursor(glfw.RESIZE_NS_CURSOR)
	g_cursors[MouseCursor.RESIZE_NWSE]   = glfw.CreateStandardCursor(glfw.RESIZE_ALL_CURSOR)
	g_cursors[MouseCursor.RESIZE_NESW]   = glfw.CreateStandardCursor(glfw.RESIZE_ALL_CURSOR)
	g_cursors[MouseCursor.RESIZE_ALL]    = glfw.CreateStandardCursor(glfw.RESIZE_ALL_CURSOR)
	g_cursors[MouseCursor.NOT_ALLOWED]   = glfw.CreateStandardCursor(glfw.NOT_ALLOWED_CURSOR)

	mx, my := glfw.GetCursorPos(_win())
	g.inp.mouse = {f32(mx), f32(my)}
	g.inp.mouse_prev = g.inp.mouse
}

@(private)
platform_cursor_pos :: proc() -> (f64, f64) {
	return glfw.GetCursorPos(_win())
}

@(private)
platform_mouse_button :: proc(button: i32) -> bool {
	if g.win == nil do return false
	return glfw.GetMouseButton(_win(), button) == glfw.PRESS
}

@(private)
platform_window_hovered :: proc() -> bool {
	if g.win == nil do return false
	return glfw.GetWindowAttrib(_win(), glfw.HOVERED) != 0
}

@(private)
platform_key_down :: proc(key: i32) -> bool {
	if g.win == nil do return false
	return glfw.GetKey(_win(), key) == glfw.PRESS
}

@(private)
platform_set_mouse_cursor :: proc(cursor: MouseCursor) {
	if g.win == nil do return
	i := int(cursor)
	if i < 0 || i >= len(g_cursors) do return
	glfw.SetCursor(_win(), g_cursors[i])
}

@(private)
platform_get_clipboard :: proc() -> string {
	if g.win == nil do return ""
	return glfw.GetClipboardString(_win())
}

@(private)
platform_set_clipboard :: proc(text: cstring) {
	if g.win == nil do return
	glfw.SetClipboardString(_win(), text)
}

@(private)
platform_drop_init :: proc() {
	if g.win != nil do glfw.SetDropCallback(_win(), _drop_cb)
}

// --- GLFW input callbacks --------------------------------------------------
// Fill the shared Input queues/edge state; read by the app on the next frame.

@(private)
_key_cb :: proc "c" (win: glfw.WindowHandle, key, scancode, action, mods: i32) {
	if key < 0 || key >= KEY_COUNT do return
	switch action {
	case glfw.PRESS:
		g.inp.pressed[key] = true
		_push_key(KeyboardKey(key))
	case glfw.RELEASE:
		g.inp.released[key] = true
	case glfw.REPEAT:
		g.inp.repeat[key] = true
	}
}

@(private)
_char_cb :: proc "c" (win: glfw.WindowHandle, codepoint: rune) {
	_push_char(codepoint)
}

@(private)
_scroll_cb :: proc "c" (win: glfw.WindowHandle, xoffset, yoffset: f64) {
	g.inp.wheel_pending.x += f32(xoffset)
	g.inp.wheel_pending.y += f32(yoffset)
}

// --- frame loop ------------------------------------------------------------

// run drives the frame loop. On native it blocks, calling frame() every tick
// until the window is asked to close, then returns. Apps may equivalently write
// their own `for !WindowShouldClose()` loop; run() exists so the same app source
// also targets web, where the browser owns the loop (see loop_web.odin).
run :: proc(frame: Run_Proc) {
	for !WindowShouldClose() {
		frame()
	}
}
