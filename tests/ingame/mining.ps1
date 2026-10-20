$ErrorActionPreference='Stop'
$computers="$TestRoot\world\computercraft\computer"
function Mining-Wait([string]$Path) {
    $until=[DateTime]::UtcNow.AddSeconds($Timeout)
    do {
        foreach ($id in 1..3) {
            $disk="$computers\$id"
            if ((Test-Path "$disk\inventory-ready.json") -and !(Test-Path "$disk\inventory-filled")) {
                $ready=Get-Content "$disk\inventory-ready.json" -Raw | ConvertFrom-Json
                $p=$ready.pose
                foreach ($slot in $ready.empty) { $index=$slot-1; Rcon "item replace block $($p.x) $($p.y) $($p.z) container.$index with minecraft:stone 64" | Out-Null }
                [IO.File]::WriteAllText("$disk\inventory-filled",'ready',$utf8)
            }
            if ((Test-Path "$disk\inventory-returned.json") -and !(Test-Path "$disk\inventory-cleared")) {
                $p=(Get-Content "$disk\inventory-returned.json" -Raw | ConvertFrom-Json).pose
                Rcon "data get block $($p.x) $($p.y) $($p.z)" | Out-Null
                $ready=Get-Content "$disk\inventory-ready.json" -Raw | ConvertFrom-Json
                foreach ($slot in $ready.empty) { $index=$slot-1; Rcon "item replace block $($p.x) $($p.y) $($p.z) container.$index with minecraft:air" | Out-Null }
                [IO.File]::WriteAllText("$disk\inventory-cleared",'ready',$utf8)
            }
            if ((Test-Path "$disk\fuel-ready.json") -and !(Test-Path "$disk\fuel-filled")) {
                $p=(Get-Content "$disk\fuel-ready.json" -Raw | ConvertFrom-Json).pose
                Rcon "item replace block $($p.x) $($p.y) $($p.z) container.15 with minecraft:coal" | Out-Null
                [IO.File]::WriteAllText("$disk\fuel-filled",'ready',$utf8)
            }
        }
        $failed=@(Get-ChildItem $computers -Recurse -Filter sandbox-result.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { !$_.ok })
        if ($failed) { throw ($failed.errors -join '; ') }
        if (Test-Path $Path) { return }
        if ($script:process.HasExited) { throw 'Minecraft exited during mining.' }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $until)
    throw "Mining timeout waiting for $Path."
}
try {
    Start-TestServer 'first'
    foreach ($cmd in @('forceload add -16 -16 32 16','fill -2 63 -2 13 68 8 minecraft:air',
        'fill -2 63 -2 13 63 8 minecraft:stone','fill 0 64 1 11 66 6 minecraft:stone','gamerule spawnChunkRadius 0','setblock -4 65 -4 computercraft:computer_advanced{ComputerId:0}',
        'setblock -4 66 -4 computercraft:wireless_modem_advanced[facing=down]',
        'setblock 14 65 -4 computercraft:computer_advanced{ComputerId:4}',
        'setblock 14 66 -4 computercraft:wireless_modem_advanced[facing=down]',
        'setblock 14 65 -2 computercraft:computer_advanced{ComputerId:6}',
        'setblock 14 66 -2 computercraft:wireless_modem_advanced[facing=down]')) { Rcon $cmd | Out-Null }
    $rows=& 'C:\Tools\lua52\lua52.exe' -e "for _,p in ipairs(dofile('tests/mining-fixture.lua').blocks) do print(p.x..' '..p.y..' '..p.z..' '..p.name) end"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot load the mining fixture.' }
    $finalBlocks=@{}
    foreach ($line in $rows) { $v=$line.Split(' '); $finalBlocks[($v[0..2] -join ' ')]=$v[3] }
    $finalBlocks | ConvertTo-Json | Set-Content "$Output\fixture-before.json"
    foreach ($position in $finalBlocks.Keys) { if($finalBlocks[$position] -ne "minecraft:stone") { Rcon "setblock $position $($finalBlocks[$position])" | Out-Null } }
    for ($id=1;$id -le 3;$id++) {
        $x=$id*4-3
        $fuel=if($id -eq 2){42}else{10000}
        Rcon "setblock $x 65 0 computercraft:turtle_advanced[facing=south]{ComputerId:$id,Fuel:$fuel,LeftUpgrade:`"minecraft:diamond_pickaxe`",RightUpgrade:`"computercraft:wireless_modem_advanced`"}" | Out-Null
    }
    for ($i=0;$i -lt $hosts.Count;$i++) {
        $p=$hosts[$i]
        Rcon "setblock $($p[0]) $($p[1]) $($p[2]) computercraft:computer_advanced{ComputerId:$($i+10)}" | Out-Null
        Rcon "setblock $($p[0]) $($p[1]+1) $($p[2]) computercraft:wireless_modem_normal[facing=down]" | Out-Null
    }
    if ($Client) { & "$PSScriptRoot\client.ps1" -TestRoot $TestRoot -Port $port -RconPort $rconPort -Output $Output -View mining -ShotName mining-before.png }
    Rcon 'computercraft turn-on 10 11 12 13' | Out-Null
    Start-Sleep -Seconds 2
    Rcon 'computercraft turn-on 0 1 2 3 4 6' | Out-Null
    Mining-Wait "$computers\4\restart-ready.json"
    Copy-Item "$TestRoot\logs\latest.log" "$Output\before-restart.log"
    $paused=@{}
    foreach ($id in 1..3) {
        $p=(Get-Content "$computers\$id\mining-paused.json" -Raw | ConvertFrom-Json).pose
        $paused[$id]=$p
        Rcon "data get block $($p.x) $($p.y) $($p.z)" | Out-Null
    }
    $loaded=Rcon 'execute if loaded 1 65 1 run time query gametime'
    if($loaded -notmatch '^The time is \d+'){throw 'Loaded-chunk query did not return its numeric result.'}
    Rcon 'computercraft shutdown 1 2 3' | Out-Null
    foreach($id in 1..3) {
        $p=$paused[$id]
        Rcon "data remove block $($p.x) $($p.y) $($p.z) RightUpgrade" | Out-Null
    }
    Rcon 'setworldspawn -1000 64 -1000' | Out-Null
    Rcon 'forceload remove all' | Out-Null
    $until=[DateTime]::UtcNow.AddSeconds(90)
    do {
        Start-Sleep -Seconds 2
        $loaded=Rcon 'execute if loaded 1 65 1 run time query gametime'
    } while ($loaded -match '^The time is \d+' -and [DateTime]::UtcNow -lt $until)
    if($loaded -match '^The time is \d+'){throw 'Mining chunk did not unload.'}
    'The active mining chunk unloaded before the server restart.' | Set-Content "$Output\chunk-unload.txt"
    Stop-TestServer
    foreach ($id in 0..4) { [IO.File]::WriteAllText("$computers\$id\boot-hold",'GPS barrier',$utf8) }
    Start-TestServer 'restart'
    Rcon 'forceload add -16 -16 32 16' | Out-Null
    foreach($id in 1..3) {
        $p=$paused[$id]
        Rcon "data modify block $($p.x) $($p.y) $($p.z) RightUpgrade set value `"computercraft:wireless_modem_advanced`"" | Out-Null
    }
    Rcon 'computercraft shutdown 10 11 12 13' | Out-Null
    Start-Sleep -Seconds 1
    Rcon 'computercraft turn-on 10 11 12 13' | Out-Null
    Start-Sleep -Seconds 2
    foreach ($id in 0..4) { Remove-Item -LiteralPath "$computers\$id\boot-hold" }
    Rcon 'computercraft turn-on 0 1 2 3 4 6' | Out-Null
    foreach($id in 1..3) { Mining-Wait "$computers\$id\sandbox-result.json" }
    Rcon 'computercraft shutdown 4' | Out-Null
    Rcon 'computercraft turn-on 4' | Out-Null
    Mining-Wait "$computers\4\sandbox-result.json"
    foreach ($id in 0..4) { Mining-Wait "$computers\$id\sandbox-result.json" }
    $mined=0
    $remaining=0
    $observations=@()
    $positive=Rcon 'execute if block 10 64 5 minecraft:bedrock run time query gametime'
    $negative=Rcon 'execute if block 10 64 5 minecraft:air run time query gametime'
    if($positive -notmatch '^The time is \d+' -or $negative -match '^The time is \d+') {throw 'Block-query positive or negative control failed.'}
    foreach ($position in $finalBlocks.Keys) {
        if ($finalBlocks[$position] -notlike '*_ore') { continue }
        $v=$position.Split(' ')
        $gap=([int]$v[0]%4 -eq 3 -and [int]$v[1] -eq 65 -and [int]$v[2] -eq 6)
        $expected=if($gap){$finalBlocks[$position]}else{'minecraft:air'}
        $response=Rcon "execute if block $position $expected run time query gametime"
        if ($response -notmatch '^The time is \d+') { throw "Expected $expected at $position." }
        if($gap){$remaining++}else{$mined++}
        $observations+=@{position=$position;expected=$expected;ok=$true}
    }
    foreach ($id in 1..3) {
        $x=$id*4-3
        $block=Rcon "data get block $x 65 0"
        if ($block -notmatch "ComputerId:\s*$id(?=[,}\s])") { throw "Turtle $id did not return home." }
    }
    $observations | ConvertTo-Json | Set-Content "$Output\block-observations.json"
    & "$PSScriptRoot\verify-mining.ps1" -Computers $computers -Output $Output
    @{ok=$true;mined=$mined;intentionallyUntouched=$remaining;restart=$true} | ConvertTo-Json | Set-Content "$Output\coverage.json"
    if ($Client) { & "$PSScriptRoot\client.ps1" -TestRoot $TestRoot -Port $port -RconPort $rconPort -Output $Output -View mining -ShotName mining-after.png }
    [IO.File]::WriteAllText("$Output\verdict.txt",'PASS',$utf8)
    Write-Output 'Gate B mining PASS'
} catch {
    [IO.File]::WriteAllText("$Output\verdict.txt","FAIL`n$($_.Exception.Message)",$utf8)
    throw
} finally {
    try { Stop-TestServer } catch { Write-Warning $_ }
    if(Test-Path "$TestRoot\logs\latest.log"){Copy-Item "$TestRoot\logs\latest.log" "$Output\latest.log" -Force}
    Copy-Item $computers "$Output\computers" -Recurse -Force
    Copy-Item "$TestRoot\config" "$Output\configs" -Recurse -Force
}
