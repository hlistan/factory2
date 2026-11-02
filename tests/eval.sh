#!/usr/bin/env bash
# Runs factory's eval cases (plugins/factory2/evals) with `claude plugin eval`. `plugin eval` loads only
# the plugin under test, and factory doesn't load its agents while its compound-engineering dependency is
# missing, so this runs a temporary copy with `dependencies` removed. None of the evaluated agents uses
# compound-engineering (they all have disallowedTools: Skill). Results go to plugins/factory2/evals/results/.
# Usage: bash tests/eval.sh [claude plugin eval options...]   e.g. --case 'prd-*' --runs 1 --max-cost-usd 2
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/factory-eval.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cp -R "$REPO/plugins/factory2" "$tmp/factory"
rm -rf "$tmp/factory/evals/results"
jq 'del(.dependencies)' "$REPO/plugins/factory2/.claude-plugin/plugin.json" > "$tmp/factory/.claude-plugin/plugin.json"
out="$REPO/plugins/factory2/evals/results/$(date -u +%Y-%m-%dT%H-%M-%SZ)"
mkdir -p "$out"
claude plugin eval "$tmp/factory" --trust-plugin --no-publish --output-dir "$out" --report "$out/report.html" "$@"
code=$?
echo "results: $out"
exit "$code"
