$GatebComputerAt = @{}

function Register-GatebComputerPlace([string]$Command) {
    $dim = 'minecraft:overworld'
    $body = $Command.Trim()
    $execute = [regex]::Match($body, '^execute in (\S+) run (.+)$')
    if ($execute.Success) {
        $dim = $execute.Groups[1].Value
        $body = $execute.Groups[2].Value.Trim()
    }
    $place = [regex]::Match($body, '^setblock (-?\d+) (-?\d+) (-?\d+) computercraft:(?:computer|turtle)_advanced(?:\[[^\]]*\])?\{.*?ComputerId:(\d+)')
    if ($place.Success) {
        $GatebComputerAt[$place.Groups[4].Value] = @{
            X = [int]$place.Groups[1].Value
            Y = [int]$place.Groups[2].Value
            Z = [int]$place.Groups[3].Value
            Dim = $dim
        }
    }
}

function Test-TurnOnLoaded([string]$Reply, [int]$Count) {
    $match = [regex]::Match($Reply, '^Turned on (\d+)/(\d+) computers$')
    if (-not $match.Success) { return $false }
    [int]$match.Groups[2].Value -eq $Count -and $Count -gt 0
}

function Invoke-LoadedTurnOn {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][scriptblock]$Send,
        [int]$WaitSec = 30
    )
    $dim = 'minecraft:overworld'
    $body = $Command.Trim()
    $execute = [regex]::Match($body, '^execute in (\S+) run (.+)$')
    if ($execute.Success) {
        $dim = $execute.Groups[1].Value
        $body = $execute.Groups[2].Value.Trim()
    }
    $turn = [regex]::Match($body, '^computercraft turn-on ([\d ]+)$')
    if (-not $turn.Success) { return (& $Send $Command) }
    $ids = @($turn.Groups[1].Value.Trim() -split '\s+' | Where-Object { $_ -ne '' })
    $seen = @{}
    foreach ($id in $ids) {
        $place = $GatebComputerAt[$id]
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
