// ingot:gfx — raylib-shaped audio API (InitAudioDevice, LoadSound, PlaySound,
// …). The shared layer owns handle packing and PCM normalization; the device
// backend lives behind the platform_audio_* seam: audio_native.odin
// (vendor:miniaudio engine + fixed sound pool) and audio_web.odin (WebAudio
// bridge via web/ingot_web.js). Handles are generation-checked so a stale
// Sound cannot touch a recycled slot.
package gfx

// MAX_SOUNDS bounds the backend sound pool (native and web).
MAX_SOUNDS :: 256

// Sound mirrors raylib's shape where ingot consumers use it: frameCount plus
// an opaque backend handle (slot + generation; 0 = invalid).
Sound :: struct {
	frameCount: u32,
	_handle:    u32,
}

// Music is a streamed Sound (file-backed; native only). UpdateMusicStream is
// a no-op on both targets — native streams on the miniaudio device thread.
Music :: struct {
	frameCount: u32,
	looping:    bool,
	_handle:    u32,
}

// Wave is caller-owned PCM (raylib layout). Supported sampleSize: 16 (s16)
// and 32 (f32), interleaved. `data` stays owned by the caller.
Wave :: struct {
	frameCount: u32,
	sampleRate: u32,
	sampleSize: u32,
	channels:   u32,
	data:       rawptr,
}

@(private)
g_audio_ready: bool

// --- handle packing (pure; unit-tested) -------------------------------------

// _audio_handle_pack encodes slot (0-based) + generation into a non-zero u32.
@(private)
_audio_handle_pack :: proc "contextless" (slot: i32, gen: u16) -> u32 {
	if slot < 0 || slot >= MAX_SOUNDS do return 0
	return u32(gen) << 16 | u32(slot + 1)
}

// _audio_handle_slot decodes the slot index, or -1 for the invalid handle.
@(private)
_audio_handle_slot :: proc "contextless" (handle: u32) -> i32 {
	low := i32(handle & 0xFFFF)
	if low == 0 || low > MAX_SOUNDS do return -1
	return low - 1
}

// _audio_handle_gen decodes the generation counter.
@(private)
_audio_handle_gen :: proc "contextless" (handle: u32) -> u16 {
	return u16(handle >> 16)
}

// --- device lifecycle -------------------------------------------------------

// InitAudioDevice starts the backend engine. Failure (no output device,
// missing browser audio) is an operating condition: IsAudioDeviceReady stays
// false and every audio call becomes a safe no-op.
InitAudioDevice :: proc() {
	assert(!g_audio_ready, "InitAudioDevice: already initialized")
	g_audio_ready = platform_audio_init()
	assert(g_audio_ready == platform_audio_ready(), "InitAudioDevice: backend state mismatch")
}

IsAudioDeviceReady :: proc() -> bool {return g_audio_ready}

CloseAudioDevice :: proc() {
	if !g_audio_ready do return
	platform_audio_close()
	g_audio_ready = false
	assert(!platform_audio_ready(), "CloseAudioDevice: backend still ready")
}

SetMasterVolume :: proc(volume: f32) {
	assert(volume >= 0 && volume <= 100, "SetMasterVolume: volume out of range")
	if !g_audio_ready do return
	platform_audio_master(clamp(volume, 0, 1))
}

// --- sounds -----------------------------------------------------------------

// LoadSound decodes a file (wav/ogg/mp3/flac) into memory. On web the name
// is treated as a URL (relative to the page origin) and fetched + decoded
// asynchronously: the returned handle is valid immediately but stays silent
// until the decode resolves — poll IsSoundReady. A play issued while the
// fetch is in flight is applied when the decode lands.
LoadSound :: proc(fileName: cstring) -> Sound {
	assert(fileName != nil, "LoadSound: nil fileName")
	if !g_audio_ready do return Sound{}
	handle, frames := platform_audio_load_file(fileName, false)
	assert(handle == 0 || _audio_handle_slot(handle) >= 0, "LoadSound: bad handle")
	return Sound{frameCount = frames, _handle = handle}
}

// LoadSoundFromWave copies caller-owned PCM into the backend. The wave is
// normalized to interleaved f32 here so both backends share one input format.
LoadSoundFromWave :: proc(wave: Wave) -> Sound {
	assert(wave.channels >= 1 && wave.channels <= 2, "LoadSoundFromWave: unsupported channels")
	assert(
		wave.sampleSize == 16 || wave.sampleSize == 32,
		"LoadSoundFromWave: unsupported sampleSize",
	)
	if !g_audio_ready || wave.frameCount == 0 || wave.data == nil do return Sound{}
	total := int(wave.frameCount) * int(wave.channels)
	samples := make([]f32, total, context.temp_allocator)
	if wave.sampleSize == 16 {
		src16 := ([^]i16)(wave.data)
		for i in 0 ..< total {
			samples[i] = f32(src16[i]) / 32768.0
		}
	} else {
		src32 := ([^]f32)(wave.data)
		for i in 0 ..< total {
			samples[i] = src32[i]
		}
	}
	handle := platform_audio_load_pcm(
		raw_data(samples),
		wave.frameCount,
		wave.channels,
		wave.sampleRate,
	)
	assert(handle == 0 || _audio_handle_slot(handle) >= 0, "LoadSoundFromWave: bad handle")
	return Sound{frameCount = wave.frameCount, _handle = handle}
}

UnloadSound :: proc(sound: Sound) {
	if !g_audio_ready || sound._handle == 0 do return
	assert(_audio_handle_slot(sound._handle) >= 0, "UnloadSound: corrupt handle")
	platform_audio_unload(sound._handle)
}

// PlaySound restarts the sound from the beginning (raylib semantics).
PlaySound :: proc(sound: Sound) {
	if !g_audio_ready || sound._handle == 0 do return
	assert(_audio_handle_slot(sound._handle) >= 0, "PlaySound: corrupt handle")
	platform_audio_play(sound._handle, true)
}

StopSound :: proc(sound: Sound) {
	if !g_audio_ready || sound._handle == 0 do return
	assert(_audio_handle_slot(sound._handle) >= 0, "StopSound: corrupt handle")
	platform_audio_stop(sound._handle)
}

IsSoundPlaying :: proc(sound: Sound) -> bool {
	if !g_audio_ready || sound._handle == 0 do return false
	assert(_audio_handle_slot(sound._handle) >= 0, "IsSoundPlaying: corrupt handle")
	return platform_audio_playing(sound._handle)
}

SetSoundVolume :: proc(sound: Sound, volume: f32) {
	assert(volume >= 0, "SetSoundVolume: negative volume")
	if !g_audio_ready || sound._handle == 0 do return
	platform_audio_volume(sound._handle, volume)
}

SetSoundPitch :: proc(sound: Sound, pitch: f32) {
	assert(pitch > 0, "SetSoundPitch: pitch must be positive")
	if !g_audio_ready || sound._handle == 0 do return
	platform_audio_pitch(sound._handle, pitch)
}

// IsSoundReady reports whether the sound's samples are decoded and playable.
// Native loads are synchronous, so any live handle is ready; on web a
// file-backed Sound resolves asynchronously (fetch + decodeAudioData) and
// stays unready — silent to play — until the decode lands. A failed fetch
// leaves it permanently unready (operating condition, not an error).
IsSoundReady :: proc(sound: Sound) -> bool {
	if !g_audio_ready || sound._handle == 0 do return false
	assert(_audio_handle_slot(sound._handle) >= 0, "IsSoundReady: corrupt handle")
	return platform_audio_loaded(sound._handle)
}

// --- music (streamed) -------------------------------------------------------

// LoadMusicStream opens a file for streamed playback. Native streams from
// disk on the device thread; web fetches + decodes the whole file into a
// buffer asynchronously (same story as LoadSound — poll IsMusicReady).
LoadMusicStream :: proc(fileName: cstring) -> Music {
	assert(fileName != nil, "LoadMusicStream: nil fileName")
	if !g_audio_ready do return Music{}
	handle, frames := platform_audio_load_file(fileName, true)
	assert(handle == 0 || _audio_handle_slot(handle) >= 0, "LoadMusicStream: bad handle")
	return Music{frameCount = frames, looping = true, _handle = handle}
}

UnloadMusicStream :: proc(music: Music) {
	if !g_audio_ready || music._handle == 0 do return
	assert(_audio_handle_slot(music._handle) >= 0, "UnloadMusicStream: corrupt handle")
	platform_audio_unload(music._handle)
}

PlayMusicStream :: proc(music: Music) {
	if !g_audio_ready || music._handle == 0 do return
	assert(_audio_handle_slot(music._handle) >= 0, "PlayMusicStream: corrupt handle")
	platform_audio_loop(music._handle, music.looping)
	platform_audio_play(music._handle, false)
}

StopMusicStream :: proc(music: Music) {
	if !g_audio_ready || music._handle == 0 do return
	assert(_audio_handle_slot(music._handle) >= 0, "StopMusicStream: corrupt handle")
	platform_audio_stop(music._handle)
}

// UpdateMusicStream is a no-op on both targets (native streams on the device
// thread; web plays fully decoded buffers, refilled by the browser). Kept
// for raylib call-site parity.
UpdateMusicStream :: proc(music: Music) {
	assert(
		music._handle == 0 || _audio_handle_slot(music._handle) >= 0,
		"UpdateMusicStream: corrupt handle",
	)
	assert(g_audio_ready == platform_audio_ready(), "UpdateMusicStream: backend state mismatch")
}

SetMusicVolume :: proc(music: Music, volume: f32) {
	assert(volume >= 0, "SetMusicVolume: negative volume")
	if !g_audio_ready || music._handle == 0 do return
	platform_audio_volume(music._handle, volume)
}

IsMusicStreamPlaying :: proc(music: Music) -> bool {
	if !g_audio_ready || music._handle == 0 do return false
	assert(_audio_handle_slot(music._handle) >= 0, "IsMusicStreamPlaying: corrupt handle")
	return platform_audio_playing(music._handle)
}

// IsMusicReady mirrors IsSoundReady for streamed music (see that proc for
// the web async-load semantics).
IsMusicReady :: proc(music: Music) -> bool {
	if !g_audio_ready || music._handle == 0 do return false
	assert(_audio_handle_slot(music._handle) >= 0, "IsMusicReady: corrupt handle")
	return platform_audio_loaded(music._handle)
}
