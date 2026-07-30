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

	const ring = [];
	const cascade = [];
	let headline = null;

	function element(id) {
		return document.getElementById(id);
	}

	function render() {
		const crash = element("crash");
		const msg = element("msg");
		if (msg) {
			msg.hidden = false;
			msg.textContent = "crashed - details below";
		}
		if (!crash) return;
		let text = "reason: " + headline;
		if (cascade.length > 0) {
			text += "\n\nfollow-on errors (usually consequences, not causes):\n" +
				cascade.join("\n");
		}
		text += "\n\nrecent console output:\n" + ring.join("\n");
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
		render();
	}

	function record(line) {
		ring.push(line);
		if (ring.length > RING_MAX) ring.shift();
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

	window.ingotCrash = {
		report: show,
		crashed: () => headline !== null,
	};
	// Back-compat with pages that check the older hook name.
	window.__ingotCrashed = () => headline !== null;
})();
