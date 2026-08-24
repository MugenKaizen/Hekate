[CmdletBinding()]
param(
    [string]$Target = (Get-Location).Path,
    [string]$Agents = 'claude,cursor,codex,copilot,gemini,aider',
    [string]$Source = '',
    [string]$Ref = '',
    [string]$Commit = '',
    [string]$Repo = $(if ($env:AAW_REPO) { $env:AAW_REPO } else { 'MugenKaizen/Hekate' }),
    [switch]$Force,
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

Set-StrictMode -Version 2.0

$installTmp = ''

function Write-AawLog { param([string]$Message) Write-Host "[aaw] $Message" }
function Write-AawWarn { param([string]$Message) Write-Warning "[aaw] $Message" }
function Throw-Aaw { param([string]$Message) throw "[aaw] ERROR: $Message" }
function Join-AawPath { param([string]$Root, [string]$RelativePath) $p = $Root; foreach ($part in ($RelativePath -split '[\\/]+')) { if ($part) { $p = Join-Path $p $part } }; $p }
function Ensure-AawParentDirectory { param([string]$Path) $parent = Split-Path -Parent $Path; if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null } }

function Show-AawHelp {
@'
ai_agent_workflow installer

Usage:
  powershell -ExecutionPolicy Bypass -File install.ps1 -Source . -Target . -Agents claude,cursor,codex,copilot,gemini,aider
  $commit = '<full-40-character-sha>'
  & ([scriptblock]::Create((irm "https://raw.githubusercontent.com/MugenKaizen/Hekate/$commit/install.ps1"))) -Commit $commit -Target .

Flags:
  -Target <path>      Root of the target project. Defaults to the current directory.
  -Agents <list>     Comma-separated: claude,cursor,codex,copilot,gemini,aider. Defaults to all.
  -Force             Overwrite existing files. Any pre-existing managed file is backed
                     up first into .workflow/backups/<UTC-timestamp>/ (same convention
                     update-runner.ps1 uses). Prints a warning listing what will be
                     overwritten and asks for confirmation before writing anything.
  -Yes               Skip the -Force confirmation prompt (needed for non-interactive
                     invocations combined with -Force).
  -DryRun            Show what would be done (including what -Force would back
                     up/overwrite) without making changes.
  -Source <path>     Local copy of the repository (for installer development).
  -Commit <sha>      Full 40-character commit SHA. Required for downloads.
  -Ref <git-ref>     Source revision metadata for local -Source development.
  -Repo <owner/name> GitHub repository. Defaults to the built-in one.
'@ | Write-Host
}

foreach ($arg in $Rest) {
    if ($arg -like '--target=*') { $Target = $arg.Substring(9); continue }
    if ($arg -like '--agents=*') { $Agents = $arg.Substring(9); continue }
    if ($arg -like '--source=*') { $Source = $arg.Substring(9); continue }
    if ($arg -like '--ref=*') { $Ref = $arg.Substring(6); continue }
    if ($arg -like '--commit=*') { $Commit = $arg.Substring(9); continue }
    if ($arg -like '--repo=*') { $Repo = $arg.Substring(7); continue }
    if ($arg -eq '--force') { $Force = $true; continue }
    if ($arg -eq '--yes') { $Yes = $true; continue }
    if ($arg -eq '--dry-run') { $DryRun = $true; continue }
    if ($arg -eq '-h' -or $arg -eq '--help') { $Help = $true; continue }
    Throw-Aaw "unknown arg: $arg"
}

if ($Help) { Show-AawHelp; exit 0 }

$script:DRY_RUN = [bool]$DryRun
$cleanupDir = ''
$script:INSTALLED_REV = ''

if ($Ref -and $Commit) { Throw-Aaw 'use either -Ref or -Commit' }
if ($Commit -and $Commit -notmatch '^[0-9a-fA-F]{40}$') { Throw-Aaw '-Commit must be a full 40-character hexadecimal SHA' }

# PlanMode makes Copy-AawInstallItem only record its destination path (for a
# pre-flight -Force overwrite/backup report) instead of touching anything.
$script:PLAN_MODE = $false
$script:PLAN_LIST = New-Object System.Collections.Generic.List[string]

function Copy-AawInstallItem {
    param([string]$Src, [string]$Dst)

    if ($script:PLAN_MODE) {
        $script:PLAN_LIST.Add($Dst)
        return
    }

    if (-not (Test-Path -LiteralPath $Src)) {
        Write-AawWarn "source missing: $Src"
        return
    }
    if (Test-Path -LiteralPath $Dst) {
        if (-not $Force) {
            Write-AawLog "skip (exists): $Dst"
            return
        }
        $dstRel = $Dst
        if ($dstRel.StartsWith($Target)) {
            $dstRel = $dstRel.Substring($Target.Length).TrimStart('\', '/')
        }
        Backup-AawFile $dstRel
    }
    if ($DryRun) {
        Write-AawLog "would copy: $Src -> $Dst"
        return
    }
    Ensure-AawParentDirectory $Dst
    Copy-Item -LiteralPath $Src -Destination $Dst -Recurse -Force
    Write-AawLog "copied: $Dst"
}

function Test-AawAgent {
    param([string]$Name)
    return ((',' + $Agents + ',') -like "*,$Name,*")
}

function Copy-AawSkills {
    param([string]$SourceRoot, [string]$DestinationRoot)
    foreach ($dir in (Get-ChildItem -LiteralPath $SourceRoot -Directory)) {
        $skill = Join-AawPath $dir.FullName 'SKILL.md'
        if (Test-Path -LiteralPath $skill) {
            Copy-AawInstallItem $skill (Join-AawPath $DestinationRoot ($dir.Name + '/SKILL.md'))
        }
    }
}

function Append-AawInstallGitignore {
    param([string]$Snippet)
    $gi = Join-AawPath $Target '.gitignore'
    if (-not (Test-Path -LiteralPath $Snippet)) { return }
    if ($DryRun) {
        Write-AawLog "would ensure .gitignore contains entries from $Snippet"
        return
    }
    Ensure-AawParentDirectory $gi
    if (-not (Test-Path -LiteralPath $gi)) { New-Item -ItemType File -Path $gi | Out-Null }
    $existing = Get-Content -LiteralPath $gi
    foreach ($line in (Get-Content -LiteralPath $Snippet)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('#')) {
            if ($existing -notcontains '# ai_agent_workflow') { Add-Content -LiteralPath $gi -Value ''; Add-Content -LiteralPath $gi -Value $line; $existing += $line }
        } elseif ($existing -notcontains $line) {
            Add-Content -LiteralPath $gi -Value $line
            $existing += $line
        }
    }
    Write-AawLog "updated: $gi"
}

function Write-AawInstallState {
    param([string]$SrcRoot)
    $stateFile = Join-AawPath $Target '.workflow/state.yml'
    if ($DryRun) {
        Write-AawLog "would write install state: $stateFile"
        return
    }
    Ensure-AawParentDirectory $stateFile
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('install:')
    $lines.Add('  tool: hekate')
    $lines.Add("  installed_repo: $Repo")
    $lines.Add("  installed_ref: $script:INSTALLED_REV")
    $lines.Add('  installed_at: ' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
    $lines.Add('  adapters:')
    foreach ($agent in ($Agents -split ',')) { if ($agent.Trim()) { $lines.Add('    - ' + $agent.Trim()) } }
    $lines.Add('schema:')
    $lines.Add('  state_version: 2')
    $migrationDir = Join-Path $SrcRoot 'migrations'
    $migrationFiles = @()
    if (Test-Path -LiteralPath $migrationDir) { $migrationFiles = Get-ChildItem -LiteralPath $migrationDir -Filter '*.ps1' | Sort-Object Name }
    if ($migrationFiles.Count -gt 0) {
        $lines.Add('  applied_migrations:')
        foreach ($file in $migrationFiles) { $lines.Add('    - ' + [System.IO.Path]::GetFileNameWithoutExtension($file.Name)) }
    } else {
        $lines.Add('  applied_migrations: []')
    }
    [System.IO.File]::WriteAllLines($stateFile, $lines.ToArray(), [System.Text.Encoding]::UTF8)
    Write-AawLog "updated: $stateFile"
}

function Invoke-AawLayDownFiles {
    param([string]$Tpl)

    Copy-AawInstallItem (Join-AawPath $Tpl 'AGENTS.md') (Join-AawPath $Target 'AGENTS.md')
    foreach ($rel in @(
        '.workflow/stack.yml', '.workflow/architecture.yml', '.workflow/conventions.yml',
        '.workflow/workflow.yml', '.workflow/presets.yml', '.workflow/status.yml',
        '.workflow/orchestration.yml', '.workflow/session.local.yml',
        '.workflow/bootstrap.md', '.workflow/delegation.md', '.workflow/subagents.md',
        '.workflow/history-format.md', '.workflow/README.md',
        '.workflow/bin/hekate-agent', '.workflow/bin/hekate-agent.ps1', '.workflow/history/.gitkeep'
    )) {
        Copy-AawInstallItem (Join-AawPath $Tpl $rel) (Join-AawPath $Target $rel)
    }

    if (Test-AawAgent 'claude') {
        Copy-AawInstallItem (Join-AawPath $Tpl 'adapters/claude/CLAUDE.md') (Join-AawPath $Target 'CLAUDE.md')
        foreach ($file in (Get-ChildItem -LiteralPath (Join-AawPath $Tpl 'adapters/claude/commands') -Filter '*.md')) {
            Copy-AawInstallItem $file.FullName (Join-AawPath $Target ('.claude/commands/' + $file.Name))
        }
        foreach ($file in (Get-ChildItem -LiteralPath (Join-AawPath $Tpl 'adapters/claude/agents') -Filter '*.md')) {
            Copy-AawInstallItem $file.FullName (Join-AawPath $Target ('.claude/agents/' + $file.Name))
        }
        Copy-AawSkills (Join-AawPath $Tpl 'skills') (Join-AawPath $Target '.claude/skills')
    }
    if (Test-AawAgent 'cursor') {
        Copy-AawInstallItem (Join-AawPath $Tpl 'adapters/cursor/.cursor/rules/workflow.mdc') (Join-AawPath $Target '.cursor/rules/workflow.mdc')
    }
    if (Test-AawAgent 'copilot') {
        Copy-AawInstallItem (Join-AawPath $Tpl 'adapters/copilot/.github/copilot-instructions.md') (Join-AawPath $Target '.github/copilot-instructions.md')
    }
    if (Test-AawAgent 'gemini') {
        Copy-AawInstallItem (Join-AawPath $Tpl 'adapters/gemini/GEMINI.md') (Join-AawPath $Target 'GEMINI.md')
    }
    if (Test-AawAgent 'aider') {
        Copy-AawInstallItem (Join-AawPath $Tpl 'adapters/aider/.aider.conf.yml') (Join-AawPath $Target '.aider.conf.yml')
    }
    if ((Test-AawAgent 'cursor') -or (Test-AawAgent 'codex') -or (Test-AawAgent 'copilot') -or (Test-AawAgent 'gemini') -or (Test-AawAgent 'aider')) {
        Copy-AawSkills (Join-AawPath $Tpl 'skills') (Join-AawPath $Target '.agents/skills')
    }
}

try {
    if ($Source) {
        $script:INSTALLED_REV = if ($Commit) { $Commit } elseif ($Ref) { $Ref } else { 'HEAD' }
        $srcRoot = (Resolve-Path -LiteralPath $Source).Path
        if (-not (Test-Path -LiteralPath (Join-Path $srcRoot 'templates'))) { Throw-Aaw "-Source does not look like ai_agent_workflow: $srcRoot" }
        Write-AawLog "using local source: $srcRoot"
    } else {
        if (-not $Commit) { Throw-Aaw 'remote installation requires -Commit <full-40-character-sha>' }
        $script:INSTALLED_REV = $Commit
        $cleanupDir = Join-Path ([System.IO.Path]::GetTempPath()) ('aaw-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $cleanupDir | Out-Null
        $zip = Join-Path $cleanupDir 'src.zip'
        $url = "https://codeload.github.com/$Repo/zip/$Commit"
        Write-AawLog "downloading $url"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath $cleanupDir -Force
        $dirs = Get-ChildItem -LiteralPath $cleanupDir -Directory
        if ($dirs.Count -lt 1) { Throw-Aaw "could not locate extracted repo in $cleanupDir" }
        $srcRoot = $dirs[0].FullName
    }

    $tpl = Join-Path $srcRoot 'templates'
    if (-not (Test-Path -LiteralPath $tpl)) { Throw-Aaw "templates dir missing: $tpl" }
    if (-not (Test-Path -LiteralPath $Target)) { Throw-Aaw "target dir does not exist: $Target" }
    if ((Test-Path -LiteralPath (Join-AawPath $Target '.workflow/workflow.yml')) -and -not $Force) {
        Throw-Aaw "Hekate is already installed in $Target; use update.ps1 (or rerun with -Force to replace managed files)"
    }

    # lib/update-common.ps1 provides Backup-AawFile/Remove-AawOldBackupRuns so
    # -Force backs up pre-existing files the same way update-runner.ps1 does.
    $script:TARGET = $Target
    $script:BACKUP_ROOT = Join-AawPath $Target '.workflow/backups'
    $script:RUN_TIMESTAMP = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $script:RUN_BACKUP_DIR = Join-AawPath $script:BACKUP_ROOT $script:RUN_TIMESTAMP
    $installTmp = Join-Path ([System.IO.Path]::GetTempPath()) ('aaw-install-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $installTmp | Out-Null
    $script:BACKED_UP_LIST_FILE = Join-Path $installTmp 'backed-up-files.txt'
    New-Item -ItemType File -Force -Path $script:BACKED_UP_LIST_FILE | Out-Null
    . (Join-Path $srcRoot 'lib/update-common.ps1')

    Write-AawLog "target: $Target"
    Write-AawLog "agents: $Agents"
    if ($DryRun) { Write-AawLog 'DRY RUN - no files will be written' }

    if ($Force) {
        $script:PLAN_MODE = $true
        Invoke-AawLayDownFiles $tpl
        $script:PLAN_MODE = $false

        $overwrite = @($script:PLAN_LIST | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
        if ($overwrite.Count -gt 0) {
            Write-AawWarn "-Force enabled; $($overwrite.Count) existing file(s) will be overwritten (backed up first into $($script:RUN_BACKUP_DIR)):"
            foreach ($path in $overwrite) { Write-Host "[aaw]   - $path" }

            if (-not $DryRun -and -not $Yes) {
                $answer = Read-Host '[aaw] Continue? Type "yes" to proceed'
                if ($answer -ne 'yes') { Throw-Aaw 'install cancelled' }
            }
        }
    }

    Invoke-AawLayDownFiles $tpl

    if (-not $DryRun) { Remove-AawOldBackupRuns 5 }

    Append-AawInstallGitignore (Join-AawPath $tpl 'gitignore.snippet')
    Write-AawInstallState $srcRoot

@'

---------------------------------------------------------
 ai_agent_workflow installed.

 Next step:
   1. Open the project in your AI agent (Claude Code / Cursor / Codex / ...).
   2. Ask: "initialize the workflow" (or /init-workflow in Claude).
   3. The agent will analyze the project, fill out .workflow/*.yml,
      and write .workflow/status.yml.

  To update later, choose a trusted full commit SHA and use the commit-pinned
  command from the Hekate README. Branches, tags, and short SHAs are rejected.

 Until the required fields are filled in, the agent will NOT work - this is by design.
---------------------------------------------------------
'@ | Write-Host
} finally {
    if ($cleanupDir -and (Test-Path -LiteralPath $cleanupDir)) { Remove-Item -LiteralPath $cleanupDir -Recurse -Force }
    if ($installTmp -and (Test-Path -LiteralPath $installTmp)) { Remove-Item -LiteralPath $installTmp -Recurse -Force }
}
