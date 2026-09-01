Set-StrictMode -Version 2.0

function Write-AawLog {
    param([string]$Message)
    Write-Host "[hekate] $Message"
}

function Write-AawWarn {
    param([string]$Message)
    Write-Warning "[hekate] $Message"
}

function Throw-Aaw {
    param([string]$Message)
    throw "[hekate] ERROR: $Message"
}

function Join-AawPath {
    param([string]$Root, [string]$RelativePath)
    if ([string]::IsNullOrEmpty($RelativePath)) { return $Root }
    $parts = $RelativePath -split '[\\/]+'
    $path = $Root
    foreach ($part in $parts) {
        if ($part -ne '') { $path = Join-Path $path $part }
    }
    return $path
}

function Ensure-AawParentDirectory {
    param([string]$Path)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
}

function Read-AawText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return Get-Content -LiteralPath $Path
}

function Write-AawText {
    param([string]$Path, [string[]]$Lines)
    Ensure-AawParentDirectory $Path
    [System.IO.File]::WriteAllLines($Path, $Lines, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-AawSameFile {
    param([string]$Left, [string]$Right)
    if (-not (Test-Path -LiteralPath $Left) -or -not (Test-Path -LiteralPath $Right)) { return $false }
    $leftHash = Get-FileHash -Algorithm SHA256 -LiteralPath $Left
    $rightHash = Get-FileHash -Algorithm SHA256 -LiteralPath $Right
    return $leftHash.Hash -eq $rightHash.Hash
}

function Read-AawStateValue {
    param([string]$Key, [string]$StateFilePath)
    if (-not (Test-Path -LiteralPath $StateFilePath)) { return '' }
    foreach ($line in (Get-Content -LiteralPath $StateFilePath)) {
        if ($line -match "^\s*$([regex]::Escape($Key)):\s*(.*)$") {
            return $matches[1].Trim()
        }
    }
    return ''
}

function Test-AawStateHasAdapter {
    param([string]$AdapterName, [string]$StateFilePath)
    if (-not (Test-Path -LiteralPath $StateFilePath)) { return $false }
    foreach ($line in (Get-Content -LiteralPath $StateFilePath)) {
        if ($line -match "^\s*-\s*$([regex]::Escape($AdapterName))\s*$") { return $true }
    }
    return $false
}

# Single reader for the migration ledger (schema.applied_migrations in
# .workflow/state.yml). Returns the migration IDs in file order.
#
# The ledger is a YAML block sequence. YAML permits the sequence items to sit
# either deeper than their key or at the *same* indentation as the key, and
# both forms must be read identically:
#
#   applied_migrations:        applied_migrations:
#     - 001-first              - 001-first
#
# List membership is therefore tracked by the indentation of the *items*, not
# by "deeper than the key". The list ends at the first non-comment, non-blank
# line that is either a mapping key (e.g. the `history:` sibling) or a
# sequence item at a different indentation, so entries belonging to any other
# key can never leak into the result. Only bare scalar IDs are returned;
# anything else (notably the `- {ran_at: ...}` maps written by the historical
# ledger-contamination bug) is skipped without terminating the list.
#
# Keep byte-for-byte behavior in sync with applied_migrations_from_state in
# lib/update-common.sh: both must accept and reject exactly the same input.
function Get-AawAppliedMigrations {
    param([string]$StateFilePath)
    $items = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $StateFilePath)) { return $items.ToArray() }

    $inList = $false
    $keyIndent = 0
    $itemIndent = -1
    foreach ($line in (Get-Content -LiteralPath $StateFilePath)) {
        if ($line -match '^\s*applied_migrations:\s*\[\]\s*$') {
            $inList = $false
            continue
        }
        if ($line -match '^\s*applied_migrations:\s*$') {
            $inList = $true
            $keyIndent = $line.Length - $line.TrimStart().Length
            $itemIndent = -1
            continue
        }
        if (-not $inList) { continue }
        if ($line -match '^\s*(?:#.*)?$') { continue }

        if ($line -match '^\s*-') {
            $lineIndent = $line.Length - $line.TrimStart().Length
            if ($itemIndent -lt 0) {
                # A dedented item cannot belong to this key.
                if ($lineIndent -lt $keyIndent) {
                    $inList = $false
                    continue
                }
                $itemIndent = $lineIndent
            } elseif ($lineIndent -ne $itemIndent) {
                $inList = $false
                continue
            }

            if ($line -match '^\s*-\s*([A-Za-z0-9][A-Za-z0-9_.-]*)\s*$') {
                $items.Add($matches[1])
            }
            continue
        }

        # Any other content (a mapping key such as `history:`) ends the list.
        $inList = $false
    }
    return $items.ToArray()
}

function Test-AawStateHasMigration {
    param([string]$MigrationId, [string]$StateFilePath)
    if (-not (Test-Path -LiteralPath $StateFilePath)) { return $false }
    if ([string]::IsNullOrEmpty($MigrationId)) { return $false }
    foreach ($id in (Get-AawAppliedMigrations $StateFilePath)) {
        if ($id -ceq $MigrationId) { return $true }
    }
    return $false
}

function Add-AawUniqueLine {
    param([string]$Path, [string]$Value)
    Ensure-AawParentDirectory $Path
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType File -Path $Path | Out-Null }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -eq $Value) { return }
    }
    Add-Content -LiteralPath $Path -Value $Value
}

function Test-AawProjectHasClaudeAdapter {
    (Test-Path -LiteralPath (Join-AawPath $script:TARGET 'CLAUDE.md')) -or
    (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.claude/commands/init-workflow.md')) -or
    (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.claude/skills/workflow/SKILL.md')) -or
    (Test-AawStateHasAdapter 'claude' $script:STATE_FILE)
}

function Test-AawProjectHasCursorAdapter {
    (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.cursor/rules/workflow.mdc')) -or
    (Test-AawStateHasAdapter 'cursor' $script:STATE_FILE)
}

function Test-AawProjectHasCodexAdapter {
    Test-AawStateHasAdapter 'codex' $script:STATE_FILE
}

function Test-AawProjectHasCopilotAdapter {
    (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.github/copilot-instructions.md')) -or
    (Test-AawStateHasAdapter 'copilot' $script:STATE_FILE)
}

function Test-AawProjectHasGeminiAdapter {
    (Test-Path -LiteralPath (Join-AawPath $script:TARGET 'GEMINI.md')) -or
    (Test-AawStateHasAdapter 'gemini' $script:STATE_FILE)
}

function Test-AawProjectHasAiderAdapter {
    (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.aider.conf.yml')) -or
    (Test-AawStateHasAdapter 'aider' $script:STATE_FILE)
}

function Test-AawAlreadyBackedUp {
    param([string]$RelativePath)
    if (-not $script:BACKED_UP_LIST_FILE -or -not (Test-Path -LiteralPath $script:BACKED_UP_LIST_FILE)) { return $false }
    foreach ($line in (Get-Content -LiteralPath $script:BACKED_UP_LIST_FILE)) {
        if ($line -eq $RelativePath) { return $true }
    }
    return $false
}

function Add-AawBackedUpMark {
    param([string]$RelativePath)
    if ($script:BACKED_UP_LIST_FILE) { Add-AawUniqueLine $script:BACKED_UP_LIST_FILE $RelativePath }
}

function Backup-AawFile {
    param([string]$RelativePath)
    $src = Join-AawPath $script:TARGET $RelativePath
    if (-not (Test-Path -LiteralPath $src)) { return }
    if (Test-AawAlreadyBackedUp $RelativePath) { return }

    # Prefer the current run's timestamped backup directory
    # (.workflow/backups/<UTC-timestamp>/<relative path>) when the caller has
    # set one up via $script:RUN_BACKUP_DIR. Falls back to the flat legacy
    # layout (.workflow/backups/<relative path>) for standalone invocations.
    $backupRootForRun = $script:BACKUP_ROOT
    if ((Get-Variable -Name RUN_BACKUP_DIR -Scope Script -ErrorAction SilentlyContinue) -and $script:RUN_BACKUP_DIR) {
        $backupRootForRun = $script:RUN_BACKUP_DIR
    }
    $dst = Join-AawPath $backupRootForRun $RelativePath
    if ($script:DRY_RUN) {
        Write-AawLog "would back up: $src -> $dst"
        Add-AawBackedUpMark $RelativePath
        return
    }

    Ensure-AawParentDirectory $dst
    Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    Add-AawBackedUpMark $RelativePath
    Write-AawLog "backed up: $dst"
}

function Remove-AawOldBackupRuns {
    param([int]$Keep = 5)
    if (-not (Test-Path -LiteralPath $script:BACKUP_ROOT)) { return }
    if ($script:DRY_RUN) { return }

    $runDirs = @(Get-ChildItem -LiteralPath $script:BACKUP_ROOT -Directory |
        Where-Object { $_.Name -match '^[0-9]{8}T[0-9]{6}Z$' } |
        Sort-Object Name -Descending)
    if ($runDirs.Count -le $Keep) { return }

    foreach ($dir in ($runDirs | Select-Object -Skip $Keep)) {
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force
        Write-AawLog "pruned old backup run: $($dir.FullName)"
    }
}

function Copy-AawFile {
    param([string]$Source, [string]$Destination)
    if ($script:DRY_RUN) {
        Write-AawLog "would copy: $Source -> $Destination"
        return
    }
    Ensure-AawParentDirectory $Destination
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Write-AawReviewFile {
    param([string]$RelativePath, [string]$Source)
    $dst = Join-AawPath $script:TARGET ($RelativePath + '.new')
    if ($script:DRY_RUN) {
        Write-AawLog "would write review copy: $dst"
        return
    }
    Ensure-AawParentDirectory $dst
    Copy-Item -LiteralPath $Source -Destination $dst -Force
    Write-AawLog "review required: $dst"
}

function Replace-AawFileIfChanged {
    param([string]$RelativePath, [string]$Source)
    $dst = Join-AawPath $script:TARGET $RelativePath
    if ((Test-Path -LiteralPath $dst) -and (Test-AawSameFile $Source $dst)) { return }
    if (Test-Path -LiteralPath $dst) { Backup-AawFile $RelativePath }
    Copy-AawFile $Source $dst
    Write-AawLog "updated: $dst"
}

function Append-AawGitignore {
    param([string]$Snippet)
    $gi = Join-AawPath $script:TARGET '.gitignore'
    $changed = $false
    if (-not (Test-Path -LiteralPath $Snippet)) { return }

    if (-not (Test-Path -LiteralPath $gi)) {
        if ($script:DRY_RUN) {
            Write-AawLog "would create: $gi"
        } else {
            Ensure-AawParentDirectory $gi
            New-Item -ItemType File -Path $gi | Out-Null
            $changed = $true
        }
    }

    $existing = @()
    if (Test-Path -LiteralPath $gi) { $existing = Get-Content -LiteralPath $gi }
    foreach ($line in (Get-Content -LiteralPath $Snippet)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($existing -contains $line) { continue }
        if (-not $changed -and (Test-Path -LiteralPath $gi)) {
            Backup-AawFile '.gitignore'
            $changed = $true
        }
        if ($script:DRY_RUN) {
            Write-AawLog "would append to .gitignore: $line"
        } else {
            Add-Content -LiteralPath $gi -Value $line
            $existing += $line
        }
    }

    if ($changed -or $script:DRY_RUN) { Write-AawLog "updated: $gi" }
}

function Expand-AawZipball {
    param([string]$Repo, [string]$Ref, [string]$Label)
    $dest = Join-Path $script:TMP_ROOT $Label
    $zip = Join-Path $script:TMP_ROOT ($Label + '.zip')
    $url = "https://codeload.github.com/$Repo/zip/$Ref"

    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Write-AawLog "downloading $url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
    $dirs = @(Get-ChildItem -LiteralPath $dest -Directory)
    if ($dirs.Count -lt 1) { Throw-Aaw "could not locate extracted repo in $dest" }
    return $dirs[0].FullName
}

function Expand-AawLocalGitRef {
    param([string]$SourceRoot, [string]$Ref, [string]$Label)
    $dest = Join-Path $script:TMP_ROOT $Label
    $zip = Join-Path $script:TMP_ROOT ($Label + '.zip')
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot '.git'))) { return $null }

    $oldLocation = Get-Location
    try {
        Set-Location -LiteralPath $SourceRoot
        & git archive --format=zip --output=$zip $Ref | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
    } finally {
        Set-Location $oldLocation
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
    return $dest
}
