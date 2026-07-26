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


if __name__ == "__main__":
    unittest.main()
