#!/usr/bin/env python3

import argparse
import collections
import os
import selectors
import signal
import subprocess
import sys
import time
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", required=True)
    parser.add_argument("--timeout", required=True, type=float)
    parser.add_argument("--output-limit", required=True, type=int)
    parser.add_argument("--log-dir", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command or args.timeout <= 0 or args.output_limit <= 0:
        parser.error("command, timeout, and output limit must be positive")
    return args


def terminate_group(process, grace_seconds=2.0):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=grace_seconds)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def write_failure_log(log_dir, package, chunks, limit):
    path = Path(log_dir)
    path.mkdir(parents=True, exist_ok=True)
    log_path = path / f"{package}.log"
    data = b"".join(chunks)
    if len(data) > limit:
        data = data[-limit:]
    log_path.write_bytes(data)
    return log_path


def main():
    args = parse_args()
    process = subprocess.Popen(
        args.command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    interrupted = None

    def handle_signal(signum, _frame):
        nonlocal interrupted
        interrupted = signum

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, handle_signal)

    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    chunks = collections.deque()
    retained = 0
    total = 0
    deadline = time.monotonic() + args.timeout
    failure = None

    try:
        while True:
            if interrupted is not None:
                failure = f"interrupted by signal {interrupted}"
                terminate_group(process)
            elif time.monotonic() >= deadline and process.poll() is None:
                failure = f"timed out after {args.timeout:g}s"
                terminate_group(process)

            events = selector.select(timeout=0.1)
            for key, _ in events:
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
                chunks.append(data)
                retained += len(data)
                total += len(data)
                while retained > args.output_limit and chunks:
                    removed = chunks.popleft()
                    retained -= len(removed)
                if total > args.output_limit and failure is None:
                    failure = f"output exceeded {args.output_limit} bytes"
                    terminate_group(process)

            if process.poll() is not None and not selector.get_map():
                break
    finally:
        terminate_group(process)
        selector.close()

    return_code = process.returncode
    if failure is None and return_code == 0:
        return 0

    log_path = write_failure_log(args.log_dir, args.package, chunks, args.output_limit)
    if failure is None:
        failure = f"exited with status {return_code}"
    print(f"test supervisor: {args.package} {failure}; log: {log_path}", file=sys.stderr)
    if interrupted is not None:
        return 128 + interrupted
    if "timed out" in failure:
        return 124
    if "output exceeded" in failure:
        return 125
    return return_code if return_code and return_code > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
