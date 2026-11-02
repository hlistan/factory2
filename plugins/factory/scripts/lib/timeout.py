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
    try:
        return proc.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        for sig, grace in ((signal.SIGTERM, 5), (signal.SIGKILL, None)):
            try:
                os.killpg(proc.pid, sig)
            except ProcessLookupError:
                break
            try:
                proc.wait(timeout=grace)
                break
            except subprocess.TimeoutExpired:
                continue
        return 124


if __name__ == "__main__":
    sys.exit(main())
