// ingot_app.js — reusable app-I/O bridges for ingot web apps.
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
		const sockets = new Map(); // id → { ws, state, queue: [{bytes, binary}] }
		let nextSock = 1;
		return {
			ingot_ws_open: (urlPtr, urlLen) => {
				const url = readStr(urlPtr, urlLen);
				const id = nextSock++;
				const rec = { ws: null, state: 1 /*connecting*/, queue: [] };
				try {
					const s = new WebSocket(url);
					s.binaryType = "arraybuffer";
					s.onopen = () => { rec.state = 2; };
					s.onclose = () => { rec.state = 0; };
					s.onerror = () => { rec.state = 3; };
					s.onmessage = (ev) => {
						if (typeof ev.data === "string") {
							rec.queue.push({ bytes: new TextEncoder().encode(ev.data), binary: false });
						} else {
							rec.queue.push({ bytes: new Uint8Array(ev.data), binary: true });
						}
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
				return writeBytes(dst, msg.bytes, cap);
			},
		};
	}

	// ---- ingot_http: browser fetch() ------------------------------------
	function httpImports(WMI) {
		const { readStr, writeBytes } = helpers(WMI);
		const reqs = new Map(); // id → { status: 0|1|2, body: Uint8Array|null, timer }
		let nextReq = 1;
		const HTTP_TIMEOUT_MS = 30000; // match native core:net receive timeout
		return {
			ingot_http_get: (urlPtr, urlLen) => {
				const url = readStr(urlPtr, urlLen);
				const id = nextReq++;
				const ctl = new AbortController();
				const rec = { status: 0, body: null, timer: 0 };
				rec.timer = setTimeout(() => {
					if (rec.status === 0) { rec.status = 2; ctl.abort(); }
				}, HTTP_TIMEOUT_MS);
				reqs.set(id, rec);
				fetch(url, { signal: ctl.signal })
					.then((resp) => resp.ok ? resp.arrayBuffer().then((b) => {
						if (rec.status === 2) return; // already timed out
						rec.body = new Uint8Array(b); rec.status = 1;
					}) : (rec.status = 2))
					.catch(() => { rec.status = 2; })
					.finally(() => { clearTimeout(rec.timer); });
				return id;
			},
			ingot_http_poll: (id) => {
				const r = reqs.get(id);
				return r ? r.status : 2;
			},
			ingot_http_body_len: (id) => {
				const r = reqs.get(id);
				return (r && r.body) ? r.body.length : 0;
			},
			ingot_http_body_copy: (id, dst, cap) => {
				const r = reqs.get(id);
				let n = 0;
				if (r && r.body && dst !== 0) n = writeBytes(dst, r.body, cap);
				if (r && r.timer) clearTimeout(r.timer);
				reqs.delete(id); // free the slot
				return n;
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

	window.ingotApp = {
		wsImports: wsImports,
		httpImports: httpImports,
		storeImports: storeImports,
		openImports: openImports,
	};
})();
