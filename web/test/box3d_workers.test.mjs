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
