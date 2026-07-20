// ingot:gfx — window + WebGPU context lifecycle and the raylib-named entry
// points apps call (InitWindow/BeginDrawing/EndDrawing/ClearBackground/...).
// All mutable package state lives in the single `g` global so every gfx file
// (batch, shapes, text, texture, input) shares one context.
package gfx

import "base:runtime"
import "core:fmt"
import "core:time"
import "vendor:glfw"
import wg "vendor:wgpu"
import wgglue "vendor:wgpu/glfwglue"

KEY_COUNT :: 349 // KB_MENU (348) + 1

Frame_State :: struct {
	surf_tex:    wg.SurfaceTexture,
	view:        wg.TextureView,
	encoder:     wg.CommandEncoder,
	pass:        wg.RenderPassEncoder,
	clear_color: Color,
	pass_begun:  bool,
	has_frame:   bool,

	// Render-target redirection (Phase 2): when rt != 0 the batch records into
	// rt_pass (targeting an offscreen texture) on its own command encoder,
	// submitted at EndTextureMode, instead of the swapchain pass.
	rt:            u32,
	rt_encoder:    wg.CommandEncoder,
	rt_pass:       wg.RenderPassEncoder,
	rt_pass_begun: bool,
	rt_clear:      Color,
	rt_w, rt_h:    i32,
	rt_depth:      bool,          // RT pass carries a depth attachment (3D)
	// 3D mode (Phase 4): a depth-enabled pass replaces the current 2D pass.
	depth_view:    wg.TextureView,
	mode3d:        bool,
}

Context :: struct {
	win:      glfw.WindowHandle,
	instance: wg.Instance,
	surface:  wg.Surface,
	adapter:  wg.Adapter,
	device:   wg.Device,
	queue:    wg.Queue,
	format:   wg.TextureFormat,
	config:   wg.SurfaceConfiguration,

	config_flags: ConfigFlags,

	// logical (point) size — what GetScreenWidth/Height and the ortho
	// projection use; physical framebuffer may be larger under HiDPI.
	width, height:       i32,
	fb_width, fb_height: i32,
	dpi:                 f32,

	frame: Frame_State,

	// timing
	start_time:  time.Time,
	last_time:   f64,
	frame_time:  f32,
	target_fps:  i32,

	// renderer (batch.odin)
	rend: Renderer,

	// input (input.odin)
	inp: Input,

	initialized: bool,
}

@(private) g: Context

// --- async adapter/device request helpers ----------------------------------

@(private) Adapter_Res :: struct { adapter: wg.Adapter, done: bool }
@(private) Device_Res  :: struct { device:  wg.Device,  done: bool }

@(private)
_on_adapter :: proc "c" (status: wg.RequestAdapterStatus, adapter: wg.Adapter, msg: wg.StringView, u1, u2: rawptr) {
	r := (^Adapter_Res)(u1)
	r.adapter = adapter
	r.done = true
}

@(private)
_on_device :: proc "c" (status: wg.RequestDeviceStatus, device: wg.Device, msg: wg.StringView, u1, u2: rawptr) {
	if status != .Success {
		context = runtime.default_context()
		fmt.eprintfln("gfx: device request failed (status=%v): %s", status, string(msg))
	}
	r := (^Device_Res)(u1)
	r.device = device
	r.done = true
}

// Uncaptured GPU errors (e.g. an invalid pipeline/vertex layout) would
// otherwise reach wgpu-native's default handler, which panics and aborts the
// whole process with no message. Logging them here keeps the app alive and
// surfaces a diagnosable error instead of a bare SIGABRT.
@(private)
_on_uncaptured_error :: proc "c" (device: ^wg.Device, type: wg.ErrorType, message: wg.StringView, u1, u2: rawptr) {
	context = runtime.default_context()
	fmt.eprintfln("gfx: wgpu uncaptured error (%v): %s", type, string(message))
}

// --- window lifecycle ------------------------------------------------------

// SetConfigFlags stashes flags to apply at InitWindow (raylib order).
SetConfigFlags :: proc(flags: ConfigFlags) {
	g.config_flags = flags
}

InitWindow :: proc(width, height: i32, title: cstring) {
	if !glfw.Init() {
		fmt.eprintln("gfx: glfw init failed")
		return
	}

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, .WINDOW_RESIZABLE in g.config_flags ? 1 : 0)
	if .WINDOW_TRANSPARENT in g.config_flags {
		glfw.WindowHint(glfw.TRANSPARENT_FRAMEBUFFER, 1)
	}
	if .WINDOW_UNDECORATED in g.config_flags {
		glfw.WindowHint(glfw.DECORATED, 0)
	}

	g.win = glfw.CreateWindow(width, height, title, nil, nil)
	if g.win == nil {
		fmt.eprintln("gfx: window creation failed")
		return
	}

	g.instance = wg.CreateInstance()
	g.surface = wgglue.GetSurface(g.instance, g.win)

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

	caps, _ := wg.SurfaceGetCapabilities(g.surface, g.adapter)
	// Prefer a non-sRGB (linear UNORM) surface. raylib writes 8-bit sRGB color
	// values straight to a UNORM framebuffer with no gamma applied; an sRGB
	// surface re-encodes them linear->sRGB on output, washing the frame out
	// (too bright). Match raylib by choosing the *Unorm format when offered.
	g.format = caps.formats[0]
	for i in 0 ..< int(caps.formatCount) {
		f := caps.formats[i]
		if f == .BGRA8Unorm || f == .RGBA8Unorm {
			g.format = f
			break
		}
	}

	g.width, g.height = width, height
	fbw, fbh := glfw.GetFramebufferSize(g.win)
	g.fb_width, g.fb_height = fbw, fbh
	sx, _ := glfw.GetWindowContentScale(g.win)
	g.dpi = sx

	alpha: wg.CompositeAlphaMode = .Opaque
	if .WINDOW_TRANSPARENT in g.config_flags {
		// pick a surface-supported non-opaque mode for the transparent backdrop
		want := [?]wg.CompositeAlphaMode{.Premultiplied, .Unpremultiplied, .Inherit, .Auto}
		outer: for w in want {
			for i in 0 ..< int(caps.alphaModeCount) {
				if caps.alphaModes[i] == w {
					alpha = w
					break outer
				}
			}
		}
	}
	g.config = wg.SurfaceConfiguration{
		device      = g.device,
		format      = g.format,
		usage       = {.RenderAttachment},
		width       = u32(fbw),
		height      = u32(fbh),
		alphaMode   = alpha,
		presentMode = .Fifo,
	}
	wg.SurfaceConfigure(g.surface, &g.config)

	g.start_time = time.now()
	g.last_time = _now()
	g.target_fps = 0

	renderer_init(&g.rend)
	input_init()
	_drop_init()

	g.initialized = true
}

CloseWindow :: proc() {
	if !g.initialized do return
	renderer_shutdown(&g.rend)
	if g.surface != nil do wg.SurfaceRelease(g.surface)
	if g.queue != nil do wg.QueueRelease(g.queue)
	if g.device != nil do wg.DeviceRelease(g.device)
	if g.adapter != nil do wg.AdapterRelease(g.adapter)
	if g.instance != nil do wg.InstanceRelease(g.instance)
	if g.win != nil do glfw.DestroyWindow(g.win)
	glfw.Terminate()
	g.initialized = false
}

WindowShouldClose :: proc() -> bool {
	if g.win == nil do return true
	return bool(glfw.WindowShouldClose(g.win))
}

// --- per-frame -------------------------------------------------------------

BeginDrawing :: proc() {
	_maybe_reconfigure()

	g.frame.surf_tex = wg.SurfaceGetCurrentTexture(g.surface)
	#partial switch g.frame.surf_tex.status {
	case .SuccessOptimal, .SuccessSuboptimal:
		// ok
	case:
		g.frame.has_frame = false
		return
	}
	g.frame.view = wg.TextureCreateView(g.frame.surf_tex.texture, nil)
	g.frame.encoder = wg.DeviceCreateCommandEncoder(g.device, nil)
	g.frame.clear_color = Color{0, 0, 0, 255}
	g.frame.pass_begun = false
	g.frame.has_frame = true
	renderer_frame_begin(&g.rend)
}

ClearBackground :: proc(c: Color) {
	// While a render target is bound but its pass hasn't begun yet, the clear
	// applies to the target (raylib: ClearBackground after BeginTextureMode
	// clears the target). Otherwise it sets the swapchain clear.
	if g.frame.rt != 0 && !g.frame.rt_pass_begun {
		g.frame.rt_clear = c
		return
	}
	g.frame.clear_color = c
}

// _ensure_pass lazily begins the frame render pass so ClearBackground (called
// after BeginDrawing in raylib order) can set the loadOp clear value first.
@(private)
_ensure_pass :: proc() {
	if !g.frame.has_frame || g.frame.pass_begun do return
	cc := g.frame.clear_color
	g.frame.pass = wg.CommandEncoderBeginRenderPass(g.frame.encoder, &{
		colorAttachmentCount = 1,
		colorAttachments = &wg.RenderPassColorAttachment{
			view       = g.frame.view,
			depthSlice = wg.DEPTH_SLICE_UNDEFINED,
			loadOp     = .Clear,
			storeOp    = .Store,
			clearValue = {
				f64(cc.r) / 255.0,
				f64(cc.g) / 255.0,
				f64(cc.b) / 255.0,
				f64(cc.a) / 255.0,
			},
		},
	})
	g.frame.pass_begun = true
}

EndDrawing :: proc() {
	if g.frame.has_frame {
		_ensure_pass() // guarantee a clear even on empty frames
		renderer_flush(&g.rend, g.frame.pass)
		wg.RenderPassEncoderEnd(g.frame.pass)
		wg.RenderPassEncoderRelease(g.frame.pass)

		cmd := wg.CommandEncoderFinish(g.frame.encoder, nil)
		wg.QueueSubmit(g.queue, {cmd})
		wg.CommandBufferRelease(cmd)
		wg.CommandEncoderRelease(g.frame.encoder)
		wg.SurfacePresent(g.surface)
		wg.TextureViewRelease(g.frame.view)
		g.frame.has_frame = false
	} else {
		// frame was skipped (surface not ready): drop any accumulated draw
		// state so it can't flush into the next frame's pass with stale binds.
		clear(&g.rend.verts)
	}

	input_poll()
	_frame_timing()
}

@(private)
_maybe_reconfigure :: proc() {
	fbw, fbh := glfw.GetFramebufferSize(g.win)
	w, h := glfw.GetWindowSize(g.win)
	changed := fbw != g.fb_width || fbh != g.fb_height
	g.width, g.height = w, h
	if changed && fbw > 0 && fbh > 0 {
		g.fb_width, g.fb_height = fbw, fbh
		g.config.width = u32(fbw)
		g.config.height = u32(fbh)
		wg.SurfaceConfigure(g.surface, &g.config)
	}
	sx, _ := glfw.GetWindowContentScale(g.win)
	g.dpi = sx
}

@(private)
_frame_timing :: proc() {
	if g.target_fps > 0 {
		target := 1.0 / f64(g.target_fps)
		for {
			now := _now()
			elapsed := now - g.last_time
			if elapsed >= target do break
			remaining := target - elapsed
			if remaining > 0.002 {
				time.sleep(time.Duration((remaining - 0.001) * f64(time.Second)))
			}
		}
	}
	now := _now()
	g.frame_time = f32(now - g.last_time)
	g.last_time = now
}

@(private)
_now :: proc() -> f64 {
	return time.duration_seconds(time.since(g.start_time))
}

// --- window/screen queries (raylib-named) ----------------------------------

GetScreenWidth  :: proc() -> i32 { return g.width }
GetScreenHeight :: proc() -> i32 { return g.height }
GetWindowScaleDPI :: proc() -> Vector2 { return {g.dpi, g.dpi} }
GetRenderWidth  :: proc() -> i32 { return g.fb_width }
GetRenderHeight :: proc() -> i32 { return g.fb_height }

SetTargetFPS :: proc(fps: i32) { g.target_fps = fps }
GetFrameTime :: proc() -> f32 { return g.frame_time }
GetTime      :: proc() -> f64 { return _now() }
GetFPS       :: proc() -> i32 {
	if g.frame_time <= 0 do return 0
	return i32(1.0 / g.frame_time + 0.5)
}

SetWindowMinSize :: proc(w, h: i32) {
	if g.win != nil do glfw.SetWindowSizeLimits(g.win, w, h, glfw.DONT_CARE, glfw.DONT_CARE)
}
SetWindowSize :: proc(w, h: i32) {
	if g.win != nil do glfw.SetWindowSize(g.win, w, h)
}
SetExitKey :: proc(key: KeyboardKey) { g.inp.exit_key = key }

GetMonitorRefreshRate :: proc(monitor: i32) -> i32 {
	m := glfw.GetPrimaryMonitor()
	if m == nil do return 60
	mode := glfw.GetVideoMode(m)
	if mode == nil do return 60
	return mode.refresh_rate
}
GetCurrentMonitor :: proc() -> i32 { return 0 }

IsWindowFocused :: proc() -> bool {
	if g.win == nil do return false
	return glfw.GetWindowAttrib(g.win, glfw.FOCUSED) != 0
}

// FlushBatch forces pending 2D geometry to record into the current render pass
// (raylib rlDrawRenderBatchActive parity — used to order custom draws).
FlushBatch :: proc() {
	if g.frame.has_frame && _active_pass_begun() {
		renderer_flush(&g.rend, active_pass())
	}
}

// --- active pass routing (render targets) ----------------------------------
// When a render target is bound (BeginTextureMode) the batch records into the
// target's pass on its own command encoder; otherwise the swapchain pass.

// active_pass returns the render pass the batch renderer should record into.
@(private)
active_pass :: proc() -> wg.RenderPassEncoder {
	if g.frame.rt != 0 do return g.frame.rt_pass
	return g.frame.pass
}

// _cur_target_format returns the wgpu colour format of the pass draws currently
// target (the swapchain, or the bound render target). Custom-shader pipelines
// are format-specific, so they are built lazily per target format.
@(private)
_cur_target_format :: proc() -> wg.TextureFormat {
	if g.frame.rt != 0 {
		e := get_texture(g.frame.rt)
		if e != nil && e.wgformat != .Undefined do return e.wgformat
	}
	return g.format
}

// _active_pass_begun reports whether the pass active_pass() returns has begun.
@(private)
_active_pass_begun :: proc() -> bool {
	if !g.frame.has_frame do return false
	if g.frame.rt != 0 do return g.frame.rt_pass_begun
	return g.frame.pass_begun
}

// _ensure_active_pass lazily begins whichever pass is current: the render
// target's pass while one is bound, otherwise the swapchain pass.
@(private)
_ensure_active_pass :: proc() {
	if g.frame.rt != 0 {
		_ensure_rt_pass()
	} else {
		_ensure_pass()
	}
}
