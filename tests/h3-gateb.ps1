param(
    [ValidateRange(15,86400)][int]$Seconds = 7200,
    [string]$Output = '',
    [string]$TestRoot = '',
    [int]$SeedBatches = 4,
    [ValidateRange(1,16)][int]$ComputerThreads = 1,
    [string]$QueueConfig = '',
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path "$PSScriptRoot\..").Path
. "$PSScriptRoot\h3-support.ps1"
if (!$TestRoot) { $TestRoot = 'C:\Work\mc-hard-h3-' + [guid]::NewGuid().ToString('N').Substring(0,12) }
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if ($TestRoot -notmatch '^C:\\Work\\mc-hard-h3-[a-f0-9]{8,32}$') { throw 'Use a random disposable C:\Work\mc-hard-h3-<random> root.' }
if (Test-Path -LiteralPath $TestRoot) { throw 'H3 requires a fresh root. Failed runs stay for review.' }
$HttpBase = 'http://127.0.0.1:1'
if (!$Output) { $Output = 'C:\Work\gemini-input\p3\evidence\h3\gateB-' + [guid]::NewGuid().ToString('N').Substring(0,8) }
New-Item -ItemType Directory -Path $TestRoot, $Output -Force | Out-Null
New-H3Disks -Source $source -Computers "$TestRoot\world\computercraft\computer" -Runtime 'minecraft' -HttpBase $HttpBase -Seconds $Seconds -SeedBatches $SeedBatches -QueueConfig $QueueConfig
$scene = @(
    'forceload add -16 -16 15 15',
    'fill -10 64 -8 10 64 8 minecraft:stone_bricks',
    'fill -10 65 -8 10 70 8 minecraft:air',
    'fill -10 65 -8 10 65 -8 minecraft:glass',
    'fill -10 65 8 10 65 8 minecraft:glass',
    'fill -3 64 1 2 64 3 minecraft:polished_andesite',
    'setblock 0 65 2 minecraft:stone_bricks',
    'fill 7 64 4 10 64 8 minecraft:air',
    'setblock -8 65 -5 computercraft:computer_advanced{ComputerId:0,On:1b}',
    'setblock -8 66 -5 computercraft:wireless_modem_advanced[facing=down]',
    'setblock 8 65 -4 computercraft:computer_advanced{ComputerId:5,On:1b}',
    'setblock 8 66 -4 computercraft:wireless_modem_advanced[facing=down]',
    'fill -7 65 -5 -3 67 -5 computercraft:monitor_advanced[facing=south]',
    'setblock -6 65 0 computercraft:turtle_advanced[facing=north]{ComputerId:1,Fuel:10000,RightUpgrade:"computercraft:wireless_modem_advanced",On:1b}',
    'setblock -2 65 0 computercraft:turtle_advanced[facing=north]{ComputerId:2,Fuel:10000,RightUpgrade:"computercraft:wireless_modem_advanced",On:1b}',
    'setblock 2 65 0 computercraft:turtle_advanced[facing=north]{ComputerId:3,Fuel:10000,RightUpgrade:"computercraft:wireless_modem_advanced",On:1b}',
    'setblock 6 65 0 computercraft:turtle_advanced[facing=north]{ComputerId:4,Fuel:10000,RightUpgrade:"computercraft:wireless_modem_advanced",On:1b}',
    'computercraft turn-on 0 1 2 3 4 5'
)
[IO.File]::WriteAllLines("$TestRoot\scene.txt", $scene, $script:H3Utf8)
$plan = [ordered]@{ scenario='h3'; source=$source; root=$TestRoot; seconds=$Seconds; turtles=4; httpBase=$HttpBase
    queueConfig=$QueueConfig; computerSpaceLimit=1000000; computerThreads=$ComputerThreads; clientLockRequired=$true; clientStarted=$false
    captureView=@{x=5;y=71;z=8;lookAt=@{x=0;y=65;z=0}}; F2Required=$true; videoRequired=$true }
[IO.File]::WriteAllText("$Output\plan.json", ($plan | ConvertTo-Json -Depth 6), $script:H3Utf8)
if ($PrepareOnly) { Write-Output "Prepared $TestRoot. Scene and client capture position are in $Output\plan.json."; return }
. 'C:\Work\gemini-input\gateb\gateb.ps1'
function Read-H3BoxText([string]$Id, [string]$Path) {
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try { return Get-GatebText $Id $Path } catch {
            [IO.File]::AppendAllText("$Output\observer-retries.txt", "$([DateTime]::UtcNow.ToString('o')) $($_.Exception.Message)`n")
            if ($attempt -eq 6) { throw }
            Start-Sleep -Seconds 2
        }
    }
}
$gatebHost = ([uri]$script:GatebUrl).Host
$allowedHosts = @('127.0.0.1', 'localhost')
if ($env:GATEB_HOST) { $allowedHosts += $env:GATEB_HOST }
if ($gatebHost -notin $allowedHosts) { throw 'Use the disposable box daemon.' }
$run = $null
$httpJob = $null
$failure = $null
try {
    $run = New-GatebRun -Name 'hard-h3' -SpaceLimit 1000000 -XmxMb 3072
    [IO.File]::WriteAllText("$Output\box-run.json", ($run | ConvertTo-Json -Depth 10), $script:H3Utf8)
    Send-GatebDir $run.id "$TestRoot\world\computercraft" 'world'
    $assets = "$TestRoot\h3-http-assets"
    New-Item -ItemType Directory -Path $assets | Out-Null
    Copy-Item -Path "$source\*.lua" -Destination $assets
    Copy-Item -LiteralPath "$source\tests\h3-http.py" -Destination $assets
    Send-GatebDir $run.id $assets '.'
    $bootstrap = [IO.File]::ReadAllText("$source\tests\h3-box-http.py")
    $httpJob = New-GatebJob -Ref 'feat/hard-h3' -Cmd @('python3','-c',$bootstrap,'--run',$run.id,'--seconds',[string]$Seconds) -TimeoutSec ($Seconds + 3600)
    [IO.File]::WriteAllText("$Output\http-job.json", ($httpJob | ConvertTo-Json -Depth 8), $script:H3Utf8)
    $ready = (Wait-GatebFile $run.id 'h3-http-ready.json' 180) | ConvertFrom-Json
    $HttpBase = $ready.url
    foreach ($id in 0..5) {
        $path = "$TestRoot\world\computercraft\computer\$id\h3.cfg"
        $text = [IO.File]::ReadAllText($path).Replace('http://127.0.0.1:1', $HttpBase)
        [IO.File]::WriteAllText($path, $text, $script:H3Utf8)
        Send-GatebFile $run.id $path "world/computercraft/computer/$id/h3.cfg"
    }
    $plan.httpBase = $HttpBase
    [IO.File]::WriteAllText("$Output\plan.json", ($plan | ConvertTo-Json -Depth 6), $script:H3Utf8)
    $fixtureUri = [uri]$HttpBase
    $HttpPort = $fixtureUri.Port
    $configured = 0
    foreach ($configPath in @('config/computercraft-server.toml','world/serverconfig/computercraft-server.toml')) {
        $configText = Get-GatebText $run.id $configPath
        if (!$configText) { continue }
        $index = $configText.IndexOf('[[http.rules]]')
        if ($index -lt 0) { throw "Missing HTTP rules in disposable $configPath." }
        $allow = "[[http.rules]]`n    host = `"$($fixtureUri.Host)`"`n    port = $HttpPort`n    action = `"allow`"`n    "
        $configText = $configText.Insert($index, $allow)
        $configText = [regex]::Replace($configText, '(?m)^(\s*computer_threads\s*=\s*)\d+', { param($match) $match.Groups[1].Value + [string]$ComputerThreads })
        Set-GatebText $run.id $configPath $configText
        [IO.File]::WriteAllText((Join-Path $Output ($configPath.Replace('/','-'))), $configText, $script:H3Utf8)
        $configured++
    }
    if (!$configured) { throw 'Cannot configure the HTTP fixture on the disposable box server.' }
    Start-GatebRun $run.id | Out-Null
    Invoke-GatebRcon $run.id $scene -Log "$Output\rcon.txt" | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds + 1800)
    $restarted = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        if (!$restarted -and (Read-H3BoxText $run.id 'world/computercraft/computer/0/restart-ready.json')) {
            Save-GatebDir $run.id 'world/computercraft/computer' "$Output\before-restart"
            Save-GatebDir $run.id 'logs' "$Output\before-restart"
            Stop-GatebRun $run.id | Out-Null
            Start-GatebRun $run.id | Out-Null
            Invoke-GatebRcon $run.id @('computercraft turn-on 0 1 2 3 4 5') -Log "$Output\rcon.txt" | Out-Null
            $restarted = $true
        }
        $summary = Read-H3BoxText $run.id 'world/computercraft/computer/5/h3-summary.json'
        $complete = [bool]$summary
        foreach ($id in 0..5) {
            $text = Read-H3BoxText $run.id "world/computercraft/computer/$id/sandbox-result.json"
            if ($text -and !(($text | ConvertFrom-Json).ok)) { throw "H3 computer $id failed. $text" }
            if (!$text) { $complete = $false }
        }
        if ($complete) { break }
        Start-Sleep -Seconds 2
    }
    if (!$complete) { throw 'H3 box scenario timed out.' }
    if (!$restarted) { throw 'H3 did not reach its restart checkpoint.' }
    Save-GatebDir $run.id 'world/computercraft/computer' $Output
    Set-GatebText $run.id 'h3-http-stop' 'stop'
    Wait-GatebFile $run.id 'h3-http-stopped.json' 60 | Out-Null
    [IO.File]::WriteAllText("$Output\http.jsonl", (Get-GatebText $run.id 'h3-http.jsonl'), $script:H3Utf8)
    Test-H3Results -Computers "$Output\computer" -Output $Output -RequireFullSoak:($Seconds -ge 7200)
    [IO.File]::WriteAllText("$Output\capture-pending.json", (@{boxRun=$run.id;root=$TestRoot;sceneReady=$true;F2=$false;video=$false;GATES='FAIL';reason='Parent must capture F2 and video under the client lock.'} | ConvertTo-Json), $script:H3Utf8)
    Write-Output "Runtime evidence saved. Box run $($run.id) remains available for parent client capture. No client lock was taken."
} catch {
    $failure = $_
    [IO.File]::WriteAllText("$Output\failure.txt", $_.ToString(), $script:H3Utf8)
    if (!(Test-Path -LiteralPath "$Output\h3-results.json")) {
        [IO.File]::WriteAllText("$Output\h3-results.json", (@{ok=$false;scenario='h3';gateEligible=$false;errors=@($_.Exception.Message)} | ConvertTo-Json), $script:H3Utf8)
    }
    throw
} finally {
    if ($run) {
        try {
            if ($httpJob) {
                Set-GatebText $run.id 'h3-http-stop' 'stop'
                [IO.File]::WriteAllText("$Output\http.jsonl", (Get-GatebText $run.id 'h3-http.jsonl'), $script:H3Utf8)
            }
            Save-GatebDir $run.id 'logs' $Output
            Save-GatebDir $run.id 'world/computercraft/computer' "$Output\final-disks"
            [IO.File]::WriteAllText("$Output\jar-sha256.txt", (Get-GatebText $run.id 'jar-sha256.txt'), $script:H3Utf8)
            [IO.File]::WriteAllText("$Output\box-rcon.txt", (Get-GatebText $run.id 'rcon.txt'), $script:H3Utf8)
        } catch { Write-Warning "Evidence download failed. $($_.Exception.Message)" }
        if ($failure) { Stop-GatebRun $run.id | Out-Null }
    }
}
