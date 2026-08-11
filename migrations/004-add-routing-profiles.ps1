Set-StrictMode -Version 2.0

if (-not (Get-Variable -Name RUNNER_ROOT -Scope Script -ErrorAction SilentlyContinue)) { $script:RUNNER_ROOT = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not (Get-Command Backup-AawFile -ErrorAction SilentlyContinue)) { . (Join-Path $script:RUNNER_ROOT 'lib/update-common.ps1') }

$configFile = Join-AawPath $script:TARGET '.workflow/orchestration.yml'
$statusFile = Join-AawPath $script:TARGET '.workflow/status.yml'
$configExists = Test-Path -LiteralPath $configFile
$configLines = @()
$needsSchema = $false; $needsDefault = $false; $needsProfiles = $false
if ($configExists) {
    $configLines = @(Get-Content -LiteralPath $configFile)
    $schemaValue = ''
    foreach ($line in $configLines) { if ($line -match '^schema_version:\s*(\S+)') { $schemaValue = $matches[1]; break } }
    $needsSchema = $schemaValue -in @('','0','1')
    $needsDefault = -not ($configLines -match '^default_profile:')
    $needsProfiles = -not ($configLines -match '^profiles:\s*$')
}
$needsStatus = $false
if (Test-Path -LiteralPath $statusFile) {
    $inside = $false; $found = $false
    foreach ($line in Get-Content -LiteralPath $statusFile) {
        if ($line -match '^orchestration:\s*$') { $inside = $true; continue }
        if ($inside -and $line -match '^\S') { break }
        if ($inside -and $line -match '^  default_profile:') { $found = $true; break }
    }
    $needsStatus = -not $found
}
if (-not $needsSchema -and -not $needsDefault -and -not $needsProfiles -and -not $needsStatus) { return }

if ($configExists) { Backup-AawFile '.workflow/orchestration.yml' }
if ($needsStatus) { Backup-AawFile '.workflow/status.yml' }
if ($script:DRY_RUN) {
    if ($needsSchema -or $needsDefault -or $needsProfiles) { Write-AawLog "would add schema v2 routing-profile fields to $configFile" }
    if ($needsStatus) { Write-AawLog "would mirror default_profile into $statusFile" }
    return
}

if ($needsSchema -or $needsDefault -or $needsProfiles) {
    $out = New-Object System.Collections.Generic.List[string]
    $schemaDone = $false; $defaultDone = $false; $profilesDone = $false
    foreach ($line in $configLines) {
        if ($needsSchema -and -not $schemaDone -and $line -match '^schema_version:') {
            $out.Add('schema_version: 2'); $schemaDone = $true; continue
        }
        if ($needsProfiles -and -not $profilesDone -and $line -match '^harnesses:\s*$') {
            $out.Add('profiles:'); $out.Add(''); $profilesDone = $true
        }
        $out.Add($line)
        if ($needsDefault -and -not $defaultDone -and $line -match '^default_harness:') {
            $out.Add('default_profile: null'); $defaultDone = $true
        }
    }
    if ($needsSchema -and -not $schemaDone) { $out.Add('schema_version: 2') }
    if ($needsDefault -and -not $defaultDone) { $out.Add('default_profile: null') }
    if ($needsProfiles -and -not $profilesDone) { $out.Add('profiles:') }
    [IO.File]::WriteAllLines($configFile, $out.ToArray(), [Text.Encoding]::UTF8)
    Write-AawLog "updated: $configFile"
}

if ($needsStatus) {
    $profile = 'null'
    if (Test-Path -LiteralPath $configFile) {
        foreach ($line in Get-Content -LiteralPath $configFile) { if ($line -match '^default_profile:\s*(\S+)') { $profile = $matches[1]; break } }
    }
    $out = New-Object System.Collections.Generic.List[string]
    $inside = $false; $inserted = $false
    foreach ($line in Get-Content -LiteralPath $statusFile) {
        if ($inside -and $line -match '^\S') {
            if (-not $inserted) { $out.Add("  default_profile: $profile"); $inserted = $true }
            $inside = $false
        }
        if ($line -match '^orchestration:\s*$') { $inside = $true }
        $out.Add($line)
        if ($inside -and -not $inserted -and $line -match '^  default_harness:') {
            $out.Add("  default_profile: $profile"); $inserted = $true
        }
    }
    if ($inside -and -not $inserted) { $out.Add("  default_profile: $profile") }
    [IO.File]::WriteAllLines($statusFile, $out.ToArray(), [Text.Encoding]::UTF8)
    Write-AawLog "updated: $statusFile"
}
