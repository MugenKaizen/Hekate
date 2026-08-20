Set-StrictMode -Version 2.0

if (-not (Get-Variable -Name RUNNER_ROOT -Scope Script -ErrorAction SilentlyContinue)) { $script:RUNNER_ROOT = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
if (-not (Get-Command Copy-AawFile -ErrorAction SilentlyContinue)) { . (Join-Path $script:RUNNER_ROOT 'lib/update-common.ps1') }

$needsPortableSkills = (Test-AawStateHasAdapter 'cursor' $script:STATE_FILE) -or (Test-AawStateHasAdapter 'codex' $script:STATE_FILE)
if (-not $needsPortableSkills) { return }

$keepClaude = (Test-AawStateHasAdapter 'claude' $script:STATE_FILE) -or
    (Test-Path -LiteralPath (Join-AawPath $script:TARGET 'CLAUDE.md')) -or
    (Test-Path -LiteralPath (Join-AawPath $script:TARGET '.claude/commands/init-workflow.md'))

$skillsRoot = Join-AawPath $script:RUNNER_ROOT 'templates/skills'
foreach ($skillTemplate in Get-ChildItem -LiteralPath $skillsRoot -Filter 'SKILL.md' -File -Recurse) {
    $skillName = $skillTemplate.Directory.Name
    $legacyRel = ".claude/skills/$skillName/SKILL.md"
    $portableRel = ".agents/skills/$skillName/SKILL.md"
    $legacyFile = Join-AawPath $script:TARGET $legacyRel
    $portableFile = Join-AawPath $script:TARGET $portableRel

    if (-not (Test-Path -LiteralPath $legacyFile)) { continue }

    if (-not (Test-Path -LiteralPath $portableFile)) {
        Copy-AawFile $legacyFile $portableFile
        Write-AawLog "relocated skill: $legacyFile -> $portableFile"
    } elseif (-not (Test-AawSameFile $legacyFile $portableFile)) {
        Write-AawWarn "portable skill differs; preserving legacy copy: $legacyFile"
        continue
    }

    if ($keepClaude) { continue }
    Backup-AawFile $legacyRel
    if ($script:DRY_RUN) {
        Write-AawLog "would remove relocated legacy skill: $legacyFile"
        continue
    }

    Remove-Item -LiteralPath $legacyFile -Force
    foreach ($directory in @(
        (Split-Path -Parent $legacyFile),
        (Join-AawPath $script:TARGET '.claude/skills'),
        (Join-AawPath $script:TARGET '.claude')
    )) {
        if ((Test-Path -LiteralPath $directory) -and @((Get-ChildItem -LiteralPath $directory -Force)).Count -eq 0) {
            Remove-Item -LiteralPath $directory -Force
        }
    }
    Write-AawLog "removed relocated legacy skill: $legacyFile"
}
