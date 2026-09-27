// LIB-CANDIDATE: this package must import only core:*.
//
// Pixel materials: the Surface_Style.Pixel half of material.odin.
//
// Pixel art has no curves, no blur and no sub-pixel coverage, so every shape
// here is a union of axis-aligned rectangles whose edges sit on whole "art
// pixels". Notched corners stand in for rounding, a two-tone bevel stands in
// for gloss, and a hard offset stands in for a soft shadow. Each primitive is
// a fixed, small number of rectangle commands, so a pixel surface costs a
// known constant rather than scaling with its size.
package ui

import "core:math"

// A dither is a full-viewport effect, so it carries a hard row bound for the
// same reason the substrates do. 1024 rows covers a 4K viewport at a two-pixel
// pitch; past it the pitch doubles instead of the command count growing.
DITHER_ROWS_MAX :: 1024
#assert(DITHER_ROWS_MAX <= PAINT_COMMANDS_HEADROOM)

// Doubling the pitch at most this many times reaches a pitch of 512 art
// pixels, beyond any viewport the runtime can open.
DITHER_PITCH_DOUBLINGS_MAX :: 8

// surface_is_pixel reports whether the active theme paints surfaces as pixel
// art. Widgets ask this rather than reading the theme field so the style has
// one spelling at every branch.
surface_is_pixel :: proc(frame: ^Ui_Frame) -> bool {
	assert(frame != nil, "surface_is_pixel: nil frame")
	return ui_frame_theme(frame).surface_style == .Pixel
}

// art_pixel is the size of one pixel-art pixel in logical units: the Emphasis
// border weight floored to a whole unit. Every pixel-style edge, notch, bevel
// and shadow offset is a whole multiple of it, which is what keeps the chunky
// grid consistent between a button and the card it sits on.
art_pixel :: proc(frame: ^Ui_Frame) -> f32 {
	assert(frame != nil, "art_pixel: nil frame")
	result := max(1, math.floor(border_pixels(frame, .Emphasis)))
	whole := math.floor(result)
	assert(result >= 1 && result == whole, "art_pixel: not a whole unit")
	return result
}

// pixel_snap_rect rounds a rectangle's edges to whole logical units so the
// strips drawn from it cannot straddle a pixel boundary.
@(private = "file")
pixel_snap_rect :: proc(rect: Rectangle) -> Rectangle {
	assert(rect.width >= 0 && rect.height >= 0, "pixel_snap_rect: negative size")
	x0 := math.round(rect.x)
	y0 := math.round(rect.y)
	x1 := math.round(rect.x + rect.width)
	y1 := math.round(rect.y + rect.height)
	result := Rectangle{x0, y0, x1 - x0, y1 - y0}
	assert(result.width >= 0 && result.height >= 0, "pixel_snap_rect: inverted rect")
	return result
}

// draw_pixel_fill fills a rectangle with one art pixel notched out of each
// corner. Three strips that do not overlap, so a translucent fill does not
// darken where two strips would otherwise cross.
draw_pixel_fill :: proc(frame: ^Ui_Frame, rect: Rectangle, color: Color) {
	assert(frame != nil, "draw_pixel_fill: nil frame")
	if rect.width <= 0 || rect.height <= 0 || color.a == 0 do return
	r := pixel_snap_rect(rect)
	notch := art_pixel(frame)
	if r.width < notch * 3 || r.height < notch * 3 {
		draw_rectangle_rec(frame, r, color)
		return
	}
	assert(r.width > notch * 2 && r.height > notch * 2, "draw_pixel_fill: notch exceeds rect")
	draw_rectangle_rec(frame, {r.x + notch, r.y, r.width - notch * 2, r.height}, color)
	side_h := r.height - notch * 2
	draw_rectangle_rec(frame, {r.x, r.y + notch, notch, side_h}, color)
	draw_rectangle_rec(frame, {r.x + r.width - notch, r.y + notch, notch, side_h}, color)
}

// draw_pixel_border outlines a rectangle one art pixel thick with the corner
// pixels left out, the stepped outline a sprite editor draws for a rounded
// box. Four strips, none overlapping.
draw_pixel_border :: proc(frame: ^Ui_Frame, rect: Rectangle, color: Color) {
	assert(frame != nil, "draw_pixel_border: nil frame")
	if rect.width <= 0 || rect.height <= 0 || color.a == 0 do return
	r := pixel_snap_rect(rect)
	edge := art_pixel(frame)
	if r.width < edge * 3 || r.height < edge * 3 {
		draw_rectangle_lines_ex(frame, r, edge, color)
		return
	}
	assert(r.width > edge * 2 && r.height > edge * 2, "draw_pixel_border: edge exceeds rect")
	span_w := r.width - edge * 2
	span_h := r.height - edge * 2
	draw_rectangle_rec(frame, {r.x + edge, r.y, span_w, edge}, color)
	draw_rectangle_rec(frame, {r.x + edge, r.y + r.height - edge, span_w, edge}, color)
	draw_rectangle_rec(frame, {r.x, r.y + edge, edge, span_h}, color)
	draw_rectangle_rec(frame, {r.x + r.width - edge, r.y + edge, edge, span_h}, color)
}

// draw_pixel_bevel lights the top and left inner edge and shades the bottom
// and right, one art pixel inside the border. Sunken swaps the two inks,
// which is the whole of a pixel button's press animation. The strips tile the
// inner ring exactly once, so neither ink is drawn over the other.
draw_pixel_bevel :: proc(frame: ^Ui_Frame, rect: Rectangle, sunken: bool) {
	assert(frame != nil, "draw_pixel_bevel: nil frame")
	if rect.width <= 0 || rect.height <= 0 do return
	style := ui_frame_theme(frame)
	edge := art_pixel(frame)
	outer := pixel_snap_rect(rect)
	inner := Rectangle {
		outer.x + edge,
		outer.y + edge,
		outer.width - edge * 2,
		outer.height - edge * 2,
	}
	// A bevel needs a lit edge, a shaded edge and at least one pixel of face
	// between them; anything smaller is all bevel and reads as noise.
	if inner.width < edge * 3 || inner.height < edge * 3 do return
	light := style.bevel_shade if sunken else style.bevel_light
	shade := style.bevel_light if sunken else style.bevel_shade
	assert(inner.width > edge * 2 && inner.height > edge * 2, "draw_pixel_bevel: tiny inner rect")
	right := inner.x + inner.width - edge
	bottom := inner.y + inner.height - edge
	draw_rectangle_rec(frame, {inner.x, inner.y, inner.width - edge, edge}, light)
	draw_rectangle_rec(frame, {inner.x, inner.y + edge, edge, inner.height - edge}, light)
	draw_rectangle_rec(frame, {right, inner.y, edge, inner.height}, shade)
	draw_rectangle_rec(frame, {inner.x + edge, bottom, inner.width - edge * 2, edge}, shade)
}

// pixel_shadow_offset resolves an elevation to a whole number of art pixels,
// never less than one for a raised surface. A shadow offset that is not a
// whole art pixel would sit half a pixel off the grid the rest of the
// surface is drawn on.
pixel_shadow_offset :: proc(frame: ^Ui_Frame, elevation: Elevation) -> f32 {
	assert(frame != nil, "pixel_shadow_offset: nil frame")
	if elevation == .Flat do return 0
	unit := art_pixel(frame)
	steps := max(1, math.round(elevation_offset(frame, elevation) / unit))
	result := steps * unit
	assert(result >= unit, "pixel_shadow_offset: raised surface without an offset")
	return result
}

// draw_pixel_shadow draws the hard drop shadow of a pixel surface: its
// notched silhouette in shadow_color, offset down and right by whole art
// pixels.
draw_pixel_shadow :: proc(frame: ^Ui_Frame, rect: Rectangle, offset: f32) {
	assert(frame != nil, "draw_pixel_shadow: nil frame")
	assert(offset >= 0, "draw_pixel_shadow: negative offset")
	base := ui_frame_theme(frame).shadow_color
	if base.a == 0 || offset == 0 || rect.width <= 0 || rect.height <= 0 do return
	shifted := Rectangle{rect.x + offset, rect.y + offset, rect.width, rect.height}
	draw_pixel_fill(frame, shifted, base)
}

// dither_pitch returns the row pitch that keeps a dither of this height
// inside DITHER_ROWS_MAX, starting from two art pixels and doubling.
dither_pitch :: proc(height: f32, unit: f32) -> f32 {
	assert(unit >= 1, "dither_pitch: invalid unit")
	assert(height >= 0, "dither_pitch: negative height")
	pitch := unit * 2
	for _ in 0 ..< DITHER_PITCH_DOUBLINGS_MAX {
		if height / pitch <= DITHER_ROWS_MAX do break
		pitch *= 2
	}
	return pitch
}

// draw_dither_rect lays a 50% ordered dither over a region: one art pixel of
// solid colour on every other row. The renderer has no texture fill, so a
// true checkerboard would cost one command per cell - over sixty thousand at
// 1080p. Rows cost one command each and read as the same half-tone at pixel
// scale, the way a scanline dim does on a sprite screen.
draw_dither_rect :: proc(frame: ^Ui_Frame, rect: Rectangle, color: Color) {
	assert(frame != nil, "draw_dither_rect: nil frame")
	if rect.width <= 0 || rect.height <= 0 || color.a == 0 do return
	r := pixel_snap_rect(rect)
	unit := art_pixel(frame)
	pitch := dither_pitch(r.height, unit)
	band := pitch / 2
	rows := int(math.ceil(r.height / pitch))
	assert(rows <= DITHER_ROWS_MAX + 1, "draw_dither_rect: row bound exceeded")
	for row in 0 ..< rows {
		y := r.y + f32(row) * pitch
		h := min(band, r.y + r.height - y)
		if h <= 0 do break
		draw_rectangle_rec(frame, {r.x, y, r.width, h}, color)
	}
}

// surface_takes_bevel reports which surface classes read as raised or inset
// objects. Page-level regions and rows are ground, not objects, and a bevel
// on them would outline every panel in the window. Buttons are excluded too:
// an inner bevel against their outline reads as a border two pixels thick on
// the lit sides and a gap on the shaded ones.
surface_takes_bevel :: proc(surface: Surface) -> bool {
	switch surface {
	case .Card, .Popup, .Chip, .Table_Header, .Input, .Code:
		return true
	case .Button_Primary, .Button_Secondary, .Button_Danger:
		return false
	case .App, .Panel, .Row, .Button_Ghost:
		return false
	}
	return false
}

// surface_bevel_sunken reports whether a surface's bevel is inset. Inputs and
// code wells are always inset, the classic sunken field; everything else is
// raised until it is pressed.
surface_bevel_sunken :: proc(surface: Surface, state: Visual_State) -> bool {
	if surface == .Input || surface == .Code do return true
	return state == .Pressed
}

// draw_pixel_surface_colors is draw_surface_colors for the pixel style:
// hard shadow, notched fill, then notched border, in the same fixed order.
draw_pixel_surface_colors :: proc(
	frame: ^Ui_Frame,
	rect: Rectangle,
	colors: Surface_Colors,
	border: Border,
	elevation: Elevation,
) {
	assert(frame != nil, "draw_pixel_surface_colors: nil frame")
	assert(rect.width > 0 && rect.height > 0, "draw_pixel_surface_colors: empty rect")
	draw_pixel_shadow(frame, rect, pixel_shadow_offset(frame, elevation))
	draw_pixel_fill(frame, rect, colors.bg)
	if border != .None do draw_pixel_border(frame, rect, colors.border)
}
