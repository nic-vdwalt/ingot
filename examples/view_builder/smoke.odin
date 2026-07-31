#+build !js
// View builder smoke mode (-define:INGOT_SMOKE=true): a self-driving harness.
//
// It exists because the builder's failure mode is an abort, not a wrong pixel.
// Every mutation the palette, canvas, and inspector expose can produce a
// document that view_play then walks, and a document the editor can reach but
// the renderer cannot survive is a crash in a live window rather than a
// failing assertion in a test. So this drives the real handlers - add into an
// explicit container, mode toggling, text edits and compaction, move up/down,
// token cycles, save/load, and a trace hit-test of the played canvas - through
// the same code paths a user's clicks reach, then exits 0.
//
// Drag itself needs synthetic mouse input, which this example does not have.
// The drop *logic* is what matters, and it is drag-independent: drop resolves
// through trace_container_at + add_node_into, both driven here.
//
// Native-only: it uses os.exit.
package main

import "core:fmt"
import "core:os"
import "ingot:ui"
import "ingot:view"

SMOKE :: #config(INGOT_SMOKE, false)

// Anchor the imports for non-smoke builds, matching examples/gallery.
_ :: fmt
_ :: os
_ :: ui
_ :: view

when SMOKE {
	SMOKE_STEP_FRAMES :: 2

	smoke_frame: int
	smoke_step_index: int

	// Every kind, so a palette entry that produces an unrenderable node is
	// caught rather than waiting for someone to drag it.
	smoke_kinds :: proc() -> int {
		return len(view.View_Kind)
	}

	SMOKE_EDIT_STEPS :: 24

	smoke_steps :: proc() -> int {
		return smoke_kinds() + SMOKE_EDIT_STEPS
	}

	smoke_step :: proc(data: ^State) {
		assert(data != nil, "smoke_step: nil state")
		smoke_frame += 1
		if smoke_frame % SMOKE_STEP_FRAMES != 0 do return
		step := smoke_step_index
		smoke_step_index += 1
		if step >= smoke_steps() {
			smoke_finish(data)
			return
		}
		if step < smoke_kinds() {
			// Through the explicit-parent path the drop handler uses, into the
			// root, so a drop into the root container is representative.
			add_node_into(data, drop_root(data), view.View_Kind(step))
			return
		}
		smoke_edit_step(data, step - smoke_kinds())
	}

	drop_root :: proc(data: ^State) -> i32 {
		assert(data != nil, "drop_root: nil state")
		if data.doc.count == 0 do return view.VIEW_NODE_NONE
		return 0
	}

	smoke_edit_step :: proc(data: ^State, step: int) {
		assert(data != nil, "smoke_edit_step: nil state")
		switch {
		case step < 4:
			// The trace hit-test: the selected node's centre must resolve back
			// to a node. This is the geometry every canvas click depends on,
			// checked against the live window rather than only headlessly.
			smoke_hit_test(data)
			select_node(data, (data.selected + 3) % max(data.doc.count, 1))
		case step < 6:
			toggle_mode(data)
		case step < 10:
			smoke_text_edit(data, step)
		case step == 10:
			view.doc_text_compact(&data.doc)
		case step < 15:
			smoke_cycle_tokens(data)
		case step == 15:
			move_node(data, true)
		case step == 16:
			move_node(data, false)
		case step < 21:
			delete_node(data)
		case step == 21:
			save(data)
		case step == 22:
			load(data)
		case:
			select_node(data, 0)
		}
	}

	smoke_hit_test :: proc(data: ^State) {
		assert(data != nil, "smoke_hit_test: nil state")
		if data.mode != .Edit do return
		if data.selected < 0 || data.selected >= data.doc.count do return
		rect := view.trace_rect(&data.trace, data.selected)
		// Zero is legal for a node that drew nothing (Spacer); only verify the
		// round trip for nodes that landed on screen.
		if rect.w <= 0 || rect.h <= 0 do return
		centre := ui.Vector2{f32(rect.x) + f32(rect.w) / 2, f32(rect.y) + f32(rect.h) / 2}
		hit := view.trace_node_at(&data.trace, view.view_of(&data.doc), centre)
		if hit == view.VIEW_NODE_NONE {
			fmt.eprintfln("smoke: node %d centre hit nothing", data.selected)
			os.exit(1)
		}
	}

	smoke_text_edit :: proc(data: ^State, step: int) {
		assert(data != nil, "smoke_text_edit: nil state")
		if data.selected <= 0 || data.selected >= data.doc.count do return
		node := data.selected
		ok := view.doc_set_label(&data.doc, node, fmt.tprintf("Edited %d", step))
		if view.view_kind_is_interactive(data.doc.nodes[node].kind) {
			ok &&= view.doc_set_key(&data.doc, node, fmt.tprintf("edited-%d", step))
		}
		if !ok {
			fmt.eprintfln("smoke: text edit failed at step %d", step)
			os.exit(1)
		}
		// The inspector fields must follow the document, as select_node does.
		inspector_load(data)
	}

	// smoke_cycle_tokens advances every token on the selection at once. The
	// point is to reach combinations, not to mimic a user: a token that only
	// renders correctly at its default is the defect being hunted.
	smoke_cycle_tokens :: proc(data: ^State) {
		assert(data != nil, "smoke_cycle_tokens: nil state")
		if data.doc.count == 0 do return
		if data.selected < 0 || data.selected >= data.doc.count do return
		node := &data.doc.nodes[data.selected]
		node.ink = cycle(node.ink)
		node.text_role = cycle(node.text_role)
		node.gap = cycle(node.gap)
		node.padding = cycle(node.padding)
		node.align = cycle(node.align)
		node.justify = cycle(node.justify)
		node.style = cycle(node.style)
		node.track.kind = cycle(node.track.kind)
		// Move the selection so later steps do not keep editing one node.
		select_node(data, (data.selected + 1) % data.doc.count)
	}

	// smoke_finish asserts the end state is coherent before exiting. Reaching
	// the last frame without aborting is most of the value, but a builder that
	// ends holding a document it cannot save has still failed.
	smoke_finish :: proc(data: ^State) {
		assert(data != nil, "smoke_finish: nil state")
		result, ok := view.view_validate(view.view_of(&data.doc))
		if !ok {
			fmt.eprintfln("smoke: editor produced an invalid document: %v", result)
			os.exit(1)
		}
		fmt.printfln("smoke: ok, %d nodes", data.doc.count)
		os.exit(0)
	}
}
