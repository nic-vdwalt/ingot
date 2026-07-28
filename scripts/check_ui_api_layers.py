#!/usr/bin/env python3
"""Enforce the documented ingot:ui public API layers."""

from __future__ import annotations

import argparse
import dataclasses
import re
import sys
from pathlib import Path

from check_odin_style import mask_source


DELETED_NAMES = {
    "btn",
    "btn_at",
    "input_at",
    "ui_begin",
    "ui_begin_frame",
    "ui_end",
    "ui_focus",
    "ui_id",
    "ui_padding",
    "ui_slot",
}
FORBIDDEN_FACADE_SUFFIXES = ("_ui", "_ui_id", "_auto")
RUNTIME_PREFIXES = ("ui_runtime_", "ui_frame_", "ui_output_", "ui_metrics")
EXPLICIT_LEAVES = {
    "back_btn_at",
    "bar_chart_at",
    "button_at",
    "button_at_state",
    "card_bg_at",
    "checkbox_at",
    "collapsible_header_at",
    "dropdown_at",
    "icon_btn_at",
    "kv_row_at",
    "line_chart_at",
    "list_row_bg_at",
    "progress_bar_animated_at",
    "progress_bar_at",
    "radio_at",
    "section_header_at",
    "slider_at",
    "slider_at_state",
    "sparkline_at",
    "spinner_at",
    "status_pill_at",
    "text_input_at",
    "tooltip_at",
}
EXPLICIT_PROTOCOLS = {
    "context_menu",
    "listbox_begin",
    "modal_begin",
    "pane_begin",
    "pane_end",
    "selectable_row",
}


@dataclasses.dataclass(frozen=True)
class Declaration:
    name: str
    line: int
    parameters: str
    private: bool
    overload: bool
    prefix: str
    body: str


def _balanced_end(source: str, start: int, opening: str, closing: str) -> int:
    depth = 0
    for index in range(start, len(source)):
        char = source[index]
        if char == opening:
            depth += 1
        elif char == closing:
            depth -= 1
            if depth == 0:
                return index
    return -1


def declarations(source: str) -> list[Declaration]:
    masked = mask_source(source)
    pattern = re.compile(r"(?m)^([a-z_][a-z_0-9]*)\s*::\s*proc\s*([({])")
    result: list[Declaration] = []
    for match in pattern.finditer(masked):
        name = match.group(1)
        opening = match.group(2)
        closing = ")" if opening == "(" else "}"
        start = match.end() - 1
        end = _balanced_end(masked, start, opening, closing)
        if end < 0:
            continue
        line = masked.count("\n", 0, match.start()) + 1
        line_start = masked.rfind("\n", 0, match.start()) + 1
        prefix_start = max(masked.rfind("\n", 0, max(line_start - 1, 0)) + 1, 0)
        prefix = source[prefix_start:match.start()]
        private = "@(private" in prefix
        content = source[start + 1 : end]
        parameters = content if opening == "(" else ""
        result.append(Declaration(name, line, parameters, private, opening == "{", prefix, content))
    return result


def _has_loose_rect(parameters: str) -> bool:
    compact = re.sub(r"\s+", "", parameters)
    return bool(
        re.search(r"(?:^|,)x,y,w,h:i32(?:,|$)", compact)
        or all(re.search(rf"(?:^|,){name}(?:,|:)", compact) for name in ("x", "y", "w", "h"))
    )


def violations(source: str) -> list[tuple[int, str]]:
    found: list[tuple[int, str]] = []
    for declaration in declarations(source):
        if declaration.private:
            continue
        name = declaration.name
        parameters = declaration.parameters
        if name in DELETED_NAMES:
            found.append((declaration.line, f"deleted UI API name: {name}"))
        if "^Ui" in parameters and "^Ui_Frame" not in parameters:
            if name.startswith("ui_") and not name.startswith(RUNTIME_PREFIXES):
                found.append((declaration.line, f"facade procedure must use a bare name: {name}"))
            if name.endswith(FORBIDDEN_FACADE_SUFFIXES):
                found.append((declaration.line, f"forbidden facade suffix: {name}"))
        if name.startswith("ui_") and not name.startswith(RUNTIME_PREFIXES):
            found.append((declaration.line, f"reserved ui_ prefix: {name}"))
        if name in EXPLICIT_LEAVES:
            if not name.endswith("_at") and not name.endswith("_at_state"):
                found.append((declaration.line, f"explicit leaf must end in _at: {name}"))
            if parameters.count("Rect_I32") != 1:
                found.append((declaration.line, f"explicit leaf needs one Rect_I32: {name}"))
            if _has_loose_rect(parameters):
                found.append((declaration.line, f"explicit leaf uses loose x/y/w/h: {name}"))
        if name in EXPLICIT_PROTOCOLS and _has_loose_rect(parameters):
            found.append((declaration.line, f"explicit protocol uses loose x/y/w/h: {name}"))
        if declaration.overload and "@(deprecated" in declaration.body:
            found.append((declaration.line, f"overload set contains deprecated member: {name}"))
    return found


def check(root: Path) -> list[str]:
    failures: list[str] = []
    for path in sorted((root / "ui").glob("*.odin")):
        if path.name.endswith("_test.odin"):
            continue
        for line, message in violations(path.read_text(encoding="utf-8")):
            failures.append(f"{path.relative_to(root)}:{line}: {message}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    arguments = parser.parse_args()
    failures = check(arguments.root.resolve())
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
