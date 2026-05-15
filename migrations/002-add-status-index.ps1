Set-StrictMode -Version 2.0

if (-not (Get-Variable -Name RUNNER_ROOT -Scope Script -ErrorAction SilentlyContinue)) { $script:RUNNER_ROOT = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not (Get-Command Replace-AawFileIfChanged -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:RUNNER_ROOT 'lib/update-common.ps1')
}

$statusFile = Join-AawPath $script:TARGET '.workflow/status.yml'
if (Test-Path -LiteralPath $statusFile) { return }

function Test-AawYamlScalarNonEmpty {
    param([string]$File, [string]$Key)
    if (-not (Test-Path -LiteralPath $File)) { return $false }
    foreach ($line in (Get-Content -LiteralPath $File)) {
        if ($line -match "^\s*$([regex]::Escape($Key)):\s*(.*)$") {
            $value = $matches[1] -replace '\s+#.*$', ''
            $value = $value.Trim().Trim('"')
            if ($value -and $value -ne 'null' -and $value -ne '[]' -and $value -ne '0') { return $true }
        }
    }
    return $false
}

function Test-AawYamlListNonEmpty {
    param([string]$File, [string]$Key)
    if (-not (Test-Path -LiteralPath $File)) { return $false }
    $inList = $false
    foreach ($line in (Get-Content -LiteralPath $File)) {
        if ($line -match "^$([regex]::Escape($Key)):\s*\[\]\s*($|#)") { return $false }
        if ($line -match "^$([regex]::Escape($Key)):\s*$") { $inList = $true; continue }
        if ($inList -and $line -match '^\s*-\s+') { return $true }
        if ($inList -and $line -match '^\S') { $inList = $false }
    }
    return $false
}

function Read-AawYamlValue {
    param([string]$File, [string]$Key)
    if (-not (Test-Path -LiteralPath $File)) { return '' }
    foreach ($line in (Get-Content -LiteralPath $File)) {
        if ($line -match "^\s*$([regex]::Escape($Key)):\s*(.*)$") {
            $value = $matches[1] -replace '\s+#.*$', ''
            return $value.Trim().Trim('"')
        }
    }
    return ''
}

function Read-AawBlockBool {
    param([string]$File, [string]$Block, [string]$Key, [string]$Default)
    if (-not (Test-Path -LiteralPath $File)) { return $Default }
    $inBlock = $false
    foreach ($line in (Get-Content -LiteralPath $File)) {
        if ($line -match "^\s*$([regex]::Escape($Block)):\s*$") { $inBlock = $true; continue }
        if ($inBlock -and $line -match "^\s*$([regex]::Escape($Key)):\s*(.*)$") {
            $value = ($matches[1] -replace '\s+#.*$', '').Trim()
            if ($value -eq 'true' -or $value -eq 'false') { return $value }
            return $Default
        }
        if ($inBlock -and $line -match '^\s*[A-Za-z0-9_]+:') { return $Default }
    }
    return $Default
}

$workflowFile = Join-AawPath $script:TARGET '.workflow/workflow.yml'
$presetsFile = Join-AawPath $script:TARGET '.workflow/presets.yml'
$stackFile = Join-AawPath $script:TARGET '.workflow/stack.yml'
$architectureFile = Join-AawPath $script:TARGET '.workflow/architecture.yml'
$conventionsFile = Join-AawPath $script:TARGET '.workflow/conventions.yml'

$activePreset = Read-AawYamlValue $presetsFile 'active_preset'
if (-not $activePreset) { $activePreset = Read-AawYamlValue $workflowFile 'preset' }
if (-not $activePreset) { $activePreset = 'null' }

$requiredFilesPresent = $true
foreach ($requiredFile in @($stackFile, $architectureFile, $conventionsFile, $workflowFile, $presetsFile)) {
    if (-not (Test-Path -LiteralPath $requiredFile)) { $requiredFilesPresent = $false }
}

$requiredFieldsFilled = $true
if (-not (Test-AawYamlScalarNonEmpty $stackFile 'project_name')) { $requiredFieldsFilled = $false }
if (-not (Test-AawYamlScalarNonEmpty $stackFile 'project_kind')) { $requiredFieldsFilled = $false }
if (-not (Test-AawYamlListNonEmpty $stackFile 'languages')) { $requiredFieldsFilled = $false }
if (-not (Test-AawYamlScalarNonEmpty $architectureFile 'style')) { $requiredFieldsFilled = $false }
if (-not (Test-AawYamlListNonEmpty $architectureFile 'layers')) { $requiredFieldsFilled = $false }
if (-not (Test-AawYamlScalarNonEmpty $conventionsFile 'formatter')) { $requiredFieldsFilled = $false }
if (-not (Test-AawYamlScalarNonEmpty $conventionsFile 'files')) { $requiredFieldsFilled = $false }
if (-not (Test-AawYamlScalarNonEmpty $conventionsFile 'style')) { $requiredFieldsFilled = $false }

$initialized = 'false'
if ($requiredFilesPresent -and $requiredFieldsFilled -and $activePreset -ne 'null') { $initialized = 'true' }

switch ($activePreset) {
    'fast' {
        $requireAnalysis = 'true'; $requirePlan = 'true'; $requireOptions = 'false'; $lightTdd = 'false'; $granularCommits = 'false'; $scopeControl = 'true'; $threeBranchModel = 'false'
    }
    'medium' {
        $requireAnalysis = 'true'; $requirePlan = 'true'; $requireOptions = 'true'; $lightTdd = 'false'; $granularCommits = 'true'; $scopeControl = 'true'; $threeBranchModel = 'true'
    }
    'full' {
        $requireAnalysis = 'true'; $requirePlan = 'true'; $requireOptions = 'true'; $lightTdd = 'true'; $granularCommits = 'true'; $scopeControl = 'true'; $threeBranchModel = 'true'
    }
    default {
        $requireAnalysis = Read-AawYamlValue $workflowFile 'require_analysis'; if ($requireAnalysis -ne 'true' -and $requireAnalysis -ne 'false') { $requireAnalysis = 'true' }
        $requirePlan = Read-AawBlockBool $workflowFile 'plan' 'required' 'true'
        $requireOptions = Read-AawBlockBool $workflowFile 'require_options' 'enabled' 'true'
        $lightTdd = Read-AawBlockBool $workflowFile 'light_tdd' 'enabled' 'true'
        $granularCommits = Read-AawBlockBool $workflowFile 'granular_commits' 'enabled' 'true'
        $scopeControl = Read-AawBlockBool $workflowFile 'scope_control' 'no_unrelated_refactors' 'true'
        $threeBranchModel = Read-AawBlockBool $workflowFile 'three_branch_model' 'enabled' 'false'
    }
}

$requiredFilesPresentText = $requiredFilesPresent.ToString().ToLowerInvariant()
$requiredFieldsFilledText = $requiredFieldsFilled.ToString().ToLowerInvariant()
$statusTmp = Join-Path $script:TMP_ROOT 'status.yml.tmp'
$lines = @(
    '# Fast pre-flight index for AI agents.',
    '# Read this file at session start instead of loading every .workflow/*.yml.',
    '# It is rewritten after /init-workflow or after deliberate workflow config edits.',
    '',
    'schema_version: 1',
    '',
    "initialized: $initialized",
    "active_preset: $activePreset",
    '',
    'checks:',
    "  required_files_present: $requiredFilesPresentText",
    "  required_fields_filled: $requiredFieldsFilledText",
    '',
    'features:',
    "  require_analysis: $requireAnalysis",
    "  require_plan: $requirePlan",
    "  require_options: $requireOptions",
    "  light_tdd: $lightTdd",
    "  granular_commits: $granularCommits",
    "  scope_control: $scopeControl",
    "  three_branch_model: $threeBranchModel",
    '',
    'lazy_load:',
    '  stack: .workflow/stack.yml',
    '  architecture: .workflow/architecture.yml',
    '  conventions: .workflow/conventions.yml',
    '  workflow_rules: .workflow/workflow.yml',
    '  presets: .workflow/presets.yml',
    '  bootstrap: .workflow/bootstrap.md',
    '',
    'required_files:',
    '  - .workflow/stack.yml',
    '  - .workflow/architecture.yml',
    '  - .workflow/conventions.yml',
    '  - .workflow/workflow.yml',
    '  - .workflow/presets.yml',
    '',
    'required_non_empty_fields:',
    '  stack.yml: [meta.project_name, meta.project_kind, languages]',
    '  architecture.yml: [style, layers]',
    '  conventions.yml: [code_style.formatter, naming.files, commits.style]',
    '',
    'notes:',
    '  - "If initialized is not true, active_preset is null, or any check is false, read .workflow/bootstrap.md."',
    '  - "Do not read stack/architecture/conventions/workflow/presets at startup unless the fast check fails."'
)
Write-AawText $statusTmp $lines
Replace-AawFileIfChanged '.workflow/status.yml' $statusTmp
