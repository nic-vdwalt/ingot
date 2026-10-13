#!/usr/bin/env python3

import argparse
import json
import re
import sys
from pathlib import Path

TEST_PROC = re.compile(r"@\(\s*test\s*\)\s+([A-Za-z_][A-Za-z0-9_]*)\s*::\s*proc\b")
EXPECT_ASSERT = re.compile(r"\btesting\.expect_assert_message\s*\(")
REQUIRED_PACKAGES = {"gfx", "ui", "fit"}


def code_only(source: str) -> str:
    result = list(source)
    index = 0
    depth = 0
    quote = ""
    while index < len(source):
        pair = source[index:index + 2]
        char = source[index]
        if depth:
            if pair == "/*":
                depth += 1
            elif pair == "*/":
                depth -= 1
            else:
                result[index] = "\n" if char == "\n" else " "
                index += 1
                continue
            result[index:index + 2] = "  "
            index += 2
        elif quote:
            result[index] = "\n" if char == "\n" else " "
            if char == "\\" and quote != "`":
                if index + 1 < len(source):
                    result[index + 1] = " "
                index += 2
                continue
            if char == quote:
                quote = ""
            index += 1
        elif pair == "/*":
            depth = 1
            result[index:index + 2] = "  "
            index += 2
        elif pair == "//":
            end = source.find("\n", index)
            if end < 0:
                end = len(source)
            result[index:end] = " " * (end - index)
            index = end
        elif char in ('"', "'", "`"):
            quote = char
            result[index] = " "
            index += 1
        else:
            index += 1
    return "".join(result)


def expected_assert_tests(root: Path, package: str = "gfx") -> set[str]:
    found: set[str] = set()
    for path in sorted((root / package).glob("*test*.odin")):
        source = code_only(path.read_text(encoding="utf-8"))
        for declaration in TEST_PROC.finditer(source):
            start = source.find("{", declaration.end())
            if start < 0:
                raise ValueError(f"{path}: test has no body")
            depth = 1
            end = start + 1
            while end < len(source) and depth:
                depth += (source[end] == "{") - (source[end] == "}")
                end += 1
            if depth:
                raise ValueError(f"{path}: unterminated test body")
            if EXPECT_ASSERT.search(source, start, end):
                found.add(f"{package}.{declaration.group(1)}")
    return found


def check_registered(found: set[str], registered: list[str]) -> list[str]:
    failures: list[str] = []
    registered_set = set(registered)
    if len(registered_set) != len(registered):
        failures.append("duplicate Windows expected-assert registration")
    for name in sorted(found - registered_set):
        failures.append(f"{name}: expected-assert test is not registered for Windows isolation")
    for name in sorted(registered_set - found):
        failures.append(f"{name}: stale Windows expected-assert registration")
    return failures


def validate_suites(manifest: dict) -> list[dict]:
    suites = manifest.get("windows_expected_assert_suites")
    if not isinstance(suites, list) or not suites:
        raise ValueError("windows_expected_assert_suites must be a nonempty list")
    packages = set()
    for suite in suites:
        if not isinstance(suite, dict) or set(suite) != {"package", "define", "tests"}:
            raise ValueError("isolation suite requires package, define and tests")
        package = suite["package"]
        if not isinstance(package, str) or package not in REQUIRED_PACKAGES:
            raise ValueError(f"invalid isolation package: {package!r}")
        if package in packages:
            raise ValueError(f"{package}: duplicate isolation suite")
        packages.add(package)
        if package not in manifest.get("test_packages", []):
            raise ValueError(f"{package}: isolation package is not a test package")
        if suite["define"] != f"INGOT_{package.upper()}_EXPECTED_ASSERTS":
            raise ValueError(f"{package}: invalid isolation define")
        tests = suite["tests"]
        if not isinstance(tests, list) or not tests:
            raise ValueError(f"{package}: tests must be a nonempty list")
        for name in tests:
            if not isinstance(name, str) or not re.fullmatch(rf"{package}\.[a-z][a-z0-9_]*", name):
                raise ValueError(f"{package}: invalid test name: {name!r}")
        if len(set(tests)) != len(tests):
            raise ValueError(f"{package}: duplicate test registration")
    if packages != REQUIRED_PACKAGES:
        raise ValueError(f"missing isolation suites: {sorted(REQUIRED_PACKAGES - packages)}")
    return suites


def check_manifest(root: Path, manifest: dict) -> list[str]:
    failures = []
    for suite in validate_suites(manifest):
        failures.extend(check_registered(expected_assert_tests(root, suite["package"]), suite["tests"]))
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    arguments = parser.parse_args()
    root = Path(arguments.root).resolve()
    try:
        manifest = json.loads((root / "scripts/gate-manifest.json").read_text(encoding="utf-8"))
        if not isinstance(manifest, dict):
            raise ValueError("gate manifest must be an object")
        failures = check_manifest(root, manifest)
    except (OSError, ValueError) as error:
        failures = [str(error)]
    for failure in failures:
        print(failure, file=sys.stderr)
    return int(bool(failures))


if __name__ == "__main__":
    sys.exit(main())
