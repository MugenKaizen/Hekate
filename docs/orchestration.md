# Cross-harness orchestration

Hekate can delegate long-running work from a primary user-facing agent to a
different CLI harness without MCP or a resident service. The primary harness
exclusively owns architecture, task decomposition, routing, subagent/harness
orchestration, review, and final verification. A child runs as a bounded
executor or advisor and cannot recursively delegate.

## Architecture

```text
parent agent (Claude / pi / Codex / Gemini / OpenCode / ...)
  └─ .workflow/bin/hekate-agent
       ├─ reads .workflow/orchestration.yml
       ├─ applies .workflow/orchestration.local.yml
       └─ persists .workflow/runs/<job-id>/
            ├─ task.md
            ├─ status
            ├─ stdout.log / stderr.log
            ├─ pid metadata
            └─ exit-code
```

The same controller works in both directions. There are no pairwise
Claude-to-pi or pi-to-Claude integrations: every parent invokes the same
registry and job lifecycle.

Native in-harness subagents are a separate mechanism. Their per-session user
permission is read from `.workflow/session.local.yml`: `off`, per-wave `ask`,
or explicitly authorized `auto`. Neither mechanism transfers architecture or
orchestration ownership away from the primary harness. Full detail for both
mechanisms is lazy-loaded from `AGENTS.md` — `.workflow/delegation.md` for
cross-harness jobs, `.workflow/subagents.md` for native subagents — not read
at session start.

## Write-access risk

A delegated child is an unattended background process running against your
checkout; a wrong or overly permissive flag is normally discovered only after
a job has already written something. Write access is a property of the
**task**, not the project, so `.workflow/orchestration.yml` ships most CLIs
as a **pair of enabled harness entries** pointing at the same executable
instead of one entry with a hidden bypass flag:

- `<name>` — advisory/read-only: research, review, propose a plan; never
  edits files. This is what a "review this diff" or "research an approach"
  profile should route to.
- `<name>-write` — the safest flag vector that actually enables unattended
  edits for that CLI (never the most-permissive/bypass-all flag). Route a
  profile to `<name>-write` only for tasks explicitly meant to write, e.g.
  "implement the approved plan."

Concretely: `claude-write` uses `acceptEdits`, never `bypassPermissions`;
`codex-write` uses `--sandbox workspace-write`, never
`--dangerously-bypass-approvals-and-sandbox`; `gemini-write` uses
`auto_edit`, never `yolo`; `opencode-write` uses the built-in `build` agent,
not `--auto`; `aider-write` uses `--yes-always` (Aider has no narrower
writer mode to prefer instead — this is already its safest writer vector).
`pi` is a special case: it has no built-in approval/sandbox gate at all and
therefore has no `pi-write` twin — plain `pi` already writes unattended the
moment it runs, so every `pi` delegation must be treated as unattended-write.

**A `-write` entry (and plain `pi`) must never run in the same worktree as
another writer, including the primary session.** Give it a dedicated git
worktree before routing a task to it. Nothing in the registry requires
hand-editing YAML to become a writer — every entry is enabled and functional
as shipped; the choice is which named entry a profile routes to. Routing to a
`-write` entry does not change who owns review: the primary harness still
owns diff review and final verification for everything a writer entry
produces, exactly as for advisory entries.

## Initialization and model selection

During workflow initialization, Hekate can:

1. run `hekate-agent doctor` to detect installed CLIs;
2. enable or disable orchestration;
3. choose one project-default harness, or named task-routing profiles;
4. choose the corresponding models and efforts from installed CLIs.

These values are committed in `.workflow/orchestration.yml`. A developer can
change personal defaults without modifying the repository:

```sh
.workflow/bin/hekate-agent config use-profile medium
# Or bypass the project profile with a harness default:
.workflow/bin/hekate-agent config use codex --model gpt-5.4 --effort high
.workflow/bin/hekate-agent config show
.workflow/bin/hekate-agent config clear
```

A particular run can select a profile or override its model/effort:

```sh
.workflow/bin/hekate-agent run --profile complex \
  --effort xhigh --task-file /tmp/self-contained-task.md
```

An explicit `--harness` bypasses an implicit default profile. Passing both
explicit `--profile` and `--harness` is rejected as ambiguous.

## Task-routing profiles

Profiles are arbitrary named harness/model/effort tuples. They may represent
complexity, role, risk, cost, provider, or a team-specific policy. The primary
workflow selects a profile; the runner and delegated child never analyze prompt
text or choose routing. Profiles are independent from the `fast` / `medium` /
`full` process presets. `none` and `null` are reserved sentinels, not valid
profile names. A common complexity-oriented setup is:

```yaml
default_profile: medium
profiles:
  small:
    harness: pi
    model: openai-codex/gpt-5.6-terra
    effort: high
  small-deep:
    harness: pi
    model: openai-codex/gpt-5.6-terra
    effort: xhigh
  medium:
    harness: pi
    model: openai-codex/gpt-5.6-sol
    effort: medium
  complex:
    harness: pi
    model: openai-codex/gpt-5.6-sol
    effort: high
```

Use these provider-specific IDs only when `hekate-agent models pi` confirms
that they are available. Profile fields omitted from YAML fall back to that
harness's defaults. Resolution precedence is: explicit CLI model/effort →
selected profile → harness defaults. Profile selection is explicit CLI → local
default → committed default.

Suggested classes (not required profile names):

- `small`: narrow, low-risk, often mechanical;
- `small-deep`: narrow but reasoning-heavy;
- `medium`: normal bounded non-trivial coding;
- `complex`: high-risk or multi-system execution under architecture already
  decided by the primary harness.

Complexity classes are one axis; whether the task writes is another, and it
maps directly to which harness entry a profile names. A team that also wants
to route by write access can add profiles like:

```yaml
profiles:
  review:
    harness: claude          # advisory — never edits
  research:
    harness: codex            # advisory — never edits
  implement:
    harness: claude-write     # writer — needs its own worktree
```

## Job lifecycle

`run` is detached by default and prints a job ID:

```sh
job_id=$(.workflow/bin/hekate-agent run --task "Review the current diff")
.workflow/bin/hekate-agent status "$job_id"
.workflow/bin/hekate-agent logs "$job_id" --follow
.workflow/bin/hekate-agent wait "$job_id" --timeout 3600
.workflow/bin/hekate-agent result "$job_id"
```

Use `--foreground` for CI or a short blocking invocation. Use `stop` only for
an active job:

```sh
.workflow/bin/hekate-agent stop "$job_id"
```

On Windows, use `.\.workflow\bin\hekate-agent.ps1` with the same command
names and options.

## Built-in harnesses

| Harness entries | Prompt transport | Model | Effort | Writer twin |
|---|---|---:|---:|---|
| `claude` | stdin | yes | yes | `claude-write` (`acceptEdits`) |
| `pi` | argument | yes | yes (`--thinking`) | none — plain `pi` already writes |
| `opencode` | argument | yes | yes (`--variant`) | `opencode-write` (`build` agent) |
| `codex` | stdin | yes | yes | `codex-write` (`--sandbox workspace-write`) |
| `gemini` | argument | yes | registry default only | `gemini-write` (`--approval-mode auto_edit`) |
| `aider` | task file | yes | registry default only | `aider-write` (`--yes-always`) |

The unsuffixed name in each row is the advisory/read-only entry; it is the
default choice for review/research profiles. See "Write-access risk" above
for why `-write` entries exist and how to route to them safely.

The table describes the shipped registry, not a permanent upstream API.
Run `doctor` and `models <harness>` after upgrading a CLI. Normal `doctor`
reports missing/disabled optional CLIs but succeeds; `doctor <harness>` fails
when that harness is missing or disabled, and `doctor --strict` fails when an
enabled executable is missing. If flags changed,
edit the declarative adapter rather than the job controller.

Non-interactive CLI flags are version-sensitive: a flag that worked in one
release can be renamed, deprecated, or removed in the next (for example,
Codex CLI's `--full-auto` was deprecated in v0.128.0 and removed in v0.147.0).
`.workflow/orchestration.yml`'s header comment states this prominently and
each harness entry carries a `min_cli_version`-style comment plus explicit
"Verified" (with source) or "Unverified" markers for every non-obvious flag.
Re-check the registry against `doctor` and each CLI's own `--help`/changelog
after every harness upgrade — do not trust a shipped flag vector indefinitely.

## Adding a harness

Add an entry to `.workflow/orchestration.yml`:

```yaml
harnesses:
  my-agent:
    enabled: true
    command: my-agent
    prompt_delivery: stdin       # stdin | argument | file
    supports_model: true
    supports_effort: false
    default_model: vendor/model
    default_effort: default
    models_command: my-agent
    models_args:
      - models
    args:
      - run
      - --model
      - "{model}"
```

Supported placeholders are `{model}`, `{effort}`, `{prompt_file}`,
`{session_id}`, and `{cwd}`. Each list item becomes exactly one argument.
Commands are never interpreted as shell source.

## Safety model

- Every shipped harness's unsuffixed entry is advisory/read-only. Only a
  `-write`-suffixed entry (or plain `pi`) edits files unattended — route to
  it deliberately, per task, never by widening an advisory entry's flags.
- Keep one writer per checkout. Use independent git worktrees for parallel
  writers, and always for any `-write` entry or `pi`.
- Put cwd, bounded scope, child executor/advisor role, allowed writes, expected
  output, prohibited re-delegation, and verification commands in every task.
- The primary harness must make architecture/decomposition/routing decisions,
  inspect the diff, review the result, and run final verification.
- A delegated child must not launch subagents, invoke another harness, or widen
  its slice. It returns any new decision to the primary harness.
- Project-local harness configuration is executable configuration. Use it only
  in repositories you trust.
- Do not store credentials in orchestration YAML or task files.
- External cwd is denied unless the committed config explicitly enables it.

## Troubleshooting

```sh
.workflow/bin/hekate-agent doctor
.workflow/bin/hekate-agent doctor opencode
.workflow/bin/hekate-agent doctor --strict
.workflow/bin/hekate-agent harnesses
.workflow/bin/hekate-agent profiles
.workflow/bin/hekate-agent models pi
.workflow/bin/hekate-agent status <job-id>
.workflow/bin/hekate-agent logs <job-id> --stderr
```

If a job becomes `orphaned`, inspect its logs and start a new job. Orphaned and
completed jobs cannot be stopped, which prevents stale PID reuse from
terminating an unrelated process.
