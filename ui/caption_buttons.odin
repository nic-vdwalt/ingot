// LIB-CANDIDATE: this package must import only core:* and ingot:gfx.
package ui

import rl "ingot:gfx"

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
caption_buttons_width :: proc() -> i32 {
	return 3 * CAPTION_BTN_W
}

// Win11 caption button colors.
@(private = "file") CAPTION_HOVER_FILL   :: rl.Color{255, 255, 255, 15}
@(private = "file") CAPTION_PRESSED_FILL :: rl.Color{255, 255, 255, 10}
@(private = "file") CAPTION_CLOSE_HOVER  :: rl.Color{196, 43, 28, 255} // #C42B1C
@(private = "file") CAPTION_CLOSE_PRESS  :: rl.Color{181, 43, 30, 255}

// draw_caption_buttons renders the three caption buttons flush to the
// top-right corner and returns their rects (physical client px) so the
// caller can publish them to the non-client hit-test.
draw_caption_buttons :: proc(screen_w: i32, st: Caption_Input) -> (min_r, max_r, close_r: rl.Rectangle) {
	w := f32(CAPTION_BTN_W)
	h := f32(TAB_BAR_HEIGHT)

	close_r = rl.Rectangle{f32(screen_w) - w, 0, w, h}
	max_r   = rl.Rectangle{f32(screen_w) - 2 * w, 0, w, h}
	min_r   = rl.Rectangle{f32(screen_w) - 3 * w, 0, w, h}

	// Opaque base under the block: masks any header overflow and keeps the
	// translucent hover fills consistent on every screen.
	rl.DrawRectangleRec(rl.Rectangle{min_r.x, 0, 3 * w, h}, BG_SECONDARY)

	focused := rl.IsWindowFocused()
	glyph_base := FG_PRIMARY if focused else FG_SECONDARY

	// Hover / pressed backgrounds.
	draw_btn_bg :: proc(r: rl.Rectangle, btn: Caption_Button, st: Caption_Input) {
		if btn == .Close {
			if st.pressed == .Close {
				rl.DrawRectangleRec(r, CAPTION_CLOSE_PRESS)
			} else if st.hover == .Close {
				rl.DrawRectangleRec(r, CAPTION_CLOSE_HOVER)
			}
			return
		}
		if st.pressed == btn {
			rl.DrawRectangleRec(r, CAPTION_PRESSED_FILL)
		} else if st.hover == btn {
			rl.DrawRectangleRec(r, CAPTION_HOVER_FILL)
		}
	}
	draw_btn_bg(min_r, .Minimize, st)
	draw_btn_bg(max_r, .Maximize, st)
	draw_btn_bg(close_r, .Close, st)

	stroke := scf(1.0)
	g := scf(10.0) // glyph box size

	// Minimize: single horizontal line at vertical center.
	{
		cx := min_r.x + (w - g) / 2
		cy := min_r.y + h / 2
		rl.DrawLineEx(rl.Vector2{cx, cy}, rl.Vector2{cx + g, cy}, stroke, glyph_base)
	}

	// Maximize / Restore.
	{
		gx := max_r.x + (w - g) / 2
		gy := max_r.y + (h - g) / 2
		if st.maximized {
			// Restore: two overlapping panes. Back pane offset up-right; only
			// its top and right edges are visible behind the front pane.
			off := scf(2.0)
			front := rl.Rectangle{gx, gy + off, g - off, g - off}
			rl.DrawRectangleLinesEx(front, stroke, glyph_base)
			// Back pane: top edge and right edge.
			bx0 := gx + off
			by0 := gy
			bx1 := gx + g
			rl.DrawLineEx(rl.Vector2{bx0, by0}, rl.Vector2{bx1, by0}, stroke, glyph_base)
			rl.DrawLineEx(rl.Vector2{bx1, by0}, rl.Vector2{bx1, by0 + g - off}, stroke, glyph_base)
		} else {
			rl.DrawRectangleLinesEx(rl.Rectangle{gx, gy, g, g}, stroke, glyph_base)
		}
	}

	// Close: two diagonals. White glyph while hovered/pressed (red background).
	{
		col := glyph_base
		if st.hover == .Close || st.pressed == .Close {
			col = rl.Color{255, 255, 255, 255}
		}
		gx := close_r.x + (w - g) / 2
		gy := close_r.y + (h - g) / 2
		rl.DrawLineEx(rl.Vector2{gx, gy}, rl.Vector2{gx + g, gy + g}, stroke, col)
		rl.DrawLineEx(rl.Vector2{gx, gy + g}, rl.Vector2{gx + g, gy}, stroke, col)
	}

	return
}

// draw_fullscreen_button renders a single caption-style button flush to the
// top-right corner (used on web builds, which have no OS title bar). It draws
// an enter/exit-fullscreen corner-bracket glyph, applies a Win11-style hover
// fill when the mouse is over it, and returns the button rect plus whether it
// is hovered so the caller can handle clicks.
draw_fullscreen_button :: proc(screen_w: i32, is_fs: bool, mouse: rl.Vector2) -> (r: rl.Rectangle, hovered: bool) {
	w := f32(CAPTION_BTN_W)
	h := f32(TAB_BAR_HEIGHT)
	r = rl.Rectangle{f32(screen_w) - w, 0, w, h}
	hovered = rl.CheckCollisionPointRec(mouse, r)

	// Opaque base + hover fill (matches the Windows caption buttons).
	rl.DrawRectangleRec(r, BG_SECONDARY)
	if hovered {
		rl.DrawRectangleRec(r, CAPTION_HOVER_FILL)
	}

	focused := rl.IsWindowFocused()
	col := FG_PRIMARY if focused else FG_SECONDARY

	stroke := scf(1.0)
	g := scf(10.0) // glyph box size
	arm := scf(3.5) // corner arm length
	gx := r.x + (w - g) / 2
	gy := r.y + (h - g) / 2

	// One L-shaped corner bracket. (sx, sy) point the arms away from the vertex.
	corner :: proc(cx, cy, sx, sy, arm, stroke: f32, col: rl.Color) {
		rl.DrawLineEx(rl.Vector2{cx, cy}, rl.Vector2{cx + sx * arm, cy}, stroke, col)
		rl.DrawLineEx(rl.Vector2{cx, cy}, rl.Vector2{cx, cy + sy * arm}, stroke, col)
	}

	if is_fs {
		// Exit: brackets inset toward the center, arms pointing outward.
		corner(gx + arm,     gy + arm,     -1, -1, arm, stroke, col)
		corner(gx + g - arm, gy + arm,     +1, -1, arm, stroke, col)
		corner(gx + arm,     gy + g - arm, -1, +1, arm, stroke, col)
		corner(gx + g - arm, gy + g - arm, +1, +1, arm, stroke, col)
	} else {
		// Enter: brackets at the outer corners, arms pointing inward.
		corner(gx,     gy,     +1, +1, arm, stroke, col)
		corner(gx + g, gy,     -1, +1, arm, stroke, col)
		corner(gx,     gy + g, +1, -1, arm, stroke, col)
		corner(gx + g, gy + g, -1, -1, arm, stroke, col)
	}

	return
}
