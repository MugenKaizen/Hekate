[CmdletBinding()]
param(
    [string]$Target = (Get-Location).Path,
    [string]$Repo = $(if ($env:AAW_REPO) { $env:AAW_REPO } else { 'MugenKaizen/Hekate' }),
    [string]$Ref = 'main',
    [string]$Commit = '',
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

Set-StrictMode -Version 2.0

foreach ($arg in $Rest) {
    if ($arg -like '--target=*') { $Target = $arg.Substring(9); continue }
    if ($arg -like '--repo=*') { $Repo = $arg.Substring(7); continue }
    if ($arg -like '--ref=*') { $Ref = $arg.Substring(6); continue }
    if ($arg -like '--commit=*') { $Commit = $arg.Substring(9); continue }
    if ($arg -eq '--force') { $Force = $true; continue }
    if ($arg -eq '--dry-run') { $DryRun = $true; continue }
    if ($arg -eq '-h' -or $arg -eq '--help') { $Help = $true; continue }
    throw "[aaw] ERROR: unknown arg: $arg"
}

if ($Help) {
@'
ai_agent_workflow update runner

Flags:
  -Target <path>      Root of the target project. Defaults to the current directory.
  -Repo <owner/name> GitHub repository. Defaults to the built-in one.
  -Ref <git-ref>     Branch/tag to update to. Defaults to main.
  -Commit <sha>      Exact commit to update to.
  -Force             Overwrite locally edited managed files after confirmation.
  -DryRun            Show what would be done without making changes.
'@ | Write-Host
    exit 0
}

$script:TARGET = $Target
$script:REPO = $Repo
$script:REF = $Ref
$script:COMMIT = $Commit
$script:DRY_RUN = [bool]$DryRun
$script:FORCE = [bool]$Force
$script:RUNNER_ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:TMP_ROOT = Join-Path ([System.IO.Path]::GetTempPath()) ('aaw-runner-' + [guid]::NewGuid().ToString('N'))

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
$script:BACKED_UP_LIST_FILE = Join-Path $script:TMP_ROOT 'backed-up-files.txt'
$script:APPLIED_MIGRATIONS_FILE = Join-Path $script:TMP_ROOT 'applied-migrations.txt'
$script:LEGACY_MODE = $false
$script:STATE_REPO = ''
$script:STATE_REF = ''
$script:OLD_SRC_ROOT = ''
$script:OLD_TPL = ''

. (Join-Path $script:RUNNER_ROOT 'lib/update-common.ps1')

function Update-AawTemplateFile {
    param([string]$TargetRelativePath, [string]$TemplateRelativePath)
    $newSrc = Join-AawPath (Join-Path $script:RUNNER_ROOT 'templates') $TemplateRelativePath
    $oldSrc = ''
    $targetPath = Join-AawPath $script:TARGET $TargetRelativePath

    if ($script:OLD_TPL) { $oldSrc = Join-AawPath $script:OLD_TPL $TemplateRelativePath }
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

function Confirm-AawForceUpdate {
    if (-not $script:FORCE -or $script:DRY_RUN) { return }
    Write-AawWarn '--force enabled; locally edited template-managed files will be overwritten after backup.'
    $answer = Read-Host '[aaw] Continue? Type "yes" to proceed'
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
    if (Test-Path -LiteralPath $stateFile) { Backup-AawFile '.workflow/state.yml' }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('install:')
    $lines.Add('  tool: hekate')
    $lines.Add("  installed_repo: $($script:REPO)")
    $lines.Add("  installed_ref: $installRef")
    $lines.Add('  installed_at: ' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
    $lines.Add('  adapters:')
    if (Test-AawProjectHasClaudeAdapter) { $lines.Add('    - claude') }
    if (Test-AawProjectHasCursorAdapter) { $lines.Add('    - cursor') }
    if (Test-AawProjectHasCodexAdapter) { $lines.Add('    - codex') }
    $lines.Add('schema:')
    $lines.Add('  state_version: 2')
    $applied = @()
    if (Test-Path -LiteralPath $script:APPLIED_MIGRATIONS_FILE) { $applied = Get-Content -LiteralPath $script:APPLIED_MIGRATIONS_FILE }
    if ($applied.Count -gt 0) {
        $lines.Add('  applied_migrations:')
        foreach ($migrationId in $applied) { if ($migrationId) { $lines.Add('    - ' + $migrationId) } }
    } else {
        $lines.Add('  applied_migrations: []')
    }
    [System.IO.File]::WriteAllLines($stateFile, $lines.ToArray(), [System.Text.Encoding]::UTF8)
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
        & $migration.FullName
        Add-AawUniqueLine $script:APPLIED_MIGRATIONS_FILE $migrationId
        Write-AawLog "applied migration: $migrationId"
    }
}

try {
    New-Item -ItemType Directory -Force -Path $script:TMP_ROOT | Out-Null
    New-Item -ItemType File -Force -Path $script:BACKED_UP_LIST_FILE | Out-Null
    New-Item -ItemType File -Force -Path $script:APPLIED_MIGRATIONS_FILE | Out-Null

    if (-not (Test-Path -LiteralPath $script:TARGET)) { Throw-Aaw "target dir does not exist: $script:TARGET" }
    if (-not (Test-Path -LiteralPath (Join-AawPath $script:TARGET 'AGENTS.md'))) { Throw-Aaw "target does not look like a workflow installation: $script:TARGET/AGENTS.md missing" }
    if (-not (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.workflow/workflow.yml'))) { Throw-Aaw 'target does not look like a workflow installation: .workflow/workflow.yml missing' }
    if (-not (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.workflow/presets.yml'))) { Throw-Aaw 'target does not look like a workflow installation: .workflow/presets.yml missing' }
    if (-not (Test-Path -LiteralPath (Join-Path $script:RUNNER_ROOT 'templates'))) { Throw-Aaw 'runner source is incomplete: templates/ missing' }

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
    Update-AawTemplateFile '.workflow/README.md' '.workflow/README.md'

    if (Test-AawProjectHasClaudeAdapter) {
        Update-AawTemplateFile 'CLAUDE.md' 'adapters/claude/CLAUDE.md'
        foreach ($commandFile in (Get-ChildItem -LiteralPath (Join-AawPath (Join-Path $script:RUNNER_ROOT 'templates') 'adapters/claude/commands') -Filter '*.md')) {
            Update-AawTemplateFile ('.claude/commands/' + $commandFile.Name) ('adapters/claude/commands/' + $commandFile.Name)
        }
        Update-AawTemplateFile '.claude/skills/workflow/SKILL.md' 'adapters/claude/skills/workflow/SKILL.md'
    }
    if (Test-AawProjectHasCursorAdapter) {
        Update-AawTemplateFile '.cursor/rules/workflow.mdc' 'adapters/cursor/.cursor/rules/workflow.mdc'
    }

    Write-AawStateFile

@'

---------------------------------------------------------
 ai_agent_workflow update finished.

 Notes:
   - Pending migrations from the downloaded snapshot were applied in order.
   - Existing .workflow/*.yml values were preserved; migrations only changed known managed paths.
   - Local edits in template-managed files were left in place and, if needed, mirrored to <file>.new.
   - Backups of changed files are stored in .workflow/backups/.
---------------------------------------------------------
'@ | Write-Host
} finally {
    if ($script:TMP_ROOT -and (Test-Path -LiteralPath $script:TMP_ROOT)) { Remove-Item -LiteralPath $script:TMP_ROOT -Recurse -Force }
}
