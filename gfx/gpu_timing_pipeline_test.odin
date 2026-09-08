#+build !js
package gfx

import "core:testing"
import wg "vendor:wgpu"

when GPU_TIMING_DIAGNOSTICS {
	gpu_timing_pipeline_test_record :: proc(
		renderer: ^Renderer,
		slot: Blend_Slot,
		fragment: string,
		format: wg.TextureFormat,
		vertex: wg.VertexBufferLayout,
		primitive: wg.PrimitiveState,
		multisample: wg.MultisampleState,
	) {
		blend := _blend_for(renderer, slot)
		target := wg.ColorTargetState {
			format    = format,
			writeMask = wg.ColorWriteMaskFlags_All,
		}
		if _format_blendable(format) do target.blend = &blend
		_gpu_timing_batch_pipeline(
			renderer,
			slot,
			fragment,
			format,
			vertex,
			primitive,
			multisample,
			blend,
			target,
		)
	}
}

@(test)
gpu_timing_pipeline_retains_swapchain_descriptor :: proc(t: ^testing.T) {
	// The swapchain format is named outside the diagnostics block so the
	// default build still type-checks this file's wgpu import.
	swapchain_format := wg.TextureFormat.BGRA8Unorm
	testing.expect_value(t, swapchain_format, wg.TextureFormat.BGRA8Unorm)
	when GPU_TIMING_DIAGNOSTICS {
		ctx := new(Context)
		defer free(ctx)
		renderer := &ctx.rend
		renderer.cust_src = .SrcAlpha
		renderer.cust_dst = .One
		renderer.cust_op = .Subtract
		attrs := [4]wg.VertexAttribute {
			{format = .Float32x2, offset = 0, shaderLocation = 0},
			{format = .Float32x4, offset = u64(offset_of(Vertex, col)), shaderLocation = 1},
			{format = .Float32x2, offset = u64(offset_of(Vertex, uv)), shaderLocation = 2},
			{format = .Uint32, offset = u64(offset_of(Vertex, mode)), shaderLocation = 3},
		}
		vertex := wg.VertexBufferLayout {
			arrayStride    = size_of(Vertex),
			stepMode       = .Vertex,
			attributeCount = 4,
			attributes     = raw_data(attrs[:]),
		}
		primitive := wg.PrimitiveState {
			topology  = .TriangleList,
			frontFace = .CCW,
			cullMode  = .None,
		}
		multisample := wg.MultisampleState {
			count = 1,
			mask  = ~u32(0),
		}
		record := gpu_timing_pipeline_test_record
		for slot in Blend_Slot {
			record(renderer, slot, "fs_ui", swapchain_format, vertex, primitive, multisample)
			record(renderer, slot, "fs_image", swapchain_format, vertex, primitive, multisample)
		}
		record(renderer, .Alpha, "fs_ocean", swapchain_format, vertex, primitive, multisample)
		record(renderer, .Alpha, "fs_ui", .RGBA16Float, vertex, primitive, multisample)
		output: [GPU_TIMING_BATCH_PIPELINES]Gpu_Timing_Batch_Pipeline
		testing.expect_value(
			t,
			context_gpu_timing_batch_pipelines(ctx, output[:]),
			GPU_TIMING_BATCH_PIPELINES,
		)
		testing.expect_value(t, context_gpu_timing_batch_pipelines(ctx, output[:4]), 0)
		for entry, index in output {
			testing.expect(t, entry.known)
			testing.expect_value(t, entry.format, wg.TextureFormat.BGRA8Unorm)
			testing.expect_value(t, entry.vertex_stride, u64(36))
			testing.expect_value(t, entry.step_mode, wg.VertexStepMode.Vertex)
			testing.expect_value(t, entry.attributes[0].offset, u64(0))
			testing.expect_value(t, entry.attributes[1].offset, u64(8))
			testing.expect_value(t, entry.attributes[2].offset, u64(24))
			testing.expect_value(t, entry.attributes[3].offset, u64(32))
			testing.expect_value(t, entry.attributes[3].format, wg.VertexFormat.Uint32)
			testing.expect_value(t, entry.primitive.topology, wg.PrimitiveTopology.TriangleList)
			testing.expect_value(t, entry.multisample.count, u32(1))
			testing.expect(t, entry.blend_enabled)
			testing.expect_value(t, entry.write_mask, wg.ColorWriteMaskFlags_All)
			expected := _blend_for(renderer, Blend_Slot(index % len(Blend_Slot)))
			testing.expect_value(t, entry.blend, expected)
		}
		alpha := output[_gpu_timing_batch_pipeline_index(.Solid, .Alpha)]
		testing.expect_value(t, alpha.blend.color.srcFactor, wg.BlendFactor.One)
		testing.expect_value(t, alpha.blend.color.dstFactor, wg.BlendFactor.OneMinusSrcAlpha)
		additive := output[_gpu_timing_batch_pipeline_index(.Image, .Additive)]
		testing.expect_value(t, additive.blend.color.dstFactor, wg.BlendFactor.One)
		multiplied := output[_gpu_timing_batch_pipeline_index(.Solid, .Multiplied)]
		testing.expect_value(t, multiplied.blend.color.srcFactor, wg.BlendFactor.Dst)
		custom := output[_gpu_timing_batch_pipeline_index(.Image, .Custom)]
		testing.expect_value(t, custom.blend.color.srcFactor, wg.BlendFactor.SrcAlpha)
		testing.expect_value(t, custom.blend.color.operation, wg.BlendOperation.Subtract)
	}
}
