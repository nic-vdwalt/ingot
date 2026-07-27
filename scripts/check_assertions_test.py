#!/usr/bin/env python3

import unittest

import check_assertions


class AssertionDisciplineTest(unittest.TestCase):
    def findings(self, source: str):
        return check_assertions.findings_for_source(source, "net/x.odin")

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

    def test_assert_and_ensure_count(self):
        for assertion in ("assert(queue != nil)", "ensure(queue != nil)"):
            source = f'''p :: proc(queue: ^Queue) {{
	{assertion}
	append(&queue.items, 1)
}}
'''
            self.assertEqual(self.findings(source), [])

    def test_compile_assert_does_not_hide_runtime_queue_risk(self):
        source = '''p :: proc(queue: ^Queue) {
	#assert(N > 0)
	append(&queue.items, 1)
}
'''
        self.assertIn("queue", self.findings(source)[0].risks)

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

    def test_cross_collection_index_in_bounded_loop_is_flagged(self):
        source = '''copy_items :: proc(source, destination: []Item) {
	for index in 0..<len(source) {
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
        self.assertIn("pointer", findings[0].risks)
        self.assertIn("index", findings[0].risks)

    def test_declarations_and_trivial_accessors_are_excluded(self):
        source = '''Callback :: #type proc(value: int) -> int
value :: proc() -> int {
	return 1
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
        self.assertEqual(risks, {"pointer", "index", "queue", "ownership", "state", "untrusted_input"})

    def test_operating_error_with_no_internal_risk_is_not_flagged(self):
        source = '''open_file :: proc(path: string) -> bool {
	if path == "" do return false
	return true
}
'''
        self.assertEqual(self.findings(source), [])

    def test_baseline_rejects_growth_and_stale_entries(self):
        finding = check_assertions.Finding("net/x.odin", "p", 1, ("queue",), 0)
        current = {finding.key: finding}
        self.assertEqual(check_assertions.check_findings(current, {finding.key: ["queue"]}), [])
        self.assertEqual(len(check_assertions.check_findings(current, {})), 1)
        self.assertEqual(len(check_assertions.check_findings({}, {finding.key: ["queue"]})), 1)

    def test_baseline_rejects_stale_risk_on_live_entry(self):
        finding = check_assertions.Finding("net/x.odin", "p", 1, ("index",), 0)
        failures = check_assertions.check_findings(
            {finding.key: finding}, {finding.key: ["index", "queue"]}
        )
        self.assertEqual(len(failures), 1)
        self.assertIn("queue", failures[0])

    def test_compound_assertion_is_one_check(self):
        masked = check_assertions.check_odin_style.mask_source(
            "p :: proc(a, b: bool) { assert(a && b) }"
        )
        self.assertEqual(len(check_assertions.ASSERTION.findall(masked)), 1)


if __name__ == "__main__":
    unittest.main()
