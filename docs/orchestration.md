# Cross-harness orchestration

Hekate can delegate long-running work from any shell-capable parent agent to a
different CLI harness without MCP or a resident service. The parent stays the
orchestrator and verifier; the child runs as an ordinary background process.

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

## Initialization and model selection

During workflow initialization, Hekate can:

1. run `hekate-agent doctor` to detect installed CLIs;
2. enable or disable orchestration;
3. choose a project-default harness;
4. choose its project-default model and effort.

These values are committed in `.workflow/orchestration.yml`. A developer can
change personal defaults without modifying the repository:

```sh
.workflow/bin/hekate-agent config use codex \
  --model gpt-5.4 --effort high
.workflow/bin/hekate-agent config show
.workflow/bin/hekate-agent config clear
```

A particular run can override both values:

```sh
.workflow/bin/hekate-agent run \
  --harness pi \
  --model openai-codex/gpt-5.4 \
  --effort high \
  --task-file /tmp/self-contained-task.md
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

| Harness | Prompt transport | Model | Effort |
|---|---|---:|---:|
| Claude Code | stdin | yes | yes |
| pi | argument | yes | yes (`--thinking`) |
| OpenCode | argument | yes | yes (`--variant`) |
| Codex CLI | stdin | yes | yes |
| Gemini CLI | argument | yes | registry default only |
| Aider | task file | yes | registry default only |

The table describes the shipped registry, not a permanent upstream API.
Run `doctor` and `models <harness>` after upgrading a CLI. If flags changed,
edit the declarative adapter rather than the job controller.

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

- Keep one writer per checkout. Use independent git worktrees for parallel
  writers.
- Put cwd, scope, allowed writes, expected output, and verification commands in
  every delegated task.
- The parent must inspect the diff and run verification after the child exits.
- Project-local harness configuration is executable configuration. Use it only
  in repositories you trust.
- Do not store credentials in orchestration YAML or task files.
- External cwd is denied unless the committed config explicitly enables it.

## Troubleshooting

```sh
.workflow/bin/hekate-agent doctor
.workflow/bin/hekate-agent harnesses
.workflow/bin/hekate-agent models pi
.workflow/bin/hekate-agent status <job-id>
.workflow/bin/hekate-agent logs <job-id> --stderr
```

If a job becomes `orphaned`, inspect its logs and start a new job. Orphaned and
completed jobs cannot be stopped, which prevents stale PID reuse from
terminating an unrelated process.
