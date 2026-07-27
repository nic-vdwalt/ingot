#+build js
// ingot:gfx — LoadTexture is unavailable on the web target. Browsers expose no
// filesystem paths, so path-based loading cannot work there.
//
// This declaration exists to fail at the call site rather than at package
// build: a polymorphic body is only type-checked when the procedure is
// instantiated, so a web build that never loads a texture by path compiles
// normally, while one that does gets a compile-time error naming the supported
// route instead of a silent empty Texture2D (id 0) that draws nothing.
package gfx

import "base:intrinsics"

LoadTexture :: proc(fileName: $T) -> Texture2D where intrinsics.type_is_string(T) {
	#panic(
		"gfx: LoadTexture(path) is unsupported on the web target because a " +
		"browser has no filesystem. Fetch the bytes (ingot:net or a JS bridge) " +
		"then call LoadImageFromMemory + LoadTextureFromImage.",
	)
}
