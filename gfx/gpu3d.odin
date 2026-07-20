// ingot:gfx — 3D / shader / render-target API surface (raylib parity).
//
// STATUS: this is a compile-compatible, runtime-SAFE surface, not yet a
// functional WebGPU 3D renderer. The consumer that exercises it (openalloy's
// galaxy view: a 7-shader HDR bloom + soft-particle + instanced-mesh pipeline)
// needs a dedicated WebGPU port — GLSL→WGSL for every shader, render-target
// ping-pong with mip chains, and instanced mesh drawing. Until that lands these
// procs are no-ops so the app builds and its 2D UI + terminal run on WebGPU;
// draws issued into a render-target (BeginTextureMode..EndTextureMode) are
// SUPPRESSED rather than leaked into the main pass, so the galaxy area renders
// blank instead of corrupting the frame. See README "Status notes".
package gfx

// --- types (mirror raylib) -------------------------------------------------

Shader :: struct {
	id:   u32,
	locs: [^]i32,
}

RenderTexture :: struct {
	id:      u32,
	texture: Texture,
	depth:   Texture,
}
RenderTexture2D :: RenderTexture

MaterialMap :: struct {
	texture: Texture2D,
	color:   Color,
	value:   f32,
}

Material :: struct {
	shader: Shader,
	maps:   [^]MaterialMap,
	params: [4]f32,
}

Mesh :: struct {
	vertexCount:   i32,
	triangleCount: i32,
	vertices:      [^]f32,
	texcoords:     [^]f32,
	normals:       [^]f32,
	colors:        [^]u8,
	indices:       [^]u16,
	vaoId:         u32,
	vboId:         [^]u32,
}

ShaderUniformDataType :: enum i32 {
	FLOAT = 0,
	VEC2,
	VEC3,
	VEC4,
	INT,
	IVEC2,
	IVEC3,
	IVEC4,
	SAMPLER2D,
}

ShaderLocationIndex :: enum i32 {
	VERTEX_POSITION = 0,
	VERTEX_TEXCOORD01,
	VERTEX_TEXCOORD02,
	VERTEX_NORMAL,
	VERTEX_TANGENT,
	VERTEX_COLOR,
	MATRIX_MVP,
	MATRIX_VIEW,
	MATRIX_PROJECTION,
	MATRIX_MODEL,
	MATRIX_NORMAL,
	VECTOR_VIEW,
	COLOR_DIFFUSE,
	COLOR_SPECULAR,
	COLOR_AMBIENT,
	MAP_ALBEDO,
	MAP_METALNESS,
	MAP_NORMAL,
	MAP_ROUGHNESS,
	MAP_OCCLUSION,
	MAP_EMISSION,
	MAP_HEIGHT,
	MAP_CUBEMAP,
	MAP_IRRADIANCE,
	MAP_PREFILTER,
	MAP_BRDF,
	VERTEX_BONEIDS,
	VERTEX_BONEWEIGHTS,
	BONE_MATRICES,
}

// --- shaders ---------------------------------------------------------------
// Implemented in shader.odin (real WGSL shader objects + uniform reflection):
//   LoadShaderFromMemory / UnloadShader / BeginShaderMode / EndShaderMode
//   GetShaderLocation / SetShaderValue{,V,Matrix,Texture}

// --- render targets --------------------------------------------------------
// Implemented in render_target.odin (real offscreen WebGPU passes):
//   LoadRenderTexture / LoadRenderTextureEx / UnloadRenderTexture
//   BeginTextureMode / EndTextureMode

// --- meshes / materials ----------------------------------------------------
// GenMeshSphere / LoadMaterialDefault / DrawMesh are implemented in
// render3d.odin (CPU-projected billboard/disc approximation over the 2D batch).

// --- blend modes / billboards ----------------------------------------------

BlendMode :: enum i32 {
	ALPHA = 0,
	ADDITIVE,
	MULTIPLIED,
	ADD_COLORS,
	SUBTRACT_COLORS,
	ALPHA_PREMULTIPLY,
	CUSTOM,
	CUSTOM_SEPARATE,
}

// BeginBlendMode selects one of the precompiled batch blend pipelines. Inputs
// are premultiplied, so ADDITIVE = One/One. CUSTOM uses the factors last set by
// rlgl.SetBlendFactors. Switching flushes the pending run first.
BeginBlendMode :: proc(mode: BlendMode) {
	slot: Blend_Slot = .Alpha
	#partial switch mode {
	case .ADDITIVE, .ADD_COLORS: slot = .Additive
	case .MULTIPLIED:            slot = .Multiplied
	case .CUSTOM, .CUSTOM_SEPARATE: slot = .Custom
	}
	if slot != g.rend.cur_blend {
		if _active_pass_begun() do renderer_flush(&g.rend, active_pass())
		g.rend.cur_blend = slot
	}
}
EndBlendMode :: proc() { BeginBlendMode(.ALPHA) }

// DrawBillboard / DrawBillboardPro implemented in render3d.odin.
