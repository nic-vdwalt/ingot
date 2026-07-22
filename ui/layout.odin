// LIB-CANDIDATE: this package must import only core:* and ingot:gfx.
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

// Rect_I32 is an integer-pixel rect matching the x/y/w/h widget convention.
Rect_I32 :: struct {
	x, y, w, h: i32,
}

Layout_Kind :: enum u8 {
	Column, // children stack vertically; main axis = y
	Row,    // children stack horizontally; main axis = x
}

Cross_Align :: enum u8 {
	Stretch, // children fill the cross axis (default)
	Start,
	Center,
	End,
}

Layout_Frame :: struct {
	kind:         Layout_Kind,
	rect:         Rect_I32, // full frame area
	cursor:       i32,      // advance along the main axis, relative to rect
	gap:          i32,      // spacing inserted between consecutive items
	cross_align:  Cross_Align,
	// Weighted-division state (row_weights / next_weighted).
	weight_total: i32, // sum of declared weights; 0 = none declared
	weight_space: i32, // main-axis pixels being divided
	weight_acc:   i32, // sum of weights consumed so far
	weight_left:  i32, // declared children not yet consumed
}

// Layout is caller-owned per-frame scratch state; zero value is ready to use.
Layout :: struct {
	stack: [MAX_LAYOUT_DEPTH]Layout_Frame,
	depth: int,
}

// layout_begin opens the root column over the given area. Must be balanced
// with layout_end; nesting Layouts is fine because callers own the struct.
layout_begin :: proc(l: ^Layout, x, y, w, h: i32, gap: i32 = 0) {
	assert(l.depth == 0, "layout_begin: layout already open")
	assert(w >= 0 && h >= 0, "layout_begin: negative size")
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
	l.depth = 0
}

// push_row carves a full-width strip of height h from the current column and
// makes it the active frame, laying children out left-to-right.
push_row :: proc(l: ^Layout, h: i32, gap: i32 = 0, cross_align: Cross_Align = .Stretch) {
	assert(l.depth > 0 && l.depth < MAX_LAYOUT_DEPTH, "push_row: depth out of bounds")
	assert(_top(l).kind == .Column, "push_row: current frame must be a column")
	r := next(l, h)
	l.stack[l.depth] = Layout_Frame {
		kind        = .Row,
		rect        = r,
		gap         = gap,
		cross_align = cross_align,
	}
	l.depth += 1
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
	l.stack[l.depth] = Layout_Frame {
		kind        = .Column,
		rect        = r,
		gap         = gap,
		cross_align = cross_align,
	}
	l.depth += 1
}

// pop closes the innermost pushed frame (row or column).
layout_pop :: proc(l: ^Layout) {
	assert(l.depth > 1, "layout_pop: nothing pushed above the root")
	assert(_top(l).weight_left == 0, "layout_pop: declared weights not fully consumed")
	l.depth -= 1
}

// next carves main_size pixels along the main axis, spanning the full cross
// axis. The size is clamped to the remaining space (asserted in debug).
next :: proc(l: ^Layout, main_size: i32) -> Rect_I32 {
	assert(l.depth > 0, "next: layout not begun")
	assert(main_size >= 0, "next: negative size")
	f := _top(l)
	avail := _main_extent(f^) - f.cursor
	if avail < 0 do avail = 0
	size := min(main_size, avail)
	r: Rect_I32
	if f.kind == .Column {
		r = Rect_I32{f.rect.x, f.rect.y + f.cursor, f.rect.w, size}
	} else {
		r = Rect_I32{f.rect.x + f.cursor, f.rect.y, size, f.rect.h}
	}
	f.cursor += size + f.gap
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

// row_weights declares the weighted children of the current frame up front so
// the remaining main-axis space (minus gaps between them) can be divided in a
// single deterministic pass by subsequent next_weighted calls.
row_weights :: proc(l: ^Layout, weights: []i32) {
	assert(l.depth > 0, "row_weights: layout not begun")
	assert(len(weights) > 0 && len(weights) <= MAX_LAYOUT_WEIGHTS, "row_weights: count out of bounds")
	f := _top(l)
	assert(f.weight_left == 0, "row_weights: previous weights not consumed")
	total: i32 = 0
	for w in weights {
		assert(w > 0, "row_weights: weights must be positive")
		total += w
	}
	avail := _main_extent(f^) - f.cursor
	gaps := f.gap * i32(len(weights) - 1)
	space := avail - gaps
	if space < 0 do space = 0
	f.weight_total = total
	f.weight_space = space
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
	before := f.weight_acc * f.weight_space / f.weight_total
	after := (f.weight_acc + weight) * f.weight_space / f.weight_total
	f.weight_acc += weight
	f.weight_left -= 1
	if f.weight_left == 0 {
		f.weight_total = 0
		f.weight_space = 0
		f.weight_acc = 0
	}
	return next(l, after - before)
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
