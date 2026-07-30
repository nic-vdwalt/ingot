"use strict";

// Black-box recorder contract.
//
// The in-page crash panel cannot report an OOM tab kill: the process is
// terminated with no error event and nothing left running to draw with. The
// black box works around that by leaving breadcrumbs in sessionStorage and
// clearing them on pagehide, so a record that SURVIVES to the next load means
// the previous session never shut down.
//
// That inverted signal is easy to get subtly wrong in two directions, and both
// would make the feature worse than useless:
//
//   - a false alarm on clean shutdown would cry wolf on every reload
//   - re-reporting the same death would make a single crash look like a loop
//
// Both are pinned below, along with the bounds and the storage-unavailable
// path (private browsing throws on access, not just on write).
//
// Each "page load" is a fresh eval of ingot_crash.js: it is an IIFE with no
// imports, so evaluating the source again gives genuinely fresh module state,
// which node's module cache would not.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const SOURCE = readFileSync(join(HERE, "..", "ingot_crash.js"), "utf8");

// A minimal sessionStorage. `mode` injects the two real-world failures:
// "throw-access" is private browsing, "throw-write" is quota exhaustion.
function makeStorage(mode = "ok", initial = {}) {
	const data = new Map(Object.entries(initial));
	return {
		data,
		getItem(key) {
			if (mode === "throw-access") throw new Error("storage disabled");
			return data.has(key) ? data.get(key) : null;
		},
		setItem(key, value) {
			if (mode === "throw-access") throw new Error("storage disabled");
			if (mode === "throw-write") throw new Error("quota exceeded");
			data.set(key, String(value));
		},
		removeItem(key) {
			if (mode === "throw-access") throw new Error("storage disabled");
			data.delete(key);
		},
	};
}

function makeElement(id) {
	const listeners = new Map();
	return {
		id,
		hidden: false,
		textContent: "",
		style: {},
		addEventListener(type, fn) {
			if (!listeners.has(type)) listeners.set(type, []);
			listeners.get(type).push(fn);
		},
		click() {
			for (const fn of listeners.get("click") || []) fn({});
		},
	};
}

// load simulates one page load against a given storage, returning the test
// hook plus the DOM elements the panel renders into.
function load(store, { readyState = "complete" } = {}) {
	const crash = makeElement("crash");
	const msg = makeElement("msg");
	const listeners = new Map();

	const win = {
		addEventListener(type, fn) {
			if (!listeners.has(type)) listeners.set(type, []);
			listeners.get(type).push(fn);
		},
	};
	Object.defineProperty(win, "sessionStorage", {
		get() {
			if (store === "unavailable") throw new Error("storage disabled");
			return store;
		},
	});

	let now = 0;
	// setInterval is captured rather than run: the heartbeat is driven
	// explicitly by the tests so they stay deterministic and do not wait on
	// wall-clock time. requestAnimationFrame is real enough to prove the
	// frame counter chains onto it.
	const timers = [];
	let rafCallback = null;
	const sandbox = {
		window: win,
		document: {
			readyState,
			getElementById: (id) => (id === "crash" ? crash : id === "msg" ? msg : null),
		},
		console: { log() {}, warn() {}, error() {} },
		performance: { now: () => (now += 5) },
		navigator: { userAgent: "test-agent" },
		location: { pathname: "/demos/test/" },
		setInterval: (fn, ms) => { timers.push({ fn, ms }); return timers.length; },
	};
	win.requestAnimationFrame = (fn) => { rafCallback = fn; return 1; };

	let hook = null;
	const globals = {
		...sandbox,
		__ingot_crash_test_hook: (exports) => { hook = exports; },
	};
	// The IIFE assigns window.ingotCrash and reads bare globals, so bind both
	// the sandbox names and globalThis-style access in one call frame.
	const names = Object.keys(globals);
	const body = SOURCE + "\n;return { api: window.ingotCrash };";
	// eslint-disable-next-line no-new-func
	const run = new Function(...names, "globalThis", body);
	const fakeGlobal = { __ingot_crash_test_hook: globals.__ingot_crash_test_hook };
	const { api } = run(...names.map((n) => globals[n]), fakeGlobal);

	const fire = (type, event = {}) => {
		for (const fn of listeners.get(type) || []) fn(event);
	};
	if (!hook) throw new Error("ingot_crash.js did not call the test hook");
	const tick = () => {
		for (const timer of timers) timer.fn();
	};
	const frame = () => {
		if (rafCallback) rafCallback(0);
	};
	return { api, hook, crash, msg, fire, listeners, timers, tick, frame, win };
}

test("a session that shuts down cleanly leaves no record", () => {
	const store = makeStorage();
	const first = load(store);
	// Breadcrumbs exist while running, so a kill mid-session has something
	// to recover.
	assert.ok(store.data.has("ingot.blackbox"));
	first.fire("pagehide");
	assert.equal(store.data.has("ingot.blackbox"), false);

	// The next load must not cry wolf.
	const second = load(store);
	assert.equal(second.api.recovered(), false);
	assert.equal(second.crash.style.display, undefined);
});

test("a session killed without pagehide is recovered as a crash", () => {
	const store = makeStorage();
	const first = load(store);
	first.api.mark("entered stress section");
	// A heartbeat is what marks the session as having actually run; without
	// one, a reload during startup would be indistinguishable from a kill.
	first.tick();
	// No pagehide: the tab was terminated by the OS.
	assert.ok(store.data.has("ingot.blackbox"));

	const second = load(store);
	assert.equal(second.api.recovered(), true);
	assert.equal(second.crash.style.display, "block");
	assert.match(second.crash.textContent, /PREVIOUS SESSION DID NOT SHUT DOWN CLEANLY/);
	assert.match(second.crash.textContent, /MARK entered stress section/);
	assert.equal(second.api.crashed(), false);
});

test("a post-mortem never covers a working demo", () => {
	// #msg is a full-screen opaque overlay on the demo pages. Showing it for
	// a PREVIOUS session's report hid a demo that was rendering perfectly -
	// the report must stay confined to the bottom-docked #crash panel.
	const store = makeStorage();
	const killed = load(store);
	killed.tick();

	const next = load(store);
	assert.equal(next.api.recovered(), true);
	assert.equal(next.crash.style.display, "block", "the report still shows");
	assert.equal(next.msg.textContent, "", "the overlay must not be repurposed");
	assert.equal(next.msg.hidden, false, "and must be left for the page to hide");
});

test("a post-mortem can be dismissed but a live crash cannot", () => {
	const store = makeStorage();
	load(store).tick();
	const next = load(store);
	assert.match(next.crash.textContent, /PREVIOUS SESSION/);
	next.crash.click();
	assert.equal(next.crash.style.display, "none", "dismissing hides the panel");

	// A live crash survives dismissal: the app is broken and hiding that
	// would mislead. render() re-appends the live headline unconditionally,
	// so this holds by construction; the early return in the click handler
	// is defence in depth for a future change to render().
	next.api.report("device lost");
	assert.match(next.crash.textContent, /device lost/);
	next.crash.click();
	assert.equal(next.crash.style.display, "block");
	assert.match(next.crash.textContent, /device lost/);
});

test("a reload before the first heartbeat is not reported as a crash", () => {
	// Hitting refresh while the module is still downloading leaves a record
	// with no heartbeat. Reporting that would cry wolf on an ordinary
	// refresh, which is what made the panel appear on a working demo.
	const store = makeStorage();
	load(store); // no tick: never got running
	assert.ok(store.data.has("ingot.blackbox"), "a record still exists");

	const next = load(store);
	assert.equal(next.api.recovered(), false);
	assert.equal(next.crash.style.display, undefined);
	assert.equal(next.msg.textContent, "");
});

test("recovery is one-shot: a second reload does not re-report the death", () => {
	const store = makeStorage();
	load(store).tick(); // killed after running
	const second = load(store);
	assert.equal(second.api.recovered(), true);
	second.fire("pagehide");

	const third = load(store);
	assert.equal(third.api.recovered(), false);
	assert.doesNotMatch(third.crash.textContent, /PREVIOUS SESSION/);
});

test("recovering a record consumes it, even if nothing overwrites it", () => {
	// The reload test above is masked by two other mechanisms that also
	// clear the key: pagehide, and the fresh record the next session writes.
	// Read-and-clear has to hold on its own, or a session that cannot write
	// (quota exhausted) would re-report an older session's death forever.
	const store = makeStorage();
	const killed = load(store);
	killed.tick();
	killed.hook.boxRecord("the original death");
	killed.hook.boxFlush(true);
	const stale = store.data.get("ingot.blackbox");
	assert.match(stale, /the original death/);

	// End to end: a session whose writes all fail must still consume the
	// previous death rather than leave it for the session after it. With
	// writes blocked, read-and-clear is the only thing that can remove it.
	const blocked = makeStorage("throw-write", { "ingot.blackbox": stale });
	const cannotWrite = load(blocked);
	assert.equal(cannotWrite.api.recovered(), true);
	assert.equal(blocked.data.has("ingot.blackbox"), false, "record must be consumed");

	// And the session after that sees a clean slate.
	const after = load(blocked);
	assert.equal(after.api.recovered(), false);
});

test("breadcrumbs stay bounded and long lines are truncated", () => {
	const store = makeStorage();
	const { hook } = load(store);
	const { BOX_CRUMBS_MAX, BOX_CRUMB_CHARS_MAX } = hook.limits;

	for (let i = 0; i < BOX_CRUMBS_MAX * 3; i += 1) hook.boxRecord("crumb " + i);
	hook.boxFlush(true);
	const record = JSON.parse(store.data.get("ingot.blackbox"));
	assert.equal(record.crumbs.length, BOX_CRUMBS_MAX);
	// The ring keeps the NEWEST crumbs: the phase that died is the last one.
	assert.match(record.crumbs[record.crumbs.length - 1], /crumb 59$/);

	hook.boxRecord("x".repeat(BOX_CRUMB_CHARS_MAX * 4));
	hook.boxFlush(true);
	const grown = JSON.parse(store.data.get("ingot.blackbox"));
	const last = grown.crumbs[grown.crumbs.length - 1];
	assert.ok(last.length < BOX_CRUMB_CHARS_MAX + 40, "long crumb must be truncated");
	assert.match(last, /\.\.\.$/);
});

test("writes are coalesced but a forced flush always persists", () => {
	const store = makeStorage();
	const { hook } = load(store);
	hook.boxFlush(true);
	const before = store.data.get("ingot.blackbox");

	// Unforced flushes inside the interval must not rewrite storage: this is
	// what keeps the recorder off the frame loop's critical path.
	hook.boxRecord("quiet one");
	hook.boxRecord("quiet two");
	assert.equal(store.data.get("ingot.blackbox"), before);

	hook.boxFlush(true);
	assert.notEqual(store.data.get("ingot.blackbox"), before);
	assert.match(store.data.get("ingot.blackbox"), /quiet two/);
});

test("unavailable storage disables the box without breaking the panel", () => {
	// Private browsing throws on ACCESS, before any read or write.
	const blocked = load("unavailable");
	assert.equal(blocked.api.recovered(), false);
	blocked.api.report("boom");
	assert.equal(blocked.api.crashed(), true);
	assert.match(blocked.crash.textContent, /reason: boom/);

	// Quota exhaustion throws on write, mid-session.
	const full = load(makeStorage("throw-write"));
	full.hook.boxRecord("after quota");
	full.api.report("still reported");
	assert.equal(full.api.crashed(), true);
	assert.match(full.crash.textContent, /reason: still reported/);
});

test("a truncated record is ignored rather than breaking startup", () => {
	// A tab killed mid-setItem can leave invalid JSON behind.
	const store = makeStorage("ok", { "ingot.blackbox": '{"crumbs":[' });
	const next = load(store);
	assert.equal(next.api.recovered(), false);
	assert.doesNotMatch(next.crash.textContent, /PREVIOUS SESSION/);
});

test("a live crash and a recovered one are reported together", () => {
	const store = makeStorage();
	load(store).tick(); // killed after running
	const second = load(store);
	second.api.report("device lost");
	// Both matter: the post-mortem explains the reload, the live reason
	// explains this session.
	assert.match(second.crash.textContent, /PREVIOUS SESSION DID NOT SHUT DOWN/);
	assert.match(second.crash.textContent, /reason: device lost/);
	assert.match(second.msg.textContent, /^crashed/);
});

// --- heartbeat --------------------------------------------------------------
//
// The first real capture on an iPhone recovered exactly one breadcrumb -
// "session start" - and nothing else, because breadcrumbs are console-driven
// and a healthy engine logs nothing. The heartbeat exists to close that blind
// spot: it records liveness and probe values on a timer, so a killed tab
// leaves a curve behind rather than silence.

test("heartbeat records liveness and is scheduled on load", () => {
	const store = makeStorage();
	const session = load(store);
	assert.equal(session.timers.length, 1, "a heartbeat timer must be scheduled");

	session.tick();
	const record = JSON.parse(store.data.get("ingot.blackbox"));
	const last = record.crumbs[record.crumbs.length - 1];
	assert.match(last, /HEARTBEAT frames=0/);
});

test("heartbeat reports frame progress so a stalled loop is visible", () => {
	const store = makeStorage();
	const session = load(store);
	// The engine drives rAF; the recorder chains a counter onto it. A tab
	// that stops ticking and one that was killed are indistinguishable in
	// storage without this.
	session.win.requestAnimationFrame(() => {});
	session.frame();
	session.frame();
	session.tick();
	const record = JSON.parse(store.data.get("ingot.blackbox"));
	assert.match(record.crumbs[record.crumbs.length - 1], /frames=[1-9]/);
});

test("watched probes appear in every heartbeat", () => {
	const store = makeStorage();
	const session = load(store);
	// This is the OOM smoking gun: ingot_web.js registers the wasm heap size
	// here, so a memory kill leaves a visible growth curve.
	let heap = 19.0;
	assert.equal(session.api.watch("wasmMiB", () => heap.toFixed(1)), true);
	session.tick();
	heap = 210.5;
	session.tick();

	const record = JSON.parse(store.data.get("ingot.blackbox"));
	const text = record.crumbs.join("\n");
	assert.match(text, /wasmMiB=19\.0/);
	assert.match(text, /wasmMiB=210\.5/);
});

test("a throwing probe does not break the heartbeat", () => {
	const store = makeStorage();
	const session = load(store);
	session.api.watch("bad", () => { throw new Error("probe failed"); });
	session.api.watch("good", () => 42);
	session.tick();
	const record = JSON.parse(store.data.get("ingot.blackbox"));
	const last = record.crumbs[record.crumbs.length - 1];
	// A broken diagnostic must not silence the working ones.
	assert.match(last, /good=42/);
	assert.doesNotMatch(last, /bad=/);
});

test("probe registration is bounded and validated", () => {
	const store = makeStorage();
	const session = load(store);
	const max = session.hook.limits.HEARTBEAT_PROBES_MAX;
	assert.equal(session.api.watch("notAFunction", "nope"), false);
	for (let i = 0; i < max; i += 1) {
		assert.equal(session.api.watch("p" + i, () => i), true);
	}
	assert.equal(session.api.watch("overflow", () => 0), false);
	assert.equal(session.hook.state().probes.length, max);
});
