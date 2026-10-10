package ui

import "core:fmt"

prepared_begin :: proc(prepared: ^Prepared_Ui, constraints: Intrinsic_Constraints = {}) {
	assert(prepared != nil, "prepared_begin: nil description")
	assert(!prepared.open, "prepared_begin: description already open")
	assert(constraints.min_w >= 0 && constraints.min_h >= 0, "prepared_begin: invalid minimum")
	assert(constraints.max_w == 0 || constraints.max_w >= constraints.min_w)
	assert(constraints.max_h == 0 || constraints.max_h >= constraints.min_h)
	prepared.u = nil
	nodes := prepared_nodes(prepared)
	assert(len(nodes) >= MAX_LAYOUT_DEPTH && len(nodes) <= MAX_PREPARED_NODES_HARD)
	assert(prepared.count >= 0 && prepared.count <= i32(len(nodes)))
	prepared.count = 0
	prepared.depth = 0
	prepared.root = -1
	prepared.constraints = constraints
	prepared.summary = {}
	prepared.direct_geometry = false
	prepared.open = true
	prepared.measured = false
	prepared.rendered = false
}

prepared_row_begin :: proc(
	prepared: ^Prepared_Ui,
	options: Prepared_Container_Options = {},
) -> Prepared_Handle {
	return prepared_container_begin(prepared, .Row, options)
}

prepared_column_begin :: proc(
	prepared: ^Prepared_Ui,
	options: Prepared_Container_Options = {},
) -> Prepared_Handle {
	return prepared_container_begin(prepared, .Column, options)
}

prepared_flow_begin :: proc(
	prepared: ^Prepared_Ui,
	options: Prepared_Flow_Options = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_flow_begin: description not open")
	handle := prepared_add(
		prepared,
		Prepared_Node{kind = .Flow, track = options.track, sizing = options.size, flow = options},
	)
	prepared_push_container(prepared, handle)
	return handle
}

prepared_grid_begin :: proc(
	prepared: ^Prepared_Ui,
	options: Prepared_Grid_Options,
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_grid_begin: description not open")
	assert(
		(options.columns > 0) != (len(options.column_tracks) > 0),
		"prepared_grid_begin: invalid columns",
	)
	assert(options.row_height >= 0, "prepared_grid_begin: invalid row height")
	assert(len(options.column_tracks) <= MAX_GRID_TRACKS, "prepared_grid_begin: too many columns")
	assert(len(options.row_tracks) <= MAX_GRID_TRACKS, "prepared_grid_begin: too many rows")
	handle := prepared_add(
		prepared,
		Prepared_Node{kind = .Grid, track = options.track, sizing = options.size, grid = options},
	)
	prepared_push_container(prepared, handle)
	return handle
}

prepared_grid_cell_begin :: proc(
	prepared: ^Prepared_Ui,
	options: Prepared_Grid_Cell_Options = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_grid_cell_begin: description not open")
	assert(options.placement.column >= -1 && options.placement.row >= -1)
	assert(options.placement.column_span >= 0 && options.placement.row_span >= 0)
	handle := prepared_add(prepared, Prepared_Node{kind = .Grid_Cell, grid_cell = options})
	prepared_push_container(prepared, handle)
	return handle
}

prepared_attachment_begin :: proc(
	prepared: ^Prepared_Ui,
	options: Prepared_Attachment_Options,
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_attachment_begin: description not open")
	assert(prepared.depth > 0, "prepared_attachment_begin: attachment cannot be root")
	assert(options.z == options.z && options.z > Z_CONTENT, "prepared_attachment_begin: invalid z")
	if options.target_kind == .Handle {
		target := i32(options.target)
		assert(target >= 0 && target < prepared.count, "prepared_attachment_begin: invalid target")
	}
	handle := prepared_add(prepared, Prepared_Node{kind = .Attachment, attachment = options})
	prepared_push_container(prepared, handle)
	return handle
}

prepared_scroll_begin :: proc(
	prepared: ^Prepared_Ui,
	options: Prepared_Scroll_Options,
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_scroll_begin: description not open")
	assert(options.state != nil, "prepared_scroll_begin: nil state")
	assert(options.id != WIDGET_ID_NONE, "prepared_scroll_begin: invalid id")
	handle := prepared_add(
		prepared,
		Prepared_Node {
			kind = .Scroll,
			scroll = options,
			track = options.track,
			sizing = options.size,
		},
	)
	prepared_push_container(prepared, handle)
	return handle
}

prepared_row :: proc(u: ^Ui, prepared: ^Prepared_Ui, options: Prepared_Container_Options = {}) {
	assert(u != nil && prepared != nil, "prepared_row: invalid argument")
	prepared_root_begin(u, prepared, .Row, options)
}

prepared_column :: proc(u: ^Ui, prepared: ^Prepared_Ui, options: Prepared_Container_Options = {}) {
	assert(u != nil && prepared != nil, "prepared_column: invalid argument")
	prepared_root_begin(u, prepared, .Column, options)
}

prepared_end :: proc(prepared: ^Prepared_Ui) -> Rect_I32 {
	assert(prepared != nil && prepared.open, "prepared_end: description not open")
	assert(prepared.u != nil && prepared.u.open, "prepared_end: invalid bound UI")
	assert(prepared.depth == 1, "prepared_end: nested container still open")
	prepared_container_end(prepared)
	return prepared_fit(prepared.u, prepared)
}

prepared_container_end :: proc(prepared: ^Prepared_Ui) {
	assert(prepared != nil && prepared.open, "prepared_container_end: description not open")
	assert(
		prepared.depth > 0 && prepared.depth <= MAX_LAYOUT_DEPTH,
		"prepared_container_end: no container",
	)
	stack_index := prepared.depth - 1
	assert(stack_index >= 0 && stack_index < len(prepared.stack))
	index := prepared.stack[stack_index]
	assert(index >= 0 && index < prepared.count, "prepared_container_end: invalid index")
	kind := prepared_nodes(prepared)[index].kind
	if kind == .Attachment || kind == .Scroll || kind == .Grid_Cell {
		assert(index >= 0 && index < i32(len(prepared_nodes(prepared))))
		assert(prepared_child_count(prepared, prepared_nodes(prepared)[index].first_child) == 1)
	}
	if kind == .Grid_Cell {
		parent := prepared_nodes(prepared)[index].parent
		assert(parent >= 0 && prepared_nodes(prepared)[parent].kind == .Grid)
	}
	prepared.depth -= 1
}

@(private = "package")
prepared_label_spec :: proc(
	prepared: ^Prepared_Ui,
	spec: Label_Spec,
	track: Track = {},
	sizing: Prepared_Size = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_label_spec: description not open")
	assert(spec.text != "", "prepared_label_spec: empty text")
	return prepared_add(
		prepared,
		Prepared_Node{kind = .Label, label = spec, track = track, sizing = sizing},
	)
}

@(private = "package")
prepared_label_text :: proc(
	prepared: ^Prepared_Ui,
	text: string,
	options: Prepared_Label_Options = {},
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_label_text: description not open")
	assert(text != "", "prepared_label_text: empty text")
	return prepared_label_spec(
		prepared,
		{text = text, role = options.role, ink = options.ink, wrap = options.wrap},
		track,
		options.size,
	)
}

prepared_label :: proc {
	prepared_label_spec,
	prepared_label_text,
}

@(private = "package")
prepared_button_spec :: proc(
	prepared: ^Prepared_Ui,
	spec: Button_Spec,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_button_spec: description not open")
	assert(spec.id != WIDGET_ID_NONE, "prepared_button_spec: zero stable id")
	assert(spec.label != "", "prepared_button_spec: empty label")
	return prepared_add(prepared, Prepared_Node{kind = .Button, button = spec, track = track})
}

@(private = "package")
prepared_button_id :: proc(
	prepared: ^Prepared_Ui,
	widget: Widget_Id,
	label: string,
	options: Button_Options = {},
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_button_id: description not open")
	assert(widget != WIDGET_ID_NONE && label != "", "prepared_button_id: invalid button")
	return prepared_button_spec(prepared, button_spec(prepared.u, widget, label, options), track)
}

@(private = "package")
prepared_button_string :: proc(
	prepared: ^Prepared_Ui,
	key: string,
	label: string,
	options: Button_Options = {},
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.u != nil, "prepared_button_string: UI not bound")
	assert(key != "" && label != "", "prepared_button_string: invalid button")
	return prepared_button_id(prepared, id(prepared.u, key), label, options, track)
}

@(private = "package")
prepared_button_u64 :: proc(
	prepared: ^Prepared_Ui,
	key: u64,
	label: string,
	options: Button_Options = {},
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.u != nil, "prepared_button_u64: UI not bound")
	assert(label != "", "prepared_button_u64: empty label")
	return prepared_button_id(prepared, id(prepared.u, key), label, options, track)
}

prepared_button :: proc {
	prepared_button_spec,
	prepared_button_id,
	prepared_button_string,
	prepared_button_u64,
}

prepared_checkbox :: proc(
	prepared: ^Prepared_Ui,
	spec: Checkbox_Spec,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_checkbox: description not open")
	assert(spec.id != WIDGET_ID_NONE && spec.label != "" && spec.checked != nil)
	return prepared_add(prepared, Prepared_Node{kind = .Checkbox, checkbox = spec, track = track})
}

prepared_radio :: proc(
	prepared: ^Prepared_Ui,
	spec: Radio_Spec,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_radio: description not open")
	assert(spec.id != WIDGET_ID_NONE && spec.label != "" && spec.selected != nil)
	return prepared_add(prepared, Prepared_Node{kind = .Radio, radio = spec, track = track})
}

prepared_slider :: proc(
	prepared: ^Prepared_Ui,
	spec: Slider_Spec,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_slider: description not open")
	assert(spec.id != WIDGET_ID_NONE && spec.value != nil && spec.maximum > spec.minimum)
	assert(spec.step >= 0 && spec.a11y_label != "", "prepared_slider: invalid spec")
	return prepared_add(prepared, Prepared_Node{kind = .Slider, slider = spec, track = track})
}

prepared_text_input :: proc(
	prepared: ^Prepared_Ui,
	spec: Prepared_Text_Input,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_text_input: description not open")
	assert(
		spec.id != WIDGET_ID_NONE && prepared_text_input_source_ok(spec),
		"prepared_text_input: invalid spec",
	)
	return prepared_add(
		prepared,
		Prepared_Node{kind = .Text_Input, text_input = spec, track = track},
	)
}

prepared_progress :: proc(
	prepared: ^Prepared_Ui,
	spec: Prepared_Progress,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_progress: description not open")
	assert(spec.value >= 0 && spec.value <= 1, "prepared_progress: invalid value")
	return prepared_add(prepared, Prepared_Node{kind = .Progress, progress = spec, track = track})
}

prepared_separator :: proc(prepared: ^Prepared_Ui, track: Track = {}) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_separator: description not open")
	return prepared_add(prepared, Prepared_Node{kind = .Separator, track = track})
}

prepared_spacer :: proc(
	prepared: ^Prepared_Ui,
	spec: Prepared_Spacer,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_spacer: description not open")
	return prepared_add(prepared, Prepared_Node{kind = .Spacer, spacer = spec, track = track})
}

prepared_table_cell :: proc(
	prepared: ^Prepared_Ui,
	spec: Prepared_Table_Cell,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_table_cell: description not open")
	assert(spec.text != "", "prepared_table_cell: empty text")
	return prepared_add(
		prepared,
		Prepared_Node{kind = .Table_Cell, table_cell = spec, track = track},
	)
}

prepared_composite :: proc(
	prepared: ^Prepared_Ui,
	spec: Prepared_Composite,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_composite: description not open")
	return prepared_add(
		prepared,
		Prepared_Node{kind = .Composite, composite = spec, track = track, sizing = spec.size},
	)
}

prepared_composite_size :: proc(
	u: ^Ui,
	spec: Prepared_Composite,
	max_width: i32,
) -> Intrinsic_Size {
	assert(u != nil && u.open && max_width >= 0, "prepared composite size: invalid argument")
	switch spec.kind {
	case .Toggle:
		return toggle_spec_size(u, spec.toggle)
	case .Dropdown:
		return dropdown_spec_size(u, spec.dropdown)
	case .Combobox:
		return combobox_spec_size(u, spec.combobox)
	case .Tabs:
		return tabs_spec_size(u, spec.tabs)
	}
	unreachable()
}

prepared_composite_at :: proc(u: ^Ui, spec: Prepared_Composite, rect: Rect_I32) -> bool {
	assert(u != nil && u.open, "prepared composite render: invalid UI")
	switch spec.kind {
	case .Toggle:
		return toggle_spec_at(u, spec.toggle, rect)
	case .Dropdown:
		return dropdown_spec_at(u, spec.dropdown, rect)
	case .Combobox:
		return combobox_spec_at(u, spec.combobox, rect)
	case .Tabs:
		return tabs_spec_at(u, spec.tabs, rect)
	}
	unreachable()
}

prepared_custom :: proc(
	prepared: ^Prepared_Ui,
	spec: Prepared_Custom,
	track: Track = {},
) -> Prepared_Handle {
	assert(spec.measure != nil, "prepared_custom: nil measure procedure")
	assert(spec.render != nil, "prepared_custom: nil render procedure")
	return prepared_add(
		prepared,
		Prepared_Node{kind = .Custom, custom = spec, track = track, sizing = spec.size},
	)
}

prepared_activated :: proc(prepared: ^Prepared_Ui, handle: Prepared_Handle) -> bool {
	assert(prepared != nil && prepared.rendered, "prepared_activated: description not rendered")
	index := i32(handle)
	assert(index >= 0 && index < prepared.count, "prepared_activated: handle out of range")
	return prepared_nodes(prepared)[index].activated
}

@(private = "file")
prepared_root_begin :: proc(
	u: ^Ui,
	prepared: ^Prepared_Ui,
	kind: Prepared_Kind,
	options: Prepared_Container_Options,
) {
	assert(u != nil && u.open && u.frame != nil, "prepared_root_begin: invalid UI")
	assert(prepared != nil && !prepared.open, "prepared_root_begin: description already open")
	assert(kind == .Row || kind == .Column, "prepared_root_begin: invalid kind")
	prepared_begin(prepared, intrinsic_constraints(max_w = remaining_rect(u).w))
	prepared.u = u
	_ = prepared_container_begin(prepared, kind, options)
}

@(private = "file")
prepared_container_begin :: proc(
	prepared: ^Prepared_Ui,
	kind: Prepared_Kind,
	options: Prepared_Container_Options,
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_container_begin: description not open")
	assert(kind == .Row || kind == .Column, "prepared_container_begin: invalid kind")
	assert(prepared.depth < MAX_LAYOUT_DEPTH, "prepared_container_begin: depth out of bounds")
	handle := prepared_add(
		prepared,
		Prepared_Node {
			kind = kind,
			container = options,
			track = options.track,
			sizing = options.size,
		},
	)
	prepared_push_container(prepared, handle)
	return handle
}

@(private = "file")
prepared_push_container :: proc(prepared: ^Prepared_Ui, handle: Prepared_Handle) {
	assert(prepared != nil && prepared.open, "prepared_push_container: description not open")
	assert(prepared.depth < MAX_LAYOUT_DEPTH, "prepared_push_container: depth out of bounds")
	index := i32(handle)
	assert(index >= 0 && index < prepared.count, "prepared_push_container: invalid handle")
	prepared.stack[prepared.depth] = index
	prepared.depth += 1
}

@(private = "file")
prepared_add :: proc(prepared: ^Prepared_Ui, node: Prepared_Node) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_add: description not open")
	assert(
		prepared.depth >= 0 && prepared.depth <= len(prepared.stack),
		"prepared_add: invalid depth",
	)
	parent := i32(-1)
	if prepared.depth > 0 do parent = prepared.stack[prepared.depth - 1]
	return prepared_add_to(prepared, parent, node)
}

prepared_add_to :: proc(
	prepared: ^Prepared_Ui,
	parent_index: i32,
	node: Prepared_Node,
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_add_to: description not open")
	nodes := prepared_nodes(prepared)
	when !ODIN_DISABLE_ASSERT {
		if prepared.count < 0 || prepared.count >= i32(len(nodes)) {
			buffer: [256]u8
			message := fmt.bprintf(
				buffer[:],
				"prepared_add_to: nodes full (parent=%d count=%d capacity=%d)",
				parent_index,
				prepared.count,
				len(nodes),
			)
			assert(prepared.count >= 0 && prepared.count < i32(len(nodes)), message)
		}
	}
	index := prepared.count
	assert(parent_index >= -1 && parent_index < index, "prepared_add_to: invalid parent")
	value := node
	value.parent = parent_index
	value.first_child = -1
	value.next_sibling = -1
	value.last_child = -1
	value.child_count = 0
	depth := i32(1)
	if parent_index >= 0 {
		parent := &nodes[parent_index]
		assert(prepared_kind_is_container(parent.kind), "prepared_add_to: parent is not container")
		limit := i32(MAX_LAYOUT_FLEX)
		if parent.kind == .Flow || parent.kind == .Grid {
			limit = min(i32(len(nodes) - 1), i32(MAX_GRID_CELLS))
		}
		if parent.kind == .Attachment || parent.kind == .Scroll || parent.kind == .Grid_Cell {
			limit = 1
		}
		assert(parent.child_count < limit, "prepared_add_to: children full")
		if parent.first_child < 0 {
			parent.first_child = index
		} else {
			assert(
				parent.last_child >= 0 && parent.last_child < index,
				"prepared_add_to: invalid sibling",
			)
			nodes[parent.last_child].next_sibling = index
		}
		parent.last_child = index
		parent.child_count += 1
		ancestor := parent_index
		for ancestor >= 0 {
			assert(depth < MAX_LAYOUT_DEPTH, "prepared_add_to: depth full")
			ancestor = nodes[ancestor].parent
			depth += 1
		}
	} else {
		assert(prepared.root < 0, "prepared_add_to: multiple roots")
		prepared.root = index
	}
	nodes[index] = value
	prepared.count += 1
	prepared.summary.depends_on_width ||= prepared_axis_dependent(value.sizing.width)
	prepared.summary.depends_on_height ||= prepared_axis_dependent(value.sizing.height)
	prepared.summary.explicit_sizing ||=
		prepared_axis_explicit(value.sizing.width) ||
		prepared_axis_explicit(value.sizing.height) ||
		value.sizing.aspect.width > 0
	if value.kind == .Flow || value.kind == .Grid || value.kind == .Scroll {
		prepared.summary.depends_on_width = true
	}
	if value.parent >= 0 {
		parent_kind := nodes[value.parent].kind
		track_dependent := value.track.kind == .Grow || value.track.kind == .Percent
		if parent_kind == .Row do prepared.summary.depends_on_width ||= track_dependent
		if parent_kind == .Column do prepared.summary.depends_on_height ||= track_dependent
	}
	if prepared_kind_is_container(value.kind) {
		prepared.summary.container_count += 1
	} else {
		prepared.summary.leaf_count += 1
	}
	prepared.summary.maximum_depth = max(prepared.summary.maximum_depth, depth)
	assert(prepared.summary.leaf_count + prepared.summary.container_count == prepared.count)
	return Prepared_Handle(index)
}
