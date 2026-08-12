#+build !js
// ingot:gfx - native (desktop) platform backend.
//
// Every GLFW call in the engine lives in this file so the shared gfx core stays
// windowing-backend-agnostic. Compiled on all non-JS targets (macOS/Windows/
// Linux); the browser target compiles platform_web.odin instead. The logic here
// is the same GLFW code that previously lived inline in context.odin /
// input.odin - moved verbatim behind the platform seam, so native behaviour is
// unchanged.
package gfx

import "core:c"
import "core:time"
import "vendor:glfw"
import wg "vendor:wgpu"
import wgglue "vendor:wgpu/glfwglue"

// Native cursor handles. Kept as a package global (not in the shared Input
// struct) so Input carries no glfw type.
@(private)
g_cursors: [11]glfw.CursorHandle
@(private)
glfw_live_windows: u32

// Monotonic clock epoch for platform_now(); the caller-side offset cancels, so
// this only needs to be a stable monotonic base.
@(private)
_mono_epoch := time.tick_now()

// _win returns g.win as a glfw handle for the native calls below.
@(private)
_win :: proc "contextless" () -> glfw.WindowHandle {
	return glfw.WindowHandle(g.win)
}

// --- window / surface / lifecycle ------------------------------------------

@(private)
platform_create_window :: proc(width, height: i32, title: cstring, flags: ConfigFlags) -> bool {
	if glfw_live_windows == 0 && !glfw.Init() do return false
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, .WINDOW_RESIZABLE in flags ? 1 : 0)
	glfw.WindowHint(glfw.TRANSPARENT_FRAMEBUFFER, .WINDOW_TRANSPARENT in flags ? 1 : 0)
	glfw.WindowHint(glfw.DECORATED, .WINDOW_UNDECORATED in flags ? 0 : 1)
	// WINDOW_HIDDEN defers the first show so a caller can attach platform state
	// that must exist before the window is visible. Windows' AccessKit
	// subclassing adapter is the motivating case: it must be installed before
	// the window is shown for the first time or it panics. Reveal with
	// ShowWindow once that state is live.
	glfw.WindowHint(glfw.VISIBLE, .WINDOW_HIDDEN in flags ? 0 : 1)
	win := glfw.CreateWindow(width, height, title, nil, nil)
	if win == nil {
		if glfw_live_windows == 0 do glfw.Terminate()
		return false
	}
	g.win = Window_Handle(win)
	glfw.SetWindowUserPointer(win, g)
	glfw_live_windows += 1
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
	wg.InstanceRequestAdapter(
		g.instance,
		&{compatibleSurface = g.surface},
		{mode = .AllowProcessEvents, callback = _on_adapter, userdata1 = &ares},
	)
	// tigerstyle: allow-unbounded-loop -- adapter callback ends synchronous device setup
	for !ares.done {wg.InstanceProcessEvents(g.instance)}
	g.adapter = ares.adapter

	dres: Device_Res
	// Read the adapter's limits to size our pools (limits.odin). The device
	// is requested with default limits on both targets so the two paths stay
	// identical; see the requiredLimits hazard note in limits.odin.
	// ares.adapter, not g.adapter: this leaf keeps its context reads in one
	// place at the top rather than reaching back into the global mid-sequence.
	g.budget = gpu_negotiate_budget(ares.adapter)
	dev_desc := wg.DeviceDescriptor {
		uncapturedErrorCallbackInfo = {callback = _on_uncaptured_error},
	}
	wg.AdapterRequestDevice(
		g.adapter,
		&dev_desc,
		{mode = .AllowProcessEvents, callback = _on_device, userdata1 = &dres},
	)
	// tigerstyle: allow-unbounded-loop -- device callback ends synchronous device setup
	for !dres.done {wg.InstanceProcessEvents(g.instance)}
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

// platform_wait_events blocks until an event arrives or `timeout` seconds
// elapse (event-driven idle). glfw.PostEmptyEvent (platform_wake) unblocks it
// from any thread.
@(private)
platform_wait_events :: proc(timeout: f64) {
	glfw.WaitEventsTimeout(timeout)
}

// platform_wake unblocks a platform_wait_events in progress. Thread-safe
// (GLFW documents PostEmptyEvent as callable from any thread).
@(private)
platform_wake :: proc "contextless" () {
	if glfw_live_windows > 0 do glfw.PostEmptyEvent()
}

@(private)
platform_window_iconified :: proc() -> bool {
	if g.win == nil do return false
	return glfw.GetWindowAttrib(_win(), glfw.ICONIFIED) != 0
}

@(private)
platform_terminate :: proc() {
	if g.win != nil {
		glfw.SetWindowUserPointer(_win(), nil)
		glfw.DestroyWindow(_win())
		g.win = nil
		assert(glfw_live_windows > 0, "platform_terminate: window count underflow")
		glfw_live_windows -= 1
	}
	if glfw_live_windows == 0 {
		for &cursor in g_cursors {
			if cursor != nil do glfw.DestroyCursor(cursor)
			cursor = nil
		}
		glfw.Terminate()
	}
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
platform_set_window_title :: proc(title: cstring) {
	if g.win != nil do glfw.SetWindowTitle(_win(), title)
}

@(private)
platform_set_window_position :: proc(x, y: i32) {
	if g.win != nil do glfw.SetWindowPos(_win(), x, y)
}

@(private)
platform_window_position :: proc() -> (i32, i32) {
	if g.win == nil do return 0, 0
	return glfw.GetWindowPos(_win())
}

PLATFORM_MONITORS_MAX :: 16

@(private)
platform_monitor_overlap :: proc(
	window_x, window_y, window_width, window_height: i32,
	monitor: glfw.MonitorHandle,
) -> i64 {
	assert(window_width > 0 && window_height > 0, "platform_monitor_overlap: invalid window")
	assert(monitor != nil, "platform_monitor_overlap: nil monitor")
	monitor_x, monitor_y, monitor_width, monitor_height := glfw.GetMonitorWorkarea(monitor)
	overlap_width := max(
		0,
		min(window_x + window_width, monitor_x + monitor_width) - max(window_x, monitor_x),
	)
	overlap_height := max(
		0,
		min(window_y + window_height, monitor_y + monitor_height) - max(window_y, monitor_y),
	)
	return i64(overlap_width) * i64(overlap_height)
}

@(private)
platform_window_monitor :: proc(window: glfw.WindowHandle) -> glfw.MonitorHandle {
	if window == nil do return nil
	fullscreen_monitor := glfw.GetWindowMonitor(window)
	if fullscreen_monitor != nil do return fullscreen_monitor
	window_x, window_y := glfw.GetWindowPos(window)
	window_width, window_height := glfw.GetWindowSize(window)
	if window_width <= 0 || window_height <= 0 do return glfw.GetPrimaryMonitor()
	monitors := glfw.GetMonitors()
	monitor_count := min(len(monitors), PLATFORM_MONITORS_MAX)
	best_monitor := glfw.GetPrimaryMonitor()
	best_overlap: i64
	for monitor_index in 0 ..< monitor_count {
		assert(monitor_index >= 0 && monitor_index < PLATFORM_MONITORS_MAX)
		monitor := monitors[monitor_index]
		overlap := platform_monitor_overlap(
			window_x,
			window_y,
			window_width,
			window_height,
			monitor,
		)
		if overlap > best_overlap {
			best_monitor = monitor
			best_overlap = overlap
		}
	}
	return best_monitor
}

@(private)
platform_monitor_refresh_rate :: proc() -> i32 {
	monitor := platform_window_monitor(_win())
	if monitor == nil do return 0
	mode := glfw.GetVideoMode(monitor)
	if mode == nil || mode.refresh_rate <= 0 do return 0
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
	img := glfw.Image {
		width  = image.width,
		height = image.height,
		pixels = ([^]u8)(image.data),
	}
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

	// Activity marks for event-driven frame scheduling (idle.odin). Cursor,
	// button, focus and size events have no state to store (they are polled),
	// but must still wake the idle gate; WindowRefresh is the OS damage signal
	// (uncover/resize) - without it an idle window would show stale content.
	glfw.SetCursorPosCallback(_win(), _cursor_pos_cb)
	glfw.SetMouseButtonCallback(_win(), _mouse_button_cb)
	glfw.SetWindowCloseCallback(_win(), _close_cb)
	glfw.SetWindowRefreshCallback(_win(), _refresh_cb)
	glfw.SetWindowFocusCallback(_win(), _focus_cb)
	glfw.SetWindowIconifyCallback(_win(), _iconify_cb)
	glfw.SetWindowSizeCallback(_win(), _window_size_cb)
	glfw.SetFramebufferSizeCallback(_win(), _fb_size_cb)

	if g_cursors[MouseCursor.DEFAULT] == nil {
		g_cursors[MouseCursor.DEFAULT] = glfw.CreateStandardCursor(glfw.ARROW_CURSOR)
		g_cursors[MouseCursor.ARROW] = glfw.CreateStandardCursor(glfw.ARROW_CURSOR)
		g_cursors[MouseCursor.IBEAM] = glfw.CreateStandardCursor(glfw.IBEAM_CURSOR)
		g_cursors[MouseCursor.CROSSHAIR] = glfw.CreateStandardCursor(glfw.CROSSHAIR_CURSOR)
		g_cursors[MouseCursor.POINTING_HAND] = glfw.CreateStandardCursor(glfw.POINTING_HAND_CURSOR)
		g_cursors[MouseCursor.RESIZE_EW] = glfw.CreateStandardCursor(glfw.RESIZE_EW_CURSOR)
		g_cursors[MouseCursor.RESIZE_NS] = glfw.CreateStandardCursor(glfw.RESIZE_NS_CURSOR)
		g_cursors[MouseCursor.RESIZE_NWSE] = glfw.CreateStandardCursor(glfw.RESIZE_ALL_CURSOR)
		g_cursors[MouseCursor.RESIZE_NESW] = glfw.CreateStandardCursor(glfw.RESIZE_ALL_CURSOR)
		g_cursors[MouseCursor.RESIZE_ALL] = glfw.CreateStandardCursor(glfw.RESIZE_ALL_CURSOR)
		g_cursors[MouseCursor.NOT_ALLOWED] = glfw.CreateStandardCursor(glfw.NOT_ALLOWED_CURSOR)
	}

	mx, my := glfw.GetCursorPos(_win())
	g.inp.mouse = {f32(mx), f32(my)}
	g.inp.mouse_prev = g.inp.mouse
}

@(private)
platform_web_input_frame_begin :: proc() {}

@(private)
platform_web_input_frame_end :: proc() {}

@(private)
platform_sync_web_text_input :: proc(
	form_id, field_id, name, placeholder, value: string,
	x, y, w, h, input_type, autocomplete: i32,
	active: bool,
) -> Web_Input_Result {
	return {}
}

@(private)
platform_sync_web_submit_button :: proc(
	form_id, label: string,
	x, y, w, h, style, font_size: i32,
	enabled: bool,
) -> bool {
	return false
}

@(private)
platform_sync_web_control :: proc(
	role: i32,
	id: u64,
	label: string,
	x, y, w, h: i32,
	state: u8,
	value, lo, hi: f32,
	position_in_set, size_of_set: i32,
) -> Web_Control_Result {
	return {}
}

// IME candidate-window positioning: GLFW delivers final composed characters
// via the char callback but has no preedit/candidate-rect API, so the per-OS
// _ime_* seams (ime_darwin.odin / ime_windows.odin / ime_other.odin) talk to
// the OS input method directly.
@(private)
platform_set_text_input_rect :: proc(x, y, w, h: i32) {
	if g.win == nil do return
	_ime_set_rect(x, y, w, h)
}

@(private)
platform_text_input_deactivate :: proc() {
	if g.win == nil do return
	_ime_deactivate()
}

@(private)
platform_cursor_pos :: proc() -> (f64, f64) {
	return glfw.GetCursorPos(_win())
}

@(private)
platform_set_cursor_pos :: proc(x, y: f64) {
	if g.win == nil do return
	glfw.SetCursorPos(_win(), x, y)
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
platform_set_cursor_hidden :: proc(hidden: bool) {
	if g.win == nil do return
	mode: i32 = glfw.CURSOR_HIDDEN if hidden else glfw.CURSOR_NORMAL
	glfw.SetInputMode(_win(), glfw.CURSOR, mode)
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
	_drop_state_reset()
	if g.win != nil do glfw.SetDropCallback(_win(), _drop_cb)
	platform_dragdrop_init()
}

@(private)
platform_drop_prepare_events :: proc() {
	platform_dragdrop_tick()
}

@(private)
platform_drop_finish_events :: proc() {
	platform_dragdrop_tick()
}

@(private)
platform_drop_shutdown :: proc() {
	platform_dragdrop_shutdown()
	if g.win != nil do glfw.SetDropCallback(_win(), nil)
	_drop_native_shutdown()
}

// platform_gamepad_poll snapshots every gamepad slot from GLFW's SDL-mapping
// database. Buttons arrive in GLFW order and are remapped to the raylib
// GamepadButton layout via _GLFW_PAD_REMAP; the analog triggers additionally
// set the digital LEFT/RIGHT_TRIGGER_2 buttons (raylib parity - GLFW exposes
// triggers only as axes).
@(private)
platform_gamepad_poll :: proc(pads: ^[MAX_GAMEPADS]Gamepad_State) {
	assert(pads != nil, "platform_gamepad_poll: nil pads")
	#assert(MAX_GAMEPADS <= glfw.JOYSTICK_LAST + 1)
	for jid in 0 ..< MAX_GAMEPADS {
		pad := &pads[jid]
		connected := bool(glfw.JoystickIsGamepad(c.int(jid)))
		if connected != pad.connected {
			_idle_note_activity(&g.idle)
		}
		pad.connected = connected
		if !connected {
			pad.buttons = {}
			pad.axes = {}
			pad.name_len = 0
			continue
		}
		state: glfw.GamepadState
		if !glfw.GetGamepadState(c.int(jid), &state) {
			continue
		}
		pad.buttons = {}
		for b in 0 ..< len(state.buttons) {
			if state.buttons[b] == glfw.PRESS {
				pad.buttons[int(_GLFW_PAD_REMAP[b])] = true
			}
		}
		for a in 0 ..< len(state.axes) {
			pad.axes[a] = state.axes[a]
		}
		// Digital trigger buttons derived from the analog axes (rest at -1).
		pad.buttons[int(GamepadButton.LEFT_TRIGGER_2)] = state.axes[4] > TRIGGER_PRESS_THRESHOLD
		pad.buttons[int(GamepadButton.RIGHT_TRIGGER_2)] = state.axes[5] > TRIGGER_PRESS_THRESHOLD
		if pad.buttons != pad.prev_buttons {
			_idle_note_activity(&g.idle)
		}
		name := glfw.GetGamepadName(c.int(jid))
		n := min(len(name), GAMEPAD_NAME_MAX)
		for i in 0 ..< n {
			pad.name[i] = name[i]
		}
		pad.name_len = i32(n)
	}
}

// --- GLFW input callbacks --------------------------------------------------
// Fill the owning window's staging queues; read by that context on its next frame.

@(private)
_callback_context :: proc "contextless" (win: glfw.WindowHandle) -> ^Context {
	if win == nil do return nil
	return cast(^Context)glfw.GetWindowUserPointer(win)
}

@(private)
_key_cb :: proc "c" (win: glfw.WindowHandle, key, scancode, action, mods: i32) {
	ctx := _callback_context(win)
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	if key < 0 || key >= KEY_COUNT do return
	switch action {
	case glfw.PRESS:
		ctx.inp.st_pressed[key] = true
		_stage_key(&ctx.inp, KeyboardKey(key))
	case glfw.RELEASE:
		ctx.inp.st_released[key] = true
	case glfw.REPEAT:
		ctx.inp.st_repeat[key] = true
	}
}

@(private)
_char_cb :: proc "c" (win: glfw.WindowHandle, codepoint: rune) {
	ctx := _callback_context(win)
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	_stage_char(&ctx.inp, codepoint)
}

@(private)
_scroll_cb :: proc "c" (win: glfw.WindowHandle, xoffset, yoffset: f64) {
	ctx := _callback_context(win)
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	ctx.inp.st_wheel.x += f32(xoffset)
	ctx.inp.st_wheel.y += f32(yoffset)
}

// The callbacks below carry no input state (their data is polled per frame);
// they exist solely to wake the event-driven idle gate.

@(private)
_cursor_pos_cb :: proc "c" (win: glfw.WindowHandle, xpos, ypos: f64) {
	if ctx := _callback_context(win); ctx != nil do _idle_note_activity(&ctx.idle)
}

@(private)
_mouse_button_cb :: proc "c" (win: glfw.WindowHandle, button, action, mods: i32) {
	if ctx := _callback_context(win); ctx != nil do _idle_note_activity(&ctx.idle)
}

@(private)
_close_cb :: proc "c" (win: glfw.WindowHandle) {
	when ODIN_OS == .Windows {
		if win != nil do glfw.HideWindow(win)
	}
}

@(private)
_refresh_cb :: proc "c" (win: glfw.WindowHandle) {
	ctx := _callback_context(win)
	if ctx == nil do return
	ctx.force_reconfigure = true
	_idle_note_activity(&ctx.idle)
}

@(private)
_focus_cb :: proc "c" (win: glfw.WindowHandle, focused: i32) {
	ctx := _callback_context(win)
	if ctx == nil do return
	if focused != 0 do ctx.force_reconfigure = true
	_idle_note_activity(&ctx.idle)
}

@(private)
_iconify_cb :: proc "c" (win: glfw.WindowHandle, iconified: i32) {
	ctx := _callback_context(win)
	if ctx == nil do return
	if iconified == 0 do ctx.force_reconfigure = true
	_idle_note_activity(&ctx.idle)
}

@(private)
_window_size_cb :: proc "c" (win: glfw.WindowHandle, width, height: i32) {
	ctx := _callback_context(win)
	if ctx == nil do return
	ctx.force_reconfigure = true
	_idle_note_activity(&ctx.idle)
}

@(private)
_fb_size_cb :: proc "c" (win: glfw.WindowHandle, width, height: i32) {
	ctx := _callback_context(win)
	if ctx == nil do return
	ctx.force_reconfigure = true
	_idle_note_activity(&ctx.idle)
}

// --- frame loop ------------------------------------------------------------

// run drives the frame loop. On native it blocks, calling frame() every tick
// until the window is asked to close, then returns. Apps may equivalently write
// their own `for !WindowShouldClose()` loop; run() exists so the same app source
// also targets web, where the browser owns the loop (see loop_web.odin).
run_data :: proc(frame: Run_Data_Proc, userdata: rawptr) -> bool {
	if frame == nil do return false
	// tigerstyle: allow-unbounded-loop -- window close terminates the application lifetime
	for !WindowShouldClose() {
		frame(userdata)
	}
	return true
}

@(private)
run_compat_frame :: proc(userdata: rawptr) {
	frame := cast(Run_Proc)userdata
	assert(frame != nil, "run_compat_frame: nil frame")
	frame()
}

run :: proc(frame: Run_Proc) {
	assert(frame != nil, "run: nil frame")
	_ = run_data(run_compat_frame, cast(rawptr)frame)
}
