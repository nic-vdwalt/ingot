// ingot:gfx - per-frame batch entry points: frame begin, texture/pipeline
// binding, vertex emission (quad, tri, quad4), and the model matrix stack
// that draws consult.
package gfx

import wg "vendor:wgpu"

@(private = "package")
renderer_frame_begin :: proc(ctx: ^Context, r: ^Renderer) -> bool {
	assert(ctx != nil, "renderer_frame_begin: nil context")
	assert(r == &ctx.rend, "renderer_frame_begin: foreign renderer")
	before := ctx.submissions.count
	oldest_age := _submission_oldest_frame_age(&ctx.submissions, ctx.stats_current.frame_index)
	completed := _submission_completed(&ctx.submissions)
	after := ctx.submissions.count
	_stats_submission_pressure(ctx, before, after, 0, oldest_age)
	if !_stream_slot_acquire(r, completed) {
		_stats_stream_slot_exhaustion(ctx)
		return false
	}
	retired := &r.retired_buffers[r.active_stream_slot]
	for buffer in retired^ do wg.BufferRelease(buffer)
	clear(retired)
	// Buffers still listed here were never submitted - a submitted frame moves
	// them to retired_buffers (_stream_transients_retire) - so the only way to
	// reach this with entries is an abandoned frame. Clearing without releasing
	// leaked them, one pair per overflowing flush.
	for buffer in r.transient_buffers do wg.BufferRelease(buffer)
	clear(&r.transient_buffers)
	clear(&r.verts)
	clear(&r.indices)
	r.overflow_bytes = 0
	r.overflow_draws = 0
	renderer_state_reset(r)
	r.cur_u = r.ubind
	r.active_shader = 0
	r.model_xf = AFFINE_IDENTITY
	clear(&r.model_stack)
	return true
}

@(private)
renderer_window_projection_refresh :: proc(r: ^Renderer, queue: wg.Queue, width, height: i32) {
	assert(r != nil, "renderer_window_projection_refresh: nil renderer")
	assert(queue != nil, "renderer_window_projection_refresh: nil queue")
	projection := _window_projection(width, height)
	when GPU_TIMING_DIAGNOSTICS {
		r.diagnostic_projection = projection
	}
	wg.QueueWriteBuffer(queue, r.ubuf, 0, &projection, size_of(projection))
}

@(private)
_batch_bind :: proc(kind: Pipe_Kind, bind, current, neutral: wg.BindGroup) -> wg.BindGroup {
	assert(neutral != nil, "_batch_bind: nil neutral bind")
	if kind == .Solid && bind == nil && current != nil do return current
	if bind == nil do return neutral
	return bind
}

// batch_set switches the active pipeline/texture, flushing the pending run
// first if the state differs. Routes to the render-target pass when one is
// bound (BeginTextureMode).
@(private)
batch_set :: proc(ctx: ^Context, r: ^Renderer, kind: Pipe_Kind, bind: wg.BindGroup) {
	assert(ctx != nil, "batch_set: nil context")
	assert(r == &ctx.rend, "batch_set: foreign renderer")
	assert(r.neutral_bind != nil, "batch_set: nil neutral bind")
	context_ensure_active_pass(ctx)
	next_bind := _batch_bind(kind, bind, r.cur_bind, r.neutral_bind)
	if kind != r.cur_kind || next_bind != r.cur_bind {
		cause: Flush_Cause = kind != r.cur_kind ? .Pipeline : .Texture
		if context_active_pass_begun(ctx) {
			renderer_flush(ctx, r, context_active_pass(ctx), cause)
		}
		r.cur_kind = kind
		r.cur_bind = next_bind
	}
}

@(private)
_batch_reserve :: proc(ctx: ^Context, r: ^Renderer, vertex_count, index_count: int) -> bool {
	assert(ctx != nil, "_batch_reserve: nil context")
	assert(r == &ctx.rend, "_batch_reserve: foreign renderer")
	assert(vertex_count > 0)
	assert(index_count > 0)
	if vertex_count > BATCH_MAX_VERTICES || index_count > BATCH_MAX_INDICES do return false
	vertices_fit := len(r.verts) <= BATCH_MAX_VERTICES - vertex_count
	indices_fit := len(r.indices) <= BATCH_MAX_INDICES - index_count
	if vertices_fit && indices_fit do return true
	if !context_active_pass_begun(ctx) do return false
	renderer_flush(ctx, r, context_active_pass(ctx), .Manual)
	return(
		len(r.verts) <= BATCH_MAX_VERTICES - vertex_count &&
		len(r.indices) <= BATCH_MAX_INDICES - index_count \
	)
}

// push_quad emits two triangles for rect `d` sampling uv rect `s`.
//
// The push_* procedures are the frame-guarded entry points; the _emit_*
// procedures below them do the geometry. Splitting the two keeps the model
// transform testable against a bare Renderer, with no shared frame state for
// concurrent tests to race on.
@(private)
push_quad :: proc(
	ctx: ^Context,
	r: ^Renderer,
	d: Rectangle,
	s: Rectangle,
	col: [4]f32,
	mode: Vertex_Mode = .Solid,
) {
	assert(ctx != nil, "push_quad: nil context")
	assert(r == &ctx.rend, "push_quad: foreign renderer")
	if !ctx.frame.has_frame do return
	_emit_quad(ctx, r, d, s, col, mode)
}

// _emit_quad transforms and appends a rectangle.
//
// A rectangle survives the model transform as a rectangle only while the
// transform does not mix the axes, so a rotating transform (BeginMode2D with a
// rotation) hands the four corners to the general quad path instead.
@(private)
_emit_quad :: proc(
	ctx: ^Context,
	r: ^Renderer,
	d: Rectangle,
	s: Rectangle,
	col: [4]f32,
	mode: Vertex_Mode = .Solid,
) {
	assert(ctx != nil, "_emit_quad: nil context")
	assert(r == &ctx.rend, "_emit_quad: foreign renderer")
	u0, v0 := s.x, s.y
	u1, v1 := s.x + s.width, s.y + s.height
	if _affine_rotates(r.model_xf) {
		_emit_quad4(
			ctx,
			r,
			{d.x, d.y},
			{d.x + d.width, d.y},
			{d.x + d.width, d.y + d.height},
			{d.x, d.y + d.height},
			{u0, v0},
			{u1, v0},
			{u1, v1},
			{u0, v1},
			col,
			mode,
		)
		return
	}
	if !_batch_reserve(ctx, r, 4, 6) do return
	p0 := _affine_apply(r.model_xf, {d.x, d.y})
	p1 := _affine_apply(r.model_xf, {d.x + d.width, d.y + d.height})
	x0, y0 := p0.x, p0.y
	x1, y1 := p1.x, p1.y
	base := u32(len(r.verts))
	append(
		&r.verts,
		Vertex{{x0, y0}, col, {u0, v0}, mode},
		Vertex{{x0, y1}, col, {u0, v1}, mode},
		Vertex{{x1, y0}, col, {u1, v0}, mode},
		Vertex{{x1, y1}, col, {u1, v1}, mode},
	)
	append(&r.indices, base, base + 1, base + 2, base + 2, base + 1, base + 3)
}

@(private)
push_tri :: proc(ctx: ^Context, r: ^Renderer, a, b, c: [2]f32, col: [4]f32) {
	assert(ctx != nil, "push_tri: nil context")
	assert(r == &ctx.rend, "push_tri: foreign renderer")
	if !ctx.frame.has_frame do return
	_emit_tri(ctx, r, a, b, c, col)
}

@(private)
_emit_tri :: proc(ctx: ^Context, r: ^Renderer, a, b, c: [2]f32, col: [4]f32) {
	assert(ctx != nil, "_emit_tri: nil context")
	assert(r == &ctx.rend, "_emit_tri: foreign renderer")
	if !_batch_reserve(ctx, r, 3, 3) do return
	pa := _affine_apply(r.model_xf, a)
	pb := _affine_apply(r.model_xf, b)
	pc := _affine_apply(r.model_xf, c)
	base := u32(len(r.verts))
	append(
		&r.verts,
		Vertex{pa, col, {0, 0}, .Solid},
		Vertex{pb, col, {0, 0}, .Solid},
		Vertex{pc, col, {0, 0}, .Solid},
	)
	append(&r.indices, base, base + 1, base + 2)
}

// push_quad4 emits an arbitrary (possibly rotated) quad with per-corner uv.
// Corners must be given in order tl, tr, br, bl.
@(private)
push_quad4 :: proc(
	ctx: ^Context,
	r: ^Renderer,
	tl, tr, br, bl: [2]f32,
	uv_tl, uv_tr, uv_br, uv_bl: [2]f32,
	col: [4]f32,
	mode: Vertex_Mode = .Solid,
) {
	assert(ctx != nil, "push_quad4: nil context")
	assert(r == &ctx.rend, "push_quad4: foreign renderer")
	if !ctx.frame.has_frame do return
	_emit_quad4(ctx, r, tl, tr, br, bl, uv_tl, uv_tr, uv_br, uv_bl, col, mode)
}

@(private)
_emit_quad4 :: proc(
	ctx: ^Context,
	r: ^Renderer,
	tl, tr, br, bl: [2]f32,
	uv_tl, uv_tr, uv_br, uv_bl: [2]f32,
	col: [4]f32,
	mode: Vertex_Mode = .Solid,
) {
	assert(ctx != nil, "_emit_quad4: nil context")
	assert(r == &ctx.rend, "_emit_quad4: foreign renderer")
	if !_batch_reserve(ctx, r, 4, 6) do return
	tlo := _affine_apply(r.model_xf, tl)
	tro := _affine_apply(r.model_xf, tr)
	bro := _affine_apply(r.model_xf, br)
	blo := _affine_apply(r.model_xf, bl)
	base := u32(len(r.verts))
	append(
		&r.verts,
		Vertex{tlo, col, uv_tl, mode},
		Vertex{blo, col, uv_bl, mode},
		Vertex{tro, col, uv_tr, mode},
		Vertex{bro, col, uv_br, mode},
	)
	append(&r.indices, base, base + 1, base + 2, base + 2, base + 1, base + 3)
}

// --- model transform (rlgl matrix stack + Camera2D) -------------------------

context_matrix_mode_push :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_matrix_mode_push: nil context")
	r := &ctx.rend
	if len(r.model_stack) >= MODEL_STACK_MAX do return
	append(&r.model_stack, r.model_xf)
}

context_matrix_mode_pop :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_matrix_mode_pop: nil context")
	r := &ctx.rend
	if context_active_pass_begun(ctx) {
		renderer_flush(ctx, r, context_active_pass(ctx), .Matrix)
	}
	n := len(r.model_stack)
	if n == 0 {r.model_xf = AFFINE_IDENTITY; return}
	assert(n > 0 && n <= MODEL_STACK_MAX, "context_matrix_mode_pop: invalid stack depth")
	r.model_xf = r.model_stack[n - 1]
	pop(&r.model_stack)
}

context_matrix_mode_translate :: proc(ctx: ^Context, x, y: f32) {
	assert(ctx != nil, "context_matrix_mode_translate: nil context")
	r := &ctx.rend
	if context_active_pass_begun(ctx) {
		renderer_flush(ctx, r, context_active_pass(ctx), .Matrix)
	}
	r.model_xf = _affine_translated(r.model_xf, x, y)
}

matrix_mode_push :: proc() {
	context_matrix_mode_push(default_context())
}

matrix_mode_pop :: proc() {
	context_matrix_mode_pop(default_context())
}

matrix_mode_translate :: proc(x, y: f32) {
	context_matrix_mode_translate(default_context(), x, y)
}

// col_f converts an 8-bit Color to normalized rgba for the vertex stream.
@(private)
col_f :: proc(c: Color) -> [4]f32 {
	return {f32(c.r) / 255.0, f32(c.g) / 255.0, f32(c.b) / 255.0, f32(c.a) / 255.0}
}
