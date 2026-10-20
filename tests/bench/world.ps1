param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$Output)
$ErrorActionPreference = 'Stop'
. C:\Work\gemini-input\gateb\gateb.ps1
. "$PSScriptRoot\box-probe.ps1"
New-Item -ItemType Directory -Force $Output | Out-Null
Wait-GatebFile $RunId 'world/computercraft/computer/0/initial-complete' 900 | Out-Null
function Rcon([string[]]$Commands) { Invoke-GatebRcon $RunId $Commands -Log "$Output\rcon.txt" }
function Probe([int]$Computer,[string]$Name,[string]$Operation,[hashtable]$Arguments=@{}) {
    Invoke-P0Probe -RunId $RunId -Computer $Computer -Name $Name -Probe $Operation -Arguments $Arguments -Output $Output
}
foreach ($computer in 0..6) {
    foreach ($file in @('world.lua','probe.lua','crypto.lua','randomness.lua')) {
        Send-GatebFile $RunId "$PSScriptRoot\$file" "world/computercraft/computer/$computer/$file"
    }
}
Rcon @('computercraft shutdown 0 1 2 3 4 5 6','computercraft turn-on 0 1 2 3 4 5 6') | Out-Null
Start-Sleep -Seconds 2
Probe 0 'peripherals' 'peripherals' | Out-Null
Probe 1 'turtle-peripherals' 'peripherals' | Out-Null
Probe 1 'fuel-normal' 'fuel' | Out-Null
Probe 6 'fuel-charging' 'fuel' @{pause=.5} | Out-Null
Rcon @('setblock 25 -59 0 minecraft:air') | Out-Null
Probe 6 'fuel-without-charger' 'fuel' @{pause=.5} | Out-Null
foreach ($upgrade in @('automata','netherite_end_automata','starbound_end_automata','creative_end_automata','chunk_vial')) {
    Rcon @(
        'computercraft shutdown 3','setblock 8 -59 0 minecraft:air',
        ('setblock 8 -59 0 computercraft:turtle_advanced[facing=north]{ComputerId:3,Fuel:1000,LeftUpgrade:"turtlematic:'+$upgrade+'",RightUpgrade:"computercraft:wireless_modem_normal"}'),
        'computercraft turn-on 3'
    ) | Out-Null
    Start-Sleep -Seconds 2
    Probe 3 "upgrade-$upgrade" 'peripherals' | Out-Null
    Probe 3 "fuel-$upgrade" 'fuel' | Out-Null
}
foreach ($level in @(0,1,7,15)) {
    Probe 1 "analog-output-$level" 'analog' @{side='right';output=$level} | Out-Null
    Probe 2 "analog-input-$level" 'analog' @{side='left'} | Out-Null
}
Rcon @('gamerule doDaylightCycle false','time set 1000') | Out-Null
Probe 0 'clock-frozen-1000' 'clock' | Out-Null
Rcon @('time set 6000') | Out-Null
Probe 0 'clock-jump-6000' 'clock' | Out-Null
Rcon @('time set 500','gamerule doDaylightCycle true') | Out-Null
Probe 0 'clock-running-500' 'clock' | Out-Null
Rcon @('gamerule doDaylightCycle false') | Out-Null
Probe 0 'ender-send' 'send' @{tag='ender-512'} | Out-Null
Probe 4 'ender-received' 'received' | Out-Null
Rcon @('setblock 0 -58 0 computercraft:wireless_modem_normal[facing=down]') | Out-Null
Probe 0 'normal-listen' 'listen' | Out-Null
Probe 0 'normal-send' 'send' @{tag='normal-512'} | Out-Null
Probe 4 'normal-received' 'received' | Out-Null
Rcon @('setblock 0 -58 0 computercraft:wireless_modem_advanced[facing=down]') | Out-Null
Probe 0 'ender-listen' 'listen' | Out-Null
Rcon @(
    'computercraft shutdown 4','setblock 512 -59 0 minecraft:air',
    'execute in minecraft:the_nether run forceload add 512 0',
    'execute in minecraft:the_nether run setblock 512 64 0 computercraft:turtle_advanced{ComputerId:4,Fuel:1000,RightUpgrade:"computercraft:wireless_modem_normal"}',
    'computercraft turn-on 4'
) | Out-Null
Start-Sleep -Seconds 2
Probe 0 'ender-crossdim-send' 'send' @{tag='ender-crossdim'} | Out-Null
Probe 4 'ender-crossdim-received' 'received' | Out-Null
$before = Get-GatebText $RunId 'world/computercraft/computer/5/results/boot.json'
[IO.File]::WriteAllText("$Output\unload-boot-before.json", $before)
Rcon @('forceload remove 1024 0') | Out-Null
$quiet = 0
for ($attempt = 0; $attempt -lt 60; $attempt++) {
    $loaded = Rcon @('execute if loaded 1024 -59 0 run time query gametime')
    if ($loaded -notmatch 'The time is') { $quiet++ } else { $quiet=0 }
    if ($quiet -ge 3) { break }
    Start-Sleep -Seconds 2
}
$heartbeat = Get-GatebText $RunId 'world/computercraft/computer/5/heartbeat.json'
Start-Sleep -Seconds 3
$afterHeartbeat = Get-GatebText $RunId 'world/computercraft/computer/5/heartbeat.json'
if (!$heartbeat -or !$afterHeartbeat) { throw 'Missing heartbeat during chunk-unload measurement.' }
@{quietQueries=$quiet; heartbeatStopped=$heartbeat -eq $afterHeartbeat; before=$heartbeat; after=$afterHeartbeat} |
    ConvertTo-Json | Set-Content "$Output\unload.json"
Rcon @('forceload add 1024 0') | Out-Null
Start-Sleep -Seconds 3
$after = Get-GatebText $RunId 'world/computercraft/computer/5/results/boot.json'
[IO.File]::WriteAllText("$Output\unload-boot-after.json", $after)
Save-GatebDir $RunId 'world/computercraft/computer' $Output
Save-GatebDir $RunId 'logs' $Output
[IO.File]::WriteAllText("$Output\jar-sha256.txt", (Get-GatebText $RunId 'jar-sha256.txt'))
Write-Output 'World measurements saved.'
