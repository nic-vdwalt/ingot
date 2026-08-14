#+build js
// ingot:gfx - browser (WASM + WebGPU) platform backend.
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
import "core:fmt"
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
	@(link_name = "ingot_canvas_pixel_width")
	_js_pixel_width :: proc() -> i32 ---
	@(link_name = "ingot_canvas_pixel_height")
	_js_pixel_height :: proc() -> i32 ---
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
	@(link_name = "ingot_set_window_title")
	_js_set_window_title :: proc(title: cstring) ---
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
	_js_web_control_sync :: proc(id_lo, id_hi, role: i32, label_ptr: rawptr, label_len: i32, x, y, w, h, state: i32, value, lo, hi: f32, position_in_set, size_of_set: i32) -> i32 ---
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
@(private)
g_web_owner: ^Context
@(private)
g_web_owner_epoch: u64

@(private)
_web_owner_context :: proc "contextless" () -> ^Context {
	if g_web_owner == nil || g_web_owner.epoch != g_web_owner_epoch do return nil
	return g_web_owner
}

@(private)
_web_context_is_owner :: proc "contextless" (ctx: ^Context) -> bool {
	return ctx != nil && ctx == g_web_owner && ctx.epoch == g_web_owner_epoch
}

// --- window / surface / lifecycle ------------------------------------------

@(private)
Web_GPU_Request :: struct {
	owner: ^Context,
	epoch: u64,
}

@(private)
_web_request_live :: proc(request: ^Web_GPU_Request) -> bool {
	return(
		request != nil &&
		request.owner != nil &&
		request.epoch == request.owner.epoch &&
		request.owner.lifecycle == .Starting \
	)
}

@(private)
platform_create_window :: proc(
	ctx: ^Context,
	width, height: i32,
	title: cstring,
	flags: ConfigFlags,
) -> bool {
	assert(ctx != nil, "platform_create_window: nil context")
	assert(
		g_web_owner == nil || _web_context_is_owner(ctx),
		"platform_create_window: web canvas already owned",
	)
	g_web_ctx = context
	g_web_owner = ctx
	g_web_owner_epoch = ctx.epoch
	ctx.win = WEB_WIN_SENTINEL
	ctx.width, ctx.height = width, height
	ctx.fb_width, ctx.fb_height = width, height
	ctx.dpi = platform_content_scale(ctx)
	return true
}

@(private)
platform_create_surface :: proc(ctx: ^Context, instance: wg.Instance) -> wg.Surface {
	assert(ctx != nil, "platform_create_surface: nil context")
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
platform_start_gpu :: proc(ctx: ^Context) {
	assert(ctx != nil, "platform_start_gpu: nil context")
	request := new(Web_GPU_Request)
	request.owner = ctx
	request.epoch = ctx.epoch
	wg.InstanceRequestAdapter(
		ctx.instance,
		&{compatibleSurface = ctx.surface},
		{callback = _web_on_adapter, userdata1 = request},
	)
}

// _web_reason renders a browser-supplied failure message for logging. Safari
// forwards an empty rejection reason for some device failures, which used to
// print as "failed (Error):" with nothing after the colon - a dead end for
// anyone reading the on-page crash panel. Say so explicitly instead.
@(private)
_web_reason :: proc(msg: wg.StringView) -> string {
	text := string(msg)
	return text if len(text) > 0 else "(browser supplied no message)"
}

// _web_report_discarded names the one GPU startup failure that otherwise
// produces no output at all: the browser resolved the request successfully,
// but by the time it did the context was no longer starting, so the result is
// thrown away and the canvas stays black forever.
//
// Every other path here already logs, because a null adapter or a rejected
// device carries a status the caller can print. A discarded SUCCESS carries
// none, and the silence is what makes it expensive: the symptom is an empty
// canvas with a clean console, identical to an app that simply drew nothing.
// A ui_gfx.App host that closed the context during startup shipped in that
// state, so keep this loud even though the condition is legitimate during a
// deliberate close.
@(private)
_web_report_discarded :: proc(ctx: ^Context, what: string, request: ^Web_GPU_Request) {
	fmt.eprintfln(
		"gfx: discarding a resolved WebGPU %s: context is %v, not Starting " +
		"(request epoch %v, context epoch %v). The canvas will stay blank until " +
		"the context is initialised again.",
		what,
		ctx.lifecycle,
		request.epoch if request != nil else 0,
		ctx.epoch,
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
	ctx := request.owner if request != nil else nil
	if status != .Success || !_web_request_live(request) {
		if status != .Success {
			// Mobile browsers commonly resolve with a null adapter (blocklisted
			// GPU, compat-mode-only device). Without this line the canvas just
			// stays black forever - surface the reason instead.
			fmt.eprintfln("gfx: WebGPU adapter request failed (%v): %s", status, _web_reason(msg))
		} else {
			_web_report_discarded(ctx, "adapter", request)
		}
		if adapter != nil do wg.AdapterRelease(adapter)
		free(request)
		return
	}
	ctx.adapter = adapter
	device_request := new(Web_GPU_Request)
	device_request.owner = ctx
	device_request.epoch = request.epoch
	free(request)
	// Read the adapter's limits to size our pools (limits.odin). The device
	// itself is requested with default limits: see the hazard note in
	// limits.odin for why passing requiredLimits through the JS glue makes
	// Safari reject the device.
	ctx.budget = gpu_negotiate_budget(adapter)
	wg.AdapterRequestDevice(
		ctx.adapter,
		&wg.DeviceDescriptor{uncapturedErrorCallbackInfo = {callback = _on_uncaptured_error}},
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
	ctx := request.owner if request != nil else nil
	if status != .Success || !_web_request_live(request) {
		if status != .Success {
			fmt.eprintfln("gfx: WebGPU device request failed (%v): %s", status, _web_reason(msg))
		} else {
			_web_report_discarded(ctx, "device", request)
		}
		if device != nil do wg.DeviceRelease(device)
		free(request)
		return
	}
	free(request)
	ctx.device = device
	ctx.queue = wg.DeviceGetQueue(ctx.device)
	_gpu_finish(ctx)
}

// On web the adapter/device requests resolve on the browser event loop, not via
// a synchronous pump. No-op.
@(private)
platform_process_events :: proc(instance: wg.Instance) {}

@(private)
platform_framebuffer_size :: proc(ctx: ^Context) -> (i32, i32) {
	assert(ctx != nil, "platform_framebuffer_size: nil context")
	// The host validates and caps the backing store before assigning it. Reading
	// those integer dimensions here keeps SurfaceConfigure exactly in sync with
	// the canvas during mobile viewport transitions.
	w := _js_pixel_width()
	h := _js_pixel_height()
	if w <= 0 do w = max(ctx.fb_width, 1)
	if h <= 0 do h = max(ctx.fb_height, 1)
	return w, h
}

@(private)
platform_window_size :: proc(ctx: ^Context) -> (i32, i32) {
	assert(ctx != nil, "platform_window_size: nil context")
	// Logical (point) size = CSS pixels.
	w := i32(_js_css_width() + 0.5)
	h := i32(_js_css_height() + 0.5)
	if w <= 0 do w = ctx.width
	if h <= 0 do h = ctx.height
	return w, h
}

@(private)
platform_content_scale :: proc(ctx: ^Context) -> f32 {
	assert(ctx != nil, "platform_content_scale: nil context")
	dpr := _js_dpr()
	return dpr <= 0 ? 1 : f32(dpr)
}

@(private)
platform_should_close :: proc(ctx: ^Context) -> bool {
	return ctx == nil
}

@(private)
platform_poll_events :: proc(ctx: ^Context) {
	assert(ctx != nil, "platform_poll_events: nil context")
	_platform_drain_mouse_edges(ctx)
}

@(private)
platform_terminate :: proc(ctx: ^Context) {
	assert(ctx != nil, "platform_terminate: nil context")
	ctx.win = nil
	if _web_context_is_owner(ctx) {
		g_web_owner = nil
		g_web_owner_epoch = 0
		g_web_ctx = {}
	}
}

@(private)
platform_now :: proc() -> f64 {
	return _js_perf_now() / 1000.0
}

// The browser paces frames via requestAnimationFrame; a busy-sleep would block
// the event loop. No-op.
@(private)
platform_sleep :: proc(seconds: f64) {}

// Web never blocks for events - rAF paces the loop and the idle gate lives in
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
platform_set_window_min_size :: proc(ctx: ^Context, w, h: i32) {}

@(private)
platform_set_window_size :: proc(ctx: ^Context, w, h: i32) {}

// The page owns the document title, so this is the one window property a
// browser can honour. Position is genuinely unavailable: a canvas has no
// position on a monitor, and the page cannot move its own window.
@(private)
platform_set_window_title :: proc(ctx: ^Context, title: cstring) {
	assert(ctx != nil, "platform_set_window_title: nil context")
	_js_set_window_title(title)
}

@(private)
platform_set_window_position :: proc(ctx: ^Context, x, y: i32) {}

@(private)
platform_window_position :: proc(ctx: ^Context) -> (i32, i32) {
	return 0, 0
}

@(private)
platform_monitor_refresh_rate :: proc(ctx: ^Context) -> i32 {
	return 60
}

@(private)
platform_window_focused :: proc(ctx: ^Context) -> bool {
	return true
}

@(private)
platform_set_window_icon :: proc(ctx: ^Context, image: Image) {}

// --- input: DOM → shared Input struct --------------------------------------
//
// Browser input events fire asynchronously (between frames), whereas the native
// backend fills g.inp synchronously inside PollEvents (which input_poll calls
// after resetting frame-scoped state). To preserve identical timing, the JS
// event entry points (input_web.odin) stage into g.inp's staging buffer - the
// same one the GLFW callbacks use - and input_poll publishes it at the exact
// point native fills it, so edge (pressed/released) semantics match
// frame-for-frame.
//
// The globals below are NOT staged events. They are the browser's answer to
// the live platform queries GLFW services from the window (key held, cursor
// position, button held, pointer inside), plus the one edge pair the browser
// genuinely must stage: a touch tap replays press and release between two
// frames, so a level comparison at frame time would miss it entirely.

// _platform_drain_mouse_edges publishes the staged button edges. Called from
// platform_poll_events (i.e. from input_poll, right after it clears the
// per-frame edge state and before input_poll's own level comparison, which
// ORs against these - see the ODIN_OS == .JS branch there).
//
// Keys, characters and wheel are absent by design: those stage through
// g.inp and are published by _input_publish_staged, so no second copy of
// them can drift out of sync with the shared one.
@(private)
_platform_drain_mouse_edges :: proc(ctx: ^Context) {
	assert(ctx != nil, "_platform_drain_mouse_edges: nil context")
	for button in 0 ..< 8 {
		if ctx.inp.web_mb_pressed[button] do ctx.inp.mb_pressed[button] = true
		if ctx.inp.web_mb_released[button] do ctx.inp.mb_released[button] = true
		ctx.inp.web_mb_pressed[button] = false
		ctx.inp.web_mb_released[button] = false
	}
}

@(private)
platform_input_init :: proc(ctx: ^Context) {
	assert(ctx != nil, "platform_input_init: nil context")
	assert(_web_context_is_owner(ctx), "platform_input_init: context does not own web canvas")
	ctx.inp = {}
}

// IME proxy: a hidden DOM textarea (web/ingot_input.js) is positioned at the
// caret and focused so browser composition events (Pinyin, Japanese, dead
// keys) fire; the canvas alone never receives them.
@(private)
platform_set_text_input_rect :: proc(ctx: ^Context, x, y, w, h: i32) {
	assert(ctx != nil, "platform_set_text_input_rect: nil context")
	_js_ime_rect(x, y, w, h, 1)
}

@(private)
platform_text_input_deactivate :: proc(ctx: ^Context) {
	assert(ctx != nil, "platform_text_input_deactivate: nil context")
	_js_ime_rect(0, 0, 0, 0, 0)
}

@(private)
platform_web_input_frame_begin :: proc(ctx: ^Context) {
	assert(ctx != nil, "platform_web_input_frame_begin: nil context")
	_js_web_input_frame_begin()
}

@(private)
platform_web_input_frame_end :: proc(ctx: ^Context) {
	assert(ctx != nil, "platform_web_input_frame_end: nil context")
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
	position_in_set, size_of_set: i32,
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
		position_in_set,
		size_of_set,
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
platform_cursor_pos :: proc(ctx: ^Context) -> (f64, f64) {
	assert(ctx != nil, "platform_cursor_pos: nil context")
	return f64(ctx.inp.mouse.x), f64(ctx.inp.mouse.y)
}

// A page cannot warp the system cursor, so the browser keeps ownership and the
// next pointer event overwrites any buffered position SetMousePosition wrote.
@(private)
platform_set_cursor_pos :: proc(ctx: ^Context, x, y: f64) {
	assert(ctx != nil, "platform_set_cursor_pos: nil context")
	assert(x == x && y == y, "platform_set_cursor_pos: NaN coordinate")
}

@(private)
platform_mouse_button :: proc(ctx: ^Context, button: i32) -> bool {
	assert(ctx != nil, "platform_mouse_button: nil context")
	if button < 0 || button >= 8 do return false
	return ctx.inp.mb_down[button]
}

@(private)
platform_window_hovered :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "platform_window_hovered: nil context")
	return ctx.inp.cursor_on_screen
}

@(private)
platform_key_down :: proc(ctx: ^Context, key: i32) -> bool {
	assert(ctx != nil, "platform_key_down: nil context")
	if key < 0 || key >= KEY_COUNT do return false
	return ctx.inp.key_down[key]
}

@(private)
platform_set_mouse_cursor :: proc(ctx: ^Context, cursor: MouseCursor) {
	assert(ctx != nil, "platform_set_mouse_cursor: nil context")
	_js_set_cursor(i32(cursor))
}

// 11 indexes the "none" entry appended to CURSORS in web/ingot_web.js.
@(private)
platform_set_cursor_hidden :: proc(ctx: ^Context, hidden: bool) {
	assert(ctx != nil, "platform_set_cursor_hidden: nil context")
	_js_set_cursor(11 if hidden else i32(ctx.inp.cur_cursor))
}

@(private)
platform_get_clipboard :: proc(ctx: ^Context) -> string {
	assert(ctx != nil, "platform_get_clipboard: nil context")
	length := _js_clipboard_len()
	if length <= 0 do return ""
	buffer := make([]byte, length, context.temp_allocator)
	copied := _js_clipboard_copy(raw_data(buffer), length)
	if copied <= 0 do return ""
	return string(buffer[:copied])
}

@(private)
platform_set_clipboard :: proc(ctx: ^Context, text: cstring) {
	assert(ctx != nil, "platform_set_clipboard: nil context")
	_js_set_clipboard(text)
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
	_drop_state_reset_context(ctx)
	_js_drop_clear()
}

// platform_gamepad_poll snapshots each pad from the browser Gamepad API. The
// JS bridge reports W3C standard-mapping buttons (17, digital) and 6 axes
// (triggers already converted to the -1..1 GLFW convention); buttons are
// remapped to the raylib GamepadButton layout via _W3C_PAD_REMAP.
@(private)
platform_gamepad_poll :: proc(pads: ^[MAX_GAMEPADS]Gamepad_State, idle: ^Idle_State) {
	assert(pads != nil, "platform_gamepad_poll: nil pads")
	assert(idle != nil, "platform_gamepad_poll: nil idle state")
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
			_idle_note_activity(idle)
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
			_idle_note_activity(idle)
		}
	}
}

// --- public window procs (native equivalents live in window_native/extra) --

context_get_window_handle :: proc(ctx: ^Context) -> rawptr {return nil}
GetWindowHandle :: proc() -> rawptr {return context_get_window_handle(default_context())}
context_is_window_minimized :: proc(ctx: ^Context) -> bool {return false}
IsWindowMinimized :: proc() -> bool {return context_is_window_minimized(default_context())}
context_is_window_hidden :: proc(ctx: ^Context) -> bool {return false}
IsWindowHidden :: proc() -> bool {return context_is_window_hidden(default_context())}
context_is_window_fullscreen :: proc(ctx: ^Context) -> bool {
	return ctx != nil && _web_context_is_owner(ctx) && _js_is_fullscreen() != 0
}
IsWindowFullscreen :: proc() -> bool {return context_is_window_fullscreen(default_context())}
// ToggleFullscreen requests (or exits) the browser Fullscreen API on the canvas.
// Must be called from a user-gesture handler; the header's fullscreen button
// forwards a click here, satisfying that requirement.
context_toggle_fullscreen_impl :: proc(ctx: ^Context) {
	if ctx != nil && _web_context_is_owner(ctx) do _js_toggle_fullscreen()
}
ToggleFullscreen :: proc() {context_toggle_fullscreen_impl(default_context())}
context_restore_window :: proc(ctx: ^Context) {}
RestoreWindow :: proc() {context_restore_window(default_context())}
context_focus_window :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_focus_window: nil context")
	assert(_web_context_is_owner(ctx), "context_focus_window: context does not own web canvas")
}
FocusWindow :: proc() {context_focus_window(default_context())}

// --- drag & drop (web) ------------------------------------------------------
//
// JS (ingot_web.js attachDrop) stages dropped file names + bytes and calls the
// ingot_web_drop_notify export; the queries below pull the staged names into
// fixed buffers so FilePathList needs no allocation. Browsers never expose
// real paths - "paths" here are bare file names; use GetDroppedFileData for
// the contents.

context_is_file_dropped :: proc(ctx: ^Context) -> bool {
	return ctx != nil && ctx.drop.ready
}

IsFileDropped :: proc() -> bool {return context_is_file_dropped(default_context())}

context_load_dropped_files :: proc(ctx: ^Context) -> FilePathList {
	if ctx == nil do return {}
	count := clamp(_js_drop_count(), 0, MAX_DROPPED_FILES)
	assert(
		count >= 0 && count <= MAX_DROPPED_FILES,
		"context_load_dropped_files: count out of bounds",
	)
	for i in 0 ..< count {
		assert(i >= 0 && i < len(ctx.drop.web_names), "context_load_dropped_files: bad index")
		ctx.drop.web_names[i] = {}
		n := _js_drop_name_copy(i, raw_data(ctx.drop.web_names[i][:]), DROP_NAME_MAX - 1)
		assert(n < DROP_NAME_MAX, "context_load_dropped_files: name overflow")
		ctx.drop.web_cstrs[i] = cstring(raw_data(ctx.drop.web_names[i][:]))
	}
	return FilePathList {
		capacity = u32(count),
		count = u32(count),
		paths = raw_data(ctx.drop.web_cstrs[:]),
	}
}

LoadDroppedFiles :: proc() -> FilePathList {
	return context_load_dropped_files(default_context())
}

context_unload_dropped_files :: proc(ctx: ^Context, files: FilePathList) {
	if ctx == nil do return
	ctx.drop.ready = false
	ctx.drop.web_names = {}
	ctx.drop.web_cstrs = {}
	_js_drop_clear()
}

UnloadDroppedFiles :: proc(files: FilePathList) {
	context_unload_dropped_files(default_context(), files)
}

// GetDroppedFileData returns the contents of dropped file `index`, allocated
// from `allocator` (caller frees), or nil when the index is empty. This is
// the target-portable way to read a drop: on web there is no path to open.
context_get_dropped_file_data :: proc(
	ctx: ^Context,
	index: i32,
	allocator := context.allocator,
) -> []byte {
	if ctx == nil || index < 0 || index >= _js_drop_count() do return nil
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

GetDroppedFileData :: proc(index: i32, allocator := context.allocator) -> []byte {
	return context_get_dropped_file_data(default_context(), index, allocator)
}
