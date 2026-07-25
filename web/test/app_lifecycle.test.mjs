import test from "node:test";
import assert from "node:assert/strict";

const memory = new WebAssembly.Memory({ initial: 1 });
const WMI = { memory };
globalThis.window = globalThis;
globalThis.localStorage = { getItem: () => null, setItem() {} };
globalThis.open = () => {};

let closed = 0;
globalThis.WebSocket = class {
	constructor() { this.binaryType = ""; }
	close() { closed += 1; }
	send() {}
};
let aborted = 0;
globalThis.AbortController = class {
	constructor() {
		this.listeners = [];
		this.signal = {
			addEventListener: (_type, listener) => this.listeners.push(listener),
		};
	}
	abort() {
		aborted += 1;
		for (const listener of this.listeners) listener();
	}
};
globalThis.fetch = (_url, options) => new Promise((_resolve, reject) => {
	options.signal.addEventListener("abort", () => reject(new Error("aborted")));
});

await import("../ingot_web.js");
await import("../ingot_app.js");

function writeText(text) {
	const bytes = new TextEncoder().encode(text);
	new Uint8Array(memory.buffer).set(bytes, 8);
	return bytes.length;
}

test("app session closes sockets and aborts fetches once", () => {
	const session = globalThis.ingotApp.createSession(WMI);
	let length = writeText("ws://test");
	session.imports.ingot_ws.ingot_ws_open(8, length);
	length = writeText("http://test");
	session.imports.ingot_http.ingot_http_request(
		0, 8, length, 0, 0, 0, 0, 1024,
	);
	session.destroy();
	session.destroy();
	assert.equal(closed, 1);
	assert.equal(aborted, 1);
});
