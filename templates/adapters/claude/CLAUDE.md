# CLAUDE.md

This project uses **`AGENTS.md`** (in the project root) as the single
source of truth for all AI agents. Read it in full before doing any work.

For pre-flight, read only:

- `.workflow/status.yml` — fast initialization check and resolved feature flags

If `status.yml → initialized` is not `true`, `active_preset` is `null`, or
any `checks.*` value is not `true` — **do not start work**. Run
`/init-workflow` or perform/refresh the procedure from `.workflow/bootstrap.md`.

Which stages are mandatory depends on the resolved feature flags in
`status.yml → features`. Lazy-load `.workflow/*.yml` only when the task needs
stack, architecture, conventions, full workflow rules, or preset definitions.

For large tasks, check whether `status.yml → features.granular_commits`
requires a checkpoint checklist and intermediate commits in `.workflow/history/`.

Slash commands for convenience:

- `/init-workflow` — initialize or complete `.workflow/*.yml`
- `/analyze` — analyze a task (stage 3.1 from `AGENTS.md`)
- `/plan` — produce a plan (stage 3.3)
- `/harness` — start or manage a long-running job in another configured CLI harness

When `.workflow/status.yml → orchestration.enabled` is true, prefer the
project-local `.workflow/bin/hekate-agent` controller over ad-hoc nested CLI
commands. Claude may use the `harness-orchestrator` custom subagent for this.
