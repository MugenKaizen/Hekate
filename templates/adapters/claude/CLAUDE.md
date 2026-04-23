# CLAUDE.md

This project uses **`AGENTS.md`** (in the project root) as the single
source of truth for all AI agents. Read it in full before doing any work.

Also read the configs in `.workflow/`:

- `.workflow/stack.yml`
- `.workflow/architecture.yml`
- `.workflow/conventions.yml`
- `.workflow/workflow.yml`
- `.workflow/presets.yml` — active workflow preset + feature registry

If the required fields in these files are not filled in, or
`presets.yml → meta.active_preset` is `null` — **do not start work**. Run
`/init-workflow` or perform the *Bootstrap* procedure from `AGENTS.md`.

Which stages are mandatory depends on the active preset. Respect the
feature flags in `workflow.yml` (they mirror `presets.yml`).

For large tasks, check whether `workflow.yml → process.granular_commits`
requires a checkpoint checklist and intermediate commits in `.workflow/history/`.

Slash commands for convenience:

- `/init-workflow` — initialize or complete `.workflow/*.yml`
- `/analyze` — analyze a task (stage 3.1 from `AGENTS.md`)
- `/plan` — produce a plan (stage 3.3)
