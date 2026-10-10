#+build !js
package odingate

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Ports of scripts/check_init_order_test.py and
// scripts/check_ui_api_layers_test.py: the same inline sources and temp
// trees, the same expected names and message fragments.

@(private = "file")
layers_source :: proc(text: string, path := "ui/x.odin") -> Source {
	context.allocator = context.temp_allocator
	if strings.has_prefix(text, "package ") do return parse_source(path, text, nil)
	return parse_source(path, strings.concatenate({"package t\n", text}), nil)
}

@(private = "file")
layers_messages :: proc(report: ^Report) -> []string {
	return report_messages(report, context.temp_allocator)
}

@(private = "file")
any_contains :: proc(lines: []string, needle: string) -> bool {
	for line in lines do if strings.contains(line, needle) do return true
	return false
}

// --- init-order -------------------------------------------------------------

@(private = "file")
init_found :: proc(text: string, path: string) -> []Init_Procedure {
	context.allocator = context.temp_allocator
	source := layers_source(text, path)
	found := make([dynamic]Init_Procedure)
	init_procedures_for_source(&source, &found)
	return found[:]
}

@(private = "file")
init_check :: proc(found: []Init_Procedure) -> []string {
	context.allocator = context.temp_allocator
	report: Report
	init_order_check(found, &report)
	return layers_messages(&report)
}

@(test)
init_order_comments_and_strings_are_ignored :: proc(t: ^testing.T) {
	found := init_found(
		"// @(init) runs before main on every target.\n" +
		"/* @(init, private) in a block comment */\n" +
		"message :: \"@(init)\"\n",
		"gfx/context.odin",
	)
	testing.expect_value(t, len(found), 0)
}

@(test)
init_order_the_permitted_declaration_is_found_and_accepted :: proc(t: ^testing.T) {
	found := init_found(
		"@(init, private)\n" +
		"_default_context_init :: proc \"contextless\" () {\n" +
		"\tdefault_context_storage.id = DEFAULT_CONTEXT_ID\n" +
		"}\n",
		"gfx/context.odin",
	)
	testing.expect_value(t, len(found), 1)
	if len(found) == 1 {
		testing.expect_value(t, found[0].name, "_default_context_init")
		testing.expect_value(t, found[0].line, 2)
	}
	testing.expect_value(t, len(init_check(found)), 0)
}

@(test)
init_order_attribute_order_and_bare_init_are_both_recognised :: proc(t: ^testing.T) {
	found := init_found(
		"@(private, init)\n" +
		"first :: proc \"contextless\" () {\n" +
		"}\n" +
		"\n" +
		"@(init)\n" +
		"second :: proc \"contextless\" () {\n" +
		"}\n",
		"gfx/context.odin",
	)
	testing.expect_value(t, len(found), 2)
	if len(found) == 2 {
		testing.expect_value(t, found[0].name, "first")
		testing.expect_value(t, found[1].name, "second")
	}
}

@(test)
init_order_similar_attributes_are_not_matched :: proc(t: ^testing.T) {
	found := init_found(
		"@(private)\n" +
		"initialise :: proc \"contextless\" () {\n" +
		"}\n" +
		"\n" +
		"@(init_like)\n" +
		"other :: proc \"contextless\" () {\n" +
		"}\n",
		"gfx/api.odin",
	)
	testing.expect_value(t, len(found), 0)
}

@(test)
init_order_a_second_init_in_another_gfx_file_fails :: proc(t: ^testing.T) {
	failures := init_check(
		{{"gfx/context.odin", "_default_context_init", 325}, {"gfx/api.odin", "_api_init", 12}},
	)
	testing.expect_value(t, len(failures), 1)
	if len(failures) == 1 {
		testing.expect(t, strings.contains(failures[0], "gfx/api.odin:12"))
		testing.expect(t, strings.contains(failures[0], "_api_init"))
	}
}

@(test)
init_order_an_init_in_a_gfx_test_file_fails :: proc(t: ^testing.T) {
	failures := init_check(
		{{"gfx/context.odin", "_default_context_init", 325}, {"gfx/api_test.odin", "_seed", 8}},
	)
	testing.expect_value(t, len(failures), 1)
	if len(failures) == 1 do testing.expect(t, strings.contains(failures[0], "gfx/api_test.odin:8"))
}

@(test)
init_order_a_differently_named_init_in_context_odin_fails :: proc(t: ^testing.T) {
	failures := init_check({{"gfx/context.odin", "_context_init", 325}})
	testing.expect_value(t, len(failures), 2)
	testing.expect(t, any_contains(failures, "_context_init"))
	testing.expect(t, any_contains(failures, "is missing"))
}

@(test)
init_order_removing_the_declaration_fails :: proc(t: ^testing.T) {
	failures := init_check({})
	testing.expect_value(t, len(failures), 1)
	if len(failures) == 1 {
		testing.expect(t, strings.contains(failures[0], "_default_context_init"))
		testing.expect(t, strings.contains(failures[0], "is missing"))
	}
}

@(test)
init_order_a_duplicated_declaration_fails :: proc(t: ^testing.T) {
	failures := init_check(
		{
			{"gfx/context.odin", "_default_context_init", 325},
			{"gfx/context.odin", "_default_context_init", 400},
		},
	)
	testing.expect_value(t, len(failures), 1)
	if len(failures) == 1 do testing.expect(t, strings.contains(failures[0], "declared 2 times"))
}

// --- ui-api-layers: declarations and ui policy ------------------------------

@(private = "file")
ui_policy :: proc(text: string) -> []string {
	context.allocator = context.temp_allocator
	source := layers_source(text)
	report: Report
	ui_layers_violations(&source, &report)
	return layers_messages(&report)
}

@(test)
ui_layers_multiline_receiver_and_renamed_receiver_are_found :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	source := layers_source("facade :: proc(\n\tctx: ^Ui,\n\tvalue: i32,\n) {}\n")
	decls := ui_layers_declarations(&source)
	testing.expect_value(t, len(decls), 1)
	if len(decls) == 1 do testing.expect(t, strings.contains(decls[0].parameters, "ctx: ^Ui"))
}

@(test)
ui_layers_comments_and_strings_are_not_declarations :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	source := layers_source(
		"// fake :: proc(u: ^Ui) {}\ns := \"fake :: proc(u: ^Ui)\"\nreal :: proc() {}\n",
	)
	decls := ui_layers_declarations(&source)
	testing.expect_value(t, len(decls), 1)
	if len(decls) == 1 do testing.expect_value(t, decls[0].name, "real")
}

@(test)
ui_layers_private_facade_helper_is_allowed :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		len(ui_policy("@(private = \"package\")\nui_helper :: proc(u: ^Ui) {}\n")),
		0,
	)
}

@(test)
ui_layers_ui_prefixed_facade_is_rejected :: proc(t: ^testing.T) {
	testing.expect(t, any_contains(ui_policy("ui_button :: proc(ctx: ^Ui) {}\n"), "bare name"))
}

@(test)
ui_layers_forbidden_facade_suffix_is_rejected :: proc(t: ^testing.T) {
	testing.expect(
		t,
		any_contains(ui_policy("button_auto :: proc(ctx: ^Ui) {}\n"), "forbidden facade suffix"),
	)
}

@(test)
ui_layers_runtime_prefix_is_allowed :: proc(t: ^testing.T) {
	messages := ui_policy("ui_frame_theme :: proc(frame: ^Ui_Frame) -> ^Theme { return nil }\n")
	testing.expect_value(t, len(messages), 0)
}

@(test)
ui_layers_explicit_leaf_requires_rect :: proc(t: ^testing.T) {
	messages := ui_policy(
		"button_at :: proc(frame: ^Ui_Frame, x, y, w, h: i32, label: string) {}\n",
	)
	testing.expect(t, any_contains(messages, "one Rect_I32"))
	testing.expect(t, any_contains(messages, "loose x/y/w/h"))
}

@(test)
ui_layers_explicit_leaf_allows_optional_interaction_rect :: proc(t: ^testing.T) {
	messages := ui_policy(
		"button_at :: proc(frame: ^Ui_Frame, rect: Rect_I32, interaction_rect: ^Rect_I32 = nil) {}\n",
	)
	testing.expect_value(t, len(messages), 0)
}

@(test)
ui_layers_explicit_protocol_rejects_loose_rectangle :: proc(t: ^testing.T) {
	messages := ui_policy("pane_begin :: proc(frame: ^Ui_Frame, x, y, w, h: i32) {}\n")
	testing.expect(t, any_contains(messages, "explicit protocol"))
}

@(test)
ui_layers_paint_subsystem_is_an_intentional_exception :: proc(t: ^testing.T) {
	messages := ui_policy(
		"overlay_rect :: proc(frame: ^Ui_Frame, rect: Rectangle, color: Color) {}\n",
	)
	testing.expect_value(t, len(messages), 0)
}

@(test)
ui_layers_deleted_name_is_rejected :: proc(t: ^testing.T) {
	testing.expect(
		t,
		any_contains(
			ui_policy("btn_at :: proc(frame: ^Ui_Frame, rect: Rect_I32) {}\n"),
			"deleted UI API",
		),
	)
}

@(test)
ui_layers_adapter_lifecycle_names_are_tracked :: proc(t: ^testing.T) {
	found_init, found_prepare := false, false
	for name in UI_LAYERS_ADAPTER_LIFECYCLE {
		if name == "adapter_init" do found_init = true
		if name == "adapter_prepare_frame" do found_prepare = true
	}
	testing.expect(t, found_init && found_prepare)
}

// --- ui-api-layers: fit public surface --------------------------------------

@(private = "file")
fit_public :: proc(text: string) -> []string {
	context.allocator = context.temp_allocator
	source := layers_source(text, "fit/x.odin")
	report: Report
	ui_layers_fit_public_violations(&source, &report)
	return layers_messages(&report)
}

@(test)
ui_layers_fit_public_alias_to_ui_is_rejected :: proc(t: ^testing.T) {
	testing.expect(t, any_contains(fit_public("Ui :: ui.Ui\n"), "internal UI type"))
}

@(test)
ui_layers_fit_approved_public_alias_to_ui_is_allowed :: proc(t: ^testing.T) {
	testing.expect_value(t, len(fit_public("Track :: ui.Track\n")), 0)
	testing.expect_value(
		t,
		len(fit_public("Control_Motion_State :: ui.Control_Motion_State\n")),
		0,
	)
}

@(test)
ui_layers_fit_unapproved_public_alias_to_ui_is_rejected :: proc(t: ^testing.T) {
	testing.expect(t, any_contains(fit_public("Unexpected :: ui.Track\n"), "internal UI type"))
}

@(test)
ui_layers_fit_private_conversion_may_reference_ui :: proc(t: ^testing.T) {
	messages := fit_public(
		"@(private = \"package\")\nto_rect :: proc(rect: Rect) -> ui.Rect_I32 { return {} }\n",
	)
	testing.expect_value(t, len(messages), 0)
}

@(test)
ui_layers_split_session_lifecycle_is_rejected :: proc(t: ^testing.T) {
	testing.expect(
		t,
		any_contains(
			fit_public("Session_Begin :: proc(session: ^Session) {}\n"),
			"split session lifecycle",
		),
	)
	testing.expect(
		t,
		any_contains(
			fit_public("session_begin :: proc(session: ^Session) {}\n"),
			"split session lifecycle",
		),
	)
}

@(test)
ui_layers_fit_snake_case_public_procedure_exposing_ui_is_rejected :: proc(t: ^testing.T) {
	messages := fit_public("surface_ui :: proc(surface: ^Surface) -> ^ui.Ui { return nil }\n")
	testing.expect(t, any_contains(messages, "internal UI type"))
}

// --- ui-api-layers: temp-tree checks ----------------------------------------

// Layers_Tree is a scratch repository root with `ui/` and `fit/` present so
// the repo walk has its expected shape; the test writes one example file.
Layers_Tree :: struct {
	root: string,
	ok:   bool,
}

@(private = "file")
layers_tree_make :: proc(t: ^testing.T) -> Layers_Tree {
	base, temp_err := os.temp_dir(context.temp_allocator)
	testing.expect(t, temp_err == nil)
	root, make_err := os.make_directory_temp(base, "odingate-layers-*", context.temp_allocator)
	testing.expect(t, make_err == nil)
	if make_err != nil do return {}
	for sub in ([?]string{"ui", "fit"}) {
		dir, _ := filepath.join({root, sub}, context.temp_allocator)
		testing.expect(t, os.make_directory(dir) == nil)
	}
	return Layers_Tree{root, true}
}

@(private = "file")
layers_tree_write :: proc(t: ^testing.T, tree: Layers_Tree, rel, text: string) {
	full, _ := filepath.join({tree.root, rel}, context.temp_allocator)
	dir, _ := filepath.split(full)
	testing.expect(t, os.make_directory_all(dir) == nil)
	testing.expect(t, os.write_entire_file(full, text) == nil)
}

@(private = "file")
layers_tree_check :: proc(tree: Layers_Tree) -> []string {
	context.allocator = context.temp_allocator
	report: Report
	ui_layers_check_repo(tree.root, &report)
	return layers_messages(&report)
}

@(private = "file")
layers_consumer_check :: proc(t: ^testing.T, text: string, allow: bool) -> []string {
	context.allocator = context.temp_allocator
	base, _ := os.temp_dir(context.temp_allocator)
	root, make_err := os.make_directory_temp(base, "odingate-consumer-*", context.temp_allocator)
	testing.expect(t, make_err == nil)
	if make_err != nil do return {}
	defer os.remove_all(root)
	path, _ := filepath.join({root, "view.odin"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, text) == nil)
	ingot, _ := filepath.join({root, "ingot"}, context.temp_allocator)
	allowed: []string = allow ? {path} : {}
	report: Report
	ui_layers_check_consumers({root}, allowed, ingot, &report)
	return layers_messages(&report)
}

@(test)
ui_layers_adapter_and_legacy_session_are_rejected :: proc(t: ^testing.T) {
	failures := layers_consumer_check(
		t,
		"package app\nf :: proc() { adapter_bind_frame(nil, nil) }\nx: App_Session\n",
		false,
	)
	testing.expect(t, any_contains(failures, "adapter"))
	testing.expect(t, any_contains(failures, "legacy session"))
}

@(test)
ui_layers_binding_allow_only_allows_binding_import :: proc(t: ^testing.T) {
	failures := layers_consumer_check(
		t,
		"package app\nimport \"ingot:libvterm\"\nf :: proc() { adapter_init(nil) }\n",
		true,
	)
	testing.expect(t, !any_contains(failures, "binding import"))
	testing.expect(t, any_contains(failures, "adapter"))
}

@(test)
ui_layers_comments_and_strings_do_not_trigger_consumer_policy :: proc(t: ^testing.T) {
	failures := layers_consumer_check(
		t,
		"package app\n// adapter_init(nil)\ns := \"App_Session ingot:pty\"\n",
		false,
	)
	testing.expect_value(t, len(failures), 0)
}

@(test)
ui_layers_advanced_ui_imports_are_allowed :: proc(t: ^testing.T) {
	failures := layers_consumer_check(
		t,
		"package app\nimport \"ingot:ui\"\nimport \"ingot:ui_gfx\"\n",
		false,
	)
	testing.expect_value(t, len(failures), 0)
}

@(test)
ui_layers_string_literal_mentioning_internal_package_is_allowed :: proc(t: ^testing.T) {
	tree := layers_tree_make(t)
	if !tree.ok do return
	defer os.remove_all(tree.root)
	layers_tree_write(
		t,
		tree,
		"examples/main.odin",
		"package main\nimport fit \"ingot:fit\"\ntitle := \"ingot:ui_gfx\"\n",
	)
	testing.expect_value(t, len(layers_tree_check(tree)), 0)
}

@(test)
ui_layers_retired_fit_and_graphics_apis_are_rejected :: proc(t: ^testing.T) {
	failures := layers_consumer_check(
		t,
		"package app\nf :: proc() { fit_tree(nil, {}); clear_frame(nil, {}) }\n",
		false,
	)
	testing.expect(t, any_contains(failures, "retired UI API"))
	testing.expect(t, any_contains(failures, "retired graphics API"))
}

@(test)
ui_layers_frame_layer_drawing_is_not_retired :: proc(t: ^testing.T) {
	failures := layers_consumer_check(
		t,
		"package app\nf :: proc(frame: ^rl.Frame) { rl.frame_draw_rectangle(frame, {}, {}) }\n",
		false,
	)
	testing.expect(t, !any_contains(failures, "retired graphics API"))
}

@(test)
ui_layers_repository_examples_allow_advanced_ui_imports :: proc(t: ^testing.T) {
	tree := layers_tree_make(t)
	if !tree.ok do return
	defer os.remove_all(tree.root)
	layers_tree_write(t, tree, "examples/main.odin", "package main\nimport \"ingot:ui_gfx\"\n")
	testing.expect_value(t, len(layers_tree_check(tree)), 0)
}

@(test)
ui_layers_example_cannot_alias_fit_as_ui :: proc(t: ^testing.T) {
	tree := layers_tree_make(t)
	if !tree.ok do return
	defer os.remove_all(tree.root)
	layers_tree_write(t, tree, "examples/main.odin", "package main\nimport ui \"ingot:fit\"\n")
	testing.expect(t, any_contains(layers_tree_check(tree), "Fit imported as internal UI alias"))
}

@(test)
ui_layers_gallery_rejects_compatibility_fit_alias_and_names :: proc(t: ^testing.T) {
	tree := layers_tree_make(t)
	if !tree.ok do return
	defer os.remove_all(tree.root)
	layers_tree_write(
		t,
		tree,
		"examples/gallery/main.odin",
		"package main\nimport legacy \"ingot:fit\"\nf :: proc() { _: legacy_Ui_Frame }\n",
	)
	failures := layers_tree_check(tree)
	testing.expect(t, any_contains(failures, "must import ingot:fit as fit"))
	testing.expect(t, any_contains(failures, "compatibility UI name"))
}

@(test)
ui_layers_non_gallery_example_rejects_compatibility_name :: proc(t: ^testing.T) {
	tree := layers_tree_make(t)
	if !tree.ok do return
	defer os.remove_all(tree.root)
	layers_tree_write(
		t,
		tree,
		"examples/chart_demo/main.odin",
		"package main\nimport fit \"ingot:fit\"\nx: fit.Host_App\n",
	)
	testing.expect(t, any_contains(layers_tree_check(tree), "compatibility UI name"))
}

@(test)
ui_layers_gallery_allows_public_fit_surface :: proc(t: ^testing.T) {
	tree := layers_tree_make(t)
	if !tree.ok do return
	defer os.remove_all(tree.root)
	layers_tree_write(
		t,
		tree,
		"examples/gallery/main.odin",
		"package main\nimport fit \"ingot:fit\"\nf :: proc(surface: ^fit.Surface) {}\n",
	)
	testing.expect_value(t, len(layers_tree_check(tree)), 0)
}

@(test)
ui_layers_rel_paths_use_forward_slashes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	when filepath.SEPARATOR == '\\' {
		testing.expect_value(t, rel_slash("ui_gfx\\adapter.odin"), "ui_gfx/adapter.odin")
	} else {
		testing.expect_value(t, rel_slash("ui_gfx/adapter.odin"), "ui_gfx/adapter.odin")
	}
	tree := layers_tree_make(t)
	if !tree.ok do return
	defer os.remove_all(tree.root)
	layers_tree_write(t, tree, "ui_gfx/adapter.odin", "package ui_gfx\n")
	layers_tree_write(t, tree, "examples/gallery/main.odin", "package main\n")
	files, ok := collect_odin_files(tree.root, "")
	testing.expect(t, ok)
	testing.expect_value(t, len(files), 2)
	for path in files do testing.expect(t, !strings.contains(path, "\\"), path)
	testing.expect_value(t, files[0], "examples/gallery/main.odin")
	testing.expect_value(t, files[1], "ui_gfx/adapter.odin")
}

@(test)
ui_layers_repo_check_honours_file_list :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	tree := layers_tree_make(t)
	if !tree.ok do return
	defer os.remove_all(tree.root)
	layers_tree_write(t, tree, "examples/main.odin", "package main\nimport ui \"ingot:fit\"\n")
	layers_tree_write(t, tree, "examples/other/main.odin", "package main\n")
	walked: Report
	ui_layers_check_repo(tree.root, &walked)
	testing.expect(t, any_contains(layers_messages(&walked), "Fit imported as internal UI alias"))
	listed: Report
	ui_layers_check_repo(tree.root, &listed, {"examples/other/main.odin"})
	testing.expect_value(t, len(listed.findings), 0)
	tracked: Report
	ui_layers_check_repo(tree.root, &tracked, {"examples/main.odin"})
	testing.expect(t, any_contains(layers_messages(&tracked), "Fit imported as internal UI alias"))
}

@(test)
ui_layers_path_inside_is_separator_agnostic :: proc(t: ^testing.T) {
	tree := layers_tree_make(t)
	if !tree.ok do return
	defer os.remove_all(tree.root)
	layers_tree_write(t, tree, "examples/x.odin", "package main\n")
	nested, _ := filepath.join({tree.root, "examples", "x.odin"}, context.temp_allocator)
	testing.expect(t, ui_layers_path_inside(nested, tree.root))
	testing.expect(t, ui_layers_path_inside(tree.root, tree.root))
	sibling := strings.concatenate({tree.root, "-other"}, context.temp_allocator)
	testing.expect(t, !ui_layers_path_inside(sibling, tree.root))
}
