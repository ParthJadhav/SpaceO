#!/usr/bin/env python3
"""Bound live XCTest hangs from outside the process that can block in WindowServer IPC.

On a deadline/interrupt, suspend the owned process group and retain it for inspection.
Killing a display owner can itself detach displays, so automatic kill/retry is unsafe.
"""
import argparse
import os
import selectors
import signal
import stat
import subprocess
import sys
import time


def supervise(command: list[str], log_path: str, case_timeout: float = 180,
              run_timeout: float = 2400) -> int:
    os.umask(0o077)
    fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        os.close(fd)
        raise ValueError("live log must be an owned regular file with one link")
    os.fchmod(fd, 0o600)
    os.ftruncate(fd, 0)
    with os.fdopen(fd, "wb", buffering=0) as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        interrupted = False

        def interrupt(_signal, _frame):
            nonlocal interrupted
            interrupted = True

        old_handlers = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGINT, signal.SIGTERM)}
        started = time.monotonic()
        case_started = None
        pending = b""
        total = 0

        def suspend():
            try:
                os.killpg(process.pid, signal.SIGSTOP)
            except ProcessLookupError:
                pass

        try:
            while True:
                now = time.monotonic()
                if (interrupted or now - started > run_timeout
                        or (case_started is not None and now - case_started > case_timeout)
                        or total > 32 * 1024 * 1024):
                    suspend()
                    message = (f"\nLIVE SAFETY STOP: process group {process.pid} suspended after "
                               "a deadline, interrupt, or log limit. No automatic kill or retry. "
                               "Inspect docs/DISPLAY_SAFETY.md; retain this log.\n").encode()
                    log.write(message)
                    sys.stderr.buffer.write(message)
                    return 124
                for key, _ in selector.select(timeout=0.1):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    total += len(chunk)
                    log.write(chunk)
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                    pending += chunk
                    lines = pending.split(b"\n")
                    pending = lines.pop()[-16384:]
                    for line in lines:
                        if b"Test Case " in line:
                            if b" started." in line:
                                case_started = time.monotonic()
                            elif any(word in line for word in (b" passed (", b" failed (", b" skipped (")):
                                case_started = None
                if process.poll() is not None and not selector.get_map():
                    return process.returncode
        except BaseException:
            # Losing stdout/log storage must not silently leave an unsupervised live worker.
            suspend()
            message = f"LIVE SAFETY STOP: process group {process.pid} suspended after supervisor failure.\n"
            try:
                log.write(message.encode())
                sys.stderr.write(message)
            except OSError:
                pass
            raise
        finally:
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
            selector.close()
            process.stdout.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required")
    return supervise(command, args.log)


if __name__ == "__main__":
    sys.exit(main())
