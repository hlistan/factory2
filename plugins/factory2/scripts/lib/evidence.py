"""factory evidence helper (stage 6). Used by scripts/evidence.sh; not called directly.

  evidence.py manifest <evidence dir> <driver> <exit code> <head sha>
      Writes <evidence dir>/manifest.json. With the playwright driver it reads the JSON reporter's
      results.json (tests, their projects = viewports, statuses and attachments; a path the demo
      reported from inside a container is found by its tail under the evidence dir); with command it lists
      the media files under the directory and maps each to criteria by AC-n / AC_n in its path; with none
      it records no media. Exit 1 when the playwright driver produced no results.json.

  evidence.py pack <evidence dir> <pack dir> <contract.json> <info.json>
      Builds <pack dir>/index.html and copies the media into <pack dir>/media/, so the folder is
      self-contained. info.json: {slug, pr_url, head, spend, findings, generated}.
"""
import html
import json
import os
import re
import shutil
import sys

AC_RE = re.compile(r"\bAC[-_](\d+)(?![\d])")
MEDIA = {".png": "image", ".jpg": "image", ".jpeg": "image", ".gif": "image", ".webp": "image",
         ".mp4": "video", ".webm": "video", ".mov": "video"}


def acs(*texts):
    out = []
    for t in texts:
        for m in AC_RE.finditer(t or ""):
            a = "AC-" + m.group(1)
            if a not in out:
                out.append(a)
    return out


def rel(path, base):
    p = os.path.realpath(path)
    b = os.path.realpath(base)
    return os.path.relpath(p, b) if p.startswith(b + os.sep) else None


def local_path(path, edir):
    """The attachment's file on this machine. A demo that ran in a container (or on another mount)
    reports its own paths; the file it names is then the one at the longest tail of that path, of a
    directory and a file at least, that exists under the evidence dir."""
    if os.path.isfile(path):
        return path
    parts = [x for x in path.replace("\\", "/").split("/") if x]
    for i in range(len(parts) - 1):
        cand = os.path.join(edir, *parts[i:])
        if os.path.isfile(cand):
            return cand
    return path


def prefer_mp4(path):
    """The mp4 next to a converted webm, when evidence.sh made one."""
    if path.endswith(".webm"):
        mp4 = path[:-5] + ".mp4"
        if os.path.isfile(mp4):
            return mp4
    return path


def walk_specs(suite, titles):
    t = titles + ([suite["title"]] if suite.get("title") else [])
    for spec in suite.get("specs") or []:
        yield t, spec
    for s in suite.get("suites") or []:
        yield from walk_specs(s, t)


def manifest_playwright(edir):
    rpath = os.path.join(edir, "results.json")
    if not os.path.isfile(rpath):
        return None
    with open(rpath, encoding="utf-8") as f:
        report = json.load(f)
    tests = []
    for top in report.get("suites") or []:
        for titles, spec in walk_specs(top, []):
            tags = spec.get("tags") or []
            for test in spec.get("tests") or []:
                results = test.get("results") or []
                last = results[-1] if results else {}
                media = []
                for res in results[-1:]:
                    for a in res.get("attachments") or []:
                        p = a.get("path")
                        if not p:
                            continue
                        p = prefer_mp4(local_path(p, edir))
                        if not os.path.isfile(p):
                            continue
                        kind = MEDIA.get(os.path.splitext(p)[1].lower())
                        if not kind:
                            continue
                        r = rel(p, edir)
                        if r is None:  # outside the evidence dir: copy it in
                            dst = os.path.join(edir, "external", str(len(tests)), os.path.basename(p))
                            os.makedirs(os.path.dirname(dst), exist_ok=True)
                            shutil.copy2(p, dst)
                            r = rel(dst, edir)
                        media.append({"kind": kind, "path": r})
                status = last.get("status") or test.get("status") or "unknown"
                tests.append({
                    "title": " › ".join(titles[1:] + [spec.get("title", "")]) if len(titles) > 1 else spec.get("title", ""),
                    "file": spec.get("file") or (titles[0] if titles else ""),
                    "ac": acs(spec.get("title", ""), " ".join(tags), " ".join(titles)),
                    "project": test.get("projectName") or "",
                    "status": status,
                    "media": media,
                })
    return tests


def manifest_files(edir):
    tests = []
    for root, _dirs, files in os.walk(edir):
        for name in sorted(files):
            p = os.path.join(root, name)
            kind = MEDIA.get(os.path.splitext(name)[1].lower())
            if not kind or (name.endswith(".webm") and os.path.isfile(p[:-5] + ".mp4")):
                continue
            r = rel(p, edir)
            tests.append({"title": r, "file": "", "ac": acs(r), "project": "", "status": "captured",
                          "media": [{"kind": kind, "path": r}]})
    return tests


def cmd_manifest(edir, driver, code, head):
    if driver == "playwright":
        tests = manifest_playwright(edir)
        if tests is None:
            print("factory: the demo run wrote no results.json (is the JSON reporter in playwright.demo.config.ts?)", file=sys.stderr)
            return 1
    elif driver == "command":
        tests = manifest_files(edir)
    else:
        tests = []
    if driver == "playwright" and tests and not any(t["media"] for t in tests):
        print("factory: the demo ran but recorded no video or screenshot; read run.log (a missing browser:"
              " npx playwright install)", file=sys.stderr)
        return 1
    m = {"driver": driver, "exit": int(code), "head": head, "tests": tests}
    with open(os.path.join(edir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(m, f, indent=2)
    n_media = sum(len(t["media"]) for t in tests)
    failed = [t for t in tests if t["status"] not in ("passed", "captured", "skipped")]
    print(f"factory: evidence: {len(tests)} test(s), {n_media} media file(s), {len(failed)} not passed")
    return 0


E = html.escape

CSS = """
:root { --bg: #fff; --fg: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --ok: #1a7f37; --bad: #cf222e; --card: #f6f8fa; }
@media (prefers-color-scheme: dark) { :root { --bg: #0d1117; --fg: #e6edf3; --muted: #8b949e; --line: #30363d; --ok: #3fb950; --bad: #f85149; --card: #161b22; } }
* { box-sizing: border-box; }
body { margin: 0; padding: 24px 16px 64px; background: var(--bg); color: var(--fg);
       font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
main { max-width: 1100px; margin: 0 auto; }
h1 { font-size: 1.6rem; margin: 0 0 4px; } h2 { margin-top: 40px; border-bottom: 1px solid var(--line); padding-bottom: 6px; }
.meta { color: var(--muted); } .meta a { color: inherit; }
.summary { display: flex; gap: 12px; flex-wrap: wrap; margin: 16px 0; }
.tile { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 10px 14px; min-width: 120px; }
.tile b { display: block; font-size: 1.4rem; }
.ac { border: 1px solid var(--line); border-radius: 10px; padding: 16px; margin: 16px 0; }
.ac h3 { margin: 0 0 6px; font-size: 1.05rem; }
.badge { display: inline-block; font-size: .78rem; font-weight: 600; padding: 1px 8px; border-radius: 999px; border: 1px solid; margin-left: 6px; vertical-align: 1px; }
.pass { color: var(--ok); border-color: var(--ok); } .fail { color: var(--bad); border-color: var(--bad); }
.tests { margin: 8px 0; padding-left: 18px; color: var(--muted); }
.cards { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 10px; align-items: flex-start; }
.card { margin: 0; background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 8px; max-width: 100%; }
.card video, .card img { display: block; max-height: 360px; max-width: 100%; width: auto; height: auto; border-radius: 4px; background: #000; }
.card img { margin-top: 6px; }
figcaption { font-size: .8rem; color: var(--muted); margin-top: 6px; word-break: break-all; } figcaption a { color: inherit; }
table { border-collapse: collapse; width: 100%; } td, th { border-bottom: 1px solid var(--line); padding: 6px 8px; text-align: left; vertical-align: top; }
"""


def copy_media(edir, pdir, path):
    src = os.path.join(edir, path)
    dst = os.path.join(pdir, "media", path)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    return "media/" + path


def media_html(edir, pdir, tests):
    """One card per test run (a viewport): the video with its screenshot as poster, or the screenshots."""
    cards = []
    for test in tests:
        shots = [copy_media(edir, pdir, m["path"]) for m in test["media"] if m["kind"] == "image"]
        vids = [copy_media(edir, pdir, m["path"]) for m in test["media"] if m["kind"] == "video"]
        if not shots and not vids:
            continue
        cap = " · ".join(x for x in (test.get("project"), test.get("status")) if x) or test["title"]
        inner = []
        for v in vids:
            poster = f' poster="{E(shots[0])}"' if shots else ""
            inner.append(f'<video controls preload="none"{poster} src="{E(v)}"></video>')
        imgs = shots if not vids else shots[1:]
        for src in imgs:
            inner.append(f'<a href="{E(src)}"><img loading="lazy" src="{E(src)}" alt="{E(test["title"])}"></a>')
        links = " · ".join(f'<a href="{E(x)}">{E(os.path.basename(x))}</a>' for x in vids + shots)
        cards.append(f'<figure class="card">{"".join(inner)}<figcaption><b>{E(cap)}</b><br>{links}</figcaption></figure>')
    return '<div class="cards">' + "".join(cards) + "</div>" if cards else ""


def cmd_pack(edir, pdir, contract_path, info_path):
    with open(os.path.join(edir, "manifest.json"), encoding="utf-8") as f:
        man = json.load(f)
    with open(contract_path, encoding="utf-8") as f:
        crit = json.load(f).get("criteria") or []
    with open(info_path, encoding="utf-8") as f:
        info = json.load(f)
    if os.path.isdir(pdir):
        shutil.rmtree(pdir)
    os.makedirs(pdir)
    tests = man.get("tests") or []
    passed = sum(1 for c in crit if c.get("passes") is True)
    body = []
    pr = info.get("pr_url") or ""
    body.append(f'<h1>Review pack: {E(info.get("slug", ""))}</h1>')
    meta = [f'commit <code>{E((info.get("head") or "")[:12])}</code>', f'generated {E(info.get("generated", ""))}',
            f'driver {E(man.get("driver", ""))}']
    if pr:
        meta.append(f'<a href="{E(pr)}">pull request</a>')
    body.append(f'<p class="meta">{" · ".join(meta)}</p>')
    body.append('<div class="summary">'
                f'<div class="tile"><b>{passed} / {len(crit)}</b>criteria pass</div>'
                f'<div class="tile"><b>{len(tests)}</b>demo tests</div>'
                f'<div class="tile"><b>{sum(len(t["media"]) for t in tests)}</b>media files</div>'
                f'<div class="tile"><b>${float((info.get("spend") or {}).get("total") or 0):.2f}</b>estimated spend</div>'
                '</div>')
    if man.get("driver") == "none":
        body.append('<p class="meta">evidence.driver is none: test results only, no screenshots or video.</p>')
    body.append("<h2>Acceptance criteria</h2>")
    for c in crit:
        cid = c.get("id", "")
        ok = c.get("passes") is True
        badge = f'<span class="badge {"pass" if ok else "fail"}">{"passes" if ok else "not passing"}</span>'
        body.append(f'<section class="ac" id="{E(cid)}"><h3>{E(cid)}{badge}</h3><p>{E(c.get("text", ""))}</p>')
        ids = c.get("test_ids") or []
        mine = [t for t in tests if cid in t.get("ac", [])]
        lines = [f'<li>{E(t["title"])} <span class="meta">({E(t.get("project") or "")} · {E(t["status"])})</span></li>' for t in mine]
        if not mine and ids:
            lines = [f"<li>{E(i)}</li>" for i in ids]
        body.append(f'<p class="meta">Level: {E(c.get("level") or "?")}</p>')
        if lines:
            body.append('<ul class="tests">' + "".join(lines) + "</ul>")
        body.append(media_html(edir, pdir, mine))
        if not mine and man.get("driver") != "none":
            body.append('<p class="meta">No demo media for this criterion (it may be tested below the e2e level).</p>')
        body.append("</section>")
    other = [t for t in tests if not t.get("ac")]
    if other:
        body.append("<h2>Other captures</h2>")
        for t in other:
            body.append(f'<section class="ac"><h3>{E(t["title"])}</h3>{media_html(edir, pdir, [t])}</section>')
    findings = info.get("findings") or []
    body.append("<h2>Advisory findings</h2>")
    if findings:
        body.append("<table><tr><th>Finding</th><th>Where</th><th>Problem</th><th>Suggested fix</th></tr>")
        for f_ in findings:
            fid = " · ".join(str(x) for x in (f_.get("id"), f_.get("lens") or f_.get("rubric"), f_.get("severity")) if x)
            body.append(f'<tr><td>{E(fid)}</td><td><code>{E(str(f_.get("where", "")))}</code></td>'
                        f'<td>{E(str(f_.get("problem", "")))}</td><td>{E(str(f_.get("fix", "")))}</td></tr>')
        body.append("</table>")
    else:
        body.append('<p class="meta">None.</p>')
    spend = info.get("spend") or {}
    stages = spend.get("by_stage") or {}
    if stages:
        body.append("<h2>Spend by stage (estimate)</h2><table><tr><th>Stage</th><th>USD</th></tr>")
        for k in sorted(stages, key=lambda s: str(s)):
            body.append(f"<tr><td>{E(str(k))}</td><td>${float(stages[k] or 0):.2f}</td></tr>")
        body.append("</table>")
    page = ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            f"<title>Review pack · {E(info.get('slug', ''))}</title><style>{CSS}</style></head>"
            f"<body><main>{''.join(body)}</main></body></html>\n")
    with open(os.path.join(pdir, "index.html"), "w", encoding="utf-8") as f:
        f.write(page)
    print(os.path.join(pdir, "index.html"))
    return 0


def main(argv):
    if len(argv) == 6 and argv[1] == "manifest":
        return cmd_manifest(argv[2], argv[3], argv[4], argv[5])
    if len(argv) == 6 and argv[1] == "pack":
        return cmd_pack(argv[2], argv[3], argv[4], argv[5])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
