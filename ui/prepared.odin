package ui

MAX_PREPARED_NODES :: 64

Prepared_Handle :: distinct i32
PREPARED_HANDLE_NONE :: Prepared_Handle(-1)

Prepared_Container_Options :: struct {
	gap:     Space,
	padding: Space,
	align:   Cross_Align,
	justify: Main_Align,
	track:   Track,
}

Label_Spec :: struct {
	text: string,
	role: Text_Role,
	ink:  Ink,
	wrap: bool,
}

Prepared_Measure_Proc :: #type proc(
	u: ^Ui,
	constraints: Intrinsic_Constraints,
	userdata: rawptr,
) -> Intrinsic_Size

Prepared_Render_Proc :: #type proc(u: ^Ui, rect: Rect_I32, userdata: rawptr) -> bool

Prepared_Custom :: struct {
	measure:  Prepared_Measure_Proc,
	render:   Prepared_Render_Proc,
	userdata: rawptr,
}

Prepared_Kind :: enum u8 {
	Row,
	Column,
	Label,
	Button,
	Custom,
}

Prepared_Node :: struct {
	kind:                     Prepared_Kind,
	parent, first_child:      i32,
	next_sibling, last_child: i32,
	track:                    Track,
	container:                Prepared_Container_Options,
	label:                    Label_Spec,
	button:                   Button_Spec,
	custom:                   Prepared_Custom,
	size:                     Intrinsic_Size,
	rect:                     Rect_I32,
	activated:                bool,
}

Prepared_Ui :: struct {
	nodes:       [MAX_PREPARED_NODES]Prepared_Node,
	stack:       [MAX_LAYOUT_DEPTH]i32,
	count:       i32,
	depth:       i32,
	root:        i32,
	constraints: Intrinsic_Constraints,
	open:        bool,
	measured:    bool,
	rendered:    bool,
}

prepared_begin :: proc(prepared: ^Prepared_Ui, constraints: Intrinsic_Constraints = {}) {
	assert(prepared != nil, "prepared_begin: nil description")
	assert(!prepared.open, "prepared_begin: description already open")
	assert(constraints.min_w >= 0 && constraints.min_h >= 0, "prepared_begin: invalid minimum")
	assert(constraints.max_w == 0 || constraints.max_w >= constraints.min_w)
	assert(constraints.max_h == 0 || constraints.max_h >= constraints.min_h)
	prepared^ = Prepared_Ui {
		root        = -1,
		constraints = constraints,
		open        = true,
	}
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

prepared_container_end :: proc(prepared: ^Prepared_Ui) {
	assert(prepared != nil && prepared.open, "prepared_container_end: description not open")
	assert(
		prepared.depth > 0 && prepared.depth <= MAX_LAYOUT_DEPTH,
		"prepared_container_end: no container",
	)
	prepared.depth -= 1
}

prepared_label :: proc(
	prepared: ^Prepared_Ui,
	spec: Label_Spec,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_label: description not open")
	assert(spec.text != "", "prepared_label: empty text")
	return prepared_add(prepared, Prepared_Node{kind = .Label, label = spec, track = track})
}

prepared_button :: proc(
	prepared: ^Prepared_Ui,
	spec: Button_Spec,
	track: Track = {},
) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_button: description not open")
	assert(spec.id != WIDGET_ID_NONE, "prepared_button: zero stable id")
	assert(spec.label != "", "prepared_button: empty label")
	return prepared_add(prepared, Prepared_Node{kind = .Button, button = spec, track = track})
}

prepared_custom :: proc(
	prepared: ^Prepared_Ui,
	spec: Prepared_Custom,
	track: Track = {},
) -> Prepared_Handle {
	assert(spec.measure != nil, "prepared_custom: nil measure procedure")
	assert(spec.render != nil, "prepared_custom: nil render procedure")
	return prepared_add(prepared, Prepared_Node{kind = .Custom, custom = spec, track = track})
}

prepared_measure :: proc(u: ^Ui, prepared: ^Prepared_Ui) -> Intrinsic_Size {
	assert(u != nil && u.open && u.frame != nil, "prepared_measure: invalid UI")
	assert(prepared != nil && prepared.open, "prepared_measure: description not open")
	assert(prepared.depth == 0 && prepared.count > 0, "prepared_measure: unbalanced or empty tree")
	assert(prepared.root >= 0 && prepared.root < prepared.count, "prepared_measure: invalid root")
	prepared_measure_natural(u, prepared)
	root := &prepared.nodes[prepared.root]
	root.size = intrinsic_constrain(root.size, prepared.constraints)
	if prepared_requires_width(prepared, prepared.root) {
		assert(
			prepared.constraints.max_w > 0,
			"prepared_measure: dependent track needs finite width",
		)
		root.size.w = prepared.constraints.max_w
	}
	prepared_assign_widths(u, prepared)
	prepared_measure_heights(u, prepared)
	root.size = intrinsic_constrain(root.size, prepared.constraints)
	assert(!root.size.overflow, "prepared_measure: intrinsic overflow")
	prepared.measured = true
	prepared.rendered = false
	return root.size
}

prepared_render_at :: proc(u: ^Ui, prepared: ^Prepared_Ui, rect: Rect_I32) {
	assert(u != nil && u.open && u.frame != nil, "prepared_render_at: invalid UI")
	assert(prepared != nil && prepared.measured, "prepared_render_at: description not measured")
	assert(!prepared.rendered && rect.w >= 0 && rect.h >= 0, "prepared_render_at: invalid render")
	root := &prepared.nodes[prepared.root]
	if root.size.w != rect.w {
		root.size.w = rect.w
		root.rect = rect
		prepared_assign_widths(u, prepared)
		prepared_measure_heights(u, prepared)
	}
	root.rect = rect
	prepared_place(u, prepared)
	for index in 0 ..< prepared.count {
		node := &prepared.nodes[index]
		switch node.kind {
		case .Label:
			prepared_render_label(u, node)
		case .Button:
			node.activated = button_spec_at(u, node.button, node.rect)
		case .Custom:
			node.activated = node.custom.render(u, node.rect, node.custom.userdata)
		case .Row, .Column:
		}
	}
	prepared.rendered = true
	prepared.open = false
}

prepared_fit :: proc(u: ^Ui, prepared: ^Prepared_Ui) -> Rect_I32 {
	assert(u != nil && u.open, "prepared_fit: frame not open")
	assert(prepared != nil && prepared.open, "prepared_fit: description not open")
	assert(prepared.root >= 0 && prepared.root < prepared.count, "prepared_fit: invalid root")
	size := prepared.nodes[prepared.root].size
	if !prepared.measured do size = prepared_measure(u, prepared)
	assert(size.w >= 0 && size.h >= 0 && !size.overflow, "prepared_fit: invalid size")
	rect := slot_next_px(u, size.w, size.h)
	prepared_render_at(u, prepared, rect)
	return rect
}

prepared_activated :: proc(prepared: ^Prepared_Ui, handle: Prepared_Handle) -> bool {
	assert(prepared != nil && prepared.rendered, "prepared_activated: description not rendered")
	index := i32(handle)
	assert(index >= 0 && index < prepared.count, "prepared_activated: handle out of range")
	return prepared.nodes[index].activated
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
		Prepared_Node{kind = kind, container = options, track = options.track},
	)
	prepared.stack[prepared.depth] = i32(handle)
	prepared.depth += 1
	return handle
}

@(private = "file")
prepared_add :: proc(prepared: ^Prepared_Ui, node: Prepared_Node) -> Prepared_Handle {
	assert(prepared != nil && prepared.open, "prepared_add: description not open")
	assert(prepared.count >= 0 && prepared.count < MAX_PREPARED_NODES, "prepared_add: nodes full")
	assert(
		prepared.depth >= 0 && prepared.depth <= MAX_LAYOUT_DEPTH,
		"prepared_add: invalid depth",
	)
	index := prepared.count
	value := node
	value.parent = -1
	value.first_child = -1
	value.next_sibling = -1
	value.last_child = -1
	if prepared.depth > 0 {
		parent_index := prepared.stack[prepared.depth - 1]
		assert(parent_index >= 0 && parent_index < index, "prepared_add: invalid parent")
		parent := &prepared.nodes[parent_index]
		value.parent = parent_index
		if parent.first_child < 0 {
			parent.first_child = index
		} else {
			assert(
				parent.last_child >= 0 && parent.last_child < index,
				"prepared_add: invalid sibling",
			)
			prepared.nodes[parent.last_child].next_sibling = index
		}
		parent.last_child = index
	} else {
		assert(prepared.root < 0, "prepared_add: multiple roots")
		prepared.root = index
	}
	prepared.nodes[index] = value
	prepared.count += 1
	return Prepared_Handle(index)
}

@(private = "file")
prepared_measure_natural :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_measure_natural: invalid argument")
	assert(prepared.count > 0 && prepared.count <= MAX_PREPARED_NODES)
	for offset in 0 ..< prepared.count {
		index := prepared.count - 1 - offset
		node := &prepared.nodes[index]
		if node.kind == .Row || node.kind == .Column {
			prepared_measure_container(u, prepared, index, false)
		} else {
			prepared_measure_leaf(u, node, 0)
		}
	}
}

@(private = "file")
prepared_measure_leaf :: proc(u: ^Ui, node: ^Prepared_Node, max_width: i32) {
	assert(u != nil && node != nil, "prepared_measure_leaf: invalid argument")
	assert(max_width >= 0, "prepared_measure_leaf: negative width")
	switch node.kind {
	case .Label:
		if node.label.wrap && max_width > 0 {
			font_size := text_role_size(u.frame, node.label.role)
			line_height := text_role_line_height(u.frame, node.label.role)
			node.size = intrinsic_leaf(
				wrapped_max_line_width_frame(u.frame, node.label.text, max_width, font_size),
				wrapped_height_px_frame(
					u.frame,
					node.label.text,
					max_width,
					font_size,
					line_height,
				),
			)
		} else {
			node.size = intrinsic_text(u, node.label.text, node.label.role)
		}
	case .Button:
		node.size = button_spec_size(u, node.button)
	case .Custom:
		node.size = node.custom.measure(u, {max_w = max_width}, node.custom.userdata)
	case .Row, .Column:
		unreachable()
	}
	assert(node.size.w >= 0 && node.size.h >= 0, "prepared_measure_leaf: invalid result")
}

@(private = "file")
prepared_measure_container :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, keep_width: bool) {
	assert(u != nil && prepared != nil, "prepared_measure_container: invalid argument")
	assert(index >= 0 && index < prepared.count, "prepared_measure_container: index out of range")
	node := &prepared.nodes[index]
	children: [MAX_LAYOUT_FLEX]Intrinsic_Size
	count: i32
	child := node.first_child
	for _ in 0 ..< MAX_LAYOUT_FLEX {
		if child < 0 do break
		assert(
			child < prepared.count && count < MAX_LAYOUT_FLEX,
			"prepared_measure_container: bad child",
		)
		children[count] = prepared.nodes[child].size
		count += 1
		child = prepared.nodes[child].next_sibling
	}
	assert(child < 0, "prepared_measure_container: too many children")
	gap := space_px(u, node.container.gap)
	size := intrinsic_row(children[:count], gap)
	if node.kind == .Column do size = intrinsic_column(children[:count], gap)
	size = intrinsic_padding(size, insets_of(u, node.container.padding))
	if keep_width && node.rect.w > 0 do size.w = node.rect.w
	node.size = size
}

@(private = "file")
prepared_requires_width :: proc(prepared: ^Prepared_Ui, index: i32) -> bool {
	assert(prepared != nil && index >= 0 && index < prepared.count)
	assert(prepared.count > 0 && prepared.count <= MAX_PREPARED_NODES)
	for node_index in 0 ..< prepared.count {
		node := prepared.nodes[node_index]
		child := node.first_child
		for _ in 0 ..< MAX_LAYOUT_FLEX {
			if child < 0 do break
			track := prepared.nodes[child].track
			if track.kind == .Grow || track.kind == .Percent do return true
			child = prepared.nodes[child].next_sibling
		}
		assert(child < 0, "prepared_requires_width: too many children")
	}
	return false
}

@(private = "file")
prepared_assign_widths :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_assign_widths: invalid argument")
	root := &prepared.nodes[prepared.root]
	root.rect = {
		w = root.size.w,
		h = max(root.size.h, 1),
	}
	for index in 0 ..< prepared.count {
		node := &prepared.nodes[index]
		if node.kind != .Row && node.kind != .Column do continue
		prepared_place_children(u, prepared, index, true)
	}
}

@(private = "file")
prepared_measure_heights :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_measure_heights: invalid argument")
	for index in 0 ..< prepared.count {
		node := &prepared.nodes[index]
		if node.kind != .Row && node.kind != .Column {
			prepared_measure_leaf(u, node, node.rect.w)
		}
	}
	for offset in 0 ..< prepared.count {
		index := prepared.count - 1 - offset
		node := &prepared.nodes[index]
		if node.kind == .Row || node.kind == .Column {
			prepared_measure_container(u, prepared, index, true)
		}
	}
}

@(private = "file")
prepared_place :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_place: invalid argument")
	assert(prepared.count > 0 && prepared.count <= MAX_PREPARED_NODES)
	for index in 0 ..< prepared.count {
		node := &prepared.nodes[index]
		if node.kind == .Row || node.kind == .Column {
			prepared_place_children(u, prepared, index, false)
		}
	}
}

@(private = "file")
prepared_place_children :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, widths_only: bool) {
	assert(u != nil && prepared != nil, "prepared_place_children: invalid argument")
	assert(index >= 0 && index < prepared.count, "prepared_place_children: index out of range")
	node := &prepared.nodes[index]
	content := rect_inset(node.rect, insets_of(u, node.container.padding))
	children: [MAX_LAYOUT_FLEX]i32
	tracks: [MAX_LAYOUT_FLEX]Track
	count := prepared_children(prepared, node.first_child, &children)
	if count == 0 do return
	for child_index in 0 ..< count {
		child := &prepared.nodes[children[child_index]]
		tracks[child_index] = prepared_track_px(u, child, node.kind)
	}
	layout: Layout
	layout_begin(&layout, content.x, content.y, content.w, content.h)
	layout_push_rect(
		&layout,
		node.kind == .Row ? .Row : .Column,
		content,
		space_px(u, node.container.gap),
		node.container.align,
	)
	axis: Flex_Axis = .Row if node.kind == .Row else .Column
	flex_begin(&layout, tracks[:count], node.container.justify, axis)
	for child_index in 0 ..< count {
		child := &prepared.nodes[children[child_index]]
		cross_size := child.size.h if node.kind == .Row else child.size.w
		rect := flex_next_sized(&layout, cross_size)
		if widths_only {
			child.rect.w = rect.w
			child.rect.h = max(rect.h, child.size.h)
		} else {
			child.rect = rect
		}
	}
	flex_end(&layout)
	layout_pop(&layout)
	layout_end(&layout)
}

@(private = "file")
prepared_children :: proc(
	prepared: ^Prepared_Ui,
	first: i32,
	result: ^[MAX_LAYOUT_FLEX]i32,
) -> i32 {
	assert(prepared != nil && result != nil, "prepared_children: invalid argument")
	count: i32
	child := first
	for _ in 0 ..< MAX_LAYOUT_FLEX {
		if child < 0 do break
		assert(child < prepared.count && count < MAX_LAYOUT_FLEX, "prepared_children: bad child")
		result[count] = child
		count += 1
		child = prepared.nodes[child].next_sibling
	}
	assert(child < 0, "prepared_children: too many children")
	return count
}

@(private = "file")
prepared_track_px :: proc(u: ^Ui, node: ^Prepared_Node, parent_kind: Prepared_Kind) -> Track {
	assert(u != nil && node != nil, "prepared_track_px: invalid argument")
	assert(parent_kind == .Row || parent_kind == .Column, "prepared_track_px: invalid parent")
	track := node.track
	if track.kind == .Fit && track.basis == 0 && track.min_size == 0 && track.max_size == 0 {
		basis := node.size.w if parent_kind == .Row else node.size.h
		return fit(basis)
	}
	minimum := ui_frame_sc(u.frame, track.min_size)
	maximum := ui_frame_sc(u.frame, track.max_size) if track.max_size > 0 else 0
	switch track.kind {
	case .Fit:
		return fit(ui_frame_sc(u.frame, track.basis), minimum, maximum)
	case .Grow:
		return grow(track.weight, minimum, maximum)
	case .Fixed:
		return fixed(ui_frame_sc(u.frame, track.basis))
	case .Percent:
		return percent(track.percent, minimum, maximum)
	}
	unreachable()
}

@(private = "file")
prepared_render_label :: proc(u: ^Ui, node: ^Prepared_Node) {
	assert(u != nil && node != nil, "prepared_render_label: invalid argument")
	assert(node.kind == .Label && node.label.text != "", "prepared_render_label: invalid node")
	if !slot_visible(node.rect) {
		_ = ui_frame_drop_degenerate(u.frame, true)
		return
	}
	if node.label.wrap {
		_ = text_wrapped(
			u.frame,
			node.label.text,
			node.rect.x,
			node.rect.y,
			node.rect.w,
			node.label.role,
			node.label.ink,
		)
	} else {
		font_size := text_role_size(u.frame, node.label.role)
		draw_text_string_frame(
			u.frame,
			node.label.text,
			node.rect.x,
			node.rect.y + (node.rect.h - font_size) / 2,
			font_size,
			text_ink(u.frame, node.label.ink),
		)
	}
	semantic_push(u.frame, .Label, node.rect, node.label.text, {})
}
