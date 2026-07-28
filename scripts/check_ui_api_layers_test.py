#!/usr/bin/env python3
"""Unit tests for check_ui_api_layers.py."""

import unittest

import check_ui_api_layers as policy


class DeclarationTests(unittest.TestCase):
    def test_multiline_receiver_and_renamed_receiver_are_found(self) -> None:
        source = """facade :: proc(\n\tcontext: ^Ui,\n\tvalue: i32,\n) {}\n"""
        declarations = policy.declarations(source)
        self.assertEqual(len(declarations), 1)
        self.assertIn("context: ^Ui", declarations[0].parameters)

    def test_comments_and_strings_are_not_declarations(self) -> None:
        source = '// fake :: proc(u: ^Ui) {}\ns := "fake :: proc(u: ^Ui)"\nreal :: proc() {}\n'
        self.assertEqual([item.name for item in policy.declarations(source)], ["real"])

    def test_private_facade_helper_is_allowed(self) -> None:
        source = '@(private = "package")\nui_helper :: proc(u: ^Ui) {}\n'
        self.assertEqual(policy.violations(source), [])


class PolicyTests(unittest.TestCase):
    def messages(self, source: str) -> list[str]:
        return [message for _, message in policy.violations(source)]

    def test_ui_prefixed_facade_is_rejected(self) -> None:
        messages = self.messages("ui_button :: proc(context: ^Ui) {}\n")
        self.assertTrue(any("bare name" in message for message in messages))

    def test_forbidden_facade_suffix_is_rejected(self) -> None:
        messages = self.messages("button_auto :: proc(context: ^Ui) {}\n")
        self.assertTrue(any("forbidden facade suffix" in message for message in messages))

    def test_runtime_prefix_is_allowed(self) -> None:
        source = "ui_frame_theme :: proc(frame: ^Ui_Frame) -> ^Theme { return nil }\n"
        self.assertEqual(self.messages(source), [])

    def test_explicit_leaf_requires_rect(self) -> None:
        messages = self.messages(
            "button_at :: proc(frame: ^Ui_Frame, x, y, w, h: i32, label: string) {}\n"
        )
        self.assertTrue(any("one Rect_I32" in message for message in messages))
        self.assertTrue(any("loose x/y/w/h" in message for message in messages))

    def test_explicit_protocol_rejects_loose_rectangle(self) -> None:
        messages = self.messages("pane_begin :: proc(frame: ^Ui_Frame, x, y, w, h: i32) {}\n")
        self.assertTrue(any("explicit protocol" in message for message in messages))

    def test_paint_subsystem_is_an_intentional_exception(self) -> None:
        source = "overlay_rect :: proc(frame: ^Ui_Frame, rect: Rectangle, color: Color) {}\n"
        self.assertEqual(self.messages(source), [])

    def test_deleted_name_is_rejected(self) -> None:
        messages = self.messages("btn_at :: proc(frame: ^Ui_Frame, rect: Rect_I32) {}\n")
        self.assertTrue(any("deleted UI API" in message for message in messages))


if __name__ == "__main__":
    unittest.main()
