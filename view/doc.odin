// The view document: a flat, position-independent description of a UI that a
// builder can author and any client can play back.
//
// Goal: let a tool produce a view as data, so it can be saved, shipped, diffed
// and fuzzed, without introducing a retained widget tree.
//
// Method: nodes live in one flat array and reference each other by index, never
// by pointer, so a document is byte-copyable. All variable-length text lives in
// a single blob addressed by offset and length, the same shape Paint_Command
// uses. Presentation is expressed only in ui tokens, so a view inherits theme
// and DPI correctness instead of re-deriving it.
//
// Two storage types, because they have different jobs. View_Doc is the mutable
// authoring buffer: fixed capacity, owned by the builder, never shipped.
// View is what view_play consumes: exactly-sized borrowed slices, so generated
// code emits [12]View_Node rather than [512] and nothing zero-fills .data.
// See docs/view-format.md.
package view

import "ingot:ui"

// Bounds. Every limit is named so it can be raised in one place, and the ones
// that must agree with ui are checked by the compiler rather than by comment.
VIEW_NODES_MAX :: 512
VIEW_DEPTH_MAX :: 16
VIEW_TEXT_BYTES_MAX :: 32768
VIEW_EVENTS_MAX :: 64
VIEW_FLEX_TRACKS_MAX :: 32

// A view nests through both the identity stack and the layout stack, so it may
// not be deeper than either. Catching this at compile time means raising
// VIEW_DEPTH_MAX cannot silently start overflowing a ui stack at runtime.
#assert(VIEW_DEPTH_MAX <= ui.MAX_ID_DEPTH)
#assert(VIEW_DEPTH_MAX <= ui.MAX_LAYOUT_DEPTH)

// A document that filled every node with an interactive widget must still fit
// the focus ring, otherwise validation would depend on node kinds rather than
// on a bound.
#assert(VIEW_NODES_MAX >= ui.MAX_FOCUSABLES)

VIEW_NODE_NONE :: i32(-1)
VIEW_BINDING_NONE :: i32(-1)

// View_Kind is closed and frozen per format version. Every kind maps to a
// procedure that is public from ingot:ui; a kind that cannot be played must not
// exist, because the document would then describe something no client can show.
View_Kind :: enum u8 {
	// Containers open a layout frame and an identity scope.
	Row,
	Column,
	Panel,
	Flex_Row,
	Flex_Column,
	// Interactive leaves carry a stable key and usually a binding.
	Button,
	Icon_Button,
	Back_Button,
	Checkbox,
	Radio,
	Slider,
	Text_Input,
	Collapsible_Header,
	// Presentational leaves register no focus and need no identity.
	Label,
	Section_Header,
	Status_Pill,
	Kv_Row,
	Progress_Bar,
	Spinner,
	Separator,
	Spacer,
}

View_Flag :: enum u8 {
	Disabled,
	Masked,
}

View_Flags :: bit_set[View_Flag;u16]

// View_Node is one element. parent, first_child and next_sibling are indices
// into the same array; VIEW_NODE_NONE terminates. Text fields index doc.text.
// Numeric geometry is in design units, so the ui facade scales it exactly once
// at the boundary rather than the document baking in a DPI.
View_Node :: struct {
	kind:         View_Kind,
	flags:        View_Flags,
	parent:       i32,
	first_child:  i32,
	next_sibling: i32,
	// key is identity and is never drawn. label is what the user sees. They are
	// separate so renaming a control in the builder cannot reset its state.
	key_offset:   u32,
	key_length:   u16,
	label_offset: u32,
	label_length: u16,
	// value is secondary text: a kv_row's value, a text_input's placeholder.
	value_offset: u32,
	value_length: u16,
	binding:      i32,
	// Presentation: tokens only. A literal here would be a theme or DPI bug.
	ink:          ui.Ink,
	text_role:    ui.Text_Role,
	gap:          ui.Space,
	padding:      ui.Space,
	align:        ui.Cross_Align,
	justify:      ui.Main_Align,
	style:        ui.Btn_Style,
	track:        ui.Track,
	size_main:    i32,
	integer:      i32,
	number_lo:    f32,
	number_hi:    f32,
	number_step:  f32,
}

// View_Doc is the authoring buffer. Static allocation: the builder owns one for
// its whole lifetime and never grows it.
View_Doc :: struct {
	nodes:    [VIEW_NODES_MAX]View_Node,
	count:    i32,
	text:     [VIEW_TEXT_BYTES_MAX]u8,
	text_len: u32,
}

// View is the play-time form: borrowed, exactly sized, retaining nothing. This
// is what generated code produces and what view_play consumes.
View :: struct {
	nodes: []View_Node,
	text:  string,
}

// view_of borrows the populated prefix of an authoring buffer. The result is
// valid only while doc is, which is the immediate-mode contract everywhere else
// in ingot: the caller owns the storage and passes it in each frame.
view_of :: proc(doc: ^View_Doc) -> View {
	assert(doc != nil, "view_of: nil doc")
	assert(doc.count >= 0 && doc.count <= VIEW_NODES_MAX, "view_of: count out of range")
	assert(doc.text_len <= VIEW_TEXT_BYTES_MAX, "view_of: text_len out of range")
	return View{nodes = doc.nodes[:doc.count], text = string(doc.text[:doc.text_len])}
}

// view_kind_is_container reports whether a kind opens a layout frame. Play,
// validate and the generator all need this and must agree, so it is one
// procedure rather than three switch arms that could drift apart.
view_kind_is_container :: proc(kind: View_Kind) -> bool {
	switch kind {
	case .Row, .Column, .Panel, .Flex_Row, .Flex_Column:
		return true
	case .Button,
	     .Icon_Button,
	     .Back_Button,
	     .Checkbox,
	     .Radio,
	     .Slider,
	     .Text_Input,
	     .Collapsible_Header,
	     .Label,
	     .Section_Header,
	     .Status_Pill,
	     .Kv_Row,
	     .Progress_Bar,
	     .Spinner,
	     .Separator,
	     .Spacer:
		return false
	}
	return false
}

// view_kind_is_flex reports whether a container sizes its children from their
// declared tracks rather than from the cursor.
view_kind_is_flex :: proc(kind: View_Kind) -> bool {
	return kind == .Flex_Row || kind == .Flex_Column
}

// view_kind_is_interactive reports whether a kind registers focus. Validation
// bounds the count of these against ui.MAX_FOCUSABLES, so a malformed document
// cannot overrun the focus ring.
view_kind_is_interactive :: proc(kind: View_Kind) -> bool {
	switch kind {
	case .Button,
	     .Icon_Button,
	     .Back_Button,
	     .Checkbox,
	     .Radio,
	     .Slider,
	     .Text_Input,
	     .Collapsible_Header:
		return true
	case .Row,
	     .Column,
	     .Panel,
	     .Flex_Row,
	     .Flex_Column,
	     .Label,
	     .Section_Header,
	     .Status_Pill,
	     .Kv_Row,
	     .Progress_Bar,
	     .Spinner,
	     .Separator,
	     .Spacer:
		return false
	}
	return false
}

// view_kind_carves_slot reports whether a kind consumes one slot from its
// parent's layout run.
//
// This matters only inside a flex container, where ui asserts that every
// declared track is consumed. Three kinds do not take one:
//
//   - Separator carves through slot_px, which is not the flex-aware path.
//   - Spacer only advances the cursor and carves nothing at all.
//   - Panel opens through push_column, which swallows the parent's entire
//     remaining space rather than taking a slot from it. That also means a
//     Panel is a poor flex child, but rejecting it outright would be a
//     surprising restriction; declaring no track for it is enough to keep the
//     run consistent.
//
// Every other kind reaches slot_next_px, which resolves a flex track.
//
// The rule is a function of kind alone, never of a node's content. An earlier
// version skipped emitting a label with empty text, which made a node's layout
// footprint depend on its data and left a flex run one track short.
view_kind_carves_slot :: proc(kind: View_Kind) -> bool {
	switch kind {
	case .Separator, .Spacer, .Panel:
		return false
	case .Row,
	     .Column,
	     .Flex_Row,
	     .Flex_Column,
	     .Button,
	     .Icon_Button,
	     .Back_Button,
	     .Checkbox,
	     .Radio,
	     .Slider,
	     .Text_Input,
	     .Collapsible_Header,
	     .Label,
	     .Section_Header,
	     .Status_Pill,
	     .Kv_Row,
	     .Progress_Bar,
	     .Spinner:
		return true
	}
	return true
}

// view_kind_needs_label reports whether a kind requires a non-empty label.
// ui.slider and ui.text_input use it as the accessible name, and
// ui.section_header and ui.status_pill assert on empty text outright. This is
// the rule that stops a document reaching an assertion inside ui.
view_kind_needs_label :: proc(kind: View_Kind) -> bool {
	switch kind {
	case .Slider, .Text_Input, .Section_Header, .Status_Pill:
		return true
	case .Row,
	     .Column,
	     .Panel,
	     .Flex_Row,
	     .Flex_Column,
	     .Button,
	     .Icon_Button,
	     .Back_Button,
	     .Checkbox,
	     .Radio,
	     .Collapsible_Header,
	     .Label,
	     .Kv_Row,
	     .Progress_Bar,
	     .Spinner,
	     .Separator,
	     .Spacer:
		return false
	}
	return false
}

// view_kind_binding reports the binding kind a node of this kind requires, or
// .None when it takes no binding. One table, consulted by both validate and
// play, so a document can never validate against a rule play does not apply.
view_kind_binding :: proc(kind: View_Kind) -> Binding_Kind {
	#partial switch kind {
	case .Checkbox, .Collapsible_Header:
		return .Boolean
	case .Radio:
		return .Integer
	case .Slider, .Progress_Bar:
		return .Number
	case .Text_Input:
		return .Text
	}
	return .None
}
