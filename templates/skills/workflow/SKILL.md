---
name: workflow
description: Initialize or deliberately maintain this project's Hekate workflow configuration. Use for bootstrap, profile changes, or workflow policy edits; not for every code task.
---

# Hekate Workflow Maintenance

1. Read root `AGENTS.md` and `.workflow/status.yml`.
2. For initialization, follow `.workflow/bootstrap.md` and distinguish observed
   facts from unknown values.
3. For policy changes, update the authored owner and refresh the legacy status
   index in the same change.
4. Preserve project-owned values and unrelated extension keys.
5. Verify YAML structure and report the checks performed.

The task workflow is adaptive. Do not introduce mandatory stage artifacts,
automatic Git actions, portable native-subagent authorization, or automatic
external fallback.
