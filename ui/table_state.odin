// LIB-CANDIDATE: imports only core:*.
// Caller-owned table state and the pure column-model core it drives.
//
// Table_State holds everything an interactive table remembers between frames -
// column widths, display order, visibility, sort, scroll offset, and the drag
// latches for resize/reorder. It is caller-owned exactly like Scrollbar_State:
// the library retains nothing. Every decision here (width solve, order move,
// visibility, resize clamp, border hit-test, reorder drop) is a pure procedure
// over Table_State plus inputs, so it is unit-tested with no frame and no GPU.
package ui

// Per-column persistent, caller-owned state. The width/visible arrays are
// indexed by a column's ORIGINAL index (its position in the caller's
// []Table_Column); `order` maps a display slot to that original index.
Table_State :: struct {
	// Column model.
	width_px:    [TABLE_COLUMN_COUNT_MAX]i32, // per-original override; 0 = use the declared Track
	order:       [TABLE_COLUMN_COUNT_MAX]u8, // display slot -> original index
	visible:     [TABLE_COLUMN_COUNT_MAX]bool, // original index -> shown
	count:       int, // number of columns bound
	initialized: bool, // false => seed from columns on first use
	// Sort (same shape callers already pass to table_header).
	sort:        Table_Sort,
	// Virtual-scroll body offset, in rows.
	scroll:      f32,
	// Interaction latches (caller-owned, like Scrollbar_State.dragging).
	resize:      Table_Resize, // active column-border drag
	reorder:     Table_Reorder, // active header drag
	sbar:        Scrollbar_State, // body scrollbar drag state (reused primitive)
	// Per-frame scratch shared by table_begin/table_row/table_end. Rebuilt every
	// frame; never a cross-frame source of truth.
	build:       Table_Build,
}

// Table_Build is the current-frame layout the unified scroll body derives once
// in table_begin and replays in table_row/table_end: the solved display-ordered
// tracks and their original indices, the scissored body region and its column
// edges, the row height, and the first visible row. It is caller-owned scratch
// with no authority beyond the open frame.
Table_Build :: struct {
	active:      bool,
	n:           int,
	tracks:      [TABLE_COLUMN_COUNT_MAX]Track, // design-unit tracks for row flex
	cols:        [TABLE_COLUMN_COUNT_MAX]i32, // display slot -> original index
	bounds:      [TABLE_COLUMN_COUNT_MAX + 1]i32, // body column edges, in pixels
	full:        Rect_I32, // header + body region (outer border, v-gridlines)
	body:        Rect_I32, // scissored body region
	row_h_px:    i32,
	first:       int,
	freeze_cols: int,
	style:       Table_Style,
}

// Table_Resize is the active border drag: which original column is being sized,
// where the pointer grabbed it, and the column's width at grab time.
Table_Resize :: struct {
	active:   bool,
	column:   i32,
	start_x:  f32,
	start_w:  i32,
}

// Table_Reorder is the active header drag: the display slot picked up, the x
// where the press began (to distinguish a click from a drag), and the live
// pointer x used to preview the drop slot.
Table_Reorder :: struct {
	active:    bool,
	from:      i32,
	press_x:   f32,
	pointer_x: f32,
}

// Table_Style selects borders, striping, and which interactions are enabled.
Table_Style :: struct {
	borders_outer:   bool,
	borders_inner_v: bool, // vertical gridlines between columns
	borders_inner_h: bool, // horizontal gridlines between rows
	row_striping:    bool, // zebra background on odd rows
	resizable:       bool,
	reorderable:     bool,
	hideable:        bool,
	min_column_px:   i32, // clamp for resize, in design units
}

// table_style_default enables the common desktop table affordances.
table_style_default :: proc() -> Table_Style {
	return Table_Style {
		borders_outer = true,
		borders_inner_v = true,
		borders_inner_h = true,
		row_striping = true,
		resizable = true,
		reorderable = true,
		hideable = true,
		min_column_px = 32,
	}
}

// table_state_init seeds identity order, all-visible, and no width overrides
// from the column list, once. Idempotent: a state already initialized (loaded
// from prefs, say) is left untouched.
table_state_init :: proc(st: ^Table_State, columns: []Table_Column) {
	assert(st != nil, "table_state_init: nil st")
	assert(len(columns) > 0, "table_state_init: empty columns")
	assert(len(columns) <= TABLE_COLUMN_COUNT_MAX, "table_state_init: too many columns")
	if st.initialized do return
	st.count = len(columns)
	for index in 0 ..< len(columns) {
		st.order[index] = u8(index)
		st.visible[index] = true
		st.width_px[index] = 0
	}
	st.sort.column = -1
	st.initialized = true
}

// table_visible_count reports how many columns are currently shown.
table_visible_count :: proc(st: ^Table_State) -> int {
	assert(st != nil, "table_visible_count: nil st")
	shown := 0
	for index in 0 ..< st.count {
		if st.visible[index] do shown += 1
	}
	return shown
}

// table_solve_widths resolves the display-ordered, visible column set: it fills
// tracks_out with the effective Track per display slot (a fixed override when
// width_px is set, otherwise the declared Track) and cols_out with the matching
// original column index, returning the visible count. Callers pass tracks_out to
// flex_begin and use cols_out to map a rendered slot back to its column. Pixel
// widths come from the rendered rects (or table_resolve_pixels for tests), so
// this stays a pure mapping and never re-implements the flex solver.
table_solve_widths :: proc(
	st: ^Table_State,
	columns: []Table_Column,
	tracks_out: []Track,
	cols_out: []i32,
) -> (
	n: int,
) {
	assert(st != nil, "table_solve_widths: nil st")
	assert(st.count == len(columns), "table_solve_widths: column count drift")
	assert(len(tracks_out) >= st.count, "table_solve_widths: tracks buffer too small")
	assert(len(cols_out) >= st.count, "table_solve_widths: cols buffer too small")
	for slot in 0 ..< st.count {
		original := int(st.order[slot])
		assert(original < st.count, "table_solve_widths: order out of range")
		if !st.visible[original] do continue
		track := columns[original].track
		if st.width_px[original] > 0 do track = fixed(st.width_px[original])
		tracks_out[n] = track
		cols_out[n] = i32(original)
		n += 1
	}
	assert(n > 0, "table_solve_widths: no visible columns")
	return n
}

// table_resolve_pixels resolves display-ordered tracks into pixel widths using a
// scratch Layout, so the result matches exactly what flex_next produces at
// render time. Pure: Layout is caller-owned scratch, no frame required. Used by
// tests to assert width conservation and available for gridline-edge math.
table_resolve_pixels :: proc(
	tracks: []Track,
	avail_px: i32,
	gap: i32,
	widths_out: []i32,
) -> (
	n: int,
) {
	assert(len(tracks) > 0, "table_resolve_pixels: empty tracks")
	assert(len(tracks) <= MAX_LAYOUT_FLEX, "table_resolve_pixels: too many tracks")
	assert(avail_px >= 0 && gap >= 0, "table_resolve_pixels: negative extent")
	assert(len(widths_out) >= len(tracks), "table_resolve_pixels: buffer too small")
	l: Layout
	row_h: i32 = 1
	layout_begin(&l, 0, 0, avail_px, row_h)
	push_row(&l, row_h, gap)
	flex_begin(&l, tracks, .Start, .Row)
	for index in 0 ..< len(tracks) {
		widths_out[index] = flex_next(&l).w
	}
	layout_pop(&l)
	layout_end(&l)
	return len(tracks)
}

// table_order_move moves the column at display slot `from` to display slot `to`,
// shifting the columns in between. A no-op when they are equal.
table_order_move :: proc(st: ^Table_State, from, to: int) {
	assert(st != nil, "table_order_move: nil st")
	assert(from >= 0 && from < st.count, "table_order_move: from out of range")
	assert(to >= 0 && to < st.count, "table_order_move: to out of range")
	if from == to do return
	moved := st.order[from]
	if from < to {
		for slot in from ..< to {
			st.order[slot] = st.order[slot + 1]
		}
	} else {
		slot := from
		for slot > to {
			st.order[slot] = st.order[slot - 1]
			slot -= 1
		}
	}
	st.order[to] = moved
}

// table_visibility_toggle flips a column's visibility by original index, but
// refuses to hide the last visible column so a table can never vanish. Returns
// true when the visibility actually changed.
table_visibility_toggle :: proc(st: ^Table_State, original: int) -> (changed: bool) {
	assert(st != nil, "table_visibility_toggle: nil st")
	assert(original >= 0 && original < st.count, "table_visibility_toggle: out of range")
	if st.visible[original] && table_visible_count(st) <= 1 do return false
	st.visible[original] = !st.visible[original]
	return true
}

// table_resize_apply records a new pixel width for one original column, clamped
// to the minimum. A resized column becomes fixed at that width via the override.
table_resize_apply :: proc(st: ^Table_State, original: int, new_w: i32, min_px: i32) {
	assert(st != nil, "table_resize_apply: nil st")
	assert(original >= 0 && original < st.count, "table_resize_apply: out of range")
	assert(min_px >= 0, "table_resize_apply: negative minimum")
	st.width_px[original] = max(new_w, min_px)
}

// table_resize_hit finds the inner column border under the pointer. `bounds`
// holds n+1 x coordinates: the left edge, each inter-column edge, and the right
// edge. Only the interior edges bounds[1 ..< n] are grabbable (the outer edges
// are the table frame). Returns the display slot of the column to the LEFT of
// the grabbed border, or -1 when the pointer is not near an inner border.
table_resize_hit :: proc(bounds: []i32, pointer_x: f32, grab_px: i32) -> i32 {
	assert(grab_px >= 0, "table_resize_hit: negative grab")
	if len(bounds) < 3 do return -1 // fewer than two columns: no inner border
	best := i32(-1)
	best_dist := f32(grab_px) + 1
	for edge in 1 ..< len(bounds) - 1 {
		dist := abs(pointer_x - f32(bounds[edge]))
		if dist <= f32(grab_px) && dist < best_dist {
			best = i32(edge - 1)
			best_dist = dist
		}
	}
	return best
}

// table_reorder_drop_slot maps a pointer x to the display slot a dragged column
// would drop into: the number of column midpoints left of the pointer, clamped
// to a valid slot. `bounds` is the same n+1 coordinate array as table_resize_hit.
table_reorder_drop_slot :: proc(bounds: []i32, pointer_x: f32) -> int {
	assert(len(bounds) >= 2, "table_reorder_drop_slot: need at least one column")
	n := len(bounds) - 1
	slot := 0
	for index in 0 ..< n {
		mid := f32(bounds[index] + bounds[index + 1]) * 0.5
		if pointer_x >= mid do slot += 1
	}
	if slot > n - 1 do slot = n - 1
	return slot
}
