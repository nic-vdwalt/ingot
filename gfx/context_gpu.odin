// ingot:gfx - GPU-side helpers for a Context: standalone command lists,
// end-of-frame texture retirement, and the async adapter/device callbacks
// that complete WebGPU setup.
package gfx

import "base:runtime"
import "core:fmt"
import wg "vendor:wgpu"

Gpu_Command_List :: struct {
	owner:   ^Context,
	epoch:   u64,
	encoder: wg.CommandEncoder,
	timing:  Gpu_Timing_Token,
	active:  bool,
}

context_begin_gpu_commands_named :: proc(ctx: ^Context, name: string) -> (Gpu_Command_List, bool) {
	assert(ctx != nil, "context_begin_gpu_commands_named: nil context")
	if !ctx.initialized do return {}, false
	assert(ctx.lifecycle == .Ready, "context_begin_gpu_commands: context is not ready")
	assert(ctx.device != nil, "context_begin_gpu_commands: initialized context requires device")
	assert(!ctx.frame.has_frame, "context_begin_gpu_commands: frame is open")
	_gpu_timing_preframe_ensure(ctx)
	encoder := _gpu_timing_command_encoder(ctx, name)
	if encoder == nil do return {}, false
	return {
			owner = ctx,
			epoch = ctx.epoch,
			encoder = encoder,
			timing = _gpu_timing_encoder_begin(ctx, encoder, name),
			active = true,
		},
		true
}

context_begin_gpu_commands :: proc(ctx: ^Context) -> (Gpu_Command_List, bool) {
	return context_begin_gpu_commands_named(ctx, "gpu-commands")
}

context_submit_gpu_commands :: proc(commands: ^Gpu_Command_List) -> bool {
	assert(commands != nil, "context_submit_gpu_commands: nil commands")
	if !commands.active || commands.owner == nil do return false
	if commands.epoch != commands.owner.epoch do return false
	_gpu_timing_encoder_end(commands.owner, commands.encoder, commands.timing)
	command := wg.CommandEncoderFinish(commands.encoder, nil)
	if command == nil {
		when GPU_TIMING_DIAGNOSTICS {
			_gpu_timing_diagnostic_encoder_retire(
				&commands.owner.gpu_timing.diagnostics[0],
				commands.encoder,
			)
		}
		return false
	}
	when GPU_TIMING_DIAGNOSTICS {
		_gpu_timing_diagnostic_submit(&commands.owner.gpu_timing.diagnostics[0], commands.encoder)
	}
	wg.QueueSubmit(commands.owner.queue, {command})
	wg.CommandBufferRelease(command)
	wg.CommandEncoderRelease(commands.encoder)
	commands^ = {}
	return true
}

// Retired_Texture is one texture's GPU handles awaiting end-of-frame
// destruction. Views/samplers/binds are release-only; the texture itself is
// destroyed (delete-now semantics) once the frame's submit no longer
// references it.
Retired_Texture :: struct {
	bind:    wg.BindGroup,
	sampler: wg.Sampler,
	view:    wg.TextureView,
	tex:     wg.Texture,
}

// MAX_RETIRED_PER_FRAME bounds mid-frame texture retirements (Tiger Style:
// put a limit on everything). The true physical maximum is one retirement per
// live texture slot plus one per font atlas: nothing else can be destroyed in
// a single frame, so exceeding this bound means the same handle was retired
// twice. A tile-cache consumer legitimately recycles hundreds of textures per
// frame while the user flick-zooms, so the previous policy cap of 64 turned an
// ordinary workload into an abort.
MAX_RETIRED_PER_FRAME :: MAX_TEXTURES + MAX_ATLASES
#assert(MAX_RETIRED_PER_FRAME == 1280)

// _retire_texture destroys a texture's GPU handles, deferring to after this
// frame's queue submit while a frame is recording (wgpu validates that
// submitted command buffers reference no destroyed textures).
@(private)
_retire_texture :: proc(
	ctx: ^Context,
	bind: wg.BindGroup,
	sampler: wg.Sampler,
	view: wg.TextureView,
	tex: wg.Texture,
) {
	assert(ctx != nil, "_retire_texture: nil context")
	// Why assert: all-nil handles mean the entry was already destroyed - a
	// double-unload of the same font/texture.
	assert(
		bind != nil || sampler != nil || view != nil || tex != nil,
		"_retire_texture: all handles nil (double unload?)",
	)
	if ctx.frame.has_frame {
		// Why assert: the bound is the physical maximum (every texture slot
		// plus every atlas), so overflowing it means a handle was retired
		// twice rather than that the caller is simply busy.
		assert(
			len(ctx.resources.retire) < MAX_RETIRED_PER_FRAME,
			"_retire_texture: retire queue full (double unload?)",
		)
		append(&ctx.resources.retire, Retired_Texture{bind, sampler, view, tex})
		return
	}
	_destroy_retired(Retired_Texture{bind, sampler, view, tex})
}

@(private)
_destroy_retired :: proc(r: Retired_Texture) {
	if r.bind != nil do wg.BindGroupRelease(r.bind)
	if r.sampler != nil do wg.SamplerRelease(r.sampler)
	if r.view != nil do wg.TextureViewRelease(r.view)
	if r.tex != nil {
		wg.TextureDestroy(r.tex)
		wg.TextureRelease(r.tex)
	}
}

// _flush_retired destroys all mid-frame-retired textures. Call after
// QueueSubmit: from that point wgpu keeps the submitted work's resources
// alive internally, so destroy is safe.
@(private)
_flush_retired :: proc(ctx: ^Context) {
	assert(ctx != nil, "_flush_retired: nil context")
	// Why assert: flushing while a frame still records would recreate the
	// destroy-before-submit validation abort this queue exists to prevent.
	assert(!ctx.frame.has_frame, "_flush_retired: called while a frame is recording")
	for retired in ctx.resources.retire do _destroy_retired(retired)
	clear(&ctx.resources.retire)
}

// --- async adapter/device request helpers ----------------------------------

@(private)
Adapter_Res :: struct {
	adapter: wg.Adapter,
	status:  wg.RequestAdapterStatus,
	done:    bool,
}
@(private)
Device_Res :: struct {
	device: wg.Device,
	status: wg.RequestDeviceStatus,
	done:   bool,
}

@(private)
_on_adapter :: proc "c" (
	status: wg.RequestAdapterStatus,
	adapter: wg.Adapter,
	msg: wg.StringView,
	u1, u2: rawptr,
) {
	context = runtime.default_context()
	r := (^Adapter_Res)(u1)
	assert(r != nil, "_on_adapter: nil result")
	r.adapter = adapter
	r.status = status
	r.done = true
}

@(private)
_on_device :: proc "c" (
	status: wg.RequestDeviceStatus,
	device: wg.Device,
	msg: wg.StringView,
	u1, u2: rawptr,
) {
	context = runtime.default_context()
	if status != .Success {
		fmt.eprintfln("gfx: device request failed (status=%v): %s", status, string(msg))
	}
	r := (^Device_Res)(u1)
	assert(r != nil, "_on_device: nil result")
	r.device = device
	r.status = status
	r.done = true
}

// INGOT_GPU_STRICT turns any uncaptured wgpu validation message into an
// immediate abort. Fuzz harnesses build with it (fuzz/run.sh gfx-frame) so
// GPU misuse that would otherwise be logged and survived fails the run -
// partial compensation for wgpu-native being a prebuilt release library
// outside AddressSanitizer's reach.
INGOT_GPU_STRICT :: #config(INGOT_GPU_STRICT, false)

// Uncaptured GPU errors (e.g. an invalid pipeline/vertex layout) would
// otherwise reach wgpu-native's default handler, which panics and aborts the
// whole process with no message. Logging them here keeps the app alive and
// surfaces a diagnosable error instead of a bare SIGABRT. Under
// INGOT_GPU_STRICT the error is fatal by design.
@(private)
_on_uncaptured_error :: proc "c" (
	device: ^wg.Device,
	type: wg.ErrorType,
	message: wg.StringView,
	u1, u2: rawptr,
) {
	context = runtime.default_context()
	_ = device
	_ = u1
	_ = u2
	fmt.eprintfln("gfx: wgpu uncaptured error (%v): %s", type, string(message))
	when INGOT_GPU_STRICT {
		panic("INGOT_GPU_STRICT: aborting on wgpu validation error")
	}
}
