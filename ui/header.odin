// LIB-CANDIDATE: imports only core:* and ingot:gfx.
package ui

import rl "ingot:gfx"

// draw_app_header renders the app header strip: a theme.bg_secondary bar of height
// TAB_BAR_HEIGHT with a left-aligned title and a hairline bottom border. On
// Windows (custom title bar) it also draws the min/max/close caption buttons at
// the top-right and publishes the non-client layout so the whole strip drags
// the window. Returns the header height so callers can inset their content.
//
// Call once per frame, drawn last (on top of everything else). On macOS/Linux
// the native title bar is retained; this strip sits just below it.
draw_app_header :: proc(frame: ^Ui_Frame, title: cstring, screen_w: i32) -> (header_h: i32) {
	assert(screen_w > 0, "draw_app_header: invalid screen width")
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	header_h = metrics.TAB_BAR_HEIGHT
	h := f32(header_h)

	// Bar background + hairline bottom border.
	rl.DrawRectangle(0, 0, screen_w, header_h, style.bg_secondary)
	rl.DrawLineEx(
		rl.Vector2{0, h},
		rl.Vector2{f32(screen_w), h},
		ui_frame_scf(frame, 1.0),
		style.border_subtle,
	)

	// Left-aligned, vertically centered title.
	if title != nil && len(title) > 0 {
		ty := (header_h - metrics.FONT_SIZE_BODY) / 2
		draw_text_frame(
			frame,
			title,
			metrics.PADDING,
			ty,
			metrics.FONT_SIZE_BODY,
			style.fg_secondary,
		)
	}

	// Windows custom title bar: caption buttons + non-client layout publish.
	when ODIN_OS == .Windows {
		if titlebar_enabled() {
			hover, pressed, maximized := titlebar_state()
			cap_in := Caption_Input {
				hover     = Caption_Button(u8(hover)),
				pressed   = Caption_Button(u8(pressed)),
				maximized = maximized,
			}
			min_r, max_r, close_r := draw_caption_buttons(frame, screen_w, cap_in)
			// interactive_right = 0: the whole strip (minus buttons) drags.
			titlebar_set_layout(min_r, max_r, close_r, 0)
		}
	}

	// Web build: no OS title bar, so offer a fullscreen toggle at the top-right.
	when ODIN_OS == .JS {
		is_fs := rl.IsWindowFullscreen()
		_, hovered := draw_fullscreen_button(frame, screen_w, is_fs, rl.GetMousePosition())
		if hovered {
			request_cursor(frame, .POINTING_HAND)
			if rl.IsMouseButtonPressed(.LEFT) {
				rl.ToggleFullscreen()
			}
		}
	}

	return
}
