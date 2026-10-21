$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\depth-host.ps1"
$problems = New-Object System.Collections.Generic.List[string]
try {
    foreach ($id in 0..4) {
        if ($id -eq 0) { Set-DepthIdle $id }
    }
    Copy-DepthProbe 1 'depth-result.lua'
    Copy-DepthProbe 1 'room-boot.lua'
    Copy-DepthText 1 'room.cfg.a' "$PSScriptRoot\room-cfg.txt"
    Set-DepthStartup 1 'room-boot.lua'
    Copy-DepthProbe 2 'depth-result.lua'
    Copy-DepthProbe 2 'room-layout-probe.lua'
    Set-DepthStartup 2 'room-layout-probe.lua'
    Copy-DepthProbe 3 'depth-result.lua'
    Copy-DepthProbe 3 'nofuel-probe.lua'
    Set-DepthStartup 3 'nofuel-probe.lua'
    Copy-DepthProbe 4 'depth-result.lua'
    Copy-DepthProbe 4 'craft-probe.lua'
    Set-DepthStartup 4 'craft-probe.lua'
    Measure-DepthDisk $GateComputerSpaceLimit

    Start-DepthWorld
    $box = @(
        'fill 98 64 98 102 68 103 minecraft:stone',
        'fill 99 65 100 101 67 102 minecraft:air',
        'setblock 100 65 99 minecraft:chest',
        'setblock 100 65 103 minecraft:chest',
        'item replace block 100 65 103 container.0 with minecraft:cobblestone 1',
        'fill 130 64 100 140 68 108 minecraft:stone',
        'fill 131 65 101 139 67 107 minecraft:air',
        'fill 170 64 100 180 68 110 minecraft:stone',
        'fill 171 65 101 179 67 106 minecraft:air',
        'fill 171 65 105 176 67 109 minecraft:air',
        'setblock 174 65 103 minecraft:stone',
        'setblock 174 66 103 minecraft:stone',
        'setblock 174 67 103 minecraft:stone',
        'setblock 177 65 104 minecraft:stone',
        'setblock 80 64 80 minecraft:stone',
        'setblock 80 65 79 minecraft:chest',
        'setblock 90 64 80 minecraft:stone',
        'setblock 90 65 79 minecraft:chest'
    )
    foreach ($command in $box) { Rcon $command | Out-Null }
    foreach ($slot in 0..26) { Rcon "item replace block 90 65 79 container.$slot with minecraft:cobblestone 64" | Out-Null }
    $loads = @(
        'container.0 with minecraft:furnace 1',
        'container.1 with minecraft:blast_furnace 1',
        'container.2 with minecraft:smoker 1',
        'container.3 with minecraft:chest 2',
        'container.4 with minecraft:coal 16',
        'container.5 with superbwarfare:galena_ore 64',
        'container.6 with superbwarfare:silver_ore 19',
        'container.7 with minecraft:raw_iron 32',
        'container.8 with minecraft:potato 20',
        'container.9 with minecraft:sand 8',
        'container.10 with minecraft:red_dye 5',
        'container.11 with minecraft:cobblestone 64'
    )
    foreach ($load in $loads) { Rcon "item replace block 100 65 99 $load" | Out-Null }
    Rcon 'setblock 80 65 90 minecraft:furnace' | Out-Null
    Rcon 'item replace block 80 65 90 container.0 with minecraft:sand 1' | Out-Null
    Rcon 'setblock 80 65 92 minecraft:furnace' | Out-Null
    Rcon 'item replace block 80 65 92 container.0 with minecraft:sand 1' | Out-Null
    Rcon 'setblock 80 65 94 minecraft:furnace' | Out-Null
    Rcon 'item replace block 80 65 94 container.0 with minecraft:sand 3' | Out-Null
    Rcon 'item replace block 80 65 94 container.1 with minecraft:coal 1' | Out-Null
    Rcon 'setblock 100 65 100 computercraft:turtle_advanced[facing=north]{ComputerId:1,Fuel:2000}' | Out-Null
    Rcon 'setblock 80 65 80 computercraft:turtle_advanced[facing=north]{ComputerId:3,Fuel:0}' | Out-Null
    Rcon 'setblock 100 65 110 computercraft:computer_advanced{ComputerId:2}' | Out-Null
    Rcon 'setblock 70 65 70 computercraft:computer_advanced{ComputerId:4}' | Out-Null
    $mediumAir = Rcon 'execute if block 135 65 104 minecraft:air'
    $pillar = Rcon 'execute if block 174 66 103 minecraft:stone'
    $step = Rcon 'execute if block 177 65 104 minecraft:stone'
    $stepAir = Rcon 'execute if block 176 65 104 minecraft:air'
    if ($mediumAir -notmatch 'passed|1') { $problems.Add("Medium room is not open. $mediumAir") }
    if ($pillar -notmatch 'passed|1') { $problems.Add("Irregular room pillar is missing. $pillar") }
    if ($step -notmatch 'passed|1' -or $stepAir -notmatch 'passed|1') { $problems.Add("Irregular room step is missing. $step $stepAir") }

    Rcon 'computercraft turn-on 1 2 3 4' | Out-Null
    $stations = "$TestRoot\world\computercraft\computer\1\depth-stations.json"
    $failedScan = "$TestRoot\world\computercraft\computer\1\room-failed.txt"
    $deadline = [DateTime]::UtcNow.AddSeconds(300)
    while (-not (Test-Path $stations) -and -not (Test-Path $failedScan) -and [DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) { throw 'Minecraft exited during the room scan.' }
        Start-Sleep -Seconds 1
    }
    if (Test-Path $failedScan) { $problems.Add((Get-Content $failedScan -Raw)) }
    elseif (-not (Test-Path $stations)) { $problems.Add('Room scan did not write depth-stations.json.') }

    Wait-DepthFile "$TestRoot\world\computercraft\computer\3\nofuel-result.json" 90
    $nofuel = Get-Content "$TestRoot\world\computercraft\computer\3\nofuel-result.json" -Raw | ConvertFrom-Json
    $still = Rcon 'data get block 80 65 80'
    if ($nofuel.moved) { $problems.Add('Unfueled turtle reported a move.') }
    if ($still -notmatch 'ComputerId:\s*3') { $problems.Add("Unfueled turtle left 80 65 80. $still") }
    $dry = Rcon 'data get block 80 65 90'
    Start-Sleep -Seconds 8
    $dryAfter = Rcon 'data get block 80 65 90'
    if ($dryAfter -notmatch 'minecraft:sand') { $problems.Add("Unfueled furnace lost its sand. $dryAfter") }
    Rcon 'setblock 80 65 92 minecraft:air' | Out-Null
    Start-Sleep -Seconds 1
    $dropped = Rcon 'execute positioned 80 65 92 if entity @e[type=item,distance=..4]'
    if ($dropped -notmatch 'passed|1') { $problems.Add("Removing the furnace did not drop its sand. $dropped") }

    Rcon 'computercraft shutdown 3' | Out-Null
    Copy-DepthProbe 3 'fullchest-probe.lua'
    Set-DepthStartup 3 'fullchest-probe.lua'
    Rcon 'setblock 80 65 80 minecraft:air' | Out-Null
    Rcon 'setblock 90 65 80 computercraft:turtle_advanced[facing=north]{ComputerId:3,Fuel:100}' | Out-Null
    Rcon 'item replace block 90 65 80 container.0 with minecraft:cobblestone 64' | Out-Null
    Rcon 'computercraft turn-on 3' | Out-Null
    Wait-DepthFile "$TestRoot\world\computercraft\computer\3\fullchest-result.json" 90
    $full = Get-Content "$TestRoot\world\computercraft\computer\3\fullchest-result.json" -Raw | ConvertFrom-Json
    if ($full.after -ne $full.before -or $full.before -ne 64) {
        $problems.Add("Full chest changed the stack from $($full.before) to $($full.after).")
    }

    Wait-DepthFile "$TestRoot\world\computercraft\computer\2\layout-ready" 120
    Rcon 'computercraft shutdown 2' | Out-Null
    Rcon 'computercraft turn-on 2' | Out-Null
    $layout = Read-DepthResult 2 120
    Add-DepthFailures $layout $problems 'layout'

    Rcon 'computercraft shutdown 2' | Out-Null
    Copy-DepthProbe 2 'wizard-probe.lua'
    Remove-Item "$TestRoot\world\computercraft\computer\2\wizard-phase","$TestRoot\world\computercraft\computer\2\wizard-state","$TestRoot\world\computercraft\computer\2\depth-result.json" -ErrorAction SilentlyContinue
    Set-DepthStartup 2 'wizard-probe.lua'
    Rcon 'computercraft turn-on 2' | Out-Null
    Wait-DepthFile "$TestRoot\world\computercraft\computer\2\wizard-ready" 120

    $sandBefore = Get-DepthCount '80 65 94' 'minecraft:sand'
    $craftDisk = "$TestRoot\world\computercraft\computer\4"
    $which = Wait-DepthEither "$craftDisk\craft-ready" "$craftDisk\depth-result.json" 180
    Stop-TestServer
    Start-TestServer 'restart'
    Rcon 'forceload add 64 64 240 160' | Out-Null
    $sandAfter = Get-DepthCount '80 65 94' 'minecraft:sand'
    if ($sandAfter -gt $sandBefore) { $problems.Add("Smelt sand doubled from $sandBefore to $sandAfter.") }
    Rcon 'computercraft turn-on 4' | Out-Null
    $craft = Read-DepthResult 4 180
    Add-DepthFailures $craft $problems 'craft restart'

    if (Test-Path $stations) {
        $found = $false
        $until = [DateTime]::UtcNow.AddSeconds(420)
        $map = Get-Content $stations -Raw | ConvertFrom-Json
        while (-not $found -and [DateTime]::UtcNow -lt $until) {
            Rcon 'computercraft turn-on 1' | Out-Null
            $hits = 0
            foreach ($cell in @($map.stations)) {
                $parts = $cell -split ','
                $pos = "$(100 + [int]$parts[0]) $(65 + [int]$parts[1]) $(100 + [int]$parts[2])"
                $block = Rcon "data get block $pos"
                if ($block -match 'blast_furnace|furnace|smoker') { $hits++ }
            }
            if ($hits -ge 1) { $found = $true } else { Start-Sleep -Seconds 5 }
        }
        $seen = @{}
        foreach ($cell in @($map.stations)) {
            $parts = $cell -split ','
            $pos = "$(100 + [int]$parts[0]) $(65 + [int]$parts[1]) $(100 + [int]$parts[2])"
            $block = Rcon "data get block $pos"
            foreach ($item in @('superbwarfare:galena_ore','superbwarfare:silver_ore','minecraft:raw_iron','minecraft:potato','minecraft:sand','minecraft:red_dye')) {
                if ($block -match [regex]::Escape($item)) { $seen[$item] = $true }
            }
        }
        foreach ($item in @('superbwarfare:galena_ore','minecraft:potato','minecraft:sand')) {
            if (-not $seen[$item]) { $problems.Add("Sorted load did not land $item in a station.") }
        }
    }
    $marker = Get-DepthCount '100 65 103' 'minecraft:cobblestone'
    if ($marker -lt 1) { $problems.Add('Output chest marker was removed.') }

    Invoke-DepthShot 'room' 'room.png'
    Invoke-DepthShot 'board' 'board.png'
    Invoke-DepthShot 'wizard' 'wizard.png'
} catch {
    $problems.Add($_.Exception.Message)
}
Complete-Depth 'room' ($problems.Count -eq 0) ($problems -join "`n")
