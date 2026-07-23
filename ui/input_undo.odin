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
// snapshot so undo reverts runs of typing, not single keystrokes.
Input_Undo :: struct {
	undo:           [dynamic]Input_Snapshot,
	redo:           [dynamic]Input_Snapshot,
	last_edit_time: f64,
	last_edit_kind: Input_Edit_Kind,
}

INPUT_UNDO_MAX :: 100
INPUT_UNDO_COALESCE_SECS :: 1.0

input_snapshot_destroy :: proc(s: ^Input_Snapshot) {
	delete(s.text)
	delete(s.pills)
}

make_input_snapshot :: proc(text: string, cursor: int, pills: []Mention_Span) -> Input_Snapshot {
	s := Input_Snapshot {
		text   = strings.clone(text),
		cursor = cursor,
	}
	s.pills = make([dynamic]Mention_Span, 0, len(pills))
	for p in pills do append(&s.pills, p)
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
	for &s in u.redo do input_snapshot_destroy(&s)
	clear(&u.redo)
	coalesce :=
		kind != .Other &&
		kind == u.last_edit_kind &&
		now - u.last_edit_time < INPUT_UNDO_COALESCE_SECS &&
		len(u.undo) > 0
	u.last_edit_time = now
	u.last_edit_kind = kind
	if coalesce do return
	if len(u.undo) >= INPUT_UNDO_MAX {
		s := u.undo[0]
		input_snapshot_destroy(&s)
		ordered_remove(&u.undo, 0)
	}
	append(&u.undo, make_input_snapshot(text, cursor, pills))
}

input_undo_reset :: proc(u: ^Input_Undo) {
	for &s in u.undo do input_snapshot_destroy(&s)
	clear(&u.undo)
	for &s in u.redo do input_snapshot_destroy(&s)
	clear(&u.redo)
	u.last_edit_kind = .None
}

input_undo_destroy :: proc(u: ^Input_Undo) {
	input_undo_reset(u)
	delete(u.undo)
	delete(u.redo)
	u^ = {}
}
