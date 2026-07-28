// ingot_app.js - reusable app-I/O bridges for ingot web apps.
//
// Provides the JS-side implementations of the foreign-import modules the ingot
// app packages call into:
//   - ingot_ws:    browser WebSocket   (backs ingot:net ws_web.odin)
//   - ingot_http:  browser fetch()     (backs ingot:net http_web.odin)
//   - ingot_store: localStorage        (backs ingot:prefs prefs_web.odin)
//   - ingot_open:  window.open()       (backs ingot:sys openurl_web.odin)
//
// Each factory takes a WasmMemoryInterface (WMI) so the closures can read/write
// the app's wasm linear memory, and returns the import object for that module.
// A host boot script merges these into the `extra` imports passed to
// odin.runWasm alongside wgpu + the engine "ingot" module (ingot_web.js).
//
//   const extra = {
//     wgpu:        webgpu.getInterface(),
//     ingot:       window.ingotWeb.ingotImports(),
//     ingot_ws:    window.ingotApp.wsImports(WMI),
//     ingot_http:  window.ingotApp.httpImports(WMI),
//     ingot_store: window.ingotApp.storeImports(WMI),
//     ingot_open:  window.ingotApp.openImports(WMI),
//   };

(function () {
	"use strict";

	// Per-WMI memory helpers (linear memory can grow, so re-view each access).
	function helpers(WMI) {
		const mem = () => new Uint8Array(WMI.memory.buffer);
		const readStr = (ptr, len) => new TextDecoder().decode(mem().subarray(ptr, ptr + len));
		const writeBytes = (dst, bytes, cap) => {
			const n = Math.min(bytes.length, cap);
			mem().set(bytes.subarray(0, n), dst);
			return n;
		};
		return { mem, readStr, writeBytes };
	}

	// ---- ingot_ws: browser WebSocket ------------------------------------
	function wsImports(WMI) {
		const { mem, readStr, writeBytes } = helpers(WMI);
		const sockets = new Map(); // id → { ws, state, queue, queuedBytes }
		const maximumQueuedMessages = 1024;
		const maximumQueuedBytes = 64 * 1024 * 1024;
		const maximumMessageBytes = 32 * 1024 * 1024;
		let nextSock = 1;
		const imports = {
			ingot_ws_open: (urlPtr, urlLen) => {
				const rawUrl = readStr(urlPtr, urlLen);
				const id = nextSock++;
				const rec = { ws: null, state: 1 /*connecting*/, queue: [], queuedBytes: 0 };
				try {
					const base = window.location && window.location.href ? window.location.href : undefined;
					const url = base ? new URL(rawUrl, base) : new URL(rawUrl);
					if (url.protocol !== "ws:" && url.protocol !== "wss:") throw new Error("invalid websocket scheme");
					const s = new WebSocket(url.href);
					s.binaryType = "arraybuffer";
					s.onopen = () => { rec.state = 2; };
					s.onclose = () => { rec.state = 0; };
					s.onerror = () => { rec.state = 3; };
					s.onmessage = (ev) => {
						const binary = typeof ev.data !== "string";
						const bytes = binary ? new Uint8Array(ev.data) : new TextEncoder().encode(ev.data);
						if (bytes.length > maximumMessageBytes) { s.close(1009); return; }
						while (rec.queue.length > 0 &&
							(rec.queue.length >= maximumQueuedMessages ||
							 rec.queuedBytes + bytes.length > maximumQueuedBytes)) {
							rec.queuedBytes -= rec.queue.shift().bytes.length;
						}
						rec.queue.push({ bytes, binary });
						rec.queuedBytes += bytes.length;
					};
					rec.ws = s;
				} catch (e) { rec.state = 3; }
				sockets.set(id, rec);
				return id;
			},
			ingot_ws_send_text: (id, ptr, n) => {
				const r = sockets.get(id);
				if (!r || r.state !== 2) return 1;
				try { r.ws.send(readStr(ptr, n)); return 0; } catch (e) { return 1; }
			},
			ingot_ws_send_binary: (id, ptr, n) => {
				const r = sockets.get(id);
				if (!r || r.state !== 2) return 1;
				try { r.ws.send(mem().slice(ptr, ptr + n)); return 0; } catch (e) { return 1; }
			},
			ingot_ws_close: (id) => {
				const r = sockets.get(id);
				if (r && r.ws) { try { r.ws.close(); } catch (e) {} }
				sockets.delete(id);
			},
			ingot_ws_state: (id) => {
				const r = sockets.get(id);
				return r ? r.state : 3;
			},
			ingot_ws_recv_len: (id) => {
				const r = sockets.get(id);
				if (!r || r.queue.length === 0) return -1;
				return r.queue[0].bytes.length;
			},
			ingot_ws_recv_binary: (id) => {
				const r = sockets.get(id);
				if (!r || r.queue.length === 0) return 0;
				return r.queue[0].binary ? 1 : 0;
			},
			ingot_ws_recv_copy: (id, dst, cap) => {
				const r = sockets.get(id);
				if (!r || r.queue.length === 0) return -1;
				const msg = r.queue.shift();
				r.queuedBytes -= msg.bytes.length;
				if (cap < msg.bytes.length) return -1;
				return writeBytes(dst, msg.bytes, cap);
			},
		};
		return {
			imports,
			destroy: () => {
				for (const rec of sockets.values()) {
					if (rec.ws) { try { rec.ws.close(); } catch (e) {} }
					rec.queue.length = 0;
				}
				sockets.clear();
			},
		};
	}

	// ---- ingot_http: browser fetch() ------------------------------------
	function httpImports(WMI) {
		if (!window.ingotWeb || typeof window.ingotWeb.httpImports !== "function") {
			throw new Error("ingot_web.js must be loaded before ingot_app.js HTTP imports");
		}
		const canonical = window.ingotWeb.httpImports(WMI);
		const active = new Set();
		const imports = {
			ingot_http_request: (...args) => {
				const id = canonical.ingot_http_request(...args);
				if (id >= 0) active.add(id);
				return id;
			},
			ingot_http_poll: (id) => canonical.ingot_http_poll(id),
			ingot_http_status: (id) => canonical.ingot_http_status(id),
			ingot_http_body_len: (id) => canonical.ingot_http_body_len(id),
			ingot_http_body_copy: (id, destination, capacity) => {
				const count = canonical.ingot_http_body_copy(id, destination, capacity);
				if (count >= 0) active.delete(id);
				return count;
			},
			ingot_http_cancel: (id) => {
				const cancelled = canonical.ingot_http_cancel(id);
				active.delete(id);
				return cancelled;
			},
		};
		return {
			imports,
			destroy: () => {
				for (const id of active) canonical.ingot_http_cancel(id);
				active.clear();
			},
		};
	}

	// ---- ingot_store: localStorage --------------------------------------
	function storeImports(WMI) {
		const { readStr, writeBytes } = helpers(WMI);
		return {
			ingot_store_get: (keyPtr, keyLen, dst, cap) => {
				const key = readStr(keyPtr, keyLen);
				const val = window.localStorage.getItem(key);
				if (val === null) return -1;
				const bytes = new TextEncoder().encode(val);
				if (dst !== 0 && cap > 0) writeBytes(dst, bytes, cap);
				return bytes.length; // full length (caller sizes on first probe)
			},
			ingot_store_set: (keyPtr, keyLen, valPtr, valLen) => {
				const key = readStr(keyPtr, keyLen);
				const val = readStr(valPtr, valLen);
				try { window.localStorage.setItem(key, val); } catch (e) {}
			},
		};
	}

	// ---- ingot_open: window.open() --------------------------------------
	function openImports(WMI) {
		const { readStr } = helpers(WMI);
		return {
			ingot_open_url: (ptr, len) => {
				const url = readStr(ptr, len);
				try { window.open(url, "_blank", "noopener,noreferrer"); } catch (e) {}
			},
		};
	}

	function createSession(WMI) {
		const ws = wsImports(WMI);
		const http = httpImports(WMI);
		let destroyed = false;
		return {
			imports: {
				ingot_ws: ws.imports,
				ingot_http: http.imports,
				ingot_store: storeImports(WMI),
				ingot_open: openImports(WMI),
			},
			destroy: () => {
				if (destroyed) return;
				destroyed = true;
				http.destroy();
				ws.destroy();
			},
		};
	}

	window.ingotApp = {
		createSession: createSession,
		wsImports: (WMI) => wsImports(WMI).imports,
		httpImports: (WMI) => httpImports(WMI).imports,
		storeImports: storeImports,
		openImports: openImports,
	};
})();
