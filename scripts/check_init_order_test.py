#!/usr/bin/env python3

import unittest

import check_init_order


class InitOrderGuardTest(unittest.TestCase):
    def test_comments_and_strings_are_ignored(self):
        # context.odin and resource_state_test.odin both discuss @(init) in
        # prose. If the guard matched that text it would fire on its own
        # documentation.
        source = '''// @(init) runs before main on every target.
/* @(init, private) in a block comment */
message :: "@(init)"
'''
        self.assertEqual(
            check_init_order.init_procedures_for_source(source, "gfx/context.odin"),
            [],
        )

    def test_the_permitted_declaration_is_found_and_accepted(self):
        source = '''@(init, private)
_default_context_init :: proc "contextless" () {
	default_context_storage.id = DEFAULT_CONTEXT_ID
}
'''
        found = check_init_order.init_procedures_for_source(source, "gfx/context.odin")
        self.assertEqual([item.name for item in found], ["_default_context_init"])
        self.assertEqual(found[0].line, 1)
        self.assertEqual(check_init_order.check_procedures(found), [])

    def test_attribute_order_and_bare_init_are_both_recognised(self):
        source = '''@(private, init)
first :: proc "contextless" () {
}

@(init)
second :: proc "contextless" () {
}
'''
        found = check_init_order.init_procedures_for_source(source, "gfx/context.odin")
        self.assertEqual([item.name for item in found], ["first", "second"])

    def test_similar_attributes_are_not_matched(self):
        source = '''@(private)
initialise :: proc "contextless" () {
}

@(init_like)
other :: proc "contextless" () {
}
'''
        self.assertEqual(
            check_init_order.init_procedures_for_source(source, "gfx/api.odin"),
            [],
        )

    def test_a_second_init_in_another_gfx_file_fails(self):
        allowed = check_init_order.Init_Procedure(
            "gfx/context.odin", "_default_context_init", 325
        )
        extra = check_init_order.Init_Procedure("gfx/api.odin", "_api_init", 12)
        failures = check_init_order.check_procedures([allowed, extra])
        self.assertEqual(len(failures), 1)
        self.assertIn("gfx/api.odin:12", failures[0])
        self.assertIn("_api_init", failures[0])

    def test_an_init_in_a_gfx_test_file_fails(self):
        allowed = check_init_order.Init_Procedure(
            "gfx/context.odin", "_default_context_init", 325
        )
        extra = check_init_order.Init_Procedure("gfx/api_tests.odin", "_seed", 8)
        failures = check_init_order.check_procedures([allowed, extra])
        self.assertEqual(len(failures), 1)
        self.assertIn("gfx/api_tests.odin:8", failures[0])

    def test_a_differently_named_init_in_context_odin_fails(self):
        renamed = check_init_order.Init_Procedure(
            "gfx/context.odin", "_context_init", 325
        )
        failures = check_init_order.check_procedures([renamed])
        self.assertEqual(len(failures), 2)
        self.assertIn("_context_init", failures[0])
        self.assertIn("is missing", failures[1])

    def test_removing_the_declaration_fails(self):
        # Without this the guard would pass vacuously on an empty scan - a
        # broken path filter or a deleted initialiser would look clean.
        failures = check_init_order.check_procedures([])
        self.assertEqual(len(failures), 1)
        self.assertIn("_default_context_init", failures[0])
        self.assertIn("is missing", failures[0])

    def test_a_duplicated_declaration_fails(self):
        duplicate = check_init_order.Init_Procedure(
            "gfx/context.odin", "_default_context_init", 325
        )
        other = check_init_order.Init_Procedure(
            "gfx/context.odin", "_default_context_init", 400
        )
        failures = check_init_order.check_procedures([duplicate, other])
        self.assertEqual(len(failures), 1)
        self.assertIn("declared 2 times", failures[0])


if __name__ == "__main__":
    unittest.main()
