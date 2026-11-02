#!/usr/bin/env python3
"""Freezes the tests and the files that define the checks, and verifies them later.

  freeze.py lists  --root R --config C
      Prints `<list>\\t<kind>\\t<path>` for every file that a freeze would cover.
  freeze.py freeze --root R --config C --run D [--plan P]
      Writes D/frozen.tsv (`list kind hash path`), D/deps.json (dependency maps of npm manifests) and
      D/checks.snapshot.json (the `checks` section of the config at this moment). When a freeze already
      exists, the check-defining list must still verify first (a re-freeze may bless reviewed test
      changes, never a changed check); exit 1 and the problems otherwise.
  freeze.py verify --root R --run D [--config C] [--plan P]
      Prints `<path>: <problem>` for every frozen file that changed, and every new check-defining file.
      Exit 0 clean, 1 problems, 2 usage or no freeze.

Lists:
  tests   test files (checks.test_pattern, or common layouts) and test support (checks.test_support globs,
          or defaults: playwright configs, fixtures, helpers, setup files). A changed frozen test is a
          problem unless the plan's `## Exceptions` section names its path. New test files are allowed.
  checks  check-defining files (checks.check_defining globs, or defaults per ecosystem) plus
          .factory/config.yaml, always. A file the plan's `## Exceptions` section names may change (never
          .factory/config.yaml). Kinds:
            npm   package.json: hashed without its dependency fields; dependency changes are allowed only
                  for names the plan's `## Exceptions` section names
            deps  lockfiles and dependency manifests (go.mod, ...): may change only when the plan's
                  `## Exceptions` section names at least one dependency
            file  any other file: any change is a problem
          A new file that matches the list after the freeze is a problem too.
Globs: an entry without `/` matches that name at any depth; with `/`, a path from the root. `*` stays in
one directory, `**` crosses directories. Files are what `git ls-files --cached --others
--exclude-standard` lists (so ignored files, like node_modules, never count).
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

DEFAULT_TEST_PATTERN = (
    r"(^|/)([Tt]ests?|__tests__|[Ss]pecs?|testing|e2e)/|(^|/)test_[^/]*\.py$|_test\.[A-Za-z0-9]+$"
    r"|\.(test|spec)\.[A-Za-z0-9]+$|(Tests?|IT)\.(java|kt|kts|scala|cs|swift|groovy)$|_spec\.rb$"
    r"|Test\.php$|_test\.exs$|(^|/)[A-Za-z0-9]+Tests?/"
)
DEFAULT_TEST_SUPPORT = [
    "playwright.config.*", "playwright.*.config.*", "**/fixtures/**", "**/__fixtures__/**", "**/testdata/**",
    "**/test-utils/**", "**/testutils/**", "**/test-helpers/**", "conftest.py", "jest.setup.*",
    "vitest.setup.*", "setupTests.*", "**/__mocks__/**",
]
DEFAULT_CHECK_DEFINING = [
    "package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock",
    "bun.lockb", "vitest.config.*", "vitest.workspace.*", "vite.config.*", "jest.config.*", "tsconfig*.json",
    "eslint.config.*", ".eslintrc*", ".eslintignore", ".prettierrc*", "prettier.config.*", "biome.json",
    "biome.jsonc", "Makefile", "justfile", "go.mod", "go.sum", ".golangci.yml", ".golangci.yaml",
    "Package.swift", "Package.resolved", ".swiftlint.yml", "project.yml", "pyproject.toml", "setup.cfg",
    "pytest.ini", "tox.ini", "ruff.toml", ".ruff.toml", "mypy.ini", "uv.lock", "poetry.lock", "Cargo.toml",
    "Cargo.lock", "Gemfile", "Gemfile.lock", ".rubocop.yml", ".github/workflows/*",
]
DEPS_KINDS = {
    "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb",
    "go.mod", "go.sum", "Package.resolved", "uv.lock", "poetry.lock", "Cargo.lock", "Gemfile.lock",
    "composer.lock", "Pipfile.lock",
}
NPM_DEP_FIELDS = ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies")
CONFIG_PATH = ".factory/config.yaml"
# factory's own files: the PRD, plan and contract (docs/specs/, which the test pattern's `specs/` would
# otherwise match), run state, and agent memory. They change during a run by design.
OWN_PREFIXES = ("docs/specs/", ".factory/", ".claude/")


def glob_re(g):
    g = g.strip()
    if g.startswith("./"):
        g = g[2:]
    if "/" not in g:
        g = "**/" + g
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif g.startswith("**", i):
            out += ".*"
            i += 2
        elif g[i] == "*":
            out += "[^/]*"
            i += 1
        elif g[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(g[i])
            i += 1
    return re.compile("^" + out + "$")


def git(root, *args):
    return subprocess.run(["git", "-C", root, *args], capture_output=True, check=True).stdout


def all_files(root):
    raw = git(root, "-c", "core.quotePath=false", "ls-files", "-z", "--cached", "--others", "--exclude-standard")
    return sorted({p for p in raw.decode("utf-8", "replace").split("\0") if p and os.path.isfile(os.path.join(root, p))})


def load_config(path):
    if not path:
        return {}
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def lists_for(root, cfg):
    checks = (cfg or {}).get("checks") or {}
    test_pat = re.compile(checks.get("test_pattern") or DEFAULT_TEST_PATTERN)
    support = [glob_re(g) for g in (checks.get("test_support") or DEFAULT_TEST_SUPPORT)]
    defining = [glob_re(g) for g in (checks.get("check_defining") or DEFAULT_CHECK_DEFINING)]
    out = []
    for p in all_files(root):
        if p != CONFIG_PATH and p.startswith(OWN_PREFIXES):
            continue
        if p == CONFIG_PATH or any(r.match(p) for r in defining):
            out.append(("checks", kind_of(p), p))
        elif test_pat.search(p) or any(r.match(p) for r in support):
            out.append(("tests", "file", p))
    if os.path.isfile(os.path.join(root, CONFIG_PATH)) and not any(p == CONFIG_PATH for _, _, p in out):
        out.append(("checks", "file", CONFIG_PATH))
    return out, defining


def kind_of(path):
    base = os.path.basename(path)
    if base == "package.json":
        return "npm"
    if base in DEPS_KINDS:
        return "deps"
    return "file"


def file_hash(root, path, kind):
    full = os.path.join(root, path)
    with open(full, "rb") as f:
        data = f.read()
    if kind == "npm":
        try:
            obj = json.loads(data.decode("utf-8"))
            for k in NPM_DEP_FIELDS:
                obj.pop(k, None)
            data = json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()
        except (ValueError, AttributeError):
            pass  # not valid JSON: hash the bytes, so any change shows
    return hashlib.sha256(data).hexdigest()


def npm_deps(root, path):
    try:
        with open(os.path.join(root, path), encoding="utf-8") as f:
            obj = json.load(f)
    except (OSError, ValueError):
        return {}
    deps = {}
    for k in NPM_DEP_FIELDS:
        for name, spec in (obj.get(k) or {}).items():
            deps[f"{k}:{name}"] = spec
    return deps


def plan_exceptions(plan):
    """Backticked tokens in the plan's `## Exceptions` section: dependency names and paths."""
    if not plan or not os.path.isfile(plan):
        return set()
    names, on = set(), False
    with open(plan, encoding="utf-8") as f:
        for line in f:
            if re.match(r"^#{1,3}\s", line):
                on = bool(re.match(r"^#{1,3}\s+Exceptions\b", line, re.I))
                continue
            if on:
                names.update(t.strip() for t in re.findall(r"`([^`]+)`", line) if t.strip())
    return names


def read_frozen(run):
    path = os.path.join(run, "frozen.tsv")
    if not os.path.isfile(path):
        return None
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 4:
                rows.append(tuple(parts))
    return rows


def verify(root, run, cfg, plan, lists=("tests", "checks")):
    rows = read_frozen(run)
    if rows is None:
        return None
    exc = plan_exceptions(plan)
    deps_old = {}
    if os.path.isfile(os.path.join(run, "deps.json")):
        with open(os.path.join(run, "deps.json"), encoding="utf-8") as f:
            deps_old = json.load(f)
    problems = []
    frozen_paths = set()
    for lst, kind, h, p in rows:
        frozen_paths.add(p)
        if lst not in lists:
            continue
        if not os.path.isfile(os.path.join(root, p)):
            if p not in exc:
                problems.append((p, f"a frozen {'test' if lst == 'tests' else 'check-defining'} file was deleted"))
            continue
        if file_hash(root, p, kind) != h:
            if lst == "tests":
                if p not in exc:
                    problems.append((p, "a frozen test file was changed after the freeze"))
            elif kind == "deps":
                if not exc:
                    problems.append((p, "a lockfile or dependency manifest changed, and the plan's Exceptions section names no dependency"))
            elif p in exc and p != CONFIG_PATH:
                pass  # the plan names this file; the PRD review saw it
            else:
                problems.append((p, "a check-defining file changed after the freeze" + (" (outside its dependency fields)" if kind == "npm" else "")))
        if kind == "npm":
            old, new = deps_old.get(p, {}), npm_deps(root, p)
            changed = sorted({k for k in set(old) | set(new) if old.get(k) != new.get(k)})
            names = sorted({k.split(":", 1)[1] for k in changed})
            unnamed = [n for n in names if n not in exc]
            if unnamed:
                problems.append((p, "dependencies changed that the plan's Exceptions section doesn't name: " + ", ".join(unnamed)))
    if "checks" in lists:
        current, _ = lists_for(root, cfg)
        for lst, _, p in current:
            if lst == "checks" and p not in frozen_paths:
                problems.append((p, "a new check-defining file appeared after the freeze"))
    return problems


def main(argv):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("cmd", choices=["lists", "freeze", "verify"])
    ap.add_argument("--root", required=True)
    ap.add_argument("--config")
    ap.add_argument("--run")
    ap.add_argument("--plan")
    ap.add_argument("--only", choices=["tests", "checks"])
    try:
        a = ap.parse_args(argv[1:])
    except SystemExit:
        print(__doc__, file=sys.stderr)
        return 2
    root = os.path.realpath(a.root)
    try:
        cfg = load_config(a.config)
        if a.cmd == "lists":
            for lst, kind, p in lists_for(root, cfg)[0]:
                print(f"{lst}\t{kind}\t{p}")
            return 0
        if not a.run:
            print("freeze: --run is required", file=sys.stderr)
            return 2
        if a.cmd == "verify":
            lists = (a.only,) if a.only else ("tests", "checks")
            problems = verify(root, a.run, cfg, a.plan, lists)
            if problems is None:
                print("freeze: nothing is frozen for this run", file=sys.stderr)
                return 2
            for p, why in problems:
                print(f"{p}: {why}")
            return 1 if problems else 0
        # freeze
        if read_frozen(a.run) is not None:
            problems = verify(root, a.run, cfg, a.plan, ("checks",))
            if problems:
                print("freeze: the check-defining files changed since the last freeze; resolve this before re-freezing:", file=sys.stderr)
                for p, why in problems:
                    print(f"{p}: {why}", file=sys.stderr)
                return 1
        os.makedirs(a.run, exist_ok=True)
        rows, deps = [], {}
        for lst, kind, p in lists_for(root, cfg)[0]:
            rows.append(f"{lst}\t{kind}\t{file_hash(root, p, kind)}\t{p}\n")
            if kind == "npm":
                deps[p] = npm_deps(root, p)
        for name, content in (
            ("frozen.tsv", "".join(rows)),
            ("deps.json", json.dumps(deps, indent=2, sort_keys=True) + "\n"),
            ("checks.snapshot.json", json.dumps((cfg or {}).get("checks") or {}, indent=2) + "\n"),
        ):
            tmp = os.path.join(a.run, name + ".tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(content)
            os.replace(tmp, os.path.join(a.run, name))
        n_tests = sum(1 for r in rows if r.startswith("tests\t"))
        print(f"freeze: {n_tests} test file(s) and {len(rows) - n_tests} check-defining file(s) frozen; check commands snapshotted")
        return 0
    except subprocess.CalledProcessError as e:
        print(f"freeze: git failed: {e.stderr.decode(errors='replace').strip()}", file=sys.stderr)
        return 2
    except (OSError, ValueError) as e:
        print(f"freeze: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
