package ui

Icon :: enum u8 {
	Settings,
	Close,
	Chevron_Left,
	Chevron_Right,
	Play,
	Pause,
	// Appended so existing ordinals stay stable for saved views and tests.
	Globe,
	Pointer,
	Text_Cursor,
	Sliders,
	Bar_Chart,
	Document,
	Layout_Grid,
	Layers,
	Gauge,
	Swatch,
	Motion,
	Zoom,
	Search,
	Command,
	Orbit,
	Sun,
}

// draw_icon_frame strokes an SVG-style outline glyph (24-unit viewBox, 2-unit
// stroke, round caps and joins) centred in rect. The switch is exhaustive so a
// new Icon cannot compile until it is assigned a glyph group.
draw_icon_frame :: proc(frame: ^Ui_Frame, icon: Icon, rect: Rect_I32, color: Color) {
	assert(frame != nil && frame.open, "draw_icon_frame: invalid frame")
	assert(rect.w >= 0 && rect.h >= 0, "draw_icon_frame: invalid rect")
	if ui_frame_drop_degenerate(frame, rect.w <= 0 || rect.h <= 0) do return
	list := frame_paint_list(frame)
	before := list.count
	pen := icon_pen_make(frame, rect, color)
	switch icon {
	case .Settings, .Close, .Chevron_Left, .Chevron_Right, .Play, .Pause:
		draw_icon_controls(frame, pen, icon)
	case .Globe, .Orbit, .Sun, .Gauge, .Search, .Zoom:
		draw_icon_round(frame, pen, icon)
	case .Pointer, .Text_Cursor, .Motion, .Command:
		draw_icon_tools(frame, pen, icon)
	case .Sliders, .Bar_Chart, .Document, .Layout_Grid, .Layers, .Swatch:
		draw_icon_blocks(frame, pen, icon)
	}
	// A full paint list drops commands instead of growing, so the delta can only
	// undercount; the bound still catches a glyph whose geometry grew too large.
	assert(list.count >= before, "draw_icon_frame: paint list shrank")
	assert(list.count - before <= ICON_COMMANDS_MAX, "draw_icon_frame: icon over command budget")
}
