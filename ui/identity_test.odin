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
identity_reset_clears_open_scope_storage :: proc(t: ^testing.T) {
	ids: Id_Context
	id_context_push(&ids, "root")
	id_context_push(&ids, "child")
	id_context_reset(&ids)
	testing.expect_value(t, ids.depth, 0)
	for id in ids.stack do testing.expect_value(t, id, WIDGET_ID_NONE)
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
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 100, 100})
	scope_begin(&u, "list")
	a := id(&u, u64(10))
	b := id(&u, u64(20))
	focus(&u, a)
	focus_opt_set(focus(&u, b))
	scope_end(&u)
	end(&u)

	begin(&u, &frame, {0, 0, 100, 100})
	scope_begin(&u, "list")
	focus(&u, id(&u, u64(30)))
	focus(&u, id(&u, u64(20)))
	focus(&u, id(&u, u64(10)))
	scope_end(&u)
	end(&u)
	testing.expect_value(t, u.stable_focus.active, focus_widget_id(b))
}

@(test)
semantic_identity_prefers_widget_id :: proc(t: ^testing.T) {
	widget := widget_id("save")
	first := sem_node_id(.Button, {}, "legacy-a", 0, widget)
	second := sem_node_id(.Button, {}, "legacy-b", 9, widget)
	testing.expect_value(t, first, second)
	testing.expect(t, first > SEM_ID_ROOT)
}
