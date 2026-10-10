#+build !js
package odingate

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Each test mirrors one case in scripts/check_gfx_context_test.py: the same
// inline sources, the same expected `path:proc` counts and messages. Sources
// gain a `package gfx` line because core:odin/parser needs one.

@(private = "file")
gfx_source :: proc(text: string, path := "gfx/x.odin") -> Source {
	context.allocator = context.temp_allocator
	if strings.has_prefix(text, "#+private") || strings.has_prefix(text, "package ") {
		return parse_source(path, text, nil)
	}
	return parse_source(path, strings.concatenate({"package gfx\n", text}), nil)
}

@(private = "file")
gfx_counts :: proc(text: string, path: string, kind: Gfx_Count_Kind) -> map[string]int {
	context.allocator = context.temp_allocator
	source := gfx_source(text, path)
	counts: map[string]int
	gfx_counts_for_source(&source, kind, &counts)
	return counts
}

@(private = "file")
gfx_escapes :: proc(text: string, path := "gfx/x.odin") -> map[string]int {
	context.allocator = context.temp_allocator
	source := gfx_source(text, path)
	debt: map[string]int
	gfx_default_context_debt_for_source(&source, &debt)
	return debt
}

@(private = "file")
expect_counts :: proc(
	t: ^testing.T,
	got: map[string]int,
	want: map[string]int,
	loc := #caller_location,
) {
	testing.expectf(t, len(got) == len(want), "expected %v, got %v", want, got, loc = loc)
	for key, value in want {
		testing.expectf(
			t,
			(got[key] or_else -1) == value,
			"key %s: expected %d, got %v",
			key,
			value,
			got[key],
			loc = loc,
		)
	}
}

@(private = "file")
pair :: proc(k1: string, v1: int, k2 := "", v2 := 0) -> map[string]int {
	m := make(map[string]int, context.temp_allocator)
	m[k1] = v1
	if k2 != "" do m[k2] = v2
	return m
}

@(private = "file")
gfx_global_names :: proc(text: string) -> []string {
	context.allocator = context.temp_allocator
	source := gfx_source(text)
	decls := gfx_package_global_declarations(&source)
	names := make([]string, len(decls))
	for decl, index in decls do names[index] = decl.name
	return names
}

@(private = "file")
expect_names :: proc(t: ^testing.T, got: []string, want: []string, loc := #caller_location) {
	testing.expectf(t, len(got) == len(want), "expected %v, got %v", want, got, loc = loc)
	if len(got) != len(want) do return
	for name, index in want do testing.expect_value(t, got[index], name, loc = loc)
}

@(private = "file")
gfx_pascal :: proc(text: string) -> Report {
	context.allocator = context.temp_allocator
	source := gfx_source(text)
	allowed: map[string]bool
	for name in ([?]string{"DrawRectangle", "BeginMode3D", "RlLoadVertexArray"}) {
		allowed[name] = true
	}
	report: Report
	gfx_pascal_case_violations(&source, allowed, &report)
	return report
}

@(test)
gfx_comments_strings_and_similar_identifiers_are_ignored :: proc(t: ^testing.T) {
	counts := gfx_counts(
		"p :: proc() {\n" +
		"\t// g.frame\n" +
		"\ttext := \"g.frame\"\n" +
		"\tglobal := 1\n" +
		"\t_ = text; _ = global\n" +
		"}\n",
		"gfx/x.odin",
		.Direct_Global,
	)
	testing.expect_value(t, len(counts), 0)
}

@(test)
gfx_direct_global_references_are_counted_by_procedure :: proc(t: ^testing.T) {
	counts := gfx_counts(
		"first :: proc() {\n" +
		"\tg.frame.has_frame = true\n" +
		"\tg.rend = {}\n" +
		"}\n" +
		"second :: proc() {\n" +
		"\tctx := g\n" +
		"\t_ = ctx\n" +
		"}\n",
		"gfx/x.odin",
		.Direct_Global,
	)
	expect_counts(t, counts, pair("gfx/x.odin:first", 2, "gfx/x.odin:second", 1))
}

@(test)
gfx_qualified_context_identifier_is_not_global_routing :: proc(t: ^testing.T) {
	source := "callback :: proc() {\n\tcontext = runtime.default_context()\n}\n"
	testing.expect_value(t, len(gfx_counts(source, "gfx/x.odin", .Direct_Global)), 0)
	testing.expect_value(t, len(gfx_escapes(source)), 0)
}

@(test)
gfx_rejects_default_context_inside_implementation :: proc(t: ^testing.T) {
	debt := gfx_escapes(
		"context_draw :: proc(ctx: ^Context) {}\n" +
		"helper :: proc() {\n" +
		"\tcontext_draw(default_context())\n" +
		"}\n",
	)
	expect_counts(t, debt, pair("gfx/x.odin:helper", 1))
}

@(test)
gfx_accepts_thin_pascal_case_default_context_wrapper :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		len(gfx_escapes("Draw :: proc() {\n\tcontext_draw(default_context())\n}\n")),
		0,
	)
}

@(test)
gfx_accepts_thin_legacy_facade_wrapper :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		len(
			gfx_escapes(
				"stats :: proc() -> Stats {\n" +
				"\treturn context_renderer_stats(default_context())\n" +
				"}\n",
			),
		),
		0,
	)
}

@(test)
gfx_rejects_renderer_internal_default_context :: proc(t: ^testing.T) {
	debt := gfx_escapes(
		"renderer_flush :: proc(r: ^Renderer) {\n\tflush(default_context(), r)\n}\n",
	)
	expect_counts(t, debt, pair("gfx/x.odin:renderer_flush", 1))
}

@(test)
gfx_rejects_control_flow_facade_escape :: proc(t: ^testing.T) {
	debt := gfx_escapes(
		"Draw :: proc() {\n\tif ready {\n\t\tcontext_draw(default_context())\n\t}\n}\n",
	)
	expect_counts(t, debt, pair("gfx/x.odin:Draw", 1))
}

@(test)
gfx_rejects_active_context_symbols :: proc(t: ^testing.T) {
	counts := gfx_counts(
		"first :: proc() {\n" +
		"\tctx := active_context()\n" +
		"\t_ = ctx\n" +
		"}\n" +
		"second :: proc() {\n" +
		"\tprevious := _context_activate(ctx)\n" +
		"\t_context_restore(previous)\n" +
		"}\n",
		"gfx/x.odin",
		.Active_Context,
	)
	expect_counts(t, counts, pair("gfx/x.odin:first", 1, "gfx/x.odin:second", 2))
}

@(test)
gfx_rejects_context_scope_symbols :: proc(t: ^testing.T) {
	counts := gfx_counts(
		"first :: proc() -> Context_Scope {\n" +
		"\treturn context_scope_enter(ctx)\n" +
		"}\n" +
		"second :: proc(scope: ^Context_Scope) {\n" +
		"\tcontext_scope_leave(scope)\n" +
		"}\n",
		"gfx/x.odin",
		.Active_Context,
	)
	expect_counts(t, counts, pair("gfx/x.odin:first", 2, "gfx/x.odin:second", 2))
}

@(test)
gfx_rejects_implicit_ui_gfx_drawing :: proc(t: ^testing.T) {
	counts := gfx_counts(
		"paint :: proc() {\n" +
		"\tBeginDrawing()\n" +
		"\tDrawText(\"x\", 0, 0, 12, WHITE)\n" +
		"\tEndDrawing()\n" +
		"}\n",
		"ui_gfx/x.odin",
		.Implicit_Draw,
	)
	expect_counts(t, counts, pair("ui_gfx/x.odin:paint", 3))
}

@(test)
gfx_zero_debt_failures_require_empty_results :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	empty: Report
	gfx_zero_debt_failures("debt", {}, &empty)
	testing.expect_value(t, len(empty.findings), 0)
	report: Report
	gfx_zero_debt_failures("debt", pair("gfx/x.odin:p", 2), &report)
	lines := report_messages(&report)
	testing.expect_value(t, len(lines), 1)
	if len(lines) == 1 {
		testing.expect_value(t, lines[0], "gfx/x.odin:p: debt is forbidden (2 references)")
	}
}

@(test)
gfx_controlled_global_routing_requires_exact_inventory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	expected: map[string]int
	for entry in GFX_CONTROLLED_GLOBAL_ROUTING do expected[entry.key] = entry.count
	testing.expect_value(t, len(gfx_controlled_global_debt(expected)), 0)
	expected["gfx/context.odin:default_context"] += 1
	expect_counts(
		t,
		gfx_controlled_global_debt(expected),
		pair("gfx/context.odin:default_context", 2),
	)
}

@(test)
gfx_test_source_suffixes_are_excluded :: proc(t: ^testing.T) {
	for path in ([?]string{"gfx/x_test.odin", "gfx/x_tests.odin", "gfx/x_fuzz_test.odin"}) {
		testing.expect(t, has_any_suffix(path, GFX_EXCLUDED_SUFFIXES[:]))
	}
}

@(test)
gfx_bare_package_global_is_reported :: proc(t: ^testing.T) {
	names := gfx_global_names(
		"package gfx\n\n@(private)\ng_owner: ^Context\ncount := 3\nflag: bool = true\n",
	)
	expect_names(t, names, {"g_owner", "count", "flag"})
}

@(test)
gfx_locals_inside_procedures_are_ignored :: proc(t: ^testing.T) {
	expect_names(
		t,
		gfx_global_names("p :: proc() {\n\tlocal := 1\n\tother: int\n\t_ = local; _ = other\n}\n"),
		{},
	)
}

@(test)
gfx_globals_inside_when_blocks_are_reported :: proc(t: ^testing.T) {
	names := gfx_global_names(
		"when ODIN_OS == .Darwin {\n" +
		"\t@(private = \"file\")\n" +
		"\tg_layer: rawptr\n" +
		"} else {\n" +
		"\tg_other: int\n" +
		"}\n",
	)
	expect_names(t, names, {"g_layer", "g_other"})
}

@(test)
gfx_struct_fields_constants_and_rodata_are_ignored :: proc(t: ^testing.T) {
	names := gfx_global_names(
		"LIMIT :: 4\n" +
		"Shape :: struct {\n" +
		"\twidth: int,\n" +
		"\theight: int,\n" +
		"}\n" +
		"Kind :: enum {\n" +
		"\tA,\n" +
		"}\n" +
		"@(rodata)\n" +
		"TABLE := [2]int{1, 2}\n" +
		"Run_Proc :: #type proc()\n",
	)
	expect_names(t, names, {})
}

@(test)
gfx_load_initialisers_are_reported :: proc(t: ^testing.T) {
	expect_names(
		t,
		gfx_global_names("when true {\n\tDEFAULT_FONT_TTF := #load(\"../assets/x.ttf\")\n}\n"),
		{"DEFAULT_FONT_TTF"},
	)
}

@(test)
gfx_failures_cover_undeclared_and_stale_entries :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	source := gfx_source("package gfx\n\ng_new: int\ng_known: int\n")
	sources := [?]Source{source}
	allowed := [?]Gfx_Allowed_Globals{{"gfx/x.odin", {"g_known", "g_gone"}}}
	report: Report
	gfx_package_global_failures(sources[:], allowed[:], &report)
	lines := report_messages(&report)
	testing.expect_value(t, len(lines), 2)
	if len(lines) == 2 {
		testing.expect_value(
			t,
			lines[0],
			"gfx/x.odin: g_gone: stale ALLOWED_PACKAGE_GLOBALS entry (declaration not found)",
		)
		testing.expect_value(t, lines[1], "gfx/x.odin:3: g_new: undeclared gfx package global")
	}
	clean := [?]Gfx_Allowed_Globals{{"gfx/x.odin", {"g_new", "g_known"}}}
	ok: Report
	gfx_package_global_failures(sources[:], clean[:], &ok)
	testing.expect_value(t, len(ok.findings), 0)
}

@(test)
gfx_raylib_named_facade_is_accepted :: proc(t: ^testing.T) {
	report := gfx_pascal(
		"DrawRectangle :: proc() {\n\tcontext_draw_rectangle(default_context())\n}\n",
	)
	testing.expect_value(t, len(report.findings), 0)
}

@(test)
gfx_ingot_only_pascal_case_is_rejected :: proc(t: ^testing.T) {
	report := gfx_pascal("SetFrameStrategy :: proc(s: Frame_Strategy) {\n\tx := s\n\t_ = x\n}\n")
	lines := report_messages(&report, context.temp_allocator)
	testing.expect_value(t, len(lines), 1)
	if len(lines) == 1 {
		testing.expect(t, strings.has_prefix(lines[0], "gfx/x.odin:2: SetFrameStrategy"))
		testing.expect(t, strings.contains(lines[0], "Ingot-only PascalCase API"))
	}
}

@(test)
gfx_deprecated_and_private_forwarders_are_accepted :: proc(t: ^testing.T) {
	report := gfx_pascal(
		"@(deprecated = \"use set_frame_strategy\")\n" +
		"SetFrameStrategy :: proc(s: Frame_Strategy) {\n" +
		"\tset_frame_strategy(s)\n" +
		"}\n" +
		"@(private = \"package\")\n" +
		"HelperThing :: proc() {\n" +
		"}\n",
	)
	testing.expect_value(t, len(report.findings), 0)
}

@(test)
gfx_snake_case_and_types_are_ignored :: proc(t: ^testing.T) {
	report := gfx_pascal(
		"set_frame_strategy :: proc(s: Frame_Strategy) {\n" +
		"}\n" +
		"Frame_Strategy :: enum u8 {\n" +
		"\tContinuous,\n" +
		"}\n",
	)
	testing.expect_value(t, len(report.findings), 0)
}

@(test)
gfx_procedure_type_is_not_a_procedure :: proc(t: ^testing.T) {
	report := gfx_pascal("Run_Proc :: proc()\nRun_Callback :: struct {\n\tproc_: Run_Proc,\n}\n")
	testing.expect_value(t, len(report.findings), 0)
}

@(test)
gfx_file_private_sources_are_skipped :: proc(t: ^testing.T) {
	report := gfx_pascal("#+private\npackage gfx\nSomething :: proc() {\n}\n")
	testing.expect_value(t, len(report.findings), 0)
}

@(test)
gfx_raylib_vocabulary_is_read_from_vendor_sources :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, temp_err := os.temp_dir(context.temp_allocator)
	testing.expect(t, temp_err == nil)
	vendor, make_err := os.make_directory_temp(base, "odingate-raylib-*", context.temp_allocator)
	testing.expect(t, make_err == nil)
	defer os.remove_all(vendor)
	rlgl, _ := filepath.join({vendor, "rlgl"})
	testing.expect(t, os.make_directory(rlgl) == nil)
	raylib, _ := filepath.join({vendor, "raylib.odin"})
	raymath, _ := filepath.join({vendor, "raymath.odin"})
	rlgl_file, _ := filepath.join({rlgl, "rlgl.odin"})
	testing.expect(
		t,
		os.write_entire_file(raylib, "DrawRectangle :: proc() ---\nColor :: struct {}\n") == nil,
	)
	testing.expect(t, os.write_entire_file(raymath, "Vector2Add :: proc() {}\n") == nil)
	testing.expect(
		t,
		os.write_entire_file(rlgl_file, "LoadVertexArray :: proc() -> u32 ---\n") == nil,
	)
	names, ok := gfx_raylib_names(vendor)
	testing.expect(t, ok)
	testing.expect(t, "DrawRectangle" in names)
	testing.expect(t, "Vector2Add" in names)
	testing.expect(t, "RlLoadVertexArray" in names)
}

@(test)
gfx_missing_vendor_source_is_an_error :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, temp_err := os.temp_dir(context.temp_allocator)
	testing.expect(t, temp_err == nil)
	vendor, make_err := os.make_directory_temp(base, "odingate-empty-*", context.temp_allocator)
	testing.expect(t, make_err == nil)
	defer os.remove_all(vendor)
	_, ok := gfx_raylib_names(vendor)
	testing.expect(t, !ok)
}
