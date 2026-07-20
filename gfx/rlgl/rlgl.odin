// ingot:gfx/rlgl — shim over the low-level raylib rlgl API the consumer apps
// use. The 2D WebGPU batch renderer doesn't expose an immediate-mode GL layer,
// so the low-level vertex-array / framebuffer / matrix-stack calls (used only by
// openalloy's deferred galaxy renderer) are runtime-safe no-ops with matching
// signatures. DrawRenderBatchActive maps to a real batch flush. Lets `import
// rlgl "vendor:raylib/rlgl"` become `import rlgl "ingot:gfx/rlgl"` unchanged.
package rlgl

import gfx "ingot:gfx"

// --- GL enum constants (values match GL / raylib) --------------------------

FLOAT               :: 0x1406
ZERO                :: 0
ONE                 :: 1
SRC_COLOR           :: 0x0300
ONE_MINUS_SRC_COLOR :: 0x0301
FUNC_ADD            :: 0x8006

FramebufferAttachType :: enum i32 {
	COLOR_CHANNEL0 = 0,
	COLOR_CHANNEL1 = 1,
	COLOR_CHANNEL2 = 2,
	COLOR_CHANNEL3 = 3,
	COLOR_CHANNEL4 = 4,
	COLOR_CHANNEL5 = 5,
	COLOR_CHANNEL6 = 6,
	COLOR_CHANNEL7 = 7,
	DEPTH = 100,
	STENCIL = 200,
}

FramebufferAttachTextureType :: enum i32 {
	CUBEMAP_POSITIVE_X = 0,
	CUBEMAP_NEGATIVE_X = 1,
	CUBEMAP_POSITIVE_Y = 2,
	CUBEMAP_NEGATIVE_Y = 3,
	CUBEMAP_POSITIVE_Z = 4,
	CUBEMAP_NEGATIVE_Z = 5,
	TEXTURE2D = 100,
	RENDERBUFFER = 200,
}

// --- batch / culling (real) ------------------------------------------------

DrawRenderBatchActive  :: proc() { gfx.FlushBatch() }
EnableBackfaceCulling  :: proc() {}
DisableBackfaceCulling :: proc() {}

// --- matrix stack (2D model translation) -----------------------------------

PushMatrix :: proc() { gfx.MatrixModePush() }
PopMatrix  :: proc() { gfx.MatrixModePop() }
Translatef :: proc(x, y, z: f32) { gfx.MatrixModeTranslate(x, y) }
GetMatrixProjection :: proc() -> gfx.Matrix { return gfx.GetProjectionMatrix() }

// --- depth / shader / clip -------------------------------------------------

EnableDepthMask  :: proc() { gfx.SetDepthMask(true) }
DisableDepthMask :: proc() { gfx.SetDepthMask(false) }
EnableShader     :: proc(id: u32) { gfx.RlEnableInstShader(id) }
DisableShader    :: proc() { gfx.RlDisableInstShader() }
SetClipPlanes    :: proc(near, far: f64) {}

// SetBlendFactors records custom blend factors for the Custom blend slot (used
// by the galaxy dust extinction pass). Forwards the GL enums to gfx which maps
// them to wgpu and rebuilds the Custom pipelines.
SetBlendFactors  :: proc(glSrcFactor, glDstFactor, glEquation: i32) {
	gfx.SetCustomBlend(gfx.BlendFactorRL(glSrcFactor), gfx.BlendFactorRL(glDstFactor), gfx.BlendOpRL(glEquation))
}

// --- vertex arrays / buffers (deferred: no-op) -----------------------------

LoadVertexArray    :: proc() -> u32 { return gfx.RlLoadVertexArray() }
EnableVertexArray  :: proc(vaoId: u32) -> bool { return gfx.RlEnableVertexArray(vaoId) }
DisableVertexArray :: proc() { gfx.RlDisableVertexArray() }
UnloadVertexArray  :: proc(vaoId: u32) { gfx.RlUnloadVertexArray(vaoId) }
LoadVertexBuffer   :: proc(buffer: rawptr, size: i32, is_dynamic: bool) -> u32 { return gfx.RlLoadVertexBuffer(buffer, size, is_dynamic) }
UpdateVertexBuffer :: proc(bufferId: u32, data: rawptr, dataSize: i32, offset: i32) { gfx.RlUpdateVertexBuffer(bufferId, data, dataSize, offset) }
UnloadVertexBuffer :: proc(vboId: u32) { gfx.RlUnloadVertexBuffer(vboId) }
EnableVertexAttribute     :: proc(index: u32) { gfx.RlEnableVertexAttribute(index) }
SetVertexAttribute        :: proc(index: u32, compSize: i32, type: i32, normalized: bool, stride: i32, offset: i32) { gfx.RlSetVertexAttribute(index, compSize, type, normalized, stride, offset) }
SetVertexAttributeDivisor :: proc(index: u32, divisor: i32) { gfx.RlSetVertexAttributeDivisor(index, divisor) }
DrawVertexArrayInstanced         :: proc(offset, count, instances: i32) { gfx.RlDrawVertexArrayInstanced(offset, count, instances) }
DrawVertexArrayElementsInstanced :: proc(offset, count: i32, buffer: rawptr, instances: i32) { gfx.RlDrawVertexArrayElementsInstanced(offset, count, buffer, instances) }

// --- framebuffers / textures -----------------------------------------------
// The galaxy builds HDR render targets from these raw calls. LoadFramebuffer
// returns an opaque non-zero id; the real colour/depth attachments are created
// by LoadTexture/LoadTextureDepth (backed by gfx render-target textures) and
// carried on the RenderTexture2D, so Attach/Complete are bookkeeping only.

@(private) _fbo_counter: u32 = 0

LoadFramebuffer    :: proc() -> u32 { _fbo_counter += 1; return _fbo_counter }
EnableFramebuffer  :: proc(id: u32) {}
DisableFramebuffer :: proc() {}
FramebufferAttach  :: proc(fboId, texId: u32, attachType, texType, mipLevel: i32) {}
FramebufferComplete :: proc(id: u32) -> bool { return id != 0 }
LoadTexture      :: proc(data: rawptr, width, height, format, mipmapCount: i32) -> u32 {
	return gfx.RlLoadColorTexture(width, height, gfx.PixelFormat(format))
}
LoadTextureDepth :: proc(width, height: i32, useRenderBuffer: bool) -> u32 {
	return gfx.RlLoadDepthTexture(width, height)
}
UnloadTexture    :: proc(id: u32) { gfx.RlUnloadTextureId(id) }
