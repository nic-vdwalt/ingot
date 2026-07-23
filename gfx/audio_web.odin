#+build js
// ingot:gfx — web audio backend. Sounds are decoded/held as WebAudio buffers
// on the JS side (web/ingot_web.js, "ingot_audio" import module); each slot is
// one voice with its own GainNode, mirroring the native miniaudio pool. The
// AudioContext unlocks on the first user gesture (browser autoplay policy) —
// PlaySound calls before that are dropped silently.
//
// LoadSound/LoadMusicStream (file paths) return invalid handles on web:
// browsers have no file paths. Embed bytes and use LoadSoundFromWave, the
// target-portable path (see examples/breakout).
package gfx

foreign import audio_js "ingot_audio"
@(default_calling_convention = "c")
foreign audio_js {
	ingot_audio_init    :: proc() -> i32 ---
	ingot_audio_pcm     :: proc(pcm: [^]f32, frames: i32, channels: i32, rate: i32) -> i32 ---
	ingot_audio_unload  :: proc(slot: i32) ---
	ingot_audio_play    :: proc(slot: i32, restart: i32) ---
	ingot_audio_stop    :: proc(slot: i32) ---
	ingot_audio_playing :: proc(slot: i32) -> i32 ---
	ingot_audio_volume  :: proc(slot: i32, volume: f32) ---
	ingot_audio_pitch   :: proc(slot: i32, pitch: f32) ---
	ingot_audio_loop    :: proc(slot: i32, looping: i32) ---
	ingot_audio_master  :: proc(volume: f32) ---
}

// Slot generations mirror the native pool so stale handles are rejected the
// same way on both targets.
@(private) g_audio_gens: [MAX_SOUNDS]u16

@(private)
platform_audio_ready :: proc() -> bool { return g_audio_ready }

@(private)
platform_audio_init :: proc() -> bool {
	return ingot_audio_init() != 0
}

@(private)
platform_audio_close :: proc() {
	for i in 0 ..< MAX_SOUNDS {
		ingot_audio_unload(i32(i))
		g_audio_gens[i] += 1
	}
}

@(private)
_audio_web_resolve :: proc(handle: u32) -> i32 {
	slot := _audio_handle_slot(handle)
	if slot < 0 do return -1
	if g_audio_gens[slot] != _audio_handle_gen(handle) do return -1
	return slot
}

// platform_audio_load_file: no file system on web — operating condition, not
// a programmer error. Returns the invalid handle.
@(private)
platform_audio_load_file :: proc(fileName: cstring, stream: bool) -> (handle: u32, frames: u32) {
	assert(fileName != nil, "platform_audio_load_file: nil fileName")
	assert(g_audio_ready, "platform_audio_load_file: device not ready")
	return 0, 0
}

@(private)
platform_audio_load_pcm :: proc(samples: [^]f32, frame_count: u32, channels: u32, rate: u32) -> u32 {
	assert(samples != nil, "platform_audio_load_pcm: nil samples")
	assert(channels >= 1 && channels <= 2, "platform_audio_load_pcm: bad channels")
	slot := ingot_audio_pcm(samples, i32(frame_count), i32(channels), i32(rate))
	if slot < 0 || slot >= MAX_SOUNDS do return 0
	return _audio_handle_pack(slot, g_audio_gens[slot])
}

@(private)
platform_audio_unload :: proc(handle: u32) {
	slot := _audio_web_resolve(handle)
	if slot < 0 do return
	ingot_audio_unload(slot)
	g_audio_gens[slot] += 1
}

@(private)
platform_audio_play :: proc(handle: u32, restart: bool) {
	slot := _audio_web_resolve(handle)
	if slot < 0 do return
	ingot_audio_play(slot, restart ? 1 : 0)
}

@(private)
platform_audio_stop :: proc(handle: u32) {
	slot := _audio_web_resolve(handle)
	if slot < 0 do return
	ingot_audio_stop(slot)
}

@(private)
platform_audio_playing :: proc(handle: u32) -> bool {
	slot := _audio_web_resolve(handle)
	if slot < 0 do return false
	return ingot_audio_playing(slot) != 0
}

@(private)
platform_audio_volume :: proc(handle: u32, volume: f32) {
	assert(volume >= 0, "platform_audio_volume: negative volume")
	slot := _audio_web_resolve(handle)
	if slot < 0 do return
	ingot_audio_volume(slot, volume)
}

@(private)
platform_audio_pitch :: proc(handle: u32, pitch: f32) {
	assert(pitch > 0, "platform_audio_pitch: non-positive pitch")
	slot := _audio_web_resolve(handle)
	if slot < 0 do return
	ingot_audio_pitch(slot, pitch)
}

@(private)
platform_audio_loop :: proc(handle: u32, looping: bool) {
	slot := _audio_web_resolve(handle)
	if slot < 0 do return
	ingot_audio_loop(slot, looping ? 1 : 0)
}

@(private)
platform_audio_master :: proc(volume: f32) {
	assert(volume >= 0 && volume <= 1, "platform_audio_master: volume out of range")
	ingot_audio_master(volume)
}
