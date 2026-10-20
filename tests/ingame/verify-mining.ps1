param([string]$Computers,[string]$Output)
$ErrorActionPreference='Stop'
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
$state=[IO.Path]::GetFullPath("$Computers\0\ssot.state").Replace('\','/')
$check="local h=assert(io.open([[$state]])); local s=assert(load('return '..h:read('*a'),'state','t',{}))().value; h:close(); assert(next(s.moves)==nil); assert(#s.mining.tasks==3); for i,t in ipairs(s.mining.tasks) do assert(t.status=='done' and t.owner==i and t.progress==6); assert(t.min.x==(i-1)*4); end; print('Three distinct completed leases and empty movement reservations survived restart')"
& 'C:\Tools\lua52\lua52.exe' -e $check | Set-Content "$Output\durable-state.txt"
if($LASTEXITCODE -ne 0){throw 'Durable mining state mismatch.'}
@{ok=$true;turtles=3;leases=3;fuelInterrupt=$true;inventoryInterrupt=$true;restart=$true} | ConvertTo-Json | Set-Content "$Output\mining-verdict.json"
& "$PSScriptRoot\verify-source.ps1" -Computers $Computers -Output $Output
