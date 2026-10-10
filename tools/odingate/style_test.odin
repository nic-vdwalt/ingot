#+build !js
package odingate

import "core:strings"
import "core:testing"

// Each test mirrors one case in scripts/check_odin_style_test.py so the port
// is provably faithful: the same inline sources, the same expected lines and
// message fragments.

// Parsed ASTs live in the per-test temp arena so the tracking allocator does
// not report every parser node as a leak.
@(private = "file")
style_source :: proc(text: string, path := "") -> Source {
	context.allocator = context.temp_allocator
	return parse_source(path == "" ? "t.odin" : path, text, nil)
}

@(private = "file")
style_run :: proc(text: string, baseline: Int_Baseline = nil, path := "") -> Report {
	context.allocator = context.temp_allocator
	source := style_source(text, path)
	report: Report
	style_check_source(&source, baseline, nil, &report)
	report_sort(&report)
	return report
}

@(private = "file")
style_lines :: proc(report: ^Report, allocator := context.temp_allocator) -> []int {
	lines := make([]int, len(report.findings), allocator)
	for finding, index in report.findings do lines[index] = finding.line
	return lines
}

@(private = "file")
expect_lines :: proc(t: ^testing.T, report: ^Report, expected: []int, loc := #caller_location) {
	got := style_lines(report)
	testing.expectf(
		t,
		len(got) == len(expected),
		"expected %d findings at %v, got %d: %v",
		len(expected),
		expected,
		len(got),
		report_messages(report, context.temp_allocator),
		loc = loc,
	)
	if len(got) != len(expected) do return
	for value, index in expected {
		testing.expectf(
			t,
			got[index] == value,
			"finding %d at line %d, want %d",
			index,
			got[index],
			value,
			loc = loc,
		)
	}
}

@(private = "file")
repeat_line :: proc(line: string, count: int) -> string {
	return strings.repeat(line, count, context.temp_allocator)
}

@(test)
style_line_limit_accepts_100_and_rejects_101 :: proc(t: ^testing.T) {
	source := strings.concatenate(
		{repeat_line("x", 100), "\n", repeat_line("x", 101), "\n"},
		context.temp_allocator,
	)
	report := style_run(source)
	expect_lines(t, &report, {2})
}

@(test)
style_unicode_counts_characters_and_crlf_is_ignored :: proc(t: ^testing.T) {
	source := strings.concatenate(
		{repeat_line("é", 100), "\r\n", repeat_line("é", 101), "\r\n"},
		context.temp_allocator,
	)
	report := style_run(source)
	expect_lines(t, &report, {2})
}

@(test)
style_procedure_limit_accepts_100_and_rejects_101 :: proc(t: ^testing.T) {
	accepted := strings.concatenate(
		{"package t\np :: proc() {\n", repeat_line("\tx := 1\n", 98), "}\n"},
		context.temp_allocator,
	)
	rejected := strings.concatenate(
		{"package t\np :: proc() {\n", repeat_line("\tx := 1\n", 99), "}\n"},
		context.temp_allocator,
	)
	ok := style_run(accepted)
	expect_lines(t, &ok, {})
	report := style_run(rejected)
	expect_lines(t, &report, {2})
	testing.expect(t, report_has_message(&report, "101 lines"))
}

@(test)
style_attributes_and_multiline_signatures_are_counted :: proc(t: ^testing.T) {
	source := style_source(
		"package t\n@(private)\np :: proc(\n\tx: int,\n) -> (\n\tint,\n) {\n\treturn x\n}\n",
	)
	procs := top_level_procs(source.file, context.temp_allocator)
	testing.expect(t, len(procs) == 1)
	testing.expect_value(t, procs[0].start_line, 2)
	testing.expect_value(t, procs[0].end_line, 9)
}

@(test)
style_strings_runes_raw_strings_and_nested_comments_hide_braces :: proc(t: ^testing.T) {
	source := style_source(
		"package t\n" +
		"p :: proc() {\n" +
		"\tx := \"}\"\n" +
		"\ty := '}'\n" +
		"\tz := `}`\n" +
		"\t/* { /* } */ } */\n" +
		"\t_ = x; _ = y; _ = z\n" +
		"}\n",
	)
	procs := top_level_procs(source.file, context.temp_allocator)
	testing.expect(t, len(procs) == 1)
	testing.expect_value(t, procs[0].end_line, 8)
}

@(test)
style_procedure_types_and_foreign_declarations_are_ignored :: proc(t: ^testing.T) {
	source := style_source(
		"package t\n" +
		"Callback :: proc(x: int) -> bool\n" +
		"foreign lib {\n" +
		"\tforeign_proc :: proc(x: int) -> bool ---\n" +
		"}\n",
	)
	procs := top_level_procs(source.file, context.temp_allocator)
	testing.expect_value(t, len(procs), 0)
}

@(test)
style_anonymous_procedure_does_not_end_outer_procedure :: proc(t: ^testing.T) {
	source := style_source(
		"package t\nouter :: proc() {\n\tcallback := proc() {\n\t}\n\t_ = callback\n}\n",
	)
	procs := top_level_procs(source.file, context.temp_allocator)
	testing.expect(t, len(procs) == 1)
	testing.expect_value(t, procs[0].name, "outer")
	testing.expect_value(t, procs[0].end_line, 6)
}

@(test)
style_baseline_allows_current_size_but_rejects_growth :: proc(t: ^testing.T) {
	source := strings.concatenate(
		{"package t\np :: proc() {\n", repeat_line("\tx := 1\n", 99), "}\n"},
		context.temp_allocator,
	)
	allowed: Int_Baseline
	defer delete(allowed)
	allowed["x:p"] = 101
	ok := style_run(source, allowed, "x")
	expect_lines(t, &ok, {})
	tight: Int_Baseline
	defer delete(tight)
	tight["x:p"] = 100
	report := style_run(source, tight, "x")
	expect_lines(t, &report, {2})
}

@(test)
style_direct_recursion_is_rejected_but_qualified_call_is_allowed :: proc(t: ^testing.T) {
	report := style_run("package t\np :: proc() {\n\tobject.p()\n\tp()\n}\n")
	expect_lines(t, &report, {4})
	testing.expect(t, report_has_message(&report, "direct recursion"))
}

@(test)
style_open_loop_requires_a_rationale_bearing_waiver :: proc(t: ^testing.T) {
	rejected := style_run("package t\np :: proc() {\n\tfor {\n\t}\n}\n")
	testing.expect(t, report_has_message(&rejected, "no structurally provable"))
	accepted := style_run(
		"package t\n" +
		"p :: proc() {\n" +
		"\t// tigerstyle: allow-unbounded-loop -- worker exits when stopped\n" +
		"\tfor {\n" +
		"\t}\n" +
		"}\n",
	)
	expect_lines(t, &accepted, {})
}

@(test)
style_bounded_loop_shapes_are_accepted :: proc(t: ^testing.T) {
	report := style_run(
		"package t\n" +
		"LIMIT :: 10\n" +
		"p :: proc(items: []int) {\n" +
		"\tfor item in items { _ = item }\n" +
		"\tfor index in 0 ..< LIMIT { _ = index }\n" +
		"\tfor index := 0; index < len(items); index += 1 { _ = items[index] }\n" +
		"}\n",
	)
	expect_lines(t, &report, {})
}

@(test)
style_condition_only_loop_and_empty_waiver_are_rejected :: proc(t: ^testing.T) {
	report := style_run(
		"package t\n" +
		"p :: proc(running: bool) {\n" +
		"\t// tigerstyle: allow-unbounded-loop --\n" +
		"\tfor running {\n" +
		"\t}\n" +
		"}\n",
	)
	expect_lines(t, &report, {3, 4})
}

@(test)
style_assert_condition_with_side_effecting_call_is_rejected :: proc(t: ^testing.T) {
	report := style_run(
		"package t\np :: proc(out: []u8) {\n\tassert(_to_rgba_into(out, nil, 1, 1, .R8))\n}\n",
	)
	expect_lines(t, &report, {3})
	testing.expect(t, report_has_message(&report, "'_to_rgba_into'"))
}

@(test)
style_multiline_and_qualified_assert_conditions_are_rejected :: proc(t: ^testing.T) {
	report := style_run(
		"package t\n" +
		"p :: proc() {\n" +
		"\tassert(\n" +
		"\t\tmesh.simplify_mesh(source, options, scratch),\n" +
		"\t\t\"generate failed\",\n" +
		"\t)\n" +
		"\tif ticket != 0 do assert_contextless(_submission_rollback(tracker, ticket))\n" +
		"}\n",
	)
	expect_lines(t, &report, {3, 7})
	testing.expect(t, report_has_message(&report, "'mesh.simplify_mesh'"))
	testing.expect(t, report_has_message(&report, "'_submission_rollback'"))
}

@(test)
style_pure_assert_conditions_are_accepted :: proc(t: ^testing.T) {
	report := style_run(
		"package t\n" +
		"p :: proc(items: []int, frame: ^Frame) {\n" +
		"\tassert(len(items) > 0 && u32(len(items)) < max(u32))\n" +
		"\tassert(text_metrics_valid(metrics), \"invalid: \" + describe(metrics))\n" +
		"\tassert(layout_kind(&u.layout) == .Row && is_ready(frame))\n" +
		"\tassert(prepared_capacity(&builder.prepared) == len(outputs))\n" +
		"\tuploaded := _stream_slot_upload(ctx, &ctx.rend)\n" +
		"\tassert(uploaded, \"upload failed\")\n" +
		"\t#assert(size_of(Node) == 16)\n" +
		"}\n",
	)
	expect_lines(t, &report, {})
}

@(test)
style_ensure_and_testing_expect_are_not_assert_calls :: proc(t: ^testing.T) {
	report := style_run(
		"package t\n" +
		"p :: proc(t: ^testing.T) {\n" +
		"\tensure(_submission_commit(tracker, ticket))\n" +
		"\ttesting.expect(t, _submission_commit(tracker, ticket))\n" +
		"\ttesting.expect_assert_message(t, \"x\")\n" +
		"}\n",
	)
	expect_lines(t, &report, {})
}

@(test)
style_assert_calls_in_comments_and_strings_are_ignored :: proc(t: ^testing.T) {
	report := style_run(
		"package t\n" +
		"p :: proc() {\n" +
		"\t// assert(_stream_slot_upload(ctx, &ctx.rend))\n" +
		"\tmessage := \"assert(_stream_slot_upload(ctx))\"\n" +
		"\t_ = message\n" +
		"}\n",
	)
	expect_lines(t, &report, {})
}

@(test)
style_assert_call_waiver_requires_a_rationale :: proc(t: ^testing.T) {
	accepted := style_run(
		"package t\n" +
		"p :: proc() {\n" +
		"\t// tigerstyle: allow-assert-call -- debug-only probe, skipped work is intended\n" +
		"\tassert(probe_counters(ctx))\n" +
		"}\n",
	)
	expect_lines(t, &accepted, {})
	rejected := style_run(
		"package t\n" +
		"p :: proc() {\n" +
		"\t// tigerstyle: allow-assert-call --\n" +
		"\tassert(probe_counters(ctx))\n" +
		"}\n",
	)
	expect_lines(t, &rejected, {4})
}

@(test)
style_pure_marker_allows_assert_call :: proc(t: ^testing.T) {
	report := style_run(
		"package t\n" +
		"// tigerstyle: pure\n" +
		"@(private)\n" +
		"slot_of :: proc(handle: u32) -> i32 {\n" +
		"\treturn i32(handle)\n" +
		"}\n" +
		"p :: proc(handle: u32) {\n" +
		"\tassert(slot_of(handle) >= 0)\n" +
		"}\n",
	)
	expect_lines(t, &report, {})
}

@(test)
style_unmarked_query_is_rejected_in_assert :: proc(t: ^testing.T) {
	report := style_run(
		"package t\n" +
		"slot_of :: proc(handle: u32) -> i32 {\n" +
		"\treturn i32(handle)\n" +
		"}\n" +
		"p :: proc(handle: u32) {\n" +
		"\tassert(slot_of(handle) >= 0)\n" +
		"}\n",
	)
	expect_lines(t, &report, {6})
	testing.expect(t, report_has_message(&report, "'slot_of'"))
}

@(test)
style_marker_from_another_file_is_honoured_through_the_index :: proc(t: ^testing.T) {
	declaring := style_source(
		"package t\n// tigerstyle: pure\nslot_of :: proc(handle: u32) -> i32 {\n\treturn 0\n}\n",
		"a.odin",
	)
	using_source := style_source(
		"package t\np :: proc(handle: u32) {\n\tassert(pkg.slot_of(handle) >= 0)\n}\n",
		"b.odin",
	)
	sources := [?]Source{declaring, using_source}
	context.allocator = context.temp_allocator
	index := style_build_purity_index(sources[:])
	report: Report
	style_check_source(&sources[1], nil, &index, &report)
	expect_lines(t, &report, {})
}

@(test)
style_dangling_pure_marker_is_reported :: proc(t: ^testing.T) {
	report := style_run("package t\n// tigerstyle: pure\nLIMIT :: 10\n")
	expect_lines(t, &report, {2})
	testing.expect(t, report_has_message(&report, "dangling pure marker"))
}

@(test)
style_pure_marked_proc_that_mutates_is_reported :: proc(t: ^testing.T) {
	report := style_run(
		"package t\n" +
		"// tigerstyle: pure\n" +
		"push :: proc(items: ^[dynamic]int, state: ^State) -> bool {\n" +
		"\tappend(items, 1)\n" +
		"\tstate.count += 1\n" +
		"\tstate.slots[0] = 2\n" +
		"\tlocal := state.count\n" +
		"\treturn local == state.count\n" +
		"}\n",
	)
	expect_lines(t, &report, {4, 5, 6})
	testing.expect(t, report_has_message(&report, "calls append"))
	testing.expect(t, report_has_message(&report, "writes through parameter state"))
}

@(test)
style_type_conversion_is_pure :: proc(t: ^testing.T) {
	report := style_run(
		"package t\n" +
		"Asset_Id :: distinct u32\n" +
		"Matrix :: matrix[4, 4]f32\n" +
		"p :: proc(raw: u32, m: [16]f32) {\n" +
		"\tassert(Asset_Id(raw) != 0 && Matrix(1) == Matrix(1))\n" +
		"}\n",
	)
	expect_lines(t, &report, {})
}

@(test)
style_external_pure_name_declared_in_tree_is_reported :: proc(t: ^testing.T) {
	report := style_run("package t\nto_string :: proc(value: int) -> string {\n\treturn \"\"\n}\n")
	expect_lines(t, &report, {2})
	testing.expect(t, report_has_message(&report, "EXTERNAL_PURE_NAMES"))
}
