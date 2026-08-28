# .workflow/

This directory holds the workflow configs for AI agents — a single source
of truth about the project: stack, architecture, conventions, and rules
for how the agent works.

## Contents

| File | Purpose |
|------|---------|
| `stack.yml` | Languages, frameworks, databases, infrastructure, run commands |
| `architecture.yml` | Style, layers, modules, dependency rules |
| `conventions.yml` | Code style, naming, tests, commits |
| `workflow.yml` | Rules for the agent itself: stages, light TDD, granular commits, history, blocking |
| `status.yml` | Fast pre-flight index: Hekate switch/module allowlist, initialized flag, active preset, resolved feature flags |
| `orchestration.yml` | Optional declarative registry for Claude, pi, OpenCode, Codex, Gemini, Aider, and custom CLI harnesses |
| `session.local.yml` | Gitignored native-subagent policy for the current primary session: `off`, `ask`, or `auto` |
| `bin/hekate-agent` | POSIX long-running job controller; PowerShell counterpart: `hekate-agent.ps1` |
| `bootstrap.md` | Initialization procedure; read only when pre-flight fails or `/init-workflow` is requested |
| `delegation.md` | Cross-harness delegation mechanics; read only when actually delegating to an external CLI harness |
| `subagents.md` | Native-subagent policy detail; read only before the first native-subagent wave, or to change policy |
| `history-format.md` | Task history file template and `events.jsonl` schema; read only during Plan/Verify |
| `state.yml` | Installed workflow reference and applied migration IDs |
| `history/` | Local task history (in `.gitignore`) |
| `backups/` | Local one-file backups created before workflow updates |

## Rules

1. **Apply the Hekate switch first.** At startup the agent reads
   `.workflow/status.yml → hekate`. `enabled: false` disables all Hekate
   behavior. With Hekate enabled, `modules` independently controls `workflow`,
   `history`, `native_subagents`, and `orchestration`. Missing keys mean true
   for compatibility with older installations.

2. **Without filled-in configs the workflow module does not work.** At startup the agent
   reads `.workflow/status.yml` only. If `initialized` is not `true`,
   `active_preset` is `null`, or any `checks.*` value is not `true`, the agent
   must stop, read `.workflow/bootstrap.md`, and run or refresh the
   initialization procedure described there.

3. **When history is enabled, every task → an entry in `history/`.** A file
   `history/YYYY-MM-DD-<slug>.md` is created with sections
   analysis / options / plan / result and, for large tasks,
   checkpoint checklist, plus an event in
   `history/events.jsonl`.

4. **When workflow is enabled, task format**: Analyze → Options (≥2 with pros/cons) → Plan → Execute.
   The plan must be self-contained — runnable in a new session without
   additional context.

5. **Light TDD for behavior changes.** `status.yml → features.light_tdd`
   controls the rule. The default is `strict-lite`: for a non-trivial
   behavior change, prefer a focused test first, then the minimum code to make
   it pass. Trivial/docs/config/mechanical edits may skip it.

6. **Granular commits for large tasks.**
   `status.yml → features.granular_commits` controls whether large tasks are
   split into verified checkpoints with intermediate commits.

7. **Edits to the configs** are made deliberately: after a change the
   agent must verify that the project's current code still matches them
   and report any discrepancies. If the change affects initialization status,
   active preset, required fields, or resolved feature flags, update
   `.workflow/status.yml` in the same change.

8. **Workflow updates are conservative.** The updater runs ordered
   migrations for known managed paths, preserves unknown/custom keys,
   and creates one backup per changed file in `backups/`.

## Native-subagent session policy

`.workflow/session.local.yml → subagents.mode` controls whether the primary
harness may use its own native subagents:

- `off` — no native subagents;
- `ask` — ask once before every exact proposed delegation wave (default);
- `auto` — use native subagents at the primary's discretion.

Missing or invalid mode is treated as `ask`. Only the user may authorize `off`
or `auto`. This does not transfer architecture, orchestration, review, or final
verification to children, and does not grant push/merge/release/destructive
authority. External CLI jobs remain separately controlled by
`orchestration.yml`.

## Cross-harness jobs (optional)

Enable and choose project defaults during initialization, or select a local
default later:

```sh
.workflow/bin/hekate-agent doctor
.workflow/bin/hekate-agent profiles
.workflow/bin/hekate-agent config use-profile medium
.workflow/bin/hekate-agent run --profile complex \
  --task-file .workflow/history/task.md
```

The last command starts a detached job and prints its id:

```sh
.workflow/bin/hekate-agent status <job-id>
.workflow/bin/hekate-agent logs <job-id> --follow
.workflow/bin/hekate-agent wait <job-id> --timeout 3600
.workflow/bin/hekate-agent result <job-id>
.workflow/bin/hekate-agent stop <job-id>
```

On Windows replace the executable with
`.\\.workflow\\bin\\hekate-agent.ps1`. Job state is local under
`.workflow/runs/`; local model selection is stored in the gitignored
`.workflow/orchestration.local.yml`. There is no MCP server or daemon.
Named profiles map arbitrary routing policies to harness/model/effort;
`small`, `medium`, `complex`, and `small-deep` are only suggested names. The
primary user-facing harness exclusively owns architecture, decomposition,
profile choice, orchestration, review, and final verification. Children are
bounded executors/advisors and cannot re-delegate. The runner never infers
complexity from prompt text. `config use <harness>` bypasses an inherited
profile, while explicit model/effort flags override profile values for one run.
Registry commands and arguments are version-sensitive, so run `doctor` after
upgrading a harness CLI. Missing optional CLIs do not fail a normal scan; use
`doctor <harness>` or `doctor --strict` when absence must fail.

## Commit presets

During initialization the agent offers a named commit preset
(`conventional`, `gitmoji`, `emoji-prefix`, `free-form`, or `custom`) and
asks for the commit message language separately — any language works with
any preset. Full definitions and examples live in `.workflow/bootstrap.md`.

## Initialization

- New project: ask the agent to "initialize the workflow" — it will ask
  questions and fill out the YAML, including confirmation of the light TDD
  mode and granular commit settings.
- Existing project: ask it to "analyze the project and fill out
  `.workflow/`" — the agent will work through the manifests, structure,
  and linters and propose values.

See `AGENTS.md` in the project root for the normal task workflow and
`.workflow/bootstrap.md` for initialization details.
