# AGENTS.md

This is the portable entry point for AI agents working in this project.
Harness-specific files point here and must not restate the workflow.

## Preflight

Read `.workflow/workflow.yml -> hekate` and `.workflow/status.yml` at session
start.

- If `hekate.enabled` or `hekate.modules.workflow` is `false`, use the
  harness's native behavior without Hekate bootstrap or task rules.
- Otherwise, if the project is not initialized or required checks are false,
  read `.workflow/bootstrap.md` before changing project files.
- Do not load every `.workflow/*` file speculatively. Read project context only
  when the task needs it.

The current `status.yml` is a legacy preflight index. It is not proof of
readiness and must not be edited merely to claim that checks passed.

## Adaptive Workflow

Use the smallest process that safely handles the task:

1. **Understand** every task. Inspect affected code, identify constraints and
   decide how the result can be verified.
2. **Decide** only when there is a material design fork, meaningful trade-off,
   difficult rollback, or an explicit request for alternatives.
3. **Plan** when work is large, risky, destructive, delegated, resumable, or
   explicitly requested. Include affected paths, steps, verification, and
   rollback where meaningful.
4. **Execute** without model-authored stage gates. Keep scope narrow and avoid
   unrelated changes.
5. **Verify** every implementation task with relevant observed evidence.

Do not invent multiple options for an obvious fix. Plan approval is required
only when the user requested planning before execution or the plan materially
changes the agreed scope.

## Tests And Evidence

Apply `.workflow/workflow.yml -> process.tdd.mode`:

- `off`: use the most appropriate verification order.
- `prefer-test-first`: prefer a focused failing test before implementation
  when practical.
- `require-test-evidence`: completion requires an observed relevant test
  result, not a claimed red-green ritual.

Passing commands are evidence, not automatic product acceptance. Report tests
that could not be run.

## Authorization Boundaries

- Never create branches or commits unless the user explicitly asks. The only
  valid portable commit consent is `explicit-request-only`; profiles do not
  grant Git authority.
- Ask before the specific destructive action. Never bypass hooks or permission
  controls to make a command succeed.
- Native subagent discovery, consent, permissions, concurrency, cancellation,
  and results belong to the active harness. The primary session retains scope,
  review, and acceptance.
- If native delegation is unavailable or declined, continue in the primary
  session. Never fall back automatically to an external harness.
- External CLI orchestration is a legacy optional component, not part of the
  portable workflow or default installation.

## Optional History

History is disabled by default. When explicitly enabled and useful for
resumable work, write one concise note under `.workflow/history/` using
`.workflow/history-format.md`. Do not create mandatory per-stage files or
events.

## Scope Control

- Do not refactor unrelated code while fixing a focused issue.
- Do not add dependencies without explicit discussion.
- Preserve user-owned configuration and unrelated worktree changes.
- Stop and report ambiguity before an operation that may lose data.

## Lazy References

| File | Read when |
|---|---|
| `.workflow/project.yml` | Commands, dependencies, runtime, framework, or architecture details matter |
| `.workflow/workflow.yml` | TDD, history, scope, or consent policy is needed |
| `.workflow/config.yml` | The selected profile or its overrides are needed |
| `.workflow/bootstrap.md` | Preflight fails or initialization is requested |
| `.workflow/history-format.md` | An optional history note is being written |
| `.workflow/README.md` | Workflow directory reference |
