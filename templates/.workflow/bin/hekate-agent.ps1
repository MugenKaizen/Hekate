[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..\..')).TrimEnd('\','/')
$Config = Join-Path $ProjectRoot '.workflow\orchestration.yml'
$LocalConfig = Join-Path $ProjectRoot '.workflow\orchestration.local.yml'
if (-not (Test-Path -LiteralPath $Config)) { throw "hekate-agent: missing $Config" }

function Fail([string]$Message) { throw "hekate-agent: $Message" }
function Scalar([string]$Value) { if ($null -eq $Value) { return '' }; $v=$Value.Trim(); if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) { return $v.Substring(1,$v.Length-2) }; return $v }
function TopValueFrom([string]$File,[string]$Key) { if (-not (Test-Path -LiteralPath $File)) { return '' }; foreach($line in Get-Content -LiteralPath $File) { if($line -match ('^'+[regex]::Escape($Key)+':\s*(.*?)\s*(?:#.*)?$')) { return Scalar $matches[1] } }; return '' }
function TopValue([string]$Key) { $v=TopValueFrom $LocalConfig $Key; if(-not $v){$v=TopValueFrom $Config $Key}; return $v }
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
function ProcessRecord([int]$Id) { return Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction SilentlyContinue }
function WorkerIdentityMatches([string]$Dir,[int]$Id) {
    if (-not $Id) { return $false }
    $record = ProcessRecord $Id
    if (-not $record -or -not $record.CommandLine) { return $false }
    return $record.CommandLine.Contains('hekate-agent.ps1') -and $record.CommandLine.Contains('__worker') -and $record.CommandLine.Contains($Dir)
}
function EffectiveStatus([string]$Dir) {
    $s = if (Test-Path "$Dir\status") { (Get-Content "$Dir\status" -Raw).Trim() } else { 'unknown' }
    if ($s -in @('queued','running')) {
        $p = if (Test-Path "$Dir\worker.pid") { [int](Get-Content "$Dir\worker.pid" -Raw) } else { 0 }
        if ($p -and -not (WorkerIdentityMatches $Dir $p)) {
            $s = 'orphaned'; AtomicText "$Dir\status" $s
        }
    }
    return $s
}
function ReplaceTokens([string]$Text,[string]$Model,[string]$Effort,[string]$Prompt,[string]$Session,[string]$Cwd){return $Text.Replace('{model}',$Model).Replace('{effort}',$Effort).Replace('{prompt_file}',$Prompt).Replace('{session_id}',$Session).Replace('{cwd}',$Cwd)}
function BuildArgv([string]$Harness,[string]$Model,[string]$Effort,[string]$Prompt,[string]$Session,[string]$Cwd){$out=@();foreach($a in @(HarnessList $Harness 'args')){$out+=ReplaceTokens $a $Model $Effort $Prompt $Session $Cwd};return,$out}

function InvokeWorker([string]$RunDir){
    AtomicText "$RunDir\status" 'running';AtomicText "$RunDir\started_at" ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
    $h=(Get-Content "$RunDir\harness" -Raw).Trim();$model=(Get-Content "$RunDir\model" -Raw).Trim();$effort=(Get-Content "$RunDir\effort" -Raw).Trim();$cwd=(Get-Content "$RunDir\cwd" -Raw).Trim();$prompt="$RunDir\prompt.md";$exe=HarnessValue $h 'command';$delivery=HarnessValue $h 'prompt_delivery';$argv=@(BuildArgv $h $model $effort $prompt (Split-Path $RunDir -Leaf) $cwd)
    $promptText = Get-Content -LiteralPath $prompt -Raw
    if ($delivery -eq 'argument') { $argv += $promptText }
    elseif ($delivery -ne 'stdin' -and $delivery -ne 'file') { Fail "invalid prompt_delivery for $h: $delivery" }
    [IO.File]::WriteAllText("$RunDir\command.txt",$exe+' '+(($argv|ForEach-Object{'['+$_+']'})-join' ')+[Environment]::NewLine)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = (($argv | ForEach-Object { QuoteProcessArg $_ }) -join ' ')
    $psi.WorkingDirectory = $cwd; $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = ($delivery -eq 'stdin'); $psi.CreateNoWindow = $true
    $process = New-Object Diagnostics.Process; $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { Fail "failed to start $exe" }
        AtomicText "$RunDir\child.pid" ([string]$process.Id)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($delivery -eq 'stdin') { $process.StandardInput.Write($promptText); $process.StandardInput.Close() }
        $process.WaitForExit(); $code = $process.ExitCode
        $stdout = $stdoutTask.GetAwaiter().GetResult(); $stderr = $stderrTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText("$RunDir\stdout.log",$stdout); [IO.File]::WriteAllText("$RunDir\stderr.log",$stderr)
    } catch { [IO.File]::WriteAllText("$RunDir\stderr.log",$_.Exception.Message);$code=1 }
    AtomicText "$RunDir\exit_code" ([string]$code);AtomicText "$RunDir\finished_at" ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'));AtomicText "$RunDir\status" $(if($code-eq0){'completed'}else{'failed'});return $code
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
            if ($taskFile) { Copy-Item -LiteralPath $taskFile -Destination "$dir\prompt.md" }
            else { [IO.File]::WriteAllText("$dir\prompt.md",$task+[Environment]::NewLine) }
            foreach ($pair in @{profile=$profile;harness=$h;model=$m;effort=$e;cwd=$cwd;job_id=$job;status='queued';created_at=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')}.GetEnumerator()) { AtomicText "$dir\$($pair.Key)" ([string]$pair.Value) }
            if ($foreground) {
                $job; $code=InvokeWorker $dir; Get-Content "$dir\stdout.log"
                if (Test-Path "$dir\stderr.log") { Get-Content "$dir\stderr.log" | Write-Error -ErrorAction Continue }
                exit $code
            } else {
                # Windows PowerShell joins ArgumentList items into one command line;
                # quote paths explicitly so projects under "Program Files" work.
                $scriptArg='"'+$MyInvocation.MyCommand.Path.Replace('"','\"')+'"'
                $dirArg='"'+$dir.Replace('"','\"')+'"'
                $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptArg,'__worker',$dirArg)
                $p=Start-Process powershell -ArgumentList $args -WindowStyle Hidden -PassThru
                AtomicText "$dir\worker.pid" ([string]$p.Id); $job
            }
        }
        '__worker' { if($Rest.Count -ne 1){exit 2}; exit (InvokeWorker $Rest[0]) }
        'list' {
            $root=JobsRoot; if(-not(Test-Path $root)){'No jobs.'; break}
            '{0,-36} {1,-10} {2,-10} {3}' -f 'JOB','STATUS','HARNESS','MODEL'
            Get-ChildItem $root -Directory | ForEach-Object { '{0,-36} {1,-10} {2,-10} {3}' -f $_.Name,(EffectiveStatus $_.FullName),(Get-Content "$($_.FullName)\harness" -Raw).Trim(),(Get-Content "$($_.FullName)\model" -Raw).Trim() }
        }
        'status' {
            if($Rest.Count -ne 1){Fail 'status requires job'}; $d=ResolveJob $Rest[0]
            "job: $($Rest[0])"; "status: $(EffectiveStatus $d)"
            foreach($f in @('profile','harness','model','effort','cwd','created_at','started_at','finished_at','exit_code','worker.pid')){if(Test-Path "$d\$f"){"${f}: $((Get-Content "$d\$f" -Raw).Trim())"}}
        }
        'logs' {
            if($Rest.Count -lt 1){Fail 'logs requires job'}; $d=ResolveJob $Rest[0]; $file=if($Rest -contains '--stderr'){'stderr.log'}else{'stdout.log'}
            if($Rest -contains '--follow'){Get-Content "$d\$file" -Wait}elseif(Test-Path "$d\$file"){Get-Content "$d\$file"}
        }
        'wait' {
            if($Rest.Count -lt 1){Fail 'wait requires job'}; $d=ResolveJob $Rest[0]; $timeout=0; $idx=[Array]::IndexOf($Rest,'--timeout'); if($idx -ge 0){$timeout=[int]$Rest[$idx+1]}
            $sw=[Diagnostics.Stopwatch]::StartNew(); while($true){$s=EffectiveStatus $d;if($s -eq 'completed'){exit 0};if($s -in @('failed','stopped','orphaned')){exit 1};if($timeout -and $sw.Elapsed.TotalSeconds -ge $timeout){exit 124};Start-Sleep -Seconds 1}
        }
        'result' {
            if($Rest.Count -ne 1){Fail 'result requires job'}; $d=ResolveJob $Rest[0]; $s=EffectiveStatus $d
            if($s -eq 'completed'){Get-Content "$d\stdout.log"}elseif($s -in @('failed','stopped','orphaned')){if(Test-Path "$d\stdout.log"){Get-Content "$d\stdout.log"};if(Test-Path "$d\stderr.log"){Get-Content "$d\stderr.log"|Write-Error -ErrorAction Continue};exit 1}else{Fail "job not finished: $s"}
        }
        'stop' {
            if($Rest.Count -ne 1){Fail 'stop requires job'}; $d=ResolveJob $Rest[0]; $state=EffectiveStatus $d
            if($state -notin @('queued','running')){Fail "job is not active: $state"}
            $workerPid=if(Test-Path "$d\worker.pid"){[int](Get-Content "$d\worker.pid" -Raw)}else{0}
            if(-not (WorkerIdentityMatches $d $workerPid)){AtomicText "$d\status" 'orphaned';Fail 'worker identity cannot be verified; refusing to signal PID'}
            if(Test-Path "$d\child.pid"){
                $childPid=[int](Get-Content "$d\child.pid" -Raw);$child=ProcessRecord $childPid
                if($child -and [int]$child.ParentProcessId -eq $workerPid){Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue}
            }
            Stop-Process -Id $workerPid -Force -ErrorAction SilentlyContinue
            AtomicText "$d\status" 'stopped'; "Stopped $($Rest[0])"
        }
        default { ShowHelp; Fail "unknown command: $Command" }
    }
} catch { Write-Error $_.Exception.Message; exit 1 }
