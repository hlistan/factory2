"""factory stats: reads every .factory/history/*.json and prints markdown tables.

  stats.py <project root> <memory max lines> [--since YYYY-MM-DD] [--export-evals]

--export-evals writes each QA false negative as a candidate eval case under .factory/eval-candidates/.
Differences between arms with fewer than 10 runs each are labelled directional.
Exit 0; 2 on bad arguments.
"""
import glob
import json
import os
import re
import sys
from collections import Counter, defaultdict


def table(head, rows):
    if not rows:
        return "_none_\n"
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    for r in rows:
        out.append("| " + " | ".join(str(c).replace("|", "\\|").replace("\n", " ") for c in r) + " |")
    return "\n".join(out) + "\n"


def usd(x):
    try:
        return f"${float(x):.2f}"
    except (TypeError, ValueError):
        return "?"


def pct(a, b):
    return f"{100 * a / b:.0f}% ({a}/{b})" if b else "–"


def load(root, since):
    runs = []
    for p in sorted(glob.glob(os.path.join(root, ".factory", "history", "*.json"))):
        try:
            with open(p, encoding="utf-8") as f:
                h = json.load(f)
        except (OSError, ValueError):
            print(f"> skipped unreadable {os.path.relpath(p, root)}\n")
            continue
        if since and (h.get("started") or "") < since:
            continue
        h.setdefault("slug", os.path.basename(p)[:-5])
        runs.append(h)
    return runs


def frontmatter(path):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return {}
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    if not m:
        return {}
    out = {}
    for line in m.group(1).splitlines():
        k, _, v = line.partition(":")
        if v and not line.startswith(" "):
            out[k.strip()] = v.strip().strip("'\"")
    return out


def docs_root(root):
    p = os.path.join(root, ".compound-engineering", "config.yaml")
    try:
        with open(p, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"^docs_root:\s*['\"]?([^'\"#]+)", line)
                if m:
                    return m.group(1).strip()
    except OSError:
        pass
    return "docs"


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    root, mx = argv[1], int(argv[2])
    since, export = "", False
    rest = argv[3:]
    while rest:
        a = rest.pop(0)
        if a == "--since" and rest:
            since = rest.pop(0)
        elif a == "--export-evals":
            export = True
        else:
            print(f"factory: unknown option {a}", file=sys.stderr)
            return 2
    runs = load(root, since)
    out = []
    finished = [r for r in runs if r.get("finished")]
    kinds = Counter(r.get("kind") or "feature" for r in runs)
    out.append(f"# factory stats{' since ' + since if since else ''}\n")
    out.append(f"{len(runs)} run(s): {kinds.get('feature', 0)} feature, {kinds.get('bugfix', 0)} bugfix; "
               f"{len(finished)} finished.\n")
    if not runs:
        out.append("No history yet: `.factory/history/` is written by /factory2:run.\n")
        print("\n".join(out))
        return 0
    small = len(runs) < 10
    if small:
        out.append("> Fewer than 10 runs: every difference below is directional, not a measurement.\n")

    # spend
    by_stage, by_agent, totals = defaultdict(float), defaultdict(float), []
    for r in runs:
        s = r.get("spend") or {}
        for k, v in (s.get("by_stage") or {}).items():
            by_stage[str(k)] += float(v or 0)
        for k, v in (s.get("by_agent") or {}).items():
            by_agent[k] += float(v or 0)
        if s.get("total") is not None:
            totals.append(float(s["total"]))
    out.append("## Spend by stage\n")
    tot = sum(by_stage.values())
    out.append(table(["Stage", "USD", "Share"], [(k, usd(v), f"{100 * v / tot:.0f}%" if tot else "–")
                                                 for k, v in sorted(by_stage.items(), key=lambda kv: kv[0])]))
    if totals:
        out.append(f"Per run: mean {usd(sum(totals) / len(totals))}, max {usd(max(totals))} ({len(totals)} runs with spend).\n")
    out.append("## Spend by agent\n")
    out.append(table(["Agent", "USD"], [(k, usd(v)) for k, v in sorted(by_agent.items(), key=lambda kv: -kv[1])]))

    # implementer
    out.append("## Implementer: first-pass rate by model and effort\n")
    arms = defaultdict(lambda: [0, 0, 0])  # runs, first pass ok, re-runs
    fn_by_effort = Counter()
    for r in runs:
        passes = sorted(r.get("implementer_passes") or [], key=lambda p: p.get("round") or 0)
        if not passes:
            continue
        first = passes[0]
        key = (first.get("model") or "?", first.get("effort") or "?")
        arms[key][0] += 1
        arms[key][1] += 1 if first.get("passed") else 0
        arms[key][2] += max(0, len(passes) - 1)
        fn_by_effort[first.get("effort") or "?"] += len(r.get("qa_false_negatives") or [])
    out.append(table(["Model", "Effort", "Runs", "First pass", "Re-runs", "QA false negatives"],
                     [(m, e, v[0], pct(v[1], v[0]), v[2], fn_by_effort.get(e, 0)) for (m, e), v in sorted(arms.items())]))

    # rounds, escalations, incidents
    out.append("## Rounds, escalations and incidents\n")
    rows = []
    for r in runs:
        rd = r.get("rounds") or {}
        rows.append((r["slug"], r.get("kind") or "feature", r.get("depth") or "–", rd.get("prd", "–"), rd.get("impl", "–"),
                     rd.get("review", "–"), rd.get("evidence", "–"), len(r.get("escalations") or []),
                     len(r.get("incidents") or []), usd((r.get("spend") or {}).get("total"))))
    out.append(table(["Run", "Kind", "Depth", "PRD", "Impl", "Review", "Evidence", "Escalations", "Incidents", "Spend"], rows))

    # escapes
    out.append("## Escapes (bugfix runs per originating run)\n")
    esc = defaultdict(list)
    for r in runs:
        if (r.get("kind") == "bugfix") and r.get("caused_by"):
            esc[r["caused_by"]].append((r["slug"], (r.get("escape") or {}).get("stage_missed") or "?"))
    out.append(table(["Shipped by", "Bugfix runs", "Stage that should have caught it"],
                     [(k, ", ".join(s for s, _ in v), ", ".join(m for _, m in v)) for k, v in sorted(esc.items())]))

    # human-found issues
    out.append("## Issues found by people\n")
    by = Counter()
    for r in runs:
        for i in r.get("issues") or []:
            if (i.get("found_by") or "") == "human":
                by[(str(i.get("stage", "?")), i.get("class") or "–", i.get("problem_type") or "–", i.get("component") or "–")] += 1
    out.append(table(["Stage", "Class", "Problem type", "Component", "Count"], [(*k, v) for k, v in sorted(by.items())]))
    sol = glob.glob(os.path.join(root, docs_root(root), "solutions", "**", "*.md"), recursive=True)
    if sol:
        pt = Counter(frontmatter(p).get("problem_type") or "–" for p in sol)
        out.append(f"Lessons in `{docs_root(root)}/solutions/` by problem type ({len(sol)} docs):\n")
        out.append(table(["Problem type", "Docs"], sorted(pt.items(), key=lambda kv: -kv[1])))

    # depth ablation
    out.append("## Depth: defects that reached stage 6 or production\n")
    dep = defaultdict(lambda: [0, 0, 0])
    for r in runs:
        d = r.get("depth") or "–"
        dep[d][0] += 1
        dep[d][1] += sum(1 for i in r.get("issues") or [] if str(i.get("stage")) == "6" and i.get("class") == "defect")
        dep[d][2] += sum(1 for x in runs if x.get("caused_by") == r["slug"])
    out.append(table(["Depth", "Runs", "Stage 6 defects", "Escapes to production"], [(k, *v) for k, v in sorted(dep.items())]))
    if any(v[0] < 10 for v in dep.values()):
        out.append("Fewer than 10 runs per depth: directional only.\n")

    # compound
    out.append("## ce-compound\n")
    co = Counter(c.get("outcome") or "?" for r in runs for c in r.get("compound") or [])
    vers = Counter(r.get("ce_version") or "?" for r in runs)
    out.append(table(["Outcome", "Count"], sorted(co.items())))
    out.append("Bundled compound-engineering versions: " + ", ".join(f"{k} ({v} runs)" for k, v in sorted(vers.items())) + "\n")

    # memory size
    out.append("## Agent memory size\n")
    rows = []
    for p in sorted(glob.glob(os.path.join(root, ".claude", "agent-memory", "factory-*", "MEMORY.md"))):
        with open(p, encoding="utf-8") as f:
            n = sum(1 for _ in f)
        agent = os.path.basename(os.path.dirname(p))[len("factory-"):]
        rows.append((agent, n, mx, "consolidate" if n >= 0.8 * mx else ""))
    out.append(table(["Agent", "Lines", "Cap", ""], rows))

    # QA false negatives / export
    fns = [(r["slug"], f) for r in runs for f in r.get("qa_false_negatives") or []]
    out.append(f"## QA false negatives\n\n{len(fns)} in total.\n")
    if export and fns:
        d = os.path.join(root, ".factory", "eval-candidates")
        os.makedirs(d, exist_ok=True)
        for slug, f in fns:
            ac = re.sub(r"[^A-Za-z0-9-]", "", str(f.get("ac") or "AC"))
            name = f"qa-{slug}-{ac}".lower()
            path = os.path.join(d, name + ".md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(f"# Candidate eval case: {name}\n\nRun: `{slug}`  \nCriterion: {f.get('ac')}\n\n"
                         f"The person's comment at stage 6 (QA had passed this criterion):\n\n> {f.get('comment', '')}\n\n"
                         "To adopt: copy the run's spec and the app state into plugins/factory2/evals/<case>/ as a\n"
                         "prompt.md for qa-evaluator, with a grader that fails when QA passes the criterion.\n")
        out.append(f"Wrote {len(fns)} candidate(s) to `.factory/eval-candidates/`; review them before adding to the plugin's evals.\n")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
