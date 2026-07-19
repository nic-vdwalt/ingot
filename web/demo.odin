// ingot web demo — WebGPU in the browser via Odin's vendor:wgpu JS backend
// (ODIN_OS == .JS). Mirrors the native spike: canvas surface, a solid-color
// pipeline, and a cleared frame with a batched rectangle, driven by
// requestAnimationFrame from the HTML shell. This is the "dividend" of building
// ingot on WebGPU — the same wgpu renderer code path targets the browser.
//
// Build:  bash build_web.sh   (see that script)
// Serve:  any static server over the web/ dir, open index.html in a WebGPU
//         browser (Chrome/Edge 113+, Safari 18+).
package web

import "base:runtime"
import wgpu "vendor:wgpu"

Vertex :: struct {
	pos: [2]f32,
	col: [4]f32,
}

State :: struct {
	ctx:      runtime.Context,
	instance: wgpu.Instance,
	surface:  wgpu.Surface,
	adapter:  wgpu.Adapter,
	device:   wgpu.Device,
	queue:    wgpu.Queue,
	config:   wgpu.SurfaceConfiguration,
	pipeline: wgpu.RenderPipeline,
	ready:    bool,
	width:    u32,
	height:   u32,
	t:        f32,
}

s: State

SHADER := `
struct VSOut { @builtin(position) pos: vec4<f32>, @location(0) col: vec4<f32> };
@vertex
fn vs_main(@location(0) pos: vec2<f32>, @location(1) col: vec4<f32>) -> VSOut {
	var o: VSOut;
	o.pos = vec4<f32>(pos, 0.0, 1.0);
	o.col = col;
	return o;
}
@fragment
fn fs_main(in: VSOut) -> @location(0) vec4<f32> { return in.col; }
`

main :: proc() {
	s.ctx = context
	s.width = 1280
	s.height = 720

	s.instance = wgpu.CreateInstance()
	s.surface = wgpu.InstanceCreateSurface(s.instance, &wgpu.SurfaceDescriptor{
		nextInChain = &wgpu.SurfaceSourceCanvasHTMLSelector{
			chain = {sType = .SurfaceSourceCanvasHTMLSelector},
			selector = "#ingot-canvas",
		},
	})

	// async, callback-chained (the browser event loop resolves these)
	wgpu.InstanceRequestAdapter(s.instance, &{compatibleSurface = s.surface}, {
		callback = on_adapter,
	})
}

on_adapter :: proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, msg: wgpu.StringView, u1, u2: rawptr) {
	context = s.ctx
	s.adapter = adapter
	wgpu.AdapterRequestDevice(s.adapter, nil, {callback = on_device})
}

on_device :: proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, msg: wgpu.StringView, u1, u2: rawptr) {
	context = s.ctx
	s.device = device
	s.queue = wgpu.DeviceGetQueue(s.device)

	caps, _ := wgpu.SurfaceGetCapabilities(s.surface, s.adapter)
	format := caps.formats[0]
	s.config = wgpu.SurfaceConfiguration{
		device = s.device, format = format, usage = {.RenderAttachment},
		width = s.width, height = s.height, alphaMode = .Opaque, presentMode = .Fifo,
	}
	wgpu.SurfaceConfigure(s.surface, &s.config)

	shader := wgpu.DeviceCreateShaderModule(s.device, &{
		nextInChain = &wgpu.ShaderSourceWGSL{chain = {sType = .ShaderSourceWGSL}, code = SHADER},
	})
	attrs := [2]wgpu.VertexAttribute{
		{format = .Float32x2, offset = 0, shaderLocation = 0},
		{format = .Float32x4, offset = u64(offset_of(Vertex, col)), shaderLocation = 1},
	}
	vbl := wgpu.VertexBufferLayout{arrayStride = size_of(Vertex), stepMode = .Vertex, attributeCount = 2, attributes = raw_data(attrs[:])}
	target := wgpu.ColorTargetState{format = format, writeMask = wgpu.ColorWriteMaskFlags_All}
	s.pipeline = wgpu.DeviceCreateRenderPipeline(s.device, &{
		vertex = {module = shader, entryPoint = "vs_main", bufferCount = 1, buffers = &vbl},
		primitive = {topology = .TriangleList, cullMode = .None},
		multisample = {count = 1, mask = ~u32(0)},
		fragment = &wgpu.FragmentState{module = shader, entryPoint = "fs_main", targetCount = 1, targets = &target},
	})
	s.ready = true
}

// step is exported and called each frame by the Odin JS runtime (odin.js)
// via requestAnimationFrame; returning true keeps the loop running.
@(export)
step :: proc(dt: f32) -> bool {
	if !s.ready do return true
	s.t += dt

	st := wgpu.SurfaceGetCurrentTexture(s.surface)
	if st.status != .SuccessOptimal && st.status != .SuccessSuboptimal do return true
	view := wgpu.TextureCreateView(st.texture, nil)
	defer wgpu.TextureViewRelease(view)

	enc := wgpu.DeviceCreateCommandEncoder(s.device, nil)
	pass := wgpu.CommandEncoderBeginRenderPass(enc, &{
		colorAttachmentCount = 1,
		colorAttachments = &wgpu.RenderPassColorAttachment{
			view = view, depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
			loadOp = .Clear, storeOp = .Store,
			clearValue = {30.0 / 255.0, 30.0 / 255.0, 30.0 / 255.0, 1.0},
		},
	})

	// a centered rectangle in NDC, gently pulsing
	h := 0.3 + 0.1 * (0.5 + 0.5 * sin_poly(s.t))
	col := [4]f32{0.24, 0.39, 1.0, 1.0}
	verts := [6]Vertex{
		{{-0.5, -h}, col}, {{-0.5, h}, col}, {{0.5, -h}, col},
		{{0.5, -h}, col}, {{-0.5, h}, col}, {{0.5, h}, col},
	}
	vbuf := wgpu.DeviceCreateBufferWithData(s.device, &{usage = {.Vertex}}, verts[:])
	defer wgpu.BufferRelease(vbuf)

	wgpu.RenderPassEncoderSetPipeline(pass, s.pipeline)
	wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, vbuf, 0, size_of(verts))
	wgpu.RenderPassEncoderDraw(pass, 6, 1, 0, 0)
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)

	cmd := wgpu.CommandEncoderFinish(enc, nil)
	wgpu.QueueSubmit(s.queue, {cmd})
	wgpu.CommandBufferRelease(cmd)
	wgpu.CommandEncoderRelease(enc)
	wgpu.SurfacePresent(s.surface)
	return true
}

@(private)
_sin :: proc "contextless" (x: f32) -> f32 {
	return sin_poly(x)
}

// minimal periodic sine (good enough for a pulsing demo) to avoid pulling
// core:math on the wasm target
@(private)
sin_poly :: proc "contextless" (x: f32) -> f32 {
	PI :: f32(3.14159265)
	xx := x
	for xx > PI do xx -= 2 * PI
	for xx < -PI do xx += 2 * PI
	abs_xx := xx < 0 ? -xx : xx
	return 4.0 / PI * xx - 4.0 / (PI * PI) * xx * abs_xx
}
