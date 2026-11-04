#!/usr/bin/env bash
# factory measurements across runs: reads every .factory/history/*.json and prints markdown tables (spend
# by stage and agent, implementer first-pass rate by model and effort, rounds, escalations, incidents,
# escapes, issues people found, depth ablation, ce-compound outcomes, agent memory size).
#   stats.sh [--since YYYY-MM-DD] [--export-evals]
#   --export-evals  writes each QA false negative as a candidate eval case under .factory/eval-candidates/
# Read-only otherwise. Exit 0; 2 on bad arguments.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
factory_need python3
case "${1:-}" in -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 0 ;; esac
max="$(cfg '.learning.memory_max_lines' 150 2>/dev/null)"; case "$max" in ''|*[!0-9]*) max=150 ;; esac
factory_py "$FACTORY_LIB/stats.py" "$FACTORY_ROOT_DIR" "$max" "$@"
