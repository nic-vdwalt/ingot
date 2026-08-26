# Borrowed UI ideas

Ingot studies useful ideas from GPUI, Dear ImGui, egui, and established native
UI toolkits. These projects are references, not compatibility or parity targets.
An idea belongs in Ingot only when it improves a real Ingot workload and can be
expressed more clearly within Ingot's single-path immediate-mode and Tiger Style
architecture.

The application remains the source of truth for persistent behavior. Ordinary
Odin control flow declares each required frame. Runtime services may retain
bounded derived data for performance, but do not become a second application
model or require callers to synchronize a widget tree.

## Candidate ideas

| Idea | Potential Ingot form | Decision gate |
|---|---|---|
| Named commands and configurable shortcuts | Current-frame command contexts over caller-owned handlers and state | Adopt only for concrete editor/tool workflows after existing keyboard, text-input, focus, and modal behavior is characterized |
| Shaped multilingual text and fallback | A bounded runtime shaping service producing immutable derived glyph runs | Approve only after a dependency, safety, native/web reproducibility, memory, and editing-correctness review |
| SVG and animated images | Explicit bounded assets plus caller-owned playback state and redraw deadlines | Adopt formats independently when parser attack surface, decode bounds, and product demand justify them |
| Pointer and touch input | A bounded pointer-event stream with pure recognizers using caller-owned state | Add the smallest gestures required by demonstrated browser or touch-device workflows |
| Reusing passive derived output | Optional immutable paint/measurement snapshots; behavior always rebuilds from caller data | Implement only when active-frame benchmarks show a meaningful end-to-end win |
| Better diagnostics and examples | Test-driver injection, debug-overlay state, focused examples, and machine-readable capabilities | Add alongside each accepted feature rather than as a parity checklist |
| Platform evidence | Revision-pinned records for behavior Ingot actually claims | Record evidence per shipped capability; unsupported work remains absent or explicitly blocked |

## Selection rules

1. Start from an Ingot application problem, not another framework's feature list.
2. Prefer the smallest source-compatible vertical slice that solves that problem.
3. Preserve immediate return-value APIs and ordinary `if` and `for` composition.
4. Keep persistent editing, scrolling, selection, animation, gesture, and menu
   state in caller-owned component values.
5. Name fixed limits for every queue, parser, traversal, cache, and asset.
6. Use iterative algorithms, transactional failure, and explicit init/reset/destroy.
7. Treat malformed files, unsupported formats, missing resources, and capacity
   exhaustion as operating errors rather than assertions.
8. Add dependencies only after safety and reproducibility justify their supply-chain cost.
9. Characterize existing behavior, add deterministic and negative tests, then
   implement one independently useful slice.
10. Measure CPU, memory, binary size, startup, and idle effects. Remove an
    optimization whose benefit does not justify its invalidation complexity.
11. Claim support only from dated runtime evidence, never from API similarity or compilation.
12. Stop when the Ingot use case is solved; matching another framework is not a goal.

## Current evidence to consult

- Keyboard, focus, modal, and text behavior: `interaction-contract.md` and
  `ui-state.md`.
- Immediate-mode ownership: `immediate-mode.md`.
- Safety and dependency policy: `TIGER_STYLE.md`.
- Existing performance results: `../benchmarks/widgets/results/`.
- Platform claims and missing evidence: `production-readiness.md`.

Ideas can be accepted, narrowed, postponed, or rejected independently. Their
presence here promises investigation only; it does not expand Ingot's supported
API or platform contract.
