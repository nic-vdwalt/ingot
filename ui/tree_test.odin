#+build !js
package ui

import "core:testing"

@(test)
tree_relationship_helpers_use_visible_preorder :: proc(t: ^testing.T) {
	expanded := true
	items := [4]Tree_Item {
		{id = 1, label = "root", depth = 0, has_children = true, expanded = &expanded},
		{id = 2, label = "child", depth = 1},
		{id = 3, label = "grandchild", depth = 2},
		{id = 4, label = "sibling", depth = 0},
	}
	testing.expect_value(t, tree_selected_index(items[:], 3), 2)
	testing.expect_value(t, tree_selected_index(items[:], 99), -1)
	testing.expect_value(t, tree_parent_index(items[:], 2), 1)
	testing.expect_value(t, tree_parent_index(items[:], 3), -1)
	testing.expect_value(t, tree_first_child_index(items[:], 0), 1)
	testing.expect_value(t, tree_first_child_index(items[:], 1), 2)
	testing.expect_value(t, tree_first_child_index(items[:], 3), -1)
}
