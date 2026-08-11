# Releasing Hekate

Hekate uses Semantic Versioning. Until the workflow/configuration contracts are
stable, releases remain in the `0.x` series and may be marked as prereleases.

## Release checklist

1. Choose the version and create `docs/releases/v<version>.md`.
2. Move relevant entries from `CHANGELOG.md → Unreleased` into the versioned
   section and set the date.
3. Verify that install/update examples in the release notes use the exact tag.
4. Run locally:

   ```sh
   ./tests/run.sh
   sh -n install.sh update.sh update-runner.sh migrations/*.sh \
     templates/.workflow/bin/hekate-agent tests/*.sh
   git diff --check
   ```

5. Smoke-test `templates/.workflow/bin/hekate-agent.ps1` on Windows when the
   release changes PowerShell behavior.
6. Review and merge the release pull request into `main`.
7. Create and push an annotated tag from the merged commit:

   ```sh
   git switch main
   git pull --ff-only
   git tag -a v0.1.0-beta.1 -m "Hekate v0.1.0-beta.1"
   git push origin v0.1.0-beta.1
   ```

8. Create the GitHub Release manually using
   `docs/releases/v0.1.0-beta.1.md` as its description and mark beta tags as
   prereleases. With GitHub CLI installed:

   ```sh
   gh release create v0.1.0-beta.1 \
     --verify-tag \
     --prerelease \
     --title "Hekate v0.1.0-beta.1 — Cross-harness orchestration" \
     --notes-file docs/releases/v0.1.0-beta.1.md
   ```

9. Verify the tag-pinned install and update commands from the published release.

## Recovery

Do not move or recreate a published tag. If a release has a problem, fix it on
`main`, prepare the next prerelease version (for example `beta.2`), and publish
a new tag. A published release/tag is immutable project history.
