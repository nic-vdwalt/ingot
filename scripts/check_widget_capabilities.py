#!/usr/bin/env python3
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "docs" / "widget-capabilities.json"
VALID_LEVELS = {"absent", "foundation", "partial", "complete"}
VALID_VALIDATION = {"not_recorded", "compiled", "validated", "blocked", "failed"}
MAX_CAPABILITIES = 128


def source_contains(symbol: str) -> bool:
    package, name = symbol.split(".", 1)
    needle = f"{name} ::"
    return any(needle in path.read_text(encoding="utf-8") for path in (ROOT / package).glob("*.odin"))


def validate(data: dict) -> list[str]:
    errors: list[str] = []
    capabilities = data.get("capabilities", [])
    if data.get("schema_version") != 1:
        errors.append("unsupported widget capability schema")
    if not capabilities or len(capabilities) > MAX_CAPABILITIES:
        errors.append("widget capability count is outside bounds")
    names = [item.get("name", "") for item in capabilities]
    if len(names) != len(set(names)):
        errors.append("duplicate widget capability name")
    for item in capabilities:
        name = item.get("name", "<unnamed>")
        for field in ("ui", "fit_surface", "fit_builder"):
            if item.get(field) not in VALID_LEVELS:
                errors.append(f"{name}: invalid {field} status")
        if item.get("state_owner") != "caller":
            errors.append(f"{name}: persistent behavior must be caller-owned")
        if item.get("validation") not in VALID_VALIDATION:
            errors.append(f"{name}: invalid validation status")
        for symbol in item.get("symbols", []):
            if symbol.count(".") != 1 or not source_contains(symbol):
                errors.append(f"{name}: missing public symbol {symbol}")
        for relative in item.get("tests", []):
            if not (ROOT / relative).is_file():
                errors.append(f"{name}: missing test evidence {relative}")
        example = item.get("example", "")
        if example and not (ROOT / example).is_file():
            errors.append(f"{name}: missing example evidence {example}")
        if item.get("fit_builder") == "complete" and not any(
            symbol.startswith("fit.") for symbol in item.get("symbols", [])
        ):
            errors.append(f"{name}: complete Builder status lacks Fit symbol")
    return errors


def main() -> int:
    errors = validate(json.loads(MANIFEST.read_text(encoding="utf-8")))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("widget capabilities: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
