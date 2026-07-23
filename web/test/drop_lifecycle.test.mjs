"use strict";

import test from "node:test";
import assert from "node:assert/strict";
import { install } from "./dom_stub.mjs";

const installed = install();
const fileEvent = (files = []) => ({
	dataTransfer: { types: ["Files"], files },
	preventDefault() {},
});
const fakeFile = (name, bytes = [1, 2, 3]) => ({
	name,
	size: bytes.length,
	arrayBuffer: async () => Uint8Array.from(bytes).buffer,
});

function memoryInterface(events) {
	return { exports: {
		ingot_web_file_drag_over: (over) => events.push(["hover", over]),
		ingot_web_drop_notify: () => events.push(["drop"]),
	} };
}

test("file hover ignores nested leave and clears on final leave", async () => {
	const { hook, canvas } = await installed;
	const events = [];
	const cleanup = hook.attachDrop(memoryInterface(events));
	await canvas.dispatch("dragenter", fileEvent());
	await canvas.dispatch("dragenter", fileEvent());
	await canvas.dispatch("dragleave", fileEvent());
	assert.deepEqual(events, [["hover", true]]);
	await canvas.dispatch("dragleave", fileEvent());
	assert.deepEqual(events, [["hover", true], ["hover", false]]);
	cleanup();
});

test("non-file drags are ignored", async () => {
	const { hook, canvas } = await installed;
	const events = [];
	const cleanup = hook.attachDrop(memoryInterface(events));
	await canvas.dispatch("dragenter", { dataTransfer: { types: ["text/plain"] } });
	await canvas.dispatch("dragover", { dataTransfer: { types: ["text/plain"] } });
	assert.deepEqual(events, []);
	cleanup();
});

test("drop clears hover before notifying completion", async () => {
	const { hook, canvas } = await installed;
	const events = [];
	const cleanup = hook.attachDrop(memoryInterface(events));
	await canvas.dispatch("dragenter", fileEvent());
	await canvas.dispatch("drop", fileEvent([fakeFile("one.txt")]));
	assert.deepEqual(events, [["hover", true], ["hover", false], ["drop"]]);
	assert.equal(globalThis.ingotWeb.ingotImports().ingot_drop_count(), 1);
	globalThis.ingotWeb.ingotImports().ingot_drop_clear();
	cleanup();
});

test("replacement cancels an in-flight older drop", async () => {
	const { hook, canvas } = await installed;
	const oldEvents = [];
	const newEvents = [];
	let resolve;
	const pending = new Promise((done) => { resolve = done; });
	const oldFile = { name: "old.txt", size: 1, arrayBuffer: () => pending };
	hook.attachDrop(memoryInterface(oldEvents));
	const dispatch = canvas.dispatch("drop", fileEvent([oldFile]));
	const cleanup = hook.attachDrop(memoryInterface(newEvents));
	resolve(Uint8Array.of(1).buffer);
	await dispatch;
	assert.deepEqual(oldEvents, [["hover", false]]);
	assert.deepEqual(newEvents, []);
	assert.equal(globalThis.ingotWeb.ingotImports().ingot_drop_count(), 0);
	cleanup();
});

test("blur clears hover and cleanup removes listeners", async () => {
	const { hook, canvas } = await installed;
	const events = [];
	const cleanup = hook.attachDrop(memoryInterface(events));
	await canvas.dispatch("dragenter", fileEvent());
	for (const listener of globalThis.listeners.get("blur") || []) listener();
	assert.deepEqual(events, [["hover", true], ["hover", false]]);
	cleanup();
	assert.equal(canvas.listeners.has("dragenter"), false);
	assert.equal(canvas.listeners.has("drop"), false);
});
