# factory evals

Run with `claude plugin eval` from `plugins/factory2` (each case 3 runs by default, plus a no-plugin
baseline arm; set a budget):

```sh
claude plugin eval . --max-cost-usd 5            # all cases
claude plugin eval . --case 'prd-reviewer-*' --runs 1 --max-cost-usd 1
```

Run at each milestone and on every agent-prompt change. Planned seed cases: a PRD with no empty-state
criterion (prd-reviewer, here), a test that asserts nothing (test-reviewer), a diff with a planted auth
bypass (reviewer-security), an acceptance criterion the app fails (qa-evaluator), and a package.json
script edit that weakens the tests (the freeze). QA false negatives exported by `/factory2:stats
--export-evals` become new qa-evaluator cases.
