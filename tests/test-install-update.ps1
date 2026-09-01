[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ('hekate install update-' + [Guid]::NewGuid().ToString('N'))
$Project = Join-Path $Tmp 'project'
$ShellExe = (Get-Process -Id $PID).Path

function TestFail([string]$Message) { throw "FAIL: $Message" }

function Invoke-TestScript {
    param([string]$Script, [string[]]$Arguments)
    $stdoutFile = Join-Path $Tmp ('stdout-' + [Guid]::NewGuid().ToString('N') + '.log')
    $stderrFile = Join-Path $Tmp ('stderr-' + [Guid]::NewGuid().ToString('N') + '.log')
    & $ShellExe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 1>$stdoutFile 2>$stderrFile
    $code = $LASTEXITCODE
    $stdout = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrFile) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
    return [PSCustomObject]@{ Code = $code; Out = $stdout; Err = $stderr }
}

function Assert-Exists([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { TestFail "expected path to exist: $Path" }
}

function Assert-Absent([string]$Path) {
    if (Test-Path -LiteralPath $Path) { TestFail "expected path to be absent: $Path" }
}

try {
    New-Item -ItemType Directory -Force -Path $Project | Out-Null
    $install = Invoke-TestScript (Join-Path $RepoRoot 'install.ps1') @(
        '-Source', $RepoRoot, '-Target', $Project, '-Agents', 'claude', '-Ref', 'HEAD', '-LegacyWorkflowFiles'
    )
    if ($install.Code -ne 0) { TestFail "fresh install failed: $($install.Err)" }

    Assert-Exists (Join-Path $Project 'AGENTS.md')
    Assert-Exists (Join-Path $Project '.workflow\workflow.yml')
    Assert-Exists (Join-Path $Project '.workflow\config.yml')
    Assert-Exists (Join-Path $Project '.workflow\project.yml')
    Assert-Exists (Join-Path $Project '.workflow\history-format.md')
    Assert-Exists (Join-Path $Project '.claude\commands\plan.md')
    Assert-Absent (Join-Path $Project '.workflow\orchestration.yml')
    Assert-Absent (Join-Path $Project '.workflow\session.local.yml')
    Assert-Absent (Join-Path $Project '.workflow\delegation.md')
    Assert-Absent (Join-Path $Project '.workflow\subagents.md')
    Assert-Absent (Join-Path $Project '.workflow\bin\hekate-agent')
    Assert-Absent (Join-Path $Project '.workflow\bin\hekate-agent.ps1')
    Assert-Absent (Join-Path $Project '.claude\commands\harness.md')
    Assert-Absent (Join-Path $Project '.claude\agents\harness-orchestrator.md')

    # The legacy project-fact files and the preset registry are opt-in.
    Assert-Exists (Join-Path $Project '.workflow\stack.yml')
    Assert-Exists (Join-Path $Project '.workflow\presets.yml')
    $defaultProject = Join-Path $Tmp 'default-payload'
    New-Item -ItemType Directory -Force -Path $defaultProject | Out-Null
    $defaultInstall = Invoke-TestScript (Join-Path $RepoRoot 'install.ps1') @(
        '-Source', $RepoRoot, '-Target', $defaultProject, '-Agents', 'claude', '-Ref', 'HEAD'
    )
    if ($defaultInstall.Code -ne 0) { TestFail "default install failed: $($defaultInstall.Err)" }
    Assert-Exists (Join-Path $defaultProject '.workflow\config.yml')
    Assert-Exists (Join-Path $defaultProject '.workflow\project.yml')
    Assert-Exists (Join-Path $defaultProject '.workflow\workflow.yml')
    Assert-Exists (Join-Path $defaultProject '.workflow\status.yml')
    Assert-Absent (Join-Path $defaultProject '.workflow\stack.yml')
    Assert-Absent (Join-Path $defaultProject '.workflow\architecture.yml')
    Assert-Absent (Join-Path $defaultProject '.workflow\conventions.yml')
    Assert-Absent (Join-Path $defaultProject '.workflow\presets.yml')

    # An unknown adapter name is rejected instead of installing core only.
    $unknownProject = Join-Path $Tmp 'unknown-adapter'
    New-Item -ItemType Directory -Force -Path $unknownProject | Out-Null
    $unknown = Invoke-TestScript (Join-Path $RepoRoot 'install.ps1') @(
        '-Source', $RepoRoot, '-Target', $unknownProject, '-Agents', 'clod', '-Ref', 'HEAD'
    )
    if ($unknown.Code -eq 0) { TestFail 'installer accepted an unknown adapter' }
    Assert-Absent (Join-Path $unknownProject 'AGENTS.md')

    $piProject = Join-Path $Tmp 'pi-project'
    New-Item -ItemType Directory -Force -Path (Join-Path $piProject '.pi') | Out-Null
    $piSettings = Join-Path $piProject '.pi\settings.json'
    [System.IO.File]::WriteAllText($piSettings, "{`"theme`":`"user-owned`"}`n")
    $piSettingsBefore = [System.IO.File]::ReadAllText($piSettings)
    $piInstall = Invoke-TestScript (Join-Path $RepoRoot 'install.ps1') @('-Source', $RepoRoot, '-Target', $piProject, '-Agents', 'pi', '-Ref', 'HEAD')
    if ($piInstall.Code -ne 0) { TestFail "Pi install failed: $($piInstall.Err)" }
    Assert-Exists (Join-Path $piProject '.pi\prompts\analyze.md')
    Assert-Exists (Join-Path $piProject '.pi\prompts\init-workflow.md')
    Assert-Exists (Join-Path $piProject '.pi\prompts\plan.md')
    Assert-Exists (Join-Path $piProject '.agents\skills\workflow\SKILL.md')
    if ([System.IO.File]::ReadAllText($piSettings) -ne $piSettingsBefore) { TestFail 'Pi install changed user-owned settings' }
    $piUpgrade = Invoke-TestScript (Join-Path $RepoRoot 'install.ps1') @('-Source', $RepoRoot, '-Target', $piProject, '-Agents', 'pi', '-Ref', 'HEAD', '-Force', '-Yes')
    if ($piUpgrade.Code -ne 0) { TestFail "Pi transactional upgrade failed:`nOUT: $($piUpgrade.Out)`nERR: $($piUpgrade.Err)" }
    if ([System.IO.File]::ReadAllText($piSettings) -ne $piSettingsBefore) { TestFail 'Pi upgrade changed user-owned settings' }

    $forceDry = Invoke-TestScript (Join-Path $RepoRoot 'install.ps1') @(
        '-Source', $RepoRoot, '-Target', $Project, '-Agents', 'claude', '-Ref', 'HEAD', '-LegacyWorkflowFiles', '-Force', '-ReplaceUnowned', '-DryRun'
    )
    if ($forceDry.Code -ne 0) { TestFail "transactional install dry-run failed: $($forceDry.Err)" }
    if (($forceDry.Out + $forceDry.Err) -notmatch 'transaction:') { TestFail 'install -Force did not delegate to the transaction engine' }
    Assert-Absent (Join-Path $Project '.workflow\install-state.json')

    $forceApply = Invoke-TestScript (Join-Path $RepoRoot 'install.ps1') @(
        '-Source', $RepoRoot, '-Target', $Project, '-Agents', 'claude', '-Ref', 'HEAD', '-LegacyWorkflowFiles', '-Force', '-Yes'
    )
    if ($forceApply.Code -ne 0) { TestFail "transactional install failed: $($forceApply.Err)" }
    Assert-Exists (Join-Path $Project '.workflow\install-state.json')
    $journal = Get-ChildItem -LiteralPath (Join-Path $Project '.workflow\transactions') -Filter 'operation-journal.json' -Recurse | Select-Object -First 1
    if (-not $journal -or ([System.IO.File]::ReadAllText($journal.FullName) -notmatch '"status":"committed"')) {
        TestFail 'transactional install did not commit its journal'
    }
    $transactionId = $journal.Directory.Name
    $recoveryRuntime = Join-Path $journal.Directory.FullName 'runtime\src\hekate-cli.mjs'
    Assert-Exists $recoveryRuntime
    & node $recoveryRuntime rollback "--transaction=$transactionId" --dry-run --json "--target=$Project" | Out-Null
    if ($LASTEXITCODE -ne 0) { TestFail 'retained standalone runtime could not plan offline rollback' }

    $updateForceDry = Invoke-TestScript (Join-Path $RepoRoot 'update.ps1') @(
        '-Source', $RepoRoot, '-Target', $Project, '-Agents', 'claude', '-Ref', 'HEAD', '-Force', '-DryRun'
    )
    if ($updateForceDry.Code -ne 0) { TestFail "transactional update dry-run failed: $($updateForceDry.Err)" }
    if (($updateForceDry.Out + $updateForceDry.Err) -notmatch 'transaction:') { TestFail 'update -Force did not delegate to the transaction engine' }
    $runnerForceDry = Invoke-TestScript (Join-Path $RepoRoot 'update-runner.ps1') @(
        '-Target', $Project, '-Agents', 'claude', '-Ref', 'HEAD', '-Force', '-ReplaceUnowned', '-DryRun'
    )
    if ($runnerForceDry.Code -ne 0) { TestFail "transactional runner dry-run failed: $($runnerForceDry.Err)" }
    if (($runnerForceDry.Out + $runnerForceDry.Err) -notmatch 'transaction:') { TestFail 'runner -Force did not delegate to the transaction engine' }

    $statePath = Join-Path $Project '.workflow\state.yml'
    $stateBefore = [System.IO.File]::ReadAllText($statePath)
    Start-Sleep -Milliseconds 1100
    $update1 = Invoke-TestScript (Join-Path $RepoRoot 'update-runner.ps1') @('-Target', $Project, '-Ref', 'HEAD')
    if ($update1.Code -ne 0) { TestFail "first update failed: $($update1.Err)" }
    $stateAfter1 = [System.IO.File]::ReadAllText($statePath)
    if ($stateAfter1 -eq $stateBefore) { TestFail 'first update did not refresh state' }

    Start-Sleep -Milliseconds 1100
    $update2 = Invoke-TestScript (Join-Path $RepoRoot 'update-runner.ps1') @('-Target', $Project, '-Ref', 'HEAD')
    if ($update2.Code -ne 0) { TestFail "second update failed: $($update2.Err)" }
    $stateAfter2 = [System.IO.File]::ReadAllText($statePath)
    if ($stateAfter2 -eq $stateAfter1) { TestFail 'second update did not refresh state history' }

    $applied = @(Get-Content -LiteralPath $statePath)
    $inMigrations = $false
    foreach ($line in $applied) {
        if ($line -eq '  applied_migrations:') { $inMigrations = $true; continue }
        if ($inMigrations -and $line -match '^  \S') { $inMigrations = $false }
        if ($inMigrations -and $line -match '\{ran_at:') {
            TestFail 'update history contaminated applied migrations'
        }
    }

    Assert-Absent (Join-Path $Project '.workflow\orchestration.yml')
    Assert-Absent (Join-Path $Project '.claude\commands\harness.md')

    $backupRoot = Join-Path $Project '.workflow\backups'
    $latest = Get-ChildItem -LiteralPath $backupRoot -Directory |
        Where-Object { $_.Name -match '^[0-9]{8}T[0-9]{6}Z$' } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $latest) { TestFail 'update did not create a rollback snapshot' }
    [System.IO.File]::WriteAllText((Join-Path $latest.FullName 'AGENTS.md'), "backup sentinel`n")
    [System.IO.File]::WriteAllText((Join-Path $Project 'AGENTS.md'), "live sentinel`n")

    $dryRollback = Invoke-TestScript (Join-Path $RepoRoot 'update-runner.ps1') @('-Target', $Project, '-Rollback', '-DryRun')
    if ($dryRollback.Code -ne 0) { TestFail "rollback dry-run failed: $($dryRollback.Err)" }
    if ([System.IO.File]::ReadAllText((Join-Path $Project 'AGENTS.md')) -ne "live sentinel`n") {
        TestFail 'rollback dry-run changed a managed file'
    }
    if ([System.IO.File]::ReadAllText($statePath) -ne $stateAfter2) {
        TestFail 'rollback dry-run changed installation state'
    }

    $rollback = Invoke-TestScript (Join-Path $RepoRoot 'update-runner.ps1') @('-Target', $Project, '-Rollback')
    if ($rollback.Code -ne 0) { TestFail "rollback failed: $($rollback.Err)" }
    if ([System.IO.File]::ReadAllText((Join-Path $Project 'AGENTS.md')) -ne "backup sentinel`n") {
        TestFail 'rollback did not restore a managed file'
    }
    $stateAfterRollback = [System.IO.File]::ReadAllText($statePath)
    if ($stateAfterRollback -ne $stateAfter1) {
        $snapshotStatePath = Join-Path $latest.FullName '.workflow\state.yml'
        $snapshotState = if (Test-Path -LiteralPath $snapshotStatePath) { [System.IO.File]::ReadAllText($snapshotStatePath) } else { '<missing>' }
        TestFail "rollback did not restore the previous installation state`nROLLBACK OUTPUT:`n$($rollback.Out)`nSNAPSHOT: $snapshotStatePath`nSNAPSHOT CONTENT:`n$snapshotState`nEXPECTED:`n$stateAfter1`nACTUAL:`n$stateAfterRollback"
    }

    # Execute one frozen PowerShell migration through the real runner. Frozen
    # migrations remain importer inputs, not current portable authority.
    $stateWithout005 = @(Get-Content -LiteralPath $statePath | Where-Object { $_ -ne '    - 005-add-session-subagent-policy' })
    [System.IO.File]::WriteAllLines($statePath, $stateWithout005, (New-Object System.Text.UTF8Encoding($false)))
    Start-Sleep -Milliseconds 1100
    $migrationUpdate = Invoke-TestScript (Join-Path $RepoRoot 'update-runner.ps1') @('-Target', $Project, '-Ref', 'HEAD')
    if ($migrationUpdate.Code -ne 0) { TestFail "migration update failed: $($migrationUpdate.Err)" }
    Assert-Exists (Join-Path $Project '.workflow\session.local.yml')
    if (-not ((Get-Content -LiteralPath $statePath) -contains '    - 005-add-session-subagent-policy')) {
        TestFail 'executed migration was not recorded in state'
    }

    Write-Host 'ok: PowerShell install/update integration tests passed'
} catch {
    Write-Error $_.Exception.Message
    exit 1
} finally {
    if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
exit 0
