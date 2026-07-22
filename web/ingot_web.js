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
	let clipboardText = "";
	let semanticFrame = 0;
	const semanticInputs = new Map();
	const semanticForms = new Map();
	const INPUT_TYPES = ["text", "email", "password"];
	const AUTOCOMPLETE = ["off", "username", "current-password", "new-password"];

	function wasmBytes(pointer, length) {
		if (!pointer || length <= 0 || !wasmMemoryInterface) return new Uint8Array();
		return new Uint8Array(wasmMemoryInterface.memory.buffer, pointer, length);
	}

	function wasmText(pointer, length) {
		return new TextDecoder().decode(wasmBytes(pointer, length));
	}

	function httpImports(wmi) {
		if (wmi) wasmMemoryInterface = wmi;
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

	function semanticForm(formId) {
		let state = semanticForms.get(formId);
		if (state) return state;
		const form = document.createElement("form");
		form.id = formId;
		form.autocomplete = "on";
		form.method = "post";
		form.action = window.location.href;
		form.noValidate = true;
		state = { form, submitted: false, seen: semanticFrame, button: null };
		form.addEventListener("submit", (event) => {
			event.preventDefault();
			if (!state.button || !state.button.disabled) state.submitted = true;
		});
		document.body.appendChild(form);
		semanticForms.set(formId, state);
		return state;
	}

	function semanticBounds(element, x, y, width, height) {
		const canvas = document.getElementById(CANVAS_ID);
		if (!canvas) return;
		const rect = canvas.getBoundingClientRect();
		element.style.position = "fixed";
		element.style.left = `${rect.left + x}px`;
		element.style.top = `${rect.top + y}px`;
		element.style.width = `${width}px`;
		element.style.height = `${height}px`;
		element.style.zIndex = "10";
		element.style.boxSizing = "border-box";
	}

	function createSemanticInput(formState, fieldId) {
		const input = document.createElement("input");
		input.id = fieldId;
		input.spellcheck = false;
		input.autocapitalize = "none";
		input.style.background = "#2d2d32";
		input.style.color = "#dcdcdc";
		input.style.border = "1px solid #464650";
		input.style.borderRadius = "0";
		input.style.padding = "0 8px";
		input.style.font = "16px sans-serif";
		input.style.outline = "none";
		const state = {
			input,
			formState,
			seen: semanticFrame,
			lastOdinValue: "",
			wasActive: false,
		};
		input.addEventListener("focus", () => {
			input.style.borderColor = "#64a0ff";
		});
		input.addEventListener("blur", () => {
			input.style.borderColor = "#464650";
		});
		input.addEventListener("keydown", (event) => {
			const fields = Array.from(formState.form.querySelectorAll("input"));
			const index = fields.indexOf(input);
			if (index < 0 || fields.length === 0) return;
			if (event.key === "Tab") {
				event.preventDefault();
				const delta = event.shiftKey ? -1 : 1;
				fields[(index + delta + fields.length) % fields.length].focus();
			} else if (event.key === "Enter" && index < fields.length - 1) {
				event.preventDefault();
				fields[index + 1].focus();
			}
		});
		formState.form.appendChild(input);
		semanticInputs.set(fieldId, state);
		return state;
	}

	function syncSemanticInput(formId, fieldId, name, placeholder, odinValue,
		x, y, width, height, inputType, autocomplete, active) {
		const formState = semanticForm(formId);
		formState.seen = semanticFrame;
		let state = semanticInputs.get(fieldId);
		if (!state) state = createSemanticInput(formState, fieldId);
		state.seen = semanticFrame;
		const input = state.input;
		input.name = name;
		input.type = INPUT_TYPES[inputType] || "text";
		input.autocomplete = AUTOCOMPLETE[autocomplete] || "off";
		input.placeholder = placeholder;
		input.setAttribute("aria-label", placeholder);
		semanticBounds(input, x, y, width, height);
		if (odinValue !== state.lastOdinValue && input.value === state.lastOdinValue) {
			input.value = odinValue;
		}
		state.lastOdinValue = odinValue;
		const canvas = document.getElementById(CANVAS_ID);
		if (active && !state.wasActive && document.activeElement === canvas) {
			input.focus();
		}
		state.wasActive = active;
		return (input.value !== odinValue ? 1 : 0) |
			(document.activeElement === input ? 2 : 0);
	}

	function syncSemanticSubmit(formId, label, x, y, width, height, style, fontSize, enabled) {
		const state = semanticForm(formId);
		state.seen = semanticFrame;
		if (!state.button) {
			state.button = document.createElement("button");
			state.button.type = "submit";
			state.button.tabIndex = -1;
			state.form.appendChild(state.button);
		}
		const button = state.button;
		button.textContent = label;
		button.disabled = !enabled;
		button.style.background = enabled ? "#3c64b4" : "#323237";
		button.style.color = enabled ? "#fff" : "#5a5a64";
		button.style.border = enabled ? "1px solid #3c64b4" : "1px solid #323237";
		button.style.borderRadius = "6px";
		button.style.padding = "0";
		button.style.font = `${fontSize}px sans-serif`;
		button.style.cursor = enabled ? "pointer" : "default";
		semanticBounds(button, x, y, width, height);
		const submitted = state.submitted;
		state.submitted = false;
		return submitted ? 1 : 0;
	}

	function semanticInputState(fieldId) {
		return semanticInputs.get(fieldId) || null;
	}

	function semanticCursorByteOffset(input) {
		const end = input.selectionStart === null ? input.value.length : input.selectionStart;
		return new TextEncoder().encode(input.value.slice(0, end)).length;
	}

	function endSemanticFrame() {
		for (const [fieldId, state] of semanticInputs) {
			if (state.seen === semanticFrame) continue;
			state.input.remove();
			semanticInputs.delete(fieldId);
		}
		for (const [formId, state] of semanticForms) {
			if (state.seen === semanticFrame) continue;
			state.form.remove();
			semanticForms.delete(formId);
		}
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
			ingot_clipboard_len: () => new TextEncoder().encode(clipboardText).length,
			ingot_clipboard_copy: (destination, capacity) => {
				const bytes = new TextEncoder().encode(clipboardText);
				const count = Math.min(capacity, bytes.length);
				if (count > 0) wasmBytes(destination, count).set(bytes.subarray(0, count));
				return count;
			},
			ingot_set_clipboard: (pointer) => {
				if (!wasmMemoryInterface || !pointer) return;
				const memory = new Uint8Array(wasmMemoryInterface.memory.buffer);
				let end = pointer;
				while (end < memory.length && memory[end] !== 0) end += 1;
				clipboardText = new TextDecoder().decode(memory.subarray(pointer, end));
				if (navigator.clipboard && navigator.clipboard.writeText) {
					navigator.clipboard.writeText(clipboardText).catch(() => {});
				}
			},
			ingot_web_input_frame_begin: () => { semanticFrame += 1; },
			ingot_web_input_frame_end: endSemanticFrame,
			ingot_web_input_sync: (formPointer, formLength, fieldPointer, fieldLength,
				namePointer, nameLength, placeholderPointer, placeholderLength,
				valuePointer, valueLength, x, y, width, height, inputType,
				autocomplete, active) => syncSemanticInput(
				wasmText(formPointer, formLength), wasmText(fieldPointer, fieldLength),
				wasmText(namePointer, nameLength),
				wasmText(placeholderPointer, placeholderLength),
				wasmText(valuePointer, valueLength), x, y, width, height,
				inputType, autocomplete, active !== 0,
			),
			ingot_web_input_value_len: (fieldPointer, fieldLength) => {
				const state = semanticInputState(wasmText(fieldPointer, fieldLength));
				return state ? new TextEncoder().encode(state.input.value).length : 0;
			},
			ingot_web_input_value_copy: (fieldPointer, fieldLength, destination, capacity) => {
				const state = semanticInputState(wasmText(fieldPointer, fieldLength));
				if (!state) return 0;
				const bytes = new TextEncoder().encode(state.input.value);
				const count = Math.min(capacity, bytes.length);
				if (count > 0) wasmBytes(destination, count).set(bytes.subarray(0, count));
				return count;
			},
			ingot_web_input_cursor: (fieldPointer, fieldLength) => {
				const state = semanticInputState(wasmText(fieldPointer, fieldLength));
				return state ? semanticCursorByteOffset(state.input) : 0;
			},
			ingot_web_submit_sync: (formPointer, formLength, labelPointer, labelLength,
				x, y, width, height, style, fontSize, enabled) => syncSemanticSubmit(
				wasmText(formPointer, formLength), wasmText(labelPointer, labelLength),
				x, y, width, height, style, fontSize, enabled !== 0,
			),
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
		// Wake the engine's event-driven idle gate on resize so an idle app
		// re-renders at the new canvas size (see gfx/input_web.odin).
		window.addEventListener("resize", () => {
			const x = wasmMemoryInterface && wasmMemoryInterface.exports;
			if (x && x.ingot_web_resize) x.ingot_web_resize();
		});
		window.addEventListener("paste", (event) => {
			const text = event.clipboardData && event.clipboardData.getData("text/plain");
			if (typeof text === "string") clipboardText = text;
		});

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
