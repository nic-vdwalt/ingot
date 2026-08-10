"use strict";

let instance = null;
let role = null;

function imports(memory) {
	return {
		env: { memory },
		odin_env: {
			write() {},
			rand_bytes(pointer, length) {
				crypto.getRandomValues(new Uint8Array(memory.buffer, pointer, length));
			},
			pow: Math.pow,
			sin: Math.sin,
			cos: Math.cos,
		},
		wgpu: new Proxy({}, { get: () => () => 0 }),
		ingot: new Proxy({}, { get: () => () => 0 }),
		ingot_http: new Proxy({}, { get: () => () => 0 }),
		ingot_audio: new Proxy({}, { get: () => () => 0 }),
		ingot_box3d_workers: {
			schedule(slot, generation) {
				if (role !== "coordinator") return false;
				self.postMessage({ type: "schedule", slot, generation });
				return true;
			},
			request_step() { return false; },
		},
	};
}

self.onmessage = async (event) => {
	const message = event.data;
	try {
		if (message.type === "init") {
			role = message.role;
			instance = await WebAssembly.instantiate(message.module, imports(message.memory));
			instance.exports.__stack_pointer.value = message.stackTop;
			self.postMessage({ type: "ready", role });
			return;
		}
		if (!instance) throw new Error("Box3D worker is not initialized");
		if (message.type === "task" && role === "task") {
			const ok = instance.exports.ingot_box3d_worker_dispatch(
				message.slot,
				message.generation,
			);
			self.postMessage({
				type: "complete",
				slot: message.slot,
				generation: message.generation,
				ok: Boolean(ok),
			});
			return;
		}
		if (message.type === "step" && role === "coordinator") {
			const ok = instance.exports.ingot_box3d_worker_step();
			self.postMessage({ type: "step-complete", ok: Boolean(ok) });
		}
	} catch (error) {
		self.postMessage({ type: "error", message: error.message || String(error) });
		throw error;
	}
};
