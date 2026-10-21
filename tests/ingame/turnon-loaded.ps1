$script:GatebComputerAt = @{}

function Register-GatebComputerPlace([string]$Command) {
    $dim = 'minecraft:overworld'
    $body = $Command.Trim()
    if ($body -match '^execute in (\S+) run (.+)$') {
        $dim = $Matches[1]
        $body = $Matches[2].Trim()
    }
    if ($body -match '^setblock (-?\d+) (-?\d+) (-?\d+) computercraft:(?:computer|turtle)_advanced(?:\[[^\]]*\])?\{.*?ComputerId:(\d+)') {
        $script:GatebComputerAt[$Matches[4]] = @{ X = [int]$Matches[1]; Y = [int]$Matches[2]; Z = [int]$Matches[3]; Dim = $dim }
    }
}

function Test-TurnOnLoaded([string]$Reply, [int]$Count) {
    if ($Reply -notmatch '^Turned on (\d+)/(\d+) computers$') { return $false }
    [int]$Matches[2] -eq $Count -and $Count -gt 0
}

function Invoke-LoadedTurnOn {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][scriptblock]$Send,
        [int]$WaitSec = 30
    )
    $dim = 'minecraft:overworld'
    $body = $Command.Trim()
    if ($body -match '^execute in (\S+) run (.+)$') {
        $dim = $Matches[1]
        $body = $Matches[2].Trim()
    }
    if ($body -notmatch '^computercraft turn-on ([\d ]+)$') { return (& $Send $Command) }
    $ids = @($Matches[1].Trim() -split '\s+' | Where-Object { $_ -ne '' })
    $seen = @{}
    foreach ($id in $ids) {
        $place = $script:GatebComputerAt[$id]
        if (-not $place -or $place.Dim -ne $dim) { continue }
        $key = "$($place.X),$($place.Z)"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $load = "forceload add $($place.X) $($place.Z) $($place.X) $($place.Z)"
        if ($dim -ne 'minecraft:overworld') { $load = "execute in $dim run $load" }
        & $Send $load | Out-Null
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSec)
    $last = ''
    do {
        $last = [string](& $Send $Command)
        if (Test-TurnOnLoaded $last $ids.Count) { return $last }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 1
    } while ($true)
    throw "$body left '$last', wanted $($ids.Count)/$($ids.Count)"
}
