#!/usr/bin/env python3
"""Keep web hosts from gating startup on `gfx.context_ready`.

On the web the GPU adapter and device resolve on the browser event loop, several
animation frames AFTER `gfx.context_init` returns. `context_init` says so: on JS
it reports success for a context that is merely `.Starting`, and `gfx.step`
skips the app callback until `g.initialized` flips.

A host that instead asks `context_ready` at startup reads that necessary `false`
as failure. That alone would only delay the app, but the failure paths tear the
context down, and `_close_window_context` zeroes the lifecycle - so when the
adapter finally arrives, `_web_on_adapter` sees a context that is no longer
`.Starting` and discards it. Nothing re-requests it. The canvas stays black for
the life of the page.

That shipped. `ui_gfx.app_run` called `app_start`, `app_start` required
`context_ready`, and every `ui_gfx.App` example - the widget gallery and the API
map among them - was a black rectangle in every browser, with a clean console on
both sides of the wasm boundary. The raylib-shaped examples were unaffected,
because `InitWindow` + `run` never asks about readiness, which is why the
breakage looked like a renderer bug rather than a lifecycle one.

`context_live` is the predicate hosts want: ready now, or still resolving on
web. This guard keeps `context_ready` out of the host packages so the mistake
cannot come back the next time someone writes a startup check.

`context_ready` remains correct for "may I draw *this frame*", which is why the
guard is scoped to host packages rather than the whole tree.

Usage:
    check_web_startup.py [ROOT]
"""

import argparse
import dataclasses
import re
import subprocess
import sys
from pathlib import Path

import check_odin_style

# Host packages: these own an application's startup and frame loop, so a
# readiness check here is a startup gate. gfx itself is exempt - that is where
# both predicates are defined and where per-frame readiness is a real question.
HOST_PACKAGES = ("ui_gfx/",)
FORBIDDEN = "context_ready"
REPLACEMENT = "context_live"

USE = re.compile(r"\bcontext_ready\b")


@dataclasses.dataclass(frozen=True)
class Use:
    path: str
    line: int


def tracked_sources(root: Path) -> list[str]:
    patterns = [f"{package}*.odin" for package in HOST_PACKAGES]
    process = subprocess.run(
        ["git", "ls-files", *patterns],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return process.stdout.splitlines()


def uses_for_source(source: str, path: str) -> list[Use]:
    """Every `context_ready` reference in one file.

    Comments and strings are masked first: app.odin documents at length why it
    calls context_live *instead of* context_ready, and matching that prose would
    make the guard fire on its own explanation.
    """
    masked = check_odin_style.mask_source(source)
    return [
        Use(path, check_odin_style.line_number(masked, match.start()))
        for match in USE.finditer(masked)
    ]


def check_uses(found: list[Use]) -> list[str]:
    return [
        f"{use.path}:{use.line}: host package gates on {FORBIDDEN}; "
        f"use gfx.{REPLACEMENT}"
        for use in sorted(found, key=lambda item: (item.path, item.line))
    ]


def current_uses(root: Path) -> list[Use]:
    found: list[Use] = []
    for relative in tracked_sources(root):
        source = (root / relative).read_text(encoding="utf-8")
        found.extend(uses_for_source(source, relative))
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    arguments = parser.parse_args()
    root = Path(arguments.root).resolve()

    failures = check_uses(current_uses(root))
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        print(
            "\nOn the web the GPU device resolves several frames after\n"
            "context_init returns, so context_ready is false at startup by\n"
            "construction. A host that reads that as failure and closes the\n"
            "context also cancels the in-flight adapter request, and the\n"
            "canvas then stays black for the life of the page with nothing\n"
            "logged anywhere.\n"
            "\n"
            "Use gfx.context_live for startup (ready, or still resolving on\n"
            "web). Keep context_ready for per-frame draw decisions inside gfx.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
