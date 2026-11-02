#!/usr/bin/env python3
"""Maps JUnit XML test results to acceptance criteria. The harness, never an agent, sets `passes`.

  junit.py sync <contract.json> <reports dir>
      Sets each criterion's test_ids and passes: passes is true only when at least one test names the
      criterion and every test that names it passed. Prints one line per criterion.
      Exit 0 when every criterion passes, 1 otherwise, 2 on bad input.
  junit.py red <contract.json> <reports dir>
      Before the code exists: lists AC tests that already pass (suspicious: they may assert nothing, or
      test behaviour that already exists) and criteria with no visible test (the suite may not have
      collected). Exit 0 when nothing is flagged, 1 otherwise.
  junit.py red-tests <reports dir> <name> [<name>...]
      Stage 5: each named test (exact test name or id, else a substring matching exactly one test) must
      appear in the results and fail. One argument per name (names may contain commas). Exit 0 when all
      are red, 1 otherwise.
  junit.py lint <reports dir>
      Lists test names that carry an `@AC-n` tag with a suffix (`@AC-1-extra`, `@AC-1b`), which a
      `--grep '@AC-1\\b'` would select by mistake. Exit 0 clean, 1 otherwise.

A test names criterion n when its name, class name or a property value contains `@AC-n` / `AC-n`
(free-text titles: Playwright, Vitest, Jest, pytest ids; not followed by a digit, letter, - or _) or
`AC_n` (function names: Go, Swift, Python; not followed by a digit), preceded by a non-letter or by
`Test`/`test`. A suffixed tag (`@AC-1-extra`) names no criterion.
Every *.xml file under the reports directory is read; a testcase with <failure> or <error> failed, one
with <skipped> was skipped (and does not pass).
"""
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

# AC-n (titles): not followed by a digit, letter, - or _, so `@AC-1-extra` and `@AC-1b` name nothing (and
# the lint reports them). AC_n (function names): not followed by a digit.
TAG = re.compile(r"(?:(?<![A-Za-z])|(?<=[Tt]est))@?AC(?:-(\d+)(?![\dA-Za-z_-])|_(\d+)(?!\d))")
SUFFIXED = re.compile(r"@AC-\d+[-A-Za-z_]")


def load_cases(reports):
    cases = []
    if not os.path.isdir(reports):
        return cases
    for dirpath, _, files in os.walk(reports):
        for fn in sorted(files):
            if not fn.endswith(".xml"):
                continue
            path = os.path.join(dirpath, fn)
            try:
                root = ET.parse(path).getroot()
            except ET.ParseError as e:
                print(f"junit: {path}: not valid XML ({e}); skipped", file=sys.stderr)
                continue
            for tc in root.iter("testcase"):
                name = tc.get("name", "")
                cls = tc.get("classname", "") or tc.get("class", "")
                props = " ".join(p.get("value", "") or (p.text or "") for p in tc.iter("property"))
                kids = {c.tag for c in tc}
                if "failure" in kids or "error" in kids:
                    status = "failed"
                elif "skipped" in kids:
                    status = "skipped"
                else:
                    status = "passed"
                cases.append({
                    "id": f"{cls}::{name}" if cls else name,
                    "name": name,
                    "text": f"{cls} {name} {props}",
                    "status": status,
                    "file": os.path.relpath(path, reports),
                })
    return cases


def criteria_of(case):
    return {int(m.group(1) or m.group(2)) for m in TAG.finditer(case["text"])}


def ac_number(cid):
    m = re.fullmatch(r"AC-(\d+)", str(cid).strip())
    return int(m.group(1)) if m else None


def load_contract(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    crit = data.get("criteria") if isinstance(data, dict) else data
    if not isinstance(crit, list):
        raise ValueError("contract.json needs a `criteria` list")
    for c in crit:
        if ac_number(c.get("id")) is None:
            raise ValueError(f"criterion id {c.get('id')!r} is not of the form AC-<n>")
    return data, crit


def cmd_sync(contract, reports):
    data, crit = load_contract(contract)
    cases = load_cases(reports)
    by_ac = {}
    for c in cases:
        for n in criteria_of(c):
            by_ac.setdefault(n, []).append(c)
    all_pass = True
    for c in crit:
        n = ac_number(c["id"])
        tests = by_ac.get(n, [])
        c["test_ids"] = sorted({t["id"] for t in tests})
        c["passes"] = bool(tests) and all(t["status"] == "passed" for t in tests)
        all_pass = all_pass and c["passes"]
        if not tests:
            why = "no test names it"
        else:
            bad = [t for t in tests if t["status"] != "passed"]
            why = f"{len(tests)} test(s) passed" if not bad else f"{len(bad)} of {len(tests)} test(s) not passing: " + "; ".join(f"{t['id']} ({t['status']})" for t in bad[:5])
        print(f"{c['id']}\t{'PASS' if c['passes'] else 'FAIL'}\t{why}")
    known = {ac_number(c["id"]) for c in crit}
    stray = sorted(n for n in by_ac if n not in known)
    for n in stray:
        print(f"AC-{n}\tUNKNOWN\ttests name a criterion that contract.json does not have")
    tmp = contract + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, contract)
    return 0 if all_pass and not stray else 1


def cmd_red(contract, reports):
    _, crit = load_contract(contract)
    cases = load_cases(reports)
    flagged = 0
    for c in crit:
        n = ac_number(c["id"])
        tests = [t for t in cases if n in criteria_of(t)]
        if not tests:
            print(f"{c['id']}\tNOT-VISIBLE\tno test result names it (the suite may have failed to collect; check the run output)")
            flagged += 1
            continue
        for t in tests:
            if t["status"] == "passed":
                print(f"{c['id']}\tPASSES-EARLY\t{t['id']} passes before the code exists")
                flagged += 1
    if not flagged:
        print("junit: every AC test fails before the code exists")
    return 1 if flagged else 0


def cmd_red_tests(reports, names):
    """Stage 5 fix loop: each named new test must be present in the results and fail."""
    cases = load_cases(reports)
    wanted = [n.strip() for n in names if n.strip()]
    if not wanted:
        print("junit: red-tests needs test names", file=sys.stderr)
        return 2
    flagged = 0
    for w in wanted:
        hits = [t for t in cases if w in (t["name"], t["id"])]
        if not hits:  # a partial name only when it is unambiguous
            sub = [t for t in cases if w in t["name"]]
            if len({t["id"] for t in sub}) > 1:
                print(f"{w}\tAMBIGUOUS\tmatches " + "; ".join(sorted({t["id"] for t in sub})[:5]) + " (give the exact name)")
                flagged += 1
                continue
            hits = sub
        if not hits:
            print(f"{w}\tNOT-VISIBLE\tno test result has this name (not collected, or misnamed)")
            flagged += 1
        elif any(t["status"] != "failed" for t in hits):
            print(f"{w}\tPASSES-EARLY\t" + "; ".join(f"{t['id']} ({t['status']})" for t in hits if t["status"] != "failed"))
            flagged += 1
        else:
            print(f"{w}\tRED\t{len(hits)} result(s) fail")
    return 1 if flagged else 0


def cmd_lint(reports):
    bad = sorted({t["id"] for t in load_cases(reports) if SUFFIXED.search(t["text"])})
    for b in bad:
        print(f"{b}\tSUFFIXED-TAG\tan @AC-n tag must not be followed by - or a letter")
    return 1 if bad else 0


def main(argv):
    try:
        if len(argv) == 4 and argv[1] == "sync":
            return cmd_sync(argv[2], argv[3])
        if len(argv) == 4 and argv[1] == "red":
            return cmd_red(argv[2], argv[3])
        if len(argv) >= 4 and argv[1] == "red-tests":
            return cmd_red_tests(argv[2], argv[3:])
        if len(argv) == 3 and argv[1] == "lint":
            return cmd_lint(argv[2])
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"junit: {e}", file=sys.stderr)
        return 2
    print(__doc__.strip().split("\n\n")[0], file=sys.stderr)
    print("usage: junit.py sync|red <contract.json> <reports dir> | junit.py red-tests <reports dir> <name>..."
          " | junit.py lint <reports dir>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
