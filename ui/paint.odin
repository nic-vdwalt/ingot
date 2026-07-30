package ui

import "base:runtime"

// Paint capacities. These are inline arrays inside Paint_List, and Ui_Output
// holds two lists (main + overlay), so every byte here is resident for the
// whole session whether or not it is ever written - which is why they are
// sized from measurement rather than round numbers.
//
// Measured with the gallery smoke run (scripts/smoke-gallery.sh), which walks
// every section including the 1000-button stress grid, at three viewports:
//
//   viewport            commands   text bytes
//   phone  780x1688          548        1,887
//   laptop 1100x760          341        1,166
//   4K     3840x2160       2,046        7,138
//
// The caps below give ~4x headroom over the 4K peak. The previous values
// (32,768 commands / 262,144 bytes) were 16x and 36x that, costing 4.2 MiB
// per list - 8.4 MiB per Ui_Output - to hold space nothing ever used.
//
// Overflow is graceful and counted (dropped_commands / dropped_text_bytes,
// see paint_push), not corrupting, so a heavier consumer degrades visibly
// rather than crashing. Both are #config for exactly that case.
PAINT_COMMAND_CAP :: #config(INGOT_PAINT_COMMAND_CAP, 8192)
PAINT_TEXT_CAP :: #config(INGOT_PAINT_TEXT_CAP, 32768)
PAINT_CLIP_CAP :: 64

// Sanity bounds: a capacity below the measured 4K peak would drop commands on
// an ordinary large display, and the code assumes room for at least one clip
// pair plus content.
#assert(PAINT_COMMAND_CAP >= 4096)
#assert(PAINT_TEXT_CAP >= 16384)

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
	commands:             [PAINT_COMMAND_CAP]Paint_Command,
	count:                int,
	text:                 [PAINT_TEXT_CAP]u8,
	text_len:             int,
	clip_stack:           [PAINT_CLIP_CAP]Rect,
	clip_emitted:         [PAINT_CLIP_CAP]bool,
	// Origin of each open clip so an unbalanced frame can name the exact
	// begin_scissor_mode call that leaked instead of only its depth.
	clip_origin:          [PAINT_CLIP_CAP]runtime.Source_Code_Location,
	clip_count:           int,
	clip_end_reserved:    int,
	// Begins rejected after PAINT_CLIP_CAP still need matching ends. Tracking
	// their logical depth separately lets paint_clip_end consume those ends
	// without popping a real outer clip.
	clip_overflow_depth:  int,
	dropped_commands:     int,
	dropped_text_bytes:   int,
	// High-water marks across this list's lifetime, surviving the per-frame
	// reset. Always tracked (two max() per frame) rather than gated behind
	// UI_TELEMETRY_ENABLED, because these are what justify PAINT_COMMAND_CAP
	// and PAINT_TEXT_CAP: a bound nobody can measure is a guess. The arrays
	// are inline, so unused capacity is memory that is always resident.
	peak_count:           int,
	peak_text_len:        int,
	command_append_count: u64,
	text_append_count:    u64,
	text_bytes_copied:    u64,
	command_growth_count: u64,
	text_growth_count:    u64,
	sink:                 Paint_Sink,
	sink_userdata:        rawptr,
}

// Ui_Output holds both paint channels by value, deliberately.
//
// Heap-allocating them was considered while cutting the engine's static
// footprint and rejected on the measurements. After right-sizing the
// capacities above, Paint_List is 0.97 MiB and Ui_Output is 1.97 MiB, so
// moving the overlay channel to the heap would save at most 0.97 MiB - and
// only for an app that never shows an overlay, since an app that does still
// allocates it. For the common case the saving is zero: the memory moves from
// a statically bounded region to the heap without shrinking.
//
// Against that: it would break Session's API, add a create/destroy lifecycle
// and an allocation-failure path to something that currently cannot fail, and
// trade static allocation for dynamic - the opposite of the preference in
// docs/TIGER_STYLE.md.
//
// The remaining static weight is gfx.Context at 10.7 MiB, essentially all of
// it the batch vertex/index arrays, which the 4K measurement shows are NOT
// oversized (see BATCH_MAX_VERTICES). Sizing those from the real framebuffer
// at init is the change with actual headroom behind it, and it belongs in gfx.
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
	list.clip_end_reserved = 0
	list.clip_overflow_depth = 0
	list.dropped_commands = 0
	list.dropped_text_bytes = 0
	when UI_TELEMETRY_ENABLED {
		list.command_append_count = 0
		list.text_append_count = 0
		list.text_bytes_copied = 0
		list.command_growth_count = 0
		list.text_growth_count = 0
	}
}

// paint_clip_leak_origin names the call site of the outermost clip left open,
// which is what a caller needs to fix an unbalanced frame. The zero location
// is returned when the stack is balanced.
paint_clip_leak_origin :: proc(list: ^Paint_List) -> runtime.Source_Code_Location {
	assert(list != nil, "paint_clip_leak_origin: nil list")
	assert(list.clip_count >= 0, "paint_clip_leak_origin: negative depth")
	if list.clip_count == 0 do return {}
	return list.clip_origin[list.clip_count - 1]
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
paint_clip_begin :: proc(list: ^Paint_List, rect: Rect, loc := #caller_location) {
	assert(list != nil, "paint_clip_begin: nil list")
	// Layout-derived negative extents mean an empty clip, not a malformed
	// command. Clamp them before intersection so the stack remains balanced.
	clamped := Rect{rect.x, rect.y, max(f32(0), rect.width), max(f32(0), rect.height)}
	if list.clip_count >= PAINT_CLIP_CAP {
		list.clip_overflow_depth += 1
		list.dropped_commands += 1
		return
	}
	effective := clamped
	if list.clip_count > 0 {
		effective = paint_clip_intersection(list.clip_stack[list.clip_count - 1], rect)
	}
	emitted := false
	if list.count + list.clip_end_reserved + 2 <= PAINT_COMMAND_CAP {
		emitted = paint_push_unreserved(list, {kind = .Clip_Begin, rect = effective})
		if emitted do list.clip_end_reserved += 1
	} else {
		list.dropped_commands += 1
	}
	list.clip_stack[list.clip_count] = effective
	list.clip_emitted[list.clip_count] = emitted
	list.clip_origin[list.clip_count] = loc
	list.clip_count += 1
}

paint_clip_end :: proc(list: ^Paint_List) {
	assert(list != nil, "paint_clip_end: nil list")
	if list.clip_overflow_depth > 0 {
		list.clip_overflow_depth -= 1
		return
	}
	// An unmatched end is a caller bug, but ignoring it is the safe failure:
	// driving depth negative would corrupt the next view's clip index.
	if list.clip_count == 0 do return
	list.clip_count -= 1
	if !list.clip_emitted[list.clip_count] do return
	assert(list.clip_end_reserved > 0, "paint_clip_end: missing reservation")
	restore := list.clip_count > 0
	rect: Rect
	if restore do rect = list.clip_stack[list.clip_count - 1]
	list.clip_end_reserved -= 1
	emitted := paint_push_unreserved(list, {kind = .Clip_End, rect = rect, clip_restore = restore})
	assert(emitted, "paint_clip_end: reserved append failed")
}

@(private = "file")
paint_push_unreserved :: proc(list: ^Paint_List, command: Paint_Command) -> bool {
	assert(list != nil, "paint_push_unreserved: nil list")
	if list.count >= PAINT_COMMAND_CAP do return false
	list.commands[list.count] = command
	list.count += 1
	list.peak_count = max(list.peak_count, list.count)
	when UI_TELEMETRY_ENABLED do list.command_append_count += 1
	if list.sink != nil do list.sink(list, command, list.sink_userdata)
	return true
}

paint_push :: proc(list: ^Paint_List, command: Paint_Command) -> bool {
	assert(list != nil, "paint_push: nil list")
	assert(list.clip_end_reserved >= 0, "paint_push: negative reservation")
	if list.count >= PAINT_COMMAND_CAP - list.clip_end_reserved {
		list.dropped_commands += 1
		return false
	}
	return paint_push_unreserved(list, command)
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
	list.peak_text_len = max(list.peak_text_len, list.text_len)
	when UI_TELEMETRY_ENABLED {
		list.text_append_count += 1
		list.text_bytes_copied += u64(len(text))
	}
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
