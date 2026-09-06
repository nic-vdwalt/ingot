package main

import "core:math"

Camera_Visual_Context :: struct {
	eye:              [3]f32,
	focus:            [3]f32,
	distance:         f32,
	surface_altitude: f32,
	projection_scale: f32,
	coverage:         f32,
	close_weight:     f32,
	regional_weight:  f32,
	overview_weight:  f32,
}

camera_visual_smoothstep :: proc(edge_0, edge_1, value: f32) -> f32 {
	assert(edge_1 > edge_0, "camera_visual_smoothstep: invalid band")
	t := clamp((value - edge_0) / (edge_1 - edge_0), 0, 1)
	return t * t * (3 - 2 * t)
}

camera_visual_weights :: proc(
	distance, close_start, close_end, overview_start, overview_end: f32,
) -> (close, regional, overview: f32) {
	assert(distance >= 0, "camera_visual_weights: negative distance")
	assert(close_end > close_start, "camera_visual_weights: invalid close band")
	assert(overview_start >= close_end, "camera_visual_weights: overlapping bands")
	assert(overview_end > overview_start, "camera_visual_weights: invalid overview band")
	close = 1 - camera_visual_smoothstep(close_start, close_end, distance)
	overview = camera_visual_smoothstep(overview_start, overview_end, distance)
	regional = max(0, 1 - close - overview)
	return
}

camera_visual_context_make :: proc(
	eye, focus: [3]f32,
	distance, surface_altitude, fovy, viewport_height, coverage: f32,
	close_start, close_end, overview_start, overview_end: f32,
) -> Camera_Visual_Context {
	assert(fovy > 0 && fovy < 180, "camera_visual_context_make: invalid fovy")
	assert(viewport_height > 0, "camera_visual_context_make: invalid viewport height")
	close, regional, overview := camera_visual_weights(
		distance,
		close_start,
		close_end,
		overview_start,
		overview_end,
	)
	return {
		eye = eye,
		focus = focus,
		distance = distance,
		surface_altitude = surface_altitude,
		projection_scale = viewport_height / (2 * math.tan(fovy * math.PI / 360)),
		coverage = clamp(coverage, 0, 1),
		close_weight = close,
		regional_weight = regional,
		overview_weight = overview,
	}
}
