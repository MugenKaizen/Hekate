---
name: workflow
description: This project's workflow — pre-flight check of .workflow/*.yml configs, the Analyze→Options→Plan→Execute→Verify stages, light TDD for non-trivial behavior changes, and maintaining .workflow/history/. Triggers — any code-change task, requests like "initialize the workflow", "analyze the task", "produce a plan", or when the project contains AGENTS.md + .workflow/.
---

# workflow

This skill activates for any work in a project that has `AGENTS.md` and
a `.workflow/` directory.

## What to do

1. **Pre-flight.** Read `AGENTS.md` and every `.workflow/*.yml`. Check
   the required fields (the list is in
   `workflow.yml → blocking.required_non_empty_fields`). If any is empty,
   stop and run `/init-workflow`. During Bootstrap, pick the commit style
   via the preset procedure in `AGENTS.md` §2.5, and ask for the commit
   message language separately.

2. **Task cycle.** Follow the cycle from section 3 of `AGENTS.md`:
     - 3.1 Analyze — read the affected files, record constraints.
     - 3.2 Options — ≥2 options with pros/cons, choose with the user.
     - 3.3 Plan — in `.workflow/history/YYYY-MM-DD-<slug>.md`, self-contained.
     - 3.4 Execute — follow the plan, nothing extra. For non-trivial behavior
       changes, apply `workflow.yml → process.light_tdd` (`strict-lite` by
       default unless the project says otherwise). If
       `workflow.yml → process.granular_commits` applies, work checkpoint by
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
- Configs — `.workflow/{stack,architecture,conventions,workflow}.yml`.
- History — `.workflow/history/` (in `.gitignore`).
