// ingot:gfx — embedded default font backing the raylib-shaped DrawText and
// MeasureText.
//
// raylib ships a built-in font so DrawText works with no asset loading at all.
// Ingot mirrors that by embedding JetBrains Mono (the same face ingot:ui uses)
// and baking it into an ordinary glyph atlas the first time DrawText or
// MeasureText is called. An application that never calls either allocates
// nothing, bakes nothing, and uploads nothing.
//
// Build with -define:INGOT_DEFAULT_FONT=false to keep the embedded face out of
// the binary. DrawText and MeasureText then do not exist, so a call site that
// depends on them fails to compile instead of silently rendering nothing. Load
// a face with LoadFontFromMemory and call DrawTextEx/MeasureTextEx instead.
package gfx

INGOT_DEFAULT_FONT :: #config(INGOT_DEFAULT_FONT, true)

// Pixel size the default atlas bakes at. DrawText scales from this size to the
// requested fontSize, so it is a quality/memory tradeoff rather than a limit:
// large enough that ordinary UI sizes scale down instead of up, small enough
// that printable ASCII occupies a small part of one 2048x2048 atlas.
DEFAULT_FONT_BAKE_PX :: 32

@(private)
DEFAULT_FONT_FIRST_CP :: rune(' ')
@(private)
DEFAULT_FONT_LAST_CP :: rune('~')
@(private)
DEFAULT_FONT_CP_COUNT :: int(DEFAULT_FONT_LAST_CP - DEFAULT_FONT_FIRST_CP) + 1

when INGOT_DEFAULT_FONT {

	@(private)
	DEFAULT_FONT_TTF := #load("../assets/fonts/JetBrainsMono-Regular.ttf")

	// _default_font returns the context's default font atlas, baking it on
	// first use. The bake needs a live GPU device, so it reports false until
	// the context is initialized; callers must not draw with a false result.
	//
	// The result is cached on Graphics_Resources rather than in a package
	// global so each Context owns its own atlas, and so context teardown
	// clears it along with the atlas slot it refers to.
	@(private)
	_default_font :: proc() -> (Font, bool) {
		if g.resources.default_font_baked {
			font := g.resources.default_font
			return font, get_atlas(font._atlas) != nil
		}
		if !g.initialized do return {}, false

		// Set before baking: a font this build cannot bake (atlas registry
		// full, corrupt embed) must not be retried on every subsequent frame.
		g.resources.default_font_baked = true

		codepoints: [DEFAULT_FONT_CP_COUNT]rune
		for &codepoint, index in codepoints {
			codepoint = DEFAULT_FONT_FIRST_CP + rune(index)
		}
		g.resources.default_font = LoadFontFromMemory(
			".ttf",
			raw_data(DEFAULT_FONT_TTF),
			i32(len(DEFAULT_FONT_TTF)),
			DEFAULT_FONT_BAKE_PX,
			raw_data(codepoints[:]),
			i32(len(codepoints)),
		)
		return g.resources.default_font, g.resources.default_font.glyphCount > 0
	}

	// DrawText matches raylib's no-asset-required entry point. Unlike raylib it
	// adds no implicit spacing: raylib's built-in face is a tightly packed
	// bitmap font needing fontSize/10 added back between glyphs, whereas the
	// embedded TTF's own advances already include it.
	DrawText :: proc(text: cstring, posX, posY, fontSize: i32, color: Color) {
		font, ok := _default_font()
		if !ok do return
		DrawTextEx(font, text, {f32(posX), f32(posY)}, f32(fontSize), 0, color)
	}

	// MeasureText reads the same atlas DrawText draws from, so its result
	// always describes what DrawText actually renders.
	MeasureText :: proc(text: cstring, fontSize: i32) -> i32 {
		font, ok := _default_font()
		if !ok do return 0
		return i32(MeasureTextEx(font, text, f32(fontSize), 0).x)
	}

}
