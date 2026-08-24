Set-StrictMode -Version 2.0

if (-not (Get-Variable -Name RUNNER_ROOT -Scope Script -ErrorAction SilentlyContinue)) { $script:RUNNER_ROOT = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not (Get-Command Copy-AawFile -ErrorAction SilentlyContinue)) { . (Join-Path $script:RUNNER_ROOT 'lib/update-common.ps1') }

# Hekate now ships real adapters for GitHub Copilot, Gemini CLI, and Aider
# (copilot, gemini, aider), in addition to claude/cursor/codex. Existing
# installations opt into a new adapter simply by asking for it - either by
# re-running update.ps1 with -Agents copilot,gemini,aider (which the runner
# honors on the same run) or by hand-authoring the adapter's marker file
# before updating.
#
# This migration only backfills the .workflow/state.yml adapters ledger for
# marker files that already exist on disk. It never creates files itself -
# that stays opt-in - and it never overwrites an adapter already recorded in
# state.

if (-not (Test-Path -LiteralPath $script:STATE_FILE)) { return }

function Register-AawAdapterIfMarkerPresent {
    param([string]$AdapterName, [string]$MarkerPath)

    if (-not (Test-Path -LiteralPath $MarkerPath)) { return }
    if (Test-AawStateHasAdapter $AdapterName $script:STATE_FILE) { return }

    if ($script:DRY_RUN) {
        Write-AawLog "would register adapter in state: $AdapterName"
        return
    }

    Backup-AawFile '.workflow/state.yml'

    $lines = Get-Content -LiteralPath $script:STATE_FILE
    $out = New-Object System.Collections.Generic.List[string]
    $done = $false
    foreach ($line in $lines) {
        $out.Add($line)
        if ((-not $done) -and ($line -match '^\s*adapters:\s*$')) {
            $out.Add('    - ' + $AdapterName)
            $done = $true
        }
    }
    [System.IO.File]::WriteAllLines($script:STATE_FILE, $out.ToArray(), [System.Text.Encoding]::UTF8)
    Write-AawLog "registered adapter in state: $AdapterName"
}

Register-AawAdapterIfMarkerPresent 'copilot' (Join-AawPath $script:TARGET '.github/copilot-instructions.md')
Register-AawAdapterIfMarkerPresent 'gemini'  (Join-AawPath $script:TARGET 'GEMINI.md')
Register-AawAdapterIfMarkerPresent 'aider'   (Join-AawPath $script:TARGET '.aider.conf.yml')
