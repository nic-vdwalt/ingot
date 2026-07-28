#+build !js
// ingot:gfx - native audio backend on vendor:miniaudio (ships with Odin; no
// external libs to vendor). One ma.engine owns the output device and its
// mixing thread; sounds live in a fixed pool of MAX_SOUNDS slots with
// generation counters, so no allocation happens per play and a stale handle
// can never touch a recycled slot. All procs here are main-thread-only - the
// miniaudio device thread reads slot data through miniaudio's own
// synchronization, never through ours.
package gfx

import ma "vendor:miniaudio"

@(private)
Audio_Slot :: struct {
	used:    bool,
	gen:     u16,
	snd:     ma.sound,
	buf:     ma.audio_buffer,
	has_buf: bool,
	pcm:     []f32, // owned copy backing `buf` for wave sounds
	frames:  u32,
}

@(private)
Audio_State :: struct {
	ready:  bool,
	engine: ma.engine,
	slots:  [MAX_SOUNDS]Audio_Slot,
}

@(private)
g_audio: Audio_State

@(private)
platform_audio_ready :: proc() -> bool {return g_audio.ready}

// platform_audio_init starts the engine (and its device thread). A missing
// output device is an operating failure: report false, never assert.
@(private)
platform_audio_init :: proc() -> bool {
	res := ma.engine_init(nil, &g_audio.engine)
	return res == .SUCCESS
}

@(private)
platform_audio_close :: proc() {
	for i in 0 ..< MAX_SOUNDS {
		if g_audio.slots[i].used do _audio_slot_free(i32(i))
	}
	ma.engine_uninit(&g_audio.engine)
}

// _audio_slot_resolve maps a handle to its slot, or -1 when the handle is
// invalid or stale (generation mismatch after UnloadSound).
@(private)
_audio_slot_resolve :: proc(handle: u32) -> i32 {
	slot := _audio_handle_slot(handle)
	if slot < 0 do return -1
	s := &g_audio.slots[slot]
	if !s.used || s.gen != _audio_handle_gen(handle) do return -1
	return slot
}

@(private)
_audio_slot_alloc :: proc() -> i32 {
	for i in 0 ..< MAX_SOUNDS {
		if !g_audio.slots[i].used do return i32(i)
	}
	return -1
}

@(private)
_audio_slot_free :: proc(slot: i32) {
	assert(slot >= 0 && slot < MAX_SOUNDS, "_audio_slot_free: slot out of range")
	s := &g_audio.slots[slot]
	assert(s.used, "_audio_slot_free: slot not in use")
	ma.sound_uninit(&s.snd)
	if s.has_buf {
		ma.audio_buffer_uninit(&s.buf)
		s.has_buf = false
	}
	if s.pcm != nil {
		delete(s.pcm)
		s.pcm = nil
	}
	s.used = false
	s.gen += 1 // stale handles now fail the generation check
}

@(private)
platform_audio_load_file :: proc(fileName: cstring, stream: bool) -> (handle: u32, frames: u32) {
	assert(fileName != nil, "platform_audio_load_file: nil fileName")
	slot := _audio_slot_alloc()
	if slot < 0 do return 0, 0
	s := &g_audio.slots[slot]
	flags: ma.sound_flags = {.STREAM} if stream else {.DECODE}
	res := ma.sound_init_from_file(&g_audio.engine, fileName, flags, nil, nil, &s.snd)
	if res != .SUCCESS do return 0, 0 // missing/corrupt file: operating failure
	length: u64
	if ma.sound_get_length_in_pcm_frames(&s.snd, &length) != .SUCCESS do length = 0
	s.used = true
	s.frames = u32(min(length, u64(max(u32))))
	assert(s.gen == _audio_handle_gen(_audio_handle_pack(slot, s.gen)), "load_file: gen roundtrip")
	return _audio_handle_pack(slot, s.gen), s.frames
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
	slot := _audio_slot_alloc()
	if slot < 0 do return 0
	s := &g_audio.slots[slot]
	total := int(frame_count) * int(channels)
	s.pcm = make([]f32, total)
	for i in 0 ..< total do s.pcm[i] = samples[i]
	cfg := ma.audio_buffer_config_init(.f32, channels, u64(frame_count), raw_data(s.pcm), nil)
	cfg.sampleRate = rate
	if ma.audio_buffer_init(&cfg, &s.buf) != .SUCCESS {
		delete(s.pcm)
		s.pcm = nil
		return 0
	}
	s.has_buf = true
	// An ma.audio_buffer begins with a data_source header; miniaudio's C API
	// relies on this same cast.
	ds := (^ma.data_source)(&s.buf)
	res := ma.sound_init_from_data_source(&g_audio.engine, ds, {}, nil, &s.snd)
	if res != .SUCCESS {
		ma.audio_buffer_uninit(&s.buf)
		s.has_buf = false
		delete(s.pcm)
		s.pcm = nil
		return 0
	}
	s.used = true
	s.frames = frame_count
	return _audio_handle_pack(slot, s.gen)
}

@(private)
platform_audio_unload :: proc(handle: u32) {
	slot := _audio_slot_resolve(handle)
	if slot < 0 do return
	_audio_slot_free(slot)
}

// platform_audio_loaded: native loads are synchronous, so any handle that
// still resolves (live slot, matching generation) is ready to play.
@(private)
platform_audio_loaded :: proc(handle: u32) -> bool {
	return _audio_slot_resolve(handle) >= 0
}

@(private)
platform_audio_play :: proc(handle: u32, restart: bool) {
	slot := _audio_slot_resolve(handle)
	if slot < 0 do return
	s := &g_audio.slots[slot]
	if restart {
		_ = ma.sound_seek_to_pcm_frame(&s.snd, 0)
	}
	_ = ma.sound_start(&s.snd)
}

@(private)
platform_audio_stop :: proc(handle: u32) {
	slot := _audio_slot_resolve(handle)
	if slot < 0 do return
	_ = ma.sound_stop(&g_audio.slots[slot].snd)
}

@(private)
platform_audio_playing :: proc(handle: u32) -> bool {
	slot := _audio_slot_resolve(handle)
	if slot < 0 do return false
	return bool(ma.sound_is_playing(&g_audio.slots[slot].snd))
}

@(private)
platform_audio_volume :: proc(handle: u32, volume: f32) {
	assert(volume >= 0, "platform_audio_volume: negative volume")
	slot := _audio_slot_resolve(handle)
	if slot < 0 do return
	ma.sound_set_volume(&g_audio.slots[slot].snd, volume)
}

@(private)
platform_audio_pitch :: proc(handle: u32, pitch: f32) {
	assert(pitch > 0, "platform_audio_pitch: non-positive pitch")
	slot := _audio_slot_resolve(handle)
	if slot < 0 do return
	ma.sound_set_pitch(&g_audio.slots[slot].snd, pitch)
}

@(private)
platform_audio_loop :: proc(handle: u32, looping: bool) {
	slot := _audio_slot_resolve(handle)
	if slot < 0 do return
	ma.sound_set_looping(&g_audio.slots[slot].snd, b32(looping))
}

@(private)
platform_audio_master :: proc(volume: f32) {
	assert(volume >= 0 && volume <= 1, "platform_audio_master: volume out of range")
	_ = ma.engine_set_volume(&g_audio.engine, volume)
}
