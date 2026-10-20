$ErrorActionPreference='Stop'
$computers="$TestRoot\world\computercraft\computer"
function Warehouse-Wait([string]$Path) {
    $until=[DateTime]::UtcNow.AddSeconds($Timeout)
    do {
        if((Test-Path "$computers\3\mine-ready.json") -and !(Test-Path "$computers\3\mine-installed")) {
            Rcon 'setblock 9 65 1 minecraft:diamond_ore' | Out-Null
            Rcon 'setblock 10 65 1 minecraft:diamond_ore' | Out-Null
            [IO.File]::WriteAllText("$computers\3\mine-installed",'ready',$utf8)
        }
        $failed=@(Get-ChildItem $computers -Recurse -Filter sandbox-result.json | ForEach-Object {Get-Content $_.FullName -Raw | ConvertFrom-Json} | Where-Object {!$_.ok})
        if($failed){throw ($failed.errors -join '; ')}
        if(Test-Path $Path){return}
        if($script:process.HasExited){throw 'Minecraft exited during the warehouse scenario.'}
        Start-Sleep -Milliseconds 500
    } while([DateTime]::UtcNow -lt $until)
    throw "Warehouse timeout waiting for $Path."
}
function Charge-Probe([string]$Mode,[int]$X,[int]$Y,[int]$Z,[bool]$Expected) {
    $disk="$computers\20"
    New-Item -ItemType Directory -Force -Path $disk | Out-Null
    Copy-Item "$PSScriptRoot\charge-probe.lua" "$disk\startup.lua" -Force
    [IO.File]::WriteAllText("$disk\probe-mode",$Mode,$utf8)
    if($script:probePosition){Rcon "setblock $script:probePosition minecraft:air" | Out-Null}
    $script:probePosition="$X $Y $Z"
    Rcon "setblock $X $Y $Z computercraft:turtle_advanced{ComputerId:20,Fuel:100,RightUpgrade:`"computercraft:wireless_modem_advanced`"}" | Out-Null
    Rcon 'computercraft turn-on 20' | Out-Null
    Warehouse-Wait "$disk\charge-$Mode.json"
    $r=Get-Content "$disk\charge-$Mode.json" -Raw | ConvertFrom-Json
    Copy-Item "$disk\charge-$Mode.json" "$Output\charge-$Mode.json"
    if(($r.after -gt $r.before) -ne $Expected){throw "Charging range probe $Mode expected rise=$Expected but measured $($r.before) to $($r.after)."}
    Rcon 'computercraft shutdown 20' | Out-Null
    Rcon "data get block $X $Y $Z" | Out-Null
}
function Inventory-Count([int]$X,[int]$Z,[string]$Item,[int]$Count) {
    if($Item -eq 'minecraft:diamond_pickaxe') {
        $text=Rcon "execute if items block $X 65 $Z container.* $Item"
        if($text -notmatch "count:\s*$Count\s*$"){throw "Inventory at $X,65,$Z expected $Count nonstackable tools. Received $text"}
        return
    }
    $text=Rcon "data get block $X 65 $Z Items[{id:`"$Item`"}].count"
    if($text -notmatch ": $Count\s*$"){throw "Inventory at $X,65,$Z expected $Count $Item. Received $text"}
}
try {
    if(!$ResumeProbes) {
    Start-TestServer 'first'
    foreach($cmd in @('forceload add -16 -16 16 16','gamerule spawnChunkRadius 0',
        'fill -1 64 -5 13 66 10 minecraft:bedrock','fill 0 65 -4 12 65 4 minecraft:air',
        'fill 0 65 8 10 65 8 minecraft:air','fill 0 65 5 0 65 7 minecraft:air','fill 10 65 5 10 65 7 minecraft:air',
        'setblock 7 65 9 minecraft:air','setblock -4 65 -4 computercraft:computer_advanced{ComputerId:0}',
        'setblock -4 66 -4 computercraft:wireless_modem_advanced[facing=down]',
        'setblock -3 65 -4 computercraft:turtle_advanced{ComputerId:21,Fuel:100,RightUpgrade:"computercraft:wireless_modem_advanced"}',
        'setblock 14 65 -4 computercraft:computer_advanced{ComputerId:4}','setblock 14 66 -4 computercraft:wireless_modem_advanced[facing=down]',
        'setblock 6 65 -11 superbwarfare:charging_station','item replace block 6 65 -11 container.0 with minecraft:coal_block 64')) {Rcon $cmd | Out-Null}
    Rcon 'data get block 6 65 -11' | Out-Null
    for($id=1;$id -le 3;$id++) {
        $x=$id*4-3
        $fuel=if($id -eq 2){35}else{500}
        foreach($cmd in @("setblock $x 65 -1 minecraft:barrel","setblock $x 65 5 minecraft:chest",
            "item replace block $x 65 -1 container.0 with minecraft:dirt 7","item replace block $x 65 -1 container.1 with minecraft:iron_ingot 11",
            "item replace block $x 65 -1 container.2 with minecraft:diamond_pickaxe",
            "setblock $x 65 0 computercraft:turtle_advanced[facing=north]{ComputerId:$id,Fuel:$fuel,LeftUpgrade:`"minecraft:diamond_pickaxe`",RightUpgrade:`"computercraft:wireless_modem_advanced`"}")) {Rcon $cmd | Out-Null}
    }
    for($i=0;$i -lt $hosts.Count;$i++) {
        $p=$hosts[$i]
        Rcon "setblock $($p[0]) $($p[1]) $($p[2]) computercraft:computer_advanced{ComputerId:$($i+10)}" | Out-Null
        Rcon "setblock $($p[0]) $($p[1]+1) $($p[2]) computercraft:wireless_modem_normal[facing=down]" | Out-Null
    }
    Rcon 'computercraft turn-on 10 11 12 13' | Out-Null
    Start-Sleep -Seconds 2
    Rcon 'computercraft turn-on 0 1 2 3 4 21' | Out-Null
    Warehouse-Wait "$computers\4\restart-ready.json"
    Copy-Item "$TestRoot\logs\latest.log" "$Output\before-restart.log"
    foreach($id in 1..3) {$p=(Get-Content "$computers\$id\warehouse-paused.json" -Raw | ConvertFrom-Json).pose; Rcon "data get block $($p.x) $($p.y) $($p.z)" | Out-Null}
    Stop-TestServer
    foreach($id in 0..4) {[IO.File]::WriteAllText("$computers\$id\boot-hold",'waiting for GPS',$utf8)}
    Start-TestServer 'restart'
    Rcon 'computercraft shutdown 10 11 12 13' | Out-Null
    Rcon 'computercraft turn-on 10 11 12 13' | Out-Null
    Start-Sleep -Seconds 2
    foreach($id in 0..4) {Remove-Item -LiteralPath "$computers\$id\boot-hold"}
    Rcon 'computercraft turn-on 0 1 2 3 4' | Out-Null
    Warehouse-Wait "$computers\4\sandbox-result.json"
    foreach($id in 0..4){Warehouse-Wait "$computers\$id\sandbox-result.json"}
    & "$PSScriptRoot\verify-warehouse.ps1" -Computers $computers -Output $Output
    } else {
        Start-TestServer 'resume-probes'
        Rcon 'forceload add -16 -16 16 16' | Out-Null
        foreach($position in @('40 65 40','40 65 41','48 65 40','48 65 41','48 73 40','40 73 32','47 65 32','48 65 32','503 65 512','495 65 512')) {
            Rcon "setblock $position minecraft:air" | Out-Null
        }
    }
    foreach($id in 1..3) {
        $x=$id*4-3
        Rcon "data get block $x 65 -1 Items" | Out-Null
        Rcon "data get block $x 65 5 Items" | Out-Null
        Inventory-Count $x -1 'minecraft:dirt' 7
        $p=(Get-Content "$computers\$id\sandbox-result.json" -Raw | ConvertFrom-Json).pose
        $block=Rcon "data get block $($p.x) $($p.y) $($p.z)"
        if($block -notmatch "ComputerId:\s*$id(?=[,}\s])"){throw "Turtle $id is missing at its reported pose."}
    }
    Inventory-Count 1 5 'minecraft:iron_ingot' 33
    Inventory-Count 1 5 'minecraft:diamond_pickaxe' 3
    Inventory-Count 9 5 'minecraft:diamond' 2
    Rcon 'forceload add 32 16 63 63' | Out-Null
    Rcon 'setblock 40 65 32 superbwarfare:charging_station' | Out-Null
    Rcon 'item replace block 40 65 32 container.0 with minecraft:coal_block 64' | Out-Null
    Rcon 'data get block 40 65 32' | Out-Null
    Charge-Probe 'axis8' 40 65 40 $true
    Charge-Probe 'axis9' 40 65 41 $false
    Charge-Probe 'diagonal8' 48 65 40 $true
    Charge-Probe 'diagonal9' 48 65 41 $false
    Charge-Probe 'corner8' 48 73 40 $true
    Charge-Probe 'vertical8' 40 73 32 $true
    Rcon 'setblock 40 65 32 minecraft:air' | Out-Null
    Rcon 'setblock 40 65 32 superbwarfare:charging_station' | Out-Null
    Rcon 'item replace block 40 65 32 container.0 with minecraft:air' | Out-Null
    Rcon 'data merge block 40 65 32 {Energy:0}' | Out-Null
    Charge-Probe 'empty' 40 65 40 $false
    Rcon 'setblock 40 65 32 minecraft:air' | Out-Null
    Charge-Probe 'broken' 40 65 40 $false
    Rcon 'setblock 40 65 32 superbwarfare:charging_station' | Out-Null
    Rcon 'item replace block 40 65 32 container.0 with minecraft:coal_block 64' | Out-Null
    Rcon "setblock $script:probePosition minecraft:air" | Out-Null
    Rcon 'setblock 47 65 32 computercraft:turtle_advanced[facing=east]{ComputerId:20,Fuel:100,RightUpgrade:"computercraft:wireless_modem_advanced"}' | Out-Null
    [IO.File]::WriteAllText("$computers\20\probe-mode",'loader',$utf8)
    Rcon 'computercraft turn-on 20' | Out-Null
    Warehouse-Wait "$computers\20\loader-ready.json"
    Rcon 'setworldspawn -1000 64 -1000' | Out-Null
    Rcon 'forceload remove all' | Out-Null
    $players=Rcon 'list'
    if($players -notmatch 'There are 0 of'){throw 'Loader evidence requires no players online.'}
    $heartbeatBefore=(Get-Content "$computers\21\heartbeat.json" -Raw | ConvertFrom-Json).at
    Start-Sleep -Seconds 15
    foreach($position in @('40 65 32','47 65 32','-4 65 -4')) {
        $loaded=Rcon "execute if loaded $position run data get block $position"
        if($loaded -notmatch 'has the following block data'){throw "Required loader chunk stopped ticking at $position."}
    }
    $heartbeatAfter=(Get-Content "$computers\21\heartbeat.json" -Raw | ConvertFrom-Json).at
    if($heartbeatAfter -le $heartbeatBefore){throw 'The server chunk guardian stopped ticking without a player.'}
    @{ok=$true;guardian=21;before=$heartbeatBefore;after=$heartbeatAfter;players=0} | ConvertTo-Json | Set-Content "$Output\server-loader.json"
    [IO.File]::WriteAllText("$computers\20\loader-go",'ready',$utf8)
    Warehouse-Wait "$computers\20\charge-loader.json"
    $loaded=Rcon 'execute if loaded 48 65 32 run data get block 48 65 32'
    if($loaded -notmatch 'ComputerId:\s*20(?=[,}\s])'){throw 'The loader turtle did not cross the chunk boundary.'}
    $charge=Get-Content "$computers\20\charge-loader.json" -Raw | ConvertFrom-Json
    if($charge.after -le $charge.before){throw 'The loader did not keep the required station ticking after movement.'}
    Copy-Item "$computers\20\charge-loader.json" "$Output\charge-loader.json"
    Rcon 'computercraft shutdown 20' | Out-Null
    Rcon 'setblock 48 65 32 minecraft:air' | Out-Null
    Rcon 'setblock 40 65 32 minecraft:air' | Out-Null
    Rcon 'forceload add 480 512 511 527' | Out-Null
    Rcon 'setblock 495 65 512 superbwarfare:charging_station' | Out-Null
    Rcon 'item replace block 495 65 512 container.0 with minecraft:coal_block 64' | Out-Null
    Rcon 'setblock 503 65 512 computercraft:turtle_advanced{ComputerId:20,Fuel:100,RightUpgrade:"computercraft:wireless_modem_normal"}' | Out-Null
    [IO.File]::WriteAllText("$computers\20\probe-mode",'unload',$utf8)
    Rcon 'computercraft turn-on 20' | Out-Null
    Warehouse-Wait "$computers\20\unload-ready.json"
    $warm=Get-Content "$computers\20\unload-ready.json" -Raw | ConvertFrom-Json
    if($warm.warm -le $warm.initial){throw 'The station did not charge before unloading.'}
    Copy-Item "$computers\20\unload-ready.json" "$Output\unload-before.json"
    Rcon 'computercraft shutdown 20' | Out-Null
    Rcon 'data remove block 503 65 512 RightUpgrade' | Out-Null
    Rcon 'forceload remove all' | Out-Null
    Copy-Item "$TestRoot\logs\latest.log" "$Output\before-station-unload-restart.log"
    Stop-TestServer
    Start-TestServer 'station-unload'
    Rcon 'forceload remove 503 512' | Out-Null
    Rcon 'forceload remove 495 512' | Out-Null
    $until=[DateTime]::UtcNow.AddSeconds(120)
    $quiet=0
    do {
        $station=Rcon 'execute if loaded 495 65 512 run time query gametime'
        $turtle=Rcon 'execute if loaded 503 65 512 run time query gametime'
        if($station -notmatch '^The time is \d+' -and $turtle -notmatch '^The time is \d+'){$quiet++}else{$quiet=0}
        if($quiet -ge 6){break}
        Start-Sleep -Seconds 2
    } while([DateTime]::UtcNow -lt $until)
    if($quiet -lt 6){throw 'The isolated station and turtle chunks did not unload.'}
    $heartbeatBefore=(Get-Content "$computers\20\unload-heartbeat.json" -Raw | ConvertFrom-Json).at
    [IO.File]::WriteAllText("$computers\20\unload-go",'ready',$utf8)
    Start-Sleep -Seconds 3
    $heartbeatAfter=(Get-Content "$computers\20\unload-heartbeat.json" -Raw | ConvertFrom-Json).at
    if($heartbeatBefore -ne $heartbeatAfter -or (Test-Path "$computers\20\charge-unload.json")){throw 'The isolated turtle kept executing while its chunk was unloaded.'}
    @{ok=$true;station='495 65 512';turtle='503 65 512';before=$heartbeatBefore;after=$heartbeatAfter;quietQueries=$quiet} | ConvertTo-Json | Set-Content "$Output\station-unload.json"
    Rcon 'forceload add 480 512 511 527' | Out-Null
    Rcon 'computercraft turn-on 20' | Out-Null
    Warehouse-Wait "$computers\20\charge-unload.json"
    $unloaded=Get-Content "$computers\20\charge-unload.json" -Raw | ConvertFrom-Json
    if($unloaded.after -le $unloaded.before){throw 'Charging did not resume after the station chunk reloaded.'}
    Copy-Item "$computers\20\charge-unload.json" $Output
    Rcon 'computercraft shutdown 20' | Out-Null
    [IO.File]::WriteAllText("$computers\20\probe-mode",'interruption',$utf8)
    Rcon 'computercraft turn-on 20' | Out-Null
    Warehouse-Wait "$computers\20\interruption-ready.json"
    Rcon 'setblock 495 65 512 minecraft:air' | Out-Null
    [IO.File]::WriteAllText("$computers\20\interruption-go",'ready',$utf8)
    Warehouse-Wait "$computers\20\charge-interruption.json"
    $interrupted=Get-Content "$computers\20\charge-interruption.json" -Raw | ConvertFrom-Json
    if($interrupted.after -ne $interrupted.before){throw 'Charging continued after the station broke.'}
    Copy-Item "$computers\20\charge-interruption.json", "$computers\20\interruption-ready.json" $Output
    Rcon 'setblock 503 65 512 minecraft:air' | Out-Null
    Rcon 'forceload add -16 -16 16 16' | Out-Null
    & "$PSScriptRoot\verify-warehouse.ps1" -Computers $computers -Output $Output
    if($Client){
        Rcon 'fill -1 66 -5 13 66 10 minecraft:air' | Out-Null
        & "$PSScriptRoot\client.ps1" -TestRoot $TestRoot -Port $port -RconPort $rconPort -Output $Output -View warehouse -ShotName warehouse.png
    }
    [IO.File]::WriteAllText("$Output\verdict.txt",'PASS',$utf8)
    Write-Output 'Gate B warehouse PASS'
} catch {
    [IO.File]::WriteAllText("$Output\verdict.txt","FAIL`n$($_.Exception.Message)",$utf8)
    throw
} finally {
    try {Stop-TestServer} catch {Write-Warning $_}
    if(Test-Path "$TestRoot\logs\latest.log"){Copy-Item "$TestRoot\logs\latest.log" "$Output\latest.log" -Force}
    New-Item -ItemType Directory -Force -Path "$Output\computers" | Out-Null
    Copy-Item "$computers\*" "$Output\computers" -Recurse -Force
    Copy-Item "$TestRoot\config" "$Output\configs" -Recurse -Force
}
