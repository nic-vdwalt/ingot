#+build js
// ingot:gfx — LoadTexture stub for the web target. Browsers expose no
// filesystem paths, so path-based loading cannot work there; fetch the bytes
// (ingot:net or a JS bridge) and decode with LoadImageFromMemory +
// LoadTextureFromImage instead. Returning an empty Texture2D (id 0) keeps the
// raylib-shaped API compiling on both targets.
package gfx

LoadTexture :: proc(fileName: cstring) -> Texture2D {
	return Texture2D{}
}
