package ui

@(private = "package")
prepared_render_tree :: proc(u: ^Ui, prepared: ^Prepared_Ui) {
	assert(u != nil && prepared != nil, "prepared_render_tree: invalid argument")
	root := &prepared_nodes(prepared)[prepared.root]
	assert(prepared_kind_is_container(root.kind), "prepared_render_tree: leaf root")
	stack: [MAX_LAYOUT_DEPTH]Prepared_Render_Frame
	prepared_render_enter(u, root)
	when UI_TELEMETRY_ENABLED {
		u.frame.prepared_telemetry.render_node_visits += 1
		u.frame.prepared_telemetry.rendered_nodes += 1
		if !prepared.direct_geometry do u.frame.prepared_telemetry.generic_fallback_nodes += 1
	}
	stack[0] = {
		index      = prepared.root,
		next_child = root.first_child,
	}
	depth := 1
	for depth > 0 {
		frame := &stack[depth - 1]
		if frame.next_child < 0 {
			prepared_render_exit(u, &prepared_nodes(prepared)[frame.index])
			depth -= 1
			continue
		}
		child_index := frame.next_child
		assert(child_index >= 0 && child_index < prepared.count, "prepared_render_tree: bad child")
		child := &prepared_nodes(prepared)[child_index]
		when UI_TELEMETRY_ENABLED {
			u.frame.prepared_telemetry.render_node_visits += 1
			u.frame.prepared_telemetry.rendered_nodes += 1
			if !prepared.direct_geometry do u.frame.prepared_telemetry.generic_fallback_nodes += 1
		}
		frame.next_child = child.next_sibling
		if prepared_kind_is_container(child.kind) {
			assert(depth < MAX_LAYOUT_DEPTH, "prepared_render_tree: depth full")
			prepared_render_enter(u, child)
			stack[depth] = {
				index      = child_index,
				next_child = child.first_child,
			}
			depth += 1
		} else {
			prepared_render_leaf(u, child)
		}
	}
}

@(private = "file")
prepared_render_enter :: proc(u: ^Ui, node: ^Prepared_Node) {
	assert(u != nil && node != nil, "prepared_render_enter: invalid argument")
	if node.kind == .Attachment {
		claim := Rectangle{}
		if node.attachment.claim {
			claim = rect_f32(prepared_rect_union(node.rect, node.target_rect))
		}
		layer_begin(u.frame, node.attachment.z, claim)
		return
	}
	if node.kind == .Scroll {
		state := node.scroll.state
		maximum := max(state.content_h - state.viewport_h, 0)
		if node.scroll.axis == .Horizontal do maximum = max(state.content_w - state.viewport_w, 0)
		semantic_push(
			u.frame,
			.Pane,
			node.rect,
			"Scrollable content",
			focus = node.scroll.focus,
			value = state.offset,
			lo = 0,
			hi = f32(maximum),
			widget = node.scroll.id,
		)
		begin_scissor_mode(u.frame, node.rect.x, node.rect.y, node.rect.w, node.rect.h)
		return
	}
	effects := prepared_container_effects(node)
	if effects.surface.enabled {
		assert(effects.background.a == 0, "prepared container: mixed surface and background")
		assert(effects.border == .None, "prepared container: mixed surface and border")
		draw_surface(
			u.frame,
			rect_f32(node.rect),
			effects.surface.kind,
			effects.surface.state,
			effects.surface.radius,
			effects.surface.border,
			effects.surface.elevation,
		)
	}
	if effects.background.a > 0 {
		draw_rounded_fill(u.frame, rect_f32(node.rect), effects.radius, effects.background)
	}
	if effects.border != .None && effects.border_color.a > 0 {
		draw_rounded_border(
			u.frame,
			rect_f32(node.rect),
			effects.radius,
			effects.border,
			effects.border_color,
		)
	}
	if effects.clip do begin_scissor_mode(u.frame, node.rect.x, node.rect.y, node.rect.w, node.rect.h)
}

@(private = "file")
prepared_render_exit :: proc(u: ^Ui, node: ^Prepared_Node) {
	assert(u != nil && node != nil, "prepared_render_exit: invalid argument")
	if node.kind == .Attachment {
		layer_end(u.frame)
		return
	}
	if node.kind == .Scroll {
		end_scissor_mode(u.frame)
		state := node.scroll.state
		if node.scroll.axis == .Horizontal &&
		   node.scroll.bar &&
		   state.content_w > state.viewport_w {
			scrollbar_offset := scrollbar_horizontal_ex(
				u.frame,
				&state.scrollbar,
				node.rect.x + ui_frame_sc(u.frame, 2),
				node.rect.y + node.rect.h - ui_frame_sc(u.frame, 9),
				node.rect.w - ui_frame_sc(u.frame, 4),
				ui_frame_sc(u.frame, 5),
				int(state.content_w),
				int(state.viewport_w),
				int(state.offset),
			)
			if state.scrollbar.dragging do state.offset = f32(scrollbar_offset)
		} else if node.scroll.axis == .Vertical &&
		   node.scroll.bar &&
		   state.content_h > state.viewport_h {
			scrollbar_offset := scrollbar_ex(
				u.frame,
				&state.scrollbar,
				node.rect.x + node.rect.w - ui_frame_sc(u.frame, 9),
				node.rect.y + ui_frame_sc(u.frame, 2),
				ui_frame_sc(u.frame, 5),
				node.rect.h - ui_frame_sc(u.frame, 4),
				int(state.content_h),
				int(state.viewport_h),
				int(state.offset),
			)
			if state.scrollbar.dragging do state.offset = f32(scrollbar_offset)
		} else {
			state.scrollbar = {}
		}
		if focus_opt_focused(node.scroll.focus) {
			draw_focus_ring(u.frame, node.rect.x, node.rect.y, node.rect.w, node.rect.h)
		}
		return
	}
	if prepared_container_effects(node).clip do end_scissor_mode(u.frame)
}

@(private = "file")
prepared_container_effects :: proc(node: ^Prepared_Node) -> Prepared_Container_Effects {
	assert(node != nil && prepared_kind_is_container(node.kind), "prepared effects: invalid node")
	switch node.kind {
	case .Row, .Column:
		return node.container.effects
	case .Flow:
		return node.flow.effects
	case .Grid:
		return node.grid.effects
	case .Grid_Cell:
		return {}
	case .Attachment,
	     .Scroll,
	     .Label,
	     .Button,
	     .Checkbox,
	     .Radio,
	     .Slider,
	     .Text_Input,
	     .Progress,
	     .Separator,
	     .Spacer,
	     .Table_Cell,
	     .Composite,
	     .Custom:
		unreachable()
	}
	unreachable()
}

@(private = "file")
prepared_render_leaf :: proc(u: ^Ui, node: ^Prepared_Node) {
	assert(u != nil && node != nil, "prepared_render_leaf: invalid argument")
	switch node.kind {
	case .Label:
		prepared_render_label(u, node)
	case .Button:
		node.activated = button_spec_at(u, node.button, node.rect)
	case .Checkbox:
		node.activated = checkbox_spec_at(u, node.checkbox, node.rect)
	case .Radio:
		node.activated = radio_spec_at(u, node.radio, node.rect)
	case .Slider:
		node.activated = slider_spec_at(u, node.slider, node.rect)
	case .Text_Input:
		node.activated = prepared_text_input_at(u, node.text_input, node.rect)
	case .Progress:
		prepared_progress_at(u, node.progress, node.rect)
	case .Separator:
		prepared_separator_at(u, node.rect)
	case .Spacer:
	case .Table_Cell:
		prepared_table_cell_at(u, node.table_cell, node.rect)
	case .Composite:
		node.activated = prepared_composite_at(u, node.composite, node.rect)
	case .Custom:
		node.activated = node.custom.render(u, node.rect, node.custom.userdata)
	case .Row, .Column, .Flow, .Grid, .Grid_Cell, .Attachment, .Scroll:
		unreachable()
	}
	if node.activation != nil {
		node.activation^ = node.activation^ || node.activated
		when UI_TELEMETRY_ENABLED do u.frame.prepared_telemetry.activation_outputs += 1
	}
}

@(private = "file")
prepared_rect_union :: proc(a, b: Rect_I32) -> Rect_I32 {
	x0 := min(i64(a.x), i64(b.x))
	y0 := min(i64(a.y), i64(b.y))
	x1 := max(i64(a.x) + i64(a.w), i64(b.x) + i64(b.w))
	y1 := max(i64(a.y) + i64(a.h), i64(b.y) + i64(b.h))
	assert(x0 >= i64(min(i32)) && y0 >= i64(min(i32)))
	assert(x1 <= i64(max(i32)) && y1 <= i64(max(i32)))
	return {i32(x0), i32(y0), i32(x1 - x0), i32(y1 - y0)}
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
			frame_text_center_y(u.frame, node.rect.y, node.rect.h, font_size),
			font_size,
			text_ink(u.frame, node.label.ink),
		)
	}
	semantic_push(u.frame, .Label, node.rect, node.label.text, {})
}
