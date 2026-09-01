[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('hekate-update-common-' + [Guid]::NewGuid().ToString('N'))

function TestFail([string]$Message) { throw "FAIL: $Message" }

try {
    New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
    . (Join-Path $RepoRoot 'lib\update-common.ps1')

    $stateFile = Join-Path $Tmp 'state.yml'
    $stateLines = @(
        'schema:',
        '  state_version: 2',
        '  applied_migrations:',
        '    - 001-first',
        '    - 002_second.test',
        '    - {ran_at: "legacy-pollution"}',
        '',
        '    # A comment inside the list does not terminate it.',
        '  history:',
        '    - {ran_at: "2026-08-30T00:00:00Z"}',
        'other:',
        '  items:',
        '    - not-a-migration'
    )
    [System.IO.File]::WriteAllLines($stateFile, $stateLines, [System.Text.Encoding]::UTF8)

    $actual = @(Get-AawAppliedMigrations $stateFile)
    $expected = @('001-first', '002_second.test')
    if ($actual.Count -ne $expected.Count) {
        TestFail "expected $($expected.Count) migrations, got $($actual.Count): $($actual -join ', ')"
    }
    for ($i = 0; $i -lt $expected.Count; $i++) {
        if ($actual[$i] -ne $expected[$i]) {
            TestFail "expected migration [$($expected[$i])] at index $i, got [$($actual[$i])]"
        }
    }

    $emptyState = Join-Path $Tmp 'empty-state.yml'
    [System.IO.File]::WriteAllLines($emptyState, @('schema:', '  applied_migrations: []', '  history:', '    - ignored'), [System.Text.Encoding]::UTF8)
    if (@(Get-AawAppliedMigrations $emptyState).Count -ne 0) {
        TestFail 'empty migration ledger returned entries'
    }

    # Migration-ledger parser: shares tests/test-ledger-fixtures with the POSIX
    # half (tests/test-ledger-parser.sh) so both readers are asserted against
    # byte-identical input and the same *.expected results. Do not fork the
    # fixtures.
    $fixtureRoot = Join-Path $PSScriptRoot 'test-ledger-fixtures'
    # IDs that must never be reported as applied: they live in update-history
    # entries, sibling keys, or malformed rows.
    $forbiddenIds = @(
        'not-a-migration',
        'leaked-history-entry',
        'deeper-not-an-item',
        'history',
        'ran_at',
        '003-never-applied',
        '002-add-status-index'
    )

    foreach ($fixture in @('indented', 'same-indent', 'empty-list', 'missing-key', 'history-after-list', 'malformed')) {
        $fixtureState = Join-Path $fixtureRoot "$fixture.yml"
        $fixtureExpected = Join-Path $fixtureRoot "$fixture.expected"
        if (-not (Test-Path -LiteralPath $fixtureState)) { TestFail "missing ledger fixture: $fixtureState" }
        if (-not (Test-Path -LiteralPath $fixtureExpected)) { TestFail "missing expected output: $fixtureExpected" }

        $want = @(@(Get-Content -LiteralPath $fixtureExpected) | Where-Object { $_ -ne '' })
        $got = @(Get-AawAppliedMigrations $fixtureState)
        if ($got.Count -ne $want.Count) {
            TestFail "ledger fixture ${fixture}: expected [$($want -join ', ')], got [$($got -join ', ')]"
        }
        for ($i = 0; $i -lt $want.Count; $i++) {
            if ($got[$i] -cne $want[$i]) {
                TestFail "ledger fixture ${fixture}: expected [$($want[$i])] at index $i, got [$($got[$i])]"
            }
        }

        # Every seeded ID must also answer true through the membership check,
        # so an already-recorded migration is never re-run.
        foreach ($id in $want) {
            if (-not (Test-AawStateHasMigration $id $fixtureState)) {
                TestFail "ledger fixture ${fixture}: Test-AawStateHasMigration did not find seeded ID $id"
            }
        }

        # Nothing outside the applied-migrations list may leak in.
        foreach ($forbidden in $forbiddenIds) {
            if ($want -contains $forbidden) { continue }
            if (Test-AawStateHasMigration $forbidden $fixtureState) {
                TestFail "ledger fixture ${fixture}: parser leaked unrelated entry $forbidden"
            }
        }
    }

    # Regression guard for the same-indentation block sequence (audit finding
    # G5). A ledger written as `  applied_migrations:` followed by
    # `  - 001-...` is valid YAML; the previous indentation-sensitive scanner
    # dropped every entry, which silently re-ran applied migrations.
    $sameIndent = @(Get-AawAppliedMigrations (Join-Path $fixtureRoot 'same-indent.yml'))
    $indented = @(Get-AawAppliedMigrations (Join-Path $fixtureRoot 'indented.yml'))
    if ($sameIndent.Count -eq 0) { TestFail 'same-indentation ledger produced no migration IDs' }
    if (($sameIndent -join "`n") -cne ($indented -join "`n")) {
        TestFail 'same-indentation and indented ledgers disagree'
    }

    # A missing state file yields no migrations and no membership.
    $absentState = Join-Path $Tmp 'definitely-absent.yml'
    if (@(Get-AawAppliedMigrations $absentState).Count -ne 0) {
        TestFail 'missing state file produced migration IDs'
    }
    if (Test-AawStateHasMigration '001-add-three-branch-model' $absentState) {
        TestFail 'missing state file reported an applied migration'
    }

    # An empty ID never matches.
    if (Test-AawStateHasMigration '' (Join-Path $fixtureRoot 'indented.yml')) {
        TestFail 'empty migration ID matched the ledger'
    }

    $project = Join-Path $Tmp 'project'
    $script:TARGET = $project
    $script:BACKUP_ROOT = Join-Path $project '.workflow\backups'
    $script:RUN_BACKUP_DIR = Join-Path $script:BACKUP_ROOT '20260830T120000Z'
    $script:BACKED_UP_LIST_FILE = Join-Path $Tmp 'backed-up.txt'
    $script:DRY_RUN = $false
    New-Item -ItemType Directory -Force -Path $project | Out-Null
    New-Item -ItemType File -Force -Path $script:BACKED_UP_LIST_FILE | Out-Null

    $managedFile = Join-Path $project 'AGENTS.md'
    [System.IO.File]::WriteAllText($managedFile, "original`n")
    Backup-AawFile 'AGENTS.md'
    [System.IO.File]::WriteAllText($managedFile, "changed`n")
    Backup-AawFile 'AGENTS.md'
    $backupFile = Join-Path $script:RUN_BACKUP_DIR 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $backupFile)) { TestFail 'backup file was not created' }
    if ([System.IO.File]::ReadAllText($backupFile) -ne "original`n") {
        TestFail 'repeated backup did not retain the first snapshot'
    }

    foreach ($day in 1..7) {
        $name = '202601{0:D2}T000000Z' -f $day
        New-Item -ItemType Directory -Force -Path (Join-Path $script:BACKUP_ROOT $name) | Out-Null
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $script:BACKUP_ROOT 'legacy-data') | Out-Null
    Remove-AawOldBackupRuns 5
    $remainingRuns = @(Get-ChildItem -LiteralPath $script:BACKUP_ROOT -Directory | Where-Object { $_.Name -match '^[0-9]{8}T[0-9]{6}Z$' })
    if ($remainingRuns.Count -ne 5) { TestFail "expected 5 retained backup runs, got $($remainingRuns.Count)" }
    if (-not (Test-Path -LiteralPath (Join-Path $script:BACKUP_ROOT 'legacy-data'))) {
        TestFail 'backup pruning removed a legacy directory'
    }

    Write-Host 'ok: PowerShell update-common tests passed'
} catch {
    Write-Error $_
    exit 1
} finally {
    if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
exit 0
