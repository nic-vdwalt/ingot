#!/usr/bin/env python3

import tempfile
import unittest
from pathlib import Path

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

    def test_controlled_global_routing_requires_exact_inventory(self):
        expected = check_gfx_context.CONTROLLED_GLOBAL_ROUTING.copy()
        self.assertEqual(check_gfx_context.controlled_global_debt(expected), {})
        expected["gfx/context.odin:default_context"] += 1
        self.assertEqual(
            check_gfx_context.controlled_global_debt(expected),
            {"gfx/context.odin:default_context": 2},
        )

    def test_test_source_suffixes_are_excluded(self):
        self.assertTrue("gfx/x_test.odin".endswith(check_gfx_context.EXCLUDED_SUFFIXES))
        self.assertTrue("gfx/x_tests.odin".endswith(check_gfx_context.EXCLUDED_SUFFIXES))
        self.assertTrue("gfx/x_fuzz_test.odin".endswith(check_gfx_context.EXCLUDED_SUFFIXES))


class PascalCaseLayerTest(unittest.TestCase):
    RAYLIB = frozenset({"DrawRectangle", "BeginMode3D", "RlLoadVertexArray"})

    def violations(self, source):
        return check_gfx_context.pascal_case_violations(source, "gfx/x.odin", self.RAYLIB)

    def test_raylib_named_facade_is_accepted(self):
        source = "DrawRectangle :: proc() {\n\tcontext_draw_rectangle(default_context())\n}\n"
        self.assertEqual(self.violations(source), [])

    def test_ingot_only_pascal_case_is_rejected(self):
        source = "SetFrameStrategy :: proc(s: Frame_Strategy) {\n\tx := s\n}\n"
        failures = self.violations(source)
        self.assertEqual(len(failures), 1)
        self.assertIn("gfx/x.odin:1: SetFrameStrategy", failures[0])
        self.assertIn("Ingot-only PascalCase API", failures[0])

    def test_deprecated_and_private_forwarders_are_accepted(self):
        source = (
            '@(deprecated = "use set_frame_strategy")\n'
            "SetFrameStrategy :: proc(s: Frame_Strategy) {\n\tset_frame_strategy(s)\n}\n"
            '@(private = "package")\n'
            "HelperThing :: proc() {\n}\n"
        )
        self.assertEqual(self.violations(source), [])

    def test_snake_case_and_types_are_ignored(self):
        source = (
            "set_frame_strategy :: proc(s: Frame_Strategy) {\n}\n"
            "Frame_Strategy :: enum u8 {\n\tContinuous,\n}\n"
        )
        self.assertEqual(self.violations(source), [])

    def test_procedure_type_is_not_a_procedure(self):
        source = "Run_Proc :: proc()\nRun_Callback :: struct {\n\tproc_: Run_Proc,\n}\n"
        self.assertEqual(self.violations(source), [])

    def test_file_private_sources_are_skipped(self):
        source = "#+private\npackage gfx\nSomething :: proc() {\n}\n"
        self.assertEqual(self.violations(source), [])

    def test_raylib_vocabulary_is_read_from_vendor_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            vendor = Path(directory)
            (vendor / "rlgl").mkdir()
            (vendor / "raylib.odin").write_text("DrawRectangle :: proc() ---\nColor :: struct {}\n")
            (vendor / "raymath.odin").write_text("Vector2Add :: proc() {}\n")
            (vendor / "rlgl" / "rlgl.odin").write_text("LoadVertexArray :: proc() -> u32 ---\n")
            names = check_gfx_context.raylib_names(vendor)
        self.assertIn("DrawRectangle", names)
        self.assertIn("Vector2Add", names)
        self.assertIn("RlLoadVertexArray", names)

    def test_missing_vendor_source_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(FileNotFoundError):
                check_gfx_context.raylib_names(Path(directory))


if __name__ == "__main__":
    unittest.main()
