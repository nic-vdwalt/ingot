// LIB-CANDIDATE: imports only core:*.
// Library-owned mention-span + composer undo/redo machinery. Extracted from
// openalloy/alloy's state package so ingot:ui's text_input can offer optional
// pill-aware undo without importing any app package. Consumers may alias these
// (e.g. `Mention_Span :: ui.Mention_Span`) to share one definition.
package ui

import "core:strings"

// Byte range [start,end) into the owning builder that bounds an accepted
// @-mention path. Rendered as an atomic highlighted chip.
Mention_Span :: struct {
	start: int,
	end:   int,
}

// One composer snapshot for undo/redo: owned copies of the text, caret and
// mention pill ranges at the time of capture.
Input_Snapshot :: struct {
	text:   string,
	cursor: int,
	pills:  [dynamic]Mention_Span,
}

Input_Edit_Kind :: enum u8 {
	None,
	Insert,
	Delete,
	Other,
}

// Undo/redo stacks for the composer. A snapshot is taken before each edit
// burst; consecutive same-kind edits within the coalesce window share one
// snapshot so undo reverts runs of typing, not single keystrokes. The window
// is anchored at the group's first edit (`group_start_time`), not the most
// recent one - a sliding anchor would fold minutes of steady typing into a
// single undo step.
Input_Undo :: struct {
	undo:             [dynamic]Input_Snapshot,
	redo:             [dynamic]Input_Snapshot,
	last_edit_time:   f64,
	group_start_time: f64,
	last_edit_kind:   Input_Edit_Kind,
}

INPUT_UNDO_MAX :: 100
INPUT_UNDO_COALESCE_SECS :: 1.0

input_snapshot_destroy :: proc(s: ^Input_Snapshot) {
	assert(s != nil, "input_snapshot_destroy: nil s")
	if len(s.text) > 0 do delete(s.text)
	if cap(s.pills) > 0 do delete(s.pills)
	s^ = {}
}

make_input_snapshot :: proc(text: string, cursor: int, pills: []Mention_Span) -> Input_Snapshot {
	s := Input_Snapshot {
		cursor = cursor,
	}
	if len(text) > 0 do s.text = strings.clone(text)
	if len(pills) > 0 {
		s.pills = make([dynamic]Mention_Span, 0, len(pills))
		for p in pills do append(&s.pills, p)
	}
	return s
}

// input_undo_record captures the current composer state before a mutation of
// `kind`. Same-kind edits inside the coalesce window fold into the previous
// snapshot. Any recorded edit invalidates the redo stack.
input_undo_record :: proc(
	u: ^Input_Undo,
	text: string,
	cursor: int,
	pills: []Mention_Span,
	kind: Input_Edit_Kind,
	now: f64,
) {
	assert(u != nil, "input_undo_record: nil u")
	assert(cursor >= 0, "input_undo_record: negative cursor")
	for &s in u.redo do input_snapshot_destroy(&s)
	clear(&u.redo)
	// Coalesce against the group's start, so every group has a bounded
	// duration: a keystroke landing past the window always snapshots, no
	// matter how recent the previous keystroke was.
	coalesce :=
		kind != .Other &&
		kind == u.last_edit_kind &&
		now - u.group_start_time < INPUT_UNDO_COALESCE_SECS &&
		len(u.undo) > 0
	u.last_edit_time = now
	u.last_edit_kind = kind
	if coalesce do return
	if len(u.undo) >= INPUT_UNDO_MAX {
		input_snapshot_destroy(&u.undo[0])
		ordered_remove(&u.undo, 0)
	}
	append(&u.undo, make_input_snapshot(text, cursor, pills))
	u.group_start_time = now
	assert(len(u.undo) <= INPUT_UNDO_MAX, "input_undo_record: stack over cap")
}

input_undo_reset :: proc(u: ^Input_Undo) {
	assert(u != nil, "input_undo_reset: nil u")
	for &s in u.undo do input_snapshot_destroy(&s)
	clear(&u.undo)
	for &s in u.redo do input_snapshot_destroy(&s)
	clear(&u.redo)
	u.last_edit_kind = .None
	u.group_start_time = 0
}

input_undo_destroy :: proc(u: ^Input_Undo) {
	assert(u != nil, "input_undo_destroy: nil u")
	input_undo_reset(u)
	if cap(u.undo) > 0 do delete(u.undo)
	if cap(u.redo) > 0 do delete(u.redo)
	u^ = {}
}
