import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

function loadApi(hardwareConcurrency = 8, overrides = {}) {
	let api = null;
	const context = {
		window: {},
		navigator: { hardwareConcurrency },
		console,
		setTimeout,
		clearTimeout,
		SharedArrayBuffer,
		WebAssembly,
		globalThis: null,
		__ingot_box3d_workers_test_hook(value) { api = value; },
		...overrides,
	};
	context.globalThis = context;
	vm.runInNewContext(fs.readFileSync(new URL("../box3d_workers.js", import.meta.url), "utf8"),
		context);
	return api;
}

test("Box3D worker count remains bounded", () => {
	const api = loadApi(32);
	assert.equal(api.workerCount({ workerCount: 99 }), 4);
	assert.equal(api.workerCount({ workerCount: 1 }), 2);
	assert.equal(api.workerCount({}), 4);
});

test("Box3D workers reject ordinary memory", async () => {
	const api = loadApi();
	const memory = new WebAssembly.Memory({ initial: 1, maximum: 2 });
	await assert.rejects(api.create("fixture.wasm", memory, {}),
		/require shared WebAssembly memory/);
});

test("Box3D worker bootstrap errors reject immediately", async () => {
	class FailingWorker {
		postMessage() {
			queueMicrotask(() => this.onmessage({ data: { type: "error", message: "bootstrap" } }));
		}
		terminate() {}
	}
	const api = loadApi(2, {
		Worker: FailingWorker,
		fetch: async () => ({
			ok: true,
			arrayBuffer: async () => Uint8Array.from([0, 97, 115, 109, 1, 0, 0, 0]).buffer,
		}),
	});
	const memory = new WebAssembly.Memory({ initial: 1, maximum: 2, shared: true });
	await assert.rejects(api.create("fixture.wasm", memory, {}), /bootstrap/);
});

function workerApi(WorkerClass, workerCount = 2) {
	return loadApi(workerCount, {
		Worker: WorkerClass,
		fetch: async () => ({
			ok: true,
			arrayBuffer: async () => Uint8Array.from([0, 97, 115, 109, 1, 0, 0, 0]).buffer,
		}),
	});
}

test("Box3D benchmark completion retains timing and counters", async () => {
	class BenchmarkWorker {
		postMessage(message) {
			if (message.type === "init") {
				this.role = message.role;
				queueMicrotask(() => this.onmessage({ data: { type: "ready" } }));
			} else if (message.type === "batch") {
				queueMicrotask(() => this.onmessage({ data: {
					type: "batch-complete", ok: true, elapsedMs: 12.345, stepCount: message.stepCount,
				} }));
			} else if (message.type === "task") {
				queueMicrotask(() => this.onmessage({ data: { type: "complete", ok: true } }));
			}
		}
		terminate() {}
	}
	const api = workerApi(BenchmarkWorker);
	const memory = new WebAssembly.Memory({ initial: 1, maximum: 2, shared: true });
	const pool = await api.create("fixture.wasm", memory, { workerCount: 2 });
	assert.equal(pool.imports.request_batch(30), true);
	await new Promise((resolve) => setImmediate(resolve));
	assert.equal(pool.imports.batch_ready(), true);
	assert.equal(pool.imports.batch_ready(), false);
	assert.equal(pool.imports.batch_elapsed_micros(), 12345);
	assert.equal(pool.imports.batch_step_count(), 30);
	assert.equal(pool.imports.completion_generation(), 1);
	assert.equal(pool.imports.worker_count(), 2);
	assert.equal(pool.imports.schedule(1, 1), true);
	await new Promise((resolve) => setImmediate(resolve));
	assert.equal(pool.imports.task_count(), 1);
	assert.equal(pool.imports.queue_high_water(), 1);
	assert.equal(pool.imports.failure_count(), 0);
	pool.destroy();
});

test("Box3D benchmark rejects invalid batches and records step failure", async () => {
	class FailingStepWorker {
		postMessage(message) {
			if (message.type === "init") {
				this.role = message.role;
				queueMicrotask(() => this.onmessage({ data: { type: "ready" } }));
			} else if (message.type === "batch") {
				queueMicrotask(() => this.onmessage({ data: {
					type: "batch-complete", ok: false, elapsedMs: 1, stepCount: message.stepCount,
				} }));
			}
		}
		terminate() {}
	}
	const api = workerApi(FailingStepWorker);
	const memory = new WebAssembly.Memory({ initial: 1, maximum: 2, shared: true });
	const pool = await api.create("fixture.wasm", memory, { workerCount: 2 });
	assert.equal(pool.imports.request_batch(0), false);
	assert.equal(pool.imports.request_batch(601), false);
	assert.equal(pool.imports.request_batch(1), true);
	await new Promise((resolve) => setImmediate(resolve));
	assert.equal(pool.imports.failure_count(), 1);
});

async function workerScriptImports() {
	let captured = null;
	const self = {};
	const context = {
		self,
		console,
		crypto,
		performance,
		Proxy,
		Math,
		Uint8Array,
		Error,
		String,
		Boolean,
		WebAssembly: {
			instantiate(module, imports) {
				captured = imports;
				return Promise.resolve({
					exports: { __stack_pointer: { value: 0 } },
				});
			},
		},
		globalThis: null,
	};
	context.globalThis = context;
	context.self.postMessage = () => {};
	vm.runInNewContext(fs.readFileSync(new URL("../box3d_worker.js", import.meta.url), "utf8"),
		context);
	const memory = new WebAssembly.Memory({ initial: 1, maximum: 2, shared: true });
	await self.onmessage({
		data: { type: "init", role: "coordinator", module: {}, memory, stackTop: 0 },
	});
	return captured;
}

test("Box3D worker supplies a monotonic clock import to Box3D", async () => {
	const imports = await workerScriptImports();
	assert.equal(typeof imports.odin_env.tick_now, "function");
	const first = imports.odin_env.tick_now();
	assert.equal(typeof first, "number");
	assert.ok(first > 0);
	assert.ok(imports.odin_env.tick_now() >= first);
});

test("Box3D benchmark profile fields survive the result path", async () => {
	class ProfilingWorker {
		postMessage(message) {
			if (message.type === "init") {
				this.role = message.role;
				queueMicrotask(() => this.onmessage({ data: { type: "ready" } }));
			} else if (message.type === "batch") {
				queueMicrotask(() => this.onmessage({ data: {
					type: "batch-complete", ok: true, elapsedMs: 40.5, stepCount: message.stepCount,
				} }));
			}
		}
		terminate() {}
	}
	const api = workerApi(ProfilingWorker);
	const memory = new WebAssembly.Memory({ initial: 1, maximum: 2, shared: true });
	const pool = await api.create("fixture.wasm", memory, { workerCount: 2 });
	assert.equal(pool.imports.request_batch(20), true);
	await new Promise((resolve) => setImmediate(resolve));
	assert.equal(pool.imports.batch_ready(), true);
	assert.equal(pool.imports.batch_elapsed_micros(), 40500);
	assert.equal(pool.imports.batch_step_count(), 20);
	assert.equal(pool.imports.failure_count(), 0);
	pool.destroy();
});
