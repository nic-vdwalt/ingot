// LIB-CANDIDATE: imports only core:*.
// Unified table body: a sticky header over a virtual-scrolled, gridded,
// zebra-striped set of fixed-height rows whose cells stay under their header.
//
// table_begin draws the interactive header (table_header_ex) and opens a
// scissored body window; the caller loops the visible rows, opening each with
// table_row and closing it with table_row_close; table_end closes the scissor
// and paints the borders. All layout lives in the caller-owned Table_State's
// per-frame build scratch, so nothing is retained between frames.
package ui

// Table_Window reports the visible slice and geometry table_begin resolved.
Table_Window :: struct {
	first:        int,
	visible_rows: int,
	row_w:        i32,
	row_h_px:     i32,
}

// table_begin draws the sticky header and opens the scroll body. `row_h` is the
// design-unit height of the header and of each data row; `count` is the total
// row count; `freeze_cols` leading display columns are kept pinned (reserved for
// horizontal scrolling — with columns that fit the width they are simply always
// visible); `visible_h` caps the body height (0 = fill the remaining area).
table_begin :: proc(
	u: ^Ui,
	key: string,
	columns: []Table_Column,
	st: ^Table_State,
	style: Table_Style,
	row_h: i32,
	count: int,
	freeze_cols: int = 0,
	visible_h: i32 = 0,
) -> (
	window: Table_Window,
) {
	assert(u != nil && u.open, "table_begin: frame not open")
	assert(st != nil, "table_begin: nil st")
	assert(len(columns) > 0, "table_begin: empty columns")
	assert(row_h > 0, "table_begin: non-positive row height")
	assert(count >= 0, "table_begin: negative count")
	assert(freeze_cols >= 0 && freeze_cols <= len(columns), "table_begin: bad freeze_cols")
	frame := u.frame
	table_state_init(st, columns)

	region := remaining_rect(u)
	avail_h := region.h
	if visible_h > 0 do avail_h = min(avail_h, ui_frame_sc(frame, visible_h))

	// Header first, above the scissor, so it never scrolls.
	_ = table_header_ex(u, key, columns, st, style, row_h)

	tracks: [TABLE_COLUMN_COUNT_MAX]Track
	cols: [TABLE_COLUMN_COUNT_MAX]i32
	n := table_solve_widths(st, columns, tracks[:], cols[:])

	header_px := ui_frame_sc(frame, row_h)
	row_h_px := header_px
	body := remaining_rect(u)
	body.h = min(body.h, max(avail_h - header_px, 0))

	visible_rows := 0
	if row_h_px > 0 && body.h >= row_h_px do visible_rows = int(body.h / row_h_px)

	// Wheel scroll while the pointer is over the body, then clamp.
	mouse := get_mouse_position(frame)
	over :=
		mouse.x >= f32(body.x) &&
		mouse.x < f32(body.x + body.w) &&
		mouse.y >= f32(body.y) &&
		mouse.y < f32(body.y + body.h)
	if over {
		wheel := get_wheel_move(frame)
		if wheel != 0 do st.scroll -= wheel * 3
	}
	st.scroll = clamp(st.scroll, 0, f32(max(count - visible_rows, 0)))
	first := int(st.scroll)

	// Resolve body column edges (pixels) for gridlines from scaled tracks.
	b := &st.build
	b.n = n
	b.row_h_px = row_h_px
	b.first = first
	b.freeze_cols = freeze_cols
	b.style = style
	b.full = Rect_I32{region.x, region.y, region.w, avail_h}
	b.body = body
	scaled: [TABLE_COLUMN_COUNT_MAX]Track
	for slot in 0 ..< n {
		b.tracks[slot] = tracks[slot]
		b.cols[slot] = cols[slot]
		scaled[slot] = table_scale_track(frame, tracks[slot])
	}
	widths: [TABLE_COLUMN_COUNT_MAX]i32
	if n > 0 {
		table_resolve_pixels(scaled[:n], body.w, 0, widths[:])
	}
	b.bounds[0] = body.x
	for slot in 0 ..< n {
		b.bounds[slot + 1] = b.bounds[slot] + widths[slot]
	}
	b.active = true

	semantic_push(frame, .List_Box, body, key, field_id = key)
	begin_scissor_mode(frame, body.x, body.y, max(body.w, 0), max(body.h, 0))

	window = Table_Window {
		first        = first,
		visible_rows = visible_rows,
		row_w        = body.w,
		row_h_px     = row_h_px,
	}
	return window
}

// table_row opens one data row inside the body. It paints the zebra background,
// selection/hover, and the per-row horizontal gridline, reports the row's
// interaction (hover/click/double-click), and opens the header's column tracks
// so the caller fills cells with cell/cell_value in display order. `key` is the
// row's stable semantic id. Close with table_row_close.
table_row :: proc(
	u: ^Ui,
	st: ^Table_State,
	index: int,
	key: string,
	selected: bool = false,
	last_click_at: ^f64 = nil,
) -> (
	result: Row_Select_Result,
) {
	assert(u != nil && u.open, "table_row: frame not open")
	assert(st != nil && st.build.active, "table_row: table_begin not open")
	assert(len(key) > 0, "table_row: semantics required")
	assert(index >= 0, "table_row: negative index")
	b := &st.build
	frame := u.frame

	parent := remaining(&u.layout)
	rect := container_rect_px(u, parent.w, b.row_h_px)
	if slot_visible(rect) {
		it := interact(frame, rect_f32(rect))
		result.hovered = it.hovered
		result.clicked = it.clicked
		result.held = it.held
		if it.clicked && last_click_at != nil && frame.input != nil {
			now := frame.input.time
			if now - last_click_at^ < ROW_DOUBLE_CLICK_SECONDS {
				result.double_clicked = true
				last_click_at^ = 0
			} else {
				last_click_at^ = now
			}
		}
		theme := ui_frame_theme(frame)
		if b.style.row_striping && index % 2 == 1 {
			draw_rectangle(frame, rect.x, rect.y, rect.w, rect.h, theme.bg_secondary)
		}
		list_row_bg_at(frame, rect, selected, result.hovered)
		if b.style.borders_inner_h {
			draw_rectangle(frame, rect.x, rect.y + rect.h - 1, rect.w, 1, theme.border_subtle)
		}
		if result.hovered do request_cursor(frame, .POINTING_HAND)
		sem: Sem_State
		if selected do sem += {.Selected}
		semantic_push(frame, .Option, rect, key, sem, field_id = key)
	}
	layout_push_rect(&u.layout, .Row, rect, 0, .Stretch)
	flex_begin_tracks(u, b.tracks[:b.n], .Start)
	return result
}

// table_row_close closes the flex run opened by table_row.
table_row_close :: proc(u: ^Ui) {
	assert(u != nil && u.open, "table_row_close: frame not open")
	flex_row_end(u)
}

// table_end closes the body scissor and paints the inner vertical gridlines and
// outer border across the whole header+body region, so they align with the
// header and cells regardless of resize, reorder, or scroll.
table_end :: proc(u: ^Ui, st: ^Table_State) {
	assert(u != nil && u.open, "table_end: frame not open")
	assert(st != nil && st.build.active, "table_end: table_begin not open")
	b := &st.build
	frame := u.frame
	end_scissor_mode(frame)
	theme := ui_frame_theme(frame)
	if b.style.borders_inner_v {
		for slot in 1 ..< b.n {
			draw_rectangle(frame, b.bounds[slot], b.full.y, 1, b.full.h, theme.border_subtle)
		}
	}
	if b.style.borders_outer {
		draw_rectangle_lines_ex(
			frame,
			rect_f32(b.full),
			ui_frame_scf(frame, 1),
			theme.border_color,
		)
	}
	b.active = false
}

// table_scale_track converts a design-unit Track into pixels the same way the
// facade flex path does, so table_resolve_pixels yields body column edges that
// match what flex_begin_tracks lays out for each row.
@(private = "file")
table_scale_track :: proc(frame: ^Ui_Frame, track: Track) -> Track {
	assert(frame != nil && frame.open, "table scale track: invalid frame")
	basis := ui_frame_sc(frame, track.basis)
	minimum := ui_frame_sc(frame, track.min_size)
	maximum := ui_frame_sc(frame, track.max_size) if track.max_size > 0 else 0
	switch track.kind {
	case .Fit:
		return fit(basis, minimum, maximum)
	case .Hug:
		return hug(basis, minimum, maximum)
	case .Grow:
		return grow(track.weight, minimum, maximum)
	case .Fixed:
		return fixed(basis)
	case .Percent:
		return percent(track.percent, minimum, maximum)
	}
	unreachable()
}
