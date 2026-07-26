#+build !js
package ui

import "core:testing"

@(test)
semantics_buffer_behaviour :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	frame.runtime = &runtime
	frame.open = true
	sem_reset(&frame)
	defer sem_reset(&frame)

	// Disabled by default: nodes are not recorded.
	sem_begin_frame(&frame)
	testing.expect(t, semantic_push(&frame, .Button, {0, 0, 10, 10}, "Off") == nil)
	testing.expect_value(t, sem_frame(&frame).count, 0)

	sem_enable(&runtime, true)
	sem_begin_frame(&frame)
	n := semantic_push(&frame, .Button, {5, 6, 100, 24}, "Save")
	testing.expect(t, n != nil)
	testing.expect_value(t, sem_frame(&frame).count, 1)
	testing.expect_value(t, sem_node_label(n), "Save")
	testing.expect_value(t, n.role, Sem_Role.Button)
	testing.expect_value(t, n.rect, Rect_I32{5, 6, 100, 24})

	// Reset clears the buffer each frame.
	sem_begin_frame(&frame)
	testing.expect_value(t, sem_frame(&frame).count, 0)

	// Saturation drops nodes without corrupting the buffer.
	for _ in 0 ..< MAX_SEM_NODES {
		testing.expect(t, semantic_push(&frame, .Label, {0, 0, 1, 1}, "x") != nil)
	}
	testing.expect(t, semantic_push(&frame, .Label, {0, 0, 1, 1}, "overflow") == nil)
	testing.expect_value(t, sem_frame(&frame).count, MAX_SEM_NODES)

	// Slider payload and state flags are carried through.
	sem_begin_frame(&frame)
	s := semantic_push(
		&frame,
		.Slider,
		{0, 0, 80, 16},
		"Volume",
		{.Disabled},
		value = 0.5,
		lo = 0,
		hi = 1,
	)
	testing.expect(t, s != nil)
	testing.expect_value(t, s.value, f32(0.5))
	testing.expect_value(t, s.hi, f32(1))
	testing.expect(t, .Disabled in s.state)

	option := semantic_push(
		&frame,
		.Option,
		{0, 20, 80, 16},
		"Vulkan",
		{.Selected},
		field_id = "backend:vulkan",
		position_in_set = 2,
		size_of_set = 4,
	)
	testing.expect_value(t, option.position_in_set, 2)
	testing.expect_value(t, option.size_of_set, 4)

	// Focused widgets get the Focused flag from their live slot.
	slot := 3
	f := semantic_push(&frame, .Checkbox, {0, 0, 10, 10}, "On", focus = {&slot, 3})
	testing.expect(t, f != nil)
	testing.expect(t, .Focused in f.state)
	nf := semantic_push(&frame, .Checkbox, {0, 0, 10, 10}, "Off", focus = {&slot, 4})
	testing.expect(t, nf != nil)
	testing.expect(t, .Focused not_in nf.state)
	focus, ok := sem_action_target(&frame, f.id)
	testing.expect(t, ok)
	testing.expect(t, focus == Focus_Opt{&slot, 3})
}

@(test)
semantics_label_truncation :: proc(t: ^testing.T) {
	// ASCII shorter than the cap: untouched.
	testing.expect_value(t, sem_label_clip("hello"), 5)
	// Exactly at the cap.
	long: [SEM_LABEL_MAX]u8
	for i in 0 ..< SEM_LABEL_MAX do long[i] = 'a'
	testing.expect_value(t, sem_label_clip(string(long[:])), SEM_LABEL_MAX)
	// Multi-byte rune straddling the cap must truncate at the rune start:
	// 62 ASCII bytes + one 3-byte rune puts the cut mid-rune at byte 64.
	buf: [SEM_LABEL_MAX + 8]u8
	for i in 0 ..< 62 do buf[i] = 'a'
	copy(buf[62:], "\u20AC") // U+20AC EURO SIGN, 3 bytes
	testing.expect_value(t, sem_label_clip(string(buf[:65])), 62)
	// A cut at a rune start is preserved.
	buf2: [SEM_LABEL_MAX + 8]u8
	for i in 0 ..< 61 do buf2[i] = 'a'
	copy(buf2[61:], "\u20AC")
	testing.expect_value(t, sem_label_clip(string(buf2[:64])), 64)
}

@(test)
semantics_node_identity :: proc(t: ^testing.T) {
	// Focus-linked ids are stable across frames and distinct across forms
	// even with identical 1-based ids.
	form_a, form_b: int
	id_a1 := sem_node_id(.Button, {&form_a, 1}, "", 0)
	id_a1_again := sem_node_id(.Button, {&form_a, 1}, "", 7) // ordinal ignored
	id_a2 := sem_node_id(.Button, {&form_a, 2}, "", 0)
	id_b1 := sem_node_id(.Button, {&form_b, 1}, "", 0)
	testing.expect_value(t, id_a1, id_a1_again)
	testing.expect(t, id_a1 != id_a2)
	testing.expect(t, id_a1 != id_b1)

	// field_id checksums are stable and distinct.
	id_email := sem_node_id(.Text_Input, {}, "login-email", 0)
	id_email2 := sem_node_id(.Text_Input, {}, "login-email", 3)
	id_pw := sem_node_id(.Text_Input, {}, "login-password", 0)
	testing.expect_value(t, id_email, id_email2)
	testing.expect(t, id_email != id_pw)

	// Fallback ids differ by call order and by role.
	l0 := sem_node_id(.Label, {}, "", 0)
	l1 := sem_node_id(.Label, {}, "", 1)
	p0 := sem_node_id(.Pane, {}, "", 0)
	testing.expect(t, l0 != l1)
	testing.expect(t, l0 != p0)

	// 0 (invalid) and SEM_ID_ROOT are never produced.
	testing.expect(t, id_a1 > SEM_ID_ROOT)
	testing.expect(t, id_email > SEM_ID_ROOT)
	testing.expect(t, l0 > SEM_ID_ROOT)
}

@(test)
semantics_text_metadata_and_privacy :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	sem_enable(&runtime, true)
	frame: Ui_Frame
	frame.runtime = &runtime
	frame.open = true
	sem_begin_frame(&frame)
	node := semantic_push(
		&frame,
		.Text_Input,
		{1, 2, 100, 24},
		"Search",
		{.Multiline},
		field_id = "search",
		description = "Search sessions",
		text_value = "hello",
		selection_start = 1,
		selection_end = 4,
	)
	testing.expect(t, node != nil)
	testing.expect_value(t, string(node.text_value[:node.text_value_len]), "hello")
	testing.expect_value(t, node.selection_start, i32(1))
	testing.expect_value(t, node.selection_end, i32(4))
	testing.expect(t, .Multiline in node.state)
}

@(test)
semantics_focus_registry :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	frame.runtime = &runtime
	frame.open = true
	sem_reset(&frame)
	defer sem_reset(&frame)

	// Registry records focusable widgets in current draw order even while
	// semantic recording is disabled, then clears before the next frame.
	slot_a, slot_b: int
	sem_begin_frame(&frame)
	semantic_push(&frame, .Button, {0, 0, 1, 1}, "a1", focus = {&slot_a, 1})
	semantic_push(&frame, .Checkbox, {0, 0, 1, 1}, "a2", focus = {&slot_a, 2})
	semantic_push(&frame, .Button, {0, 0, 1, 1}, "b1", focus = {&slot_b, 1})
	semantic_push(&frame, .Label, {0, 0, 1, 1}, "static")
	list := sem_focus_list(&frame)
	testing.expect_value(t, list.count, 3)
	testing.expect(t, list.entries[0] == Sem_Focus_Entry{focus = Focus_Opt{&slot_a, 1}})
	testing.expect(t, list.entries[1] == Sem_Focus_Entry{focus = Focus_Opt{&slot_a, 2}})
	testing.expect(t, list.entries[2] == Sem_Focus_Entry{focus = Focus_Opt{&slot_b, 1}})
	sem_begin_frame(&frame)
	testing.expect_value(t, sem_focus_list(&frame).count, 0)
}

@(test)
semantics_disabled_focus_is_not_traversable_but_action_is_retained :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	sem_enable(&runtime, true)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	slot: int
	node := semantic_push(
		&frame,
		.Button,
		{0, 0, 10, 10},
		"Disabled",
		{.Disabled},
		focus = {&slot, 1},
	)
	testing.expect(t, node != nil)
	testing.expect(t, .Disabled in node.state)
	testing.expect_value(t, sem_focus_list(&frame).count, 0)
	target, ok := sem_action_target(&frame, node.id)
	testing.expect(t, ok)
	testing.expect(t, target == Focus_Opt{&slot, 1})
	ui_frame_end(&frame)
}
