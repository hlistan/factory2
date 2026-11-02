"""Run a command with a time limit: timeout.py <seconds> <command> [args...].

Exit status: the command's own, or 124 when the limit was reached (the same convention as GNU timeout,
which macOS doesn't ship). On the limit the command's whole process group gets SIGTERM, then SIGKILL
after 5 s, so test runners and the dev servers they start don't outlive the hook. Output passes through.
"""
import os
import signal
import subprocess
import sys


def main():
    if len(sys.argv) < 3:
        print("usage: timeout.py <seconds> <command> [args...]", file=sys.stderr)
        return 2
    try:
        limit = float(sys.argv[1])
    except ValueError:
        print("timeout.py: seconds must be a number", file=sys.stderr)
        return 2
    proc = subprocess.Popen(sys.argv[2:], start_new_session=True)

    def stop_group():
        for sig, grace in ((signal.SIGTERM, 5), (signal.SIGKILL, 5)):
            try:
                os.killpg(proc.pid, sig)
            except ProcessLookupError:
                return
            try:
                proc.wait(timeout=grace)
                return
            except subprocess.TimeoutExpired:
                continue

    def on_signal(signum, _frame):
        # the child runs in its own session, so a signal to our group (an outer timeout.py, or Claude
        # Code cancelling the hook) wouldn't reach it: pass it on before exiting
        stop_group()
        sys.exit(128 + signum)

    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(s, on_signal)
    try:
        return proc.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        stop_group()
        return 124


if __name__ == "__main__":
    sys.exit(main())
