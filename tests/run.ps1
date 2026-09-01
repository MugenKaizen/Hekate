# PowerShell entry point mirroring tests/run.sh: syntax-checks then runs the
# PowerShell test suites.
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$TestScripts = @(
    (Join-Path $RepoRoot 'tests\test-update-common.ps1'),
    (Join-Path $RepoRoot 'tests\test-install-update.ps1'),
    (Join-Path $RepoRoot 'tests\test-hekate-agent.ps1')
)
$ProductionScripts = @(
    (Join-Path $RepoRoot 'install.ps1'),
    (Join-Path $RepoRoot 'update.ps1'),
    (Join-Path $RepoRoot 'update-runner.ps1'),
    (Join-Path $RepoRoot 'lib\update-common.ps1'),
    (Join-Path $RepoRoot 'templates\.workflow\bin\hekate-agent.ps1')
) + @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'migrations') -Filter '*.ps1' | ForEach-Object { $_.FullName })

foreach ($file in $ProductionScripts + $TestScripts) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) { Write-Error $e.ToString() }
        exit 1
    }
}

foreach ($testScript in $TestScripts) {
    & $testScript
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
exit 0
