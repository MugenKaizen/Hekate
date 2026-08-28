Set-StrictMode -Version 2.0

if (-not (Get-Variable -Name RUNNER_ROOT -Scope Script -ErrorAction SilentlyContinue)) { $script:RUNNER_ROOT = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not (Get-Command Join-AawPath -ErrorAction SilentlyContinue)) { . (Join-Path $script:RUNNER_ROOT 'lib/update-common.ps1') }

$workflowFile = Join-AawPath $script:TARGET '.workflow/workflow.yml'
$statusFile = Join-AawPath $script:TARGET '.workflow/status.yml'
$needsWorkflow = (Test-Path -LiteralPath $workflowFile) -and -not ((Get-Content -LiteralPath $workflowFile) -match '^hekate:\s*$')
$needsStatus = (Test-Path -LiteralPath $statusFile) -and -not ((Get-Content -LiteralPath $statusFile) -match '^hekate:\s*$')
if (-not $needsWorkflow -and -not $needsStatus) { return }

if ($needsWorkflow) { Backup-AawFile '.workflow/workflow.yml' }
if ($needsStatus) { Backup-AawFile '.workflow/status.yml' }
if ($script:DRY_RUN) {
    if ($needsWorkflow) { Write-AawLog "would add Hekate module switches to $workflowFile" }
    if ($needsStatus) { Write-AawLog "would add Hekate module switches to $statusFile" }
    return
}

function Add-HekateModuleSwitches([string]$Path, [string]$Anchor) {
    $out = New-Object System.Collections.Generic.List[string]
    $inserted = $false
    foreach ($line in Get-Content -LiteralPath $Path) {
        if (-not $inserted -and $line -eq $Anchor) {
            $out.Add('hekate:')
            $out.Add('  enabled: true')
            $out.Add('  modules:')
            $out.Add('    workflow: true')
            $out.Add('    history: true')
            $out.Add('    native_subagents: true')
            $out.Add('    orchestration: true')
            $out.Add('')
            $inserted = $true
        }
        $out.Add($line)
    }
    if (-not $inserted) {
        $out.Add('')
        $out.Add('hekate:')
        $out.Add('  enabled: true')
        $out.Add('  modules:')
        $out.Add('    workflow: true')
        $out.Add('    history: true')
        $out.Add('    native_subagents: true')
        $out.Add('    orchestration: true')
    }
    [IO.File]::WriteAllLines($Path, $out.ToArray(), [Text.UTF8Encoding]::new($false))
}

if ($needsWorkflow) {
    Add-HekateModuleSwitches $workflowFile 'meta:'
    Write-AawLog "updated: $workflowFile"
}
if ($needsStatus) {
    Add-HekateModuleSwitches $statusFile 'features:'
    Write-AawLog "updated: $statusFile"
}
