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

@(require) import "core:c"
@(require) import "core:fmt"
@(require) import "core:time"
@(require) import "vendor:glfw"
@(require) import wg "vendor:wgpu"
@(require) import wgglue "vendor:wgpu/glfwglue"

when !INGOT_GFX_SDL3 {

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

	@(private)
	_context_window :: proc(ctx: ^Context) -> glfw.WindowHandle {
		assert(ctx != nil, "_context_window: nil context")
		return glfw.WindowHandle(ctx.win)
	}

	// --- window / surface / lifecycle ------------------------------------------

	@(private)
	platform_create_window :: proc(
		ctx: ^Context,
		width, height: i32,
		title: cstring,
		flags: ConfigFlags,
	) -> bool {
		assert(ctx != nil, "platform_create_window: nil context")
		if glfw_live_windows == 0 && !glfw.Init() do return false
		glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
		glfw.WindowHint(glfw.RESIZABLE, .WINDOW_RESIZABLE in flags ? 1 : 0)
		glfw.WindowHint(glfw.TRANSPARENT_FRAMEBUFFER, .WINDOW_TRANSPARENT in flags ? 1 : 0)
		glfw.WindowHint(glfw.DECORATED, .WINDOW_UNDECORATED in flags ? 0 : 1)
		focused := _window_wants_initial_focus(flags)
		glfw.WindowHint(glfw.FOCUSED, focused ? 1 : 0)
		glfw.WindowHint(glfw.FOCUS_ON_SHOW, focused ? 1 : 0)
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
		ctx.win = Window_Handle(win)
		glfw.SetWindowUserPointer(win, ctx)
		glfw_live_windows += 1
		return true
	}

	@(private)
	platform_window_ready :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_window_ready: nil context")
		assert(ctx.win != nil, "platform_window_ready: no window")
		if !_window_should_activate(ctx.config_flags) do return
		_platform_activate_window(ctx)
		glfw.FocusWindow(_context_window(ctx))
	}

	when ODIN_OS != .Darwin {
		@(private)
		platform_create_surface :: proc(ctx: ^Context, instance: wg.Instance) -> wg.Surface {
			assert(ctx != nil, "platform_create_surface: nil context")
			return wgglue.GetSurface(instance, _context_window(ctx))
		}
	}

	// platform_start_gpu acquires the adapter+device synchronously (wgpu-native
	// resolves the async requests via InstanceProcessEvents) and finishes context
	// setup before returning. g.instance and g.surface are already set.
	@(private)
	platform_start_gpu :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_start_gpu: nil context")
		ares: Adapter_Res
		wg.InstanceRequestAdapter(
			ctx.instance,
			&{compatibleSurface = ctx.surface},
			{mode = .AllowProcessEvents, callback = _on_adapter, userdata1 = &ares},
		)
		// tigerstyle: allow-unbounded-loop -- adapter callback ends synchronous device setup
		for !ares.done {wg.InstanceProcessEvents(ctx.instance)}
		if ares.status != .Success || ares.adapter == nil {
			fmt.eprintln("gfx: adapter request failed")
			_close_window_context(ctx)
			return
		}
		ctx.adapter = ares.adapter

		dres: Device_Res
		// Read the adapter's limits to size our pools (limits.odin). The device
		// is requested with default limits on both targets so the two paths stay
		// identical; see the requiredLimits hazard note in limits.odin.
		// ares.adapter, not g.adapter: this leaf keeps its context reads in one
		// place at the top rather than reaching back into the global mid-sequence.
		ctx.budget = gpu_negotiate_budget(ares.adapter)
		features: [2]wg.FeatureName
		feature_count := uint(0)
		if wg.AdapterHasFeature(ares.adapter, .TimestampQuery) &&
		   wg.AdapterHasFeature(ares.adapter, .TimestampQueryInsideEncoders) {
			features[0] = .TimestampQuery
			features[1] = .TimestampQueryInsideEncoders
			feature_count = 2
		}
		dev_desc := wg.DeviceDescriptor {
			requiredFeatureCount = feature_count,
			requiredFeatures = raw_data(features[:]),
			uncapturedErrorCallbackInfo = {callback = _on_uncaptured_error},
		}
		wg.AdapterRequestDevice(
			ctx.adapter,
			&dev_desc,
			{mode = .AllowProcessEvents, callback = _on_device, userdata1 = &dres},
		)
		// tigerstyle: allow-unbounded-loop -- device callback ends synchronous device setup
		for !dres.done {wg.InstanceProcessEvents(ctx.instance)}
		if dres.status != .Success || dres.device == nil {
			fmt.eprintln("gfx: device request failed")
			_close_window_context(ctx)
			return
		}
		ctx.device = dres.device
		ctx.queue = wg.DeviceGetQueue(ctx.device)
		if ctx.queue == nil {
			fmt.eprintln("gfx: device returned no queue")
			_close_window_context(ctx)
			return
		}

		_ = _gpu_finish(ctx)
	}

	// platform_process_events pumps the backend event loop while gfx busy-waits for
	// the async adapter/device requests to resolve (native: wgpu-native resolves
	// them synchronously via InstanceProcessEvents).
	@(private)
	platform_process_events :: proc(instance: wg.Instance) {
		wg.InstanceProcessEvents(instance)
	}

	@(private)
	platform_framebuffer_size :: proc(ctx: ^Context) -> (i32, i32) {
		assert(ctx != nil, "platform_framebuffer_size: nil context")
		return glfw.GetFramebufferSize(_context_window(ctx))
	}

	@(private)
	platform_window_size :: proc(ctx: ^Context) -> (i32, i32) {
		assert(ctx != nil, "platform_window_size: nil context")
		return glfw.GetWindowSize(_context_window(ctx))
	}

	@(private)
	platform_content_scale :: proc(ctx: ^Context) -> f32 {
		assert(ctx != nil, "platform_content_scale: nil context")
		sx, _ := glfw.GetWindowContentScale(_context_window(ctx))
		return sx
	}

	@(private)
	platform_should_close :: proc(ctx: ^Context) -> bool {
		if ctx == nil || ctx.win == nil do return true
		return bool(glfw.WindowShouldClose(_context_window(ctx)))
	}

	@(private)
	platform_poll_events :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_poll_events: nil context")
		glfw.PollEvents()
		_platform_activation_poll(ctx)
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
	platform_window_iconified :: proc(ctx: ^Context) -> bool {
		if ctx == nil || ctx.win == nil do return false
		return glfw.GetWindowAttrib(_context_window(ctx), glfw.ICONIFIED) != 0
	}

	@(private)
	platform_terminate :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_terminate: nil context")
		if ctx.win != nil {
			win := _context_window(ctx)
			glfw.SetWindowUserPointer(win, nil)
			glfw.DestroyWindow(win)
			ctx.win = nil
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
	platform_set_window_min_size :: proc(ctx: ^Context, w, h: i32) {
		if ctx != nil && ctx.win != nil {
			glfw.SetWindowSizeLimits(_context_window(ctx), w, h, glfw.DONT_CARE, glfw.DONT_CARE)
		}
	}

	@(private)
	platform_set_window_size :: proc(ctx: ^Context, w, h: i32) {
		if ctx != nil && ctx.win != nil do glfw.SetWindowSize(_context_window(ctx), w, h)
	}

	@(private)
	platform_set_window_title :: proc(ctx: ^Context, title: cstring) {
		if ctx != nil && ctx.win != nil do glfw.SetWindowTitle(_context_window(ctx), title)
	}

	@(private)
	platform_set_window_position :: proc(ctx: ^Context, x, y: i32) {
		if ctx != nil && ctx.win != nil do glfw.SetWindowPos(_context_window(ctx), x, y)
	}

	@(private)
	platform_window_position :: proc(ctx: ^Context) -> (i32, i32) {
		if ctx == nil || ctx.win == nil do return 0, 0
		return glfw.GetWindowPos(_context_window(ctx))
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
	platform_monitor_refresh_rate :: proc(ctx: ^Context) -> i32 {
		if ctx == nil || ctx.win == nil do return 0
		monitor := platform_window_monitor(_context_window(ctx))
		if monitor == nil do return 0
		mode := glfw.GetVideoMode(monitor)
		if mode == nil || mode.refresh_rate <= 0 do return 0
		return mode.refresh_rate
	}

	@(private)
	platform_window_focused :: proc(ctx: ^Context) -> bool {
		if ctx == nil || ctx.win == nil do return false
		glfw_focused := glfw.GetWindowAttrib(_context_window(ctx), glfw.FOCUSED) != 0
		native_focused, native_known := _platform_native_window_focus(ctx)
		return _window_focus_resolve(glfw_focused, native_focused, native_known)
	}

	@(private)
	platform_set_window_icon :: proc(ctx: ^Context, image: Image) {
		if ctx == nil || ctx.win == nil || image.data == nil do return
		img := glfw.Image {
			width  = image.width,
			height = image.height,
			pixels = ([^]u8)(image.data),
		}
		imgs := [1]glfw.Image{img}
		glfw.SetWindowIcon(_context_window(ctx), imgs[:])
	}

	// --- input -----------------------------------------------------------------

	@(private)
	platform_input_init :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_input_init: nil context")
		if ctx.win == nil do return
		win := _context_window(ctx)
		glfw.SetKeyCallback(win, _key_cb)
		glfw.SetCharCallback(win, _char_cb)
		glfw.SetScrollCallback(win, _scroll_cb)

		// Cursor and button callbacks stage ordered raw pointer events while legacy
		// mouse state remains snapshot-polled. Focus, size, and WindowRefresh events
		// wake the idle gate; WindowRefresh is the OS damage signal (uncover/resize).
		glfw.SetCursorPosCallback(win, _cursor_pos_cb)
		glfw.SetMouseButtonCallback(win, _mouse_button_cb)
		glfw.SetWindowCloseCallback(win, _close_cb)
		glfw.SetWindowRefreshCallback(win, _refresh_cb)
		glfw.SetWindowFocusCallback(win, _focus_cb)
		glfw.SetWindowIconifyCallback(win, _iconify_cb)
		glfw.SetWindowSizeCallback(win, _window_size_cb)
		glfw.SetFramebufferSizeCallback(win, _fb_size_cb)

		default_cursor := int(MouseCursor.DEFAULT)
		assert(
			default_cursor >= 0 && default_cursor < len(g_cursors),
			"platform_input_init: cursor index",
		)
		if g_cursors[default_cursor] == nil {
			g_cursors[MouseCursor.DEFAULT] = glfw.CreateStandardCursor(glfw.ARROW_CURSOR)
			g_cursors[MouseCursor.ARROW] = glfw.CreateStandardCursor(glfw.ARROW_CURSOR)
			g_cursors[MouseCursor.IBEAM] = glfw.CreateStandardCursor(glfw.IBEAM_CURSOR)
			g_cursors[MouseCursor.CROSSHAIR] = glfw.CreateStandardCursor(glfw.CROSSHAIR_CURSOR)
			g_cursors[MouseCursor.POINTING_HAND] = glfw.CreateStandardCursor(
				glfw.POINTING_HAND_CURSOR,
			)
			g_cursors[MouseCursor.RESIZE_EW] = glfw.CreateStandardCursor(glfw.RESIZE_EW_CURSOR)
			g_cursors[MouseCursor.RESIZE_NS] = glfw.CreateStandardCursor(glfw.RESIZE_NS_CURSOR)
			g_cursors[MouseCursor.RESIZE_NWSE] = glfw.CreateStandardCursor(glfw.RESIZE_ALL_CURSOR)
			g_cursors[MouseCursor.RESIZE_NESW] = glfw.CreateStandardCursor(glfw.RESIZE_ALL_CURSOR)
			g_cursors[MouseCursor.RESIZE_ALL] = glfw.CreateStandardCursor(glfw.RESIZE_ALL_CURSOR)
			g_cursors[MouseCursor.NOT_ALLOWED] = glfw.CreateStandardCursor(glfw.NOT_ALLOWED_CURSOR)
		}

		mx, my := glfw.GetCursorPos(win)
		ctx.inp.mouse = {f32(mx), f32(my)}
		ctx.inp.mouse_prev = ctx.inp.mouse
	}

	@(private)
	platform_web_input_frame_begin :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_web_input_frame_begin: nil context")
	}

	@(private)
	platform_web_input_frame_end :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_web_input_frame_end: nil context")
	}

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
	platform_set_text_input_rect :: proc(ctx: ^Context, x, y, w, h: i32) {
		if ctx == nil || ctx.win == nil do return
		_ime_set_rect(ctx, x, y, w, h)
	}

	@(private)
	platform_text_input_deactivate :: proc(ctx: ^Context) {
		if ctx == nil || ctx.win == nil do return
		_ime_deactivate()
	}

	@(private)
	platform_cursor_pos :: proc(ctx: ^Context) -> (f64, f64) {
		assert(ctx != nil && ctx.win != nil, "platform_cursor_pos: invalid context")
		return glfw.GetCursorPos(_context_window(ctx))
	}

	@(private)
	platform_set_cursor_pos :: proc(ctx: ^Context, x, y: f64) {
		if ctx == nil || ctx.win == nil do return
		glfw.SetCursorPos(_context_window(ctx), x, y)
	}

	@(private)
	platform_mouse_button :: proc(ctx: ^Context, button: i32) -> bool {
		if ctx == nil || ctx.win == nil do return false
		return glfw.GetMouseButton(_context_window(ctx), button) == glfw.PRESS
	}

	@(private)
	platform_window_hovered :: proc(ctx: ^Context) -> bool {
		if ctx == nil || ctx.win == nil do return false
		win := _context_window(ctx)
		if glfw.GetWindowAttrib(win, glfw.FOCUSED) == 0 do return false
		x, y := glfw.GetCursorPos(win)
		width, height := glfw.GetWindowSize(win)
		return _pointer_inside_window(x, y, width, height)
	}

	@(private)
	_pointer_inside_window :: proc(x, y: f64, width, height: i32) -> bool {
		if width <= 0 || height <= 0 do return false
		return x >= 0 && y >= 0 && x < f64(width) && y < f64(height)
	}

	@(private)
	platform_key_down :: proc(ctx: ^Context, key: i32) -> bool {
		if ctx == nil || ctx.win == nil do return false
		return glfw.GetKey(_context_window(ctx), key) == glfw.PRESS
	}

	@(private)
	platform_set_mouse_cursor :: proc(ctx: ^Context, cursor: MouseCursor) {
		if ctx == nil || ctx.win == nil do return
		i := int(cursor)
		if i < 0 || i >= len(g_cursors) do return
		glfw.SetCursor(_context_window(ctx), g_cursors[i])
	}

	@(private)
	platform_set_cursor_hidden :: proc(ctx: ^Context, hidden: bool) {
		if ctx == nil || ctx.win == nil do return
		mode: i32 = glfw.CURSOR_HIDDEN if hidden else glfw.CURSOR_NORMAL
		glfw.SetInputMode(_context_window(ctx), glfw.CURSOR, mode)
	}

	@(private)
	platform_get_clipboard :: proc(ctx: ^Context) -> string {
		if ctx == nil || ctx.win == nil do return ""
		return glfw.GetClipboardString(_context_window(ctx))
	}

	@(private)
	platform_set_clipboard :: proc(ctx: ^Context, text: cstring) {
		if ctx == nil || ctx.win == nil do return
		glfw.SetClipboardString(_context_window(ctx), text)
	}

	@(private)
	platform_drop_init :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_drop_init: nil context")
		_drop_state_reset_context(ctx)
		if ctx.win != nil do glfw.SetDropCallback(_context_window(ctx), _drop_cb)
		platform_dragdrop_init(ctx)
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
	platform_drop_shutdown :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_drop_shutdown: nil context")
		platform_dragdrop_shutdown(ctx)
		if ctx.win != nil do glfw.SetDropCallback(_context_window(ctx), nil)
		_drop_native_shutdown_context(ctx)
	}

	// platform_gamepad_poll snapshots every gamepad slot from GLFW's SDL-mapping
	// database. Buttons arrive in GLFW order and are remapped to the raylib
	// GamepadButton layout via _GLFW_PAD_REMAP; the analog triggers additionally
	// set the digital LEFT/RIGHT_TRIGGER_2 buttons (raylib parity - GLFW exposes
	// triggers only as axes).
	@(private)
	platform_gamepad_poll :: proc(pads: ^[MAX_GAMEPADS]Gamepad_State, idle: ^Idle_State) {
		assert(pads != nil, "platform_gamepad_poll: nil pads")
		assert(idle != nil, "platform_gamepad_poll: nil idle state")
		#assert(MAX_GAMEPADS <= glfw.JOYSTICK_LAST + 1)
		for jid in 0 ..< MAX_GAMEPADS {
			pad := &pads[jid]
			connected := bool(glfw.JoystickIsGamepad(c.int(jid)))
			if connected != pad.connected {
				_idle_note_activity(idle)
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
			pad.buttons[int(GamepadButton.LEFT_TRIGGER_2)] =
				state.axes[4] > TRIGGER_PRESS_THRESHOLD
			pad.buttons[int(GamepadButton.RIGHT_TRIGGER_2)] =
				state.axes[5] > TRIGGER_PRESS_THRESHOLD
			if pad.buttons != pad.prev_buttons {
				_idle_note_activity(idle)
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
			ctx.inp.key_down[key] = true
			_stage_key(&ctx.inp, KeyboardKey(key))
		case glfw.RELEASE:
			ctx.inp.st_released[key] = true
			ctx.inp.key_down[key] = false
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

	@(private)
	_native_pointer_buttons :: proc "contextless" (
		win: glfw.WindowHandle,
		changed_button, changed_action: i32,
	) -> Pointer_Buttons {
		if win == nil do return 0
		buttons: u16
		for button in 0 ..< 7 {
			down := glfw.GetMouseButton(win, i32(button)) == glfw.PRESS
			if i32(button) == changed_button do down = changed_action == glfw.PRESS
			if down do buttons |= u16(1) << u16(button)
		}
		return Pointer_Buttons(buttons)
	}

	@(private)
	_pointer_mouse_pressure :: proc "contextless" (buttons: Pointer_Buttons) -> f32 {
		return buttons != 0 ? 0.5 : 0
	}

	@(private)
	_cursor_pos_cb :: proc "c" (win: glfw.WindowHandle, xpos, ypos: f64) {
		ctx := _callback_context(win)
		if ctx == nil do return
		_idle_note_activity(&ctx.idle)
		buttons := _native_pointer_buttons(win, -1, -1)
		_ = pointer_stage(
			&ctx.inp,
			{
				id = POINTER_ID_NATIVE_MOUSE,
				position = {f32(xpos), f32(ypos)},
				pressure = _pointer_mouse_pressure(buttons),
				buttons = buttons,
				kind = .Move,
				pointer_type = .Mouse,
				button = .None,
				primary = true,
			},
		)
	}

	@(private)
	_mouse_button_cb :: proc "c" (win: glfw.WindowHandle, button, action, mods: i32) {
		ctx := _callback_context(win)
		if ctx == nil do return
		_idle_note_activity(&ctx.idle)
		if button < 0 || button > i32(Pointer_Button.Back) do return
		if action != glfw.PRESS && action != glfw.RELEASE do return
		x, y := glfw.GetCursorPos(win)
		down := action == glfw.PRESS
		buttons := _native_pointer_buttons(win, button, action)
		ctx.inp.pointer_native_mouse_active = down || buttons != 0
		_ = pointer_stage(
			&ctx.inp,
			{
				id = POINTER_ID_NATIVE_MOUSE,
				position = {f32(x), f32(y)},
				pressure = _pointer_mouse_pressure(buttons),
				buttons = buttons,
				kind = down ? Pointer_Event_Kind.Down : .Up,
				pointer_type = .Mouse,
				button = Pointer_Button(button),
				primary = true,
			},
		)
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
		if focused == 0 && ctx.inp.pointer_native_mouse_active {
			x, y := glfw.GetCursorPos(win)
			_ = pointer_stage(
				&ctx.inp,
				{
					id = POINTER_ID_NATIVE_MOUSE,
					position = {f32(x), f32(y)},
					kind = .Cancel,
					pointer_type = .Mouse,
					button = .None,
					primary = true,
				},
			)
			ctx.inp.pointer_native_mouse_active = false
		}
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

}
