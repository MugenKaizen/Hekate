Set-StrictMode -Version 2.0

if (-not (Get-Variable -Name RUNNER_ROOT -Scope Script -ErrorAction SilentlyContinue)) { $script:RUNNER_ROOT = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not (Get-Command Replace-AawFileIfChanged -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:RUNNER_ROOT 'lib/update-common.ps1')
}

function Add-AawWorkflowGitBlock {
    param([string]$WorkflowFile)
    $workflowTmp = Join-Path $script:TMP_ROOT 'workflow.yml.tmp'
    $lines = @(Get-Content -LiteralPath $WorkflowFile)
    foreach ($line in $lines) {
        if ($line -match '^\s*three_branch_model:\s*$') { return }
    }

    $block = @(
        '  three_branch_model:               # feature_id: three_branch_model - see .workflow/presets.yml',
        '    enabled: false',
        '    branches:',
        '      main: main                    # production / release',
        '      stage: stage                  # pre-production / QA',
        '      dev: dev                      # default integration branch',
        '    default_working_branch: dev     # branch from which feature branches are cut',
        '    create_during_bootstrap: true   # if enabled and branches missing, bootstrap creates them locally',
        '    push_during_bootstrap: false    # never push without asking the user'
    )

    $output = New-Object System.Collections.Generic.List[string]
    $seenGit = $false
    $inserted = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $output.Add($line)
        if ($line -match '^git:\s*$') {
            $seenGit = $true
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j] -match '^\s') { $j++ }
            if ($j -eq $i + 1) {
                foreach ($b in $block) { $output.Add($b) }
                $inserted = $true
            }
            continue
        }
        if ($seenGit -and -not $inserted -and $i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^\S') {
            foreach ($b in $block) { $output.Add($b) }
            $inserted = $true
        }
    }

    if (-not $seenGit) {
        $output.Add('')
        $output.Add('git:')
        foreach ($b in $block) { $output.Add($b) }
    } elseif (-not $inserted) {
        foreach ($b in $block) { $output.Add($b) }
    }

    Write-AawText $workflowTmp $output.ToArray()
    Replace-AawFileIfChanged '.workflow/workflow.yml' $workflowTmp
}

function Add-AawConventionBranchFields {
    param([string]$ConventionsFile)
    $conventionsTmp = Join-Path $script:TMP_ROOT 'conventions.yml.tmp'
    $lines = @(Get-Content -LiteralPath $ConventionsFile)
    $hasBranches = $false
    $hasModel = $false
    $hasFlow = $false
    foreach ($line in $lines) {
        if ($line -match '^branches:\s*$') { $hasBranches = $true }
        if ($line -match '^\s*model:\s*') { $hasModel = $true }
        if ($line -match '^\s*flow:\s*') { $hasFlow = $true }
    }

    $output = New-Object System.Collections.Generic.List[string]
    $inBranches = $false
    foreach ($line in $lines) {
        if ($inBranches -and $line -match '^\S') {
            if (-not $hasModel) { $output.Add('  model: ""                # "" | three-branch') }
            if (-not $hasFlow) { $output.Add('  flow: ""                 # e.g. "feature -> dev -> stage -> main"') }
            $inBranches = $false
        }
        $output.Add($line)
        if ($line -match '^branches:\s*$') { $inBranches = $true }
    }

    if (-not $hasBranches) {
        $output.Add('')
        $output.Add('branches:')
        $output.Add('  default: ""              # main | master | trunk (single-branch repos)')
        $output.Add('  style: ""                # feature/<slug> | <ticket>-<slug>')
        $output.Add('  protected: []')
        $output.Add('  model: ""                # "" | three-branch')
        $output.Add('  flow: ""                 # e.g. "feature -> dev -> stage -> main"')
    } elseif ($inBranches) {
        if (-not $hasModel) { $output.Add('  model: ""                # "" | three-branch') }
        if (-not $hasFlow) { $output.Add('  flow: ""                 # e.g. "feature -> dev -> stage -> main"') }
    }

    Write-AawText $conventionsTmp $output.ToArray()
    Replace-AawFileIfChanged '.workflow/conventions.yml' $conventionsTmp
}

function Add-AawPresetFeatureDefaults {
    param([string]$PresetsFile)
    $presetsTmp = Join-Path $script:TMP_ROOT 'presets.yml.tmp'
    $lines = @(Get-Content -LiteralPath $PresetsFile)
    $text = [string]::Join("`n", $lines)

    $output = New-Object System.Collections.Generic.List[string]
    $currentPreset = ''
    $inFeatures = $false
    $featureSeen = @{ fast = $false; medium = $false; full = $false }
    $defaults = @{ fast = 'false'; medium = 'true'; full = 'true' }

    foreach ($line in $lines) {
        if ($inFeatures -and $line -match '^    [^\s]') {
            if ($currentPreset -and -not $featureSeen[$currentPreset]) { $output.Add('      three_branch_model: ' + $defaults[$currentPreset]) }
            $inFeatures = $false
        }
        if ($line -match '^  (fast|medium|full):\s*$') { $currentPreset = $matches[1] }
        if ($currentPreset -and $line -match '^    features:\s*$') { $inFeatures = $true }
        if ($inFeatures -and $line -match '^      three_branch_model:') { $featureSeen[$currentPreset] = $true }
        $output.Add($line)
    }
    if ($inFeatures -and $currentPreset -and -not $featureSeen[$currentPreset]) { $output.Add('      three_branch_model: ' + $defaults[$currentPreset]) }

    if ($text -notmatch '(?m)^\s*- id: three_branch_model\s*$') {
        $output.Add('')
        $output.Add('  - id: three_branch_model')
        $output.Add('    description: "Maintain main / stage / dev branches in the repo."')
        $output.Add('    controls:')
        $output.Add('      - "workflow.yml -> git.three_branch_model.enabled"')
        $output.Add('      - "conventions.yml -> branches.model"')
        $output.Add('      - "conventions.yml -> branches.protected"')
        $output.Add('    question: "Maintain a main / stage / dev branch layout in this repo?"')
        $output.Add('    defaults: { fast: false, medium: true, full: true }')
    }

    Write-AawText $presetsTmp $output.ToArray()
    Replace-AawFileIfChanged '.workflow/presets.yml' $presetsTmp
}

$workflowFile = Join-AawPath $script:TARGET '.workflow/workflow.yml'
$conventionsFile = Join-AawPath $script:TARGET '.workflow/conventions.yml'
$presetsFile = Join-AawPath $script:TARGET '.workflow/presets.yml'

if (Test-Path -LiteralPath $workflowFile) { Add-AawWorkflowGitBlock $workflowFile }
if (Test-Path -LiteralPath $conventionsFile) { Add-AawConventionBranchFields $conventionsFile }
if (Test-Path -LiteralPath $presetsFile) { Add-AawPresetFeatureDefaults $presetsFile }
