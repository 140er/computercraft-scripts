param([string]$Computers,[string]$Output)
$ErrorActionPreference='Stop'
if ($Output) { New-Item -ItemType Directory -Force -Path $Output | Out-Null }
foreach ($id in @(0,1,2,3,4,6)) {
    $result=Get-Content "$Computers\$id\sandbox-result.json" -Raw | ConvertFrom-Json
    if(!$result.ok){throw "Computer $id failed."}
}
$fuel=Get-Content "$Computers\2\sandbox-result.json" -Raw | ConvertFrom-Json
$inventory=Get-Content "$Computers\3\sandbox-result.json" -Raw | ConvertFrom-Json
if(!$fuel.fuelInterrupt -or !$inventory.inventoryInterrupt){throw 'Missing real service interrupts.'}
$expected=@(0,12,22,12)
foreach ($id in 1..3) {
    $result=Get-Content "$Computers\$id\sandbox-result.json" -Raw | ConvertFrom-Json
    $diamond=0
    foreach($item in $result.inventory){
        if($item.name -in @('minecraft:diamond','minecraft:diamond_ore','minecraft:deepslate_diamond_ore')){$diamond+=$item.count}
    }
    if($diamond -ne $expected[$id]){throw "Turtle $id collected $diamond diamonds, expected $($expected[$id])."}
}
$root=[IO.Path]::GetFullPath("$Computers\0").Replace('\','/')
$helper=[IO.Path]::GetFullPath("$PSScriptRoot\read-ssot.lua").Replace('\','/')
$check="local control, map = dofile([[$helper]])([[$root]]); assert(control and next(control.moves)==nil); assert(map and #map.mining.tasks==3); for i,t in ipairs(map.mining.tasks) do assert(t.status=='done' and t.owner==i and t.progress==6); assert(t.min.x==(i-1)*4); end; print('Three distinct completed leases and empty movement reservations survived restart')"
$lua52 = 'C:\Tools\lua52\lua52.exe'
if (!(Test-Path -LiteralPath $lua52)) { $lua52 = (Get-Command lua5.2 -ErrorAction Stop).Source }
& $lua52 -e $check | Set-Content "$Output\durable-state.txt"
if($LASTEXITCODE -ne 0){throw 'Durable mining state mismatch.'}
@{ok=$true;turtles=3;leases=3;fuelInterrupt=$true;inventoryInterrupt=$true;restart=$true} | ConvertTo-Json | Set-Content "$Output\mining-verdict.json"
& "$PSScriptRoot\verify-source.ps1" -Computers $Computers -Output $Output -Scenario mining
if(Test-Path "$Computers\5\world.json") {
    $world=Get-Content "$Computers\5\world.json" -Raw | ConvertFrom-Json
    $ores=@($world.blocks.PSObject.Properties | Where-Object {$_.Value -like '*_ore'})
    if($world.collisions -ne 0 -or $ores.Count -ne 3){throw 'Unexpected emulator collisions or remaining ore.'}
    foreach($key in @('3,65,6','7,65,6','11,65,6')) {
        if($world.blocks.PSObject.Properties[$key].Value -ne 'minecraft:diamond_ore'){throw "Missing untouched gap ore at $key."}
    }
    @{ok=$true;mined=46;intentionallyUntouched=3;collisions=0;moves=$world.timeline.Count} | ConvertTo-Json | Set-Content "$Output\coverage.json"
}
