# Interaction contract

This document defines the target default user-facing behavior of Ingot controls.
It is normative for built-in widgets, the gallery, and platform adapters.
Application-specific behavior may differ only when the application makes the
difference explicit and preserves keyboard and accessibility access.

Some controls do not yet satisfy every requirement. Compliance and platform
support remain unclaimed until recorded by the production-readiness matrix.

## Compatibility and evidence

- Public APIs remain source-compatible unless a migration is separately approved.
- Behavior changes begin with characterization tests and end with a gallery journey.
- Deterministic tests prove state transitions, not native platform integration.
- Platform claims require dated evidence under the production-readiness matrix.
- Reduced functionality must be documented instead of silently emulating success.

## Pointer interaction

- A primary press inside an enabled control owns that gesture.
- Drag controls update continuously while held, including outside their original bounds.
- Releasing outside ends the gesture without activating a release-over action.
- Presses that begin on an overlay never click through to content underneath it.
- Focus loss, pointer cancellation, owner removal, and missed release events safely end ownership.
- Hover, pressed, held, disabled, and dragging states provide immediate visual feedback.
- Small visual affordances may use a larger non-overlapping hit rectangle.

## Keyboard interaction

- Tab and Shift+Tab traverse enabled focusable controls in a stable, documented order.
- Enter activates buttons and primary actions where platform convention permits.
- Space activates buttons, checkboxes, and other pressable controls without scrolling the page.
- Escape cancels or closes the topmost dismissible transient surface.
- Arrow keys operate composite controls according to their role.
- Home and End move to meaningful boundaries in sliders, menus, lists, and text fields.
- Page Up and Page Down move by a larger bounded increment where the role supports it.
- Repeated keys produce bounded repeat behavior and never bypass disabled state.

## Focus

- Focus ownership is independent from focus-ring visibility.
- Keyboard navigation makes focus indication visible.
- A pointer press may suppress only the visual ring; pointer movement alone does not.
- Programmatic and accessibility focus remain represented in semantic output.
- Removing or disabling the focused control resolves focus deterministically.
- Scrolling containers reveal a newly keyboard-focused descendant.

## Overlays and modal surfaces

- The topmost interactive overlay owns pointer and keyboard routing.
- Opening a modal chooses an intentional initial focus target.
- Tab and Shift+Tab cannot leave an open modal.
- Closing a modal restores focus to its surviving opener when possible.
- Escape, click-away, explicit action, and programmatic closure remain distinguishable.
- Click-away dismissal is opt-in for destructive or data-entry dialogs.
- Context menus open from pointer and keyboard entry points.
- Menus remain inside the usable viewport and reveal their highlighted row.

## Forms and feedback

- Inputs have persistent visible labels; placeholders are supplementary hints.
- Required, invalid, read-only, disabled, and loading states are visually and semantically distinct.
- Validation identifies the field, explains recovery, and does not rely on color alone.
- Submission moves focus to the first invalid field or announces the resulting status.
- Destructive reset or discard actions require proportional confirmation or undo.
- Long-running work exposes progress or loading state and prevents duplicate submission.
- Success and failure feedback describe the user outcome rather than implementation counters.

## Accessibility

- Every interactive control exposes name, role, state, value, and supported actions.
- Text controls expose current value, selection, read-only, password, and multiline state.
- Composite controls expose selected item and collection position where supported.
- Disabled controls cannot be activated by pointer, keyboard, or accessibility action.
- Status changes that require attention are exposed without stealing focus unexpectedly.
- Semantic identity follows stable widget identity rather than labels or row positions.

## Text editing and platform conventions

- macOS and Apple browser hosts use Command for primary shortcuts.
- Windows, Linux, and non-Apple browser hosts use Control for primary shortcuts.
- Raw modifier state remains available for application-specific shortcuts.
- Selection, word movement, line movement, undo, redo, copy, cut, and paste follow host convention.
- Composition text remains transient until committed by the platform input method.
- IME candidate positioning follows the focused field caret in window coordinates.
- Clipboard failures are recoverable and never destroy the current selection.

## Motion and timing

- Animation never delays input, focus, dismissal, or confirmation.
- Reduced motion removes nonessential interpolation and blinking motion.
- Event-driven hosts request redraws only for visible state changes and bounded animation deadlines.
- Hover dwell is optional enhancement; essential information also has keyboard and accessibility access.

## Scale, density, and responsive layout

- UI scale and density are independent settings.
- Comfortable density is the default until representative visual review approves otherwise.
- Compact density reduces whitespace without reducing legibility or essential hit targets.
- Built-in surfaces remain usable at 100%, 150%, and 200% scale.
- Narrow layouts switch explicitly to a reviewed compact composition; they do not rely on accidental clipping.
- Navigation, forms, overlays, and status feedback remain reachable without horizontal overflow.

## Typography

- `Ui_Metrics` exposes exactly four type sizes: `FONT_SIZE_TITLE`, `FONT_SIZE_BODY`,
  `FONT_SIZE_LABEL`, `FONT_SIZE_NOTE`. A second name for an existing size is not
  added: aliases let two call sites drift apart while both look deliberate.
- `Text_Role` has exactly one role per size. `text_roles_are_pairwise_distinct`
  enforces this.
- Widgets resolve size and colour through `Text_Role`/`Ink` rather than reading
  metrics directly, so a theme or scale change cannot miss a call site.
- Control labels (`checkbox_at`, `radio_at`) and button labels (`btn_at`) share
  one default size, `FONT_SIZE_LABEL`. They appear side by side in almost every
  panel; a differing default made those panels inconsistent unless each caller
  intervened. All three accept a `font_size` override.

### Recorded default changes

| Date | Change | Rationale |
|---|---|---|
| 2026-07-27 | `checkbox_at`/`radio_at` label default `FONT_SIZE_BODY` (16) → `FONT_SIZE_LABEL` (13) | Matched `btn_at`. Controls and buttons in one panel previously differed by 3 px with neither call site naming a size. Covered by `control_labels_default_to_button_label_size`. |
| 2026-07-27 | Removed `FONT_SIZE`, `FONT_SIZE_LARGE`, `FONT_SIZE_SMALL` from `Ui_Metrics`; removed `Text_Role.Large`/`.Small` | Each duplicated an existing size. Callers used the pairs interchangeably for the same purpose. Replace with `FONT_SIZE_BODY`, `FONT_SIZE_TITLE`, `FONT_SIZE_LABEL` and `.Title`/`.Label` respectively. |

## Approval sequence

Each behavior change follows the same gate:

1. Record current behavior and all call sites.
2. Approve the desired interaction with concrete examples.
3. Add deterministic characterization and outcome tests.
4. Implement the smallest source-compatible slice.
5. Demonstrate it in the gallery.
6. Run package, strict, web, fuzz, and relevant windowed checks.
7. Perform hands-on target validation and record evidence.
8. Stop for approval before beginning the next slice.
