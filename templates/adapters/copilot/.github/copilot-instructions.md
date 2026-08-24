# GitHub Copilot instructions

This project uses **`AGENTS.md`** (in the project root) as the single
source of truth for all AI agents. Read it in full before doing any work.

For pre-flight, read only:

- `.workflow/status.yml` — fast initialization check and resolved feature flags

If `status.yml → initialized` is not `true`, `active_preset` is `null`, or
any `checks.*` value is not `true` — **do not start work**. Perform (or
refresh) the Bootstrap procedure from `.workflow/bootstrap.md`.

Which stages are mandatory depends on the resolved feature flags in
`status.yml → features`. Lazy-load `.workflow/*.yml` only when the task needs
stack, architecture, conventions, full workflow rules, or preset definitions.

For large tasks, check whether `status.yml → features.granular_commits`
requires a checkpoint checklist and intermediate commits in `.workflow/history/`.

Don't do unrequested refactors, don't add dependencies without discussion,
and perform destructive actions only with explicit confirmation.
