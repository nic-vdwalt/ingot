// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Deferred one-frame overlay draw layer (a minimal Dear ImGui channel-split).
// Popups and tooltips record their draws during the frame; the commands are
// replayed after all main content so overlays paint on top without callers
// re-ordering code. Commands live one frame in bounded buffers — no retained
// widget state, no allocation. Recorded coordinates are screen space (the
// replay runs after any pane translation has been popped), so recorders in a
// translated pane must add pane_origin_x themselves.
//
// overlay_flush is called from apply_cursor (the end-of-frame hook every host
// already calls) so overlays work in existing apps without new wiring; it is
// also public for hosts that want explicit control of the replay point.
package ui

import "core:strings"
import rl "ingot:gfx"

// MAX_OVERLAY_CMDS bounds recorded commands per frame.
MAX_OVERLAY_CMDS :: 256

// OVERLAY_TEXT_CAP bounds recorded text bytes per frame (incl. NUL bytes).
OVERLAY_TEXT_CAP :: 8192

Overlay_Cmd_Kind :: enum u8 {
	Rect,
	Rect_Lines,
	Rounded,
	Rounded_Lines,
	Line,
	Text,
}

Overlay_Cmd :: struct {
	kind:      Overlay_Cmd_Kind,
	rect:      rl.Rectangle, // shape bounds; text: x/y position
	color:     rl.Color,
	roundness: f32,
	segments:  i32,
	thickness: f32,
	p0, p1:    rl.Vector2, // Line endpoints
	text_off:  i32, // Text: offset of NUL-terminated bytes in text_buf
	font_size: i32,
}

Overlay_State :: struct {
	cmds:     [MAX_OVERLAY_CMDS]Overlay_Cmd,
	count:    int,
	text_buf: [OVERLAY_TEXT_CAP]u8,
	text_len: int,
	open:     bool,
	dropped:  int, // commands discarded because a buffer was full
}

// overlay_begin opens a recording group for one overlay (popup, tooltip).
// When claim_input is true the group's rect (screen space) is registered with
// the input router so the overlay occludes the widgets it covers next frame.
overlay_begin :: proc(frame: ^Ui_Frame, rect: rl.Rectangle, claim_input: bool) {
	assert(frame != nil && frame.open, "overlay_begin: invalid frame")
	assert(!frame.overlay.open, "overlay_begin: group already open")
	assert(rect.width >= 0 && rect.height >= 0, "overlay_begin: negative rect")
	frame.overlay.open = true
	if claim_input do route_claim(frame, rect)
}

// overlay_end closes the current recording group.
overlay_end :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "overlay_end: invalid frame")
	assert(frame.overlay.open, "overlay_end: no group open")
	frame.overlay.open = false
}

@(private = "file")
ov_push :: proc(frame: ^Ui_Frame, cmd: Overlay_Cmd) {
	assert(frame != nil && frame.open, "overlay draw: invalid frame")
	state := &frame.overlay
	assert(state.open, "overlay draw outside overlay_begin/overlay_end")
	if state.count >= MAX_OVERLAY_CMDS {
		state.dropped += 1
		return
	}
	state.cmds[state.count] = cmd
	state.count += 1
}

overlay_rect :: proc(frame: ^Ui_Frame, rect: rl.Rectangle, color: rl.Color) {
	ov_push(frame, Overlay_Cmd{kind = .Rect, rect = rect, color = color})
}

overlay_rect_lines :: proc(frame: ^Ui_Frame, rect: rl.Rectangle, thickness: f32, color: rl.Color) {
	ov_push(
		frame,
		Overlay_Cmd{kind = .Rect_Lines, rect = rect, thickness = thickness, color = color},
	)
}

overlay_rounded :: proc(
	frame: ^Ui_Frame,
	rect: rl.Rectangle,
	roundness: f32,
	segments: i32,
	color: rl.Color,
) {
	ov_push(
		frame,
		Overlay_Cmd {
			kind = .Rounded,
			rect = rect,
			roundness = roundness,
			segments = segments,
			color = color,
		},
	)
}

overlay_rounded_lines :: proc(
	frame: ^Ui_Frame,
	rect: rl.Rectangle,
	roundness: f32,
	segments: i32,
	thickness: f32,
	color: rl.Color,
) {
	ov_push(
		frame,
		Overlay_Cmd {
			kind = .Rounded_Lines,
			rect = rect,
			roundness = roundness,
			segments = segments,
			thickness = thickness,
			color = color,
		},
	)
}

overlay_line :: proc(frame: ^Ui_Frame, p0, p1: rl.Vector2, color: rl.Color) {
	ov_push(frame, Overlay_Cmd{kind = .Line, p0 = p0, p1 = p1, color = color})
}

// overlay_text records a text draw. The string is copied into the bounded
// text buffer (with a NUL for cstring replay); overlong frames drop the
// command rather than allocate.
overlay_text :: proc(frame: ^Ui_Frame, text: string, x, y, font_size: i32, color: rl.Color) {
	assert(frame.overlay.open, "overlay_text outside overlay_begin/overlay_end")
	if len(text) + 1 > OVERLAY_TEXT_CAP - frame.overlay.text_len ||
	   frame.overlay.count >= MAX_OVERLAY_CMDS {
		frame.overlay.dropped += 1
		return
	}
	off := frame.overlay.text_len
	copy(frame.overlay.text_buf[off:], text)
	frame.overlay.text_buf[off + len(text)] = 0
	frame.overlay.text_len += len(text) + 1
	ov_push(
		frame,
		Overlay_Cmd {
			kind = .Text,
			rect = rl.Rectangle{f32(x), f32(y), 0, 0},
			text_off = i32(off),
			font_size = font_size,
			color = color,
		},
	)
}

// overlay_cmd_count returns the number of commands currently recorded.
overlay_cmd_count :: proc(frame: ^Ui_Frame) -> int {
	return frame.overlay.count
}

// overlay_dropped returns commands discarded this frame (buffer full).
overlay_dropped :: proc(frame: ^Ui_Frame) -> int {
	return frame.overlay.dropped
}

// overlay_reset discards all recorded commands without replaying (tests /
// teardown).
overlay_reset :: proc(frame: ^Ui_Frame) {
	frame.overlay.count = 0
	frame.overlay.text_len = 0
	frame.overlay.dropped = 0
	frame.overlay.open = false
}

// overlay_flush replays all recorded commands in record order and resets the
// buffers. Call after all main content is drawn, before rl.EndDrawing.
// Idempotent within a frame (a second call replays nothing).
overlay_flush :: proc(frame: ^Ui_Frame) {
	assert(!frame.overlay.open, "overlay_flush: group still open (missing overlay_end)")
	for i in 0 ..< frame.overlay.count {
		cmd := frame.overlay.cmds[i]
		switch cmd.kind {
		case .Rect:
			rl.DrawRectangleRec(cmd.rect, cmd.color)
		case .Rect_Lines:
			rl.DrawRectangleLinesEx(cmd.rect, cmd.thickness, cmd.color)
		case .Rounded:
			rl.DrawRectangleRounded(cmd.rect, cmd.roundness, cmd.segments, cmd.color)
		case .Rounded_Lines:
			rl.DrawRectangleRoundedLinesEx(
				cmd.rect,
				cmd.roundness,
				cmd.segments,
				cmd.thickness,
				cmd.color,
			)
		case .Line:
			rl.DrawLineEx(cmd.p0, cmd.p1, 1, cmd.color)
		case .Text:
			text := cstring(raw_data(frame.overlay.text_buf[cmd.text_off:]))
			draw_text_with(
				&frame.runtime.text,
				text,
				i32(cmd.rect.x),
				i32(cmd.rect.y),
				cmd.font_size,
				cmd.color,
			)
		}
	}
	frame.overlay.count = 0
	frame.overlay.text_len = 0
	frame.overlay.dropped = 0
}

// overlay_text_str is a convenience for callers holding a strings.Builder.
overlay_text_str :: proc(
	frame: ^Ui_Frame,
	sb: ^strings.Builder,
	x, y, font_size: i32,
	color: rl.Color,
) {
	assert(sb != nil, "overlay_text_str: nil builder")
	overlay_text(frame, strings.to_string(sb^), x, y, font_size, color)
}
