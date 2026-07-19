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

// --- matrix stack (deferred: no-op) ----------------------------------------

PushMatrix :: proc() {}
PopMatrix  :: proc() {}
Translatef :: proc(x, y, z: f32) {}
GetMatrixProjection :: proc() -> gfx.Matrix { return gfx.Matrix(1) }

// --- depth / shader / clip (deferred: no-op) -------------------------------

EnableDepthMask  :: proc() {}
DisableDepthMask :: proc() {}
EnableShader     :: proc(id: u32) {}
DisableShader    :: proc() {}
SetClipPlanes    :: proc(near, far: f64) {}
SetBlendFactors  :: proc(glSrcFactor, glDstFactor, glEquation: i32) {}

// --- vertex arrays / buffers (deferred: no-op) -----------------------------

LoadVertexArray    :: proc() -> u32 { return 0 }
EnableVertexArray  :: proc(vaoId: u32) -> bool { return false }
DisableVertexArray :: proc() {}
UnloadVertexArray  :: proc(vaoId: u32) {}
LoadVertexBuffer   :: proc(buffer: rawptr, size: i32, is_dynamic: bool) -> u32 { return 0 }
UpdateVertexBuffer :: proc(bufferId: u32, data: rawptr, dataSize: i32, offset: i32) {}
UnloadVertexBuffer :: proc(vboId: u32) {}
EnableVertexAttribute     :: proc(index: u32) {}
SetVertexAttribute        :: proc(index: u32, compSize: i32, type: i32, normalized: bool, stride: i32, offset: i32) {}
SetVertexAttributeDivisor :: proc(index: u32, divisor: i32) {}
DrawVertexArrayInstanced         :: proc(offset, count, instances: i32) {}
DrawVertexArrayElementsInstanced :: proc(offset, count: i32, buffer: rawptr, instances: i32) {}

// --- framebuffers / textures (deferred: no-op) -----------------------------

LoadFramebuffer    :: proc() -> u32 { return 0 }
EnableFramebuffer  :: proc(id: u32) {}
DisableFramebuffer :: proc() {}
FramebufferAttach  :: proc(fboId, texId: u32, attachType, texType, mipLevel: i32) {}
FramebufferComplete :: proc(id: u32) -> bool { return false }
LoadTexture      :: proc(data: rawptr, width, height, format, mipmapCount: i32) -> u32 { return 0 }
LoadTextureDepth :: proc(width, height: i32, useRenderBuffer: bool) -> u32 { return 0 }
UnloadTexture    :: proc(id: u32) {}
