#!/usr/bin/env python3

import pathlib
import shutil
import subprocess
import tempfile
import unittest

import check_assertions


class AssertionDisciplineTest(unittest.TestCase):
    # An ordinary source path. This used to be "net/x.odin", which two
    # exclusions special-cased by name - so the suite exercised a branch
    # production never took, and the loosest rules in the gate went untested.
    FIXTURE_PATH = "ui/fixture.odin"

    def findings(self, source: str):
        return check_assertions.findings_for_source(source, self.FIXTURE_PATH)

    def test_findings_do_not_depend_on_the_source_path(self):
        # No path may be privileged: a gate that reports differently depending
        # on which file it is reading is not a gate.
        source = '''p :: proc(queue: ^Queue) {
	assert(queue != nil)
	append(&queue.items, 1)
}
'''
        risks = {
            path: tuple(f.risks for f in check_assertions.findings_for_source(source, path))
            for path in ("net/x.odin", "ui/fixture.odin", "gfx/other.odin")
        }
        self.assertEqual(len(set(risks.values())), 1, risks)

    def test_comments_and_strings_do_not_count_as_assertions(self):
        source = '''p :: proc(queue: ^Queue) {
	// assert(queue != nil)
	text := "ensure(queue != nil)"
	append(&queue.items, 1)
}
'''
        findings = self.findings(source)
        self.assertEqual(len(findings), 1)
        self.assertIn("queue", findings[0].risks)

    def test_queue_pointer_check_does_not_cover_queue_mutation(self):
        for assertion in ("assert(queue != nil)", "ensure(queue != nil)"):
            source = f'''p :: proc(queue: ^Queue) {{
	{assertion}
	append(&queue.items, 1)
}}
'''
            self.assertIn("queue", self.findings(source)[0].risks)

    def test_queue_capacity_contract_covers_queue_mutation(self):
        source = '''p :: proc(queue: ^Queue) {
	assert(queue != nil)
	assert(len(queue.items) < cap(queue.items))
	append(&queue.items, 1)
}
'''
        self.assertEqual(self.findings(source), [])

    def test_compile_assert_does_not_hide_runtime_queue_risk(self):
        source = '''p :: proc(queue: ^Queue) {
	#assert(N > 0)
	append(&queue.items, 1)
}
'''
        self.assertIn("queue", self.findings(source)[0].risks)

    def test_unrelated_assertion_does_not_hide_index_risk(self):
        source = '''p :: proc(queue: ^Queue, items: []Item, index: int) {
	assert(queue != nil)
	consume(items[index])
}
'''
        findings = self.findings(source)
        self.assertEqual(findings[0].risks, ("index",))

    def test_signature_types_and_void_forwarding_are_not_risks(self):
        source = '''draw :: proc(context: ^Context, points: []Point) {
	render_line(context, points)
	render_flush(context)
}
'''
        self.assertEqual(self.findings(source), [])

    def test_forwarder_with_queue_mutation_is_not_excluded(self):
        source = '''submit :: proc(context: ^Context, item: Item) {
	append(&context.queue, item)
	platform_submit(context)
}
'''
        self.assertIn("queue", self.findings(source)[0].risks)

    def test_same_collection_bounded_loop_is_excluded(self):
        source = '''visit :: proc(items: []Item) {
	for index in 0..<len(items) {
		consume(items[index])
	}
}
'''
        self.assertEqual(self.findings(source), [])

    def test_cross_collection_index_with_no_destination_bound_is_flagged(self):
        source = '''copy_item :: proc(source, destination: []Item, index: int) {
	if index < len(source) {
		destination[index] = source[index]
	}
}
'''
        self.assertIn("index", self.findings(source)[0].risks)

    def test_guarded_callback_payload_index_remains_flagged(self):
        source = '''on_payload :: proc(user_data: rawptr, payload: []u8, offset: int) {
	if user_data == nil do return
	context := transmute(^Context)user_data
	dispatch_byte(context, payload[offset])
}
'''
        findings = self.findings(source)
        self.assertNotIn("pointer", findings[0].risks)
        self.assertIn("index", findings[0].risks)

    def test_declarations_and_trivial_accessors_are_excluded(self):
        source = '''Callback :: #type proc(value: int) -> int
value :: proc() -> int {
	return 1
}
'''
        self.assertEqual(self.findings(source), [])

    def test_empty_pointer_stub_is_excluded(self):
        source = '''platform_noop :: proc(context: ^Context) {}
'''
        self.assertEqual(self.findings(source), [])

    def test_pointer_stub_with_mutation_is_not_excluded(self):
        source = '''platform_mutate :: proc(context: ^Context) {
	context.ready = true
}
'''
        self.assertIn("pointer", self.findings(source)[0].risks)

    def test_return_short_circuit_proves_pointer_is_non_nil(self):
        source = '''available :: proc(context: ^Context) -> bool {
	return context != nil && context.ready
}
'''
        self.assertEqual(self.findings(source), [])

    def test_risk_categories_are_detected(self):
        source = '''p :: proc(state: ^State, payload: []u8) {
	context := transmute(^State)raw_data(payload)
	item := payload[state.head]
	append(&state.queue, item)
	copy := clone(payload)
	state.running = false
	read_payload(context)
	delete(copy)
}
'''
        risks = set(self.findings(source)[0].risks)
        self.assertEqual(risks, {"pointer", "index", "queue", "ownership", "state"})

    def test_operating_error_with_no_internal_risk_is_not_flagged(self):
        source = '''open_file :: proc(path: string) -> bool {
	if path == "" do return false
	return true
}
'''
        self.assertEqual(self.findings(source), [])

    def test_baseline_rejects_growth_and_stale_entries(self):
        finding = check_assertions.Finding("ui/fixture.odin", "p", 1, ("queue",), 0)
        current = {finding.key: finding}
        self.assertEqual(check_assertions.check_findings(current, {finding.key: ["queue"]}), [])
        self.assertEqual(len(check_assertions.check_findings(current, {})), 1)
        self.assertEqual(len(check_assertions.check_findings({}, {finding.key: ["queue"]})), 1)

    def test_baseline_rejects_stale_risk_on_live_entry(self):
        finding = check_assertions.Finding("ui/fixture.odin", "p", 1, ("index",), 0)
        failures = check_assertions.check_findings(
            {finding.key: finding}, {finding.key: ["index", "queue"]}
        )
        self.assertEqual(len(failures), 1)
        self.assertIn("queue", failures[0])

    def test_empty_baseline_rejects_complete_current_findings(self):
        finding = check_assertions.Finding("ui/fixture.odin", "new", 2, ("index",), 0)
        self.assertEqual(len(check_assertions.check_findings({finding.key: finding}, {})), 1)

    def test_measurement_includes_complete_current_findings(self):
        old = check_assertions.Finding("ui/fixture.odin", "old", 1, ("index",), 0)
        new = check_assertions.Finding("ui/fixture.odin", "new", 2, ("queue",), 0)
        result = check_assertions.measurement({old.key: old, new.key: new})
        self.assertEqual(result["uncovered"], 2)
        self.assertEqual(result["by_risk"], {"index": 1, "queue": 1})

    def test_compound_assertion_is_one_check(self):
        masked = check_assertions.check_odin_style.mask_source(
            "p :: proc(a, b: bool) { assert(a && b) }"
        )
        self.assertEqual(len(check_assertions.ASSERTION.findall(masked)), 1)


class MapLookupTest(unittest.TestCase):
    """A comma-ok map lookup is not an array index.

    Odin has no comma-ok indexing form for arrays or slices, so `v, ok := m[k]`
    is unambiguously a map lookup: total over the key domain, already reporting
    a miss through `ok`. Flagging it would demand a tautological assertion,
    which TIGER_STYLE.md forbids by name.
    """

    def test_comma_ok_map_lookup_is_not_an_index_risk(self):
        source = '''obj_string :: proc(obj: json.Object, key: string) -> (string, bool) {
	if v, has := obj[key]; has {
		if s, is_s := v.(string); is_s do return s, true
	}
	return "", false
}
'''
        self.assertNotIn("index", check_assertions.risks_for(source))
        self.assertEqual(check_assertions.findings_for_source(source, "ui/fixture.odin"), [])

    def test_ordinary_array_index_is_still_an_index_risk(self):
        source = '''p :: proc(xs: []int, i: int) -> int {
	return xs[i]
}
'''
        self.assertIn("index", check_assertions.risks_for(source))

    def test_masking_preserves_offsets(self):
        # Callers slice the original text by an operation's offset, so a mask
        # that shifted characters would silently corrupt every prefix analysis.
        source = "\tif v, ok := m[key]; ok do use(v)\n\tvalue := xs[i]\n"
        masked = check_assertions.mask_map_lookups(source)
        self.assertEqual(len(masked), len(source))
        self.assertNotIn("[key]", masked)
        self.assertIn("[i]", masked)

    def test_map_lookup_does_not_hide_a_later_array_index(self):
        source = '''p :: proc(m: map[string]int, xs: []int, k: string, i: int) -> int {
	if v, ok := m[k]; ok do return v
	return xs[i]
}
'''
        self.assertIn("index", check_assertions.risks_for(source))


class PointerParameterTest(unittest.TestCase):
    """A ^T parameter is a pointer risk even with no `^` in the body.

    Odin auto-dereferences field access, so a procedure taking ^T and reading
    `t.field` contains no dereference token at all. Matching only an explicit
    `x^` missed the most common pointer shape in the codebase - and let a
    deleted `assert(panel != nil)` pass the gate unnoticed.
    """

    def findings(self, source: str):
        return check_assertions.findings_for_source(source, "ui/x.odin")

    def test_auto_dereferenced_pointer_parameter_without_contract_is_flagged(self):
        source = '''p :: proc(panel: ^Panel) {
	panel.x = 4
	use(panel.ctx)
}
'''
        self.assertIn("pointer", check_assertions.risks_for(source))
        self.assertEqual([f.risks for f in self.findings(source)], [("pointer",)])

    def test_nil_assertion_discharges_the_contract(self):
        source = '''p :: proc(panel: ^Panel) {
	assert(panel != nil)
	panel.x = 4
	use(panel.ctx)
}
'''
        self.assertEqual(self.findings(source), [])

    def test_nil_guard_discharges_the_contract(self):
        source = '''p :: proc(panel: ^Panel) {
	if panel == nil do return
	panel.x = 4
	use(panel.ctx)
}
'''
        self.assertEqual(self.findings(source), [])

    def test_grouped_parameters_all_carry_the_risk(self):
        # Odin's `a, b: ^T` states the type once for the whole group.
        source = '''p :: proc(a, b: ^Panel) {
	a.x = 1
	b.x = 2
	use(a)
}
'''
        self.assertEqual(check_assertions.pointer_parameter_names(source), ("a", "b"))
        self.assertEqual([f.risks for f in self.findings(source)], [("pointer",)])

    def test_pointer_return_type_is_not_a_parameter_risk(self):
        source = '''p :: proc(n: int) -> ^Foo {
	use(n)
	return nil
}
'''
        self.assertEqual(check_assertions.pointer_parameter_names(source), ())
        self.assertEqual(self.findings(source), [])

    def test_value_parameters_carry_no_pointer_risk(self):
        source = '''p :: proc(n: int, m: int) {
	use(n)
	use(m)
	use(n + m)
}
'''
        self.assertNotIn("pointer", check_assertions.risks_for(source))


class PackageSelectionTest(unittest.TestCase):
    """The gate's rules are not ingot-specific; only its default scope is.

    A consumer repository (the scout client, say) keeps its Odin under a path
    ingot has never heard of. Without a way to name that path the gate silently
    scans nothing and reports a clean bill of health, which is worse than not
    running it at all.
    """

    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        for relative in ("ui/a.odin", "client/src/b.odin", "client/src/b_test.odin"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("p :: proc() {}" + chr(10), encoding="utf-8")
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True)

    def test_default_scope_sees_only_ingot_packages(self):
        self.assertEqual(check_assertions.tracked_sources(self.root), ["ui/a.odin"])

    def test_explicit_packages_replace_the_default(self):
        self.assertEqual(
            check_assertions.tracked_sources(self.root, ("client/src/",)),
            ["client/src/b.odin"],
        )

    def test_explicit_packages_still_exclude_test_sources(self):
        sources = check_assertions.tracked_sources(self.root, ("client/",))
        self.assertNotIn("client/src/b_test.odin", sources)


if __name__ == "__main__":
    unittest.main()


class ContextlessAssertionTest(unittest.TestCase):
    # assert_contextless is the only assertion form available inside a
    # `proc "contextless"`, which is what every platform event callback must
    # be. A gate that recognised only `assert` pushed those callbacks into the
    # baseline as permanent debt, or worse, invited moving the contract to a
    # caller that cannot enforce it. \bassert\b never matches inside
    # assert_contextless, so this needed to be spelled out explicitly.
    FIXTURE_PATH = "gfx/fixture.odin"

    def findings(self, source: str):
        return check_assertions.findings_for_source(source, self.FIXTURE_PATH)

    def test_assert_contextless_counts_as_an_assertion(self):
        source = '''p :: proc "contextless" (inp: ^Input, value: rune) {
	if inp == nil do return
	assert_contextless(inp.tail >= 0 && inp.tail < CHAR_Q, "p: bad tail")
	inp.queue[inp.tail] = value
}
'''
        findings = self.findings(source)
        self.assertEqual(findings, [], findings)

    def test_assert_contextless_is_not_confused_with_bare_assert(self):
        # The alternation must not let the shorter token win and leave the
        # index risk uncovered.
        source = '''p :: proc "contextless" (inp: ^Input, value: rune) {
	if inp == nil do return
	inp.queue[inp.tail] = value
}
'''
        findings = self.findings(source)
        self.assertTrue(any("index" in f.risks for f in findings), findings)


if __name__ == "__main__":
    unittest.main()
