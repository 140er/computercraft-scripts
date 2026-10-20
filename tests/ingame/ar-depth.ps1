$depthIds = @(1,2,3,7)
$depthAll = @(0,1,2,3,4,7,20,21,22)
$depthHomes = @{1=17;2=21;3=25;7=29}
$depthChecks = [System.Collections.Generic.List[object]]::new()
$depthSecret = @{}
foreach ($id in @(0,1,2,3,4,7,20,21)) { $depthSecret[$id] = "depth-secret-$id-1234567890" }
if (!$arTestOwnerName -or !$arTestOwnerUUID) { throw 'Depth testing requires the verified native AP player identity.' }
if (!(Get-Variable DepthSoakSeconds -ErrorAction SilentlyContinue)) { $DepthSoakSeconds = 7200 }
function Read-Depth([int]$Id) {
    $text = Read-ArText "$TestRoot\world\computercraft\computer\$Id\ar-depth.json"
    if (!$text) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $null }
}
function Wait-Depth([scriptblock]$Check,[string]$Description,[int]$Seconds=600) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $states = @{}
        foreach ($id in $depthAll) { $states[$id] = Read-Depth $id }
        if (& $Check $states) { return $states }
        if (!(Test-ArServer)) { throw "Depth server exited. $Description" }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $until)
    $states.Values | ConvertTo-Json -Depth 30 | Set-Content "$Output\depth-timeout-$([guid]::NewGuid().ToString('N')).json"
    throw "Depth check timed out. $Description"
}
function Send-DepthRequest([int]$Id,[hashtable]$Request) {
    $Request.id = [guid]::NewGuid().ToString('N')
    Write-ArText "$TestRoot\world\computercraft\computer\$Id\ar-depth-request.json" ($Request | ConvertTo-Json -Depth 12 -Compress)
    return $Request.id
}
function Wait-DepthRequest([int]$Id,[string]$RequestId) {
    $states = Wait-Depth { param($s) $s[$Id] -and $s[$Id].resultId -eq $RequestId } "controller $Id request $RequestId"
    if (!$states[$Id].commandResult.ok) { throw "Controller $Id rejected request. $($states[$Id].commandResult.error)" }
    return $states[$Id].commandResult
}
function DepthCommand([string]$Command,[Nullable[int]]$Target=$null) {
    $request = @{action='command';command=$Command}
    if ($null -ne $Target) { $request.target = [int]$Target }
    $rid = Send-DepthRequest 20 $request
    return Wait-DepthRequest 20 $rid
}
function Check-Depth([string]$Name,[scriptblock]$Action) {
    $started = [DateTime]::UtcNow
    try {
        $value = & $Action
        $depthChecks.Add(@{name=$Name;ok=$true;started=$started.ToString('o');finished=[DateTime]::UtcNow.ToString('o');evidence=$value})
    } catch {
        $depthChecks.Add(@{name=$Name;ok=$false;started=$started.ToString('o');finished=[DateTime]::UtcNow.ToString('o');error=$_.Exception.Message})
        Write-Output "Depth check failed. $Name. $($_.Exception.Message)"
    }
    $depthChecks | ConvertTo-Json -Depth 30 | Set-Content "$Output\depth-checks.json"
}
function Save-Depth([string]$Label) {
    foreach ($id in $depthAll) {
        foreach ($name in @('ar-depth.json','ar-depth-metrics.jsonl','miner.log','server.state','ssot.state','nav.state','mining.state')) {
            Save-ArFile "$TestRoot\world\computercraft\computer\$id\$name" "$Output\depth-$Label-$id-$name"
        }
    }
}
function Invoke-DepthAuth([int]$Id,[string]$Action) {
    $rid=Send-DepthRequest $Id @{action=$Action}
    $result=Wait-DepthRequest $Id $rid
    if($result.packets) {
        $seen=Wait-Depth {param($s)
            foreach($packet in $result.packets) {
                if(!@($s[0].authPackets | Where-Object {
                    $_.probe -eq $packet.probe -and $_.peer -eq $packet.claimedPeer -and (!$packet.after -or $_.at -ge $packet.after)
                }).Count){return $false}
            }
            return $true
        } "production server received every $Action packet from native computer $Id"
        $last=($seen[0].authPackets | Measure-Object at -Maximum).Maximum
        $null=Wait-Depth {param($s) $s[0].time -gt $last} 'production controls sampled after native auth packets'
    }
    $null=Wait-Depth {param($s) $s[0].time -gt $result.completedAt} 'production state sampled after auth action completed'
    return $result
}
function Assert-DepthAuthUnchanged($Before,$After) {
    if($Before.controls.arHub -ne $After.controls.arHub -or $Before.controls.view3D -ne $After.controls.view3D) {
        throw 'Unauthorized native traffic changed AR ownership or visibility.'
    }
    foreach($key in @('P','T','O','A')) {
        if($Before.layers.$key -ne $After.layers.$key){throw "Unauthorized native traffic changed AR layer $key."}
    }
    foreach($key in @('commandSeq','recharges','rechargeRequests')) {
        if(($Before.controls.$key | ConvertTo-Json -Depth 15 -Compress) -ne ($After.controls.$key | ConvertTo-Json -Depth 15 -Compress)) {
            throw "Unauthorized native traffic changed persisted $key."
        }
    }
}
function Measure-DepthOre([string]$Label) {
    $count=0
    $rows=[System.Collections.Generic.List[object]]::new()
    foreach($id in $depthIds) {
        $x=$depthHomes[$id]
        for($z=9;$z -le 72;$z++) {
            $answer=Rcon "execute if block $x 65 $z minecraft:diamond_ore run time query gametime"
            $present=$answer -match '^The time is \d+'
            if($present){$count++}
            $rows.Add(@{x=$x;y=65;z=$z;ore=$present;response=$answer})
        }
    }
    @{count=$count;blocks=$rows} | ConvertTo-Json -Depth 10 | Set-Content "$Output\depth-ore-$Label.json"
    return $count
}
function Measure-DepthInventory([int]$X,[int]$Y,[int]$Z,[string]$Name) {
    $answer=Rcon "data get block $X $Y $Z Items"
    if($answer -notmatch 'has the following block data:\s*\[') {
        throw "Native inventory at $X,$Y,$Z did not return its item list. $answer"
    }
    $items=@{}
    foreach($entry in [regex]::Matches($answer,'\{[^{}]*\}')) {
        $item=[regex]::Match($entry.Value,'\bid:\s*"([^"]+)"')
        $count=[regex]::Match($entry.Value,'\bcount:\s*(\d+)')
        if($item.Success -and $count.Success) {
            $items[$item.Groups[1].Value]+=[int]$count.Groups[1].Value
        }
    }
    if($answer -match 'minecraft:diamond"' -and !$items.ContainsKey('minecraft:diamond')) {
        throw "Native diamond inventory at $X,$Y,$Z could not be counted."
    }
    return @{name=$Name;x=$X;y=$Y;z=$Z;items=$items;response=$answer}
}
$manifest = @(Get-ChildItem "$source\*.lua" | Sort-Object Name | Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash) $([IO.Path]::GetFileName($_.Path))" })
$digest = [Security.Cryptography.SHA256]::Create()
try { $sourceHash = [BitConverter]::ToString($digest.ComputeHash([Text.Encoding]::UTF8.GetBytes(($manifest -join "`n")))).Replace('-','').ToLowerInvariant() }
finally { $digest.Dispose() }
$manifest | Set-Content "$Output\depth-source-sha256.txt"
$arDepthServices,$arDepthSurveys=@{},@{}
if (Test-Path "$PSScriptRoot\ar-recharge.ps1") { . "$PSScriptRoot\ar-recharge.ps1" }
foreach ($id in $depthAll) {
    if (Read-ArText "$TestRoot\world\computercraft\computer\$id\ar-depth-config.json") {
        throw 'Depth fixture already exists. Preserve this attempt and use a fresh test root.'
    }
}
Stop-ArServer
foreach ($id in $depthAll) {
    $disk = "$TestRoot\world\computercraft\computer\$id"
    $role = if ($id -eq 0) {'server'} elseif ($id -eq 4) {'hub'} else {'miner'}
    Copy-ArRole $id $role
    Copy-ArFile "$PSScriptRoot\ar-depth-probe.lua" "$disk\ar-depth-probe.lua"
    Write-ArText "$disk\startup.lua" 'shell.run("ar-depth-probe.lua")'
}
$controllers = (@(foreach ($id in $depthSecret.Keys) { "['$id']='$($depthSecret[$id])'" }) -join ',')
$auth = "{controllers={$controllers},chatNames={'$arTestOwnerName'},chatUUIDs={['$arTestOwnerName']='$arTestOwnerUUID'},arControllers={['4']={name='$arTestOwnerName',uuid='$arTestOwnerUUID'},['20']={name='$arTestOwnerName',uuid='$arTestOwnerUUID'}},maxChunks=64}"
foreach ($id in @(0,4)) {
    $disk = "$TestRoot\world\computercraft\computer\$id"
    Write-ArText "$disk\ssot.cfg" $auth
    Write-ArText "$disk\ar.cfg" "{enabled=true,proHud=true,xrayTurtles=true,xrayOres=true,xrayTunnels=false,ownerName='$arTestOwnerName',ownerUUID='$arTestOwnerUUID',dimension='minecraft:overworld',origin={dim='minecraft:overworld',x=24,y=65,z=32},radius=64,maxCells=128,maxTurtles=32,chatEnabled=true}"
}
$hosts = @(@(-8,70,-8),@(8,70,-8),@(-8,70,8),@(-8,78,-8))
for ($index=0;$index -lt $hosts.Count;$index++) {
    $point=$hosts[$index]
    $disk="$TestRoot\world\computercraft\computer\$($index+10)"
    Write-ArText "$disk\startup.lua" "while not peripheral.find('modem') do sleep(.1) end; shell.run('gps','host','$($point[0])','$($point[1])','$($point[2])')"
}
foreach ($id in @(0,4,20,21,22)) {
    $role = if ($id -eq 0) {'server'} elseif ($id -eq 4) {'hub'} else {'controller'}
    $secret=if($id -eq 22){'unpaired-attacker-1234567890'}else{$depthSecret[$id]}
    $cfg=@{role=$role;spaceLimit=$SpaceLimit;sourceHash=$sourceHash;secret=$secret;
        ownerName=$arTestOwnerName;ownerUUID=$arTestOwnerUUID}
    Write-ArText "$TestRoot\world\computercraft\computer\$id\ar-depth-config.json" ($cfg | ConvertTo-Json -Compress)
}
Start-ArServer 'depth-prepare'
foreach ($command in @('computercraft shutdown 0 1 2 3 4','gamerule spawnChunkRadius 0','setworldspawn -1000 64 -1000',
    'forceload add -16 -16 31 79','fill 16 64 6 31 64 8 minecraft:stone',
    'fill 16 65 6 31 70 8 minecraft:air','fill 16 64 9 31 66 72 minecraft:stone',
    'fill 16 67 9 31 71 72 minecraft:air',
    'setblock 4 65 -3 minecraft:air','setblock 6 65 -3 minecraft:air','setblock 8 65 -3 minecraft:air',
    'setblock -4 66 0 computercraft:computer_advanced{ComputerId:20}',
    'setblock -4 67 0 computercraft:wireless_modem_advanced[facing=down]',
    'setblock -6 66 0 computercraft:computer_advanced{ComputerId:21}',
    'setblock -6 67 0 computercraft:wireless_modem_advanced[facing=down]',
    'setblock -10 66 0 computercraft:computer_advanced{ComputerId:22}',
    'setblock -10 67 0 computercraft:wireless_modem_advanced[facing=down]')) { Rcon $command | Out-Null }
for ($index=0;$index -lt $hosts.Count;$index++) {
    $point=$hosts[$index]
    Rcon "setblock $($point[0]) $($point[1]) $($point[2]) computercraft:computer_advanced{ComputerId:$($index+10)}" | Out-Null
    Rcon "setblock $($point[0]) $($point[1]+1) $($point[2]) computercraft:wireless_modem_advanced[facing=down]" | Out-Null
}
if (Get-Command Initialize-ArRecharge -ErrorAction SilentlyContinue) { Initialize-ArRecharge }
foreach ($id in $depthIds) {
    $x=$depthHomes[$id]
    $service = if ($arDepthServices.ContainsKey($id)) { ",warehouse=$($arDepthServices[$id])" } else {''}
    $miner="{home={x=$x,y=65,z=8},facing=2,spine=2,ssot={enabled=true,server=0,secret='$($depthSecret[$id])',dimension='minecraft:overworld',timeout=5},nav={enabled=true,traffic=true,bounds={min={dim='minecraft:overworld',x=14,y=63,z=-8},max={dim='minecraft:overworld',x=34,y=72,z=79}}},mining={enabled=true,home={dim='minecraft:overworld',x=$x,y=65,z=8,h=2},targets={'minecraft:diamond_ore'}}$service}"
    Write-ArText "$TestRoot\world\computercraft\computer\$id\miner.cfg" $miner
    $cfg=@{role='miner';spaceLimit=$SpaceLimit;sourceHash=$sourceHash;secret=$depthSecret[$id]}
    if ($arDepthSurveys.ContainsKey($id)) { $cfg.surveys=$arDepthSurveys[$id] }
    Write-ArText "$TestRoot\world\computercraft\computer\$id\ar-depth-config.json" ($cfg | ConvertTo-Json -Depth 10 -Compress)
    Rcon "fill $x 65 9 $x 65 72 minecraft:diamond_ore" | Out-Null
    Rcon "setblock $x 65 7 minecraft:chest" | Out-Null
    Rcon "setblock $x 65 8 computercraft:turtle_advanced[facing=south]{ComputerId:$id,Fuel:20000,LeftUpgrade:`"computercraft:wireless_modem_advanced`",RightUpgrade:`"minecraft:diamond_pickaxe`"}" | Out-Null
}
if((Measure-DepthOre 'before') -ne 256){throw 'Native fixture did not contain all 256 diamond ore blocks.'}
$initialInventory=@(foreach($id in $depthIds) { Measure-DepthInventory $depthHomes[$id] 65 8 "turtle-$id" })
foreach($row in $initialInventory){if($row.items.Count){throw 'Native miner inventory was not empty before mining.'}}
@{diamondOreBlocks=256;turtles=$depthIds;homes=$depthHomes;inventory=$initialInventory;zone=@{min=@(16,64,9);max=@(31,66,72)}} |
    ConvertTo-Json -Depth 10 | Set-Content "$Output\depth-world-before.json"
Rcon 'computercraft turn-on 10 11 12 13 0 4 20 21 22' | Out-Null
$null = Wait-Depth {param($s) $s[0].ssot -and $s[20].programRunning -and $s[21].programRunning -and $s[22].programRunning} 'production server and test controllers'
if (Get-Command Register-ArRecharge -ErrorAction SilentlyContinue) { Register-ArRecharge }
$zone=@{min=@{dim='minecraft:overworld';x=16;y=64;z=9};max=@{dim='minecraft:overworld';x=31;y=66;z=72};spacing=4}
$rid=Send-DepthRequest 20 @{action='mine-config';zone=$zone}
$configured=Wait-DepthRequest 20 $rid
if ($configured.count -ne 4) { throw 'Expected four production mining tasks.' }
Rcon 'computercraft turn-on 1 2 3 7' | Out-Null
$null=Wait-Depth {param($s)
    foreach($id in $depthIds){if(!$s[$id].ok -or !$s[$id].surveyed){return $false}}
    return $true
} 'all miners completed native service route surveys' 1200
Check-Depth 'native unauthorized AR and recharge packets leave production controls unchanged' {
    $ready=Wait-Depth {param($s) $s[0].controls.arHub -eq 4 -and $s[0].layers.O -eq $true} 'enrolled hub owns the native AR controller'
    $before=$ready[0]
    $raw=Invoke-DepthAuth 22 'auth-raw'
    $wrongOwner=Invoke-DepthAuth 20 'auth-owner'
    $unowned=Invoke-DepthAuth 21 'auth-owner'
    $null=Wait-Depth {param($s) $s[0].ssot.authCounters.'20' -eq $wrongOwner.counter} 'latest legitimate controller counter was observed'
    $counters=Invoke-DepthAuth 20 'auth-counters'
    $after=Read-Depth 0
    Assert-DepthAuthUnchanged $before $after
    if($after.ssot.authCounters.'20' -ne $wrongOwner.counter){throw 'Malformed native counters changed the authenticated replay counter.'}
    Save-Depth 'auth-rejected'
    @{before=$before.controls;after=$after.controls;raw=$raw;wrongOwner=$wrongOwner;unowned=$unowned;counters=$counters;
        received=$after.authPackets;senderTransport='Computer 22 emits real modem envelopes claiming sender 20; regular rednet.send uses its own ID.'}
}
Check-Depth 'native replay of an authenticated AR layer command cannot undo its replacement' {
    Rcon 'computercraft shutdown 4' | Out-Null
    try {
        $result=Invoke-DepthAuth 20 'auth-ar-replay'
        $null=Wait-Depth {param($s) $s[0].layers.O -eq $true -and $s[0].controls.arCounters.'20' -eq $result.currentCounter} 'restored AR layer and latest counter persisted'
        Save-Depth 'auth-ar-replay'
        $result
    } finally { Rcon 'computercraft turn-on 4' | Out-Null }
}
foreach($id in $depthIds) {
    Write-ArText "$TestRoot\world\computercraft\computer\$id\ar-depth-start.json" '{"start":true}'
}
$ready=Wait-Depth {param($s)
    foreach($id in $depthIds) { if (!$s[$id].ok -or !$s[$id].programRunning -or !$s[$id].pose -or $s[$id].moves -lt 1) { return $false } }
    return $s[0].ssot.cells -gt 0 -and $s[0].reportedOres -gt 0 -and $s[0].arUpdates -gt 0
} 'four real miners populated the shared map'
Save-Depth 'initial'
Check-Depth 'two simultaneous snapshot request streams' {
    $a=Send-DepthRequest 20 @{action='snapshot-burst';chunk='minecraft:overworld|1|4|1';count=32}
    $b=Send-DepthRequest 21 @{action='snapshot-burst';chunk='minecraft:overworld|1|4|1';count=32}
    $left=Wait-DepthRequest 20 $a
    $right=Wait-DepthRequest 21 $b
    if ([Math]::Max($left.started,$right.started) -gt [Math]::Min($left.finished,$right.finished)) { throw 'Snapshot requests did not overlap in time.' }
    @{left=$left;right=$right}
}
Check-Depth 'server restart during production mining' {
    $before=Wait-Depth {param($s) @($s[0].ssot.tasks | Where-Object {$_.status -eq 'active' -and $_.progress -lt 64}).Count -gt 0} 'active task before restart'
    Save-Depth 'before-restart'
    $boot=$before[0].boot
    Stop-ArServer
    Start-ArServer 'depth-restart'
    Rcon 'computercraft turn-on 10 11 12 13 0 4 20 21 1 2 3 7' | Out-Null
    $after=Wait-Depth {param($s)
        if ($s[0].boot -le $boot) {return $false}
        foreach($id in $depthIds) {if (!$s[$id].ok -or !$s[$id].pose) {return $false}}
        return $s[0].ssot.revision -gt $before[0].ssot.revision
    } 'durable map and all miners resumed after restart'
    Save-Depth 'after-restart'
    @{beforeRevision=$before[0].ssot.revision;afterRevision=$after[0].ssot.revision;beforeBoot=$boot;afterBoot=$after[0].boot}
}
Check-Depth 'missing server modem stops movement and recovers after replacement' {
    $moving=@{}; foreach($id in $depthIds){$moving[$id]=Read-Depth $id}
    $null=Wait-Depth {param($s)
        foreach($id in $depthIds){if($s[$id].moves -gt $moving[$id].moves){return $true}}
        return $false
    } 'real mining movement before server modem removal'
    Rcon 'setblock 0 67 0 minecraft:air' | Out-Null
    try {
        Start-Sleep -Seconds 25
        $before=@{}; foreach($id in $depthIds){$before[$id]=Read-Depth $id}
        Start-Sleep -Seconds 10
        $after=@{}; foreach($id in $depthIds){$after[$id]=Read-Depth $id}
        foreach($id in $depthIds){
            if(!$before[$id] -or !$after[$id]){throw "Missing native turtle $id sample during modem outage."}
            if($after[$id].time -le $before[$id].time){throw "Turtle $id stopped producing native samples during the modem outage."}
            if($after[$id].moves -ne $before[$id].moves){throw "Turtle $id moved while the SSOT modem was absent."}
        }
    } finally {
        Rcon 'setblock 0 67 0 computercraft:wireless_modem_advanced[facing=down]' | Out-Null
        Rcon 'computercraft shutdown 0 1 2 3 7' | Out-Null
        Rcon 'computercraft turn-on 0 1 2 3 7' | Out-Null
    }
    $null=Wait-Depth {param($s)
        foreach($id in $depthIds){if(!$s[$id].ok -or $s[$id].boot -le $after[$id].boot){return $false}}
        return $s[0].ssot -ne $null
    } 'rebooted production nodes after replacing missing modem'
    Save-Depth 'modem-restored'
    @{movementDuringAbsence=0;recovery='modem replaced and production computers rebooted'}
}
Check-Depth 'native turtle chunk unload and durable occupancy' {
    $at=Wait-Depth {param($s)
        foreach($id in $depthIds){if($s[$id].pose.z -ge 56){$script:depthUnloadId=$id;return $true}}
        return $false
    } 'a miner reached the distant chunk' 900
    $unloadId=$script:depthUnloadId
    DepthCommand 'estop' | Out-Null
    $stopped=Wait-Depth {param($s)
        foreach($id in $depthIds){if($s[$id].control.kind -ne 'estop'){return $false}}
        return $true
    } 'all native miners stopped before unloading a distant chunk'
    $pose=$stopped[$unloadId].pose
    $loadedBefore=Rcon "execute if loaded $($pose.x) $($pose.y) $($pose.z) run time query gametime"
    if($loadedBefore -notmatch '^The time is \d+'){throw 'Initial native loaded-chunk query failed.'}
    Rcon 'computercraft shutdown 1 2 3 7' | Out-Null
    foreach($id in $depthIds) {
        $p=$stopped[$id].pose
        Rcon "data remove block $($p.x) $($p.y) $($p.z) LeftUpgrade" | Out-Null
    }
    Rcon 'forceload remove 16 16 31 79' | Out-Null
    try {
        $until=[DateTime]::UtcNow.AddSeconds(90)
        do {
            $loaded=Rcon "execute if loaded $($pose.x) $($pose.y) $($pose.z) run time query gametime"
            if($loaded -notmatch '^The time is \d+'){break}
            Start-Sleep -Seconds 2
        } while([DateTime]::UtcNow -lt $until)
        if($loaded -match '^The time is \d+'){throw 'Native chunk did not unload.'}
        Start-Sleep -Seconds 20
        $server=Read-Depth 0
        $saved=$server.ssot.poses."$unloadId"
        if(!$saved -or $saved.x -ne $pose.x -or $saved.y -ne $pose.y -or $saved.z -ne $pose.z){throw 'Unloaded turtle lost its authoritative occupancy.'}
    } finally {
        Rcon 'forceload add 16 16 31 79' | Out-Null
        foreach($id in $depthIds) {
            $p=$stopped[$id].pose
            Rcon "data modify block $($p.x) $($p.y) $($p.z) LeftUpgrade set value `"computercraft:wireless_modem_advanced`"" | Out-Null
        }
        Rcon 'computercraft turn-on 1 2 3 7' | Out-Null
    }
    $null=Wait-Depth {param($s)
        foreach($id in $depthIds){if(!$s[$id].ok -or $s[$id].boot -le $stopped[$id].boot){return $false}}
        return $s[$unloadId].time -gt $server.time
    } 'turtles ticked after real chunk reload'
    DepthCommand 'go' | Out-Null
    Save-Depth 'chunk-reloaded'
    @{turtle=$unloadId;pose=$pose;unloaded=$true;occupancyRetained=$true;loadedResponse=$loadedBefore;unloadedResponse=$loaded}
}
$arCaptureCamera = @{x=24;y=69;z=-4;yaw=0;pitch=10}
Check-Depth 'real client F2 screenshot and video of the production fleet' {
    if (!(Get-Command Invoke-ArCapture -ErrorAction SilentlyContinue)) { throw 'Real client capture is unavailable.' }
    Invoke-ArCapture 'ar-production'
    foreach ($file in @('ar-production.png','ar-production.mp4')) {
        if (!(Test-Path "$Output\$file") -or (Get-Item "$Output\$file").Length -eq 0) {
            throw "Real client capture is missing $file."
        }
    }
    @{screenshot='ar-production.png';video='ar-production.mp4'}
}
DepthCommand 'go' | Out-Null
if (Get-Command Invoke-ArRechargeChecks -ErrorAction SilentlyContinue) {
    Check-Depth 'native recall and recharge' { Invoke-ArRechargeChecks }
}
Check-Depth 'native replay of an accepted recharge creates no new delivery or movement command' {
    $before=Read-Depth 0
    $miners=@{};foreach($id in $depthIds){$miners[$id]=Read-Depth $id}
    $result=Invoke-DepthAuth 20 'auth-recharge-replay'
    $null=Wait-Depth {param($s)
        if($s[0].time -lt $result.completedAt+5000){return $false}
        foreach($id in $depthIds){if($s[$id].time -lt $result.completedAt+5000){return $false}}
        return $true
    } 'fresh production server and miner observations after recharge replay'
    $after=Read-Depth 0
    foreach($key in @('commandSeq','recharges','rechargeRequests')) {
        if(($before.controls.$key | ConvertTo-Json -Depth 15 -Compress) -ne ($after.controls.$key | ConvertTo-Json -Depth 15 -Compress)){
            throw "Native replay changed persisted $key."
        }
    }
    foreach($id in $depthIds) {
        $now=Read-Depth $id
        if($now.control.rechargeId -ne $miners[$id].control.rechargeId){throw "Native replay changed turtle $id recharge receipt."}
    }
    Save-Depth 'auth-recharge-replay'
    @{before=$before.controls;after=$after.controls;request=$result}
}
DepthCommand 'go' | Out-Null
Check-Depth 'four production turtles two-hour soak' {
    $deadline=[DateTime]::UtcNow.AddSeconds([Math]::Max(10800,$DepthSoakSeconds+1800))
    $target=[int64]$DepthSoakSeconds*1000
    do {
        $complete=$true
        foreach($id in $depthIds){
            $row=Read-Depth $id
            if(!$row -or !$row.ok -or !$row.programRunning){throw "Production turtle $id stopped during soak."}
            if([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-$row.time -gt 15000){throw "Production turtle $id stopped sampling during soak."}
            if($row.sourceHash -ne $sourceHash){throw "Turtle $id soak evidence belongs to different source."}
            if($row.activeMs -lt $target){$complete=$false}
        }
        $server=Read-Depth 0
        if(!$server.ok -or !$server.ssot){throw 'Production server stopped during soak.'}
        if([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()-$server.time -gt 15000){throw 'Production server stopped sampling during soak.'}
        Save-ArFile "$TestRoot\world\computercraft\computer\0\ar-depth.json" "$Output\depth-soak-progress.json"
        if($complete){break}
        Write-Output "AR depth soak active. Required seconds=$DepthSoakSeconds. Last sampled turtle active seconds=$([math]::Floor($row.activeMs/1000))."
        Start-Sleep -Seconds 30
    } while([DateTime]::UtcNow -lt $deadline)
    if(!$complete){throw 'Four-turtle soak did not reach its required active duration.'}
    Save-Depth 'soak'
    if($DepthSoakSeconds -lt 7200){throw 'Short diagnostic soak does not satisfy the two-hour gate.'}
    @{secondsPerTurtle=$DepthSoakSeconds;turtles=$depthIds;sourceHash=$sourceHash;workload='production mining, then idle heartbeats after tasks complete'}
}
Check-Depth 'all four mining tasks finish and conserve 256 diamonds' {
    $done=Wait-Depth {param($s)
        $tasks=@($s[0].ssot.tasks)
        return $tasks.Count -eq 4 -and @($tasks | Where-Object {$_.status -ne 'done' -or $_.progress -ne 64}).Count -eq 0
    } 'all four production mining tasks completed' 600
    DepthCommand 'estop' | Out-Null
    $stopped=Wait-Depth {param($s)
        foreach($id in $depthIds){if($s[$id].control.kind -ne 'estop'){return $false}}
        return $true
    } 'all inventories stopped before conservation count'
    $rows=@(foreach($id in $depthIds) {
        $p=$stopped[$id].pose
        Measure-DepthInventory $p.x $p.y $p.z "turtle-$id"
        Measure-DepthInventory $depthHomes[$id] 65 7 "home-chest-$id"
        if($arDepthServices.ContainsKey($id)){Measure-DepthInventory $depthHomes[$id] 65 5 "drop-chest-$id"}
    })
    $diamonds=0
    foreach($row in $rows){$diamonds+=[int]$row.items['minecraft:diamond']}
    $remaining=Measure-DepthOre 'after'
    @{diamonds=$diamonds;remainingOre=$remaining;inventories=$rows;tasks=$done[0].ssot.tasks} |
        ConvertTo-Json -Depth 15 | Set-Content "$Output\depth-inventory-after.json"
    if($diamonds -ne 256 -or $remaining -ne 0){throw "Native ore conservation failed. Diamonds=$diamonds, remaining ore=$remaining."}
    @{diamondOreBefore=256;diamondOreAfter=$remaining;diamondsAfter=$diamonds}
}
Save-Depth 'final'
@{ok=(@($depthChecks | Where-Object {!$_.ok}).Count -eq 0);sourceHash=$sourceHash;checks=$depthChecks;
    limits=@('Wearer removal detection is absent from cc_ar 0.2.1','Through-wall rendering is absent from cc_ar 0.2.1')} |
    ConvertTo-Json -Depth 30 | Set-Content "$Output\depth-result.json"
if (@($depthChecks | Where-Object {!$_.ok}).Count) { throw 'Native AR depth checks failed. See depth-result.json.' }
