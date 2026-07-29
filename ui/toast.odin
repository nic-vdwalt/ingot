// LIB-CANDIDATE: imports only core:*.
// Toast notifications: a bounded caller-owned queue of timed messages drawn
// as stacked overlay cards in the top-right corner. Pushing past capacity
// drops the oldest toast; decay uses the frame's delta time.
package ui

TOAST_CAP :: 6
TOAST_TEXT_CAP :: 160
TOAST_SECONDS: f32 : 4

Toast_Kind :: enum u8 {
	Info,
	Success,
	Error,
}

Toast :: struct {
	text:      [TOAST_TEXT_CAP]u8,
	text_len:  int,
	kind:      Toast_Kind,
	remaining: f32,
}

// Toast_State is the caller-owned queue. Zero value is ready to use.
Toast_State :: struct {
	items: [TOAST_CAP]Toast,
	count: int,
}

// toast_push enqueues a message, truncating to capacity on a byte boundary
// and evicting the oldest toast when the queue is full.
toast_push :: proc(st: ^Toast_State, kind: Toast_Kind, message: string) {
	assert(st != nil, "toast_push: nil state")
	assert(message != "", "toast_push: empty message")
	assert(st.count >= 0 && st.count <= TOAST_CAP, "toast_push: corrupt count")
	if st.count == TOAST_CAP {
		for index in 1 ..< st.count {
			st.items[index - 1] = st.items[index]
		}
		st.count -= 1
	}
	item := &st.items[st.count]
	item^ = {}
	item.kind = kind
	item.remaining = TOAST_SECONDS
	item.text_len = min(len(message), TOAST_TEXT_CAP)
	copy(item.text[:item.text_len], message[:item.text_len])
	st.count += 1
	assert(st.count <= TOAST_CAP, "toast_push: overflow")
}

// toast_tick advances decay by dt seconds and compacts expired toasts.
// Split from drawing so headless tests can drive the queue.
toast_tick :: proc(st: ^Toast_State, dt: f32) {
	assert(st != nil, "toast_tick: nil state")
	assert(dt >= 0, "toast_tick: negative dt")
	kept := 0
	for index in 0 ..< st.count {
		st.items[index].remaining -= dt
		if st.items[index].remaining > 0 {
			if kept != index do st.items[kept] = st.items[index]
			kept += 1
		}
	}
	st.count = kept
}

// toasts_draw ticks the queue with the frame's delta time and records the
// visible toasts on the overlay layer, newest at the top.
toasts_draw :: proc(frame: ^Ui_Frame, st: ^Toast_State, screen: Rect_I32) {
	assert(frame != nil, "toasts_draw: nil frame")
	assert(st != nil, "toasts_draw: nil state")
	toast_tick(st, frame_time(frame))
	if st.count == 0 do return
	if st.count > 0 do request_redraw(frame)
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	width := ui_frame_sc(frame, 320)
	height := metrics.ROW_H_MD + metrics.CONTROL_GAP
	gap := ui_frame_sc(frame, 8)
	x := screen.x + screen.w - width - ui_frame_sc(frame, 16)
	y := screen.y + ui_frame_sc(frame, 56)
	for index := st.count - 1; index >= 0; index -= 1 {
		item := &st.items[index]
		rect := Rectangle{f32(x), f32(y), f32(width), f32(height)}
		accent := style.fg_accent
		switch item.kind {
		case .Info:
			accent = style.fg_accent
		case .Success:
			accent = style.fg_success
		case .Error:
			accent = style.fg_error
		}
		overlay_begin(frame, rect, claim_input = false)
		overlay_rect(frame, rect, style.bg_popup)
		overlay_rect_lines(frame, rect, ui_frame_scf(frame, 1), style.border_subtle)
		overlay_rect(frame, {rect.x, rect.y, f32(ui_frame_sc(frame, 3)), rect.height}, accent)
		message := string(item.text[:item.text_len])
		shown := truncate_to_width_frame(
			frame,
			message,
			width - metrics.PADDING * 2,
			metrics.FONT_SIZE_BODY,
		)
		overlay_text(
			frame,
			shown,
			x + metrics.PADDING,
			y + (height - metrics.FONT_SIZE_BODY) / 2,
			metrics.FONT_SIZE_BODY,
			style.fg_primary,
		)
		overlay_end(frame)
		semantic_push(frame, .Status, {x, y, width, height}, message)
		y += height + gap
	}
}
