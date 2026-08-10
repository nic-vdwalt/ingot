package main

import "base:intrinsics"
import "core:math/linalg"
import workers "ingot:box3d_workers"
import rl "ingot:gfx"
import b3 "vendor:box3d"

NUM_BOXES :: 25

State :: struct {
	world:      b3.WorldId,
	boxes:      [NUM_BOXES]b3.BodyId,
	transforms: [NUM_BOXES]b3.WorldTransform,
	camera:     rl.Camera3D,
}

box3d_step_pending: u32
state: State

main :: proc() {
	rl.InitWindow(1024, 768, "Box3D + Ingot sample")
	state.camera = {
		position   = {25, -25, 15},
		up         = {0, 0, 1},
		fovy       = 45,
		projection = .PERSPECTIVE,
	}
	rl.SetTargetFPS(60)

	world_def := b3.DefaultWorldDef()
	world_def.gravity = {0, 0, -10}
	workers.configure_world(&world_def)
	state.world = b3.CreateWorld(world_def)

	ground_body_def := b3.DefaultBodyDef()
	ground_body_def.position = {0, 0, -10}
	ground_id := b3.CreateBody(state.world, ground_body_def)

	ground_box := b3.MakeBoxHull(50, 50, 10)
	ground_shape_def := b3.DefaultShapeDef()
	_ = b3.CreateHullShape(ground_id, ground_shape_def, &ground_box.base)

	for i in 0 ..< len(state.boxes) {
		body_def := b3.DefaultBodyDef()
		body_def.type = .dynamicBody
		offset_x := f32(0.05 if i % 2 == 0 else -0.05)
		body_def.position = {offset_x, 0, 2 + f32(i) * 2.5}
		state.boxes[i] = b3.CreateBody(state.world, body_def)

		dynamic_box := b3.MakeCubeHull(1)
		shape_def := b3.DefaultShapeDef()
		shape_def.density = 1
		shape_def.baseMaterial.friction = 0.3
		_ = b3.CreateHullShape(state.boxes[i], shape_def, &dynamic_box.base)
	}
	box_transforms_sync()

	rl.run(frame)
	when ODIN_OS != .JS {
		b3.DestroyWorld(state.world)
		rl.CloseWindow()
	}
}

frame :: proc() {
	when workers.ENABLED {
		if intrinsics.atomic_load_explicit(&box3d_step_pending, .Acquire) == 0 {
			box_transforms_sync()
			intrinsics.atomic_store_explicit(&box3d_step_pending, 1, .Release)
			if !workers.request_step() {
				intrinsics.atomic_store_explicit(&box3d_step_pending, 0, .Release)
			}
		}
	} else {
		b3.World_Step(state.world, 1.0 / 60.0, 4)
		box_transforms_sync()
	}

	rl.BeginDrawing()
	rl.ClearBackground(rl.RAYWHITE)
	rl.BeginMode3D(state.camera)

	rl.DrawCube({0, 0, -2}, 100, 100, 4, rl.LIGHTGRAY)
	rl.DrawCubeWires({0, 0, -2}, 100, 100, 4, rl.GRAY)

	for transform in state.transforms {
		model := linalg.matrix4_from_trs_f32(transform.p, transform.q, [3]f32{2, 2, 2})
		rl.DrawCubeTransform(model, rl.BLUE)
		rl.DrawCubeWiresTransform(model, rl.DARKBLUE)
	}

	rl.DrawGrid(20, 5)
	rl.EndMode3D()
	rl.DrawFPS(10, 10)
	rl.DrawText("Box3D + Ingot sample", 10, 35, 20, rl.DARKGRAY)
	rl.EndDrawing()
}

box_transforms_sync :: proc() {
	for box, index in state.boxes {
		state.transforms[index] = b3.Body_GetTransform(box)
	}
}

when workers.ENABLED {
	@(export, link_name = "ingot_box3d_worker_step")
	box3d_worker_step :: proc "contextless" () -> bool {
		if !b3.World_IsValid(state.world) do return false
		b3.World_Step(state.world, 1.0 / 60.0, 4)
		intrinsics.atomic_store_explicit(&box3d_step_pending, 0, .Release)
		return true
	}
}
