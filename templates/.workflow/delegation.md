# Cross-harness delegation

Read this file only when `.workflow/status.yml → orchestration.enabled` is
`true` **and** the current task actually needs to delegate bounded work to a
configured external CLI harness (Claude Code, pi, OpenCode, Codex, Gemini,
Aider, or a custom entry). This is `AGENTS.md` §3.6 material, mandatory
whenever delegation is used, just not loaded at session start or on tasks
that never delegate.

When `orchestration.enabled` is `true`, the **primary harness** — the current
user-facing agent session — may delegate a bounded task to a configured child
harness through the project-local job controller. The primary harness
exclusively owns architecture, task decomposition, profile and model
routing, subagent/harness orchestration, review, and final verification:

```sh
.workflow/bin/hekate-agent run --profile <profile> \
  --task-file <self-contained-task.md>
# Or bypass the implicit profile explicitly:
.workflow/bin/hekate-agent run --harness pi --model <model> --effort high \
  --task-file <self-contained-task.md>
```

On Windows use:

```powershell
.\.workflow\bin\hekate-agent.ps1 run --profile <profile> `
  --task-file <self-contained-task.md>
```

Runs are background by default and return a job id. Use `status`, `logs`,
`wait`, `result`, and `stop` with that id. `config use-profile` selects a local
profile; `config use` selects a local harness and deliberately bypasses an
inherited project profile. Neither modifies committed project config. Read
`.workflow/orchestration.yml` for the declarative registry only when routing a
task — it also documents the write-access risk of unattended child harnesses
and the least-privileged default each one ships with.

## Advisory vs. writer harness entries

`.workflow/orchestration.yml` ships most CLIs as a PAIR of enabled harness
entries pointing at the same executable, because write access is a property
of the task, not the project:

- `<name>` — advisory/read-only. Research, review, propose a plan; never
  edits files. Safe as the default for any profile, including "review this
  diff" or "research an approach" tasks.
- `<name>-write` — the safest flag vector that actually enables unattended
  edits for that CLI (never the most-permissive/bypass-all flag). Route a
  profile to `<name>-write` only for tasks explicitly meant to write, e.g.
  "implement the approved plan."

`pi` has no permission gate of any kind and therefore has no `pi-write`
twin — plain `pi` already writes unattended the moment it runs.

A `<name>-write` entry (and plain `pi`) writes to the checkout UNATTENDED.
**Never run a writer entry in the same worktree as another writer, including
the primary session.** Give it a dedicated git worktree before routing a task
to it. The primary harness still owns diff review and final verification for
everything a writer entry produces — a writer result is evidence, not
acceptance, exactly like an advisory result.

When choosing or defining profiles, classify the task by whether it writes,
not only by size/complexity, and route accordingly:

```yaml
profiles:
  review:
    harness: claude          # advisory
  research:
    harness: codex            # advisory
  implement:
    harness: claude-write     # writer — needs its own worktree
```

## Profiles

When named profiles exist, classify before launch; never ask the runner to infer
from prompt text:

- `small` — narrow, low-risk, usually one concern or mechanical change;
- `medium` — normal non-trivial coding with bounded multi-file reasoning;
- `complex` — high-risk or multi-system execution under architecture already
  decided by the primary harness;
- `small-deep` (optional) — narrow scope that still needs unusually deep
  reasoning.

Use the configured matching profile, or an explicit profile chosen by the user.
CLI `--model` / `--effort` may override profile values for one run.

## Delegation rules

- Delegation transfers execution or advisory work, never ownership. A child is
  a bounded executor/advisor: it must not redesign architecture, decompose the
  parent task, choose its own route/profile, launch subagents or harnesses, or
  recursively delegate. If its slice requires such a decision, it stops and
  returns the decision to the primary harness.
- The primary harness creates the task contract, chooses the child/profile, and
  invokes `run` directly. A lifecycle helper may only monitor an existing job
  ID; it cannot start jobs or take over routing or orchestration.
- The task file must be self-contained: scope, allowed writes, expected output,
  child role, prohibited re-delegation, and verification commands.
- Never run two writer agents in the same checkout. Concurrent writers require
  separate git worktrees; advisory/review agents should be explicitly read-only.
- A child result is evidence, not acceptance. The parent remains responsible for
  reviewing the diff, running verification, and making product/scope decisions.
- Do not bypass permissions or broaden cwd access merely to make unattended work
  succeed. The controller restricts cwd to the project root unless the committed
  config deliberately opts out (`orchestration.yml → allow_external_cwd`).
- Every harness ships as an advisory (read-only) entry by default, with a
  separately-named `<name>-write` twin for the safest flag vector that
  actually enables unattended edits (never the most-permissive/bypass-all
  flag). Route to the `-write` twin only for a task explicitly meant to
  write, and only from a dedicated worktree — never widen an advisory
  entry's flags to make a delegated run "just work". `pi` has no built-in
  approval/sandbox gate at all and has no `-write` twin; treat any `pi`
  delegation as unattended-write and isolate it in its own worktree.
- Harness flags are version-sensitive. Use `hekate-agent doctor` after CLI
  upgrades and update the registry rather than inventing shell wrappers.
