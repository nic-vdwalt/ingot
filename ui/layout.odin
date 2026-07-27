// LIB-CANDIDATE: this package must import only core:*.
// Never import app packages — destined for a standalone Odin GUI library.
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

// Rect_I32 is an integer-pixel rect matching the x/y/w/h widget convention.
Rect_I32 :: struct {
	x, y, w, h: i32,
}

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
	w := max(rect.w - value.left - value.right, 0)
	h := max(rect.h - value.top - value.bottom, 0)
	return {rect.x + value.left, rect.y + value.top, w, h}
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

Fit_Column :: struct {
	x, y, w: i32,
	cursor:  i32,
	gap:     i32,
	items:   i32,
	open:    bool,
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

fit_column_next :: proc(column: ^Fit_Column, height: i32) -> Rect_I32 {
	assert(column != nil && column.open, "fit_column_next: column not open")
	assert(height >= 0, "fit_column_next: negative height")
	assert(column.items < MAX_FIT_COLUMN_ITEMS, "fit_column_next: too many items")
	before := column.gap if column.items > 0 else 0
	assert(column.cursor <= 0x7fff_ffff - before - height, "fit_column_next: extent overflow")
	column.cursor += before
	result := Rect_I32{column.x, column.y + column.cursor, column.w, height}
	column.cursor += height
	column.items += 1
	return result
}

fit_column_space :: proc(column: ^Fit_Column, height: i32) {
	assert(column != nil && column.open, "fit_column_space: column not open")
	assert(height >= 0, "fit_column_space: negative height")
	assert(column.cursor <= 0x7fff_ffff - height, "fit_column_space: extent overflow")
	column.cursor += height
}

fit_column_end :: proc(column: ^Fit_Column) -> Rect_I32 {
	assert(column != nil && column.open, "fit_column_end: column not open")
	assert(
		column.cursor >= 0 && column.items <= MAX_FIT_COLUMN_ITEMS,
		"fit_column_end: corrupt column",
	)
	result := Rect_I32{column.x, column.y, column.w, column.cursor}
	column.open = false
	return result
}

Layout_Kind :: enum u8 {
	Column, // children stack vertically; main axis = y
	Row, // children stack horizontally; main axis = x
}

Cross_Align :: enum u8 {
	Stretch, // children fill the cross axis (default)
	Start,
	Center,
	End,
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

Flex_Kind :: enum u8 {
	Fit,
	Grow,
	Fixed,
	Percent,
}

// Flex_Size describes one sibling on the active frame's main axis. max_size
// is inclusive; zero means unbounded so the zero value remains useful.
Flex_Size :: struct {
	kind:     Flex_Kind,
	basis:    i32,
	weight:   i32,
	percent:  f32,
	min_size: i32,
	max_size: i32,
}

Layout_Size :: Flex_Size

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
	// Flex sizing is resolved up front and consumed by flex_next in order.
	flex_sizes:   [MAX_LAYOUT_FLEX]i32,
	flex_count:   i32,
	flex_index:   i32,
}

// Layout is caller-owned per-frame scratch state; zero value is ready to use.
Layout :: struct {
	stack: [MAX_LAYOUT_DEPTH]Layout_Frame,
	depth: int,
}

// flex_fit uses a caller-measured intrinsic size and may compress to min_size.
flex_fit :: proc(intrinsic: i32, min_size: i32 = 0, max_size: i32 = 0) -> Flex_Size {
	assert(intrinsic >= 0, "flex_fit: negative intrinsic size")
	assert(
		min_size >= 0 && (max_size == 0 || max_size >= min_size),
		"flex_fit: invalid constraints",
	)
	return Flex_Size{kind = .Fit, basis = intrinsic, min_size = min_size, max_size = max_size}
}

// flex_grow shares free space by weight after fixed, fit, and percent bases.
flex_grow :: proc(weight: i32 = 1, min_size: i32 = 0, max_size: i32 = 0) -> Flex_Size {
	assert(weight > 0, "flex_grow: weight must be positive")
	assert(
		min_size >= 0 && (max_size == 0 || max_size >= min_size),
		"flex_grow: invalid constraints",
	)
	return Flex_Size{kind = .Grow, weight = weight, min_size = min_size, max_size = max_size}
}

flex_fixed :: proc(size: i32) -> Flex_Size {
	assert(size >= 0, "flex_fixed: negative size")
	return Flex_Size{kind = .Fixed, basis = size, min_size = size, max_size = size}
}

// flex_percent uses a fraction of remaining frame space after inter-item gaps.
flex_percent :: proc(percent: f32, min_size: i32 = 0, max_size: i32 = 0) -> Flex_Size {
	assert(percent >= 0 && percent <= 1, "flex_percent: percent outside 0..1")
	assert(
		min_size >= 0 && (max_size == 0 || max_size >= min_size),
		"flex_percent: invalid constraints",
	)
	return Flex_Size{kind = .Percent, percent = percent, min_size = min_size, max_size = max_size}
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
	assert(l.depth > 1, "layout_pop: nothing pushed above the root")
	assert(_top(l).weight_left == 0, "layout_pop: declared weights not fully consumed")
	assert(
		_top(l).flex_index == _top(l).flex_count,
		"layout_pop: declared flex sizes not fully consumed",
	)
	l.depth -= 1
}

// flex_begin resolves one bounded sibling sequence before any child is drawn.
flex_begin :: proc(l: ^Layout, sizes: []Flex_Size) {
	assert(l.depth > 0, "flex_begin: layout not begun")
	assert(len(sizes) > 0 && len(sizes) <= MAX_LAYOUT_FLEX, "flex_begin: count out of bounds")
	f := _top(l)
	assert(f.weight_left == 0, "flex_begin: weighted sequence is active")
	assert(f.flex_index == f.flex_count, "flex_begin: previous flex sequence not consumed")
	gap_total := i64(f.gap) * i64(len(sizes) - 1)
	space_i64 := max(i64(_main_extent(f^)) - i64(f.cursor) - gap_total, i64(0))
	space := i32(min(space_i64, i64(max(i32))))
	_flex_resolve(f, sizes, space)
}

layout_flex_active :: proc(l: ^Layout) -> bool {
	assert(l != nil, "layout_flex_active: nil layout")
	assert(l.depth > 0, "layout_flex_active: layout not begun")
	return _top(l).flex_count > 0
}

// flex_next emits the next pre-resolved sibling using ordinary cursor advance.
flex_next :: proc(l: ^Layout) -> Rect_I32 {
	assert(l != nil && l.depth > 0, "flex_next: layout not begun")
	f := _top(l)
	cross_size := f.rect.w if f.kind == .Column else f.rect.h
	return flex_next_sized(l, cross_size)
}

flex_next_sized :: proc(l: ^Layout, cross_size: i32) -> Rect_I32 {
	assert(l.depth > 0, "flex_next_sized: layout not begun")
	assert(cross_size >= 0, "flex_next_sized: negative cross size")
	f := _top(l)
	assert(f.flex_index < f.flex_count, "flex_next_sized: no flex size available")
	size := f.flex_sizes[f.flex_index]
	f.flex_index += 1
	if f.flex_index == f.flex_count {
		f.flex_count = 0
		f.flex_index = 0
	}
	return next_sized(l, size, cross_size)
}

// next carves main_size pixels along the main axis, spanning the full cross
// axis. Overflow is clipped to the frame and never advances beyond its extent.
next :: proc(l: ^Layout, main_size: i32) -> Rect_I32 {
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
	assert(l.depth > 0, "spacer: layout not begun")
	assert(px >= 0, "spacer: negative spacer")
	f := _top(l)
	avail := _main_extent(f^) - f.cursor
	f.cursor += min(px, max(avail, 0))
}

// remaining returns the not-yet-carved area of the current frame.
remaining :: proc(l: ^Layout) -> Rect_I32 {
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
}

// next_weighted carves the next weighted child's share. The weight must match
// the corresponding entry declared via row_weights; rounding is distributed
// so all shares sum exactly to the declared space.
next_weighted :: proc(l: ^Layout, weight: i32) -> Rect_I32 {
	assert(l.depth > 0, "next_weighted: layout not begun")
	assert(weight > 0, "next_weighted: weight must be positive")
	f := _top(l)
	assert(f.weight_left > 0, "next_weighted: no weights declared (call row_weights)")
	// Cumulative division: share_i = floor(acc+w * S/T) - floor(acc * S/T)
	// guarantees the shares sum exactly to weight_space.
	before := i64(f.weight_acc) * i64(f.weight_space) / i64(f.weight_total)
	after := (i64(f.weight_acc) + i64(weight)) * i64(f.weight_space) / i64(f.weight_total)
	assert(after >= before && after - before <= i64(max(i32)), "next_weighted: invalid share")
	f.weight_acc += weight
	f.weight_left -= 1
	if f.weight_left == 0 {
		f.weight_total = 0
		f.weight_space = 0
		f.weight_acc = 0
	}
	return next(l, i32(after - before))
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
_flex_compress :: proc(resolved: ^[MAX_LAYOUT_FLEX]i32, sizes: []Flex_Size, overflow: i32) {
	assert(resolved != nil, "_flex_compress: nil sizes")
	assert(overflow > 0, "_flex_compress: non-positive overflow")
	capacity: i64
	for size, index in sizes {
		if size.kind == .Fit || size.kind == .Grow {
			capacity += i64(resolved[index] - size.min_size)
		}
	}
	shrink := min(i64(overflow), capacity)
	consumed: i64
	acc: i64
	for size, index in sizes {
		if size.kind != .Fit && size.kind != .Grow do continue
		item_capacity := i64(resolved[index] - size.min_size)
		before := acc * shrink / max(capacity, 1)
		acc += item_capacity
		after := acc * shrink / max(capacity, 1)
		resolved[index] -= i32(after - before)
		consumed += after - before
	}
	assert(consumed == shrink, "_flex_compress: incomplete distribution")
}

@(private = "file")
_flex_expand :: proc(resolved: ^[MAX_LAYOUT_FLEX]i32, sizes: []Flex_Size, free: i32) {
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
_flex_resolve :: proc(f: ^Layout_Frame, sizes: []Flex_Size, space: i32) {
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
	assert(l.depth > 0, "_top: empty layout stack")
	assert(l.depth <= MAX_LAYOUT_DEPTH, "_top: depth out of bounds")
	return &l.stack[l.depth - 1]
}

// _main_extent returns the frame's total main-axis length in pixels.
@(private = "file")
_main_extent :: proc(f: Layout_Frame) -> i32 {
	assert(f.rect.w >= 0 && f.rect.h >= 0, "_main_extent: negative rect")
	return f.rect.h if f.kind == .Column else f.rect.w
}
