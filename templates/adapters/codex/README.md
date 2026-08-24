# Codex

Codex reads `AGENTS.md` from the project root directly and needs no
adapter-specific pointer file. It also loads shared Agent Skills from
`.agents/skills/`; the installer deploys both when the Codex adapter is
selected.

For GitHub Copilot, use the `copilot` adapter instead (`--agents=copilot`),
which installs a real `.github/copilot-instructions.md` pointer file.
