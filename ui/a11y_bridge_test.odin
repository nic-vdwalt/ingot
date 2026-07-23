#+build !js
package ui

import "core:testing"
import ak "ingot:accesskit"

@(test)
a11y_role_mapping :: proc(t: ^testing.T) {
	// Every interactive semantic role must map to a real AccessKit role —
	// Unknown would make the widget invisible to assistive tech.
	testing.expect_value(t, a11y_role(.Button), ak.Role.Button)
	testing.expect_value(t, a11y_role(.Checkbox), ak.Role.Check_Box)
	testing.expect_value(t, a11y_role(.Radio), ak.Role.Radio_Button)
	testing.expect_value(t, a11y_role(.Slider), ak.Role.Slider)
	testing.expect_value(t, a11y_role(.Text_Input), ak.Role.Text_Input)
	testing.expect_value(t, a11y_role(.Dropdown), ak.Role.Combo_Box)
	testing.expect_value(t, a11y_role(.Menu_Item), ak.Role.Menu_Item)
	testing.expect_value(t, a11y_role(.Label), ak.Role.Label)
	testing.expect_value(t, a11y_role(.Pane), ak.Role.Pane)
	testing.expect_value(t, a11y_role(.Modal), ak.Role.Dialog)
	testing.expect_value(t, a11y_role(.None), ak.Role.Unknown)
}
