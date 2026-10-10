package ui

prepared_measure :: proc(u: ^Ui, prepared: ^Prepared_Ui) -> Intrinsic_Size {
	assert(u != nil && u.open && u.frame != nil, "prepared_measure: invalid UI")
	assert(prepared != nil && prepared.open, "prepared_measure: description not open")
	assert(prepared.depth == 0 && prepared.count > 0, "prepared_measure: unbalanced or empty tree")
	assert(prepared.root >= 0 && prepared.root < prepared.count, "prepared_measure: invalid root")
	prepared_telemetry_describe(u.frame, prepared)
	if prepared_direct_grid_measure(u, prepared) do return prepared_nodes(prepared)[prepared.root].size
	natural_started := prepared_phase_begin(u.frame, .Measure_Natural)
	prepared_measure_natural(u, prepared)
	prepared_phase_end(u.frame, .Measure_Natural, natural_started)
	root := &prepared_nodes(prepared)[prepared.root]
	root.size = intrinsic_constrain(root.size, prepared.constraints)
	dependencies := Prepared_Dependencies {
		width  = prepared.summary.depends_on_width,
		height = prepared.summary.depends_on_height,
	}
	if dependencies.width {
		assert(
			prepared.constraints.max_w > 0,
			"prepared_measure: dependent track needs finite width",
		)
		root.size.w = prepared.constraints.max_w
	}
	if dependencies.height {
		assert(
			prepared.constraints.max_h > 0,
			"prepared_measure: dependent track needs finite height",
		)
		root.size.h = prepared.constraints.max_h
	}
	resolve_started := prepared_phase_begin(u.frame, .Resolve_Size)
	if prepared.summary.explicit_sizing {
		prepared_resolve_sizes(u, prepared)
		prepared_remeasure_containers(u, prepared)
	}
	prepared_phase_end(u.frame, .Resolve_Size, resolve_started)
	root.size = intrinsic_constrain(root.size, prepared.constraints)
	resolved_started := prepared_phase_begin(u.frame, .Measure_Resolved)
	prepared_assign_widths(u, prepared)
	prepared_measure_heights(u, prepared)
	prepared_phase_end(u.frame, .Measure_Resolved, resolved_started)
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
	assert(prepared.root >= 0, "prepared_render_at: negative root")
	assert(
		prepared.root < i32(prepared_capacity(prepared)),
		"prepared_render_at: root out of bounds",
	)
	assert(prepared.root < prepared.count, "prepared_render_at: root beyond count")
	root := &prepared_nodes(prepared)[prepared.root]
	if root.size.w > rect.w || root.size.h > rect.h {
		ui_frame_record_layout_overflow(u.frame)
	}
	if root.size.w != rect.w || root.size.h != rect.h {
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.render_relayouts += 1
		root.size.w = rect.w
		root.size.h = rect.h
		root.rect = rect
		// The render rect is the authoritative bound: re-resolve explicit
		// tracks against it so Grow and Percent land identically no matter
		// what constraints the measure pass ran under. Rendering the same
		// tree at the same rect must produce the same layout (pass
		// idempotence); skipping the height half of this left Grow-height
		// children at their stale measure-time resolution whenever only the
		// height changed, collapsing them to their natural floor.
		prepared.constraints = intrinsic_constraints(max_w = rect.w, max_h = rect.h)
		if prepared.summary.explicit_sizing {
			prepared_resolve_sizes(u, prepared)
			prepared_remeasure_containers(u, prepared)
			root.size = intrinsic_constrain(root.size, prepared.constraints)
		}
		prepared_assign_widths(u, prepared)
		prepared_measure_heights(u, prepared)
	}
	root.rect = rect
	place_started := prepared_phase_begin(u.frame, .Place)
	if prepared.direct_geometry {
		prepared_direct_grid_place(u, prepared)
		root.target_rect = root.rect
	} else {
		prepared_place(u, prepared)
	}
	prepared_phase_end(u.frame, .Place, place_started)
	render_started := prepared_phase_begin(u.frame, .Render_Tree)
	prepared_render_tree(u, prepared)
	prepared_phase_end(u.frame, .Render_Tree, render_started)
	prepared.rendered = true
	prepared.open = false
}

prepared_fit :: proc(u: ^Ui, prepared: ^Prepared_Ui) -> Rect_I32 {
	assert(u != nil && u.open, "prepared_fit: frame not open")
	assert(prepared != nil && prepared.open, "prepared_fit: description not open")
	assert(prepared.root >= 0 && prepared.root < prepared.count, "prepared_fit: invalid root")
	size := prepared_nodes(prepared)[prepared.root].size
	if !prepared.measured do size = prepared_measure(u, prepared)
	assert(size.w >= 0 && size.h >= 0 && !size.overflow, "prepared_fit: invalid size")
	rect := slot_next_px(u, size.w, size.h)
	prepared_render_at(u, prepared, rect)
	return rect
}

@(private = "file")
prepared_telemetry_describe :: proc(frame: ^Ui_Frame, prepared: ^Prepared_Ui) {
	assert(frame != nil && prepared != nil, "prepared telemetry: invalid argument")
	assert(prepared.count > 0, "prepared telemetry: empty description")
	when UI_TELEMETRY_ENABLED {
		telemetry := &frame.prepared_telemetry
		telemetry.description_nodes = u64(prepared.count)
		telemetry.leaf_nodes = u64(prepared.summary.leaf_count)
		telemetry.container_nodes = u64(prepared.summary.container_count)
		telemetry.maximum_depth = u64(prepared.summary.maximum_depth)
		telemetry.fixed_leaf_nodes = 0
		telemetry.intrinsic_leaf_nodes = 0
		telemetry.width_dependent_leaf_nodes = 0
		for index in 0 ..< prepared.count {
			node := &prepared_nodes(prepared)[index]
			if prepared_kind_is_container(node.kind) do continue
			if prepared_leaf_size_is_fixed(node) {
				telemetry.fixed_leaf_nodes += 1
			} else {
				telemetry.intrinsic_leaf_nodes += 1
			}
			if prepared_leaf_width_dependent(node) {
				telemetry.width_dependent_leaf_nodes += 1
			}
		}
		assert(telemetry.leaf_nodes == telemetry.fixed_leaf_nodes + telemetry.intrinsic_leaf_nodes)
	}
}

@(private = "file")
prepared_direct_grid_measure :: proc(u: ^Ui, prepared: ^Prepared_Ui) -> bool {
	assert(u != nil && prepared != nil, "prepared direct grid: invalid argument")
	if !prepared_direct_grid_eligible(prepared) do return false
	for index in 1 ..< prepared.count {
		node := &prepared_nodes(prepared)[index]
		if prepared_kind_is_container(node.kind) do continue
		node.size.w = prepared_axis_size(u, node.sizing.width, 0, prepared.constraints.max_w)
		node.size.h = prepared_axis_size(u, node.sizing.height, 0, prepared.constraints.max_h)
		node.measure_flags += {.Width_Valid}
	}
	for offset in 0 ..< prepared.count {
		index := prepared.count - 1 - offset
		node := &prepared_nodes(prepared)[index]
		if node.kind == .Row do prepared_measure_container(u, prepared, index, false)
	}
	root := &prepared_nodes(prepared)[prepared.root]
	prepared_measure_grid(u, prepared, prepared.root, false)
	root.size = intrinsic_constrain(root.size, prepared.constraints)
	prepared.direct_geometry = true
	prepared.measured = true
	prepared.rendered = false
	when UI_TELEMETRY_ENABLED {
		u.frame.prepared_telemetry.fixed_leaf_measure_skips += u64(prepared.summary.leaf_count)
		u.frame.prepared_telemetry.specialized_nodes += u64(prepared.count)
	}
	return true
}

@(private = "file")
prepared_direct_grid_eligible :: proc(prepared: ^Prepared_Ui) -> bool {
	assert(prepared != nil && prepared.root >= 0, "prepared direct grid: invalid description")
	root := &prepared_nodes(prepared)[prepared.root]
	if root.kind != .Grid || root.grid.row_height <= 0 do return false
	if len(root.grid.column_tracks) > 0 || len(root.grid.row_tracks) > 0 do return false
	if root.grid.effects != (Prepared_Container_Effects{}) do return false
	if root.sizing != (Prepared_Size{}) do return false
	for index in 1 ..< prepared.count {
		node := &prepared_nodes(prepared)[index]
		if node.kind == .Row {
			if node.parent != prepared.root ||
			   node.container.effects != (Prepared_Container_Effects{}) {
				return false
			}
			if node.sizing.aspect.width != 0 || node.sizing.transition.state != nil do return false
			continue
		}
		if prepared_kind_is_container(node.kind) || !prepared_leaf_size_is_fixed(node) do return false
		parent := &prepared_nodes(prepared)[node.parent]
		if parent.kind != .Grid && parent.kind != .Row do return false
		if node.sizing.aspect.width != 0 || node.sizing.transition.state != nil do return false
	}
	return true
}

prepared_measure_natural :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_measure_natural: invalid argument")
	assert(prepared.count > 0 && prepared.count <= i32(prepared_capacity(prepared)))
	for offset in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.natural_node_visits += 1
		index := prepared.count - 1 - offset
		node := &prepared_nodes(prepared)[index]
		if node.kind == .Flow {
			prepared_measure_flow(u, prepared, index, false)
		} else if node.kind == .Grid {
			prepared_measure_grid(u, prepared, index, false)
		} else if node.kind == .Grid_Cell {
			prepared_measure_grid_cell(prepared, index)
		} else if node.kind == .Attachment {
			prepared_measure_attachment(prepared, index)
		} else if node.kind == .Scroll {
			prepared_measure_scroll(u, prepared, index, false)
		} else if prepared_kind_is_container(node.kind) {
			prepared_measure_container(u, prepared, index, false)
		} else {
			if prepared_leaf_width_dependent(node) {
				node.measure_flags += {.Width_Dependent}
			}
			if prepared_leaf_size_is_fixed(node) {
				when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.fixed_leaf_measure_skips += 1
			} else if prepared_leaf_needs_natural(prepared, index) {
				prepared_measure_leaf(u, node, 0)
				node.measure_flags += {.Natural_Valid}
				when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.natural_leaf_measures += 1
			}
		}
	}
}

@(private = "file")
prepared_leaf_needs_natural :: proc(prepared: ^Prepared_Ui, index: i32) -> bool {
	assert(prepared != nil && index >= 0, "prepared natural leaf: invalid argument")
	assert(index < prepared.count, "prepared natural leaf: index out of range")
	node := &prepared_nodes(prepared)[index]
	assert(!prepared_kind_is_container(node.kind), "prepared natural leaf: container")
	if node.parent < 0 do return true
	assert(node.parent < index, "prepared natural leaf: invalid parent")
	parent := &prepared_nodes(prepared)[node.parent]
	return parent.kind != .Grid || parent.grid.row_height <= 0
}

@(private = "file")
prepared_axis_is_fixed :: proc(track: Track) -> bool {
	return track.kind == .Fixed || (track.kind == .Fit && track.basis > 0)
}

@(private = "file")
prepared_leaf_size_is_fixed :: proc(node: ^Prepared_Node) -> bool {
	assert(node != nil, "prepared fixed leaf: nil node")
	assert(!prepared_kind_is_container(node.kind), "prepared fixed leaf: container")
	return prepared_axis_is_fixed(node.sizing.width) && prepared_axis_is_fixed(node.sizing.height)
}

@(private = "file")
prepared_leaf_width_dependent :: proc(node: ^Prepared_Node) -> bool {
	assert(node != nil, "prepared leaf dependency: nil node")
	assert(!prepared_kind_is_container(node.kind), "prepared leaf dependency: container")
	if node.kind == .Text_Input do return node.text_input.max_lines > 0
	return (node.kind == .Label && node.label.wrap) || node.kind == .Custom
}

@(private = "file")
prepared_leaf_needs_width_measure :: proc(node: ^Prepared_Node, width: i32) -> bool {
	assert(node != nil, "prepared leaf measure: nil node")
	assert(width >= 0, "prepared leaf measure: negative width")
	if prepared_leaf_size_is_fixed(node) do return false
	if .Natural_Valid not_in node.measure_flags do return true
	if .Width_Dependent not_in node.measure_flags do return false
	return .Width_Valid not_in node.measure_flags || node.measured_width != width
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
	case .Checkbox:
		node.size = checkbox_spec_size(u, node.checkbox)
	case .Radio:
		node.size = radio_spec_size(u, node.radio)
	case .Slider:
		node.size = slider_spec_size(u, node.slider)
	case .Text_Input:
		if node.text_input.max_lines > 0 && max_width > 0 {
			node.size = prepared_text_input_grown_size(u, node.text_input, max_width)
		} else {
			node.size = prepared_text_input_size(u, node.text_input)
		}
	case .Progress:
		node.size = prepared_progress_size(u, node.progress)
	case .Separator:
		node.size = prepared_separator_size(u)
	case .Spacer:
		node.size = prepared_spacer_size(u, node.spacer)
	case .Table_Cell:
		node.size = prepared_table_cell_size(u, node.table_cell)
	case .Composite:
		node.size = prepared_composite_size(u, node.composite, max_width)
	case .Custom:
		node.size = node.custom.measure(u, {max_w = max_width}, node.custom.userdata)
	case .Row, .Column, .Flow, .Grid, .Grid_Cell, .Attachment, .Scroll:
		unreachable()
	}
	assert(node.size.w >= 0 && node.size.h >= 0, "prepared_measure_leaf: invalid result")
}

@(private = "file")
prepared_measure_attachment :: proc(prepared: ^Prepared_Ui, index: i32) {
	assert(prepared != nil && index >= 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	assert(node.kind == .Attachment, "prepared_measure_attachment: wrong kind")
	assert(node.first_child >= 0 && node.first_child == node.last_child)
	node.size = prepared_nodes(prepared)[node.first_child].size
}

@(private = "file")
prepared_measure_grid_cell :: proc(prepared: ^Prepared_Ui, index: i32) {
	assert(prepared != nil && index >= 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	assert(node.kind == .Grid_Cell, "prepared_measure_grid_cell: wrong kind")
	assert(node.first_child >= 0 && node.first_child == node.last_child)
	node.size = prepared_nodes(prepared)[node.first_child].size
}

prepared_measure_scroll :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, keep_width: bool) {
	assert(u != nil && prepared != nil && index >= 0 && index < prepared.count)
	node := &prepared_nodes(prepared)[index]
	assert(node.kind == .Scroll && node.scroll.state != nil, "prepared scroll: invalid node")
	assert(
		node.first_child >= 0 && node.first_child == node.last_child,
		"prepared scroll: child count",
	)
	child := &prepared_nodes(prepared)[node.first_child]
	padding := insets_of(u, node.scroll.padding)
	node.scroll.state.content_w = child.size.w + padding.left + padding.right
	node.scroll.state.content_h = child.size.h + padding.top + padding.bottom
	node.size = intrinsic_padding(child.size, padding)
	if keep_width && node.rect.w > 0 do node.size.w = node.rect.w
}

@(private = "file")
prepared_measure_container :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, keep_width: bool) {
	assert(u != nil && prepared != nil, "prepared_measure_container: invalid argument")
	when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.container_measures += 1
	assert(index >= 0 && index < prepared.count, "prepared_measure_container: index out of range")
	node := &prepared_nodes(prepared)[index]
	children: [MAX_LAYOUT_FLEX]Intrinsic_Size
	count: i32
	child := node.first_child
	for _ in 0 ..< MAX_LAYOUT_FLEX {
		if child < 0 do break
		assert(
			child < prepared.count && count < MAX_LAYOUT_FLEX,
			"prepared_measure_container: bad child",
		)
		value := &prepared_nodes(prepared)[child]
		if value.kind != .Attachment {
			children[count] = value.size
			count += 1
		}
		child = value.next_sibling
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
prepared_measure_flow :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, keep_width: bool) {
	assert(u != nil && prepared != nil, "prepared_measure_flow: invalid argument")
	when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.container_measures += 1
	assert(index >= 0 && index < prepared.count, "prepared_measure_flow: index out of range")
	node := &prepared_nodes(prepared)[index]
	padding := insets_of(u, node.flow.padding)
	max_width := prepared.constraints.max_w
	if keep_width && node.rect.w > 0 do max_width = node.rect.w
	assert(max_width > 0, "prepared_measure_flow: finite width required")
	content_w := max(max_width - padding.left - padding.right, 0)
	flow: Flow_Layout
	flow_begin(&flow, {w = content_w}, space_px(u, node.flow.gap_x), space_px(u, node.flow.gap_y))
	child := node.first_child
	for _ in 0 ..< prepared.count {
		if child < 0 do break
		assert(child < prepared.count, "prepared_measure_flow: child out of range")
		value := &prepared_nodes(prepared)[child]
		if value.kind != .Attachment do _ = flow_next(&flow, value.size.w, value.size.h)
		child = value.next_sibling
	}
	assert(child < 0, "prepared_measure_flow: child bound")
	content := flow_end(&flow)
	node.size = intrinsic_padding(intrinsic_leaf(content.w, content.h), padding)
	if keep_width do node.size.w = max_width
}

@(private = "file")
prepared_measure_grid :: proc(u: ^Ui, prepared: ^Prepared_Ui, index: i32, keep_width: bool) {
	assert(u != nil && prepared != nil, "prepared_measure_grid: invalid argument")
	when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.container_measures += 1
	assert(index >= 0 && index < prepared.count, "prepared_measure_grid: index out of range")
	node := &prepared_nodes(prepared)[index]
	padding := insets_of(u, node.grid.padding)
	width := prepared.constraints.max_w
	if keep_width && node.rect.w > 0 do width = node.rect.w
	assert(width > 0, "prepared_measure_grid: finite width required")
	if len(node.grid.column_tracks) == 0 {
		assert(node.grid.columns > 0, "prepared_measure_grid: invalid columns")
		count := prepared_in_flow_child_count(prepared, node.first_child)
		rows := (count + node.grid.columns - 1) / node.grid.columns
		gap_y := space_px(u, node.grid.gap_y)
		row_h := ui_frame_sc(u.frame, node.grid.row_height)
		content_h := rows * row_h + max(rows - 1, 0) * gap_y
		content_w := max(width - padding.left - padding.right, 0)
		node.size = intrinsic_padding(intrinsic_leaf(content_w, content_h), padding)
		return
	}
	rows := len(node.grid.row_tracks)
	if rows == 0 {
		count := prepared_in_flow_child_count(prepared, node.first_child)
		rows = int(
			(count + i32(len(node.grid.column_tracks)) - 1) / i32(len(node.grid.column_tracks)),
		)
	}
	row_h := ui_frame_sc(u.frame, node.grid.row_height)
	content_h := i32(rows) * row_h + max(i32(rows) - 1, 0) * space_px(u, node.grid.gap_y)
	if len(node.grid.row_tracks) > 0 {
		row_tracks: [MAX_GRID_TRACKS]Track
		row_sizes: [MAX_GRID_TRACKS]i32
		for track, track_index in node.grid.row_tracks {
			row_tracks[track_index] = prepared_scale_track(u, track)
		}
		result := track_resolve(
			row_tracks[:rows],
			prepared.constraints.max_h,
			space_px(u, node.grid.gap_y),
			row_sizes[:],
		)
		content_h = result.used
	}
	node.size = intrinsic_padding(
		intrinsic_leaf(width - padding.left - padding.right, content_h),
		padding,
	)
}

@(private = "package")
prepared_child_count :: proc(prepared: ^Prepared_Ui, first: i32) -> i32 {
	assert(prepared != nil, "prepared_child_count: nil description")
	count: i32
	child := first
	for _ in 0 ..< prepared.count {
		assert(count >= 0 && count < prepared.count, "prepared_child_count: corrupt count")
		if child < 0 do break
		assert(child < prepared.count, "prepared_child_count: child out of range")
		count += 1
		child = prepared_nodes(prepared)[child].next_sibling
	}
	assert(child < 0, "prepared_child_count: child bound")
	return count
}

@(private = "file")
prepared_in_flow_child_count :: proc(prepared: ^Prepared_Ui, first: i32) -> i32 {
	assert(prepared != nil, "prepared_in_flow_child_count: nil description")
	count: i32
	child := first
	for _ in 0 ..< prepared.count {
		if child < 0 do break
		assert(child < prepared.count, "prepared_in_flow_child_count: child out of range")
		if prepared_nodes(prepared)[child].kind != .Attachment do count += 1
		child = prepared_nodes(prepared)[child].next_sibling
	}
	assert(child < 0 && count >= 0, "prepared_in_flow_child_count: child bound")
	return count
}

@(private = "package")
prepared_axis_dependent :: proc(track: Track) -> bool {
	return track.kind == .Grow || track.kind == .Percent
}

@(private = "file")
prepared_resolve_sizes :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_resolve_sizes: invalid argument")
	for index in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.resolve_node_visits += 1
		prepared_resolve_node_size(u, prepared, &prepared_nodes(prepared)[index])
	}
}

@(private = "file")
prepared_resolve_node_size :: proc(u: ^Ui, prepared: ^Prepared_Ui, node: ^Prepared_Node) {
	assert(u != nil && prepared != nil && node != nil, "prepared resolve node: invalid argument")
	prepared_validate_size(node.sizing)
	node.size.w = prepared_axis_size(u, node.sizing.width, node.size.w, prepared.constraints.max_w)
	node.size.h = prepared_axis_size(
		u,
		node.sizing.height,
		node.size.h,
		prepared.constraints.max_h,
	)
	prepared_apply_aspect(&node.size, node.sizing, prepared.constraints)
}

@(private = "file")
prepared_remeasure_containers :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_remeasure_containers: invalid argument")
	for offset in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.remeasure_node_visits += 1
		index := prepared.count - 1 - offset
		node := &prepared_nodes(prepared)[index]
		if node.kind == .Flow {
			prepared_measure_flow(u, prepared, index, false)
		} else if node.kind == .Grid {
			prepared_measure_grid(u, prepared, index, false)
		} else if node.kind == .Grid_Cell {
			prepared_measure_grid_cell(prepared, index)
		} else if node.kind == .Attachment {
			prepared_measure_attachment(prepared, index)
		} else if node.kind == .Scroll {
			prepared_measure_scroll(u, prepared, index, false)
		} else if node.kind == .Row || node.kind == .Column {
			prepared_measure_container(u, prepared, index, false)
		} else {
			continue
		}
		prepared_resolve_node_size(u, prepared, node)
	}
}

@(private = "file")
prepared_validate_size :: proc(sizing: Prepared_Size) {
	ratio := sizing.aspect
	assert(ratio.width >= 0 && ratio.height >= 0, "prepared size: negative aspect")
	assert((ratio.width == 0) == (ratio.height == 0), "prepared size: incomplete aspect")
}

@(private = "file")
prepared_apply_aspect :: proc(
	size: ^Intrinsic_Size,
	sizing: Prepared_Size,
	constraints: Intrinsic_Constraints,
) {
	assert(size != nil && size.w >= 0 && size.h >= 0, "prepared aspect: invalid size")
	ratio := sizing.aspect
	if ratio.width == 0 do return
	width_explicit := prepared_axis_explicit(sizing.width)
	height_explicit := prepared_axis_explicit(sizing.height)
	if width_explicit && height_explicit do return
	if width_explicit {
		size.h = i32(i64(size.w) * i64(ratio.height) / i64(ratio.width))
	} else if height_explicit {
		size.w = i32(i64(size.h) * i64(ratio.width) / i64(ratio.height))
	} else {
		width := size.w
		height := i32(i64(width) * i64(ratio.height) / i64(ratio.width))
		if constraints.max_h > 0 && height > constraints.max_h {
			height = constraints.max_h
			width = i32(i64(height) * i64(ratio.width) / i64(ratio.height))
		}
		size.w = width
		size.h = height
	}
	size^ = intrinsic_constrain(size^, constraints)
}

@(private = "package")
prepared_axis_explicit :: proc(track: Track) -> bool {
	return track.kind != .Fit || track.basis > 0 || track.min_size > 0 || track.max_size > 0
}

@(private = "file")
prepared_axis_size :: proc(u: ^Ui, track: Track, natural, available: i32) -> i32 {
	assert(u != nil && natural >= 0 && available >= 0, "prepared_axis_size: invalid argument")
	minimum := ui_frame_sc(u.frame, track.min_size)
	maximum := ui_frame_sc(u.frame, track.max_size) if track.max_size > 0 else 0
	result := natural
	switch track.kind {
	case .Fit:
		if track.basis > 0 do result = ui_frame_sc(u.frame, track.basis)
	case .Hug:
		result = natural
	case .Fixed:
		result = ui_frame_sc(u.frame, track.basis)
	case .Grow:
		assert(available > 0, "prepared_axis_size: grow needs finite bound")
		result = available
	case .Percent:
		assert(available > 0, "prepared_axis_size: percent needs finite bound")
		result = i32(f32(available) * track.percent)
	}
	result = max(result, minimum)
	if maximum > 0 do result = min(result, maximum)
	return result
}

@(private = "file")
prepared_measure_heights :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_measure_heights: invalid argument")
	for index in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.resolved_measure_visits += 1
		node := &prepared_nodes(prepared)[index]
		if !prepared_kind_is_container(node.kind) {
			if prepared_leaf_needs_width_measure(node, node.rect.w) {
				prepared_measure_leaf(u, node, node.rect.w)
				when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.resolved_leaf_measures += 1
			}
			node.measured_width = node.rect.w
			node.measure_flags += {.Width_Valid}
			node.size.w = prepared_axis_size(
				u,
				node.sizing.width,
				node.size.w,
				prepared.constraints.max_w,
			)
			node.size.h = prepared_axis_size(
				u,
				node.sizing.height,
				node.size.h,
				prepared.constraints.max_h,
			)
			prepared_apply_aspect(&node.size, node.sizing, prepared.constraints)
		}
	}
	for offset in 0 ..< prepared.count {
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.resolved_measure_visits += 1
		index := prepared.count - 1 - offset
		node := &prepared_nodes(prepared)[index]
		if node.kind == .Flow {
			prepared_measure_flow(u, prepared, index, true)
		} else if node.kind == .Grid {
			prepared_measure_grid(u, prepared, index, true)
		} else if node.kind == .Scroll {
			prepared_measure_scroll(u, prepared, index, true)
		} else if node.kind == .Grid_Cell {
			prepared_measure_grid_cell(prepared, index)
		} else if node.kind == .Attachment {
			prepared_measure_attachment(prepared, index)
		} else if node.kind == .Row || node.kind == .Column {
			prepared_measure_container(u, prepared, index, true)
		} else {
			continue
		}
		prepared_resolve_node_size(u, prepared, node)
	}
}
