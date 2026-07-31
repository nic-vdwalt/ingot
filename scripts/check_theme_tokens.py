#!/usr/bin/env python3
"""Guard the UI design-token layer against regression to raw literals.

`ui/tokens.odin` exists because three visual properties had drifted apart
across the widget tree, each in a way that looked correct at its own call site:

  - Corner radius. `BTN_ROUNDNESS` is a *ratio* while `CARD_RADIUS_PX` is an
    *absolute pixel count*, so a button and a card of equal height could not be
    made to match at any UI scale. Five more raw literals had accumulated
    around them.
  - Border width. Most call sites scaled through `ui_frame_scf`, but four
    passed a bare `1`. At 2x DPI a dropdown field's border was one physical
    pixel while its own popup's was two.
  - Palette colors. Caption buttons, the spellcheck squiggle and the split-drop
    hint carried hardcoded `Color{...}` literals that no theme could override,
    which is why high-contrast caption hover was a 10-alpha white wash on pure
    black - invisible, and unreported for as long as it shipped.

Each of those is invisible in review: a literal `1` is not obviously wrong
until you know the surrounding convention. This script encodes the convention.

The baseline is monotonic, matching `check_odin_style.py` and
`check_gfx_context.py`: existing violations are recorded and may only
decrease. A file may not gain a violation, and an entry that has been fixed
must be removed from the baseline so it cannot silently return.

Usage:
    check_theme_tokens.py ROOT --baseline scripts/theme_token_baseline.json
    check_theme_tokens.py ROOT --measure > scripts/theme_token_baseline.json
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import check_odin_style

# Test files describe behaviour rather than draw, and frequently need literal
# colors to assert against.
EXCLUDED_SUFFIXES = ("_test.odin",)

# The palette files are where literal colors are *supposed* to live: a theme is
# data. Excluding them is what makes a literal anywhere else meaningful.
PALETTE_FILES = {"ui/theme.odin", "ui/paper.odin"}

# tokens.odin defines the scale itself and material.odin implements the
# primitives the scale resolves to, so both legitimately name raw numbers.
TOKEN_FILES = {"ui/tokens.odin", "ui/material.odin"}

# A Color composite literal with numeric channels: Color{12, 34, 56, 255}.
# A named-field or variable-built color is not a magic literal, so the pattern
# deliberately requires digits.
RAW_COLOR = re.compile(r"\bColor\{\s*\d+\s*,\s*\d+\s*,\s*\d+\s*(?:,\s*\d+\s*)?\}")

# A numeric roundness argument to the rounded-rect primitives. Group 1 is the
# rect argument, group 2 the roundness; a token-resolved call passes an
# identifier there instead of a number.
NUMERIC_ROUNDNESS = re.compile(
    r"draw_rectangle_rounded(?:_lines_ex)?\s*\(\s*[^,]+,\s*[^,]+,\s*(\d+(?:\.\d+)?)\s*,"
)

# An unscaled numeric thickness passed to a *_lines_ex border call. The
# scaled forms go through border_pixels or ui_frame_scf and so are identifiers
# or calls, never bare digits.
UNSCALED_BORDER = re.compile(
    r"draw_rectangle_lines_ex\s*\(\s*[^,]+,\s*[^,]+,\s*(\d+(?:\.\d+)?)\s*,"
)


def tracked_sources(root: Path) -> list[str]:
    process = subprocess.run(
        ["git", "ls-files", "ui/*.odin"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return [
        path
        for path in process.stdout.splitlines()
        if not path.endswith(EXCLUDED_SUFFIXES)
    ]


def counts_for_source(source: str, path: str) -> dict[str, int]:
    """Count token violations in one file, keyed by "path:kind"."""
    # mask_source blanks comments and string literals, so a Color{...} inside
    # an explanatory comment is not counted as a violation.
    masked = check_odin_style.mask_source(source)
    counts: dict[str, int] = {}

    if path not in PALETTE_FILES and path not in TOKEN_FILES:
        raw_colors = len(RAW_COLOR.findall(masked))
        if raw_colors:
            counts[f"{path}:raw_color"] = raw_colors

    if path not in TOKEN_FILES:
        roundness = len(NUMERIC_ROUNDNESS.findall(masked))
        if roundness:
            counts[f"{path}:numeric_roundness"] = roundness

        border = len(UNSCALED_BORDER.findall(masked))
        if border:
            counts[f"{path}:unscaled_border"] = border

    return counts


def current_counts(root: Path) -> dict[str, int]:
    counts: dict[str, int] = {}
    for relative in tracked_sources(root):
        source = (root / relative).read_text(encoding="utf-8")
        counts.update(counts_for_source(source, relative))
    return counts


ADVICE = {
    "raw_color": "use a Theme field; palettes are data and live in theme.odin or paper.odin",
    "numeric_roundness": "use radius_ratio(frame, Radius, rect) and radius_segments",
    "unscaled_border": "use border_pixels(frame, Border) so the width scales with DPI",
}


def check_counts(current: dict[str, int], baseline: dict[str, int]) -> list[str]:
    failures: list[str] = []
    for key, count in sorted(current.items()):
        allowed = baseline.get(key, 0)
        if count > allowed:
            kind = key.rsplit(":", 1)[1]
            failures.append(
                f"{key}: increased from {allowed} to {count}; {ADVICE.get(kind, '')}"
            )
    for key in sorted(set(baseline) - set(current)):
        failures.append(f"{key}: stale baseline entry; remove it")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--baseline")
    parser.add_argument("--measure", action="store_true")
    arguments = parser.parse_args()
    root = Path(arguments.root).resolve()
    current = current_counts(root)
    if arguments.measure:
        print(json.dumps(current, indent=2, sort_keys=True))
        return 0
    if not arguments.baseline:
        parser.error("--baseline is required unless --measure is used")
    baseline = json.loads(Path(arguments.baseline).read_text(encoding="utf-8"))
    failures = check_counts(current, baseline)
    for failure in failures:
        print(failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
