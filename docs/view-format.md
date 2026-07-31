# The view format

## Scope

`ingot:view` lets a builder produce a **view** — a declarative description of a
UI — and lets any other Ingot client render it. A view is data, not code, so it
can be authored by a tool, saved, shipped, diffed, and fuzzed.

This document is the specification. It is written before the implementation for
the reason [3d-content-pipeline-plan.md](3d-content-pipeline-plan.md) is: a
subsystem that will carry untrusted input across a file boundary is cheaper to
get right in design than in review.

[Immediate mode](immediate-mode.md) defines the architecture the format must not
break, [Tiger Style](TIGER_STYLE.md) defines the safety policy, and
[api-layers.md](api-layers.md) places `ingot:view` in the stack.

## Non-goals

- **No retained tree.** A view is not a widget model the application keeps in
  sync. `view_play` walks it and forgets it, exactly as a hand-written frame
  procedure would.
- **No general DSL.** The format expresses what the public `^Ui` facade already
  exposes and nothing else. A node kind that cannot be played cannot exist.
- **No styling arithmetic.** Tokens only. A literal color or pixel gap in a view
  file is the same defect `scripts/check_theme_tokens.py` exists to catch.
- **No relaxation of Tiger Style.** No recursion, no unbounded loop, no dynamic
  growth without a declared limit.

## Three decisions worth recording

These were settled during design review. The rationale is here because the code
that results looks arbitrary without it.

### Generated code emits data, not calls

The obvious design gives the format two backends: an interpreter for the builder
and a code generator that emits unrolled widget calls for shipping. It is wrong.
Two emitters mean two copies of the semantics, and
`TIGER_STYLE.md:239` is explicit that copies drift. Proposing a differential test
to detect the drift is adopting technical debt at birth, which the same document
forbids in its opening section.

So `viewc` emits a **static `View` literal** — an exactly-sized `[N]View_Node`
array and a string constant — and the shipped program calls the same
`view_play`. Every property wanted from codegen survives:

| Goal | How it is met |
|---|---|
| No runtime parse | The literal is materialised into `.rodata` by the compiler |
| Compile-time checking | Every enum, index and bound is checked in the emitted source |
| No runtime version risk | A format change becomes a *compile* error, not a decode failure |
| One implementation | `view_play` is the only thing that knows what a node means |

What this costs is a bounded walk over at most `VIEW_NODES_MAX` nodes instead of
straight-line calls. See [Cost](#cost) — it is noise.

### Decode returns `ok`; play asserts

A truncated or corrupt `.ingv` is an **operating** error. `TIGER_STYLE.md:44-46`
requires it be handled, and a view could plausibly be fetched over a network, so
crashing on bad content would be a denial of service.

- `view_decode` validates and returns `ok = false`. It never asserts on file
  content, at any depth, for any input.
- `view_play` uses `ensure` on values `view_decode` already validated. That is
  defence in depth against a **programmer** error — hand-constructing a `View`
  and skipping validation — which is the case `TIGER_STYLE.md:76-78` names.

The two seams have different failure modes and therefore different mechanisms.

### Authoring storage and play storage are different types

A `View_Doc` is `[512]View_Node` plus `[32768]u8`: about 69 KB, nearly all zeros
in any real view. Emitting one as a static initialiser would land 69 KB of
mostly-zero bytes in `.data` and fail `scripts/check_wasm_bloat.py`, whose
docstring explains that a global reaches `.data` "the moment it has a static
initialiser - however small".

So the format has two types:

- **`View_Doc`** — the mutable authoring buffer. Fixed capacity, owned by the
  builder, never shipped.
- **`View`** — what `view_play` consumes: two borrowed slices, exactly sized.
  Generated code emits `[12]View_Node`, not `[512]`.

This also makes `view_play` properly immediate-mode: it borrows caller-owned
storage and retains nothing.

## Packages

`ingot:view` is the runtime: types, codec, validation, and `view_play`. It
imports `ingot:ui` and `core:*` only, and `ui` gains no file-format knowledge.

The generator lives in a **separate package**, `ingot:view/generate`, because it
needs `core:fmt` and `core:fmt` pulls `core:os`, which does not exist on
js/wasm. Keeping it out of the runtime means a web consumer that only plays
views never pays for the generator and cannot fail to compile because of it. The
same reasoning applies to test files: they carry `#+build !js`, as `ui`'s do.

`tools/viewc` is the CLI over `ingot:view/generate`.

## The document

### Nodes

A view is a flat array of `View_Node`. Links are `i32` indices, never pointers,
so a document is byte-copyable and position-independent — the same shape
`Sem_Node` uses in `ui/semantics.odin`.

```odin
View_Node :: struct {
	kind:         View_Kind,
	parent:       i32, // VIEW_NODE_NONE at the root
	first_child:  i32,
	next_sibling: i32,
	// Text. All variable-length data lives in one blob addressed by
	// offset/length, as Paint_Command does in ui/paint.odin.
	key_offset:    u32, // stable identity, never displayed
	key_length:    u16,
	label_offset:  u32, // primary display text
	label_length:  u16,
	value_offset:  u32, // secondary text: kv_row value, text_input placeholder
	value_length:  u16,
	binding: i32, // into Bindings.slots; VIEW_BINDING_NONE for none
	// Presentation: tokens only, never literals.
	ink:       ui.Ink,
	text_role: ui.Text_Role,
	gap:       ui.Space,
	padding:   ui.Space,
	align:     ui.Cross_Align,
	justify:   ui.Main_Align,
	style:     ui.Btn_Style,
	// Geometry. Logical units; the facade scales them exactly once.
	track:     ui.Track, // this node's size on the parent's main axis
	size_main: i32,      // row height, column width, spinner diameter
	integer:   i32,      // radio value
	number_lo, number_hi, number_step: f32, // slider range
	flags: View_Flags,
}
```

`key` is identity and is never drawn. `label` is what the user sees. They are
separate so that renaming a button in the builder cannot reset its state —
`ui-state.md` requires identity be independent of display text.

### Kinds

Frozen for format version 1. Every kind maps to a procedure that is public from
`ingot:ui` today; this was verified by compiling a probe against the collection,
not by reading.

| Group | Kinds |
|---|---|
| Containers | `Row`, `Column`, `Panel`, `Flex_Row`, `Flex_Column` |
| Interactive | `Button`, `Icon_Button`, `Back_Button`, `Checkbox`, `Radio`, `Slider`, `Text_Input`, `Collapsible_Header` |
| Presentational | `Label`, `Section_Header`, `Status_Pill`, `Kv_Row`, `Progress_Bar`, `Spinner`, `Separator`, `Spacer` |

Deliberately excluded from v1, each because it needs a binding the scalar model
does not have: `sparkline`, `line_chart`, `bar_chart` (array bindings),
`dropdown`, `combobox`, `listbox` (item arrays plus retained state), `tooltip`
(`Tooltip_State`). A narrow format that ships beats a complete one that never
stabilises; each of these is a version bump, not a redesign.

Note that `ui.checkbox`, `ui.radio` and `ui.text_input` are declared as proc
*groups* whose members all carry `@(private = "package")`. The probe established
that the group is callable from another package even though a member named
directly is not. That is why these kinds are in v1 rather than deferred.

### Identity

Each node carries an author-assigned key. `view_play` derives identity with
`ui.id(u, key)` and pushes a scope per container with `ui.scope_begin` /
`ui.scope_end`. Identity is therefore the path of keys from the root, which makes
it stable across insertion, reordering and relabelling, and identical across
processes — the property `ui-state.md` requires.

Keys must be unique among siblings. `view_validate` enforces it; two siblings
with the same key would collide into one `Widget_Id` and share focus and
interaction state.

### Bindings

A view cannot own state. The document describes structure; the client supplies
storage and reads events back. This is the interface another client implements.

```odin
Binding_Kind :: enum u8 {None, Boolean, Number, Integer, Text, Label}

Binding :: struct {
	kind: Binding_Kind,
	as:   struct #raw_union {
		boolean: ^bool,
		number:  ^f32,
		integer: ^i32,
		text:    ^ui.Input_Box,
		label:   string,
	},
}

Bindings :: struct {
	slots:  []Binding,
	events: ^Event_Sink,
}
```

One slice, so one index space and one bounds check. An earlier draft had five
parallel slices; `TIGER_STYLE.md:242-243` asks for lower dimensionality at the
call site, and five index spaces is five chances to use the wrong one.

`kind` is the tag that makes the union safe. `view_play` checks it with `ensure`
before reading the union, because a `binding` index and its expected kind are
derived from document data.

Interaction is reported through a sink rather than a return value, because a
walk cannot return one value per node:

```odin
Event      :: struct {node: i32, key_offset: u32, key_length: u16}
Event_Sink :: struct {events: [VIEW_EVENTS_MAX]Event, count: i32}
```

`view_fired(view, sink, "save")` is the polling API.

### Bounds

Every limit is named, and the ones that must agree with `ui` are checked at
compile time.

| Constant | Value | Why |
|---|---|---|
| `VIEW_NODES_MAX` | 512 | Twice `MAX_SEM_NODES`; not every node is semantic |
| `VIEW_DEPTH_MAX` | 16 | Must not exceed `ui.MAX_ID_DEPTH` or `ui.MAX_LAYOUT_DEPTH`, both 16 |
| `VIEW_TEXT_BYTES_MAX` | 32768 | Matches `PAINT_TEXT_CAP` |
| `VIEW_EVENTS_MAX` | 64 | One frame's interactions; a frame cannot click 64 things |
| `VIEW_FLEX_TRACKS_MAX` | 32 | Children of one flex container |

```odin
#assert(VIEW_DEPTH_MAX <= ui.MAX_ID_DEPTH)
#assert(VIEW_DEPTH_MAX <= ui.MAX_LAYOUT_DEPTH)
```

`view_validate` additionally rejects a document whose interactive node count
exceeds `ui.MAX_FOCUSABLES`, so a malformed file cannot overrun the focus ring.

### One walk, shared

`view_play`, `view_validate` and the generator are all tree walks. Recursion is
banned without exception, so rather than write three iterative walks and give a
bounds bug three places to hide, there is one iterator with an explicit
`[VIEW_DEPTH_MAX]i32` stack and an asserted exit invariant. The three callers
differ only in what they do at each node.

## The container format

```
offset  size  field
0       4     magic       "INGV"
4       4     version     u32le, VIEW_FORMAT_VERSION
8       4     flags       u32le, reserved, must be 0
12      4     node_count  u32le
16      4     text_length u32le
20      4     checksum    u32le, CRC-32 over the payload
24      ...   payload     node_count node records, then text_length bytes
```

Records are encoded **field by field with explicit widths**. Never a struct
memcpy: `TIGER_STYLE.md:128-131` requires explicitly sized types at a file
boundary, and a memcpy would let target padding and field order leak into the
file, making the format silently ABI-dependent.

Assertions are paired across the seam: the encoder asserts what the decoder
checks. `TIGER_STYLE.md:83-86` asks for exactly this at a serialize/parse
boundary, and it is the pairing, not either side alone, that catches an
asymmetric change.

Version policy: `view_decode` accepts one version. A mismatch returns
`ok = false` with a distinguishable reason. Adding a field to `View_Node` is a
version bump — the format is deliberately small so that bumps are cheap.

## Distribution

| Path | Mechanism |
|---|---|
| Ship generated code | `viewc login.ingv -o src/views/login.odin`; the consumer compiles it and has no runtime dependency on the format at all |
| Ship data | `#load("views/login.ingv")`, then `view_decode`. Required on web, which has no filesystem |
| Builder scratch | `prefs.write`, which is already atomic natively and already has a `localStorage` twin on web |

Generated `.odin` files are *generated output* in the sense
[compatibility.md](compatibility.md) uses: no source-stability guarantee. The
**format version** is the contract, not the emitted text.

## Cost

Back-of-the-envelope, as `TIGER_STYLE.md:187-196` requires during design.

| Resource | Cost |
|---|---|
| Disk | One read at load; roughly 2 KB for a realistic view. Generated views: zero, the data is in the binary |
| Network | None in the engine. A view an application fetches is application-owned |
| Memory | `View_Doc` ≈ 69 KB, builder-only, static. `View` is two slices; a shipped view costs its exact node bytes |
| CPU | At most `VIEW_NODES_MAX` iterations of a switch plus one widget call, per frame |

The walk is sequential over a flat array — the cache-friendly case — and the
widget call inside each iteration does text shaping and layout, dominating the
dispatch by orders of magnitude. This is the measurement that makes "collapse
codegen into data" affordable, and it is why that decision costs nothing real.

## Testing

Negative space is mandatory, not optional. `view_decode` has a test for every
way a file can be wrong: truncated header, truncated payload, bad magic, wrong
version, non-zero reserved flags, checksum mismatch, node count over cap, text
length over cap, offset past `text_length`, binding index out of range, cyclic
parent links, depth overflow, duplicate sibling keys. Each returns `ok = false`
and none of them crashes.

`fuzz/view/` drives the decoder from a seed corpus, and the invariant is the same
one: no input, however malformed, may crash or hang the decoder.

The round-trip test asserts `decode(encode(doc))` is byte-identical, and that a
decoded document and the committed generated literal produce structurally equal
`View`s. There is no differential backend test, because after the first design
decision above there is only one backend.
