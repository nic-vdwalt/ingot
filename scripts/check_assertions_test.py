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

    def test_assert_ensure_and_compile_assert_count(self):
        for assertion in ("assert(queue != nil)", "ensure(queue != nil)", "#assert(N > 0)"):
            source = f'''p :: proc(queue: ^Queue) {{
	{assertion}
	append(&queue.items, 1)
}}
'''
            self.assertEqual(self.findings(source), [])

    def test_declarations_and_trivial_accessors_are_excluded(self):
        source = '''Callback :: #type proc(value: int) -> int
value :: proc() -> int {
	return 1
}
'''
        self.assertEqual(self.findings(source), [])

    def test_risk_categories_are_detected(self):
        source = '''p :: proc(state: ^State, payload: []u8) {
	item := payload[state.head]
	append(&state.queue, item)
	copy := clone(payload)
	state.running = false
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

    def test_compound_assertion_is_one_check(self):
        masked = check_assertions.check_odin_style.mask_source(
            "p :: proc(a, b: bool) { assert(a && b) }"
        )
        self.assertEqual(len(check_assertions.ASSERTION.findall(masked)), 1)


if __name__ == "__main__":
    unittest.main()
