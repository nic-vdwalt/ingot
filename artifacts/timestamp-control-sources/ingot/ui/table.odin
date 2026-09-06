// LIB-CANDIDATE: imports only core:*.
// Sortable table primitives. The library owns the header (click-to-sort with
// direction indicators) and the shared column tracks; the caller owns the
// data, does the actual sorting, and draws rows with table_row_begin (^Layout)
// or flex_row_begin (^Ui) using table_tracks so cells align with the header.
package ui

TABLE_COLUMN_COUNT_MAX :: MAX_LAYOUT_FLEX

// Table_Column declares one column: a header label plus the flex track every
// row must reuse. numeric right-aligns the header (and by convention cells).
Table_Column :: struct {
	label:   string,
	track:   Track,
	numeric: bool,
}

// Table_Sort is the caller-owned sort state: which column and direction.
// column -1 means unsorted.
Table_Sort :: struct {
	column:     i32,
	descending: bool,
}

// table_tracks copies the column tracks into buffer so callers can open row
// flex containers with exactly the header's geometry.
table_tracks :: proc(columns: []Table_Column, buffer: []Track) -> []Track {
	assert(len(columns) > 0, "table_tracks: empty columns")
	assert(len(columns) <= TABLE_COLUMN_COUNT_MAX, "table_tracks: too many columns")
	assert(len(buffer) >= len(columns), "table_tracks: buffer too small")
	for column, index in columns {
		buffer[index] = column.track
	}
	return buffer[:len(columns)]
}

// table_row_begin carves one data row from the enclosing column and opens the
// header's column tracks across it, so a cell sequence cannot be declared down
// the wrong axis.
//
// This exists because the two-step form is easy to get subtly wrong: calling
// flex_begin on the enclosing COLUMN, rather than pushing a row first, splits
// the row's height into N bands and stacks every cell at the same x. The run
// is fully consumed either way, so flex_end, layout_pop and layout_end all
// pass and no assertion fires. Pairing the push and the flex here makes the
// correct form the shortest one, and the axis argument turns the incorrect
// form into an immediate assertion rather than silent overlap.
//
// Balance with table_row_end. Cells are taken with flex_next, exactly as the
// header takes them, so a row always resolves the same tracks the header did.
table_row_begin :: proc(
	l: ^Layout,
	height: i32,
	columns: []Table_Column,
	buffer: []Track,
	gap: i32 = 0,
) {
	assert(l != nil, "table_row_begin: nil l")
	assert(height > 0, "table_row_begin: non-positive height")
	assert(len(columns) > 0, "table_row_begin: empty columns")
	assert(len(buffer) >= len(columns), "table_row_begin: buffer too small")
	push_row(l, height, gap)
	flex_begin(l, table_tracks(columns, buffer), axis = .Row)
}

// table_row_end closes the row opened by table_row_begin. It calls flex_end
// before popping so an UNDER-consumed cell run fails here, naming the row,
// rather than several frames later inside layout_pop.
table_row_end :: proc(l: ^Layout) {
	assert(l != nil, "table_row_end: nil l")
	assert(l.depth > 1, "table_row_end: no row pushed")
	flex_end(l)
	layout_pop(l)
}

// table_sort_toggle applies one header click: first click sorts ascending,
// a second click on the same column flips direction. Pure and testable.
table_sort_toggle :: proc(sort: ^Table_Sort, column: i32) {
	assert(sort != nil, "table_sort_toggle: nil sort")
	assert(column >= 0, "table_sort_toggle: negative column")
	if sort.column == column {
		sort.descending = !sort.descending
	} else {
		sort.column = column
		sort.descending = false
	}
}

// table_header carves one header row of clickable, focusable column labels
// with an ascending/descending indicator on the active sort column. Returns
// true on the frame the sort changed.
table_header :: proc(
	u: ^Ui,
	key: string,
	columns: []Table_Column,
	sort: ^Table_Sort,
	height: i32 = 30,
) -> (
	changed: bool,
) {
	assert(u != nil && u.open, "table_header: frame not open")
	assert(sort != nil, "table_header: nil sort")
	assert(len(columns) > 0, "table_header: empty columns")
	assert(len(columns) <= TABLE_COLUMN_COUNT_MAX, "table_header: too many columns")
	assert(height > 0, "table_header: non-positive height")
	tracks_buffer: [TABLE_COLUMN_COUNT_MAX]Track
	scope_begin(u, key)
	defer scope_end(u)
	flex_row_begin(u, height, table_tracks(columns, tracks_buffer[:]), align = .Center)
	defer flex_row_end(u)
	for column, index in columns {
		rect := flex_slot_next(u, height)
		if !slot_visible(rect) do continue
		if table_header_cell(u, rect, column, index, sort) do changed = true
	}
	return changed
}

// table_header_cell draws one clickable, focusable, sortable header cell into a
// pre-carved slot. `original` is the column's index in the caller's array; it
// is the sort key and the seed for the widget's stable id, so a reordered
// header keeps each column's identity and sort state. Returns true when this
// cell's click toggled the sort. Shared by table_header and table_header_ex.
@(private = "file")
table_header_cell :: proc(
	u: ^Ui,
	rect: Rect_I32,
	column: Table_Column,
	original: int,
	sort: ^Table_Sort,
) -> (
	clicked: bool,
) {
	assert(u != nil && u.frame != nil, "table_header_cell: invalid Ui")
	assert(sort != nil, "table_header_cell: nil sort")
	frame := u.frame
	widget := id(u, u64(original) + 1)
	fo := focus(u, widget)
	focus_opt_click(frame, fo, rect.x, rect.y, rect.w, rect.h)
	it := interact(frame, rect_f32(rect))
	if it.hovered do request_cursor(frame, .POINTING_HAND)
	clicked = it.clicked || focus_opt_activated(frame, fo)
	if clicked do table_sort_toggle(sort, i32(original))
	table_header_label_draw(u, rect, column, original, sort, fo, widget)
	return clicked
}

// table_header_label_draw paints one header cell's label, sort arrow, focus
// ring, and semantic node. It performs no interaction, so both the legacy
// (pointer-in-cell) and the interactive (arbitrated pointer) headers share the
// exact same appearance.
@(private = "file")
table_header_label_draw :: proc(
	u: ^Ui,
	rect: Rect_I32,
	column: Table_Column,
	original: int,
	sort: ^Table_Sort,
	fo: Focus_Opt,
	widget: Widget_Id,
) {
	assert(u != nil && u.frame != nil, "table_header_label_draw: invalid Ui")
	assert(sort != nil, "table_header_label_draw: nil sort")
	frame := u.frame
	metrics := ui_frame_metrics(frame)
	is_active := sort.column == i32(original)
	label := column.label
	if is_active do label = table_header_label(frame, label, sort.descending)
	color := Ink.Primary if is_active else .Secondary
	label_w := text_width(frame, label, .Label)
	text_x := rect.x + ui_frame_sc(frame, 4)
	if column.numeric do text_x = rect.x + rect.w - label_w - ui_frame_sc(frame, 4)
	text(frame, label, text_x, rect.y + (rect.h - metrics.FONT_SIZE_LABEL) / 2, .Label, color)
	if focus_opt_focused(fo) do draw_focus_ring(frame, rect.x, rect.y, rect.w, rect.h)
	semantic_push(frame, .Button, rect, column.label, {}, fo, widget = widget)
}

// table_header_ex is the interactive superset of table_header: it draws headers
// in the caller-owned Table_State's display order, skips hidden columns, sorts
// on click, resizes columns by dragging their borders (style.resizable), and
// rearranges columns by dragging a header (style.reorderable). Column widths,
// order, visibility, and sort all live in `st`; the library retains nothing.
// Returns true when sort, a width, or the order changed this frame. Pair its
// display order with table_row so a body's cells stay under their header.
table_header_ex :: proc(
	u: ^Ui,
	key: string,
	columns: []Table_Column,
	st: ^Table_State,
	style: Table_Style,
	height: i32 = 30,
) -> (
	changed: bool,
) {
	assert(u != nil && u.open, "table_header_ex: frame not open")
	assert(st != nil, "table_header_ex: nil st")
	assert(len(columns) > 0, "table_header_ex: empty columns")
	assert(len(columns) <= TABLE_COLUMN_COUNT_MAX, "table_header_ex: too many columns")
	assert(height > 0, "table_header_ex: non-positive height")
	table_state_init(st, columns)

	tracks: [TABLE_COLUMN_COUNT_MAX]Track
	cols: [TABLE_COLUMN_COUNT_MAX]i32
	n := table_solve_widths(st, columns, tracks[:], cols[:])

	// rects[slot] is the drawn header cell; bounds[0] is the row's left edge and
	// bounds[i] is the right edge of display column i-1 (the resize/reorder math).
	rects: [TABLE_COLUMN_COUNT_MAX]Rect_I32
	bounds: [TABLE_COLUMN_COUNT_MAX + 1]i32
	header_y, header_h: i32

	// Draw pass: labels, focus, semantics, and keyboard-driven sort. Pointer
	// click/drag is arbitrated once, afterwards, so a click sorts but a drag
	// resizes or reorders without also toggling the sort.
	scope_begin(u, key)
	flex_row_begin(u, height, tracks[:n], align = .Center)
	for slot in 0 ..< n {
		original := int(cols[slot])
		rect := flex_slot_next(u, height)
		rects[slot] = rect
		if slot == 0 {
			header_y = rect.y
			header_h = rect.h
			bounds[0] = rect.x
		}
		bounds[slot + 1] = rect.x + rect.w
		if !slot_visible(rect) do continue
		widget := id(u, u64(original) + 1)
		fo := focus(u, widget)
		focus_opt_click(u.frame, fo, rect.x, rect.y, rect.w, rect.h)
		if focus_opt_activated(u.frame, fo) {
			table_sort_toggle(&st.sort, i32(original))
			changed = true
		}
		table_header_label_draw(u, rect, columns[original], original, &st.sort, fo, widget)
	}
	flex_row_end(u)
	scope_end(u)

	if table_header_pointer(
		u,
		st,
		style,
		rects[:n],
		bounds[:n + 1],
		cols[:n],
		header_y,
		header_h,
	) {
		changed = true
	}
	return changed
}

// table_header_pointer arbitrates all header pointer input after the cells are
// drawn: resize borders win first (their grab strips sit on top), then a header
// drag reorders, and a header click sorts. Only one gesture runs per frame, and
// the single-drag-latch invariant is asserted.
@(private = "file")
table_header_pointer :: proc(
	u: ^Ui,
	st: ^Table_State,
	style: Table_Style,
	rects: []Rect_I32,
	bounds: []i32,
	cols: []i32,
	header_y, header_h: i32,
) -> (
	changed: bool,
) {
	assert(u != nil && u.frame != nil, "table_header_pointer: invalid Ui")
	assert(st != nil, "table_header_pointer: nil st")
	frame := u.frame
	if style.resizable {
		resized, engaged := table_header_resize(u, st, bounds, cols, style, header_y, header_h)
		if resized do changed = true
		if engaged {
			assert(!st.reorder.active, "table: resize and reorder both active")
			return changed
		}
	} else if st.resize.active {
		st.resize.active = false
		interact_forget(frame, &st.resize.active)
	}

	if style.reorderable {
		if table_header_reorder(u, st, rects, bounds, cols, header_y, header_h) do changed = true
	} else {
		if st.reorder.active {
			st.reorder.active = false
			interact_forget(frame, &st.reorder.active)
		}
		mouse := get_mouse_position(frame)
		slot := table_header_hovered_slot(rects, mouse, header_y, header_h)
		if slot >= 0 {
			it := interact(frame, rect_f32(rects[slot]))
			if it.hovered do request_cursor(frame, .POINTING_HAND)
			if it.clicked {
				table_sort_toggle(&st.sort, cols[slot])
				changed = true
			}
		}
	}
	assert(!(st.resize.active && st.reorder.active), "table: two drag latches active")
	return changed
}

// table_header_hovered_slot returns the display slot under the pointer, or -1
// when the pointer is outside the header band.
@(private = "file")
table_header_hovered_slot :: proc(rects: []Rect_I32, mouse: Vec2, header_y, header_h: i32) -> int {
	if mouse.y < f32(header_y) || mouse.y >= f32(header_y + header_h) do return -1
	for rect, slot in rects {
		if mouse.x >= f32(rect.x) && mouse.x < f32(rect.x + rect.w) do return slot
	}
	return -1
}

// table_header_resize runs the border-drag interaction. It maintains a single
// caller-owned latch (st.resize.active) exactly like Scrollbar_State: press
// claims the border, motion applies the delta through the pure
// table_resize_apply, and a column that disappears mid-drag releases the latch
// cleanly. `engaged` reports that a border is hovered or held, so the caller can
// suppress reorder/sort for this frame.
@(private = "file")
table_header_resize :: proc(
	u: ^Ui,
	st: ^Table_State,
	bounds: []i32,
	cols: []i32,
	style: Table_Style,
	header_y, header_h: i32,
) -> (
	changed: bool,
	engaged: bool,
) {
	assert(u != nil && u.frame != nil, "table_header_resize: invalid Ui")
	assert(st != nil, "table_header_resize: nil st")
	frame := u.frame
	mouse_x := get_mouse_position(frame).x
	scale := ui_frame_scf(frame, 1)
	grab_px := ui_frame_sc(frame, 6)
	active_before := st.resize.active

	target_slot := -1
	if st.resize.active {
		for slot in 0 ..< len(cols) {
			if cols[slot] == st.resize.column {
				target_slot = slot
				break
			}
		}
		if target_slot < 0 {
			// The dragged column was hidden or removed: drop the latch.
			st.resize.active = false
			interact_forget(frame, &st.resize.active)
			return false, false
		}
	} else {
		hit := table_resize_hit(bounds, mouse_x, grab_px)
		if hit >= 0 do target_slot = int(hit)
	}
	if target_slot < 0 do return false, false

	border_x := bounds[target_slot + 1]
	grab := rect_f32(Rect_I32{border_x - grab_px, header_y, grab_px * 2, header_h})
	request_cursor(frame, .RESIZE_EW)
	it := interact(frame, grab, &st.resize.active)
	if it.pressed && !active_before {
		// Widths are stored in design units so they scale like every other
		// Track; the grabbed pixel width is converted once, here.
		start_px := bounds[target_slot + 1] - bounds[target_slot]
		st.resize.column = cols[target_slot]
		st.resize.start_x = mouse_x
		st.resize.start_w = i32(f32(start_px) / scale + 0.5)
	}
	if st.resize.active {
		delta_design := i32((mouse_x - st.resize.start_x) / scale)
		new_w := st.resize.start_w + delta_design
		table_resize_apply(st, int(st.resize.column), new_w, style.min_column_px)
		changed = true
	}
	return changed, true
}

// table_header_reorder runs the header-drag interaction against a single
// caller-owned latch (st.reorder.active). A press arms the gesture; moving past
// a small threshold turns it into a drag that previews the drop slot; releasing
// commits table_order_move for a drag or toggles the sort for a plain click.
@(private = "file")
table_header_reorder :: proc(
	u: ^Ui,
	st: ^Table_State,
	rects: []Rect_I32,
	bounds: []i32,
	cols: []i32,
	header_y, header_h: i32,
) -> (
	changed: bool,
) {
	assert(u != nil && u.frame != nil, "table_header_reorder: invalid Ui")
	assert(st != nil, "table_header_reorder: nil st")
	frame := u.frame
	mouse := get_mouse_position(frame)
	threshold := f32(ui_frame_sc(frame, 4))
	active_before := st.reorder.active

	slot := -1
	if st.reorder.active {
		slot = int(st.reorder.from)
	} else {
		slot = table_header_hovered_slot(rects, mouse, header_y, header_h)
	}
	if slot < 0 do return false

	rect := rects[slot]
	it := interact(frame, rect_f32(rect), &st.reorder.active)
	if it.pressed && !active_before {
		st.reorder.from = i32(slot)
		st.reorder.press_x = mouse.x
		st.reorder.pointer_x = mouse.x
	}

	if st.reorder.active {
		st.reorder.pointer_x = mouse.x
		dragging := abs(st.reorder.pointer_x - st.reorder.press_x) > threshold
		if dragging {
			request_cursor(frame, .RESIZE_ALL)
			drop := table_reorder_drop_slot(bounds, st.reorder.pointer_x)
			table_header_reorder_preview(frame, rect, bounds, drop, header_y, header_h)
		} else if it.hovered {
			request_cursor(frame, .POINTING_HAND)
		}
		return false
	}

	// Latch released this frame (covers a same-frame click and the end of a
	// multi-frame drag); press_x is set either on this frame's press or when
	// the drag was armed.
	if it.released {
		if abs(mouse.x - st.reorder.press_x) > threshold {
			drop := table_reorder_drop_slot(bounds, mouse.x)
			from := int(st.reorder.from)
			if drop != from {
				table_order_move(st, from, drop)
				changed = true
			}
		} else {
			table_sort_toggle(&st.sort, cols[st.reorder.from])
			changed = true
		}
	} else if it.hovered {
		request_cursor(frame, .POINTING_HAND)
	}
	return changed
}

// table_header_reorder_preview tints the picked-up header and draws an insertion
// marker at the drop boundary, so the drag reads clearly.
@(private = "file")
table_header_reorder_preview :: proc(
	frame: ^Ui_Frame,
	from_rect: Rect_I32,
	bounds: []i32,
	drop: int,
	header_y, header_h: i32,
) {
	assert(frame != nil, "table_header_reorder_preview: nil frame")
	assert(drop >= 0 && drop < len(bounds), "table_header_reorder_preview: drop out of range")
	theme := ui_frame_theme(frame)
	tint := theme.fg_accent
	tint[3] = 56
	draw_rectangle(frame, from_rect.x, from_rect.y, from_rect.w, from_rect.h, tint)
	marker_w := ui_frame_sc(frame, 2)
	marker_x := bounds[drop] - marker_w / 2
	draw_rectangle(frame, marker_x, header_y, marker_w, header_h, theme.fg_accent)
}

// table_visibility_menu renders a checkbox per column bound to the caller-owned
// Table_State visibility mask, applying each toggle through the guarded pure
// helper (so the last visible column can never be hidden). Place it behind a
// "Columns" button or inside a popup. Returns true when a column was shown or
// hidden this frame.
table_visibility_menu :: proc(
	u: ^Ui,
	key: string,
	columns: []Table_Column,
	st: ^Table_State,
	row_h: i32 = 26,
) -> (
	changed: bool,
) {
	assert(u != nil && u.open, "table_visibility_menu: frame not open")
	assert(st != nil, "table_visibility_menu: nil st")
	assert(len(columns) > 0, "table_visibility_menu: empty columns")
	assert(row_h > 0, "table_visibility_menu: non-positive row height")
	table_state_init(st, columns)
	scope_begin(u, key)
	defer scope_end(u)
	for column, original in columns {
		row_begin(u, row_h, .None, .Center)
		shown := st.visible[original]
		before := shown
		if checkbox(u, u64(original) + 1, column.label, &shown) {
			if shown != before && table_visibility_toggle(st, original) do changed = true
		}
		row_end(u)
	}
	return changed
}

// table_header_label appends the sort-direction arrow in the temp allocator.
@(private = "file")
table_header_label :: proc(frame: ^Ui_Frame, label: string, descending: bool) -> string {
	assert(frame != nil, "table_header_label: nil frame")
	arrow := " \u25BE" if descending else " \u25B4"
	joined := make([]u8, len(label) + len(arrow), ui_frame_allocator(frame))
	copy(joined, label)
	copy(joined[len(label):], arrow)
	return string(joined)
}
