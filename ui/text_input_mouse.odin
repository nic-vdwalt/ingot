// Text input: mouse pipeline - hit-testing, click-count state machine,
// word/pill-aware double-click selection, and drag auto-scroll.
package ui

import "core:strings"

// Map a pane-local mouse position to a byte offset within the input's visible
// window. Rows clamp to the visible band; x clamps to line ends.
@(private)
input_mouse_to_byte :: proc(
	frame: ^Ui_Frame,
	vlines: []Wrap_Line,
	text: string,
	mouse: Vector2,
	inner_x, y: i32,
	vis_start, vis_end: int,
) -> int {
	// Why assert: a caller passing an empty layout or an inverted visible
	// band would index vlines out of range below.
	assert(frame != nil && frame.open, "input_mouse_to_byte: invalid frame")
	metrics := ui_frame_metrics(frame)
	assert(len(vlines) > 0, "input_mouse_to_byte: empty visual lines")
	assert(vis_start <= vis_end, "input_mouse_to_byte: inverted visible band")
	// The same scaled padding the renderer offsets lines by; an unscaled
	// literal here made clicks land one row off at non-1 UI scales.
	pad := ui_frame_sc(frame, TI_PAD_TOP)
	row := vis_start + int((mouse.y - f32(y + pad)) / f32(metrics.LINE_HEIGHT))
	if row < vis_start do row = vis_start
	if row > vis_end - 1 do row = vis_end - 1
	if row < 0 do row = 0
	if row >= len(vlines) do row = len(vlines) - 1
	vl := vlines[row]
	line := text[vl.start:vl.end]
	col := caret_pixel_to_col_frame(frame, line, i32(mouse.x) - inner_x, metrics.FONT_SIZE_BODY)
	return vl.start + caret_col_to_byte(line, col)
}

// ti_mouse_masked places the caret from a click in a masked (password) input.
@(private)
ti_mouse_masked :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View) {
	assert(ctx != nil, "ti_mouse_masked: nil ctx")
	assert(ctx.caret, "ti_mouse_masked: caret model required")
	assert(ctx.masked, "ti_mouse_masked: masked input required")
	if !is_mouse_button_pressed(ctx.frame, .LEFT) do return
	mouse := get_mouse_position(ctx.frame)
	if route_occluded(ctx.frame, mouse) do return
	mouse = frame_to_local(ctx.frame, mouse)
	if !point_in_rect(mouse, ctx.rect) do return
	masked_text := v.masked_text
	masked_c := strings.clone_to_cstring(masked_text, context.temp_allocator)
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	masked_w := measure_text_frame(ctx.frame, masked_c, font_size)
	masked_offset := max(0, masked_w - ctx.inner_w)
	col := caret_pixel_to_col_frame(
		ctx.frame,
		masked_text,
		i32(mouse.x) - ctx.inner_x + masked_offset,
		font_size,
	)
	ctx.cursor^ = caret_col_to_byte(text, col)
	sel_set(ctx.sel, ctx.sb, ctx.cursor^, ctx.cursor^)
}

// ti_click_count_update advances the single/double/triple click counter.
// Two clicks group when they land within 0.4s and within one rune of the
// previous click - byte distance alone would drop double-clicks on wide
// (CJK/emoji) runes whose neighbouring boundaries sit 3-4 bytes apart.
@(private)
ti_click_count_update :: proc(sel: ^Input_Sel, text: string, offset: int, now: f64) {
	assert(sel != nil, "ti_click_count_update: nil selection")
	assert(offset >= 0 && offset <= len(text), "ti_click_count_update: invalid offset")
	// The stored offset can outlive edits between clicks; clamp before use.
	last := caret_clamp(text, sel.last_click_byte)
	near := offset >= caret_prev_rune(text, last) && offset <= caret_next_rune(text, last)
	if now - sel.last_click_time < 0.4 && near {
		sel.click_count = min(sel.click_count + 1, 3)
	} else {
		sel.click_count = 1
	}
	sel.last_click_time = now
	sel.last_click_byte = offset
	assert(sel.click_count >= 1 && sel.click_count <= 3, "ti_click_count_update: invalid count")
}

// ti_word_bounds_pills returns word bounds widened over any intersecting
// pill: pills are atomic everywhere else, so word selection must never
// bisect a mention.
@(private)
ti_word_bounds_pills :: proc(
	text: string,
	pills: ^[dynamic]Mention_Span,
	offset: int,
) -> (
	start: int,
	end: int,
) {
	assert(offset >= 0 && offset <= len(text), "ti_word_bounds_pills: invalid offset")
	start, end = find_word_bounds(text, offset)
	if pills != nil {
		start = pill_snap_left(pills, start)
		end = pill_snap_right(pills, end)
	}
	assert(start >= 0 && start <= end && end <= len(text), "ti_word_bounds_pills: bad bounds")
	return
}

@(private = "file")
ti_click_apply :: proc(ctx: ^TI_Ctx, text: string, offset: int) {
	assert(ctx != nil && ctx.sel != nil, "ti_click_apply: invalid context")
	assert(offset >= 0 && offset <= len(text), "ti_click_apply: invalid offset")
	sel := ctx.sel
	switch sel.click_count {
	case 2:
		start, end := ti_word_bounds_pills(text, ctx.pills, offset)
		sel_set(sel, ctx.sb, start, end)
		sel.dragging = true
		ctx.cursor^ = end
	case 3:
		start := caret_line_start(text, offset)
		end := caret_line_end(text, offset)
		sel_set(sel, ctx.sb, start, end)
		sel.dragging = false
		ctx.cursor^ = end
	case:
		ctx.cursor^ = offset
		if ctx.pills != nil do ctx.cursor^ = pill_snap_caret(ctx.pills, ctx.cursor^)
		sel_set(sel, ctx.sb, ctx.cursor^, ctx.cursor^)
		sel.dragging = true
	}
	assert(ctx.cursor^ >= 0 && ctx.cursor^ <= len(text), "ti_click_apply: invalid cursor")
}

// ti_drag_autoscroll_row picks the row a drag extends to while the mouse is
// held outside the box's vertical band: one visual row past the caret's
// current row, clamped to the document, at most once per
// TI_DRAG_SCROLL_SECS. Pure so the rate limit and clamping are unit-testable
// without a frame.
@(private)
ti_drag_autoscroll_row :: proc(
	sel: ^Input_Sel,
	cur_row, row_count: int,
	up: bool,
	now: f64,
) -> (
	row: int,
	stepped: bool,
) {
	assert(sel != nil, "ti_drag_autoscroll_row: nil selection")
	assert(cur_row >= 0 && cur_row < row_count, "ti_drag_autoscroll_row: row out of range")
	if now - sel.drag_scroll_time < TI_DRAG_SCROLL_SECS do return cur_row, false
	row = cur_row - 1 if up else cur_row + 1
	if row < 0 do row = 0
	if row > row_count - 1 do row = row_count - 1
	if row == cur_row do return cur_row, false
	sel.drag_scroll_time = now
	return row, true
}

// ti_mouse_press handles the button-down edge. Shift+click extends the
// selection from the existing anchor (or from the caret when there is none)
// and deliberately skips the double/triple-click counter, matching platform
// convention. A plain click runs the single/double/triple state machine.
@(private = "file")
ti_mouse_press :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View, mouse: Vector2) -> bool {
	assert(ctx.caret, "ti_mouse_press: caret model required")
	assert(ctx.sel != nil, "ti_mouse_press: nil selection")
	assert(ctx.active, "ti_mouse_press: input not active")
	sel := ctx.sel
	if !point_in_rect(mouse, ctx.rect) {
		if sel.sb == ctx.sb do sel_reset(sel)
		return false
	}
	off := input_mouse_to_byte(
		ctx.frame,
		v.vlines,
		text,
		mouse,
		ctx.inner_x,
		ctx.y,
		v.vis_start,
		v.vis_end,
	)
	shift := is_key_down(ctx.frame, .LEFT_SHIFT) || is_key_down(ctx.frame, .RIGHT_SHIFT)
	if shift {
		if ti_sel_owner(ctx) {
			sel.extent = off
			sel.active = sel.anchor != off
		} else {
			sel_set(sel, ctx.sb, ctx.cursor^, off)
		}
		sel.dragging = true
		ctx.cursor^ = off
	} else {
		ti_click_count_update(sel, text, off, frame_input(ctx.frame).time)
		ti_click_apply(ctx, text, off)
	}
	if ctx.desired_col != nil {
		_, c := caret_row_col(text, ctx.cursor^)
		ctx.desired_col^ = c
	}
	return true
}

// ti_mouse_drag extends the selection while the button is held. Inside the
// box the extent follows the mouse; above or below it, the extent steps one
// visual row per tick so the band (which follows the caret in ti_layout)
// auto-scrolls through long wrapped text.
@(private = "file")
ti_mouse_drag :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View, mouse: Vector2) -> bool {
	assert(ctx.caret, "ti_mouse_drag: caret model required")
	assert(ctx.sel != nil, "ti_mouse_drag: nil selection")
	assert(ctx.active, "ti_mouse_drag: input not active")
	assert(ctx.sel.dragging && ctx.sel.sb == ctx.sb, "ti_mouse_drag: not dragging this input")
	assert(len(v.vlines) > 0, "ti_mouse_drag: empty layout")
	sel := ctx.sel
	above := mouse.y < f32(ctx.y)
	below := mouse.y > f32(ctx.y + ctx.h)
	off := sel.extent
	if above || below {
		now := frame_input(ctx.frame).time
		row, stepped := ti_drag_autoscroll_row(sel, v.cur_vrow, len(v.vlines), above, now)
		// Keep repainting while the mouse is parked outside the box, or the
		// scroll stalls in event-driven frame mode (same pattern as the
		// caret blink).
		request_redraw_in(ctx.frame, TI_DRAG_SCROLL_SECS)
		if !stepped do return false
		vl := v.vlines[row]
		line := text[vl.start:vl.end]
		font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
		col := caret_pixel_to_col_frame(ctx.frame, line, i32(mouse.x) - ctx.inner_x, font_size)
		off = vl.start + caret_col_to_byte(line, col)
	} else {
		off = input_mouse_to_byte(
			ctx.frame,
			v.vlines,
			text,
			mouse,
			ctx.inner_x,
			ctx.y,
			v.vis_start,
			v.vis_end,
		)
	}
	if off == sel.extent && sel.click_count != 2 do return false
	if sel.click_count == 2 {
		// A drag that follows a double-click (including the press frame
		// itself, where the button is already down) extends a whole word at
		// a time and must never shrink below the originally clicked word.
		anchor, extent := ti_drag_word_sel(text, ctx.pills, sel.last_click_byte, off)
		if anchor == sel.anchor && extent == sel.extent do return false
		sel_set(sel, ctx.sb, anchor, extent)
		ctx.cursor^ = extent
		return true
	}
	sel.extent = off
	sel.active = sel.anchor != sel.extent
	ctx.cursor^ = off
	return true
}

// ti_drag_word_sel computes the word-granular selection for a drag after a
// double-click: the anchor word (at the original click byte) stays fully
// selected and the extent snaps to the boundary of the word under the mouse,
// matching platform convention. Pure so it is unit-testable without a frame.
@(private)
ti_drag_word_sel :: proc(
	text: string,
	pills: ^[dynamic]Mention_Span,
	click_byte, off: int,
) -> (
	anchor: int,
	extent: int,
) {
	assert(off >= 0 && off <= len(text), "ti_drag_word_sel: invalid offset")
	// pills is optional; when present, each span covers at least one byte of
	// the text, so there can never be more pills than bytes.
	assert(pills == nil || len(pills) <= len(text), "ti_drag_word_sel: more pills than bytes")
	// The click byte can outlive edits between frames; clamp before use.
	wa_s, wa_e := ti_word_bounds_pills(text, pills, caret_clamp(text, click_byte))
	ws, we := ti_word_bounds_pills(text, pills, off)
	if off < wa_s do return wa_e, ws
	assert(we >= wa_s, "ti_drag_word_sel: extent behind anchor")
	return wa_s, we
}

// ti_mouse_caret handles press (single/double/triple click, shift-extend),
// drag-extend with auto-scroll, and release for the caret-aware renderer,
// then refreshes the caret's visual position so highlight and caret don't
// lag one frame.
@(private)
ti_mouse_caret :: proc(ctx: ^TI_Ctx, text: string, v: ^TI_View) {
	assert(ctx.caret, "ti_mouse_caret: caret model required")
	assert(v.caret_render, "ti_mouse_caret: caret renderer required")
	sel := ctx.sel
	mouse := get_mouse_position(ctx.frame)
	occluded := route_occluded(ctx.frame, mouse)
	mouse = frame_to_local(ctx.frame, mouse)
	moved := false
	if is_mouse_button_pressed(ctx.frame, .LEFT) && !occluded {
		moved = ti_mouse_press(ctx, text, v, mouse)
	}
	if sel.dragging && sel.sb == ctx.sb && is_mouse_button_down(ctx.frame, .LEFT) {
		moved |= ti_mouse_drag(ctx, text, v, mouse)
	}
	if sel.dragging && is_mouse_button_released(ctx.frame, .LEFT) {
		sel.dragging = false
		if sel.anchor == sel.extent do sel.active = false
	}
	// ti_layout already computed the caret's visual position this frame;
	// recompute only when a click or drag actually moved it, so idle frames
	// skip the second prefix measure.
	if moved {
		v.cur_vrow, v.cur_caret_x = input_caret_visual_frame(
			ctx.frame,
			v.vlines,
			text,
			ctx.cursor^,
			int(ui_frame_metrics(ctx.frame).FONT_SIZE_BODY),
		)
		if ctx.desired_x != nil do ctx.desired_x^ = v.cur_caret_x
	}
}
