// Leaf emitters.
//
// Goal: one pure procedure per node kind, so view_play stays a walk and a
// switch, and so the mapping from a node to a ui call is readable one line at a
// time.
//
// Method: each emit_* takes the primitives it needs and nothing else - no
// document, no walk state, no index. A leaf therefore cannot depend on where in
// the tree it was reached, which is what lets the generator and the interpreter
// share them without either knowing about the other.
package view

import "ingot:ui"

// emit_leaf resolves identity and binding once, then dispatches. It is the only
// place a node's index becomes a Widget_Id, so the identity rule - key path,
// never label - is enforced in one place rather than per kind.
@(private = "package")
emit_leaf :: proc(u: ^ui.Ui, view: View, node: View_Node, index: i32, bindings: ^Bindings) {
	assert(u != nil, "emit_leaf: nil Ui")
	label := text_slice(view, node.label_offset, node.label_length)
	value := text_slice(view, node.value_offset, node.value_length)
	if !view_kind_is_interactive(node.kind) {
		emit_presentational(u, node, label, value, bindings)
		return
	}
	key := text_slice(view, node.key_offset, node.key_length)
	ensure(key != "", "emit_leaf: interactive node without a key")
	widget := ui.id(u, key)
	fired := emit_interactive(u, node, widget, label, value, bindings)
	if fired && bindings != nil && bindings.events != nil {
		sink_push(
			bindings.events,
			Event{node = index, key_offset = node.key_offset, key_length = node.key_length},
		)
	}
}

// emit_presentational must call exactly one widget per node, unconditionally.
// An earlier version skipped a label with empty text, which made a node's
// layout footprint depend on its content and left a flex run one track short of
// what child_tracks had declared. Kinds that cannot tolerate empty text are
// rejected by view_validate instead of being skipped here.
@(private = "file")
emit_presentational :: proc(
	u: ^ui.Ui,
	node: View_Node,
	label: string,
	value: string,
	bindings: ^Bindings,
) {
	assert(u != nil, "emit_presentational: nil Ui")
	#partial switch node.kind {
	case .Label:
		ui.label(u, label, node.text_role, node.ink)
	case .Section_Header:
		ensure(label != "", "emit_presentational: ui.section_header requires text")
		ui.section_header(u, label)
	case .Status_Pill:
		ensure(label != "", "emit_presentational: ui.status_pill requires text")
		ui.status_pill(u, label, node.ink, node.size_main)
	case .Kv_Row:
		ui.kv_row(u, label, value, node.ink, ui.Ink.Primary, node.size_main)
	case .Progress_Bar:
		ui.progress_bar(u, binding_number(node, bindings)^, node.ink, progress_height(node))
	case .Spinner:
		ui.spinner(u, spinner_diameter(node))
	case .Separator:
		ui.separator(u)
	case .Spacer:
		ui.space(u, node.gap)
	}
}

// emit_interactive returns whether the control reported a change this frame.
// The bindings pointer is threaded down rather than resolved here because each
// kind needs a different member of the union, and resolving it per kind keeps
// the ensure next to the use.
@(private = "file")
emit_interactive :: proc(
	u: ^ui.Ui,
	node: View_Node,
	widget: ui.Widget_Id,
	label: string,
	value: string,
	bindings: ^Bindings,
) -> bool {
	assert(u != nil, "emit_interactive: nil Ui")
	enabled := .Disabled not_in node.flags
	#partial switch node.kind {
	case .Button:
		return ui.button(u, widget, label, node.style, enabled)
	case .Icon_Button:
		return ui.icon_btn(u, widget, label, enabled)
	case .Back_Button:
		return ui.back_btn(u, widget, label)
	case .Checkbox:
		return ui.checkbox(u, widget, label, binding_boolean(node, bindings))
	case .Collapsible_Header:
		open := binding_boolean(node, bindings)
		return ui.collapsible_header(u, widget, label, open)
	case .Radio:
		return ui.radio(u, widget, label, binding_integer(node, bindings), node.integer)
	case .Slider:
		return emit_slider(u, node, widget, label, bindings)
	case .Text_Input:
		return emit_text_input(u, node, widget, label, value, bindings)
	}
	return false
}

// emit_text_input goes through the options form because ui.text_input asserts
// on an empty accessible name, and the short form has no way to supply one. The
// node's label is the name and its value is the placeholder: a placeholder is
// not an accessible name, and treating it as one is the usual way a form ends
// up unusable with a screen reader.
@(private = "file")
emit_text_input :: proc(
	u: ^ui.Ui,
	node: View_Node,
	widget: ui.Widget_Id,
	label: string,
	value: string,
	bindings: ^Bindings,
) -> bool {
	assert(u != nil, "emit_text_input: nil Ui")
	ensure(label != "", "emit_text_input: ui.text_input requires an accessible label")
	options := ui.Text_Input_Options {
		height = node.size_main,
		masked = .Masked in node.flags,
		semantics = ui.Text_Input_Semantics{name = label},
	}
	return ui.text_input(u, widget, binding_text(node, bindings), value, options)
}

// emit_slider is separate because its range needs repairing before ui sees it.
// A zero-width range is a legal thing for a half-edited document to contain and
// would make ui.slider divide by zero; that is a document problem to absorb
// here, not an assertion to fire inside a widget.
@(private = "file")
emit_slider :: proc(
	u: ^ui.Ui,
	node: View_Node,
	widget: ui.Widget_Id,
	label: string,
	bindings: ^Bindings,
) -> bool {
	assert(u != nil, "emit_slider: nil Ui")
	lo, hi := node.number_lo, node.number_hi
	if !(hi > lo) do hi = lo + 1
	step := node.number_step if node.number_step > 0 else 0
	ensure(label != "", "emit_slider: ui.slider requires an accessible label")
	return ui.slider(
		u,
		widget,
		binding_number(node, bindings),
		lo,
		hi,
		step,
		node.size_main,
		label,
	)
}

// The binding_* accessors are the tag check. Each ensures the slot exists and
// holds the kind this node needs before the union is read, because both the
// index and the expected kind came from document data.
@(private = "file")
binding_slot :: proc(node: View_Node, bindings: ^Bindings, want: Binding_Kind) -> ^Binding {
	ensure(bindings != nil, "binding_slot: interactive node with no bindings table")
	ensure(node.binding >= 0, "binding_slot: node has no binding")
	ensure(int(node.binding) < len(bindings.slots), "binding_slot: binding index out of range")
	slot := &bindings.slots[node.binding]
	ensure(slot.kind == want, "binding_slot: binding kind does not match the node")
	return slot
}

@(private = "file")
binding_boolean :: proc(node: View_Node, bindings: ^Bindings) -> ^bool {
	slot := binding_slot(node, bindings, .Boolean)
	ensure(slot.as.boolean != nil, "binding_boolean: nil target")
	return slot.as.boolean
}

@(private = "file")
binding_number :: proc(node: View_Node, bindings: ^Bindings) -> ^f32 {
	slot := binding_slot(node, bindings, .Number)
	ensure(slot.as.number != nil, "binding_number: nil target")
	return slot.as.number
}

@(private = "file")
binding_integer :: proc(node: View_Node, bindings: ^Bindings) -> ^i32 {
	slot := binding_slot(node, bindings, .Integer)
	ensure(slot.as.integer != nil, "binding_integer: nil target")
	return slot.as.integer
}

@(private = "file")
binding_text :: proc(node: View_Node, bindings: ^Bindings) -> ^ui.Input_Box {
	slot := binding_slot(node, bindings, .Text)
	ensure(slot.as.text != nil, "binding_text: nil target")
	return slot.as.text
}

// Presentational size defaults. A zero in the document means "use the widget's
// own default"; these two widgets assert on a non-positive size, so the
// substitution has to happen before the call rather than inside it.
@(private = "file")
progress_height :: proc(node: View_Node) -> i32 {
	return node.size_main if node.size_main > 0 else 8
}

@(private = "file")
spinner_diameter :: proc(node: View_Node) -> i32 {
	return node.size_main if node.size_main > 0 else 24
}
