# Pi Integration

## Static Adapter

Select `pi` during installation to add generic prompt templates under
`.pi/prompts/` and the narrow workflow-maintenance skill under
`.agents/skills/`. Hekate does not create, merge, or claim
`.pi/settings.json`; installation and transactional upgrade preserve it byte
for byte.

## Enforcement Package

`@hekate/pi-extension` is a global Pi package targeting Pi
`>=0.84.4 <0.85.0`. It uses the common extension event API, so its mutation
policy is identical in TUI, print, JSON, and RPC modes. The deterministic core
and transactional CLI support Node 20+, while the optional Pi runtime and
`hekate agent` require the runtime's Node `>=22.19.0` contract.

Session states are derived mechanically from authored inputs and the generated
lock. The state is revalidated before every non-read or unknown tool call, so a
lock that becomes stale, malformed, or forged during a session immediately
removes mutation tools:

| State | Behavior |
|---|---|
| `absent` | No Hekate behavior |
| `off` | No Hekate behavior |
| `blocked` | Known read-only tools only |
| `configuring` | Reads plus direct edits to `config.yml` and `project.yml` |
| `ready` | Normal tools, with generated/auth state protection and destructive confirmation |

The package does not modify the system prompt or inject normal-turn context.
State and observed verification results use Pi custom session entries, which do
not enter model context. Pi has no OS sandbox; tool filtering is not described
as process isolation.

Direct `pi` use is protected only when this global package is enabled. The
Hekate wrapper loads the same factory inline so project trust and
extension-discovery flags cannot disable wrapper enforcement.

## Hekate Wrapper

`hekate agent` constructs Pi services and an `AgentSessionRuntime` through Pi's
documented SDK. It does not fork, vendor, or shell out to Pi. Supported modes:

```text
hekate agent
hekate agent --mode=print --prompt="task"
hekate agent --mode=json --prompt="task" --no-session
hekate agent --mode=rpc
```

Print and JSON prompts may also be read from bounded stdin. Project-local Pi
resources are untrusted by default outside TUI; use `--trust-project` or
`--no-trust-project` for an explicit session override. In TUI,
`/hekate-bootstrap` initializes authored configuration and `/hekate-settings`
changes validated workflow settings. Neither command invokes a shell or writes
project source.

Pi owns providers, OAuth, models, sessions, compaction, and session trees. The
wrapper owns only mandatory Hekate extension loading and Hekate-specific tools.
Direct Pi invocation does not imply wrapper enforcement unless the global
extension package is enabled.

## Wrapper Subagents

`hekate agent --subagents` explicitly enables the `subagent` tool. Without the
flag the tool is not registered. Children run pinned Pi in JSON, no-session
mode with a strict role tool allowlist and a private prompt file. The scheduler
enforces recursion depth, task/concurrency/output/token/cost bounds, canonical
working directories, process-tree cancellation, and structured usage/results.

Advisory roles cannot receive shell or mutation tools. Writer roles require a
Git-authenticated linked worktree in the parent repository, explicit write
authorization, and an atomic local writer lease. Child success is reported as
`review_pending`; the parent remains responsible for reviewing and accepting
all output.
