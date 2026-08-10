#!/usr/bin/env python3
"""check_threaded_demo.py - load a staged threaded demo in a real browser.

The unit gates cannot see this class of failure. A threaded module built with
-target-features:atomics but linked against the SINGLE-threaded box3d object
compiles, stages, gzips and deploys clean, then traps on the first physics step
with "Atomics.wait cannot be called in this context", because the single
threaded finishTask runs inline on the calling thread and the main thread may
not block. Nothing short of running the module catches that, and it reached
production once.

So this serves a staged demo directory over HTTP with COOP/COEP, opens it, and
fails on any uncaught exception or wasm trap. It needs WebGPU, so Chromium is
launched headed with the ANGLE/Metal backend; that is also the configuration a
visitor actually has.

    python3 scripts/check_threaded_demo.py --demo-dir ../openalloy-web/public_html/demos/ingot-box3d-workers

Exits 0 with a SKIP line when Playwright or its browsers are missing.
"""

import argparse
import functools
import http.server
import pathlib
import sys
import threading


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        # Without these SharedArrayBuffer is not exposed, the page takes its
        # single-threaded branch, and the check silently proves nothing.
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *args):
        pass


# box3d_workers.js refuses a step whenever the coordinator is not yet assigned,
# a step is already in flight, or the pool has failed. The app then steps the
# world on the main thread, where box3d's parallel-for cannot block - so this is
# the path that traps, and on a healthy machine the startup window that exercises
# it is only a few frames wide. Holding request_step/request_batch false makes
# that window the whole run, which is the difference between a check that
# reproduces the failure and one that happens not to.
FORCE_MAIN_THREAD = """
  Object.defineProperty(window, 'ingotBox3dWorkers', {
    configurable: true,
    set(v) {
      const orig = v.create;
      v.create = async function(...a) {
        const pool = await orig.apply(this, a);
        pool.imports.request_step = () => false;
        pool.imports.request_batch = () => false;
        return pool;
      };
      Object.defineProperty(window, 'ingotBox3dWorkers',
        {value: v, writable: true, configurable: true});
    }
  });
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--demo-dir", required=True, help="staged demo directory to serve")
    ap.add_argument("--seconds", type=float, default=8.0, help="how long to let it run")
    ap.add_argument("--force-main-thread", action="store_true",
                    help="make the worker pool refuse every step, forcing the "
                         "app's main-thread fallback")
    args = ap.parse_args()

    demo = pathlib.Path(args.demo_dir).resolve()
    if not (demo / "index.html").is_file():
        print("check_threaded_demo: SKIP (%s has no index.html)" % demo)
        return 0

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("check_threaded_demo: SKIP (playwright not installed)")
        return 0

    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(Handler, directory=str(demo)))
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()

    errors = []
    logs = []
    try:
        with sync_playwright() as pw:
            try:
                browser = pw.chromium.launch(headless=False, args=[
                    "--enable-unsafe-webgpu",
                    "--enable-features=Vulkan,WebGPU",
                    "--use-angle=metal",
                ])
            except Exception as exc:
                print("check_threaded_demo: SKIP (chromium unavailable: %s)"
                      % str(exc).splitlines()[0][:100])
                return 0

            page = browser.new_context().new_page()
            if args.force_main_thread:
                page.add_init_script(FORCE_MAIN_THREAD)
            page.on("pageerror", lambda e: errors.append("pageerror: %s" % e))
            page.on("console", lambda m: (
                logs.append("%s: %s" % (m.type, m.text)),
                errors.append("console.error: %s" % m.text)
                if m.type == "error" and "favicon" not in m.text
                and "404" not in m.text else None))
            # A favicon 404 is noise; a missing module is the whole failure. Log
            # the URL so the two are never confused again.
            page.on("requestfailed", lambda r: logs.append(
                "requestfailed: %s %s" % (r.url, r.failure)))
            page.on("response", lambda r: logs.append(
                "http %d %s" % (r.status, r.url)))
            # The physics runs on workers. An uncaught trap there never reaches
            # the page's error handler, so subscribe to each worker directly.
            page.on("worker", lambda w: w.on("close", lambda _w: logs.append(
                "worker closed: %s" % _w.url)))

            page.goto("http://127.0.0.1:%d/index.html" % port)
            page.wait_for_timeout(int(args.seconds * 1000))

            isolated = page.evaluate("() => crossOriginIsolated === true")
            mode = page.evaluate(
                "() => (document.getElementById('mode') || {}).textContent || ''")
            crashed = page.evaluate(
                "() => !!(window.ingotCrash && window.ingotCrash.crashed())")
            crash_text = page.evaluate(
                "() => (document.getElementById('crash') || {}).textContent || ''")
            browser.close()
    finally:
        server.shutdown()

    print("== %s ==" % demo.name)
    print("   crossOriginIsolated  %s" % isolated)
    print("   mode chip            %r" % mode)
    print("   crash recorder       %s" % ("CRASHED" if crashed else "clean"))
    for line in logs:
        print("   log: %s" % line[:160])

    failures = []
    if not isolated:
        failures.append("page is not cross-origin isolated; the threaded module was never loaded")
    if "enabled" not in mode:
        failures.append("worker pool not enabled (mode chip: %r)" % mode)
    if crashed:
        failures.append("crash recorder fired: %s" % crash_text.strip()[:300])
    failures.extend(errors)

    if failures:
        print("\ncheck_threaded_demo: FAIL")
        for f in failures:
            print("  " + f[:400])
        return 1

    print("\ncheck_threaded_demo: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
