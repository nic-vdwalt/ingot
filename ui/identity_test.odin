#+build !js
package ui

import "core:testing"

@(test)
identity_is_deterministic_and_namespaced :: proc(t: ^testing.T) {
	first := widget_id("account")
	second := widget_id("account")
	numeric := widget_id(u64(42))
	testing.expect_value(t, first, second)
	testing.expect(t, first != numeric)
	testing.expect(t, first != WIDGET_ID_NONE)
}

@(test)
identity_scopes_are_stable_and_composable :: proc(t: ^testing.T) {
	ids: Id_Context
	root := id_context_id(&ids, "save")
	id_context_push(&ids, "settings")
	settings := id_context_id(&ids, "save")
	id_context_push(&ids, u64(42))
	row := id_context_id(&ids, "save")
	id_context_pop(&ids)
	testing.expect_value(t, id_context_id(&ids, "save"), settings)
	id_context_pop(&ids)
	testing.expect_value(t, id_context_id(&ids, "save"), root)
	testing.expect(t, root != settings && settings != row)
}

@(test)
generated_focus_survives_reorder :: proc(t: ^testing.T) {
	u: Ui
	ui_begin(&u, 0, 0, 100, 100)
	ui_id_root(&u, "list")
	a := ui_id(&u, u64(10))
	b := ui_id(&u, u64(20))
	ui_focus(&u, a)
	focus_opt_set(ui_focus(&u, b))
	ui_id_pop(&u)
	ui_end(&u)

	ui_begin(&u, 0, 0, 100, 100)
	ui_id_root(&u, "list")
	ui_focus(&u, ui_id(&u, u64(30)))
	ui_focus(&u, ui_id(&u, u64(20)))
	ui_focus(&u, ui_id(&u, u64(10)))
	ui_id_pop(&u)
	ui_end(&u)
	testing.expect_value(t, u.stable_focus.active, b)
}

@(test)
semantic_identity_prefers_widget_id :: proc(t: ^testing.T) {
	widget := widget_id("save")
	first := sem_node_id(.Button, {}, "legacy-a", 0, widget)
	second := sem_node_id(.Button, {}, "legacy-b", 9, widget)
	testing.expect_value(t, first, second)
	testing.expect(t, first > SEM_ID_ROOT)
}
