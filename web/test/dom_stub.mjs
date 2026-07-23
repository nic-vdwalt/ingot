// Minimal DOM stub for testing web/ingot_web.js's semantic overlay logic
// under `node --test` — hand-rolled to keep the repo free of npm
// dependencies (no jsdom). Implements only the surface the overlay uses:
// createElement, getElementById, appendChild/remove, style, attributes,
// focus/activeElement, getBoundingClientRect, addEventListener/dispatch.
"use strict";

let idCounter = 0;

export class StubElement {
	constructor(tag) {
		this.tagName = tag.toUpperCase();
		this.style = {};
		this.attributes = new Map();
		this.children = [];
		this.parent = null;
		this.listeners = new Map();
		this.id = "";
		this.value = "";
		this.checked = false;
		this.disabled = false;
		this.textContent = "";
		this.type = "";
		this.name = "";
		this.placeholder = "";
		this.autocomplete = "";
		this.spellcheck = true;
		this.autocapitalize = "";
		this.tabIndex = 0;
		this.noValidate = false;
		this.method = "";
		this.action = "";
		this.selectionStart = null;
		this._uid = ++idCounter;
	}
	setAttribute(k, v) { this.attributes.set(k, String(v)); }
	getAttribute(k) { return this.attributes.has(k) ? this.attributes.get(k) : null; }
	appendChild(child) {
		child.parent = this;
		this.children.push(child);
		stubDocument._all.add(child);
		return child;
	}
	remove() {
		if (this.parent) {
			const i = this.parent.children.indexOf(this);
			if (i >= 0) this.parent.children.splice(i, 1);
			this.parent = null;
		}
		stubDocument._all.delete(this);
		for (const c of [...this.children]) c.remove();
		if (stubDocument.activeElement === this) stubDocument.activeElement = stubDocument.body;
	}
	addEventListener(type, fn) {
		if (!this.listeners.has(type)) this.listeners.set(type, []);
		this.listeners.get(type).push(fn);
	}
	dispatch(type, event = {}) {
		event.preventDefault ||= () => {};
		for (const fn of this.listeners.get(type) || []) fn(event);
	}
	focus() {
		stubDocument.activeElement = this;
		this.dispatch("focus");
	}
	blur() {
		if (stubDocument.activeElement === this) stubDocument.activeElement = stubDocument.body;
		this.dispatch("blur");
	}
	getBoundingClientRect() {
		return { left: 0, top: 0, width: 800, height: 600 };
	}
	querySelectorAll(sel) {
		// Only "input" is used by the overlay's Tab handler.
		const out = [];
		const walk = (el) => {
			for (const c of el.children) {
				if (c.tagName === sel.toUpperCase()) out.push(c);
				walk(c);
			}
		};
		walk(this);
		return out;
	}
	get isConnected() { return stubDocument._all.has(this); }
}

export const stubDocument = {
	_all: new Set(),
	body: null,
	activeElement: null,
	createElement(tag) { return new StubElement(tag); },
	getElementById(id) {
		for (const el of this._all) if (el.id === id) return el;
		return null;
	},
};

// install wires the stub globals (window/document/etc.) and loads
// ingot_web.js via the __ingot_test_hook, returning the hook's exports.
export async function install() {
	stubDocument._all.clear();
	stubDocument.body = new StubElement("body");
	stubDocument._all.add(stubDocument.body);
	stubDocument.activeElement = stubDocument.body;

	// Canvas the overlay positions against.
	const canvas = new StubElement("canvas");
	canvas.id = "ingot-canvas";
	stubDocument.body.appendChild(canvas);

	globalThis.document = stubDocument;
	globalThis.window = globalThis; // ingot_web.js sets window.ingotWeb
	globalThis.performance ||= { now: () => 0 };
	globalThis.navigator ||= {};
	globalThis.location = { href: "http://test.local/" };

	let hooked = null;
	globalThis.__ingot_test_hook = (exports) => { hooked = exports; };
	// Fresh import each call is unnecessary — module state resets via
	// endSemanticFrame; a single import suffices per process.
	await import("../ingot_web.js");
	delete globalThis.__ingot_test_hook;
	if (!hooked) throw new Error("ingot_web.js did not call the test hook");
	return { hook: hooked, canvas };
}
