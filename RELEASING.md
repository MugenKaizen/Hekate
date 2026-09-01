# Releasing Hekate

Hekate uses Semantic Versioning. Until the workflow/configuration contracts are
stable, releases remain in the `0.x` series and may be marked as prereleases.

## Release checklist

1. Choose the version, update the root and all workspace package versions plus
   exact internal `@hekate/*` dependencies, refresh `package-lock.json` and
   `bun.lock`, and create `docs/releases/v<version>.md`.
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
   npm ci
   bun install --frozen-lockfile
   npm run build:runtime
   git diff --exit-code -- distribution/runtime
   npm test
   bun run test:bun
   HEKATE_PACKAGE_SMOKE_PI=1 npm run test:package
   HEKATE_PACKAGE_SMOKE_PI=1 bun run test:package:bun
   ./tests/run.sh
   sh -n install.sh update.sh update-runner.sh migrations/*.sh \
     templates/.workflow/bin/hekate-agent tests/*.sh
   git diff --check
   ```

   The npm and Bun package smokes each pack every workspace, install the
   tarballs without workspace links, and exercise the packaged payload,
   rollback, cleanup, and optional Pi runtime boundary. The regular runtime
   tests also enforce the CLI tarball inventory with both packers. npm remains
   the publication transport for the npm registry.
   The runtime build must reproduce the committed commit-pinned transactional
   artifact byte-for-byte; portable update and offline rollback do not use npm.

5. Run `tests/run.ps1` under Windows PowerShell 5.1. CI must pass both the
   Windows PowerShell and POSIX jobs before release.
6. Confirm that `migrations/001-*` through `009-*` remain the exact frozen
   legacy migration set on both platforms. Do not add regex migration `010`.
   Changes to existing migrations are limited to critical safety corrections
   with regression fixtures. New configuration upgrades belong in the typed v1
   importer.
7. Review and merge the release pull request into `main`.
8. Create and push an annotated tag from the merged commit:

   ```sh
   git switch main
   git pull --ff-only
   VERSION=v<version>
   git tag -a "$VERSION" -m "Hekate $VERSION"
   git push origin "$VERSION"
   ```

9. Publish npm packages from the tagged commit in dependency order. Confirm the
   authenticated npm account has access to the `@hekate` scope before running:

   ```sh
   npm publish --workspace=@hekate/core --tag beta
   npm publish --workspace=@hekate/subagents --tag beta
   npm publish --workspace=@hekate/pi-extension --tag beta
   npm publish --workspace=@hekate/cli --tag beta
   ```

10. Create the GitHub Release manually using
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

11. Verify the commit-pinned install and update commands from the published
   release. Confirm that omitting `--commit` / `-Commit` fails before download.

## Recovery

Do not move or recreate a published tag. If a release has a problem, fix it on
`main`, prepare the next prerelease version (for example `beta.2`), and publish
a new tag. A published release/tag is immutable project history.
