#!/usr/bin/env python3
"""Enforce Ingot UI API layers in the framework and its consumers."""

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
    "button_with_options_at",
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
    "text_input_with_options_at",
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
ADAPTER_LIFECYCLE = {
    "adapter_attach_runtime",
    "adapter_begin_frame",
    "adapter_bind_frame",
    "adapter_destroy",
    "adapter_end_frame",
    "adapter_init",
    "adapter_init_context",
    "adapter_open_frame",
    "adapter_prepare_frame",
}
LEGACY_SESSION = re.compile(r"\b(?:App_Session(?:_Config)?|app_session_[a-z_0-9]+)\b")
BINDING_IMPORT = re.compile(r'"ingot:(libvterm|pty|accesskit)"')
INTERNAL_UI_IMPORT = re.compile(r'(?m)^\s*import\s+(?:[A-Za-z_][A-Za-z_0-9]*\s+)?"ingot:(?:ui|ui_gfx)"')
FIT_AS_INTERNAL_IMPORT = re.compile(r'(?m)^\s*import\s+(ui|ui_gfx)\s+"ingot:fit"')
EXAMPLE_FIT_IMPORT = re.compile(r'(?m)^\s*import\s+(?!fit\s+)[a-zA-Z_][a-zA-Z_0-9]*\s+"ingot:fit"')
EXAMPLE_INTERNAL_NAME = re.compile(
    r"\b(?:Ui|Ui_Frame|Ui_Input|Ui_Output|Ui_Runtime|Surface_Frame|Host_App|Host_Session|"
    r"legacy_[A-Za-z_0-9]*)\b"
)
EXAMPLE_INNER_ACCESS = re.compile(r"\bfit\.[A-Za-z_][A-Za-z_0-9]*\.inner\b|\b[A-Za-z_][A-Za-z_0-9]*\.inner\b")
FIT_INTERNAL_NAME = re.compile(
    r"\b(?:ui|ui_gfx)\.|\b(?:Adapter|Ui|Ui_Frame|Ui_Input|Ui_Output|"
    r"Ui_Runtime|Host_App|Host_Session|Session_Frame)\b"
)
FIT_PUBLIC_ALIAS_ALLOW = {
    "Attachment_Point :: ui.Attachment_Point",
    "Attachment_Target :: ui.Attachment_Target_Kind",
    "Border :: ui.Border",
    "Button_Style :: ui.Btn_Style",
    "Caption_Button :: ui.Caption_Button",
    "Combobox_Item :: ui.Combobox_Item",
    "Cross_Align :: ui.Cross_Align",
    "Diff_Layout :: ui.Diff_Layout",
    "Diff_Row_Kind :: ui.Diff_Row_Kind",
    "Elevation :: ui.Elevation",
    "Focus_Id :: ui.Focus_Id",
    "Focus_State :: ui.Focus_State",
    "Ink :: ui.Ink",
    "Listbox_Keys :: ui.Listbox_Keys",
    "Main_Align :: ui.Main_Align",
    "Pigment :: ui.Pigment",
    "Radius :: ui.Radius",
    "Space :: ui.Space",
    "Spinner_Style :: ui.Spinner_Style",
    "Surface_Kind :: ui.Surface",
    "Text_Role :: ui.Text_Role",
    "Tint :: ui.Tint",
    "Track :: ui.Track",
    "Track_Kind :: ui.Track_Kind",
    "Transition_State :: ui.Transition_Rect_State",
    "Truncate_Side :: ui.Truncate_Side",
    "Visual_State :: ui.Visual_State",
}
FIT_SPLIT_SESSION = re.compile(r"\b(?:Session_Begin|Session_End|session_acquire_frame|session_present_frame)\b")
RETIRED_UI = re.compile(r"\b(?:Fit_Node|Fit_Prepared|fit_tree|fit_nodes|prepared_[a-z_0-9]+)\b")
RETIRED_GFX = re.compile(
    r"\b(?:begin_frame|context_begin_frame|end_frame|clear_frame|draw_rect|draw_circle|"
    r"frame_draw_[a-z_0-9]+)\s*\("
)


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


def _matches(source: str, pattern: re.Pattern[str], message: str, path: Path, root: Path) -> list[str]:
    failures: list[str] = []
    relative_path = path.relative_to(root).as_posix()
    for match in pattern.finditer(source):
        line = source.count("\n", 0, match.start()) + 1
        failures.append(f"{relative_path}:{line}: {message.format(name=match.group(0))}")
    return failures


def fit_public_violations(source: str) -> list[tuple[int, str]]:
    masked = mask_source(source)
    failures: list[tuple[int, str]] = []
    lines = masked.splitlines()
    private_next = False
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("@(private"):
            private_next = True
            continue
        if not stripped or stripped.startswith("package ") or stripped.startswith("import "):
            continue
        declaration = re.match(r"^([A-Z][A-Za-z_0-9]*)\s*::", stripped)
        procedure = re.match(r"^([A-Z][A-Za-z_0-9]*)\s*::\s*proc\b", stripped)
        public = declaration is not None or procedure is not None
        opaque_storage = stripped.startswith("Storage_Node :: distinct ui.Prepared_Node")
        allowed_alias = stripped in FIT_PUBLIC_ALIAS_ALLOW
        if public and not private_next:
            if FIT_INTERNAL_NAME.search(stripped) and not opaque_storage and not allowed_alias:
                failures.append((index + 1, "Fit public declaration exposes internal UI type"))
            if FIT_SPLIT_SESSION.search(stripped):
                failures.append((index + 1, "Fit public declaration exposes split session lifecycle"))
        if stripped.endswith("}") or "::" in stripped:
            private_next = False
    return failures


def _adapter_violations(root: Path) -> list[str]:
    failures: list[str] = []
    pattern = re.compile(r"\b(" + "|".join(sorted(ADAPTER_LIFECYCLE)) + r")\s*\(")
    allowed = {root / "ui_gfx" / "adapter.odin", root / "ui_gfx" / "session.odin"}
    for directory in (root / "examples", root / "ui_gfx"):
        for path in sorted(directory.rglob("*.odin")):
            if path in allowed or path.name.endswith("_test.odin"):
                continue
            source = mask_source(path.read_text(encoding="utf-8"))
            failures.extend(_matches(source, pattern, "backend adapter call {name}; use Session", path, root))
    return failures


def _inside(path: Path, roots: list[Path]) -> bool:
    return any(path == root or root in path.parents for root in roots)


def consumer_violations(consumer_roots: list[Path], binding_allow: set[Path], ingot_root: Path) -> list[str]:
    failures: list[str] = []
    adapter = re.compile(r"\b(" + "|".join(sorted(ADAPTER_LIFECYCLE)) + r")\s*\(")
    for root in consumer_roots:
        for path in sorted(root.rglob("*.odin")):
            resolved = path.resolve()
            if resolved == ingot_root or ingot_root in resolved.parents:
                continue
            raw_source = path.read_text(encoding="utf-8")
            source = mask_source(raw_source)
            failures.extend(_matches(source, adapter, "backend adapter call {name}; use Session", path, root))
            failures.extend(_matches(source, LEGACY_SESSION, "legacy session API {name}; use fit.Session", path, root))
            failures.extend(
                _matches(raw_source, INTERNAL_UI_IMPORT, "internal UI import {name}; use ingot:fit", path, root)
            )
            failures.extend(_matches(source, RETIRED_UI, "retired UI API {name}; use fit.Builder", path, root))
            failures.extend(_matches(source, RETIRED_GFX, "retired graphics API {name}; use PascalCase gfx", path, root))
            if resolved not in binding_allow:
                failures.extend(
                    _matches(source, BINDING_IMPORT, "binding import {name}; use the higher-level package", path, root)
                )
    return failures


def check(root: Path) -> list[str]:
    failures: list[str] = []
    for path in sorted((root / "examples").rglob("*.odin")):
        raw_source = path.read_text(encoding="utf-8")
        failures.extend(
            _matches(raw_source, INTERNAL_UI_IMPORT, "internal UI import {name}; use ingot:fit", path, root)
        )
        failures.extend(
            _matches(raw_source, FIT_AS_INTERNAL_IMPORT, "Fit imported as internal UI alias {name}", path, root)
        )
        source = mask_source(raw_source)
        failures.extend(
            _matches(raw_source, EXAMPLE_FIT_IMPORT, "example must import ingot:fit as fit: {name}", path, root)
        )
        if '"ingot:fit"' in raw_source:
            failures.extend(
                _matches(source, EXAMPLE_INTERNAL_NAME, "example exposes compatibility UI name {name}", path, root)
            )
    for path in sorted((root / "fit").glob("*.odin")):
        source = path.read_text(encoding="utf-8")
        for line, message in fit_public_violations(source):
            failures.append(f"{path.relative_to(root)}:{line}: {message}")
    for path in sorted((root / "ui").glob("*.odin")):
        if path.name.endswith("_test.odin"):
            continue
        for line, message in violations(path.read_text(encoding="utf-8")):
            failures.append(f"{path.relative_to(root)}:{line}: {message}")
    failures.extend(_adapter_violations(root))
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--consumer-root", action="append", default=[], type=Path)
    parser.add_argument("--binding-allow", action="append", default=[], type=Path)
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    consumer_roots = [path.resolve() for path in arguments.consumer_root]
    binding_allow = {path.resolve() for path in arguments.binding_allow}
    invalid = sorted(path for path in binding_allow if not _inside(path, consumer_roots))
    if invalid:
        print("binding allowance is outside every consumer root: " + str(invalid[0]), file=sys.stderr)
        return 2
    failures = check(root)
    failures.extend(consumer_violations(consumer_roots, binding_allow, root))
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
