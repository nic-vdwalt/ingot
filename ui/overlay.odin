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

@(private = "file")
Overlay_State :: struct {
	cmds:     [MAX_OVERLAY_CMDS]Overlay_Cmd,
	count:    int,
	text_buf: [OVERLAY_TEXT_CAP]u8,
	text_len: int,
	open:     bool,
	dropped:  int, // commands discarded because a buffer was full
}

@(private = "file")
ov: Overlay_State

// overlay_begin opens a recording group for one overlay (popup, tooltip).
// When claim_input is true the group's rect (screen space) is registered with
// the input router so the overlay occludes the widgets it covers next frame.
overlay_begin :: proc(rect: rl.Rectangle, claim_input: bool) {
	assert(!ov.open, "overlay_begin: group already open (missing overlay_end)")
	assert(rect.width >= 0 && rect.height >= 0, "overlay_begin: negative rect")
	ov.open = true
	if claim_input {
		route_claim(rect)
	}
}

// overlay_end closes the current recording group.
overlay_end :: proc() {
	assert(ov.open, "overlay_end: no group open")
	ov.open = false
}

@(private = "file")
ov_push :: proc(cmd: Overlay_Cmd) {
	assert(ov.open, "overlay draw outside overlay_begin/overlay_end")
	if ov.count >= MAX_OVERLAY_CMDS {
		ov.dropped += 1
		return
	}
	ov.cmds[ov.count] = cmd
	ov.count += 1
}

overlay_rect :: proc(rect: rl.Rectangle, color: rl.Color) {
	ov_push(Overlay_Cmd{kind = .Rect, rect = rect, color = color})
}

overlay_rect_lines :: proc(rect: rl.Rectangle, thickness: f32, color: rl.Color) {
	ov_push(Overlay_Cmd{kind = .Rect_Lines, rect = rect, thickness = thickness, color = color})
}

overlay_rounded :: proc(rect: rl.Rectangle, roundness: f32, segments: i32, color: rl.Color) {
	ov_push(
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
	rect: rl.Rectangle,
	roundness: f32,
	segments: i32,
	thickness: f32,
	color: rl.Color,
) {
	ov_push(
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

overlay_line :: proc(p0, p1: rl.Vector2, color: rl.Color) {
	ov_push(Overlay_Cmd{kind = .Line, p0 = p0, p1 = p1, color = color})
}

// overlay_text records a text draw. The string is copied into the bounded
// text buffer (with a NUL for cstring replay); overlong frames drop the
// command rather than allocate.
overlay_text :: proc(text: string, x, y, font_size: i32, color: rl.Color) {
	assert(ov.open, "overlay_text outside overlay_begin/overlay_end")
	if len(text) + 1 > OVERLAY_TEXT_CAP - ov.text_len || ov.count >= MAX_OVERLAY_CMDS {
		ov.dropped += 1
		return
	}
	off := ov.text_len
	copy(ov.text_buf[off:], text)
	ov.text_buf[off + len(text)] = 0
	ov.text_len += len(text) + 1
	ov_push(
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
overlay_cmd_count :: proc() -> int {
	return ov.count
}

// overlay_dropped returns commands discarded this frame (buffer full).
overlay_dropped :: proc() -> int {
	return ov.dropped
}

// overlay_reset discards all recorded commands without replaying (tests /
// teardown).
overlay_reset :: proc() {
	ov.count = 0
	ov.text_len = 0
	ov.dropped = 0
	ov.open = false
}

// overlay_flush replays all recorded commands in record order and resets the
// buffers. Call after all main content is drawn, before rl.EndDrawing.
// Idempotent within a frame (a second call replays nothing).
overlay_flush :: proc() {
	assert(!ov.open, "overlay_flush: group still open (missing overlay_end)")
	for i in 0 ..< ov.count {
		cmd := ov.cmds[i]
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
			text := cstring(raw_data(ov.text_buf[cmd.text_off:]))
			draw_text(text, i32(cmd.rect.x), i32(cmd.rect.y), cmd.font_size, cmd.color)
		}
	}
	ov.count = 0
	ov.text_len = 0
	ov.dropped = 0
}

// overlay_text_str is a convenience for callers holding a strings.Builder.
overlay_text_str :: proc(sb: ^strings.Builder, x, y, font_size: i32, color: rl.Color) {
	assert(sb != nil, "overlay_text_str: nil builder")
	overlay_text(strings.to_string(sb^), x, y, font_size, color)
}
