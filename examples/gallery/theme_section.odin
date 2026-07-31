// The Theme section, composed as a page rather than as a specification sheet.
//
// The earlier version of this file inventoried the token enums: seven stacked
// grids, an ALL-CAPS header on each, a bordered box around every cell, and a
// uniform header-grid-space cadence throughout. That is what a form looks like.
// A written page has almost no boxes - it has a margin, indentation,
// underlines and whitespace, and it lets alignment do the work the borders
// were doing.
//
// Three rules shape everything below, and the first is not negotiable:
//
//   1. Every vertical advance is a whole number of rule-heights. On ruled
//      paper this is the difference between a page and a background texture:
//      text sitting *between* two rules reads as a rendering fault, and a
//      near-miss looks worse than no rules at all.
//   2. Content hangs off the margin. Labels and measurements go in the margin
//      where an annotation belongs, not crammed inside the swatch they
//      describe.
//   3. The hand-drawn accents are spent, not sprinkled. One taped swatch, one
//      dog-eared card, one highlighter. Tape on everything is a scrapbook;
//      tape on one thing is composed.
//
// The state row is also the materials demo: Selected *is* a highlighter swipe
// and Pressed *is* a scribble, rather than a flat fill beside a caption
// claiming as much. The materials are therefore exercised on every frame
// instead of only in tests.
//
// Geometry here is application-owned and physical, like the Charts, Layout and
// Stress sections. That is a deliberate choice rather than a shortcut: the
// facade's slot_next takes *logical* units and scales them per call, and
// scaling is not distributive over rounding - at 1.25x scale a two-line slot
// resolves to 55 physical pixels while two one-line rules resolve to 56. A
// facade-built page would drift a pixel off its own rules at some scales,
// which is precisely the defect the baseline grid exists to prevent. Advancing
// by the already-scaled metric keeps text and rules exact at every scale.
package main

import "core:fmt"
import "ingot:ui"

// Column geometry in logical pixels; everything horizontal is expressed
// against these so the page has one measure rather than per-section widths.
LABEL_COL_W :: 118
CHIP_W :: 96
SWATCH_W :: CHIP_W * 2

// The specimen sentence. A pangram earns its place in a type specimen: it puts
// every letter in front of the reader, which is the one thing a specimen does.
SPECIMEN :: "Sphinx of black quartz, judge my vow"

// Page is the writing cursor: a physical-pixel position on the ruled grid.
//
// It replaces the ad-hoc row heights the previous version used (30, 34, 40, 44
// and 52 - none of them related to LINE_HEIGHT, so nothing landed on a rule).
Page :: struct {
	frame:  ^ui.Ui_Frame,
	x:      i32, // Left edge of the page, physical.
	y:      i32, // Current baseline, physical. Advances only through page_line.
	w:      i32, // Page width, physical.
	indent: i32, // Body inset clear of the margin rule, physical.
	line:   i32, // One rule-height, physical. The grid unit.
}

page_begin :: proc(frame: ^ui.Ui_Frame, x, y, w: i32) -> Page {
	assert(frame != nil, "page_begin: nil frame")
	assert(w > 0, "page_begin: non-positive width")
	line := ui.ui_frame_metrics(frame).LINE_HEIGHT
	assert(line > 0, "page_begin: metrics carry a non-positive line height")
	return {frame = frame, x = x, y = y, w = w, indent = page_indent(frame), line = line}
}

// page_line consumes `count` rule-heights and returns the row it occupied.
//
// The single place the cursor moves. Because it advances by whole multiples of
// the already-scaled metric, a row's top always coincides with a rule.
page_line :: proc(page: ^Page, count: i32) -> ui.Rect_I32 {
	assert(page != nil, "page_line: nil page")
	assert(count > 0, "page_line: non-positive line count")
	row := ui.Rect_I32{page.x, page.y, page.w, page.line * count}
	page.y += page.line * count
	return row
}

// page_body returns the left edge of body content: clear of the margin rule
// when the palette draws one, flush with the page when it does not.
page_body :: proc(page: ^Page) -> i32 {
	assert(page != nil, "page_body: nil page")
	return page.x + page.indent
}

// page_indent resolves the body inset for the active palette.
page_indent :: proc(frame: ^ui.Ui_Frame) -> i32 {
	assert(frame != nil, "page_indent: nil frame")
	theme := ui.ui_frame_theme(frame)
	if theme.substrate.kind == .None || !theme.substrate.margin do return 0
	// Clear of the rule by a hair, so the writing does not touch it.
	return ui.ui_frame_sc(frame, MARGIN_INSET + 10)
}

// annotate writes a right-aligned note in the margin beside a row.
//
// This is what a margin is for. The contrast ratios and pixel sizes it carries
// used to be crammed inside each swatch as a second line of tiny text, which
// is both harder to read and the reason every swatch had to be a box tall
// enough to hold two lines.
annotate :: proc(page: ^Page, row: ui.Rect_I32, note: string) {
	assert(page != nil, "annotate: nil page")
	if len(note) == 0 || page.indent == 0 do return
	width := ui.text_width(page.frame, note, .Note)
	gap := ui.ui_frame_sc(page.frame, 8)
	x := page.x + page.indent - width - gap
	if x < page.x do return
	ui.text(page.frame, note, x, row.y, .Note, .Muted)
}

// page_heading writes a heading with a hand-drawn underline sized to the words
// rather than to the column.
//
// A rule running the full width reads as a border - the eye takes it as the
// top edge of whatever follows. One that stops where the text stops reads as
// something a person drew.
page_heading :: proc(page: ^Page, title: string) {
	assert(page != nil, "page_heading: nil page")
	row := page_line(page, 1)
	ui.text(page.frame, title, page_body(page), row.y, .Title, .Heading)

	theme := ui.ui_frame_theme(page.frame)
	// On a paper palette the underline is ink; a screen palette has no pen, so
	// it falls back to the ordinary hairline colour.
	color := theme.paper_margin if theme.paper_margin.a > 0 else theme.border_subtle
	ui.draw_hand_underline(
		page.frame,
		page_body(page),
		row.y + row.h - ui.ui_frame_sc(page.frame, 5),
		ui.text_width(page.frame, title, .Title),
		color,
	)
	page_line(page, 1)
}

draw_theme_section :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	assert(frame != nil, "draw_theme_section: nil frame")
	page := page_begin(frame, x, y0, w)

	draw_page_opening(&page)
	draw_surface_states(&page)
	draw_ink_chips(&page)
	draw_taped_accent(&page)
	draw_type_specimen(&page)
	draw_shape_notes(&page)
	draw_measure_notes(&page)

	return page.y
}

// The opening: title, underline, and one line of orienting prose. One
// sentence, not a paragraph - a note to yourself is short.
draw_page_opening :: proc(page: ^Page) {
	assert(page != nil, "draw_page_opening: nil page")
	page_heading(page, "Design tokens")
	row := page_line(page, 1)
	ui.text(
		page.frame,
		"every value below resolves from the active palette",
		page_body(page),
		row.y,
		.Body,
		.Secondary,
	)
	page_line(page, 1)
}

// state_cell_width divides the space right of the label column between the
// states. Separate so the heading row and the body rows cannot disagree about
// column width, which is the drift that puts a heading over the wrong column.
state_cell_width :: proc(page: ^Page, label_w: i32) -> i32 {
	assert(page != nil, "state_cell_width: nil page")
	count := i32(len(ui.Visual_State))
	gap := ui.ui_frame_sc(page.frame, 6)
	available := page.w - page.indent - label_w - gap * (count - 1)
	minimum := ui.ui_frame_sc(page.frame, 38)
	// Capped rather than filling the column. A cell stretched across the whole
	// page turns the highlighter into a 190-pixel band over 20 pixels of text,
	// which reads as a fill rather than as a mark someone made.
	maximum := ui.ui_frame_sc(page.frame, 76)
	if available < minimum * count do return minimum
	return min(available / count, maximum)
}

// Surfaces and their states, one band per surface.
//
// This is both the state matrix and the materials demo. Selected renders as a
// marker swipe and Pressed as a scribble, because a token whose whole job is
// to describe an appearance should be shown in it rather than labelled with it.
draw_surface_states :: proc(page: ^Page) {
	assert(page != nil, "draw_surface_states: nil page")
	page_heading(page, "Surfaces")

	label_w := ui.ui_frame_sc(page.frame, LABEL_COL_W)
	gap := ui.ui_frame_sc(page.frame, 6)
	cell_w := state_cell_width(page, label_w)
	body := page_body(page)
	// Cells are inset vertically so consecutive rows do not touch. Without
	// this, thirteen highlighter swipes stack into one continuous yellow
	// column with a sawtooth edge - it reads as a rendering fault rather than
	// as thirteen separate marks.
	inset := ui.ui_frame_sc(page.frame, 2)

	// The key sits on its own line in the muted ink an annotation uses, so it
	// reads as a legend rather than as content.
	head := page_line(page, 1)
	for state, index in ui.Visual_State {
		x := body + label_w + i32(index) * (cell_w + gap)
		ui.text(page.frame, fmt.tprint(state), x, head.y, .Note, .Muted)
	}

	for surface in ui.Surface {
		row := page_line(page, 1)
		ui.text_truncated(
			page.frame,
			fmt.tprint(surface),
			body,
			row.y,
			label_w - gap,
			.Note,
			.Secondary,
		)
		for state, index in ui.Visual_State {
			cell := ui.Rectangle {
				f32(body + label_w + i32(index) * (cell_w + gap)),
				f32(row.y + inset),
				f32(cell_w),
				f32(page.line - inset * 2),
			}
			draw_state_cell(page.frame, cell, surface, state)
		}
	}
	page_line(page, 1)
}

// draw_state_cell paints one surface in one state, using the material that
// state actually means.
draw_state_cell :: proc(
	frame: ^ui.Ui_Frame,
	cell: ui.Rectangle,
	surface: ui.Surface,
	state: ui.Visual_State,
) {
	assert(frame != nil, "draw_state_cell: nil frame")
	theme := ui.ui_frame_theme(frame)
	colors := ui.surface_colors(frame, surface, state)

	switch state {
	case .Selected:
		// A highlighter is how a person marks a selection on paper. A screen
		// palette has no marker, so the ordinary selected fill stands in.
		if theme.highlighter.a > 0 {
			ui.draw_highlight_swipe(frame, cell, theme.highlighter)
		} else {
			ui.draw_surface(frame, cell, surface, state, .SM, .None, .Flat)
		}
	case .Pressed:
		// Pressed is a scribble over the resting surface: the mark you make
		// while pushing on something, not a different colour of paint.
		ui.draw_surface(frame, cell, surface, .Rest, .SM, .None, .Flat)
		ui.draw_scribble_fill(frame, cell, colors.bg)
	case .Rest, .Hover, .Disabled:
		ui.draw_surface(frame, cell, surface, state, .SM, .None, .Flat)
	}

	// "Ag" carries an ascender and a descender, so a fill that clips text or a
	// rule that cuts through it shows up here rather than hiding behind an
	// all-caps sample.
	ui.text(frame, "Ag", i32(cell.x) + ui.ui_frame_sc(frame, 5), i32(cell.y), .Note, .Primary)
}

// legible_on picks whichever of the palette's two extreme inks reads better on
// a given fill.
//
// A swatch labelled in a fixed colour is only readable across half a palette:
// the dark inks disappear into their own chips and the light ones into the
// pale chips, which looks like a rendering fault rather than a swatch. Picking
// per chip is also the honest demonstration, since it is what any real
// interface has to do when it puts text on an arbitrary fill.
legible_on :: proc(frame: ^ui.Ui_Frame, fill: ui.Color) -> ui.Ink {
	assert(frame != nil, "legible_on: nil frame")
	dark := ui.text_ink(frame, .Primary)
	light := ui.text_ink(frame, .Inverse)
	if ui.contrast_ratio(light, fill) > ui.contrast_ratio(dark, fill) do return .Inverse
	return .Primary
}

// Every ink as a paint chip, with the row's worst contrast in the margin.
//
// No borders: a run of unboxed colour chips is how a paint card is laid out,
// and a fill is its own boundary.
draw_ink_chips :: proc(page: ^Page) {
	assert(page != nil, "draw_ink_chips: nil page")
	page_heading(page, "Ink")

	chip_w := ui.ui_frame_sc(page.frame, CHIP_W)
	gap := ui.ui_frame_sc(page.frame, 6)
	card := ui.surface_colors(page.frame, .Card, .Rest)
	body := page_body(page)
	per_row := max((page.w - page.indent) / (chip_w + gap), 1)
	inset := ui.ui_frame_sc(page.frame, 2)

	row := page_line(page, 1)
	column := i32(0)
	worst := f64(21)
	for ink in ui.Ink {
		if column >= per_row {
			annotate(page, row, fmt.tprintf("min %.1f:1", worst))
			row = page_line(page, 1)
			column = 0
			worst = 21
		}
		color := ui.text_ink(page.frame, ink)
		ratio := ui.contrast_ratio(color, card.bg)
		if ratio < worst do worst = ratio

		cell := ui.Rectangle {
			f32(body + column * (chip_w + gap)),
			f32(row.y + inset),
			f32(chip_w),
			f32(page.line - inset * 2),
		}
		ui.draw_rectangle_rec(page.frame, cell, color)
		// The label is drawn in whichever of the page's two extreme inks reads
		// better *on this chip*, rather than always in Primary. A fixed label
		// colour left half the row unreadable - the dark inks vanished into
		// their own chips, which looked like a bug rather than a swatch.
		ui.text_truncated(
			page.frame,
			fmt.tprint(ink),
			i32(cell.x) + ui.ui_frame_sc(page.frame, 4),
			i32(cell.y),
			chip_w - ui.ui_frame_sc(page.frame, 8),
			.Note,
			legible_on(page.frame, color),
		)
		column += 1
	}
	annotate(page, row, fmt.tprintf("min %.1f:1", worst))
	page_line(page, 1)
}

// The one taped item on the page: the accent colour, tape over its corner,
// hex in the margin.
//
// Exactly one. A page where everything is taped down is a scrapbook; a page
// with a single taped swatch reads as something a person placed deliberately.
draw_taped_accent :: proc(page: ^Page) {
	assert(page != nil, "draw_taped_accent: nil page")
	theme := ui.ui_frame_theme(page.frame)
	if theme.tape_color.a == 0 do return

	row := page_line(page, 2)
	accent := theme.fg_accent
	swatch := ui.Rectangle {
		f32(page_body(page)),
		f32(row.y),
		f32(ui.ui_frame_sc(page.frame, SWATCH_W)),
		f32(row.h - ui.ui_frame_sc(page.frame, 6)),
	}
	ui.draw_shadow_hard(page.frame, swatch, .SM, .Lifted)
	ui.draw_rectangle_rec(page.frame, swatch, accent)
	ui.draw_tape_strip(page.frame, swatch, f32(ui.ui_frame_sc(page.frame, 26)), theme.tape_color)
	annotate(page, row, fmt.tprintf("#%02X%02X%02X", accent.r, accent.g, accent.b))
	page_line(page, 1)
}

// The four type roles, each a specimen on its own baseline with the resolved
// pixel size in the margin.
//
// The size used to be part of the sample string ("Body 16px - Sphinx of..."),
// which is not a specimen: a specimen shows the face, and the measurement is
// an annotation about it.
draw_type_specimen :: proc(page: ^Page) {
	assert(page != nil, "draw_type_specimen: nil page")
	page_heading(page, "Type")
	for role in ui.Text_Role {
		// Title is taller than one rule, so it takes two and stays on grid.
		count := i32(1)
		if ui.text_role_line_height(page.frame, role) > page.line do count = 2
		row := page_line(page, count)
		ui.text_truncated(
			page.frame,
			SPECIMEN,
			page_body(page),
			row.y,
			page.w - page.indent,
			role,
			.Primary,
		)
		annotate(page, row, fmt.tprintf("%v %dpx", role, ui.text_role_size(page.frame, role)))
	}
	page_line(page, 1)
}

// Radius and elevation together on one dog-eared card.
//
// The fold and the hard shadow belong in the same exhibit because they are the
// same idea: a sheet lifted off the page has both a shadow and a corner you
// can turn.
draw_shape_notes :: proc(page: ^Page) {
	assert(page != nil, "draw_shape_notes: nil page")
	page_heading(page, "Shape")

	theme := ui.ui_frame_theme(page.frame)
	row := page_line(page, 3)
	card := ui.Rectangle {
		f32(page_body(page)),
		f32(row.y),
		f32(ui.ui_frame_sc(page.frame, 150)),
		f32(row.h - ui.ui_frame_sc(page.frame, 8)),
	}
	ui.draw_surface(page.frame, card, .Card, .Rest, .MD, .Hairline, .Lifted)
	// A card is a smaller sheet, and a bounded one - the only place a dot grid
	// is affordable, since it costs area rather than height. The dots take the
	// margin ink, not the rule ink: rules are pale by design because text sits
	// on them, and a one-pixel dot at that alpha is invisible.
	if theme.paper_margin.a > 0 {
		spacing := page.line / 2
		if ui.dot_grid_fits(card, spacing) {
			ui.draw_dot_grid(page.frame, card, spacing, theme.paper_margin)
		}
	}
	ui.draw_dog_ear(
		page.frame,
		card,
		f32(ui.ui_frame_sc(page.frame, 14)),
		theme.bg_app,
		theme.border_subtle,
	)
	ui.text(
		page.frame,
		"Lifted",
		i32(card.x) + ui.ui_frame_sc(page.frame, 10),
		i32(card.y) + ui.ui_frame_sc(page.frame, 4),
		.Note,
		.Secondary,
	)
	annotate(page, row, "card")

	// The radii as an unboxed run beside the card: filled blocks with no
	// border, so the corner is the only thing that differs between them.
	block_x := i32(card.x + card.width) + ui.ui_frame_sc(page.frame, 16)
	block_w := ui.ui_frame_sc(page.frame, 52)
	gap := ui.ui_frame_sc(page.frame, 8)
	for radius, index in ui.Radius {
		block := ui.Rectangle {
			f32(block_x + i32(index) * (block_w + gap)),
			card.y,
			f32(block_w),
			f32(page.line * 2),
		}
		if block.x + block.width > f32(page.x + page.w) do break
		ui.draw_surface(page.frame, block, .Chip, .Rest, radius, .None, .Flat)
		ui.text(
			page.frame,
			fmt.tprint(radius),
			i32(block.x) + ui.ui_frame_sc(page.frame, 4),
			i32(block.y) + page.line * 2,
			.Note,
			.Muted,
		)
	}
	page_line(page, 1)
}

// Spacing and tint as indented runs hanging off the margin.
draw_measure_notes :: proc(page: ^Page) {
	assert(page != nil, "draw_measure_notes: nil page")
	page_heading(page, "Measure")

	theme := ui.ui_frame_theme(page.frame)
	bar_h := ui.ui_frame_sc(page.frame, 10)
	body := page_body(page)
	for space in ui.Space {
		row := page_line(page, 1)
		width := ui.space_pixels(page.frame, space)
		// A zero-width token still needs a visible row, or None reads as a
		// missing entry rather than as a deliberate zero.
		ui.draw_rectangle(
			page.frame,
			body,
			row.y + ui.ui_frame_sc(page.frame, 5),
			max(width, 1),
			bar_h,
			theme.fg_accent,
		)
		annotate(page, row, fmt.tprintf("%v %dpx", space, width))
	}
	page_line(page, 1)

	for tint in ui.Tint {
		row := page_line(page, 1)
		bar := ui.Rectangle {
			f32(body),
			f32(row.y + ui.ui_frame_sc(page.frame, 3)),
			f32(ui.ui_frame_sc(page.frame, SWATCH_W)),
			f32(page.line - ui.ui_frame_sc(page.frame, 6)),
		}
		ui.draw_rectangle_rec(page.frame, bar, ui.color_tinted(theme.fg_accent, tint))
		annotate(page, row, fmt.tprintf("%v %d", tint, ui.tint_alpha(tint)))
	}
	page_line(page, 1)
}
