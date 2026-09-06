// Text input: soft-wrap layout - vlines memo, incremental rewrap splice,
// caret visual position, and the per-frame visible-band computation.
package ui

import "core:strings"

@(private = "file")
input_vlines_memo_matches :: proc(
	memo: ^Input_Vlines_Memo,
	text: string,
	width, font_size: i32,
) -> bool {
	assert(memo != nil, "input_vlines_memo_matches: nil memo")
	return memo.valid && width == memo.width && font_size == memo.font_size && text == memo.text
}

@(private = "file")
input_vlines_memo_release :: proc(memo: ^Input_Vlines_Memo) {
	assert(memo != nil, "input_vlines_memo_release: nil memo")
	if memo.owned {
		if len(memo.val) > 0 do delete(memo.val)
		if len(memo.text) > 0 do delete(memo.text)
	}
	memo.val = nil
	memo.text = ""
	memo.valid = false
	memo.owned = false
}

@(private = "file")
input_vlines_memo_commit :: proc(
	memo: ^Input_Vlines_Memo,
	text: string,
	width, font_size: i32,
	vlines: []Wrap_Line,
) -> []Wrap_Line {
	assert(memo != nil, "input_vlines_memo_commit: nil memo")
	assert(len(vlines) > 0, "input_vlines_memo_commit: empty lines")
	input_vlines_memo_release(memo)
	memo.val = make([]Wrap_Line, len(vlines))
	copy(memo.val, vlines)
	memo.text = strings.clone(text)
	memo.width = width
	memo.font_size = font_size
	memo.valid = true
	memo.owned = true
	assert(len(memo.val) == len(vlines))
	return memo.val
}

// Build the soft-wrapped visual lines for an input's text using an explicit
// memo. Each logical line (split on '\n') is word-wrapped to inner_w; the
// returned ranges are absolute byte offsets into `text`. Always returns at
// least one (possibly empty) line.
//
// The wrap callee is threaded as a raw pointer + proc so the Text_System and
// Ui_Frame entry points share one implementation (including the incremental
// splice below) instead of drifting as line-for-line duplicates.
@(private = "file")
TI_Wrap_Fn :: #type proc(data: rawptr, logical: string, max_width, font_size: i32) -> []Wrap_Line

@(private = "file")
ti_wrap_with :: proc(data: rawptr, logical: string, max_width, font_size: i32) -> []Wrap_Line {
	assert(data != nil, "ti_wrap_with: nil text system")
	assert(font_size > 0, "ti_wrap_with: invalid font size")
	return wrap_compute_with((^Text_System)(data), logical, max_width, font_size)
}

@(private = "file")
ti_wrap_frame :: proc(data: rawptr, logical: string, max_width, font_size: i32) -> []Wrap_Line {
	assert(data != nil, "ti_wrap_frame: nil frame")
	assert(font_size > 0, "ti_wrap_frame: invalid font size")
	return wrap_compute_frame((^Ui_Frame)(data), logical, max_width, font_size)
}

// input_vlines_wrap_region appends the soft-wrapped lines of text[lo:hi]
// (split on '\n') to out, with byte ranges absolute into `text`.
@(private = "file")
input_vlines_wrap_region :: proc(
	wrap_data: rawptr,
	wrap_fn: TI_Wrap_Fn,
	out: ^[dynamic]Wrap_Line,
	text: string,
	lo, hi: int,
	inner_w, font_size: i32,
) {
	assert(wrap_fn != nil, "input_vlines_wrap_region: nil wrap fn")
	assert(0 <= lo && lo <= hi && hi <= len(text), "input_vlines_wrap_region: bad region")
	base := lo
	for logical in strings.split(text[lo:hi], "\n", context.temp_allocator) {
		// Uncached wrap: the memo already ensures this only runs when the
		// text/width changed, and routing a large paste through the global
		// wrap_text cache would evict the transcript's layouts.
		for seg in wrap_fn(wrap_data, logical, inner_w, font_size) {
			append(out, Wrap_Line{base + seg.start, base + seg.end})
		}
		base += len(logical) + 1 // +1 for the consumed '\n'
	}
}

// input_vlines_incremental rewraps only the logical lines an edit touched,
// reusing the memo's lines before and after the change. Wrapping is
// context-free per logical line (each is wrapped in isolation), so splicing
// is exact; the win is that typing in a large document re-measures one
// logical line instead of all of them.
@(private = "file")
input_vlines_incremental :: proc(
	wrap_data: rawptr,
	wrap_fn: TI_Wrap_Fn,
	memo: ^Input_Vlines_Memo,
	text: string,
	inner_w, font_size: i32,
) -> []Wrap_Line {
	assert(memo != nil, "input_vlines_incremental: nil memo")
	assert(memo.valid && memo.owned, "input_vlines_incremental: cold memo")
	assert(
		memo.width == inner_w && memo.font_size == font_size,
		"input_vlines_incremental: geometry changed",
	)
	old := memo.text
	// Common prefix/suffix in bytes; the suffix may not overlap the prefix.
	limit := min(len(old), len(text))
	p := 0
	for p < limit && old[p] == text[p] do p += 1
	s := 0
	for s < limit - p && old[len(old) - 1 - s] == text[len(text) - 1 - s] do s += 1
	// Widen the changed region to whole logical lines. The bytes before `ls`
	// and the trailing `s` bytes are identical in both strings, so line
	// boundaries found in one hold in the other.
	ls := strings.last_index_byte(text[:p], '\n') + 1
	new_hi := len(text) - s
	old_hi := len(old) - s
	rel := strings.index_byte(text[new_hi:], '\n')
	new_end := len(text) if rel < 0 else new_hi + rel
	old_end := len(old) if rel < 0 else old_hi + rel
	delta := len(text) - len(old)
	vlines := make([dynamic]Wrap_Line, context.temp_allocator)
	// Lines wholly before the changed logical line: their ranges end before
	// the '\n' that precedes `ls`, so `end < ls` is an exact cut.
	for vl in memo.val {
		if vl.end >= ls do break
		append(&vlines, vl)
	}
	input_vlines_wrap_region(wrap_data, wrap_fn, &vlines, text, ls, new_end, inner_w, font_size)
	// Lines wholly after the changed region start past the '\n' at old_end;
	// the shared suffix shifts by the edit's byte delta.
	for vl in memo.val {
		if vl.start <= old_end do continue
		append(&vlines, Wrap_Line{vl.start + delta, vl.end + delta})
	}
	if len(vlines) == 0 do append(&vlines, Wrap_Line{0, 0})
	// Oracle: a splice producing out-of-bounds or backward ranges would
	// corrupt every caret/selection mapping downstream.
	prev := 0
	for vl in vlines {
		assert(vl.start >= prev && vl.start <= vl.end, "input_vlines_incremental: unordered")
		assert(vl.end <= len(text), "input_vlines_incremental: out of bounds")
		prev = vl.start
	}
	return vlines[:]
}

@(private = "file")
input_vlines_memo_build :: proc(
	wrap_data: rawptr,
	wrap_fn: TI_Wrap_Fn,
	memo: ^Input_Vlines_Memo,
	text: string,
	inner_w: i32,
	font_size: i32,
) -> []Wrap_Line {
	assert(memo != nil, "input_vlines_memo_build: nil memo")
	assert(inner_w >= 0 && font_size > 0, "input_vlines_memo_build: invalid dimensions")
	if input_vlines_memo_matches(memo, text, inner_w, font_size) do return memo.val
	// A warm memo whose geometry still matches means only the text changed:
	// splice around the edit instead of rewrapping the whole document.
	if memo.valid && memo.owned && memo.width == inner_w && memo.font_size == font_size {
		spliced := input_vlines_incremental(wrap_data, wrap_fn, memo, text, inner_w, font_size)
		return input_vlines_memo_commit(memo, text, inner_w, font_size, spliced)
	}
	vlines := make([dynamic]Wrap_Line, context.temp_allocator)
	input_vlines_wrap_region(wrap_data, wrap_fn, &vlines, text, 0, len(text), inner_w, font_size)
	if len(vlines) == 0 do append(&vlines, Wrap_Line{0, 0})
	// Persist copies so the memo survives the temp allocator reset.
	return input_vlines_memo_commit(memo, text, inner_w, font_size, vlines[:])
}

input_visual_lines_memo_with :: proc(
	system: ^Text_System,
	memo: ^Input_Vlines_Memo,
	text: string,
	inner_w: i32,
	font_size: i32,
) -> []Wrap_Line {
	assert(system != nil, "input_visual_lines_memo: nil text system")
	assert(memo != nil, "input_visual_lines_memo: nil memo")
	return input_vlines_memo_build(system, ti_wrap_with, memo, text, inner_w, font_size)
}

input_visual_lines_memo_frame :: proc(
	frame: ^Ui_Frame,
	memo: ^Input_Vlines_Memo,
	text: string,
	inner_w: i32,
	font_size: i32,
) -> []Wrap_Line {
	assert(frame != nil && frame.open, "input_visual_lines_memo_frame: invalid frame")
	assert(memo != nil, "input_visual_lines_memo_frame: nil memo")
	return input_vlines_memo_build(frame, ti_wrap_frame, memo, text, inner_w, font_size)
}

// input_vlines_memo_destroy releases a memo's owned clones.
input_vlines_memo_destroy :: proc(memo: ^Input_Vlines_Memo) {
	assert(memo != nil, "input_vlines_memo_destroy: nil memo")
	input_vlines_memo_release(memo)
	assert(!memo.owned && !memo.valid, "input_vlines_memo_destroy: live memo")
}

// Map a byte offset to its visual (soft-wrapped) row and pixel x within the row.
input_caret_visual :: proc(
	system: ^Text_System,
	vlines: []Wrap_Line,
	text: string,
	pos, font_size: int,
) -> (
	row: int,
	x_px: i32,
) {
	assert(system != nil, "input_caret_visual: nil text system")
	for vl, idx in vlines {
		if pos <= vl.end {
			p := pos
			if p < vl.start do p = vl.start
			c := strings.clone_to_cstring(text[vl.start:p], context.temp_allocator)
			return idx, measure_text_with(system, c, i32(font_size))
		}
	}
	if len(vlines) > 0 {
		vl := vlines[len(vlines) - 1]
		c := strings.clone_to_cstring(text[vl.start:vl.end], context.temp_allocator)
		return len(vlines) - 1, measure_text_with(system, c, i32(font_size))
	}
	return 0, 0
}

input_caret_visual_frame :: proc(
	frame: ^Ui_Frame,
	vlines: []Wrap_Line,
	text: string,
	pos, font_size: int,
) -> (
	row: int,
	x_px: i32,
) {
	assert(frame != nil && frame.open, "input_caret_visual_frame: invalid frame")
	assert(font_size > 0, "input_caret_visual_frame: invalid font size")
	for vl, idx in vlines {
		if pos <= vl.end {
			p := pos
			if p < vl.start do p = vl.start
			prefix := strings.clone_to_cstring(text[vl.start:p], context.temp_allocator)
			return idx, measure_text_frame(frame, prefix, i32(font_size))
		}
	}
	if len(vlines) > 0 {
		vl := vlines[len(vlines) - 1]
		line := strings.clone_to_cstring(text[vl.start:vl.end], context.temp_allocator)
		return len(vlines) - 1, measure_text_frame(frame, line, i32(font_size))
	}
	return 0, 0
}

// ti_layout computes the visible window of visual lines for the caret-aware
// renderer and persists the scroll position.
@(private)
ti_layout :: proc(ctx: ^TI_Ctx, text: string) -> TI_View {
	assert(ctx.inner_w >= 0, "ti_layout: negative inner width")
	assert(ctx.h > 0, "ti_layout: non-positive height")
	v: TI_View
	v.has_newlines = !ctx.masked && strings.contains_rune(text, '\n')
	// Visual rows are render-only; caret navigation/history still use
	// logical lines.
	v.caret_render = ctx.caret && !ctx.masked
	v.masked_caret = ctx.caret && ctx.masked
	metrics := ui_frame_metrics(ctx.frame)
	// Shared with text_input_visible_lines so behaviour (Enter semantics)
	// and rendering can never disagree about a box's line count.
	v.visible_lines = text_input_visible_lines(ctx.frame, ctx.h)
	// One star string per frame: the mouse, render, and caret paths all
	// consume the same temp-allocated mask instead of rebuilding it.
	if ctx.masked do v.masked_text = masked_display(text)
	if !v.caret_render do return v
	v.vlines = input_visual_lines_memo_frame(
		ctx.frame,
		ctx.memo,
		text,
		ctx.inner_w,
		metrics.FONT_SIZE_BODY,
	)
	v.cur_vrow, v.cur_caret_x = input_caret_visual_frame(
		ctx.frame,
		v.vlines,
		text,
		ctx.cursor^,
		int(metrics.FONT_SIZE_BODY),
	)
	v.vis_start =
		ctx.scroll_line^ if ctx.scroll_line != nil else max(0, len(v.vlines) - int(v.visible_lines))
	if v.cur_vrow < v.vis_start do v.vis_start = v.cur_vrow
	if v.cur_vrow >= v.vis_start + int(v.visible_lines) {
		v.vis_start = v.cur_vrow - int(v.visible_lines) + 1
	}
	if v.vis_start < 0 do v.vis_start = 0
	// Never scroll further than needed to fill the visible window, so the
	// view pulls back up when the input grows (e.g. after a line wraps and
	// the bar height increases).
	max_start := max(0, len(v.vlines) - int(v.visible_lines))
	if v.vis_start > max_start do v.vis_start = max_start
	if ctx.scroll_line != nil do ctx.scroll_line^ = v.vis_start
	v.vis_end = min(len(v.vlines), v.vis_start + int(v.visible_lines))
	assert(v.vis_start <= v.vis_end, "ti_layout: inverted visible band")
	return v
}
