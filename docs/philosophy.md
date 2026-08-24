# Philosophy

## The problem

AI agents work better the more clearly the project's context is described.
But in practice:

- Context is scattered across developers' heads, chat threads, and bits of README.
- Every team/agent has its own instruction format: `CLAUDE.md`, `.cursor/rules`,
  `AGENTS.md`, `.github/copilot-instructions.md`, `.aider.conf.yml`, etc.
- The same agent behaves differently in similar situations because the
  work process is not codified.

## Principles

1. **Agent-independent.** The source of truth is an open format (YAML +
   Markdown), not the API of a specific assistant. Any agent that can
   read files is compatible.

2. **`AGENTS.md` is the single entry point.** All agent-specific files
   (`CLAUDE.md`, `.cursor/rules/*.mdc`, etc.) point to it.
   Want to change behavior — change `AGENTS.md`, not N copies. `AGENTS.md`
   itself stays a compact, genuinely-always-read core: pre-flight check,
   the task cycle in brief, scope control, and a pointer index. Detail that
   is only needed situationally — the history file/event schema, cross-harness
   delegation mechanics, native-subagent policy detail — lives in separate
   `.workflow/*.md` files that are lazy-loaded per the conditions in
   `AGENTS.md` §1.1, so "read this in full" stays cheap in practice, not just
   in name.

3. **Configs in YAML, not prose.** Stack, architecture, conventions are
   data, not documentation. YAML forces you to think in structure and
   doesn't allow "maybe" in key places.

4. **Explicit blocking instead of a polite reminder.** If key fields
   are empty — the agent stops. This prevents "blind" changes to a
   project the agent knows nothing about.

5. **Mandatory cycle: Analyze → Options → Plan → Execute → Verify.**
   Options with pros and cons are a defense against tunnel vision. The
   plan is self-contained so it can be resumed in a new session or
   handed off to another agent. For non-trivial behavior changes, the
   default execution mode is light TDD (`strict-lite`): start with a
   focused test unless there is a clear reason not to. For large tasks,
   the default is also to split the work into verified checkpoints with
   granular commits unless the developer disables that during bootstrap.

6. **History is local, not shared.** `.workflow/history/` is in
   `.gitignore`: it is the working context of a specific developer, not
   a project artifact. If something from the history belongs in the
   repo — move it to a regular changelog/ADR.

7. **Minimum magic and one orchestration owner.** No shipped binaries, daemons,
   MCP servers, or runtime dependencies. Shell/PowerShell + Markdown + YAML.
   Optional cross-harness orchestration is a project-local job-control script
   that starts ordinary CLI processes and persists inspectable files; it is not
   a resident service. Every shipped harness defaults to its least-privileged
   non-interactive mode — a delegated child does not get unattended write
   access to your checkout unless a team consciously opts in per harness. The
   primary user-facing harness retains architecture,
   decomposition, orchestration, review, and final verification; children only
   execute or advise within bounded slices. Native subagents are also governed
   by a local user policy: disabled, approval before each exact wave, or
   explicitly authorized automatic use.
