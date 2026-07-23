#+build !js
// ingot:gfx — path-based texture loading (native only). The web target has no
// filesystem paths, so its LoadTexture stub lives in texture_web.odin; web
// apps fetch bytes and decode with LoadImageFromMemory + LoadTextureFromImage.
package gfx

import "core:os"

// LoadTexture reads an image file from disk, decodes it via stb_image, and
// uploads it as a GPU texture. A missing or undecodable file is an operating
// error, not a programmer error, so it is handled by returning an empty
// Texture2D (id 0) rather than asserted.
LoadTexture :: proc(fileName: cstring) -> Texture2D {
	assert(fileName != nil, "LoadTexture: nil fileName")
	path := string(fileName)
	if len(path) == 0 do return Texture2D{}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return Texture2D{}
	// stb_image takes an i32 byte count; reject files that cannot fit rather
	// than silently truncating the size.
	if len(data) == 0 || len(data) > int(max(i32)) do return Texture2D{}
	image := LoadImageFromMemory(fileName, raw_data(data), i32(len(data)))
	if image.data == nil do return Texture2D{}
	defer UnloadImage(image)
	tex := LoadTextureFromImage(image)
	assert(
		tex.id == 0 || (tex.width == image.width && tex.height == image.height),
		"LoadTexture: uploaded texture size must match decoded image",
	)
	return tex
}
