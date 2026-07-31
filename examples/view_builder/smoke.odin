#+build !js
// View builder smoke mode (-define:INGOT_SMOKE=true): a self-driving harness.
//
// It exists because the builder's failure mode is an abort, not a wrong pixel.
// Every mutation the palette and inspector expose can produce a document that
// view_play then walks, and a document the editor can reach but the renderer
// cannot survive is a crash in a live window rather than a failing assertion in
// a test. So this drives the real handlers - add_node, delete_node, the token
// cycles, save and load - through the same code paths a user's clicks reach,
// then exits 0.
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
	// caught rather than waiting for someone to click it.
	smoke_kinds :: proc() -> int {
		return len(view.View_Kind)
	}

	// The steps: add every kind, cycle every token on the selection, delete
	// back down, then round-trip through the file format.
	smoke_steps :: proc() -> int {
		return smoke_kinds() + 8 + 6 + 2
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
			add_node(data, view.View_Kind(step))
			return
		}
		smoke_edit_step(data, step - smoke_kinds())
	}

	smoke_edit_step :: proc(data: ^State, step: int) {
		assert(data != nil, "smoke_edit_step: nil state")
		if step < 8 {
			smoke_cycle_tokens(data)
			return
		}
		if step < 14 {
			delete_node(data)
			return
		}
		if step == 14 {
			save(data)
			return
		}
		load(data)
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
		data.selected = (data.selected + 1) % data.doc.count
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
