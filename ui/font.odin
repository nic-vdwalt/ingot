// LIB-CANDIDATE: imports only core:* and vendor:raylib.
package ui

import rl "vendor:raylib"
import "core:strings"

// Embed the TTF font at compile time (Nerd Font Mono — single-cell-width icons).
FONT_DATA := #load("../assets/fonts/JetBrainsMonoNerdFontMono-Regular.ttf")

@(private)
font_loaded: bool

// Rasterization multiplier: atlases are baked at draw_size × font_dpi so
// glyphs sample ~1:1 physical pixels under WINDOW_HIGHDPI.
@(private)
font_dpi: f32 = 1.0

// Lazy per-size atlas cache. The UI uses ≤3 distinct sizes, so this stays
// tiny; each atlas is rasterized at its native draw size (× DPI) instead of
// bilinear-downscaling one large atlas (which blurs text).
@(private)
font_cache: map[i32]rl.Font

// Codepoint list shared by all atlases; built once in init_font.
@(private)
font_codepoints: []rune

// set_font_dpi sets the atlas rasterization multiplier. Call before
// init_font / any drawing; changing it later requires reset_font_atlases().
set_font_dpi :: proc(scale: f32) {
	font_dpi = scale if scale > 0 else 1.0
}

// reset_font_atlases unloads every cached atlas so the next draw re-rasterizes
// at the current font_dpi. Call when the window's DPI scale changes (e.g. the
// window moved between a retina and a non-retina display).
reset_font_atlases :: proc() {
	if !font_loaded do return
	for _, f in font_cache {
		rl.UnloadFont(f)
	}
	clear(&font_cache)
}

// --- measure_text memoization ------------------------------------------------
// The font never changes after init_font(), so width(text,size) is a pure
// function and safe to cache for the process lifetime.
@(private)
Measure_Key :: struct {
	text: string,
	size: i32,
}

@(private)
measure_cache: map[Measure_Key]i32

// A contiguous range of Unicode codepoints to rasterize.
Codepoint_Range :: struct {
	start: rune,
	end:   rune,
}

// Codepoint ranges to load — standard Unicode + a slice of Nerd Font PUA glyphs.
CODEPOINT_RANGES :: [?]Codepoint_Range{
	{0x0020, 0x007E}, // Basic Latin
	{0x00A0, 0x00FF}, // Latin-1 Supplement
	{0x0100, 0x024F}, // Latin Extended-A & B
	{0x2000, 0x206F}, // General Punctuation
	{0x2190, 0x21FF}, // Arrows
	{0x2500, 0x257F}, // Box Drawing
	{0x25A0, 0x25FF}, // Geometric Shapes
	{0x2600, 0x26FF}, // Miscellaneous Symbols
	{0x2700, 0x27BF}, // Dingbats
	{0xE0A0, 0xE0A3}, // Powerline Symbols
	{0xE0B0, 0xE0D4}, // Powerline Extra
	{0xEA60, 0xEC1E}, // Codicons
	{0xF000, 0xF2FF}, // Font Awesome (classic)
	{0xF400, 0xF533}, // Octicons
}

// Initialize the custom font system. Call after rl.InitWindow().
init_font :: proc() {
	total := 0
	for r in CODEPOINT_RANGES {
		total += int(r.end - r.start) + 1
	}

	font_codepoints = make([]rune, total)
	idx := 0
	for r in CODEPOINT_RANGES {
		for cp := r.start; cp <= r.end; cp += 1 {
			font_codepoints[idx] = cp
			idx += 1
		}
	}

	font_cache = make(map[i32]rl.Font)
	font_loaded = true
}

// get_font returns the atlas for a draw size, rasterizing it on first use at
// size × font_dpi physical pixels.
@(private)
get_font :: proc(size: i32) -> rl.Font {
	if f, ok := font_cache[size]; ok do return f

	px := i32(f32(size)*font_dpi + 0.5)
	f := rl.LoadFontFromMemory(
		".ttf",
		raw_data(FONT_DATA),
		i32(len(FONT_DATA)),
		px,
		raw_data(font_codepoints),
		i32(len(font_codepoints)),
	)
	if f.glyphCount > 0 {
		// BILINEAR covers non-integer DPI ratios (e.g. 1.5) where glyphs
		// still land between physical pixels.
		rl.SetTextureFilter(f.texture, .BILINEAR)
	}
	font_cache[size] = f
	return f
}

// Unload all font atlases. Call before rl.CloseWindow().
destroy_font :: proc() {
	if font_loaded {
		for _, f in font_cache {
			rl.UnloadFont(f)
		}
		delete(font_cache)
		font_cache = nil
		delete(font_codepoints)
		font_codepoints = nil
		font_loaded = false
	}
	for k in measure_cache {
		delete(k.text)
	}
	delete(measure_cache)
	measure_cache = nil
}

// clear_measure_cache flushes the text-measurement memo. Call when the UI
// scale changes so entries measured at the old font sizes are dropped.
clear_measure_cache :: proc() {
	for k in measure_cache {
		delete(k.text)
	}
	clear(&measure_cache)
}

// Draw text using the custom font. Falls back to default if font failed to load.
draw_text :: proc(text: cstring, x, y, size: i32, color: rl.Color) {
	if font_loaded {
		// Zero extra spacing: the font's own advance metrics keep glyph
		// origins on pixel boundaries (fractional spacing smears glyphs).
		rl.DrawTextEx(get_font(size), text, rl.Vector2{f32(x), f32(y)}, f32(size), 0, color)
	} else {
		rl.DrawText(text, x, y, size, color)
	}
}

// Cap on cached measure entries. Streaming text produces never-repeating
// partial strings; without a cap the cache grows for the process lifetime.
MEASURE_CACHE_MAX :: 8192
// Strings longer than this are not worth caching: they are almost always
// unique, and cloning them is the leak.
MEASURE_CACHE_MAX_KEY_LEN :: 256

// Measure text width using the custom font.
measure_text :: proc(text: cstring, size: i32) -> i32 {
	if font_loaded {
		key := Measure_Key{text = string(text), size = size}
		if cached, ok := measure_cache[key]; ok {
			return cached
		}
		v := rl.MeasureTextEx(get_font(size), text, f32(size), 0)
		w := i32(v.x)
		if len(key.text) <= MEASURE_CACHE_MAX_KEY_LEN {
			if len(measure_cache) >= MEASURE_CACHE_MAX {
				// Evict ~half instead of flushing everything — a full flush
				// causes a hitch frame where all visible text re-measures at
				// once. Map order is effectively random, so this is random
				// eviction.
				doomed := make([dynamic]Measure_Key, 0, MEASURE_CACHE_MAX / 2, context.temp_allocator)
				for k in measure_cache {
					if len(doomed) >= MEASURE_CACHE_MAX / 2 do break
					append(&doomed, k)
				}
				for k in doomed {
					delete_key(&measure_cache, k)
					delete(k.text)
				}
			}
			// Own the key string so it survives the caller's temp allocator.
			measure_cache[Measure_Key{text = strings.clone(string(text)), size = size}] = w
		}
		return w
	}
	return rl.MeasureText(text, size)
}

// Pixel width of a single rune at the given size, backed by measure_cache.
// Encodes into a stack buffer so cache hits allocate nothing.
rune_width :: proc(r: rune, size: i32) -> i32 {
	buf: [5]u8 // up to 4 UTF-8 bytes + NUL
	n := 0
	c := u32(r)
	switch {
	case c <= 0x7F:
		buf[0] = u8(c); n = 1
	case c <= 0x7FF:
		buf[0] = u8(0xC0 | (c >> 6)); buf[1] = u8(0x80 | (c & 0x3F)); n = 2
	case c <= 0xFFFF:
		buf[0] = u8(0xE0 | (c >> 12)); buf[1] = u8(0x80 | ((c >> 6) & 0x3F))
		buf[2] = u8(0x80 | (c & 0x3F)); n = 3
	case:
		buf[0] = u8(0xF0 | (c >> 18)); buf[1] = u8(0x80 | ((c >> 12) & 0x3F))
		buf[2] = u8(0x80 | ((c >> 6) & 0x3F)); buf[3] = u8(0x80 | (c & 0x3F)); n = 4
	}
	buf[n] = 0
	return measure_text(cstring(&buf[0]), size)
}

// Draw a single Unicode codepoint using the custom font.
draw_codepoint :: proc(codepoint: rune, x, y: i32, size: i32, color: rl.Color) {
	if font_loaded {
		rl.DrawTextCodepoint(get_font(size), codepoint, rl.Vector2{f32(x), f32(y)}, f32(size), color)
	}
}
