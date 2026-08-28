---
name: workflow
description: This project's workflow — fast pre-flight via .workflow/status.yml, lazy-loaded .workflow/*.yml configs, the Analyze→Options→Plan→Execute→Verify stages, light TDD for non-trivial behavior changes, and maintaining .workflow/history/. Triggers — any code-change task, requests like "initialize the workflow", "analyze the task", "produce a plan", or when the project contains AGENTS.md + .workflow/.
---

# workflow

This skill activates for any work in a project that has `AGENTS.md` and
a `.workflow/` directory.

## What to do

1. **Pre-flight.** Read `AGENTS.md` and `.workflow/status.yml` only. Apply
   `status.yml → hekate` first. If `hekate.enabled` is false, stop applying
   this skill. A module runs only when its allowlist value is true; missing
   module keys mean true for older installations. If workflow is enabled and
   `initialized` is not `true`, `active_preset` is `null`, or any `checks.*`
   value is not `true`, stop and run `/init-workflow`. During Bootstrap, pick
   the commit style via the preset procedure in `.workflow/bootstrap.md`, ask
   for the commit message language separately, configure optional cross-harness
   delegation from `.workflow/orchestration.yml`, and update `.workflow/status.yml`.

   Do not read every `.workflow/*.yml` at startup. Lazy-load detailed configs
   only when the current task needs stack, architecture, conventions, full
   workflow rules, or preset definitions.

2. **Task cycle.** When `hekate.modules.workflow` is true, follow the cycle from section 3 of `AGENTS.md`:
     - 3.1 Analyze — read the affected files, record constraints.
     - 3.2 Options — ≥2 options with pros/cons, choose with the user.
     - 3.3 Plan — in `.workflow/history/YYYY-MM-DD-<slug>.md`, self-contained.
     - 3.4 Execute — follow the plan, nothing extra. For non-trivial behavior
        changes, apply `status.yml → features.light_tdd` (`strict-lite` by
        default unless the project says otherwise). If
        `status.yml → features.granular_commits` applies, work checkpoint by
        checkpoint and commit according to its mode.
     - 3.5 Verify — run the checks, update `result` and `events.jsonl`.

3. **History.** Only when `hekate.modules.history` is true, each task = one markdown in `.workflow/history/` plus
    events in `events.jsonl`. Large tasks also keep a checkpoint checklist in
    the same markdown file. The format is in section 4 of `AGENTS.md`.

4. **Native subagents.** Only when `hekate.modules.native_subagents` is true, before proposing a native-subagent wave, read
   `.workflow/session.local.yml` and apply `subagents.mode`: `off` forbids
   launches, `ask` requires one user approval for the exact proposed wave, and
   `auto` permits primary-controlled launches at its discretion. Missing or
   invalid mode means `ask`. The primary retains architecture, decomposition,
   orchestration, and acceptance; children cannot recursively delegate.

5. **Cross-harness delegation.** When both `hekate.modules.orchestration` and `status.yml → orchestration.enabled` are
   true, the current user-facing session is the primary harness and exclusively
   owns architecture, decomposition, routing/profile choice, orchestration,
   review, and final verification. Use `.workflow/bin/hekate-agent` for bounded
   external executor/advisor jobs. Children must not re-delegate or launch
   subagents. Classify/select profiles in the primary session; the runner never
   infers from prompt text. Keep one writer per checkout, use worktrees for
   concurrent writers, and independently verify child output. Do not use MCP.

6. **Scope control.** Don't do unrequested refactors, don't add
   dependencies without discussion, and perform destructive actions only
   with explicit confirmation.

## Memory anchors

- Source of truth — `AGENTS.md` in the project root.
- Fast pre-flight — `.workflow/status.yml`.
- Lazy configs — `.workflow/{stack,architecture,conventions,workflow,presets}.yml`.
- History — `.workflow/history/` (in `.gitignore`).
- Native-subagent policy — `.workflow/session.local.yml` (gitignored).
- Harness routing — `.workflow/orchestration.yml` + `.workflow/bin/hekate-agent`.
