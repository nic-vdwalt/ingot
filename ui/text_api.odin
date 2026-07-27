// LIB-CANDIDATE: imports only core:*.
//
// Semantic text API. Callers name the *role* a string plays and the *ink* it
// is drawn with; the frame's Ui_Metrics and Theme resolve those to a concrete
// font size and color. This removes the two most repeated call shapes in
// consumer code — re-deriving metrics/theme purely to feed a size and a color,
// and cloning every literal to a cstring at the call site.
//
// The explicit draw_text_frame / measure_text_frame / draw_text_wrapped_frame /
// draw_text_truncated_frame entry points remain the escape hatch for callers
// that need a size or color these enums do not name.
package ui

import "core:strings"

// Text_Role names the typographic slot a string occupies. Sizes come from
// Ui_Metrics so they follow the runtime UI scale. There are exactly four roles
// because there are exactly four sizes; a role that resolves to the same size
// as another role only lets two call sites disagree while both look correct.
Text_Role :: enum u8 {
	Body, // default reading size
	Title, // view/section titles and emphasized headings
	Label, // control labels, buttons, dense rows
	Note, // footnotes, timestamps, hints
}

// Ink names the semantic role of a text color rather than a palette slot, so
// themes can remap without touching call sites.
Ink :: enum u8 {
	Primary,
	Heading,
	Secondary,
	Muted,
	Accent,
	Danger,
	Success,
	Inverse,
	Disabled,
	Label,
	Accent_Light,
	Tool,
	Diff_Add,
	Diff_Remove,
	User,
	Assistant,
	Plan,
}

// text_role_size resolves a role against the frame's scaled metrics.
text_role_size :: proc(frame: ^Ui_Frame, role: Text_Role) -> i32 {
	metrics := ui_frame_metrics(frame)
	size: i32
	switch role {
	case .Body:
		size = metrics.FONT_SIZE_BODY
	case .Title:
		size = metrics.FONT_SIZE_TITLE
	case .Label:
		size = metrics.FONT_SIZE_LABEL
	case .Note:
		size = metrics.FONT_SIZE_NOTE
	}
	assert(size > 0, "text_role_size: role resolved to non-positive size")
	return size
}

// text_role_line_height resolves the wrapped line advance for a role. Body
// uses the metric directly; other roles keep the same ratio so mixed-size
// blocks stay visually consistent across UI scales.
text_role_line_height :: proc(frame: ^Ui_Frame, role: Text_Role) -> i32 {
	metrics := ui_frame_metrics(frame)
	assert(metrics.LINE_HEIGHT > 0, "text_role_line_height: invalid line height")
	if role == .Body do return metrics.LINE_HEIGHT
	assert(metrics.FONT_SIZE_BODY > 0, "text_role_line_height: invalid body size")
	size := text_role_size(frame, role)
	height := (size * metrics.LINE_HEIGHT + metrics.FONT_SIZE_BODY / 2) / metrics.FONT_SIZE_BODY
	if height < size + 1 do height = size + 1
	assert(height > 0, "text_role_line_height: resolved non-positive height")
	return height
}

// text_ink resolves a semantic ink against the frame's theme.
text_ink :: proc(frame: ^Ui_Frame, ink: Ink) -> Color {
	style := ui_frame_theme(frame)
	color: Color
	switch ink {
	case .Primary:
		color = style.fg_primary
	case .Heading:
		color = style.fg_heading
	case .Secondary:
		color = style.fg_secondary
	case .Muted:
		color = style.fg_muted_dim
	case .Accent:
		color = style.fg_accent
	case .Danger:
		color = style.fg_error
	case .Success:
		color = style.fg_success
	case .Inverse:
		color = style.button_text
	case .Disabled:
		color = style.fg_disabled
	case .Label:
		color = style.fg_label
	case .Accent_Light:
		color = style.fg_accent_light
	case .Tool:
		color = style.fg_tool
	case .Diff_Add:
		color = style.fg_diff_add
	case .Diff_Remove:
		color = style.fg_diff_remove
	case .User:
		color = style.fg_user
	case .Assistant:
		color = style.fg_assistant
	case .Plan:
		color = style.fg_plan
	}
	assert(color.a > 0, "text_ink: theme resolved a fully transparent ink")
	return color
}

// text draws a single line at (x, y). The cstring conversion happens once,
// here, in the temp allocator.
text :: proc(
	frame: ^Ui_Frame,
	s: string,
	x, y: i32,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) {
	assert(frame != nil && frame.open, "text: invalid frame")
	if len(s) == 0 do return
	size := text_role_size(frame, role)
	color := text_ink(frame, ink)
	value := strings.clone_to_cstring(s, context.temp_allocator)
	draw_text_frame(frame, value, x, y, size, color)
}

// text_wrapped word-wraps within max_width and returns the height consumed.
// Pass draw = false to measure without emitting paint commands.
text_wrapped :: proc(
	frame: ^Ui_Frame,
	s: string,
	x, y, max_width: i32,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
	draw: bool = true,
) -> i32 {
	assert(frame != nil && frame.open, "text_wrapped: invalid frame")
	assert(max_width >= 0, "text_wrapped: negative width")
	if len(s) == 0 do return 0
	size := text_role_size(frame, role)
	line_height := text_role_line_height(frame, role)
	color := text_ink(frame, ink)
	return draw_text_wrapped_frame(
		frame,
		x,
		y,
		max_width,
		s,
		color,
		size,
		line_height,
		draw = draw,
	)
}

// text_truncated draws one line, cutting it with a trailing ellipsis when it
// would exceed max_width.
text_truncated :: proc(
	frame: ^Ui_Frame,
	s: string,
	x, y, max_width: i32,
	role: Text_Role = .Body,
	ink: Ink = .Primary,
) {
	assert(frame != nil && frame.open, "text_truncated: invalid frame")
	assert(max_width >= 0, "text_truncated: negative width")
	if len(s) == 0 do return
	size := text_role_size(frame, role)
	color := text_ink(frame, ink)
	draw_text_truncated_frame(frame, s, x, y, max_width, size, color)
}

// text_width measures a single line without drawing it.
text_width :: proc(frame: ^Ui_Frame, s: string, role: Text_Role = .Body) -> i32 {
	assert(frame != nil && frame.open, "text_width: invalid frame")
	if len(s) == 0 do return 0
	size := text_role_size(frame, role)
	value := strings.clone_to_cstring(s, context.temp_allocator)
	width := measure_text_frame(frame, value, size)
	assert(width >= 0, "text_width: negative measurement")
	return width
}

// text_height returns the height text_wrapped would consume for the same
// arguments, without emitting paint commands.
text_height :: proc(frame: ^Ui_Frame, s: string, max_width: i32, role: Text_Role = .Body) -> i32 {
	assert(frame != nil && frame.open, "text_height: invalid frame")
	assert(max_width >= 0, "text_height: negative width")
	if len(s) == 0 do return 0
	return text_wrapped(frame, s, 0, 0, max_width, role, .Primary, draw = false)
}
