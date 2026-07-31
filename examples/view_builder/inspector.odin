// The inspector: a node tree plus a config panel for the selected element.
//
// The panel shows only what applies to the selected kind - a slider gets a
// range section, a button gets a style cycle, a flex child gets track controls.
// Everything edits tokens or document fields, never literals: a document is
// only portable across themes and DPIs because it cannot express a raw colour
// or pixel gap in the first place.
//
// Text editing goes through three Input_Boxes owned by State. They are loaded
// when the selection changes (select_node -> inspector_load) and written back
// every frame the text differs from the document. Writeback is guarded by
// box_owner - the node the boxes were loaded from - so changing selection while
// a field is focused can never write one node's text into another.
package main

import "core:fmt"
import "ingot:ui"
import "ingot:view"

draw_inspector :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "draw_inspector: invalid arguments")
	ui.scope_begin(form, "inspector")
	defer ui.scope_end(form)
	// A column, not a panel: panel_begin swallows the parent's remaining space
	// instead of taking a flex track, so a panel cannot sit in the flex row.
	ui.column_begin(form, 0, .XS)
	defer ui.column_end(form)
	ui.padding(form, .SM)
	ui.label(form, "Structure", ui.Text_Role.Label, ui.Ink.Heading)
	draw_node_list(form, data)
	ui.space(form, .SM)
	ui.separator(form)
	ui.space(form, .SM)
	draw_config_panel(form, data)
}

// draw_node_list shows the tree in document order, indented by depth. The walk
// is the package's own iterator, so the list can never disagree with what the
// canvas renders.
draw_node_list :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "draw_node_list: invalid arguments")
	source := view.view_of(&data.doc)
	walk := view.walk_begin(source)
	for {
		step, more := view.walk_next(&walk)
		if !more do break
		if step.event != .Enter do continue
		node := data.doc.nodes[step.node]
		label := view.view_text(source, node.label_offset, node.label_length)
		key := view.view_text(source, node.key_offset, node.key_length)
		text := fmt.tprintf(
			"%*s%v%s",
			int(step.depth) * 2,
			"",
			node.kind,
			label != "" ? fmt.tprintf(" %q", label) : fmt.tprintf(" [%s]", key),
		)
		style := ui.Btn_Style.Primary if step.node == data.selected else ui.Btn_Style.Ghost
		// Keys are offset by one: ui reserves the zero id, and the root node is
		// index 0. Without the offset the root row aborts the frame.
		if ui.button(form, u64(step.node) + 1, text, style) do select_node(data, step.node)
	}
}

// --- config panel ------------------------------------------------------------

draw_config_panel :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "draw_config_panel: invalid arguments")
	if data.doc.count == 0 || data.selected < 0 || data.selected >= data.doc.count {
		ui.label(form, "Click an element on the canvas", ui.Text_Role.Note, ui.Ink.Muted)
		ui.label(form, "to configure it here.", ui.Text_Role.Note, ui.Ink.Muted)
		return
	}
	node := &data.doc.nodes[data.selected]
	kind := node.kind
	ui.label(
		form,
		fmt.tprintf("%v  ·  node %d", kind, data.selected),
		ui.Text_Role.Label,
		ui.Ink.Heading,
	)
	ui.space(form, .XS)

	config_text_fields(form, data, kind)
	config_behaviour(form, data, node, kind)
	config_range(form, data, node, kind)
	config_appearance(form, data, node, kind)
	config_layout(form, data, node, kind)
	config_actions(form, data)
}

// inspector_load fills the text boxes from the current selection and records
// the owner. Called from select_node and at startup - never per frame, or
// typing would be overwritten by the document every frame.
inspector_load :: proc(data: ^State) {
	assert(data != nil, "inspector_load: nil state")
	data.box_owner = data.selected
	if data.selected < 0 || data.selected >= data.doc.count {
		ui.input_box_set_text(&data.key_box, "")
		ui.input_box_set_text(&data.label_box, "")
		ui.input_box_set_text(&data.value_box, "")
		return
	}
	source := view.view_of(&data.doc)
	node := data.doc.nodes[data.selected]
	ui.input_box_set_text(&data.key_box, view.view_text(source, node.key_offset, node.key_length))
	ui.input_box_set_text(
		&data.label_box,
		view.view_text(source, node.label_offset, node.label_length),
	)
	ui.input_box_set_text(
		&data.value_box,
		view.view_text(source, node.value_offset, node.value_length),
	)
}

// config_text_fields draws the applicable fields and writes changes back into
// the document. Change detection is comparison, not the widget's return value:
// ui.text_input's bool means submitted (Enter), and an editor wants the canvas
// updating on every keystroke.
config_text_fields :: proc(form: ^ui.Ui, data: ^State, kind: view.View_Kind) {
	assert(form != nil && data != nil, "config_text_fields: invalid arguments")
	if data.box_owner != data.selected do inspector_load(data)

	if view.view_kind_is_interactive(kind) {
		ui.label(form, "Key (identity)", ui.Text_Role.Note, ui.Ink.Secondary)
		_ = ui.text_input(form, "cfg-key", &data.key_box, "stable key", 26)
	}
	if kind_has_label(kind) {
		ui.label(form, "Label", ui.Text_Role.Note, ui.Ink.Secondary)
		_ = ui.text_input(form, "cfg-label", &data.label_box, "display text", 26)
	}
	if kind == .Kv_Row || kind == .Text_Input {
		name := kind == .Text_Input ? "Placeholder" : "Value"
		ui.label(form, name, ui.Text_Role.Note, ui.Ink.Secondary)
		_ = ui.text_input(form, "cfg-value", &data.value_box, "secondary text", 26)
	}
	inspector_writeback(data, kind)
}

// inspector_writeback pushes edited text into the document. Guarded by owner
// so a stale box never writes across a selection change, and refusing a key
// that collides with a sibling keeps the document valid mid-edit rather than
// only complaining at save.
inspector_writeback :: proc(data: ^State, kind: view.View_Kind) {
	assert(data != nil, "inspector_writeback: nil state")
	if data.box_owner != data.selected do return
	node := data.selected
	if node < 0 || node >= data.doc.count do return
	source := view.view_of(&data.doc)
	entry := data.doc.nodes[node]

	if view.view_kind_is_interactive(kind) {
		typed := ui.input_box_text(&data.key_box)
		current := view.view_text(source, entry.key_offset, entry.key_length)
		if typed != current {
			if typed == "" {
				set_status(data, "an interactive element needs a key", true)
			} else if key_collides(&data.doc, node, typed) {
				set_status(data, fmt.tprintf("key %q already used by a sibling", typed), true)
			} else if view.doc_set_key(&data.doc, node, typed) {
				set_status(data, "")
			}
		}
	}
	if kind_has_label(kind) {
		typed := ui.input_box_text(&data.label_box)
		current := view.view_text(source, entry.label_offset, entry.label_length)
		if typed != current {
			if typed == "" && view.view_kind_needs_label(kind) {
				set_status(data, fmt.tprintf("%v requires a label", kind), true)
			} else {
				_ = view.doc_set_label(&data.doc, node, typed)
			}
		}
	}
	if kind == .Kv_Row || kind == .Text_Input {
		typed := ui.input_box_text(&data.value_box)
		current := view.view_text(source, entry.value_offset, entry.value_length)
		if typed != current do _ = view.doc_set_value(&data.doc, node, typed)
	}
}

// key_collides reports whether another sibling already uses this key. Two
// siblings with one key derive the same Widget_Id and share interaction state,
// which is why validation rejects it - refusing it here keeps the canvas
// rendering while the user types.
key_collides :: proc(doc: ^view.View_Doc, node: i32, key: string) -> bool {
	assert(doc != nil, "key_collides: nil doc")
	assert(node >= 0 && node < doc.count, "key_collides: node out of range")
	source := view.view_of(doc)
	parent := doc.nodes[node].parent
	cursor := parent == view.VIEW_NODE_NONE ? i32(0) : doc.nodes[parent].first_child
	steps := 0
	for cursor != view.VIEW_NODE_NONE {
		steps += 1
		assert(steps <= int(doc.count), "key_collides: unbounded chain")
		if cursor != node {
			entry := doc.nodes[cursor]
			if view.view_text(source, entry.key_offset, entry.key_length) == key do return true
		}
		cursor = doc.nodes[cursor].next_sibling
	}
	return false
}

kind_has_label :: proc(kind: view.View_Kind) -> bool {
	if view.view_kind_is_container(kind) do return false
	#partial switch kind {
	case .Separator, .Spacer, .Spinner, .Progress_Bar:
		return false
	}
	return true
}

config_behaviour :: proc(form: ^ui.Ui, data: ^State, node: ^view.View_Node, kind: view.View_Kind) {
	assert(form != nil && data != nil && node != nil, "config_behaviour: invalid arguments")
	if !view.view_kind_is_interactive(kind) do return
	ui.space(form, .XS)
	ui.label(form, "Behaviour", ui.Text_Role.Note, ui.Ink.Secondary)
	disabled := .Disabled in node.flags
	if ui.checkbox(form, "cfg-disabled", "Disabled", &disabled) {
		if disabled do node.flags += {.Disabled}
		else do node.flags -= {.Disabled}
	}
	if kind == .Text_Input {
		masked := .Masked in node.flags
		if ui.checkbox(form, "cfg-masked", "Masked (password)", &masked) {
			if masked do node.flags += {.Masked}
			else do node.flags -= {.Masked}
		}
	}
	if kind == .Radio {
		stepper_i32(form, data, "Radio value", &node.integer, 1, 0, 64)
	}
}

config_range :: proc(form: ^ui.Ui, data: ^State, node: ^view.View_Node, kind: view.View_Kind) {
	assert(form != nil && data != nil && node != nil, "config_range: invalid arguments")
	if kind != .Slider do return
	ui.space(form, .XS)
	ui.label(form, "Range", ui.Text_Role.Note, ui.Ink.Secondary)
	stepper_f32(form, data, "Low", &node.number_lo, 1)
	stepper_f32(form, data, "High", &node.number_hi, 1)
	stepper_f32(form, data, "Step", &node.number_step, 0.05)
}

config_appearance :: proc(form: ^ui.Ui, data: ^State, node: ^view.View_Node, kind: view.View_Kind) {
	assert(form != nil && data != nil && node != nil, "config_appearance: invalid arguments")
	ui.space(form, .XS)
	ui.label(form, "Appearance", ui.Text_Role.Note, ui.Ink.Secondary)
	if cycle_button(form, "ink", "Ink", fmt.tprintf("%v", node.ink)) {
		node.ink = cycle(node.ink)
	}
	if kind == .Label {
		if cycle_button(form, "role", "Text role", fmt.tprintf("%v", node.text_role)) {
			node.text_role = cycle(node.text_role)
		}
	}
	if kind == .Button {
		if cycle_button(form, "style", "Button style", fmt.tprintf("%v", node.style)) {
			node.style = cycle(node.style)
		}
	}
}

config_layout :: proc(form: ^ui.Ui, data: ^State, node: ^view.View_Node, kind: view.View_Kind) {
	assert(form != nil && data != nil && node != nil, "config_layout: invalid arguments")
	ui.space(form, .XS)
	ui.label(form, "Layout", ui.Text_Role.Note, ui.Ink.Secondary)
	if view.view_kind_is_container(kind) {
		if cycle_button(form, "gap", "Gap", fmt.tprintf("%v", node.gap)) {
			node.gap = cycle(node.gap)
		}
		if kind == .Panel {
			if cycle_button(form, "padding", "Padding", fmt.tprintf("%v", node.padding)) {
				node.padding = cycle(node.padding)
			}
		}
		if cycle_button(form, "align", "Align", fmt.tprintf("%v", node.align)) {
			node.align = cycle(node.align)
		}
		if view.view_kind_is_flex(kind) {
			if cycle_button(form, "justify", "Justify", fmt.tprintf("%v", node.justify)) {
				node.justify = cycle(node.justify)
			}
		}
	}
	if size_name, sized := size_label(kind); sized {
		stepper_i32(form, data, size_name, &node.size_main, 4, 0, 4096)
	}
	// Track controls only make sense when the parent distributes tracks.
	parent := node.parent
	if parent != view.VIEW_NODE_NONE && view.view_kind_is_flex(data.doc.nodes[parent].kind) {
		if cycle_button(form, "track", "Track", fmt.tprintf("%v", node.track.kind)) {
			node.track.kind = cycle(node.track.kind)
		}
		#partial switch node.track.kind {
		case .Fixed:
			stepper_i32(form, data, "Basis", &node.track.basis, 8, 0, 4096)
		case .Grow:
			stepper_i32(form, data, "Weight", &node.track.weight, 1, 0, 64)
		case .Percent:
			stepper_f32(form, data, "Percent", &node.track.percent, 0.05)
		}
	}
}

// size_label names the size stepper by what the number means for this kind, so
// the panel says "Diameter" for a spinner rather than a generic "Size".
size_label :: proc(kind: view.View_Kind) -> (name: string, sized: bool) {
	#partial switch kind {
	case .Row, .Flex_Row:
		return "Height", true
	case .Column, .Flex_Column:
		return "Width", true
	case .Spinner:
		return "Diameter", true
	case .Progress_Bar:
		return "Height", true
	case .Slider:
		return "Width", true
	case .Text_Input:
		return "Height", true
	case .Status_Pill, .Kv_Row:
		return "Font size", true
	}
	return "", false
}

config_actions :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "config_actions: invalid arguments")
	if data.selected <= 0 do return
	ui.space(form, .SM)
	ui.flex_row_begin(form, 26, {ui.grow(), ui.fixed(40), ui.fixed(40)}, gap = .XS)
	if ui.button(form, "cfg-delete", "Delete", ui.Btn_Style.Danger) do delete_node(data)
	if ui.button(form, "cfg-up", "↑") do move_node(data, false)
	if ui.button(form, "cfg-down", "↓") do move_node(data, true)
	ui.flex_row_end(form)
}

// --- small controls ----------------------------------------------------------

cycle_button :: proc(form: ^ui.Ui, key: string, name: string, value: string) -> bool {
	assert(form != nil, "cycle_button: nil form")
	return ui.button(form, key, fmt.tprintf("%s: %s", name, value), ui.Btn_Style.Ghost)
}

// cycle advances an enum by one, wrapping. Generic so each editor above is one
// line, and it stays inside the enum by construction.
cycle :: proc(value: $T) -> T {
	count := len(T)
	assert(count > 0, "cycle: empty enum")
	return T((int(value) + 1) % count)
}

stepper_i32 :: proc(
	form: ^ui.Ui,
	data: ^State,
	name: string,
	value: ^i32,
	step: i32,
	lo: i32,
	hi: i32,
) {
	assert(form != nil && data != nil && value != nil, "stepper_i32: invalid arguments")
	assert(step > 0 && lo <= hi, "stepper_i32: invalid step or range")
	ui.scope_begin(form, name)
	defer ui.scope_end(form)
	ui.flex_row_begin(form, 24, {ui.grow(), ui.fixed(28), ui.fixed(28)}, gap = .XS)
	ui.label(form, fmt.tprintf("%s: %d", name, value^), ui.Text_Role.Note, ui.Ink.Primary)
	if ui.button(form, "minus", "−") do value^ = max(value^ - step, lo)
	if ui.button(form, "plus", "+") do value^ = min(value^ + step, hi)
	ui.flex_row_end(form)
}

stepper_f32 :: proc(form: ^ui.Ui, data: ^State, name: string, value: ^f32, step: f32) {
	assert(form != nil && data != nil && value != nil, "stepper_f32: invalid arguments")
	assert(step > 0, "stepper_f32: non-positive step")
	ui.scope_begin(form, name)
	defer ui.scope_end(form)
	ui.flex_row_begin(form, 24, {ui.grow(), ui.fixed(28), ui.fixed(28)}, gap = .XS)
	ui.label(form, fmt.tprintf("%s: %.2f", name, value^), ui.Text_Role.Note, ui.Ink.Primary)
	if ui.button(form, "minus", "−") do value^ -= step
	if ui.button(form, "plus", "+") do value^ += step
	ui.flex_row_end(form)
}
