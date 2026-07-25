package ui

PAINT_COMMAND_CAP :: 32768
PAINT_TEXT_CAP :: 262144
PAINT_CLIP_CAP :: 64

Paint_Channel :: enum u8 {
	Main,
	Overlay,
}

Paint_Sink :: #type proc(list: ^Paint_List, command: Paint_Command, userdata: rawptr)

Paint_Kind :: enum u8 {
	Rectangle,
	Rectangle_Outline,
	Rectangle_Rounded,
	Rectangle_Rounded_Outline,
	Rectangle_Gradient_V,
	Line,
	Circle,
	Circle_Outline,
	Ring,
	Triangle,
	Text,
	Codepoint,
	Clip_Begin,
	Clip_End,
}

Paint_Command :: struct {
	kind:         Paint_Kind,
	rect:         Rect,
	p0:           Vec2,
	p1:           Vec2,
	p2:           Vec2,
	color:        Color,
	color_end:    Color,
	thickness:    f32,
	roundness:    f32,
	segments:     i32,
	inner_radius: f32,
	outer_radius: f32,
	start_angle:  f32,
	end_angle:    f32,
	font:         Font_Id,
	font_size:    f32,
	spacing:      f32,
	codepoint:    rune,
	text_offset:  int,
	text_length:  int,
	clip_restore: bool,
}

Paint_List :: struct {
	commands:           [PAINT_COMMAND_CAP]Paint_Command,
	count:              int,
	text:               [PAINT_TEXT_CAP]u8,
	text_len:           int,
	clip_stack:         [PAINT_CLIP_CAP]Rect,
	clip_emitted:       [PAINT_CLIP_CAP]bool,
	clip_count:         int,
	dropped_commands:   int,
	dropped_text_bytes: int,
	sink:               Paint_Sink,
	sink_userdata:      rawptr,
}

Ui_Output :: struct {
	main:     Paint_List,
	overlay:  Paint_List,
	platform: Platform_Output,
}

paint_list_reset :: proc(list: ^Paint_List) {
	assert(list != nil, "paint_list_reset: nil list")
	list.count = 0
	list.text_len = 0
	list.clip_count = 0
	list.dropped_commands = 0
	list.dropped_text_bytes = 0
}

paint_clip_intersection :: proc(a, b: Rect) -> Rect {
	assert(a.width >= 0 && a.height >= 0, "paint_clip_intersection: invalid first rect")
	assert(b.width >= 0 && b.height >= 0, "paint_clip_intersection: invalid second rect")
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.width, b.x + b.width)
	y1 := min(a.y + a.height, b.y + b.height)
	return {x0, y0, max(f32(0), x1 - x0), max(f32(0), y1 - y0)}
}

// The clip stack is maintained even when the command buffer is full, because a
// dropped Clip_Begin must still pair with its Clip_End; tying the depth to push
// success leaves the stack unbalanced for the rest of the frame. clip_emitted
// records whether the paired command reached the buffer so the replayed stream
// stays balanced too.
paint_clip_begin :: proc(list: ^Paint_List, rect: Rect) {
	assert(list != nil, "paint_clip_begin: nil list")
	assert(rect.width >= 0 && rect.height >= 0, "paint_clip_begin: invalid rect")
	assert(list.clip_count < PAINT_CLIP_CAP, "paint_clip_begin: clip limit")
	effective := rect
	if list.clip_count > 0 {
		effective = paint_clip_intersection(list.clip_stack[list.clip_count - 1], rect)
	}
	emitted := paint_push(list, {kind = .Clip_Begin, rect = effective})
	list.clip_stack[list.clip_count] = effective
	list.clip_emitted[list.clip_count] = emitted
	list.clip_count += 1
}

paint_clip_end :: proc(list: ^Paint_List) {
	assert(list != nil, "paint_clip_end: nil list")
	assert(list.clip_count > 0, "paint_clip_end: no clip")
	list.clip_count -= 1
	if !list.clip_emitted[list.clip_count] do return
	restore := list.clip_count > 0
	rect: Rect
	if restore do rect = list.clip_stack[list.clip_count - 1]
	paint_push(list, {kind = .Clip_End, rect = rect, clip_restore = restore})
}

paint_push :: proc(list: ^Paint_List, command: Paint_Command) -> bool {
	assert(list != nil, "paint_push: nil list")
	if list.count >= PAINT_COMMAND_CAP {
		list.dropped_commands += 1
		return false
	}
	list.commands[list.count] = command
	list.count += 1
	if list.sink != nil do list.sink(list, command, list.sink_userdata)
	return true
}

paint_push_text :: proc(list: ^Paint_List, command: Paint_Command, text: string) -> bool {
	assert(list != nil, "paint_push_text: nil list")
	if len(text) > PAINT_TEXT_CAP - list.text_len {
		list.dropped_text_bytes += len(text)
		return false
	}
	stored_command := command
	stored_command.text_offset = list.text_len
	stored_command.text_length = len(text)
	copy(list.text[list.text_len:], transmute([]u8)text)
	list.text_len += len(text)
	return paint_push(list, stored_command)
}

paint_text :: proc(list: ^Paint_List, command: Paint_Command) -> string {
	assert(list != nil, "paint_text: nil list")
	assert(command.text_offset >= 0 && command.text_length >= 0, "paint_text: invalid range")
	end := command.text_offset + command.text_length
	assert(end <= list.text_len, "paint_text: range exceeds storage")
	return string(list.text[command.text_offset:end])
}

ui_output_reset :: proc(output: ^Ui_Output) {
	assert(output != nil, "ui_output_reset: nil output")
	paint_list_reset(&output.main)
	paint_list_reset(&output.overlay)
	platform_output_reset(&output.platform)
}

paint_list_set_sink :: proc(list: ^Paint_List, sink: Paint_Sink, userdata: rawptr) {
	assert(list != nil, "paint_list_set_sink: nil list")
	assert((sink == nil) == (userdata == nil), "paint_list_set_sink: incomplete sink")
	list.sink = sink
	list.sink_userdata = userdata
}
