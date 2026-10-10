package ui

// trackpads deliver larger inertia-driven values; the multiplier compensates.
get_wheel_move :: proc(frame: ^Ui_Frame) -> f32 {
	wheel := get_mouse_wheel_move(frame)
	when ODIN_OS == .Windows || ODIN_OS == .Linux {
		return wheel * 5.0
	} else {
		return wheel
	}
}

// Convert this frame's mouse-wheel delta into whole row steps, carrying
// fractional remainders in accum so small trackpad deltas are not lost.
// Resets the accumulator on direction reversal. Returns rows to scroll
// (positive = down the list).
wheel_row_steps :: proc(frame: ^Ui_Frame, accum: ^f32) -> int {
	return wheel_accum_steps(accum, get_wheel_move(frame))
}

// wheel_accum_steps is the pure core of wheel_row_steps: fold one frame's
// wheel delta into the accumulator and return whole row steps (positive =
// down the list). Split out so the carry/reversal logic is unit-testable
// without live mouse input.
wheel_accum_steps :: proc(accum: ^f32, wheel: f32) -> int {
	assert(accum != nil, "wheel_accum_steps: nil accumulator")
	if wheel == 0 do return 0
	if (accum^ > 0 && wheel < 0) || (accum^ < 0 && wheel > 0) {
		accum^ = 0
	}
	accum^ += wheel
	steps := int(accum^)
	accum^ -= f32(steps)
	// Why assert: the fractional remainder must stay below one full row or
	// steps were computed wrong.
	assert(accum^ > -1 && accum^ < 1, "wheel_accum_steps: remainder out of range")
	return -steps
}


// --- Interactive vertical scrollbar ----------------------------------------

// Scrollbar_State is caller-owned drag state, so multiple scrollbars can be
// dragged independently (one per Pane, or standalone via scrollbar_ex).
Scrollbar_State :: struct {
	dragging: bool,
	grab_dy:  f32,
}

// Draw a draggable vertical scrollbar (track + thumb) and return the updated
// first-visible-row offset. total and visible are row counts; offset is the
// current first visible row. Supports thumb dragging and track-click jumps.
// Uses the shared module drag slot; prefer scrollbar_ex for per-instance state.
// scrollbar_ex is scrollbar with caller-owned drag state.
scrollbar_ex :: proc(
	frame: ^Ui_Frame,
	st: ^Scrollbar_State,
	x, y, w, h: i32,
	total, visible, offset: int,
) -> int {
	// Why assert: negative row counts mean the caller mixed up pixel and row
	// units; every later division would silently produce garbage offsets.
	assert(st != nil, "scrollbar_ex: nil state")
	assert(total >= 0 && visible >= 0, "scrollbar_ex: negative row counts")
	assert(w > 0, "scrollbar_ex: non-positive width")
	if total <= visible || h <= 0 {
		// Content shrank below the viewport mid-drag: drop the latch and
		// release the frame's arbitration slot in the same breath. The
		// generation check in interact_frame_begin would reclaim it on the
		// next frame anyway; doing it here avoids one frame of dead input.
		if st.dragging {
			st.dragging = false
			interact_forget(frame, &st.dragging)
		}
		return 0
	}
	max_off := total - visible
	off := clamp(offset, 0, max_off)

	style := ui_frame_theme(frame)
	draw_rectangle(frame, x, y, w, h, style.bg_secondary)
	thumb_h := max(ui_frame_sc(frame, 20), h * i32(visible) / i32(total))
	track_range := max(h - thumb_h, 1)
	thumb_y := y + i32(f32(track_range) * f32(off) / f32(max_off))

	mouse := get_mouse_position(frame)
	mouse = frame_to_local(frame, mouse)
	thumb_rect := Rectangle{f32(x), f32(thumb_y), f32(w), f32(thumb_h)}
	track_rect := Rectangle{f32(x), f32(y), f32(w), f32(h)}

	it := interact(frame, track_rect, &st.dragging)
	if it.pressed {
		if point_in_rect(mouse, thumb_rect) {
			st.grab_dy = mouse.y - f32(thumb_y)
		} else {
			// Jump: center the thumb on the click, then keep dragging.
			st.grab_dy = f32(thumb_h) / 2
		}
	}
	if it.held {
		t := (mouse.y - st.grab_dy - f32(y)) / f32(track_range)
		off = clamp(int(t * f32(max_off) + 0.5), 0, max_off)
	}

	// Recompute the thumb position after a drag update.
	thumb_y = y + i32(f32(track_range) * f32(off) / f32(max_off))
	thumb_hover :=
		it.hovered && point_in_rect(mouse, Rectangle{f32(x), f32(thumb_y), f32(w), f32(thumb_h)})
	col := style.border_color
	if st.dragging || thumb_hover do col = style.fg_accent
	draw_rectangle(frame, x, thumb_y, w, thumb_h, col)
	return off
}

scrollbar_horizontal_ex :: proc(
	frame: ^Ui_Frame,
	st: ^Scrollbar_State,
	x, y, w, h: i32,
	total, visible, offset: int,
) -> int {
	assert(st != nil, "scrollbar_horizontal_ex: nil state")
	assert(total >= 0 && visible >= 0, "scrollbar_horizontal_ex: negative counts")
	assert(h > 0, "scrollbar_horizontal_ex: non-positive height")
	if total <= visible || w <= 0 {
		if st.dragging {
			st.dragging = false
			interact_forget(frame, &st.dragging)
		}
		return 0
	}
	max_off := total - visible
	off := clamp(offset, 0, max_off)
	style := ui_frame_theme(frame)
	draw_rectangle(frame, x, y, w, h, style.bg_secondary)
	thumb_w := max(ui_frame_sc(frame, 20), w * i32(visible) / i32(total))
	track_range := max(w - thumb_w, 1)
	thumb_x := x + i32(f32(track_range) * f32(off) / f32(max_off))
	mouse := frame_to_local(frame, get_mouse_position(frame))
	thumb_rect := Rectangle{f32(thumb_x), f32(y), f32(thumb_w), f32(h)}
	track_rect := Rectangle{f32(x), f32(y), f32(w), f32(h)}
	it := interact(frame, track_rect, &st.dragging)
	if it.pressed {
		if point_in_rect(mouse, thumb_rect) {
			st.grab_dy = mouse.x - f32(thumb_x)
		} else {
			st.grab_dy = f32(thumb_w) / 2
		}
	}
	if it.held {
		t := (mouse.x - st.grab_dy - f32(x)) / f32(track_range)
		off = clamp(int(t * f32(max_off) + 0.5), 0, max_off)
	}
	thumb_x = x + i32(f32(track_range) * f32(off) / f32(max_off))
	thumb_hover :=
		it.hovered && point_in_rect(mouse, Rectangle{f32(thumb_x), f32(y), f32(thumb_w), f32(h)})
	col := style.border_color
	if st.dragging || thumb_hover do col = style.fg_accent
	draw_rectangle(frame, thumb_x, y, thumb_w, h, col)
	return off
}


// --- scroll pane -----------------------------------------------------------

// Pane is caller-owned state for a scissored, wheel-scrollable region with a
// measured content height (clamps scroll on the next frame) and a scrollbar.
Pane :: struct {
	scroll:         f32,
	content_h:      i32, // measured by pane_end, consumed next frame
	open:           bool, // set by pane_begin, cleared by pane_end (balance check)
	sbar:           Scrollbar_State, // per-pane scrollbar drag state
	// Cull band in effect before pane_begin, restored by pane_end. Saved
	// rather than reset to infinity so nested panes compose: an inner pane
	// must not widen the band its parent narrowed.
	saved_cull_top: i32,
	saved_cull_bot: i32,
}

pane_reset :: proc(p: ^Pane) {
	assert(p != nil, "pane_reset: nil p")
	p.scroll = 0
	p.content_h = 0
	p.open = false
}

// pane_begin handles wheel input over the pane rect, clamps scroll, begins the
// scissor, and returns the y cursor the caller should start drawing at. When
// `keyboard` is true and the mouse hovers the pane, PageUp/PageDown/Home/End
// and Up/Down arrows scroll it - leave it off for panes that host text inputs
// (their caret owns those keys). `keyboard_unhovered` lets a modal pane that
// owns the keyboard scroll without the pointer over it. Hit testing for
// widgets inside the pane is clipped to the pane rect until pane_end.
pane_begin :: proc(
	frame: ^Ui_Frame,
	p: ^Pane,
	rect: Rect_I32,
	pad: i32 = 10,
	keyboard: bool = false,
	keyboard_unhovered: bool = false,
) -> (
	cursor_y: i32,
) {
	assert(frame != nil, "pane_begin: nil frame")
	assert(p != nil, "pane_begin: nil p")
	x, y, w, h := rect.x, rect.y, rect.w, rect.h
	// Why assert: an already-open pane means a missing pane_end - the scissor
	// stack would corrupt every subsequent draw.
	assert(!p.open, "pane_begin: pane already begun (missing pane_end)")
	assert(w >= 0 && h >= 0, "pane_begin: negative pane size")
	p.open = true
	mouse := get_mouse_position(frame)
	local := frame_to_local(frame, mouse)
	hovered :=
		point_in_rect(local, {f32(x), f32(y), f32(w), f32(h)}) && !route_occluded(frame, mouse)
	if hovered {
		p.scroll -= get_wheel_move(frame) * f32(ui_frame_sc(frame, 24))
	}
	if keyboard && (hovered || keyboard_unhovered) {
		pane_keyboard_scroll(frame, p, h)
	}
	p.scroll = clamp(p.scroll, 0, f32(max(p.content_h - h, 0)))
	begin_pane_scissor(frame, x, y, w, h)
	interact_clip_push(frame, {f32(x), f32(y), f32(w), f32(h)})
	// Narrow the cull band to the pane's visible rows so leaf painters can
	// skip geometry the scissor would discard at raster time. The band must
	// match the scissor exactly or widgets vanish at the pane edges; both use
	// the same y and h. Intersecting with the saved band keeps a nested pane
	// from widening its parent's.
	p.saved_cull_top = frame.text_cull_top
	p.saved_cull_bot = frame.text_cull_bottom
	set_text_cull_band_frame(
		frame,
		max(y, p.saved_cull_top),
		max(min(y + h, p.saved_cull_bot), max(y, p.saved_cull_top)),
	)
	return y + ui_frame_sc(frame, pad) - i32(p.scroll)
}

// pane_keyboard_scroll applies PageUp/PageDown/Home/End and Up/Down arrow
// scrolling to a hovered pane. Scroll is clamped by pane_begin right after.
@(private = "file")
pane_keyboard_scroll :: proc(frame: ^Ui_Frame, p: ^Pane, h: i32) {
	assert(p != nil, "pane_keyboard_scroll: nil pane")
	assert(p.open, "pane_keyboard_scroll: pane not begun")
	step := f32(ui_frame_metrics(frame).LINE_HEIGHT)
	if is_key_pressed(frame, .DOWN) || is_key_pressed_repeat(frame, .DOWN) do p.scroll += step
	if is_key_pressed(frame, .UP) || is_key_pressed_repeat(frame, .UP) do p.scroll -= step
	if is_key_pressed(frame, .PAGE_DOWN) || is_key_pressed_repeat(frame, .PAGE_DOWN) {
		p.scroll += f32(h)
	}
	if is_key_pressed(frame, .PAGE_UP) || is_key_pressed_repeat(frame, .PAGE_UP) do p.scroll -= f32(h)
	if is_key_pressed(frame, .HOME) do p.scroll = 0
	if is_key_pressed(frame, .END) do p.scroll = f32(max(p.content_h - h, 0))
}

// pane_end ends the scissor, records the measured content height from the
// caller's final y cursor, and draws/handles the scrollbar when content
// overflows the pane.
pane_end :: proc(frame: ^Ui_Frame, p: ^Pane, rect: Rect_I32, end_y: i32, pad: i32 = 10) {
	assert(frame != nil, "pane_end: nil frame")
	assert(p != nil, "pane_end: nil p")
	x, y, w, h := rect.x, rect.y, rect.w, rect.h
	// Why assert: pane_end without pane_begin would pop a scissor the pane
	// never pushed, clipping unrelated draws.
	assert(p.open, "pane_end: pane not begun")
	assert(h >= 0, "pane_end: negative pane height")
	p.open = false
	end_scissor_mode(frame)
	interact_clip_pop(frame)
	// Restore the enclosing band before the scrollbar draws: the scrollbar
	// sits inside the pane rect but outside the scissor, and a nested pane's
	// parent must get its own band back unchanged.
	assert(p.saved_cull_top <= p.saved_cull_bot, "pane_end: corrupt saved cull band")
	set_text_cull_band_frame(frame, p.saved_cull_top, p.saved_cull_bot)
	start_y := y + ui_frame_sc(frame, pad) - i32(p.scroll)
	p.content_h = end_y - start_y + ui_frame_sc(frame, pad)
	if p.content_h > h {
		off := scrollbar_ex(
			frame,
			&p.sbar,
			x + w - ui_frame_sc(frame, 9),
			y + ui_frame_sc(frame, 2),
			ui_frame_sc(frame, 5),
			h - ui_frame_sc(frame, 4),
			int(p.content_h),
			int(h),
			int(p.scroll),
		)
		p.scroll = f32(off)
	}
}
