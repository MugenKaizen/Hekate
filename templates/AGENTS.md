# AGENTS.md

The single source of truth for any AI agent (Claude Code, Cursor, Codex,
Copilot, Aider, Gemini CLI, etc.) working on this project. Other
agent-specific files (`CLAUDE.md`, `.cursor/rules/*`, and so on) must
point here.

> **Rule #0.** Before doing anything in this project, read this file in
> full along with every file in `.workflow/`. If that has already been
> done in the current session, you don't need to re-read them.

---

## 1. Pre-flight check (required before any task)

1. Read `.workflow/stack.yml`, `.workflow/architecture.yml`,
   `.workflow/conventions.yml`, `.workflow/workflow.yml`,
   `.workflow/presets.yml`.
2. Verify that every required file from
   `workflow.yml → blocking.required_files` is present and every required
   field from `workflow.yml → blocking.required_non_empty_fields` is filled in.
3. If **any** file is missing, `presets.yml → meta.active_preset` is `null`,
   or a required field is empty — **stop** and go to the **Bootstrap** section
   below. Do not write code, do not create plans, do not make edits until
   initialization is complete.
4. If everything is filled in — proceed to **Task workflow**. When deciding
   which stages are mandatory, respect the feature flags in `workflow.yml`
   (which reflect the active preset from `presets.yml`).

---

## 2. Bootstrap (workflow initialization)

Run this process when the configs are empty, missing, or the user
explicitly asks to "initialize the workflow" / "/init-workflow".

### 2.0. Choose a workflow preset

Before interviewing or analyzing, read `.workflow/presets.yml`. Ask the user
**one** question first:

> Which workflow preset do you want?
> - **fast** — minimal process, plan only (no options, no TDD, no granular commits)
> - **medium** — balanced (adds options + granular commits; no TDD) *(recommended default)*
> - **full** — complete workflow (all stages + light TDD strict-lite)
> - **custom** — configure each feature individually

Show each preset's `label` and `description` from `presets.yml` verbatim.

Then:

- If the user picked **fast / medium / full**: load that preset's `features:`
  map from `presets.yml` and apply the values to the corresponding fields in
  `workflow.yml` (see each feature's `controls:` path). **Skip every bootstrap
  question about features that are disabled in the chosen preset** — for
  example, do not ask about light TDD in Fast or Medium.
- If the user picked **custom**: iterate `presets.yml → features:` in order
  and ask the feature's `question` (yes/no) for each entry. Fill
  `workflow.yml` from the answers. When a feature has `when_enabled_mode`,
  apply that mode value whenever the user enables it.

Write the chosen preset name to `.workflow/presets.yml → meta.active_preset`
and mirror it to `.workflow/workflow.yml → meta.preset`.

### 2.1. Identify the project type

- **New** (empty repo / just `git init`) → *interview* mode.
- **Existing** (has sources, manifests) → *analyze + confirm* mode.

### 2.2. New project — interview

Ask the user questions by groups, one group at a time:

1. **Meta**: name, kind (web-app / cli / library / service / …), a short
   description.
2. **Stack**: languages and versions, frameworks (backend/frontend/testing),
   databases, infrastructure, external services, commands (install/dev/test/lint/build).
3. **Architecture**: style (clean / hexagonal / ddd / mvc / modular-monolith / …),
   layers and their dependencies, major modules, patterns, anti-patterns.
4. **Conventions**: formatter, linter, line length, naming (files,
   directories, variables, classes, constants), test layout, branching
   rules. For commits, do not ask free-form questions — run the
   **Commit convention preset** procedure from §2.5 below.
5. **Workflow rules**: the process features were already decided in §2.0 via
   the chosen preset (or custom answers). Do **not** re-ask about features
   the active preset has disabled. Only confirm settings for features that
   the preset enables and that require extra parameters (e.g., commit-message
   language in §2.5). Everything else comes from `presets.yml`.

After each group, show the filled-in YAML and ask the user to confirm or adjust.

### 2.3. Existing project — analysis

Analyze the repo **on your own**, gathering facts:

- Dependency manifests: `package.json`, `pyproject.toml`, `requirements*.txt`,
  `go.mod`, `Cargo.toml`, `Gemfile`, `composer.json`, `pom.xml`, `build.gradle*`.
- Linter/formatter configs: `.eslintrc*`, `.prettierrc*`, `ruff.toml`,
  `pyproject.toml [tool.*]`, `.golangci.yml`, `rustfmt.toml`.
- Directory structure: presence of `src/`, `app/`, `internal/`, `domain/`,
  `application/`, `infrastructure/`, test directories.
- CI: `.github/workflows/`, `.gitlab-ci.yml`, `circleci/`.
- Containerization: `Dockerfile`, `docker-compose.yml`, `k8s/`.
- Commit history (`git log --oneline -n 100`) for message style.
- `README.md` for the description and run commands.

Based on the facts, fill out drafts of all four YAML files. Then:

1. Show the user the result one file at a time.
2. Explicitly flag fields you are **not sure about** (mark `# TODO: confirm`).
3. Do not fill in a field if there isn't enough evidence — leave it empty.
4. Process features (TDD, granular commits, options, …) were decided in
   §2.0 via the workflow preset. Do not re-ask about them here; the values
   in `workflow.yml` already reflect the preset from `presets.yml`.
5. For the `commits:` block, run the **Commit convention preset** procedure
   from §2.5 — first recommend a preset based on `git log --oneline -n 100`,
   then still show all presets.
6. Ask the user to confirm or correct each file.

### 2.4. Finishing initialization

- Write all YAML files: `stack.yml`, `architecture.yml`, `conventions.yml`,
  `workflow.yml`, and `presets.yml` (with `meta.active_preset` set).
- Create `.workflow/history/` if it does not exist.
- Make sure `.workflow/history/` is in `.gitignore` (if not, add it).
- Tell the user: "The workflow is initialized. You can now assign tasks."
- Create the first history entry for the bootstrap itself:
  `.workflow/history/<date>-bootstrap.md`. Include the chosen preset name
  and the resolved feature map so future sessions know what was applied.

### 2.5. Commit convention preset

Do not ask "what commit style do you use?" in the abstract. Instead show the
user the four named presets below, ask which one fits, and fill the whole
`commits:` block in `conventions.yml` from the chosen preset. If none fits,
fall back to `custom` and ask the raw fields by hand.

Presets (language is handled separately, see below — any preset works with
any language):

1. **conventional** — Conventional Commits 1.0.
   Examples: `feat(auth): add OAuth login` / `feat(auth): добавить OAuth-логин`.
2. **gitmoji** — emoji from gitmoji.dev in front of the type.
   Examples: `✨ feat(auth): add OAuth login` / `✨ feat(auth): добавить OAuth-логин`.
3. **emoji-prefix** — short local emoji map in front of the type.
   Map: `✨ feat`, `🐛 fix`, `♻️ refactor`, `📝 docs`, `✅ test`, `🚀 perf`,
   `🔧 chore`, `⏪ revert`. Example: `🐛 fix(api): handle empty body`.
4. **free-form** — no strict template, only the subject length is enforced.
   Example: `Fix empty body handling in API`.

Fifth option — `custom`: if none of the presets fits, ask the user to fill
the raw `commits:` fields manually.

For an existing project, first look at `git log --oneline -n 100`, try to
guess which preset the history already matches, and recommend it — but still
show the full list.

After the user picks a preset, fill `conventions.yml → commits:` exactly from
the template below. The `language` value comes from a separate question (see
next subsection) and is **not** part of the preset.

```yaml
# conventional
commits:
  style: conventional
  preset: conventional
  subject_max_length: 72
  language: <from the user's language answer>
  require_body_for: [feat, fix, refactor]
  forbid_in_subject: ["ticket numbers without prefix"]

# gitmoji
commits:
  style: gitmoji
  preset: gitmoji
  subject_max_length: 72
  language: <from the user's language answer>
  require_body_for: [feat, fix, refactor]
  forbid_in_subject: []
  # full map: see https://gitmoji.dev

# emoji-prefix
commits:
  style: conventional
  preset: emoji-prefix
  subject_max_length: 72
  language: <from the user's language answer>
  require_body_for: [feat, fix, refactor]
  forbid_in_subject: []
  emoji_map:
    feat: "✨"
    fix: "🐛"
    refactor: "♻️"
    docs: "📝"
    test: "✅"
    perf: "🚀"
    chore: "🔧"
    revert: "⏪"

# free-form
commits:
  style: free-form
  preset: free-form
  subject_max_length: 72
  language: <from the user's language answer>
  require_body_for: []
  forbid_in_subject: []
```

#### Commit message language (separate question)

Right after the preset is chosen, ask one extra question:

> In which language should commit subjects and bodies be written?
> `en | ru | de | es | fr | pt | zh | ja | other` — or a free string,
> e.g. `ru-en-mix` for a mixed style.

Write the user's answer verbatim into `commits.language`. For an existing
project, first look at `git log` to estimate the dominant language and offer
it as the default — but accept whatever the user says.

### 2.6. Extending with new process features

The registry of customizable process features lives in
`.workflow/presets.yml → features:`. To add a new customizable step to the
workflow (e.g., `security_review`, `architecture_diff`, `dependency_audit`):

1. Append one entry to `presets.yml → features:` with a unique `id`,
   a `description`, a `question` (for custom mode), a `controls:` list
   naming the `workflow.yml` paths it writes to, and `defaults:` with a
   boolean for each of `fast`, `medium`, `full`.
2. If needed, add the matching block to `.workflow/workflow.yml` at the
   path named in `controls`.
3. Optionally reference the new feature from §3 (Task workflow) so agents
   know when to run it.

**Do not** hardcode new features in this file, in `init-workflow.md`, or in
adapter files. The bootstrap procedure is data-driven over `presets.yml` —
a new entry automatically appears in preset application and custom mode.

---

## 3. Task workflow (task execution cycle)

For **every non-trivial task**, this order is required:

### 3.1. Analyze

- Understand **what** is being asked and **why**. If the goal is unclear,
  ask clarifying questions before starting the analysis.
- Find and read the affected files. Don't guess — read.
- Check the applicable sections of `.workflow/architecture.yml` and
  `.workflow/conventions.yml`.
- Decide whether `workflow.yml → process.light_tdd` applies to this task.
  For behavior changes, identify which test should be added or updated first.
- If `workflow.yml → process.granular_commits` is enabled, decide whether the
  task is large. A large task has at least 2 independently verifiable
  checkpoints that can be completed and committed without leaving the branch in
  a broken state.
- Record the constraints: which invariants must not be violated, which
  modules must not be touched.

### 3.2. Options

- Propose **at least 2 options** for the solution (unless `workflow.yml`
  allows skipping for trivial tasks).
- For each option — **pros** and **cons**. The cons must include
  architectural rule violations if there are any.
- Explicitly recommend one and justify the choice.
- Wait for the user's agreement on an option before writing the plan.

### 3.3. Plan

The plan is written to `.workflow/history/YYYY-MM-DD-<slug>.md` and must
be **self-contained** — it can be opened in a new session without context
and executed. The plan must include:

1. **Context** — why this task exists, what problem it solves.
2. **Affected files** — full paths of every file to be created or
   modified, with a short description of the changes.
3. **Steps** — step-by-step actions. Each step is an atomic change.
4. **Verification** — how to confirm the task is done (test commands,
   manual check scenarios, expected behavior).
5. **Rollback notes** — what to do if something goes wrong (for risky
   changes).
6. **Checkpoint checklist** — required for large tasks when
   `workflow.yml → process.granular_commits.enabled` is `true`.

When `workflow.yml → process.light_tdd` applies, the steps should reflect a
lightweight TDD loop: add or update a focused test first, run the narrowest
relevant check if practical to see it fail, then implement the minimum code
needed to make it pass. If test-first is impractical, explicitly state why in
Analysis or Plan and add the test immediately after implementation.

When `workflow.yml → process.granular_commits` applies, the plan must include
checkpoint boundaries in the same history file. Each checkpoint must describe:

- the slice of work being completed;
- the verification required before it counts as done;
- the commit message to use after successful verification.

Wait for plan approval before executing.

### 3.4. Execute

- Follow the plan step by step.
- If along the way you realize the plan is wrong — stop, update the plan,
  get re-approval.
- For non-trivial behavior changes, follow `workflow.yml → process.light_tdd`.
  The default mode is `strict-lite`: use test-first unless there is a clear,
  stated reason not to.
- If `workflow.yml → process.granular_commits` applies, execute checkpoint by
  checkpoint. After a checkpoint is verified, mark it complete in the task
  history and handle the commit according to `process.granular_commits.mode`:
  - `auto` — create the commit immediately.
  - `ask` — stop and ask the user before creating the commit.
- Commit messages for checkpoints must follow `.workflow/conventions.yml`.
- Don't do unrequested refactors and don't add dependencies that aren't
  in the plan (see `workflow.yml → scope_control`).

### 3.5. Verify

- Run the commands from the Verification section.
- If light TDD was bypassed, verify that the follow-up test was still added
  and passes.
- For tasks with checkpoint checklists, update the checklist status after each
  verified checkpoint and append `checkpoint_completed` /
  `checkpoint_committed` events when they happen.
- Update the `result` section in the task history file: what was done,
  what was checked, known limitations.
- Append an event to `.workflow/history/events.jsonl`:
  `{"ts": "<ISO-8601>", "task_slug": "<slug>", "type": "verified", "summary": "<1 line>"}`.

---

## 4. History (.workflow/history/)

This directory is **in `.gitignore`** and is not shared with the team. It
exists so the agent has continuity between sessions.

### 4.1. Markdown per task

`.workflow/history/YYYY-MM-DD-<kebab-slug>.md`:

```markdown
# <Task title>

## Analysis
<what was understood, which files were studied, which constraints apply>

## Options
### Option 1: <name>
- Pros: …
- Cons: …
### Option 2: <name>
- Pros: …
- Cons: …
**Chosen:** Option N — <rationale>

## Plan
### Context
### Affected files
### Steps
### Verification
### Rollback notes

## Checkpoint checklist
- [ ] CP1. <checkpoint title>
  - Verify: <command or scenario>
  - Commit: <message>
- [x] CP2. <checkpoint title>
  - Verify: <command or scenario>
  - Commit: <message>

## Result
<what was done, checks performed, remaining TODOs>
```

The `Checkpoint checklist` section is required only for large tasks when
`workflow.yml → process.granular_commits.enabled` is `true`.

### 4.2. events.jsonl

Every significant state change — one JSON line:

```json
{"ts":"2026-04-22T10:15:00Z","task_slug":"add-user-export","type":"started","summary":"user asked to add CSV export"}
{"ts":"2026-04-22T10:18:00Z","task_slug":"add-user-export","type":"analyzed","summary":"touched files: src/users/*, src/export/*"}
{"ts":"2026-04-22T10:22:00Z","task_slug":"add-user-export","type":"options_proposed","summary":"2 options: streaming vs buffered"}
{"ts":"2026-04-22T10:25:00Z","task_slug":"add-user-export","type":"planned","summary":"see history/2026-04-22-add-user-export.md"}
{"ts":"2026-04-22T10:33:00Z","task_slug":"add-user-export","type":"checkpoint_completed","summary":"CP1 tests added and passing"}
{"ts":"2026-04-22T10:35:00Z","task_slug":"add-user-export","type":"checkpoint_committed","summary":"test(users): cover export validation"}
{"ts":"2026-04-22T10:40:00Z","task_slug":"add-user-export","type":"verified","summary":"tests green, manual export of 10k rows OK"}
```

Allowed `type` values: `started | analyzed | options_proposed | planned | checkpoint_completed | checkpoint_committed | executed | verified | blocked`.

---

## 5. Scope control

- **Don't do what wasn't asked for.** Fixed a bug — don't refactor the area around it.
- **Don't add dependencies** without an explicit request and a separate discussion.
- **Destructive actions** (deleting files, migrations, `git reset --hard`,
  force-push) — only with the user's explicit confirmation for the specific
  action.
- **Don't use `--no-verify`**, don't bypass hooks, don't disable linters.

---

## 6. References

- `.workflow/stack.yml` — technology stack
- `.workflow/architecture.yml` — architecture
- `.workflow/conventions.yml` — code style and conventions
- `.workflow/workflow.yml` — agent's working rules
- `.workflow/README.md` — brief cheat sheet
