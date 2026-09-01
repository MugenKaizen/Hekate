[CmdletBinding()]
param(
    [string]$Target = (Get-Location).Path,
    [string]$Repo = $(if ($env:HEKATE_REPO) { $env:HEKATE_REPO } else { 'MugenKaizen/Hekate' }),
    [string]$Ref = 'HEAD',
    [string]$Commit = '',
    [string]$Agents = '',
    [switch]$Force,
    [switch]$Yes,
    [switch]$ReplaceUnowned,
    [switch]$DryRun,
    [switch]$Rollback,
    [string]$RollbackName = '',
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

foreach ($arg in $Rest) {
    if ($arg -like '--target=*') { $Target = $arg.Substring(9); continue }
    if ($arg -like '--repo=*') { $Repo = $arg.Substring(7); continue }
    if ($arg -like '--ref=*') { $Ref = $arg.Substring(6); continue }
    if ($arg -like '--commit=*') { $Commit = $arg.Substring(9); continue }
    if ($arg -like '--agents=*') { $Agents = $arg.Substring(9); continue }
    if ($arg -eq '--force') { $Force = $true; continue }
    if ($arg -eq '--yes') { $Yes = $true; continue }
    if ($arg -eq '--replace-unowned') { $ReplaceUnowned = $true; continue }
    if ($arg -eq '--dry-run') { $DryRun = $true; continue }
    if ($arg -like '--rollback=*') { $Rollback = $true; $RollbackName = $arg.Substring(11); continue }
    if ($arg -eq '--rollback') { $Rollback = $true; continue }
    if ($arg -eq '-h' -or $arg -eq '--help') { $Help = $true; continue }
    throw "[hekate] ERROR: unknown arg: $arg"
}

if ($Help) {
@'
ai_agent_workflow update runner

Flags:
  -Target <path>      Root of the target project. Defaults to the current directory.
  -Repo <owner/name> GitHub repository. Defaults to the built-in one.
  -Ref <git-ref>     Source revision metadata. Defaults to HEAD.
  -Commit <sha>      Exact commit to update to.
  -Agents <list>     Comma-separated adapters to opt into on this update, in
                     addition to any already detected: claude,cursor,codex,
                     copilot,gemini,aider. Lets an existing installation pick
                     up a newly supported adapter without a full reinstall.
  -Force             Overwrite locally edited managed files after confirmation.
  -Yes               Skip the confirmation prompt for non-interactive use.
  -ReplaceUnowned    Explicitly approve replacing unowned files during upgrade.
  -DryRun            Show what would be done without making changes.
  -Rollback           Restore the most recent backup run (.workflow/backups/<ts>/)
                      over the current files.
  -RollbackName <run> Restore a specific backup run by its timestamp directory
                      name (e.g. 20260825T120000Z). Implies -Rollback.

Backups: every run that overwrites or removes a managed file first copies the
original into .workflow/backups/<UTC-timestamp>/<relative-path>. Only the 5
most recent backup runs are retained; older ones are pruned automatically.
'@ | Write-Host
    exit 0
}

if ($RollbackName) { $Rollback = $true }

$script:TARGET = $Target
$script:REPO = $Repo
$script:REF = $Ref
$script:COMMIT = $Commit
$script:AGENTS = $Agents
$script:DRY_RUN = [bool]$DryRun
$script:FORCE = [bool]$Force
$script:REPLACE_UNOWNED = [bool]$ReplaceUnowned
$script:ROLLBACK = [bool]$Rollback
$script:ROLLBACK_NAME = $RollbackName
$script:RUNNER_ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:TMP_ROOT = Join-Path ([System.IO.Path]::GetTempPath()) ('hekate-runner-' + [guid]::NewGuid().ToString('N'))

function Join-AawPathEarly {
    param([string]$Root, [string]$RelativePath)
    $path = $Root
    foreach ($part in ($RelativePath -split '[\\/]+')) {
        if ($part) { $path = Join-Path $path $part }
    }
    return $path
}

$script:STATE_FILE = Join-AawPathEarly $Target '.workflow/state.yml'
$script:BACKUP_ROOT = Join-AawPathEarly $Target '.workflow/backups'
$script:RUN_TIMESTAMP = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$script:RUN_BACKUP_DIR = Join-Path $script:BACKUP_ROOT $script:RUN_TIMESTAMP
$script:BACKED_UP_LIST_FILE = Join-Path $script:TMP_ROOT 'backed-up-files.txt'
$script:APPLIED_MIGRATIONS_FILE = Join-Path $script:TMP_ROOT 'applied-migrations.txt'
$script:NEW_MIGRATIONS_FILE = Join-Path $script:TMP_ROOT 'newly-applied-migrations.txt'
$script:LEGACY_MODE = $false
$script:STATE_REPO = ''
$script:STATE_REF = ''
$script:OLD_SRC_ROOT = ''
$script:OLD_TPL = ''

. (Join-Path $script:RUNNER_ROOT 'lib/update-common.ps1')

function Test-AawRequestedAgent {
    param([string]$Name)
    if (-not $script:AGENTS) { return $false }
    return ((',' + $script:AGENTS + ',') -like "*,$Name,*")
}

function Invoke-AawRollback {
    if (-not (Test-Path -LiteralPath $script:TARGET)) { Throw-Aaw "target dir does not exist: $script:TARGET" }
    if (-not (Test-Path -LiteralPath $script:BACKUP_ROOT)) { Throw-Aaw "no backups available to roll back: $($script:BACKUP_ROOT) missing" }

    if ($script:ROLLBACK_NAME) {
        if ($script:ROLLBACK_NAME -notmatch '^[0-9]{8}T[0-9]{6}Z$') {
            Throw-Aaw '-RollbackName must be a backup run timestamp like 20260825T120000Z'
        }
        $chosen = $script:ROLLBACK_NAME
    } else {
        $runDirs = @(Get-ChildItem -LiteralPath $script:BACKUP_ROOT -Directory |
            Where-Object { $_.Name -match '^[0-9]{8}T[0-9]{6}Z$' } |
            Sort-Object Name -Descending)
        if ($runDirs.Count -lt 1) { Throw-Aaw "no backup runs found under $($script:BACKUP_ROOT)" }
        $chosen = $runDirs[0].Name
    }

    $chosenDir = Join-Path $script:BACKUP_ROOT $chosen
    if (-not (Test-Path -LiteralPath $chosenDir)) { Throw-Aaw "backup run not found: $chosenDir" }

    $files = @(Get-ChildItem -LiteralPath $chosenDir -Recurse -File -Force)
    if ($files.Count -lt 1) { Throw-Aaw "backup run is empty; nothing to restore: $chosenDir" }

    Write-AawLog "rolling back using backup run: $chosen ($($files.Count) file(s))"
    if ($script:DRY_RUN) { Write-AawLog 'DRY RUN - no files will be restored' }

    foreach ($file in $files) {
        $rel = $file.FullName.Substring($chosenDir.Length).TrimStart('\', '/')
        $dest = Join-AawPathEarly $script:TARGET $rel
        if ($script:DRY_RUN) {
            Write-AawLog "would restore: $dest"
            continue
        }
        Ensure-AawParentDirectory $dest
        Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
        Write-AawLog "restored: $dest"
    }

    if (-not $script:DRY_RUN) {
        Write-AawLog "rollback complete using backup run: $chosen"
        Write-AawLog 'note: this restores files captured in that run, including .workflow/state.yml if it was backed up, which reverts the applied-migrations ledger and installed_ref to their prior values.'
    }
}

function Update-AawTemplateFile {
    param(
        [string]$TargetRelativePath,
        [string]$TemplateRelativePath,
        [string]$OldTemplateRelativePath = $TemplateRelativePath
    )
    $newSrc = Join-AawPath (Join-Path $script:RUNNER_ROOT 'templates') $TemplateRelativePath
    $oldSrc = ''
    $targetPath = Join-AawPath $script:TARGET $TargetRelativePath

    if ($script:OLD_TPL) { $oldSrc = Join-AawPath $script:OLD_TPL $OldTemplateRelativePath }
    if (-not (Test-Path -LiteralPath $newSrc)) { return }

    if (-not (Test-Path -LiteralPath $targetPath)) {
        Copy-AawFile $newSrc $targetPath
        Write-AawLog "added: $targetPath"
        return
    }

    if (Test-AawSameFile $targetPath $newSrc) { return }

    if ((-not $script:LEGACY_MODE) -and $oldSrc -and (Test-Path -LiteralPath $oldSrc) -and (Test-AawSameFile $targetPath $oldSrc)) {
        Backup-AawFile $TargetRelativePath
        Copy-AawFile $newSrc $targetPath
        Write-AawLog "updated: $targetPath"
        return
    }

    if ($script:FORCE) {
        Backup-AawFile $TargetRelativePath
        Copy-AawFile $newSrc $targetPath
        Write-AawLog "updated: $targetPath"
        return
    }

    Write-AawReviewFile $TargetRelativePath $newSrc
}

function Update-AawSkills {
    param([string]$DestinationRoot)
        foreach ($skillDir in (Get-ChildItem -LiteralPath (Join-AawPath (Join-Path $script:RUNNER_ROOT 'templates') 'skills') -Directory)) {
            if ($skillDir.Name -ne 'workflow') { continue }
        if (Test-Path -LiteralPath (Join-AawPath $skillDir.FullName 'SKILL.md')) {
            Update-AawTemplateFile ($DestinationRoot + '/' + $skillDir.Name + '/SKILL.md') ('skills/' + $skillDir.Name + '/SKILL.md') ('adapters/claude/skills/' + $skillDir.Name + '/SKILL.md')
        }
    }
}

function Confirm-AawForceUpdate {
    if (-not $script:FORCE -or $script:DRY_RUN) { return }
    Write-AawWarn '--force enabled; locally edited template-managed files will be overwritten after backup.'
    $answer = Read-Host '[hekate] Continue? Type "yes" to proceed'
    if ($answer -ne 'yes') { Throw-Aaw 'update cancelled' }
}

function Update-AawRootReadme {
    $newSrc = Join-Path $script:RUNNER_ROOT 'README.md'
    $targetPath = Join-AawPath $script:TARGET 'README.md'
    if (-not (Test-Path -LiteralPath $newSrc) -or -not (Test-Path -LiteralPath $targetPath)) { return }
    if (Test-AawSameFile $targetPath $newSrc) { return }

    $oldSrc = ''
    if ($script:OLD_SRC_ROOT) { $oldSrc = Join-Path $script:OLD_SRC_ROOT 'README.md' }
    if ((-not $script:LEGACY_MODE) -and $oldSrc -and (Test-Path -LiteralPath $oldSrc) -and (Test-AawSameFile $targetPath $oldSrc)) {
        Backup-AawFile 'README.md'
        Copy-AawFile $newSrc $targetPath
        Write-AawLog "updated: $targetPath"
        return
    }

    $lines = Get-Content -LiteralPath $targetPath
    if ($lines -contains '# Hekate') {
        if ($script:FORCE) {
            Backup-AawFile 'README.md'
            Copy-AawFile $newSrc $targetPath
            Write-AawLog "updated: $targetPath"
        } else {
            Write-AawReviewFile 'README.md' $newSrc
        }
    }
}

function Write-AawStateFile {
    $stateFile = Join-AawPath $script:TARGET '.workflow/state.yml'
    $installRef = $script:REF
    if ($script:COMMIT) { $installRef = $script:COMMIT }
    if ($script:DRY_RUN) {
        Write-AawLog "would write install state: $stateFile"
        return
    }

    # Preserve up to the 4 most recent prior history entries (single-line
    # flow mappings) so this run's entry keeps a bounded rolling window of 5.
    $oldHistoryLines = @()
    $fromRef = if ($script:STATE_REF) { $script:STATE_REF } else { 'unknown' }
    if (Test-Path -LiteralPath $stateFile) {
        $oldHistoryLines = @(Get-Content -LiteralPath $stateFile | Where-Object { $_ -match '^    - \{' } | Select-Object -Last 4)
        Backup-AawFile '.workflow/state.yml'
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $backupDirField = 'null'
    if (Test-Path -LiteralPath $script:RUN_BACKUP_DIR) {
        $backupDirField = "`".workflow/backups/$($script:RUN_TIMESTAMP)`""
    }

    $migrationsAppliedField = '[]'
    $newMigrations = @()
    if (Test-Path -LiteralPath $script:NEW_MIGRATIONS_FILE) { $newMigrations = @(Get-Content -LiteralPath $script:NEW_MIGRATIONS_FILE | Where-Object { $_ }) }
    if ($newMigrations.Count -gt 0) {
        $migrationsAppliedField = '[' + ($newMigrations -join ', ') + ']'
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('install:')
    $lines.Add('  tool: hekate')
    $lines.Add("  installed_repo: $($script:REPO)")
    $lines.Add("  installed_ref: $installRef")
    $lines.Add('  installed_at: ' + $timestamp)
    $lines.Add('  adapters:')
    if (Test-AawProjectHasClaudeAdapter) { $lines.Add('    - claude') }
    if (Test-AawProjectHasCursorAdapter) { $lines.Add('    - cursor') }
    if (Test-AawProjectHasCodexAdapter) { $lines.Add('    - codex') }
    if (Test-AawProjectHasCopilotAdapter) { $lines.Add('    - copilot') }
    if (Test-AawProjectHasGeminiAdapter) { $lines.Add('    - gemini') }
    if (Test-AawProjectHasAiderAdapter) { $lines.Add('    - aider') }
    $lines.Add('schema:')
    $lines.Add('  state_version: 2')
    $applied = @()
    if (Test-Path -LiteralPath $script:APPLIED_MIGRATIONS_FILE) { $applied = @(Get-Content -LiteralPath $script:APPLIED_MIGRATIONS_FILE) }
    if ($applied.Count -gt 0) {
        $lines.Add('  applied_migrations:')
        foreach ($migrationId in $applied) { if ($migrationId) { $lines.Add('    - ' + $migrationId) } }
    } else {
        $lines.Add('  applied_migrations: []')
    }

    $lines.Add('  history:')
    foreach ($historyLine in $oldHistoryLines) { $lines.Add($historyLine) }
    $lines.Add("    - {ran_at: `"$timestamp`", from_ref: `"$fromRef`", to_ref: `"$installRef`", backup_dir: $backupDirField, migrations_applied: $migrationsAppliedField}")

    # An interrupted in-place write truncates the ledger, so the file is
    # replaced atomically instead.
    $stateTemp = "$stateFile.tmp"
    [System.IO.File]::WriteAllLines($stateTemp, $lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    # PowerShell binds $null to an empty string here, which File.Replace rejects,
    # so the "no backup file" argument must be a typed null.
    if (Test-Path -LiteralPath $stateFile) { [System.IO.File]::Replace($stateTemp, $stateFile, [NullString]::Value) }
    else { [System.IO.File]::Move($stateTemp, $stateFile) }
    Write-AawLog "updated: $stateFile"
}

function Get-AawOldSource {
    if ($script:LEGACY_MODE) { return $null }
    if ($script:STATE_REPO -eq $script:REPO) {
        $local = Expand-AawLocalGitRef $script:RUNNER_ROOT $script:STATE_REF 'old'
        if ($local) { return $local }
    }
    return Expand-AawZipball $script:STATE_REPO $script:STATE_REF 'old'
}

function Invoke-AawMigrations {
    $migrationDir = Join-Path $script:RUNNER_ROOT 'migrations'
    if (-not (Test-Path -LiteralPath $migrationDir)) { return }
    foreach ($migration in (Get-ChildItem -LiteralPath $migrationDir -Filter '*.ps1' | Sort-Object Name)) {
        $migrationId = [System.IO.Path]::GetFileNameWithoutExtension($migration.Name)
        $already = $false
        if (Test-Path -LiteralPath $script:APPLIED_MIGRATIONS_FILE) {
            foreach ($line in (Get-Content -LiteralPath $script:APPLIED_MIGRATIONS_FILE)) { if ($line -eq $migrationId) { $already = $true } }
        }
        if ($already) {
            Write-AawLog "skip migration: $migrationId"
            continue
        }
        Write-AawLog "running migration: $migrationId"
        . $migration.FullName
        Add-AawUniqueLine $script:APPLIED_MIGRATIONS_FILE $migrationId
        Add-AawUniqueLine $script:NEW_MIGRATIONS_FILE $migrationId
        Write-AawLog "applied migration: $migrationId"
    }
}

try {
    New-Item -ItemType Directory -Force -Path $script:TMP_ROOT | Out-Null
    New-Item -ItemType File -Force -Path $script:BACKED_UP_LIST_FILE | Out-Null
    New-Item -ItemType File -Force -Path $script:APPLIED_MIGRATIONS_FILE | Out-Null
    New-Item -ItemType File -Force -Path $script:NEW_MIGRATIONS_FILE | Out-Null

    if (-not (Test-Path -LiteralPath $script:TARGET)) { Throw-Aaw "target dir does not exist: $script:TARGET" }

    if ($script:ROLLBACK) {
        Invoke-AawRollback
        exit 0
    }

    # The frozen legacy path operates on the legacy managed files; the
    # transactional -Force path reconciles either contract layout and must not
    # demand them.
    $hasV1 = (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.workflow/install-state.json')) -or (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.workflow/config.yml'))
    $hasLegacy = (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.workflow/workflow.yml')) -and (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.workflow/presets.yml'))
    if ($script:FORCE) {
        if (-not $hasV1 -and -not (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.workflow/workflow.yml')) -and -not (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.workflow/presets.yml'))) {
            Throw-Aaw 'target does not look like a Hekate installation: no .workflow/install-state.json, config.yml, workflow.yml, or presets.yml'
        }
    } else {
        if ($hasV1 -and -not $hasLegacy) { Throw-Aaw 'target uses the v1 contract layout; rerun with -Force to update it transactionally' }
        if (-not (Test-Path -LiteralPath (Join-AawPath $script:TARGET 'AGENTS.md'))) { Throw-Aaw "target does not look like a workflow installation: $script:TARGET/AGENTS.md missing" }
        if (-not (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.workflow/workflow.yml'))) { Throw-Aaw 'target does not look like a workflow installation: .workflow/workflow.yml missing' }
        if (-not (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.workflow/presets.yml'))) { Throw-Aaw 'target does not look like a workflow installation: .workflow/presets.yml missing' }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $script:RUNNER_ROOT 'templates'))) { Throw-Aaw 'runner source is incomplete: templates/ missing' }

    if ($script:FORCE) {
        $node = Get-Command node -ErrorAction SilentlyContinue
        if (-not $node) { Throw-Aaw 'transactional upgrade requires Node 20 or newer' }
        & $node.Source -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)'
        if ($LASTEXITCODE -ne 0) { Throw-Aaw 'transactional upgrade requires Node 20 or newer' }
        $runtimeRoot = Join-AawPath $script:RUNNER_ROOT 'distribution/runtime'
        $runtime = Join-AawPath $runtimeRoot 'src/hekate-cli.mjs'
        if (-not (Test-Path -LiteralPath $runtime)) { Throw-Aaw 'standalone transactional runtime is missing from the source snapshot' }
        $targetRelease = if ($script:COMMIT) { $script:COMMIT } else { $script:REF }
        $upgradeArgs = @($runtime, 'upgrade', "--to=$targetRelease", '--force', "--target=$script:TARGET", "--source=$script:RUNNER_ROOT")
        if ($script:AGENTS) { $upgradeArgs += "--adapters=$script:AGENTS" }
        if ($Yes) { $upgradeArgs += '--yes' }
        if ($script:REPLACE_UNOWNED) { $upgradeArgs += '--replace-unowned' }
        if ($script:DRY_RUN) { $upgradeArgs += '--dry-run' }
        $env:HEKATE_RECOVERY_RUNTIME_ROOT = $runtimeRoot
        & $node.Source @upgradeArgs
        exit $LASTEXITCODE
    }

    foreach ($migrationId in (Get-AawAppliedMigrations $script:STATE_FILE)) { Add-AawUniqueLine $script:APPLIED_MIGRATIONS_FILE $migrationId }

    if (Test-Path -LiteralPath $script:STATE_FILE) {
        $script:STATE_REPO = Read-AawStateValue 'installed_repo' $script:STATE_FILE
        $script:STATE_REF = Read-AawStateValue 'installed_ref' $script:STATE_FILE
    }
    if (-not $script:STATE_REPO) { $script:STATE_REPO = $script:REPO }
    if (-not $script:STATE_REF) {
        $script:LEGACY_MODE = $true
        Write-AawWarn 'state file missing or incomplete; running in legacy safe mode'
    }
    if (-not $script:LEGACY_MODE) {
        try {
            $script:OLD_SRC_ROOT = Get-AawOldSource
            if ($script:OLD_SRC_ROOT) { $script:OLD_TPL = Join-Path $script:OLD_SRC_ROOT 'templates' }
        } catch {
            $script:LEGACY_MODE = $true
            Write-AawWarn 'could not load previously installed templates; falling back to legacy safe mode'
        }
    }

    Write-AawLog "target: $script:TARGET"
    if ($script:COMMIT) { Write-AawLog "updating to commit: $script:COMMIT" } else { Write-AawLog "updating to ref: $script:REF" }
    if ($script:DRY_RUN) { Write-AawLog 'DRY RUN - no files will be written' }
    Confirm-AawForceUpdate

    Append-AawGitignore (Join-AawPath (Join-Path $script:RUNNER_ROOT 'templates') 'gitignore.snippet')
    Invoke-AawMigrations

    Update-AawTemplateFile 'AGENTS.md' 'AGENTS.md'
    Update-AawRootReadme
    Update-AawTemplateFile '.workflow/bootstrap.md' '.workflow/bootstrap.md'
    Update-AawTemplateFile '.workflow/history-format.md' '.workflow/history-format.md'
    Update-AawTemplateFile '.workflow/README.md' '.workflow/README.md'
    foreach ($legacyFile in @(
        '.workflow/delegation.md', '.workflow/subagents.md',
        '.workflow/orchestration.yml', '.workflow/bin/hekate-agent',
        '.workflow/bin/hekate-agent.ps1'
    )) {
        if (Test-Path -LiteralPath (Join-AawPath $script:TARGET $legacyFile)) {
            Update-AawTemplateFile $legacyFile $legacyFile
        }
    }

    if (Test-AawProjectHasClaudeAdapter) {
        Update-AawTemplateFile 'CLAUDE.md' 'adapters/claude/CLAUDE.md'
        foreach ($commandFile in (Get-ChildItem -LiteralPath (Join-AawPath (Join-Path $script:RUNNER_ROOT 'templates') 'adapters/claude/commands') -Filter '*.md')) {
            if ($commandFile.Name -eq 'harness.md' -and -not (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.claude/commands/harness.md'))) { continue }
            Update-AawTemplateFile ('.claude/commands/' + $commandFile.Name) ('adapters/claude/commands/' + $commandFile.Name)
        }
        foreach ($agentFile in (Get-ChildItem -LiteralPath (Join-AawPath (Join-Path $script:RUNNER_ROOT 'templates') 'adapters/claude/agents') -Filter '*.md')) {
            if (-not (Test-Path -LiteralPath (Join-AawPath $script:TARGET ('.claude/agents/' + $agentFile.Name)))) { continue }
            Update-AawTemplateFile ('.claude/agents/' + $agentFile.Name) ('adapters/claude/agents/' + $agentFile.Name)
        }
        Update-AawSkills '.claude/skills'
    }
    if (Test-AawProjectHasCursorAdapter) {
        Update-AawTemplateFile '.cursor/rules/workflow.mdc' 'adapters/cursor/.cursor/rules/workflow.mdc'
    }
    if ((Test-AawProjectHasCopilotAdapter) -or (Test-AawRequestedAgent 'copilot')) {
        Update-AawTemplateFile '.github/copilot-instructions.md' 'adapters/copilot/.github/copilot-instructions.md'
    }
    if ((Test-AawProjectHasGeminiAdapter) -or (Test-AawRequestedAgent 'gemini')) {
        Update-AawTemplateFile 'GEMINI.md' 'adapters/gemini/GEMINI.md'
    }
    if ((Test-AawProjectHasAiderAdapter) -or (Test-AawRequestedAgent 'aider')) {
        Update-AawTemplateFile '.aider.conf.yml' 'adapters/aider/.aider.conf.yml'
    }
    if ((Test-AawProjectHasCursorAdapter) -or (Test-AawProjectHasCodexAdapter) `
        -or (Test-AawProjectHasCopilotAdapter) -or (Test-AawProjectHasGeminiAdapter) -or (Test-AawProjectHasAiderAdapter) `
        -or (Test-AawRequestedAgent 'copilot') -or (Test-AawRequestedAgent 'gemini') -or (Test-AawRequestedAgent 'aider')) {
        Update-AawSkills '.agents/skills'
    }

    Write-AawStateFile
    Remove-AawOldBackupRuns 5

@'

---------------------------------------------------------
 ai_agent_workflow update finished.

 Notes:
   - Pending migrations from the downloaded snapshot were applied in order.
   - Existing .workflow/*.yml values were preserved; migrations only changed known managed paths.
   - Local edits in template-managed files were left in place and, if needed, mirrored to <file>.new.
   - Backups of changed files are stored in .workflow/backups/<UTC-timestamp>/ (last 5 runs kept).
   - Use -Rollback (optionally -RollbackName <timestamp>) to restore a backup run.
---------------------------------------------------------
'@ | Write-Host
} finally {
    if ($script:TMP_ROOT -and (Test-Path -LiteralPath $script:TMP_ROOT)) { Remove-Item -LiteralPath $script:TMP_ROOT -Recurse -Force }
}
