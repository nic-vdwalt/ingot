#+build !js
package gfx

@(require) import "core:c"
@(require) import "core:fmt"
@(require) import "core:strings"
@(require) import "core:unicode/utf8"
@(require) import sdl "vendor:sdl3"
@(require) import wg "vendor:wgpu"
@(require) import sdlglue "vendor:wgpu/sdl3glue"

when INGOT_GFX_SDL3 {

	SDL_WINDOW_MAX :: 16
	SDL_EVENT_PUMP_MAX :: 4096
	SDL_GPU_EVENT_PUMP_MAX :: 1_000_000
	SDL_WAKE_EVENT :: sdl.EventType.USER

	Sdl_Window_State :: struct {
		window:          ^sdl.Window,
		owner:           ^Context,
		close_requested: bool,
		mouse_inside:    bool,
		mouse_buttons:   [8]bool,
	}

	@(private)
	g_sdl_windows: [SDL_WINDOW_MAX]Sdl_Window_State
	@(private)
	g_sdl_window_count: int
	@(private)
	g_sdl_cursors: [11]^sdl.Cursor
	@(private)
	g_sdl_gamepads: [MAX_GAMEPADS]^sdl.Gamepad

	@(private)
	_sdl_window :: proc(ctx: ^Context) -> ^sdl.Window {
		assert(ctx != nil, "_sdl_window: nil context")
		return cast(^sdl.Window)rawptr(ctx.win)
	}

	@(private)
	_sdl_state_for_window :: proc(window: ^sdl.Window) -> ^Sdl_Window_State {
		if window == nil do return nil
		for &state in g_sdl_windows {
			if state.window == window do return &state
		}
		return nil
	}

	@(private)
	_sdl_state_for_id :: proc(id: sdl.WindowID) -> ^Sdl_Window_State {
		if id == 0 do return nil
		return _sdl_state_for_window(sdl.GetWindowFromID(id))
	}

	@(private)
	_sdl_state_add :: proc(window: ^sdl.Window, owner: ^Context) -> bool {
		assert(window != nil && owner != nil, "_sdl_state_add: invalid argument")
		for &state in g_sdl_windows {
			if state.window != nil do continue
			state.window = window
			state.owner = owner
			state.mouse_inside = true
			g_sdl_window_count += 1
			return true
		}
		return false
	}

	@(private)
	_sdl_state_remove :: proc(window: ^sdl.Window) {
		state := _sdl_state_for_window(window)
		if state == nil do return
		state^ = {}
		assert(g_sdl_window_count > 0, "_sdl_state_remove: window count underflow")
		g_sdl_window_count -= 1
	}

	@(private)
	_sdl_window_flags :: proc(flags: ConfigFlags) -> sdl.WindowFlags {
		result := sdl.WindowFlags{.HIGH_PIXEL_DENSITY}
		if .WINDOW_RESIZABLE in flags do result += {.RESIZABLE}
		if .WINDOW_UNDECORATED in flags do result += {.BORDERLESS}
		if .WINDOW_TRANSPARENT in flags do result += {.TRANSPARENT}
		if .WINDOW_HIDDEN in flags do result += {.HIDDEN}
		if .WINDOW_MINIMIZED in flags do result += {.MINIMIZED}
		if .WINDOW_MAXIMIZED in flags do result += {.MAXIMIZED}
		if .WINDOW_TOPMOST in flags do result += {.ALWAYS_ON_TOP}
		if .FULLSCREEN_MODE in flags do result += {.FULLSCREEN}
		return result
	}

	@(private)
	platform_create_window :: proc(
		ctx: ^Context,
		width, height: i32,
		title: cstring,
		flags: ConfigFlags,
	) -> bool {
		assert(ctx != nil, "platform_create_window: nil context")
		if g_sdl_window_count == 0 {
			if !sdl.Init({.VIDEO, .GAMEPAD}) {
				fmt.eprintfln("gfx: SDL init failed: %s", sdl.GetError())
				return false
			}
		}
		window := sdl.CreateWindow(title, c.int(width), c.int(height), _sdl_window_flags(flags))
		if window == nil {
			fmt.eprintfln("gfx: SDL window creation failed: %s", sdl.GetError())
			if g_sdl_window_count == 0 do sdl.Quit()
			return false
		}
		if !_sdl_state_add(window, ctx) {
			sdl.DestroyWindow(window)
			if g_sdl_window_count == 0 do sdl.Quit()
			return false
		}
		ctx.win = Window_Handle(rawptr(window))
		return true
	}

	@(private)
	platform_window_ready :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_window_ready: nil context")
		assert(ctx.win != nil, "platform_window_ready: no window")
		if !_window_should_activate(ctx.config_flags) do return
		_platform_activate_window(ctx)
		_ = sdl.RaiseWindow(_sdl_window(ctx))
	}

	@(private)
	platform_create_surface :: proc(ctx: ^Context, instance: wg.Instance) -> wg.Surface {
		assert(ctx != nil, "platform_create_surface: nil context")
		assert(ctx.win != nil, "platform_create_surface: no window")
		assert(instance != nil, "platform_create_surface: nil instance")
		surface := sdlglue.GetSurface(instance, _sdl_window(ctx))
		if surface == nil do fmt.eprintfln("gfx: SDL WebGPU surface creation failed: %s", sdl.GetError())
		return surface
	}

	@(private)
	platform_start_gpu :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_start_gpu: nil context")
		ares: Adapter_Res
		wg.InstanceRequestAdapter(
			ctx.instance,
			&{compatibleSurface = ctx.surface},
			{mode = .AllowProcessEvents, callback = _on_adapter, userdata1 = &ares},
		)
		for event_count := 0;
		    event_count < SDL_GPU_EVENT_PUMP_MAX && !ares.done;
		    event_count += 1 {
			wg.InstanceProcessEvents(ctx.instance)
		}
		assert(ares.done, "platform_start_gpu: adapter request did not finish")
		if ares.status != .Success || ares.adapter == nil {
			fmt.eprintln("gfx: adapter request failed")
			_close_window_context(ctx)
			return
		}
		ctx.adapter = ares.adapter
		ctx.budget = gpu_negotiate_budget(ares.adapter)
		dres: Device_Res
		dev_desc := wg.DeviceDescriptor {
			uncapturedErrorCallbackInfo = {callback = _on_uncaptured_error},
		}
		wg.AdapterRequestDevice(
			ctx.adapter,
			&dev_desc,
			{mode = .AllowProcessEvents, callback = _on_device, userdata1 = &dres},
		)
		for event_count := 0;
		    event_count < SDL_GPU_EVENT_PUMP_MAX && !dres.done;
		    event_count += 1 {
			wg.InstanceProcessEvents(ctx.instance)
		}
		assert(dres.done, "platform_start_gpu: device request did not finish")
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

	@(private)
	platform_process_events :: proc(instance: wg.Instance) {
		wg.InstanceProcessEvents(instance)
	}

	@(private)
	platform_framebuffer_size :: proc(ctx: ^Context) -> (i32, i32) {
		assert(ctx != nil && ctx.win != nil, "platform_framebuffer_size: invalid context")
		width, height: c.int
		if !sdl.GetWindowSizeInPixels(_sdl_window(ctx), &width, &height) do return 0, 0
		return i32(width), i32(height)
	}

	@(private)
	platform_window_size :: proc(ctx: ^Context) -> (i32, i32) {
		assert(ctx != nil && ctx.win != nil, "platform_window_size: invalid context")
		width, height: c.int
		if !sdl.GetWindowSize(_sdl_window(ctx), &width, &height) do return 0, 0
		return i32(width), i32(height)
	}

	@(private)
	platform_content_scale :: proc(ctx: ^Context) -> f32 {
		assert(ctx != nil && ctx.win != nil, "platform_content_scale: invalid context")
		return max(sdl.GetWindowDisplayScale(_sdl_window(ctx)), 1)
	}

	@(private)
	platform_should_close :: proc(ctx: ^Context) -> bool {
		if ctx == nil || ctx.win == nil do return true
		state := _sdl_state_for_window(_sdl_window(ctx))
		assert(state == nil || state.owner == ctx, "platform_should_close: invalid window owner")
		return state == nil || state.close_requested
	}

	@(private)
	_sdl_poll_all :: proc() {
		event: sdl.Event
		count := 0
		for count < SDL_EVENT_PUMP_MAX && sdl.PollEvent(&event) {
			_sdl_dispatch(&event)
			count += 1
		}
		assert(count < SDL_EVENT_PUMP_MAX, "_sdl_poll_all: event pump limit reached")
	}

	@(private)
	platform_poll_events :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_poll_events: nil context")
		_sdl_poll_all()
	}

	@(private)
	platform_wait_events :: proc(timeout: f64) {
		assert(timeout >= 0, "platform_wait_events: negative timeout")
		milliseconds := i32(clamp(timeout * 1000, 0, f64(max(i32))))
		event: sdl.Event
		if sdl.WaitEventTimeout(&event, milliseconds) do _sdl_dispatch(&event)
		_sdl_poll_all()
	}

	@(private)
	platform_wake :: proc "contextless" () {
		if g_sdl_window_count == 0 do return
		event: sdl.Event
		event.type = SDL_WAKE_EVENT
		_ = sdl.PushEvent(&event)
	}

	@(private)
	platform_window_iconified :: proc(ctx: ^Context) -> bool {
		if ctx == nil || ctx.win == nil do return false
		return .MINIMIZED in sdl.GetWindowFlags(_sdl_window(ctx))
	}

	@(private)
	platform_terminate :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_terminate: nil context")
		if ctx.win != nil {
			window := _sdl_window(ctx)
			_sdl_state_remove(window)
			sdl.DestroyWindow(window)
			ctx.win = nil
		}
		if g_sdl_window_count != 0 do return
		for &cursor in g_sdl_cursors {
			if cursor != nil do sdl.DestroyCursor(cursor)
			cursor = nil
		}
		for &gamepad in g_sdl_gamepads {
			if gamepad != nil do sdl.CloseGamepad(gamepad)
			gamepad = nil
		}
		sdl.Quit()
	}

	@(private)
	platform_now :: proc() -> f64 {
		return f64(sdl.GetTicksNS()) / 1_000_000_000
	}

	@(private)
	platform_sleep :: proc(seconds: f64) {
		if seconds > 0 do sdl.DelayPrecise(u64(seconds * 1_000_000_000))
	}

	@(private)
	platform_set_window_min_size :: proc(ctx: ^Context, width, height: i32) {
		if ctx != nil && ctx.win != nil {
			_ = sdl.SetWindowMinimumSize(_sdl_window(ctx), c.int(width), c.int(height))
		}
	}

	@(private)
	platform_set_window_size :: proc(ctx: ^Context, width, height: i32) {
		if ctx != nil && ctx.win != nil {
			_ = sdl.SetWindowSize(_sdl_window(ctx), c.int(width), c.int(height))
		}
	}

	@(private)
	platform_set_window_title :: proc(ctx: ^Context, title: cstring) {
		if ctx != nil && ctx.win != nil do _ = sdl.SetWindowTitle(_sdl_window(ctx), title)
	}

	@(private)
	platform_set_window_position :: proc(ctx: ^Context, x, y: i32) {
		if ctx != nil && ctx.win != nil do _ = sdl.SetWindowPosition(_sdl_window(ctx), c.int(x), c.int(y))
	}

	@(private)
	platform_window_position :: proc(ctx: ^Context) -> (i32, i32) {
		if ctx == nil || ctx.win == nil do return 0, 0
		x, y: c.int
		if !sdl.GetWindowPosition(_sdl_window(ctx), &x, &y) do return 0, 0
		return i32(x), i32(y)
	}

	@(private)
	platform_monitor_refresh_rate :: proc(ctx: ^Context) -> i32 {
		if ctx == nil || ctx.win == nil do return 0
		display := sdl.GetDisplayForWindow(_sdl_window(ctx))
		if display == 0 do return 0
		mode := sdl.GetCurrentDisplayMode(display)
		if mode == nil || mode.refresh_rate <= 0 do return 0
		return i32(mode.refresh_rate + 0.5)
	}

	@(private)
	platform_window_focused :: proc(ctx: ^Context) -> bool {
		if ctx == nil || ctx.win == nil do return false
		return .INPUT_FOCUS in sdl.GetWindowFlags(_sdl_window(ctx))
	}

	@(private)
	platform_set_window_icon :: proc(ctx: ^Context, image: Image) {
		if ctx == nil || ctx.win == nil || image.data == nil do return
		pitch := c.int(image.width * 4)
		surface := sdl.CreateSurfaceFrom(image.width, image.height, .RGBA32, image.data, pitch)
		if surface == nil do return
		_ = sdl.SetWindowIcon(_sdl_window(ctx), surface)
		sdl.DestroySurface(surface)
	}

	@(private)
	_sdl_cursor_kind :: proc(cursor: MouseCursor) -> sdl.SystemCursor {
		#partial switch cursor {
		case .DEFAULT, .ARROW:
			return .DEFAULT
		case .IBEAM:
			return .TEXT
		case .CROSSHAIR:
			return .CROSSHAIR
		case .POINTING_HAND:
			return .POINTER
		case .RESIZE_EW:
			return .EW_RESIZE
		case .RESIZE_NS:
			return .NS_RESIZE
		case .RESIZE_NWSE:
			return .NWSE_RESIZE
		case .RESIZE_NESW:
			return .NESW_RESIZE
		case .RESIZE_ALL:
			return .MOVE
		case .NOT_ALLOWED:
			return .NOT_ALLOWED
		}
		return .DEFAULT
	}

	@(private)
	platform_input_init :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_input_init: nil context")
		if ctx.win == nil do return
		for cursor in MouseCursor {
			index := int(cursor)
			if index >= 0 && index < len(g_sdl_cursors) && g_sdl_cursors[index] == nil {
				g_sdl_cursors[index] = sdl.CreateSystemCursor(_sdl_cursor_kind(cursor))
			}
		}
		x, y: f32
		_ = sdl.GetMouseState(&x, &y)
		ctx.inp.mouse = {x, y}
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

	@(private)
	platform_set_text_input_rect :: proc(ctx: ^Context, x, y, w, h: i32) {
		if ctx == nil || ctx.win == nil do return
		window := _sdl_window(ctx)
		if !sdl.TextInputActive(window) do _ = sdl.StartTextInput(window)
		rect := sdl.Rect{x, y, w, h}
		_ = sdl.SetTextInputArea(window, &rect, 0)
	}

	@(private)
	platform_text_input_deactivate :: proc(ctx: ^Context) {
		if ctx == nil || ctx.win == nil do return
		window := _sdl_window(ctx)
		if sdl.TextInputActive(window) do _ = sdl.StopTextInput(window)
	}

	@(private)
	platform_cursor_pos :: proc(ctx: ^Context) -> (f64, f64) {
		assert(ctx != nil, "platform_cursor_pos: nil context")
		assert(ctx.win != nil, "platform_cursor_pos: no window")
		return f64(ctx.inp.mouse.x), f64(ctx.inp.mouse.y)
	}

	@(private)
	platform_set_cursor_pos :: proc(ctx: ^Context, x, y: f64) {
		if ctx != nil && ctx.win != nil do sdl.WarpMouseInWindow(_sdl_window(ctx), f32(x), f32(y))
	}

	@(private)
	platform_mouse_button :: proc(ctx: ^Context, button: i32) -> bool {
		if ctx == nil || ctx.win == nil || button < 0 || button >= 8 do return false
		state := _sdl_state_for_window(_sdl_window(ctx))
		if state == nil do return false
		return state.mouse_buttons[button]
	}

	@(private)
	platform_window_hovered :: proc(ctx: ^Context) -> bool {
		if ctx == nil || ctx.win == nil do return false
		state := _sdl_state_for_window(_sdl_window(ctx))
		if state == nil do return false
		if state.mouse_inside do return true
		if !platform_window_focused(ctx) do return false
		x, y := platform_cursor_pos(ctx)
		width, height := platform_window_size(ctx)
		return _pointer_inside_window(x, y, width, height)
	}

	@(private)
	_pointer_inside_window :: proc(x, y: f64, width, height: i32) -> bool {
		if width <= 0 || height <= 0 do return false
		return x >= 0 && y >= 0 && x < f64(width) && y < f64(height)
	}

	@(private)
	platform_key_down :: proc(ctx: ^Context, key: i32) -> bool {
		if ctx == nil || key < 0 || key >= KEY_COUNT do return false
		return ctx.inp.key_down[key]
	}

	@(private)
	platform_set_mouse_cursor :: proc(ctx: ^Context, cursor: MouseCursor) {
		if ctx == nil || ctx.win == nil do return
		index := int(cursor)
		if index >= 0 && index < len(g_sdl_cursors) && g_sdl_cursors[index] != nil {
			_ = sdl.SetCursor(g_sdl_cursors[index])
		}
	}

	@(private)
	platform_set_cursor_hidden :: proc(ctx: ^Context, hidden: bool) {
		if ctx == nil || ctx.win == nil do return
		if hidden do _ = sdl.HideCursor()
		else do _ = sdl.ShowCursor()
	}

	@(private)
	platform_get_clipboard :: proc(ctx: ^Context) -> string {
		if ctx == nil || ctx.win == nil do return ""
		value := sdl.GetClipboardText()
		if value == nil do return ""
		defer sdl.free(value)
		return strings.clone(string(cstring(value)), context.temp_allocator)
	}

	@(private)
	platform_set_clipboard :: proc(ctx: ^Context, text: cstring) {
		if ctx != nil && ctx.win != nil do _ = sdl.SetClipboardText(text)
	}

	@(private)
	platform_drop_init :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_drop_init: nil context")
		_drop_state_reset_context(ctx)
	}

	@(private)
	platform_drop_prepare_events :: proc() {}

	@(private)
	platform_drop_finish_events :: proc() {}

	@(private)
	platform_drop_shutdown :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_drop_shutdown: nil context")
		_drop_native_shutdown_context(ctx)
	}

	@(private)
	_sdl_gamepad_reconcile :: proc() {
		count: c.int
		ids := sdl.GetGamepads(&count)
		if ids == nil do return
		defer sdl.free(ids)
		assert(count >= 0, "_sdl_gamepad_reconcile: negative count")
		for &gamepad in g_sdl_gamepads {
			if gamepad == nil do continue
			id := sdl.GetGamepadID(gamepad)
			found := false
			for index in 0 ..< int(count) {
				if ids[index] == id {found = true; break}
			}
			if !found {sdl.CloseGamepad(gamepad); gamepad = nil}
		}
		for index in 0 ..< int(count) {
			id := ids[index]
			if sdl.GetGamepadFromID(id) != nil do continue
			for &slot in g_sdl_gamepads {
				if slot == nil {slot = sdl.OpenGamepad(id); break}
			}
		}
	}

	@(private)
	_sdl_axis_normalize :: proc(value: i16) -> f32 {
		if value < 0 do return f32(value) / 32768
		return f32(value) / 32767
	}

	@(private)
	_sdl_trigger_normalize :: proc(value: i16) -> f32 {
		return clamp(f32(value) / 32767 * 2 - 1, -1, 1)
	}

	@(private)
	_sdl_gamepad_button :: proc(gamepad: ^sdl.Gamepad, button: GamepadButton) -> bool {
		assert(gamepad != nil, "_sdl_gamepad_button: nil gamepad")
		sdl_button: sdl.GamepadButton
		#partial switch button {
		case .UNKNOWN, .LEFT_TRIGGER_2, .RIGHT_TRIGGER_2:
			return false
		case .RIGHT_FACE_DOWN:
			sdl_button = .SOUTH
		case .RIGHT_FACE_RIGHT:
			sdl_button = .EAST
		case .RIGHT_FACE_LEFT:
			sdl_button = .WEST
		case .RIGHT_FACE_UP:
			sdl_button = .NORTH
		case .LEFT_TRIGGER_1:
			sdl_button = .LEFT_SHOULDER
		case .RIGHT_TRIGGER_1:
			sdl_button = .RIGHT_SHOULDER
		case .MIDDLE_LEFT:
			sdl_button = .BACK
		case .MIDDLE:
			sdl_button = .GUIDE
		case .MIDDLE_RIGHT:
			sdl_button = .START
		case .LEFT_THUMB:
			sdl_button = .LEFT_STICK
		case .RIGHT_THUMB:
			sdl_button = .RIGHT_STICK
		case .LEFT_FACE_UP:
			sdl_button = .DPAD_UP
		case .LEFT_FACE_RIGHT:
			sdl_button = .DPAD_RIGHT
		case .LEFT_FACE_DOWN:
			sdl_button = .DPAD_DOWN
		case .LEFT_FACE_LEFT:
			sdl_button = .DPAD_LEFT
		}
		return sdl.GetGamepadButton(gamepad, sdl_button)
	}

	@(private)
	platform_gamepad_poll :: proc(pads: ^[MAX_GAMEPADS]Gamepad_State, idle: ^Idle_State) {
		assert(pads != nil && idle != nil, "platform_gamepad_poll: invalid argument")
		_sdl_gamepad_reconcile()
		for index in 0 ..< MAX_GAMEPADS {
			pad := &pads[index]
			gamepad := g_sdl_gamepads[index]
			connected := gamepad != nil && sdl.GamepadConnected(gamepad)
			if connected != pad.connected do _idle_note_activity(idle)
			pad.connected = connected
			if !connected {pad.buttons = {}; pad.axes = {}; pad.name_len = 0; continue}
			pad.buttons = {}
			for button in GamepadButton {
				pad.buttons[int(button)] = _sdl_gamepad_button(gamepad, button)
			}
			pad.axes[0] = _sdl_axis_normalize(sdl.GetGamepadAxis(gamepad, .LEFTX))
			pad.axes[1] = _sdl_axis_normalize(sdl.GetGamepadAxis(gamepad, .LEFTY))
			pad.axes[2] = _sdl_axis_normalize(sdl.GetGamepadAxis(gamepad, .RIGHTX))
			pad.axes[3] = _sdl_axis_normalize(sdl.GetGamepadAxis(gamepad, .RIGHTY))
			pad.axes[4] = _sdl_trigger_normalize(sdl.GetGamepadAxis(gamepad, .LEFT_TRIGGER))
			pad.axes[5] = _sdl_trigger_normalize(sdl.GetGamepadAxis(gamepad, .RIGHT_TRIGGER))
			pad.buttons[int(GamepadButton.LEFT_TRIGGER_2)] = pad.axes[4] > TRIGGER_PRESS_THRESHOLD
			pad.buttons[int(GamepadButton.RIGHT_TRIGGER_2)] = pad.axes[5] > TRIGGER_PRESS_THRESHOLD
			if pad.buttons != pad.prev_buttons do _idle_note_activity(idle)
			name_ptr := sdl.GetGamepadName(gamepad)
			name := ""
			if name_ptr != nil do name = string(name_ptr)
			length := min(len(name), GAMEPAD_NAME_MAX)
			pad.name = {}
			copy(pad.name[:length], transmute([]u8)name[:length])
			pad.name_len = i32(length)
		}
	}

	@(private)
	_sdl_key :: proc(scancode: sdl.Scancode) -> KeyboardKey {
		if scancode >= .A && scancode <= .Z {
			return KeyboardKey(int(KeyboardKey.A) + int(scancode) - int(sdl.Scancode.A))
		}
		if scancode >= ._1 && scancode <= ._9 {
			return KeyboardKey(int(KeyboardKey.ONE) + int(scancode) - int(sdl.Scancode._1))
		}
		#partial switch scancode {
		case ._0:
			return .ZERO
		case .SPACE:
			return .SPACE
		case .APOSTROPHE:
			return .APOSTROPHE
		case .COMMA:
			return .COMMA
		case .MINUS:
			return .MINUS
		case .PERIOD:
			return .PERIOD
		case .SLASH:
			return .SLASH
		case .SEMICOLON:
			return .SEMICOLON
		case .EQUALS:
			return .EQUAL
		case .LEFTBRACKET:
			return .LEFT_BRACKET
		case .BACKSLASH, .NONUSBACKSLASH:
			return .BACKSLASH
		case .RIGHTBRACKET:
			return .RIGHT_BRACKET
		case .GRAVE:
			return .GRAVE
		case .ESCAPE:
			return .ESCAPE
		case .RETURN:
			return .ENTER
		case .TAB:
			return .TAB
		case .BACKSPACE:
			return .BACKSPACE
		case .INSERT:
			return .INSERT
		case .DELETE:
			return .DELETE
		case .RIGHT:
			return .RIGHT
		case .LEFT:
			return .LEFT
		case .DOWN:
			return .DOWN
		case .UP:
			return .UP
		case .PAGEUP:
			return .PAGE_UP
		case .PAGEDOWN:
			return .PAGE_DOWN
		case .HOME:
			return .HOME
		case .END:
			return .END
		case .CAPSLOCK:
			return .CAPS_LOCK
		case .SCROLLLOCK:
			return .SCROLL_LOCK
		case .NUMLOCKCLEAR:
			return .NUM_LOCK
		case .PRINTSCREEN:
			return .PRINT_SCREEN
		case .PAUSE:
			return .PAUSE
		case .F1 ..= .F12:
			return KeyboardKey(int(KeyboardKey.F1) + int(scancode) - int(sdl.Scancode.F1))
		case:
			return _sdl_key_extended(scancode)
		}
	}

	@(private)
	_sdl_key_extended :: proc(scancode: sdl.Scancode) -> KeyboardKey {
		#partial switch scancode {
		case .KP_0:
			return .KP_0
		case .KP_1 ..= .KP_9:
			return KeyboardKey(int(KeyboardKey.KP_1) + int(scancode) - int(sdl.Scancode.KP_1))
		case .KP_PERIOD:
			return .KP_DECIMAL
		case .KP_DIVIDE:
			return .KP_DIVIDE
		case .KP_MULTIPLY:
			return .KP_MULTIPLY
		case .KP_MINUS:
			return .KP_SUBTRACT
		case .KP_PLUS:
			return .KP_ADD
		case .KP_ENTER:
			return .KP_ENTER
		case .KP_EQUALS:
			return .KP_EQUAL
		case .LSHIFT:
			return .LEFT_SHIFT
		case .LCTRL:
			return .LEFT_CONTROL
		case .LALT:
			return .LEFT_ALT
		case .LGUI:
			return .LEFT_SUPER
		case .RSHIFT:
			return .RIGHT_SHIFT
		case .RCTRL:
			return .RIGHT_CONTROL
		case .RALT:
			return .RIGHT_ALT
		case .RGUI:
			return .RIGHT_SUPER
		case .APPLICATION:
			return .KB_MENU
		case:
			return .KEY_NULL
		}
	}

	@(private)
	_sdl_mouse_button :: proc(button: u8) -> i32 {
		switch button {
		case sdl.BUTTON_LEFT:
			return i32(MouseButton.LEFT)
		case sdl.BUTTON_RIGHT:
			return i32(MouseButton.RIGHT)
		case sdl.BUTTON_MIDDLE:
			return i32(MouseButton.MIDDLE)
		case sdl.BUTTON_X1:
			return i32(MouseButton.SIDE)
		case sdl.BUTTON_X2:
			return i32(MouseButton.EXTRA)
		case:
			return -1
		}
	}

	@(private)
	_sdl_pointer_buttons :: proc(state: ^Sdl_Window_State) -> Pointer_Buttons {
		assert(state != nil, "_sdl_pointer_buttons: nil state")
		buttons: u16
		for index in 0 ..< 7 {
			if state.mouse_buttons[index] do buttons |= u16(1) << u16(index)
		}
		return Pointer_Buttons(buttons)
	}

	@(private)
	_sdl_pointer_pressure :: proc(buttons: Pointer_Buttons) -> f32 {
		return buttons != 0 ? 0.5 : 0
	}

	@(private)
	_sdl_dispatch_key :: proc(event: ^sdl.Event) {
		assert(event != nil, "_sdl_dispatch_key: nil event")
		state := _sdl_state_for_id(event.key.windowID)
		if state == nil do return
		ctx := state.owner
		key := _sdl_key(event.key.scancode)
		_idle_note_activity(&ctx.idle)
		if key == .KEY_NULL do return
		index := int(key)
		assert(index >= 0 && index < KEY_COUNT, "_sdl_dispatch_key: invalid key")
		if event.key.down {
			ctx.inp.key_down[index] = true
			if event.key.repeat do ctx.inp.st_repeat[index] = true
			else {ctx.inp.st_pressed[index] = true; _stage_key(&ctx.inp, key)}
		} else {
			ctx.inp.key_down[index] = false
			ctx.inp.st_released[index] = true
		}
	}

	@(private)
	_sdl_dispatch_text :: proc(event: ^sdl.Event) {
		state := _sdl_state_for_id(event.text.windowID)
		if state == nil || event.text.text == nil do return
		_idle_note_activity(&state.owner.idle)
		text := string(event.text.text)
		for offset := 0; offset < len(text); {
			value, size := utf8.decode_rune_in_string(text[offset:])
			if size <= 0 do break
			if value != utf8.RUNE_ERROR || size > 1 do _stage_char(&state.owner.inp, value)
			offset += size
		}
	}

	@(private)
	_sdl_dispatch_motion :: proc(event: ^sdl.Event) {
		state := _sdl_state_for_id(event.motion.windowID)
		if state == nil || event.motion.which == sdl.TOUCH_MOUSEID do return
		ctx := state.owner
		_idle_note_activity(&ctx.idle)
		ctx.inp.mouse = {event.motion.x, event.motion.y}
		buttons := _sdl_pointer_buttons(state)
		_ = pointer_stage(
			&ctx.inp,
			{
				id = POINTER_ID_NATIVE_MOUSE,
				position = ctx.inp.mouse,
				pressure = _sdl_pointer_pressure(buttons),
				buttons = buttons,
				kind = .Move,
				pointer_type = .Mouse,
				button = .None,
				primary = true,
			},
		)
	}

	@(private)
	_sdl_dispatch_button :: proc(event: ^sdl.Event) {
		state := _sdl_state_for_id(event.button.windowID)
		if state == nil || event.button.which == sdl.TOUCH_MOUSEID do return
		button := _sdl_mouse_button(event.button.button)
		if button < 0 || button >= 7 do return
		ctx := state.owner
		_idle_note_activity(&ctx.idle)
		state.mouse_buttons[button] = event.button.down
		ctx.inp.mouse = {event.button.x, event.button.y}
		buttons := _sdl_pointer_buttons(state)
		ctx.inp.pointer_native_mouse_active = event.button.down || buttons != 0
		_ = pointer_stage(
			&ctx.inp,
			{
				id = POINTER_ID_NATIVE_MOUSE,
				position = {event.button.x, event.button.y},
				pressure = _sdl_pointer_pressure(buttons),
				buttons = buttons,
				kind = event.button.down ? Pointer_Event_Kind.Down : .Up,
				pointer_type = .Mouse,
				button = Pointer_Button(button),
				primary = true,
			},
		)
	}

	@(private)
	_sdl_dispatch_window :: proc(event: ^sdl.Event) {
		state := _sdl_state_for_id(event.window.windowID)
		if state == nil do return
		ctx := state.owner
		#partial switch event.type {
		case .WINDOW_CLOSE_REQUESTED:
			state.close_requested = true
		case .WINDOW_MOUSE_ENTER:
			state.mouse_inside = true
		case .WINDOW_MOUSE_LEAVE:
			state.mouse_inside = false
		case .WINDOW_FOCUS_LOST:
			if ctx.inp.pointer_native_mouse_active {
				_ = pointer_stage(
					&ctx.inp,
					{
						id = POINTER_ID_NATIVE_MOUSE,
						position = ctx.inp.mouse,
						kind = .Cancel,
						pointer_type = .Mouse,
						button = .None,
						primary = true,
					},
				)
				ctx.inp.pointer_native_mouse_active = false
			}
			state.mouse_buttons = {}
			ctx.inp.key_down = {}
		case .WINDOW_EXPOSED,
		     .WINDOW_RESIZED,
		     .WINDOW_PIXEL_SIZE_CHANGED,
		     .WINDOW_METAL_VIEW_RESIZED,
		     .WINDOW_RESTORED,
		     .WINDOW_FOCUS_GAINED,
		     .WINDOW_DISPLAY_CHANGED,
		     .WINDOW_DISPLAY_SCALE_CHANGED:
			ctx.force_reconfigure = true
		case:
		}
		_idle_note_activity(&ctx.idle)
	}

	@(private)
	_sdl_dispatch_drop :: proc(event: ^sdl.Event) {
		state := _sdl_state_for_id(event.drop.windowID)
		if state == nil do return
		ctx := state.owner
		#partial switch event.type {
		case .DROP_BEGIN:
			_drop_paths_clear_context(ctx)
			_drop_hover_stage_context(ctx, true)
		case .DROP_POSITION:
			_drop_hover_stage_context(ctx, true)
		case .DROP_FILE:
			if event.drop.data != nil && len(ctx.drop.paths) < MAX_DROPPED_FILES {
				path := string(event.drop.data)
				total := len(path)
				for stored in ctx.drop.paths do total += len(string(stored))
				if len(path) > 0 && total <= MAX_DROPPED_PATH_BYTES {
					append(&ctx.drop.paths, strings.clone_to_cstring(path))
				}
			}
		case .DROP_COMPLETE:
			if len(ctx.drop.paths) > 0 do _drop_complete_context(ctx)
			else do _drop_hover_stage_context(ctx, false)
		case .DROP_TEXT:
			_drop_hover_stage_context(ctx, false)
		case:
		}
		_idle_note_activity(&ctx.idle)
	}

	@(private)
	_sdl_dispatch :: proc(event: ^sdl.Event) {
		assert(event != nil, "_sdl_dispatch: nil event")
		#partial switch event.type {
		case .QUIT:
			for &state in g_sdl_windows do if state.window != nil do state.close_requested = true
		case .KEY_DOWN, .KEY_UP:
			_sdl_dispatch_key(event)
		case .TEXT_INPUT:
			_sdl_dispatch_text(event)
		case .MOUSE_MOTION:
			_sdl_dispatch_motion(event)
		case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
			_sdl_dispatch_button(event)
		case .MOUSE_WHEEL:
			state := _sdl_state_for_id(event.wheel.windowID)
			if state != nil {
				direction: f32 = -1 if event.wheel.direction == .FLIPPED else 1
				state.owner.inp.st_wheel += {event.wheel.x * direction, event.wheel.y * direction}
				_idle_note_activity(&state.owner.idle)
			}
		case .WINDOW_FIRST ..= .WINDOW_LAST:
			_sdl_dispatch_window(event)
		case .DROP_FILE, .DROP_TEXT, .DROP_BEGIN, .DROP_COMPLETE, .DROP_POSITION:
			_sdl_dispatch_drop(event)
		case .GAMEPAD_ADDED, .GAMEPAD_REMOVED, .GAMEPAD_REMAPPED:
			for &state in g_sdl_windows do if state.owner != nil do _idle_note_activity(&state.owner.idle)
		case:
		}
	}

	run_data :: proc(frame: Run_Data_Proc, userdata: rawptr) -> bool {
		if frame == nil do return false
		for !WindowShouldClose() do frame(userdata)
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
