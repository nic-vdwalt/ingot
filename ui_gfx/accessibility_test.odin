#+build !js
package ui_gfx

import "core:testing"
import ak "ingot:accesskit"
import "ingot:ui"

@(test)
adapter_maps_listbox_roles :: proc(t: ^testing.T) {
	when ak.ENABLED {
		testing.expect_value(
			t,
			adapter_a11y_role(&ui.Sem_Node{role = .List_Box}),
			ak.Role.List_Box,
		)
		testing.expect_value(
			t,
			adapter_a11y_role(&ui.Sem_Node{role = .Option}),
			ak.Role.List_Box_Option,
		)
	}
}

@(test)
a11y_snapshot_equal_detects_identity_and_change :: proc(t: ^testing.T) {
	a, b: ui.Sem_Frame
	// Empty frames are equal.
	testing.expect(t, a11y_snapshot_equal(&a, &b), "empty frames must compare equal")
	a.count = 1
	a.nodes[0] = ui.Sem_Node {
		id   = 7,
		role = .Button,
		rect = {1, 2, 30, 20},
	}
	testing.expect(t, !a11y_snapshot_equal(&a, &b), "count change must compare unequal")
	b = a
	testing.expect(t, a11y_snapshot_equal(&a, &b), "identical frames must compare equal")
	// A moved rect (animation) is a real change and must publish.
	b.nodes[0].rect.y = 3
	testing.expect(t, !a11y_snapshot_equal(&a, &b), "rect change must compare unequal")
	b = a
	// Focus lives in node state, so a focus move is caught by node compare.
	b.nodes[0].state += {.Focused}
	testing.expect(t, !a11y_snapshot_equal(&a, &b), "focus change must compare unequal")
}

@(test)
a11y_publish_skips_unchanged_snapshot :: proc(t: ^testing.T) {
	// Drive the gate directly: once a snapshot is published, an identical
	// frame must be recognized as unchanged and a differing one as changed.
	adapter: Adapter
	frame: ui.Sem_Frame
	frame.count = 2
	frame.nodes[0] = ui.Sem_Node {
		id   = 1,
		role = .Button,
		rect = {0, 0, 10, 10},
	}
	frame.nodes[1] = ui.Sem_Node {
		id   = 2,
		role = .Checkbox,
		rect = {0, 12, 10, 10},
	}
	// First publish: gate must not suppress (nothing published yet).
	suppress := adapter.a11y_published && a11y_snapshot_equal(&adapter.a11y_snapshot, &frame)
	testing.expect(t, !suppress, "first frame must publish")
	adapter.a11y_snapshot = frame
	adapter.a11y_published = true
	// Identical second frame: suppressed.
	suppress = adapter.a11y_published && a11y_snapshot_equal(&adapter.a11y_snapshot, &frame)
	testing.expect(t, suppress, "identical frame must be suppressed")
	// Changed node: publishes again.
	frame.nodes[1].state += {.Checked}
	suppress = adapter.a11y_published && a11y_snapshot_equal(&adapter.a11y_snapshot, &frame)
	testing.expect(t, !suppress, "changed frame must publish")
}
