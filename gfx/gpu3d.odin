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

// --- shaders (deferred: no-op) ---------------------------------------------

LoadShaderFromMemory :: proc(vsCode, fsCode: cstring) -> Shader { return Shader{} }
UnloadShader :: proc(shader: Shader) {}
BeginShaderMode :: proc(shader: Shader) {}
EndShaderMode :: proc() {}
GetShaderLocation :: proc(shader: Shader, uniformName: cstring) -> i32 { return -1 }
SetShaderValue :: proc(shader: Shader, #any_int locIndex: i32, value: rawptr, uniformType: ShaderUniformDataType) {}
SetShaderValueV :: proc(shader: Shader, #any_int locIndex: i32, value: rawptr, uniformType: ShaderUniformDataType, count: i32) {}
SetShaderValueMatrix :: proc(shader: Shader, #any_int locIndex: i32, mat: Matrix) {}
SetShaderValueTexture :: proc(shader: Shader, #any_int locIndex: i32, texture: Texture2D) {}

// --- render targets (deferred: draws suppressed while active) --------------

LoadRenderTexture :: proc(width, height: i32) -> RenderTexture2D {
	return RenderTexture2D{}
}
UnloadRenderTexture :: proc(target: RenderTexture2D) {}

BeginTextureMode :: proc(target: RenderTexture2D) {
	if g.frame.has_frame && g.frame.pass_begun {
		renderer_flush(&g.rend, g.frame.pass)
	}
	g.frame.tex_mode = true
}
EndTextureMode :: proc() {
	// discard anything the caller tried to draw into the offscreen target
	clear(&g.rend.verts)
	g.frame.tex_mode = false
}

// --- meshes / materials (deferred: no-op) ----------------------------------

GenMeshSphere :: proc(radius: f32, rings, slices: i32) -> Mesh { return Mesh{} }
UnloadMesh :: proc(mesh: Mesh) {}
DrawMesh :: proc(mesh: Mesh, material: Material, transform: Matrix) {}
LoadMaterialDefault :: proc() -> Material { return Material{} }

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

// Blend-mode switching isn't wired into the batch pipeline yet (additive glow
// for the galaxy is part of the deferred 3D port); no-op keeps apps building.
BeginBlendMode :: proc(mode: BlendMode) {}
EndBlendMode :: proc() {}

DrawBillboardPro :: proc(camera: Camera, texture: Texture2D, source: Rectangle, position: Vector3, up: Vector3, size: Vector2, origin: Vector2, rotation: f32, tint: Color) {}
DrawBillboard :: proc(camera: Camera, texture: Texture2D, position: Vector3, scale: f32, tint: Color) {}
