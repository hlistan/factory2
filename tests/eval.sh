#!/usr/bin/env bash
# Runs factory's eval cases (plugins/factory2/evals) with `claude plugin eval`, on a temporary copy of the
# plugin without earlier results. Results go to plugins/factory2/evals/results/.
# Usage: bash tests/eval.sh [claude plugin eval options...]   e.g. --case 'prd-*' --runs 1 --max-cost-usd 2
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/factory-eval.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cp -R "$REPO/plugins/factory2" "$tmp/factory"
rm -rf "$tmp/factory/evals/results"
out="$REPO/plugins/factory2/evals/results/$(date -u +%Y-%m-%dT%H-%M-%SZ)"
mkdir -p "$out"
claude plugin eval "$tmp/factory" --trust-plugin --no-publish --output-dir "$out" --report "$out/report.html" "$@"
code=$?
echo "results: $out"
exit "$code"
