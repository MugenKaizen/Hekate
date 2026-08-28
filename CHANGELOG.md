# Changelog

All notable changes to Hekate are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) while it is in the
`0.x` development series.

## [Unreleased]

### Added

- A master Hekate switch and module allowlist for independently enabling the
  workflow, local task history, native subagents, and cross-harness
  orchestration. Initialization offers `all`, `history + subagents`, `off`, or
  a custom selection; migration `009-add-module-switches` preserves the old
  all-enabled behavior for existing installations.

### Changed

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

[Unreleased]: https://github.com/MugenKaizen/Hekate/compare/v0.2.0-beta.1...HEAD
[0.2.0-beta.1]: https://github.com/MugenKaizen/Hekate/compare/v0.1.0-beta.1...v0.2.0-beta.1
[0.1.0-beta.1]: https://github.com/MugenKaizen/Hekate/releases/tag/v0.1.0-beta.1
