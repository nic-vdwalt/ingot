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
	const semanticControls = new Map();
	const INPUT_TYPES = ["text", "email", "password"];
	const AUTOCOMPLETE = ["off", "username", "current-password", "new-password"];
	// Dropped files staged for the engine (names + bytes; browsers never expose
	// real paths). Bounded: MAX_DROP_FILES files, MAX_DROP_BYTES each.
	const MAX_DROP_FILES = 16;
	const MAX_DROP_BYTES = 32 * 1024 * 1024;
	let dropFiles = [];

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

	// Semantic control mirror: buttons/checkboxes/radios/sliders/dropdowns
	// recorded by the engine's semantic layer (ui/semantics.odin) become real
	// DOM controls assistive tech can reach. They sit over the canvas but are
	// invisible and mouse-transparent (opacity 0, pointer-events none); AT
	// activation still fires click/change events, staged here and pulled by
	// the engine on the next sync. Sem_Role ordinals; Sem_State bits:
	// 1 checked, 2 disabled, 4 focused, 8 expanded.
	const CONTROL_ROLES = {
		1: { tag: "button" },                     // Button
		2: { tag: "input", type: "checkbox" },    // Checkbox
		3: { tag: "input", type: "radio" },       // Radio
		4: { tag: "input", type: "range" },       // Slider
		6: { tag: "button", listbox: true },      // Dropdown
		7: { tag: "button" },                     // Menu_Item
	};

	function createSemanticControl(key, role) {
		const spec = CONTROL_ROLES[role];
		if (!spec) return null;
		const el = document.createElement(spec.tag);
		if (spec.type) el.type = spec.type;
		if (spec.tag === "button") el.type = "button";
		if (spec.listbox) el.setAttribute("aria-haspopup", "listbox");
		el.tabIndex = -1; // reachable by AT virtual cursors, not by page Tab
		el.style.opacity = "0";
		el.style.pointerEvents = "none";
		const state = { el, role, seen: semanticFrame, activated: false, changed: false, value: 0 };
		if (spec.type === "checkbox" || spec.type === "radio") {
			el.addEventListener("change", () => { state.activated = true; });
		} else if (spec.type === "range") {
			el.addEventListener("change", () => {
				state.changed = true;
				state.value = parseFloat(el.value) || 0;
			});
		} else {
			el.addEventListener("click", () => { state.activated = true; });
		}
		document.body.appendChild(el);
		semanticControls.set(key, state);
		return state;
	}

	function syncSemanticControl(key, role, label, x, y, width, height, stateBits, value, lo, hi) {
		let state = semanticControls.get(key);
		if (state && state.role !== role) {
			state.el.remove();
			semanticControls.delete(key);
			state = null;
		}
		if (!state) state = createSemanticControl(key, role);
		if (!state) return 0;
		state.seen = semanticFrame;
		const el = state.el;
		el.setAttribute("aria-label", label);
		if (el.tagName === "BUTTON") el.textContent = label;
		semanticBounds(el, x, y, width, height);
		el.disabled = (stateBits & 2) !== 0;
		if (state.role === 2 || state.role === 3) el.checked = (stateBits & 1) !== 0;
		if (state.role === 6) el.setAttribute("aria-expanded", (stateBits & 8) !== 0 ? "true" : "false");
		if (state.role === 4 && !state.changed) {
			el.min = String(lo);
			el.max = String(hi);
			el.step = "any";
			el.value = String(value);
		}
		const flags = (state.activated ? 1 : 0) | (state.changed ? 2 : 0);
		state.activated = false;
		state.changed = false;
		return flags;
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
		for (const [key, state] of semanticControls) {
			if (state.seen === semanticFrame) continue;
			state.el.remove();
			semanticControls.delete(key);
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
			ingot_web_control_sync: (idLo, idHi, role, labelPointer, labelLength,
				x, y, width, height, stateBits, value, lo, hi) => syncSemanticControl(
				`${idHi >>> 0}:${idLo >>> 0}`, role,
				wasmText(labelPointer, labelLength),
				x, y, width, height, stateBits, value, lo, hi,
			),
			ingot_web_control_value: (idLo, idHi) => {
				const state = semanticControls.get(`${idHi >>> 0}:${idLo >>> 0}`);
				return state ? state.value : 0;
			},
			ingot_ime_rect: (x, y, w, h, active) => {
				// Position/focus the hidden IME proxy (created by
				// ingot_input.js) at the caret so browser composition events
				// fire there. Inactive → return focus to the canvas.
				const ime = document.getElementById("ingot-ime");
				const c = document.getElementById(CANVAS_ID);
				if (!ime || !c) return;
				if (active) {
					const r = c.getBoundingClientRect();
					ime.style.left = (r.left + window.scrollX + x) + "px";
					ime.style.top = (r.top + window.scrollY + y) + "px";
					ime.style.height = Math.max(h, 1) + "px";
					// Only steal focus from ourselves — never from semantic
					// DOM form inputs (ingot-web-input overlays).
					const a = document.activeElement;
					if (a !== ime && (a === c || a === document.body || a === null)) {
						ime.focus({ preventScroll: true });
					}
				} else if (document.activeElement === ime) {
					ime.blur();
					ime.value = "";
					c.focus({ preventScroll: true });
				}
			},
			// Gamepad bridge: fills W3C standard-mapping buttons (digital),
			// 6 axes (triggers converted from 0..1 button values to the -1..1
			// GLFW convention), and the id string. Returns the name length, or
			// -1 when the slot has no standard-mapping gamepad.
			ingot_gamepad_state: (slot, buttonsPtr, buttonsCap, axesPtr, axesCap,
				namePtr, nameCap) => {
				const pads = navigator.getGamepads ? navigator.getGamepads() : [];
				const pad = pads && pads[slot];
				if (!pad || !pad.connected || pad.mapping !== "standard") return -1;
				const buttons = wasmBytes(buttonsPtr, buttonsCap);
				const nb = Math.min(buttonsCap, pad.buttons.length, 17);
				for (let i = 0; i < nb; i += 1) {
					buttons[i] = pad.buttons[i].pressed ? 1 : 0;
				}
				if (axesCap >= 6 && wasmMemoryInterface) {
					const axes = new Float32Array(
						wasmMemoryInterface.memory.buffer, axesPtr, axesCap);
					const na = Math.min(4, pad.axes.length);
					for (let i = 0; i < na; i += 1) axes[i] = pad.axes[i];
					const lt = pad.buttons[6] ? pad.buttons[6].value : 0;
					const rt = pad.buttons[7] ? pad.buttons[7].value : 0;
					axes[4] = lt * 2 - 1;
					axes[5] = rt * 2 - 1;
				}
				const id = new TextEncoder().encode(pad.id || "");
				const n = Math.min(nameCap, id.length);
				if (n > 0) wasmBytes(namePtr, n).set(id.subarray(0, n));
				return n;
			},
			// Drag-and-drop staging (see attachDrop): names + bytes queried by
			// the engine through the len/copy pattern used for the clipboard.
			ingot_drop_count: () => dropFiles.length,
			ingot_drop_name_len: (index) => {
				const f = dropFiles[index];
				return f ? f.name.length : 0;
			},
			ingot_drop_name_copy: (index, destination, capacity) => {
				const f = dropFiles[index];
				if (!f) return 0;
				const count = Math.min(capacity, f.name.length);
				if (count > 0) wasmBytes(destination, count).set(f.name.subarray(0, count));
				return count;
			},
			ingot_drop_data_len: (index) => {
				const f = dropFiles[index];
				return f ? f.data.length : 0;
			},
			ingot_drop_data_copy: (index, destination, capacity) => {
				const f = dropFiles[index];
				if (!f) return 0;
				const count = Math.min(capacity, f.data.length);
				if (count > 0) wasmBytes(destination, count).set(f.data.subarray(0, count));
				return count;
			},
			ingot_drop_clear: () => { dropFiles = []; },
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

	// WebAudio bridge ("ingot_audio" import module — gfx/audio_web.odin).
	// Each slot is one voice: a decoded AudioBuffer + per-slot GainNode,
	// mirroring the native miniaudio pool. The AudioContext starts suspended
	// under browser autoplay policy; the first user gesture resumes it, and
	// plays issued before the unlock are dropped silently.
	const AUDIO_MAX_SLOTS = 256;
	const audioState = {
		ctx: null,
		master: null,
		slots: new Array(AUDIO_MAX_SLOTS).fill(null),
	};

	function audioResume() {
		if (audioState.ctx && audioState.ctx.state === "suspended") {
			audioState.ctx.resume().catch(() => {});
		}
	}

	function audioImports() {
		return {
			ingot_audio_init: () => {
				const Ctx = window.AudioContext || window.webkitAudioContext;
				if (!Ctx) return 0;
				if (!audioState.ctx) {
					audioState.ctx = new Ctx();
					audioState.master = audioState.ctx.createGain();
					audioState.master.connect(audioState.ctx.destination);
					const unlock = () => audioResume();
					window.addEventListener("pointerdown", unlock);
					window.addEventListener("keydown", unlock);
				}
				return 1;
			},
			ingot_audio_pcm: (pcmPtr, frames, channels, rate) => {
				if (!audioState.ctx || frames <= 0 || channels <= 0) return -1;
				const slot = audioState.slots.findIndex((s) => s === null);
				if (slot < 0) return -1;
				const interleaved = new Float32Array(
					wasmMemoryInterface.memory.buffer, pcmPtr, frames * channels);
				const buffer = audioState.ctx.createBuffer(channels, frames, rate);
				for (let ch = 0; ch < channels; ch += 1) {
					const dst = buffer.getChannelData(ch);
					for (let i = 0; i < frames; i += 1) {
						dst[i] = interleaved[i * channels + ch];
					}
				}
				const gain = audioState.ctx.createGain();
				gain.connect(audioState.master);
				audioState.slots[slot] = {
					buffer, gain, source: null,
					playing: false, looping: false, pitch: 1,
				};
				return slot;
			},
			ingot_audio_unload: (slot) => {
				const s = audioState.slots[slot];
				if (!s) return;
				if (s.source) { try { s.source.stop(); } catch (_) {} }
				s.gain.disconnect();
				audioState.slots[slot] = null;
			},
			ingot_audio_play: (slot, restart) => {
				const s = audioState.slots[slot];
				if (!s || !audioState.ctx) return;
				audioResume();
				if (audioState.ctx.state !== "running") return; // pre-gesture: drop
				if (s.source && (restart || !s.playing)) {
					try { s.source.stop(); } catch (_) {}
					s.source = null;
					s.playing = false;
				}
				if (s.playing && !restart) return;
				const src = audioState.ctx.createBufferSource();
				src.buffer = s.buffer;
				src.loop = s.looping;
				src.playbackRate.value = s.pitch;
				src.connect(s.gain);
				src.onended = () => { if (s.source === src) s.playing = false; };
				s.source = src;
				s.playing = true;
				src.start();
			},
			ingot_audio_stop: (slot) => {
				const s = audioState.slots[slot];
				if (!s || !s.source) return;
				try { s.source.stop(); } catch (_) {}
				s.source = null;
				s.playing = false;
			},
			ingot_audio_playing: (slot) => {
				const s = audioState.slots[slot];
				return s && s.playing ? 1 : 0;
			},
			ingot_audio_volume: (slot, volume) => {
				const s = audioState.slots[slot];
				if (s) s.gain.gain.value = volume;
			},
			ingot_audio_pitch: (slot, pitch) => {
				const s = audioState.slots[slot];
				if (!s) return;
				s.pitch = pitch;
				if (s.source) s.source.playbackRate.value = pitch;
			},
			ingot_audio_loop: (slot, looping) => {
				const s = audioState.slots[slot];
				if (!s) return;
				s.looping = looping !== 0;
				if (s.source) s.source.loop = s.looping;
			},
			ingot_audio_master: (volume) => {
				if (audioState.master) audioState.master.gain.value = volume;
			},
		};
	}

	// Canvas drag-and-drop: stage dropped file names + contents, then notify
	// the engine (ingot_web_drop_notify export) so IsFileDropped flips on the
	// next frame. Bounded to MAX_DROP_FILES files of MAX_DROP_BYTES each.
	function attachDrop(wmi) {
		const c = document.getElementById(CANVAS_ID);
		if (!c) return;
		c.addEventListener("dragover", (event) => { event.preventDefault(); });
		c.addEventListener("drop", async (event) => {
			event.preventDefault();
			const files = Array.from(event.dataTransfer ? event.dataTransfer.files : [])
				.slice(0, MAX_DROP_FILES);
			const staged = [];
			for (const file of files) {
				if (file.size > MAX_DROP_BYTES) continue;
				try {
					const buf = await file.arrayBuffer();
					staged.push({
						name: new TextEncoder().encode(file.name),
						data: new Uint8Array(buf),
					});
				} catch (_) { /* unreadable file: skip */ }
			}
			if (staged.length === 0) return;
			dropFiles = staged;
			const x = wmi && wmi.exports;
			if (x && x.ingot_web_drop_notify) x.ingot_web_drop_notify();
		});
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
			ingot_audio: audioImports(),
		};

		// ingot_input.js (Step 4) registers DOM listeners that push into the
		// engine's input exports; if present, let it attach now.
		if (window.ingotInput && typeof window.ingotInput.attach === "function") {
			window.ingotInput.attach(CANVAS_ID, wmi);
		}
		attachDrop(wmi);

		// odin.js runs main() (_start), then drives the exported step() via
		// requestAnimationFrame until it returns false.
		return window.odin.runWasm(wasmPath, null, extra, wmi);
	}

	window.ingotWeb = {
		run: ingotRun,
		fitCanvas: fitCanvas,
		ingotImports: ingotImports,
		httpImports: httpImports,
		audioImports: audioImports,
	};
})();
