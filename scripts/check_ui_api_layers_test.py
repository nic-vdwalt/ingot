#!/usr/bin/env python3
"""Unit tests for check_ui_api_layers.py."""

import tempfile
import unittest
from pathlib import Path

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

    def test_adapter_lifecycle_names_are_tracked(self) -> None:
        self.assertIn("adapter_init", policy.ADAPTER_LIFECYCLE)
        self.assertIn("adapter_prepare_frame", policy.ADAPTER_LIFECYCLE)


class ConsumerPolicyTests(unittest.TestCase):
    def check(self, source: str, allow: bool = False) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            path = root / "view.odin"
            path.write_text(source, encoding="utf-8")
            allowed = {path} if allow else set()
            return policy.consumer_violations([root], allowed, root / "ingot")

    def test_adapter_and_legacy_session_are_rejected(self) -> None:
        failures = self.check("package app\nf :: proc() { adapter_bind_frame(nil, nil) }\nx: App_Session\n")
        self.assertTrue(any("adapter" in failure for failure in failures))
        self.assertTrue(any("legacy session" in failure for failure in failures))

    def test_binding_allow_only_allows_binding_import(self) -> None:
        source = 'package app\nimport "ingot:libvterm"\nf :: proc() { adapter_init(nil) }\n'
        failures = self.check(source, allow=True)
        self.assertFalse(any("binding import" in failure for failure in failures))
        self.assertTrue(any("adapter" in failure for failure in failures))

    def test_comments_and_strings_do_not_trigger_consumer_policy(self) -> None:
        source = 'package app\n// adapter_init(nil)\ns := "App_Session ingot:pty"\n'
        self.assertEqual(self.check(source), [])

    def test_internal_ui_import_is_rejected(self) -> None:
        failures = self.check('package app\nimport "ingot:ui"\n')
        self.assertTrue(any("internal UI import" in failure for failure in failures))

    def test_string_literal_mentioning_internal_package_is_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "ui").mkdir()
            (root / "fit").mkdir()
            examples = root / "examples"
            examples.mkdir()
            (examples / "main.odin").write_text(
                'package main\nimport fit "ingot:fit"\ntitle := "ingot:ui_gfx"\n',
                encoding="utf-8",
            )
            failures = policy.check(root)
        self.assertEqual(failures, [])

    def test_retired_fit_and_graphics_apis_are_rejected(self) -> None:
        source = "package app\nf :: proc() { fit_tree(nil, {}); clear_frame(nil, {}) }\n"
        failures = self.check(source)
        self.assertTrue(any("retired UI API" in failure for failure in failures))
        self.assertTrue(any("retired graphics API" in failure for failure in failures))

    def test_repository_examples_reject_internal_ui_imports(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "ui").mkdir()
            (root / "fit").mkdir()
            examples = root / "examples"
            examples.mkdir()
            (examples / "main.odin").write_text('package main\nimport "ingot:ui_gfx"\n')
            failures = policy.check(root)
        self.assertTrue(any("examples/main.odin" in failure for failure in failures))
        self.assertTrue(any("internal UI import" in failure for failure in failures))

    def test_fit_public_alias_to_ui_is_rejected(self) -> None:
        failures = policy.fit_public_violations("Ui :: ui.Ui\n")
        self.assertTrue(any("internal UI type" in message for _, message in failures))

    def test_fit_approved_public_alias_to_ui_is_allowed(self) -> None:
        self.assertEqual(policy.fit_public_violations("Track :: ui.Track\n"), [])

    def test_fit_unapproved_public_alias_to_ui_is_rejected(self) -> None:
        failures = policy.fit_public_violations("Unexpected :: ui.Track\n")
        self.assertTrue(any("internal UI type" in message for _, message in failures))

    def test_fit_private_conversion_may_reference_ui(self) -> None:
        source = '@(private = "package")\nto_rect :: proc(rect: Rect) -> ui.Rect_I32 { return {} }\n'
        self.assertEqual(policy.fit_public_violations(source), [])

    def test_example_cannot_alias_fit_as_ui(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "ui").mkdir()
            (root / "fit").mkdir()
            examples = root / "examples"
            examples.mkdir()
            (examples / "main.odin").write_text('package main\nimport ui "ingot:fit"\n')
            failures = policy.check(root)
        self.assertTrue(any("Fit imported as internal UI alias" in failure for failure in failures))

    def test_split_session_lifecycle_is_rejected(self) -> None:
        failures = policy.fit_public_violations("Session_Begin :: proc(session: ^Session) {}\n")
        self.assertTrue(any("split session lifecycle" in message for _, message in failures))

    def test_gallery_rejects_compatibility_fit_alias_and_names(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "ui").mkdir()
            (root / "fit").mkdir()
            gallery = root / "examples" / "gallery"
            gallery.mkdir(parents=True)
            (gallery / "main.odin").write_text(
                'package main\nimport legacy "ingot:fit"\nf :: proc() { _: legacy_Ui_Frame }\n',
                encoding="utf-8",
            )
            failures = policy.check(root)
        self.assertTrue(any("must import ingot:fit as fit" in failure for failure in failures))
        self.assertTrue(any("compatibility UI name" in failure for failure in failures))

    def test_non_gallery_example_rejects_compatibility_name(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "ui").mkdir()
            (root / "fit").mkdir()
            example = root / "examples" / "chart_demo"
            example.mkdir(parents=True)
            (example / "main.odin").write_text(
                'package main\nimport fit "ingot:fit"\nx: fit.Host_App\n',
                encoding="utf-8",
            )
            failures = policy.check(root)
        self.assertTrue(any("compatibility UI name" in failure for failure in failures))

    def test_gallery_allows_public_fit_surface(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "ui").mkdir()
            (root / "fit").mkdir()
            gallery = root / "examples" / "gallery"
            gallery.mkdir(parents=True)
            (gallery / "main.odin").write_text(
                'package main\nimport fit "ingot:fit"\nf :: proc(surface: ^fit.Surface) {}\n',
                encoding="utf-8",
            )
            failures = policy.check(root)
        self.assertEqual(failures, [])


if __name__ == "__main__":
    unittest.main()
