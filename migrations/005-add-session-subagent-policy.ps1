Set-StrictMode -Version 2.0

if (-not (Get-Variable -Name RUNNER_ROOT -Scope Script -ErrorAction SilentlyContinue)) { $script:RUNNER_ROOT = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not (Get-Command Join-AawPath -ErrorAction SilentlyContinue)) { . (Join-Path $script:RUNNER_ROOT 'lib/update-common.ps1') }

$policyFile = Join-AawPath $script:TARGET '.workflow/session.local.yml'
$statusFile = Join-AawPath $script:TARGET '.workflow/status.yml'
$needsPolicy = -not (Test-Path -LiteralPath $policyFile)
$needsStatus = (Test-Path -LiteralPath $statusFile) -and -not ((Get-Content -LiteralPath $statusFile) -match '^native_subagents:\s*$')
if (-not $needsPolicy -and -not $needsStatus) { return }

if ($needsStatus) { Backup-AawFile '.workflow/status.yml' }
if ($script:DRY_RUN) {
    if ($needsPolicy) { Write-AawLog "would create local native-subagent policy: $policyFile" }
    if ($needsStatus) { Write-AawLog "would add native-subagent policy pointer to $statusFile" }
    return
}

if ($needsPolicy) {
    $parent = Split-Path -Parent $policyFile
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $lines = @(
        '# Local policy for native subagents in the current user-facing harness session.',
        '# This file is gitignored. The user may change the mode at any time.',
        '# Missing/invalid mode is treated as `ask`.',
        '',
        'schema_version: 1',
        '',
        'subagents:',
        '  # off  — never launch native subagents',
        '  # ask  — ask once before each exact delegation wave (safe default)',
        '  # auto — the primary harness may launch native subagents at its discretion',
        '  mode: ask'
    )
    [IO.File]::WriteAllLines($policyFile, $lines, [Text.UTF8Encoding]::new($false))
    Write-AawLog "created: $policyFile"
}

if ($needsStatus) {
    $out = New-Object System.Collections.Generic.List[string]
    $inserted = $false
    foreach ($line in Get-Content -LiteralPath $statusFile) {
        if (-not $inserted -and $line -match '^lazy_load:\s*$') {
            $out.Add('native_subagents:')
            $out.Add('  policy: .workflow/session.local.yml')
            $out.Add('  missing_or_invalid_mode: ask')
            $out.Add('')
            $inserted = $true
        }
        $out.Add($line)
    }
    if (-not $inserted) {
        $out.Add('')
        $out.Add('native_subagents:')
        $out.Add('  policy: .workflow/session.local.yml')
        $out.Add('  missing_or_invalid_mode: ask')
    }
    [IO.File]::WriteAllLines($statusFile, $out.ToArray(), [Text.UTF8Encoding]::new($false))
    Write-AawLog "updated: $statusFile"
}
