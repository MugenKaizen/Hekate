# Native-subagent session policy

This policy applies only when `status.yml → hekate.enabled` and
`hekate.modules.native_subagents` are both `true`.

Read this file only before the primary harness's first native-subagent wave
in a session, or when the user asks to change the subagent policy. This is
`AGENTS.md` §1.2 material, mandatory whenever native subagents are used, just
not loaded at session start or on tasks that never launch one.

The primary harness may use its native subagents for bounded advisory,
research, review, validation, or execution work, while retaining all
architecture, decomposition, orchestration, and acceptance authority.

Before the first native-subagent wave, read
`.workflow/status.yml → native_subagents.policy` (normally
`.workflow/session.local.yml`). Resolve `subagents.mode` as follows:

- `off` — do not launch native subagents; the primary handles the task itself.
- `ask` — before each exact delegation wave, show the user the proposed agent
  count, roles, scope, and write authority, then wait for approval. One approval
  covers only that named wave; additions or later waves require another approval.
- `auto` — the primary may launch native subagents at its discretion without a
  separate question for each wave.

Missing, unreadable, or invalid policy means `ask`. Only an explicit user choice
may change the mode to `off` or `auto`; the primary writes that choice to the
local policy file and the user may change it at any time. `auto` never grants
permission to push, merge, release, perform destructive actions, bypass the
one-writer rule, or transfer primary-harness ownership. Native-subagent policy
is separate from external CLI harness availability in `orchestration.yml`.
Every child remains a bounded executor/advisor and must not recursively
orchestrate or delegate.

`.workflow/session.local.yml` is gitignored and looks like:

```yaml
subagents:
  mode: ask  # off | ask | auto
```

`ask` is the safe default and requires one user approval for each exact
proposed wave, not one prompt per child.
