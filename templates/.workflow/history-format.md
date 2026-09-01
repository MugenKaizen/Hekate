# Optional History Note

History is disabled by default. Use it only when explicitly enabled and a task
benefits from resumable local context. Do not create one file per workflow
stage and do not append mandatory JSONL events.

Suggested path:

```text
.workflow/history/YYYY-MM-DD-<slug>.md
```

Suggested contents:

```markdown
# <Task>

## Context
Requested outcome, relevant constraints, and important decisions.

## Progress
Completed work and remaining steps.

## Evidence
Commands run, observed results, and checks that remain unavailable.
```

Keep secrets, transcripts, and large command output out of history notes.
Move durable architecture decisions into normal project documentation or ADRs.
