#!/usr/bin/env bash
# Copies compound-engineering's ce-compound and ce-compound-refresh skills, unchanged, from one upstream
# release into plugins/factory2/skills/, and writes the manifest that tests/plugin.test.sh checks the copy
# against (plugins/factory2/vendor/compound-engineering/upstream.json: tag, commit, per-file blob hashes).
# Also checks that the ported learnings-researcher (agents/learnings-researcher.md) is still the file at
# that release; if not, it prints the upstream diff to review and re-port by hand.
#
# Re-vendoring is a deliberate upgrade: read the upstream diff between the pinned tag and the new one,
# run this, then run tests/run.sh and tests/live/ce-contract.sh, and record the change in docs/PRD.md.
#
# Usage: tools/vendor-ce.sh <release tag, e.g. compound-engineering-v3.34.0> [--src <upstream checkout>]
# Needs git and jq; clones https://github.com/EveryInc/compound-engineering-plugin unless --src is given.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$REPO/plugins/factory2"
URL="https://github.com/EveryInc/compound-engineering-plugin"
SKILLS="ce-compound ce-compound-refresh"
LR_PATH="skills/ce-plan/references/agents/learnings-researcher.md"
LR_MARK='<!-- PORTED-TEXT: everything below this line is the upstream file, unchanged -->'

tag="${1:-}"; [ -n "$tag" ] || { sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 2; }
src=""; [ "${2:-}" = "--src" ] && src="${3:-}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/vendor-ce.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
if [ -z "$src" ]; then
  git clone -q --filter=blob:none "$URL" "$tmp/up"; src="$tmp/up"
fi
g() { git -C "$src" "$@"; }
commit="$(g rev-list -n1 "$tag")" || { echo "vendor-ce: no tag $tag in $src" >&2; exit 2; }
version="$(g show "${commit}:.claude-plugin/plugin.json" | jq -r .version)"
date="$(g log -1 --format=%cs "$commit")"

for s in $SKILLS; do
  rm -rf "${PLUGIN:?}/skills/$s"
  mkdir -p "$PLUGIN/skills/$s"
  g archive "$commit" "skills/$s" | tar -x -C "$tmp"
  cp -R "$tmp/skills/$s/." "$PLUGIN/skills/$s/"
done
V="$PLUGIN/vendor/compound-engineering"; mkdir -p "$V"
g show "${commit}:LICENSE" > "$V/LICENSE"

skills_json="{}"
for s in $SKILLS; do
  tree="$(g rev-parse "${commit}:skills/$s")"
  files="$(g ls-tree -r "${commit}" "skills/$s" | awk -v p="skills/$s/" '{ sub(p, "", $4); print $4 "\t" $3 }' |
    jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): .[1]}) | add')"
  skills_json="$(jq --arg s "$s" --arg t "$tree" --argjson f "$files" '. + {($s): {tree: $t, files: $f}}' <<<"$skills_json")"
done
lr_blob="$(g rev-parse "${commit}:$LR_PATH")"
jq -n --arg url "$URL" --arg tag "$tag" --arg c "$commit" --arg v "$version" --arg d "$date" \
  --argjson skills "$skills_json" --arg lrp "$LR_PATH" --arg lrb "$lr_blob" '{
    upstream: $url, tag: $tag, commit: $c, version: $v, released: $d, license: "MIT, (c) Every, Inc. (LICENSE here)",
    note: "Copied unchanged by tools/vendor-ce.sh. Do not edit these skills; re-vendor instead.",
    skills: $skills, ported: {"agents/learnings-researcher.md": {path: $lrp, blob: $lrb}}
  }' > "$V/upstream.json"

local_lr="$(awk -v m="$LR_MARK" 'f{print} $0==m{f=1}' "$PLUGIN/agents/learnings-researcher.md" | git hash-object --stdin)"
echo "vendored compound-engineering $version ($tag, ${commit:0:10}, $date): $SKILLS"
if [ "$local_lr" = "$lr_blob" ]; then
  echo "learnings-researcher port matches $tag"
else
  echo "learnings-researcher port differs from $tag (local $local_lr, upstream $lr_blob); review and re-port:"
  echo "  git -C <checkout> show ${commit}:$LR_PATH"
fi
