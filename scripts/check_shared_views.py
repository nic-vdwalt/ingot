#!/usr/bin/env python3
"""check_shared_views.py - real-browser gate for SharedArrayBuffer view rejection.

Threaded web builds import a `shared: true` WebAssembly.Memory, so every view
handed to a Web API is backed by a SharedArrayBuffer. Blink and Gecko both
reject those views in TextDecoder.decode and crypto.getRandomValues, even
though the Encoding spec allows them (AllowSharedBufferSource, whatwg/encoding
PR 182). Without a defensive copy the threaded build dies on its first string
read.

getRandomValues additionally caps a single call at 65536 bytes. Odin never
exceeds it: base/runtime/os_specific_js.odin chunks at MAX_PER_CALL_BYTES
before the import is reached, and the quota throws only above 65536. The check
below pins that boundary rather than an out-of-contract size.

Node accepts shared views and enforces no quota, so `node --test` passes either
way. Only a real browser can catch a regression here, which is what this script
is for.

Loads the staged web/odin.js, web/ingot_web.js and web/ingot_app.js into a
cross-origin-isolated page, installs a shared memory, and asserts every fixed
entry point round-trips.

Exits 0 and prints a SKIP line when Playwright or its browsers are missing, so
the gate stays usable on machines without them.
"""

import argparse
import pathlib
import sys

PAGE = "<!doctype html><meta charset=utf-8><title>shared view check</title>"

# Drives the real runtime helpers over a shared memory. Each entry returns a
# value on success and throws on rejection; the harness reports either.
SCRIPT = r"""() => {
  const out = [];
  const rec = (name, fn) => {
    try { out.push({ name, ok: true, detail: String(fn()) }); }
    catch (e) { out.push({ name, ok: false, detail: e.constructor.name + ": " + e.message }); }
  };

  if (typeof SharedArrayBuffer === "undefined") {
    return [{ name: "SharedArrayBuffer", ok: false, detail: "not exposed; page is not cross-origin isolated" }];
  }

  const wmi = new window.odin.WasmMemoryInterface();
  wmi.setIntSize(4);
  const memory = new WebAssembly.Memory({ initial: 4, maximum: 8, shared: true });
  wmi.setMemory(memory);
  rec("memory is shared", () => {
    if (!(memory.buffer instanceof SharedArrayBuffer)) throw new Error("memory is not shared");
    return "yes";
  });
  rec("wmi.isShared cached", () => {
    if (wmi.isShared !== true) throw new Error("setMemory did not resolve isShared");
    return "true";
  });

  // "Hello, Odin\0"
  new Uint8Array(memory.buffer).set([72, 101, 108, 108, 111, 44, 32, 79, 100, 105, 110, 0], 64);

  rec("odin.js loadString", () => {
    const s = wmi.loadString(64, 11);
    if (s !== "Hello, Odin") throw new Error("wrong value: " + JSON.stringify(s));
    return s;
  });
  rec("odin.js loadCstring", () => {
    const s = wmi.loadCstring(64);
    if (s !== "Hello, Odin") throw new Error("wrong value: " + JSON.stringify(s));
    return s;
  });
  rec("odin.js loadBytesUnshared", () => {
    const b = wmi.loadBytesUnshared(64, 11);
    if (b.buffer instanceof SharedArrayBuffer) throw new Error("returned a shared view");
    return b.byteLength + " bytes, unshared";
  });

  // rand_bytes fills in place, so a copy alone would silently discard the
  // entropy. Assert the bytes actually landed back in shared memory.
  rec("odin.js rand_bytes", () => {
    const imports = window.odin.setupDefaultImports(wmi);
    new Uint8Array(memory.buffer, 256, 64).fill(0);
    imports.odin_env.rand_bytes(256, 64);
    const v = new Uint8Array(memory.buffer, 256, 64);
    let nonzero = 0;
    for (let i = 0; i < v.length; i += 1) if (v[i] !== 0) nonzero += 1;
    if (nonzero === 0) throw new Error("entropy discarded: all 64 bytes still zero");
    return nonzero + "/64 nonzero";
  });

  // The largest call Odin can emit is exactly 65536 bytes: base/runtime/
  // os_specific_js.odin chunks at MAX_PER_CALL_BYTES before reaching JS, and
  // getRandomValues throws QuotaExceededError only *above* 65536. Pin that
  // boundary through the shared staging path.
  rec("odin.js rand_bytes at quota", () => {
    const OFF = 4096, LEN = 65536;
    const imports = window.odin.setupDefaultImports(wmi);
    new Uint8Array(memory.buffer, OFF, LEN).fill(0);
    imports.odin_env.rand_bytes(OFF, LEN);
    const v = new Uint8Array(memory.buffer, OFF, LEN);
    let nonzero = 0;
    for (let i = 0; i < LEN; i += 1) if (v[i] !== 0) nonzero += 1;
    // ~1/256 of random bytes are legitimately zero, so 90% is a safe floor.
    if (nonzero < LEN * 0.9) throw new Error("entropy discarded: " + nonzero + "/" + LEN + " nonzero");
    const spill = new Uint8Array(memory.buffer, OFF + LEN, 8);
    for (let i = 0; i < spill.length; i += 1) if (spill[i] !== 0) throw new Error("wrote past the requested range");
    return nonzero + "/" + LEN + " nonzero";
  });

  // ingot_app.js readStr has no public export, so drive it through the real
  // ingot_open bridge with window.open stubbed. A shared-view rejection
  // surfaces as a throw out of ingot_open_url.
  rec("ingot_app.js readStr", () => {
    if (!window.ingotApp || !window.ingotApp.openImports) return "skipped: ingot_app.js absent";
    const realOpen = window.open;
    let seen = null;
    window.open = (url) => { seen = url; return null; };
    try {
      window.ingotApp.openImports({ memory }).ingot_open_url(64, 11);
    } finally {
      window.open = realOpen;
    }
    if (seen !== "Hello, Odin") throw new Error("wrong value: " + JSON.stringify(seen));
    return seen;
  });

  rec("ingot_web.js loaded", () => {
    if (!window.ingotWeb) throw new Error("ingot_web.js did not initialise");
    return "yes";
  });

  return out;
}"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--web-dir", default=None, help="staged web directory (default: repo web/)")
    args = ap.parse_args()

    root = pathlib.Path(__file__).resolve().parent.parent
    web = pathlib.Path(args.web_dir) if args.web_dir else root / "web"

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("check_shared_views: SKIP (playwright not installed; "
              "pip install playwright && python3 -m playwright install chromium)")
        return 0

    sources = []
    for name in ("odin.js", "ingot_web.js", "ingot_app.js"):
        path = web / name
        if not path.exists():
            print("check_shared_views: SKIP (%s not staged; run build_web.sh first)" % path)
            return 0
        sources.append(path.read_text())

    def headers(route):
        route.fulfill(status=200, body=PAGE, headers={
            "content-type": "text/html; charset=utf-8",
            "cross-origin-opener-policy": "same-origin",
            "cross-origin-embedder-policy": "require-corp",
        })

    failures = []
    ran_any = False

    with sync_playwright() as pw:
        for engine in ("chromium", "firefox"):
            try:
                browser = getattr(pw, engine).launch()
            except Exception as exc:
                print("check_shared_views: %s unavailable (%s)"
                      % (engine, str(exc).splitlines()[0][:100]))
                continue
            ran_any = True
            page = browser.new_context().new_page()
            page.route("**/sharedviews", headers)
            page.goto("https://ingot.invalid/sharedviews")
            for src in sources:
                page.add_script_tag(content=src)
            label = "%s %s" % (engine, browser.version)
            print("== %s ==" % label)
            for row in page.evaluate(SCRIPT):
                status = "ok  " if row["ok"] else "FAIL"
                print("   %-28s %s  %s" % (row["name"], status, row["detail"]))
                if not row["ok"]:
                    failures.append("%s: %s: %s" % (label, row["name"], row["detail"]))
            browser.close()

    if not ran_any:
        print("check_shared_views: SKIP (no playwright browsers installed; "
              "python3 -m playwright install chromium firefox)")
        return 0

    if failures:
        print("\ncheck_shared_views: FAIL")
        for f in failures:
            print("  " + f)
        return 1

    print("\ncheck_shared_views: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
