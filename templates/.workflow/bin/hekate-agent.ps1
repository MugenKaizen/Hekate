# Hekate cross-harness job runner (PowerShell 5.1-compatible implementation
# of ../bin/hekate-agent).
#
# Canonical job-directory layout (must match hekate-agent (sh) exactly; a job
# created by one implementation must be fully readable by the other):
#   status        - queued | running | completed | failed | stopped | orphaned
#   profile       - resolved profile name, or "none"
#   harness       - resolved harness name
#   model         - resolved model token
#   effort        - resolved effort token
#   cwd           - absolute working directory for the job
#   task.md       - the task/prompt text delivered to the harness
#   command.txt   - the resolved command line, for debugging
#   stdout.log    - harness stdout (streamed incrementally as it arrives)
#   stderr.log    - harness stderr (streamed incrementally as it arrives)
#   worker-pid    - PID of the detached worker process (this script, __worker)
#   child-pid     - PID of the harness child process launched by the worker
#   worker-token  - durable identity marker ("<pid>:<start-time>") used to
#                   verify worker-pid ownership before signaling it
#   created-at    - UTC timestamp the job directory was created
#   started-at    - UTC timestamp the worker began running the harness
#   finished-at   - UTC timestamp the worker observed the harness exit
#   exit-code     - the harness process's exit code
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Rest = @($Rest)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..\..')).TrimEnd('\','/')
$Config = Join-Path $ProjectRoot '.workflow\orchestration.yml'
$LocalConfig = Join-Path $ProjectRoot '.workflow\orchestration.local.yml'
$StatusConfig = Join-Path $ProjectRoot '.workflow\status.yml'
if (-not (Test-Path -LiteralPath $Config)) { throw "hekate-agent: missing $Config" }

function Fail([string]$Message) { throw "hekate-agent: $Message" }
function Scalar([string]$Value) { if ($null -eq $Value) { return '' }; $v=$Value.Trim(); if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) { return $v.Substring(1,$v.Length-2) }; return $v }
function TopValueFrom([string]$File,[string]$Key) { if (-not (Test-Path -LiteralPath $File)) { return '' }; foreach($line in Get-Content -LiteralPath $File) { if($line -match ('^'+[regex]::Escape($Key)+':\s*(.*?)\s*(?:#.*)?$')) { return Scalar $matches[1] } }; return '' }
function TopValue([string]$Key) { $v=TopValueFrom $LocalConfig $Key; if(-not $v){$v=TopValueFrom $Config $Key}; return $v }
function DirectSectionRaw([string]$File,[string]$Section,[string]$Key) {
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $inside = $false; $keyIndent = -1
    foreach ($line in Get-Content -LiteralPath $File) {
        if ($line -match ('^' + [regex]::Escape($Section) + ':\s*$')) { $inside = $true; continue }
        if (-not $inside -or $line -match '^\s*(?:#.*)?$') { continue }
        if ($line -match '^\S') { break }
        if ($line -notmatch '^(\s+)(.*)$') { continue }
        $indent = $matches[1].Length; $content = $matches[2]
        if ($keyIndent -lt 0) { $keyIndent = $indent }
        if ($indent -eq $keyIndent -and $content -match ('^' + [regex]::Escape($Key) + ':\s*(.*?)\s*(?:#.*)?$')) {
            return 'F:' + (Scalar $matches[1])
        }
    }
    return $null
}
function DirectNestedRaw([string]$File,[string]$Section,[string]$Item,[string]$Key) {
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $inSection = $false; $inItem = $false; $itemIndent = -1; $keyIndent = -1
    foreach ($line in Get-Content -LiteralPath $File) {
        if ($line -match ('^' + [regex]::Escape($Section) + ':\s*$')) { $inSection = $true; continue }
        if (-not $inSection -or $line -match '^\s*(?:#.*)?$') { continue }
        if ($line -match '^\S') { break }
        if ($line -notmatch '^(\s+)(.*)$') { continue }
        $indent = $matches[1].Length; $content = $matches[2]
        if (-not $inItem) {
            if ($itemIndent -lt 0) { $itemIndent = $indent }
            if ($indent -eq $itemIndent -and $content -eq ($Item + ':')) { $inItem = $true }
            continue
        }
        if ($indent -le $itemIndent) { break }
        if ($keyIndent -lt 0) { $keyIndent = $indent }
        if ($indent -eq $keyIndent -and $content -match ('^' + [regex]::Escape($Key) + ':\s*(.*?)\s*(?:#.*)?$')) {
            return 'F:' + (Scalar $matches[1])
        }
    }
    return $null
}
function SectionNames([string]$File,[string]$Section) { if(-not(Test-Path -LiteralPath $File)){return};$inside=$false;foreach($line in Get-Content -LiteralPath $File){if($line-match('^'+[regex]::Escape($Section)+':\s*$')){$inside=$true;continue};if($inside-and$line-match'^\S'){break};if($inside-and$line-match'^  ([A-Za-z0-9_.-]+):\s*$'){$matches[1]}} }
function HarnessNames { SectionNames $Config 'harnesses' }
function ProfileNames { @(@((SectionNames $Config 'profiles')) + @((SectionNames $LocalConfig 'profiles'))) | Where-Object { $_ -notin @('none','null') } | Select-Object -Unique }
function HarnessValueFrom([string]$File,[string]$Harness,[string]$Key) { return SectionValueFrom $File 'harnesses' $Harness $Key }
function SectionValueFrom([string]$File,[string]$Section,[string]$Item,[string]$Key) { if(-not(Test-Path -LiteralPath $File)){return ''};$sectionFound=$false;$inside=$false;foreach($line in Get-Content -LiteralPath $File){if($line-match('^'+[regex]::Escape($Section)+':\s*$')){$sectionFound=$true;continue};if($sectionFound-and$line-match'^\S'){break};if($sectionFound-and$line-match('^  '+[regex]::Escape($Item)+':\s*$')){$inside=$true;continue};if($inside-and$line-match'^  [A-Za-z0-9_.-]+:\s*$'){break};if($inside-and$line-match('^    '+[regex]::Escape($Key)+':\s*(.*?)\s*(?:#.*)?$')){return Scalar $matches[1]}};return '' }
function LocalDefault([string]$Harness,[string]$Key) { return SectionValueFrom $LocalConfig 'defaults' $Harness $Key }
function ProfileValue([string]$Profile,[string]$Key) { $v=SectionValueFrom $LocalConfig 'profiles' $Profile $Key;if(-not$v){$v=SectionValueFrom $Config 'profiles' $Profile $Key};return $v }
function DefaultProfile { $v=TopValue 'default_profile';if($v-in@('','null','none')){return ''};return $v }
function HarnessValue([string]$Harness,[string]$Key) { $v='';if($Key-eq'default_model'){$v=LocalDefault $Harness 'model'}elseif($Key-eq'default_effort'){$v=LocalDefault $Harness 'effort'};if(-not$v){$v=HarnessValueFrom $Config $Harness $Key};return $v }
function HarnessList([string]$Harness,[string]$Key) { $section=$false;$inside=$false;$list=$false;foreach($line in Get-Content -LiteralPath $Config){if($line-match'^harnesses:\s*$'){$section=$true;continue};if($section-and$line-match'^\S'){break};if($section-and$line-match('^  '+[regex]::Escape($Harness)+':\s*$')){$inside=$true;continue};if($inside-and$line-match'^  [A-Za-z0-9_.-]+:\s*$'){break};if($inside-and$line-match('^    '+[regex]::Escape($Key)+':\s*$')){$list=$true;continue};if($list-and$line-match'^      -\s*(.*)$'){Scalar $matches[1];continue};if($list-and$line-match'^    [A-Za-z0-9_-]+:'){break}} }
function HasHarness([string]$Name) { return @((HarnessNames)) -contains $Name }
function HasProfile([string]$Name) { return @((ProfileNames)) -contains $Name }
function ValidateId([string]$Value) { if($Value-notmatch'^[A-Za-z0-9][A-Za-z0-9_.-]*$'){Fail "invalid identifier: $Value"} }
function ValidateProfileId([string]$Value) { ValidateId $Value;if($Value-in@('none','null')){Fail "reserved profile name: $Value"} }
function ValidateValue([string]$Label,[string]$Value) { if($Value-notmatch'^[A-Za-z0-9._:/@+~-]+$'){Fail "invalid ${Label}: $Value"} }
function ResolveSafeCwd([string]$Value) {
    $full = [IO.Path]::GetFullPath($Value).TrimEnd('\','/')
    $allowExternal = (TopValue 'allow_external_cwd') -eq 'true'
    if (-not $allowExternal -and -not ($full -eq $ProjectRoot -or $full.StartsWith($ProjectRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) {
        Fail "cwd must stay inside project root: $ProjectRoot"
    }
    if (-not $allowExternal -and $full -ne $ProjectRoot) {
        $relative = $full.Substring($ProjectRoot.Length).TrimStart('\','/')
        $current = $ProjectRoot
        foreach ($part in ($relative -split '[\\/]+')) {
            if (-not $part) { continue }
            $current = Join-Path $current $part
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail "cwd crosses a symlink/junction and is not allowed: $current"
            }
        }
    }
    return $full
}
function QuoteProcessArg([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"'); $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { [void]$builder.Append(('\' * (2 * $slashes + 1))); [void]$builder.Append('"'); $slashes = 0; continue }
        if ($slashes) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($ch)
    }
    if ($slashes) { [void]$builder.Append(('\' * (2 * $slashes))) }
    [void]$builder.Append('"'); return $builder.ToString()
}
function JobsRoot {
    $d = TopValue 'jobs_dir'
    if (-not $d) { $d = '.workflow/runs' }
    if ([IO.Path]::IsPathRooted($d)) { return $d }
    return Join-Path $ProjectRoot $d
}
function AtomicText([string]$Path,[string]$Text) {
    $tmp = "$Path.tmp.$PID"
    [IO.File]::WriteAllText($tmp, $Text + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    Move-Item -Force -LiteralPath $tmp -Destination $Path
}
function ResolveJob([string]$Id) {
    ValidateId $Id
    $d = Join-Path (JobsRoot) $Id
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { Fail "unknown job: $Id" }
    return $d
}
function ProcessRecord([int]$Id) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        return Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction SilentlyContinue
    }
    $ps = Get-Command ps -ErrorAction SilentlyContinue
    if (-not $ps) { return $null }
    $parentText = (& $ps.Source -o ppid= -p $Id 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $parentText) { return $null }
    $commandLine = ((& $ps.Source -o command= -p $Id 2>$null) -join ' ').Trim()
    $parentId = 0
    if (-not [int]::TryParse((($parentText -join '').Trim()), [ref]$parentId)) { return $null }
    return [PSCustomObject]@{ ParentProcessId=$parentId; CommandLine=$commandLine }
}
function CurrentStartTimeToken([int]$Id) {
    try { return (Get-Process -Id $Id -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o') } catch { return '' }
}
# WorkerIdentityMatches verifies $Id is still the same process recorded as
# the worker for job $Dir, guarding against PID reuse. Primary check: the
# "worker-token" file (written once, at worker start, as "<pid>:<start-time>")
# is compared against the current process's actual start time for that pid —
# durable and independent of command-line contents. Fallback, used only when
# the token is unavailable or inconclusive: substring-match CommandLine, as
# before. If neither check can positively establish ownership, refuse.
function WorkerIdentityMatches([string]$Dir,[int]$Id) {
    if (-not $Id) { return $false }
    $tokenPath = Join-Path $Dir 'worker-token'
    if (Test-Path -LiteralPath $tokenPath) {
        $token = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
        $parts = $token -split ':', 2
        if ($parts.Count -eq 2 -and $parts[0]) {
            $tokenPid = 0
            if ([int]::TryParse($parts[0], [ref]$tokenPid)) {
                if ($tokenPid -ne $Id) { return $false }
                $tokenTime = $parts[1]
                if ($tokenTime) {
                    $currentTime = CurrentStartTimeToken $Id
                    if ($currentTime) { return $currentTime -eq $tokenTime }
                }
            }
        }
    }
    $record = ProcessRecord $Id
    if (-not $record -or -not $record.CommandLine) { return $false }
    return $record.CommandLine.Contains('hekate-agent.ps1') -and $record.CommandLine.Contains('__worker') -and $record.CommandLine.Contains($Dir)
}
function EffectiveStatus([string]$Dir) {
    $statusPath = Join-Path $Dir 'status'
    $workerPidPath = Join-Path $Dir 'worker-pid'
    $s = if (Test-Path $statusPath) { (Get-Content $statusPath -Raw).Trim() } else { 'unknown' }
    if ($s -in @('queued','running')) {
        $p = if (Test-Path $workerPidPath) { [int](Get-Content $workerPidPath -Raw) } else { 0 }
        if ($p -and -not (WorkerIdentityMatches $Dir $p)) {
            $s = 'orphaned'; AtomicText $statusPath $s
        }
    }
    return $s
}
function ReplaceTokens([string]$Text,[string]$Model,[string]$Effort,[string]$Prompt,[string]$Session,[string]$Cwd){return $Text.Replace('{model}',$Model).Replace('{effort}',$Effort).Replace('{prompt_file}',$Prompt).Replace('{session_id}',$Session).Replace('{cwd}',$Cwd)}
function BuildArgv([string]$Harness,[string]$Model,[string]$Effort,[string]$Prompt,[string]$Session,[string]$Cwd){$out=@();foreach($a in @(HarnessList $Harness 'args')){$out+=ReplaceTokens $a $Model $Effort $Prompt $Session $Cwd};return $out}

function InvokeWorker([string]$RunDir){
    $statusPath=Join-Path $RunDir 'status';$startedAtPath=Join-Path $RunDir 'started-at';$workerTokenPath=Join-Path $RunDir 'worker-token'
    $harnessPath=Join-Path $RunDir 'harness';$modelPath=Join-Path $RunDir 'model';$effortPath=Join-Path $RunDir 'effort';$cwdPath=Join-Path $RunDir 'cwd';$prompt=Join-Path $RunDir 'task.md'
    $commandPath=Join-Path $RunDir 'command.txt';$stdoutPath=Join-Path $RunDir 'stdout.log';$stderrPath=Join-Path $RunDir 'stderr.log';$childPidPath=Join-Path $RunDir 'child-pid'
    $exitCodePath=Join-Path $RunDir 'exit-code';$finishedAtPath=Join-Path $RunDir 'finished-at'
    $selfStart = CurrentStartTimeToken $PID
    AtomicText $workerTokenPath ("${PID}:$selfStart")
    AtomicText $startedAtPath ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'));AtomicText $statusPath 'running'
    $h=(Get-Content $harnessPath -Raw).Trim();$model=(Get-Content $modelPath -Raw).Trim();$effort=(Get-Content $effortPath -Raw).Trim();$cwd=(Get-Content $cwdPath -Raw).Trim();$exe=HarnessValue $h 'command';$delivery=HarnessValue $h 'prompt_delivery';$argv=@(BuildArgv $h $model $effort $prompt (Split-Path $RunDir -Leaf) $cwd)
    $promptText = Get-Content -LiteralPath $prompt -Raw
    if ($delivery -eq 'argument') { $argv += $promptText.TrimEnd("`r","`n") }
    elseif ($delivery -ne 'stdin' -and $delivery -ne 'file') { Fail "invalid prompt_delivery for ${h}: $delivery" }
    [IO.File]::WriteAllText($commandPath,$exe+' '+(($argv|ForEach-Object{'['+$_+']'})-join' ')+[Environment]::NewLine)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = (($argv | ForEach-Object { QuoteProcessArg $_ }) -join ' ')
    $psi.WorkingDirectory = $cwd; $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = ($delivery -eq 'stdin'); $psi.CreateNoWindow = $true
    $process = New-Object Diagnostics.Process; $process.StartInfo = $psi
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    # Stream child output to stdout.log/stderr.log incrementally as it
    # arrives (rather than buffering the whole run and writing once at the
    # end), so `hekate-agent logs`/`logs --follow` show progress on a job
    # that is still running. AutoFlush ensures each line is durable as soon
    # as it is written. PowerShell 5.1-compatible: Register-ObjectEvent +
    # BeginOutputReadLine/BeginErrorReadLine, no PS7-only syntax.
    $stdoutWriter = New-Object IO.StreamWriter($stdoutPath, $false, $utf8NoBom)
    $stdoutWriter.AutoFlush = $true
    $stderrWriter = New-Object IO.StreamWriter($stderrPath, $false, $utf8NoBom)
    $stderrWriter.AutoFlush = $true
    $writeAction = { if ($null -ne $EventArgs.Data) { $Event.MessageData.WriteLine($EventArgs.Data) } }
    $outEvent = $null; $errEvent = $null
    try {
        if (-not $process.Start()) { Fail "failed to start $exe" }
        AtomicText $childPidPath ([string]$process.Id)
        $outEvent = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $writeAction -MessageData $stdoutWriter
        $errEvent = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $writeAction -MessageData $stderrWriter
        $process.BeginOutputReadLine(); $process.BeginErrorReadLine()
        if ($delivery -eq 'stdin') { $process.StandardInput.Write($promptText); $process.StandardInput.Close() }
        $process.WaitForExit(); $code = $process.ExitCode
        # Give the async data-received events a brief moment to drain any
        # already-buffered output before we close the writers.
        Start-Sleep -Milliseconds 100
    } catch { $stderrWriter.WriteLine($_.Exception.Message);$code=1 } finally {
        if ($outEvent) { Unregister-Event -SourceIdentifier $outEvent.Name -ErrorAction SilentlyContinue }
        if ($errEvent) { Unregister-Event -SourceIdentifier $errEvent.Name -ErrorAction SilentlyContinue }
        $stdoutWriter.Close(); $stderrWriter.Close()
    }
    AtomicText $exitCodePath ([string]$code);AtomicText $finishedAtPath ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'));AtomicText $statusPath $(if($code-eq0){'completed'}else{'failed'});return $code
}

function ShowHarnesses { '{0,-12} {1,-8} {2,-22} {3,-10} {4}'-f'HARNESS','ENABLED','MODEL','EFFORT','COMMAND';foreach($h in HarnessNames){'{0,-12} {1,-8} {2,-22} {3,-10} {4}'-f$h,(HarnessValue $h 'enabled'),(HarnessValue $h 'default_model'),(HarnessValue $h 'default_effort'),(HarnessValue $h 'command')} }
function ShowProfiles { '{0,-14} {1,-12} {2,-28} {3}'-f'PROFILE','HARNESS','MODEL','EFFORT';foreach($p in ProfileNames){'{0,-14} {1,-12} {2,-28} {3}'-f$p,(ProfileValue $p 'harness'),(ProfileValue $p 'model'),(ProfileValue $p 'effort')} }
function ShowHelp {@'
Usage: hekate-agent.ps1 doctor|harnesses|profiles|models|config|run|list|status|logs|wait|result|stop
Run `Get-Help .workflow/bin/hekate-agent.ps1` or see .workflow/README.md for examples.
'@}
function WriteLocal([string]$Selected,[string]$Model,[string]$Effort,[string]$Profile){
    $preserved=@();$inside=$false
    if(Test-Path -LiteralPath $LocalConfig){foreach($line in Get-Content -LiteralPath $LocalConfig){if($line-match'^profiles:\s*$'){$inside=$true};if($inside-and$line-match'^\S'-and$line-notmatch'^profiles:'){break};if($inside){$preserved+=$line}}}
    $lines=@('# Per-developer overrides; generated by hekate-agent.','schema_version: 2','enabled: true',"default_harness: $Selected","default_profile: $Profile",'defaults:')
    foreach($h in HarnessNames){$m=HarnessValue $h 'default_model';$e=HarnessValue $h 'default_effort';if($h-eq$Selected){if($Model){$m=$Model};if($Effort){$e=$Effort}};$lines+="  ${h}:";$lines+="    model: $m";$lines+="    effort: $e"}
    if($preserved.Count){$lines+='';$lines+=$preserved}
    $tmp="$LocalConfig.tmp.$PID";[IO.File]::WriteAllLines($tmp,$lines,[Text.UTF8Encoding]::new($false));Move-Item -Force $tmp $LocalConfig
}

try {
    switch ($Command) {
        'help' { ShowHelp }
        'doctor' {
            if($Rest.Count-gt1){Fail 'doctor accepts one harness or --strict'}
            $strict=$false;$target=''
            if($Rest.Count-eq1){if($Rest[0]-eq'--strict'){$strict=$true}else{$target=$Rest[0];ValidateId $target;if(-not(HasHarness $target)){Fail "unknown harness: $target"}}}
            "project: $ProjectRoot"
            "enabled: $(TopValue 'enabled')"
            "default: $(TopValue 'default_harness')"
            $missing=$false
            foreach ($h in HarnessNames) {
                if($target-and$h-ne$target){continue}
                $exe = HarnessValue $h 'command';$enabled=(HarnessValue $h 'enabled')-eq'true'
                if(-not$enabled){"disabled disabled {0,-12} {1}"-f$h,$exe;if($target){$missing=$true};continue}
                $found = Get-Command $exe -ErrorAction SilentlyContinue
                if ($found) { "ok       enabled  {0,-12} {1}" -f $h,$found.Source }
                else { "missing  enabled  {0,-12} {1}" -f $h,$exe;$missing=$true }
            }
            if($missing-and($strict-or$target)){exit 1}
        }
        'harnesses' { ShowHarnesses }
        'profiles' { ShowProfiles }
        'models' {
            if ($Rest.Count -ne 1) { Fail 'models requires a harness' }
            $h = $Rest[0]
            if (-not (HasHarness $h)) { Fail "unknown harness: $h" }
            $exe = HarnessValue $h 'models_command'
            if (-not $exe) { "No model-list command configured for $h. Current default: $(HarnessValue $h 'default_model')" }
            else { $a = @(HarnessList $h 'models_args'); & $exe @a }
        }
        'config' {
            if ($Rest.Count -lt 1) { Fail 'config requires show, use, or clear' }
            $action = $Rest[0]
            if ($action -eq 'show') {
                $profile=DefaultProfile;if(-not$profile){$profile='none'}
                "enabled: $(TopValue 'enabled')"; "default_harness: $(TopValue 'default_harness')"; "default_profile: $profile"; "local_override: $LocalConfig"; ShowHarnesses
            } elseif ($action -eq 'clear') {
                Remove-Item -LiteralPath $LocalConfig -Force -ErrorAction SilentlyContinue
                "Cleared $LocalConfig"
            } elseif ($action -eq 'use') {
                if ($Rest.Count -lt 2) { Fail 'config use requires a harness' }
                $h=$Rest[1]; ValidateId $h
                if (-not (HasHarness $h)) { Fail "unknown harness: $h" }
                $m=''; $e=''
                for ($i=2; $i -lt $Rest.Count; $i++) {
                    if ($Rest[$i] -eq '--model') { $i++; if($i -ge $Rest.Count){Fail '--model requires value'}; $m=$Rest[$i] }
                    elseif ($Rest[$i] -eq '--effort') { $i++; if($i -ge $Rest.Count){Fail '--effort requires value'}; $e=$Rest[$i] }
                    else { Fail "unknown config option: $($Rest[$i])" }
                }
                if ($m) { ValidateValue 'model' $m; if((HarnessValue $h 'supports_model') -ne 'true'){Fail "$h does not support model selection"} }
                if ($e) { ValidateValue 'effort' $e; if((HarnessValue $h 'supports_effort') -ne 'true'){Fail "$h does not support effort selection"} }
                WriteLocal $h $m $e 'none'
                "Default harness: $h (model=$(HarnessValue $h 'default_model') effort=$(HarnessValue $h 'default_effort'))"
            } elseif ($action -eq 'use-profile') {
                if($Rest.Count-ne2){Fail 'config use-profile requires one profile'}
                $profile=$Rest[1];ValidateProfileId $profile;if(-not(HasProfile $profile)){Fail "unknown profile: $profile"}
                $h=ProfileValue $profile 'harness';if(-not(HasHarness $h)){Fail "unknown harness in profile ${profile}: $h"}
                if((HarnessValue $h 'enabled')-ne'true'){Fail "harness is disabled: $h"}
                $m=ProfileValue $profile 'model';$e=ProfileValue $profile 'effort'
                if($m-and(HarnessValue $h 'supports_model')-ne'true'){Fail "$h does not support model selection"}
                if($e-and(HarnessValue $h 'supports_effort')-ne'true'){Fail "$h does not support effort selection"}
                WriteLocal $h '' '' $profile
                "Default profile: $profile (harness=$h model=$m effort=$e)"
            } else { Fail "unknown config action: $action" }
        }
        'run' {
            $profile='';$profileExplicit=$false;$h='';$harnessExplicit=$false;$m='';$modelSelected=$false;$e='';$effortSelected=$false;$cwd=$ProjectRoot;$task='';$taskFile='';$name='';$foreground=$false
            for ($i=0; $i -lt $Rest.Count; $i++) {
                switch ($Rest[$i]) {
                    '--profile' { $i++;if($i-ge$Rest.Count){Fail '--profile requires value'};$profile=$Rest[$i];$profileExplicit=$true }
                    '--harness' { $i++;if($i-ge$Rest.Count){Fail '--harness requires value'};$h=$Rest[$i];$harnessExplicit=$true }
                    '--model' { $i++;if($i-ge$Rest.Count){Fail '--model requires value'};$m=$Rest[$i];$modelSelected=$true }
                    '--effort' { $i++;if($i-ge$Rest.Count){Fail '--effort requires value'};$e=$Rest[$i];$effortSelected=$true }
                    '--cwd' { $cwd=$Rest[++$i] }
                    '--task' { $task=$Rest[++$i] }
                    '--task-file' { $taskFile=$Rest[++$i] }
                    '--name' { $name=$Rest[++$i] }
                    '--foreground' { $foreground=$true }
                    default { Fail "unknown run option: $($Rest[$i])" }
                }
            }
            if($profileExplicit-and$harnessExplicit){Fail 'use either --profile or --harness'}
            $hekateEnabled=DirectSectionRaw $StatusConfig 'hekate' 'enabled'
            if($hekateEnabled-and$hekateEnabled.Substring(2)-ne'true'){Fail 'Hekate is disabled in .workflow/status.yml'}
            $orchestrationModule=DirectNestedRaw $StatusConfig 'hekate' 'modules' 'orchestration'
            if($orchestrationModule-and$orchestrationModule.Substring(2)-ne'true'){Fail 'orchestration module is disabled in .workflow/status.yml'}
            if ((TopValue 'enabled') -ne 'true') { Fail 'orchestration disabled; run config use <harness>' }
            if ($task -and $taskFile) { Fail 'use only one task source' }
            if (-not $task -and -not $taskFile) { Fail 'run requires --task or --task-file' }
            if(-not$profileExplicit-and-not$harnessExplicit){$profile=DefaultProfile}
            if($profile){
                ValidateProfileId $profile;if(-not(HasProfile $profile)){Fail "unknown profile: $profile"}
                $h=ProfileValue $profile 'harness'
                if(-not$modelSelected){$m=ProfileValue $profile 'model';$modelSelected=[bool]$m}
                if(-not$effortSelected){$e=ProfileValue $profile 'effort';$effortSelected=[bool]$e}
            }else{$profile='none';if(-not$h){$h=TopValue 'default_harness'}}
            ValidateId $h
            if (-not (HasHarness $h)) { Fail "unknown harness: $h" }
            if ((HarnessValue $h 'enabled') -ne 'true') { Fail "harness is disabled: $h" }
            if (-not $m) { $m=HarnessValue $h 'default_model' }
            if (-not $e) { $e=HarnessValue $h 'default_effort' }
            ValidateValue 'model' $m; ValidateValue 'effort' $e
            if ($modelSelected -and (HarnessValue $h 'supports_model') -ne 'true') { Fail "$h does not support model selection" }
            if ($effortSelected -and (HarnessValue $h 'supports_effort') -ne 'true') { Fail "$h does not support effort selection" }
            $exe=HarnessValue $h 'command'
            if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { Fail "command not found: $exe" }
            $cwd=ResolveSafeCwd $cwd
            if ($name) { ValidateId $name }
            $root=JobsRoot; New-Item -ItemType Directory -Force -Path $root | Out-Null
            $job=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+$(if($name){$name}else{$h})+'-'+$PID
            $dir=Join-Path $root $job; New-Item -ItemType Directory -Path $dir | Out-Null
            if ($taskFile) { Copy-Item -LiteralPath $taskFile -Destination (Join-Path $dir 'task.md') }
            else { [IO.File]::WriteAllText((Join-Path $dir 'task.md'),$task+[Environment]::NewLine) }
            foreach ($pair in @{profile=$profile;harness=$h;model=$m;effort=$e;cwd=$cwd;status='queued'}.GetEnumerator()) { AtomicText (Join-Path $dir $pair.Key) ([string]$pair.Value) }
            AtomicText (Join-Path $dir 'created-at') ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
            if ($foreground) {
                $job; $code=InvokeWorker $dir; Get-Content (Join-Path $dir 'stdout.log')
                if (Test-Path (Join-Path $dir 'stderr.log')) { Get-Content (Join-Path $dir 'stderr.log') | Write-Error -ErrorAction Continue }
                exit $code
            } else {
                # Windows PowerShell joins ArgumentList items into one command line;
                # quote paths explicitly so projects under "Program Files" work.
                $scriptArg='"'+$MyInvocation.MyCommand.Path.Replace('"','\"')+'"'
                $dirArg='"'+$dir.Replace('"','\"')+'"'
                $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptArg,'__worker',$dirArg)
                $startParams=@{
                    FilePath=(Get-Process -Id $PID).Path
                    ArgumentList=$args
                    PassThru=$true
                    RedirectStandardOutput=(Join-Path $dir 'worker-stdout.log')
                    RedirectStandardError=(Join-Path $dir 'worker-stderr.log')
                }
                if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){$startParams.WindowStyle='Hidden'}
                $p=Start-Process @startParams
                AtomicText (Join-Path $dir 'worker-pid') ([string]$p.Id); $job
            }
        }
        '__worker' { if($Rest.Count -ne 1){exit 2}; exit (InvokeWorker $Rest[0]) }
        'list' {
            $root=JobsRoot; if(-not(Test-Path $root)){'No jobs.'; break}
            '{0,-36} {1,-10} {2,-10} {3}' -f 'JOB','STATUS','HARNESS','MODEL'
            Get-ChildItem $root -Directory | ForEach-Object { '{0,-36} {1,-10} {2,-10} {3}' -f $_.Name,(EffectiveStatus $_.FullName),(Get-Content (Join-Path $_.FullName 'harness') -Raw).Trim(),(Get-Content (Join-Path $_.FullName 'model') -Raw).Trim() }
        }
        'status' {
            if($Rest.Count -ne 1){Fail 'status requires job'}; $d=ResolveJob $Rest[0]
            "job: $($Rest[0])"; "status: $(EffectiveStatus $d)"
            foreach($f in @('profile','harness','model','effort','cwd','created-at','started-at','finished-at','exit-code','worker-pid')){$path=Join-Path $d $f;if(Test-Path $path){"${f}: $((Get-Content $path -Raw).Trim())"}}
        }
        'logs' {
            if($Rest.Count -lt 1){Fail 'logs requires job'}; $d=ResolveJob $Rest[0]; $file=if($Rest -contains '--stderr'){'stderr.log'}else{'stdout.log'}
            $path=Join-Path $d $file;if($Rest -contains '--follow'){Get-Content $path -Wait}elseif(Test-Path $path){Get-Content $path}
        }
        'wait' {
            # Matches sh semantics exactly: block until a terminal state,
            # exit 124 on timeout, otherwise exit with the harness's own
            # persisted exit code (falling back to 1 if none was recorded,
            # e.g. an orphaned job that never produced one).
            if($Rest.Count -lt 1){Fail 'wait requires job'}; $d=ResolveJob $Rest[0]; $timeout=0; $idx=[Array]::IndexOf($Rest,'--timeout'); if($idx -ge 0){$timeout=[int]$Rest[$idx+1]}
            $sw=[Diagnostics.Stopwatch]::StartNew()
            while($true){
                $s=EffectiveStatus $d
                if($s -in @('completed','failed','stopped','orphaned')){break}
                if($timeout -and $sw.Elapsed.TotalSeconds -ge $timeout){exit 124}
                Start-Sleep -Seconds 1
            }
            $code=1
            $exitCodePath=Join-Path $d 'exit-code';if(Test-Path $exitCodePath){$raw=(Get-Content $exitCodePath -Raw).Trim();if($raw){$code=[int]$raw}}
            exit $code
        }
        'result' {
            if($Rest.Count -ne 1){Fail 'result requires job'}; $d=ResolveJob $Rest[0]; $s=EffectiveStatus $d
            $stdoutPath=Join-Path $d 'stdout.log';$stderrPath=Join-Path $d 'stderr.log';if($s -eq 'completed'){Get-Content $stdoutPath}elseif($s -in @('failed','stopped','orphaned')){if(Test-Path $stdoutPath){Get-Content $stdoutPath};if(Test-Path $stderrPath){Get-Content $stderrPath|Write-Error -ErrorAction Continue};exit 1}else{Fail "job not finished: $s"}
        }
        'stop' {
            if($Rest.Count -ne 1){Fail 'stop requires job'}; $d=ResolveJob $Rest[0]; $state=EffectiveStatus $d
            if($state -notin @('queued','running')){Fail "job is not active: $state"}
            $workerPidPath=Join-Path $d 'worker-pid';$statusPath=Join-Path $d 'status';$childPidPath=Join-Path $d 'child-pid'
            $workerPid=if(Test-Path $workerPidPath){[int](Get-Content $workerPidPath -Raw)}else{0}
            if(-not (WorkerIdentityMatches $d $workerPid)){AtomicText $statusPath 'orphaned';Fail 'worker identity cannot be verified; refusing to signal PID'}
            if(Test-Path $childPidPath){
                $childPid=[int](Get-Content $childPidPath -Raw);$child=ProcessRecord $childPid
                if($child -and [int]$child.ParentProcessId -eq $workerPid){Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue}
            }
            Stop-Process -Id $workerPid -Force -ErrorAction SilentlyContinue
            AtomicText $statusPath 'stopped'; "Stopped $($Rest[0])"
        }
        default { ShowHelp; Fail "unknown command: $Command" }
    }
} catch { Write-Error $_.Exception.Message; exit 1 }
