// Shared memory is allocated only for the threaded module.
//
// ingot_web.js used to allocate a shared WebAssembly.Memory whenever the page
// was cross-origin isolated, regardless of whether Box3D workers were asked
// for. That was invisible while no site sent COOP/COEP. The moment one does,
// EVERY demo starts reserving 64 MiB it never uses, and odin.js then warns
// that the module exports its own memory and discards the shared one.
//
// Only the module built with INGOT_WEB_THREADS=1 is linked --import-memory and
// therefore actually needs the shared buffer, so allocation must follow the
// worker request, not the isolation state.
import test from "node:test";
import assert from "node:assert/strict";
import { install } from "./dom_stub.mjs";

await install();

// runWasm is the last thing createSession does. Stubbing it keeps these tests
// on the host wiring rather than on WebAssembly instantiation.
function stubOdin() {
	globalThis.window.odin = {
		WasmMemoryInterface: class {
			setMemory(memory) { this.memory = memory; }
			setIntSize() {}
			setExports() {}
		},
		WebGPUInterface: class {
			constructor(wmi) { this.wmi = wmi; }
			getInterface() { return {}; }
		},
		runWasm: async () => ({}),
	};
}

function reset() {
	stubOdin();
	globalThis.navigator.gpu = {};
	globalThis.crossOriginIsolated = true;
	delete globalThis.window.ingotBox3dWorkers;
	if (globalThis.window.ingotWeb) globalThis.window.ingotWeb.stop();
}

test("an isolated page allocates no shared memory unless workers are requested", async () => {
	reset();
	const session = await globalThis.window.ingotWeb.createSession("test.wasm", {});
	// setMemory was never called, so odin.js will use the module's own export.
	assert.equal(session.wmi.memory, undefined);
	session.destroy();
});

test("requesting workers allocates shared memory", async () => {
	reset();
	let createdWith = null;
	globalThis.window.ingotBox3dWorkers = {
		create: async (_path, memory) => {
			createdWith = memory;
			return { imports: {}, destroy() {} };
		},
	};
	const session = await globalThis.window.ingotWeb.createSession("test.wasm",
		{ box3dWorkers: true });
	assert.ok(session.wmi.memory instanceof WebAssembly.Memory);
	assert.ok(session.wmi.memory.buffer instanceof SharedArrayBuffer);
	assert.equal(createdWith, session.wmi.memory);
	session.destroy();
});

test("a page that is not isolated ignores the worker request", async () => {
	reset();
	globalThis.crossOriginIsolated = false;
	// The non-threaded module must still start here, so no memory and no pool.
	const session = await globalThis.window.ingotWeb.createSession("test.wasm",
		{ box3dWorkers: true });
	assert.equal(session.wmi.memory, undefined);
	session.destroy();
});

test("requesting workers without box3d_workers.js names the missing file", async () => {
	reset();
	// Reaching window.ingotBox3dWorkers.create on undefined would throw an
	// anonymous TypeError; the page needs to be told which script it forgot.
	await assert.rejects(
		globalThis.window.ingotWeb.createSession("test.wasm", { box3dWorkers: true }),
		/box3d_workers\.js is not loaded/);
});
