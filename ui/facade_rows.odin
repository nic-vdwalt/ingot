// Facade rows: interactive list/table rows and windowed scrolling. These
// close the gap between the facade layout tier and the explicit-tier
// interact/list_row_bg_at/scissor plumbing that data-dense views need.
package ui

// Double-click window for row activation, in seconds.
ROW_DOUBLE_CLICK_SECONDS :: 0.4

Row_Select_Result :: struct {
	hovered:        bool,
	clicked:        bool,
	double_clicked: bool,
	held:           bool,
}

// row_select_begin carves a full-width row strip, reports its interaction,
// paints hover/selected background, and opens a flex track run so cells lay
// out inside it. Close with row_select_end. Double-click detection needs a
// caller-owned timestamp slot (pass nil to disable); the widget itself stays
// stateless.
row_select_begin :: proc(
	u: ^Ui,
	key: string,
	height: i32,
	tracks: []Track,
	selected: bool,
	last_click_at: ^f64 = nil,
	gap: Space = .None,
) -> Row_Select_Result {
	assert(u != nil && u.open, "row_select_begin: frame not open")
	assert(len(key) > 0, "row_select_begin: semantics required")
	assert(height > 0 && len(tracks) > 0, "row_select_begin: degenerate row")

	result: Row_Select_Result
	height_px := ui_frame_sc(u.frame, height)
	parent := remaining(&u.layout)
	rect := container_rect_px(u, parent.w, height_px)
	if slot_visible(rect) {
		it := interact(u.frame, rect_f32(rect))
		result.hovered = it.hovered
		result.clicked = it.clicked
		result.held = it.held
		if it.clicked && last_click_at != nil && u.frame.input != nil {
			now := u.frame.input.time
			if now - last_click_at^ < ROW_DOUBLE_CLICK_SECONDS {
				result.double_clicked = true
				last_click_at^ = 0
			} else {
				last_click_at^ = now
			}
		}
		list_row_bg_at(u.frame, rect, selected, result.hovered)
		if result.hovered do request_cursor(u.frame, .POINTING_HAND)
		sem: Sem_State
		if selected do sem += {.Selected}
		semantic_push(u.frame, .Option, rect, key, sem, field_id = key)
	}
	layout_push_rect(&u.layout, .Row, rect, space_px(u, gap), .Stretch)
	flex_begin_tracks(u, tracks, .Start)
	return result
}

row_select_end :: proc(u: ^Ui) {
	assert(u != nil && u.open, "row_select_end: frame not open")
	flex_row_end(u)
}

// list_window_begin turns the remaining container height (or visible_h when
// positive) into a wheel-scrollable window over `count` fixed-height rows.
// It clamps *scroll, opens a scissor over the region, and returns the row
// window; the caller draws rows [first, first+visible_rows) and closes with
// list_window_end.
list_window_begin :: proc(
	u: ^Ui,
	key: string,
	row_h: i32,
	count: int,
	scroll: ^f32,
	visible_h: i32 = 0,
) -> (
	first: int,
	visible_rows: int,
) {
	assert(u != nil && u.open, "list_window_begin: frame not open")
	assert(len(key) > 0, "list_window_begin: semantics required")
	assert(row_h > 0 && count >= 0 && scroll != nil, "list_window_begin: bad args")

	row_h_px := ui_frame_sc(u.frame, row_h)
	region := remaining_rect(u)
	if visible_h > 0 {
		region.h = min(region.h, ui_frame_sc(u.frame, visible_h))
	}
	if region.h < row_h_px || row_h_px <= 0 {
		begin_scissor_mode(u.frame, region.x, region.y, max(region.w, 0), max(region.h, 0))
		return 0, 0
	}
	visible_rows = int(region.h / row_h_px)

	mouse := get_mouse_position(u.frame)
	over :=
		mouse.x >= f32(region.x) &&
		mouse.x < f32(region.x + region.w) &&
		mouse.y >= f32(region.y) &&
		mouse.y < f32(region.y + region.h)
	if over {
		wheel := get_wheel_move(u.frame)
		if wheel != 0 do scroll^ -= wheel * 3
	}
	scroll^ = clamp(scroll^, 0, f32(max(count - visible_rows, 0)))
	first = int(scroll^)

	semantic_push(u.frame, .List_Box, region, key, field_id = key)
	begin_scissor_mode(u.frame, region.x, region.y, region.w, region.h)
	return first, visible_rows
}

list_window_end :: proc(u: ^Ui) {
	assert(u != nil && u.open, "list_window_end: frame not open")
	assert(u.frame != nil, "list_window_end: nil frame")
	end_scissor_mode(u.frame)
}
