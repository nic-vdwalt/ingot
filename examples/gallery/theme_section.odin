// The Theme section as a sketchbook colour study.
//
// This replaced two earlier attempts, and what each got wrong is worth
// recording because it shaped what is here.
//
// The first was a specification sheet: seven stacked grids, ALL-CAPS headers,
// a bordered box around every cell. That is what a form looks like, not a
// designed page.
//
// The second was ruled writing paper - and the rules turned out to be driving
// everything else. A baseline grid exists to sit text on, so every swatch had
// to shrink to row height or break the rhythm, and the colour ended up as a
// table of samples rather than as the subject. Writing paper was simply the
// wrong reference: a sketchbook is *drawing* paper, blank and toned, showing
// grain instead of lines.
//
// So: no rules, no margin line, and blocks sized by what they show. Three
// things carry over from the ruled version because they were right
// independently of the paper - the reserved margin column for annotations, the
// per-chip legible label, and spending the hand-drawn accents sparingly rather
// than sprinkling them.
//
// Placement jitter comes from legacy.scatter_unit, a pure hash of the item index.
// Frames here are event-driven, so an RNG would deal a new layout on every
// unrelated redraw and the page would crawl while the user typed; it would
// also break the capture harness, whose output must be byte-reproducible.
package main

import "core:fmt"
import legacy "ingot:fit"

// Column geometry in design units. Everything horizontal is expressed against
// these so the page has one measure rather than per-section widths.
LABEL_COL_W :: 118
CHIP_W :: 96
SWATCH_W :: CHIP_W * 2

// The specimen sentence. A pangram earns its place in a type specimen: it puts
// every letter in front of the reader, which is the one thing a specimen does.
SPECIMEN :: "Sphinx of black quartz, judge my vow"

// Pigment_Study names one entry in the opening colour study. The pigments are
// the palette's own roles rather than a separate table, so a retheme repaints
// the study instead of leaving it showing stale colours.
//
// The blocks read the *pigment* table, not the ink table. That is the whole
// point of the split: pigments are paint and stay saturated, while the labels
// beside them are ink and stay legible. Reading inks here is what tied the
// study to the text-contrast bar and forced the grounds pale.
//
// The label names the role rather than the pigment, because the role is true
// on every palette. On the sketch palettes Pigment.Accent is ultramarine; on
// high contrast there is no pigment table at all and theme_pigment falls back
// to gold. A block captioned "ultramarine" while rendering yellow is simply
// wrong, so the pigment names are a secondary row shown only where they apply.
PIGMENT_ROLES := [legacy.Pigment]string {
	.Accent  = "accent",
	.Danger  = "danger",
	.Success = "success",
	.Tool    = "tool",
	.Earth   = "earth",
	.Leaf    = "leaf",
}

PIGMENT_NAMES := [legacy.Pigment]string {
	.Accent  = "ultramarine",
	.Danger  = "vermilion",
	.Success = "viridian",
	.Tool    = "yellow ochre",
	.Earth   = "burnt sienna",
	.Leaf    = "sap green",
}

// Page is the writing cursor: a physical-pixel position that flows downward.
//
// The strict baseline grid the ruled version used is gone with the rules it
// served. What remains is a bounded cursor, so content still cannot escape the
// pane, but a block may be any height its content needs.
Page :: struct {
	frame:  ^legacy.Ui_Frame,
	x:      i32, // Left edge of the page, physical.
	y:      i32, // Current write position, physical. Moves only via page_advance.
	w:      i32, // Page width, physical.
	indent: i32, // Body inset, reserving the annotation column. Physical.
	line:   i32, // One line height, physical. The unit for text rows.
}

page_begin :: proc(frame: ^legacy.Ui_Frame, x, y, w: i32) -> Page {
	assert(frame != nil, "page_begin: nil frame")
	assert(w > 0, "page_begin: non-positive width")
	line := legacy.ui_frame_metrics(frame).LINE_HEIGHT
	assert(line > 0, "page_begin: metrics carry a non-positive line height")
	return {frame = frame, x = x, y = y, w = w, indent = page_indent(frame), line = line}
}

// page_advance consumes `height` screen-space pixels and returns the block.
//
// The single place the cursor moves, which is what keeps a loose layout from
// becoming an unbounded one.
page_advance :: proc(page: ^Page, height: i32) -> legacy.Rect_I32 {
	assert(page != nil, "page_advance: nil page")
	assert(height > 0, "page_advance: non-positive height")
	block := legacy.Rect_I32{page.x, page.y, page.w, height}
	page.y += height
	return block
}

// page_rows advances a whole number of text lines. Text still wants a line
// rhythm even on unruled paper; only the graphics are free-form.
page_rows :: proc(page: ^Page, count: i32) -> legacy.Rect_I32 {
	assert(page != nil, "page_rows: nil page")
	assert(count > 0, "page_rows: non-positive row count")
	return page_advance(page, page.line * count)
}

// page_body returns the left edge of body content, clear of the annotation
// column.
page_body :: proc(page: ^Page) -> i32 {
	assert(page != nil, "page_body: nil page")
	return page.x + page.indent
}

// page_indent resolves the body inset for the active palette.
//
// It keys off having a substrate at all, not off the margin *rule*. Those were
// one flag until this revision, which made "keep the reserved column, drop the
// line" impossible to express - and the column is what keeps measurements out
// of the swatches they describe.
page_indent :: proc(frame: ^legacy.Ui_Frame) -> i32 {
	assert(frame != nil, "page_indent: nil frame")
	if legacy.ui_frame_theme(frame).substrate.kind == .None do return 0
	return legacy.ui_frame_sc(frame, MARGIN_INSET + 10)
}

// annotate writes a right-aligned note in the reserved margin column.
annotate :: proc(page: ^Page, row: legacy.Rect_I32, note: string) {
	assert(page != nil, "annotate: nil page")
	if len(note) == 0 || page.indent == 0 do return
	width := legacy.text_width(page.frame, note, .Note)
	gap := legacy.ui_frame_sc(page.frame, 8)
	x := page.x + page.indent - width - gap
	if x < page.x do return
	legacy.text(page.frame, note, x, row.y, .Note, .Muted)
}

// page_heading writes a heading underlined in pencil, sized to the words
// rather than to the column.
//
// A rule running the full width reads as a border - the eye takes it as the
// top edge of whatever follows. One that stops where the text stops reads as
// a mark someone made.
page_heading :: proc(page: ^Page, title: string) {
	assert(page != nil, "page_heading: nil page")
	row := page_rows(page, 1)
	legacy.text(page.frame, title, page_body(page), row.y, .Title, .Heading)

	theme := legacy.ui_frame_theme(page.frame)
	color := theme.graphite if theme.graphite.a > 0 else theme.border_subtle
	legacy.draw_hand_underline(
		page.frame,
		page_body(page),
		row.y + row.h - legacy.ui_frame_sc(page.frame, 5),
		legacy.text_width(page.frame, title, .Title),
		color,
	)
	page_rows(page, 1)
}

draw_theme_section :: proc(frame: ^legacy.Ui_Frame, x, y0, w: i32) -> i32 {
	assert(frame != nil, "draw_theme_section: nil frame")
	page := page_begin(frame, x, y0, w)

	draw_page_opening(&page)
	draw_pigment_studies(&page)
	draw_surface_states(&page)
	draw_ink_chips(&page)
	draw_taped_accent(&page)
	draw_type_specimen(&page)
	draw_shape_notes(&page)
	draw_measure_notes(&page)

	return page.y
}

// The opening: title, underline, one line of orienting prose.
draw_page_opening :: proc(page: ^Page) {
	assert(page != nil, "draw_page_opening: nil page")
	page_heading(page, "Design tokens")
	row := page_rows(page, 1)
	legacy.text(
		page.frame,
		"every value below resolves from the active palette",
		page_body(page),
		row.y,
		.Body,
		.Secondary,
	)
	page_rows(page, 1)
}

// The colour study: pigments laid as overlapping painted blocks.
//
// This is the page's subject, so it comes first and takes the most room. The
// blocks vary in size and sit at hash-derived offsets, and they deliberately
// overlap - draw_pigment_block bleeds translucently past its own edge, so an
// overlap produces the darker seam that reads as paint rather than as two
// rectangles that happen to touch.
draw_pigment_studies :: proc(page: ^Page) {
	assert(page != nil, "draw_pigment_studies: nil page")
	page_heading(page, "Pigments")

	body := page_body(page)
	available := page.w - page.indent
	count := i32(len(legacy.Pigment))
	// Blocks are wider than their pitch so they overlap, which is where the
	// bleed produces its darker seam. That means the last block extends past
	// the last pitch step, so the pitch is solved from the *total* width the
	// row will actually occupy - laying them on available/count and then
	// widening each one is what ran the last pigment off the page.
	//
	// The overlap is an edge, not a third of the block. A heavy overlap made
	// the row read as stacked panes of tinted glass rather than as swatches
	// laid down beside one another.
	OVERLAP :: f32(1.06)
	span := f32(available) - f32(legacy.ui_frame_sc(page.frame, 4))
	pitch := i32(span / (f32(count - 1) + OVERLAP))
	block_w := f32(pitch) * OVERLAP
	band_h := page.line * 4
	band := page_advance(page, band_h + page.line)

	style := legacy.ui_frame_theme(page.frame)
	for pigment_role, index in legacy.Pigment {
		i := u32(index)
		// The pigment table, not the ink table. Paint stays saturated; the
		// labels below stay legible because they are ink.
		pigment := legacy.theme_pigment(style, pigment_role)
		// Bounded jitter: enough that the row is not a ruler, small enough
		// that nothing escapes its slot or collides with the label below.
		wobble_x := (legacy.scatter_unit(i, 0) - 0.5) * f32(page.line) * 0.5
		wobble_y := (legacy.scatter_unit(i, 1) - 0.5) * f32(page.line) * 0.6
		height := f32(band_h) * (0.72 + legacy.scatter_unit(i, 2) * 0.28)

		block := legacy.legacy_rect {
			f32(body + i32(index) * pitch) + wobble_x,
			f32(band.y) + wobble_y,
			block_w,
			height,
		}
		legacy.draw_pigment_block(page.frame, block, pigment)
		// One block carries a chalk highlight, so the two-direction working
		// that toned paper exists for is visible in the exhibit that is about
		// colour. Only one: a lit edge on every block reads as a gloss.
		if index == 0 do legacy.draw_chalk_highlight(page.frame, block, .None)
	}

	// Names sit under the band rather than on the paint: a label on a wash is
	// unreadable at whatever alpha the wash happens to be.
	//
	// The role goes under each block because that is what the colour actually
	// is on any palette. The pigment names are a single note in the margin,
	// since they describe the sketch palettes rather than the swatches on
	// screen - on high contrast these same roles resolve to gold and white.
	label_row := page_rows(page, 1)
	for pigment_role, index in legacy.Pigment {
		legacy.text_truncated(
			page.frame,
			PIGMENT_ROLES[pigment_role],
			body + i32(index) * pitch,
			label_row.y,
			pitch - legacy.ui_frame_sc(page.frame, 4),
			.Note,
			.Secondary,
		)
	}

	// The pigment names only under a sketch palette, in muted ink so they read
	// as a caption rather than as a second set of labels. On a screen palette
	// they would be a lie: Ink.Accent is gold there, not ultramarine.
	if legacy.ui_frame_theme(page.frame).substrate.kind != .None {
		pigment_row := page_rows(page, 1)
		for pigment_role, index in legacy.Pigment {
			legacy.text_truncated(
				page.frame,
				PIGMENT_NAMES[pigment_role],
				body + i32(index) * pitch,
				pigment_row.y,
				pitch - legacy.ui_frame_sc(page.frame, 4),
				.Note,
				.Muted,
			)
		}
		annotate(page, pigment_row, "pigments")
	}
	page_rows(page, 1)
}

// state_cell_width divides the space right of the label column between the
// states. Separate so the key row and the body rows cannot disagree about
// column width, which is the drift that puts a heading over the wrong column.
state_cell_width :: proc(page: ^Page, label_w: i32) -> i32 {
	assert(page != nil, "state_cell_width: nil page")
	count := i32(len(legacy.Visual_State))
	gap := legacy.ui_frame_sc(page.frame, 6)
	available := page.w - page.indent - label_w - gap * (count - 1)
	minimum := legacy.ui_frame_sc(page.frame, 38)
	// Capped rather than filling the column: a cell stretched across the whole
	// page turns the highlighter into a band over a few pixels of text, which
	// reads as a fill rather than as a mark.
	maximum := legacy.ui_frame_sc(page.frame, 76)
	if available < minimum * count do return minimum
	return min(available / count, maximum)
}

// Surfaces and their states, one band per legacy.
//
// The one exhibit that earns a grid: it is a matrix, and reading down a column
// or across a row is the point. It is also the materials demo - Selected *is*
// a highlighter swipe and Pressed *is* a scribble, so both run every frame
// rather than only in tests.
draw_surface_states :: proc(page: ^Page) {
	assert(page != nil, "draw_surface_states: nil page")
	page_heading(page, "Surfaces")

	label_w := legacy.ui_frame_sc(page.frame, LABEL_COL_W)
	gap := legacy.ui_frame_sc(page.frame, 6)
	cell_w := state_cell_width(page, label_w)
	body := page_body(page)
	// Cells are inset vertically so consecutive rows do not touch. Without it,
	// thirteen highlighter swipes stack into one continuous column with a
	// sawtooth edge - a rendering fault rather than thirteen marks.
	inset := legacy.ui_frame_sc(page.frame, 2)

	head := page_rows(page, 1)
	for state, index in legacy.Visual_State {
		x := body + label_w + i32(index) * (cell_w + gap)
		legacy.text(page.frame, fmt.tprint(state), x, head.y, .Note, .Muted)
	}

	for surface in legacy.Surface_Kind {
		row := page_rows(page, 1)
		legacy.text_truncated(
			page.frame,
			fmt.tprint(surface),
			body,
			row.y,
			label_w - gap,
			.Note,
			.Secondary,
		)
		for state, index in legacy.Visual_State {
			cell := legacy.legacy_rect {
				f32(body + label_w + i32(index) * (cell_w + gap)),
				f32(row.y + inset),
				f32(cell_w),
				f32(page.line - inset * 2),
			}
			draw_state_cell(page.frame, cell, surface, state)
		}
	}
	page_rows(page, 1)
}

// draw_state_cell paints one surface in one state, using the material that
// state actually means.
draw_state_cell :: proc(
	frame: ^legacy.Ui_Frame,
	cell: legacy.legacy_rect,
	surface: legacy.Surface_Kind,
	state: legacy.Visual_State,
) {
	assert(frame != nil, "draw_state_cell: nil frame")
	theme := legacy.ui_frame_theme(frame)
	colors := legacy.surface_colors(frame, surface, state)

	switch state {
	case .Selected:
		// A highlighter is how a person marks a selection on paper. A screen
		// palette has no marker, so the ordinary selected fill stands in.
		if theme.highlighter.a > 0 {
			legacy.draw_highlight_swipe(frame, cell, theme.highlighter)
		} else {
			legacy.draw_surface(frame, cell, surface, state, .SM, .None, .Flat)
		}
	case .Pressed:
		// Pressed is a scribble over the resting surface: the mark you make
		// while pushing on something, not a different colour of paint.
		legacy.draw_surface(frame, cell, surface, .Rest, .SM, .None, .Flat)
		legacy.draw_scribble_fill(frame, cell, colors.bg)
	case .Rest, .Hover, .Disabled:
		legacy.draw_surface(frame, cell, surface, state, .SM, .None, .Flat)
	}

	// "Ag" carries an ascender and a descender, so a fill that clips text
	// shows up here rather than hiding behind an all-caps sample.
	legacy.text(
		frame,
		"Ag",
		i32(cell.x) + legacy.ui_frame_sc(frame, 5),
		i32(cell.y),
		.Note,
		.Primary,
	)
}

// legible_on picks whichever of the palette's two extreme inks reads better on
// a given fill.
//
// A swatch labelled in a fixed colour is only readable across half a palette:
// the dark inks disappear into their own chips and the light ones into the
// pale chips, which looks like a rendering fault rather than a swatch.
legible_on :: proc(frame: ^legacy.Ui_Frame, fill: legacy.legacy_color) -> legacy.legacy_ink {
	assert(frame != nil, "legible_on: nil frame")
	dark := legacy.text_ink(frame, .Primary)
	light := legacy.text_ink(frame, .Inverse)
	if legacy.contrast_ratio(light, fill) > legacy.contrast_ratio(dark, fill) do return .Inverse
	return .Primary
}

// Every ink as a painted chip, with the row's worst contrast in the margin.
//
// Washes rather than flat fills: a filled rectangle reads as a table cell no
// matter what colour it holds.
draw_ink_chips :: proc(page: ^Page) {
	assert(page != nil, "draw_ink_chips: nil page")
	page_heading(page, "Ink")

	chip_w := legacy.ui_frame_sc(page.frame, CHIP_W)
	gap := legacy.ui_frame_sc(page.frame, 6)
	card := legacy.surface_colors(page.frame, .Card, .Rest)
	body := page_body(page)
	per_row := max((page.w - page.indent) / (chip_w + gap), 1)
	inset := legacy.ui_frame_sc(page.frame, 2)

	row := page_rows(page, 1)
	column := i32(0)
	worst := f64(21)
	for ink in legacy.legacy_ink {
		if column >= per_row {
			annotate(page, row, fmt.tprintf("min %.1f:1", worst))
			row = page_rows(page, 1)
			column = 0
			worst = 21
		}
		color := legacy.text_ink(page.frame, ink)
		ratio := legacy.contrast_ratio(color, card.bg)
		if ratio < worst do worst = ratio

		cell := legacy.legacy_rect {
			f32(body + column * (chip_w + gap)),
			f32(row.y + inset),
			f32(chip_w),
			f32(page.line - inset * 2),
		}
		legacy.draw_wash(page.frame, cell, color)
		legacy.text_truncated(
			page.frame,
			fmt.tprint(ink),
			i32(cell.x) + legacy.ui_frame_sc(page.frame, 4),
			i32(cell.y),
			chip_w - legacy.ui_frame_sc(page.frame, 8),
			.Note,
			legible_on(page.frame, color),
		)
		column += 1
	}
	annotate(page, row, fmt.tprintf("min %.1f:1", worst))
	page_rows(page, 1)
}

// The one taped item on the page: the accent colour, tape over its corner,
// hex in the margin.
//
// Exactly one. A page where everything is taped down is a scrapbook; a page
// with a single taped swatch reads as something a person placed deliberately.
draw_taped_accent :: proc(page: ^Page) {
	assert(page != nil, "draw_taped_accent: nil page")
	theme := legacy.ui_frame_theme(page.frame)
	if theme.tape_color.a == 0 do return

	row := page_rows(page, 2)
	accent := theme.fg_accent
	swatch := legacy.legacy_rect {
		f32(page_body(page)),
		f32(row.y),
		f32(legacy.ui_frame_sc(page.frame, SWATCH_W)),
		f32(row.h - legacy.ui_frame_sc(page.frame, 6)),
	}
	legacy.draw_shadow_hard(page.frame, swatch, .SM, .Lifted)
	legacy.draw_pigment_block(page.frame, swatch, accent)
	legacy.draw_tape_strip(
		page.frame,
		swatch,
		f32(legacy.ui_frame_sc(page.frame, 26)),
		theme.tape_color,
	)
	annotate(page, row, fmt.tprintf("#%02X%02X%02X", accent.r, accent.g, accent.b))
	page_rows(page, 1)
}

// The four type roles, each a specimen with its resolved size in the margin.
draw_type_specimen :: proc(page: ^Page) {
	assert(page != nil, "draw_type_specimen: nil page")
	page_heading(page, "Type")
	for role in legacy.legacy_text_role {
		count := i32(1)
		if legacy.text_role_line_height(page.frame, role) > page.line do count = 2
		row := page_rows(page, count)
		legacy.text_truncated(
			page.frame,
			SPECIMEN,
			page_body(page),
			row.y,
			page.w - page.indent,
			role,
			.Primary,
		)
		annotate(page, row, fmt.tprintf("%v %dpx", role, legacy.text_role_size(page.frame, role)))
	}
	page_rows(page, 1)
}

// Radius and elevation together on one dog-eared card.
//
// The fold and the hard shadow belong in the same exhibit because they are the
// same idea: a sheet lifted off the page has both a shadow and a corner you
// can turn.
draw_shape_notes :: proc(page: ^Page) {
	assert(page != nil, "draw_shape_notes: nil page")
	page_heading(page, "Shape")

	theme := legacy.ui_frame_theme(page.frame)
	row := page_rows(page, 3)
	card := legacy.legacy_rect {
		f32(page_body(page)),
		f32(row.y),
		f32(legacy.ui_frame_sc(page.frame, 150)),
		f32(row.h - legacy.ui_frame_sc(page.frame, 8)),
	}
	legacy.draw_surface(page.frame, card, .Card, .Rest, .MD, .Hairline, .Lifted)
	// The lit edge. draw_surface already laid the cast shadow, so the card is
	// now worked from both directions - which is what a raised sheet on toned
	// stock actually looks like, and what a white ground cannot express.
	legacy.draw_chalk_highlight(page.frame, card, .MD)
	// A card is a smaller sheet: it gets its own grain, which is the one place
	// a bounded texture is affordable.
	if theme.paper_tooth.a > 0 {
		legacy.draw_paper_tooth(page.frame, card, theme.paper_tooth)
	}
	legacy.draw_dog_ear(
		page.frame,
		card,
		f32(legacy.ui_frame_sc(page.frame, 14)),
		// The folded flap catches the light, so it takes chalk rather than
		// borrowing the app background. On a screen palette chalk is zeroed
		// and the fold falls back to the ground, as before.
		theme.chalk if theme.chalk.a > 0 else theme.bg_app,
		theme.border_subtle,
	)
	legacy.text(
		page.frame,
		"Lifted",
		i32(card.x) + legacy.ui_frame_sc(page.frame, 10),
		i32(card.y) + legacy.ui_frame_sc(page.frame, 4),
		.Note,
		.Secondary,
	)
	annotate(page, row, "card")

	// The radii as an unboxed run beside the card: filled blocks with no
	// border, so the corner is the only thing that differs between them.
	block_x := i32(card.x + card.width) + legacy.ui_frame_sc(page.frame, 16)
	block_w := legacy.ui_frame_sc(page.frame, 52)
	gap := legacy.ui_frame_sc(page.frame, 8)
	for radius, index in legacy.legacy_radius {
		block := legacy.legacy_rect {
			f32(block_x + i32(index) * (block_w + gap)),
			card.y,
			f32(block_w),
			f32(page.line * 2),
		}
		if block.x + block.width > f32(page.x + page.w) do break
		legacy.draw_surface(page.frame, block, .Chip, .Rest, radius, .None, .Flat)
		legacy.text(
			page.frame,
			fmt.tprint(radius),
			i32(block.x) + legacy.ui_frame_sc(page.frame, 4),
			i32(block.y) + page.line * 2,
			.Note,
			.Muted,
		)
	}
	page_rows(page, 1)
}

// Spacing and tint as indented runs hanging off the margin.
draw_measure_notes :: proc(page: ^Page) {
	assert(page != nil, "draw_measure_notes: nil page")
	page_heading(page, "Measure")

	theme := legacy.ui_frame_theme(page.frame)
	bar_h := legacy.ui_frame_sc(page.frame, 10)
	body := page_body(page)
	for space in legacy.legacy_space {
		row := page_rows(page, 1)
		width := legacy.space_pixels(page.frame, space)
		// A zero-width token still needs a visible row, or None reads as a
		// missing entry rather than as a deliberate zero.
		legacy.draw_rectangle(
			page.frame,
			body,
			row.y + legacy.ui_frame_sc(page.frame, 5),
			max(width, 1),
			bar_h,
			theme.fg_accent,
		)
		annotate(page, row, fmt.tprintf("%v %dpx", space, width))
	}
	page_rows(page, 1)

	for tint in legacy.Tint {
		row := page_rows(page, 1)
		bar := legacy.legacy_rect {
			f32(body),
			f32(row.y + legacy.ui_frame_sc(page.frame, 3)),
			f32(legacy.ui_frame_sc(page.frame, SWATCH_W)),
			f32(page.line - legacy.ui_frame_sc(page.frame, 6)),
		}
		legacy.draw_rectangle_rec(page.frame, bar, legacy.color_tinted(theme.fg_accent, tint))
		annotate(page, row, fmt.tprintf("%v %d", tint, legacy.tint_alpha(tint)))
	}
	page_rows(page, 1)
}
