# Changelog

All notable changes to Hekate are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) while it is in the
`0.x` development series.

## [Unreleased]

## [0.3.0-beta.1] - 2026-09-01

### Added

- Node 20 deterministic core and CLI packages with strict YAML 1.2 parsing,
  versioned schemas, profile resolution, stable gate states, canonical
  `status.lock.json` compilation, and `check` / `compile` commands.
- Cross-platform CI for Node, POSIX, and Windows PowerShell suites.
- Transactional forced upgrade, dry-run, and offline rollback with ownership
  ledgers, historical import preservation reports, and repeat-upgrade fixtures.
- A manifest-installed Pi adapter, mandatory global/inline Pi enforcement
  extension, and SDK-based `hekate agent` wrapper with TUI, print, JSON, RPC,
  stdin prompts, project trust, bootstrap, and settings UI.
- Opt-in wrapper-native Pi subagents with advisory capability isolation,
  aggregate resource budgets, process-tree cancellation, structured evidence,
  and Git-authenticated writer worktrees.

### Fixed

- A forced upgrade no longer replaces files Hekate has no record of installing
  without review. The preservation report and operation plan are printed before
  confirmation, each unowned file is named, and `--yes` refuses with `HKT903`
  unless `--replace-unowned` states the approval explicitly.
- `install.sh --force` and `install.ps1 -Force` recognize a v1 contract
  installation instead of falling through to the fresh-install copy path, which
  overwrote managed files outside the transaction engine. The frozen legacy
  update runners refuse a v1 layout with an actionable message.
- Unknown adapter names are rejected by the shell and PowerShell installers
  rather than silently installing the core component only.
- `.workflow/state.yml` is replaced atomically, so an interrupted write can no
  longer truncate the applied-migration ledger and `installed_ref`.
- The migration-ledger parser reads block sequences written at the same
  indentation as their key; previously every recorded migration ID was dropped
  and already-applied migrations re-ran.
- A writer subagent lease is published only after it is acquired, so a losing
  contender no longer deletes the holder's live lease.
- Pi extension commands and status updates no longer require optional UI
  methods, keeping behavior identical in TUI, print, JSON, and RPC modes.
- Pi enforcement revalidates project readiness before each non-read tool call,
  preventing a session from retaining mutation authority after its lock becomes
  stale, malformed, or forged.
- Explicit cleanup preserves proof of unpublished preparation, reports partial
  component removal, and converges safely when retried after interruption.
- The published CLI tarball now contains its manifest and template payload;
  Pi is an optional peer so Node 20 transactional commands do not install a
  runtime that requires Node 22.19.
- CI installs all workspace tarballs in a clean consumer and exercises the
  transactional lifecycle on Node 20 plus the optional Pi boundary on Node
  22.19.
- Bun 1.3.14+ is supported alongside npm with an independent frozen lockfile,
  full core/CLI coverage, clean installed-tarball lifecycle tests, and Linux
  and macOS CI jobs.
- Commit-pinned portable upgrades use a reproducible standalone transaction
  runtime instead of `npm ci` and retain that executable in each recovery
  bundle for offline rollback.
- An aborted legacy import keeps its machine-readable report under
  `.workflow/migration/<run-id>/` for offline inspection.

### Changed

- A dedicated Hekate TUI is explicitly deferred until real-use UX evidence and
  a stable renderer-independent session adapter exist; the SDK wrapper keeps
  the stock Pi TUI as its supported interactive surface.
- The default payload no longer installs `stack.yml`, `architecture.yml`,
  `conventions.yml`, or `presets.yml`. `project.yml` owns those facts and
  profile definitions ship with Hekate, so a project records only its selection.
  The files remain available as the opt-in `legacy-workflow-files` component
  through `--components`, `install.sh --legacy-workflow-files`, and
  `install.ps1 -LegacyWorkflowFiles`.
- Manifest `update_strategy` and `remove_strategy` now govern installation
  dispositions; `create-only` and `preserve` assets can no longer overwrite an
  existing file, and `archive` removals are journaled as an archive copy plus a
  backed-up delete.
- The Hekate wrapper forwards `SIGINT` and `SIGTERM` to the running Pi session,
  detaches its handlers when the run ends, and exits with the conventional
  signal code.
- The portable task contract is now adaptive: Understand, Decide when needed,
  Plan when needed, Execute, and Verify. Profiles no longer impose mandatory
  option rounds, plan approval, automatic commits, or branch creation.
- TDD policy is normalized to `off`, `prefer-test-first`, or
  `require-test-evidence`; completion evidence is based on observed checks.
- Local history is optional and disabled by default instead of creating
  per-stage Markdown and JSONL artifacts for every task.
- Native-subagent authorization belongs to the active harness. The portable
  `off | ask | auto` policy is no longer installed.
- Cross-harness orchestration is retained as a legacy experimental component
  for existing installations and removed from the fresh default payload.
- Installer and updater output is prefixed `[hekate]` instead of `[aaw]`, a
  leftover from an earlier project name that was visible on every line the user
  sees. Temporary working directories follow the same rename.
- The undocumented `AAW_REPO` environment variable is now `HEKATE_REPO`.

## [0.2.0-beta.1] - 2026-08-25

### Changed

- **Breaking.** Delegated child harnesses are no longer granted unattended write
  access by default. Every harness now ships as an advisory entry locked to its
  least-privileged non-interactive mode, plus an explicit writer twin
  (`claude-write`, `codex-write`, `gemini-write`, `opencode-write`,
  `aider-write`) selected per task. Writer twins use each CLI's middle
  permission tier, never its bypass-everything mode. `pi` has no permission gate
  of its own and is documented as inherently a writer.
- **Breaking.** `install.sh --force` / `install.ps1 -Force` now lists the files
  it would replace and asks for confirmation. Non-interactive invocations
  (including `curl … | sh`) abort without writing unless `--yes` / `-Yes` is
  passed.
- `AGENTS.md` reduced from 338 to 200 lines. The task-history format,
  cross-harness delegation mechanics, and native-subagent policy detail moved to
  `.workflow/history-format.md`, `.workflow/delegation.md`, and
  `.workflow/subagents.md`, loaded only when needed. No rule was removed.
- Job directories now use one field-naming scheme across both runners, so a run
  created on POSIX is readable on Windows and vice versa.

### Added

- Installable adapters for GitHub Copilot, Gemini CLI, and Aider, alongside the
  existing Claude Code, Cursor, and Codex adapters. `--agents` on an update opts
  an existing installation into a new adapter without reinstalling.
- Per-run timestamped backups under `.workflow/backups/<UTC-timestamp>/`, bounded
  to the five most recent runs, recorded in `.workflow/state.yml → schema.history`.
- `update-runner --rollback[=<timestamp>]` restores a recorded run and rewinds
  `applied_migrations`.
- Migrations `007-add-portable-adapters` and `008-add-lazy-load-docs`.
- PowerShell test suite (`tests/run.ps1`), executed by `tests/run.sh` when a
  PowerShell interpreter is present.
- Arbitrary named task-routing profiles with `run --profile`, local
  `config use-profile`, explicit override precedence, and persisted profile
  metadata.
- Optional/targeted/strict harness doctor modes.
- Explicit primary-harness ownership of architecture, decomposition, routing,
  orchestration, review, and final verification.
- Gitignored native-subagent session policy with `off`, per-wave `ask`, and
  explicitly authorized `auto` modes, plus migration 005 for existing installs.

### Fixed

- `wait` on Windows returned `1` for any failure instead of the harness exit
  code, contradicting its own usage text.
- `logs` and `logs --follow` on Windows showed nothing until a job finished; the
  runner buffered all child output in memory instead of streaming it to disk.
- The POSIX YAML reader was hardcoded to exact 2/4/6-space indentation and
  silently returned empty for otherwise valid configs. It now measures
  indentation relative to the enclosing block, rejects tab-indented files with a
  clear error, and distinguishes an absent key from an empty one. Fixes a
  state-machine bug where a duplicate item name aborted the whole section.
- Worker ownership is verified against a recorded process start time rather than
  a substring match on `ps` output, which misreported jobs as orphaned when the
  command line was truncated or wrapped.
- `install.sh --force` overwrote hand-filled `.workflow/*.yml` with no backup.
- Network install and update now require a full commit SHA and use that same
  immutable revision for the bootstrap script, downloaded snapshot, and
  persisted installation state.
- Normal doctor scans no longer fail merely because optional harness CLIs are
  absent.
- Exact profile lookup prevents dotted names from aliasing another YAML entry;
  quoted values and reserved sentinels are handled consistently.
- Migration 004 preserves forward schema versions and handles customized status
  blocks without a `default_harness` anchor.

### Known limitations

- The PowerShell half of this release was written and reviewed but not executed:
  no PowerShell interpreter was available on the development machine, so
  `tests/run.ps1` reports `SKIPPED` there. Smoke-test on Windows before relying
  on `hekate-agent.ps1`, `install.ps1`, or the `.ps1` migrations.
- Job directories created before this release are unreadable by the new runners
  because the metadata field names changed. Drain in-flight jobs before
  upgrading.

## [0.1.0-beta.1] - 2026-08-11

### Added

- Agent-independent `Analyze → Options → Plan → Execute → Verify` workflow.
- Data-driven `fast`, `medium`, `full`, and `custom` workflow presets.
- Fast startup pre-flight through `.workflow/status.yml` and lazy-loaded project
  context.
- Conservative installers and migration-based update runners for POSIX shell
  and Windows PowerShell.
- Optional cross-harness orchestration without MCP or a resident daemon.
- Declarative adapters for Claude Code, pi, OpenCode, Codex CLI, Gemini CLI,
  Aider, and custom CLI harnesses.
- Persistent background job lifecycle: `run`, `list`, `status`, `logs`, `wait`,
  `result`, and `stop`.
- Project defaults plus gitignored per-developer model and effort overrides.
- Claude Code `/harness` command and `harness-orchestrator` custom agent.
- Migration `003-add-cross-harness-orchestration` for existing installations.
- Fake-harness integration tests and installer/update smoke tests.

### Security

- Harness argument vectors are executed directly without `eval` or `sh -c`.
- Job identifiers reject multiline/path-traversal input.
- Delegated working directories stay inside the project by default.
- Stop operations verify worker ownership before signalling stored PIDs.
- Concurrent writers are explicitly required to use separate worktrees.

### Known limitations

- Harness model names and effort semantics are provider- and version-specific.
- Non-interactive CLI flags may require registry updates after harness upgrades.
- This is an early beta; configuration and job metadata formats may change
  before `1.0.0`.

[Unreleased]: https://github.com/MugenKaizen/Hekate/compare/v0.3.0-beta.1...HEAD
[0.3.0-beta.1]: https://github.com/MugenKaizen/Hekate/compare/v0.2.0-beta.1...v0.3.0-beta.1
[0.2.0-beta.1]: https://github.com/MugenKaizen/Hekate/compare/v0.1.0-beta.1...v0.2.0-beta.1
[0.1.0-beta.1]: https://github.com/MugenKaizen/Hekate/releases/tag/v0.1.0-beta.1
