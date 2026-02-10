# AGENTS.md

Project-specific instructions for Codex agents live here.

## Working Agreement
- Keep changes small and focused.
- Run tests relevant to changed code by default.
- Install or update dependencies when required by implementation; report dependency changes in the summary.
- Ask before running long-running or potentially destructive commands.
- Prefer `rg` for file/content search.
- Keep responses concise and actionable.
- Aim for ~500 lines per file; split when it exceeds unless there’s a good reason.

## Standard Local Branch + CI Workflow
Use this workflow for all code-change tasks unless the user explicitly asks for a different process.

1. Work in the current local checkout (no worktrees by default).
2. Create/switch to a dedicated branch per task: `git checkout -b codex/<task>` (or `git checkout codex/<task>` if it exists).
3. Confirm branch and cleanliness with `git status`.
4. Make only task-scoped changes and keep diffs focused.
5. Run relevant local checks before each push (tests/lint/build for changed code).
6. Commit in small, clear increments: `git add -A && git commit -m "<message>"`.
7. Push early so CI starts: `git push -u origin <branch>` (or `git push` if upstream exists).
8. Open (or update) a PR immediately, preferably Draft first.
9. Ensure required CI checks run and monitor results on each push.
10. If CI fails, fix on the same branch, rerun local checks, then push again.
11. Request and address review feedback until approvals are complete.
12. Sync with latest target branch if required by policy (rebase or merge), rerun checks, and push updates.
13. Merge only after required checks pass and required approvals are satisfied.
