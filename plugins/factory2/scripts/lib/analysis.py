#!/usr/bin/env python3
"""A run's analysis, to make the process cheaper and faster: time, tokens and money by stage and agent,
waits for the person, loops back with their reasons, repeated and slow steps, and what to change.

    analysis.py <state.json> [<history.json>] [--now <ISO time>]

Reads the run's trace (state.trace: stage, phase, round, wait, reply and step events, each with `at`),
its spend (state.spend: the main session per stage, in dollars and tokens, and every subagent with its
stage, dollars and tokens), its spawns and rounds, and the history (escalations, issues found by people).
Prints JSON {markdown, summary}: the markdown is the analysis block, the summary the numbers behind it.
"""
import json
import sys
from datetime import datetime, timezone

STAGES = {1: "Analyze and plan", 2: "Plan review", 3: "Fix the plan", 4: "Implement", 5: "Review, QA and fixes",
          6: "Docs and evidence", 7: "Merge and deploy", 8: "Monitor"}
TOKEN_KEYS = ("input", "cache_write_5m", "cache_write_1h", "cache_read", "output")


def ts(s):
    if not s:
        return None
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        try:
            return datetime.strptime(s, "%Y-%m-%dT%H:%MZ").replace(tzinfo=timezone.utc)
        except ValueError:
            return None


def dur(secs):
    secs = int(round(secs or 0))
    if secs < 60:
        return f"{secs}s"
    m = secs // 60
    if m < 60:
        return f"{m}m"
    h, m = divmod(m, 60)
    if h < 48:
        return f"{h}h {m:02d}m"
    d, h = divmod(h, 24)
    return f"{d}d {h}h"


def money(x):
    return f"${x:,.2f}"


def ktok(n):
    n = int(n or 0)
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1000:
        return f"{n / 1000:.0f}k"
    return str(n)


def tok_total(t):
    return sum(int((t or {}).get(k) or 0) for k in TOKEN_KEYS)


def analyse(state, history, now):
    trace = sorted(state.get("trace") or [], key=lambda e: e.get("at", ""))
    created = ts(state.get("created")) or (ts(trace[0]["at"]) if trace else now)

    # --- time per stage: from each stage event to the next one (or now)
    segs = []
    traced = [(ts(e["at"]), e.get("stage")) for e in trace if e.get("kind") == "stage" and ts(e.get("at")) and e.get("stage")]
    first = traced[0][0] if traced else now
    # before the trace began (runs started on an older factory), the agents' spawns and stops say which
    # stage the run was in and when: an estimate
    seen = sorted([(ts(x.get("at")), x.get("stage")) for x in (state.get("spawns") or [])]
                  + [(ts(x.get("at")), x.get("stage")) for x in ((state.get("spend") or {}).get("agents") or {}).values()],
                  key=lambda m: m[0] or now)
    derived, last = [], 1
    for t, st in seen:
        if t and st and t < first and st != last:
            derived.append((t, st)); last = st
    estimated = bool(derived) or not traced
    marks = [(created, 1)] + derived + traced
    for i, (t0, st) in enumerate(marks):
        t1 = marks[i + 1][0] if i + 1 < len(marks) else now
        segs.append((st, t0, t1))
    stage_secs, visits = {}, {}
    for st, t0, t1 in segs:
        stage_secs[st] = stage_secs.get(st, 0) + max((t1 - t0).total_seconds(), 0)
    for i, (st, _, _) in enumerate(segs):
        if i == 0 or segs[i - 1][0] != st:
            visits[st] = visits.get(st, 0) + 1

    # --- waits for the person: a wait event to its reply
    waits, open_w = [], {}
    for e in trace:
        if e.get("kind") == "wait":
            open_w[e.get("for")] = ts(e["at"])
        elif e.get("kind") == "reply" and e.get("for") in open_w:
            t0 = open_w.pop(e["for"])
            waits.append({"for": e["for"], "secs": (ts(e["at"]) - t0).total_seconds(), "outcome": e.get("outcome")})
    for k, t0 in open_w.items():
        waits.append({"for": k, "secs": (now - t0).total_seconds(), "outcome": "waiting"})
    wait_secs = sum(w["secs"] for w in waits)
    total_secs = max((now - created).total_seconds(), 1)

    # --- spend and tokens per stage
    sp = state.get("spend") or {}
    usd, tok = {}, {}
    for s, v in (sp.get("main") or {}).items():
        usd[int(s)] = usd.get(int(s), 0) + float(v or 0)
    for s, t in (sp.get("main_tokens") or {}).items():
        tok[int(s)] = tok.get(int(s), 0) + tok_total(t)
    agents = {}
    for a in (sp.get("agents") or {}).values():
        s = int(a.get("stage") or 0)
        usd[s] = usd.get(s, 0) + float(a.get("usd") or 0)
        tok[s] = tok.get(s, 0) + tok_total(a.get("tokens"))
        r = agents.setdefault(a.get("agent", "?"), {"runs": 0, "usd": 0.0, "tokens": 0, "output": 0})
        r["runs"] += 1
        r["usd"] += float(a.get("usd") or 0)
        r["tokens"] += tok_total(a.get("tokens"))
        r["output"] += int((a.get("tokens") or {}).get("output") or 0)
    spawns = {}
    for sw in state.get("spawns") or []:
        spawns[sw.get("agent")] = spawns.get(sw.get("agent"), 0) + 1
    total_usd = sum(usd.values())
    total_tok = sum(tok.values())
    main_usd = sum(float(v or 0) for v in (sp.get("main") or {}).values())

    # --- loops back
    backs = [e for e in trace if e.get("kind") == "stage" and e.get("from") and e.get("stage") and e["stage"] < e["from"]]
    loop_cost = []
    for b in backs:
        t0 = ts(b["at"])
        later = [ts(e["at"]) for e in trace if e.get("kind") == "stage" and ts(e.get("at")) and ts(e["at"]) > t0
                 and (e.get("stage") or 0) >= b["from"]]
        t1 = later[0] if later else now
        loop_cost.append({"from": b["from"], "to": b["stage"], "why": b.get("why") or "", "revoked": b.get("revoked") or "",
                          "secs": (t1 - t0).total_seconds(), "at": b["at"]})

    # --- steps: checks and evidence recordings
    steps = {}
    for e in trace:
        if e.get("kind") != "step":
            continue
        n = e.get("name", "?")
        key = "evidence recording" if n.startswith("evidence capture") else n
        r = steps.setdefault(key, {"n": 0, "secs": 0, "failed": 0})
        r["n"] += 1
        r["secs"] += int(e.get("secs") or 0)
        r["failed"] += 1 if e.get("exit") not in (0, None) else 0

    rounds = state.get("rounds") or {}
    esc = (history or {}).get("escalations") or []
    human = [i for i in ((history or {}).get("issues") or []) if i.get("found_by") == "human"]

    # --- what to change
    tips = []
    if backs:
        worst = max(loop_cost, key=lambda x: x["secs"])
        tips.append(f"**{len(backs)} loop(s) back** cost {dur(sum(x['secs'] for x in loop_cost))}; the longest, stage "
                    f"{worst['from']} → {worst['to']} ({worst['why'] or 'no reason given'}), took {dur(worst['secs'])}. "
                    "A problem found later than stage 5 means review and QA missed it: add it to the reviewers' calibration "
                    "(ce-compound) so the next run catches it in stage 5.")
    ev = steps.get("evidence recording")
    if ev and ev["n"] > 1:
        tips.append(f"**The evidence was recorded {ev['n']} times** ({dur(ev['secs'])}). Record once, at the final gate, "
                    "after every check passes, and re-record only the criteria a fix touched (`evidence.sh capture --ac`).")
    if ev and ev["failed"]:
        tips.append(f"**{ev['failed']} evidence recording(s) failed**: a demo test that fails on camera is a test the checks "
                    "didn't run. Run the `@AC` e2e specs in stage 5's checks so the recording never finds a failure.")
    if total_secs > 0 and wait_secs / total_secs > 0.4:
        tips.append(f"**{wait_secs / total_secs:.0%} of the time was waiting for a person** ({dur(wait_secs)}). "
                    "Replies on the issue unblock the run at once; the status block at the top of the issue says when you are needed.")
    if esc:
        reasons = "; ".join((e.get("reason", "")[:70] + ("…" if len(e.get("reason", "")) > 70 else "")) for e in esc[:3])
        tips.append(f"**{len(esc)} limit(s) were raised mid-run** ({reasons}). "
                    "If this keeps happening, raise `limits.*` for runs this size, or split the feature into smaller issues.")
    if total_usd > 0:
        top_stage = max(usd, key=lambda s: usd[s])
        share = usd[top_stage] / total_usd
        if share > 0.35:
            tips.append(f"**Stage {top_stage} ({STAGES.get(top_stage, '')}) took {share:.0%} of the spend** "
                        f"({money(usd[top_stage])}). Look there first.")
        if agents:
            ta = max(agents, key=lambda a: agents[a]["usd"])
            if agents[ta]["usd"] / total_usd > 0.25:
                tips.append(f"**{ta}** cost {money(agents[ta]['usd'])} over {agents[ta]['runs']} run(s) "
                            f"({agents[ta]['usd'] / total_usd:.0%}). Try a cheaper model or a lower effort for it "
                            "(`roles.{ta}` in .factory/config.yaml) and compare with `/factory2:stats`.")
        if main_usd / total_usd > 0.4:
            tips.append(f"**The orchestrating session cost {money(main_usd)} ({main_usd / total_usd:.0%})**: long tool "
                        "outputs and re-reading files in the main context. Prefer `--tail` on checks and delegate reading to agents.")
    if (rounds.get("impl") or 0) > 1:
        tips.append(f"**The implementer ran {rounds['impl']} times** before the tests passed: a plan step was unclear or "
                    "a test too strict; the failure reports say which.")
    if human:
        tips.append(f"**People found {len(human)} issue(s) the agents missed**; each is a calibration line for the agent "
                    "that should have caught it (`/factory2:stats` lists them across runs).")
    if not tips:
        tips.append("Nothing stands out: no loops back, one recording, no limit raised.")

    # --- markdown
    L = ["### 📊 Analysis: where the time and tokens went", ""]
    L.append(f"**Total:** {dur(total_secs)} elapsed · {dur(total_secs - wait_secs)} working · {dur(wait_secs)} waiting for a person · "
             f"{money(total_usd)} · {ktok(total_tok)} tokens")
    L.append("")
    if estimated:
        L.append("<sub>Time per stage before tracing began is estimated from the agents' start and stop times.</sub>")
        L.append("")
    L.append("| Stage | Time | Visits | Spend | Tokens |")
    L.append("|---|---:|---:|---:|---:|")
    for st in sorted(set(stage_secs) | set(usd)):
        if st == 0:
            continue
        L.append(f"| {st} {STAGES.get(st, '')} | {dur(stage_secs.get(st, 0))} | {visits.get(st, 0)} | "
                 f"{money(usd.get(st, 0))} | {ktok(tok.get(st, 0))} |")
    L.append("")
    if agents:
        L.append("| Agent | Runs | Spend | Tokens | Output |")
        L.append("|---|---:|---:|---:|---:|")
        for a in sorted(agents, key=lambda a: -agents[a]["usd"]):
            r = agents[a]
            L.append(f"| {a} | {r['runs']} | {money(r['usd'])} | {ktok(r['tokens'])} | {ktok(r['output'])} |")
        L.append(f"| *main session* | | {money(main_usd)} | {ktok(sum(tok_total(t) for t in (sp.get('main_tokens') or {}).values()))} | |")
        L.append("")
    if loop_cost:
        L.append("**Loops back**")
        L.append("")
        for x in loop_cost:
            L.append(f"- {x['at'][:16].replace('T', ' ')} · stage {x['from']} → {x['to']}: {x['why'] or 'no reason given'}"
                     f"{' (revoked: ' + x['revoked'] + ')' if x['revoked'] else ''} · {dur(x['secs'])} until back")
        L.append("")
    if waits:
        L.append("**Waits for a person:** " + "; ".join(f"{w['for']} {dur(w['secs'])} ({w['outcome']})" for w in waits))
        L.append("")
    if steps:
        L.append("**Slow or repeated steps:** " + "; ".join(
            f"{k} ×{v['n']} {dur(v['secs'])}{' (' + str(v['failed']) + ' failed)' if v['failed'] else ''}"
            for k, v in sorted(steps.items(), key=lambda kv: -kv[1]["secs"])[:6]))
        L.append("")
    if rounds:
        L.append("**Rounds:** " + ", ".join(f"{k} {v}" for k, v in rounds.items()))
        L.append("")
    L.append("#### What to change")
    L.append("")
    L.extend(f"- {t}" for t in tips)
    summary = {"elapsed_s": int(total_secs), "waiting_s": int(wait_secs), "usd": round(total_usd, 4), "tokens": total_tok,
               "stages": {str(k): {"secs": int(stage_secs.get(k, 0)), "visits": visits.get(k, 0), "usd": round(usd.get(k, 0), 4),
                                   "tokens": tok.get(k, 0)} for k in sorted(set(stage_secs) | set(usd))},
               "agents": agents, "spawns": spawns, "loops_back": loop_cost, "waits": waits, "steps": steps,
               "tips": tips}
    return "\n".join(L) + "\n", summary


def main(argv):
    args = argv[1:]
    now = datetime.now(timezone.utc)
    if "--now" in args:
        i = args.index("--now")
        now = ts(args[i + 1]) or now
        del args[i:i + 2]
    if not args:
        print(__doc__, file=sys.stderr)
        return 2
    with open(args[0], encoding="utf-8") as f:
        state = json.load(f)
    history = {}
    if len(args) > 1:
        try:
            with open(args[1], encoding="utf-8") as f:
                history = json.load(f)
        except (OSError, ValueError):
            history = {}
    md, summary = analyse(state, history, now)
    json.dump({"markdown": md, "summary": summary}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
