// The inspector: a node list and a token editor for the selection.
//
// Every control here edits a token, never a literal. That is the same rule the
// rest of the repository follows, and it is stricter in a builder than
// anywhere: a document is only portable across themes and DPIs because it
// cannot express a raw colour or a pixel gap in the first place.
package main

import "core:fmt"
import "ingot:ui"
import "ingot:view"

draw_inspector :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "draw_inspector: invalid arguments")
	ui.scope_begin(form, "inspector")
	defer ui.scope_end(form)
	// A column, not a panel: panel_begin opens through push_column, which
	// swallows the parent's remaining space instead of taking a flex track, so
	// a panel cannot be a direct child of the flex row in draw.
	ui.column_begin(form, 0, .XS)
	defer ui.column_end(form)
	ui.padding(form, .SM)
	ui.label(form, "Nodes", ui.Text_Role.Label, ui.Ink.Heading)
	draw_node_list(form, data)
	ui.space(form, .SM)
	ui.separator(form)
	ui.space(form, .SM)
	draw_node_editor(form, data)
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
		if ui.button(form, u64(step.node) + 1, text, style) do data.selected = step.node
	}
}

draw_node_editor :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "draw_node_editor: invalid arguments")
	if data.doc.count == 0 || data.selected < 0 || data.selected >= data.doc.count {
		ui.label(form, "no selection", ui.Text_Role.Note, ui.Ink.Muted)
		return
	}
	node := &data.doc.nodes[data.selected]
	ui.label(form, fmt.tprintf("%v", node.kind), ui.Text_Role.Label, ui.Ink.Heading)
	draw_token_cycles(form, node)
	draw_size_controls(form, node)
}

// draw_token_cycles steps each token through its enum. Cycling rather than
// offering a dropdown keeps the editor to one widget per token and makes every
// legal value reachable, which is what matters for exercising the format.
draw_token_cycles :: proc(form: ^ui.Ui, node: ^view.View_Node) {
	assert(form != nil && node != nil, "draw_token_cycles: invalid arguments")
	if cycle_button(form, "ink", "Ink", fmt.tprintf("%v", node.ink)) {
		node.ink = cycle(node.ink)
	}
	if cycle_button(form, "role", "Text role", fmt.tprintf("%v", node.text_role)) {
		node.text_role = cycle(node.text_role)
	}
	if cycle_button(form, "gap", "Gap", fmt.tprintf("%v", node.gap)) {
		node.gap = cycle(node.gap)
	}
	if cycle_button(form, "padding", "Padding", fmt.tprintf("%v", node.padding)) {
		node.padding = cycle(node.padding)
	}
	if cycle_button(form, "align", "Align", fmt.tprintf("%v", node.align)) {
		node.align = cycle(node.align)
	}
	if cycle_button(form, "justify", "Justify", fmt.tprintf("%v", node.justify)) {
		node.justify = cycle(node.justify)
	}
	if cycle_button(form, "style", "Button style", fmt.tprintf("%v", node.style)) {
		node.style = cycle(node.style)
	}
	if cycle_button(form, "track", "Track", fmt.tprintf("%v", node.track.kind)) {
		node.track.kind = cycle(node.track.kind)
	}
}

draw_size_controls :: proc(form: ^ui.Ui, node: ^view.View_Node) {
	assert(form != nil && node != nil, "draw_size_controls: invalid arguments")
	ui.flex_row_begin(form, 26, {ui.grow(), ui.fixed(34), ui.fixed(34)}, gap = .XS)
	ui.label(form, fmt.tprintf("Size %d", node.size_main), ui.Text_Role.Note, ui.Ink.Secondary)
	if ui.button(form, "size-down", "-", ui.Btn_Style.Secondary) {
		node.size_main = max(node.size_main - 4, 0)
	}
	if ui.button(form, "size-up", "+", ui.Btn_Style.Secondary) {
		node.size_main = min(node.size_main + 4, 4096)
	}
	ui.flex_row_end(form)

	ui.flex_row_begin(form, 26, {ui.grow(), ui.fixed(34), ui.fixed(34)}, gap = .XS)
	ui.label(form, fmt.tprintf("Basis %d", node.track.basis), ui.Text_Role.Note, ui.Ink.Secondary)
	if ui.button(form, "basis-down", "-", ui.Btn_Style.Secondary) {
		node.track.basis = max(node.track.basis - 8, 0)
	}
	if ui.button(form, "basis-up", "+", ui.Btn_Style.Secondary) {
		node.track.basis = min(node.track.basis + 8, 4096)
	}
	ui.flex_row_end(form)
}

cycle_button :: proc(form: ^ui.Ui, key: string, name: string, value: string) -> bool {
	assert(form != nil, "cycle_button: nil form")
	return ui.button(form, key, fmt.tprintf("%s: %s", name, value), ui.Btn_Style.Ghost)
}

// cycle advances an enum by one, wrapping. It is generic so the eight editors
// above are one line each instead of eight near-identical switches, and it
// stays inside the enum by construction rather than by a bounds check.
cycle :: proc(value: $T) -> T {
	count := len(T)
	assert(count > 0, "cycle: empty enum")
	return T((int(value) + 1) % count)
}
