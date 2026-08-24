# Changelog

All notable changes to Hekate are documented here. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) while it is in the
`0.x` development series.

## [Unreleased]

### Added

- Arbitrary named task-routing profiles with `run --profile`, local
  `config use-profile`, explicit override precedence, and persisted profile
  metadata.
- Optional/targeted/strict harness doctor modes.
- Explicit primary-harness ownership of architecture, decomposition, routing,
  orchestration, review, and final verification.
- Gitignored native-subagent session policy with `off`, per-wave `ask`, and
  explicitly authorized `auto` modes, plus migration 005 for existing installs.

### Fixed

- Network install and update now require a full commit SHA and use that same
  immutable revision for the bootstrap script, downloaded snapshot, and
  persisted installation state.
- Normal doctor scans no longer fail merely because optional harness CLIs are
  absent.
- Exact profile lookup prevents dotted names from aliasing another YAML entry;
  quoted values and reserved sentinels are handled consistently.
- Migration 004 preserves forward schema versions and handles customized status
  blocks without a `default_harness` anchor.

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

[Unreleased]: https://github.com/MugenKaizen/Hekate/compare/v0.1.0-beta.1...HEAD
[0.1.0-beta.1]: https://github.com/MugenKaizen/Hekate/releases/tag/v0.1.0-beta.1
