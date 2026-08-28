# History file format

Read this file only when `status.yml → hekate.modules.history` is `true` and
you are about to create or update a task history entry. With the workflow
module enabled this happens during Plan and Verify. Without the workflow
module, history records the work without imposing workflow stages.

`.workflow/history/` is **in `.gitignore`** and is not shared with the team.
It exists so the agent has continuity between sessions.

## 1. Markdown per task

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
`status.yml → features.granular_commits` is `true`.

When `hekate.modules.workflow` is `false`, use the compact standalone format:

```markdown
# <Task title>

## Context
<request and relevant constraints>

## Work
<changes or actions performed>

## Result
<checks performed, outcome, and remaining limitations>
```

The plan section must be **self-contained** — it can be opened in a new
session without context and executed. It must include:

1. **Context** — why this task exists, what problem it solves.
2. **Affected files** — full paths of every file to be created or
   modified, with a short description of the changes.
3. **Steps** — step-by-step actions. Each step is an atomic change.
4. **Verification** — how to confirm the task is done (test commands,
   manual check scenarios, expected behavior).
5. **Rollback notes** — what to do if something goes wrong (for risky
   changes).
6. **Checkpoint checklist** — required for large tasks when
   `status.yml → features.granular_commits` is `true`. Each checkpoint
   describes the slice of work being completed, the verification required
   before it counts as done, and the commit message to use after successful
   verification.

## 2. events.jsonl

Every significant state change — one JSON line in
`.workflow/history/events.jsonl`:

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

With the workflow module enabled, an event must be appended:

- `started` — when a non-trivial task begins (Analyze).
- `analyzed` — after Analyze completes.
- `options_proposed` — after Options are presented to the user.
- `planned` — after the plan file is written and approved.
- `checkpoint_completed` / `checkpoint_committed` — for each verified
  checkpoint, when `status.yml → features.granular_commits` applies.
- `verified` — at the end of Verify:
  `{"ts": "<ISO-8601>", "task_slug": "<slug>", "type": "verified", "summary": "<1 line>"}`.
- `blocked` — whenever the task cannot proceed (missing info, failing
  precondition, denied confirmation for a destructive action).

Without the workflow module, append only the events that describe actual work,
normally `started`, `executed`, `verified`, or `blocked`.
