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
	ctx := g
}
'''
        self.assertEqual(
            check_gfx_context.counts_for_source(source, "gfx/x.odin"),
            {"gfx/x.odin:first": 2, "gfx/x.odin:second": 1},
        )

    def test_qualified_context_identifier_is_not_global_routing(self):
        source = '''callback :: proc() {
	context = runtime.default_context()
}
'''
        self.assertEqual(check_gfx_context.counts_for_source(source, "gfx/x.odin"), {})
        self.assertEqual(check_gfx_context.default_context_debt_for_source(source, "gfx/x.odin"), {})

    def test_rejects_default_context_inside_implementation(self):
        source = '''context_draw :: proc(ctx: ^Context) {}
helper :: proc() {
	context_draw(default_context())
}
'''
        self.assertEqual(
            check_gfx_context.default_context_debt_for_source(source, "gfx/x.odin"),
            {"gfx/x.odin:helper": 1},
        )

    def test_accepts_thin_pascal_case_default_context_wrapper(self):
        source = '''Draw :: proc() {
	context_draw(default_context())
}
'''
        self.assertEqual(check_gfx_context.default_context_debt_for_source(source, "gfx/x.odin"), {})

    def test_accepts_thin_legacy_facade_wrapper(self):
        source = '''stats :: proc() -> Stats {
	return context_renderer_stats(default_context())
}
'''
        self.assertEqual(check_gfx_context.default_context_debt_for_source(source, "gfx/x.odin"), {})

    def test_rejects_renderer_internal_default_context(self):
        source = '''renderer_flush :: proc(r: ^Renderer) {
	flush(default_context(), r)
}
'''
        self.assertEqual(
            check_gfx_context.default_context_debt_for_source(source, "gfx/x.odin"),
            {"gfx/x.odin:renderer_flush": 1},
        )

    def test_rejects_control_flow_facade_escape(self):
        source = '''Draw :: proc() {
	if ready {
		context_draw(default_context())
	}
}
'''
        self.assertEqual(
            check_gfx_context.default_context_debt_for_source(source, "gfx/x.odin"),
            {"gfx/x.odin:Draw": 1},
        )

    def test_rejects_active_context_symbols(self):
        source = '''first :: proc() {
	ctx := active_context()
}
second :: proc() {
	previous := _context_activate(ctx)
	_context_restore(previous)
}
'''
        self.assertEqual(
            check_gfx_context.counts_for_source(
                source,
                "gfx/x.odin",
                check_gfx_context.ACTIVE_CONTEXT,
            ),
            {"gfx/x.odin:first": 1, "gfx/x.odin:second": 2},
        )

    def test_rejects_context_scope_symbols(self):
        source = '''first :: proc() -> Context_Scope {
	return context_scope_enter(ctx)
}
second :: proc(scope: ^Context_Scope) {
	context_scope_leave(scope)
}
'''
        self.assertEqual(
            check_gfx_context.counts_for_source(
                source,
                "gfx/x.odin",
                check_gfx_context.ACTIVE_CONTEXT,
            ),
            {"gfx/x.odin:first": 2, "gfx/x.odin:second": 2},
        )

    def test_rejects_implicit_ui_gfx_drawing(self):
        source = '''paint :: proc() {
	BeginDrawing()
	DrawText("x", 0, 0, 12, WHITE)
	EndDrawing()
}
'''
        self.assertEqual(
            check_gfx_context.counts_for_source(
                source,
                "ui_gfx/x.odin",
                check_gfx_context.UI_GFX_IMPLICIT_DRAW,
            ),
            {"ui_gfx/x.odin:paint": 3},
        )

    def test_zero_debt_failures_require_empty_results(self):
        self.assertEqual(check_gfx_context.zero_debt_failures("debt", {}), [])
        self.assertEqual(
            check_gfx_context.zero_debt_failures("debt", {"gfx/x.odin:p": 2}),
            ["gfx/x.odin:p: debt is forbidden (2 references)"],
        )

    def test_test_source_suffixes_are_excluded(self):
        self.assertTrue("gfx/x_test.odin".endswith(check_gfx_context.EXCLUDED_SUFFIXES))
        self.assertTrue("gfx/x_tests.odin".endswith(check_gfx_context.EXCLUDED_SUFFIXES))
        self.assertTrue("gfx/x_fuzz_test.odin".endswith(check_gfx_context.EXCLUDED_SUFFIXES))


if __name__ == "__main__":
    unittest.main()
