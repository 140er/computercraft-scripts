param(
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$Output
)
$ErrorActionPreference = 'Stop'
. C:\Work\gemini-input\gateb\gateb.ps1
New-Item -ItemType Directory -Force -Path $Output | Out-Null
& "$PSScriptRoot\prepare.ps1" -Computers "$Output\stage\computercraft\computer" -Ids @(0,1,2,3,4,5,6)
Send-GatebDir $RunId "$Output\stage\computercraft" 'world'
$commands = @(
    'gamerule spawnChunkRadius 0',
    'gamerule doDaylightCycle false',
    'time set day',
    'forceload add -16 -16 31 15',
    'forceload add 512 0',
    'forceload add 1024 0',
    'fill -2 -60 -5 28 -60 5 minecraft:stone_bricks',
    'setblock 0 -59 0 computercraft:computer_advanced{ComputerId:0}',
    'setblock 0 -58 0 computercraft:wireless_modem_advanced[facing=down]',
    'setblock -1 -59 0 advancedperipherals:player_detector',
    'setblock 1 -59 0 classicperipherals:cryptographic_accelerator',
    'setblock 0 -59 -1 cc_ar:ar_controller',
    'setblock 4 -59 0 computercraft:turtle_advanced[facing=north]{ComputerId:1,Fuel:1000,RightUpgrade:"computercraft:wireless_modem_normal"}',
    'setblock 5 -59 0 computercraft:turtle_advanced[facing=north]{ComputerId:2,Fuel:1000}',
    'setblock 8 -59 0 computercraft:turtle_advanced[facing=north]{ComputerId:3,Fuel:1000}',
    'setblock 512 -59 0 computercraft:turtle_advanced[facing=north]{ComputerId:4,Fuel:1000,RightUpgrade:"computercraft:wireless_modem_normal"}',
    'setblock 1024 -59 0 computercraft:turtle_advanced[facing=north]{ComputerId:5,Fuel:1000,RightUpgrade:"computercraft:wireless_modem_normal"}',
    'setblock 24 -59 0 computercraft:turtle_advanced[facing=north]{ComputerId:6,Fuel:100}',
    'setblock 25 -59 0 superbwarfare:charging_station',
    'item replace block 25 -59 0 container.0 with minecraft:coal_block 64',
    'computercraft turn-on 0 1 2 3 4 5 6'
)
Invoke-GatebRcon $RunId $commands -Log "$Output\rcon.txt"
Write-Output "P0 probes started on disposable box run $RunId."
