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
			tick_now: () => performance.now(),
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
			request_batch() { return false; },
			batch_ready() { return false; },
			batch_elapsed_micros() { return 0; },
			batch_step_count() { return 0; },
			task_count() { return 0; },
			queue_high_water() { return 0; },
			failure_count() { return 0; },
			completion_generation() { return 0; },
			worker_count() { return 1; },
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
			if (instance.exports.ingot_box3d_worker_init) {
				instance.exports.ingot_box3d_worker_init();
			}
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
			const started = performance.now();
			const ok = instance.exports.ingot_box3d_worker_step();
			self.postMessage({
				type: "step-complete",
				ok: Boolean(ok),
				elapsedMs: performance.now() - started,
				stepCount: 1,
			});
			return;
		}
		if (message.type === "batch" && role === "coordinator") {
			const started = performance.now();
			const ok = instance.exports.ingot_box3d_benchmark_batch(message.stepCount);
			self.postMessage({
				type: "batch-complete",
				ok: Boolean(ok),
				elapsedMs: performance.now() - started,
				stepCount: message.stepCount,
			});
		}
	} catch (error) {
		self.postMessage({
			type: "error",
			message: error.message || String(error),
			stack: error.stack || "",
			role,
		});
		throw error;
	}
};
