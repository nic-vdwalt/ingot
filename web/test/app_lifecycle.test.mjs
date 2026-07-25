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
	constructor() { this.signal = {}; }
	abort() { aborted += 1; }
};
globalThis.fetch = () => new Promise(() => {});

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
	session.imports.ingot_http.ingot_http_get(8, length);
	session.destroy();
	session.destroy();
	assert.equal(closed, 1);
	assert.equal(aborted, 1);
});
