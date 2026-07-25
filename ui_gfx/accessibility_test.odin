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
