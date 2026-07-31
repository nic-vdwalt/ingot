// LIB-CANDIDATE: this package must import only core:*.
//
// Paper materials: the drawing half of the token layer in tokens.odin.
//
// Everything here is built from the primitives already in draw.odin. No new
// paint kind is introduced, because the constraint that shaped this file is
// that the renderer has no transform stack, no texture support and no blur:
//
//   - Nothing can be rotated. Text commands carry a single origin point and no
//     angle, so a tilted card could hold no tilted label. draw_dog_ear and
//     draw_tape_strip are the substitutes that give a page its handmade edge
//     without needing rotation.
//   - Nothing can be blurred. draw_shadow_hard replaces a stacked-ring
//     approximation that spent four draw commands imitating one soft edge; a
//     hard offset shadow is both cheaper and a better match for paper, which
//     does not diffuse light the way that approximation assumed.
//   - Clips do not nest in the backend, so a decorative stroke cannot be
//     clipped to a rounded interior. draw_highlight_swipe insets its geometry
//     instead, the same way the button gloss already does.
//
// Every procedure that loops over geometry is bounded by a named constant
// derived from the paint budget, and asserts that bound rather than trusting
// it. Overflow is otherwise silent: paint_push counts a dropped command and
// returns, so an unbounded decoration would not crash, it would just quietly
// erase part of itself on a large display.
package ui

// Substrate bounds.
//
// A ruled page draws one line per text baseline. At 4K the viewport is 2160
// physical pixels tall, and the smallest LINE_HEIGHT the metrics can produce
// is 11 (22 logical at the 0.5 minimum UI scale), giving 197 rules worst case.
// 256 rounds that up for headroom. Beyond it the rules are closer together
// than the text they are meant to sit behind, so drawing more is not a
// legibility trade, it is pure cost.
SUBSTRATE_RULES_MAX :: 256

// A dot grid is quadratic in the area it covers, which is why it is a
// card-only material. A 20px grid over a 4K viewport is roughly 20,700
// commands against a total budget of 8192 - it would erase itself and most of
// the interface with it. 1024 covers the largest card the gallery ships (a
// full-width chart at 3x scale) with margin, and draw_dot_grid asserts the
// rect it is handed cannot exceed it.
SUBSTRATE_DOTS_MAX :: 1024

// Paper tooth is the sketchbook substrate: sparse flecks standing in for the
// grain of toned drawing stock. Like the dot grid it is quadratic in area, so
// it carries a hard count rather than a density - a density would look
// identical on a laptop and quietly cost sixteen times as much at 4K.
//
// 512 is what reads as grain rather than as noise across a full viewport;
// beyond it the flecks merge into a wash and stop being texture.
SUBSTRATE_FLECKS_MAX :: 512

// Every substrate must fit in the headroom an ordinary 4K frame leaves, not in
// the raw command cap. Checking this at compile time means lowering the paint
// budget fails the build here rather than silently truncating a page at 4K.
#assert(SUBSTRATE_RULES_MAX <= PAINT_COMMANDS_HEADROOM)
#assert(SUBSTRATE_DOTS_MAX <= PAINT_COMMANDS_HEADROOM)
#assert(SUBSTRATE_FLECKS_MAX <= PAINT_COMMANDS_HEADROOM)

// A marker fill reads as a scribble from about five strokes; past that the
// strokes merge and the extra commands buy nothing. A fixed count also makes a
// pressed row cost the same whether it is 40 or 400 pixels wide.
SCRIBBLE_STROKES_MAX :: 7

// draw_surface is the single fill-stroke-shadow entry point for a token-styled
// region. Widgets call this instead of composing draw_rectangle_rounded and
// draw_rectangle_rounded_lines_ex themselves, which is what stops two widgets
// drawing the same surface class with different radii or border weights.
//
// Order matters and is fixed here: shadow, then fill, then border. A border
// drawn before its fill would be half-covered by it.
draw_surface :: proc(
	frame: ^Ui_Frame,
	rect: Rectangle,
	surface: Surface,
	state: Visual_State = .Rest,
	radius: Radius = .MD,
	border: Border = .Hairline,
	elevation: Elevation = .Flat,
) {
	assert(frame != nil, "draw_surface: nil frame")
	if rect.width <= 0 || rect.height <= 0 do return
	colors := surface_colors(frame, surface, state)
	ratio := radius_ratio(frame, radius, rect)
	segments := radius_segments(radius_pixels(frame, radius, min(rect.width, rect.height)))

	if elevation != .Flat {
		draw_shadow_hard(frame, rect, radius, elevation)
	}
	if colors.bg.a > 0 {
		draw_rectangle_rounded(frame, rect, ratio, segments, colors.bg)
	}
	if border != .None && colors.border.a > 0 {
		draw_rectangle_rounded_lines_ex(
			frame,
			rect,
			ratio,
			segments,
			border_pixels(frame, border),
			colors.border,
		)
	}
}

// draw_shadow_hard offsets one rounded rect behind a surface.
//
// It replaces draw_shadow_rounded's four expanding translucent rings. That
// procedure had no callers inside this package, so nothing had to be migrated
// to change the model, and its downward bias was a raw +3 that did not scale -
// at 3x UI scale its shadow sat a third as far from the card as at 1x.
draw_shadow_hard :: proc(frame: ^Ui_Frame, rect: Rectangle, radius: Radius, elevation: Elevation) {
	assert(frame != nil, "draw_shadow_hard: nil frame")
	assert(rect.width > 0 && rect.height > 0, "draw_shadow_hard: empty rect")
	base := ui_frame_theme(frame).shadow_color
	offset := elevation_offset(frame, elevation)
	// A palette may disable shadows outright by zeroing shadow_color alpha,
	// which is how the high-contrast theme opts out without a special case
	// here. Flat resolves to a zero offset for the same reason.
	if base.a == 0 || offset == 0 do return
	shifted := Rectangle{rect.x + offset, rect.y + offset, rect.width, rect.height}
	ratio := radius_ratio(frame, radius, shifted)
	segments := radius_segments(radius_pixels(frame, radius, min(shifted.width, shifted.height)))
	draw_rectangle_rounded(frame, shifted, ratio, segments, base)
}

// rules_needed reports how many rules a region of this height takes at this
// spacing. Exposed for the same reason as dot_grid_fits: a caller that cannot
// guarantee a bounded region should ask before drawing rather than trip the
// precondition inside draw_rule_lines.
rules_needed :: proc(height: f32, spacing: i32) -> int {
	assert(spacing > 0, "rules_needed: non-positive spacing")
	if height <= 0 do return 0
	// Rules sit at each multiple of the spacing strictly inside the region, so
	// a region exactly N spacings tall carries N-1 of them.
	count := int(height / f32(spacing))
	if f32(count) * f32(spacing) >= height do count -= 1
	return max(count, 0)
}

// draw_rule_lines fills a region with horizontal rules, the notebook
// substrate's base layer.
//
// Spacing defaults to LINE_HEIGHT so rules land on the same rhythm as the text
// drawn over them. A rule at an arbitrary spacing would cut through descenders
// on some lines and not others, which reads as a rendering fault rather than
// as paper.
draw_rule_lines :: proc(frame: ^Ui_Frame, rect: Rectangle, spacing: i32 = 0, color: Color) {
	assert(frame != nil, "draw_rule_lines: nil frame")
	assert(spacing >= 0, "draw_rule_lines: negative spacing")
	if rect.width <= 0 || rect.height <= 0 || color.a == 0 do return
	step := spacing if spacing > 0 else ui_frame_metrics(frame).LINE_HEIGHT
	assert(step > 0, "draw_rule_lines: non-positive rule spacing")

	// The bound is a precondition on the geometry rather than a cap applied
	// while drawing. Truncating mid-loop would hide the problem on exactly the
	// displays where it appears: a region needing more than SUBSTRATE_RULES_MAX
	// is taller than a 4K viewport at minimum scale, so the caller passed
	// something it did not mean to.
	count := rules_needed(rect.height, step)
	assert(count <= SUBSTRATE_RULES_MAX, "draw_rule_lines: region exceeds the rule bound")

	thickness := border_pixels(frame, .Hairline)
	for index in 1 ..= count {
		y := rect.y + f32(index) * f32(step)
		draw_line_ex(frame, {rect.x, y}, {rect.x + rect.width, y}, thickness, color)
	}
}

// draw_margin_rule draws the single vertical line down a ruled page.
//
// It takes an inset rather than deriving one, because the margin has to line
// up with whatever padding the caller's content uses; a margin that does not
// align with the text it sits beside looks like a mistake rather than a page.
draw_margin_rule :: proc(frame: ^Ui_Frame, rect: Rectangle, inset: i32, color: Color) {
	assert(frame != nil, "draw_margin_rule: nil frame")
	assert(inset >= 0, "draw_margin_rule: negative inset")
	if rect.width <= 0 || rect.height <= 0 || color.a == 0 do return
	x := rect.x + f32(ui_frame_sc(frame, inset))
	if x >= rect.x + rect.width do return
	draw_line_ex(
		frame,
		{x, rect.y},
		{x, rect.y + rect.height},
		border_pixels(frame, .Hairline),
		color,
	)
}

// draw_hand_underline draws the double stroke people actually make when
// underlining by hand: one full pass, then a shorter second pass slightly
// below and inset from the start.
//
// A single straight rule under a heading reads as a border - the eye takes it
// as the top edge of whatever follows. The doubled, deliberately unequal pair
// reads as a pen instead, because no one draws the same line twice.
//
// The insets are fractions of the width rather than fixed pixels, so a short
// heading and a long one both look drawn by the same hand; a fixed inset makes
// a short underline look like a full one that failed to reach the end.
draw_hand_underline :: proc(frame: ^Ui_Frame, x, y, width: i32, color: Color) {
	assert(frame != nil, "draw_hand_underline: nil frame")
	assert(width >= 0, "draw_hand_underline: negative width")
	if width == 0 || color.a == 0 do return
	thickness := border_pixels(frame, .Hairline)
	assert(thickness > 0, "draw_hand_underline: scaled the stroke to nothing")

	span := f32(width)
	top := f32(y)
	draw_line_ex(frame, {f32(x), top}, {f32(x) + span, top}, thickness, color)

	// The return stroke: starts a twelfth in, stops a fifth short, and sits
	// one hairline lower. Deterministic, because frames here are event-driven
	// and a randomised second stroke would reshuffle on unrelated input - the
	// underline would appear to twitch whenever anything else redrew.
	second_y := top + thickness + ui_frame_scf(frame, 1)
	start := f32(x) + span / 12
	end := f32(x) + span * 0.8
	if end <= start do return
	draw_line_ex(frame, {start, second_y}, {end, second_y}, thickness, color)
}

// dot_grid_fits reports whether a region can be dotted within the command
// bound. Exposed so a caller can choose a different substrate rather than
// tripping the assertion in draw_dot_grid.
dot_grid_fits :: proc(rect: Rectangle, spacing: i32) -> bool {
	assert(spacing > 0, "dot_grid_fits: non-positive spacing")
	if rect.width <= 0 || rect.height <= 0 do return true
	columns := int(rect.width / f32(spacing)) + 1
	rows := int(rect.height / f32(spacing)) + 1
	return columns * rows <= SUBSTRATE_DOTS_MAX
}

// draw_dot_grid fills a bounded region with grid dots.
//
// It asserts the region fits rather than clipping to the bound, because a
// silently half-drawn grid is worse than a loud failure: the missing half is
// invisible in a screenshot and only appears on displays larger than the one
// the author was using. Callers that cannot guarantee a bounded rect should
// ask dot_grid_fits first, or use rules, which scale linearly.
draw_dot_grid :: proc(frame: ^Ui_Frame, rect: Rectangle, spacing: i32 = 0, color: Color) {
	assert(frame != nil, "draw_dot_grid: nil frame")
	assert(spacing >= 0, "draw_dot_grid: negative spacing")
	if rect.width <= 0 || rect.height <= 0 || color.a == 0 do return
	step := spacing if spacing > 0 else ui_frame_metrics(frame).LINE_HEIGHT
	assert(step > 0, "draw_dot_grid: non-positive grid spacing")
	assert(dot_grid_fits(rect, step), "draw_dot_grid: region exceeds the dot bound")

	// Dots are one-pixel rects rather than circles: both cost a single paint
	// command, but a circle also carries a segment fan the renderer has to
	// tessellate for a mark too small to show curvature.
	size := max(border_pixels(frame, .Hairline), 1)
	// Bounded by the same counts dot_grid_fits checked, so the loops carry
	// their limit in their range rather than in a running counter.
	columns := rules_needed(rect.width, step)
	rows := rules_needed(rect.height, step)
	for row in 1 ..= rows {
		for column in 1 ..= columns {
			x := rect.x + f32(column) * f32(step)
			y := rect.y + f32(row) * f32(step)
			draw_rectangle_rec(frame, {x, y, size, size}, color)
		}
	}
}

// draw_highlight_swipe lays a marker stroke behind content, the paper
// equivalent of a selection fill.
//
// The end wedges are what distinguish it from a plain rect: a real highlighter
// tapers where the tip lifts. They are drawn as triangles because the backend
// cannot clip them to a rounded interior, so the shape has to be built rather
// than masked.
draw_highlight_swipe :: proc(frame: ^Ui_Frame, rect: Rectangle, color: Color) {
	assert(frame != nil, "draw_highlight_swipe: nil frame")
	if rect.width <= 0 || rect.height <= 0 || color.a == 0 do return
	taper := min(rect.height * 0.5, rect.width * 0.25)
	body := Rectangle{rect.x + taper, rect.y, rect.width - taper * 2, rect.height}
	if body.width > 0 do draw_rectangle_rec(frame, body, color)

	left := rect.x + taper
	right := rect.x + rect.width - taper
	top := rect.y
	bottom := rect.y + rect.height
	draw_triangle(frame, {left, top}, {rect.x, bottom}, {left, bottom}, color)
	draw_triangle(frame, {right, top}, {right, bottom}, {rect.x + rect.width, bottom}, color)
}

// draw_scribble_fill hatches a region with diagonal strokes, the pressed-state
// material.
//
// Stroke placement is a fixed fraction of the width rather than randomised.
// Frames here are event-driven and redraw on unrelated input, so a random
// scribble would reshuffle whenever anything else changed - the control would
// appear to shimmer while held.
draw_scribble_fill :: proc(frame: ^Ui_Frame, rect: Rectangle, color: Color) {
	assert(frame != nil, "draw_scribble_fill: nil frame")
	if rect.width <= 0 || rect.height <= 0 || color.a == 0 do return
	thickness := border_pixels(frame, .Hairline)
	span := rect.width + rect.height
	step := span / f32(SCRIBBLE_STROKES_MAX + 1)
	if step <= 0 do return

	// The range is the bound: Tiger Style prefers a fixed `for _ in 1..=N` to
	// a counter precisely because the limit is then visible in the loop header
	// and needs no assertion to enforce it.
	for index in 1 ..= SCRIBBLE_STROKES_MAX {
		offset := step * f32(index)
		x0 := rect.x + max(offset - rect.height, 0)
		y0 := rect.y + min(offset, rect.height)
		x1 := rect.x + min(offset, rect.width)
		y1 := rect.y + max(offset - rect.width, 0)
		draw_line_ex(frame, {x0, y0}, {x1, y1}, thickness, color)
	}
}

// draw_tape_strip draws a piece of tape across a corner.
//
// Tape and the dog ear below are the two substitutes for rotating a card. A
// tilted card is unrepresentable here, but a tilted *strip* is two triangles,
// and it carries the same "placed by hand" reading without needing the label
// inside it to tilt as well.
// draw_tape_strip lays a band of tape diagonally across the top-left corner.
//
// Tape and the dog ear below are the two substitutes for rotating a card. A
// tilted card is unrepresentable here, but a tilted *strip* is two triangles,
// and it carries the same "placed by hand" reading without needing the label
// inside it to tilt as well.
//
// The geometry is a band centred on the corner diagonal, not a quad hung off
// the corner point. An earlier version offset each vertex by half the span
// independently, which produced a diamond floating outside the rect entirely -
// it read as a rendering fault rather than as tape. Building the band from the
// diagonal and its perpendicular keeps it symmetrical about the corner at any
// size.
draw_tape_strip :: proc(frame: ^Ui_Frame, rect: Rectangle, length: f32, color: Color) {
	assert(frame != nil, "draw_tape_strip: nil frame")
	assert(length >= 0, "draw_tape_strip: negative length")
	if rect.width <= 0 || rect.height <= 0 || color.a == 0 || length == 0 do return
	span := min(length, min(rect.width, rect.height))
	if span <= 0 do return

	// Unit vectors along the corner diagonal and across it. The diagonal runs
	// from the left edge up toward the top edge, so the tape reads as applied
	// from the lower left.
	DIAGONAL :: f32(0.70710678) // 1/sqrt(2): the 45-degree component
	along := Vector2{DIAGONAL, -DIAGONAL}
	across := Vector2{DIAGONAL, DIAGONAL}

	centre := Vector2{rect.x + span * 0.5, rect.y + span * 0.5}
	// Overhang the corner slightly so the tape appears to hold the sheet down
	// rather than to float on top of it.
	half_length := span * 0.85
	half_width := span * 0.28

	p0 := Vector2 {
		centre.x - along.x * half_length - across.x * half_width,
		centre.y - along.y * half_length - across.y * half_width,
	}
	p1 := Vector2 {
		centre.x + along.x * half_length - across.x * half_width,
		centre.y + along.y * half_length - across.y * half_width,
	}
	p2 := Vector2 {
		centre.x + along.x * half_length + across.x * half_width,
		centre.y + along.y * half_length + across.y * half_width,
	}
	p3 := Vector2 {
		centre.x - along.x * half_length + across.x * half_width,
		centre.y - along.y * half_length + across.y * half_width,
	}
	draw_triangle(frame, p0, p3, p2, color)
	draw_triangle(frame, p0, p2, p1, color)
}

// draw_dog_ear folds one corner of a page.
//
// Only the bottom-right corner is offered. A dog ear on an arbitrary corner
// would need the caller to reason about which edges the fold shades, and the
// fold only reads correctly when it sits opposite the reading direction.
draw_dog_ear :: proc(frame: ^Ui_Frame, rect: Rectangle, size: f32, fold, shade: Color) {
	assert(frame != nil, "draw_dog_ear: nil frame")
	assert(size >= 0, "draw_dog_ear: negative size")
	if rect.width <= 0 || rect.height <= 0 || size == 0 do return
	span := min(size, min(rect.width, rect.height))
	right := rect.x + rect.width
	bottom := rect.y + rect.height
	// The notch cut out of the page, then the folded flap over it.
	draw_triangle(frame, {right - span, bottom}, {right, bottom - span}, {right, bottom}, fold)
	draw_triangle(
		frame,
		{right - span, bottom},
		{right - span, bottom - span},
		{right, bottom - span},
		shade,
	)
}

// scatter_hash maps an index to a well-distributed 32-bit value.
//
// This is deliberately a pure function of the index rather than a random
// number generator, and that choice is load-bearing. Frames here are
// event-driven: the interface redraws when anything at all changes, so a
// stateful generator would deal a different sequence on every redraw and the
// paper grain would crawl while the user typed. It would also break the
// capture harness, whose output is expected to be byte-reproducible.
//
// The constants are the standard integer finalizer from MurmurHash3, chosen
// because it avalanches well at small indices, which is exactly the range a
// fleck field uses.
scatter_hash :: proc(index: u32) -> u32 {
	value := index
	value ~= value >> 16
	value *= 0x7feb352d
	value ~= value >> 15
	value *= 0x846ca68b
	value ~= value >> 16
	return value
}

// scatter_unit returns a deterministic value in [0, 1) for an index and a
// stream. The stream lets one index produce several independent coordinates -
// an x, a y and a size - without the three correlating into a diagonal line.
scatter_unit :: proc(index, stream: u32) -> f32 {
	raw := scatter_hash(index * 3 + stream)
	return f32(raw % 4096) / 4096
}

// draw_paper_tooth scatters flecks across a region to suggest the grain of
// toned drawing stock.
//
// This is the sketchbook's answer to ruled lines. Rules are for writing on;
// drawing paper is blank and shows its texture instead, so the substrate has
// to read as a surface rather than as a guide.
//
// The count scales with area so a small card is not as busy as a full page,
// but is hard-capped: a fleck field costs area, and a density that looks right
// on a laptop is sixteen times as expensive at 4K.
draw_paper_tooth :: proc(frame: ^Ui_Frame, rect: Rectangle, color: Color) {
	assert(frame != nil, "draw_paper_tooth: nil frame")
	if rect.width <= 0 || rect.height <= 0 || color.a == 0 do return

	// One fleck per this many square logical pixels. Sparse by design: grain
	// is felt rather than seen, and anything denser reads as noise or dirt.
	FLECK_AREA :: f32(2600)
	scale := max(ui_frame_scf(frame, 1), 0.001)
	logical_area := (rect.width / scale) * (rect.height / scale)
	count := int(logical_area / FLECK_AREA)
	count = clamp(count, 0, SUBSTRATE_FLECKS_MAX)
	if count == 0 do return

	size := max(border_pixels(frame, .Hairline), 1)
	for index in 0 ..< count {
		i := u32(index)
		x := rect.x + scatter_unit(i, 0) * rect.width
		y := rect.y + scatter_unit(i, 1) * rect.height
		// Two thirds of the flecks are single specks and a third are doubled,
		// which is what keeps the field from looking like a regular stipple.
		wide := size * 2 if scatter_unit(i, 2) > 0.66 else size
		draw_rectangle_rec(frame, {x, y, wide, size}, color)
	}
}

// WASH_BLEED_STRIPS is how many translucent overhang strips a pigment block
// lays past its own edge. Three is enough for the edge to read as soaked
// rather than cut; a fixed count keeps a large swatch exactly as expensive as
// a small one, which a proportional bleed would not.
WASH_BLEED_STRIPS :: 3

// draw_wash lays a pigment gradient that pools toward the bottom.
//
// Watercolour is not a flat fill: gravity and drying carry pigment downward,
// so a laid wash is lighter where it starts and denser where it settles. The
// renderer has exactly one gradient primitive and it happens to be vertical,
// which is the direction this effect needs.
draw_wash :: proc(frame: ^Ui_Frame, rect: Rectangle, pigment: Color) {
	assert(frame != nil, "draw_wash: nil frame")
	if rect.width <= 0 || rect.height <= 0 || pigment.a == 0 do return
	// The top is thinned toward the paper rather than toward white, so a wash
	// reads as pigment on stock rather than as a fade to nothing.
	//
	// Only slightly thinned. An earlier value of 0.72 let so much ground show
	// through that overlapping blocks read as stacked panes of tinted glass
	// rather than as paint: laid pigment covers its paper, and the density
	// difference between where a wash starts and where it pools is subtle.
	top := Color{pigment.r, pigment.g, pigment.b, u8(f32(pigment.a) * 0.88)}
	draw_rectangle_gradient_v(
		frame,
		i32(rect.x),
		i32(rect.y),
		i32(rect.width),
		i32(rect.height),
		top,
		pigment,
	)
}

// draw_pigment_block paints a swatch: a wash, plus a bleed past its edges.
//
// The bleed is the whole point. A filled rectangle reads as a table cell no
// matter what colour it is; paint stops unevenly, soaks past where the brush
// went, and darkens where it overlaps something already laid down. Drawing the
// bleed translucently means two adjacent blocks produce that darker seam for
// free, without either needing to know about the other.
//
// Cost is fixed: one wash plus WASH_BLEED_STRIPS * 2 strips plus two corner
// triangles, regardless of the swatch's size.
draw_pigment_block :: proc(frame: ^Ui_Frame, rect: Rectangle, pigment: Color) {
	assert(frame != nil, "draw_pigment_block: nil frame")
	if rect.width <= 0 || rect.height <= 0 || pigment.a == 0 do return
	draw_wash(frame, rect, pigment)

	step := max(border_pixels(frame, .Hairline), 1)
	for index in 1 ..= WASH_BLEED_STRIPS {
		// Each successive strip is fainter and reaches further, which is how
		// a soaked edge actually falls off.
		fade := f32(WASH_BLEED_STRIPS + 1 - index) / f32(WASH_BLEED_STRIPS + 1)
		alpha := u8(f32(pigment.a) * fade * 0.45)
		if alpha == 0 do continue
		wash := Color{pigment.r, pigment.g, pigment.b, alpha}
		reach := step * f32(index)
		// Bottom edge bleeds further than the top: pigment runs downhill.
		draw_rectangle_rec(frame, {rect.x, rect.y - reach, rect.width, reach}, wash)
		draw_rectangle_rec(
			frame,
			{rect.x, rect.y + rect.height + reach - step, rect.width, reach},
			wash,
		)
	}

	// Two soft corners, so the block is not a perfect rectangle. Opposite
	// corners rather than all four: a brush lifts somewhere, not everywhere.
	notch := min(rect.width, rect.height) * 0.18
	if notch <= 0 do return
	pale := Color{pigment.r, pigment.g, pigment.b, u8(f32(pigment.a) * 0.35)}
	draw_triangle(
		frame,
		{rect.x, rect.y},
		{rect.x + notch, rect.y},
		{rect.x, rect.y + notch},
		pale,
	)
	draw_triangle(
		frame,
		{rect.x + rect.width, rect.y + rect.height},
		{rect.x + rect.width - notch, rect.y + rect.height},
		{rect.x + rect.width, rect.y + rect.height - notch},
		pale,
	)
}

// CHALK_STROKES is how many strokes a highlight lays along a lit edge. Three
// gives a falloff without the cost scaling with the surface: a highlight on a
// full-width card costs exactly what one on a chip does.
CHALK_STROKES :: 3

// draw_chalk_highlight lays white gouache along the lit edge of a surface.
//
// This is the counterpart to draw_shadow_hard, and together they are why toned
// paper exists as a medium. A white ground can only be worked *darker*, so a
// form is built entirely from shadow. A toned ground can be worked in both
// directions - ink below it, chalk above it - which is how a sheet of kraft
// carries a lit edge and a cast shadow at the same time.
//
// Ignoring the light direction is what made the first toned palettes look like
// dimmed light themes: they were worked only darker, so the ground had to stay
// pale for the ink to have anywhere to go.
//
// A palette without chalk (every screen palette) zeroes the colour and this
// returns without drawing, matching how every other material opts out.
draw_chalk_highlight :: proc(frame: ^Ui_Frame, rect: Rectangle, radius: Radius) {
	assert(frame != nil, "draw_chalk_highlight: nil frame")
	assert(rect.width > 0 && rect.height > 0, "draw_chalk_highlight: empty rect")
	base := ui_frame_theme(frame).chalk
	if base.a == 0 do return

	thickness := border_pixels(frame, .Hairline)
	// The highlight is inset past the corner radius. Backend clips do not
	// nest, so a stroke running the full width would overhang a rounded corner
	// rather than following it - the same constraint btn_gloss works around.
	inset := radius_pixels(frame, radius, min(rect.width, rect.height))
	span := rect.width - inset * 2
	if span <= 0 do return

	for index in 0 ..< CHALK_STROKES {
		// Each stroke sits a little lower and fades, so the edge reads as a
		// soft lit band rather than as a drawn line.
		fade := f32(CHALK_STROKES - index) / f32(CHALK_STROKES)
		alpha := u8(f32(base.a) * fade * 0.5)
		if alpha == 0 do continue
		y := rect.y + thickness * f32(index)
		draw_line_ex(
			frame,
			{rect.x + inset, y},
			{rect.x + inset + span, y},
			thickness,
			Color{base.r, base.g, base.b, alpha},
		)
	}
}
