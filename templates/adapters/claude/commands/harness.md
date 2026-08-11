---
description: Start or manage a long-running task in another configured AI harness
argument-hint: "run <harness> <model> <effort> <task> | status <job-id> | logs <job-id> | result <job-id> | stop <job-id> | config ..."
allowed-tools: Bash(.workflow/bin/hekate-agent *)
---

Use the project-local cross-harness runner for this request:

```text
$ARGUMENTS
```

The runner is `.workflow/bin/hekate-agent`. Do not invoke another harness
through an ad-hoc shell command when the runner can represent the operation.

For a new substantial task:

1. Put the complete, self-contained task in a temporary file under
   `.workflow/history/` or pass it with `--task` when it is short.
2. Start it with `hekate-agent run`; runs are backgrounded by default.
3. Return the job ID immediately unless the user asked to wait.
4. Use `status`, `logs`, `wait`, and `result` for lifecycle management.
5. After completion, inspect the diff and run the parent workflow's own
   verification. A child result is evidence, not automatic acceptance.

Never start two writer agents in the same checkout. Use separate git worktrees
for concurrent writers. Run `hekate-agent doctor` if a configured CLI or flag
is unavailable.
