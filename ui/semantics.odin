// LIB-CANDIDATE: imports only core:*.
// Per-frame semantic recording layer: widgets describe themselves (role,
// rect, label, state) as they draw, into a flat bounded buffer that platform
// consumers (AccessKit adapters, the web DOM mirror) read at end of frame.
//
// This is an output buffer like the draw list, not a retained tree: it is
// reset every frame and rebuilt by the widget calls themselves, so there is
// no hidden state and no widget-ID hashing. Unlike input_route's claim
// buffer there is no double buffer — consumers read the completed frame
// after all UI is drawn, so no cross-frame semantics are needed.
//
// Node identity (sem_node_id) derives from caller-owned stable state — the
// form-focus slot pointer + 1-based id, or a text input's field_id string —
// never from call-site hashing. Widgets without either fall back to per-role
// call order, which is unstable under layout changes and acceptable only for
// non-interactive roles (screen readers re-read labels).
package ui

// MAX_SEM_NODES bounds semantic nodes per frame (Tiger Style: put a limit on
// everything). Saturation drops nodes rather than corrupting the buffer —
// under-reporting is the safe failure mode for assistive tech.
MAX_SEM_NODES :: 256

// SEM_LABEL_MAX bounds the copied label bytes; longer labels truncate at a
// rune boundary so assistive tech never receives split UTF-8.
SEM_LABEL_MAX :: 64

// MAX_SEM_FOCUS bounds the frame-ordered focus registry (focus_scope.odin).
MAX_SEM_FOCUS :: 128

Sem_Role :: enum u8 {
	None,
	Button,
	Checkbox,
	Radio,
	Slider,
	Text_Input,
	Dropdown,
	Menu_Item,
	Label,
	Pane,
	Modal,
}

Sem_Flag :: enum u8 {
	Checked,
	Disabled,
	Focused,
	Expanded,
}

Sem_State :: bit_set[Sem_Flag;u8]

Sem_Node :: struct {
	id:        u64,
	role:      Sem_Role,
	rect:      Rect_I32,
	label:     [SEM_LABEL_MAX]u8,
	label_len: u8,
	state:     Sem_State,
	value:     f32, // slider/progress current value
	lo:        f32, // slider range low
	hi:        f32, // slider range high
	focus:     ^int, // caller's focus slot, for action/focus routing
	focus_id:  int, // 1-based id within that slot's cycle
}

Sem_Frame :: struct {
	nodes: [MAX_SEM_NODES]Sem_Node,
	count: int,
}

// Sem_Focus_Entry is one focusable widget recorded in draw order; the
// app-global Tab cycler (focus_scope.odin) walks these.
Sem_Focus_Entry :: struct {
	focus: ^int,
	id:    int,
}

Sem_Focus_List :: struct {
	entries: [MAX_SEM_FOCUS]Sem_Focus_Entry,
	count:   int,
}

@(private = "file") sem_cur: Sem_Frame
@(private = "file") sem_on: bool
@(private = "file") sem_ordinals: [Sem_Role]int
@(private = "file") sem_focus_cur: Sem_Focus_List
@(private = "file") sem_focus_prev: Sem_Focus_List

// sem_enable turns semantic node recording on or off. Off by default so apps
// without an accessibility consumer pay only a branch per widget. The focus
// registry records regardless, so focus_scope_cycle works either way.
sem_enable :: proc(on: bool) {
	sem_on = on
}

sem_enabled :: proc() -> bool {
	return sem_on
}

// sem_begin_frame resets the node buffer, per-role ordinals, and rotates the
// focus registry. Called once per frame from begin_cursor_frame, next to
// route_begin_frame.
sem_begin_frame :: proc() {
	assert(sem_cur.count >= 0 && sem_cur.count <= MAX_SEM_NODES,
		"sem_begin_frame: corrupt node count")
	assert(sem_focus_cur.count >= 0 && sem_focus_cur.count <= MAX_SEM_FOCUS,
		"sem_begin_frame: corrupt focus count")
	sem_cur.count = 0
	sem_ordinals = {}
	// Focus registry double-buffers: the Tab cycler consults last frame's
	// draw order (same one-frame latency justification as input_route).
	sem_focus_prev = sem_focus_cur
	sem_focus_cur.count = 0
}

// sem_reset clears all semantic state (tests / teardown).
sem_reset :: proc() {
	sem_cur = {}
	sem_ordinals = {}
	sem_focus_cur = {}
	sem_focus_prev = {}
	sem_on = false
}

// SEM_ID_ROOT is the window root node; 0 is reserved as invalid (AccessKit's
// convention). Derived widget ids start above both.
SEM_ID_ROOT :: u64(1)

@(private = "file") SEM_FNV_OFFSET :: u64(0xcbf29ce484222325)
@(private = "file") SEM_FNV_PRIME :: u64(0x00000100000001b3)

// sem_node_id derives a stable node id without call-site hashing, in
// priority order:
//  1. focus link: the caller's focus-slot pointer is long-lived caller state
//     and the 1-based id is stable per form — pointer XOR id<<48.
//  2. field_id: FNV-1a checksum of a caller-chosen stable string (text
//     inputs). A checksum of explicit identity, not egui-style ID hashing.
//  3. fallback: role<<56 | per-role call order this frame. Unstable under
//     layout changes; acceptable only for non-interactive roles.
// Pure — unit-testable without a window.
sem_node_id :: proc(role: Sem_Role, focus: Focus_Opt, field_id: string, ordinal: int) -> u64 {
	assert(role != .None, "sem_node_id: role required")
	assert(ordinal >= 0, "sem_node_id: negative ordinal")
	id: u64
	if focus.focus != nil {
		assert(focus.id > 0, "sem_node_id: focus ids are 1-based")
		assert(focus.id < (1 << 16), "sem_node_id: focus id exceeds 16-bit pack space")
		id = u64(uintptr(focus.focus)) ~ (u64(focus.id) << 48)
	} else if field_id != "" {
		h := SEM_FNV_OFFSET
		for b in transmute([]u8)field_id {
			h ~= u64(b)
			h *= SEM_FNV_PRIME
		}
		id = h
	} else {
		id = (u64(role) << 56) | u64(ordinal)
	}
	// Keep 0 (invalid) and SEM_ID_ROOT reserved even in the astronomically
	// unlikely collision case — deterministic remap, not an assert, because
	// the inputs are caller data.
	if id <= SEM_ID_ROOT {
		id += SEM_ID_ROOT + 1
	}
	return id
}

// sem_label_clip returns the byte length of `label` that fits SEM_LABEL_MAX,
// backing off to a rune boundary so truncation never splits UTF-8. Pure.
sem_label_clip :: proc(label: string) -> int {
	n := min(len(label), SEM_LABEL_MAX)
	// A UTF-8 continuation byte is 10xxxxxx; back up until the cut points at
	// a rune start (or the string head).
	for n > 0 && n < len(label) && (label[n] & 0xC0) == 0x80 {
		n -= 1
	}
	assert(n >= 0 && n <= SEM_LABEL_MAX, "sem_label_clip: clip out of range")
	return n
}

// semantic_push records one widget's semantics for this frame. Widgets call
// it once, after interaction state is known. Returns the recorded node, or
// nil when recording is disabled or the bounded buffer is full (drop, don't
// corrupt). The focus registry records regardless of sem_enable so global
// Tab order works without an accessibility consumer.
semantic_push :: proc(
	role: Sem_Role,
	rect: Rect_I32,
	label: string,
	state: Sem_State = {},
	focus: Focus_Opt = {},
	field_id: string = "",
	value: f32 = 0,
	lo: f32 = 0,
	hi: f32 = 0,
) -> ^Sem_Node {
	assert(role != .None, "semantic_push: role required")
	if focus.focus != nil && sem_focus_cur.count < MAX_SEM_FOCUS {
		sem_focus_cur.entries[sem_focus_cur.count] = {focus.focus, focus.id}
		sem_focus_cur.count += 1
	}
	if !sem_on do return nil
	ordinal := sem_ordinals[role]
	sem_ordinals[role] = ordinal + 1
	if sem_cur.count >= MAX_SEM_NODES {
		return nil
	}
	node := &sem_cur.nodes[sem_cur.count]
	sem_cur.count += 1
	node^ = {
		id       = sem_node_id(role, focus, field_id, ordinal),
		role     = role,
		rect     = rect,
		state    = state,
		value    = value,
		lo       = lo,
		hi       = hi,
		focus    = focus.focus,
		focus_id = focus.id,
	}
	n := sem_label_clip(label)
	copy(node.label[:n], label[:n])
	node.label_len = u8(n)
	if focus_opt_focused(focus) {
		node.state += {.Focused}
	}
	return node
}

// sem_frame exposes this frame's recorded nodes to platform consumers
// (AccessKit bridge, web DOM mirror). Read at end of frame, after all UI.
sem_frame :: proc() -> ^Sem_Frame {
	return &sem_cur
}

// sem_focus_list returns last frame's draw-ordered focusable widgets for the
// app-global Tab cycler.
sem_focus_list :: proc() -> ^Sem_Focus_List {
	return &sem_focus_prev
}

// sem_node_label returns the node's label as a string view.
sem_node_label :: proc(node: ^Sem_Node) -> string {
	assert(node != nil, "sem_node_label: nil node")
	assert(int(node.label_len) <= SEM_LABEL_MAX, "sem_node_label: corrupt label length")
	return string(node.label[:node.label_len])
}
