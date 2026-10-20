param(
    [ValidateSet('Prepare','Run')][string]$Mode = 'Prepare',
    [ValidateSet('Box','Local')][string]$HostKind = 'Box',
    [string]$RunId = '',
    [string]$TestRoot = '',
    [string]$Bindings = '',
    [scriptblock]$Rcon,
    [scriptblock]$Restart,
    [string]$Output = 'C:\Work\gemini-input\p3\evidence\wizard',
    [ValidateRange(7200,86400)][int]$SoakSeconds = 7200,
    [ValidateRange(10,60)][int]$SampleSeconds = 30,
    [ValidateRange(30,900)][int]$TimeoutSeconds = 120,
    [string]$ModJar = 'C:\mc-cc-test\base\mods\superbwarfare-0.8.9.2-mc1.21.1-c22d98c2.jar'
)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path "$PSScriptRoot\..\..").Path
. "$source\tests\wh2-wizard-gate-host.ps1"
$plan = Get-Content -LiteralPath "$source\tests\wh2-wizard-gate-plan.json" -Raw | ConvertFrom-Json
$utf8 = New-Object Text.UTF8Encoding($false)
$attempt = Join-Path $Output ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $attempt -Force | Out-Null
$prepared = Join-Path $attempt 'prepared'
$computers = Join-Path $prepared 'world\computercraft\computer'
New-Item -ItemType Directory -Path $computers -Force | Out-Null

function Write-WizardJson([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), $utf8)
}

function Get-WizardScene {
    $cmds = [Collections.Generic.List[string]]::new()
    $cmds.Add('forceload add -16 -16 63 15')
    foreach ($room in $plan.rooms) {
        $a = $room.min; $b = $room.max
        $cmds.Add("fill $($a[0]) $($a[1]) $($a[2]) $($b[0]) $($b[1]) $($b[2]) minecraft:stone hollow")
        $cmds.Add("fill $($a[0]+1) $($a[1]+1) $($a[2]+1) $($b[0]-1) $($b[1]-1) $($b[2]-1) minecraft:air")
        $cmds.Add("fill $($a[0]+1) 65 $($a[2]) $($a[0]+2) 67 $($a[2]) minecraft:air")
        if ($room.pillar) {
            $p = $room.pillar
            $cmds.Add("fill $($p[0]) $($p[1]) $($p[2]) $($p[0]) $($b[1]-1) $($p[2]) minecraft:stone")
        }
        if ($room.notch) {
            $a = $room.notch[0]; $b = $room.notch[1]
            $cmds.Add("fill $($a[0]) $($a[1]) $($a[2]) $($b[0]) $($b[1]) $($b[2]) minecraft:stone")
        }
        $cmds.Add("setblock $($room.min[0]+2) 65 $($room.min[2]+5) minecraft:barrel")
        $cmds.Add("item replace block $($room.min[0]+2) 65 $($room.min[2]+5) container.0 with minecraft:stone 37")
        $cmds.Add("setblock $($room.min[0]+4) 65 $($room.min[2]+5) minecraft:furnace")
    }
    foreach ($inventory in $plan.inventories) {
        $p = $inventory.pose
        $cmds.Add("setblock $($p[0]) $($p[1]) $($p[2]) $($inventory.block)")
        if ($inventory.fill) {
            foreach ($slot in 0..26) { $cmds.Add("item replace block $($p[0]) $($p[1]) $($p[2]) container.$slot with $($inventory.fill.item) $($inventory.fill.count)") }
        }
    }
    $cmds.Add('setblock -6 65 -4 computercraft:computer_advanced{ComputerId:0}')
    $cmds.Add('setblock -6 66 -4 computercraft:wireless_modem_advanced[facing=down]')
    $cmds.Add('setblock -4 65 -4 computercraft:computer_advanced{ComputerId:5}')
    $cmds.Add('setblock -4 66 -4 computercraft:wireless_modem_advanced[facing=down]')
    $cmds.Add('setblock 0 65 -4 computercraft:computer_advanced{ComputerId:6}')
    $cmds.Add('setblock 0 66 -4 computercraft:wireless_modem_advanced[facing=down]')
    foreach ($x in -4..-2) {
        foreach ($y in 65..67) { $cmds.Add("setblock $x $y -5 computercraft:monitor_advanced[facing=south]") }
    }
    foreach ($id in 1..4) {
        $x = $id * 2
        $cmds.Add("setblock $x 64 2 minecraft:chest")
        $cmds.Add("setblock $x 66 2 minecraft:barrel")
        $cmds.Add("setblock $x 65 2 computercraft:turtle_advanced{ComputerId:$id,Fuel:2000,RightUpgrade:`"computercraft:wireless_modem_advanced`"}")
        $slot = 0
        foreach ($row in $plan.inventories[0].contents) {
            $cmds.Add("item replace block $x 66 2 container.$slot with $($row.item) $($row.count)")
            $slot++
        }
    }
    return $cmds.ToArray()
}

$missing = [Collections.Generic.List[string]]::new()
foreach ($file in @('sha2.lua','ssot-auth.lua','wh2-client.lua','wh2-wizard.lua','wh2-board.lua','wh2-wizard-adapter.lua')) {
    if (!(Test-Path -LiteralPath "$source\$file")) { $missing.Add($file) }
}
if (!$Bindings -or !(Test-Path -LiteralPath $Bindings -PathType Leaf)) { $missing.Add('authenticated wh2-wizard-gate-bindings.lua supplied through -Bindings') }
$provenance = [Collections.Generic.List[object]]::new()
if (Test-Path -LiteralPath $ModJar) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ModJar)
    try {
        foreach ($item in $plan.unknowns) {
            $name = $item.Split(':')[1]
            $entry = $archive.Entries | Where-Object { $_.FullName -eq "assets/superbwarfare/models/item/$name.json" } | Select-Object -First 1
            if (!$entry) { throw "Item $item has no model in the local jar." }
            $provenance.Add(@{item=$item; jar=(Split-Path $ModJar -Leaf); sha256=(Get-FileHash -LiteralPath $ModJar -Algorithm SHA256).Hash; entry=$entry.FullName})
        }
    } finally { $archive.Dispose() }
} else { $missing.Add("local mod jar $ModJar") }
Write-WizardJson "$attempt\item-provenance.json" $provenance.ToArray()
$scene = @(Get-WizardScene)
[IO.File]::WriteAllLines("$attempt\scene.rcon.txt", $scene, $utf8)
Copy-Item -LiteralPath "$source\tests\wh2-wizard-gate-plan.json" -Destination "$attempt\requirements.json"
$diskInventory = [Collections.Generic.List[object]]::new()
$commonFiles = @('atomic.lua','ssot.lua','ssot-client.lua','sha2.lua','ssot-auth.lua','wh2-client.lua',
    'wh2-fleet.lua','wh2-wizard.lua','wh2-board.lua','wh2-wizard-adapter.lua','wh2-layout.lua','wh2-craft.lua','wh2-recipes.lua')
foreach ($id in 0..6) {
    $disk = Join-Path $computers $id
    New-Item -ItemType Directory -Path $disk -Force | Out-Null
    $names = $commonFiles
    if ($id -eq 0) { $names += @('server.lua','mine-tasks.lua','warehouse-tasks.lua') }
    foreach ($name in $names) {
        if (!(Test-Path -LiteralPath "$source\$name")) { continue }
        [IO.File]::WriteAllText("$disk\$name", [IO.File]::ReadAllText("$source\$name").Replace("`r`n", "`n"), $utf8)
    }
    foreach ($name in @('wh2-wizard-gate-runtime.lua','wh2-wizard-gate-checks.lua')) {
        Copy-Item -LiteralPath "$source\tests\$name" -Destination $disk
    }
    Copy-Item -LiteralPath "$source\tests\sandbox\wh2-wizard-driver.lua" -Destination "$disk\startup.lua"
    if ($Bindings -and (Test-Path -LiteralPath $Bindings)) { Copy-Item -LiteralPath $Bindings -Destination "$disk\wh2-wizard-gate-bindings.lua" }
    $role = if ($id -eq 0) { 'server' } elseif ($id -in @(5,6)) { 'board' } else { 'turtle' }
    Write-WizardJson "$disk\wizard-config.json" @{schema=1; enabled=$true; role=$role; computerId=$id; serverId=0; operators=@{'5'=$true;'6'=$true}; diskLimit=$plan.diskLimit; unknowns=$plan.unknowns; sampleSeconds=$SampleSeconds}
    $bytes = (Get-ChildItem -LiteralPath $disk -File | Measure-Object -Property Length -Sum).Sum
    $diskInventory.Add(@{computerId=$id; stagedBytes=$bytes; capacity=$plan.diskLimit; headroom=$plan.diskLimit-$bytes; files=@(Get-ChildItem -LiteralPath $disk -File | Select-Object Name,Length)})
    if ($bytes -ge $plan.diskLimit) { $missing.Add("computer $id source already exceeds the disk limit") }
}
Write-WizardJson "$attempt\staged-disk-sizes.json" $diskInventory.ToArray()
Write-WizardJson "$attempt\preparation.json" @{status='prepared'; runtimeExecuted=$false; missing=@($missing.ToArray()); computers=$computers; sceneCommands=$scene.Count; diskLimit=$plan.diskLimit; soakSeconds=$SoakSeconds}
Write-Output "Wizard preparation: $attempt"
if ($Mode -eq 'Prepare') {
    if ($missing.Count) { Write-Output ('Missing prerequisites: ' + ($missing -join ', ')) }
    return
}
if ($missing.Count) { throw ('Wizard runtime blocked: ' + ($missing -join ', ')) }
if ($HostKind -eq 'Box') {
    if (!$RunId) { throw 'Run requires an existing disposable box RunId.' }
    . C:\Work\gemini-input\gateb\gateb.ps1
    $run = Get-GatebRun $RunId
    if ($run.space_limit -and $run.space_limit -ne $plan.diskLimit) { throw 'Use a disposable run with SpaceLimit 1000000.' }
    Send-GatebDir $RunId "$prepared\world\computercraft" 'world'
} else {
    if (!$Rcon -or !$Restart) { throw 'Local Run requires loopback-only Rcon and process Restart scriptblocks from the owning runner.' }
    $resolved = [IO.Path]::GetFullPath($TestRoot)
    if ($resolved -notmatch '^C:\\Work\\mc-wh2-wizard-[a-zA-Z0-9-]+$') { throw 'Local TestRoot must be a disposable C:\Work\mc-wh2-wizard-* root.' }
    $properties = Get-Content -LiteralPath "$resolved\server.properties" -Raw
    if ($properties -notmatch '(?m)^server-ip=127\.0\.0\.1\s*$') { throw 'Local server must bind to loopback.' }
    New-Item -ItemType Directory -Path "$resolved\world\computercraft" -Force | Out-Null
    Copy-Item -LiteralPath $computers -Destination "$resolved\world\computercraft" -Recurse
}

function Invoke-WizardRcon([string[]]$Commands) {
    if ($HostKind -eq 'Box') { return Invoke-GatebRcon $RunId $Commands -Log "$attempt\rcon.txt" }
    foreach ($command in $Commands) {
        $reply = & $Rcon $command
        Add-Content -LiteralPath "$attempt\rcon.txt" -Value "$([DateTime]::UtcNow.ToString('o')) > $command`n$reply"
        $reply
    }
}
function Set-WizardFile([int]$Id, [string]$Name, [string]$Text) {
    $path = "world/computercraft/computer/$Id/$Name"
    if ($HostKind -eq 'Box') { Set-GatebText $RunId $path $Text }
    else { [IO.File]::WriteAllText((Join-Path $resolved $path), $Text, $utf8) }
}
function Get-WizardFile([int]$Id, [string]$Name) {
    $path = "world/computercraft/computer/$Id/$Name"
    if ($HostKind -eq 'Box') { return Get-GatebText $RunId $path }
    $local = Join-Path $resolved $path
    if (Test-Path -LiteralPath $local) { [IO.File]::ReadAllText($local) }
}
function Start-WizardCommand([int[]]$Ids, [string]$Action, [string]$Case = '') {
    $nonce = [guid]::NewGuid().ToString('N')
    foreach ($id in $Ids) { Set-WizardFile $id 'wizard-command.json' (@{nonce=$nonce;action=$Action;case=$Case} | ConvertTo-Json -Compress) }
    return $nonce
}
function Wait-WizardCommand([int[]]$Ids, [string]$Nonce) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    foreach ($id in $Ids) {
        do {
            $text = Get-WizardFile $id 'sandbox-result.json'
            if ($text) { throw "Computer $id stopped. Its failure report is retained on disk." }
            $text = Get-WizardFile $id 'wizard-result.json'
            if ($text) {
                $result = $text | ConvertFrom-Json
                if ($result.nonce -eq $Nonce) {
                    if (!$result.ok) { throw "Computer $id rejected scenario action: $($result.error)" }
                    break
                }
            }
            if ([DateTime]::UtcNow -gt $deadline) { throw "Computer $id timed out waiting for nonce $Nonce." }
            Start-Sleep -Milliseconds 500
        } while ($true)
    }
}
function Invoke-WizardCommand([int[]]$Ids, [string]$Action, [string]$Case = '') {
    Wait-WizardCommand $Ids (Start-WizardCommand $Ids $Action $Case)
}
$archives = [Collections.Generic.List[object]]::new()
function Get-WizardChest([int[]]$Pose) {
    $text = Invoke-WizardRcon @("data get block $($Pose -join ' ') Items")
    return ConvertFrom-WizardInventory ($text -join "`n")
}
function Save-WizardCounts([string]$Label, [int]$ExpectedLoads, [bool]$Routed) {
    Invoke-WizardCommand @(1,2,3,4) 'snapshot'
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($id in 1..4) {
        $inventory = (Get-WizardFile $id 'wizard-inventory.json' | ConvertFrom-Json).inventory
        foreach ($property in $inventory.PSObject.Properties) { $rows.Add([pscustomobject]@{location="turtle:$id";item=$property.Name;count=[int]$property.Value}) }
        foreach ($y in @(64,66)) {
            $counts = Get-WizardChest @(($id*2),$y,2)
            foreach ($item in $counts.Keys) { $rows.Add([pscustomobject]@{location="block:$($id*2):${y}:2";item=$item;count=$counts[$item]}) }
        }
    }
    foreach ($pose in $archives) {
        $counts = Get-WizardChest $pose
        foreach ($item in $counts.Keys) { $rows.Add([pscustomobject]@{location="archive:$($pose -join ',')";item=$item;count=$counts[$item]}) }
    }
    Write-WizardJson "$attempt\counts-$Label.json" $rows.ToArray()
    $rows | ForEach-Object { [pscustomobject]$_ } | Export-Csv -LiteralPath "$attempt\counts-$Label.csv" -NoTypeInformation
    foreach ($item in $plan.unknowns) {
        $load = $plan.inventories[0].contents | Where-Object { $_.item -eq $item }
        $actual = ($rows | Where-Object { $_.item -eq $item } | Measure-Object -Property count -Sum).Sum
        $expected = 4 * $load.count * $ExpectedLoads
        if ($actual -ne $expected) { throw "$Label expected total $expected $item, observed $actual." }
        $destinations = ($rows | Where-Object { $_.item -eq $item -and ($_.location -like 'archive:*' -or $_.location -match '^block:\d+:64:2$') } | Measure-Object -Property count -Sum).Sum
        if ($Routed -and $destinations -ne $expected) { throw "$Label expected $expected routed $item, observed $destinations." }
        if (!$Routed -and $destinations -ne 0) { throw 'Unknown material moved before a board answer.' }
    }
    foreach ($load in $plan.inventories[0].contents | Where-Object { $_.item -notin $plan.unknowns }) {
        $actual = ($rows | Where-Object { $_.item -eq $load.item } | Measure-Object -Property count -Sum).Sum
        if ($actual -ne 4 * $load.count) { throw "$Label changed the retained mixed load for $($load.item)." }
    }
}
function Add-WizardUnknownLoad {
    foreach ($id in 1..4) {
        $slot = 6
        foreach ($load in $plan.inventories[0].contents | Where-Object { $_.item -in $plan.unknowns }) {
            Invoke-WizardRcon @("item replace block $($id*2) 66 2 container.$slot with $($load.item) $($load.count)") | Out-Null
            $slot++
        }
    }
}
function Move-WizardOutputsToArchive {
    foreach ($id in 1..4) {
        $index = $archives.Count
        $pose = @((64 + ($index % 16) * 2), 64, (16 + [math]::Floor($index / 16) * 2))
        Invoke-WizardRcon @("forceload add $($pose[0]) $($pose[2])",
            "clone $($id*2) 64 2 $($id*2) 64 2 $($pose -join ' ') replace move",
            "setblock $($id*2) 64 2 minecraft:chest") | Out-Null
        $archives.Add($pose)
    }
    Write-WizardJson "$attempt\archive-poses.json" $archives.ToArray()
}

try {
    Invoke-WizardRcon $scene | Out-Null
    foreach ($room in $plan.rooms) {
        $pose = @(($room.min[0]+2),65,($room.min[2]+5))
        Write-WizardJson "$attempt\room-$($room.id)-inventory.json" (Get-WizardChest $pose)
    }
    Invoke-WizardRcon @('computercraft turn-on 0 1 2 3 4 5 6') | Out-Null
    Save-WizardCounts 'initial' 1 $false
    Invoke-WizardCommand @(1,2,3,4) 'report'
    Invoke-WizardCommand @(1,2,3,4) 'report'
    Invoke-WizardCommand @(1,2,3,4) 'route'
    Save-WizardCounts 'unknown-retained' 1 $false
    Invoke-WizardCommand @(5) 'answer'
    Invoke-WizardCommand @(1,2,3,4) 'route'
    Save-WizardCounts 'answered' 1 $true
    Invoke-WizardCommand @(5) 'fuzz'
    Invoke-WizardCommand @(5) 'stale'
    Invoke-WizardCommand @(5) 'revision'
    $revision = (Get-WizardFile 5 'wizard-revision.json' | ConvertFrom-Json).revision
    $raceNonce = [guid]::NewGuid().ToString('N')
    foreach ($id in @(5,6)) {
        Set-WizardFile $id 'wizard-command.json' (@{nonce=$raceNonce;action='race-answer';item=$plan.unknowns[0];baseRevision=$revision} | ConvertTo-Json -Compress)
    }
    Wait-WizardCommand @(5,6) $raceNonce
    $race = @(foreach ($id in @(5,6)) { [pscustomobject]@{id=$id; result=(Get-WizardFile $id 'wizard-race.json' | ConvertFrom-Json)} })
    Write-WizardJson "$attempt\concurrent-answers.json" $race
    $winner = @($race | Where-Object { $_.result.nonce -eq $raceNonce -and $_.result.reply.ok })
    $loser = @($race | Where-Object { $_.result.nonce -eq $raceNonce -and $_.result.reply.code -eq 'stale_revision' })
    if ($winner.Count -ne 1 -or $loser.Count -ne 1) { throw 'Concurrent operator answers did not produce exactly one accepted answer and one stale rejection.' }
    Invoke-WizardCommand @($loser[0].id) 'stale'
    Invoke-WizardRcon @('computercraft reboot 1 2 3 4 5') | Out-Null
    Invoke-WizardCommand @(5) 'retained'
    if ($HostKind -eq 'Box') { Stop-GatebRun $RunId | Out-Null; Start-GatebRun $RunId | Out-Null }
    else { & $Restart }
    Invoke-WizardCommand @(5) 'retained'
    Add-WizardUnknownLoad
    Invoke-WizardCommand @(1,2,3,4) 'route'
    Save-WizardCounts 'after-restart' 2 $true
    Move-WizardOutputsToArchive
    foreach ($slot in 0..26) { Invoke-WizardRcon @("item replace block 2 64 2 container.$slot with minecraft:cobblestone 64") | Out-Null }
    Add-WizardUnknownLoad
    Invoke-WizardCommand @(1,2,3,4) 'route'
    Invoke-WizardCommand @(1) 'snapshot'
    $blocked = (Get-WizardFile 1 'wizard-inventory.json' | ConvertFrom-Json).inventory
    foreach ($load in $plan.inventories[0].contents | Where-Object { $_.item -in $plan.unknowns }) {
        if ($blocked.($load.item) -ne $load.count) { throw 'Full chest did not retain the exact unknown stack in turtle 1.' }
    }
    Move-WizardOutputsToArchive
    Invoke-WizardCommand @(1,2,3,4) 'route'
    Save-WizardCounts 'full-chest-recovered' 3 $true
    Invoke-WizardRcon @('computercraft shutdown 1','data merge block 2 65 2 {Fuel:0}','computercraft turn-on 1',
        'item replace block -2 65 7 container.0 with minecraft:raw_iron 32') | Out-Null
    Invoke-WizardCommand @(5) 'boundary' 'no-fuel'
    Invoke-WizardRcon @('item replace block -2 65 7 container.1 with minecraft:coal 8') | Out-Null
    Invoke-WizardCommand @(5) 'boundary' 'removed-machine-start'
    Invoke-WizardRcon @('setblock -2 65 7 minecraft:air destroy',
        'execute as @e[type=minecraft:item,x=-2,y=65,z=7,distance=..3] run data get entity @s Item') | Out-Null
    Invoke-WizardCommand @(5) 'boundary' 'removed-machine'
    Invoke-WizardCommand @(5) 'boundary' 'modem-removal-start'
    Invoke-WizardRcon @('setblock -4 66 -4 minecraft:air') | Out-Null
    Invoke-WizardCommand @(5) 'boundary' 'modem-removal'
    Invoke-WizardRcon @('setblock -4 66 -4 computercraft:wireless_modem_advanced[facing=down]') | Out-Null
    Invoke-WizardCommand @(5) 'retained'
    foreach ($case in @('authentication','event-bursts','unload','updates')) {
        Invoke-WizardCommand @(5) 'boundary' $case
    }
    Invoke-WizardRcon @('computercraft shutdown 1','data merge block 2 65 2 {Fuel:2000}','computercraft turn-on 1') | Out-Null
    $soakStart = [DateTime]::UtcNow
    $loads = 3
    do {
        Add-WizardUnknownLoad
        $loads++
        Invoke-WizardCommand @(1,2,3,4) 'report'
        Invoke-WizardCommand @(1,2,3,4) 'route'
        Save-WizardCounts "soak-$loads" $loads $true
        if ($loads % 8 -eq 0) { Move-WizardOutputsToArchive }
        Write-WizardJson "$attempt\soak-progress.json" @{started=$soakStart.ToString('o');elapsedSeconds=([DateTime]::UtcNow-$soakStart).TotalSeconds;requiredSeconds=$SoakSeconds}
        Start-Sleep -Seconds $SampleSeconds
    } while (([DateTime]::UtcNow - $soakStart).TotalSeconds -lt $SoakSeconds)
    Write-WizardJson "$attempt\runtime.json" @{status='awaiting-evidence-review';runId=$RunId;hostKind=$HostKind;soakSeconds=([DateTime]::UtcNow-$soakStart).TotalSeconds;capture='missing-lead-owned-F2-and-video'}
} catch {
    Write-WizardJson "$attempt\runtime.json" @{status='failed';error=$_.Exception.Message;runId=$RunId;hostKind=$HostKind}
    throw
} finally {
    if ($HostKind -eq 'Box') {
        Save-GatebDir $RunId 'world/computercraft/computer' $attempt
        Save-GatebDir $RunId 'logs' $attempt
        foreach ($name in @('jar-sha256.txt','rcon.txt')) {
            $text = Get-GatebText $RunId $name
            if ($text) { [IO.File]::WriteAllText("$attempt\box-$name", $text, $utf8) }
        }
    } else {
        Copy-Item -LiteralPath "$resolved\world\computercraft\computer" -Destination "$attempt\computers" -Recurse
        Copy-Item -LiteralPath "$resolved\logs" -Destination "$attempt\logs" -Recurse
    }
}
