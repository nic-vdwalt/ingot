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
	@(link_name = "ingot_perf_now")
	_js_perf_now :: proc() -> f64 ---
	@(link_name = "ingot_canvas_css_width")
	_js_css_width :: proc() -> f64 ---
	@(link_name = "ingot_canvas_css_height")
	_js_css_height :: proc() -> f64 ---
	@(link_name = "ingot_device_pixel_ratio")
	_js_dpr :: proc() -> f64 ---
	@(link_name = "ingot_set_cursor")
	_js_set_cursor :: proc(cur: i32) ---
	@(link_name = "ingot_clipboard_len")
	_js_clipboard_len :: proc() -> i32 ---
	@(link_name = "ingot_clipboard_copy")
	_js_clipboard_copy :: proc(dst: rawptr, cap: i32) -> i32 ---
	@(link_name = "ingot_set_clipboard")
	_js_set_clipboard :: proc(text: cstring) ---
	@(link_name = "ingot_web_input_frame_begin")
	_js_web_input_frame_begin :: proc() ---
	@(link_name = "ingot_web_input_frame_end")
	_js_web_input_frame_end :: proc() ---
	@(link_name = "ingot_web_input_sync")
	_js_web_input_sync :: proc(form_ptr: rawptr, form_len: i32, field_ptr: rawptr, field_len: i32, name_ptr: rawptr, name_len: i32, placeholder_ptr: rawptr, placeholder_len: i32, value_ptr: rawptr, value_len: i32, x, y, w, h, input_type, autocomplete, active: i32) -> i32 ---
	@(link_name = "ingot_web_input_value_len")
	_js_web_input_value_len :: proc(field_ptr: rawptr, field_len: i32) -> i32 ---
	@(link_name = "ingot_web_input_value_copy")
	_js_web_input_value_copy :: proc(field_ptr: rawptr, field_len: i32, dst: rawptr, cap: i32) -> i32 ---
	@(link_name = "ingot_web_input_cursor")
	_js_web_input_cursor :: proc(field_ptr: rawptr, field_len: i32) -> i32 ---
	@(link_name = "ingot_web_submit_sync")
	_js_web_submit_sync :: proc(form_ptr: rawptr, form_len: i32, label_ptr: rawptr, label_len: i32, x, y, w, h, style, font_size, enabled: i32) -> i32 ---
	@(link_name = "ingot_web_control_sync")
	_js_web_control_sync :: proc(id_lo, id_hi, role: i32, label_ptr: rawptr, label_len: i32, x, y, w, h, state: i32, value, lo, hi: f32) -> i32 ---
	@(link_name = "ingot_web_control_value")
	_js_web_control_value :: proc(id_lo, id_hi: i32) -> f64 ---
	@(link_name = "ingot_is_fullscreen")
	_js_is_fullscreen :: proc() -> i32 ---
	@(link_name = "ingot_toggle_fullscreen")
	_js_toggle_fullscreen :: proc() ---
	@(link_name = "ingot_ime_rect")
	_js_ime_rect :: proc(x, y, w, h, active: i32) ---
	@(link_name = "ingot_gamepad_state")
	_js_gamepad_state :: proc(slot: i32, buttons: [^]u8, buttons_cap: i32, axes: [^]f32, axes_cap: i32, name: [^]u8, name_cap: i32) -> i32 ---
	@(link_name = "ingot_drop_count")
	_js_drop_count :: proc() -> i32 ---
	@(link_name = "ingot_drop_name_len")
	_js_drop_name_len :: proc(index: i32) -> i32 ---
	@(link_name = "ingot_drop_name_copy")
	_js_drop_name_copy :: proc(index: i32, dst: rawptr, cap: i32) -> i32 ---
	@(link_name = "ingot_drop_data_len")
	_js_drop_data_len :: proc(index: i32) -> i32 ---
	@(link_name = "ingot_drop_data_copy")
	_js_drop_data_copy :: proc(index: i32, dst: rawptr, cap: i32) -> i32 ---
	@(link_name = "ingot_drop_clear")
	_js_drop_clear :: proc() ---
}

// A non-nil sentinel so the shared `g.win == nil` guards treat the web target as
// "window present" (there is no OS window; the canvas plays that role).
@(private)
WEB_WIN_SENTINEL :: Window_Handle(uintptr(1))

// Captured Odin context for the "c" GPU callbacks (they run from the browser
// event loop, where Odin's implicit context isn't available). Set in
// platform_create_window, which runs under main's context.
@(private)
g_web_ctx: runtime.Context

// --- window / surface / lifecycle ------------------------------------------

@(private)
Web_GPU_Request :: struct {
	epoch: u64,
}

@(private)
_web_request_live :: proc(request: ^Web_GPU_Request) -> bool {
	return request != nil && request.epoch == g.epoch && g.lifecycle == .Starting
}

@(private)
platform_create_window :: proc(width, height: i32, title: cstring, flags: ConfigFlags) -> bool {
	g_web_ctx = context
	g.win = WEB_WIN_SENTINEL
	g.width, g.height = width, height
	g.fb_width, g.fb_height = width, height
	g.dpi = platform_content_scale()
	return true
}

@(private)
platform_create_surface :: proc(instance: wg.Instance) -> wg.Surface {
	return wg.InstanceCreateSurface(
		instance,
		&wg.SurfaceDescriptor {
			nextInChain = &wg.SurfaceSourceCanvasHTMLSelector {
				chain = {sType = .SurfaceSourceCanvasHTMLSelector},
				selector = "#ingot-canvas",
			},
		},
	)
}

// platform_start_gpu kicks off the async adapter→device request chain and
// returns immediately. The browser resolves the requests on its event loop; the
// device callback calls _gpu_finish, which flips g.initialized to true. The web
// frame loop skips drawing until then.
@(private)
platform_start_gpu :: proc() {
	request := new(Web_GPU_Request)
	request.epoch = g.epoch
	wg.InstanceRequestAdapter(
		g.instance,
		&{compatibleSurface = g.surface},
		{callback = _web_on_adapter, userdata1 = request},
	)
}

@(private)
_web_on_adapter :: proc "c" (
	status: wg.RequestAdapterStatus,
	adapter: wg.Adapter,
	msg: wg.StringView,
	u1, u2: rawptr,
) {
	context = g_web_ctx
	request := cast(^Web_GPU_Request)u1
	if status != .Success || !_web_request_live(request) {
		if adapter != nil do wg.AdapterRelease(adapter)
		free(request)
		return
	}
	g.adapter = adapter
	device_request := new(Web_GPU_Request)
	device_request.epoch = request.epoch
	free(request)
	wg.AdapterRequestDevice(
		g.adapter,
		nil,
		{callback = _web_on_device, userdata1 = device_request},
	)
}

@(private)
_web_on_device :: proc "c" (
	status: wg.RequestDeviceStatus,
	device: wg.Device,
	msg: wg.StringView,
	u1, u2: rawptr,
) {
	context = g_web_ctx
	request := cast(^Web_GPU_Request)u1
	if status != .Success || !_web_request_live(request) {
		if device != nil do wg.DeviceRelease(device)
		free(request)
		return
	}
	free(request)
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

// Web never blocks for events — rAF paces the loop and the idle gate lives in
// step() (loop_web.odin). No-ops keep the shared pump code target-neutral.
@(private)
platform_wait_events :: proc(timeout: f64) {}

@(private)
platform_wake :: proc "contextless" () {}

@(private)
platform_window_iconified :: proc() -> bool {
	return false
}

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

@(private)
st_pressed: [KEY_COUNT]bool
@(private)
st_released: [KEY_COUNT]bool
@(private)
st_repeat: [KEY_COUNT]bool
@(private)
st_held: [KEY_COUNT]bool // sticky held state for IsKeyDown
@(private)
st_keys: [CHAR_Q]KeyboardKey // ring of pressed keys (GetKeyPressed)
@(private)
st_key_h, st_key_t: int
@(private)
st_chars: [CHAR_Q]rune // ring of typed runes (GetCharPressed)
@(private)
st_char_h, st_char_t: int
@(private)
st_wheel: Vector2
@(private)
st_mouse: Vector2
@(private)
st_mb: [8]bool
@(private)
st_hovered: bool

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
		if st_pressed[i] {g.inp.pressed[i] = true}
		if st_released[i] {g.inp.released[i] = true}
		if st_repeat[i] {g.inp.repeat[i] = true}
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

// IME proxy: a hidden DOM textarea (web/ingot_input.js) is positioned at the
// caret and focused so browser composition events (Pinyin, Japanese, dead
// keys) fire; the canvas alone never receives them.
@(private)
platform_set_text_input_rect :: proc(x, y, w, h: i32) {
	_js_ime_rect(x, y, w, h, 1)
}

@(private)
platform_text_input_deactivate :: proc() {
	_js_ime_rect(0, 0, 0, 0, 0)
}

@(private)
platform_web_input_frame_begin :: proc() {
	_js_web_input_frame_begin()
}

@(private)
platform_web_input_frame_end :: proc() {
	_js_web_input_frame_end()
}

@(private)
web_string_data :: proc(value: string) -> rawptr {
	if len(value) == 0 do return nil
	bytes := transmute([]byte)value
	return raw_data(bytes)
}

@(private)
platform_sync_web_text_input :: proc(
	form_id, field_id, name, placeholder, value: string,
	x, y, w, h, input_type, autocomplete: i32,
	active: bool,
) -> Web_Input_Result {
	field_data := web_string_data(field_id)
	field_len := i32(len(field_id))
	flags := _js_web_input_sync(
		web_string_data(form_id),
		i32(len(form_id)),
		field_data,
		field_len,
		web_string_data(name),
		i32(len(name)),
		web_string_data(placeholder),
		i32(len(placeholder)),
		web_string_data(value),
		i32(len(value)),
		x,
		y,
		w,
		h,
		input_type,
		autocomplete,
		active ? 1 : 0,
	)
	result := Web_Input_Result {
		cursor  = int(_js_web_input_cursor(field_data, field_len)),
		changed = flags & 1 != 0,
		focused = flags & 2 != 0,
	}
	if result.changed {
		length := _js_web_input_value_len(field_data, field_len)
		if length > 0 {
			buffer := make([]byte, length, context.temp_allocator)
			copied := _js_web_input_value_copy(field_data, field_len, raw_data(buffer), length)
			if copied > 0 do result.value = string(buffer[:copied])
		}
	}
	return result
}

@(private)
platform_sync_web_control :: proc(
	role: i32,
	id: u64,
	label: string,
	x, y, w, h: i32,
	state: u8,
	value, lo, hi: f32,
) -> Web_Control_Result {
	// Node ids exceed JS's 2^53 safe-integer range (fallback ids pack the
	// role into bits 56+), so the id crosses as two i32 halves and keys a
	// string map on the JS side.
	id_lo := i32(u32(id & 0xFFFFFFFF))
	id_hi := i32(u32(id >> 32))
	flags := _js_web_control_sync(
		id_lo,
		id_hi,
		role,
		web_string_data(label),
		i32(len(label)),
		x,
		y,
		w,
		h,
		i32(state),
		value,
		lo,
		hi,
	)
	result := Web_Control_Result {
		activated = flags & 1 != 0,
		changed   = flags & 2 != 0,
	}
	if result.changed {
		result.value = f32(_js_web_control_value(id_lo, id_hi))
	}
	return result
}

@(private)
platform_sync_web_submit_button :: proc(
	form_id, label: string,
	x, y, w, h, style, font_size: i32,
	enabled: bool,
) -> bool {
	return(
		_js_web_submit_sync(
			web_string_data(form_id),
			i32(len(form_id)),
			web_string_data(label),
			i32(len(label)),
			x,
			y,
			w,
			h,
			style,
			font_size,
			enabled ? 1 : 0,
		) !=
		0 \
	)
}

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
	length := _js_clipboard_len()
	if length <= 0 do return ""
	buffer := make([]byte, length, context.temp_allocator)
	copied := _js_clipboard_copy(raw_data(buffer), length)
	if copied <= 0 do return ""
	return string(buffer[:copied])
}

@(private)
platform_set_clipboard :: proc(text: cstring) {
	_js_set_clipboard(text)
}

@(private)
platform_drop_init :: proc() {
	_drop_state_reset()
}

@(private)
platform_drop_prepare_events :: proc() {}

@(private)
platform_drop_finish_events :: proc() {}

@(private)
platform_drop_shutdown :: proc() {
	_drop_state_reset()
	_js_drop_clear()
}

// platform_gamepad_poll snapshots each pad from the browser Gamepad API. The
// JS bridge reports W3C standard-mapping buttons (17, digital) and 6 axes
// (triggers already converted to the -1..1 GLFW convention); buttons are
// remapped to the raylib GamepadButton layout via _W3C_PAD_REMAP.
@(private)
platform_gamepad_poll :: proc(pads: ^[MAX_GAMEPADS]Gamepad_State) {
	assert(pads != nil, "platform_gamepad_poll: nil pads")
	w3c_buttons: [17]u8
	for slot in 0 ..< MAX_GAMEPADS {
		pad := &pads[slot]
		w3c_buttons = {}
		name_len := _js_gamepad_state(
			i32(slot),
			raw_data(w3c_buttons[:]),
			i32(len(w3c_buttons)),
			raw_data(pad.axes[:]),
			i32(len(pad.axes)),
			raw_data(pad.name[:]),
			i32(len(pad.name)),
		)
		connected := name_len >= 0
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
		assert(name_len <= GAMEPAD_NAME_MAX, "platform_gamepad_poll: name overflow")
		pad.name_len = min(name_len, GAMEPAD_NAME_MAX)
		pad.buttons = {}
		for b in 0 ..< len(w3c_buttons) {
			if w3c_buttons[b] != 0 {
				pad.buttons[int(_W3C_PAD_REMAP[b])] = true
			}
		}
		if pad.buttons != pad.prev_buttons {
			_idle_note_activity(&g.idle)
		}
	}
}

// --- public window procs (native equivalents live in window_native/extra) --

GetWindowHandle :: proc() -> rawptr {return nil}
IsWindowMinimized :: proc() -> bool {return false}
IsWindowHidden :: proc() -> bool {return false}
IsWindowFullscreen :: proc() -> bool {return _js_is_fullscreen() != 0}
// ToggleFullscreen requests (or exits) the browser Fullscreen API on the canvas.
// Must be called from a user-gesture handler; the header's fullscreen button
// forwards a click here, satisfying that requirement.
ToggleFullscreen :: proc() {_js_toggle_fullscreen()}
RestoreWindow :: proc() {}

// --- drag & drop (web) ------------------------------------------------------
//
// JS (ingot_web.js attachDrop) stages dropped file names + bytes and calls the
// ingot_web_drop_notify export; the queries below pull the staged names into
// fixed buffers so FilePathList needs no allocation. Browsers never expose
// real paths — "paths" here are bare file names; use GetDroppedFileData for
// the contents.

@(private)
g_drop_names: [MAX_DROPPED_FILES][DROP_NAME_MAX]u8
@(private)
g_drop_cstrs: [MAX_DROPPED_FILES]cstring

IsFileDropped :: proc() -> bool {return g_drop_ready}

LoadDroppedFiles :: proc() -> FilePathList {
	count := clamp(_js_drop_count(), 0, MAX_DROPPED_FILES)
	assert(count >= 0 && count <= MAX_DROPPED_FILES, "LoadDroppedFiles: count out of bounds")
	for i in 0 ..< count {
		g_drop_names[i] = {}
		n := _js_drop_name_copy(i, raw_data(g_drop_names[i][:]), DROP_NAME_MAX - 1)
		assert(n < DROP_NAME_MAX, "LoadDroppedFiles: name overflow")
		g_drop_cstrs[i] = cstring(raw_data(g_drop_names[i][:]))
	}
	return FilePathList {
		capacity = u32(count),
		count = u32(count),
		paths = raw_data(g_drop_cstrs[:]),
	}
}

UnloadDroppedFiles :: proc(files: FilePathList) {
	g_drop_ready = false
	for i in 0 ..< MAX_DROPPED_FILES {
		g_drop_names[i] = {}
		g_drop_cstrs[i] = nil
	}
	_js_drop_clear()
}

// GetDroppedFileData returns the contents of dropped file `index`, allocated
// from `allocator` (caller frees), or nil when the index is empty. This is
// the target-portable way to read a drop: on web there is no path to open.
GetDroppedFileData :: proc(index: i32, allocator := context.allocator) -> []byte {
	if index < 0 || index >= _js_drop_count() do return nil
	length := _js_drop_data_len(index)
	assert(length >= 0, "GetDroppedFileData: negative length")
	if length <= 0 do return nil
	buffer := make([]byte, int(length), allocator)
	copied := _js_drop_data_copy(index, raw_data(buffer), length)
	if copied <= 0 {
		delete(buffer, allocator)
		return nil
	}
	return buffer[:copied]
}
