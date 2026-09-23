#!/usr/bin/env python3

import unittest

import check_odin_style


class OdinStyleTest(unittest.TestCase):
    def test_line_limit_accepts_100_and_rejects_101(self):
        source = ("x" * 100) + "\n" + ("x" * 101) + "\n"
        violations = check_odin_style.check_source(source)
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].line, 2)

    def test_unicode_counts_characters_and_crlf_is_ignored(self):
        source = ("é" * 100) + "\r\n" + ("é" * 101) + "\r\n"
        violations = check_odin_style.check_source(source)
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].line, 2)

    def test_procedure_limit_accepts_100_and_rejects_101(self):
        accepted = "p :: proc() {\n" + ("\tx := 1\n" * 98) + "}\n"
        rejected = "p :: proc() {\n" + ("\tx := 1\n" * 99) + "}\n"
        self.assertEqual(check_odin_style.check_source(accepted), [])
        violations = check_odin_style.check_source(rejected)
        self.assertEqual(len(violations), 1)
        self.assertIn("101 lines", violations[0].message)

    def test_attributes_and_multiline_signatures_are_counted(self):
        source = "@(private)\np :: proc(\n\tx: int,\n) -> (\n\tint,\n) {\n\treturn x\n}\n"
        self.assertEqual(check_odin_style.procedures(source)[0].start_line, 1)
        self.assertEqual(check_odin_style.procedures(source)[0].end_line, 8)

    def test_strings_runes_raw_strings_and_nested_comments_hide_braces(self):
        source = '''p :: proc() {
\tx := "}"
\ty := '}'
\tz := `}`
\t/* { /* } */ } */
}
'''
        procedure = check_odin_style.procedures(source)[0]
        self.assertEqual(procedure.end_line, 6)

    def test_procedure_types_and_foreign_declarations_are_ignored(self):
        source = "Callback :: proc(x: int) -> bool\nforeign_proc :: proc(x: int) -> bool ---\n"
        self.assertEqual(check_odin_style.procedures(source), [])

    def test_anonymous_procedure_does_not_end_outer_procedure(self):
        source = "outer :: proc() {\n\tcallback := proc() {\n\t}\n}\n"
        procedure = check_odin_style.procedures(source)[0]
        self.assertEqual(procedure.name, "outer")
        self.assertEqual(procedure.end_line, 4)

    def test_baseline_allows_current_size_but_rejects_growth(self):
        source = "p :: proc() {\n" + ("\tx := 1\n" * 99) + "}\n"
        self.assertEqual(check_odin_style.check_source(source, {"x:p": 101}, "x"), [])
        violations = check_odin_style.check_source(source, {"x:p": 100}, "x")
        self.assertEqual(len(violations), 1)

    def test_direct_recursion_is_rejected_but_qualified_call_is_allowed(self):
        source = "p :: proc() {\n\tobject.p()\n\tp()\n}\n"
        violations = check_odin_style.check_source(source)
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].line, 3)
        self.assertIn("direct recursion", violations[0].message)

    def test_open_loop_requires_a_rationale_bearing_waiver(self):
        rejected = "p :: proc() {\n\tfor {\n\t}\n}\n"
        self.assertIn("no structurally provable", check_odin_style.check_source(rejected)[0].message)
        accepted = (
            "p :: proc() {\n"
            "\t// tigerstyle: allow-unbounded-loop -- worker exits when stopped\n"
            "\tfor {\n\t}\n}\n"
        )
        self.assertEqual(check_odin_style.check_source(accepted), [])

    def test_bounded_loop_shapes_are_accepted(self):
        source = (
            "LIMIT :: 10\n"
            "p :: proc(items: []int) {\n"
            "\tfor item in items { _ = item }\n"
            "\tfor index in 0 ..< LIMIT { _ = index }\n"
            "\tfor index := 0; index < len(items); index += 1 { _ = items[index] }\n"
            "}\n"
        )
        self.assertEqual(check_odin_style.check_source(source), [])

    def test_condition_only_loop_and_empty_waiver_are_rejected(self):
        source = (
            "p :: proc(running: bool) {\n"
            "\t// tigerstyle: allow-unbounded-loop --\n"
            "\tfor running {\n\t}\n}\n"
        )
        violations = check_odin_style.check_source(source)
        self.assertEqual(len(violations), 2)

    def test_assert_condition_with_side_effecting_call_is_rejected(self):
        source = "p :: proc(out: []u8) {\n\tassert(_to_rgba_into(out, nil, 1, 1, .R8))\n}\n"
        violations = check_odin_style.check_source(source)
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].line, 2)
        self.assertIn("'_to_rgba_into'", violations[0].message)

    def test_multiline_and_qualified_assert_conditions_are_rejected(self):
        source = (
            "p :: proc() {\n"
            "\tassert(\n"
            "\t\tmesh.simplify_mesh(source, options, scratch),\n"
            "\t\t\"generate failed\",\n"
            "\t)\n"
            "\tif ticket != 0 do assert_contextless(_submission_rollback(tracker, ticket))\n"
            "}\n"
        )
        violations = check_odin_style.check_source(source)
        self.assertEqual([violation.line for violation in violations], [2, 6])
        self.assertIn("'mesh.simplify_mesh'", violations[0].message)
        self.assertIn("'_submission_rollback'", violations[1].message)

    def test_pure_assert_conditions_are_accepted(self):
        source = (
            "p :: proc(items: []int, frame: ^Frame) {\n"
            "\tassert(len(items) > 0 && u32(len(items)) < max(u32))\n"
            "\tassert(text_metrics_valid(metrics), \"invalid: \" + describe(metrics))\n"
            "\tassert(layout_kind(&u.layout) == .Row && is_ready(frame))\n"
            "\tassert(prepared_capacity(&builder.prepared) == len(outputs))\n"
            "\tuploaded := _stream_slot_upload(ctx, &ctx.rend)\n"
            "\tassert(uploaded, \"upload failed\")\n"
            "\t#assert(size_of(Node) == 16)\n"
            "}\n"
        )
        self.assertEqual(check_odin_style.check_source(source), [])

    def test_ensure_and_testing_expect_are_not_assert_calls(self):
        source = (
            "p :: proc(t: ^testing.T) {\n"
            "\tensure(_submission_commit(tracker, ticket))\n"
            "\ttesting.expect(t, _submission_commit(tracker, ticket))\n"
            "\ttesting.expect_assert_message(t, \"x\")\n"
            "}\n"
        )
        self.assertEqual(check_odin_style.check_source(source), [])

    def test_assert_calls_in_comments_and_strings_are_ignored(self):
        source = (
            "p :: proc() {\n"
            "\t// assert(_stream_slot_upload(ctx, &ctx.rend))\n"
            "\tmessage := \"assert(_stream_slot_upload(ctx))\"\n"
            "}\n"
        )
        self.assertEqual(check_odin_style.check_source(source), [])

    def test_assert_call_waiver_requires_a_rationale(self):
        accepted = (
            "p :: proc() {\n"
            "\t// tigerstyle: allow-assert-call -- debug-only probe, skipped work is intended\n"
            "\tassert(probe_counters(ctx))\n"
            "}\n"
        )
        self.assertEqual(check_odin_style.check_source(accepted), [])
        rejected = (
            "p :: proc() {\n"
            "\t// tigerstyle: allow-assert-call --\n"
            "\tassert(probe_counters(ctx))\n"
            "}\n"
        )
        violations = check_odin_style.check_source(rejected)
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].line, 3)

    def test_pure_marker_allows_assert_call(self):
        source = (
            "// tigerstyle: pure\n"
            "@(private)\n"
            "slot_of :: proc(handle: u32) -> i32 {\n"
            "\treturn i32(handle)\n"
            "}\n"
            "p :: proc(handle: u32) {\n"
            "\tassert(slot_of(handle) >= 0)\n"
            "}\n"
        )
        self.assertEqual(check_odin_style.check_source(source), [])

    def test_unmarked_query_is_rejected_in_assert(self):
        source = (
            "slot_of :: proc(handle: u32) -> i32 {\n"
            "\treturn i32(handle)\n"
            "}\n"
            "p :: proc(handle: u32) {\n"
            "\tassert(slot_of(handle) >= 0)\n"
            "}\n"
        )
        violations = check_odin_style.check_source(source)
        self.assertEqual([violation.line for violation in violations], [5])
        self.assertIn("'slot_of'", violations[0].message)

    def test_marker_from_another_file_is_honoured_through_the_index(self):
        declaring = "// tigerstyle: pure\nslot_of :: proc(handle: u32) -> i32 {\n\treturn 0\n}\n"
        using = "p :: proc(handle: u32) {\n\tassert(pkg.slot_of(handle) >= 0)\n}\n"
        purity = check_odin_style.build_purity_index([declaring, using])
        self.assertEqual(check_odin_style.check_source(using, purity=purity), [])

    def test_dangling_pure_marker_is_reported(self):
        source = "// tigerstyle: pure\nLIMIT :: 10\n"
        violations = check_odin_style.check_source(source)
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].line, 1)
        self.assertIn("dangling pure marker", violations[0].message)

    def test_pure_marked_proc_that_mutates_is_reported(self):
        source = (
            "// tigerstyle: pure\n"
            "push :: proc(items: ^[dynamic]int, state: ^State) -> bool {\n"
            "\tappend(items, 1)\n"
            "\tstate.count += 1\n"
            "\tstate.slots[0] = 2\n"
            "\tlocal := state.count\n"
            "\treturn local == state.count\n"
            "}\n"
        )
        violations = check_odin_style.check_source(source)
        self.assertEqual([violation.line for violation in violations], [3, 4, 5])
        self.assertIn("calls append", violations[0].message)
        self.assertIn("writes through parameter state", violations[1].message)

    def test_type_conversion_is_pure(self):
        source = (
            "Asset_Id :: distinct u32\n"
            "Matrix :: matrix[4, 4]f32\n"
            "p :: proc(raw: u32, m: [16]f32) {\n"
            "\tassert(Asset_Id(raw) != 0 && Matrix(1) == Matrix(1))\n"
            "}\n"
        )
        self.assertEqual(check_odin_style.check_source(source), [])

    def test_external_pure_name_declared_in_tree_is_reported(self):
        source = "to_string :: proc(value: int) -> string {\n\treturn \"\"\n}\n"
        violations = check_odin_style.check_source(source)
        self.assertEqual(len(violations), 1)
        self.assertIn("EXTERNAL_PURE_NAMES", violations[0].message)


if __name__ == "__main__":
    unittest.main()
