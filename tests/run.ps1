# PowerShell entry point mirroring tests/run.sh: syntax-checks then runs the
# PowerShell integration suite for hekate-agent.ps1.
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Cli = Join-Path $RepoRoot 'templates\.workflow\bin\hekate-agent.ps1'
$TestScript = Join-Path $RepoRoot 'tests\test-hekate-agent.ps1'

foreach ($file in @($Cli, $TestScript)) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        foreach ($e in $errors) { Write-Error $e.ToString() }
        exit 1
    }
}

& $TestScript
exit $LASTEXITCODE
