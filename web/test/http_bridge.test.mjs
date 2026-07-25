"use strict";

import test from "node:test";
import assert from "node:assert/strict";

globalThis.window = globalThis;
await import("../ingot_web.js");
await import("../ingot_app.js");

const encoder = new TextEncoder();
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

function fixture() {
	const memory = new WebAssembly.Memory({ initial: 1, maximum: 2 });
	const session = globalThis.ingotApp.createSession({ memory });
	const http = session.imports.ingot_http;
	const write = (pointer, value) => {
		const bytes = typeof value === "string" ? encoder.encode(value) : value;
		new Uint8Array(memory.buffer).set(bytes, pointer);
		return bytes.length;
	};
	const request = ({
		method = 0,
		url = "https://test.local/resource",
		headers = "",
		body = new Uint8Array(),
		maximumBody = 1024,
	} = {}) => {
		const urlLength = write(8, url);
		const headersLength = write(256, headers);
		const bodyLength = write(512, body);
		return http.ingot_http_request(
			method, 8, urlLength, 256, headersLength,
			512, bodyLength, maximumBody,
		);
	};
	return { memory, http, request, session };
}

function response(status, values) {
	const bytes = Uint8Array.from(values);
	return {
		status,
		arrayBuffer: () => Promise.resolve(
			bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
		),
	};
}

test("forwards the current request ABI and preserves HTTP responses", async () => {
	const { memory, http, request } = fixture();
	let call = null;
	globalThis.fetch = (url, options) => {
		call = { url, options };
		return Promise.resolve(response(403, [4, 5, 6]));
	};

	const id = request({
		method: 1,
		headers: '{"X-Test":"yes"}',
		body: Uint8Array.of(1, 2, 3),
	});
	await settle();

	assert.equal(call.url, "https://test.local/resource");
	assert.equal(call.options.method, "POST");
	assert.deepEqual(call.options.headers, { "X-Test": "yes" });
	assert.deepEqual(Array.from(call.options.body), [1, 2, 3]);
	assert.equal(call.options.credentials, "same-origin");
	assert.equal(http.ingot_http_poll(id), 1);
	assert.equal(http.ingot_http_status(id), 403);
	assert.equal(http.ingot_http_body_len(id), 3);
	assert.equal(http.ingot_http_body_copy(id, 1024, 3), 3);
	assert.deepEqual(Array.from(new Uint8Array(memory.buffer, 1024, 3)), [4, 5, 6]);
	assert.equal(http.ingot_http_body_copy(id, 1024, 3), -1);
});

test("maps every method and omits a GET body", async () => {
	const { http, request } = fixture();
	const calls = [];
	globalThis.fetch = (_url, options) => {
		calls.push(options);
		return Promise.resolve(response(204, []));
	};

	for (let method = 0; method < 5; method += 1) {
		const id = request({ method, body: Uint8Array.of(9) });
		await settle();
		assert.equal(http.ingot_http_body_copy(id, 0, 0), 0);
	}

	assert.deepEqual(calls.map((call) => call.method),
		["GET", "POST", "PUT", "PATCH", "DELETE"]);
	assert.equal(calls[0].body, undefined);
	for (const call of calls.slice(1)) assert.deepEqual(Array.from(call.body), [9]);
});

test("reports malformed headers and oversized responses as bridge errors", async () => {
	const { http, request } = fixture();
	let fetches = 0;
	globalThis.fetch = () => {
		fetches += 1;
		return Promise.resolve(response(200, [1, 2, 3]));
	};

	const malformed = request({ headers: "{" });
	assert.equal(fetches, 0);
	assert.equal(http.ingot_http_poll(malformed), 2);
	assert.equal(http.ingot_http_body_copy(malformed, 0, 0), 0);

	const oversized = request({ maximumBody: 2 });
	await settle();
	assert.equal(http.ingot_http_poll(oversized), 2);
	assert.equal(http.ingot_http_status(oversized), 0);
	assert.equal(http.ingot_http_body_len(oversized), 0);
	assert.equal(http.ingot_http_body_copy(oversized, 0, 0), 0);
});

test("cancel and destroy abort only live owned requests", () => {
	const { http, request, session } = fixture();
	let aborted = 0;
	globalThis.fetch = (_url, options) => new Promise((_resolve, reject) => {
		options.signal.addEventListener("abort", () => {
			aborted += 1;
			reject(new Error("aborted"));
		});
	});

	const cancelled = request();
	request();
	assert.equal(http.ingot_http_cancel(cancelled), 1);
	assert.equal(http.ingot_http_cancel(cancelled), 0);
	session.destroy();
	session.destroy();
	assert.equal(aborted, 2);
});
