#!/usr/bin/env bash
# Static checks of the plugin's agents and skills, and the learnings-researcher port:
# - every agent disallows the Skill tool; no memory frontmatter, and memory-inject skips the right agents; preloaded skills exist and are
#   preloadable (user-invocable: false, never disable-model-invocation: true)
# - the bundled ce-compound and ce-compound-refresh are byte-identical to the release pinned in
#   vendor/compound-engineering/upstream.json (every file's blob hash, no file added or missing), and the
#   ported learnings-researcher body hashes to the blob recorded there; with FACTORY_TEST_ONLINE=1, the
#   latest upstream release is compared and drift is reported (not failed)
# - factory2 declares no plugin dependencies
. "$(dirname "$0")/lib.sh"
A="$PLUGIN/agents"; K="$PLUGIN/skills"
fm() { awk 'NR==1 && $0=="---"{f=1; next} f && $0=="---"{exit} f' "$1"; }  # frontmatter of a file
field() { fm "$1" | sed -n "s/^$2: *//p" | head -n1; }

no_memory="learnings-researcher challenger researcher"
for f in "$A"/*.md; do
  a="$(basename "$f" .md)"
  t_eq "$(field "$f" name)" "$a" "$a: name matches the file"
  t_eq "$(field "$f" disallowedTools)" "Skill" "$a: disallowedTools Skill"
  case "$a" in   # the user's per-agent choice (docs/PRD.md, "plugin name and per-agent models")
    learnings-researcher) want="opus high" ;;
    researcher)           want="sonnet high" ;;
    reviewer-security)    want="fable high" ;;
    implementer)          want="opus low" ;;
    *)                    want="opus medium" ;;
  esac
  t_eq "$(field "$f" model) $(field "$f" effort)" "$want" "$a: model and effort"
  # memory is loaded by the SubagentStart hook (memory-inject.sh), never by the frontmatter: `memory:`
  # does nothing with auto memory off, and it gives every agent Write and Edit
  t_eq "$(field "$f" memory)" "" "$a: no memory frontmatter"
  case " $no_memory " in
    *" $a "*) t_hasnt "$(cat "$f")" "MEMORY.md" "$a: no memory, and its prompt doesn't mention one" ;;
    *) t_has "$(tr -s "\n " "  " < "$f")" "reference material, not rules" "$a: prompt treats memory as reference, not rules" ;;
  esac
  for s in $(fm "$f" | awk '/^skills:/{f=1; next} f && /^  - /{print $2; next} f{exit}'); do
    [ "$s" = "playwright-cli" ] && continue   # installed into the project by /factory2:init
    if [ -f "$K/$s/SKILL.md" ]; then t_ok; else t_fail "$a preloads missing skill $s"; fi
    t_eq "$(field "$K/$s/SKILL.md" user-invocable)" "false" "$s: preloaded skill is user-invocable: false"
    t_hasnt "$(fm "$K/$s/SKILL.md")" "disable-model-invocation: true" "$s: preloadable"
  done
done
t_eq "$(ls "$A" | wc -l | tr -d ' ')" "14" "14 agents"
t_has "$(grep -o 'learnings-researcher|challenger|researcher' "$S/memory-inject.sh")" "learnings-researcher|challenger|researcher" "memory-inject skips the agents without memory"
t_eq "$(jq -r '.hooks.SubagentStart[0].matcher' "$PLUGIN/hooks/hooks.json")" "^factory2:" "SubagentStart hook loads memory for factory agents"
for s in run init status stats monitor; do
  t_eq "$(field "$K/$s/SKILL.md" name)" "$s" "skill $s exists"
done
for r in stages-1-3 stage-4 stage-5 stage-6 stages-7-8 learning; do
  [ -f "$K/run/references/$r.md" ] && t_ok || t_fail "run reference $r.md missing"
  t_has "$(cat "$K/run/SKILL.md")" "references/$r.md" "run SKILL.md links $r.md"
done
# every script a skill calls exists (or is a known later-milestone script)
later="evidence.sh ship.sh monitor.sh stats.sh"
for s in $(grep -ho '\$S/[a-z-]*\.sh' "$K"/*/SKILL.md "$K"/run/references/*.md | sort -u | sed 's#\$S/##'); do
  case " $later " in *" $s "*) continue ;; esac
  [ -f "$S/$s" ] && t_ok || t_fail "skills call missing script $s"
done

# --- the learnings-researcher port
M='<!-- PORTED-TEXT: everything below this line is the upstream file, unchanged -->'
f="$A/learnings-researcher.md"
t_eq "$(grep -c -x -F "$M" "$f")" "1" "port marker present once"
body_sha="$(awk -v m="$M" 'f{print} $0==m{f=1}' "$f" | git hash-object --stdin)"
U="$PLUGIN/vendor/compound-engineering/upstream.json"
t_eq "$body_sha" "$(jq -r '.ported["agents/learnings-researcher.md"].blob' "$U")" "ported body is the pinned upstream blob"
t_eq "$body_sha" "ab60b70641cf6fe395048b511bb96fd3d893663e" "learnings-researcher pin unchanged (f2762dd)"

# --- the bundled compound-engineering skills
[ -f "$PLUGIN/vendor/compound-engineering/LICENSE" ] && t_ok || t_fail "compound-engineering LICENSE is bundled"
for s in $(jq -r '.skills | keys[]' "$U"); do
  want="$(jq -r --arg s "$s" '.skills[$s].files | to_entries[] | "\(.key) \(.value)"' "$U" | sort)"
  have="$(cd "$K/$s" && find . -type f | sed 's#^\./##' | sort | while read -r f; do printf '%s %s\n' "$f" "$(git hash-object "$f")"; done)"
  t_eq "$have" "$want" "$s is byte-identical to $(jq -r .tag "$U")"
  t_eq "$(field "$K/$s/SKILL.md" name)" "$s" "bundled skill $s keeps its upstream name"
done
t_eq "$(jq -r '.skills | keys | join(" ")' "$U")" "ce-compound ce-compound-refresh" "bundles exactly ce-compound and ce-compound-refresh"
t_eq "$(jq -r '.dependencies // [] | length' "$PLUGIN/.claude-plugin/plugin.json")" "0" "factory2 declares no plugin dependencies"
t_eq "$(jq -r 'has("allowCrossMarketplaceDependenciesOn")' "$REPO/.claude-plugin/marketplace.json")" "false" "marketplace allows no cross-marketplace dependencies"
t_hasnt "$(cat "$K"/run/SKILL.md "$K"/run/references/*.md "$K"/init/SKILL.md)" "compound-engineering:" "skills call the bundled ce-compound, never compound-engineering:"
if [ "${FACTORY_TEST_ONLINE:-0}" = "1" ] && command -v gh >/dev/null; then
  rel="$(gh api 'repos/EveryInc/compound-engineering-plugin/releases/latest' --jq .tag_name 2>/dev/null)"
  if [ -z "$rel" ]; then echo "  NOTE compound-engineering: couldn't read the latest release"
  elif [ "$rel" = "$(jq -r .tag "$U")" ]; then echo "  compound-engineering: the pin is the latest release ($rel)"
  else
    for s in $(jq -r '.skills | keys[]' "$U"); do
      t="$(gh api "repos/EveryInc/compound-engineering-plugin/contents/skills?ref=$rel" --jq ".[] | select(.name == \"$s\") | .sha" 2>/dev/null)"
      [ "$t" = "$(jq -r --arg s "$s" '.skills[$s].tree' "$U")" ] || echo "  DRIFT $s: changed in $rel (pinned $(jq -r .tag "$U")); read the diff, then tools/vendor-ce.sh $rel"
    done
    lr="$(gh api "repos/EveryInc/compound-engineering-plugin/contents/skills/ce-plan/references/agents/learnings-researcher.md?ref=$rel" --jq .sha 2>/dev/null)"
    [ "$lr" = "$body_sha" ] || echo "  DRIFT learnings-researcher: changed in $rel (blob ${lr:-missing}); review and re-port"
  fi
fi
t_eq "$(fm "$PLUGIN/skills/run/SKILL.md" | sed -n 's/^effort: *//p')" "medium" "orchestrator runs at medium"
t_eq "$(jq -r .name "$PLUGIN/.claude-plugin/plugin.json")" "factory2" "plugin is named factory2"
t_done
