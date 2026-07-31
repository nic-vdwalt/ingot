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
// Placement jitter comes from ui.scatter_unit, a pure hash of the item index.
// Frames here are event-driven, so an RNG would deal a new layout on every
// unrelated redraw and the page would crawl while the user typed; it would
// also break the capture harness, whose output must be byte-reproducible.
package main

import "core:fmt"
import "ingot:ui"

// Column geometry in logical pixels. Everything horizontal is expressed
// against these so the page has one measure rather than per-section widths.
LABEL_COL_W :: 118
CHIP_W :: 96
SWATCH_W :: CHIP_W * 2

// The specimen sentence. A pangram earns its place in a type specimen: it puts
// every letter in front of the reader, which is the one thing a specimen does.
SPECIMEN :: "Sphinx of black quartz, judge my vow"

// Pigment_Study names one entry in the opening colour study. The pigments are
// the palette's own accent roles rather than a separate table, so a retheme
// repaints the study instead of leaving it showing stale colours.
//
// The *label* therefore has to name the role, not the pigment. On the sketch
// palettes Ink.Accent is ultramarine, but on high contrast it is gold, and a
// block captioned "ultramarine" while rendering yellow is simply wrong. The
// pigment name is kept as a secondary note: it describes the sketch palettes
// rather than whatever is currently on screen.
Pigment_Study :: struct {
	role:    string,
	pigment: string,
	ink:     ui.Ink,
}

PIGMENT_STUDIES := [?]Pigment_Study {
	{"accent", "ultramarine", .Accent},
	{"danger", "vermilion", .Danger},
	{"success", "viridian", .Success},
	{"tool", "yellow ochre", .Tool},
	{"removed", "burnt sienna", .Diff_Remove},
	{"assistant", "sap green", .Assistant},
}

// Page is the writing cursor: a physical-pixel position that flows downward.
//
// The strict baseline grid the ruled version used is gone with the rules it
// served. What remains is a bounded cursor, so content still cannot escape the
// pane, but a block may be any height its content needs.
Page :: struct {
	frame:  ^ui.Ui_Frame,
	x:      i32, // Left edge of the page, physical.
	y:      i32, // Current write position, physical. Moves only via page_advance.
	w:      i32, // Page width, physical.
	indent: i32, // Body inset, reserving the annotation column. Physical.
	line:   i32, // One line height, physical. The unit for text rows.
}

page_begin :: proc(frame: ^ui.Ui_Frame, x, y, w: i32) -> Page {
	assert(frame != nil, "page_begin: nil frame")
	assert(w > 0, "page_begin: non-positive width")
	line := ui.ui_frame_metrics(frame).LINE_HEIGHT
	assert(line > 0, "page_begin: metrics carry a non-positive line height")
	return {frame = frame, x = x, y = y, w = w, indent = page_indent(frame), line = line}
}

// page_advance consumes `height` physical pixels and returns the block.
//
// The single place the cursor moves, which is what keeps a loose layout from
// becoming an unbounded one.
page_advance :: proc(page: ^Page, height: i32) -> ui.Rect_I32 {
	assert(page != nil, "page_advance: nil page")
	assert(height > 0, "page_advance: non-positive height")
	block := ui.Rect_I32{page.x, page.y, page.w, height}
	page.y += height
	return block
}

// page_rows advances a whole number of text lines. Text still wants a line
// rhythm even on unruled paper; only the graphics are free-form.
page_rows :: proc(page: ^Page, count: i32) -> ui.Rect_I32 {
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
page_indent :: proc(frame: ^ui.Ui_Frame) -> i32 {
	assert(frame != nil, "page_indent: nil frame")
	if ui.ui_frame_theme(frame).substrate.kind == .None do return 0
	return ui.ui_frame_sc(frame, MARGIN_INSET + 10)
}

// annotate writes a right-aligned note in the reserved margin column.
annotate :: proc(page: ^Page, row: ui.Rect_I32, note: string) {
	assert(page != nil, "annotate: nil page")
	if len(note) == 0 || page.indent == 0 do return
	width := ui.text_width(page.frame, note, .Note)
	gap := ui.ui_frame_sc(page.frame, 8)
	x := page.x + page.indent - width - gap
	if x < page.x do return
	ui.text(page.frame, note, x, row.y, .Note, .Muted)
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
	ui.text(page.frame, title, page_body(page), row.y, .Title, .Heading)

	theme := ui.ui_frame_theme(page.frame)
	color := theme.graphite if theme.graphite.a > 0 else theme.border_subtle
	ui.draw_hand_underline(
		page.frame,
		page_body(page),
		row.y + row.h - ui.ui_frame_sc(page.frame, 5),
		ui.text_width(page.frame, title, .Title),
		color,
	)
	page_rows(page, 1)
}

draw_theme_section :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
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
	ui.text(
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
	count := i32(len(PIGMENT_STUDIES))
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
	span := f32(available) - f32(ui.ui_frame_sc(page.frame, 4))
	pitch := i32(span / (f32(count - 1) + OVERLAP))
	block_w := f32(pitch) * OVERLAP
	band_h := page.line * 4
	band := page_advance(page, band_h + page.line)

	for study, index in PIGMENT_STUDIES {
		i := u32(index)
		pigment := ui.text_ink(page.frame, study.ink)
		// Bounded jitter: enough that the row is not a ruler, small enough
		// that nothing escapes its slot or collides with the label below.
		wobble_x := (ui.scatter_unit(i, 0) - 0.5) * f32(page.line) * 0.5
		wobble_y := (ui.scatter_unit(i, 1) - 0.5) * f32(page.line) * 0.6
		height := f32(band_h) * (0.72 + ui.scatter_unit(i, 2) * 0.28)

		block := ui.Rectangle {
			f32(body + i32(index) * pitch) + wobble_x,
			f32(band.y) + wobble_y,
			block_w,
			height,
		}
		ui.draw_pigment_block(page.frame, block, pigment)
	}

	// Names sit under the band rather than on the paint: a label on a wash is
	// unreadable at whatever alpha the wash happens to be.
	//
	// The role goes under each block because that is what the colour actually
	// is on any palette. The pigment names are a single note in the margin,
	// since they describe the sketch palettes rather than the swatches on
	// screen - on high contrast these same roles resolve to gold and white.
	label_row := page_rows(page, 1)
	for study, index in PIGMENT_STUDIES {
		ui.text_truncated(
			page.frame,
			study.role,
			body + i32(index) * pitch,
			label_row.y,
			pitch - ui.ui_frame_sc(page.frame, 4),
			.Note,
			.Secondary,
		)
	}

	// The pigment names only under a sketch palette, in muted ink so they read
	// as a caption rather than as a second set of labels. On a screen palette
	// they would be a lie: Ink.Accent is gold there, not ultramarine.
	if ui.ui_frame_theme(page.frame).substrate.kind != .None {
		pigment_row := page_rows(page, 1)
		for study, index in PIGMENT_STUDIES {
			ui.text_truncated(
				page.frame,
				study.pigment,
				body + i32(index) * pitch,
				pigment_row.y,
				pitch - ui.ui_frame_sc(page.frame, 4),
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
	count := i32(len(ui.Visual_State))
	gap := ui.ui_frame_sc(page.frame, 6)
	available := page.w - page.indent - label_w - gap * (count - 1)
	minimum := ui.ui_frame_sc(page.frame, 38)
	// Capped rather than filling the column: a cell stretched across the whole
	// page turns the highlighter into a band over a few pixels of text, which
	// reads as a fill rather than as a mark.
	maximum := ui.ui_frame_sc(page.frame, 76)
	if available < minimum * count do return minimum
	return min(available / count, maximum)
}

// Surfaces and their states, one band per surface.
//
// The one exhibit that earns a grid: it is a matrix, and reading down a column
// or across a row is the point. It is also the materials demo - Selected *is*
// a highlighter swipe and Pressed *is* a scribble, so both run every frame
// rather than only in tests.
draw_surface_states :: proc(page: ^Page) {
	assert(page != nil, "draw_surface_states: nil page")
	page_heading(page, "Surfaces")

	label_w := ui.ui_frame_sc(page.frame, LABEL_COL_W)
	gap := ui.ui_frame_sc(page.frame, 6)
	cell_w := state_cell_width(page, label_w)
	body := page_body(page)
	// Cells are inset vertically so consecutive rows do not touch. Without it,
	// thirteen highlighter swipes stack into one continuous column with a
	// sawtooth edge - a rendering fault rather than thirteen marks.
	inset := ui.ui_frame_sc(page.frame, 2)

	head := page_rows(page, 1)
	for state, index in ui.Visual_State {
		x := body + label_w + i32(index) * (cell_w + gap)
		ui.text(page.frame, fmt.tprint(state), x, head.y, .Note, .Muted)
	}

	for surface in ui.Surface {
		row := page_rows(page, 1)
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
	page_rows(page, 1)
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

	// "Ag" carries an ascender and a descender, so a fill that clips text
	// shows up here rather than hiding behind an all-caps sample.
	ui.text(frame, "Ag", i32(cell.x) + ui.ui_frame_sc(frame, 5), i32(cell.y), .Note, .Primary)
}

// legible_on picks whichever of the palette's two extreme inks reads better on
// a given fill.
//
// A swatch labelled in a fixed colour is only readable across half a palette:
// the dark inks disappear into their own chips and the light ones into the
// pale chips, which looks like a rendering fault rather than a swatch.
legible_on :: proc(frame: ^ui.Ui_Frame, fill: ui.Color) -> ui.Ink {
	assert(frame != nil, "legible_on: nil frame")
	dark := ui.text_ink(frame, .Primary)
	light := ui.text_ink(frame, .Inverse)
	if ui.contrast_ratio(light, fill) > ui.contrast_ratio(dark, fill) do return .Inverse
	return .Primary
}

// Every ink as a painted chip, with the row's worst contrast in the margin.
//
// Washes rather than flat fills: a filled rectangle reads as a table cell no
// matter what colour it holds.
draw_ink_chips :: proc(page: ^Page) {
	assert(page != nil, "draw_ink_chips: nil page")
	page_heading(page, "Ink")

	chip_w := ui.ui_frame_sc(page.frame, CHIP_W)
	gap := ui.ui_frame_sc(page.frame, 6)
	card := ui.surface_colors(page.frame, .Card, .Rest)
	body := page_body(page)
	per_row := max((page.w - page.indent) / (chip_w + gap), 1)
	inset := ui.ui_frame_sc(page.frame, 2)

	row := page_rows(page, 1)
	column := i32(0)
	worst := f64(21)
	for ink in ui.Ink {
		if column >= per_row {
			annotate(page, row, fmt.tprintf("min %.1f:1", worst))
			row = page_rows(page, 1)
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
		ui.draw_wash(page.frame, cell, color)
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
	page_rows(page, 1)
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

	row := page_rows(page, 2)
	accent := theme.fg_accent
	swatch := ui.Rectangle {
		f32(page_body(page)),
		f32(row.y),
		f32(ui.ui_frame_sc(page.frame, SWATCH_W)),
		f32(row.h - ui.ui_frame_sc(page.frame, 6)),
	}
	ui.draw_shadow_hard(page.frame, swatch, .SM, .Lifted)
	ui.draw_pigment_block(page.frame, swatch, accent)
	ui.draw_tape_strip(page.frame, swatch, f32(ui.ui_frame_sc(page.frame, 26)), theme.tape_color)
	annotate(page, row, fmt.tprintf("#%02X%02X%02X", accent.r, accent.g, accent.b))
	page_rows(page, 1)
}

// The four type roles, each a specimen with its resolved size in the margin.
draw_type_specimen :: proc(page: ^Page) {
	assert(page != nil, "draw_type_specimen: nil page")
	page_heading(page, "Type")
	for role in ui.Text_Role {
		count := i32(1)
		if ui.text_role_line_height(page.frame, role) > page.line do count = 2
		row := page_rows(page, count)
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

	theme := ui.ui_frame_theme(page.frame)
	row := page_rows(page, 3)
	card := ui.Rectangle {
		f32(page_body(page)),
		f32(row.y),
		f32(ui.ui_frame_sc(page.frame, 150)),
		f32(row.h - ui.ui_frame_sc(page.frame, 8)),
	}
	ui.draw_surface(page.frame, card, .Card, .Rest, .MD, .Hairline, .Lifted)
	// A card is a smaller sheet: it gets its own grain, which is the one place
	// a bounded texture is affordable.
	if theme.paper_tooth.a > 0 {
		ui.draw_paper_tooth(page.frame, card, theme.paper_tooth)
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
	page_rows(page, 1)
}

// Spacing and tint as indented runs hanging off the margin.
draw_measure_notes :: proc(page: ^Page) {
	assert(page != nil, "draw_measure_notes: nil page")
	page_heading(page, "Measure")

	theme := ui.ui_frame_theme(page.frame)
	bar_h := ui.ui_frame_sc(page.frame, 10)
	body := page_body(page)
	for space in ui.Space {
		row := page_rows(page, 1)
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
	page_rows(page, 1)

	for tint in ui.Tint {
		row := page_rows(page, 1)
		bar := ui.Rectangle {
			f32(body),
			f32(row.y + ui.ui_frame_sc(page.frame, 3)),
			f32(ui.ui_frame_sc(page.frame, SWATCH_W)),
			f32(page.line - ui.ui_frame_sc(page.frame, 6)),
		}
		ui.draw_rectangle_rec(page.frame, bar, ui.color_tinted(theme.fg_accent, tint))
		annotate(page, row, fmt.tprintf("%v %d", tint, ui.tint_alpha(tint)))
	}
	page_rows(page, 1)
}
