#!/usr/bin/env python3
"""Unit tests for check_theme_tokens.

The gate is only worth having if it detects the three defects it was written
for, and only tolerable if it does not fire on the correct forms. Both halves
are tested here: a parser that silently matches nothing would pass every file
it was handed, which is the failure mode a guard script must not have.
"""

from __future__ import annotations

import unittest

import check_theme_tokens as gate


class RawColorTests(unittest.TestCase):
    def test_detects_hardcoded_palette_literal(self) -> None:
        source = "draw_rectangle_rec(frame, r, Color{255, 255, 255, 15})\n"
        counts = gate.counts_for_source(source, "ui/caption_buttons.odin")
        self.assertEqual(counts.get("ui/caption_buttons.odin:raw_color"), 1)

    def test_ignores_theme_field_reference(self) -> None:
        source = "draw_rectangle_rec(frame, r, style.caption_hover)\n"
        counts = gate.counts_for_source(source, "ui/caption_buttons.odin")
        self.assertNotIn("ui/caption_buttons.odin:raw_color", counts)

    def test_ignores_palette_files(self) -> None:
        """A theme is data; literal colors are the point of these files."""
        source = "fg_primary = Color{44, 42, 38, 255},\n"
        for path in ("ui/theme.odin", "ui/sketch.odin"):
            counts = gate.counts_for_source(source, path)
            self.assertNotIn(f"{path}:raw_color", counts)

    def test_ignores_colors_inside_comments(self) -> None:
        """mask_source blanks comments, so documentation may cite a literal."""
        source = "// The old value was Color{255, 255, 255, 15}, invisible on black.\n"
        counts = gate.counts_for_source(source, "ui/caption_buttons.odin")
        self.assertNotIn("ui/caption_buttons.odin:raw_color", counts)


class RoundnessTests(unittest.TestCase):
    def test_detects_numeric_roundness(self) -> None:
        source = "draw_rectangle_rounded(frame, rect, 0.25, 4, bg)\n"
        counts = gate.counts_for_source(source, "ui/controls.odin")
        self.assertEqual(counts.get("ui/controls.odin:numeric_roundness"), 1)

    def test_detects_numeric_roundness_on_outline(self) -> None:
        source = "draw_rectangle_rounded_lines_ex(frame, rect, 0.25, 4, 1.0, border)\n"
        counts = gate.counts_for_source(source, "ui/controls.odin")
        self.assertEqual(counts.get("ui/controls.odin:numeric_roundness"), 1)

    def test_ignores_token_resolved_roundness(self) -> None:
        source = "draw_rectangle_rounded(frame, rect, box_round, box_segments, bg)\n"
        counts = gate.counts_for_source(source, "ui/controls.odin")
        self.assertNotIn("ui/controls.odin:numeric_roundness", counts)

    def test_detects_segments_with_composite_rect_and_qualified_call(self) -> None:
        source = "ui.draw_rectangle_rounded(frame, {x, y, w, h}, ratio, 4, bg)\n"
        counts = gate.counts_for_source(source, "ui/controls.odin")
        self.assertEqual(counts.get("ui/controls.odin:numeric_segments"), 1)

    def test_detects_overlay_roundness_and_segments(self) -> None:
        source = "overlay_rounded(frame, rect_f32({x, y, w, h}), 0.5, 4, bg)\n"
        counts = gate.counts_for_source(source, "ui/chart.odin")
        self.assertEqual(counts.get("ui/chart.odin:numeric_roundness"), 1)
        self.assertEqual(counts.get("ui/chart.odin:numeric_segments"), 1)


class BorderTests(unittest.TestCase):
    def test_detects_unscaled_border_width(self) -> None:
        """The DPI bug: a bare 1 stays one physical pixel at every scale."""
        source = "draw_rectangle_lines_ex(frame, rrect, 1, border)\n"
        counts = gate.counts_for_source(source, "ui/dropdown.odin")
        self.assertEqual(counts.get("ui/dropdown.odin:unscaled_border"), 1)

    def test_ignores_token_resolved_border(self) -> None:
        source = (
            "draw_rectangle_lines_ex(frame, rrect, border_pixels(frame, .Hairline), border)\n"
        )
        counts = gate.counts_for_source(source, "ui/dropdown.odin")
        self.assertNotIn("ui/dropdown.odin:unscaled_border", counts)

    def test_ignores_scf_scaled_border(self) -> None:
        source = "draw_rectangle_lines_ex(frame, rrect, ui_frame_scf(frame, 1), border)\n"
        counts = gate.counts_for_source(source, "ui/dropdown.odin")
        self.assertNotIn("ui/dropdown.odin:unscaled_border", counts)


class TokenFileTests(unittest.TestCase):
    def test_token_files_are_exempt(self) -> None:
        """tokens.odin defines the scale; material.odin implements it."""
        source = (
            "draw_rectangle_rounded(frame, rect, 0.5, 4, bg)\n"
            "x := Color{1, 2, 3, 4}\n"
        )
        for path in ("ui/tokens.odin", "ui/material.odin"):
            self.assertEqual(gate.counts_for_source(source, path), {})


class BaselineTests(unittest.TestCase):
    def test_increase_fails(self) -> None:
        failures = gate.check_counts({"ui/a.odin:raw_color": 3}, {"ui/a.odin:raw_color": 2})
        self.assertEqual(len(failures), 1)
        self.assertIn("increased from 2 to 3", failures[0])

    def test_decrease_passes(self) -> None:
        self.assertEqual(
            gate.check_counts({"ui/a.odin:raw_color": 1}, {"ui/a.odin:raw_color": 2}),
            [],
        )

    def test_equal_passes(self) -> None:
        self.assertEqual(
            gate.check_counts({"ui/a.odin:raw_color": 2}, {"ui/a.odin:raw_color": 2}),
            [],
        )

    def test_new_violation_fails_without_a_baseline_entry(self) -> None:
        failures = gate.check_counts({"ui/new.odin:raw_color": 1}, {})
        self.assertEqual(len(failures), 1)
        self.assertIn("increased from 0 to 1", failures[0])

    def test_stale_entry_must_be_removed(self) -> None:
        """A fixed violation must leave the baseline so it cannot return."""
        failures = gate.check_counts({}, {"ui/a.odin:raw_color": 2})
        self.assertEqual(len(failures), 1)
        self.assertIn("stale baseline entry", failures[0])

    def test_failure_message_names_the_remedy(self) -> None:
        failures = gate.check_counts({"ui/a.odin:unscaled_border": 1}, {})
        self.assertIn("border_pixels", failures[0])


if __name__ == "__main__":
    unittest.main()
