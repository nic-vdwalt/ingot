// ingot_crash.js - on-device crash reporting for ingot web demos.
//
// Mobile browsers have no reachable console, so a wasm trap in the
// requestAnimationFrame step (odin.js stops scheduling and never reports why)
// or an Odin panic is otherwise indistinguishable from a black canvas. This
// mirrors recent console output into a panel on the page and surfaces
// uncaught errors and rejections there.
//
// Load this BEFORE odin.js/wgpu.js so nothing is missed, and give the page a
// #crash element (any block element) plus a #msg status element.
//
// Root cause vs cascade: a GPU failure usually produces one meaningful line
// (an Odin `gfx:` log) followed by a pile of derived exceptions as the null
// device propagates through the wgpu glue. The FIRST fatal reason is kept as
// the headline and later ones are listed underneath, because the last error
// is almost never the useful one.
//
// BLACK BOX: the in-page panel cannot report the failure that matters most on
// a phone. When iOS Safari kills a tab for memory pressure the process is
// terminated outright - no error event, no rejection, no final frame, and
// nothing left running to draw a panel with. To catch those, breadcrumbs are
// mirrored into sessionStorage as the app runs and the record is cleared on
// pagehide. If the next load still FINDS a record, the previous session never
// reached pagehide - it was killed - and its last breadcrumbs are shown as a
// post-mortem. That turns an invisible tab death into a readable report on
// reload, with no USB cable and no desktop browser.
(function () {
	"use strict";

	// Bounded ring: enough lines to carry the engine's startup logs, small
	// enough to stay readable on a phone screen.
	const RING_MAX = 40;
	// Cascade failures can arrive by the hundreds once a device is null.
	const CASCADE_MAX = 5;
	// Console lines matching this are engine-authored failures worth
	// promoting to the panel on their own, without waiting for a throw.
	const FATAL_PATTERN = /panic|assert|fatal|gfx: /i;

	// --- black box --------------------------------------------------------
	// sessionStorage (not localStorage) so a report belongs to one tab, does
	// not leak between tabs, and does not outlive the browsing session.
	const BOX_KEY = "ingot.blackbox";
	// Breadcrumbs kept across a kill. Deliberately smaller than RING_MAX:
	// this is rewritten to storage repeatedly, and the last handful of lines
	// is what identifies the phase that died.
	const BOX_CRUMBS_MAX = 20;
	// One pathological line (a whole shader source, a base64 blob) must not
	// consume the storage quota by itself.
	const BOX_CRUMB_CHARS_MAX = 200;
	// Writing on every crumb would add a synchronous storage hit to the frame
	// loop and perturb the very frames being measured. Coalesce to at most
	// one write per interval; a kill loses at most this much history, which
	// is the right trade for not distorting the measurement.
	const BOX_FLUSH_INTERVAL_MS = 1000;

	// --- heartbeat ---------------------------------------------------------
	// Breadcrumbs are console-driven, and a healthy engine logs nothing. The
	// first real capture proved the cost of that: a killed tab produced a
	// single "session start" crumb and no other evidence at all.
	//
	// The heartbeat fixes the blind spot by recording liveness on a timer -
	// how long the tab survived, whether the rAF loop was still running, and
	// what probes (notably the wasm heap size) report. A tab killed for
	// memory then leaves a visible growth curve instead of silence.
	const HEARTBEAT_INTERVAL_MS = 1000;
	// Heartbeats share the crumb ring, so this bounds how much history a
	// steady heartbeat can evict. 20 crumbs at 1s is ~20s of history, which
	// covers "open the page, tap the section, watch it die".
	const HEARTBEAT_PROBES_MAX = 8;

	const ring = [];
	const cascade = [];
	let headline = null;

	const box = {
		crumbs: [],
		started: "",
		dirty: false,
		lastFlush: 0,
		// Set once the session is closed or the box is disabled, so a late
		// crumb cannot resurrect a record already cleared.
		closed: false,
	};
	let postMortem = null;

	// storage probes sessionStorage defensively: private browsing and
	// storage-disabled contexts throw on ACCESS, not just on write. The panel
	// must keep working when the black box cannot.
	function storage() {
		try {
			return window.sessionStorage || null;
		} catch (_) {
			return null;
		}
	}

	function element(id) {
		return document.getElementById(id);
	}

	// boxFlush persists the breadcrumbs. `force` bypasses the coalescing
	// interval for the two moments that matter: a fatal reason, and pagehide.
	function boxFlush(force) {
		if (box.closed) return;
		if (!box.dirty && !force) return;
		const now = Date.now();
		if (!force && now - box.lastFlush < BOX_FLUSH_INTERVAL_MS) return;
		const store = storage();
		if (!store) return;
		box.lastFlush = now;
		box.dirty = false;
		try {
			store.setItem(BOX_KEY, JSON.stringify({
				started: box.started,
				path: location.pathname,
				crumbs: box.crumbs,
			}));
		} catch (_) {
			// Quota exceeded or storage revoked mid-session. Disable the box
			// rather than throwing inside the app it exists to diagnose.
			box.closed = true;
		}
	}

	function boxRecord(line) {
		if (box.closed) return;
		const text = line.length > BOX_CRUMB_CHARS_MAX
			? line.slice(0, BOX_CRUMB_CHARS_MAX) + "..."
			: line;
		box.crumbs.push(Math.round(performance.now()) + "ms " + text);
		if (box.crumbs.length > BOX_CRUMBS_MAX) box.crumbs.shift();
		box.dirty = true;
		boxFlush(false);
	}

	// boxClose marks this session as ended normally by removing the record.
	// Its ABSENCE on the next load is exactly the signal that the tab lived;
	// its presence is the signal that it was killed.
	function boxClose() {
		if (box.closed) return;
		box.closed = true;
		const store = storage();
		if (!store) return;
		try {
			store.removeItem(BOX_KEY);
		} catch (_) { /* nothing useful to do at shutdown */ }
	}

	// boxRecover reads and clears any record left by a previous session in
	// this tab. Read-and-clear makes recovery one-shot: reloading twice must
	// not report the same death again.
	function boxRecover() {
		const store = storage();
		if (!store) return null;
		let raw = null;
		try {
			raw = store.getItem(BOX_KEY);
			if (raw) store.removeItem(BOX_KEY);
		} catch (_) {
			return null;
		}
		if (!raw) return null;
		try {
			const parsed = JSON.parse(raw);
			if (!parsed || !Array.isArray(parsed.crumbs)) return null;
			return parsed;
		} catch (_) {
			// A truncated write (killed mid-setItem) leaves invalid JSON.
			// Nothing to report, but do not let it break startup.
			return null;
		}
	}

	function postMortemText() {
		if (!postMortem) return "";
		const crumbs = postMortem.crumbs.length > 0
			? postMortem.crumbs.join("\n")
			: "(no breadcrumbs recorded)";
		// "Most likely", not "was": an ungraceful end is also what a hard
		// browser crash or a force-quit looks like.
		return "PREVIOUS SESSION DIED WITHOUT SHUTTING DOWN\n" +
			"The tab was terminated - most likely killed by the OS under memory\n" +
			"pressure, which produces no JavaScript error. Last breadcrumbs:\n\n" +
			crumbs + "\n\n" + "-".repeat(48) + "\n\n";
	}

	function render() {
		const crash = element("crash");
		const msg = element("msg");
		if (msg) {
			msg.hidden = false;
			msg.textContent = headline !== null
				? "crashed - details below"
				: "previous session crashed - details below";
		}
		if (!crash) return;
		let text = postMortemText();
		if (headline !== null) {
			text += "reason: " + headline;
			if (cascade.length > 0) {
				text += "\n\nfollow-on errors (usually consequences, not causes):\n" +
					cascade.join("\n");
			}
			text += "\n\nrecent console output:\n" + ring.join("\n");
		}
		crash.style.display = "block";
		crash.textContent = text;
	}

	function show(reason) {
		const text = reason === undefined || reason === null || reason === ""
			? "(no reason reported)"
			: String(reason);
		if (headline === null) {
			headline = text;
		} else if (text !== headline && cascade.length < CASCADE_MAX &&
			!cascade.includes(text)) {
			cascade.push(text);
		}
		// Persist immediately: whatever follows a fatal reason may be the
		// thing that kills the tab, and then this is all that survives.
		boxRecord("FATAL " + text);
		boxFlush(true);
		render();
	}

	function record(line) {
		ring.push(line);
		if (ring.length > RING_MAX) ring.shift();
		boxRecord(line);
		// Engine failures are logged before the trap unwinds, so promote them
		// even if the browser swallows the subsequent error event.
		if (FATAL_PATTERN.test(line)) show(line);
	}

	for (const level of ["log", "warn", "error"]) {
		const original = console[level].bind(console);
		console[level] = function (...args) {
			try {
				record(args.map((a) => typeof a === "string" ? a : String(a)).join(" "));
			} catch (_) { /* never let reporting break the app */ }
			original(...args);
		};
	}

	// --- heartbeat ---------------------------------------------------------

	const probes = [];
	let frames = 0;
	let heartbeatTimer = null;

	// countFrame is chained onto requestAnimationFrame so the heartbeat can
	// report whether the render loop is still ticking. A stalled loop and a
	// killed tab look identical in storage otherwise.
	function installFrameCounter() {
		const original = window.requestAnimationFrame;
		if (typeof original !== "function") return;
		window.requestAnimationFrame = function (callback) {
			return original.call(window, (timestamp) => {
				frames += 1;
				return callback(timestamp);
			});
		};
	}

	function heartbeat() {
		const parts = ["frames=" + frames];
		for (const probe of probes) {
			try {
				const value = probe.read();
				if (value !== undefined && value !== null) {
					parts.push(probe.name + "=" + value);
				}
			} catch (_) {
				// A probe that throws is a broken diagnostic, not a reason to
				// stop recording the rest.
			}
		}
		boxRecord("HEARTBEAT " + parts.join(" "));
		// Forced: an unforced flush could coalesce away the very last
		// heartbeat before a kill, which is the one that matters most.
		boxFlush(true);
	}

	function startHeartbeat() {
		if (heartbeatTimer !== null) return;
		if (typeof setInterval !== "function") return;
		installFrameCounter();
		heartbeatTimer = setInterval(heartbeat, HEARTBEAT_INTERVAL_MS);
	}

	window.addEventListener("error", (event) => {
		const where = event.filename
			? " (" + event.filename + ":" + event.lineno + ")"
			: "";
		show(event.message + where);
	});

	window.addEventListener("unhandledrejection", (event) => {
		const reason = event.reason;
		const detail = reason && reason.message ? reason.message : reason;
		show("unhandled rejection: " + detail);
	});

	// pagehide is the last event iOS Safari reliably delivers before a tab is
	// backgrounded or closed; it does not fire unload at all. Reaching here
	// means this session ended on its own terms.
	window.addEventListener("pagehide", boxClose);

	box.started = new Date().toISOString();
	postMortem = boxRecover();
	boxRecord("session start " + navigator.userAgent);
	boxFlush(true);
	startHeartbeat();
	if (postMortem) {
		// Render immediately: the previous session's report must appear even
		// if this one goes on to run perfectly.
		if (document.readyState === "loading") {
			window.addEventListener("DOMContentLoaded", render);
		} else {
			render();
		}
	}

	window.ingotCrash = {
		report: show,
		crashed: () => headline !== null,
		// True when the PREVIOUS session in this tab was killed. Pages use it
		// to keep the report visible instead of hiding the status line after
		// a successful boot.
		recovered: () => postMortem !== null,
		// Breadcrumb from application code, for phases the console does not
		// cover ("entered stress section"), so a kill can be attributed.
		mark: (label) => {
			boxRecord("MARK " + label);
			boxFlush(true);
		},
		// Register a named value sampled by every heartbeat. The wasm heap
		// size (ingot_web.js) is the one that matters: a tab killed under
		// memory pressure leaves a visible growth curve behind, which is
		// otherwise unobservable from inside the page.
		watch: (name, read) => {
			if (typeof read !== "function") return false;
			if (probes.length >= HEARTBEAT_PROBES_MAX) return false;
			probes.push({name, read});
			return true;
		},
	};
	// Back-compat with pages that check the older hook name.
	window.__ingotCrashed = () => headline !== null;

	// Test-only hook, mirroring ingot_web.js's. Guarded so browsers never see
	// it and no behavior changes.
	if (typeof globalThis.__ingot_crash_test_hook === "function") {
		globalThis.__ingot_crash_test_hook({
			boxRecord,
			boxFlush,
			boxClose,
			boxRecover,
			render,
			heartbeat,
			state: () => ({box, postMortem, headline, probes, frames}),
			limits: {BOX_KEY, BOX_CRUMBS_MAX, BOX_CRUMB_CHARS_MAX, HEARTBEAT_PROBES_MAX},
		});
	}
})();
