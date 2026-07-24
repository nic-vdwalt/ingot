package ui

PAINT_COMMAND_CAP :: 8192
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
}

Paint_List :: struct {
	commands:           [PAINT_COMMAND_CAP]Paint_Command,
	count:              int,
	text:               [PAINT_TEXT_CAP]u8,
	text_len:           int,
	clip_depth:         int,
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
	list.clip_depth = 0
	list.dropped_commands = 0
	list.dropped_text_bytes = 0
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
