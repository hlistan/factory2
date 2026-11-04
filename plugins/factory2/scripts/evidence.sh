#!/usr/bin/env bash
# factory stage 6: capture the evidence and build the review pack.
#   evidence.sh capture [--ac <AC-n>]   runs the demo and writes <run>/evidence/ with manifest.json.
#       evidence.driver playwright (default): `evidence.playwright` (default `npx playwright test -c
#         playwright.demo.config.ts`) with --grep '@AC-<n>\b' for every criterion in contract.json (or
#         the one --ac names). The demo config records a video and screenshots per test, one project per
#         evidence.viewports size, and writes results.json (JSON reporter) into $FACTORY_EVIDENCE.
#         Failing tests still leave evidence; capture fails only when nothing was recorded.
#       evidence.driver command: runs `evidence.capture`, which writes screenshots or recordings into
#         $FACTORY_EVIDENCE; a file whose path names AC-n (or AC_n) is shown under that criterion.
#       evidence.driver none: no media; the pack shows test results only.
#     WebM videos are converted to H.264 mp4 when ffmpeg is installed (the WebM is kept otherwise).
#     Environment for the commands: FACTORY_EVIDENCE, FACTORY_VIEWPORTS (e.g. 1440x900,390x844),
#     FACTORY_PORT (and PORT when unset), CI=true; they run from the project root.
#   evidence.sh pack [--findings <json>]  builds <run>/review-pack/index.html from the manifest,
#       contract.json (criteria and passes), the advisory findings (default <run>/advisory.json: a list,
#       or {findings: [...]}), spend and the PR link; media are copied in, so the folder is
#       self-contained. When evidence.publish is set it runs with FACTORY_PACK=<pack dir> and its last
#       output line is the pack's URL. Prints `pack: <path>` and `url: <url>` (when published).
# Exit status: 0 ok, 1 nothing captured or a command failed, 2 usage or config error.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_need git jq python3

root="$FACTORY_ROOT_DIR"
cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in ''|-h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;; esac
slug="$(factory_active_slug)"
[ -n "$slug" ] || { echo "factory: no active run in this checkout" >&2; exit 1; }
run="$root/.factory/runs/$slug"
spec="$root/docs/specs/$slug"
edir="$run/evidence"
pdir="$run/review-pack"
factory_config_json >/dev/null || { echo "factory: .factory/config.yaml doesn't parse" >&2; exit 2; }

viewports() { factory_config_json | jq -r '(.evidence.viewports // ["1440x900","768x1024","390x844"]) | if type == "array" then map(tostring) | join(",") else tostring end'; }

to_mp4() { # converts every WebM under the evidence dir when ffmpeg is available
  local n=0 w
  factory_has ffmpeg || { echo "factory: ffmpeg not installed; videos stay WebM" >&2; return 0; }
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    if ffmpeg -nostdin -loglevel error -y -i "$w" -c:v libx264 -pix_fmt yuv420p -movflags +faststart "${w%.webm}.mp4" </dev/null; then
      n=$((n + 1))
    else
      rm -f "${w%.webm}.mp4"; echo "factory: ffmpeg couldn't convert $w; keeping the WebM" >&2
    fi
  done < <(find "$edir" -type f -name '*.webm' 2>/dev/null)
  [ "$n" -gt 0 ] && echo "factory: converted $n video(s) to mp4"
  return 0
}

case "$cmd" in
  capture)
    ac=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --ac) ac="${2:-}"; shift 2 ;;
        *) echo "factory: capture [--ac AC-<n>]" >&2; exit 2 ;;
      esac
    done
    if [ -n "$ac" ]; then
      printf '%s' "$ac" | grep -Eq '^AC-[0-9]+$' || { echo "factory: --ac takes a criterion id like AC-3" >&2; exit 2; }
    fi
    driver="$(cfg '.evidence.driver' playwright)"
    rm -rf "$edir"; mkdir -p "$edir"
    port="$(state_get '.port // empty')"
    export CI=true FACTORY_EVIDENCE="$edir" FACTORY_VIEWPORTS="$(viewports)"
    if [ -n "$port" ]; then export FACTORY_PORT="$port"; [ -n "${PORT:-}" ] || export PORT="$port"; fi
    code=0
    case "$driver" in
      playwright)
        pw="$(cfg '.evidence.playwright' 'npx playwright test -c playwright.demo.config.ts')"
        case "$pw" in *playwright.demo.config.ts*) [ -f "$root/playwright.demo.config.ts" ] || {
          echo "factory: playwright.demo.config.ts is missing in the project root; /factory2:init copies it from the plugin's templates" >&2; exit 2; } ;; esac
        if [ -n "$ac" ]; then grep="@${ac}\\b"
        else
          ids="$(jq -r '[.criteria // [] | .[] | .id | select(test("^AC-[0-9]+$")) | sub("^AC-"; "")] | join("|")' "$spec/contract.json" 2>/dev/null)"
          [ -n "$ids" ] || { echo "factory: no criteria in $spec/contract.json" >&2; exit 2; }
          grep="@AC-(${ids})\\b"
        fi
        echo "factory: capturing: $pw --grep '$grep'"
        (cd "$root" && bash -c "$pw --grep '$grep'" </dev/null) > "$edir/run.log" 2>&1 || code=$?
        tail -n 15 "$edir/run.log"
        ;;
      command)
        c="$(cfg '.evidence.capture')"
        [ -n "$c" ] || { echo "factory: evidence.driver is command but evidence.capture is empty" >&2; exit 2; }
        (cd "$root" && bash -c "$c" </dev/null) > "$edir/run.log" 2>&1 || code=$?
        tail -n 15 "$edir/run.log"
        [ "$code" = 0 ] || { echo "factory: evidence.capture exited $code" >&2; exit 1; }
        ;;
      none) : ;;
      *) echo "factory: evidence.driver must be playwright, command or none (got '$driver')" >&2; exit 2 ;;
    esac
    to_mp4
    factory_py "$FACTORY_LIB/evidence.py" manifest "$edir" "$driver" "$code" "$(git -C "$root" rev-parse HEAD 2>/dev/null)" || exit 1
    [ "$code" = 0 ] || echo "factory: the demo run exited $code: some criteria failed on camera; the pack shows which" >&2
    state_update '.evidence = {captured_at: $at, head: $h, driver: $d, exit: ($c | tonumber)}' \
      --arg at "$(now_utc)" --arg h "$(git -C "$root" rev-parse HEAD 2>/dev/null)" --arg d "$driver" --arg c "$code"
    ;;

  pack)
    findings="$run/advisory.json"
    while [ $# -gt 0 ]; do
      case "$1" in
        --findings) findings="${2:-}"; shift 2 ;;
        *) echo "factory: pack [--findings <json>]" >&2; exit 2 ;;
      esac
    done
    [ -f "$edir/manifest.json" ] || { echo "factory: no evidence yet; run evidence.sh capture first" >&2; exit 1; }
    [ -f "$spec/contract.json" ] || { echo "factory: no $spec/contract.json" >&2; exit 1; }
    f='[]'
    if [ -f "$findings" ]; then
      f="$(jq -c 'if type == "array" then . elif type == "object" then (.findings // []) else [] end' "$findings")" || { echo "factory: $findings isn't JSON" >&2; exit 2; }
    fi
    spend="$(bash "$FACTORY_SCRIPTS/state.sh" spend 2>/dev/null)"; [ -n "$spend" ] || spend='{}'
    info="$run/.pack-info.json"
    jq -n --arg slug "$slug" --arg pr "$(state_get '.pr_url // empty')" --arg head "$(git -C "$root" rev-parse HEAD 2>/dev/null)" \
      --argjson spend "$spend" --argjson findings "$f" --arg at "$(now_utc)" \
      '{slug: $slug, pr_url: $pr, head: $head, spend: $spend, findings: $findings, generated: $at}' > "$info"
    index="$(factory_py "$FACTORY_LIB/evidence.py" pack "$edir" "$pdir" "$spec/contract.json" "$info")" || exit 1
    echo "pack: $index"
    url=""
    pub="$(cfg '.evidence.publish')"
    if [ -n "$pub" ]; then
      out="$(cd "$root" && FACTORY_PACK="$pdir" bash -c "$pub" </dev/null)" || { echo "factory: evidence.publish failed" >&2; exit 1; }
      url="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1)"
      [ -n "$url" ] && echo "url: $url"
    fi
    state_update '.evidence.pack = $p | .evidence.url = (if $u == "" then null else $u end) | .evidence.packed_at = $at' \
      --arg p "$index" --arg u "$url" --arg at "$(now_utc)"
    ;;

  *) echo "factory: evidence.sh capture|pack" >&2; exit 2 ;;
esac
