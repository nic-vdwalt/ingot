#!/usr/bin/env python3

import argparse
import collections
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

READ_CHUNK_BYTES = 65536
PROCESS_GRACE_SECONDS = 2.0
QUEUE_WAIT_SECONDS = 0.1


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", required=True)
    parser.add_argument("--timeout", required=True, type=float)
    parser.add_argument("--output-limit", required=True, type=int)
    parser.add_argument("--log-dir", required=True)
    parser.add_argument("--retain-success-log", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command or args.timeout <= 0 or args.output_limit <= 0:
        parser.error("command, timeout, and output limit must be positive")
    return args


def terminate_group(process, grace_seconds=PROCESS_GRACE_SECONDS):
    if process.poll() is not None:
        return True
    try:
        if os.name == "nt":
            process.send_signal(signal.CTRL_BREAK_EVENT)
        else:
            os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=grace_seconds)
    except (OSError, subprocess.TimeoutExpired):
        if os.name == "nt":
            result = subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            if result.returncode != 0 and process.poll() is None:
                return False
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            process.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            return False
    return process.poll() is not None


def write_failure_log(log_dir, package, chunks, limit):
    path = Path(log_dir)
    path.mkdir(parents=True, exist_ok=True)
    log_path = path / f"{package}.log"
    data = b"".join(chunks)
    if len(data) > limit:
        data = data[-limit:]
    log_path.write_bytes(data)
    return log_path


def read_output(stream, events):
    while True:
        data = stream.read(READ_CHUNK_BYTES)
        events.put(data)
        if not data:
            return


def retain_chunk(chunks, retained, data, limit):
    chunks.append(data)
    retained += len(data)
    while retained > limit and chunks:
        retained -= len(chunks.popleft())
    return retained


def supervise(args):
    creationflags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
    process = subprocess.Popen(
        args.command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=os.name != "nt",
        creationflags=creationflags,
    )
    events = queue.Queue()
    reader = threading.Thread(target=read_output, args=(process.stdout, events), daemon=True)
    reader.start()
    chunks = collections.deque()
    retained = 0
    total = 0
    deadline = time.monotonic() + args.timeout
    failure = None
    output_closed = False
    interrupted = None

    def handle_signal(signum, _frame):
        nonlocal interrupted
        interrupted = signum

    handled_signals = [signal.SIGINT, signal.SIGTERM]
    if hasattr(signal, "SIGHUP"):
        handled_signals.append(signal.SIGHUP)
    previous_handlers = {signum: signal.signal(signum, handle_signal) for signum in handled_signals}
    try:
        while not output_closed or process.poll() is None:
            if interrupted is not None and failure is None:
                failure = f"interrupted by signal {interrupted}"
            if time.monotonic() >= deadline and process.poll() is None and failure is None:
                failure = f"timed out after {args.timeout:g}s"
            if failure is not None and process.poll() is None and not terminate_group(process):
                failure += "; process tree did not terminate"
            try:
                data = events.get(timeout=QUEUE_WAIT_SECONDS)
            except queue.Empty:
                continue
            if not data:
                output_closed = True
                continue
            remaining = max(args.output_limit - total, 0)
            if remaining > 0:
                sys.stdout.buffer.write(data[:remaining])
                sys.stdout.buffer.flush()
            retained = retain_chunk(chunks, retained, data, args.output_limit)
            total += len(data)
            if total > args.output_limit and failure is None:
                failure = f"output exceeded {args.output_limit} bytes"
        reader.join(timeout=PROCESS_GRACE_SECONDS)
    finally:
        terminate_group(process)
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)

    return process, chunks, failure, interrupted


def main():
    args = parse_args()
    process, chunks, failure, interrupted = supervise(args)
    return_code = process.returncode
    if failure is None and return_code == 0:
        if args.retain_success_log:
            write_failure_log(args.log_dir, args.package, chunks, args.output_limit)
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
