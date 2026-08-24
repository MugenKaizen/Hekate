# Releasing Hekate

Hekate uses Semantic Versioning. Until the workflow/configuration contracts are
stable, releases remain in the `0.x` series and may be marked as prereleases.

## Release checklist

1. Choose the version and create `docs/releases/v<version>.md`.
2. Move relevant entries from `CHANGELOG.md → Unreleased` into the versioned
   section and set the date.
3. Verify that install/update examples in the repository use the
   `<full-40-character-commit-sha>` placeholder in both the raw bootstrap URL
   and `--commit` / `-Commit`. The final SHA cannot be embedded in its own Git
   commit; it is substituted into the published GitHub Release notes after the
   release tag is created. Do not use a branch, tag, or short SHA in executable
   download examples.
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
   VERSION=v<version>
   git tag -a "$VERSION" -m "Hekate $VERSION"
   git push origin "$VERSION"
   ```

8. Create the GitHub Release manually using
   `docs/releases/$VERSION.md` as its description and mark beta tags as
   prereleases. With GitHub CLI installed:

   ```sh
   RELEASE_COMMIT=$(git rev-parse "${VERSION}^{commit}")
   test "$(printf '%s' "$RELEASE_COMMIT" | wc -c | tr -d ' ')" -eq 40
   RELEASE_NOTES=$(mktemp)
   sed "s/<full-40-character-commit-sha>/$RELEASE_COMMIT/g" \
     "docs/releases/$VERSION.md" > "$RELEASE_NOTES"
   gh release create "$VERSION" \
      --verify-tag \
      --prerelease \
      --title "Hekate $VERSION" \
      --notes-file "$RELEASE_NOTES"
   rm -f "$RELEASE_NOTES"
   ```

9. Verify the commit-pinned install and update commands from the published
   release. Confirm that omitting `--commit` / `-Commit` fails before download.

## Recovery

Do not move or recreate a published tag. If a release has a problem, fix it on
`main`, prepare the next prerelease version (for example `beta.2`), and publish
a new tag. A published release/tag is immutable project history.
