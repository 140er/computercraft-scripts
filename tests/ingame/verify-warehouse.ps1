param([string]$Computers,[string]$Output)
$ErrorActionPreference='Stop'
if ($Output) { New-Item -ItemType Directory -Force -Path $Output | Out-Null }
$results=@()
foreach($id in 1..3) {
    $r=Get-Content "$Computers\$id\sandbox-result.json" -Raw | ConvertFrom-Json
    if(!$r.ok -or !$r.charged -or !$r.restart){throw "Turtle $id did not pass service recovery."}
    if($r.order.lines[0].delivered -ne 11 -or $r.order.lines[1].delivered -ne 1){throw "Wrong delivery from $id."}
    if(@($r.inventory | Where-Object {$_ -and $_.count -gt 0}).Count -gt 0){throw "Turtle $id kept order cargo."}
    $results+=$r
}
if(!$results[2].mining){throw 'Mining continuation was not exercised.'}
if($results[1].automaticCharges -lt 1){throw 'The low-fuel store turtle did not continue its order after charging.'}
if(($results[0].trafficYields+$results[1].trafficYields) -lt 1){throw 'The aisle test did not exercise physical yielding.'}
& "$PSScriptRoot\verify-source.ps1" -Computers $Computers -Output $Output -Ids @(0,1,2,3,4)
$results | ConvertTo-Json -Depth 14 | Set-Content "$Output\warehouse-results.json"
if(Test-Path "$Computers\5\world.json") {
    $world=Get-Content "$Computers\5\world.json" -Raw | ConvertFrom-Json
    if($world.collisions -ne 0){throw 'The emulators collided.'}
    foreach($id in 1..3) {
        $x=$id*4-3
        $source=@{}
        $drop=@{}
        foreach($v in $world.inventories.PSObject.Properties["$x,65,-1"].Value){$source[$v.name]+=$v.count}
        if($source['minecraft:dirt'] -ne 7 -or $source['minecraft:iron_ingot'] -ne 0 -or $source['minecraft:diamond_pickaxe'] -ne 0){throw "Source $id lost supplies or retained ordered stock."}
        $r=$results[$id-1]
        if(!$r.dropped -or !$r.duplicate -or !$r.reordered){throw "Turtle $id missed a network fault."}
    }
    $drop=@{}
    foreach($v in $world.inventories.PSObject.Properties['1,65,5'].Value){$drop[$v.name]+=$v.count}
    if($drop['minecraft:iron_ingot'] -ne 33 -or $drop['minecraft:diamond_pickaxe'] -ne 3 -or $drop['minecraft:dirt']){throw 'The shared drop has the wrong physical quantities.'}
    $ore=0
    foreach($v in $world.inventories.PSObject.Properties['9,65,5'].Value){if($v.name -eq 'minecraft:diamond_ore'){$ore+=$v.count}}
    if($ore -ne 2){throw 'The mining service lost ore.'}
    @{ok=$true;turtles=3;collisions=0;moves=$world.timeline.Count;physicalYield=$true;restart=$true} | ConvertTo-Json | Set-Content "$Output\coverage.json"
}
$root=[IO.Path]::GetFullPath("$Computers\0").Replace('\','/')
$helper=[IO.Path]::GetFullPath("$PSScriptRoot\read-ssot.lua").Replace('\','/')
$check="local control, map = dofile([[$helper]])([[$root]]); assert(control and next(control.moves)==nil); assert(map and next(map.warehouse.locks)==nil); local n=0; for _,j in pairs(map.warehouse.orders) do n=n+1; assert(j.status=='partial'); assert(j.lines[1].wanted==12 and j.lines[1].delivered==11 and j.lines[2].delivered==1); end; assert(n==3); assert(map.mining and #map.mining.tasks==1 and map.mining.tasks[1].owner==3 and map.mining.tasks[1].status=='done' and map.mining.tasks[1].progress==2); print('Three partial orders, exact quantities, empty bays, empty moves and completed mining survived restart')"
$lua52 = 'C:\Tools\lua52\lua52.exe'
if (!(Test-Path -LiteralPath $lua52)) { $lua52 = (Get-Command lua5.2 -ErrorAction Stop).Source }
& $lua52 -e $check | Set-Content "$Output\durable-state.txt"
if($LASTEXITCODE -ne 0){throw 'Warehouse durable state mismatch.'}
Write-Output 'Three exact deliveries, charging, physical-transfer restart and mining continuation passed.'
