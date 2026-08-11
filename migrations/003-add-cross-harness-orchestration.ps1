Set-StrictMode -Version 2.0

if (-not (Get-Variable -Name RUNNER_ROOT -Scope Script -ErrorAction SilentlyContinue)) { $script:RUNNER_ROOT = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not (Get-Command Backup-AawFile -ErrorAction SilentlyContinue)) { . (Join-Path $script:RUNNER_ROOT 'lib/update-common.ps1') }

$statusFile = Join-AawPath $script:TARGET '.workflow/status.yml'
if (-not (Test-Path -LiteralPath $statusFile)) { return }
$lines = @(Get-Content -LiteralPath $statusFile)
$needsBlock = $lines -notcontains 'orchestration:'
$needsLazy = $lines -notcontains '  orchestration: .workflow/orchestration.yml'
if (-not $needsBlock -and -not $needsLazy) { return }

$enabled = 'false'
$defaultHarness = 'pi'
$configFile = Join-AawPath $script:TARGET '.workflow/orchestration.yml'
if (Test-Path -LiteralPath $configFile) {
    foreach ($line in Get-Content -LiteralPath $configFile) {
        if ($line -match '^enabled:\s*(true|false)\s*$') { $enabled = $matches[1] }
        if ($line -match '^default_harness:\s*([A-Za-z0-9_.-]+)\s*$') { $defaultHarness = $matches[1] }
    }
}

Backup-AawFile '.workflow/status.yml'
if ($script:DRY_RUN) {
    Write-AawLog "would add orchestration status/lazy-load fields to $statusFile"
    return
}

$out = New-Object System.Collections.Generic.List[string]
$lazyInserted = -not $needsLazy
foreach ($line in $lines) {
    $out.Add($line)
    if (-not $lazyInserted -and $line -eq '  bootstrap: .workflow/bootstrap.md') {
        $out.Add('  orchestration: .workflow/orchestration.yml')
        $lazyInserted = $true
    }
}
if (-not $lazyInserted) {
    $out.Add('')
    $out.Add('lazy_load:')
    $out.Add('  orchestration: .workflow/orchestration.yml')
}
if ($needsBlock) {
    $out.Add('')
    $out.Add('orchestration:')
    $out.Add("  enabled: $enabled")
    $out.Add("  default_harness: $defaultHarness")
    $out.Add('  config: .workflow/orchestration.yml')
    $out.Add('  runner: .workflow/bin/hekate-agent')
}
[System.IO.File]::WriteAllLines($statusFile, $out.ToArray(), [System.Text.Encoding]::UTF8)
Write-AawLog "updated: $statusFile"
