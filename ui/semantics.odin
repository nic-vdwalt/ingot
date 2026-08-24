// LIB-CANDIDATE: imports only core:*.
// Per-frame semantic recording layer: widgets describe themselves (role,
// rect, label, state) as they draw, into a flat bounded buffer that platform
// consumers (AccessKit adapters, the web DOM mirror) read at end of frame.
//
// This is an output buffer like the draw list, not a retained tree: it is
// reset every frame and rebuilt by the widget calls themselves, so there is
// no hidden state and no widget-ID hashing. Unlike input_route's claim
// buffer there is no double buffer - consumers read the completed frame
// after all UI is drawn, so no cross-frame semantics are needed.
//
// Node identity (sem_node_id) derives from caller-owned stable state - the
// form-focus slot pointer + 1-based id, or a text input's field_id string -
// never from call-site hashing. Widgets without either fall back to per-role
// call order, which is unstable under layout changes and acceptable only for
// non-interactive roles (screen readers re-read labels).
package ui

import "core:unicode/utf8"

// MAX_SEM_NODES bounds semantic nodes per frame (Tiger Style: put a limit on
// everything). Saturation drops nodes rather than corrupting the buffer -
// under-reporting is the safe failure mode for assistive tech.
MAX_SEM_NODES :: 256

// SEM_LABEL_MAX bounds the copied label bytes; longer labels truncate at a
// rune boundary so assistive tech never receives split UTF-8.
SEM_LABEL_MAX :: 64
SEM_DESCRIPTION_MAX :: 128
SEM_VALUE_MAX :: 256

// MAX_SEM_FOCUS bounds the frame-ordered focus registry (focus_scope.odin).
MAX_SEM_FOCUS :: MAX_FOCUSABLES
MAX_SEM_FOCUS_SCOPES :: 16

Focus_Scope_Id :: distinct u64
FOCUS_SCOPE_NONE :: Focus_Scope_Id(0)

Focus_Scope_Stamp :: struct {
	id:       Focus_Scope_Id,
	priority: i32,
	modal:    Modal_Id,
}

Focus_Scope_Stack :: struct {
	entries: [MAX_SEM_FOCUS_SCOPES]Focus_Scope_Stamp,
	count:   int,
}

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
	Tab,
	Tab_Panel,
	List,
	List_Item,
	Option,
	Status,
	Progress,
	List_Box,
	Link,
}

Sem_Flag :: enum u8 {
	Checked,
	Disabled,
	Focused,
	Expanded,
	Selected,
	Read_Only,
	Password,
	Multiline,
}

Sem_State :: bit_set[Sem_Flag;u8]

Sem_Node :: struct {
	id:              u64,
	parent_id:       u64,
	role:            Sem_Role,
	rect:            Rect_I32,
	label:           [SEM_LABEL_MAX]u8,
	label_len:       u8,
	description:     [SEM_DESCRIPTION_MAX]u8,
	description_len: u8,
	text_value:      [SEM_VALUE_MAX]u8,
	text_value_len:  u16,
	selection_start: i32,
	selection_end:   i32,
	state:           Sem_State,
	value:           f32,
	lo:              f32,
	hi:              f32,
	position_in_set: int,
	size_of_set:     int,
}

Sem_Frame :: struct {
	nodes: [MAX_SEM_NODES]Sem_Node,
	count: int,
}

// Sem_Focus_Entry is one focusable widget recorded in draw order; the
// app-global Tab cycler (focus_scope.odin) walks these.
Sem_Focus_Entry :: struct {
	focus:    Focus_Opt,
	scope_id: Focus_Scope_Id,
	priority: i32,
	modal:    Modal_Id,
}

Sem_Focus_List :: struct {
	entries: [MAX_SEM_FOCUS]Sem_Focus_Entry,
	count:   int,
}

Sem_Action_Target :: struct {
	id:    u64,
	focus: Focus_Opt,
}

Sem_Action_Targets :: struct {
	entries: [MAX_SEM_FOCUS]Sem_Action_Target,
	count:   int,
}

Semantics_State :: struct {
	cur:                    Sem_Frame,
	on:                     bool,
	ordinals:               [Sem_Role]int,
	focus_cur:              Sem_Focus_List,
	action_targets:         Sem_Action_Targets,
	focus_scopes:           Focus_Scope_Stack,
	cycle_requested:        bool,
	cycle_backwards:        bool,
	nodes_dropped:          int,
	focus_dropped:          int,
	action_targets_dropped: int,
	id_collisions:          int,
	text_truncations:       int,
}

sem_enable :: proc(runtime: ^Ui_Runtime, on: bool) {
	assert(runtime != nil && runtime.initialized)
	runtime.semantics_enabled = on
}

sem_enabled :: proc(frame: ^Ui_Frame) -> bool {
	assert(frame != nil && frame.open)
	return frame.runtime.semantics_enabled
}

semantic_will_emit :: proc(frame: ^Ui_Frame) -> bool {
	assert(frame != nil && frame.open, "semantic_will_emit: invalid frame")
	assert(frame.runtime != nil, "semantic_will_emit: nil runtime")
	return frame.runtime.semantics_enabled
}

sem_begin_frame :: proc(frame: ^Ui_Frame) {
	assert(frame != nil, "sem_begin_frame: nil frame")
	state := &frame.semantics
	assert(state.cur.count >= 0 && state.cur.count <= MAX_SEM_NODES)
	assert(state.focus_cur.count >= 0 && state.focus_cur.count <= MAX_SEM_FOCUS)
	assert(state.action_targets.count >= 0 && state.action_targets.count <= MAX_SEM_FOCUS)
	assert(state.focus_scopes.count >= 0 && state.focus_scopes.count <= MAX_SEM_FOCUS_SCOPES)
	assert(state.focus_scopes.count == 0, "sem_begin_frame: unbalanced prior focus scope")
	state.cur.count = 0
	state.ordinals = {}
	state.focus_cur.count = 0
	state.action_targets.count = 0
	state.focus_scopes.count = 0
	state.cycle_requested = false
	state.cycle_backwards = false
	state.nodes_dropped = 0
	state.focus_dropped = 0
	state.action_targets_dropped = 0
	state.id_collisions = 0
	state.text_truncations = 0
}

sem_reset :: proc(frame: ^Ui_Frame) {
	assert(frame != nil, "sem_reset: nil frame")
	frame.semantics = {}
}

// SEM_ID_ROOT is the window root node; 0 is reserved as invalid (AccessKit's
// convention). Derived widget ids start above both.
SEM_ID_ROOT :: u64(1)

@(private = "file")
SEM_FNV_OFFSET :: u64(0xcbf29ce484222325)
@(private = "file")
SEM_FNV_PRIME :: u64(0x00000100000001b3)

// sem_node_id derives a stable node id without call-site hashing, in
// priority order:
//  1. widget: a Widget_Id generated by the facade tier from its scope stack.
//  2. field_id: FNV-1a checksum of a caller-chosen application-global
//     semantic key. Explicit identity remains stable when focus ownership moves.
//  3. focus link: the explicit tier's identity, derived from a caller-owned
//     Focus_State and Focus_Id. This is a supported tier, not a legacy path.
//  4. fallback: role<<56 | per-role call order this frame. Unstable under
//     layout changes; acceptable only for non-interactive roles.
// Pure - unit-testable without a window.
sem_node_id :: proc(
	role: Sem_Role,
	focus: Focus_Opt,
	field_id: string,
	ordinal: int,
	widget: Widget_Id = WIDGET_ID_NONE,
) -> u64 {
	assert(role != .None, "sem_node_id: role required")
	assert(ordinal >= 0, "sem_node_id: negative ordinal")
	id: u64
	if widget != WIDGET_ID_NONE {
		id = id_hash_u64(SEM_FNV_OFFSET, u64(widget))
	} else if field_id != "" {
		id = SEM_FNV_OFFSET
		for b in transmute([]u8)field_id {
			id ~= u64(b)
			id *= SEM_FNV_PRIME
		}
	} else if focus.focus != nil {
		assert(focus.id > 0, "sem_node_id: focus ids are positive")
		id = SEM_FNV_OFFSET
		pointer := u64(uintptr(focus.focus))
		for shift: u64 = 0; shift < 64; shift += 8 {
			id ~= (pointer >> shift) & 0xff
			id *= SEM_FNV_PRIME
		}
		focus_id := u64(focus.id)
		for shift: u64 = 0; shift < 64; shift += 8 {
			id ~= (focus_id >> shift) & 0xff
			id *= SEM_FNV_PRIME
		}
	} else {
		id = (u64(role) << 56) | u64(ordinal)
	}
	// Keep 0 (invalid) and SEM_ID_ROOT reserved even in the astronomically
	// unlikely collision case - deterministic remap, not an assert, because
	// the inputs are caller data.
	if id <= SEM_ID_ROOT {
		id += SEM_ID_ROOT + 1
	}
	return id
}

// sem_text_clip returns the byte length of the longest valid-UTF-8 prefix
// that fits limit. Semantic strings cross into AccessKit and the browser DOM,
// so truncation must not split a rune and malformed input ends the value early.
sem_text_clip :: proc(value: string, limit: int) -> int {
	assert(limit >= 0, "sem_text_clip: negative limit")
	n := 0
	for n < len(value) && n < limit {
		r, size := utf8.decode_rune(value[n:])
		if r == utf8.RUNE_ERROR && size == 1 do break
		if n + size > limit do break
		n += size
	}
	assert(n >= 0 && n <= limit, "sem_text_clip: clip out of range")
	return n
}

sem_label_clip :: proc(label: string) -> int {
	return sem_text_clip(label, SEM_LABEL_MAX)
}

sem_focus_register :: proc(frame: ^Ui_Frame, focus: Focus_Opt, state: Sem_State) {
	assert(frame != nil && frame.open, "sem_focus_register: invalid frame")
	if focus.focus == nil || .Disabled in state do return
	assert(focus.id > 0, "sem_focus_register: invalid focus id")
	list := &frame.semantics.focus_cur
	assert(list.count >= 0 && list.count <= MAX_SEM_FOCUS)
	for i in 0 ..< list.count {
		existing := list.entries[i].focus
		assert(
			existing.focus != focus.focus || existing.id != focus.id,
			"sem_focus_register: duplicate focus registration",
		)
	}
	if list.count >= MAX_SEM_FOCUS {
		frame.semantics.focus_dropped += 1
		return
	}
	scope := focus_scope_current(frame)
	list.entries[list.count] = {
		focus    = focus,
		scope_id = scope.id,
		priority = scope.priority,
		modal    = scope.modal,
	}
	list.count += 1
}

// semantic_push records one widget's semantics for this frame. Widgets call
// it once, after interaction state is known. Returns the recorded node, or
// nil when recording is disabled or the bounded buffer is full (drop, don't
// corrupt). The focus registry records regardless of sem_enable so global
// Tab order works without an accessibility consumer.
semantic_push :: proc(
	frame: ^Ui_Frame,
	role: Sem_Role,
	rect: Rect_I32,
	label: string,
	state: Sem_State = {},
	focus: Focus_Opt = {},
	field_id: string = "",
	value: f32 = 0,
	lo: f32 = 0,
	hi: f32 = 0,
	description: string = "",
	text_value: string = "",
	selection_start: i32 = 0,
	selection_end: i32 = 0,
	position_in_set: int = 0,
	size_of_set: int = 0,
	widget: Widget_Id = WIDGET_ID_NONE,
) -> ^Sem_Node {
	assert(frame != nil && frame.open, "semantic_push: invalid frame")
	assert(role != .None, "semantic_push: role required")
	assert(
		(position_in_set == 0 && size_of_set == 0) ||
		(position_in_set > 0 && size_of_set > 0 && position_in_set <= size_of_set),
		"semantic_push: invalid collection position",
	)
	sem := &frame.semantics
	if !frame.runtime.semantics_enabled && (focus.focus == nil || .Disabled in state) {
		return nil
	}
	sem_focus_register(frame, focus, state)
	if !frame.runtime.semantics_enabled do return nil
	ordinal := sem.ordinals[role]
	sem.ordinals[role] = ordinal + 1
	if sem.cur.count >= MAX_SEM_NODES {
		sem.nodes_dropped += 1
		return nil
	}
	id := sem_node_id(role, focus, field_id, ordinal, widget)
	for index in 0 ..< sem.cur.count {
		if sem.cur.nodes[index].id == id {
			sem.id_collisions += 1
			sem.nodes_dropped += 1
			return nil
		}
	}
	node := &sem.cur.nodes[sem.cur.count]
	sem.cur.count += 1
	node^ = {
		id              = id,
		role            = role,
		rect            = rect,
		state           = state,
		value           = value,
		lo              = lo,
		hi              = hi,
		position_in_set = position_in_set,
		size_of_set     = size_of_set,
	}
	if focus.focus != nil {
		if sem.action_targets.count < MAX_SEM_FOCUS {
			sem.action_targets.entries[sem.action_targets.count] = {node.id, focus}
			sem.action_targets.count += 1
		} else {
			sem.action_targets_dropped += 1
		}
	}
	n := sem_label_clip(label)
	if n < len(label) do sem.text_truncations += 1
	copy(node.label[:n], label[:n])
	node.label_len = u8(n)
	description_len := sem_text_clip(description, SEM_DESCRIPTION_MAX)
	if description_len < len(description) do sem.text_truncations += 1
	copy(node.description[:description_len], description[:description_len])
	node.description_len = u8(description_len)
	text_value_len := sem_text_clip(text_value, SEM_VALUE_MAX)
	if text_value_len < len(text_value) do sem.text_truncations += 1
	copy(node.text_value[:text_value_len], text_value[:text_value_len])
	node.text_value_len = u16(text_value_len)
	node.selection_start = selection_start
	node.selection_end = selection_end
	if focus_opt_focused(focus) {
		node.state += {.Focused}
	}
	return node
}

// sem_frame exposes this frame's recorded nodes to platform consumers
// (AccessKit bridge, web DOM mirror). Read at end of frame, after all UI.
sem_frame :: proc(frame: ^Ui_Frame) -> ^Sem_Frame {
	assert(frame != nil, "sem_frame: nil frame")
	return &frame.semantics.cur
}

// sem_focus_list returns this frame's draw-ordered focusable widgets.
sem_focus_list :: proc(frame: ^Ui_Frame) -> ^Sem_Focus_List {
	assert(frame != nil, "sem_focus_list: nil frame")
	return &frame.semantics.focus_cur
}

sem_action_target :: proc(frame: ^Ui_Frame, id: u64) -> (Focus_Opt, bool) {
	assert(frame != nil && frame.open, "sem_action_target: invalid frame")
	targets := &frame.semantics.action_targets
	assert(targets.count >= 0 && targets.count <= MAX_SEM_FOCUS)
	for i in 0 ..< targets.count {
		if targets.entries[i].id == id do return targets.entries[i].focus, true
	}
	return {}, false
}

sem_node_accepts_action :: proc(frame: ^Ui_Frame, id: u64, action: A11y_Action_Kind) -> bool {
	assert(frame != nil && frame.open, "sem_node_accepts_action: invalid frame")
	assert(action != .Focus, "sem_node_accepts_action: focus is resolved separately")
	sem := sem_frame(frame)
	for i in 0 ..< sem.count {
		node := &sem.nodes[i]
		if node.id != id do continue
		if .Disabled in node.state do return false
		#partial switch action {
		case .Click:
			return node.role != .Label && node.role != .Pane && node.role != .Modal
		case .Increment, .Decrement:
			return node.role == .Slider && .Read_Only not_in node.state
		}
	}
	return false
}

// sem_node_label returns the node's label as a string view.
sem_node_label :: proc(node: ^Sem_Node) -> string {
	assert(node != nil, "sem_node_label: nil node")
	assert(int(node.label_len) <= SEM_LABEL_MAX, "sem_node_label: corrupt label length")
	return string(node.label[:node.label_len])
}
