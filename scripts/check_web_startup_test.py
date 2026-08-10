#!/usr/bin/env python3

import unittest

import check_web_startup


class WebStartupGuardTest(unittest.TestCase):
    def test_comments_and_strings_are_ignored(self):
        # app.odin documents why it calls context_live instead of
        # context_ready. If the guard matched that prose it would fire on its
        # own explanation.
        source = '''// context_live, not context_ready: the device resolves later.
/* context_ready is false at startup on web */
message :: "context_ready"
'''
        self.assertEqual(
            check_web_startup.uses_for_source(source, "ui_gfx/app.odin"),
            [],
        )

    def test_a_startup_gate_on_context_ready_is_rejected(self):
        source = '''app_start :: proc(app: ^App) -> bool {
	if !gfx.context_ready(app.gfx_context) do return false
	return true
}
'''
        found = check_web_startup.uses_for_source(source, "ui_gfx/app.odin")
        self.assertEqual([use.line for use in found], [2])
        failures = check_web_startup.check_uses(found)
        self.assertEqual(len(failures), 1)
        self.assertIn("ui_gfx/app.odin:2", failures[0])
        self.assertIn("context_live", failures[0])

    def test_the_corrected_gate_passes(self):
        source = '''app_start :: proc(app: ^App) -> bool {
	if !gfx.context_live(app.gfx_context) do return false
	return true
}
'''
        found = check_web_startup.uses_for_source(source, "ui_gfx/app.odin")
        self.assertEqual(found, [])
        self.assertEqual(check_web_startup.check_uses(found), [])

    def test_a_substring_is_not_a_match(self):
        source = '''ready :: proc() -> bool {
	return context_readyish
}
'''
        self.assertEqual(
            check_web_startup.uses_for_source(source, "ui_gfx/app.odin"),
            [],
        )


if __name__ == "__main__":
    unittest.main()
