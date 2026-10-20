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
$stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$work = "C:\Work\gateb-run-$stamp"
if (!$Output) { $Output = "C:\Work\gateb-evidence\$stamp" }
$Output = [IO.Path]::GetFullPath($Output)
$serverLock = 'C:\Work\gemini-input\p2\gateB.lock'
$owner = "gateb.ps1 $Ref $stamp pid $PID"
$problems = New-Object Collections.Generic.List[string]
$rows = New-Object Collections.Generic.List[string]
$testRoots = New-Object Collections.Generic.List[string]
$holdsServer = $false
$holdsClient = $false
$sha = 'unknown'
$started = [DateTime]::Now
New-Item -ItemType Directory -Force -Path $work, $Output | Out-Null
. $Gateb

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
function Enter-ServerLock {
    $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSec)
    while ($true) {
        $freeGb = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
        if ($freeGb -ge 5) {
            try {
                New-Item -ItemType Directory -Path $serverLock -ErrorAction Stop | Out-Null
                [IO.File]::WriteAllText("$serverLock\owner.txt", $owner, $utf8)
                $script:holdsServer = $true
                return
            } catch { }
        }
        if ([DateTime]::UtcNow -gt $deadline) { throw "gateB.lock or 5 GB free RAM not available within $LockTimeoutSec s." }
        Start-Sleep -Seconds 60
    }
}
function Exit-ServerLock {
    if ($script:holdsServer -and (Get-Content "$serverLock\owner.txt" -Raw -ErrorAction SilentlyContinue) -eq $owner) {
        Remove-Item -LiteralPath $serverLock -Recurse -Force
    }
    $script:holdsServer = $false
}

try {
    $src = "$work\src"
    git init -q $src
    git -C $src fetch -q --depth 1 https://github.com/140er/computercraft-scripts.git $Ref
    if ($LASTEXITCODE) { throw "Cannot fetch $Ref." }
    git -C $src checkout -q FETCH_HEAD
    $sha = (git -C $src rev-parse HEAD).Trim()

    $live = @{}
    foreach ($line in (Get-GatebHealth).mods) {
        if ($line.Trim()) { $hash, $name = $line.Trim() -split '\s+', 2; $live[$name] = $hash.ToLower() }
    }
    if ($live.Count -eq 0) { throw 'gatebd returned no live jar hashes.' }
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
        Enter-GatebClientLock $owner
        $holdsClient = $true
        try {
            & "$src\tests\ingame\run.ps1" -Scenario $s -Base $stage -Battery "$stage\mods\turtlebattery-0.3.0.jar" -Output $out -TestRoot $root -Timeout $Timeout -Client *>&1 | Out-File "$out-driver.log" -Encoding utf8
        } catch {
            Add-Content "$out-driver.log" "DRIVER ERROR $($_.Exception.Message)"
        } finally {
            Exit-GatebClientLock
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
        } else { $problems.Add("$s wrote no jar-sha256.txt.") }
        $rows.Add("| $s | $verdict | $(($shots | ForEach-Object { $_.FullName }) -join '<br>') | $(($videos | ForEach-Object { $_.FullName }) -join '<br>') |")
    }
    if (!(Get-ChildItem $Output -Recurse -Filter '*.mp4' -File)) { $problems.Add('No video clip. Include the warehouse scenario.') }
    $depth = "$src\docs\testing\gateB-depth.md"
    if (Test-Path $depth) {
        $items = @(Get-Content $depth | Where-Object { $_ -match '^- ' })
        [IO.File]::WriteAllLines("$Output\depth-not-run.txt", $items, $utf8)
        $problems.Add("gateB-depth.md has $($items.Count) items that no tests/ingame scenario runs. See $Output\depth-not-run.txt.")
    }
} catch {
    $problems.Add("Run aborted. $($_.Exception.Message)")
} finally {
    if ($holdsClient) { Exit-GatebClientLock }
    Exit-ServerLock
    foreach ($path in @($testRoots) + "$work") {
        try { Remove-TestTree $path } catch { $problems.Add("Teardown left $path. $($_.Exception.Message)") }
    }
}

$gates = if ($problems.Count -eq 0) { 'PASS' } else { 'FAIL' }
$unloaded = @($live.Keys | Where-Object { $name = $_; !(Get-ChildItem $Output -Recurse -Filter 'jar-sha256.txt' | Select-String -SimpleMatch $name -Quiet) })
$summary = @("GATES: $gates", '', "Ref $Ref at $sha.", "Host $env:COMPUTERNAME, VM-local disposable servers under C:\Work\mc-ssot-pr1-gb$stamp-*, never live.",
    "Started $($started.ToString('s')), finished $([DateTime]::Now.ToString('s')).", "Live jars from gatebd not loaded by any scenario: $(if ($unloaded) { $unloaded -join ', ' } else { 'none' }).", '',
    '| Scenario | Verdict | Screenshots | Video |', '| --- | --- | --- | --- |') + $rows + @('', 'Problems:') +
    $(if ($problems.Count) { $problems | ForEach-Object { "- $_" } } else { '- none' }) + @('', "Evidence: $Output")
[IO.File]::WriteAllLines("$Output\SUMMARY.md", $summary, $utf8)
$summary
if ($gates -ne 'PASS') { exit 1 }
