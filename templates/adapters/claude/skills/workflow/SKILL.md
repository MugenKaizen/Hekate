---
name: workflow
description: This project's workflow — fast pre-flight via .workflow/status.yml, lazy-loaded .workflow/*.yml configs, the Analyze→Options→Plan→Execute→Verify stages, light TDD for non-trivial behavior changes, and maintaining .workflow/history/. Triggers — any code-change task, requests like "initialize the workflow", "analyze the task", "produce a plan", or when the project contains AGENTS.md + .workflow/.
---

# workflow

This skill activates for any work in a project that has `AGENTS.md` and
a `.workflow/` directory.

## What to do

1. **Pre-flight.** Read `AGENTS.md` and `.workflow/status.yml` only. If
   `initialized` is not `true`, `active_preset` is `null`, or any `checks.*`
   value is not `true`, stop and run `/init-workflow`. During Bootstrap, pick
   the commit style via the preset procedure in `.workflow/bootstrap.md`, ask
   for the commit message language separately, and update `.workflow/status.yml`.

   Do not read every `.workflow/*.yml` at startup. Lazy-load detailed configs
   only when the current task needs stack, architecture, conventions, full
   workflow rules, or preset definitions.

2. **Task cycle.** Follow the cycle from section 3 of `AGENTS.md`:
     - 3.1 Analyze — read the affected files, record constraints.
     - 3.2 Options — ≥2 options with pros/cons, choose with the user.
     - 3.3 Plan — in `.workflow/history/YYYY-MM-DD-<slug>.md`, self-contained.
     - 3.4 Execute — follow the plan, nothing extra. For non-trivial behavior
        changes, apply `status.yml → features.light_tdd` (`strict-lite` by
        default unless the project says otherwise). If
        `status.yml → features.granular_commits` applies, work checkpoint by
        checkpoint and commit according to its mode.
     - 3.5 Verify — run the checks, update `result` and `events.jsonl`.

3. **History.** Each task = one markdown in `.workflow/history/` plus
    events in `events.jsonl`. Large tasks also keep a checkpoint checklist in
    the same markdown file. The format is in section 4 of `AGENTS.md`.

4. **Scope control.** Don't do unrequested refactors, don't add
   dependencies without discussion, and perform destructive actions only
   with explicit confirmation.

## Memory anchors

- Source of truth — `AGENTS.md` in the project root.
- Fast pre-flight — `.workflow/status.yml`.
- Lazy configs — `.workflow/{stack,architecture,conventions,workflow,presets}.yml`.
- History — `.workflow/history/` (in `.gitignore`).
