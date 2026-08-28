# PowerShell mirror of tests/test-hekate-agent.sh, covering the same
# scenarios against templates/.workflow/bin/hekate-agent.ps1. Windows
# PowerShell 5.1-compatible: no ?:, ??, or other PS7-only syntax.
#
# NOTE: this suite has not been executed against a real PowerShell/pwsh
# install as part of authoring it (none was available in the environment
# that wrote it). Review carefully before trusting a first "pass" result.
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("hekate-ps-test-" + [Guid]::NewGuid().ToString('N'))
$Project = Join-Path $Tmp 'project'
$FakeBin = Join-Path $Tmp 'bin'
New-Item -ItemType Directory -Force -Path (Join-Path $Project '.workflow\bin') | Out-Null
New-Item -ItemType Directory -Force -Path $FakeBin | Out-Null

function Cleanup { if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue } }

$FailedMessage = $null
function TestFail([string]$Message) { throw "FAIL: $Message" }
function AssertContains([string]$Haystack, [string]$Needle, [string]$Label) {
    if ($null -eq $Haystack) { $Haystack = '' }
    if (-not $Haystack.Contains($Needle)) { TestFail "expected [$Needle] in [$Label]: $Haystack" }
}
function AssertNotContains([string]$Haystack, [string]$Needle, [string]$Label) {
    if ($null -eq $Haystack) { $Haystack = '' }
    if ($Haystack.Contains($Needle)) { TestFail "did not expect [$Needle] in [$Label]: $Haystack" }
}

# --- locate a PowerShell interpreter to run the CLI as a genuine separate
# process (invoking a .ps1 in-process via `&` would mean its `exit` calls
# tear down this test runner too).
$ShellExe = $null
foreach ($candidate in @('pwsh', 'powershell')) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { $ShellExe = $cmd.Source; break }
}
if (-not $ShellExe) { Write-Error 'no pwsh or powershell found to drive the CLI under test'; exit 2 }

$CliPath = Join-Path $Project '.workflow\bin\hekate-agent.ps1'

function Invoke-Hekate {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CliArgs)
    $errFile = Join-Path $Tmp ('stderr-' + [Guid]::NewGuid().ToString('N') + '.log')
    $stdout = & $ShellExe -NoProfile -ExecutionPolicy Bypass -File $CliPath @CliArgs 2>$errFile
    $code = $LASTEXITCODE
    $stderr = ''
    if (Test-Path -LiteralPath $errFile) { $stderr = (Get-Content -LiteralPath $errFile -Raw); Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
    return [PSCustomObject]@{ Out = ($stdout -join "`n"); Err = $stderr; Code = $code }
}

try {
    # --- build the fixture project -----------------------------------------
    $srcConfig = Join-Path $RepoRoot 'templates\.workflow\orchestration.yml'
    $dstConfig = Join-Path $Project '.workflow\orchestration.yml'
    $lines = Get-Content -LiteralPath $srcConfig
    $out = New-Object System.Collections.Generic.List[string]
    $currentHarness = ''
    $insertedFakes = $false
    foreach ($line in $lines) {
        if ($line -match '^default_profile:') { $out.Add('default_profile: medium'); continue }
        if ($line -match '^  ([A-Za-z0-9_.-]+):\s*$') { $currentHarness = $Matches[1] }
        if ($line -match '^    command:\s*(\S+)\s*$' -and $currentHarness -in @('claude', 'pi', 'aider')) {
            $out.Add("    command: $currentHarness.cmd"); continue
        }
        if ($line -match '^  opencode:\s*$') { $out.Add($line); continue }
        if ($currentHarness -eq 'opencode' -and $line -match '^    command:') {
            $out.Add('    command: hekate-test-missing-opencode'); continue
        }
        if (-not $insertedFakes -and $line -match '^  claude:\s*$') {
            $out.Add('  fakeXcli:')
            $out.Add('    enabled: true')
            $out.Add('    command: claude.cmd')
            $out.Add('    prompt_delivery: stdin')
            $out.Add('    supports_model: true')
            $out.Add('    supports_effort: true')
            $out.Add('    default_model: fake/alias-harness')
            $out.Add('    default_effort: low')
            $out.Add('    args:')
            $out.Add('  fake.cli:')
            $out.Add('    enabled: true')
            $out.Add('    command: pi.cmd')
            $out.Add('    prompt_delivery: argument')
            $out.Add('    supports_model: true')
            $out.Add('    supports_effort: true')
            $out.Add('    default_model: fake/dotted-harness')
            $out.Add('    default_effort: high')
            $out.Add('    args:')
            $insertedFakes = $true
            $out.Add($line)
            continue
        }
        if ($line -match '^profiles:\s*$') {
            $out.Add($line)
            $out.Add('  small:')
            $out.Add('    harness: pi')
            $out.Add('    model: fake/terra')
            $out.Add('    effort: high')
            $out.Add('  medium:')
            $out.Add('    harness: pi')
            $out.Add('    model: fake/sol')
            $out.Add('    effort: medium')
            $out.Add('  no-effort:')
            $out.Add('    harness: gemini')
            $out.Add('    effort: high')
            $out.Add('  aXb:')
            $out.Add('    harness: pi')
            $out.Add('    model: fake/alias')
            $out.Add('    effort: low')
            $out.Add('  a.b:')
            $out.Add('    harness: pi')
            $out.Add('    model: fake/dotted')
            $out.Add('    effort: high')
            $out.Add('  quoted:')
            $out.Add("    harness: 'pi'")
            $out.Add("    model: 'fake/quoted'")
            $out.Add("    effort: 'high'")
            $out.Add('  none:')
            $out.Add('    harness: pi')
            $out.Add('    model: fake/reserved')
            $out.Add('    effort: high')
            continue
        }
        $out.Add($line)
    }
    Set-Content -LiteralPath $dstConfig -Value $out -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'templates\.workflow\bin\hekate-agent.ps1') -Destination $CliPath -Force

    # --- fake harness executables (Windows batch, direct-launchable) -------
    Set-Content -LiteralPath (Join-Path $FakeBin 'pi.cmd') -Value @'
@echo off
setlocal EnableDelayedExpansion
set out=pi-args:
:loop
if "%~1"=="" goto done
set out=!out!<%~1>
if "%~1"=="SLOW" (
  ping -n 31 127.0.0.1 >nul
)
shift
goto loop
:done
echo !out!
'@ -Encoding ASCII

    Set-Content -LiteralPath (Join-Path $FakeBin 'claude.cmd') -Value @'
@echo off
setlocal EnableDelayedExpansion
set out=claude-args:
:loop
if "%~1"=="" goto done
set out=!out!<%~1>
shift
goto loop
:done
echo !out!
echo prompt:
findstr "^"
'@ -Encoding ASCII

    Set-Content -LiteralPath (Join-Path $FakeBin 'aider.cmd') -Value @'
@echo off
:loop
if "%~1"=="" goto notfound
if "%~1"=="--message-file" (
  set mf=%~2
  goto found
)
shift
goto loop
:found
set /p line=<"%mf%"
echo file-prompt:%line%
exit /b 0
:notfound
exit /b 2
'@ -Encoding ASCII

    $env:Path = "$FakeBin;$env:Path"
    Push-Location $Project

    # Disabled by default.
    $r = Invoke-Hekate 'run' '--task' 'nope'
    if ($r.Code -eq 0) { TestFail 'disabled orchestration accepted a run' }

    # Enable orchestration and pick up the committed default profile.
    (Get-Content -LiteralPath $dstConfig) -replace '^enabled: false$', 'enabled: true' | Set-Content -LiteralPath $dstConfig -Encoding UTF8
    $profiles = (Invoke-Hekate 'profiles').Out
    AssertContains $profiles 'medium' 'profiles'
    AssertContains $profiles 'fake/sol' 'profiles'
    AssertNotContains $profiles "`nnone " 'profiles'

    $r = Invoke-Hekate 'run' '--task' 'implicit committed profile' '--foreground'
    if ($r.Code -ne 0) { TestFail "implicit profile run failed: $($r.Err)" }
    $implicit = $r.Out.Trim()
    $implicitDir = Join-Path $Project ".workflow\runs\$implicit"
    if ((Get-Content -LiteralPath (Join-Path $implicitDir 'profile') -Raw).Trim() -ne 'medium') { TestFail 'committed default profile not persisted' }
    if ((Get-Content -LiteralPath (Join-Path $implicitDir 'model') -Raw).Trim() -ne 'fake/sol') { TestFail 'committed profile model not resolved' }

    # Explicit module switches prevent new jobs; a missing block above retained
    # backward-compatible behavior.
    $statusPath = Join-Path $Project '.workflow\status.yml'
    [IO.File]::WriteAllLines($statusPath, @('hekate:', '  enabled: true', '  modules:', '    orchestration: false'), [Text.UTF8Encoding]::new($false))
    $r = Invoke-Hekate 'run' '--task' 'nope'
    if ($r.Code -eq 0) { TestFail 'disabled orchestration module accepted a run' }
    [IO.File]::WriteAllLines($statusPath, @('hekate:', '    enabled: true', '    modules:', '        orchestration:'), [Text.UTF8Encoding]::new($false))
    $r = Invoke-Hekate 'run' '--task' 'nope'
    if ($r.Code -eq 0) { TestFail 'empty orchestration module with four-space indentation accepted a run' }
    [IO.File]::WriteAllLines($statusPath, @('hekate:', '  enabled: false'), [Text.UTF8Encoding]::new($false))
    $r = Invoke-Hekate 'run' '--task' 'nope'
    if ($r.Code -eq 0) { TestFail 'disabled Hekate accepted a run' }
    Remove-Item -LiteralPath $statusPath

    # Dotted profile/harness names.
    $harnesses = (Invoke-Hekate 'harnesses').Out
    $dottedLine = ($harnesses -split "`n") | Where-Object { $_ -match '^fake\.cli\s' }
    AssertContains $dottedLine 'command=pi.cmd' 'harnesses'
    AssertContains $dottedLine 'model=fake/dotted-harness' 'harnesses'
    $r = Invoke-Hekate 'run' '--profile' 'a.b' '--task' 'dotted exact profile' '--foreground'
    if ($r.Code -ne 0) { TestFail "dotted profile run failed: $($r.Err)" }
    $dottedDir = Join-Path $Project ".workflow\runs\$($r.Out.Trim())"
    if ((Get-Content -LiteralPath (Join-Path $dottedDir 'model') -Raw).Trim() -ne 'fake/dotted') { TestFail 'dotted profile aliased another name' }

    $r = Invoke-Hekate 'run' '--profile' 'quoted' '--task' 'quoted profile values' '--foreground'
    if ($r.Code -ne 0) { TestFail "quoted profile run failed: $($r.Err)" }
    $quotedDir = Join-Path $Project ".workflow\runs\$($r.Out.Trim())"
    if ((Get-Content -LiteralPath (Join-Path $quotedDir 'harness') -Raw).Trim() -ne 'pi') { TestFail 'single-quoted harness was not unquoted' }
    if ((Get-Content -LiteralPath (Join-Path $quotedDir 'model') -Raw).Trim() -ne 'fake/quoted') { TestFail 'single-quoted model was not unquoted' }

    # Local profile selection, explicit effort override.
    $r = Invoke-Hekate 'config' 'use-profile' 'small'
    AssertContains $r.Out 'default_profile: small' 'config use-profile'
    $r = Invoke-Hekate 'run' '--task' 'local profile override' '--effort' 'xhigh' '--foreground'
    if ($r.Code -ne 0) { TestFail "local profile run failed: $($r.Err)" }
    $localDir = Join-Path $Project ".workflow\runs\$($r.Out.Trim())"
    if ((Get-Content -LiteralPath (Join-Path $localDir 'effort') -Raw).Trim() -ne 'xhigh') { TestFail 'explicit effort did not override profile' }
    $statusOut = (Invoke-Hekate 'status' (Split-Path $localDir -Leaf)).Out
    AssertContains $statusOut 'profile: small' 'status'

    # --- item 1: unified job-directory field names --------------------------
    # These are the canonical, hyphenated file names shared with the sh
    # runner (worker-pid/child-pid/started-at/finished-at/exit-code/task.md).
    if (-not (Test-Path (Join-Path $localDir 'task.md'))) { TestFail 'task.md field missing (unified naming)' }
    if (-not (Test-Path (Join-Path $localDir 'exit-code'))) { TestFail 'exit-code field missing (unified naming)' }
    if (-not (Test-Path (Join-Path $localDir 'started-at'))) { TestFail 'started-at field missing (unified naming)' }
    if (-not (Test-Path (Join-Path $localDir 'finished-at'))) { TestFail 'finished-at field missing (unified naming)' }
    if (Test-Path (Join-Path $localDir 'exit_code')) { TestFail 'legacy exit_code field should not exist' }
    if (Test-Path (Join-Path $localDir 'prompt.md')) { TestFail 'legacy prompt.md field should not exist' }

    # Runtime harness selection disables inherited profile.
    $r = Invoke-Hekate 'config' 'use' 'pi' '--model' 'fake/model' '--effort' 'low'
    AssertContains $r.Out 'default_harness: pi' 'config use'
    AssertContains $r.Out 'default_profile: none' 'config use'

    # Foreground argv-safety: a semicolon-laden single task string survives
    # as one argv element, and is never handed to a shell.
    $r = Invoke-Hekate 'run' '--task' 'implement a long task; do not split me' '--foreground'
    if ($r.Code -ne 0) { TestFail "foreground run failed: $($r.Err)" }
    $fgDir = Join-Path $Project ".workflow\runs\$($r.Out.Trim())"
    $fgOut = Get-Content -LiteralPath (Join-Path $fgDir 'stdout.log') -Raw
    AssertContains $fgOut '<fake/model>' 'stdout.log'
    AssertContains $fgOut '<low>' 'stdout.log'
    AssertContains $fgOut '<implement a long task; do not split me>' 'stdout.log'
    if ((Get-Content -LiteralPath (Join-Path $fgDir 'status') -Raw).Trim() -ne 'completed') { TestFail 'foreground job did not complete' }

    # --- background lifecycle + item 2: wait returns the real exit code ----
    $r = Invoke-Hekate 'run' '--harness' 'pi' '--task' 'background task'
    if ($r.Code -ne 0) { TestFail "background run submission failed: $($r.Err)" }
    $job = $r.Out.Trim()
    $waitResult = Invoke-Hekate 'wait' $job
    if ($waitResult.Code -ne 0) { TestFail "wait did not return the harness's real (zero) exit code: $($waitResult.Code)" }
    $statusOut = (Invoke-Hekate 'status' $job).Out
    AssertContains $statusOut 'status: completed' 'status'
    $resultOut = (Invoke-Hekate 'result' $job).Out
    AssertContains $resultOut '<background task>' 'result'

    # stdin delivery.
    Invoke-Hekate 'config' 'use' 'claude' '--model' 'sonnet' '--effort' 'high' | Out-Null
    $r = Invoke-Hekate 'run' '--task' 'stdin task body' '--foreground'
    if ($r.Code -ne 0) { TestFail "claude stdin run failed: $($r.Err)" }
    $claudeDir = Join-Path $Project ".workflow\runs\$($r.Out.Trim())"
    $claudeOut = Get-Content -LiteralPath (Join-Path $claudeDir 'stdout.log') -Raw
    AssertContains $claudeOut '<sonnet>' 'claude stdout'
    AssertContains $claudeOut '<high>' 'claude stdout'
    AssertContains $claudeOut 'prompt:' 'claude stdout'
    AssertContains $claudeOut 'stdin task body' 'claude stdout'

    # file delivery (Aider).
    $r = Invoke-Hekate 'run' '--harness' 'aider' '--task' 'task from file' '--foreground'
    if ($r.Code -ne 0) { TestFail "aider run failed: $($r.Err)" }
    $aiderDir = Join-Path $Project ".workflow\runs\$($r.Out.Trim())"
    AssertContains (Get-Content -LiteralPath (Join-Path $aiderDir 'stdout.log') -Raw) 'file-prompt:task from file' 'aider stdout'

    # doctor: missing optional CLI is reported, not fatal by default.
    $doctor = (Invoke-Hekate 'doctor').Out
    AssertContains $doctor 'missing  enabled  opencode' 'doctor'
    $r = Invoke-Hekate 'doctor' 'opencode'
    if ($r.Code -eq 0) { TestFail 'targeted missing doctor returned success' }
    $r = Invoke-Hekate 'doctor' '--strict'
    if ($r.Code -eq 0) { TestFail 'strict doctor returned success with missing harnesses' }
    $r = Invoke-Hekate 'doctor' 'pi'
    if ($r.Code -ne 0) { TestFail 'targeted available doctor failed' }

    # Reject unsafe input.
    $r = Invoke-Hekate 'config' 'use' 'pi' '--model' 'x;touch-pwned'
    if ($r.Code -eq 0) { TestFail 'unsafe model accepted' }
    $r = Invoke-Hekate 'run' '--harness' 'pi' '--cwd' $Tmp '--task' 'escape'
    if ($r.Code -eq 0) { TestFail 'outside cwd accepted' }
    if (Test-Path (Join-Path $Project 'touch-pwned')) { TestFail 'shell injection occurred' }

    # --- item 5: worker identity / stop safety ------------------------------
    $r = Invoke-Hekate 'run' '--harness' 'pi' '--task' 'SLOW'
    if ($r.Code -ne 0) { TestFail "slow job submission failed: $($r.Err)" }
    $slowJob = $r.Out.Trim()
    $slowDir = Join-Path $Project ".workflow\runs\$slowJob"
    $waited = 0
    while ((Get-Content -LiteralPath (Join-Path $slowDir 'status') -Raw).Trim() -ne 'running' -and $waited -lt 50) {
        Start-Sleep -Milliseconds 100; $waited++
    }
    if (-not (Test-Path (Join-Path $slowDir 'worker-token'))) { TestFail 'worker-token was not written at worker start' }
    $r = Invoke-Hekate 'stop' $slowJob
    if ($r.Code -ne 0) { TestFail "stop failed on an active, verified worker: $($r.Err)" }
    if ((Get-Content -LiteralPath (Join-Path $slowDir 'status') -Raw).Trim() -ne 'stopped') { TestFail 'stop did not persist state' }
    $r = Invoke-Hekate 'stop' $slowJob
    if ($r.Code -eq 0) { TestFail 'stop accepted twice on an already-stopped job' }

    # A worker-token whose recorded start-time cannot match the current
    # process (bogus/foreign token) must NOT be treated as verified, and
    # `stop` must refuse to signal.
    $spoof = Join-Path $Project '.workflow\runs\manual-spoof'
    New-Item -ItemType Directory -Force -Path $spoof | Out-Null
    'running' | Set-Content -LiteralPath (Join-Path $spoof 'status') -Encoding UTF8
    "$PID" | Set-Content -LiteralPath (Join-Path $spoof 'worker-pid') -Encoding UTF8
    "$PID`:1970-01-01T00:00:00.0000000Z" | Set-Content -LiteralPath (Join-Path $spoof 'worker-token') -Encoding UTF8
    'pi' | Set-Content -LiteralPath (Join-Path $spoof 'harness') -Encoding UTF8
    'fake/model' | Set-Content -LiteralPath (Join-Path $spoof 'model') -Encoding UTF8
    'low' | Set-Content -LiteralPath (Join-Path $spoof 'effort') -Encoding UTF8
    $Project | Set-Content -LiteralPath (Join-Path $spoof 'cwd') -Encoding UTF8
    $r = Invoke-Hekate 'stop' 'manual-spoof'
    if ($r.Code -eq 0) { TestFail 'stop signaled a PID whose worker-token start-time did not match (spoofable identity)' }

    # Orphan detection: an unrelated/impossible PID is never mistaken for
    # the worker, and `wait` returns instead of hanging.
    $orphan = Join-Path $Project '.workflow\runs\manual-orphan'
    New-Item -ItemType Directory -Force -Path $orphan | Out-Null
    'running' | Set-Content -LiteralPath (Join-Path $orphan 'status') -Encoding UTF8
    '999999' | Set-Content -LiteralPath (Join-Path $orphan 'worker-pid') -Encoding UTF8
    'pi' | Set-Content -LiteralPath (Join-Path $orphan 'harness') -Encoding UTF8
    'fake/model' | Set-Content -LiteralPath (Join-Path $orphan 'model') -Encoding UTF8
    'low' | Set-Content -LiteralPath (Join-Path $orphan 'effort') -Encoding UTF8
    $Project | Set-Content -LiteralPath (Join-Path $orphan 'cwd') -Encoding UTF8
    $statusOut = (Invoke-Hekate 'status' 'manual-orphan').Out
    AssertContains $statusOut 'status: orphaned' 'orphan status'
    if ((Get-Content -LiteralPath (Join-Path $orphan 'status') -Raw).Trim() -ne 'orphaned') { TestFail 'orphan status not persisted' }
    $r = Invoke-Hekate 'wait' 'manual-orphan'
    if ($r.Code -eq 0) { TestFail 'orphan wait returned success' }

    Write-Host 'ok: hekate-agent.ps1 integration tests passed'
    Pop-Location
    Cleanup
    exit 0
} catch {
    try { Pop-Location -ErrorAction SilentlyContinue } catch {}
    Write-Error $_.Exception.Message
    Cleanup
    exit 1
}
