Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Temp = Join-Path ([IO.Path]::GetTempPath()) ('hekate-ps-' + [guid]::NewGuid().ToString('N'))
$Project = Join-Path $Temp 'project with spaces'

function Assert-Contains([string]$Actual, [string]$Expected) {
    if (-not $Actual.Contains($Expected)) { throw "Expected [$Expected] in [$Actual]" }
}

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $Project '.workflow\bin') | Out-Null
    Copy-Item (Join-Path $Root 'templates\.workflow\bin\hekate-agent.ps1') (Join-Path $Project '.workflow\bin\hekate-agent.ps1')
    $fake = Join-Path $Project 'fake-harness.ps1'
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
Write-Output ('args:' + ($Rest -join '|'))
if (-not [Console]::IsInputRedirected) { exit 0 }
$inputText = [Console]::In.ReadToEnd()
if ($inputText) { Write-Output ('stdin:' + $inputText.TrimEnd()) }
'@ | Set-Content -LiteralPath $fake -Encoding UTF8

    $psExe = (Get-Process -Id $PID).Path
    $quotedExe = $psExe.Replace('"','')
    $quotedFake = $fake.Replace('"','')
    $config = @"
schema_version: 2
enabled: false
default_harness: fake
default_profile: medium
jobs_dir: .workflow/runs
allow_external_cwd: false

profiles:
  medium:
    harness: fake
    model: profile/model
    effort: medium
  none:
    harness: fake
    model: reserved/model
    effort: medium

harnesses:
  fake:
    enabled: true
    command: "$quotedExe"
    prompt_delivery: argument
    supports_model: true
    supports_effort: true
    default_model: default/model
    default_effort: medium
    models_command: "$quotedExe"
    models_args:
      - -NoProfile
      - -Command
      - "Write-Output default/model"
    args:
      - -NoProfile
      - -File
      - "$quotedFake"
      - --model
      - "{model}"
      - --effort
      - "{effort}"
  missing:
    enabled: true
    command: definitely-missing-hekate-command
    prompt_delivery: argument
    supports_model: true
    supports_effort: true
    default_model: default/model
    default_effort: medium
    args:
  disabled:
    enabled: false
    command: disabled-hekate-command
    prompt_delivery: argument
    supports_model: true
    supports_effort: true
    default_model: default/model
    default_effort: medium
    args:
"@
    Set-Content -LiteralPath (Join-Path $Project '.workflow\orchestration.yml') -Value $config -Encoding UTF8
    $cli = Join-Path $Project '.workflow\bin\hekate-agent.ps1'

    & $cli config use-profile medium | Out-Null
    $profileRun = (& $cli run --foreground --effort xhigh --task 'profile task' | Out-String)
    Assert-Contains $profileRun 'profile/model'
    Assert-Contains $profileRun 'xhigh'
    $profiles = (& $cli profiles | Out-String)
    Assert-Contains $profiles 'medium'
    if ($profiles.Contains('none')) { throw 'Reserved profile was listed' }

    Add-Content -LiteralPath (Join-Path $Project '.workflow\orchestration.local.yml') -Value @'

profiles:
  personal:
    harness: fake
    model: personal/model
    effort: high
'@
    $profiles = (& $cli profiles | Out-String)
    Assert-Contains $profiles 'medium'
    Assert-Contains $profiles 'personal'
    & $cli config use-profile personal | Out-Null
    $personalRun = (& $cli run --foreground --task 'personal profile task' | Out-String)
    Assert-Contains $personalRun 'personal/model'

    & $psExe -NoProfile -ExecutionPolicy Bypass -File $cli config use-profile none 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'Reserved profile was accepted' }

    $doctor = (& $cli doctor | Out-String)
    Assert-Contains $doctor 'missing'
    Assert-Contains $doctor 'disabled'
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $cli doctor missing 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'Targeted missing doctor returned success' }
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $cli doctor disabled 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'Targeted disabled doctor returned success' }

    & $cli config use fake --model test/model --effort high | Out-Null
    $show = (& $cli config show | Out-String)
    Assert-Contains $show 'default_harness: fake'
    Assert-Contains $show 'default_profile: none'
    Assert-Contains $show 'test/model'

    $foreground = (& $cli run --foreground --task 'task with spaces' | Out-String)
    Assert-Contains $foreground 'test/model'
    Assert-Contains $foreground 'task with spaces'

    $job = (& $cli run --task 'background task' | Select-Object -Last 1).Trim()
    & $cli wait $job --timeout 30
    $status = (& $cli status $job | Out-String)
    Assert-Contains $status 'status: completed'
    $result = (& $cli result $job | Out-String)
    Assert-Contains $result 'background task'

    $outside = Join-Path $Temp 'outside'
    New-Item -ItemType Directory -Path $outside | Out-Null
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $cli run --foreground --cwd $outside --task denied 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'External cwd was accepted' }

    Write-Output 'ok: PowerShell hekate-agent integration tests passed'
} finally {
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
