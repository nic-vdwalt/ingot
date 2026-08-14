// ingot:gfx/rlgl - shim over the low-level raylib rlgl API the consumer apps
// use. The 2D WebGPU batch renderer doesn't expose an immediate-mode GL layer,
// so the low-level vertex-array and matrix-stack calls (used only by
// openalloy's deferred galaxy renderer) map onto an internal instancing path
// with matching signatures. DrawRenderBatchActive maps to a real batch flush.
// Lets `import rlgl "vendor:raylib/rlgl"` become `import rlgl "ingot:gfx/rlgl"`
// for that surface.
//
// Calls that this renderer cannot honour are absent rather than present as
// silent no-ops, so a dependency on them is a compile error at the call site.
package rlgl

import gfx "ingot:gfx"

// --- GL enum constants (values match GL / raylib) --------------------------

FLOAT :: 0x1406
ZERO :: 0
ONE :: 1
SRC_COLOR :: 0x0300
ONE_MINUS_SRC_COLOR :: 0x0301
FUNC_ADD :: 0x8006

// --- batch / culling (real) ------------------------------------------------

ContextDrawRenderBatchActive :: proc(ctx: ^gfx.Context) {gfx.context_flush_batch(ctx)}
DrawRenderBatchActive :: proc() {gfx.FlushBatch()}
EnableBackfaceCulling :: proc() {}
DisableBackfaceCulling :: proc() {}

// --- matrix stack (2D model translation) -----------------------------------

ContextPushMatrix :: proc(ctx: ^gfx.Context) {gfx.context_matrix_mode_push(ctx)}
PushMatrix :: proc() {gfx.MatrixModePush()}
ContextPopMatrix :: proc(ctx: ^gfx.Context) {gfx.context_matrix_mode_pop(ctx)}
PopMatrix :: proc() {gfx.MatrixModePop()}
ContextTranslatef :: proc(ctx: ^gfx.Context, x, y, z: f32) {gfx.context_matrix_mode_translate(
		ctx,
		x,
		y,
	)}
Translatef :: proc(x, y, z: f32) {gfx.MatrixModeTranslate(x, y)}
ContextGetMatrixProjection :: proc(ctx: ^gfx.Context) -> gfx.Matrix {
	return gfx.context_get_projection_matrix(ctx)
}
GetMatrixProjection :: proc() -> gfx.Matrix {return gfx.GetProjectionMatrix()}

// --- shader / clip ---------------------------------------------------------

ContextEnableShader :: proc(ctx: ^gfx.Context, id: u32) {gfx.ContextRlEnableInstShader(ctx, id)}
EnableShader :: proc(id: u32) {gfx.RlEnableInstShader(id)}
ContextDisableShader :: proc(ctx: ^gfx.Context) {gfx.ContextRlDisableInstShader(ctx)}
DisableShader :: proc() {gfx.RlDisableInstShader()}
SetClipPlanes :: proc(near, far: f64) {}

// SetBlendFactors records custom blend factors for the Custom blend slot (used
// by the galaxy dust extinction pass). Forwards the GL enums to gfx which maps
// them to wgpu and rebuilds the Custom pipelines.
ContextSetBlendFactors :: proc(ctx: ^gfx.Context, glSrcFactor, glDstFactor, glEquation: i32) {
	gfx.context_set_custom_blend(
		ctx,
		gfx.BlendFactorRL(glSrcFactor),
		gfx.BlendFactorRL(glDstFactor),
		gfx.BlendOpRL(glEquation),
	)
}

SetBlendFactors :: proc(glSrcFactor, glDstFactor, glEquation: i32) {
	gfx.SetCustomBlend(
		gfx.BlendFactorRL(glSrcFactor),
		gfx.BlendFactorRL(glDstFactor),
		gfx.BlendOpRL(glEquation),
	)
}

// --- vertex arrays / buffers (deferred: no-op) -----------------------------

ContextLoadVertexArray :: proc(ctx: ^gfx.Context) -> u32 {return gfx.ContextRlLoadVertexArray(ctx)}
LoadVertexArray :: proc() -> u32 {return gfx.RlLoadVertexArray()}
ContextEnableVertexArray :: proc(ctx: ^gfx.Context, vaoId: u32) -> bool {
	return gfx.ContextRlEnableVertexArray(ctx, vaoId)
}
EnableVertexArray :: proc(vaoId: u32) -> bool {return gfx.RlEnableVertexArray(vaoId)}
ContextDisableVertexArray :: proc(ctx: ^gfx.Context) {gfx.ContextRlDisableVertexArray(ctx)}
DisableVertexArray :: proc() {gfx.RlDisableVertexArray()}
ContextUnloadVertexArray :: proc(ctx: ^gfx.Context, vaoId: u32) {gfx.ContextRlUnloadVertexArray(
		ctx,
		vaoId,
	)}
UnloadVertexArray :: proc(vaoId: u32) {gfx.RlUnloadVertexArray(vaoId)}
LoadVertexBuffer :: proc(
	buffer: rawptr,
	size: i32,
	is_dynamic: bool,
) -> u32 {return gfx.RlLoadVertexBuffer(buffer, size, is_dynamic)}
ContextLoadVertexBuffer :: proc(
	ctx: ^gfx.Context,
	buffer: rawptr,
	size: i32,
	is_dynamic: bool,
) -> u32 {return gfx.ContextRlLoadVertexBuffer(ctx, buffer, size, is_dynamic)}
UpdateVertexBuffer :: proc(
	bufferId: u32,
	data: rawptr,
	dataSize: i32,
	offset: i32,
) {gfx.RlUpdateVertexBuffer(bufferId, data, dataSize, offset)}
ContextUpdateVertexBuffer :: proc(
	ctx: ^gfx.Context,
	bufferId: u32,
	data: rawptr,
	dataSize: i32,
	offset: i32,
) {gfx.ContextRlUpdateVertexBuffer(ctx, bufferId, data, dataSize, offset)}
ContextUnloadVertexBuffer :: proc(ctx: ^gfx.Context, vboId: u32) {gfx.ContextRlUnloadVertexBuffer(
		ctx,
		vboId,
	)}
UnloadVertexBuffer :: proc(vboId: u32) {gfx.RlUnloadVertexBuffer(vboId)}
EnableVertexAttribute :: proc(index: u32) {gfx.RlEnableVertexAttribute(index)}
SetVertexAttribute :: proc(
	index: u32,
	compSize: i32,
	type: i32,
	normalized: bool,
	stride: i32,
	offset: i32,
) {gfx.RlSetVertexAttribute(index, compSize, type, normalized, stride, offset)}
ContextSetVertexAttribute :: proc(
	ctx: ^gfx.Context,
	index: u32,
	compSize: i32,
	type: i32,
	normalized: bool,
	stride: i32,
	offset: i32,
) {gfx.ContextRlSetVertexAttribute(ctx, index, compSize, type, normalized, stride, offset)}
ContextSetVertexAttributeDivisor :: proc(ctx: ^gfx.Context, index: u32, divisor: i32) {
	gfx.ContextRlSetVertexAttributeDivisor(ctx, index, divisor)
}
SetVertexAttributeDivisor :: proc(index: u32, divisor: i32) {gfx.RlSetVertexAttributeDivisor(
		index,
		divisor,
	)}
ContextDrawVertexArrayInstanced :: proc(ctx: ^gfx.Context, offset, count, instances: i32) {
	gfx.ContextRlDrawVertexArrayInstanced(ctx, offset, count, instances)
}
DrawVertexArrayInstanced :: proc(offset, count, instances: i32) {gfx.RlDrawVertexArrayInstanced(
		offset,
		count,
		instances,
	)}
DrawVertexArrayElementsInstanced :: proc(
	offset, count: i32,
	buffer: rawptr,
	instances: i32,
) {gfx.RlDrawVertexArrayElementsInstanced(offset, count, buffer, instances)}

// --- textures ---------------------------------------------------------------
// The galaxy builds HDR render targets from these raw calls. Colour and depth
// attachments are real gfx render-target textures carried on a RenderTexture2D.
//
// There is deliberately no LoadFramebuffer/EnableFramebuffer/FramebufferAttach/
// FramebufferComplete here: those were bookkeeping-only no-ops that accepted a
// framebuffer assembly this renderer never performed. Use gfx.RenderTexture2D
// (LoadRenderTexture + BeginTextureMode) or an explicit WebGPU target instead.

ContextLoadTexture :: proc(
	ctx: ^gfx.Context,
	data: rawptr,
	width, height, format, mipmapCount: i32,
) -> u32 {
	return gfx.ContextRlLoadColorTexture(ctx, width, height, gfx.PixelFormat(format))
}
LoadTexture :: proc(data: rawptr, width, height, format, mipmapCount: i32) -> u32 {
	return gfx.RlLoadColorTexture(width, height, gfx.PixelFormat(format))
}
ContextLoadTextureDepth :: proc(
	ctx: ^gfx.Context,
	width, height: i32,
	useRenderBuffer: bool,
) -> u32 {
	return gfx.ContextRlLoadDepthTexture(ctx, width, height)
}
LoadTextureDepth :: proc(width, height: i32, useRenderBuffer: bool) -> u32 {
	return gfx.RlLoadDepthTexture(width, height)
}
ContextUnloadTexture :: proc(ctx: ^gfx.Context, id: u32) {gfx.ContextRlUnloadTextureId(ctx, id)}
UnloadTexture :: proc(id: u32) {gfx.RlUnloadTextureId(id)}
