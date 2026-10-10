package ui

@(private = "package")
prepared_direct_grid_place :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared direct place: invalid argument")
	assert(prepared.direct_geometry, "prepared direct place: generic description")
	prepared_place_grid(u, prepared, prepared.root)
	for index in 1 ..< prepared.count {
		node := &prepared_nodes(prepared)[index]
		node.target_rect = node.rect
		if node.kind == .Row do prepared_place_children(u, prepared, index, false)
	}
}

@(private = "package")
prepared_assign_widths :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_assign_widths: invalid argument")
	root := &prepared_nodes(prepared)[prepared.root]
	root.rect = {
		w = root.size.w,
		h = max(root.size.h, 1),
	}
	for index in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.width_assignment_visits += 1
		node := &prepared_nodes(prepared)[index]
		if node.kind == .Row || node.kind == .Column {
			prepared_place_children(u, prepared, index, true)
		} else if node.kind == .Flow {
			prepared_place_flow(u, prepared, index)
		} else if node.kind == .Grid {
			prepared_place_grid(u, prepared, index)
		} else if node.kind == .Grid_Cell {
			prepared_place_grid_cell(prepared, index)
		} else if node.kind == .Scroll {
			prepared_place_scroll(u, prepared, index, false)
		} else if node.kind == .Attachment {
			prepared_assign_attachment_width(prepared, index)
		}
	}
}

// prepared_assign_attachment_width hands an attached subtree its own resolved
// width. Without it the subtree's width-dependent leaves (wrapped labels,
// growing text inputs) would measure at width 0 and render taller than laid out.
@(private = "file")
prepared_assign_attachment_width :: proc(prepared: ^Prepared_Ui, index: i32) {
	assert(prepared != nil && index > 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	assert(node.kind == .Attachment && node.first_child == node.last_child)
	assert(node.first_child > index && node.first_child < prepared.count)
	child := &prepared_nodes(prepared)[node.first_child]
	child.rect.w = child.size.w
	child.rect.h = max(child.rect.h, child.size.h)
}

@(private = "package")
prepared_place :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_place: invalid argument")
	assert(prepared.count > 0 && prepared.count <= i32(prepared_capacity(prepared)))
	for index in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED {
			u.frame.prepared_telemetry.placement_node_visits += 1
			u.frame.prepared_telemetry.placed_nodes += 1
		}
		node := &prepared_nodes(prepared)[index]
		node.target_rect = node.rect
		if node.kind == .Attachment {
			prepared_place_attachment(u, prepared, index)
		} else {
			prepared_apply_transition(u, node)
			prepared_place_container(u, prepared, index)
		}
	}
}

@(private = "file")
prepared_place_container :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32) {
	assert(u != nil && prepared != nil && index >= 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	if node.kind == .Row || node.kind == .Column {
		prepared_place_children(u, prepared, index, false)
	} else if node.kind == .Flow {
		prepared_place_flow(u, prepared, index)
	} else if node.kind == .Grid {
		prepared_place_grid(u, prepared, index)
	} else if node.kind == .Grid_Cell {
		prepared_place_grid_cell(prepared, index)
	} else if node.kind == .Scroll {
		prepared_place_scroll(u, prepared, index, true)
	}
}

@(private = "file")
prepared_attachment_z :: proc(prepared: ^Prepared_Ui, index: i32) -> (z: Z_Order, scoped: bool) {
	assert(prepared != nil && index >= 0 && index < prepared.count)
	nodes := prepared_nodes(prepared)
	current := nodes[index].parent
	for _ in 0 ..< prepared.count {
		if current < 0 do return
		assert(current < prepared.count, "prepared_attachment_z: invalid parent")
		if nodes[current].kind == .Attachment do return nodes[current].attachment.z, true
		current = nodes[current].parent
	}
	assert(false, "prepared_attachment_z: parent chain exceeds node count")
	return
}

@(private = "file")
prepared_place_scroll :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, interactive: bool) {
	assert(u != nil && prepared != nil && index >= 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	assert(node.kind == .Scroll && node.scroll.state != nil, "prepared scroll place: invalid node")
	assert(
		node.first_child >= 0 && node.first_child == node.last_child,
		"prepared scroll place: child count",
	)
	state := node.scroll.state
	if interactive {
		state.viewport_w = node.rect.w
		state.viewport_h = node.rect.h
		content_size := state.content_h
		viewport_size := node.rect.h
		if node.scroll.axis == .Horizontal {
			content_size = state.content_w
			viewport_size = node.rect.w
		}
		maximum := max(content_size - viewport_size, 0)
		mouse := get_mouse_position(u.frame)
		screen := frame_rect_to_screen(u.frame, rect_f32(node.rect))
		z, scoped := prepared_attachment_z(prepared, index)
		scoped = scoped && z > frame_z(u.frame)
		if scoped do z_scope_begin(u.frame, z)
		if node.scroll.focus.focus == nil && slot_visible(node.rect) {
			node.scroll.focus = focus(u, node.scroll.id)
		}
		focus_opt_click(
			u.frame,
			node.scroll.focus,
			node.rect.x,
			node.rect.y,
			node.rect.w,
			node.rect.h,
		)
		if point_in_rect(mouse, screen) && !route_occluded(u.frame, mouse) {
			wheel := get_mouse_wheel_move_v(u.frame)
			delta := wheel.y
			if node.scroll.axis == .Horizontal && wheel.x != 0 do delta = wheel.x
			when ODIN_OS == .Windows do delta *= 5
			state.offset -= delta * f32(ui_frame_sc(u.frame, 24))
		}
		if node.scroll.keyboard && focus_opt_focused(node.scroll.focus) {
			prepared_scroll_keyboard(u.frame, state, viewport_size, content_size, node.scroll.axis)
		}
		state.offset = clamp(state.offset, 0, f32(maximum))
		if scoped do z_scope_end(u.frame)
	}
	content := rect_inset(node.rect, insets_of(u, node.scroll.padding))
	child := &prepared_nodes(prepared)[node.first_child]
	if node.scroll.axis == .Horizontal {
		child.rect = {content.x - i32(state.offset), content.y, child.size.w, content.h}
	} else {
		child.rect = {content.x, content.y - i32(state.offset), content.w, child.size.h}
	}
}

@(private = "file")
prepared_scroll_keyboard :: proc(
	frame: ^Ui_Frame,
	state: ^Prepared_Scroll_State,
	viewport_size, content_size: i32,
	axis: Scroll_Axis,
) {
	assert(
		frame != nil && state != nil && viewport_size >= 0 && content_size >= 0,
		"prepared scroll keyboard: invalid argument",
	)
	step := f32(ui_frame_metrics(frame).LINE_HEIGHT)
	if axis == .Horizontal {
		if is_key_pressed_or_repeat(frame, .RIGHT) do state.offset += step
		if is_key_pressed_or_repeat(frame, .LEFT) do state.offset -= step
	} else {
		if is_key_pressed_or_repeat(frame, .DOWN) do state.offset += step
		if is_key_pressed_or_repeat(frame, .UP) do state.offset -= step
	}
	if is_key_pressed_or_repeat(frame, .PAGE_DOWN) do state.offset += f32(viewport_size)
	if is_key_pressed_or_repeat(frame, .PAGE_UP) do state.offset -= f32(viewport_size)
	if is_key_pressed(frame, .HOME) do state.offset = 0
	if is_key_pressed(frame, .END) do state.offset = f32(max(content_size - viewport_size, 0))
}

prepared_apply_transition :: proc(u: ^Ui, node: ^Prepared_Node) {
	assert(u != nil && node != nil, "prepared_apply_transition: invalid argument")
	transition := node.sizing.transition
	if node.kind == .Attachment do transition = node.attachment.transition
	if transition.state != nil {
		node.rect = transition_rect(
			u.frame,
			transition.state,
			node.target_rect,
			transition.options,
		)
	}
}

@(private = "file")
prepared_place_attachment :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32) {
	assert(u != nil && prepared != nil && index > 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	assert(node.kind == .Attachment && node.first_child == node.last_child)
	assert(node.first_child > index && node.first_child < prepared.count)
	target := prepared_attachment_target(u, prepared, index)
	width, height := node.size.w, node.size.h
	target_point := prepared_attachment_point(target, node.attachment.target_point)
	self_point := prepared_attachment_point({w = width, h = height}, node.attachment.self_point)
	x := target_point.x - self_point.x + ui_frame_sc(u.frame, node.attachment.offset_x)
	y := target_point.y - self_point.y + ui_frame_sc(u.frame, node.attachment.offset_y)
	node.target_rect = {x, y, width, height}
	if node.attachment.clamp_to_viewport {
		node.target_rect.x = clamp(node.target_rect.x, 0, max(u.screen_w - width, 0))
		node.target_rect.y = clamp(node.target_rect.y, 0, max(u.screen_h - height, 0))
	}
	node.rect = node.target_rect
	prepared_apply_transition(u, node)
	prepared_nodes(prepared)[node.first_child].rect = node.rect
}

@(private = "file")
prepared_attachment_target :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32) -> Rect_I32 {
	assert(u != nil && prepared != nil && index > 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	switch node.attachment.target_kind {
	case .Parent:
		return prepared_screen_rect(u, prepared_nodes(prepared)[node.parent].rect)
	case .Root:
		return prepared_screen_rect(u, prepared_nodes(prepared)[prepared.root].rect)
	case .Handle:
		target := i32(node.attachment.target)
		assert(target >= 0 && target < index, "prepared attachment: invalid handle")
		assert(
			!prepared_is_ancestor(prepared, index, target),
			"prepared attachment: descendant target",
		)
		return prepared_screen_rect(u, prepared_nodes(prepared)[target].rect)
	case .Screen_Rect:
		return node.attachment.target_screen
	case .Viewport:
		return {0, 0, u.screen_w, u.screen_h}
	}
	unreachable()
}

@(private = "file")
prepared_screen_rect :: proc(u: ^Ui, rect: Rect_I32) -> Rect_I32 {
	assert(u != nil && u.open && u.frame != nil, "prepared_screen_rect: invalid UI")
	value := frame_rect_to_screen(u.frame, rect_f32(rect))
	return {i32(value.x), i32(value.y), rect.w, rect.h}
}

@(private = "file")
prepared_is_ancestor :: proc(prepared: ^Prepared_Ui, ancestor, node: i32) -> bool {
	assert(prepared != nil && ancestor >= 0 && node >= 0)
	cursor := node
	for _ in 0 ..< MAX_LAYOUT_DEPTH {
		if cursor < 0 do return false
		if cursor == ancestor do return true
		cursor = prepared_nodes(prepared)[cursor].parent
	}
	assert(cursor < 0, "prepared_is_ancestor: depth bound")
	return false
}

@(private = "file")
prepared_attachment_point :: proc(rect: Rect_I32, point: Attachment_Point) -> [2]i32 {
	x, y := rect.x, rect.y
	switch point {
	case .Top, .Center, .Bottom:
		x += rect.w / 2
	case .Top_Right, .Right, .Bottom_Right:
		x += rect.w
	case .Top_Left, .Left, .Bottom_Left:
	}
	switch point {
	case .Left, .Center, .Right:
		y += rect.h / 2
	case .Bottom_Left, .Bottom, .Bottom_Right:
		y += rect.h
	case .Top_Left, .Top, .Top_Right:
	}
	return {x, y}
}

@(private = "file")
prepared_flow_line_end :: proc(
	prepared: ^Prepared_Ui,
	first: i32,
	width, gap: i32,
) -> (
	end: i32,
	count, used, height: i32,
) {
	assert(prepared != nil && first >= 0 && first < prepared.count)
	assert(width >= 0 && gap >= 0, "prepared flow line: invalid bounds")
	child := first
	for _ in 0 ..< prepared.count {
		if child < 0 do break
		value := &prepared_nodes(prepared)[child]
		if value.kind == .Attachment {
			child = value.next_sibling
			continue
		}
		item_width := value.size.w
		if value.track.kind == .Grow do item_width = ui_frame_sc(prepared.u.frame, value.track.min_size)
		before := gap if count > 0 else 0
		if count > 0 && i64(used) + i64(before) + i64(item_width) > i64(width) do break
		used = min(width, used + before + item_width)
		height = max(height, value.size.h)
		count += 1
		child = value.next_sibling
	}
	assert(count > 0, "prepared flow line: empty line")
	return child, count, used, height
}

@(private = "file")
prepared_flow_grow_sizes :: proc(
	u: ^Ui,
	prepared: ^Prepared_Ui,
	first, end, free: i32,
	result: ^[MAX_FLOW_GROW_ITEMS]i32,
) -> i32 {
	assert(u != nil && prepared != nil && result != nil, "prepared flow grow: invalid argument")
	tracks: [MAX_FLOW_GROW_ITEMS]Track
	count: i32
	child := first
	for _ in 0 ..< prepared.count {
		if child < 0 || child == end do break
		value := &prepared_nodes(prepared)[child]
		if value.kind != .Attachment && value.track.kind == .Grow {
			assert(count < MAX_FLOW_GROW_ITEMS, "prepared flow grow: line capacity exceeded")
			tracks[count] = prepared_scale_track(u, value.track)
			count += 1
		}
		child = value.next_sibling
	}
	if count > 0 do _ = track_resolve(tracks[:count], free, 0, result[:])
	return count
}

@(private = "file")
prepared_place_flow_line :: proc(
	u: ^Ui,
	prepared: ^Prepared_Ui,
	node: ^Prepared_Node,
	first, end, count, used, height, y: i32,
	content: Rect_I32,
) {
	assert(
		u != nil && prepared != nil && node != nil,
		"prepared flow place line: invalid argument",
	)
	gap := space_px(u, node.flow.gap_x)
	free := max(content.w - used, 0)
	grow_sizes: [MAX_FLOW_GROW_ITEMS]i32
	grow_count := prepared_flow_grow_sizes(u, prepared, first, end, free, &grow_sizes)
	resolved_used := content.w if grow_count > 0 else used
	leftover := max(content.w - resolved_used, 0)
	x := content.x
	between: i32
	if node.flow.justify == .Center do x += leftover / 2
	if node.flow.justify == .End do x += leftover
	if node.flow.justify == .Space_Between && count > 1 do between = leftover
	child, item_index, grow_index := first, i32(0), i32(0)
	for _ in 0 ..< prepared.count {
		if child < 0 || child == end do break
		value := &prepared_nodes(prepared)[child]
		if value.kind != .Attachment {
			width := value.size.w
			if value.track.kind == .Grow {
				width = grow_sizes[grow_index]
				grow_index += 1
			}
			offset_y: i32
			if node.flow.align == .Center do offset_y = (height - value.size.h) / 2
			if node.flow.align == .End do offset_y = height - value.size.h
			value.rect = {x, y + offset_y, min(width, content.w), value.size.h}
			x += width
			if item_index + 1 < count {
				x += gap
				if between > 0 {
					share := i64(item_index + 1) * i64(between) / i64(count - 1)
					before := i64(item_index) * i64(between) / i64(count - 1)
					x += i32(share - before)
				}
			}
			item_index += 1
		}
		child = value.next_sibling
	}
	assert(grow_index == grow_count && item_index == count, "prepared flow place line: incomplete")
}

@(private = "file")
prepared_place_flow :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32) {
	assert(u != nil && prepared != nil, "prepared_place_flow: invalid argument")
	node := &prepared_nodes(prepared)[index]
	content := rect_inset(node.rect, insets_of(u, node.flow.padding))
	child := node.first_child
	y := content.y
	for _ in 0 ..< prepared.count {
		for child >= 0 && prepared_nodes(prepared)[child].kind == .Attachment {
			child = prepared_nodes(prepared)[child].next_sibling
		}
		if child < 0 do break
		end, count, used, height := prepared_flow_line_end(
			prepared,
			child,
			content.w,
			space_px(u, node.flow.gap_x),
		)
		prepared_place_flow_line(u, prepared, node, child, end, count, used, height, y, content)
		y += height + space_px(u, node.flow.gap_y)
		child = end
	}
	assert(child < 0, "prepared_place_flow: child bound")
}

@(private = "file")
prepared_grid_items :: proc(
	prepared: ^Prepared_Ui,
	node: ^Prepared_Node,
	indices: ^[MAX_GRID_CELLS]i32,
	placements: ^[MAX_GRID_CELLS]Grid_Placement,
) -> i32 {
	assert(prepared != nil && node != nil, "prepared grid items: invalid argument")
	assert(indices != nil && placements != nil, "prepared grid items: nil output")
	count: i32
	child := node.first_child
	for _ in 0 ..< prepared.count {
		if child < 0 do break
		value := &prepared_nodes(prepared)[child]
		if value.kind != .Attachment {
			assert(count < MAX_GRID_CELLS, "prepared grid items: capacity exceeded")
			indices[count] = child
			placements[count] =
				value.grid_cell.placement if value.kind == .Grid_Cell else {-1, -1, 1, 1}
			count += 1
		}
		child = value.next_sibling
	}
	assert(child < 0, "prepared grid items: child bound")
	return count
}

@(private = "file")
prepared_place_track_grid :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, content: Rect_I32) {
	assert(u != nil && prepared != nil, "prepared track grid: invalid argument")
	node := &prepared_nodes(prepared)[index]
	column_count := len(node.grid.column_tracks)
	indices: [MAX_GRID_CELLS]i32
	placements: [MAX_GRID_CELLS]Grid_Placement
	resolved: [MAX_GRID_CELLS]Grid_Resolved_Placement
	count := prepared_grid_items(prepared, node, &indices, &placements)
	row_count := len(node.grid.row_tracks)
	if row_count == 0 {
		row_count = min((int(count) + column_count - 1) / column_count, MAX_GRID_TRACKS)
	}
	row_count = max(row_count, 1)
	columns: [MAX_GRID_TRACKS]Track
	rows: [MAX_GRID_TRACKS]Track
	for track, track_index in node.grid.column_tracks {
		columns[track_index] = prepared_scale_track(u, track)
	}
	for track, track_index in node.grid.row_tracks {
		rows[track_index] = prepared_scale_track(u, track)
	}
	if len(node.grid.row_tracks) == 0 {
		row_height := fixed(ui_frame_sc(u.frame, node.grid.row_height))
		for track_index in 0 ..< row_count do rows[track_index] = row_height
	}
	for item_index in 0 ..< count {
		placement := placements[item_index]
		placement.column_span = max(placement.column_span, 1)
		placement.row_span = max(placement.row_span, 1)
		if placement.column < 0 || placement.column_span != 1 do continue
		item := &prepared_nodes(prepared)[indices[item_index]]
		column := &columns[placement.column]
		if column.kind == .Fit || column.kind == .Hug do column.basis = max(column.basis, item.size.w)
	}
	column_sizes: [MAX_GRID_TRACKS]i32
	row_sizes: [MAX_GRID_TRACKS]i32
	_ = track_resolve(
		columns[:column_count],
		content.w,
		space_px(u, node.grid.gap_x),
		column_sizes[:],
	)
	_ = track_resolve(rows[:row_count], content.h, space_px(u, node.grid.gap_y), row_sizes[:])
	unplaced := grid_auto_place(
		placements[:count],
		i32(column_count),
		i32(row_count),
		node.grid.auto_flow,
		resolved[:],
	)
	for _ in 0 ..< unplaced do ui_frame_record_layout_overflow(u.frame)
	for item_index in 0 ..< count {
		item := &prepared_nodes(prepared)[indices[item_index]]
		if resolved[item_index].placed {
			item.rect = grid_span_rect(
				content,
				column_sizes[:column_count],
				row_sizes[:row_count],
				space_px(u, node.grid.gap_x),
				space_px(u, node.grid.gap_y),
				resolved[item_index],
			)
		} else {
			item.rect = {content.x, content.y, 0, 0}
		}
	}
}

@(private = "file")
prepared_place_grid :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32) {
	assert(u != nil && prepared != nil, "prepared_place_grid: invalid argument")
	node := &prepared_nodes(prepared)[index]
	content := rect_inset(node.rect, insets_of(u, node.grid.padding))
	if len(node.grid.column_tracks) > 0 {
		prepared_place_track_grid(u, prepared, index, content)
		return
	}
	grid: Grid
	grid_begin(
		&grid,
		content,
		node.grid.columns,
		ui_frame_sc(u.frame, node.grid.row_height),
		space_px(u, node.grid.gap_x),
		space_px(u, node.grid.gap_y),
	)
	child := node.first_child
	for _ in 0 ..< prepared.count {
		if child < 0 do break
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.child_run_visits += 1
		value := &prepared_nodes(prepared)[child]
		if value.kind != .Attachment do value.rect = grid_next(&grid)
		child = value.next_sibling
	}
	assert(child < 0, "prepared_place_grid: child bound")
	_ = grid_end(&grid)
}

@(private = "file")
prepared_place_grid_cell :: proc(prepared: ^Prepared_Ui, index: i32) {
	assert(prepared != nil && index >= 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	assert(node.kind == .Grid_Cell && node.first_child == node.last_child)
	child := &prepared_nodes(prepared)[node.first_child]
	width := child.size.w
	height := child.size.h
	if node.grid_cell.align_x == .Stretch do width = node.rect.w
	if node.grid_cell.align_y == .Stretch do height = node.rect.h
	x := node.rect.x
	y := node.rect.y
	if node.grid_cell.align_x == .Center do x += (node.rect.w - width) / 2
	if node.grid_cell.align_x == .End do x += node.rect.w - width
	if node.grid_cell.align_y == .Center do y += (node.rect.h - height) / 2
	if node.grid_cell.align_y == .End do y += node.rect.h - height
	child.rect = {x, y, min(width, node.rect.w), min(height, node.rect.h)}
}

@(private = "file")
prepared_place_children :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, widths_only: bool) {
	assert(u != nil && prepared != nil, "prepared_place_children: invalid argument")
	assert(index >= 0 && index < prepared.count, "prepared_place_children: index out of range")
	node := &prepared_nodes(prepared)[index]
	content := rect_inset(node.rect, insets_of(u, node.container.padding))
	children: [MAX_LAYOUT_FLEX]i32
	tracks: [MAX_LAYOUT_FLEX]Track
	count := prepared_children(prepared, node.first_child, &children)
	if count == 0 do return
	for child_index in 0 ..< count {
		child := &prepared_nodes(prepared)[children[child_index]]
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
		child := &prepared_nodes(prepared)[children[child_index]]
		cross_size := child.size.h if node.kind == .Row else child.size.w
		rect := flex_next_sized(&layout, cross_size)
		if widths_only {
			child.rect.w = rect.w
			child.rect.h = max(rect.h, child.size.h)
		} else {
			child.rect = rect
		}
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.width_assignments += 1
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
	for _ in 0 ..< prepared.count {
		if child < 0 do break
		assert(child < prepared.count, "prepared_children: bad child")
		value := &prepared_nodes(prepared)[child]
		if value.kind != .Attachment {
			assert(count < MAX_LAYOUT_FLEX, "prepared_children: too many children")
			result[count] = child
			count += 1
		}
		child = value.next_sibling
	}
	assert(child < 0, "prepared_children: too many children")
	return count
}

@(private = "package")
prepared_scale_track :: proc(u: ^Ui, track: Track) -> Track {
	assert(u != nil && u.frame != nil, "prepared scale track: invalid UI")
	assert(track.min_size >= 0 && (track.max_size == 0 || track.max_size >= track.min_size))
	minimum := ui_frame_sc(u.frame, track.min_size)
	maximum := ui_frame_sc(u.frame, track.max_size) if track.max_size > 0 else 0
	switch track.kind {
	case .Fit:
		return fit(ui_frame_sc(u.frame, track.basis), minimum, maximum)
	case .Hug:
		return hug(ui_frame_sc(u.frame, track.basis), minimum, maximum)
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
prepared_track_px :: proc(u: ^Ui, node: ^Prepared_Node, parent_kind: Prepared_Kind) -> Track {
	assert(u != nil && node != nil, "prepared_track_px: invalid argument")
	assert(parent_kind == .Row || parent_kind == .Column, "prepared_track_px: invalid parent")
	track := node.track
	if track.kind == .Fit && track.basis == 0 && track.min_size == 0 && track.max_size == 0 {
		basis := node.size.w if parent_kind == .Row else node.size.h
		assert(basis >= 0, "prepared_track_px: negative intrinsic basis")
		return hug(basis)
	}
	if track.kind == .Hug {
		basis := node.size.w if parent_kind == .Row else node.size.h
		track.basis = basis
		track.min_size = ui_frame_sc(u.frame, track.min_size)
		track.max_size = ui_frame_sc(u.frame, track.max_size) if track.max_size > 0 else 0
		return track
	}
	return prepared_scale_track(u, track)
}
