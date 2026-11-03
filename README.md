# factory2 marketplace

A Claude Code plugin marketplace with one plugin, [`factory2`](plugins/factory2/README.md): an 8-stage
feature harness (plan → PRD review → fixes → test-first implementation → review → evidence → deploy →
monitor) with human gates and self-learning.

```sh
claude plugin marketplace add <this repo's git URL or local path>
claude plugin install factory2@factory2
```

factory2 has no plugin dependencies: it bundles the two compound-engineering skills it uses, pinned to
one release. Then run `/factory2:init` in each project.

## Layout

- `plugins/factory2/`: the plugin (agents, skills, hooks, scripts, templates, evals)
- `tests/`: bash tests for the scripts (`bash tests/run.sh`), plus live platform tests
- `tools/vendor-ce.sh`: updates the bundled compound-engineering skills to another release
- `docs/GUIDE.md`: **user guide**: how the harness works, step by step; monitoring; controlling results; self-learning
- `docs/PRD.md`: the design, its evidence and build status; `docs/solutions/`: lessons learned while
  building it

MIT licensed.
