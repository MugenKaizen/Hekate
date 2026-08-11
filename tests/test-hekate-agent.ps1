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
schema_version: 1
enabled: false
default_harness: fake
jobs_dir: .workflow/runs
allow_external_cwd: false

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
"@
    Set-Content -LiteralPath (Join-Path $Project '.workflow\orchestration.yml') -Value $config -Encoding UTF8
    $cli = Join-Path $Project '.workflow\bin\hekate-agent.ps1'

    & $cli config use fake --model test/model --effort high | Out-Null
    $show = (& $cli config show | Out-String)
    Assert-Contains $show 'default_harness: fake'
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
