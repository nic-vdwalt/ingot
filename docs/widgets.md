# Widget reference

`ingot:fit` is the recommended application surface. Persistent behavior always
lives in caller-owned values; widget calls derive only the current frame's
interaction, semantics, and paint.

## Builder controls

| Control | State and result |
|---|---|
| `Label` | Passive text; no persistent state |
| `Button` | Direct `Action` or activation destination |
| `Button_Command` | Optional typed value copied into a caller-owned bounded queue |
| `Checkbox` | Caller-owned `^bool` |
| `Radio` | Caller-owned selected value |
| `Slider` | Caller-owned `^f32` |
| `Text_Input` | Caller-owned `Input_Box`, or string builder plus `Text_Input_State` |
| `Progress` | Passive bounded `0..1` value |
| `Table_*` | Caller-owned columns, sort, widths, order, visibility, and scroll |
| `Scroll` | Caller-owned offset and scrollbar state |

## Advanced caller-owned controls

The following currently use a borrowed `fit.Surface` because their APIs expose
explicit geometry or bounded begin/end protocols:

- `Virtual_List_Begin`, `Virtual_List_Row`, `Virtual_List_End`
- `Split_Pane`
- `Tree`
- command-palette filtering and caller-owned palette state
- time parsing/formatting helpers
- color hexadecimal parsing/formatting helpers

Virtual lists cap logical item count at `VIRTUAL_LIST_ITEM_COUNT_MAX` and emit
only the visible row window. Split panes persist only the caller's ratio and drag
latch. Tree callers supply a flattened visible preorder and own expansion and
selection state; no recursive retained tree exists. Command palettes use a
fixed 256-item match buffer and retain no command behavior.

## Existing composites

Tabs, toasts, dropdowns, comboboxes, date pickers, context menus, modals,
confirmation dialogs, charts, markdown, and interactive tables are available in
`ingot:ui`; Fit exposes their state and Surface facades where the public boundary
is established. See [`gui-parity.md`](gui-parity.md) for promotion status.

## Text boundary

Text input is grapheme-aware for navigation and deletion, including combining
marks and emoji ZWJ sequences. Rendering remains scalar stb text. This does not
imply OpenType shaping, bidi layout, fallback, or color emoji; those capabilities
remain explicitly unsupported.

## Quality contract

An interactive widget is not considered complete from appearance alone. It must
have bounded state and work, keyboard behavior, focus, semantics, DPI/theme
coverage, deterministic interaction tests, saturation behavior, and an example.
Screenshots supplement these structural checks and never replace them.
