# CLAUDE.md

This project uses **`AGENTS.md`** (in the project root) as the single
source of truth for all AI agents. Read it in full before doing any work.

For pre-flight, read only:

- `.workflow/status.yml` — Hekate switch/module allowlist, fast initialization
  check, and resolved feature flags

Apply `status.yml → hekate` first. If `hekate.enabled` is false, do not apply
the remaining Hekate rules. Workflow, history, native subagents, and external
orchestration each run only when their `hekate.modules` value is true. Missing
module keys mean true for compatibility with older installations.

If the workflow module is enabled and `status.yml → initialized` is not `true`, `active_preset` is `null`, or
any `checks.*` value is not `true` — **do not start work**. Run
`/init-workflow` or perform/refresh the procedure from `.workflow/bootstrap.md`.

Which stages are mandatory depends on the resolved feature flags in
`status.yml → features`. Lazy-load `.workflow/*.yml` only when the task needs
stack, architecture, conventions, full workflow rules, or preset definitions.

For large tasks, check whether `status.yml → features.granular_commits`
requires a checkpoint checklist and intermediate commits in `.workflow/history/`.

When the native-subagents module is enabled, before using native Claude subagents, apply `AGENTS.md → Native-subagent session
policy` from `.workflow/session.local.yml`: `off`, `ask`, or `auto`. Missing or
invalid mode means `ask`; in `ask`, one user approval covers only the exact
proposed delegation wave.

Slash commands for convenience:

- `/init-workflow` — initialize or complete `.workflow/*.yml`
- `/analyze` — analyze a task (stage 3.1 from `AGENTS.md`)
- `/plan` — produce a plan (stage 3.3)
- `/harness` — start or manage a long-running job in another configured CLI harness

When both `.workflow/status.yml → hekate.modules.orchestration` and
`orchestration.enabled` are true, this user-facing
Claude session remains the primary harness and exclusively owns architecture,
decomposition, routing, subagent/harness orchestration, review, and final
verification. Prefer `.workflow/bin/hekate-agent` over ad-hoc nested CLI
commands. Delegated children are bounded executors/advisors and cannot
re-delegate. The `harness-orchestrator` custom agent may only monitor an
existing job ID already started by the primary session; it cannot start jobs or
select scope or routing.
