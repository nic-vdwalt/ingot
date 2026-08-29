# GUI parity target

This matrix defines the non-text GUI scope used to compare Ingot with Skald. It
is an implementation and evidence checklist, not a claim that every listed
control is already production-ready. `fit` is the recommended application API;
`ui` is the advanced immediate-mode toolkit.

Status terms are evidence-derived from [`widget-capabilities.json`](widget-capabilities.json):

- `builder` — complete recommended `fit.Builder` control.
- `surface` — complete `ui` control with a Fit Surface or Region facade.
- `ui` — complete advanced `ui` control without an established Fit facade.
- `foundation` — bounded state, parser, layout, or filtering exists, but the interactive control is incomplete.
- `absent` — agreed scope with no implementation.
- `deferred` — deliberately excluded from this plan.
- `out of scope` — not an intended Ingot capability.

The capability gate checks public symbols and evidence paths so this matrix cannot silently outrun the code. Runtime validation is recorded separately and remains `not_recorded` unless dated evidence exists.

## Widget matrix

| Capability | Evidence level | Completion evidence |
|---|---|---|
| Button | builder | Builder/direct tests and gallery |
| Checkbox | builder | Builder/direct tests and gallery |
| Radio | builder | Builder/direct tests and gallery |
| Toggle | absent | Add a first-party control rather than restyling checkbox at call sites |
| Slider | builder | Builder/direct tests and gallery |
| Progress | builder | Builder/direct tests and gallery |
| Select/dropdown | surface | Complete UI control and Fit Surface/Region facade; Builder promotion pending |
| Combobox | surface | Complete UI control and Fit Surface/Region facade; Builder promotion pending |
| Single-line text input | builder | Editing, IME, semantics, and gallery tests |
| Multi-line text input | builder | Editing, wrapping, semantics, and gallery tests |
| Tabs | surface | Complete UI tab bar and Fit Region facade; Builder promotion and focused tests pending |
| Menus/context menus | surface | Context menu exists; menu bar and nested menus are absent |
| Modal/dialog | surface | Modal, popup, and confirmation APIs exist; ordinary Builder conveniences pending |
| Image | absent | Renderer-independent paint has no image command |
| Split pane | surface | Caller-owned ratio, keyboard, semantics, and layout tests exist |
| Toast | surface | UI and Fit Surface APIs exist; Builder promotion pending |
| Drag and drop | absent | Table column reorder is specialized, not a reusable payload API |
| Command palette | foundation | Bounded filtering and state tests exist; interactive control is incomplete |
| Tree | ui | Complete bounded flattened tree; Fit facade, semantics depth, and gallery pending |
| Date picker | surface | Complete UI control and Fit Surface/Region facade; Builder promotion pending |
| Time picker | foundation | Strict value parser/formatter only |
| Color picker | foundation | Strict hexadecimal parser/formatter only |
| Table | surface | Interactive virtual UI table and simple prepared cells; APIs remain split |
| Virtual list/grid | surface | Public bounded culling protocol and tests exist; Builder container pending |
| Charts | surface | Complete UI charts and Fit Surface facade; Builder promotion pending |
| Accessibility semantics | surface | Native/browser bridges exist; runtime evidence remains not recorded |

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
