// ingot_web.js — browser host glue for an ingot (Odin → WASM + WebGPU) app.
//
// Responsibilities:
//   1. Provide the "ingot" foreign-import module the engine calls into
//      (performance.now, canvas CSS size, devicePixelRatio) — see
//      gfx/platform_web.odin.
//   2. Size the canvas backing store to CSS size × devicePixelRatio so WebGPU
//      renders at physical resolution (HiDPI-crisp), matching the native
//      macOS policy.
//   3. Hand DOM input events to the engine (wired in Step 4 via ingot_input.js).
//   4. Boot the wasm module; odin.js drives main() then the exported step() via
//      requestAnimationFrame.
//
// Requires odin.js and wgpu.js (staged by build_web.sh) to be loaded first.

(function () {
	"use strict";

	const CANVAS_ID = "ingot-canvas";
	const HTTP_MAXIMUM_SLOTS = 64;
	const httpSlots = new Array(HTTP_MAXIMUM_SLOTS).fill(null);
	let wasmMemoryInterface = null;

	function wasmBytes(pointer, length) {
		if (!pointer || length <= 0 || !wasmMemoryInterface) return new Uint8Array();
		return new Uint8Array(wasmMemoryInterface.memory.buffer, pointer, length);
	}

	function wasmText(pointer, length) {
		return new TextDecoder().decode(wasmBytes(pointer, length));
	}

	function httpImports() {
		const methods = ["GET", "POST", "PUT", "PATCH", "DELETE"];
		return {
			ingot_http_request: (method, urlPointer, urlLength, headersPointer,
				headersLength, bodyPointer, bodyLength, maximumBody) => {
				const id = httpSlots.findIndex((slot) => slot === null);
				if (id < 0) return -1;
				const slot = { state: 0, status: 0, body: new Uint8Array() };
				httpSlots[id] = slot;
				let headers = {};
				try {
					const encoded = wasmText(headersPointer, headersLength);
					if (encoded) headers = JSON.parse(encoded);
				} catch (_) {
					slot.state = 2;
					return id;
				}
				const body = bodyLength > 0 ? wasmBytes(bodyPointer, bodyLength).slice() : undefined;
				const controller = new AbortController();
				const timeout = setTimeout(() => controller.abort(), 30000);
				fetch(wasmText(urlPointer, urlLength), {
					method: methods[method] || "GET",
					headers,
					body: method === 0 ? undefined : body,
					credentials: "same-origin",
					signal: controller.signal,
				}).then(async (response) => {
					const bytes = new Uint8Array(await response.arrayBuffer());
					if (bytes.length > maximumBody) throw new Error("response too large");
					slot.status = response.status;
					slot.body = bytes;
					slot.state = 1;
				}).catch(() => { slot.state = 2; }).finally(() => clearTimeout(timeout));
				return id;
			},
			ingot_http_poll: (id) => httpSlots[id] ? httpSlots[id].state : 2,
			ingot_http_status: (id) => httpSlots[id] ? httpSlots[id].status : 0,
			ingot_http_body_len: (id) => httpSlots[id] ? httpSlots[id].body.length : 0,
			ingot_http_body_copy: (id, destination, capacity) => {
				const slot = httpSlots[id];
				if (!slot) return -1;
				const count = Math.min(capacity, slot.body.length);
				if (count > 0) wasmBytes(destination, count).set(slot.body.subarray(0, count));
				httpSlots[id] = null;
				return count;
			},
		};
	}

	// Resize the canvas backing store to match its CSS box × devicePixelRatio.
	// gfx reads css size + dpr each frame (_maybe_reconfigure) and reconfigures
	// the swapchain when the framebuffer size changes, so we only need to keep
	// the backing store in sync here.
	function fitCanvas() {
		const c = document.getElementById(CANVAS_ID);
		if (!c) return;
		const dpr = window.devicePixelRatio || 1;
		const rect = c.getBoundingClientRect();
		const w = Math.max(1, Math.round(rect.width * dpr));
		const h = Math.max(1, Math.round(rect.height * dpr));
		if (c.width !== w) c.width = w;
		if (c.height !== h) c.height = h;
	}

	// browser CSS cursor strings indexed by ingot MouseCursor enum (gfx/types.odin)
	const CURSORS = [
		"default", "default", "text", "crosshair", "pointer",
		"ew-resize", "ns-resize", "nwse-resize", "nesw-resize", "move",
		"not-allowed",
	];

	// The "ingot" foreign-import module (see gfx/platform_web.odin).
	function ingotImports() {
		return {
			ingot_perf_now: () => performance.now(),
			ingot_canvas_css_width: () => {
				const c = document.getElementById(CANVAS_ID);
				return c ? c.getBoundingClientRect().width : 0;
			},
			ingot_canvas_css_height: () => {
				const c = document.getElementById(CANVAS_ID);
				return c ? c.getBoundingClientRect().height : 0;
			},
			ingot_device_pixel_ratio: () => window.devicePixelRatio || 1,
			ingot_set_cursor: (cur) => {
				const c = document.getElementById(CANVAS_ID);
				if (c) c.style.cursor = CURSORS[cur] || "default";
			},
			ingot_is_fullscreen: () => {
				const fs = document.fullscreenElement ||
					document.webkitFullscreenElement;
				return fs ? 1 : 0;
			},
			ingot_toggle_fullscreen: () => {
				const fs = document.fullscreenElement ||
					document.webkitFullscreenElement;
				if (fs) {
					const exit = document.exitFullscreen ||
						document.webkitExitFullscreen;
					if (exit) exit.call(document);
					return;
				}
				const c = document.getElementById(CANVAS_ID);
				const target = (c && c.parentElement) || c ||
					document.documentElement;
				const req = target.requestFullscreen ||
					target.webkitRequestFullscreen;
				if (req) {
					const p = req.call(target);
					if (p && p.catch) p.catch(() => {});
				}
			},
		};
	}

	// Boot an ingot wasm app. `wasmPath` defaults to "ingot_web.wasm".
	async function ingotRun(wasmPath, opts) {
		opts = opts || {};
		wasmPath = wasmPath || "ingot_web.wasm";

		if (!navigator.gpu) {
			throw new Error(
				"WebGPU is not available. Use Chrome/Edge 113+ or Safari 18+.");
		}

		fitCanvas();
		window.addEventListener("resize", fitCanvas);

		const wmi = new window.odin.WasmMemoryInterface();
		wasmMemoryInterface = wmi;
		const webgpu = new window.odin.WebGPUInterface(wmi);

		const extra = {
			wgpu: webgpu.getInterface(),
			ingot: ingotImports(),
			ingot_http: httpImports(),
		};

		// ingot_input.js (Step 4) registers DOM listeners that push into the
		// engine's input exports; if present, let it attach now.
		if (window.ingotInput && typeof window.ingotInput.attach === "function") {
			window.ingotInput.attach(CANVAS_ID, wmi);
		}

		// odin.js runs main() (_start), then drives the exported step() via
		// requestAnimationFrame until it returns false.
		return window.odin.runWasm(wasmPath, null, extra, wmi);
	}

	window.ingotWeb = {
		run: ingotRun,
		fitCanvas: fitCanvas,
		ingotImports: ingotImports,
		httpImports: httpImports,
	};
})();
