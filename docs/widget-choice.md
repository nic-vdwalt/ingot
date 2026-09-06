# Choosing a widget

The [Fit guide](fit-guide.md#when-state-changes) lists delivery phases and
ownership requirements. Builder operations run during render, not inline in Draw;
use Action as the default operation path and typed commands only when needed.

- Use `Button` for one immediate operation. Use an `Action` for the shortest
  path; use `Button_Command` when several input sources share one typed command.
- Use `Checkbox` for an independent boolean and `Radio` for one value from a
  small visible set.
- Use dropdown/select for a short closed set. Use combobox when users must
  filter a longer set.
- Use `Text_Input` with caller-owned `Text_Input_State` for editable text. Set a
  finite byte limit for untrusted or persisted fields.
- Use tabs for a small number of peer views. Use a tree for hierarchical
  navigation whose expansion state belongs to the application.
- Use a virtual list for large fixed-height collections. Use an interactive
  table when columns, sorting, resizing, reordering, or persisted layout matter.
- Use a split pane when both regions remain visible and the caller persists the
  ratio. Use tabs when only one region should be visible.
- Use a popup for anchored temporary content and a modal when background input
  must be blocked and focus contained.
- Use a context menu for pointer-local actions. Use a command palette when named
  commands from menus, shortcuts, and tools share one searchable catalog.
- Use date/time/color value helpers only for their documented bounded scalar
  models; applications needing locale-specific formatting own that policy.

Prefer the smallest control that represents the application's state directly.
Do not use a convenience widget to hide persistent behavior inside the
framework.
