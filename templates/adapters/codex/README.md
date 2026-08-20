# Codex / GitHub Copilot

These agents read `AGENTS.md` from the project root directly. Codex also
loads shared Agent Skills from `.agents/skills/`; the installer deploys
both files when the Codex adapter is selected.

If you want to highlight the workflow explicitly in
`.github/copilot-instructions.md`, create the file with this content:

```markdown
This project uses AGENTS.md as the single source of truth. Read
AGENTS.md and .workflow/status.yml before any work. Do not read every
.workflow/*.yml at startup. If the fast pre-flight check in status.yml
fails, do not start work — perform the Bootstrap procedure from
`.workflow/bootstrap.md`.
```
