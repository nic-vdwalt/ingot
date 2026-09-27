"use strict";

// Crash-heartbeat GPU probes and on-device bisect switches.
//
// An iPhone capture showed every in-page metric flat (wasm heap, DOM, atlas
// count) while the tab was still killed, so the growth is in WebKit's GPU
// process. These probes report what the page can see of it: live WebGPU
// objects by type, bytes uploaded per heartbeat, and frames that reached the
// GPU. The bisect switches (?ingot_dpr, ?ingot_fps) let a phone narrow the
// cause without a debugger; they must change nothing when absent.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { fileURLToPath } from "node:url";
import { install } from "./dom_stub.mjs";

const { hook } = await install();

function loadWebGPUInterface() {
	const source = fs.readFileSync(fileURLToPath(new URL("../wgpu.js", import.meta.url)), "utf8");
	const sandbox = { window: {}, console };
	vm.createContext(sandbox);
	vm.runInContext(source, sandbox);
	return sandbox.window.odin.WebGPUInterface;
}

const WebGPUInterface = loadWebGPUInterface();

function makeInterface() {
	return new WebGPUInterface({ intSize: 4 });
}

test("live() tracks create and release per manager", () => {
	const gpu = makeInterface();
	const a = gpu.textures.create({});
	const b = gpu.textures.create({});
	gpu.bindGroups.create({});
	assert.equal(gpu.textures.live(), 2);
	gpu.textures.reference(a);
	gpu.textures.release(a);
	assert.equal(gpu.textures.live(), 2, "a referenced object survives one release");
	gpu.textures.release(a);
	gpu.textures.release(b);
	assert.equal(gpu.textures.live(), 0);
	assert.equal(gpu.bindGroups.live(), 1);
	assert.equal(gpu.textures.create(null), 0, "null creates nothing");
	assert.equal(gpu.textures.live(), 0);
});

test("liveObjectCounts sums every manager by type name", () => {
	const gpu = makeInterface();
	gpu.textures.create({});
	gpu.textureViews.create({});
	gpu.textureViews.create({});
	const counts = gpu.liveObjectCounts();
	assert.equal(counts.byName.Texture, 1);
	assert.equal(counts.byName.TextureView, 2);
	assert.equal(counts.byName.Buffer, 0);
	assert.equal(counts.total, 3);
});

test("upload bytes accumulate across writes and reset on take", () => {
	const gpu = makeInterface();
	const bytes = new Uint8Array(64);
	gpu.mem = {
		intSize: 4,
		loadBytes: (_ptr, len) => bytes.subarray(0, Number(len)),
	};
	const writes = [];
	const queue = { writeBuffer: (...args) => writes.push(args) };
	const queueIdx = gpu.queues.create(queue);
	const bufferIdx = gpu.buffers.create({ buffer: {}, mapping: null });
	const iface = gpu.getInterface();
	iface.wgpuQueueWriteBuffer(queueIdx, bufferIdx, 0n, 0, 16n);
	iface.wgpuQueueWriteBuffer(queueIdx, bufferIdx, 16, 0, 48);
	assert.equal(writes.length, 2);
	assert.equal(gpu.takeUploadBytes(), 64);
	assert.equal(gpu.takeUploadBytes(), 0, "take resets the counter");
});

test("heartbeat probes format counts, uploads and frames", () => {
	const fakeGpu = {
		liveObjectCounts: () => ({
			total: 44,
			byName: { Texture: 5, BindGroup: 31, Buffer: 6, Sampler: 2, TextureView: 0 },
		}),
		takeUploadBytes: () => 3072,
	};
	const wmi = { exports: { ingot_web_app_frame_count: () => 120 } };
	const values = Object.fromEntries(
		hook.gpuHeartbeatProbes(wmi, fakeGpu).map(([name, probe]) => [name, probe()]),
	);
	assert.equal(values.gpuObjs, 44);
	assert.equal(values.gpuTop, "BindGroup:31,Buffer:6,Texture:5,Sampler:2");
	assert.equal(values.uploadKiB, "3.0");
	assert.equal(values.appFrames, 120);
});

test("heartbeat probes report null instead of throwing", () => {
	const broken = {
		liveObjectCounts() { throw new Error("gone"); },
		takeUploadBytes() { throw new Error("gone"); },
	};
	for (const wmi of [{ exports: null }, { exports: { ingot_web_app_frame_count: () => -1 } }]) {
		for (const [name, probe] of hook.gpuHeartbeatProbes(wmi, broken)) {
			assert.equal(probe(), null, name);
		}
	}
	for (const [name, probe] of hook.gpuHeartbeatProbes(null, null)) {
		assert.equal(probe(), null, name);
	}
});

test("bisect switches parse valid values and ignore the rest", () => {
	const off = {
		dpr: 0, fps: 0, upload: "pooled", gc: false, a11y: "on", autoscroll: false,
		skip: { scissor: false, texwrite: false }, inflight: 0, capture: 0,
	};
	assert.deepEqual({ ...hook.parseBisectSwitches("") }, off);
	assert.deepEqual({ ...hook.parseBisectSwitches("?ingot_dpr=1&ingot_fps=20") }, { ...off, dpr: 1, fps: 20 });
	assert.deepEqual({ ...hook.parseBisectSwitches("?ingot_dpr=abc&ingot_fps=") }, off);
	assert.deepEqual({ ...hook.parseBisectSwitches("?ingot_dpr=0&ingot_fps=0") }, off);
	assert.deepEqual({ ...hook.parseBisectSwitches("?ingot_dpr=9&ingot_fps=1000") }, off);
	assert.deepEqual({ ...hook.parseBisectSwitches(undefined) }, off);
	assert.deepEqual({ ...hook.parseBisectSwitches("?ingot_upload=view") }, { ...off, upload: "view" });
	assert.deepEqual({ ...hook.parseBisectSwitches("?ingot_upload=other") }, off);
	assert.equal(hook.describeBisectSwitches(off), "none");
	assert.equal(hook.describeBisectSwitches({ ...off, dpr: 1, fps: 20 }), "dpr=1 fps=20");
	assert.equal(hook.describeBisectSwitches({ ...off, upload: "view" }), "upload=view");
	assert.deepEqual({ ...hook.parseBisectSwitches("?ingot_fps=off&ingot_dpr=off") }, { ...off, fps: -1, dpr: -1 });
	assert.deepEqual({ ...hook.parseBisectSwitches("?ingot_gc=1") }, { ...off, gc: true });
	assert.equal(hook.describeBisectSwitches({ ...off, fps: -1, gc: true }), "fps=off gc=1");
	assert.deepEqual({ ...hook.parseBisectSwitches("?ingot_a11y=off") }, { ...off, a11y: "off" });
	assert.deepEqual({ ...hook.parseBisectSwitches("?ingot_a11y=static") }, { ...off, a11y: "static" });
	assert.deepEqual({ ...hook.parseBisectSwitches("?ingot_a11y=x") }, off);
	assert.deepEqual({ ...hook.parseBisectSwitches("?ingot_autoscroll=1") }, { ...off, autoscroll: true });
	assert.deepEqual({ ...hook.parseBisectSwitches("?ingot_autoscroll=yes") }, off);
	assert.equal(hook.describeBisectSwitches({ ...off, a11y: "off", autoscroll: true }), "a11y=off autoscroll=1");
	assert.equal(hook.describeBisectSwitches({ ...off, a11y: "static" }), "a11y=static");
});

test("no switches in the test URL leaves the dpr cap untouched", () => {
	assert.deepEqual({ ...hook.bisectSwitches }, {
		dpr: 0, fps: 0, upload: "pooled", gc: false, a11y: "on", autoscroll: false,
		skip: { scissor: false, texwrite: false }, inflight: 0, capture: 0,
	});
	const previous = globalThis.devicePixelRatio;
	globalThis.devicePixelRatio = 2;
	try {
		assert.equal(globalThis.ingotWeb.ingotImports().ingot_device_pixel_ratio(), 2);
	} finally {
		globalThis.devicePixelRatio = previous;
	}
});

test("iOS WebKit gets default limits; URL values and off override them", () => {
	const off = hook.parseBisectSwitches("");
	assert.deepEqual(hook.resolveFrameLimits(off, false), { fps: 0, dpr: 0, ios: false });
	assert.deepEqual(hook.resolveFrameLimits(off, true), { fps: 30, dpr: 1.5, ios: true });
	assert.deepEqual(hook.resolveFrameLimits(hook.parseBisectSwitches("?ingot_fps=20&ingot_dpr=1"), true), { fps: 20, dpr: 1, ios: true });
	assert.deepEqual(hook.resolveFrameLimits(hook.parseBisectSwitches("?ingot_fps=off&ingot_dpr=off"), true), { fps: 0, dpr: 0, ios: true });
	assert.equal(hook.describeFrameLimits({ fps: 30, dpr: 1.5, ios: true }), "fps=30 dpr=1.5 ios");
	assert.equal(hook.describeFrameLimits({ fps: 0, dpr: 0, ios: false }), "fps=none dpr=none");
	assert.equal(hook.isIosWebKit({ userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_6 like Mac OS X) CriOS/154" }), true);
	assert.equal(hook.isIosWebKit({ userAgent: "Mozilla/5.0 (Macintosh)", platform: "MacIntel", maxTouchPoints: 5 }), true);
	assert.equal(hook.isIosWebKit({ userAgent: "Mozilla/5.0 (Macintosh)", platform: "MacIntel", maxTouchPoints: 0 }), false);
	assert.equal(hook.isIosWebKit({ userAgent: "Mozilla/5.0 (Linux; Android 15) Chrome/140", platform: "Linux armv8l", maxTouchPoints: 5 }), false);
	assert.equal(hook.isIosWebKit(null), false);
});

test("gpuNew reports objects created since the previous heartbeat", () => {
	const gpu = makeInterface();
	const probe = new Map(hook.gpuHeartbeatProbes({ exports: {} }, gpu)).get("gpuNew");
	assert.equal(probe(), 0);
	gpu.textures.create({});
	gpu.buffers.create({});
	assert.equal(probe(), 2);
	assert.equal(probe(), 0);
	assert.equal(new Map(hook.gpuHeartbeatProbes(null, null)).get("gpuNew")(), null);
});

test("GC nudge and tap-highlight helpers are inert without their inputs", () => {
	let intervals = 0;
	let cleared = 0;
	const win = { setInterval: () => { intervals += 1; return 7; }, clearInterval: (id) => { if (id === 7) cleared += 1; } };
	hook.installGcNudge(win, false)();
	assert.equal(intervals, 0);
	hook.installGcNudge(win, true)();
	assert.equal(intervals, 1);
	assert.equal(cleared, 1);
	const props = {};
	hook.suppressTapHighlight({ style: { setProperty: (k, v) => { props[k] = v; } } });
	assert.equal(props["-webkit-tap-highlight-color"], "transparent");
	hook.suppressTapHighlight(null);
});

// A fake window with a millisecond clock, a rAF queue flushed on 60 Hz
// vsyncs, and timers, so the cap can be driven deterministically.
function makeFakeFrameWindow() {
	const state = { now: 0, rafs: new Map(), timers: new Map(), nextRaf: 1, nextTimer: 1, maxOutstanding: 0 };
	const win = {
		performance: { now: () => state.now },
		requestAnimationFrame(cb) {
			const id = state.nextRaf++;
			state.rafs.set(id, cb);
			return id;
		},
		cancelAnimationFrame(id) {
			state.rafs.delete(id);
		},
		setTimeout(cb, ms) {
			const id = state.nextTimer++;
			state.timers.set(id, { cb, at: state.now + ms });
			return id;
		},
		clearTimeout(id) {
			state.timers.delete(id);
		},
	};
	const run = (fromMs, toMs) => {
		let nextVsync = Math.ceil(fromMs / (1000 / 60)) * (1000 / 60);
		for (let ms = fromMs; ms <= toMs; ms += 0.5) {
			state.now = ms;
			for (const [id, timer] of Array.from(state.timers)) {
				if (timer.at > ms) continue;
				state.timers.delete(id);
				timer.cb();
			}
			if (ms >= nextVsync) {
				nextVsync += 1000 / 60;
				const due = Array.from(state.rafs);
				state.rafs.clear();
				for (const [, cb] of due) cb(ms);
			}
			state.maxOutstanding = Math.max(state.maxOutstanding, state.rafs.size + state.timers.size);
		}
	};
	return { win, state, run };
}

test("frame-rate cap delivers at most fps callbacks per second without multiplying requests", () => {
	const { win, state, run } = makeFakeFrameWindow();
	const original = win.requestAnimationFrame;
	const originalCancel = win.cancelAnimationFrame;
	const uninstall = hook.installFrameRateCap(win, 20);
	assert.notEqual(win.cancelAnimationFrame, originalCancel, "cancel is wrapped");
	let delivered = 0;
	const loop = () => {
		delivered += 1;
		win.requestAnimationFrame(loop);
	};
	win.requestAnimationFrame(loop);
	run(0, 1000);
	assert.ok(delivered >= 19 && delivered <= 21, `delivered ${delivered}`);
	assert.ok(state.maxOutstanding <= 1, `outstanding ${state.maxOutstanding}`);

	let cancelledRan = false;
	const id = win.requestAnimationFrame(() => { cancelledRan = true; });
	win.cancelAnimationFrame(id);
	run(1000.5, 1200);
	assert.equal(cancelledRan, false, "cancelAnimationFrame stops a capped callback");

	uninstall();
	assert.equal(state.rafs.size + state.timers.size, 0, "uninstall leaves nothing pending");
	assert.equal(win.requestAnimationFrame, original, "uninstall restores rAF");
	assert.equal(win.cancelAnimationFrame, originalCancel, "uninstall restores cancel");
});

test("frame-rate cap is a no-op without a valid fps", () => {
	const win = { requestAnimationFrame: () => 1, cancelAnimationFrame: () => {}, setTimeout: () => 1 };
	const original = win.requestAnimationFrame;
	const originalCancel = win.cancelAnimationFrame;
	hook.installFrameRateCap(win, 0)();
	assert.equal(win.requestAnimationFrame, original);
	assert.equal(win.cancelAnimationFrame, originalCancel);
});

test("auto-scroll only drives the wheel while Stress is shown", () => {
	let tick = null;
	let cleared = 0;
	const win = {
		setInterval: (fn) => { tick = fn; return 11; },
		clearInterval: (id) => { if (id === 11) cleared += 1; },
	};
	const calls = [];
	const exports = {
		ingot_web_wheel: (dx, dy) => calls.push(["wheel", dx, dy]),
		ingot_web_mouse_move: (x, y) => calls.push(["move", x, y]),
	};
	assert.equal(typeof hook.installAutoScroll(win, () => exports, () => null, false), "function");
	assert.equal(tick, null, "disabled installs no interval");
	try {
		hook.setCurrentSection("Buttons");
		const uninstall = hook.installAutoScroll(win, () => exports, () => ({ width: 400, height: 800 }), true);
		tick();
		assert.equal(calls.length, 0, "no scrolling off Stress");
		hook.setCurrentSection("Stress");
		tick();
		assert.deepEqual(calls, [["move", 200, 400], ["wheel", 0, -1]]);
		hook.setCurrentSection("Layout");
		tick();
		assert.equal(calls.length, 2, "stops when Stress is left");
		uninstall();
		assert.equal(cleared, 1);
	} finally {
		hook.setCurrentSection("");
	}
});
