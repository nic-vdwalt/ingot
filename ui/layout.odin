// LIB-CANDIDATE: this package must import only core:*.
// Never import app packages - destined for a standalone Odin GUI library.
//
// Cursor-based row/column auto-layout (microui/ImGui style, not a constraint
// solver). A caller-owned Layout carves integer-pixel rects out of a bounded
// frame stack; widgets keep their plain x/y/w/h signatures and simply receive
// the computed rect. Single pass, no measurement recursion, no hidden state:
// weights for flex-like division are declared up front (row_weights) so the
// division happens in one deterministic pass.
package ui

// MAX_LAYOUT_DEPTH bounds frame nesting (Tiger Style: put a limit on
// everything). 16 levels is far deeper than any real panel tree.
MAX_LAYOUT_DEPTH :: 16

// MAX_LAYOUT_WEIGHTS bounds the number of weighted children in one frame.
MAX_LAYOUT_WEIGHTS :: 32

// MAX_LAYOUT_FLEX bounds one flex declaration to fixed caller-owned storage.
MAX_LAYOUT_FLEX :: 32

// Rect_I32 and its float paint counterpart live in types.odin.

Insets_I32 :: struct {
	left, top, right, bottom: i32,
}

insets :: proc(all: i32) -> Insets_I32 {
	assert(all >= 0, "insets: negative inset")
	return {all, all, all, all}
}

rect_inset :: proc(rect: Rect_I32, value: Insets_I32) -> Rect_I32 {
	assert(value.left >= 0 && value.top >= 0, "rect_inset: negative leading inset")
	assert(value.right >= 0 && value.bottom >= 0, "rect_inset: negative trailing inset")
	width := max(i64(rect.w) - i64(value.left) - i64(value.right), i64(0))
	height := max(i64(rect.h) - i64(value.top) - i64(value.bottom), i64(0))
	x := clamp(i64(rect.x) + i64(value.left), i64(min(i32)), i64(max(i32)))
	y := clamp(i64(rect.y) + i64(value.top), i64(min(i32)), i64(max(i32)))
	return {i32(x), i32(y), i32(min(width, i64(max(i32)))), i32(min(height, i64(max(i32))))}
}

// Intrinsic_Size is an allocation-free content measurement. Overflow means
// an extent saturated at max(i32); placement still follows normal clipping.
Intrinsic_Size :: struct {
	w, h:     i32,
	overflow: bool,
}

Intrinsic_Constraints :: struct {
	min_w, min_h: i32,
	max_w, max_h: i32,
}

intrinsic_constraints :: proc(
	min_w: i32 = 0,
	min_h: i32 = 0,
	max_w: i32 = 0,
	max_h: i32 = 0,
) -> Intrinsic_Constraints {
	assert(min_w >= 0 && min_h >= 0, "intrinsic_constraints: negative minimum")
	assert(max_w == 0 || max_w >= min_w, "intrinsic_constraints: invalid width")
	assert(max_h == 0 || max_h >= min_h, "intrinsic_constraints: invalid height")
	return {min_w, min_h, max_w, max_h}
}

intrinsic_constrain :: proc(
	value: Intrinsic_Size,
	constraints: Intrinsic_Constraints,
) -> Intrinsic_Size {
	assert(value.w >= 0 && value.h >= 0, "intrinsic_constrain: negative size")
	assert(
		constraints.min_w >= 0 && constraints.min_h >= 0,
		"intrinsic_constrain: invalid minimum",
	)
	assert(constraints.max_w == 0 || constraints.max_w >= constraints.min_w)
	assert(constraints.max_h == 0 || constraints.max_h >= constraints.min_h)
	w := max(value.w, constraints.min_w)
	h := max(value.h, constraints.min_h)
	if constraints.max_w > 0 do w = min(w, constraints.max_w)
	if constraints.max_h > 0 do h = min(h, constraints.max_h)
	return {w, h, value.overflow}
}

intrinsic_leaf :: proc(w, h: i32) -> Intrinsic_Size {
	assert(w >= 0 && h >= 0, "intrinsic_leaf: negative size")
	return {w = w, h = h}
}

intrinsic_row :: proc(children: []Intrinsic_Size, gap: i32 = 0) -> Intrinsic_Size {
	assert(len(children) <= MAX_LAYOUT_FLEX, "intrinsic_row: count out of bounds")
	assert(gap >= 0, "intrinsic_row: negative gap")
	width := i64(gap) * i64(max(len(children) - 1, 0))
	height: i32
	overflow := false
	for child in children {
		assert(child.w >= 0 && child.h >= 0, "intrinsic_row: negative child")
		width += i64(child.w)
		height = max(height, child.h)
		overflow = overflow || child.overflow
	}
	w, saturated := _intrinsic_extent(width)
	return {w = w, h = height, overflow = overflow || saturated}
}

intrinsic_column :: proc(children: []Intrinsic_Size, gap: i32 = 0) -> Intrinsic_Size {
	assert(len(children) <= MAX_LAYOUT_FLEX, "intrinsic_column: count out of bounds")
	assert(gap >= 0, "intrinsic_column: negative gap")
	width: i32
	height := i64(gap) * i64(max(len(children) - 1, 0))
	overflow := false
	for child in children {
		assert(child.w >= 0 && child.h >= 0, "intrinsic_column: negative child")
		width = max(width, child.w)
		height += i64(child.h)
		overflow = overflow || child.overflow
	}
	h, saturated := _intrinsic_extent(height)
	return {w = width, h = h, overflow = overflow || saturated}
}

intrinsic_padding :: proc(value: Intrinsic_Size, padding: Insets_I32) -> Intrinsic_Size {
	assert(value.w >= 0 && value.h >= 0, "intrinsic_padding: negative size")
	assert(padding.left >= 0 && padding.top >= 0, "intrinsic_padding: negative leading inset")
	assert(padding.right >= 0 && padding.bottom >= 0, "intrinsic_padding: negative trailing inset")
	w, width_overflow := _intrinsic_extent(i64(value.w) + i64(padding.left) + i64(padding.right))
	h, height_overflow := _intrinsic_extent(i64(value.h) + i64(padding.top) + i64(padding.bottom))
	return {w = w, h = h, overflow = value.overflow || width_overflow || height_overflow}
}

@(private = "file")
_intrinsic_extent :: proc(value: i64) -> (i32, bool) {
	assert(value >= 0, "_intrinsic_extent: negative extent")
	if value > i64(max(i32)) do return max(i32), true
	return i32(value), false
}

MAX_FIT_COLUMN_ITEMS :: 64

// A separate flow bound keeps large collections on the existing chunked or virtualized paths.
MAX_FLOW_ITEMS :: 1024

Flow_Layout :: struct {
	bounds:       Rect_I32,
	gap_x, gap_y: i32,
	cursor_x:     i32,
	cursor_y:     i32,
	line_h:       i32,
	content_w:    i32,
	items:        i32,
	open:         bool,
}

flow_begin :: proc(flow: ^Flow_Layout, bounds: Rect_I32, gap_x: i32 = 0, gap_y: i32 = 0) {
	assert(flow != nil, "flow_begin: nil flow")
	assert(!flow.open, "flow_begin: flow already open")
	assert(bounds.w >= 0 && bounds.h >= 0, "flow_begin: negative bounds")
	assert(gap_x >= 0 && gap_y >= 0, "flow_begin: negative gap")
	assert(i64(bounds.x) + i64(bounds.w) <= i64(max(i32)), "flow_begin: horizontal overflow")
	assert(i64(bounds.y) + i64(bounds.h) <= i64(max(i32)), "flow_begin: vertical overflow")
	flow^ = Flow_Layout {
		bounds = bounds,
		gap_x  = gap_x,
		gap_y  = gap_y,
		open   = true,
	}
}

flow_next :: proc(flow: ^Flow_Layout, width, height: i32) -> Rect_I32 {
	assert(flow != nil && flow.open, "flow_next: flow not open")
	assert(width >= 0 && height >= 0, "flow_next: negative size")
	assert(flow.items < MAX_FLOW_ITEMS, "flow_next: too many items")
	item_w := min(width, flow.bounds.w)
	before := flow.gap_x if flow.cursor_x > 0 else 0
	if flow.cursor_x > 0 && i64(flow.cursor_x) + i64(before) + i64(item_w) > i64(flow.bounds.w) {
		next_y := i64(flow.cursor_y) + i64(flow.line_h) + i64(flow.gap_y)
		assert(next_y <= i64(max(i32)), "flow_next: vertical overflow")
		flow.cursor_x = 0
		flow.cursor_y = i32(next_y)
		flow.line_h = 0
		before = 0
	}
	next_x := i64(flow.cursor_x) + i64(before) + i64(item_w)
	assert(next_x <= i64(flow.bounds.w), "flow_next: horizontal overflow")
	assert(i64(flow.bounds.y) + i64(flow.cursor_y) <= i64(max(i32)), "flow_next: y overflow")
	flow.cursor_x += before
	result := Rect_I32 {
		flow.bounds.x + flow.cursor_x,
		flow.bounds.y + flow.cursor_y,
		item_w,
		height,
	}
	flow.cursor_x = i32(next_x)
	flow.line_h = max(flow.line_h, height)
	flow.content_w = max(flow.content_w, flow.cursor_x)
	flow.items += 1
	return result
}

flow_end :: proc(flow: ^Flow_Layout) -> Rect_I32 {
	assert(flow != nil && flow.open, "flow_end: flow not open")
	assert(flow.items >= 0 && flow.items <= MAX_FLOW_ITEMS, "flow_end: corrupt flow")
	content_h := i64(flow.cursor_y) + i64(flow.line_h)
	assert(content_h <= i64(max(i32)), "flow_end: content overflow")
	result := Rect_I32{flow.bounds.x, flow.bounds.y, flow.content_w, i32(content_h)}
	flow.open = false
	return result
}

// Fit_Column stacks fixed-height rows and reports the extent they consumed.
//
// A column may be bounded (see fit_column_begin_bounded). An unbounded column
// grows without limit, which is only correct when the caller has already proven
// the content fits; a panel laid out against a window edge has not, and an
// unbounded column will happily place rows past the bottom of the screen.
Fit_Column :: struct {
	x, y, w:  i32,
	cursor:   i32,
	gap:      i32,
	items:    i32,
	max_h:    i32,
	bounded:  bool,
	overflow: i32,
	open:     bool,
}

fit_column_begin :: proc(column: ^Fit_Column, x, y, w: i32, gap: i32 = 0) {
	assert(column != nil, "fit_column_begin: nil column")
	assert(!column.open, "fit_column_begin: column already open")
	assert(w >= 0 && gap >= 0, "fit_column_begin: negative dimension")
	column^ = Fit_Column {
		x    = x,
		y    = y,
		w    = w,
		gap  = gap,
		open = true,
	}
}

// fit_column_begin_bounded limits the column to max_h pixels. Rows that do not
// fit are returned with zero height (slot_visible reports them as invisible,
// so widgets skip them) and their lost pixels accumulate in fit_column_overflow.
//
// Why clamp rather than assert: max_h is typically computed as
// `available_bottom - cursor`, which legitimately goes negative on a short
// window. Asserting there turns a layout that should degrade into a crash.
fit_column_begin_bounded :: proc(column: ^Fit_Column, x, y, w, max_h: i32, gap: i32 = 0) {
	assert(column != nil, "fit_column_begin_bounded: nil column")
	assert(!column.open, "fit_column_begin_bounded: column already open")
	assert(gap >= 0, "fit_column_begin_bounded: negative gap")
	column^ = Fit_Column {
		x       = x,
		y       = y,
		w       = max(w, 0),
		gap     = gap,
		max_h   = max(max_h, 0),
		bounded = true,
		open    = true,
	}
}

// fit_column_remaining reports the unused pixels of a bounded column. An
// unbounded column always reports max(i32).
fit_column_remaining :: proc(column: ^Fit_Column) -> i32 {
	assert(column != nil, "fit_column_remaining: nil column")
	if !column.bounded do return max(i32)
	return max(column.max_h - column.cursor, 0)
}

// fit_column_overflow reports the content pixels a bounded column could not
// place. Valid during and after the column. Zero means everything fit.
fit_column_overflow :: proc(column: ^Fit_Column) -> i32 {
	assert(column != nil, "fit_column_overflow: nil column")
	assert(column.overflow >= 0, "fit_column_overflow: corrupt column")
	return column.overflow
}

fit_column_next :: proc(column: ^Fit_Column, height: i32) -> Rect_I32 {
	assert(column != nil && column.open, "fit_column_next: column not open")
	assert(height >= 0, "fit_column_next: negative height")
	assert(column.items < MAX_FIT_COLUMN_ITEMS, "fit_column_next: too many items")
	before := column.gap if column.items > 0 else 0
	granted := height
	if column.bounded {
		remaining := max(column.max_h - column.cursor, 0)
		before = min(before, remaining)
		remaining -= before
		granted = min(height, remaining)
		assert(column.overflow <= 0x7fff_ffff - (height - granted), "fit_column_next: overflow")
		column.overflow += height - granted
	}
	assert(column.cursor <= 0x7fff_ffff - before - granted, "fit_column_next: extent overflow")
	column.cursor += before
	result := Rect_I32{column.x, column.y + column.cursor, column.w, granted}
	column.cursor += granted
	column.items += 1
	return result
}

fit_column_space :: proc(column: ^Fit_Column, height: i32) {
	assert(column != nil && column.open, "fit_column_space: column not open")
	assert(height >= 0, "fit_column_space: negative height")
	granted := height
	if column.bounded {
		granted = min(height, max(column.max_h - column.cursor, 0))
		assert(column.overflow <= 0x7fff_ffff - (height - granted), "fit_column_space: overflow")
		column.overflow += height - granted
	}
	assert(column.cursor <= 0x7fff_ffff - granted, "fit_column_space: extent overflow")
	column.cursor += granted
}

fit_column_end :: proc(column: ^Fit_Column) -> Rect_I32 {
	assert(column != nil && column.open, "fit_column_end: column not open")
	assert(
		column.cursor >= 0 && column.items <= MAX_FIT_COLUMN_ITEMS,
		"fit_column_end: corrupt column",
	)
	assert(
		!column.bounded || column.cursor <= column.max_h,
		"fit_column_end: bounded column exceeded its budget",
	)
	result := Rect_I32{column.x, column.y, column.w, column.cursor}
	column.open = false
	return result
}

// MAX_GRID_ITEMS bounds one grid to fixed work per frame; larger collections
// belong on the chunked or virtualized paths, matching MAX_FLOW_ITEMS.
MAX_GRID_ITEMS :: 4096

// Grid places caller-drawn cells on a fixed column count with a uniform row
// height, in row-major order. Column widths come from cumulative division
// (like next_weighted), so every row spans the bounds exactly and no call
// site does per-cell x/y arithmetic. Single pass, no retained children: the
// caller declares the shape up front and grid_end reports the consumed rect.
Grid :: struct {
	bounds:       Rect_I32,
	cols:         i32,
	row_h:        i32,
	gap_x, gap_y: i32,
	index:        i32,
	open:         bool,
}

grid_begin :: proc(
	grid: ^Grid,
	bounds: Rect_I32,
	cols, row_h: i32,
	gap_x: i32 = 0,
	gap_y: i32 = 0,
) {
	assert(grid != nil, "grid_begin: nil grid")
	assert(!grid.open, "grid_begin: grid already open")
	assert(bounds.w >= 0 && bounds.h >= 0, "grid_begin: negative bounds")
	assert(cols > 0 && cols <= MAX_GRID_ITEMS, "grid_begin: column count out of bounds")
	assert(row_h >= 0 && gap_x >= 0 && gap_y >= 0, "grid_begin: negative dimension")
	assert(i64(bounds.x) + i64(bounds.w) <= i64(max(i32)), "grid_begin: horizontal overflow")
	grid^ = Grid {
		bounds = bounds,
		cols   = cols,
		row_h  = row_h,
		gap_x  = gap_x,
		gap_y  = gap_y,
		open   = true,
	}
}

// grid_next returns the next cell in row-major order. Gaps that do not fit a
// narrow bounds clamp the shared content width to zero instead of trapping,
// so a squeezed window degrades to invisible cells (slot_visible is false).
grid_next :: proc(grid: ^Grid) -> Rect_I32 {
	assert(grid != nil && grid.open, "grid_next: grid not open")
	assert(grid.index < MAX_GRID_ITEMS, "grid_next: too many items")
	col := i64(grid.index % grid.cols)
	row := i64(grid.index / grid.cols)
	content_w := max(i64(grid.bounds.w) - i64(grid.gap_x) * i64(grid.cols - 1), 0)
	x0 := col * content_w / i64(grid.cols)
	x1 := (col + 1) * content_w / i64(grid.cols)
	x := i64(grid.bounds.x) + x0 + col * i64(grid.gap_x)
	y := i64(grid.bounds.y) + row * (i64(grid.row_h) + i64(grid.gap_y))
	assert(x + (x1 - x0) <= i64(max(i32)), "grid_next: horizontal overflow")
	assert(y + i64(grid.row_h) <= i64(max(i32)), "grid_next: vertical overflow")
	grid.index += 1
	return Rect_I32{i32(x), i32(y), i32(x1 - x0), grid.row_h}
}

// grid_end reports the content rect the placed cells consumed and closes the
// grid for reuse.
grid_end :: proc(grid: ^Grid) -> Rect_I32 {
	assert(grid != nil && grid.open, "grid_end: grid not open")
	assert(grid.index >= 0 && grid.index <= MAX_GRID_ITEMS, "grid_end: corrupt grid")
	rows := i64((grid.index + grid.cols - 1) / grid.cols)
	content_h: i64
	if rows > 0 do content_h = rows * i64(grid.row_h) + (rows - 1) * i64(grid.gap_y)
	assert(i64(grid.bounds.y) + content_h <= i64(max(i32)), "grid_end: content overflow")
	result := Rect_I32{grid.bounds.x, grid.bounds.y, grid.bounds.w, i32(content_h)}
	grid.open = false
	return result
}

// grid_visible_range reports the half-open index range [first, end) whose
// cells intersect the vertical band [top, bottom], for a grid whose geometry
// matches grid_begin's arguments. Pure: it does not touch the grid's cursor,
// so a caller can compute the range up front and then place only those cells.
//
// This exists so a large grid can skip *building* off-screen cells - labels,
// measurement, interaction - not just skip painting them. Painting is already
// culled by the frame's cull band (widgets.odin); the remaining per-cell cost
// is the caller's, and only the caller can avoid it.
//
// `count` is the total number of cells the caller intends to place. The
// returned range is always within [0, count], and is empty (first == end)
// when nothing intersects.
grid_visible_range :: proc(
	bounds: Rect_I32,
	cols, row_h, gap_y, count: i32,
	top, bottom: i32,
) -> (
	first: i32,
	end: i32,
) {
	assert(cols > 0, "grid_visible_range: non-positive column count")
	assert(row_h >= 0, "grid_visible_range: negative row height")
	assert(gap_y >= 0, "grid_visible_range: negative gap")
	assert(count >= 0 && count <= MAX_GRID_ITEMS, "grid_visible_range: count out of bounds")
	assert(top <= bottom, "grid_visible_range: inverted band")
	if count == 0 do return 0, 0
	// A zero-height stride would make every row start at the same y, so the
	// row arithmetic below cannot select a subset. Draw everything and let
	// the paint-level cull handle it.
	stride := i64(row_h) + i64(gap_y)
	if stride <= 0 do return 0, count
	rows := i64((count + cols - 1) / cols)

	// Row r spans [bounds.y + r*stride, bounds.y + r*stride + row_h].
	// Visible when that span intersects [top, bottom]:
	//   first visible row: smallest r with r*stride >= top - bounds.y - row_h
	//                      -> ceiling, or a row whose bottom edge stops just
	//                         short of the band would be included
	//   last visible row:  largest  r with r*stride <= bottom - bounds.y
	//                      -> floor
	first_row := _grid_row_ceil(i64(top) - i64(bounds.y) - i64(row_h), stride)
	last_row := _grid_row_floor(i64(bottom) - i64(bounds.y), stride)
	first_row = clamp(first_row, 0, rows)
	last_row = clamp(last_row, -1, rows - 1)
	if last_row < first_row do return 0, 0

	first = i32(min(first_row * i64(cols), i64(count)))
	end = i32(min((last_row + 1) * i64(cols), i64(count)))
	assert(first >= 0 && first <= count, "grid_visible_range: first out of bounds")
	assert(end >= first && end <= count, "grid_visible_range: end out of bounds")
	return first, end
}

// _grid_row_floor divides toward negative infinity. Odin's `/` truncates
// toward zero, which for a negative offset would round the wrong way.
@(private = "file")
_grid_row_floor :: proc(value, stride: i64) -> i64 {
	assert(stride > 0, "_grid_row_floor: non-positive stride")
	quotient := value / stride
	if value % stride != 0 && value < 0 do quotient -= 1
	return quotient
}

// _grid_row_ceil divides toward positive infinity, for the same reason.
@(private = "file")
_grid_row_ceil :: proc(value, stride: i64) -> i64 {
	assert(stride > 0, "_grid_row_ceil: non-positive stride")
	quotient := value / stride
	if value % stride != 0 && value > 0 do quotient += 1
	return quotient
}

// grid_skip_to advances the grid's cursor to `index` without placing cells, so
// a caller that computed a visible range with grid_visible_range can start
// there and still have grid_end measure the full content height.
grid_skip_to :: proc(grid: ^Grid, index: i32) {
	assert(grid != nil && grid.open, "grid_skip_to: grid not open")
	assert(index >= grid.index, "grid_skip_to: cannot rewind the cursor")
	assert(index <= MAX_GRID_ITEMS, "grid_skip_to: index out of bounds")
	grid.index = index
}

Layout_Kind :: enum u8 {
	Column, // children stack vertically; main axis = y
	Row, // children stack horizontally; main axis = x
}

// Flex_Axis lets a caller state which way it believes a declared flex run
// travels, so flex_begin can reject a run opened against the wrong frame.
//
// A separate type rather than an optional Layout_Kind: several places branch
// as `if kind == .Column { ... } else { ... }`, so an extra Layout_Kind member
// would be treated as a row by every one of them. Adding a state that lays out
// silently-but-wrongly to fix a bug about laying out silently-but-wrongly is
// not a trade worth making. Unspecified is the zero value, so omitting the
// argument keeps the previous behaviour exactly.
Flex_Axis :: enum u8 {
	Unspecified, // no opinion; no axis check is performed
	Column, // caller expects the run to travel down the main axis y
	Row, // caller expects the run to travel across the main axis x
}

Cross_Align :: enum u8 {
	Stretch, // children fill the cross axis (default)
	Start,
	Center,
	End,
}

// Main_Align packs a declared flex run along the main axis. It only applies
// to flex containers because only a declared run knows its total size before
// any child is drawn; ordinary cursor rows would need a second pass.
Main_Align :: enum u8 {
	Start, // pack at the cursor (default)
	Center, // center the run inside the free space
	End, // pack against the far edge
	Space_Between, // distribute the free space between siblings
}

Space :: enum u8 {
	None,
	XS,
	SM,
	MD,
	LG,
	XL,
}

Layout_Style :: struct {
	gap:     Space,
	padding: Space,
	align:   Cross_Align,
}

Track_Kind :: enum u8 {
	Fit,
	Grow,
	Fixed,
	Percent,
	Hug,
}

// Track describes one sibling on the active frame's main axis. max_size is
// inclusive; zero means unbounded so the zero value remains useful. A Track is
// unit-agnostic: the facade tier hands it design units and scales it once, while
// the Layout tier hands it screen-space pixels.
Track :: struct {
	kind:     Track_Kind,
	basis:    i32,
	weight:   i32,
	percent:  f32,
	min_size: i32,
	max_size: i32,
}

Layout_Frame :: struct {
	kind:         Layout_Kind,
	rect:         Rect_I32, // full frame area
	cursor:       i32, // advance along the main axis, relative to rect
	gap:          i32, // spacing inserted between consecutive items
	cross_align:  Cross_Align,
	// Weighted-division state (row_weights / next_weighted).
	weight_total: i32, // sum of declared weights; 0 = none declared
	weight_space: i32, // main-axis pixels being divided
	weight_acc:   i32, // sum of weights consumed so far
	weight_left:  i32, // declared children not yet consumed
	weight_count: i32,
	weight_index: i32,
	weights:      [MAX_LAYOUT_WEIGHTS]i32,
	// Flex sizing is resolved up front and consumed by flex_next in order.
	flex_sizes:   [MAX_LAYOUT_FLEX]i32,
	flex_count:   i32,
	flex_index:   i32,
	// Space_Between leftover, distributed between flex siblings by cumulative
	// division so the shares sum exactly.
	flex_between: i32,
}

// Layout is caller-owned per-frame scratch state; zero value is ready to use.
Layout :: struct {
	stack: [MAX_LAYOUT_DEPTH]Layout_Frame,
	depth: int,
}

// fit uses a caller-measured intrinsic size and may compress to min_size.
fit :: proc(basis: i32, min_size: i32 = 0, max_size: i32 = 0) -> Track {
	assert(basis >= 0, "fit: negative basis")
	assert(min_size >= 0, "fit: negative minimum")
	assert(max_size == 0 || max_size >= min_size, "fit: invalid maximum")
	return Track{kind = .Fit, basis = basis, min_size = min_size, max_size = max_size}
}

// hug preserves a measured intrinsic basis until explicitly shrinkable tracks
// have consumed their compression capacity.
hug :: proc(basis: i32, min_size: i32 = 0, max_size: i32 = 0) -> Track {
	assert(basis >= 0, "hug: negative basis")
	assert(min_size >= 0, "hug: negative minimum")
	assert(max_size == 0 || max_size >= min_size, "hug: invalid maximum")
	return Track{kind = .Hug, basis = basis, min_size = min_size, max_size = max_size}
}

intrinsic_fit_width :: proc(value: Intrinsic_Size, min_size: i32 = 0, max_size: i32 = 0) -> Track {
	assert(!value.overflow, "intrinsic_fit_width: overflowed measurement")
	assert(value.w >= 0 && value.h >= 0, "intrinsic_fit_width: negative size")
	return fit(value.w, min_size, max_size)
}

intrinsic_fit_height :: proc(
	value: Intrinsic_Size,
	min_size: i32 = 0,
	max_size: i32 = 0,
) -> Track {
	assert(!value.overflow, "intrinsic_fit_height: overflowed measurement")
	assert(value.w >= 0 && value.h >= 0, "intrinsic_fit_height: negative size")
	return fit(value.h, min_size, max_size)
}

// grow shares free space by weight after fixed, fit, and percent bases.
grow :: proc(weight: i32 = 1, min_size: i32 = 0, max_size: i32 = 0) -> Track {
	assert(weight > 0, "grow: weight must be positive")
	assert(min_size >= 0, "grow: negative minimum")
	assert(max_size == 0 || max_size >= min_size, "grow: invalid maximum")
	return Track{kind = .Grow, weight = weight, min_size = min_size, max_size = max_size}
}

fixed :: proc(size: i32) -> Track {
	assert(size >= 0, "fixed: negative size")
	return Track{kind = .Fixed, basis = size, min_size = size, max_size = size}
}

// percent uses a fraction of remaining frame space after inter-item gaps.
percent :: proc(value: f32, min_size: i32 = 0, max_size: i32 = 0) -> Track {
	assert(value >= 0 && value <= 1, "percent: value outside 0..1")
	assert(min_size >= 0, "percent: negative minimum")
	assert(max_size == 0 || max_size >= min_size, "percent: invalid maximum")
	return Track{kind = .Percent, percent = value, min_size = min_size, max_size = max_size}
}

// layout_begin opens the root column over the given area. Must be balanced
// with layout_end; nesting Layouts is fine because callers own the struct.
layout_begin :: proc(l: ^Layout, x, y, w, h: i32, gap: i32 = 0) {
	assert(l != nil && l.depth == 0, "layout_begin: layout already open")
	assert(w >= 0 && h >= 0 && gap >= 0, "layout_begin: negative size")
	assert(i64(x) + i64(w) <= i64(max(i32)), "layout_begin: horizontal extent overflow")
	assert(i64(y) + i64(h) <= i64(max(i32)), "layout_begin: vertical extent overflow")
	l.stack[0] = Layout_Frame {
		kind = .Column,
		rect = Rect_I32{x, y, w, h},
		gap  = gap,
	}
	l.depth = 1
}

// layout_end closes the root frame and resets the layout for reuse.
layout_end :: proc(l: ^Layout) {
	assert(l != nil, "layout_end: nil l")
	assert(l.depth == 1, "layout_end: unbalanced push/pop")
	assert(l.stack[0].cursor >= 0, "layout_end: corrupt cursor")
	assert(
		l.stack[0].flex_index == l.stack[0].flex_count,
		"layout_end: declared flex sizes not fully consumed",
	)
	l.depth = 0
}

layout_push_rect :: proc(
	l: ^Layout,
	kind: Layout_Kind,
	rect: Rect_I32,
	gap: i32 = 0,
	cross_align: Cross_Align = .Stretch,
) {
	assert(l != nil, "layout_push_rect: nil layout")
	assert(l.depth > 0 && l.depth < MAX_LAYOUT_DEPTH, "layout_push_rect: depth out of bounds")
	assert(rect.w >= 0 && rect.h >= 0, "layout_push_rect: negative rectangle")
	assert(gap >= 0, "layout_push_rect: negative gap")
	l.stack[l.depth] = Layout_Frame {
		kind        = kind,
		rect        = rect,
		gap         = gap,
		cross_align = cross_align,
	}
	l.depth += 1
}

// push_row carves a full-width strip of height h from the current column and
// makes it the active frame, laying children out left-to-right.
push_row :: proc(l: ^Layout, h: i32, gap: i32 = 0, cross_align: Cross_Align = .Stretch) {
	assert(l.depth > 0 && l.depth < MAX_LAYOUT_DEPTH, "push_row: depth out of bounds")
	assert(_top(l).kind == .Column, "push_row: current frame must be a column")
	layout_push_rect(l, .Row, next(l, h), gap, cross_align)
}

// push_column makes the current frame's remaining space the active column.
// Inside a row this fills everything right of the cursor; use next() first to
// carve fixed-width cells.
push_column :: proc(l: ^Layout, gap: i32 = 0, cross_align: Cross_Align = .Stretch) {
	assert(l != nil, "push_column: nil l")
	assert(l.depth > 0 && l.depth < MAX_LAYOUT_DEPTH, "push_column: depth out of bounds")
	r := remaining(l)
	assert(r.w >= 0 && r.h >= 0, "push_column: negative remaining space")
	// Consume the parent's remaining space so siblings after layout_pop() don't
	// overlap the column.
	f := _top(l)
	f.cursor = _main_extent(f^)
	layout_push_rect(l, .Column, r, gap, cross_align)
}

push_column_sized :: proc(l: ^Layout, w: i32, gap: i32 = 0, cross_align: Cross_Align = .Stretch) {
	assert(l.depth > 0 && l.depth < MAX_LAYOUT_DEPTH, "push_column_sized: depth out of bounds")
	assert(_top(l).kind == .Row, "push_column_sized: current frame must be a row")
	layout_push_rect(l, .Column, next(l, w), gap, cross_align)
}

layout_inset :: proc(l: ^Layout, value: Insets_I32) {
	assert(l != nil && l.depth > 0, "layout_inset: layout not begun")
	f := _top(l)
	assert(f.cursor == 0, "layout_inset: frame already consumed")
	assert(f.weight_left == 0 && f.flex_index == f.flex_count, "layout_inset: sequence active")
	f.rect = rect_inset(f.rect, value)
}

// pop closes the innermost pushed frame (row or column).
layout_pop :: proc(l: ^Layout) {
	assert(l != nil, "layout_pop: nil l")
	assert(l.depth > 1, "layout_pop: nothing pushed above the root")
	assert(_top(l).weight_left == 0, "layout_pop: declared weights not fully consumed")
	assert(
		_top(l).flex_index == _top(l).flex_count,
		"layout_pop: declared flex sizes not fully consumed",
	)
	l.depth -= 1
}

// flex_begin resolves one bounded sibling sequence before any child is drawn.
// justify packs the resolved run along the main axis; free space only exists
// when no uncapped grow track absorbed it.
//
// axis states which way the caller believes the tracks run. It defaults to
// .Unspecified so every existing call is unaffected, but passing the intended
// axis converts the worst failure this API has into an assertion: tracks meant
// for a row, declared against a column frame, carve the frame's HEIGHT into N
// bands instead of its width into N cells. Every cell then draws at the same
// x, and because the run is still fully consumed, flex_end, layout_pop and
// layout_end all pass. The geometry is silently wrong and nothing in the
// library can tell, because the intent exists only at the call site.
//
// This mirrors push_row, which already asserts its parent frame is a column:
// the library checked the axis when pushing a FRAME but not when declaring a
// SEQUENCE inside one.
flex_begin :: proc(
	l: ^Layout,
	sizes: []Track,
	justify: Main_Align = .Start,
	axis: Flex_Axis = .Unspecified,
) {
	assert(l != nil, "flex_begin: nil l")
	assert(l.depth > 0, "flex_begin: layout not begun")
	assert(len(sizes) > 0 && len(sizes) <= MAX_LAYOUT_FLEX, "flex_begin: count out of bounds")
	f := _top(l)
	assert(axis_matches(axis, f.kind), "flex_begin: axis mismatch with active frame")
	assert(f.weight_left == 0, "flex_begin: weighted sequence is active")
	assert(f.flex_index == f.flex_count, "flex_begin: previous flex sequence not consumed")
	gap_total := i64(f.gap) * i64(len(sizes) - 1)
	space_i64 := max(i64(_main_extent(f^)) - i64(f.cursor) - gap_total, i64(0))
	space := i32(min(space_i64, i64(max(i32))))
	_flex_resolve(f, sizes, space)
	_flex_justify(f, space, justify)
}

// flex_end closes a declared run. flex_next_sized auto-terminates a fully
// consumed run, so this exists to fail an *under*-consumed one at the call
// site rather than several frames later inside layout_pop.
flex_end :: proc(l: ^Layout) {
	assert(l != nil, "flex_end: nil l")
	assert(l.depth > 0, "flex_end: layout not begun")
	f := _top(l)
	assert(f.flex_index == f.flex_count, "flex_end: declared flex sizes not fully consumed")
	f.flex_count = 0
	f.flex_index = 0
	f.flex_between = 0
}

layout_flex_active :: proc(l: ^Layout) -> bool {
	assert(l != nil, "layout_flex_active: nil layout")
	assert(l.depth > 0, "layout_flex_active: layout not begun")
	return _top(l).flex_count > 0
}

// layout_cross_align reports the active frame's cross-axis alignment so the
// facade tier can branch on it without reaching into the frame stack.
layout_cross_align :: proc(l: ^Layout) -> Cross_Align {
	assert(l != nil, "layout_cross_align: nil layout")
	assert(l.depth > 0, "layout_cross_align: layout not begun")
	return _top(l).cross_align
}

// flex_next emits the next pre-resolved sibling using ordinary cursor advance.
flex_next :: proc(l: ^Layout) -> Rect_I32 {
	assert(l != nil && l.depth > 0, "flex_next: layout not begun")
	f := _top(l)
	cross_size := f.rect.w if f.kind == .Column else f.rect.h
	return flex_next_sized(l, cross_size)
}

flex_next_sized :: proc(l: ^Layout, cross_size: i32) -> Rect_I32 {
	assert(l != nil, "flex_next_sized: nil l")
	assert(l.depth > 0, "flex_next_sized: layout not begun")
	assert(cross_size >= 0, "flex_next_sized: negative cross size")
	f := _top(l)
	assert(f.flex_index < f.flex_count, "flex_next_sized: no flex size available")
	if f.flex_between > 0 && f.flex_index > 0 {
		// Cumulative division over the gaps so the shares sum exactly to the
		// leftover recorded by flex_begin.
		gaps := i64(f.flex_count - 1)
		before := (i64(f.flex_index) - 1) * i64(f.flex_between) / gaps
		after := i64(f.flex_index) * i64(f.flex_between) / gaps
		spacer(l, i32(after - before))
	}
	size := f.flex_sizes[f.flex_index]
	f.flex_index += 1
	if f.flex_index == f.flex_count {
		f.flex_count = 0
		f.flex_index = 0
		f.flex_between = 0
	}
	return next_sized(l, size, cross_size)
}

// next carves main_size pixels along the main axis, spanning the full cross
// axis. Overflow is clipped to the frame and never advances beyond its extent.
next :: proc(l: ^Layout, main_size: i32) -> Rect_I32 {
	assert(l != nil, "next: nil l")
	assert(l.depth > 0, "next: layout not begun")
	assert(main_size >= 0, "next: negative size")
	f := _top(l)
	extent := i64(_main_extent(f^))
	cursor := min(max(i64(f.cursor), i64(0)), extent)
	avail := extent - cursor
	size := min(i64(main_size), avail)
	r: Rect_I32
	if f.kind == .Column {
		r = Rect_I32{f.rect.x, i32(i64(f.rect.y) + cursor), f.rect.w, i32(size)}
	} else {
		r = Rect_I32{i32(i64(f.rect.x) + cursor), f.rect.y, i32(size), f.rect.h}
	}
	advance := size
	if size > 0 && cursor + size < extent do advance += i64(f.gap)
	f.cursor = i32(min(cursor + advance, extent))
	return r
}

// next_sized carves main_size like next but limits the cross axis to
// cross_size, positioned by the frame's cross_align.
next_sized :: proc(l: ^Layout, main_size, cross_size: i32) -> Rect_I32 {
	assert(l != nil, "next_sized: nil l")
	assert(l.depth > 0, "next_sized: layout not begun")
	assert(cross_size >= 0, "next_sized: negative cross size")
	f := _top(l)
	r := next(l, main_size)
	cross_extent := f.rect.w if f.kind == .Column else f.rect.h
	c := min(cross_size, cross_extent)
	offset: i32
	switch f.cross_align {
	case .Stretch:
		return r // ignore cross_size; fill
	case .Start:
		offset = 0
	case .Center:
		offset = (cross_extent - c) / 2
	case .End:
		offset = cross_extent - c
	}
	if f.kind == .Column {
		r.x += offset
		r.w = c
	} else {
		r.y += offset
		r.h = c
	}
	return r
}

// spacer advances the cursor by px without emitting a rect (gap is not added).
spacer :: proc(l: ^Layout, px: i32) {
	assert(l != nil, "spacer: nil l")
	assert(l.depth > 0, "spacer: layout not begun")
	assert(px >= 0, "spacer: negative spacer")
	f := _top(l)
	avail := _main_extent(f^) - f.cursor
	f.cursor += min(px, max(avail, 0))
}

// remaining returns the not-yet-carved area of the current frame.
remaining :: proc(l: ^Layout) -> Rect_I32 {
	assert(l != nil, "remaining: nil l")
	assert(l.depth > 0, "remaining: layout not begun")
	f := _top(l)
	avail := _main_extent(f^) - f.cursor
	assert(f.cursor >= 0, "remaining: corrupt cursor")
	if avail < 0 do avail = 0
	if f.kind == .Column {
		return Rect_I32{f.rect.x, f.rect.y + f.cursor, f.rect.w, avail}
	}
	return Rect_I32{f.rect.x + f.cursor, f.rect.y, avail, f.rect.h}
}

take_remaining :: proc(l: ^Layout) -> Rect_I32 {
	assert(l != nil && l.depth > 0, "take_remaining: layout not begun")
	r := remaining(l)
	f := _top(l)
	f.cursor = _main_extent(f^)
	return r
}

// layout_kind returns the active frame's axis kind (Column or Row).
layout_kind :: proc(l: ^Layout) -> Layout_Kind {
	assert(l != nil)
	assert(l.depth > 0 && l.depth <= len(l.stack), "layout_kind: layout not begun")
	return l.stack[l.depth - 1].kind
}

// row_weights declares the weighted children of the current frame up front so
// the remaining main-axis space (minus gaps between them) can be divided in a
// single deterministic pass by subsequent next_weighted calls.
row_weights :: proc(l: ^Layout, weights: []i32) {
	assert(l != nil, "row_weights: nil l")
	assert(l.depth > 0, "row_weights: layout not begun")
	assert(
		len(weights) > 0 && len(weights) <= MAX_LAYOUT_WEIGHTS,
		"row_weights: count out of bounds",
	)
	f := _top(l)
	assert(f.flex_index == f.flex_count, "row_weights: flex sequence is active")
	assert(f.weight_left == 0, "row_weights: previous weights not consumed")
	total: i64
	for w in weights {
		assert(w > 0, "row_weights: weights must be positive")
		total += i64(w)
	}
	assert(total <= i64(max(i32)), "row_weights: total weight overflow")
	avail := max(i64(_main_extent(f^)) - i64(f.cursor), i64(0))
	gaps := i64(f.gap) * i64(len(weights) - 1)
	space := max(avail - gaps, i64(0))
	f.weight_total = i32(total)
	f.weight_space = i32(space)
	f.weight_acc = 0
	f.weight_left = i32(len(weights))
	f.weight_count = i32(len(weights))
	f.weight_index = 0
	for weight, index in weights do f.weights[index] = weight
}

// next_weighted carves the next weighted child's share. The weight must match
// the corresponding entry declared via row_weights; rounding is distributed
// so all shares sum exactly to the declared space.
next_weighted :: proc(l: ^Layout, weight: i32) -> Rect_I32 {
	assert(l != nil, "next_weighted: nil l")
	assert(l.depth > 0, "next_weighted: layout not begun")
	assert(weight > 0, "next_weighted: weight must be positive")
	f := _top(l)
	assert(f.weight_left > 0, "next_weighted: no weights declared (call row_weights)")
	assert(f.weight_index >= 0 && f.weight_index < f.weight_count)
	assert(weight == f.weights[f.weight_index], "next_weighted: weight differs from declaration")
	// Cumulative division: share_i = floor(acc+w * S/T) - floor(acc * S/T)
	// guarantees the shares sum exactly to weight_space.
	before := i64(f.weight_acc) * i64(f.weight_space) / i64(f.weight_total)
	after := (i64(f.weight_acc) + i64(weight)) * i64(f.weight_space) / i64(f.weight_total)
	assert(after >= before && after - before <= i64(max(i32)), "next_weighted: invalid share")
	f.weight_acc += weight
	f.weight_left -= 1
	f.weight_index += 1
	if f.weight_left == 0 {
		assert(f.weight_index == f.weight_count)
		f.weight_total = 0
		f.weight_space = 0
		f.weight_acc = 0
		f.weight_count = 0
		f.weight_index = 0
	}
	return next(l, i32(after - before))
}

// _flex_justify packs a freshly resolved run along the main axis. Center and
// End advance the cursor once; Space_Between records the leftover so
// flex_next_sized can distribute it between siblings.
@(private = "file")
_flex_justify :: proc(f: ^Layout_Frame, space: i32, justify: Main_Align) {
	assert(f != nil, "_flex_justify: nil frame")
	assert(space >= 0 && f.flex_count > 0, "_flex_justify: invalid input")
	f.flex_between = 0
	if justify == .Start do return
	total: i64
	for size in f.flex_sizes[:f.flex_count] do total += i64(size)
	leftover := i32(clamp(i64(space) - total, 0, i64(max(i32))))
	if leftover == 0 do return
	switch justify {
	case .Start:
	case .Center:
		f.cursor += leftover / 2
	case .End:
		f.cursor += leftover
	case .Space_Between:
		// A single sibling has no between-gaps; pack it at the start.
		if f.flex_count > 1 do f.flex_between = leftover
	}
	assert(f.cursor >= 0, "_flex_justify: corrupt cursor")
}

@(private = "file")
_flex_clamp :: proc(size, min_size, max_size: i32) -> i32 {
	assert(size >= 0 && min_size >= 0, "_flex_clamp: negative size")
	assert(max_size == 0 || max_size >= min_size, "_flex_clamp: invalid maximum")
	result := max(size, min_size)
	if max_size > 0 do result = min(result, max_size)
	assert(result >= min_size, "_flex_clamp: result below minimum")
	return result
}

@(private = "file")
_flex_compression_priority :: proc(track: Track) -> i32 {
	switch track.kind {
	case .Fit, .Grow:
		return 0
	case .Hug:
		return 1
	case .Fixed, .Percent:
		return -1
	}
	unreachable()
}

@(private = "file")
_flex_compress_priority :: proc(
	resolved: ^[MAX_LAYOUT_FLEX]i32,
	sizes: []Track,
	overflow: i32,
	priority: i32,
) -> i32 {
	assert(resolved != nil, "_flex_compress_priority: nil sizes")
	assert(len(sizes) <= MAX_LAYOUT_FLEX, "_flex_compress_priority: count out of bounds")
	assert(overflow > 0, "_flex_compress_priority: non-positive overflow")
	assert(priority >= 0 && priority <= 1, "_flex_compress_priority: invalid priority")
	capacity: i64
	for size, index in sizes {
		if _flex_compression_priority(size) != priority do continue
		item_capacity := resolved[index] - size.min_size
		assert(item_capacity >= 0, "_flex_compress_priority: size below minimum")
		capacity += i64(item_capacity)
	}
	if capacity == 0 do return overflow
	shrink := min(i64(overflow), capacity)
	consumed: i64
	acc: i64
	for size, index in sizes {
		if _flex_compression_priority(size) != priority do continue
		item_capacity := i64(resolved[index] - size.min_size)
		before := acc * shrink / capacity
		acc += item_capacity
		after := acc * shrink / capacity
		resolved[index] -= i32(after - before)
		consumed += after - before
	}
	assert(consumed == shrink, "_flex_compress_priority: incomplete distribution")
	return overflow - i32(shrink)
}

@(private = "file")
_flex_compress :: proc(resolved: ^[MAX_LAYOUT_FLEX]i32, sizes: []Track, overflow: i32) {
	assert(resolved != nil, "_flex_compress: nil sizes")
	assert(len(sizes) <= MAX_LAYOUT_FLEX, "_flex_compress: count out of bounds")
	assert(overflow > 0, "_flex_compress: non-positive overflow")
	remaining := _flex_compress_priority(resolved, sizes, overflow, 0)
	if remaining > 0 {
		remaining = _flex_compress_priority(resolved, sizes, remaining, 1)
	}
	assert(remaining >= 0 && remaining <= overflow, "_flex_compress: invalid remainder")
}

@(private = "file")
_flex_expand :: proc(resolved: ^[MAX_LAYOUT_FLEX]i32, sizes: []Track, free: i32) {
	assert(resolved != nil, "_flex_expand: nil sizes")
	assert(free > 0, "_flex_expand: non-positive free space")
	remaining_free := free
	for _ in 0 ..< MAX_LAYOUT_FLEX {
		total_weight: i64
		for size, index in sizes {
			uncapped :=
				size.kind == .Grow && (size.max_size == 0 || resolved[index] < size.max_size)
			if uncapped do total_weight += i64(size.weight)
		}
		if total_weight == 0 || remaining_free == 0 do break
		applied: i32
		weight_acc: i64
		for size, index in sizes {
			uncapped :=
				size.kind == .Grow && (size.max_size == 0 || resolved[index] < size.max_size)
			if !uncapped do continue
			before := weight_acc * i64(remaining_free) / total_weight
			weight_acc += i64(size.weight)
			after := weight_acc * i64(remaining_free) / total_weight
			share := i32(after - before)
			if size.max_size > 0 do share = min(share, size.max_size - resolved[index])
			resolved[index] += share
			applied += share
		}
		assert(applied >= 0 && applied <= remaining_free, "_flex_expand: invalid distribution")
		if applied == 0 do break
		remaining_free -= applied
	}
	assert(remaining_free >= 0, "_flex_expand: negative remainder")
}

@(private = "file")
_flex_resolve :: proc(f: ^Layout_Frame, sizes: []Track, space: i32) {
	assert(f != nil, "_flex_resolve: nil frame")
	assert(space >= 0 && len(sizes) <= MAX_LAYOUT_FLEX, "_flex_resolve: invalid input")
	total: i64
	for size, index in sizes {
		assert(
			size.min_size >= 0 && (size.max_size == 0 || size.max_size >= size.min_size),
			"_flex_resolve: invalid constraints",
		)
		resolved: i32
		switch size.kind {
		case .Fit:
			assert(size.basis >= 0, "_flex_resolve: negative fit basis")
			resolved = _flex_clamp(size.basis, size.min_size, size.max_size)
		case .Hug:
			assert(size.basis >= 0, "_flex_resolve: negative hug basis")
			resolved = _flex_clamp(size.basis, size.min_size, size.max_size)
		case .Grow:
			assert(size.weight > 0, "_flex_resolve: invalid grow weight")
			resolved = size.min_size
		case .Fixed:
			assert(size.basis >= 0, "_flex_resolve: negative fixed basis")
			resolved = size.basis
		case .Percent:
			assert(size.percent >= 0 && size.percent <= 1, "_flex_resolve: invalid percent")
			resolved = _flex_clamp(i32(f32(space) * size.percent), size.min_size, size.max_size)
		}
		f.flex_sizes[index] = resolved
		total += i64(resolved)
	}
	if total > i64(space) {
		_flex_compress(&f.flex_sizes, sizes, i32(min(total - i64(space), i64(max(i32)))))
	} else if total < i64(space) {
		_flex_expand(&f.flex_sizes, sizes, i32(i64(space) - total))
	}
	f.flex_count = i32(len(sizes))
	f.flex_index = 0
	assert(f.flex_count > 0 && f.flex_count <= MAX_LAYOUT_FLEX, "_flex_resolve: invalid result")
}

// _top returns the active frame. Internal; callers use the procs above.
@(private = "file")
_top :: proc(l: ^Layout) -> ^Layout_Frame {
	assert(l != nil, "_top: nil l")
	assert(l.depth > 0, "_top: empty layout stack")
	assert(l.depth <= MAX_LAYOUT_DEPTH, "_top: depth out of bounds")
	return &l.stack[l.depth - 1]
}

// axis_matches reports whether a caller-declared axis agrees with the active
// frame. Pure and exported, so the contract is testable without building a
// layout: see layout_test.odin. .Unspecified always matches, which is what
// keeps every pre-existing flex_begin call behaving exactly as before.
axis_matches :: proc(axis: Flex_Axis, kind: Layout_Kind) -> bool {
	switch axis {
	case .Unspecified:
		return true
	case .Column:
		return kind == .Column
	case .Row:
		return kind == .Row
	}
	return false
}

// _main_extent returns the frame's total main-axis length in pixels.
@(private = "file")
_main_extent :: proc(f: Layout_Frame) -> i32 {
	assert(f.rect.w >= 0 && f.rect.h >= 0, "_main_extent: negative rect")
	return f.rect.h if f.kind == .Column else f.rect.w
}
