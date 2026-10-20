param(
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$Output,
    [Parameter(Mandatory)][string]$TestRoot
)
$ErrorActionPreference = 'Stop'
. C:\Work\gemini-input\gateb\gateb.ps1
New-Item -ItemType Directory -Force $Output,$TestRoot | Out-Null
Invoke-GatebRcon $RunId @(
    'fill 0 -59 1 4 -57 1 computercraft:monitor_advanced[facing=south]',
    'time set day','weather clear','gamerule doDaylightCycle false',
    'setblock 25 -59 0 superbwarfare:charging_station',
    'item replace block 25 -59 0 container.0 with minecraft:coal_block 64'
) -Log "$Output\scene-rcon.txt" | Out-Null
[IO.File]::WriteAllText("$TestRoot\p0-run-id.txt", $RunId)
Enter-GatebClientLock 'p0'
try {
    $local = Connect-GatebLocal $RunId $TestRoot
    & "$PSScriptRoot\..\ingame\client.ps1" -TestRoot $TestRoot -Port $local.Port -RconPort $local.RconPort -Output $Output -View p0 -Timeout 1800
} finally {
    Disconnect-GatebLocal $TestRoot
    Exit-GatebClientLock
}
