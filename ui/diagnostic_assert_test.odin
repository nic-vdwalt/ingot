#+build !js
package ui

import "core:testing"

when ODIN_OS != .Windows || INGOT_UI_EXPECTED_ASSERTS {
	@(test)
	focus_duplicate_reports_registration_indices :: proc(t: ^testing.T) {
		owner: Ui
		owner.open = true
		widget := Widget_Id(101)
		owner.focus_cur[0] = focus_widget_id(widget)
		owner.focus_seq = 1
		testing.expect_assert_message(t, "focus: duplicate stable id 101 (first=0 current=1)")
		_ = focus(&owner, widget)
	}

	@(test)
	prepared_capacity_reports_parent_and_limit :: proc(t: ^testing.T) {
		prepared: Prepared_Ui
		nodes: [1]Prepared_Node
		prepared.open = true
		prepared.external = nodes[:]
		prepared.count = 1
		testing.expect_assert_message(
			t,
			"prepared_add_to: nodes full (parent=0 count=1 capacity=1)",
		)
		_ = prepared_add_to(&prepared, 0, {})
	}
}
