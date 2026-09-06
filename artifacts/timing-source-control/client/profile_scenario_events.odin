package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import rl "ingot:gfx"

profile_scenario_publish :: proc(value: ^Client_State) {
	assert(value != nil, "profile_scenario_publish: nil state")
	when PROFILE_ENABLED {
		scenario := &value.profile_scenario
		if !scenario.active do return
		elapsed := rl.GetTime() - scenario.started
		phase := "warmup" if elapsed < scenario.warmup else "measured"
		if !value.was_focused do phase = "background"
		if elapsed >= scenario.warmup + scenario.duration do phase = "cooldown"
		now := rl.GetTime()
		if phase == scenario.phase && now - scenario.last_published < 1 do return
		scenario.last_published = now
		scenario.phase = phase
		path := os.get_env("AESIR_TELEMETRY", context.temp_allocator)
		if path == "" do return
		record := struct {
			kind:            string `json:"k"`,
			version:         int `json:"v"`,
			scenario:        string,
			seed:            string,
			quality:         string,
			render_scale:    f64,
			phase:           string,
			native_seconds:  f64,
			width:           i32,
			height:          i32,
			refresh_hz:      f64,
			opaque_method:   string,
			terrain_variant: string,
			terrain_sha256: string,
			terrain_validation: string,
			terrain_artifact_saved: bool,
			camera_position: [3]f32,
			camera_target:   [3]f32,
		} {
			kind            = "investigation",
			version         = 1,
			scenario        = scenario.name,
			seed            = fmt.tprintf("%d", value.world.foundation.seed),
			quality         = "fixed" if scenario.fixed else "adaptive",
			render_scale    = f64(value.performance.render_scale),
			phase           = phase,
			native_seconds  = rl.GetTime(),
			width           = rl.GetScreenWidth(),
			height          = rl.GetScreenHeight(),
			refresh_hz      = f64(value.performance.refresh_rate),
			opaque_method   = "split-pass diagnostic" if profile_opaque_split() else "intact pass",
			terrain_variant = value.terrain.profile_shader.variant,
			terrain_sha256 = string(value.terrain.profile_shader.sha256[:]),
			terrain_validation = value.terrain.profile_shader.validation,
			terrain_artifact_saved = value.terrain.profile_shader.artifact_saved,
			camera_position = value.camera.position,
			camera_target   = value.camera.target,
		}
		data, err := json.marshal(record, allocator = context.temp_allocator)
		if err == nil {
			history, open_error := os.open(
				fmt.tprintf("%s.scenario.jsonl", path),
				os.O_WRONLY | os.O_CREATE | os.O_APPEND,
			)
			if open_error == nil {
				_, write_error := os.write(history, data)
				if write_error == nil {_, _ = os.write(history, []u8{'\n'})}
				_ = os.close(history)
			}
			temporary := fmt.tprintf("%s.scenario.partial", path)
			if os.write_entire_file(temporary, data) == nil {
				_ = os.rename(temporary, fmt.tprintf("%s.scenario", path))
			}
		}
	}
}
