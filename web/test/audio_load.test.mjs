// Async audio file loading (ingot_audio_load / ingot_audio_ready /
// ingot_audio_frames): the slot must be allocated eagerly (the engine gets a
// valid handle immediately), resolve to ready with a frame count once
// fetch + decodeAudioData land, apply play intent recorded while pending,
// and mark failed fetches as permanently errored — never throwing into the
// wasm boundary.
"use strict";

import { test } from "node:test";
import assert from "node:assert/strict";
import { install } from "./dom_stub.mjs";

class StubGainNode {
	constructor() { this.gain = { value: 1 }; }
	connect() {}
	disconnect() {}
}

class StubBufferSource {
	constructor() {
		this.playbackRate = { value: 1 };
		this.loop = false;
		this.buffer = null;
		this.onended = null;
		this.started = false;
	}
	connect() {}
	start() { this.started = true; }
	stop() {}
}

class StubAudioContext {
	constructor() { this.state = "running"; this.destination = {}; }
	createGain() { return new StubGainNode(); }
	createBufferSource() { return new StubBufferSource(); }
	createBuffer(channels, frames) { return { length: frames, numberOfChannels: channels }; }
	decodeAudioData() { return Promise.resolve({ length: 4410, numberOfChannels: 1 }); }
	resume() { this.state = "running"; return Promise.resolve(); }
}

// Let queued promise chains (fetch -> arrayBuffer -> decode -> apply) settle.
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

// ingot_web.js is a module-cached singleton: install() only fires the test
// hook on the first import, so set up once and share across tests (each test
// allocates fresh slots from the pool).
let shared = null;
async function setup() {
	if (shared) return shared;
	await install();
	globalThis.AudioContext = StubAudioContext;
	const audio = globalThis.ingotWeb.audioImports();
	// Route wasmText at a real backing buffer so URL pointers decode; the
	// http import module owns the shared wasmMemoryInterface setter.
	const memory = { buffer: new ArrayBuffer(4096) };
	globalThis.ingotWeb.httpImports({ memory });
	const urlBytes = new TextEncoder().encode("sfx/hit.ogg");
	new Uint8Array(memory.buffer).set(urlBytes, 0);
	assert.equal(audio.ingot_audio_init(), 1);
	shared = { audio, urlLen: urlBytes.length };
	return shared;
}

test("load resolves asynchronously and applies deferred play", async () => {
	const { audio, urlLen } = await setup();
	let resolveFetch = null;
	globalThis.fetch = () => new Promise((resolve) => { resolveFetch = resolve; });

	const slot = audio.ingot_audio_load(0, urlLen, 0);
	assert.ok(slot >= 0, "slot allocated eagerly");
	assert.equal(audio.ingot_audio_ready(slot), 0, "pending until decode");
	assert.equal(audio.ingot_audio_frames(slot), 0);

	// Play while the fetch is in flight: intent is recorded, not dropped.
	audio.ingot_audio_play(slot, 1);
	assert.equal(audio.ingot_audio_playing(slot), 0, "not audible yet");

	resolveFetch({ ok: true, arrayBuffer: () => Promise.resolve(new ArrayBuffer(8)) });
	await settle();

	assert.equal(audio.ingot_audio_ready(slot), 1, "ready after decode");
	assert.equal(audio.ingot_audio_frames(slot), 4410, "decoded frame count reported");
	assert.equal(audio.ingot_audio_playing(slot), 1, "deferred play applied");
});

test("failed fetch leaves a permanently silent slot", async () => {
	const { audio, urlLen } = await setup();
	globalThis.fetch = () => Promise.reject(new Error("offline"));

	const slot = audio.ingot_audio_load(0, urlLen, 0);
	assert.ok(slot >= 0);
	await settle();

	assert.equal(audio.ingot_audio_ready(slot), 2, "error state");
	assert.equal(audio.ingot_audio_frames(slot), 0);
	// Play on a failed slot must be a silent no-op, never a throw.
	audio.ingot_audio_play(slot, 1);
	assert.equal(audio.ingot_audio_playing(slot), 0);
});

test("stop cancels a deferred play", async () => {
	const { audio, urlLen } = await setup();
	let resolveFetch = null;
	globalThis.fetch = () => new Promise((resolve) => { resolveFetch = resolve; });

	const slot = audio.ingot_audio_load(0, urlLen, 1);
	audio.ingot_audio_play(slot, 0);
	audio.ingot_audio_stop(slot);

	resolveFetch({ ok: true, arrayBuffer: () => Promise.resolve(new ArrayBuffer(8)) });
	await settle();

	assert.equal(audio.ingot_audio_ready(slot), 1);
	assert.equal(audio.ingot_audio_playing(slot), 0, "stop cleared pending intent");
});

test("non-2xx response is an error, unload frees the slot mid-flight", async () => {
	const { audio, urlLen } = await setup();
	globalThis.fetch = () => Promise.resolve({ ok: false, status: 404 });

	const slot = audio.ingot_audio_load(0, urlLen, 0);
	await settle();
	assert.equal(audio.ingot_audio_ready(slot), 2, "http error -> error state");

	// Unload during flight: the late decode must not resurrect the slot.
	let resolveFetch = null;
	globalThis.fetch = () => new Promise((resolve) => { resolveFetch = resolve; });
	const slot2 = audio.ingot_audio_load(0, urlLen, 0);
	audio.ingot_audio_unload(slot2);
	resolveFetch({ ok: true, arrayBuffer: () => Promise.resolve(new ArrayBuffer(8)) });
	await settle();
	assert.equal(audio.ingot_audio_ready(slot2), 2, "unloaded slot reads as error");
});
