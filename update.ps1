[CmdletBinding()]
param(
    [string]$Target = (Get-Location).Path,
    [string]$Source = '',
    [string]$Repo = $(if ($env:AAW_REPO) { $env:AAW_REPO } else { 'MugenKaizen/Hekate' }),
    [string]$Ref = 'main',
    [string]$Commit = '',
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

Set-StrictMode -Version 2.0

function Write-AawLog { param([string]$Message) Write-Host "[aaw] $Message" }
function Throw-Aaw { param([string]$Message) throw "[aaw] ERROR: $Message" }

function Show-AawHelp {
@'
ai_agent_workflow update bootstrap

Usage:
  powershell -ExecutionPolicy Bypass -File update.ps1 -Target . -Ref main
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/MugenKaizen/Hekate/main/update.ps1))) -Target .

Flags:
  -Target <path>      Root of the target project. Defaults to the current directory.
  -Source <path>     Local copy of the repository (for updater development).
  -Repo <owner/name> GitHub repository. Defaults to the built-in one.
  -Ref <git-ref>     Branch/tag to update to. Defaults to main.
  -Commit <sha>      Exact commit to update to.
  -Force             Overwrite locally edited managed files after confirmation.
  -DryRun            Show what would be done without making changes.
'@ | Write-Host
}

foreach ($arg in $Rest) {
    if ($arg -like '--target=*') { $Target = $arg.Substring(9); continue }
    if ($arg -like '--source=*') { $Source = $arg.Substring(9); continue }
    if ($arg -like '--repo=*') { $Repo = $arg.Substring(7); continue }
    if ($arg -like '--ref=*') { $Ref = $arg.Substring(6); continue }
    if ($arg -like '--commit=*') { $Commit = $arg.Substring(9); continue }
    if ($arg -eq '--force') { $Force = $true; continue }
    if ($arg -eq '--dry-run') { $DryRun = $true; continue }
    if ($arg -eq '-h' -or $arg -eq '--help') { $Help = $true; continue }
    Throw-Aaw "unknown arg: $arg"
}

if ($Help) { Show-AawHelp; exit 0 }

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('aaw-update-' + [guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
    $requestedRev = $Ref
    if ($Commit) { $requestedRev = $Commit }

    if ($Source) {
        $snapshotRoot = (Resolve-Path -LiteralPath $Source).Path
        if (-not (Test-Path -LiteralPath (Join-Path $snapshotRoot 'update-runner.ps1'))) { Throw-Aaw '-Source does not look like ai_agent_workflow: missing update-runner.ps1' }
        Write-AawLog "using local source: $snapshotRoot"
    } else {
        $snapshotDir = Join-Path $tmpRoot 'snapshot'
        $snapshotZip = Join-Path $tmpRoot 'snapshot.zip'
        $snapshotUrl = "https://codeload.github.com/$Repo/zip/$requestedRev"
        New-Item -ItemType Directory -Force -Path $snapshotDir | Out-Null
        Write-AawLog "downloading $snapshotUrl"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $snapshotUrl -OutFile $snapshotZip -UseBasicParsing
        Expand-Archive -LiteralPath $snapshotZip -DestinationPath $snapshotDir -Force
        $dirs = Get-ChildItem -LiteralPath $snapshotDir -Directory
        if ($dirs.Count -lt 1) { Throw-Aaw "could not locate extracted repo in $snapshotDir" }
        $snapshotRoot = $dirs[0].FullName
    }

    $runner = Join-Path $snapshotRoot 'update-runner.ps1'
    if (-not (Test-Path -LiteralPath $runner)) { Throw-Aaw 'update runner missing in downloaded snapshot' }

    $runnerArgs = @('-Target', $Target, '-Repo', $Repo, '-Ref', $Ref)
    if ($Commit) { $runnerArgs += @('-Commit', $Commit) }
    if ($DryRun) { $runnerArgs += '-DryRun' }
    if ($Force) { $runnerArgs += '-Force' }

    Write-AawLog 'starting update runner from snapshot'
    $engineName = 'powershell.exe'
    if ($PSVersionTable.PSVersion.Major -ge 6) { $engineName = 'pwsh' }
    $engineCommand = Get-Command $engineName -ErrorAction SilentlyContinue
    if ($engineCommand) { $engine = $engineCommand.Source } else { $engine = $engineName }

    & $engine -NoProfile -ExecutionPolicy Bypass -File $runner @runnerArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    if ($tmpRoot -and (Test-Path -LiteralPath $tmpRoot)) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
}
