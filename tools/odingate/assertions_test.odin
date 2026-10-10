#+build !js
package odingate

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Each test mirrors one case in scripts/check_assertions_test.py: the same
// inline procedures, the same expected risk sets. Sources gain a `package t`
// line because core:odin/parser needs one; nothing here asserts on lines.

@(private = "file")
assert_source :: proc(text: string, path := "ui/fixture.odin") -> Source {
	context.allocator = context.temp_allocator
	return parse_source(path, strings.concatenate({"package t\n", text}), nil)
}

@(private = "file")
assert_findings :: proc(text: string, path := "ui/fixture.odin") -> []Assert_Finding {
	context.allocator = context.temp_allocator
	source := assert_source(text, path)
	return assert_findings_for_source(&source)
}

@(private = "file")
assert_risks :: proc(text: string) -> Risk_Set {
	context.allocator = context.temp_allocator
	source := assert_source(text)
	procs := top_level_procs(source.file)
	if len(procs) == 0 do return {}
	body := proc_body(&source, procs[0])
	return assert_risks_for(&body)
}

@(private = "file")
first_risks :: proc(
	t: ^testing.T,
	findings: []Assert_Finding,
	loc := #caller_location,
) -> Risk_Set {
	testing.expectf(t, len(findings) > 0, "expected a finding, got none", loc = loc)
	if len(findings) == 0 do return {}
	return findings[0].risks
}

@(private = "file")
expect_clean :: proc(t: ^testing.T, findings: []Assert_Finding, loc := #caller_location) {
	testing.expectf(t, len(findings) == 0, "expected no findings, got %v", findings, loc = loc)
}

@(test)
assertions_findings_do_not_depend_on_the_source_path :: proc(t: ^testing.T) {
	source := "p :: proc(queue: ^Queue) {\n\tassert(queue != nil)\n\tappend(&queue.items, 1)\n}\n"
	reference := first_risks(t, assert_findings(source, "net/x.odin"))
	for path in ([?]string{"ui/fixture.odin", "gfx/other.odin"}) {
		testing.expect_value(t, first_risks(t, assert_findings(source, path)), reference)
	}
}

@(test)
assertions_comments_and_strings_do_not_count :: proc(t: ^testing.T) {
	findings := assert_findings(
		"p :: proc(queue: ^Queue) {\n" +
		"\t// assert(queue != nil)\n" +
		"\ttext := \"ensure(queue != nil)\"\n" +
		"\tappend(&queue.items, 1)\n" +
		"}\n",
	)
	testing.expect_value(t, len(findings), 1)
	testing.expect(t, .Queue in first_risks(t, findings))
}

@(test)
assertions_queue_pointer_check_does_not_cover_queue_mutation :: proc(t: ^testing.T) {
	for check in ([?]string{"assert(queue != nil)", "ensure(queue != nil)"}) {
		source := strings.concatenate(
			{"p :: proc(queue: ^Queue) {\n\t", check, "\n\tappend(&queue.items, 1)\n}\n"},
			context.temp_allocator,
		)
		testing.expect(t, .Queue in first_risks(t, assert_findings(source)))
	}
}

@(test)
assertions_queue_capacity_contract_covers_queue_mutation :: proc(t: ^testing.T) {
	expect_clean(
		t,
		assert_findings(
			"p :: proc(queue: ^Queue) {\n" +
			"\tassert(queue != nil)\n" +
			"\tassert(len(queue.items) < cap(queue.items))\n" +
			"\tappend(&queue.items, 1)\n" +
			"}\n",
		),
	)
}

@(test)
assertions_compile_assert_does_not_hide_runtime_queue_risk :: proc(t: ^testing.T) {
	findings := assert_findings(
		"p :: proc(queue: ^Queue) {\n\t#assert(N > 0)\n\tappend(&queue.items, 1)\n}\n",
	)
	testing.expect(t, .Queue in first_risks(t, findings))
}

@(test)
assertions_unrelated_assertion_does_not_hide_index_risk :: proc(t: ^testing.T) {
	findings := assert_findings(
		"p :: proc(queue: ^Queue, items: []Item, index: int) {\n" +
		"\tassert(queue != nil)\n" +
		"\tconsume(items[index])\n" +
		"}\n",
	)
	testing.expect_value(t, first_risks(t, findings), Risk_Set{.Index})
}

@(test)
assertions_signature_types_and_void_forwarding_are_not_risks :: proc(t: ^testing.T) {
	expect_clean(
		t,
		assert_findings(
			"draw :: proc(ctx: ^Context, points: []Point) {\n" +
			"\trender_line(ctx, points)\n" +
			"\trender_flush(ctx)\n" +
			"}\n",
		),
	)
}

@(test)
assertions_forwarder_with_queue_mutation_is_not_excluded :: proc(t: ^testing.T) {
	findings := assert_findings(
		"submit :: proc(ctx: ^Context, item: Item) {\n" +
		"\tappend(&ctx.queue, item)\n" +
		"\tplatform_submit(ctx)\n" +
		"}\n",
	)
	testing.expect(t, .Queue in first_risks(t, findings))
}

@(test)
assertions_same_collection_bounded_loop_is_excluded :: proc(t: ^testing.T) {
	expect_clean(
		t,
		assert_findings(
			"visit :: proc(items: []Item) {\n" +
			"\tfor index in 0..<len(items) {\n" +
			"\t\tconsume(items[index])\n" +
			"\t}\n" +
			"}\n",
		),
	)
}

@(test)
assertions_cross_collection_index_with_no_destination_bound_is_flagged :: proc(t: ^testing.T) {
	findings := assert_findings(
		"copy_item :: proc(source, destination: []Item, index: int) {\n" +
		"\tif index < len(source) {\n" +
		"\t\tdestination[index] = source[index]\n" +
		"\t}\n" +
		"}\n",
	)
	testing.expect(t, .Index in first_risks(t, findings))
}

@(test)
assertions_guarded_callback_payload_index_remains_flagged :: proc(t: ^testing.T) {
	findings := assert_findings(
		"on_payload :: proc(user_data: rawptr, payload: []u8, offset: int) {\n" +
		"\tif user_data == nil do return\n" +
		"\tctx := transmute(^Context)user_data\n" +
		"\tdispatch_byte(ctx, payload[offset])\n" +
		"}\n",
	)
	risks := first_risks(t, findings)
	testing.expect(t, .Pointer not_in risks)
	testing.expect(t, .Index in risks)
}

@(test)
assertions_declarations_and_trivial_accessors_are_excluded :: proc(t: ^testing.T) {
	expect_clean(
		t,
		assert_findings(
			"Callback :: #type proc(value: int) -> int\nvalue :: proc() -> int {\n\treturn 1\n}\n",
		),
	)
}

@(test)
assertions_empty_pointer_stub_is_excluded :: proc(t: ^testing.T) {
	expect_clean(t, assert_findings("platform_noop :: proc(ctx: ^Context) {}\n"))
}

@(test)
assertions_pointer_stub_with_mutation_is_not_excluded :: proc(t: ^testing.T) {
	findings := assert_findings(
		"platform_mutate :: proc(ctx: ^Context) {\n\tctx.ready = true\n}\n",
	)
	testing.expect(t, .Pointer in first_risks(t, findings))
}

@(test)
assertions_return_short_circuit_proves_pointer_is_non_nil :: proc(t: ^testing.T) {
	expect_clean(
		t,
		assert_findings(
			"available :: proc(ctx: ^Context) -> bool {\n\treturn ctx != nil && ctx.ready\n}\n",
		),
	)
}

@(test)
assertions_risk_categories_are_detected :: proc(t: ^testing.T) {
	findings := assert_findings(
		"p :: proc(state: ^State, payload: []u8) {\n" +
		"\tctx := transmute(^State)raw_data(payload)\n" +
		"\titem := payload[state.head]\n" +
		"\tappend(&state.queue, item)\n" +
		"\tcopy := clone(payload)\n" +
		"\tstate.running = false\n" +
		"\tread_payload(ctx)\n" +
		"\tdelete(copy)\n" +
		"}\n",
	)
	testing.expect_value(
		t,
		first_risks(t, findings),
		Risk_Set{.Pointer, .Index, .Queue, .Ownership, .State},
	)
}

@(test)
assertions_operating_error_with_no_internal_risk_is_not_flagged :: proc(t: ^testing.T) {
	expect_clean(
		t,
		assert_findings(
			"open_file :: proc(path: string) -> bool {\n" +
			"\tif path == \"\" do return false\n" +
			"\treturn true\n" +
			"}\n",
		),
	)
}

@(test)
assertions_zero_debt_check_rejects_every_current_finding :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	report: Report
	assert_check_findings({{"ui/fixture.odin", "p", 1, {.Queue}}}, nil, false, &report)
	testing.expect_value(t, len(report.findings), 1)
	testing.expect(t, report_has_message(&report, "queue"))
}

@(test)
assertions_zero_debt_check_accepts_an_empty_measurement :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	report: Report
	assert_check_findings({}, nil, false, &report)
	testing.expect_value(t, len(report.findings), 0)
}

@(test)
assertions_comma_ok_map_lookup_is_not_an_index_risk :: proc(t: ^testing.T) {
	source :=
		"obj_string :: proc(obj: json.Object, key: string) -> (string, bool) {\n" +
		"\tif v, has := obj[key]; has {\n" +
		"\t\tif s, is_s := v.(string); is_s do return s, true\n" +
		"\t}\n" +
		"\treturn \"\", false\n" +
		"}\n"
	testing.expect(t, .Index not_in assert_risks(source))
	expect_clean(t, assert_findings(source))
}

@(test)
assertions_ordinary_array_index_is_still_an_index_risk :: proc(t: ^testing.T) {
	testing.expect(
		t,
		.Index in assert_risks("p :: proc(xs: []int, i: int) -> int {\n\treturn xs[i]\n}\n"),
	)
}

@(test)
assertions_masking_preserves_offsets :: proc(t: ^testing.T) {
	source := "\tif v, ok := m[key]; ok do use(v)\n\tvalue := xs[i]\n"
	masked := assert_mask_map_lookups(source, context.temp_allocator)
	testing.expect_value(t, len(masked), len(source))
	testing.expect(t, !strings.contains(masked, "[key]"))
	testing.expect(t, strings.contains(masked, "[i]"))
}

@(test)
assertions_map_lookup_does_not_hide_a_later_array_index :: proc(t: ^testing.T) {
	source :=
		"p :: proc(m: map[string]int, xs: []int, k: string, i: int) -> int {\n" +
		"\tif v, ok := m[k]; ok do return v\n" +
		"\treturn xs[i]\n" +
		"}\n"
	testing.expect(t, .Index in assert_risks(source))
}

@(test)
assertions_auto_dereferenced_pointer_parameter_without_contract_is_flagged :: proc(t: ^testing.T) {
	source := "p :: proc(panel: ^Panel) {\n\tpanel.x = 4\n\tuse(panel.ctx)\n}\n"
	testing.expect(t, .Pointer in assert_risks(source))
	findings := assert_findings(source, "ui/x.odin")
	testing.expect_value(t, len(findings), 1)
	testing.expect_value(t, first_risks(t, findings), Risk_Set{.Pointer})
}

@(test)
assertions_nil_assertion_discharges_the_contract :: proc(t: ^testing.T) {
	expect_clean(
		t,
		assert_findings(
			"p :: proc(panel: ^Panel) {\n" +
			"\tassert(panel != nil)\n" +
			"\tpanel.x = 4\n" +
			"\tuse(panel.ctx)\n" +
			"}\n",
			"ui/x.odin",
		),
	)
}

@(test)
assertions_nil_guard_discharges_the_contract :: proc(t: ^testing.T) {
	expect_clean(
		t,
		assert_findings(
			"p :: proc(panel: ^Panel) {\n" +
			"\tif panel == nil do return\n" +
			"\tpanel.x = 4\n" +
			"\tuse(panel.ctx)\n" +
			"}\n",
			"ui/x.odin",
		),
	)
}

@(test)
assertions_grouped_parameters_all_carry_the_risk :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	source := assert_source(
		"p :: proc(a, b: ^Panel) {\n\ta.x = 1\n\tb.x = 2\n\tuse(a)\n}\n",
		"ui/x.odin",
	)
	procs := top_level_procs(source.file)
	testing.expect_value(t, len(procs), 1)
	names := assert_pointer_parameter_names(procs[0].lit)
	testing.expect_value(t, len(names), 2)
	if len(names) == 2 {
		testing.expect_value(t, names[0], "a")
		testing.expect_value(t, names[1], "b")
	}
	findings := assert_findings_for_source(&source)
	testing.expect_value(t, len(findings), 1)
	testing.expect_value(t, first_risks(t, findings), Risk_Set{.Pointer})
}

@(test)
assertions_pointer_return_type_is_not_a_parameter_risk :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	source := assert_source(
		"p :: proc(n: int) -> ^Foo {\n\tuse(n)\n\treturn nil\n}\n",
		"ui/x.odin",
	)
	procs := top_level_procs(source.file)
	testing.expect_value(t, len(procs), 1)
	testing.expect_value(t, len(assert_pointer_parameter_names(procs[0].lit)), 0)
	expect_clean(t, assert_findings_for_source(&source))
}

@(test)
assertions_value_parameters_carry_no_pointer_risk :: proc(t: ^testing.T) {
	testing.expect(
		t,
		.Pointer not_in
		assert_risks("p :: proc(n: int, m: int) {\n\tuse(n)\n\tuse(m)\n\tuse(n + m)\n}\n"),
	)
}

@(test)
assertions_default_scope_sees_only_ingot_packages :: proc(t: ^testing.T) {
	files := [?]string{"ui/a.odin", "client/src/b.odin", "client/src/b_test.odin"}
	kept := filter_paths(
		files[:],
		ASSERT_PACKAGES[:],
		ASSERT_EXCLUDED_PREFIXES[:],
		ASSERT_EXCLUDED_SUFFIXES[:],
	)
	defer delete(kept)
	testing.expect_value(t, len(kept), 1)
	if len(kept) == 1 do testing.expect_value(t, kept[0], "ui/a.odin")
}

@(test)
assertions_explicit_packages_replace_the_default :: proc(t: ^testing.T) {
	files := [?]string{"ui/a.odin", "client/src/b.odin", "client/src/b_test.odin"}
	kept := filter_paths(
		files[:],
		{"client/src/"},
		ASSERT_EXCLUDED_PREFIXES[:],
		ASSERT_EXCLUDED_SUFFIXES[:],
	)
	defer delete(kept)
	testing.expect_value(t, len(kept), 1)
	if len(kept) == 1 do testing.expect_value(t, kept[0], "client/src/b.odin")
}

@(test)
assertions_explicit_packages_still_exclude_test_sources :: proc(t: ^testing.T) {
	files := [?]string{"ui/a.odin", "client/src/b.odin", "client/src/b_test.odin"}
	kept := filter_paths(
		files[:],
		{"client/"},
		ASSERT_EXCLUDED_PREFIXES[:],
		ASSERT_EXCLUDED_SUFFIXES[:],
	)
	defer delete(kept)
	for path in kept do testing.expect(t, path != "client/src/b_test.odin")
}

@(test)
assertions_assert_contextless_counts_as_an_assertion :: proc(t: ^testing.T) {
	expect_clean(
		t,
		assert_findings(
			"p :: proc \"contextless\" (inp: ^Input, value: rune) {\n" +
			"\tif inp == nil do return\n" +
			"\tassert_contextless(inp.tail >= 0 && inp.tail < CHAR_Q, \"p: bad tail\")\n" +
			"\tinp.queue[inp.tail] = value\n" +
			"}\n",
			"gfx/fixture.odin",
		),
	)
}

@(test)
assertions_assert_contextless_is_not_confused_with_bare_assert :: proc(t: ^testing.T) {
	findings := assert_findings(
		"p :: proc \"contextless\" (inp: ^Input, value: rune) {\n" +
		"\tif inp == nil do return\n" +
		"\tinp.queue[inp.tail] = value\n" +
		"}\n",
		"gfx/fixture.odin",
	)
	found := false
	for finding in findings do if .Index in finding.risks do found = true
	testing.expect(t, found)
}

@(test)
assertions_without_baseline_every_finding_fails :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	report: Report
	assert_check_findings({{"src/a.odin", "p", 1, {.Index}}}, nil, false, &report)
	lines := report_messages(&report)
	testing.expect_value(t, len(lines), 1)
	if len(lines) == 1 {
		expected := "src/a.odin:p: uncovered assertion risks: index"
		testing.expect_value(t, lines[0], expected)
	}
}

@(test)
assertions_recorded_debt_passes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	baseline: List_Baseline
	baseline["src/a.odin:p"] = {"index"}
	report: Report
	assert_check_findings({{"src/a.odin", "p", 1, {.Index}}}, baseline, true, &report)
	testing.expect_value(t, len(report.findings), 0)
}

@(test)
assertions_new_risk_fails :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	baseline: List_Baseline
	baseline["src/a.odin:p"] = {"index"}
	report: Report
	assert_check_findings({{"src/a.odin", "p", 1, {.Index, .Queue}}}, baseline, true, &report)
	lines := report_messages(&report)
	testing.expect_value(t, len(lines), 1)
	if len(lines) == 1 {
		expected := "src/a.odin:p: uncovered assertion risks added: queue"
		testing.expect_value(t, lines[0], expected)
	}
}

@(test)
assertions_paid_debt_must_leave_the_baseline :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	baseline: List_Baseline
	baseline["src/a.odin:p"] = {"index"}
	report: Report
	assert_check_findings({}, baseline, true, &report)
	lines := report_messages(&report)
	testing.expect_value(t, len(lines), 1)
	if len(lines) == 1 {
		expected := "src/a.odin:p: stale assertion baseline entry; remove it"
		testing.expect_value(t, lines[0], expected)
	}
}

@(test)
assertions_baseline_rejects_unknown_risks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	baseline: List_Baseline
	baseline["src/a.odin:p"] = {"indx"}
	testing.expect(t, !assert_validate_baseline(baseline))
	baseline["src/a.odin:p"] = {"index"}
	testing.expect(t, assert_validate_baseline(baseline))
}

// term_pump is the documented worked example of assertion discipline
// (AGENTS.md); the rule must find nothing to say about it.
@(test)
assertions_worked_example_is_clean :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := odingate_repo_root()
	path, join_err := filepath.join({root, "term/term_pump.odin"})
	testing.expect(t, join_err == nil)
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		testing.expectf(t, false, "cannot read %s: %v", path, read_err)
		return
	}
	source := parse_source("term/term_pump.odin", string(data), nil)
	testing.expect(t, source.parse_ok)
	expect_clean(t, assert_findings_for_source(&source))
}

// odingate_repo_root resolves the repository root from this file's location
// so tests do not depend on the working directory.
odingate_repo_root :: proc() -> string {
	here := #directory
	joined, err := filepath.join({here, "..", ".."}, context.temp_allocator)
	if err != nil do return here
	cleaned, clean_err := filepath.clean(joined, context.temp_allocator)
	if clean_err != nil do return here
	return cleaned
}
