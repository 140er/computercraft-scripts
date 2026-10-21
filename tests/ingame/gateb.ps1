param(
    [string]$Ref = 'main',
    [ValidateSet('ssot','nav','mining','warehouse')][string[]]$Scenario = @('ssot','nav','mining','warehouse'),
    [string]$Output = '',
    [int]$Timeout = 900,
    [int]$LockTimeoutSec = 14400,
    [string]$Gateb = 'C:\Work\gemini-input\gateb\gateb.ps1',
    [string]$Base = 'C:\mc-cc-test\base'
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$allScenarios = @('ssot','nav','mining','warehouse')
$partial = @($allScenarios | Where-Object { $Scenario -notcontains $_ }).Count -gt 0
$stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$work = "C:\Work\gateb-run-$stamp"
if (!$Output) { $Output = "C:\Work\gateb-evidence\$stamp" }
$Output = [IO.Path]::GetFullPath($Output)
$serverLock = 'C:\Work\gemini-input\p2\gateB.lock'
$clientLock = 'C:\Work\gemini-input\p2\gateB-client.lock'
$holdFile = 'C:\Work\gemini-input\p2\gateB.hold'
$startTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
$owner = "gateb.ps1 host $env:COMPUTERNAME stamp $stamp pid $PID start $startTicks ref $Ref"
$problems = New-Object Collections.Generic.List[string]
$rows = New-Object Collections.Generic.List[string]
$testRoots = New-Object Collections.Generic.List[string]
$holdsServer = $false
$holdsClient = $false
$sha = 'unknown'
$live = @{}
$phase = 'starting'
$started = [DateTime]::Now
New-Item -ItemType Directory -Force -Path $work, $Output | Out-Null

function Write-Summary([string]$Gates) {
    $lines = @("GATES: $Gates", '', "Ref $Ref at $sha.", "Run $stamp, pid $PID, host $env:COMPUTERNAME. VM-local disposable servers under C:\Work\mc-ssot-pr1-gb$stamp-*, never live.",
        "Scenarios $($Scenario -join ', ')$(if ($partial) { ' (subset, so PARTIAL at best)' }).",
        'New-H3Disks does not block GATES: PASS. gateb.ps1 and the ssot, nav, mining, and warehouse scenarios never call it.',
        "Started $($started.ToString('s')). Heartbeat $([DateTime]::Now.ToString('s')), $script:phase.", '',
        '| Scenario | Verdict | Screenshots | Video |', '| --- | --- | --- | --- |') + $rows + @('', 'Problems:') +
        $(if ($problems.Count) { $problems | ForEach-Object { "- $_" } } else { '- none' }) + @('', "Evidence: $Output")
    [IO.File]::WriteAllLines("$Output\SUMMARY.md", $lines, $utf8)
    $lines
}
function Set-Phase([string]$Text) { $script:phase = $Text; Write-Summary 'RUNNING' | Out-Null }
function Remove-TestTree([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) { return }
    function Remove-Links([string]$Dir) {
        foreach ($d in [IO.Directory]::GetDirectories($Dir)) {
            if ([IO.File]::GetAttributes($d) -band [IO.FileAttributes]::ReparsePoint) {
                cmd /c rmdir "$d" | Out-Null
                if (Test-Path -LiteralPath $d) { throw "Could not unlink junction $d." }
            } else { Remove-Links $d }
        }
    }
    Remove-Links $Path
    Remove-Item -LiteralPath $Path -Recurse -Force
}
# The client command line names its test root. The server's does not (relative @libraries argfile), so it is matched by parent PID.
function Stop-RunJava([string]$RunStamp, [int]$OwnerPid, [int64]$OwnerStart, [int64]$Before = [int64]::MaxValue) {
    $needle = "mc-ssot-pr1-gb$RunStamp-"
    $pids = @(Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" | Where-Object {
        ($_.CommandLine -and $_.CommandLine.Replace('/', '\').Contains($needle)) -or
        ($_.ParentProcessId -eq $OwnerPid -and $_.CreationDate.ToUniversalTime().Ticks -ge $OwnerStart -and $_.CreationDate.ToUniversalTime().Ticks -lt $Before)
    } | ForEach-Object { $_.ProcessId })
    if ($pids) {
        Stop-Process -Id $pids -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $pids -Timeout 30 -ErrorAction SilentlyContinue
    }
}
function Invoke-Reclaim([string]$Lock) {
    $text = Get-Content "$Lock\owner.txt" -Raw -ErrorAction SilentlyContinue
    if (!$text -or $text -notmatch '^gateb\.ps1 host (\S+) stamp (\S+) pid (\d+) start (\d+)' -or $Matches[1] -ne $env:COMPUTERNAME) { return }
    $deadStamp = $Matches[2]; $deadPid = [int]$Matches[3]; $deadStart = [int64]$Matches[4]
    $process = Get-Process -Id $deadPid -ErrorAction SilentlyContinue
    if ($process -and $process.StartTime.ToUniversalTime().Ticks -eq $deadStart) { return }
    $reusedAt = if ($process) { $process.StartTime.ToUniversalTime().Ticks } else { [int64]::MaxValue }
    Stop-RunJava $deadStamp $deadPid $deadStart $reusedAt
    $dirs = @(Get-ChildItem C:\Work -Directory -Filter "mc-ssot-pr1-gb$deadStamp-*") + @(Get-Item "C:\Work\gateb-run-$deadStamp" -ErrorAction SilentlyContinue)
    foreach ($dir in $dirs) { if ($dir) { Remove-TestTree $dir.FullName } }
    if ((Get-Content "$Lock\owner.txt" -Raw -ErrorAction SilentlyContinue) -eq $text) { Remove-Item -LiteralPath $Lock -Recurse -Force }
    $problems.Add("Reclaimed $(Split-Path $Lock -Leaf) from dead run $deadStamp (pid $deadPid). This is a note, not a failure.")
}
function Wait-NoHold {
    $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSec)
    while ($true) {
        $health = $null
        $last = $null
        foreach ($delay in @(0, 2, 2, 2)) {
            if ($delay -gt 0) { Start-Sleep -Seconds $delay }
            try {
                $health = Get-GatebHealth
                $last = $null
                break
            } catch {
                $last = $_
            }
        }
        if ($last) { throw $last }
        $held = (Test-Path $holdFile) -or ($health.PSObject.Properties['hold'] -and $health.hold)
        if (!$held) { return $health }
        if ([DateTime]::UtcNow -gt $deadline) { throw "A gate B hold stayed active for $LockTimeoutSec s." }
        Set-Phase 'waiting for a gate B hold'
        Start-Sleep -Seconds 60
    }
}
function Enter-ServerLock {
    $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSec)
    while ($true) {
        Wait-NoHold | Out-Null
        Invoke-Reclaim $serverLock
        if ((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB -ge 5) {
            $created = $false
            try { New-Item -ItemType Directory -Path $serverLock -ErrorAction Stop | Out-Null; $created = $true } catch { }
            if ($created) {
                try { [IO.File]::WriteAllText("$serverLock\owner.txt", $owner, $utf8); $script:holdsServer = $true; return }
                catch { Remove-Item -LiteralPath $serverLock -Recurse -Force -ErrorAction SilentlyContinue; throw }
            }
        }
        if ([DateTime]::UtcNow -gt $deadline) { throw "gateB.lock or 5 GB free RAM not available within $LockTimeoutSec s." }
        Set-Phase 'waiting for gateB.lock'
        Start-Sleep -Seconds 60
    }
}
function Enter-ClientLock {
    $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSec)
    while ($true) {
        Invoke-Reclaim $clientLock
        try { Enter-GatebClientLock $owner 600; $script:holdsClient = $true; return }
        catch { if ($_.Exception.Message -ne 'client lock timeout') { throw } }
        if ([DateTime]::UtcNow -gt $deadline) { throw "gateB-client.lock not available within $LockTimeoutSec s." }
        Set-Phase 'waiting for gateB-client.lock'
        Start-Sleep -Seconds 60
    }
}
function Exit-OwnLock([string]$Lock) {
    $text = Get-Content "$Lock\owner.txt" -Raw -ErrorAction SilentlyContinue
    if ($text -and $text.StartsWith($owner)) { Remove-Item -LiteralPath $Lock -Recurse -Force }
}

try {
    . $Gateb
    Set-Phase 'fetching the ref'
    $src = "$work\src"
    git init -q $src
    if ($LASTEXITCODE) { throw "git init failed in $src." }
    git -C $src fetch -q --depth 1 https://github.com/140er/computercraft-scripts.git $Ref
    if ($LASTEXITCODE) { throw "Cannot fetch $Ref." }
    git -C $src checkout -q FETCH_HEAD
    if ($LASTEXITCODE) { throw "Cannot check out $Ref." }
    $sha = (git -C $src rev-parse HEAD).Trim()
    if ($LASTEXITCODE) { throw "Cannot resolve the $Ref commit." }

    Set-Phase 'staging the live jars'
    foreach ($line in (Wait-NoHold).mods) {
        if ($line.Trim()) { $hash, $name = $line.Trim() -split '\s+', 2; $live[$name] = $hash.ToLower() }
    }
    if ($live.Count -eq 0) { throw 'gatebd returned no live jar hashes.' }
    $battery = @($live.Keys | Where-Object { $_ -like 'turtlebattery-*.jar' })[0]
    if (!$battery) { throw 'gatebd lists no turtlebattery jar.' }
    $stage = "$work\base"
    New-Item -ItemType Directory -Force -Path "$stage\mods" | Out-Null
    New-Item -ItemType Junction -Path "$stage\libraries" -Target "$Base\libraries" | Out-Null
    Copy-Item "$Base\config" "$stage\config" -Recurse
    $cache = Join-Path (Split-Path $Gateb) 'mods-cache'
    foreach ($name in $live.Keys) {
        $candidates = @("$cache\$($live[$name])-$name", "$Base\mods\$name")
        $jar = $candidates | Where-Object { (Test-Path -LiteralPath $_) -and (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLower() -eq $live[$name] } | Select-Object -First 1
        if (!$jar) { throw "No local copy of live jar $name with sha256 $($live[$name])." }
        Copy-Item -LiteralPath $jar "$stage\mods\$name"
    }

    Enter-ServerLock
    foreach ($s in $Scenario) {
        $out = "$Output\$s"
        $root = "C:\Work\mc-ssot-pr1-gb$stamp-$s"
        $testRoots.Add($root)
        $recorded = $false
        try {
            Wait-NoHold | Out-Null
            Enter-ClientLock
            Set-Phase "scenario $s running"
            Push-Location $src
            try {
                & "$src\tests\ingame\run.ps1" -Scenario $s -Base $stage -Battery "$stage\mods\$battery" -Output $out -TestRoot $root -Timeout $Timeout -Client *>&1 | Out-File "$out-driver.log" -Encoding utf8
            } catch {
                Add-Content "$out-driver.log" "DRIVER ERROR $($_.Exception.Message)"
            } finally {
                Pop-Location
                Stop-RunJava $stamp $PID $startTicks
                Exit-OwnLock $clientLock
                $holdsClient = $false
            }
            Get-ChildItem $root -Filter 'std*.log' -ErrorAction SilentlyContinue | Copy-Item -Destination $out
            $verdict = if (Test-Path "$out\verdict.txt") { ([IO.File]::ReadAllText("$out\verdict.txt") -split "`n")[0].Trim() } else { 'MISSING' }
            $shots = @(Get-ChildItem $out -Filter '*.png' -File -ErrorAction SilentlyContinue)
            $videos = @(Get-ChildItem $out -Filter '*.mp4' -File -ErrorAction SilentlyContinue)
            if ($verdict -ne 'PASS') { $problems.Add("$s verdict $verdict. See $out\verdict.txt and $out-driver.log.") }
            if ($shots.Count -eq 0 -or (Test-Path "$out\visual-missing.txt")) { $problems.Add("$s has no client F2 screenshot.") }
            if (Test-Path "$out\jar-sha256.txt") {
                foreach ($line in Get-Content "$out\jar-sha256.txt") {
                    $hash, $name = $line.Trim() -split '\s+', 2
                    if ($live[$name] -ne $hash.ToLower()) { $problems.Add("$s loaded $name, which does not match the live sha256.") }
                }
                $missing = @($live.Keys | Where-Object { !(Select-String -LiteralPath "$out\jar-sha256.txt" -SimpleMatch " $_" -Quiet) } | Sort-Object)
                if ($missing) { $problems.Add("$s test server is missing live jars $($missing -join ', ').") }
            } else { $problems.Add("$s wrote no jar-sha256.txt.") }
            $rows.Add("| $s | $verdict | $(($shots | ForEach-Object { $_.FullName }) -join '<br>') | $(($videos | ForEach-Object { $_.FullName }) -join '<br>') |")
            $recorded = $true
            Set-Phase "scenario $s finished $verdict"
        } catch {
            if ($holdsClient) {
                Exit-OwnLock $clientLock
                $holdsClient = $false
            }
            Stop-RunJava $stamp $PID $startTicks
            if (-not $recorded) {
                $problems.Add("$s error. $($_.Exception.Message)")
                $rows.Add("| $s | ERROR |  |  |")
                try { Set-Phase "scenario $s finished ERROR" } catch { }
            } else {
                $problems.Add("$s error after its verdict. $($_.Exception.Message)")
            }
        }
    }
    if (!$partial -and !(Get-ChildItem $Output -Recurse -Filter '*.mp4' -File)) { $problems.Add('No video clip.') }
    $depth = "$src\docs\testing\gateB-depth.md"
    if (Test-Path $depth) {
        $map = @(Get-Content "$src\tests\ingame\depth-map.txt" -ErrorAction SilentlyContinue | ForEach-Object { if ($_ -match '^\s*(\w+)\s*\|\s*(.+?)\s*$') { [pscustomobject]@{ Scenario = $Matches[1]; Item = $Matches[2] } } })
        $passed = @($rows | ForEach-Object { if ($_ -match '^\| (\w+) \| PASS \|') { $Matches[1] } })
        $uncovered = @(Get-Content $depth | Where-Object { $_ -match '^- ' } | ForEach-Object { $_.Substring(2).Trim() } | Where-Object {
            $item = $_; !($map | Where-Object { $item.StartsWith($_.Item) -and ($passed -contains $_.Scenario -or $Scenario -notcontains $_.Scenario) }) })
        if ($uncovered) {
            [IO.File]::WriteAllLines("$Output\depth-not-run.txt", $uncovered, $utf8)
            $problems.Add("$($uncovered.Count) gateB-depth.md items have no passing scenario in tests/ingame/depth-map.txt. See $Output\depth-not-run.txt.")
        }
    }
} catch {
    $problems.Add("Run aborted. $($_.Exception.Message)")
} finally {
    Stop-RunJava $stamp $PID $startTicks
    foreach ($path in @($testRoots) + "$work") {
        try { Remove-TestTree $path } catch { $problems.Add("Teardown left $path. $($_.Exception.Message)") }
    }
    if ($holdsClient) { Exit-OwnLock $clientLock }
    if ($holdsServer) { Exit-OwnLock $serverLock }
}

$gates = if ($problems | Where-Object { $_ -notlike 'Reclaimed *' }) { 'FAIL' } elseif ($partial) { 'PARTIAL' } else { 'PASS' }
$phase = 'finished'
Write-Summary $gates
if ($gates -eq 'FAIL') { exit 1 }
if ($gates -eq 'PARTIAL') { exit 2 }
