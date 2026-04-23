# AGENTS.md

The single source of truth for any AI agent (Claude Code, Cursor, Codex,
Copilot, Aider, Gemini CLI, etc.) working on this project. Other
agent-specific files (`CLAUDE.md`, `.cursor/rules/*`, and so on) must
point here.

> **Rule #0.** Before doing anything in this project, read this file in
> full along with the `.workflow/*.yml` configs listed below. If that has
> already been done in the current session, you don't need to re-read them.
> Do not read `.workflow/bootstrap.md` unless initialization is required.

---

## 1. Pre-flight check (required before any task)

1. Read `.workflow/stack.yml`, `.workflow/architecture.yml`,
   `.workflow/conventions.yml`, `.workflow/workflow.yml`,
   `.workflow/presets.yml`.
2. Verify that every required file from
   `workflow.yml → blocking.required_files` is present and every required
   field from `workflow.yml → blocking.required_non_empty_fields` is filled in.
3. If **any** file is missing, `presets.yml → meta.active_preset` is `null`,
   or a required field is empty — **stop**, read `.workflow/bootstrap.md`, and
   run that procedure. Do not write code, do not create plans, do not make
   edits until initialization is complete.
4. If everything is filled in — proceed to **Task workflow**. When deciding
   which stages are mandatory, respect the feature flags in `workflow.yml`
   (which reflect the active preset from `presets.yml`).

---

## 2. Bootstrap (workflow initialization)

Do **not** read bootstrap details during a normal initialized session.

Only read `.workflow/bootstrap.md` and run that procedure when the pre-flight
check above fails, or when the user explicitly asks to "initialize the
workflow" / "/init-workflow".

---

## 3. Task workflow (task execution cycle)

For **every non-trivial task**, this order is required:

### 3.1. Analyze

- Understand **what** is being asked and **why**. If the goal is unclear,
  ask clarifying questions before starting the analysis.
- Find and read the affected files. Don't guess — read.
- Check the applicable sections of `.workflow/architecture.yml` and
  `.workflow/conventions.yml`.
- Decide whether `workflow.yml → process.light_tdd` applies to this task.
  For behavior changes, identify which test should be added or updated first.
- If `workflow.yml → process.granular_commits` is enabled, decide whether the
  task is large. A large task has at least 2 independently verifiable
  checkpoints that can be completed and committed without leaving the branch in
  a broken state.
- Record the constraints: which invariants must not be violated, which
  modules must not be touched.

### 3.2. Options

- Propose **at least 2 options** for the solution (unless `workflow.yml`
  allows skipping for trivial tasks).
- For each option — **pros** and **cons**. The cons must include
  architectural rule violations if there are any.
- Explicitly recommend one and justify the choice.
- Wait for the user's agreement on an option before writing the plan.

### 3.3. Plan

The plan is written to `.workflow/history/YYYY-MM-DD-<slug>.md` and must
be **self-contained** — it can be opened in a new session without context
and executed. The plan must include:

1. **Context** — why this task exists, what problem it solves.
2. **Affected files** — full paths of every file to be created or
   modified, with a short description of the changes.
3. **Steps** — step-by-step actions. Each step is an atomic change.
4. **Verification** — how to confirm the task is done (test commands,
   manual check scenarios, expected behavior).
5. **Rollback notes** — what to do if something goes wrong (for risky
   changes).
6. **Checkpoint checklist** — required for large tasks when
   `workflow.yml → process.granular_commits.enabled` is `true`.

When `workflow.yml → process.light_tdd` applies, the steps should reflect a
lightweight TDD loop: add or update a focused test first, run the narrowest
relevant check if practical to see it fail, then implement the minimum code
needed to make it pass. If test-first is impractical, explicitly state why in
Analysis or Plan and add the test immediately after implementation.

When `workflow.yml → process.granular_commits` applies, the plan must include
checkpoint boundaries in the same history file. Each checkpoint must describe:

- the slice of work being completed;
- the verification required before it counts as done;
- the commit message to use after successful verification.

Wait for plan approval before executing.

### 3.4. Execute

- Follow the plan step by step.
- If along the way you realize the plan is wrong — stop, update the plan,
  get re-approval.
- For non-trivial behavior changes, follow `workflow.yml → process.light_tdd`.
  The default mode is `strict-lite`: use test-first unless there is a clear,
  stated reason not to.
- If `workflow.yml → process.granular_commits` applies, execute checkpoint by
  checkpoint. After a checkpoint is verified, mark it complete in the task
  history and handle the commit according to `process.granular_commits.mode`:
  - `auto` — create the commit immediately.
  - `ask` — stop and ask the user before creating the commit.
- Commit messages for checkpoints must follow `.workflow/conventions.yml`.
- Don't do unrequested refactors and don't add dependencies that aren't
  in the plan (see `workflow.yml → scope_control`).

### 3.5. Verify

- Run the commands from the Verification section.
- If light TDD was bypassed, verify that the follow-up test was still added
  and passes.
- For tasks with checkpoint checklists, update the checklist status after each
  verified checkpoint and append `checkpoint_completed` /
  `checkpoint_committed` events when they happen.
- Update the `result` section in the task history file: what was done,
  what was checked, known limitations.
- Append an event to `.workflow/history/events.jsonl`:
  `{"ts": "<ISO-8601>", "task_slug": "<slug>", "type": "verified", "summary": "<1 line>"}`.

---

## 4. History (.workflow/history/)

This directory is **in `.gitignore`** and is not shared with the team. It
exists so the agent has continuity between sessions.

### 4.1. Markdown per task

`.workflow/history/YYYY-MM-DD-<kebab-slug>.md`:

```markdown
# <Task title>

## Analysis
<what was understood, which files were studied, which constraints apply>

## Options
### Option 1: <name>
- Pros: …
- Cons: …
### Option 2: <name>
- Pros: …
- Cons: …
**Chosen:** Option N — <rationale>

## Plan
### Context
### Affected files
### Steps
### Verification
### Rollback notes

## Checkpoint checklist
- [ ] CP1. <checkpoint title>
  - Verify: <command or scenario>
  - Commit: <message>
- [x] CP2. <checkpoint title>
  - Verify: <command or scenario>
  - Commit: <message>

## Result
<what was done, checks performed, remaining TODOs>
```

The `Checkpoint checklist` section is required only for large tasks when
`workflow.yml → process.granular_commits.enabled` is `true`.

### 4.2. events.jsonl

Every significant state change — one JSON line:

```json
{"ts":"2026-04-22T10:15:00Z","task_slug":"add-user-export","type":"started","summary":"user asked to add CSV export"}
{"ts":"2026-04-22T10:18:00Z","task_slug":"add-user-export","type":"analyzed","summary":"touched files: src/users/*, src/export/*"}
{"ts":"2026-04-22T10:22:00Z","task_slug":"add-user-export","type":"options_proposed","summary":"2 options: streaming vs buffered"}
{"ts":"2026-04-22T10:25:00Z","task_slug":"add-user-export","type":"planned","summary":"see history/2026-04-22-add-user-export.md"}
{"ts":"2026-04-22T10:33:00Z","task_slug":"add-user-export","type":"checkpoint_completed","summary":"CP1 tests added and passing"}
{"ts":"2026-04-22T10:35:00Z","task_slug":"add-user-export","type":"checkpoint_committed","summary":"test(users): cover export validation"}
{"ts":"2026-04-22T10:40:00Z","task_slug":"add-user-export","type":"verified","summary":"tests green, manual export of 10k rows OK"}
```

Allowed `type` values: `started | analyzed | options_proposed | planned | checkpoint_completed | checkpoint_committed | executed | verified | blocked`.

---

## 5. Scope control

- **Don't do what wasn't asked for.** Fixed a bug — don't refactor the area around it.
- **Don't add dependencies** without an explicit request and a separate discussion.
- **Destructive actions** (deleting files, migrations, `git reset --hard`,
  force-push) — only with the user's explicit confirmation for the specific
  action.
- **Don't use `--no-verify`**, don't bypass hooks, don't disable linters.

---

## 6. References

- `.workflow/stack.yml` — technology stack
- `.workflow/architecture.yml` — architecture
- `.workflow/conventions.yml` — code style and conventions
- `.workflow/workflow.yml` — agent's working rules
- `.workflow/bootstrap.md` — initialization procedure; read only when pre-flight fails
- `.workflow/README.md` — brief cheat sheet
