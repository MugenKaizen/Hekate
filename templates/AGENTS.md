# AGENTS.md

The single source of truth for any AI agent (Claude Code, Cursor, Codex,
Copilot, Aider, Gemini CLI, etc.) working on this project. Other
agent-specific files (`CLAUDE.md`, `.cursor/rules/*`, and so on) must
point here.

> **Rule #0.** Before doing anything in this project: read this file in full
> (it is a short, always-load core) and read `.workflow/status.yml` for the
> Hekate master switch, module allowlist, and fast pre-flight check. Everything else —
> the full history file format, cross-harness delegation mechanics,
> native-subagent policy detail, and every `.workflow/*.yml` config — is
> lazy-loaded per §1.1, **only** when the current task actually needs it.
> Loading this file is cheap by design; do not defeat that by speculatively
> reading the lazy-loaded files below "just in case." Do not read
> `.workflow/bootstrap.md` unless initialization is required.

---

## 1. Pre-flight check (required before any task)

1. Read `.workflow/status.yml` only.
2. Apply `status.yml → hekate` first:
   - if `hekate.enabled` is `false`, stop applying Hekate rules and continue
     with the harness's native/default behavior;
   - a module runs only when `hekate.enabled` and its value under
     `hekate.modules` are both `true`;
   - missing `hekate` or module keys mean `true` for compatibility with older
     installations.
3. If `hekate.modules.workflow` is `false`, skip the initialization checks
   below and use only the enabled standalone modules. Otherwise verify:
   - `initialized: true`
   - `active_preset` is not `null`
   - `checks.required_files_present: true`
   - `checks.required_fields_filled: true`
4. If `.workflow/status.yml` is missing, any required value above fails, or any value is
   `unknown` — **stop**, read `.workflow/bootstrap.md`, and run or refresh that
   procedure. Do not write code, do not create plans, do not make edits until
   initialization is complete and `.workflow/status.yml` is updated.
5. If the fast check passes — proceed to **§3 Task workflow**. When deciding
   which stages are mandatory, use `status.yml → features`. Read
   `.workflow/workflow.yml` only if a needed rule is not represented in
   `status.yml`. Use `status.yml → orchestration` to decide whether external
   harness routing is available.

### 1.1 Lazy-loading rules

Do not read detailed workflow configs speculatively. Load them only when the
current task needs the information:

- `.workflow/stack.yml` — when choosing commands, dependencies, runtime,
  framework-specific implementation, or answering stack questions.
- `.workflow/architecture.yml` — when changing module boundaries,
  dependencies, layers, architecture, or comparing solution options.
- `.workflow/conventions.yml` — when creating/editing code, tests,
  documentation, branches, or commit messages.
- `.workflow/workflow.yml` — when a process detail is missing from
  `status.yml`, or when editing workflow behavior itself.
- `.workflow/presets.yml` — only during initialization, preset changes, or
  workflow feature customization.
- `.workflow/bootstrap.md` — only when the fast pre-flight check fails or the
  user explicitly asks to initialize the workflow.
- `.workflow/orchestration.yml` — only when both
  `status.yml → hekate.modules.orchestration` and `orchestration.enabled` are
  true and the task needs cross-harness delegation or model routing.
- `.workflow/delegation.md` — only alongside `orchestration.yml`, when a task
  actually delegates to an external CLI harness (§3.6 lives here now).
- `.workflow/session.local.yml` — only before considering a native-subagent
  delegation wave or when the user asks to change its policy.
- `.workflow/subagents.md` — only before the first native-subagent wave of a
  session, or when changing that policy (§1.2 detail lives here now).
- `.workflow/history-format.md` — only when creating or updating a task
  history entry (Plan and Verify stages; §4 detail lives here now).

### 1.2 Native-subagent session policy (summary)

When `status.yml → hekate.modules.native_subagents` is `true`, the primary
harness may use its native subagents for bounded advisory,
research, review, validation, or execution work, while retaining all
architecture, decomposition, orchestration, and acceptance authority.
`subagents.mode` (from `.workflow/session.local.yml`) is `off` (never
launch), `ask` (approve each exact wave — the default when missing/invalid),
or `auto` (launch at the primary's discretion; still no push/merge/release/
destructive/recursive-delegation authority). Before the first wave of a
session, or to change the mode, read `.workflow/subagents.md` in full.

---

## 2. Bootstrap (workflow initialization)

Do **not** read bootstrap details during a normal initialized session.

Only read `.workflow/bootstrap.md` and run that procedure when the pre-flight
check above fails, or when the user explicitly asks to "initialize the
workflow" / "/init-workflow".

---

## 3. Task workflow (task execution cycle, in brief)

When `status.yml → hekate.modules.workflow` is `true`, every non-trivial task
uses **Analyze → Options → Plan → Execute → Verify**, with mandatory stages
selected by `status.yml → features`. When the module is `false`, §3.1-§3.5 do
not apply. Optional cross-harness delegation remains independently available
when its module is enabled.

### 3.1 Analyze

Understand what and why (ask if unclear); read the affected files, don't
guess. Lazy-load only the applicable sections of `architecture.yml` and
`conventions.yml`. Decide whether `light_tdd` applies and, for behavior
changes, which test comes first. If `granular_commits` is enabled, decide
whether the task is large (≥2 independently verifiable, committable
checkpoints). Record constraints: invariants and modules that must not be
touched.

### 3.2 Options

Propose **at least 2 options** (unless `status.yml` allows skipping for
trivial tasks), each with pros/cons (cons must include architecture-rule
violations). Recommend one and justify it. Wait for the user's agreement
before writing the plan.

### 3.3 Plan

Write a **self-contained** plan. When the history module is enabled, write it
to `.workflow/history/YYYY-MM-DD-<slug>.md`; otherwise keep it in the current
conversation. It must include
context, affected files, atomic steps, verification, rollback notes, and (for
large tasks under `granular_commits`) a checkpoint checklist. See
`.workflow/history-format.md` for the exact template and field rules. When
`light_tdd` applies, steps should add/update a focused test first, run the
narrowest check to see it fail, then implement the minimum to pass (or state
why test-first is impractical and add the test right after). Wait for plan
approval before executing.

### 3.4 Execute

Follow the plan step by step; if it turns out wrong, stop, update it, get
re-approval. Follow the resolved `light_tdd` mode (default `strict-lite`:
test-first unless a stated reason not to). If `granular_commits` applies,
execute checkpoint by checkpoint and commit per the resolved mode (`auto` →
commit immediately; `ask` → confirm with the user first). Commit messages follow
`conventions.yml`. No unrequested refactors, no undiscussed dependencies (see
`workflow.yml → scope_control`).

### 3.5 Verify

Run the Verification commands. If light TDD was bypassed, confirm the
follow-up test was added and passes. When the history module is enabled, update
checkpoint status and the plan file's `Result` section, then append the
applicable events to `.workflow/history/events.jsonl`. Full event schema and
allowed `type` values are in `.workflow/history-format.md`.

### 3.6 Optional cross-harness delegation

When both `.workflow/status.yml → hekate.modules.orchestration` and
`orchestration.enabled` are `true`, the primary
harness may delegate a bounded task to a configured child CLI harness via
`.workflow/bin/hekate-agent`, while retaining architecture, decomposition,
routing, review, and final-verification ownership. Read
`.workflow/delegation.md` in full before the first delegation of a session —
it has the exact commands, profile classes, and the non-negotiable delegation
rules (one writer per checkout, no re-delegation, child result is evidence
not acceptance, never bypass permissions to make an unattended run "succeed").

---

## 4. History (.workflow/history/)

Enabled only when `status.yml → hekate.modules.history` is `true`. It is
gitignored, per-developer continuity, not a shared project artifact. Every
non-trivial task gets `history/YYYY-MM-DD-<slug>.md`; with the workflow module
enabled it contains Analysis / Options / Plan / Result, otherwise it records
the context, work performed, and result without imposing those stages. Events
go to `history/events.jsonl`. Full template and event schema:
`.workflow/history-format.md` (read only during Plan/Verify — see §1.1).

---

## 5. Scope control

- **Don't do what wasn't asked for.** Fixed a bug — don't refactor the area around it.
- **Don't add dependencies** without an explicit request and a separate discussion.
- **Destructive actions** (deleting files, migrations, `git reset --hard`,
  force-push) — only with the user's explicit confirmation for the specific
  action.
- **Don't use `--no-verify`**, don't bypass hooks, don't disable linters.

---

## 6. References (pointer index)

Always-load: `status.yml` (including `hekate.enabled` and `hekate.modules`). Everything else below is lazy-loaded per §1.1 —
read only when the noted condition applies.

| File | Read when |
|---|---|
| `.workflow/status.yml` | Always, at session start |
| `.workflow/stack.yml` | Stack/command/dependency questions |
| `.workflow/architecture.yml` | Module/layer/dependency/architecture decisions |
| `.workflow/conventions.yml` | Creating/editing code, tests, docs, commits |
| `.workflow/workflow.yml` | A process detail is missing from `status.yml` |
| `.workflow/presets.yml` | Initialization, preset changes |
| `.workflow/bootstrap.md` | Pre-flight fails, or `/init-workflow` requested |
| `.workflow/orchestration.yml` | Orchestration enabled and task needs routing |
| `.workflow/delegation.md` | Actually delegating to an external CLI harness |
| `.workflow/session.local.yml` | Before a native-subagent wave, or changing policy |
| `.workflow/subagents.md` | Before the first native-subagent wave, or changing policy |
| `.workflow/history-format.md` | Creating/updating a task history entry |
| `.workflow/bin/hekate-agent` | Invoking a delegated job (persistent background controller, no MCP/daemon) |
| `.workflow/README.md` | Brief cheat sheet |
