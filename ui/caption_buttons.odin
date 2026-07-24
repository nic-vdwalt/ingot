// LIB-CANDIDATE: this package must import only core:* and ingot:gfx.
package ui


// Caption buttons for the custom Windows title bar (min / max-restore / close),
// drawn Win11-style at the top-right of the header row. Platform-agnostic:
// hover/pressed state is produced by the Win32 non-client message handlers
// (titlebar_windows.odin) and passed in as a snapshot each frame.

Caption_Button :: enum u8 {
	None,
	Minimize,
	Maximize,
	Close,
}

Caption_Input :: struct {
	hover:     Caption_Button,
	pressed:   Caption_Button,
	maximized: bool,
}

// Total width of the three-button block, in physical pixels.
caption_buttons_width :: proc(frame: ^Ui_Frame) -> i32 {
	assert(frame != nil && frame.open, "caption_buttons_width: invalid frame")
	return 3 * ui_frame_metrics(frame).CAPTION_BTN_W
}

// Win11 caption button colors.
@(private = "file")
CAPTION_HOVER_FILL :: Color{255, 255, 255, 15}
@(private = "file")
CAPTION_PRESSED_FILL :: Color{255, 255, 255, 10}
@(private = "file")
CAPTION_CLOSE_HOVER :: Color{196, 43, 28, 255} // #C42B1C
@(private = "file")
CAPTION_CLOSE_PRESS :: Color{181, 43, 30, 255}

// draw_caption_buttons renders the three caption buttons flush to the
// top-right corner and returns their rects (physical client px) so the
// caller can publish them to the non-client hit-test.
draw_caption_buttons :: proc(
	frame: ^Ui_Frame,
	screen_w: i32,
	st: Caption_Input,
) -> (
	min_r, max_r, close_r: Rectangle,
) {
	assert(frame != nil && frame.open, "draw_caption_buttons: invalid frame")
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	w := f32(metrics.CAPTION_BTN_W)
	h := f32(metrics.TAB_BAR_HEIGHT)

	close_r = Rectangle{f32(screen_w) - w, 0, w, h}
	max_r = Rectangle{f32(screen_w) - 2 * w, 0, w, h}
	min_r = Rectangle{f32(screen_w) - 3 * w, 0, w, h}

	// Opaque base under the block: masks any header overflow and keeps the
	// translucent hover fills consistent on every screen.
	draw_rectangle_rec(frame, Rectangle{min_r.x, 0, 3 * w, h}, style.bg_secondary)

	focused := frame_input(frame).window_focused
	glyph_base := style.fg_primary if focused else style.fg_secondary

	// Hover / pressed backgrounds.
	draw_btn_bg :: proc(frame: ^Ui_Frame, r: Rectangle, btn: Caption_Button, st: Caption_Input) {
		if btn == .Close {
			if st.pressed == .Close {
				draw_rectangle_rec(frame, r, CAPTION_CLOSE_PRESS)
			} else if st.hover == .Close {
				draw_rectangle_rec(frame, r, CAPTION_CLOSE_HOVER)
			}
			return
		}
		if st.pressed == btn {
			draw_rectangle_rec(frame, r, CAPTION_PRESSED_FILL)
		} else if st.hover == btn {
			draw_rectangle_rec(frame, r, CAPTION_HOVER_FILL)
		}
	}
	draw_btn_bg(frame, min_r, .Minimize, st)
	draw_btn_bg(frame, max_r, .Maximize, st)
	draw_btn_bg(frame, close_r, .Close, st)

	stroke := ui_frame_scf(frame, 1.0)
	g := ui_frame_scf(frame, 10.0) // glyph box size

	// Minimize: single horizontal line at vertical center.
	{
		cx := min_r.x + (w - g) / 2
		cy := min_r.y + h / 2
		draw_line_ex(frame, Vector2{cx, cy}, Vector2{cx + g, cy}, stroke, glyph_base)
	}

	// Maximize / Restore.
	{
		gx := max_r.x + (w - g) / 2
		gy := max_r.y + (h - g) / 2
		if st.maximized {
			// Restore: two overlapping panes. Back pane offset up-right; only
			// its top and right edges are visible behind the front pane.
			off := ui_frame_scf(frame, 2.0)
			front := Rectangle{gx, gy + off, g - off, g - off}
			draw_rectangle_lines_ex(frame, front, stroke, glyph_base)
			// Back pane: top edge and right edge.
			bx0 := gx + off
			by0 := gy
			bx1 := gx + g
			draw_line_ex(frame, Vector2{bx0, by0}, Vector2{bx1, by0}, stroke, glyph_base)
			draw_line_ex(frame, Vector2{bx1, by0}, Vector2{bx1, by0 + g - off}, stroke, glyph_base)
		} else {
			draw_rectangle_lines_ex(frame, Rectangle{gx, gy, g, g}, stroke, glyph_base)
		}
	}

	// Close: two diagonals. White glyph while hovered/pressed (red background).
	{
		col := glyph_base
		if st.hover == .Close || st.pressed == .Close {
			col = Color{255, 255, 255, 255}
		}
		gx := close_r.x + (w - g) / 2
		gy := close_r.y + (h - g) / 2
		draw_line_ex(frame, Vector2{gx, gy}, Vector2{gx + g, gy + g}, stroke, col)
		draw_line_ex(frame, Vector2{gx, gy + g}, Vector2{gx + g, gy}, stroke, col)
	}

	return
}

// draw_fullscreen_button renders a single caption-style button flush to the
// top-right corner (used on web builds, which have no OS title bar). It draws
// an enter/exit-fullscreen corner-bracket glyph, applies a Win11-style hover
// fill when the mouse is over it, and returns the button rect plus whether it
// is hovered so the caller can handle clicks.
draw_fullscreen_button :: proc(
	frame: ^Ui_Frame,
	screen_w: i32,
	is_fs: bool,
	mouse: Vector2,
) -> (
	r: Rectangle,
	hovered: bool,
) {
	assert(frame != nil && frame.open, "draw_fullscreen_button: invalid frame")
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	w := f32(metrics.CAPTION_BTN_W)
	h := f32(metrics.TAB_BAR_HEIGHT)
	r = Rectangle{f32(screen_w) - w, 0, w, h}
	hovered = point_in_rect(mouse, r)

	// Opaque base + hover fill (matches the Windows caption buttons).
	draw_rectangle_rec(frame, r, style.bg_secondary)
	if hovered {
		draw_rectangle_rec(frame, r, CAPTION_HOVER_FILL)
	}

	focused := frame_input(frame).window_focused
	col := style.fg_primary if focused else style.fg_secondary

	stroke := ui_frame_scf(frame, 1.0)
	g := ui_frame_scf(frame, 10.0) // glyph box size
	arm := ui_frame_scf(frame, 3.5) // corner arm length
	gx := r.x + (w - g) / 2
	gy := r.y + (h - g) / 2

	// One L-shaped corner bracket. (sx, sy) point the arms away from the vertex.
	corner :: proc(frame: ^Ui_Frame, cx, cy, sx, sy, arm, stroke: f32, col: Color) {
		draw_line_ex(frame, Vector2{cx, cy}, Vector2{cx + sx * arm, cy}, stroke, col)
		draw_line_ex(frame, Vector2{cx, cy}, Vector2{cx, cy + sy * arm}, stroke, col)
	}

	if is_fs {
		// Exit: brackets inset toward the center, arms pointing outward.
		corner(frame, gx + arm, gy + arm, -1, -1, arm, stroke, col)
		corner(frame, gx + g - arm, gy + arm, +1, -1, arm, stroke, col)
		corner(frame, gx + arm, gy + g - arm, -1, +1, arm, stroke, col)
		corner(frame, gx + g - arm, gy + g - arm, +1, +1, arm, stroke, col)
	} else {
		// Enter: brackets at the outer corners, arms pointing inward.
		corner(frame, gx, gy, +1, +1, arm, stroke, col)
		corner(frame, gx + g, gy, -1, +1, arm, stroke, col)
		corner(frame, gx, gy + g, +1, -1, arm, stroke, col)
		corner(frame, gx + g, gy + g, -1, -1, arm, stroke, col)
	}

	return
}
