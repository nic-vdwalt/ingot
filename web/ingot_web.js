// ingot_web.js - browser host glue for an ingot (Odin → WASM + WebGPU) app.
//
// Responsibilities:
//   1. Provide the "ingot" foreign-import module the engine calls into
//      (performance.now, canvas CSS size, devicePixelRatio) - see
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
	// Mobile-browser guard: mirroring semantic nodes into DOM costs style
	// writes + a forced reflow per element per frame. Desktop absorbs
	// thousands; iOS Safari's watchdog kills the tab (see the gallery's
	// 1000-button stress grid). Cap how many controls are mirrored per frame;
	// AT still reaches everything below the cap, and the canvas remains fully
	// interactive for everyone else.
	const SEMANTIC_CONTROLS_MAX = 256;
	let semanticControlsSynced = 0;
// Canvas-drawn text fields (Sem_Role 5) get no DOM mirror; their rects are
// kept so a touch tap can focus the IME proxy inside the user gesture, the
// only way iOS and Android will raise the soft keyboard.
let semanticTextInputs = [];
const IME_TAP_FOCUS_GRACE_MS = 300;
let semanticTextInputsNext = [];
	// Gallery section most recently announced through ingot_web_mark
	// ("section <name>"); the ?ingot_autoscroll driver only runs on Stress.
	let currentSection = "";
	// Shared codecs: per-call `new TextDecoder()` allocations at 1000+ calls
	// per frame create GC pressure that stalls mobile browsers.
	const textDecoder = new TextDecoder();
	const textEncoder = new TextEncoder();
	// Canvas rect cached per semantic frame: getBoundingClientRect between
	// style writes forces a reflow per mirrored element - the main cost that
	// froze mobile Safari.
	let canvasRectCache = null;
	const INPUT_TYPES = ["text", "email", "password"];
	const AUTOCOMPLETE = ["off", "username", "current-password", "new-password"];
	// Dropped files staged for the engine (names + bytes; browsers never expose
	// real paths). Bounded: MAX_DROP_FILES files, MAX_DROP_BYTES each.
	const MAX_DROP_FILES = 16;
	const MAX_DROP_BYTES = 32 * 1024 * 1024;
	let dropFiles = [];
	let detachDrop = null;
	let activeSession = null;
	let dropGeneration = 0;

	function wasmBytes(pointer, length) {
		if (!pointer || length <= 0 || !wasmMemoryInterface) return new Uint8Array();
		return new Uint8Array(wasmMemoryInterface.memory.buffer, pointer, length);
	}

	// Threaded builds import a `shared: true` memory, and both Blink and Gecko
	// reject SharedArrayBuffer-backed views in TextDecoder.decode even though
	// the Encoding spec allows them. Copy first when the view is shared. Node
	// accepts shared views, so `node --test` cannot catch a regression here.
	function decodeUtf8(view) {
		if (typeof SharedArrayBuffer !== "undefined" && view.buffer instanceof SharedArrayBuffer) {
			return textDecoder.decode(view.slice());
		}
		return textDecoder.decode(view);
	}

	function wasmText(pointer, length) {
		return decodeUtf8(wasmBytes(pointer, length));
	}

	function canvasRect() {
		if (canvasRectCache) return canvasRectCache;
		const canvas = document.getElementById(CANVAS_ID);
		if (!canvas) return null;
		canvasRectCache = canvas.getBoundingClientRect();
		return canvasRectCache;
	}

	function httpImports(wmi) {
		if (wmi) wasmMemoryInterface = wmi;
		const methods = ["GET", "POST", "PUT", "PATCH", "DELETE"];
		const streamRead = (slot) => {
			if (!slot || !slot.reader || slot.chunk.length > 0 || slot.state !== 0) return;
			slot.reader.read().then(({ done, value }) => {
				if (done) {
					slot.chunk = slot.carry;
					slot.carry = new Uint8Array();
					slot.state = 1;
					clearTimeout(slot.timeout);
					return;
				}
				if (!(value instanceof Uint8Array) || value.length === 0) {
					streamRead(slot);
					return;
				}
				if (slot.received > slot.maximumBody - value.length) {
					throw new Error("response too large");
				}
				slot.received += value.length;
				const merged = new Uint8Array(slot.carry.length + value.length);
				merged.set(slot.carry);
				merged.set(value, slot.carry.length);
				const newline = merged.lastIndexOf(10);
				if (newline < 0) {
					slot.carry = merged;
					streamRead(slot);
					return;
				}
				slot.chunk = merged.slice(0, newline + 1);
				slot.carry = merged.slice(newline + 1);
			}).catch(() => {
				slot.state = 2;
				clearTimeout(slot.timeout);
			});
		};
		return {
			ingot_http_request: (method, urlPointer, urlLength, headersPointer,
				headersLength, bodyPointer, bodyLength, maximumBody) => {
				const id = httpSlots.findIndex((slot) => slot === null);
				if (id < 0) return -1;
				const slot = { state: 0, status: 0, body: new Uint8Array(), controller: null };
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
				slot.controller = controller;
				const timeout = setTimeout(() => controller.abort(), 120000);
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
			ingot_http_stream_request: (urlPointer, urlLength, maximumBody) => {
				const id = httpSlots.findIndex((slot) => slot === null);
				if (id < 0 || maximumBody <= 0) return -1;
				const slot = {
					state: 0, status: 0, body: new Uint8Array(), chunk: new Uint8Array(),
					carry: new Uint8Array(), controller: new AbortController(), reader: null,
					received: 0, maximumBody, timeout: null,
				};
				httpSlots[id] = slot;
				slot.timeout = setTimeout(() => slot.controller.abort(), 120000);
				fetch(wasmText(urlPointer, urlLength), {
					method: "GET", credentials: "same-origin", signal: slot.controller.signal,
				}).then((response) => {
					slot.status = response.status;
					if (!response.body) throw new Error("stream unavailable");
					slot.reader = response.body.getReader();
					streamRead(slot);
				}).catch(() => {
					slot.state = 2;
					clearTimeout(slot.timeout);
				});
				return id;
			},
			ingot_http_stream_chunk_len: (id) => {
				const slot = httpSlots[id];
				return slot ? slot.chunk.length : -1;
			},
			ingot_http_stream_chunk_copy: (id, destination, capacity) => {
				const slot = httpSlots[id];
				if (!slot || capacity < slot.chunk.length) return -1;
				const count = slot.chunk.length;
				if (count > 0) wasmBytes(destination, count).set(slot.chunk);
				slot.chunk = new Uint8Array();
				streamRead(slot);
				return count;
			},
			ingot_http_stream_release: (id) => {
				const slot = httpSlots[id];
				if (!slot) return 0;
				if (slot.reader) slot.reader.cancel().catch(() => {});
				if (slot.controller) slot.controller.abort();
				if (slot.timeout) clearTimeout(slot.timeout);
				httpSlots[id] = null;
				return 1;
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
			ingot_http_cancel: (id) => {
				const slot = httpSlots[id];
				if (!slot) return 0;
				if (slot.controller) slot.controller.abort();
				httpSlots[id] = null;
				return 1;
			},
		};
	}

	// Cap the backing-store scale. A modern phone reports devicePixelRatio 3,
	// which on a 390x844 CSS viewport means a 1170x2532 framebuffer - 11.9 MB
	// per buffer, and a swapchain holds several. Capping at 2 renders
	// 780x1688 = 5.3 MB, saving ~6.6 MB per buffer for a difference few
	// people can see at arm's length.
	//
	// Both the backing store (fitCanvas) and the value the engine reads
	// (ingot_device_pixel_ratio) must use this same number: gfx computes its
	// framebuffer size as css x dpr, so a disagreement would configure a
	// swapchain that does not match the canvas.
	const CANVAS_DPR_MAX = 2;
	const CANVAS_DIMENSION_MAX = 8192;
	// The pixel budget exists for phones, where a swapchain of 12 MB buffers
	// is what gets the tab killed. On a desktop it is the wrong trade: a
	// Retina laptop in fullscreen is already 5.6 MP and a 5K iMac 14.7 MP, so
	// a 4 MP cap engaged on every one of them and the whole frame was
	// rendered small and stretched back up - the blur that made the demos
	// look worse than the native build. Coarse pointer is the cheapest proxy
	// for "memory-constrained touch device" that every browser exposes.
	const CANVAS_PIXELS_MAX_COARSE = 4 * 1024 * 1024;
	const CANVAS_PIXELS_MAX_FINE = 16 * 1024 * 1024;
	// How many CSS pixels fitCanvas may shave off the box to find a size
	// whose product with the ratio is a whole device pixel. 1.25 needs a
	// multiple of 4, 1.5 an even number; 16 covers every ratio browsers
	// report in practice and bounds the loop.
	const CANVAS_SNAP_STEPS_MAX = 16;
	// When the pixel budget engages, the effective ratio snaps down to this
	// grid. A continuous ratio changed on every toolbar collapse, which made
	// gfx discard and re-rasterise every font atlas (ui_gfx/text.odin
	// adapter_set_font_dpi) on each resize. 0.25 keeps the snap search
	// (multiples of 4 CSS px) inside CANVAS_SNAP_STEPS_MAX.
	const CANVAS_DPR_STEP = 0.25;
	// Scale the pixel budget applied on top of canvasDpr(), 1 when it did
	// not engage. Reported to the engine so fonts rasterise at the size
	// they are actually drawn at, rather than at dpr and then minified.
	let canvasCapScale = 1;

	// On-device bisect switches, read once from the page URL. They exist to
	// narrow a mobile kill down without a debugger: ?ingot_dpr=1 caps the
	// backing-store ratio (framebuffer-scaled memory), ?ingot_fps=20 caps the
	// rAF rate the engine sees (per-frame growth). Invalid values are ignored
	// and nothing changes without the parameters.
	const BISECT_DPR_MIN = 0.5;
	const BISECT_FPS_MIN = 1;
	const BISECT_FPS_MAX = 120;
	// Default limits for iOS WebKit, whose GPU process kills the tab under
	// continuous presenting while every in-page metric stays flat. Fewer and
	// smaller frames are the only levers the page has. `off` in the URL
	// switch removes a default so the uncapped path stays reproducible.
	const IOS_WEBKIT_FPS_DEFAULT = 30;
	const IOS_WEBKIT_DPR_DEFAULT = 1.5;
	const BISECT_OFF = -1;
	const GC_NUDGE_BYTES = 8 * 1024 * 1024;
	const GC_NUDGE_INTERVAL_MS = 1000;
	const BISECT_INFLIGHT_MAX = 8;
	const BISECT_CAPTURE_MAX = 8;

	function parseBisectSwitches(search) {
		const switches = {
			dpr: 0, fps: 0, upload: "pooled", gc: false, a11y: "on", autoscroll: false,
			skip: { scissor: false, texwrite: false }, inflight: 0, capture: 0,
		};
		if (typeof search !== "string" || typeof URLSearchParams !== "function") return switches;
		let params;
		try {
			params = new URLSearchParams(search);
		} catch (_) {
			return switches;
		}
		const dprText = params.get("ingot_dpr");
		if (dprText === "off") switches.dpr = BISECT_OFF;
		const dpr = dprText === null || dprText === "" ? NaN : Number(dprText);
		if (Number.isFinite(dpr) && dpr >= BISECT_DPR_MIN && dpr <= CANVAS_DPR_MAX) switches.dpr = dpr;
		const fpsText = params.get("ingot_fps");
		if (fpsText === "off") switches.fps = BISECT_OFF;
		const fps = fpsText === null || fpsText === "" ? NaN : Number(fpsText);
		if (Number.isFinite(fps) && fps >= BISECT_FPS_MIN && fps <= BISECT_FPS_MAX) switches.fps = fps;
		if (params.get("ingot_upload") === "view") switches.upload = "view";
		if (params.get("ingot_gc") === "1") switches.gc = true;
		const a11y = params.get("ingot_a11y");
		if (a11y === "off" || a11y === "static") switches.a11y = a11y;
		if (params.get("ingot_autoscroll") === "1") switches.autoscroll = true;
		const skip = params.get("ingot_skip");
		if (skip) {
			for (const token of skip.split(",")) {
				const name = token.trim();
				if (name === "scissor" || name === "texwrite") switches.skip[name] = true;
			}
		}
		const smallInt = (text, max) => {
			if (text === null || !/^\d+$/.test(text)) return 0;
			const n = Number(text);
			return n >= 1 && n <= max ? n : 0;
		};
		switches.inflight = smallInt(params.get("ingot_gpu_inflight"), BISECT_INFLIGHT_MAX);
		switches.capture = smallInt(params.get("ingot_capture"), BISECT_CAPTURE_MAX);
		return switches;
	}

	function describeBisectSwitches(switches) {
		const parts = [];
		if (switches.dpr !== 0) parts.push("dpr=" + (switches.dpr > 0 ? switches.dpr : "off"));
		if (switches.fps !== 0) parts.push("fps=" + (switches.fps > 0 ? switches.fps : "off"));
		if (switches.upload === "view") parts.push("upload=view");
		if (switches.gc) parts.push("gc=1");
		if (switches.a11y === "off" || switches.a11y === "static") parts.push("a11y=" + switches.a11y);
		if (switches.autoscroll) parts.push("autoscroll=1");
		const skipped = switches.skip
			? ["scissor", "texwrite"].filter((name) => switches.skip[name])
			: [];
		if (skipped.length) parts.push("skip=" + skipped.join(","));
		if (switches.inflight > 0) parts.push("inflight=" + switches.inflight);
		if (switches.capture > 0) parts.push("capture=" + switches.capture);
		return parts.length ? parts.join(" ") : "none";
	}

	const bisectSwitches = parseBisectSwitches(
		typeof location !== "undefined" && location ? location.search : "",
	);

	function isIosWebKit(nav) {
		if (!nav) return false;
		const ua = String(nav.userAgent || "");
		if (/\b(iPhone|iPad|iPod)\b/.test(ua)) return true;
		return nav.platform === "MacIntel" && Number(nav.maxTouchPoints) > 1;
	}

	// Final limits: an explicit URL value wins, `off` means none, otherwise
	// the platform default. 0 means "no limit" for both fields.
	function resolveFrameLimits(switches, iosWebKit) {
		const pick = (value, fallback) => (value > 0 ? value : value === BISECT_OFF ? 0 : fallback);
		return {
			fps: pick(switches.fps, iosWebKit ? IOS_WEBKIT_FPS_DEFAULT : 0),
			dpr: pick(switches.dpr, iosWebKit ? IOS_WEBKIT_DPR_DEFAULT : 0),
			ios: iosWebKit,
		};
	}

	function describeFrameLimits(limits) {
		return `fps=${limits.fps || "none"} dpr=${limits.dpr || "none"}${limits.ios ? " ios" : ""}`;
	}

	const frameLimits = resolveFrameLimits(
		bisectSwitches,
		isIosWebKit(typeof navigator !== "undefined" ? navigator : null),
	);

	// Throttles every rAF callback to at most `fps` deliveries per second.
	// odin.js drives step() through window rAF, so this is the only seam that
	// caps the engine without patching the vendored runtime. An early request
	// waits on a timer rather than re-queueing rAF: the re-queue version made
	// the crash heartbeat's frame count climb every second on iOS, and it
	// returned the first rAF id, so cancelAnimationFrame cancelled nothing.
	// Each capped callback owns at most one live rAF or timer, and capped ids
	// cancel through the wrapped cancelAnimationFrame. Returns an uninstall
	// function.
	const FRAME_CAP_TIMER_SLACK_MS = 4;

	function installFrameRateCap(win, fps) {
		if (!(fps > 0) || !win || typeof win.requestAnimationFrame !== "function" ||
			typeof win.setTimeout !== "function") return () => {};
		const original = win.requestAnimationFrame;
		const originalCancel = win.cancelAnimationFrame;
		const now = () => (win.performance && typeof win.performance.now === "function")
			? win.performance.now() : Date.now();
		const interval = 1000 / fps;
		let last = -Infinity;
		let nextId = 1;
		const pending = new Map();
		const capped = function (callback) {
			const id = nextId++;
			const entry = { raf: 0, timer: 0 };
			pending.set(id, entry);
			const request = () => {
				entry.timer = 0;
				entry.raf = original.call(win, run);
			};
			const wait = (at) => {
				const early = interval - (at - last);
				if (early <= 1) return false;
				entry.timer = win.setTimeout(request, Math.max(0, early - FRAME_CAP_TIMER_SLACK_MS));
				return true;
			};
			function run(timestamp) {
				entry.raf = 0;
				if (wait(timestamp)) return;
				pending.delete(id);
				last = timestamp;
				callback(timestamp);
			}
			if (!wait(now())) request();
			return id;
		};
		const cappedCancel = function (id) {
			const entry = pending.get(id);
			if (!entry) {
				return typeof originalCancel === "function" ? originalCancel.call(win, id) : undefined;
			}
			pending.delete(id);
			if (entry.timer && typeof win.clearTimeout === "function") win.clearTimeout(entry.timer);
			if (entry.raf && typeof originalCancel === "function") originalCancel.call(win, entry.raf);
			return undefined;
		};
		win.requestAnimationFrame = capped;
		win.cancelAnimationFrame = cappedCancel;
		return () => {
			for (const id of Array.from(pending.keys())) cappedCancel(id);
			if (win.requestAnimationFrame === capped) win.requestAnimationFrame = original;
			if (win.cancelAnimationFrame === cappedCancel) win.cancelAnimationFrame = originalCancel;
		};
	}

	// Bisect (?ingot_gpu_inflight=N): holds each rAF callback while N or more
	// submits are still executing on the GPU. odin.js re-requests rAF from
	// inside step(), so a held callback pauses the app loop until the GPU
	// catches up instead of letting WebKit queue frames. Installed outermost,
	// after the frame cap. `onDefer` counts each held frame. Returns an
	// uninstall function.
	function installGpuBackpressure(win, limit, getInFlight, onDefer) {
		if (!(limit > 0) || typeof getInFlight !== "function" || !win ||
			typeof win.requestAnimationFrame !== "function") return () => {};
		const previous = win.requestAnimationFrame;
		const previousCancel = win.cancelAnimationFrame;
		let nextId = 1;
		const pending = new Map();
		const busy = () => {
			try {
				return getInFlight() >= limit;
			} catch (_) {
				return false;
			}
		};
		const gated = function (callback) {
			const id = nextId++;
			const entry = { callback, innerId: 0 };
			const gate = (timestamp) => {
				if (!pending.has(id)) return;
				if (busy()) {
					if (typeof onDefer === "function") {
						try { onDefer(); } catch (_) {}
					}
					entry.innerId = previous.call(win, gate);
					return;
				}
				pending.delete(id);
				callback(timestamp);
			};
			pending.set(id, entry);
			entry.innerId = previous.call(win, gate);
			return id;
		};
		const gatedCancel = function (id) {
			const entry = pending.get(id);
			if (!entry) {
				return typeof previousCancel === "function" ? previousCancel.call(win, id) : undefined;
			}
			pending.delete(id);
			if (entry.innerId && typeof previousCancel === "function") previousCancel.call(win, entry.innerId);
			return undefined;
		};
		win.requestAnimationFrame = gated;
		win.cancelAnimationFrame = gatedCancel;
		return () => {
			for (const id of Array.from(pending.keys())) gatedCancel(id);
			if (win.requestAnimationFrame === gated) win.requestAnimationFrame = previous;
			if (win.cancelAnimationFrame === gatedCancel) win.cancelAnimationFrame = previousCancel;
		};
	}

	// Bisect experiment (?ingot_gc=1): JavaScriptCore schedules a collection
	// sooner as external ArrayBuffer memory grows. If WebKit only frees the
	// GPU-process memory behind released WebGPU wrappers on collection, this
	// makes Stress survive. Returns an uninstall function.
	function installGcNudge(win, enabled) {
		if (!enabled || !win || typeof win.setInterval !== "function") return () => {};
		let sink = null;
		const id = win.setInterval(() => {
			sink = new ArrayBuffer(GC_NUDGE_BYTES);
			sink = null;
		}, GC_NUDGE_INTERVAL_MS);
		return () => win.clearInterval(id);
	}

	// Bisect driver (?ingot_autoscroll=1): scrolls the gallery pane up and
	// down at a fixed rate while Stress is shown, so device runs compare
	// like with like instead of depending on how a finger scrolled. Uses the
	// same wheel export the browser wheel handler feeds; the pointer is parked
	// at the canvas centre so the pane under it receives the scroll.
	const AUTOSCROLL_INTERVAL_MS = 33;
	const AUTOSCROLL_FLIP_MS = 3000;
	const AUTOSCROLL_NOTCHES = 1;
	const AUTOSCROLL_SECTION = "Stress";

	function installAutoScroll(win, getExports, getCanvasBox, enabled) {
		if (!enabled || !win || typeof win.setInterval !== "function") return () => {};
		let direction = -1;
		let flipAt = 0;
		const id = win.setInterval(() => {
			if (currentSection !== AUTOSCROLL_SECTION) {
				flipAt = 0;
				return;
			}
			const x = getExports();
			const box = getCanvasBox();
			if (!x || !box || typeof x.ingot_web_wheel !== "function" ||
				typeof x.ingot_web_mouse_move !== "function") return;
			const t = Date.now();
			if (flipAt === 0) flipAt = t + AUTOSCROLL_FLIP_MS;
			if (t >= flipAt) {
				direction = -direction;
				flipAt = t + AUTOSCROLL_FLIP_MS;
			}
			x.ingot_web_mouse_move(box.width / 2, box.height / 2);
			x.ingot_web_wheel(0, direction * AUTOSCROLL_NOTCHES);
		}, AUTOSCROLL_INTERVAL_MS);
		return () => {
			if (typeof win.clearInterval === "function") win.clearInterval(id);
		};
	}

	// Per-submit WebGPU call profile for the crash heartbeat. The standalone
	// repro page survives the same upload volume that kills the gallery, so
	// the difference must be in which calls the engine makes per frame; this
	// measures them so the repro can be matched exactly.
	const GPU_CALL_KEYS = [
		"sub", "dI", "idx", "d", "sc", "bg", "pl", "vb", "ib", "wB", "wBKiB", "wT", "wTKiB", "cfg", "gct",
	];
	const GPU_CALL_WRAPS = [
		["GPUQueue", "writeBuffer", "wB"],
		["GPUQueue", "writeTexture", "wT"],
		["GPUQueue", "submit", "sub"],
		["GPURenderPassEncoder", "draw", "d"],
		["GPURenderPassEncoder", "drawIndexed", "dI"],
		["GPURenderPassEncoder", "setScissorRect", "sc"],
		["GPURenderPassEncoder", "setBindGroup", "bg"],
		["GPURenderPassEncoder", "setPipeline", "pl"],
		["GPURenderPassEncoder", "setVertexBuffer", "vb"],
		["GPURenderPassEncoder", "setIndexBuffer", "ib"],
		// Each surface configure reallocates drawables; the acquire count
		// shows whether frames present more than once per submit.
		["GPUCanvasContext", "configure", "cfg"],
		["GPUCanvasContext", "getCurrentTexture", "gct"],
	];

	function gpuWriteBufferBytes(args) {
		const data = args[2];
		if (!data) return 0;
		const unit = typeof data.BYTES_PER_ELEMENT === "number" ? data.BYTES_PER_ELEMENT : 1;
		if (typeof args[4] === "number") return args[4] * unit;
		const length = typeof data.length === "number" ? data.length : data.byteLength;
		const offset = typeof args[3] === "number" ? args[3] : 0;
		return Math.max(0, (length - offset) * unit);
	}

	function wrapPrototypeMethod(win, owner, method, makeWrapper, restores) {
		const ctor = win && win[owner];
		const proto = ctor && ctor.prototype;
		if (!proto || typeof proto[method] !== "function") return false;
		const original = proto[method];
		const wrapped = makeWrapper(original);
		proto[method] = wrapped;
		restores.push(() => {
			if (proto[method] === wrapped) proto[method] = original;
		});
		return true;
	}

	function installGpuCallCounters(win) {
		const counts = {};
		const reset = () => {
			for (const key of GPU_CALL_KEYS) counts[key] = 0;
		};
		reset();
		const restores = [];
		for (const [owner, method, key] of GPU_CALL_WRAPS) {
			wrapPrototypeMethod(win, owner, method, (original) => function (...args) {
				try {
					counts[key] += 1;
					if (key === "wB") counts.wBKiB += gpuWriteBufferBytes(args) / 1024;
					else if (key === "wT") counts.wTKiB += (args[1] && args[1].byteLength || 0) / 1024;
					else if (key === "dI") counts.idx += Number(args[0]) || 0;
				} catch (_) {}
				return original.apply(this, args);
			}, restores);
		}
		if (!restores.length) return { probe: () => null, uninstall: () => {} };
		const probe = () => {
			const submits = counts.sub;
			if (submits === 0) {
				reset();
				return null;
			}
			const parts = [`sub=${submits}`];
			for (const key of GPU_CALL_KEYS) {
				if (key === "sub" || counts[key] === 0) continue;
				const avg = counts[key] / submits;
				parts.push(`${key}=${key === "idx" || key.endsWith("KiB") ? Math.round(avg) : avg.toFixed(1)}`);
			}
			reset();
			return parts.join(" ");
		};
		return {
			probe,
			uninstall: () => {
				for (const restore of restores.splice(0).reverse()) restore();
			},
		};
	}

	// GPU backlog for the crash heartbeat: submits whose work the GPU has not
	// finished yet, and how long completion takes. A GPU slower than the
	// frame rate makes WebKit queue frames and drawables no JS counter sees,
	// which would show here as a steadily climbing in-flight count.
	function installGpuBacklogProbe(win) {
		const queueCtor = win && win.GPUQueue;
		const proto = queueCtor && queueCtor.prototype;
		const none = { probe: () => null, inFlight: () => 0, noteDeferred: () => {}, uninstall: () => {} };
		if (!proto || typeof proto.submit !== "function") return none;
		const perf = win.performance;
		const now = () => (perf && typeof perf.now === "function") ? perf.now() : Date.now();
		const pendingStarts = [];
		let maxInFlight = 0;
		let latSum = 0;
		let latMax = 0;
		let completed = 0;
		let submitted = 0;
		let deferred = 0;
		let installed = true;
		const original = proto.submit;
		const wrapped = function (...args) {
			const result = original.apply(this, args);
			try {
				if (installed && typeof this.onSubmittedWorkDone === "function") {
					const t0 = now();
					pendingStarts.push(t0);
					submitted += 1;
					if (pendingStarts.length > maxInFlight) maxInFlight = pendingStarts.length;
					const done = () => {
						if (!installed) return;
						pendingStarts.shift();
						const latency = now() - t0;
						latSum += latency;
						if (latency > latMax) latMax = latency;
						completed += 1;
					};
					this.onSubmittedWorkDone().then(done, done);
				}
			} catch (_) {}
			return result;
		};
		proto.submit = wrapped;
		const probe = () => {
			if (submitted === 0 && pendingStarts.length === 0 && deferred === 0) return null;
			const oldest = pendingStarts.length ? Math.round(now() - pendingStarts[0]) : 0;
			const avg = completed ? Math.round(latSum / completed) : 0;
			let text = `inflight=${pendingStarts.length} max=${maxInFlight} oldestMs=${oldest}` +
				` latMs=${avg}/${Math.round(latMax)} done=${completed}`;
			if (deferred) text += ` defer=${deferred}`;
			maxInFlight = pendingStarts.length;
			latSum = 0;
			latMax = 0;
			completed = 0;
			submitted = 0;
			deferred = 0;
			return text;
		};
		return {
			probe,
			inFlight: () => pendingStarts.length,
			noteDeferred: () => { deferred += 1; },
			uninstall: () => {
				installed = false;
				pendingStarts.length = 0;
				if (proto.submit === wrapped) proto.submit = original;
			},
		};
	}

	// Bisect (?ingot_skip=scissor,texwrite): drops scissor rects and/or
	// texture writes while Stress is shown, to test whether either is what
	// the bare repro page lacks. Installed after the counters so skipped calls
	// still count. Returns an uninstall function.
	const GPU_SKIP_SECTION = "Stress";

	function installGpuSkips(win, skip, getSection) {
		if (!skip || (!skip.scissor && !skip.texwrite) || typeof getSection !== "function") return () => {};
		const restores = [];
		const skipping = () => {
			try {
				return getSection() === GPU_SKIP_SECTION;
			} catch (_) {
				return false;
			}
		};
		const makeSkip = (original) => function (...args) {
			if (skipping()) return undefined;
			return original.apply(this, args);
		};
		if (skip.scissor) wrapPrototypeMethod(win, "GPURenderPassEncoder", "setScissorRect", makeSkip, restores);
		if (skip.texwrite) wrapPrototypeMethod(win, "GPUQueue", "writeTexture", makeSkip, restores);
		return () => {
			for (const restore of restores.splice(0).reverse()) restore();
		};
	}

	// Desktop capture (?ingot_capture=N): records every WebGPU object the
	// engine creates and, once Stress has been shown for a moment, N frames
	// of calls with their upload data. The JSON replays in the standalone
	// repro page without ingot, wasm or wgpu.js, which separates WebKit's
	// handling of ingot's real GPU work from the binding layer. Installed
	// before the wasm starts so no creation is missed; buffer and texture
	// contents are shadowed from boot so the capture can start from the
	// state the first captured frame saw.
	const CAPTURE_SECTION = "Stress";
	const CAPTURE_SETTLE_MS = 1500;
	const CAPTURE_BUFFER_MAP_WRITE = 0x0002;
	const CAPTURE_BUFFER_COPY_DST = 0x0008;
	const CAPTURE_MAP_MODE_WRITE = 0x0002;
	const CAPTURE_TEXTURE_COPY_DST = 0x02;
	const CAPTURE_TEXEL_BYTES = {
		r8unorm: 1, rgba8unorm: 4, "rgba8unorm-srgb": 4, bgra8unorm: 4, "bgra8unorm-srgb": 4,
	};
	const CAPTURE_B64_CHUNK = 0x8000;
	const CAPTURE_CREATE_KINDS = [
		["createBuffer", "buffer"],
		["createTexture", "texture"],
		["createSampler", "sampler"],
		["createShaderModule", "shaderModule"],
		["createBindGroupLayout", "bindGroupLayout"],
		["createPipelineLayout", "pipelineLayout"],
		["createRenderPipeline", "renderPipeline"],
		["createComputePipeline", "computePipeline"],
		["createBindGroup", "bindGroup"],
	];
	const CAPTURE_PASS_METHODS = [
		"setPipeline", "setBindGroup", "setVertexBuffer", "setIndexBuffer", "draw", "drawIndexed",
		"drawIndirect", "drawIndexedIndirect", "setScissorRect", "setViewport", "setBlendConstant",
		"setStencilReference", "pushDebugGroup", "popDebugGroup", "insertDebugMarker",
		"beginOcclusionQuery", "endOcclusionQuery", "executeBundles", "end",
	];
	const CAPTURE_ENCODER_CALLS = ["copyBufferToBuffer", "copyBufferToTexture", "copyTextureToTexture", "clearBuffer"];

	function captureBase64(bytes) {
		let text = "";
		for (let i = 0; i < bytes.length; i += CAPTURE_B64_CHUNK) {
			text += String.fromCharCode.apply(null, bytes.subarray(i, i + CAPTURE_B64_CHUNK));
		}
		return btoa(text);
	}

	function captureBytes(data) {
		if (!data) return null;
		if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
		if (data instanceof ArrayBuffer ||
			(typeof SharedArrayBuffer !== "undefined" && data instanceof SharedArrayBuffer)) {
			return new Uint8Array(data);
		}
		return null;
	}

	function captureExtent(size) {
		if (!size) return { width: 1, height: 1, depth: 1 };
		if (typeof size.width === "number") {
			return { width: size.width, height: size.height || 1, depth: size.depthOrArrayLayers || 1 };
		}
		const list = Array.from(size);
		return { width: list[0] || 1, height: list[1] || 1, depth: list[2] || 1 };
	}

	function captureOrigin(origin) {
		if (!origin) return { x: 0, y: 0, z: 0 };
		if (typeof origin.x === "number" || typeof origin.y === "number" || typeof origin.z === "number") {
			return { x: origin.x || 0, y: origin.y || 0, z: origin.z || 0 };
		}
		const list = Array.from(origin);
		return { x: list[0] || 0, y: list[1] || 0, z: list[2] || 0 };
	}

	function installGpuCapture(win, frames, getSection) {
		const off = { state: "off", json: () => "", uninstall: () => {} };
		if (!(frames > 0) || !win || !win.GPUDevice || typeof getSection !== "function") return off;
		const restores = [];
		const perf = win.performance;
		const now = () => (perf && typeof perf.now === "function") ? perf.now() : Date.now();
		const makeRef = (obj) => typeof win.WeakRef === "function" ? new win.WeakRef(obj) : { deref: () => obj };
		const ids = new WeakMap();
		const surfaceObjs = new WeakSet();
		const records = new Map();
		const shadows = new WeakMap();
		let shadowList = [];
		const mapModes = new WeakMap();
		const mappedRanges = new WeakMap();
		const warnings = [];
		const warned = new Set();
		const warn = (text) => {
			if (warned.has(text)) return;
			warned.add(text);
			warnings.push(text);
		};
		const mark = (text) => {
			try {
				if (win.ingotCrash && typeof win.ingotCrash.mark === "function") win.ingotCrash.mark(text);
			} catch (_) {}
		};
		let nextId = 1;
		let locals = new WeakMap();
		let nextLocal = 1;
		let surface = null;
		let stressSince = null;
		let frameOps = null;
		let initial = null;
		let cachedJson = "";
		const capturedFrames = [];
		const api = {
			state: "idle",
			submits: 0,
			section: "",
			frames,
			json: () => cachedJson,
			uninstall: () => {
				frameOps = null;
				for (const restore of restores.splice(0).reverse()) restore();
				if (win.__ingotCapture === api) delete win.__ingotCapture;
			},
		};

		const serialize = (value, deps) => {
			if (value === null || value === undefined) return null;
			const type = typeof value;
			if (type === "bigint") return Number(value);
			if (type === "function" || type === "symbol") return undefined;
			if (type !== "object") return value;
			if (surfaceObjs.has(value)) return "surface";
			const id = ids.get(value);
			if (id !== undefined) {
				if (deps) deps.push(id);
				return { ref: id };
			}
			const local = locals.get(value);
			if (local !== undefined) return { local };
			if (Array.isArray(value)) {
				return value.map((item) => {
					const out = serialize(item, deps);
					return out === undefined ? null : out;
				});
			}
			if (ArrayBuffer.isView(value)) return { typed: value.constructor.name, values: Array.from(value) };
			const proto = Object.getPrototypeOf(value);
			if (proto !== Object.prototype && proto !== null) {
				const name = (value.constructor && value.constructor.name) || "object";
				warn("unrecorded object " + name);
				return { unknown: name };
			}
			const out = {};
			for (const key of Object.keys(value)) {
				if (value[key] === undefined) continue;
				const item = serialize(value[key], deps);
				if (item !== undefined) out[key] = item;
			}
			return out;
		};

		const register = (obj, kind, extra) => {
			if (!obj || typeof obj !== "object" || ids.has(obj)) return;
			const id = nextId++;
			ids.set(obj, id);
			records.set(id, Object.assign({ id, kind }, extra));
		};

		const trackBuffer = (buffer, desc) => {
			const usage = Number(desc.usage) || 0;
			const mapped = desc.mappedAtCreation === true;
			if (!(usage & (CAPTURE_BUFFER_COPY_DST | CAPTURE_BUFFER_MAP_WRITE)) && !mapped) return;
			const id = ids.get(buffer);
			shadows.set(buffer, { id, kind: "buffer", size: Number(desc.size) || 0, bytes: null, hi: 0 });
			shadowList.push({ id, ref: makeRef(buffer) });
			if (mapped) mapModes.set(buffer, CAPTURE_MAP_MODE_WRITE);
		};

		const trackTexture = (texture, desc) => {
			const usage = Number(desc.usage) || 0;
			if (!(usage & CAPTURE_TEXTURE_COPY_DST)) return;
			const extent = captureExtent(desc.size);
			const bpp = CAPTURE_TEXEL_BYTES[desc.format];
			const dimension = desc.dimension || "2d";
			if (!bpp || dimension !== "2d") {
				warn(`texture ${desc.format} ${dimension} contents not captured`);
				return;
			}
			if (extent.depth > 1) warn("texture layers beyond 0 not captured");
			const id = ids.get(texture);
			shadows.set(texture, {
				id, kind: "texture", format: desc.format, width: extent.width, height: extent.height, bpp,
				size: extent.width * extent.height * bpp, bytes: null,
			});
			shadowList.push({ id, ref: makeRef(texture) });
		};

		const shadowBufferWrite = (shadow, offset, src) => {
			if (!shadow || !src) return;
			const end = Math.min(shadow.size, offset + src.length);
			if (end <= offset) return;
			if (!shadow.bytes) shadow.bytes = new Uint8Array(shadow.size);
			shadow.bytes.set(src.subarray(0, end - offset), offset);
			if (end > shadow.hi) shadow.hi = end;
		};

		const shadowTextureWrite = (shadow, destination, bytes, layout, size) => {
			if ((Number(destination.mipLevel) || 0) !== 0) return;
			const origin = captureOrigin(destination.origin);
			if (origin.z !== 0) return;
			const extent = captureExtent(size);
			const width = Math.min(extent.width, shadow.width - origin.x);
			const height = Math.min(extent.height, shadow.height - origin.y);
			if (width <= 0 || height <= 0) return;
			const rowBytes = width * shadow.bpp;
			const bytesPerRow = layout && layout.bytesPerRow ? Number(layout.bytesPerRow) : extent.width * shadow.bpp;
			const base = layout && layout.offset ? Number(layout.offset) : 0;
			if (!shadow.bytes) shadow.bytes = new Uint8Array(shadow.size);
			for (let row = 0; row < height; row += 1) {
				const src = base + row * bytesPerRow;
				if (src + rowBytes > bytes.length) break;
				const dst = ((origin.y + row) * shadow.width + origin.x) * shadow.bpp;
				shadow.bytes.set(bytes.subarray(src, src + rowBytes), dst);
			}
		};

		const snapshot = () => {
			const buffers = new Map();
			const textures = new Map();
			const alive = [];
			for (const entry of shadowList) {
				const obj = entry.ref.deref();
				if (!obj) continue;
				alive.push(entry);
				const shadow = shadows.get(obj);
				if (!shadow || !shadow.bytes) continue;
				if (shadow.kind === "buffer") {
					if (shadow.hi <= 0) continue;
					const hi = Math.min(shadow.size, (shadow.hi + 3) & ~3);
					buffers.set(shadow.id, shadow.bytes.slice(0, hi));
				} else {
					textures.set(shadow.id, {
						format: shadow.format, width: shadow.width, height: shadow.height, bpp: shadow.bpp,
						bytes: shadow.bytes.slice(),
					});
				}
			}
			shadowList = alive;
			return { buffers, textures };
		};

		const buildJson = () => {
			const roots = new Set();
			const walk = (value) => {
				if (!value || typeof value !== "object") return;
				if (Array.isArray(value)) {
					for (const item of value) walk(item);
					return;
				}
				if (typeof value.ref === "number") {
					roots.add(value.ref);
					return;
				}
				for (const key of Object.keys(value)) walk(value[key]);
			};
			for (const frame of capturedFrames) walk(frame.ops);
			const reachable = new Set();
			const stack = Array.from(roots);
			while (stack.length) {
				const id = stack.pop();
				if (reachable.has(id)) continue;
				const record = records.get(id);
				if (!record) {
					warn("missing object " + id);
					continue;
				}
				reachable.add(id);
				for (const dep of record.deps || []) stack.push(dep);
			}
			const objects = Array.from(reachable).sort((a, b) => a - b).map((id) => {
				const { deps, ...rest } = records.get(id);
				return rest;
			});
			const buffers = [];
			const textures = [];
			if (initial) {
				for (const [id, bytes] of initial.buffers) {
					if (reachable.has(id)) buffers.push({ id, b64: captureBase64(bytes) });
				}
				for (const [id, tex] of initial.textures) {
					if (!reachable.has(id)) continue;
					textures.push({
						id, format: tex.format, width: tex.width, height: tex.height, bpp: tex.bpp,
						b64: captureBase64(tex.bytes),
					});
				}
			}
			return JSON.stringify({
				version: 1,
				userAgent: win.navigator ? String(win.navigator.userAgent) : "",
				section: CAPTURE_SECTION,
				surface,
				objects,
				initial: { buffers, textures },
				frames: capturedFrames,
				warnings,
			});
		};

		const beginFrame = () => {
			frameOps = [];
			locals = new WeakMap();
			nextLocal = 1;
		};

		const afterSubmit = () => {
			api.submits += 1;
			if (api.state === "capturing") {
				capturedFrames.push({ ops: frameOps });
				if (capturedFrames.length < frames) {
					beginFrame();
					return;
				}
				frameOps = null;
				cachedJson = buildJson();
				api.state = "done";
				mark(`capture done frames=${capturedFrames.length} bytes=${cachedJson.length}`);
				return;
			}
			if (api.state !== "idle") return;
			let section = "";
			try {
				section = getSection();
			} catch (_) {}
			api.section = section;
			if (section !== CAPTURE_SECTION) {
				stressSince = null;
				return;
			}
			const t = now();
			if (stressSince === null) {
				stressSince = t;
				return;
			}
			if (t - stressSince < CAPTURE_SETTLE_MS) return;
			initial = snapshot();
			beginFrame();
			api.state = "capturing";
			mark(`capture start frames=${frames}`);
		};

		const guarded = (label, fn) => {
			try {
				fn();
			} catch (error) {
				warn(label + ": " + (error && error.message ? error.message : String(error)));
			}
		};

		for (const [method, kind] of CAPTURE_CREATE_KINDS) {
			wrapPrototypeMethod(win, "GPUDevice", method, (original) => function (...args) {
				const obj = original.apply(this, args);
				guarded(method, () => {
					const deps = [];
					const desc = serialize(args[0], deps) || {};
					register(obj, kind, { desc, deps });
					if (kind === "buffer") trackBuffer(obj, args[0] || {});
					else if (kind === "texture") trackTexture(obj, args[0] || {});
				});
				return obj;
			}, restores);
		}
		wrapPrototypeMethod(win, "GPUDevice", "createRenderPipelineAsync", (original) => function (...args) {
			const deps = [];
			let desc = {};
			guarded("createRenderPipelineAsync", () => { desc = serialize(args[0], deps) || {}; });
			return original.apply(this, args).then((pipeline) => {
				guarded("createRenderPipelineAsync", () => register(pipeline, "renderPipeline", { desc, deps }));
				return pipeline;
			});
		}, restores);
		wrapPrototypeMethod(win, "GPUDevice", "createCommandEncoder", (original) => function (...args) {
			const encoder = original.apply(this, args);
			if (frameOps) {
				guarded("createCommandEncoder", () => {
					const local = nextLocal++;
					frameOps.push({ op: "encoder", local, desc: serialize(args[0]) });
					locals.set(encoder, local);
				});
			}
			return encoder;
		}, restores);
		wrapPrototypeMethod(win, "GPURenderPipeline", "getBindGroupLayout", (original) => function (...args) {
			const layout = original.apply(this, args);
			guarded("getBindGroupLayout", () => {
				const pipelineId = ids.get(this);
				if (pipelineId === undefined) {
					warn("bind group layout of unrecorded pipeline");
					return;
				}
				register(layout, "autoLayout", { pipeline: { ref: pipelineId }, index: Number(args[0]) || 0, deps: [pipelineId] });
			});
			return layout;
		}, restores);
		wrapPrototypeMethod(win, "GPUTexture", "createView", (original) => function (...args) {
			const view = original.apply(this, args);
			guarded("createView", () => {
				if (surfaceObjs.has(this)) {
					surfaceObjs.add(view);
					return;
				}
				const deps = [];
				const textureId = ids.get(this);
				if (textureId === undefined) warn("view of unrecorded texture");
				else deps.push(textureId);
				register(view, "view", {
					texture: textureId === undefined ? null : { ref: textureId },
					desc: serialize(args[0], deps) || {},
					deps,
				});
			});
			return view;
		}, restores);
		wrapPrototypeMethod(win, "GPUCanvasContext", "configure", (original) => function (...args) {
			const result = original.apply(this, args);
			guarded("configure", () => {
				const config = args[0] || {};
				const canvas = this.canvas;
				surface = {
					format: config.format,
					alphaMode: config.alphaMode || "opaque",
					usage: config.usage,
					width: canvas ? canvas.width : 0,
					height: canvas ? canvas.height : 0,
				};
			});
			return result;
		}, restores);
		wrapPrototypeMethod(win, "GPUCanvasContext", "getCurrentTexture", (original) => function (...args) {
			const texture = original.apply(this, args);
			guarded("getCurrentTexture", () => {
				surfaceObjs.add(texture);
				if (!surface) surface = { format: texture.format, alphaMode: "opaque" };
				surface.width = texture.width;
				surface.height = texture.height;
			});
			return texture;
		}, restores);
		wrapPrototypeMethod(win, "GPUBuffer", "mapAsync", (original) => function (...args) {
			guarded("mapAsync", () => mapModes.set(this, Number(args[0]) || 0));
			return original.apply(this, args);
		}, restores);
		wrapPrototypeMethod(win, "GPUBuffer", "getMappedRange", (original) => function (...args) {
			const range = original.apply(this, args);
			guarded("getMappedRange", () => {
				if (!((mapModes.get(this) || 0) & CAPTURE_MAP_MODE_WRITE) || !shadows.has(this)) return;
				let list = mappedRanges.get(this);
				if (!list) {
					list = [];
					mappedRanges.set(this, list);
				}
				list.push({ offset: Number(args[0]) || 0, range });
			});
			return range;
		}, restores);
		wrapPrototypeMethod(win, "GPUBuffer", "unmap", (original) => function (...args) {
			guarded("unmap", () => {
				const list = mappedRanges.get(this);
				mapModes.delete(this);
				if (!list) return;
				mappedRanges.delete(this);
				const shadow = shadows.get(this);
				for (const { offset, range } of list) shadowBufferWrite(shadow, offset, new Uint8Array(range));
				if (frameOps) warn("mapped buffer write during capture is not replayed");
			});
			return original.apply(this, args);
		}, restores);
		wrapPrototypeMethod(win, "GPUQueue", "writeBuffer", (original) => function (...args) {
			guarded("writeBuffer", () => {
				const [buffer, bufferOffset, data, dataOffset, size] = args;
				const all = captureBytes(data);
				if (!all) return;
				const unit = typeof data.BYTES_PER_ELEMENT === "number" ? data.BYTES_PER_ELEMENT : 1;
				const start = (Number(dataOffset) || 0) * unit;
				const length = size === undefined ? all.length - start : Number(size) * unit;
				const bytes = all.subarray(start, start + length);
				shadowBufferWrite(shadows.get(buffer), Number(bufferOffset) || 0, bytes);
				if (frameOps) {
					frameOps.push({
						op: "writeBuffer", buffer: serialize(buffer), offset: Number(bufferOffset) || 0,
						b64: captureBase64(bytes),
					});
				}
			});
			return original.apply(this, args);
		}, restores);
		wrapPrototypeMethod(win, "GPUQueue", "writeTexture", (original) => function (...args) {
			guarded("writeTexture", () => {
				const [destination, data, layout, size] = args;
				const bytes = captureBytes(data);
				if (!bytes || !destination) return;
				const shadow = shadows.get(destination.texture);
				if (shadow) shadowTextureWrite(shadow, destination, bytes, layout, size);
				if (frameOps) {
					frameOps.push({
						op: "writeTexture", destination: serialize(destination), layout: serialize(layout),
						size: serialize(size), b64: captureBase64(bytes),
					});
				}
			});
			return original.apply(this, args);
		}, restores);
		wrapPrototypeMethod(win, "GPUQueue", "submit", (original) => function (...args) {
			if (frameOps) {
				guarded("submit", () => frameOps.push({ op: "submit", buffers: serialize(Array.from(args[0] || [])) }));
			}
			const result = original.apply(this, args);
			guarded("afterSubmit", afterSubmit);
			return result;
		}, restores);
		wrapPrototypeMethod(win, "GPUCommandEncoder", "beginRenderPass", (original) => function (...args) {
			const pass = original.apply(this, args);
			if (frameOps) {
				guarded("beginRenderPass", () => {
					const local = nextLocal++;
					frameOps.push({ op: "beginRenderPass", encoder: serialize(this), local, desc: serialize(args[0]) });
					locals.set(pass, local);
				});
			}
			return pass;
		}, restores);
		wrapPrototypeMethod(win, "GPUCommandEncoder", "finish", (original) => function (...args) {
			const commandBuffer = original.apply(this, args);
			if (frameOps) {
				guarded("finish", () => {
					const local = nextLocal++;
					frameOps.push({ op: "finish", encoder: serialize(this), local, desc: serialize(args[0]) });
					locals.set(commandBuffer, local);
				});
			}
			return commandBuffer;
		}, restores);
		wrapPrototypeMethod(win, "GPUCommandEncoder", "beginComputePass", (original) => function (...args) {
			if (frameOps) warn("compute pass during capture is not replayed");
			return original.apply(this, args);
		}, restores);
		for (const method of CAPTURE_ENCODER_CALLS) {
			wrapPrototypeMethod(win, "GPUCommandEncoder", method, (original) => function (...args) {
				if (frameOps) {
					guarded(method, () => frameOps.push({
						op: "encoderCall", encoder: serialize(this), method, args: serialize(args),
					}));
				}
				return original.apply(this, args);
			}, restores);
		}
		for (const method of CAPTURE_PASS_METHODS) {
			wrapPrototypeMethod(win, "GPURenderPassEncoder", method, (original) => function (...args) {
				if (frameOps) {
					guarded(method, () => frameOps.push({
						op: "pass", pass: serialize(this), method, args: serialize(args),
					}));
				}
				return original.apply(this, args);
			}, restores);
		}
		win.__ingotCapture = api;
		mark(`capture armed frames=${frames}`);
		return api;
	}

	function canvasDpr() {
		const dpr = Number(window.devicePixelRatio);
		if (!Number.isFinite(dpr) || dpr <= 0) return 1;
		const cap = frameLimits.dpr > 0 ? Math.min(frameLimits.dpr, CANVAS_DPR_MAX) : CANVAS_DPR_MAX;
		return Math.min(dpr, cap);
	}

	// The ratio between the backing store and the CSS box after every cap,
	// which is the only number that keeps gfx's swapchain and font atlas in
	// agreement with what the compositor puts on screen.
	function canvasEffectiveDpr() {
		return canvasDpr() * canvasCapScale;
	}

	// Crash-heartbeat probes for memory WebKit keeps outside the page: live
	// WebGPU objects by type, bytes uploaded per heartbeat, and frames that
	// actually reached the GPU. Takes its inputs as parameters so nothing
	// here depends on session-scoped names. A probe that throws reports null.
	const GPU_TOP_TYPES = 4;

	function safeProbe(probe) {
		return () => {
			try {
				return probe();
			} catch (_) {
				return null;
			}
		};
	}

	function gpuHeartbeatProbes(wmi, webgpu) {
		const counts = () => {
			if (!webgpu || typeof webgpu.liveObjectCounts !== "function") return null;
			return webgpu.liveObjectCounts();
		};
		let createdBefore = 0;
		const createdTotal = () => {
			if (!webgpu) return null;
			let total = 0;
			let managers = 0;
			for (const key of Object.keys(webgpu)) {
				const manager = webgpu[key];
				if (!manager || typeof manager.idx !== "number" || typeof manager.create !== "function") continue;
				total += manager.idx;
				managers += 1;
			}
			return managers ? total : null;
		};
		return [
			["gpuObjs", safeProbe(() => {
				const c = counts();
				return c ? c.total : null;
			})],
			["gpuTop", safeProbe(() => {
				const c = counts();
				if (!c) return null;
				return Object.entries(c.byName)
					.filter(([, n]) => n > 0)
					.sort((a, b) => b[1] - a[1])
					.slice(0, GPU_TOP_TYPES)
					.map(([name, n]) => `${name}:${n}`)
					.join(",");
			})],
			["uploadKiB", safeProbe(() => {
				if (!webgpu || typeof webgpu.takeUploadBytes !== "function") return null;
				return (webgpu.takeUploadBytes() / 1024).toFixed(1);
			})],
			["appFrames", safeProbe(() => {
				const x = wmi && wmi.exports;
				if (!x || typeof x.ingot_web_app_frame_count !== "function") return null;
				const count = x.ingot_web_app_frame_count();
				return count < 0 ? null : count;
			})],
			["gpuNew", safeProbe(() => {
				const total = createdTotal();
				if (total === null) return null;
				const delta = total - createdBefore;
				createdBefore = total;
				return delta;
			})],
		];
	}

	function canvasPixelsMax() {
		if (typeof window.matchMedia === "function") {
			const coarse = window.matchMedia("(pointer: coarse)");
			if (coarse && coarse.matches) return CANVAS_PIXELS_MAX_COARSE;
		}
		return CANVAS_PIXELS_MAX_FINE;
	}

	// Largest whole CSS size not above `value` whose product with `dpr` is a
	// whole number of device pixels. A fractional product cannot be honoured
	// by a bitmap, and rounding it leaves the browser resampling every frame
	// by a fraction of a pixel, which is exactly what reads as blur.
	function snapCssDimension(value, dpr) {
		if (!Number.isFinite(value) || value < 1) return 1;
		const floored = Math.floor(value);
		for (let step = 0; step <= CANVAS_SNAP_STEPS_MAX; step += 1) {
			const candidate = floored - step;
			if (candidate < 1) break;
			const pixels = candidate * dpr;
			if (Math.abs(pixels - Math.round(pixels)) < 1e-6) return candidate;
		}
		return Math.max(1, floored);
	}

	// Content box of the canvas. clientWidth excludes a CSS border, which
	// getBoundingClientRect includes; a bitmap sized to the border box paints
	// two pixels wider than the area it is drawn into. The node DOM stub only
	// offers the rect, so fall back to it there.
	function canvasContentBox(c) {
		const clientW = Number(c.clientWidth);
		const clientH = Number(c.clientHeight);
		if (clientW > 0 && clientH > 0) return { width: clientW, height: clientH };
		const rect = c.getBoundingClientRect();
		return { width: rect.width, height: rect.height };
	}

	// Largest CANVAS_DPR_STEP multiple, not above `dpr`, at which a css box of
	// cssW x cssH fits both the pixel budget and the per-axis bound. Zero when
	// even one step does not fit, which only a pathological box can cause.
	function steppedCanvasRatio(cssW, cssH, dpr, budget) {
		const limit = Math.min(
			dpr,
			Math.sqrt(budget / (cssW * cssH)),
			CANVAS_DIMENSION_MAX / cssW,
			CANVAS_DIMENSION_MAX / cssH,
		);
		if (!Number.isFinite(limit)) return 0;
		return Math.floor(limit / CANVAS_DPR_STEP) * CANVAS_DPR_STEP;
	}

	// Android Chrome flashes a highlight over any tapped element it treats as
	// interactive; the focusable canvas qualifies, so every button press
	// flashed the whole app. Applied from here so every embedding page gets it.
	function suppressTapHighlight(canvas) {
		if (!canvas || !canvas.style) return;
		if (typeof canvas.style.setProperty === "function") {
			canvas.style.setProperty("-webkit-tap-highlight-color", "transparent");
		}
	}

	function fitCanvas() {
		const c = document.getElementById(CANVAS_ID);
		if (!c) return;
		const dpr = canvasDpr();
		// Release the pin from the previous fit before measuring, otherwise
		// the canvas can never grow back after a shrink.
		c.style.width = "";
		c.style.height = "";
		const box = canvasContentBox(c);
		let cssW = snapCssDimension(box.width, dpr);
		let cssH = snapCssDimension(box.height, dpr);
		let w = Math.min(CANVAS_DIMENSION_MAX, Math.max(1, Math.round(cssW * dpr)));
		let h = Math.min(CANVAS_DIMENSION_MAX, Math.max(1, Math.round(cssH * dpr)));
		const budget = canvasPixelsMax();
		canvasCapScale = 1;
		if (w * h > budget) {
			let stepped = steppedCanvasRatio(cssW, cssH, dpr, budget);
			let fitted = null;
			// Re-snapping the css box to the stepped ratio can hand back a few
			// more css pixels than the dpr snap did, so the budget is checked
			// on the final bitmap and the ratio steps down until it holds.
			// Bounded: dpr is at most CANVAS_DPR_MAX, so this runs at most
			// CANVAS_DPR_MAX / CANVAS_DPR_STEP times.
			while (stepped >= CANVAS_DPR_STEP && fitted === null) {
				const snappedW = snapCssDimension(box.width, stepped);
				const snappedH = snapCssDimension(box.height, stepped);
				const pixelsW = Math.max(1, Math.round(snappedW * stepped));
				const pixelsH = Math.max(1, Math.round(snappedH * stepped));
				const fits = pixelsW * pixelsH <= budget &&
					pixelsW <= CANVAS_DIMENSION_MAX && pixelsH <= CANVAS_DIMENSION_MAX;
				if (fits) fitted = { snappedW, snappedH, pixelsW, pixelsH };
				else stepped -= CANVAS_DPR_STEP;
			}
			if (fitted !== null) {
				cssW = fitted.snappedW;
				cssH = fitted.snappedH;
				w = fitted.pixelsW;
				h = fitted.pixelsH;
				canvasCapScale = stepped / dpr;
			} else {
				const scale = Math.sqrt(budget / (w * h));
				w = Math.max(1, Math.floor(w * scale));
				h = Math.max(1, Math.floor(h * scale));
				canvasCapScale = Math.min(w / (cssW * dpr), h / (cssH * dpr));
			}
		}
		if (c.width !== w) c.width = w;
		if (c.height !== h) c.height = h;
		// Pin the element to the snapped CSS size so it covers exactly the
		// device pixels the bitmap has. The slack (under one CSS pixel per
		// axis) shows the stage background, which the demo pages colour to
		// match.
		c.style.width = `${cssW}px`;
		c.style.height = `${cssH}px`;
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

	function semanticBounds(state, element, x, y, width, height) {
		const rect = canvasRect();
		if (!rect) return;
		// Bisect (?ingot_a11y=static): place each mirror element once, never
		// move it, to separate per-frame restyling from element existence.
		if (bisectSwitches.a11y === "static" && state.bounds) return;
		const left = rect.left + x;
		const top = rect.top + y;
		// Style writes invalidate layout even when values are unchanged on some
		// engines; diffing keeps steady-state frames free of DOM mutations.
		const b = state.bounds || (state.bounds = {});
		if (b.left === left && b.top === top && b.width === width && b.height === height) return;
		b.left = left; b.top = top; b.width = width; b.height = height;
		element.style.position = "fixed";
		element.style.left = `${left}px`;
		element.style.top = `${top}px`;
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
		semanticBounds(state, input, x, y, width, height);
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
		semanticBounds(state, button, x, y, width, height);
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
	// 1 checked, 2 disabled, 4 focused, 8 expanded, 16 selected.
	const CONTROL_ROLES = {
		1: { tag: "button" },                     // Button
		2: { tag: "input", type: "checkbox" },    // Checkbox
		3: { tag: "input", type: "radio" },       // Radio
		4: { tag: "input", type: "range" },       // Slider
		6: { tag: "button", listbox: true },      // Dropdown
		7: { tag: "button" },                     // Menu_Item
		15: { tag: "div", ariaRole: "option" },   // Option
		18: { tag: "div", ariaRole: "listbox" },  // List_Box
		19: { tag: "a", ariaRole: "link" },        // Link
	};

	function createSemanticControl(key, role) {
		const spec = CONTROL_ROLES[role];
		if (!spec) return null;
		const el = document.createElement(spec.tag);
		if (spec.type) el.type = spec.type;
		if (spec.ariaRole) el.setAttribute("role", spec.ariaRole);
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

	function syncSemanticControl(key, role, label, x, y, width, height, stateBits, value, lo, hi, positionInSet = 0, sizeOfSet = 0) {
		if (role === 5) {
			if (semanticTextInputsNext.length < SEMANTIC_CONTROLS_MAX) {
				semanticTextInputsNext.push({
					key, x, y, w: width, h: height, focused: (stateBits & 4) !== 0,
				});
			}
			return 0;
		}
		// Bisect (?ingot_a11y=off): no DOM mirror for controls. Text-input
		// rects above stay, the IME keyboard depends on them.
		if (bisectSwitches.a11y === "off") return 0;
		let state = semanticControls.get(key);
		if (state && state.role !== role) {
			state.el.remove();
			semanticControls.delete(key);
			state = null;
		}
		if (!state && semanticControlsSynced >= SEMANTIC_CONTROLS_MAX) return 0;
		if (!state) state = createSemanticControl(key, role);
		if (!state) return 0;
		semanticControlsSynced += 1;
		state.seen = semanticFrame;
		const el = state.el;
		if (state.label !== label) {
			state.label = label;
			el.setAttribute("aria-label", label);
			if (el.tagName === "BUTTON") el.textContent = label;
		}
		semanticBounds(state, el, x, y, width, height);
		el.disabled = (stateBits & 2) !== 0;
		if (state.role === 2 || state.role === 3) el.checked = (stateBits & 1) !== 0;
		if (state.role === 6) el.setAttribute("aria-expanded", (stateBits & 8) !== 0 ? "true" : "false");
		if (state.role === 15) el.setAttribute("aria-selected", (stateBits & 16) !== 0 ? "true" : "false");
		if (positionInSet > 0 && sizeOfSet > 0) {
			el.setAttribute("aria-posinset", String(positionInSet));
			el.setAttribute("aria-setsize", String(sizeOfSet));
		} else {
			el.removeAttribute("aria-posinset");
			el.removeAttribute("aria-setsize");
		}
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
		return textEncoder.encode(input.value.slice(0, end)).length;
	}

	function endSemanticFrame() {
		semanticTextInputs = semanticTextInputsNext;
		semanticTextInputsNext = [];
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

	// browser CSS cursor strings indexed by ingot MouseCursor enum (gfx/types.odin);
	// index 11 is the hidden-cursor sentinel used by platform_set_cursor_hidden.
	const CURSORS = [
		"default", "default", "text", "crosshair", "pointer",
		"ew-resize", "ns-resize", "nwse-resize", "nesw-resize", "move",
		"not-allowed", "none",
	];

	// The GPU device is gone for good once the browser revokes it (tab
	// backgrounded too long, GPU process reset, memory pressure on a phone).
	// gfx stops drawing, so without this the page is a frozen canvas with no
	// explanation. Idempotent: at most one overlay per page.
	const DEVICE_LOST_ID = "ingot-device-lost";
	let deviceLost = false;

	function reloadPage() {
		if (typeof location !== "undefined" && typeof location.reload === "function") {
			location.reload();
		}
	}

	function showDeviceLost(reason) {
		if (deviceLost) return;
		deviceLost = true;
		if (!document.body || document.getElementById(DEVICE_LOST_ID)) return;
		const panel = document.createElement("div");
		panel.id = DEVICE_LOST_ID;
		panel.setAttribute("role", "alert");
		panel.setAttribute("data-reason", String(reason));
		Object.assign(panel.style, {
			position: "fixed", inset: "0", zIndex: "20", display: "flex",
			flexDirection: "column", alignItems: "center", justifyContent: "center",
			gap: "12px", padding: "24px", background: "rgba(20, 20, 24, 0.92)",
			color: "#ddd", font: "14px ui-monospace, monospace", textAlign: "center",
			cursor: "pointer",
		});
		const text = document.createElement("div");
		text.textContent = "The browser reset graphics. Tap to reload.";
		const button = document.createElement("button");
		button.type = "button";
		button.textContent = "Reload";
		panel.appendChild(text);
		panel.appendChild(button);
		// The whole panel is the target: "tap to reload" must work on a
		// phone without hunting for the button.
		panel.addEventListener("click", reloadPage);
		document.body.appendChild(panel);
	}

	function clearDeviceLost() {
		deviceLost = false;
		const panel = document.getElementById(DEVICE_LOST_ID);
		if (panel) panel.remove();
	}

	// The "ingot" foreign-import module (see gfx/platform_web.odin).
	function ingotImports() {
		return {
			ingot_perf_now: () => performance.now(),
			// Logical size must be the same content box fitCanvas sized the
			// bitmap from, or the engine lays out against a border it cannot
			// paint into.
			ingot_canvas_css_width: () => {
				const c = document.getElementById(CANVAS_ID);
				return c ? canvasContentBox(c).width : 0;
			},
			ingot_canvas_css_height: () => {
				const c = document.getElementById(CANVAS_ID);
				return c ? canvasContentBox(c).height : 0;
			},
			ingot_canvas_pixel_width: () => {
				const c = document.getElementById(CANVAS_ID);
				return c ? c.width : 0;
			},
			ingot_canvas_pixel_height: () => {
				const c = document.getElementById(CANVAS_ID);
				return c ? c.height : 0;
			},
			ingot_device_pixel_ratio: () => canvasEffectiveDpr(),
			// gfx/platform_web.odin _web_on_device_lost: the browser revoked
			// the GPU device. Nothing can draw again in this page instance.
			ingot_device_lost: (reason) => showDeviceLost(reason),
			ingot_set_cursor: (cur) => {
				const c = document.getElementById(CANVAS_ID);
				if (c) c.style.cursor = CURSORS[cur] || "default";
			},
			ingot_clipboard_len: () => textEncoder.encode(clipboardText).length,
			ingot_clipboard_copy: (destination, capacity) => {
				const bytes = textEncoder.encode(clipboardText);
				const count = Math.min(capacity, bytes.length);
				if (count > 0) wasmBytes(destination, count).set(bytes.subarray(0, count));
				return count;
			},
			ingot_set_clipboard: (pointer) => {
				if (!wasmMemoryInterface || !pointer) return;
				const memory = new Uint8Array(wasmMemoryInterface.memory.buffer);
				let end = pointer;
				while (end < memory.length && memory[end] !== 0) end += 1;
				clipboardText = decodeUtf8(memory.subarray(pointer, end));
				if (navigator.clipboard && navigator.clipboard.writeText) {
					navigator.clipboard.writeText(clipboardText).catch(() => {});
				}
			},
			ingot_set_window_title: (pointer) => {
				if (!wasmMemoryInterface || !pointer) return;
				const memory = new Uint8Array(wasmMemoryInterface.memory.buffer);
				let end = pointer;
				while (end < memory.length && memory[end] !== 0) end += 1;
				document.title = decodeUtf8(memory.subarray(pointer, end));
			},
			ingot_web_input_frame_begin: () => {
				semanticFrame += 1;
				semanticControlsSynced = 0;
				canvasRectCache = null;
			},
			ingot_web_input_frame_end: endSemanticFrame,
			ingot_web_mark: (ptr, len) => {
				if (!ptr || len <= 0) return;
				let text;
				try {
					text = wasmText(ptr, len);
				} catch (_) {
					return;
				}
				if (text.startsWith("section ")) currentSection = text.slice(8);
				if (!window.ingotCrash || typeof window.ingotCrash.mark !== "function") return;
				try {
					window.ingotCrash.mark(text);
				} catch (_) {}
			},
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
				return state ? textEncoder.encode(state.input.value).length : 0;
			},
			ingot_web_input_value_copy: (fieldPointer, fieldLength, destination, capacity) => {
				const state = semanticInputState(wasmText(fieldPointer, fieldLength));
				if (!state) return 0;
				const bytes = textEncoder.encode(state.input.value);
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
				x, y, width, height, stateBits, value, lo, hi, positionInSet, sizeOfSet) => syncSemanticControl(
				`${idHi >>> 0}:${idLo >>> 0}`, role,
				wasmText(labelPointer, labelLength),
				x, y, width, height, stateBits, value, lo, hi, positionInSet, sizeOfSet,
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
					// Only steal focus from ourselves - never from semantic
					// DOM form inputs (ingot-web-input overlays).
					const a = document.activeElement;
					if (a !== ime && (a === c || a === document.body || a === null)) {
						ime.focus({ preventScroll: true });
					}
				} else if (document.activeElement === ime) {
					// A touch tap focused the proxy inside the gesture (see
					// focusImeForTap in ingot_input.js); give the engine a
					// few frames to activate the field before treating an
					// inactive report as "no field focused".
					const tapAt = ime.ingotTapFocusAt || 0;
					const now = (typeof performance !== "undefined" && performance.now)
						? performance.now() : Date.now();
					if (tapAt > 0 && now - tapAt < IME_TAP_FOCUS_GRACE_MS) return;
					ime.ingotTapFocusAt = 0;
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
				const id = textEncoder.encode(pad.id || "");
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

	// WebAudio bridge ("ingot_audio" import module - gfx/audio_web.odin).
	// Each slot is one voice: a decoded AudioBuffer + per-slot GainNode,
	// mirroring the native miniaudio pool. The AudioContext starts suspended
	// under browser autoplay policy; the first user gesture resumes it, and
	// plays issued before the unlock are dropped silently.
	const AUDIO_MAX_SLOTS = 256;
	const audioState = {
		ctx: null,
		master: null,
		slots: new Array(AUDIO_MAX_SLOTS).fill(null),
		unlock: null,
	};

	function audioResume() {
		if (audioState.ctx && audioState.ctx.state === "suspended") {
			audioState.ctx.resume().catch(() => {});
		}
	}

	// Start (or restart) playback on a decoded slot. Shared by ingot_audio_play
	// and the deferred start applied when an async decode completes.
	function audioStart(s, restart) {
		if (!s.buffer || !audioState.ctx) return;
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
					audioState.unlock = () => audioResume();
					window.addEventListener("pointerdown", audioState.unlock);
					window.addEventListener("keydown", audioState.unlock);
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
					load: 1, frames, pendingPlay: false, pendingRestart: false,
				};
				return slot;
			},
			// Async file loading: the slot is allocated eagerly so the engine
			// gets a valid handle immediately; fetch + decodeAudioData resolve
			// behind it. load: 0 = pending, 1 = ready, 2 = error (slot stays
			// allocated but permanently silent - mirrors httpSlots' error state).
			ingot_audio_load: (urlPtr, urlLen, looping) => {
				if (!audioState.ctx) return -1;
				const slot = audioState.slots.findIndex((v) => v === null);
				if (slot < 0) return -1;
				const s = {
					buffer: null, gain: audioState.ctx.createGain(), source: null,
					playing: false, looping: looping !== 0, pitch: 1,
					load: 0, frames: 0, pendingPlay: false, pendingRestart: false,
					controller: new AbortController(),
				};
				s.gain.connect(audioState.master);
				audioState.slots[slot] = s;
				fetch(wasmText(urlPtr, urlLen), {
					credentials: "same-origin",
					signal: s.controller.signal,
				})
					.then((response) => {
						if (!response.ok) throw new Error("http " + response.status);
						return response.arrayBuffer();
					})
					.then((bytes) => audioState.ctx.decodeAudioData(bytes))
					.then((buffer) => {
						if (audioState.slots[slot] !== s) return; // unloaded mid-flight
						s.buffer = buffer;
						s.frames = buffer.length;
						s.load = 1;
						// Apply intent recorded while the decode was in flight so
						// PlaySound-right-after-LoadSound "just works".
						if (s.pendingPlay) {
							s.pendingPlay = false;
							audioStart(s, s.pendingRestart);
						}
					})
					.catch(() => { if (audioState.slots[slot] === s) s.load = 2; });
				return slot;
			},
			ingot_audio_ready: (slot) => {
				const s = audioState.slots[slot];
				return s ? s.load : 2;
			},
			ingot_audio_frames: (slot) => {
				const s = audioState.slots[slot];
				return s ? s.frames : 0;
			},
			ingot_audio_unload: (slot) => {
				const s = audioState.slots[slot];
				if (!s) return;
				if (s.controller) s.controller.abort();
				if (s.source) { try { s.source.stop(); } catch (_) {} }
				s.gain.disconnect();
				audioState.slots[slot] = null;
			},
			ingot_audio_play: (slot, restart) => {
				const s = audioState.slots[slot];
				if (!s) return;
				if (!s.buffer) {
					// Decode still in flight: record intent, applied on completion.
					if (s.load === 0) { s.pendingPlay = true; s.pendingRestart = !!restart; }
					return;
				}
				audioStart(s, restart);
			},
			ingot_audio_stop: (slot) => {
				const s = audioState.slots[slot];
				if (!s) return;
				s.pendingPlay = false; // cancel a deferred start too
				if (!s.source) return;
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

	function attachDrop(wmi) {
		if (detachDrop) detachDrop();
		const canvas = document.getElementById(CANVAS_ID);
		if (!canvas) return () => {};
		let active = true;
		let depth = 0;
		const generation = ++dropGeneration;
		const exports = () => wmi && wmi.exports;
		const hasFiles = (event) => Array.from(
			event.dataTransfer ? event.dataTransfer.types || [] : []).includes("Files");
		const notifyHover = (over) => {
			const x = exports();
			if (x && x.ingot_web_file_drag_over) x.ingot_web_file_drag_over(over);
		};
		const onDragEnter = (event) => {
			if (!hasFiles(event)) return;
			event.preventDefault();
			depth = Math.min(depth + 1, 1024);
			if (depth === 1) notifyHover(true);
		};
		const onDragOver = (event) => {
			if (!hasFiles(event)) return;
			event.preventDefault();
			if (depth === 0) depth = 1;
			notifyHover(true);
		};
		const onDragLeave = (event) => {
			if (depth === 0) return;
			event.preventDefault();
			depth -= 1;
			if (depth === 0) notifyHover(false);
		};
		const onDrop = async (event) => {
			if (!hasFiles(event)) return;
			event.preventDefault();
			depth = 0;
			notifyHover(false);
			const files = Array.from(event.dataTransfer ? event.dataTransfer.files : [])
				.slice(0, MAX_DROP_FILES);
			const staged = [];
			for (const file of files) {
				if (file.size > MAX_DROP_BYTES) continue;
				try {
					const buffer = await file.arrayBuffer();
					staged.push({
						name: new TextEncoder().encode(file.name),
						data: new Uint8Array(buffer),
					});
				} catch (_) { /* unreadable file: skip */ }
			}
			if (!active || generation !== dropGeneration || staged.length === 0) return;
			dropFiles = staged;
			const x = exports();
			if (x && x.ingot_web_drop_notify) x.ingot_web_drop_notify();
		};
		const onCancel = () => {
			if (depth > 0) notifyHover(false);
			depth = 0;
		};
		canvas.addEventListener("dragenter", onDragEnter);
		canvas.addEventListener("dragover", onDragOver);
		canvas.addEventListener("dragleave", onDragLeave);
		canvas.addEventListener("drop", onDrop);
		window.addEventListener("blur", onCancel);
		const cleanup = () => {
			if (!active) return;
			active = false;
			dropGeneration += 1;
			onCancel();
			canvas.removeEventListener("dragenter", onDragEnter);
			canvas.removeEventListener("dragover", onDragOver);
			canvas.removeEventListener("dragleave", onDragLeave);
			canvas.removeEventListener("drop", onDrop);
			window.removeEventListener("blur", onCancel);
			if (detachDrop === cleanup) detachDrop = null;
		};
		detachDrop = cleanup;
		return cleanup;
	}

	function clearSemanticOverlays() {
		for (const state of semanticInputs.values()) state.input.remove();
		for (const state of semanticForms.values()) state.form.remove();
		for (const state of semanticControls.values()) state.el.remove();
		semanticInputs.clear();
		semanticForms.clear();
		semanticControls.clear();
	}

	function box3dWorkerImports(box3dWorkers) {
		if (box3dWorkers) return box3dWorkers.imports;
		return {
			schedule: () => false,
			request_step: () => false,
			request_batch: () => false,
			request_command: () => false,
			step_ready: () => false,
			batch_ready: () => false,
			command_ready: () => false,
			elapsed_micros: () => 0,
			completed_value: () => 0,
			batch_elapsed_micros: () => 0,
			batch_step_count: () => 0,
			task_count: () => 0,
			queue_high_water: () => 0,
			failure_count: () => 0,
			completion_generation: () => 0,
			worker_count: () => 1,
		};
	}

	async function createSession(wasmPath, opts) {
		opts = opts || {};
		wasmPath = wasmPath || "ingot_web.wasm";
		if (activeSession) throw new Error("an ingot web session is already active");
		if (!navigator.gpu) {
			throw new Error(
				"WebGPU is not available. Use Chrome/Edge 113+ or Safari 18+.");
		}
		const sharedMemory = typeof SharedArrayBuffer !== "undefined" &&
			crossOriginIsolated === true;
		const threaded = opts.box3dWorkers === true && sharedMemory;
		const wmi = new window.odin.WasmMemoryInterface();
		let box3dWorkers = null;
		// Only the threaded module imports env.memory; every other build
		// exports its own. Allocating a shared buffer for them wastes 64 MiB
		// and makes odin.js warn about a memory it is about to discard, which
		// became reachable on every demo once the site turned on COOP/COEP.
		if (threaded) {
			const memory = new WebAssembly.Memory({
				initial: 1024,
				maximum: 4096,
				shared: true,
			});
			wmi.setMemory(memory);
			if (!window.ingotBox3dWorkers) {
				throw new Error("box3dWorkers requested but box3d_workers.js is not loaded");
			}
			box3dWorkers = await window.ingotBox3dWorkers.create(wasmPath, memory, opts);
		}
		wasmMemoryInterface = wmi;
		// Before any GPU call so the capture sees every object the engine
		// creates. Off unless ?ingot_capture=N.
		const gpuCapture = installGpuCapture(window, bisectSwitches.capture, () => currentSection);
		const webgpu = new window.odin.WebGPUInterface(wmi);
		if (bisectSwitches.upload === "view" && "uploadMode" in webgpu) webgpu.uploadMode = "view";
		// Feed the crash recorder the metrics that can explain a kill from
		// inside the page. The wasm heap alone proved insufficient: a real
		// capture showed it flat at 43 MiB while the tab died anyway, so the
		// memory must be outside it. These probes narrow that down.
		// Optional: the demos load the recorder, embedders may not.
		let gpuCallCounters = null;
		let gpuBacklog = null;
		if (window.ingotCrash && window.ingotCrash.watch) {
			gpuCallCounters = installGpuCallCounters(window);
			window.ingotCrash.watch("gpuCalls", gpuCallCounters.probe);
			gpuBacklog = installGpuBacklogProbe(window);
			window.ingotCrash.watch("gpuQ", gpuBacklog.probe);
			window.ingotCrash.watch("wasmMiB", () => {
				const memory = wmi.memory;
				if (!memory || !memory.buffer) return null;
				return (memory.buffer.byteLength / (1024 * 1024)).toFixed(1);
			});
			// The framebuffer is the leading suspect for off-heap memory: at
			// dpr 3 a phone-sized canvas is ~12 MB per swapchain buffer.
			// Reported as WxH@dpr plus the megabytes one buffer occupies.
			window.ingotCrash.watch("canvas", () => {
				const c = document.getElementById(CANVAS_ID);
				if (!c) return null;
				const mib = (c.width * c.height * 4) / (1024 * 1024);
				const scale = canvasEffectiveDpr().toFixed(3);
				return `${c.width}x${c.height}@${scale}=${mib.toFixed(1)}MiB`;
			});
			// Chrome (and CriOS) expose the JS heap; Safari does not, so this
			// probe simply reports nothing there rather than guessing.
			window.ingotCrash.watch("jsHeapMiB", () => {
				const memory = performance.memory;
				if (!memory || !memory.usedJSHeapSize) return null;
				return (memory.usedJSHeapSize / (1024 * 1024)).toFixed(1);
			});
			// The semantic mirror creates real DOM nodes per widget. A count
			// that climbs frame over frame would mean the reaper is failing.
			window.ingotCrash.watch("domNodes", () => {
				return document.getElementsByTagName("*").length;
			});
			// Each font size is a 2048x2048 GPU atlas. A kill right after
			// this steps up points at atlas creation rather than the canvas.
			window.ingotCrash.watch("atlases", () => {
				const x = wmi.exports;
				if (!x || typeof x.ingot_web_atlas_count !== "function") return null;
				const count = x.ingot_web_atlas_count();
				return count < 0 ? null : count;
			});
			for (const [name, probe] of gpuHeartbeatProbes(wmi, webgpu)) {
				window.ingotCrash.watch(name, probe);
			}
		}
		if (window.ingotCrash && typeof window.ingotCrash.mark === "function") {
			try {
				window.ingotCrash.mark("switches " + describeBisectSwitches(bisectSwitches));
				window.ingotCrash.mark("limits " + describeFrameLimits(frameLimits));
			} catch (_) {}
		}
		const uninstallFrameRateCap = installFrameRateCap(window, frameLimits.fps);
		const uninstallGpuBackpressure = installGpuBackpressure(
			window,
			bisectSwitches.inflight,
			gpuBacklog ? gpuBacklog.inFlight : null,
			gpuBacklog ? gpuBacklog.noteDeferred : null,
		);
		const uninstallGcNudge = installGcNudge(window, bisectSwitches.gc);
		const uninstallGpuSkips = installGpuSkips(window, bisectSwitches.skip, () => currentSection);
		const uninstallAutoScroll = installAutoScroll(
			window,
			() => wmi.exports,
			() => {
				const c = document.getElementById(CANVAS_ID);
				return c ? canvasContentBox(c) : null;
			},
			bisectSwitches.autoscroll,
		);
		suppressTapHighlight(document.getElementById(CANVAS_ID));
		const listeners = [];
		const listen = (target, type, handler) => {
			target.addEventListener(type, handler);
			listeners.push([target, type, handler]);
		};
		const applyResize = () => {
			fitCanvas();
			const x = wmi.exports;
			if (x && x.ingot_web_resize) x.ingot_web_resize();
		};
		// Mobile browsers fire resize in bursts (URL bar, rotation, soft
		// keyboard). Each fit can reallocate the swapchain, so apply at most
		// one per animation frame. Hosts without rAF (node tests) stay
		// synchronous.
		let resizeFrame = 0;
		const onResize = () => {
			if (typeof window.requestAnimationFrame !== "function") {
				applyResize();
				return;
			}
			if (resizeFrame) return;
			resizeFrame = window.requestAnimationFrame(() => {
				resizeFrame = 0;
				applyResize();
			});
		};
		const onPaste = (event) => {
			const text = event.clipboardData && event.clipboardData.getData("text/plain");
			if (typeof text === "string") clipboardText = text;
		};
		const onResume = () => {
			if (document.visibilityState && document.visibilityState !== "visible") return;
			// The device cannot come back in this page, and reloading is what
			// the user would do anyway on returning to a dead canvas.
			if (deviceLost) {
				reloadPage();
				return;
			}
			fitCanvas();
			const x = wmi.exports;
			if (x && x.ingot_web_resume) x.ingot_web_resume();
		};
		fitCanvas();
		listen(window, "resize", onResize);
		listen(window, "orientationchange", onResize);
		// visualViewport tracks the soft keyboard and pinch zoom, which on
		// iOS do not always fire a window resize.
		if (window.visualViewport) listen(window.visualViewport, "resize", onResize);
		// The canvas's container can change size without the window doing so
		// (flex layout, a crash panel appearing). fitCanvas pins only the
		// canvas's own style, so observing the parent cannot feed back.
		const canvasElement = document.getElementById(CANVAS_ID);
		const canvasParent = canvasElement && canvasElement.parentElement;
		const resizeObserver = typeof ResizeObserver === "function" && canvasParent
			? new ResizeObserver(onResize) : null;
		if (resizeObserver) resizeObserver.observe(canvasParent);
		listen(window, "paste", onPaste);
		listen(window, "pageshow", onResume);
		listen(document, "visibilitychange", onResume);
		const detachInput = window.ingotInput && window.ingotInput.attach
			? window.ingotInput.attach(CANVAS_ID, wmi) : () => {};
		const detachFiles = attachDrop(wmi);
		const appSession = opts.appSessionFactory ? opts.appSessionFactory(wmi) : null;
		const extra = Object.assign({
			wgpu: webgpu.getInterface(),
			ingot: ingotImports(),
			ingot_http: httpImports(),
			ingot_audio: audioImports(),
			ingot_box3d_workers: box3dWorkerImports(box3dWorkers),
		}, appSession ? appSession.imports : {}, opts.imports || {});
		let destroyed = false;
		const session = {
			wmi,
			destroy: () => {
				if (destroyed) return;
				destroyed = true;
				const x = wmi.exports;
				const errors = [];
				const safely = (fn) => {
					try { fn(); } catch (error) { errors.push(error); }
				};
				if (opts.onDestroy) safely(() => opts.onDestroy(x));
				if (x && x.client_web_shutdown) safely(() => x.client_web_shutdown());
				if (box3dWorkers) safely(() => box3dWorkers.destroy());
				for (const slot of httpSlots) {
					if (slot && slot.controller) safely(() => slot.controller.abort());
				}
				httpSlots.fill(null);
				if (appSession && appSession.destroy) safely(() => appSession.destroy());
				safely(detachFiles);
				safely(detachInput);
				for (const [target, type, handler] of listeners) {
					safely(() => target.removeEventListener(type, handler));
				}
				if (resizeObserver) safely(() => resizeObserver.disconnect());
				if (resizeFrame && typeof window.cancelAnimationFrame === "function") {
					safely(() => window.cancelAnimationFrame(resizeFrame));
				}
				resizeFrame = 0;
				safely(uninstallGpuBackpressure);
				safely(uninstallFrameRateCap);
				safely(uninstallGcNudge);
				safely(uninstallAutoScroll);
				safely(uninstallGpuSkips);
				if (gpuBacklog) safely(gpuBacklog.uninstall);
				if (gpuCallCounters) safely(gpuCallCounters.uninstall);
				safely(gpuCapture.uninstall);
				currentSection = "";
				safely(clearDeviceLost);
				safely(clearSemanticOverlays);
				if (wasmMemoryInterface === wmi) wasmMemoryInterface = null;
				if (activeSession === session) activeSession = null;
				if (errors.length) console.error("ingot session cleanup failed", errors);
			},
		};
		activeSession = session;
		try {
			session.runResult = await window.odin.runWasm(wasmPath, null, extra, wmi);
			return session;
		} catch (error) {
			session.destroy();
			throw error;
		}
	}

	async function ingotRun(wasmPath, opts) {
		return createSession(wasmPath, opts);
	}

	function ingotStop() {
		if (activeSession) activeSession.destroy();
	}

	window.ingotWeb = {
		run: ingotRun,
		stop: ingotStop,
		createSession: createSession,
		fitCanvas: fitCanvas,
		ingotImports: ingotImports,
		httpImports: httpImports,
		audioImports: audioImports,
		textInputs: () => semanticTextInputs,
	};

	// Test-only export hook: node --test (web/test/) exercises the semantic
	// overlay logic against a DOM stub. Guarded so browsers never see it and
	// no behavior changes.
	if (typeof globalThis.__ingot_test_hook === "function") {
		globalThis.__ingot_test_hook({
			syncSemanticInput,
			syncSemanticControl,
			syncSemanticSubmit,
			endSemanticFrame,
			beginSemanticFrame: () => { semanticFrame += 1; },
			semanticState: () => ({ semanticInputs, semanticForms, semanticControls }),
			textInputs: () => semanticTextInputs,
			attachDrop,
			box3dWorkerImports,
			clearDeviceLost,
			gpuHeartbeatProbes,
			parseBisectSwitches,
			describeBisectSwitches,
			installFrameRateCap,
			installGpuBackpressure,
			bisectSwitches,
			isIosWebKit,
			resolveFrameLimits,
			describeFrameLimits,
			installGcNudge,
			suppressTapHighlight,
			installAutoScroll,
			installGpuCallCounters,
			installGpuBacklogProbe,
			installGpuSkips,
			installGpuCapture,
			setCurrentSection: (name) => { currentSection = String(name); },
		});
	}
})();
