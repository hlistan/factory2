---
name: issue-flow
description: Track features on GitHub with one issue each as the only source of truth - issue statuses todo, planning, building, testing, documenting, done (closed), plus blocked; PRs building or blocked; requests for a person as issue comments naming the PR. Use to set up the labels in a repository, move an issue or PR through the flow, ask a person for something on the issue, or list what waits for someone.
argument-hint: "[setup | show <issue> | start <issue> <pr> | status <pr> <status> | block <pr> | unblock <pr> | merged <pr> | stop <pr>]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/issue-flow.sh *) Bash(gh issue list *) Bash(gh pr list *) Bash(gh issue view *) Bash(gh pr view *) Read
---

# Issue flow

`F=${CLAUDE_PLUGIN_ROOT}/scripts/issue-flow.sh`. Run `bash $F <command>` from the repository; gh's
repository (or `GH_REPO`) is the one changed. Arguments: `$ARGUMENTS` (none: `show` what is open, below).

## The schema
The **issue** says *what* is built, and is the only source of truth for it. It carries exactly one status:

| Status | Meaning | Set by |
|---|---|---|
| `todo` | Wanted and ready to be built | a person (monitoring, for an incident) |
| `planning` | What will be built and how: the PRD, criteria and plan, and their approval | the flow |
| `building` | Tests first, then the code | the flow |
| `testing` | Review, QA and fixes | the flow |
| `documenting` | Docs, then the evidence for the final approval, then the merge | the flow |
| closed | **Done**: every pull request for it is merged | the flow |

plus `blocked` while any of its pull requests waits for a person. An issue nobody labelled is a backlog idea.

A **pull request** says *how*. It contributes to exactly one issue, named at the top of its body
(`<!-- issue-flow:issue=<n> status=<status> -->` and `Part of #<n>`, never `Fixes`: the issue closes only
when its last pull request merges). It carries `building` while in progress (and is a draft), or
`blocked` while a person must act. A merged pull request carries neither.

With several open pull requests, the issue shows the earliest status among them, and `blocked` while
any of them is blocked.

## Asking a person
Everything a person must do is a comment **on the issue** that names the pull request, so the issue's
page and notifications are the one place to look. `bash $F block <pr>` takes the comment on stdin, marks
both blocked and posts it. The details (the plan, the evidence) stay on the pull request; the comment
links them and says exactly what to reply, with examples:

```markdown
### 🛑 Blocked: PR #93 needs your approval of the plan
**Open [PR #93](<link to the comment with the plan>)** to read what will be built and how.

#### What to do
Reply on this issue (or on PR #93) with one of:
- **Approve**: a comment whose first line is `/approve`
- **Ask for changes**, one per line, naming the criterion: `AC-7: an empty list says "Nothing to review".`
```

When the person has answered, `bash $F unblock <pr>`.

## Commands
- `setup`: creates the six labels in the repository (safe to repeat).
- `start <issue> <pr> [status]`: the pull request works on the issue; it is `building`, the issue
  `planning` (or the status given).
- `status <pr> <planning|building|testing|documenting>`: the pull request's work moved on, or back.
- `block <pr>` (comment on stdin), `unblock <pr>`.
- `merged <pr>`: after the merge; closes the issue when it was the last open pull request.
- `stop <pr>`: the work stopped unmerged; closes the pull request, and the issue is `todo` again
  unless other pull requests work on it.
- `show <issue>`, `issue <pr>`.

Never set these labels by hand (`gh issue edit --add-label`): the flow recomputes them from the pull
requests, and factory's guard blocks it during a run.

## What waits, what moves
- Waiting for a person: `gh issue list --label blocked` (and `gh pr list --label blocked`).
- Ready to start: `gh issue list --label todo`.
- In progress: `gh issue list --label planning` (`building`, `testing`, `documenting`).
- With no arguments, show these three lists, one line per issue.

In a factory run, `/factory2:run` does all of this itself: `pr.sh open` creates the issue when the run
has none and calls `start`; `state.sh stage` sets the status (stages 1-3 planning, 4 building,
5 testing, 6-7 documenting); `pr.sh request-approval` and `pr.sh ask` block; their replies unblock;
`ship.sh merge` calls `merged`; `state.sh end --stop` calls `stop`.
