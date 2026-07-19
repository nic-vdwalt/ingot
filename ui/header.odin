// LIB-CANDIDATE: imports only core:* and ingot:gfx.
package ui

import rl "ingot:gfx"

// draw_app_header renders the app header strip: a BG_SECONDARY bar of height
// TAB_BAR_HEIGHT with a left-aligned title and a hairline bottom border. On
// Windows (custom title bar) it also draws the min/max/close caption buttons at
// the top-right and publishes the non-client layout so the whole strip drags
// the window. Returns the header height so callers can inset their content.
//
// Call once per frame, drawn last (on top of everything else). On macOS/Linux
// the native title bar is retained; this strip sits just below it.
draw_app_header :: proc(title: cstring, screen_w: i32) -> (header_h: i32) {
	header_h = TAB_BAR_HEIGHT
	h := f32(header_h)

	// Bar background + hairline bottom border.
	rl.DrawRectangle(0, 0, screen_w, header_h, BG_SECONDARY)
	rl.DrawLineEx(
		rl.Vector2{0, h}, rl.Vector2{f32(screen_w), h},
		scf(1.0), BORDER_SUBTLE,
	)

	// Left-aligned, vertically centered title.
	if title != nil && len(title) > 0 {
		ty := (header_h - FONT_SIZE) / 2
		draw_text(title, PADDING, ty, FONT_SIZE, FG_SECONDARY)
	}

	// Windows custom title bar: caption buttons + non-client layout publish.
	when ODIN_OS == .Windows {
		if titlebar_enabled() {
			hover, pressed, maximized := titlebar_state()
			cap_in := Caption_Input{
				hover     = Caption_Button(u8(hover)),
				pressed   = Caption_Button(u8(pressed)),
				maximized = maximized,
			}
			min_r, max_r, close_r := draw_caption_buttons(screen_w, cap_in)
			// interactive_right = 0: the whole strip (minus buttons) drags.
			titlebar_set_layout(min_r, max_r, close_r, 0)
		}
	}

	return
}
