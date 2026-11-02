"""Resolve a tool's target path the way the filesystem will, for test-guard.

  pathcheck.py <root> <cwd> <path> [frozen.tsv]
Prints `inside<TAB><rel>` or `outside<TAB><abs>`.
  - A relative path is taken from <cwd> (the hook input's cwd; the root when empty).
  - `..`, symlinks (including a symlinked root, like macOS /tmp) and missing directories are resolved
    with os.path.realpath, which normalises a missing tail lexically, as the editing tools do.
  - When the target exists and is the same file (same device and inode) as a frozen path, <rel> is that
    frozen path. This catches symlinks to frozen files, hard links, and other spellings of the same file
    on a case-insensitive filesystem (macOS default: `TESTS/A.test.ts` is `tests/a.test.ts`).
Exit 0, or 2 on bad usage.
"""
import os
import sys


def case_insensitive(root):
    try:
        return os.path.samefile(root, root.upper()) and os.path.samefile(root, root.lower())
    except OSError:
        return False


def main(argv):
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    root = os.path.realpath(argv[1])
    cwd = argv[2] or root
    path = argv[3]
    frozen = argv[4] if len(argv) > 4 else ""
    full = os.path.realpath(os.path.join(cwd, path))
    inside = full == root or full.startswith(root + os.sep)
    if not inside and case_insensitive(root):
        inside = full.lower() == root.lower() or full.lower().startswith(root.lower() + os.sep)
    if not inside:
        print(f"outside\t{full}")
        return 0
    rel = full[len(root) + 1:] or "."
    if frozen and os.path.isfile(frozen) and os.path.exists(full):
        try:
            st = os.stat(full)
            with open(frozen, encoding="utf-8") as f:
                for line in f:
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) != 4:
                        continue
                    try:
                        fs = os.stat(os.path.join(root, parts[3]))
                    except OSError:
                        continue
                    if (fs.st_dev, fs.st_ino) == (st.st_dev, st.st_ino):
                        rel = parts[3]
                        break
        except OSError:
            pass
    print(f"inside\t{rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
