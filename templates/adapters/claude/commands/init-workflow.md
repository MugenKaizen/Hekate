---
description: Initialize or refresh .workflow project configuration
---

Follow `.workflow/bootstrap.md`.

- Configure Hekate enablement and one adaptive profile.
- Inspect existing project facts before asking questions.
- Preserve unknown and project-owned values.
- Distinguish observed, unknown, and not-applicable facts.
- Refresh the legacy `.workflow/status.yml` index from authored values.
- Verify required files and fields before marking initialization complete.

Bootstrap must not create commits or branches, authorize native subagents,
configure external fallback, or create mandatory history artifacts.
