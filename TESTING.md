# Local Testing

This guide covers tests that can be run before opening a pull request or
publishing packages. Run commands from the repository root unless noted
otherwise.

## Safety

The automated suites use temporary directories. Packaging checks also
regenerate the ignored `packages/cli/payload/` assembly directory. The manual
mutation examples below create a disposable project from a historical fixture.
Do not point `install`, `upgrade`, `rollback`, or `cleanup` at a valuable
project until the disposable scenario behaves as expected.

Requirements:

- Node 20 or newer for the deterministic core and transactional CLI;
- Bun 1.3.14 or newer for the alternative package-manager/runtime path;
- npm with access to the public registry for dependency and package smoke tests;
- Node 22.19 or newer for the optional Pi runtime test;
- `pwsh` or Windows PowerShell for PowerShell coverage.

Install the locked development dependencies first:

```sh
npm ci
```

Or install the independently locked Bun dependency graph:

```sh
bun install --frozen-lockfile
```

## Quick Check

Run the deterministic Node suite:

```sh
npm test
```

Run the same core and CLI coverage with Bun:

```sh
bun run test:bun
```

Run installer, updater, migration, wrapper, and available PowerShell suites:

```sh
./tests/run.sh
```

If neither `pwsh` nor `powershell` is on `PATH`, the command reports the
PowerShell suite as skipped. On Windows, run it directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1
```

Check patch whitespace before committing:

```sh
git diff --check
```

## Published-Package Simulation

This is the most important local release test. It packs all four workspaces,
installs their tarballs in a clean temporary consumer without workspace links,
and exercises installed `check`, packaged-payload `upgrade`, offline
`rollback`, and explicit `cleanup`:

```sh
npm run test:package
```

The test also confirms that `hekate agent` reports `HKT950` when the optional Pi
runtime is absent. Under Node 22.19 or newer, test the opposite boundary by
installing and loading the pinned Pi runtime in the temporary consumer:

```sh
HEKATE_PACKAGE_SMOKE_PI=1 npm run test:package
```

Neither command publishes anything. Generated tarballs and consumer projects
remain under the operating system's temporary directory and are removed after
the test.

Run the equivalent flow using Bun to pack, install, and execute the tarballs:

```sh
bun run test:package:bun
```

Under Bun with optional Pi enabled:

```sh
HEKATE_PACKAGE_SMOKE_PI=1 bun run test:package:bun
```

For unpublished exact-version `@hekate/*` packages, the temporary Bun consumer
uses local `file:` overrides so no internal package is fetched from the public
registry. These overrides are test-only and are removed with the consumer.

## Manual Static Install

Use a new temporary directory to inspect the locally authored payload:

```sh
TEST_PROJECT=$(mktemp -d)
./install.sh \
  --source="$PWD" \
  --ref=HEAD \
  --target="$TEST_PROJECT" \
  --agents=claude,cursor,pi
printf 'Installed test project: %s\n' "$TEST_PROJECT"
```

Inspect the generated files and edit only this disposable project. A local
source is used, so this does not download or trust a remote revision.

PowerShell equivalent:

```powershell
$TestProject = Join-Path ([System.IO.Path]::GetTempPath()) ("hekate-manual-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $TestProject | Out-Null
.\install.ps1 -Source $PWD.Path -Ref HEAD -Target $TestProject -Agents 'claude,cursor,pi'
$TestProject
```

## Manual Transaction Lifecycle

The following POSIX scenario copies a released historical fixture, upgrades it
with the current local payload, rolls it back offline, and removes only that
transaction's recovery bundle:

```sh
REPO_ROOT=$PWD
TEST_PROJECT=$(mktemp -d)
RESULT_FILE=$(mktemp)
cp -R packages/core/test/fixtures/historical/v0.2.0-beta.1/input/. "$TEST_PROJECT/"

node packages/cli/bin/hekate.js upgrade \
  --to=0.3.0-beta.1 \
  --force \
  --dry-run \
  --json \
  --source="$REPO_ROOT" \
  --target="$TEST_PROJECT"

node packages/cli/bin/hekate.js upgrade \
  --to=0.3.0-beta.1 \
  --force \
  --yes \
  --json \
  --source="$REPO_ROOT" \
  --target="$TEST_PROJECT" > "$RESULT_FILE"

TRANSACTION_ID=$(node -e \
  'const fs = require("node:fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).transaction_id)' \
  "$RESULT_FILE")

node packages/cli/bin/hekate.js rollback \
  --transaction="$TRANSACTION_ID" \
  --dry-run \
  --json \
  --target="$TEST_PROJECT"

node packages/cli/bin/hekate.js rollback \
  --transaction="$TRANSACTION_ID" \
  --yes \
  --json \
  --target="$TEST_PROJECT"

node packages/cli/bin/hekate.js cleanup \
  --transaction="$TRANSACTION_ID" \
  --yes \
  --json \
  --target="$TEST_PROJECT"
```

Expected results:

- dry-run reports operations without changing the fixture;
- upgrade returns `ok: true` and a transaction ID;
- rollback returns `rolled_back: true` without network access;
- cleanup returns `cleaned: true` and removes only the exact-ID bundle;
- repeating cleanup returns `status: "absent"`.

Remove the disposable files when inspection is complete:

```sh
rm -rf "$TEST_PROJECT" "$RESULT_FILE"
```

## Pi Testing

### Manual Wrapper Test

The wrapper can be run directly from this checkout. First verify that its Pi SDK
loads without contacting a provider:

```sh
node packages/cli/bin/hekate.js agent --invalid
```

The expected result is the Hekate usage line and exit code 2. `HKT950` instead
means that the optional Pi runtime did not load. Running the wrapper in the
Hekate repository itself currently has an `absent` gate, so it demonstrates Pi
startup but not Hekate restrictions:

```sh
node packages/cli/bin/hekate.js check --json
node packages/cli/bin/hekate.js agent
```

To exercise the gate manually, install only the Pi adapter into a disposable
project and start the wrapper from that project:

```sh
REPO_ROOT=$PWD
PI_PROJECT=$(mktemp -d)
./install.sh \
  --source="$REPO_ROOT" \
  --ref=HEAD \
  --target="$PI_PROJECT" \
  --agents=pi

cd "$PI_PROJECT"
node "$REPO_ROOT/packages/cli/bin/hekate.js" check --json
node "$REPO_ROOT/packages/cli/bin/hekate.js" agent
```

The first check should report `needs_configuration` and `HKT210` diagnostics.
In the TUI:

1. Run `/hekate-bootstrap` and complete the authored project facts.
2. Exit the TUI and run `node "$REPO_ROOT/packages/cli/bin/hekate.js" compile`.
3. Run `node "$REPO_ROOT/packages/cli/bin/hekate.js" check --json`; it should
   report `ready` with a current lock.
4. Start `node "$REPO_ROOT/packages/cli/bin/hekate.js" agent` again and request
   a harmless write to an ordinary disposable file.
5. While the session remains open, edit `.workflow/project.yml` in another
   terminal and request another write. Live revalidation should remove mutation
   authority because the generated lock is now stale.
6. Requests to edit generated or authorization state, such as
   `.workflow/status.lock.json`, should remain blocked even in `ready` state.

Return to the repository and remove the disposable project afterwards:

```sh
cd "$REPO_ROOT"
rm -rf "$PI_PROJECT"
```

TUI and provider-backed modes follow Pi's Node `>=22.19.0` runtime contract.
Configure credentials and models through Pi's normal configuration before this
manual test; never place them in the Hekate project.

### Automated Policy Tests

Mechanical Pi policy behavior does not require provider credentials:

```sh
node --test packages/pi-extension/test/extension.test.js
node --test packages/cli/test/agent-runner.test.js
```

These tests cover absent, disabled, configuring, blocked, and ready states,
including stale or forged locks during a live session and parity across TUI,
print, JSON, and RPC modes.

An additional non-interactive provider test is optional. Configure Pi's provider
and model using Pi's normal configuration, then run under Node 22.19 or newer:

```sh
node packages/cli/bin/hekate.js agent \
  --mode=print \
  --prompt="Read the project status and report whether mutation is allowed" \
  --no-session \
  --no-trust-project
```

This can contact an external provider and incur usage charges. Do not place
credentials in the repository, command history, fixtures, or captured test
output.

## Full Local Gate

Before requesting review, run:

```sh
npm ci
npm test
npm run test:package
bun install --frozen-lockfile
bun run test:bun
bun run test:package:bun
./tests/run.sh
git diff --check
```

On Node 22.19 or newer, replace both package commands with:

```sh
HEKATE_PACKAGE_SMOKE_PI=1 npm run test:package
HEKATE_PACKAGE_SMOKE_PI=1 bun run test:package:bun
```

A local pass does not replace the GitHub Actions matrix. Windows PowerShell 5.1,
exact Node 20/22.19 runners, provider/OAuth smoke, and operational soak remain
environment-specific release evidence.

## Reporting Failures

When reporting a failure, include:

- the command that failed;
- operating system and architecture;
- `node --version`, `npm --version`, and PowerShell version when relevant;
- exit code and diagnostics such as `HKT444`, `HKT900`, `HKT902`, or `HKT950`;
- whether the failure occurred in the repository, a temporary fixture, or an
  installed-tarball consumer.

Redact credentials, provider responses, private migration archives, and project
content before sharing logs.
