"use strict";

(function() {
	const WORKER_MAX = 4;
	const TASK_MAX = 256;
	const STACK_BYTES = 1024 * 1024;
	const READY_TIMEOUT_MS = 10000;

	function workerCount(options) {
		const requested = Number(options.workerCount || navigator.hardwareConcurrency || 2);
		return Math.max(2, Math.min(WORKER_MAX, Math.floor(requested)));
	}

	function workerReady(worker, message) {
		return new Promise((resolve, reject) => {
			const timeout = setTimeout(() => reject(new Error("Box3D worker ready timeout")),
				READY_TIMEOUT_MS);
			worker.onmessage = (event) => {
				if (event.data.type === "error") {
					clearTimeout(timeout);
					reject(new Error(event.data.message || "Box3D worker failed"));
					return;
				}
				if (event.data.type !== "ready") return;
				clearTimeout(timeout);
				resolve(worker);
			};
			worker.onerror = (event) => {
				clearTimeout(timeout);
				reject(event.error || new Error(event.message || "Box3D worker failed"));
			};
			worker.postMessage(message);
		});
	}

	async function create(wasmPath, memory, options) {
		if (!(memory.buffer instanceof SharedArrayBuffer)) {
			throw new Error("Box3D workers require shared WebAssembly memory");
		}
		const response = await fetch(wasmPath);
		if (!response.ok) throw new Error(`Box3D WASM fetch failed: ${response.status}`);
		const module = await WebAssembly.compile(await response.arrayBuffer());
		const count = workerCount(options || {});
		const workers = [];
		const idle = [];
		const pending = [];
		let coordinator = null;
		let destroyed = false;
		let stepPending = false;

		const fail = (error) => {
			if (destroyed) return;
			console.error("Box3D worker pool failed", error);
			for (const worker of workers) worker.terminate();
			workers.length = 0;
			idle.length = 0;
			pending.length = 0;
			destroyed = true;
		};
		const dispatch = () => {
			while (!destroyed && idle.length && pending.length) {
				const worker = idle.pop();
				worker.postMessage(pending.shift());
			}
		};
		const attachTaskWorker = (worker) => {
			worker.onmessage = (event) => {
				if (event.data.type === "error") {
					fail(new Error(event.data.message || "Box3D task worker failed"));
					return;
				}
				if (event.data.type === "complete") {
					if (!event.data.ok) {
						fail(new Error("Box3D task dispatch failed"));
						return;
					}
					idle.push(worker);
					dispatch();
				}
			};
			worker.onerror = (event) => fail(event.error || new Error(event.message));
			idle.push(worker);
		};

		try {
			for (let index = 0; index < count; index += 1) {
				const worker = new Worker("box3d_worker.js");
				workers.push(worker);
				const role = index === 0 ? "coordinator" : "task";
				const stackTop = 7 * 1024 * 1024 - index * STACK_BYTES;
				await workerReady(worker, { type: "init", module, memory, role, stackTop });
				if (role === "coordinator") {
					coordinator = worker;
					worker.onmessage = (event) => {
						if (event.data.type === "error") {
							fail(new Error(event.data.message || "Box3D coordinator failed"));
							return;
						}
						if (event.data.type === "step-complete") {
							stepPending = false;
							if (!event.data.ok) fail(new Error("Box3D world step failed"));
						}
						if (event.data.type === "schedule") {
							if (event.data.slot >= TASK_MAX || pending.length >= TASK_MAX) {
								fail(new Error("Box3D worker task capacity exceeded"));
								return;
							}
							pending.push({
								type: "task",
								slot: event.data.slot,
								generation: event.data.generation,
							});
							dispatch();
						}
					};
					worker.onerror = (event) => fail(event.error || new Error(event.message));
				} else {
					attachTaskWorker(worker);
				}
			}
		} catch (error) {
			fail(error);
			throw error;
		}

		return {
			module,
			memory,
			workerCount: count,
			imports: {
				schedule: (slot, generation) => {
					if (destroyed || slot >= TASK_MAX || pending.length >= TASK_MAX) return false;
					pending.push({ type: "task", slot, generation });
					dispatch();
					return true;
				},
				request_step: () => {
					if (destroyed || !coordinator || stepPending) return false;
					stepPending = true;
					coordinator.postMessage({ type: "step" });
					return true;
				},
			},
			destroy() {
				if (destroyed) return;
				destroyed = true;
				for (const worker of workers) worker.terminate();
				workers.length = 0;
				idle.length = 0;
				pending.length = 0;
			},
		};
	}

	const api = { create, workerCount };
	window.ingotBox3dWorkers = api;
	if (typeof globalThis.__ingot_box3d_workers_test_hook === "function") {
		globalThis.__ingot_box3d_workers_test_hook(api);
	}
})();
