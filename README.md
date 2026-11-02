# factory marketplace

A Claude Code plugin marketplace with one plugin, [`factory`](plugins/factory/README.md): an 8-stage
feature harness (plan → PRD review → fixes → test-first implementation → review → evidence → deploy →
monitor) with human gates and self-learning.

```sh
claude plugin marketplace add <this repo's git URL or local path>
claude plugin install factory@factory
```

Installing factory also installs its dependency, compound-engineering, from the
`compound-engineering-plugin` marketplace (add it first with
`claude plugin marketplace add EveryInc/compound-engineering-plugin`). Then run `/factory:init` in each
project.

## Layout

- `plugins/factory/`: the plugin (agents, skills, hooks, scripts, templates, evals)
- `tests/`: bash tests for the scripts (`bash tests/run.sh`), plus live platform tests
- `docs/PRD.md`: the design and its evidence; `docs/history/`: earlier versions and reviews;
  `docs/solutions/`: lessons learned while building it

MIT licensed.
