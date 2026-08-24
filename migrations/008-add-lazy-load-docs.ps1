Set-StrictMode -Version 2.0

if (-not (Get-Variable -Name RUNNER_ROOT -Scope Script -ErrorAction SilentlyContinue)) { $script:RUNNER_ROOT = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not (Get-Command Copy-AawFile -ErrorAction SilentlyContinue)) { . (Join-Path $script:RUNNER_ROOT 'lib/update-common.ps1') }

# AGENTS.md was restructured to lazy-load detail out of three new files:
# .workflow/delegation.md, .workflow/subagents.md, .workflow/history-format.md.
# Existing installations updated in place would otherwise end up with a new
# AGENTS.md that references files they don't have yet. Add them if missing;
# never overwrite a file that's already there.

function Add-AawFileIfMissing {
    param([string]$RelativePath)
    $src = Join-AawPath $script:RUNNER_ROOT ('templates/' + $RelativePath)
    $dst = Join-AawPath $script:TARGET $RelativePath

    if (-not (Test-Path -LiteralPath $src)) { return }
    if (Test-Path -LiteralPath $dst) { return }

    Copy-AawFile $src $dst
    Write-AawLog "added: $dst"
}

Add-AawFileIfMissing '.workflow/delegation.md'
Add-AawFileIfMissing '.workflow/subagents.md'
Add-AawFileIfMissing '.workflow/history-format.md'
