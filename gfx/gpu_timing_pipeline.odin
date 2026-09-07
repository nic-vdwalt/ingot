package gfx

import wg "vendor:wgpu"

// GPU_TIMING_BATCH_PIPELINES is Pipe_Kind × Blend_Slot: every batch pipeline
// the swapchain-format set can select for a window draw. Indexed by
// _gpu_timing_batch_pipeline_index so the export order is stable.
GPU_TIMING_BATCH_PIPELINES :: 8

// GPU_TIMING_BATCH_PIPELINE_SLOTS sizes the Renderer storage: zero when the
// diagnostics are compiled out so production builds carry no descriptor copy.
GPU_TIMING_BATCH_PIPELINE_SLOTS :: GPU_TIMING_BATCH_PIPELINES when GPU_TIMING_DIAGNOSTICS else 0

// Gpu_Timing_Batch_Pipeline retains the descriptor a batch pipeline was
// created from, so a replay can rebuild the exact pipeline instead of
// guessing the vertex layout, blend or write mask from the source tree.
// Only the first format recorded per (kind, slot) is kept: renderer_init
// builds the swapchain set before any alt-format set exists, so the retained
// descriptor is the one a window draw selects.
Gpu_Timing_Batch_Pipeline :: struct {
	known:         bool,
	format:        wg.TextureFormat,
	vertex_stride: u64,
	attributes:    [4]wg.VertexAttribute,
	step_mode:     wg.VertexStepMode,
	primitive:     wg.PrimitiveState,
	multisample:   wg.MultisampleState,
	blend:         wg.BlendState,
	blend_enabled: bool,
	write_mask:    wg.ColorWriteMaskFlags,
}

// _gpu_timing_batch_pipeline_index maps (kind, slot) to a stable export slot.
_gpu_timing_batch_pipeline_index :: proc(kind: Pipe_Kind, slot: Blend_Slot) -> int {
	index := int(slot) + int(kind) * len(Blend_Slot)
	assert(index >= 0 && index < GPU_TIMING_BATCH_PIPELINES)
	return index
}

// _gpu_timing_batch_pipeline records the descriptor _make_pipe is about to
// hand to the device. Fragment entry points outside the batch shader are not
// batch pipelines and are ignored. Rebuilds at the retained format (Custom
// blend changes) replace the entry; other formats never displace it.
_gpu_timing_batch_pipeline :: proc(
	renderer: ^Renderer,
	slot: Blend_Slot,
	fragment: string,
	format: wg.TextureFormat,
	vertex: wg.VertexBufferLayout,
	primitive: wg.PrimitiveState,
	multisample: wg.MultisampleState,
	blend: wg.BlendState,
	target: wg.ColorTargetState,
) {
	assert(renderer != nil)
	assert(vertex.attributeCount == 4)
	assert(vertex.attributes != nil)
	when GPU_TIMING_DIAGNOSTICS {
		kind: Pipe_Kind
		if fragment == "fs_image" {
			kind = .Image
		} else if fragment == "fs_ui" {
			kind = .Solid
		} else {
			return
		}
		index := _gpu_timing_batch_pipeline_index(kind, slot)
		assert(index < GPU_TIMING_BATCH_PIPELINES)
		entry := &renderer.diagnostic_pipelines[index]
		if entry.known && entry.format != format do return
		entry^ = {
			known         = true,
			format        = format,
			vertex_stride = vertex.arrayStride,
			step_mode     = vertex.stepMode,
			primitive     = primitive,
			multisample   = multisample,
			blend         = blend,
			blend_enabled = target.blend != nil,
			write_mask    = target.writeMask,
		}
		copy(entry.attributes[:], vertex.attributes[:4])
	}
}

// context_gpu_timing_batch_pipelines copies the retained batch pipeline
// descriptors out in export order. Returns the number written, which is
// GPU_TIMING_BATCH_PIPELINES when diagnostics are compiled in and the output
// has room, and 0 otherwise.
context_gpu_timing_batch_pipelines :: proc(
	ctx: ^Context,
	output: []Gpu_Timing_Batch_Pipeline,
) -> int {
	assert(ctx != nil)
	when GPU_TIMING_DIAGNOSTICS {
		if len(output) < GPU_TIMING_BATCH_PIPELINES do return 0
		copy(output[:GPU_TIMING_BATCH_PIPELINES], ctx.rend.diagnostic_pipelines[:])
		return GPU_TIMING_BATCH_PIPELINES
	} else {
		return 0
	}
}
