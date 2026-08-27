# GUI parity target

This matrix defines the non-text GUI scope used to compare Ingot with Skald. It
is an implementation and evidence checklist, not a claim that every listed
control is already production-ready. `fit` is the recommended application API;
`ui` is the advanced immediate-mode toolkit.

Status terms:

- `supported` — public API, deterministic tests, and a maintained example exist.
- `partial` — useful implementation exists, but API exposure or quality evidence
  is incomplete.
- `missing` — agreed scope with no complete implementation.
- `deferred` — deliberately excluded from this plan.
- `out of scope` — not an intended Ingot capability.

## Widget matrix

| Capability | `fit` | `ui` | Completion evidence |
|---|---|---|---|
| Button | supported | supported | Builder/direct tests and gallery |
| Checkbox | supported | supported | Builder/direct tests and gallery |
| Radio | supported | supported | Builder/direct tests and gallery |
| Toggle | partial | supported | Promote through Builder and add parity fixture |
| Slider | supported | supported | Builder/direct tests and gallery |
| Progress | supported | supported | Builder/direct tests and gallery |
| Select/dropdown | partial | supported | Unify Builder exposure and interaction evidence |
| Combobox | partial | supported | Unify Builder exposure and interaction evidence |
| Single-line text input | supported | supported | Editing, IME, semantics, and gallery tests |
| Multi-line text input | supported | supported | Editing, wrapping, semantics, and gallery tests |
| Tabs | partial | supported | Promote caller-owned selection through Builder |
| Menus/context menus | partial | supported | Promote Builder composition and focus evidence |
| Modal/dialog | partial | supported | Promote Builder composition and focus evidence |
| Image | partial | supported | Add ordinary Builder leaf and gallery fixture |
| Split pane | missing | missing | Caller-owned ratio, keyboard, semantics, tests |
| Toast | partial | supported | Promote Builder rendering and saturation evidence |
| Drag and drop | partial | supported | Promote Builder hooks and native/browser fixture |
| Command palette | missing | missing | Bounded filter over named commands |
| Tree | missing | missing | Bounded visible traversal with caller-owned state |
| Date picker | partial | supported | Promote Builder API and complete keyboard evidence |
| Time picker | missing | missing | Popup-based caller-owned picker |
| Color picker | missing | missing | Popup-based caller-owned picker |
| Table | supported | supported | Builder table demo and deterministic tests |
| Virtual list/grid | missing | partial | Public bounded culling API and parity fixture |
| Charts | partial | supported | Promote Builder API and gallery coverage |
| Accessibility semantics | supported | supported | Native/browser bridges; runtime evidence pending |

## Deferred text capabilities

| Capability | Status | Boundary |
|---|---|---|
| OpenType shaping | deferred | Scalar `vendor:stb/truetype` rendering remains canonical |
| Bidirectional layout | deferred | No bidi rendering claim |
| Font fallback | deferred | One font per scalar atlas |
| Color emoji | deferred | No COLR, CBDT, or sbix claim |
| Complex-script rendering | deferred | Applications must use a specialist owned path |

The scalar text boundary is documented in
[`text-asset-dependency-policy.md`](text-asset-dependency-policy.md) and exposed
through `gfx.capabilities()`. Grapheme-safe editing tests do not imply shaped
rendering support.

## API ergonomics fixtures

The high-level API is evaluated with these bounded examples:

| Fixture | Required behavior |
|---|---|
| Counter | Direct Action remains the shortest primary path |
| Form | Caller-owned values, validation, submit, and focus |
| Typed commands | Optional fixed-capacity typed queue without a reducer/runtime |
| Delayed completion | Explicit owner appends completion and requests redraw |
| Worker completion | Bounded copied result; no borrowed frame pointers |
| Modal workflow | Focus containment and distinguishable close reasons |
| Dynamic list | Stable caller identity and bounded visible work |
| Multi-window request | Explicit platform owner and lifecycle result |

## Baseline

Baseline revision: `5c38d3f84e1ad0e199f92d8ad7592d2f78031b3b`.

| Measure | Value |
|---|---:|
| Tracked Odin files | 482 |
| Tracked Odin test files | 164 |
| Tracked Odin source lines | 126,487 |
| Examples with `main.odin` | 21 |
| Pinned Odin | `dev-2026-08-nightly:902106f` |

The accepted headless UI baseline remains
[`benchmarks/widgets/results/2026-07-26-m2-max-phase-2.md`](../benchmarks/widgets/results/2026-07-26-m2-max-phase-2.md).
It excludes GPU execution, presentation, native events, startup, RSS, idle
power, and real text rendering. End-to-end evidence must not overwrite or
reinterpret that scope.

## Completion rules

A row moves to `supported` only when all applicable evidence exists:

1. Caller-owned persistent state and bounded current-frame work.
2. Public `fit` and/or `ui` API with explicit ownership and saturation behavior.
3. Deterministic geometry, interaction, focus, paint, and semantics tests.
4. Keyboard and accessibility behavior.
5. Dark, light, custom-theme, and DPI coverage.
6. Gallery or focused example.
7. Native/browser runtime evidence where platform integration is involved.

Screenshots supplement these structural oracles and never replace them.
