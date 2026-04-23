# .workflow/

This directory holds the workflow configs for AI agents — a single source
of truth about the project: stack, architecture, conventions, and rules
for how the agent works.

## Contents

| File | Purpose |
|------|---------|
| `stack.yml` | Languages, frameworks, databases, infrastructure, run commands |
| `architecture.yml` | Style, layers, modules, dependency rules |
| `conventions.yml` | Code style, naming, tests, commits |
| `workflow.yml` | Rules for the agent itself: stages, light TDD, granular commits, history, blocking |
| `bootstrap.md` | Initialization procedure; read only when pre-flight fails or `/init-workflow` is requested |
| `state.yml` | Installed workflow reference and applied migration IDs |
| `history/` | Local task history (in `.gitignore`) |
| `backups/` | Local one-file backups created before workflow updates |

## Rules

1. **Without filled-in configs the agent does not work.** If the required
   fields (`workflow.yml → blocking.required_non_empty_fields`) are empty,
   the agent must stop, read `.workflow/bootstrap.md`, and run the
   initialization procedure described there.

2. **Every task → an entry in `history/`.** A file
   `history/YYYY-MM-DD-<slug>.md` is created with sections
   analysis / options / plan / result and, for large tasks,
   checkpoint checklist, plus an event in
   `history/events.jsonl`.

3. **Task format**: Analyze → Options (≥2 with pros/cons) → Plan → Execute.
   The plan must be self-contained — runnable in a new session without
   additional context.

4. **Light TDD for behavior changes.** `workflow.yml → process.light_tdd`
   controls the rule. The default is `strict-lite`: for a non-trivial
   behavior change, prefer a focused test first, then the minimum code to make
   it pass. Trivial/docs/config/mechanical edits may skip it.

5. **Granular commits for large tasks.** `workflow.yml → process.granular_commits`
   controls whether large tasks are split into verified checkpoints with
   intermediate commits. The default is enabled, but initialization must still
   ask the developer to confirm it and choose whether commits happen
   automatically or only after a prompt.

6. **Edits to the configs** are made deliberately: after a change the
   agent must verify that the project's current code still matches them
   and report any discrepancies.

7. **Workflow updates are conservative.** The updater runs ordered
   migrations for known managed paths, preserves unknown/custom keys,
   and creates one backup per changed file in `backups/`.

## Commit presets

During initialization the agent offers a named commit preset
(`conventional`, `gitmoji`, `emoji-prefix`, `free-form`, or `custom`) and
asks for the commit message language separately — any language works with
any preset. Full definitions and examples live in `.workflow/bootstrap.md`.

## Initialization

- New project: ask the agent to "initialize the workflow" — it will ask
  questions and fill out the YAML, including confirmation of the light TDD
  mode and granular commit settings.
- Existing project: ask it to "analyze the project and fill out
  `.workflow/`" — the agent will work through the manifests, structure,
  and linters and propose values.

See `AGENTS.md` in the project root for the normal task workflow and
`.workflow/bootstrap.md` for initialization details.
