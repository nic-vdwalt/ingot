#!/usr/bin/env python3

import unittest

import check_gfx_context


class GfxContextGuardTest(unittest.TestCase):
    def test_comments_strings_and_similar_identifiers_are_ignored(self):
        source = '''p :: proc() {
	// g.frame
	text := "g.frame"
	global := 1
}
'''
        self.assertEqual(check_gfx_context.counts_for_source(source, "gfx/x.odin"), {})

    def test_direct_global_references_are_counted_by_procedure(self):
        source = '''first :: proc() {
	g.frame.has_frame = true
	g.rend = {}
}
second :: proc() {
	ctx := &g
}
'''
        self.assertEqual(
            check_gfx_context.counts_for_source(source, "gfx/x.odin"),
            {"gfx/x.odin:first": 2, "gfx/x.odin:second": 1},
        )

    def test_context_escapes_are_counted_by_procedure(self):
        source = '''first :: proc() {
	ctx := default_context()
}
second :: proc() {
	scope := context_scope_enter(ctx)
}
'''
        self.assertEqual(
            check_gfx_context.counts_for_source(
                source,
                "ui_gfx/x.odin",
                check_gfx_context.CONTEXT_ESCAPE,
            ),
            {"ui_gfx/x.odin:first": 1, "ui_gfx/x.odin:second": 1},
        )

    def test_baseline_rejects_growth_and_stale_entries(self):
        current = {"gfx/x.odin:p": 2}
        self.assertEqual(check_gfx_context.check_counts(current, {"gfx/x.odin:p": 2}), [])
        self.assertEqual(len(check_gfx_context.check_counts(current, {"gfx/x.odin:p": 1})), 1)
        self.assertEqual(len(check_gfx_context.check_counts({}, {"gfx/x.odin:p": 1})), 1)


if __name__ == "__main__":
    unittest.main()
