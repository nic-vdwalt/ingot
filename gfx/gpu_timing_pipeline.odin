package gfx

import wg "vendor:wgpu"

Gpu_Timing_Batch_Pipeline :: struct {
	known: bool,
	format: wg.TextureFormat,
	vertex_stride: u64,
	attributes: [4]wg.VertexAttribute,
	step_mode: wg.VertexStepMode,
	primitive: wg.PrimitiveState,
	multisample: wg.MultisampleState,
	blend: wg.BlendState,
	blend_enabled: bool,
	write_mask: wg.ColorWriteMask,
}

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
		} else if fragment != "fs_ui" {
			return
		}
		index := int(slot) + int(kind) * 4
		entry := &renderer.diagnostic_pipelines[index]
		entry^ = {
			known = true,
			format = format,
			vertex_stride = vertex.arrayStride,
			step_mode = vertex.stepMode,
			primitive = primitive,
			multisample = multisample,
			blend = blend,
			blend_enabled = target.blend != nil,
			write_mask = target.writeMask,
		}
		copy(entry.attributes[:], vertex.attributes[:4])
	}
}
