---
description: Start or manage a long-running task in another configured AI harness
argument-hint: "run [--profile <name> | --harness <name>] <task> | status <job-id> | logs <job-id> | result <job-id> | stop <job-id> | config ..."
allowed-tools: Bash(.workflow/bin/hekate-agent *)
---

Use the project-local cross-harness runner for this request:

```text
$ARGUMENTS
```

The runner is `.workflow/bin/hekate-agent`. Do not invoke another harness
through an ad-hoc shell command when the runner can represent the operation.

The current user-facing Claude session is the primary harness. It exclusively
owns architecture, decomposition, profile/model choice, orchestration, review,
and final verification. Delegated children are bounded executors/advisors and
must not launch subagents, invoke another harness, or recursively delegate.

For a new substantial task:

1. The primary session defines the architecture and bounded execution/advisory
   slice. Put its complete task contract under `.workflow/history/` or pass it
   with `--task` when short; include the child role and no-redelegation rule.
2. The primary classifies/selects an appropriate configured profile (common
   names include `small`, `medium`, `complex`, or `small-deep`) or an explicit
   harness. The runner and child do not make this decision.
3. Start it with `hekate-agent run`; runs are backgrounded by default.
4. Return the job ID immediately unless the user asked to wait.
5. Use `status`, `logs`, `wait`, and `result` for lifecycle management.
6. After completion, inspect the diff and run the parent workflow's own
   verification. A child result is evidence, not automatic acceptance.

Never start two writer agents in the same checkout. Use separate git worktrees
for concurrent writers. Run `hekate-agent doctor` if a configured CLI or flag
is unavailable.
