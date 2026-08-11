# Customization

The workflow is designed to be easy to extend for a specific project or
team.

## Levels of change

### 1. Filling in the YAML (the common case)

Just fill out `.workflow/*.yml` for your stack. No need to fork anything.
The agent reads `.workflow/status.yml` every session and lazy-loads detailed
YAML only when a task needs it. If you change initialization status, required
fields, active preset, or resolved feature flags, update `status.yml` too.

### 2. Adding fields to the YAML

If you need fields that are not in the template (for example, special
environments or your company's security policies) — just add them. The
agent does not complain about "extra" keys.

For fields that should **block work** when empty, add them to
`workflow.yml → blocking.required_non_empty_fields` and mirror the check in
`.workflow/status.yml`:

```yaml
blocking:
  required_non_empty_fields:
    stack.yml: [meta.project_name, meta.project_kind, languages]
    my_custom.yml: [security.data_classification]
```

### 2b. Adding a new customizable process feature

The workflow comes with three presets — **fast**, **medium**, **full** —
plus a **custom** mode where the user toggles each feature individually.
The list of features is declared in `.workflow/presets.yml → features:`.

To add a new process feature (say, `security_review` or
`architecture_diff`):

1. Append an entry to `features:` in `.workflow/presets.yml`:

   ```yaml
   - id: security_review
     description: "Mandatory security review before Execute stage."
     controls:
       - "workflow.yml → process.security_review.enabled"
     question: "Require a security review before implementation?"
     defaults: { fast: false, medium: false, full: true }
   ```

2. If the feature needs runtime settings, add the matching block to
   `workflow.yml` under the path in `controls`.
3. Optionally reference the new feature in `AGENTS.md` §3 so the agent
   knows when to run it during the task cycle.
4. If normal task routing needs the resolved value, add it to
   `.workflow/status.yml → features` so startup stays cheap.

That's it — `/init-workflow` iterates the feature registry, so the new
feature automatically appears in both the preset application step and the
custom-mode interview. You do **not** need to touch `AGENTS.md`,
`init-workflow.md`, or any adapter file. Update `.workflow/bootstrap.md`
only if the initialization procedure itself changes.

### 3. Custom adapters for agents

If your agent is not on the list (Aider, Gemini CLI, Continue, Windsurf…),
create a file for it that points to `AGENTS.md`:

- **Aider**: add `read: [AGENTS.md, .workflow/status.yml]` to `.aider.conf.yml`.
- **Continue**: in `.continue/config.json`, set a system prompt that
  references `AGENTS.md`.
- **Windsurf / Gemini CLI**: usually read `AGENTS.md` out of the box.

You can put your own adapter into a fork of this repo under
`templates/adapters/<agent>/` and extend `install.sh` with a `has_agent`
section.

### 3b. Adding or changing a CLI harness

Cross-harness delegation is declarative in `.workflow/orchestration.yml`.
Every registry entry specifies an executable, separate argv items, prompt
transport (`stdin`, `argument`, or `file`), model/effort capabilities, and
project defaults. The runner is generic; adding a harness does not require a
pairwise adapter or code change.

Supported safe placeholders in argv items are `{model}`, `{effort}`,
`{prompt_file}`, `{session_id}`, and `{cwd}`. Commands are spawned directly,
without `eval` or a shell. Example:

```yaml
harnesses:
  my-agent:
    enabled: true
    command: my-agent
    prompt_delivery: stdin
    supports_model: true
    supports_effort: false
    default_model: vendor/model
    default_effort: default
    args:
      - "run"
      - "--model"
      - "{model}"
```

For the complete lifecycle, safety model, built-in harness matrix, and
troubleshooting, see [`docs/orchestration.md`](orchestration.md).

Keep CLI-version-specific flags here and run
`.workflow/bin/hekate-agent doctor` after upgrades. Per-developer choices
belong in the gitignored local override created by:

```sh
.workflow/bin/hekate-agent config use my-agent --model vendor/other-model
```

Do not put secrets in either config. Project-local harness entries are code
execution configuration and should only be used in trusted repositories.

### 4. A custom process

For most cases, choosing a preset (`fast` / `medium` / `full`) or the
`custom` mode at `/init-workflow` is enough — the feature registry in
`presets.yml` covers disabling Options, skipping TDD, turning off granular
commits, etc.

If the `Analyze → Options → Plan → Execute → Verify` cycle itself does
not fit, edit section 3 of `AGENTS.md` and `workflow.yml → process` — for
example, add a brand-new stage. For toggleable features, prefer adding an
entry to `presets.yml → features:` (see §2b above) rather than hardcoding
it in `AGENTS.md`.

The key is to keep a single source of truth: change behavior in
`AGENTS.md`, not in five adapters.

## Fork or edit in your own project

- **Forking the repository** makes sense if the team has stable
  non-standard rules (a custom set of YAML files, a custom set of
  stages). Install via `--repo=your-org/your-fork`.
- **Editing the files directly in the target project** fits individual
  settings for a single project.

## Versioning

The `.workflow/*.yml` files are part of the project — commit them to the repo.
The `.workflow/history/`, `.workflow/runs/`, and
`.workflow/orchestration.local.yml` paths are local and stay in `.gitignore`.

Hekate itself uses Semantic Versioning. User-visible changes belong in
[`CHANGELOG.md`](../CHANGELOG.md); the publication checklist is in
[`RELEASING.md`](../RELEASING.md). Pin installation and update URLs to a tag
for reproducible team setups.
