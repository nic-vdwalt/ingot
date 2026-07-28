#+build js
// ingot:gfx - web audio backend. Sounds are decoded/held as WebAudio buffers
// on the JS side (web/ingot_web.js, "ingot_audio" import module); each slot is
// one voice with its own GainNode, mirroring the native miniaudio pool. The
// AudioContext unlocks on the first user gesture (browser autoplay policy) -
// PlaySound calls before that are dropped silently.
//
// LoadSound/LoadMusicStream treat the file name as a URL (relative to the
// page origin): the JS bridge allocates the slot eagerly - so the handle is
// valid immediately - then fetch()es and decodeAudioData()s behind it. Plays
// issued while the decode is in flight are recorded and applied when it
// lands; poll IsSoundReady/IsMusicReady for completion. Embedded bytes via
// LoadSoundFromWave remain the synchronous path (see examples/breakout).
package gfx

foreign import audio_js "ingot_audio"
@(default_calling_convention = "c")
foreign audio_js {
	ingot_audio_init :: proc() -> i32 ---
	ingot_audio_pcm :: proc(pcm: [^]f32, frames: i32, channels: i32, rate: i32) -> i32 ---
	ingot_audio_load :: proc(url: [^]u8, url_len: i32, looping: i32) -> i32 ---
	ingot_audio_ready :: proc(slot: i32) -> i32 ---
	ingot_audio_frames :: proc(slot: i32) -> i32 ---
	ingot_audio_unload :: proc(slot: i32) ---
	ingot_audio_play :: proc(slot: i32, restart: i32) ---
	ingot_audio_stop :: proc(slot: i32) ---
	ingot_audio_playing :: proc(slot: i32) -> i32 ---
	ingot_audio_volume :: proc(slot: i32, volume: f32) ---
	ingot_audio_pitch :: proc(slot: i32, pitch: f32) ---
	ingot_audio_loop :: proc(slot: i32, looping: i32) ---
	ingot_audio_master :: proc(volume: f32) ---
}

// Slot generations mirror the native pool so stale handles are rejected the
// same way on both targets.
@(private)
Audio_State :: struct {
	ready: bool,
	gens:  [MAX_SOUNDS]u16,
}

@(private)
g_audio: Audio_State

@(private)
platform_audio_ready :: proc() -> bool {return g_audio.ready}

@(private)
platform_audio_init :: proc() -> bool {
	return ingot_audio_init() != 0
}

@(private)
platform_audio_close :: proc() {
	for i in 0 ..< MAX_SOUNDS {
		ingot_audio_unload(i32(i))
		g_audio.gens[i] += 1
	}
}

@(private)
_audio_web_resolve :: proc(handle: u32) -> i32 {
	slot := _audio_handle_slot(handle)
	if slot < 0 do return -1
	if g_audio.gens[slot] != _audio_handle_gen(handle) do return -1
	return slot
}

// platform_audio_load_file: the name is a URL fetched + decoded by the JS
// bridge. The slot (and thus the handle) is allocated eagerly; frames stays
// 0 until the async decode resolves (a failed fetch leaves the slot
// permanently silent - an operating condition, not a programmer error).
// `stream` maps to looping intent recorded on the JS slot.
@(private)
platform_audio_load_file :: proc(fileName: cstring, stream: bool) -> (handle: u32, frames: u32) {
	assert(fileName != nil, "platform_audio_load_file: nil fileName")
	assert(g_audio.ready, "platform_audio_load_file: device not ready")
	url := string(fileName)
	slot := ingot_audio_load(raw_data(url), i32(len(url)), stream ? 1 : 0)
	if slot < 0 || slot >= MAX_SOUNDS do return 0, 0
	return _audio_handle_pack(slot, g_audio.gens[slot]), u32(max(ingot_audio_frames(slot), 0))
}

// platform_audio_loaded: ready only once the JS-side fetch + decode landed
// (state 1); pending (0) and failed (2) slots are not playable.
@(private)
platform_audio_loaded :: proc(handle: u32) -> bool {
	slot := _audio_web_resolve(handle)
	if slot < 0 do return false
	return ingot_audio_ready(slot) == 1
}

@(private)
platform_audio_load_pcm :: proc(
	samples: [^]f32,
	frame_count: u32,
	channels: u32,
	rate: u32,
) -> u32 {
	assert(samples != nil, "platform_audio_load_pcm: nil samples")
	assert(channels >= 1 && channels <= 2, "platform_audio_load_pcm: bad channels")
	slot := ingot_audio_pcm(samples, i32(frame_count), i32(channels), i32(rate))
	if slot < 0 || slot >= MAX_SOUNDS do return 0
	return _audio_handle_pack(slot, g_audio.gens[slot])
}

@(private)
platform_audio_unload :: proc(handle: u32) {
	slot := _audio_web_resolve(handle)
	if slot < 0 do return
	ingot_audio_unload(slot)
	g_audio.gens[slot] += 1
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
