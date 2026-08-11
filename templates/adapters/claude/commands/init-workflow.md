---
description: Initialize or complete .workflow/*.yml for this project
---

Perform the **Bootstrap** procedure from `.workflow/bootstrap.md`.

In short:

1. Read `.workflow/presets.yml` to load the preset definitions and the
   feature registry. This file is the source of truth for *which* process
   features exist and *how* each preset configures them.
2. **Ask the user which workflow preset to use**. Show the
   `label` and `description` of each preset verbatim:
   - `fast` — plan-only, no options / no TDD / no granular commits.
   - `medium` — balanced (options + granular commits, no TDD). **Recommend
     this as the default.**
   - `full` — everything on, including light TDD (strict-lite).
   - `custom` — iterate `presets.yml → features:` and ask each feature's
     `question` one by one.
3. Apply the chosen preset (or custom answers) to `.workflow/workflow.yml`
   by writing to the paths listed in each feature's `controls:`. For
   features disabled by the chosen preset, **do not** ask further questions
   about them later in the interview. For features with a `when_enabled_mode`,
   use that value whenever the feature is enabled.
4. Configure optional cross-harness delegation from
   `.workflow/orchestration.yml`: ask whether to enable it and, only when
   enabled, choose the default installed harness/model/effort. Run
   `.workflow/bin/hekate-agent doctor`; no MCP server is involved.
5. Determine whether this is a new or an existing project.
6. For an existing project, analyze dependency manifests, linter configs,
   directory structure, CI, Dockerfile, README, and commit history.
7. Fill out drafts of `.workflow/stack.yml`, `.workflow/architecture.yml`,
   and `.workflow/conventions.yml`. Leave fields empty when there is not
   enough evidence and mark them with `# TODO: confirm`.
8. For `conventions.yml → commits`, run the **Commit convention preset**
   procedure from `.workflow/bootstrap.md`: show the four named presets
   (`conventional`, `gitmoji`, `emoji-prefix`, `free-form`) plus `custom`;
   recommend one based on `git log --oneline -n 100` if there is a clear
   match, otherwise recommend `conventional`; then ask a separate question
   about the commit message language and write the answer into
   `commits.language` verbatim.
9. Show the user one file at a time and wait for confirmation.
10. Write `meta.active_preset` to `.workflow/presets.yml` and mirror it to
    `.workflow/workflow.yml → meta.preset`.
11. Write `.workflow/status.yml` with `initialized: true`, the active preset,
    required-check booleans, resolved feature flags, and orchestration summary.
12. After writing all YAML files, create
     `.workflow/history/<date>-bootstrap.md` with the chosen preset, the
     resolved feature map, and any assumptions.
13. Make sure `.workflow/history/`, `.workflow/runs/`, and
    `.workflow/orchestration.local.yml` are in `.gitignore`.

Do not start any other work until the required fields from
`workflow.yml → blocking.required_non_empty_fields` are filled in and
`presets.yml → meta.active_preset` is not `null`.

**Note for future features.** Do **not** hardcode feature questions in this
file. The procedure above iterates `.workflow/presets.yml → features:`. To
add a new customizable step, append an entry there (see `.workflow/bootstrap.md`).
