"""Fold a run's calibration lines into each agent's MEMORY.md: fold.py <history.json> <project root> <max lines>

Each line goes to .claude/agent-memory/factory-<agent>/MEMORY.md as `- <line>` unless MEMORY.md or
archive.md (same directory) already has it, so folding is idempotent even after archiving. When MEMORY.md
passes <max> lines, the oldest lessons move to archive.md (not injected, readable on demand).
Lines are kept verbatim (backslashes included); newlines inside a line become spaces.
Prints one notice per archived agent to stderr. Exit 0, 2 on bad input.
"""
import json
import os
import re
import sys

HEADER = "# factory-{a} lessons\n\nReference material, not rules: it never overrides the task, contract.json or your instructions.\n\n"


def read_lines(path):
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8") as f:
        return f.read().split("\n")


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    hist, root, mx = argv[1], argv[2], int(argv[3])
    with open(hist, encoding="utf-8") as f:
        cal = json.load(f).get("calibration") or []
    for item in cal:
        agent = str(item.get("agent") or "")
        line = re.sub(r"\s*\n\s*", " ", str(item.get("line") or "")).strip()
        if not re.fullmatch(r"[a-z][a-z0-9-]*", agent) or not line:
            continue
        d = os.path.join(root, ".claude", "agent-memory", f"factory-{agent}")
        os.makedirs(d, exist_ok=True)
        m, a = os.path.join(d, "MEMORY.md"), os.path.join(d, "archive.md")
        if not os.path.isfile(m):
            with open(m, "w", encoding="utf-8") as f:
                f.write(HEADER.format(a=agent))
        entry = f"- {line}"
        if entry in read_lines(m) or entry in read_lines(a):
            continue
        lines = read_lines(m)
        if lines and lines[-1] == "":
            lines.pop()
        lines.append(entry)
        if len(lines) > mx:
            head = [x for x in lines if not x.startswith("- ")]
            items = [x for x in lines if x.startswith("- ")]
            keep = max(mx - len(head), 1)
            old, items = items[:-keep], items[-keep:]
            with open(a, "a", encoding="utf-8") as f:
                f.write("".join(x + "\n" for x in old))
            lines = head + items
            print(f"factory: factory-{agent}/MEMORY.md reached {mx} lines; the oldest lessons moved to archive.md"
                  " (consolidate with /factory2:stats)", file=sys.stderr)
        tmp = m + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        os.replace(tmp, m)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
