$ErrorActionPreference = 'Stop'

function Set-DepthSpaceLimit([int]$Bytes) {
    foreach ($file in @("$TestRoot\config\computercraft-server.toml", "$TestRoot\world\serverconfig\computercraft-server.toml")) {
        $config = [regex]::Replace([IO.File]::ReadAllText($file), 'computer_space_limit\s*=\s*\d+', "computer_space_limit = $Bytes")
        $limits = @([regex]::Matches($config, 'computer_space_limit\s*=\s*(\d+)') | ForEach-Object { $_.Groups[1].Value })
        if ($limits.Count -lt 1 -or @($limits | Where-Object { $_ -ne "$Bytes" }).Count -gt 0) {
            throw "computer_space_limit did not become $Bytes in $file."
        }
        [IO.File]::WriteAllText($file, $config, $utf8)
    }
}

function Copy-DepthText([int]$Id, [string]$Name, [string]$SourcePath) {
    $text = [IO.File]::ReadAllText($SourcePath).Replace("`r`n", "`n")
    $dest = "$TestRoot\world\computercraft\computer\$Id\$Name"
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    [IO.File]::WriteAllText($dest, $text, $utf8)
}

function Copy-DepthProbe([int]$Id, [string]$Name) {
    Copy-DepthText $Id $Name "$PSScriptRoot\$Name"
}

function Set-DepthStartup([int]$Id, [string]$Probe) {
    $body = @"
local ok, err = pcall(function() dofile("$Probe") end)
if not ok and not fs.exists("depth-result.json") then
  local D = dofile("depth-result.lua")
  local checks = {}
  D.check(checks, "probe", false, err)
  D.finish(checks)
end
while true do sleep(5) end
"@
    $path = "$TestRoot\world\computercraft\computer\$Id\startup.lua"
    [IO.File]::WriteAllText($path, ($body.Replace("`r`n", "`n") + "`n"), $utf8)
}

function Set-DepthIdle([int]$Id) {
    $path = "$TestRoot\world\computercraft\computer\$Id\startup.lua"
    [IO.File]::WriteAllText($path, "while true do sleep(5) end`n", $utf8)
}

function Measure-DepthDisk([int]$Limit) {
    $lines = New-Object System.Collections.Generic.List[string]
    $root = "$TestRoot\world\computercraft\computer"
    foreach ($dir in Get-ChildItem $root -Directory) {
        $sum = 0
        Get-ChildItem $dir.FullName -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $sum += $_.Length }
        $lines.Add("$($dir.Name) $sum")
        if ($sum -ge $Limit) { throw "Computer $($dir.Name) holds $sum bytes. The limit is $Limit." }
    }
    [IO.File]::WriteAllLines("$Output\disk-bytes.txt", $lines, $utf8)
}

function Wait-DepthEither([string]$First, [string]$Second, [int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (Test-Path -LiteralPath $First) { return 'first' }
        if (Test-Path -LiteralPath $Second) { return 'second' }
        if ($process -and $process.HasExited) { throw 'Minecraft exited during the scenario.' }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timeout waiting for $First."
}

function Wait-DepthFile([string]$Path, [int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (Test-Path -LiteralPath $Path) { return }
        if ($process -and $process.HasExited) { throw 'Minecraft exited during the scenario.' }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timeout waiting for $Path."
}

function Read-DepthResult([int]$Id, [int]$Seconds) {
    $path = "$TestRoot\world\computercraft\computer\$Id\depth-result.json"
    Wait-DepthFile $path $Seconds
    Copy-Item -LiteralPath $path -Destination "$Output\computer-$Id-depth-result.json" -Force
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Add-DepthFailures($Result, $Problems, [string]$Label) {
    if (-not $Result) { $Problems.Add("$Label wrote no depth result."); return }
    if ($Result.ok) { return }
    foreach ($check in @($Result.checks)) {
        if (-not $check.ok) { $Problems.Add("${Label}: $($check.name): $($check.error)") }
    }
    if (@($Result.checks | Where-Object { -not $_.ok }).Count -eq 0) {
        $Problems.Add("$Label depth result is not ok.")
    }
}

function Get-DepthCount([string]$Pos, [string]$Item) {
    $text = Rcon "data get block $Pos Items[{id:`"$Item`"}].count"
    Add-Content -LiteralPath "$Output\item-counts.txt" -Value "$Pos $Item $text" -Encoding utf8
    if ($text -match '(\d+)\s*$') { return [int]$Matches[1] }
    return 0
}

function Invoke-DepthShot([string]$View, [string]$ShotName) {
    if (-not $Client) { return }
    & "$PSScriptRoot\client.ps1" -TestRoot $TestRoot -Port $port -RconPort $rconPort -Output $Output -Timeout 240 -View $View -ShotName $ShotName
}

function Save-DepthEvidence([string]$Name) {
    $dest = Join-Path $source "docs\evidence\$Name"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $latest = "$TestRoot\logs\latest.log"
    if (Test-Path -LiteralPath $latest) { Copy-Item -LiteralPath $latest -Destination "$Output\latest.log" -Force }
    Get-ChildItem -LiteralPath $Output -File | Copy-Item -Destination $dest -Force
    $computers = "$TestRoot\world\computercraft\computer"
    if (Test-Path -LiteralPath $computers) {
        Get-ChildItem $computers -Recurse -File -Include 'depth-result.json','sandbox-result.json','*.txt','*.jsonl','attempt-*' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $rel = $_.FullName.Substring($computers.Length).TrimStart('\','/')
                $target = Join-Path $dest ("computer" + $rel)
                New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
                Copy-Item -LiteralPath $_.FullName -Destination $target -Force
            }
    }
}

function Complete-Depth([string]$Name, [bool]$Ok, [string]$Detail) {
    $text = if ($Ok) { "PASS`n" } else { "FAIL`n$Detail`n" }
    [IO.File]::WriteAllText("$Output\verdict.txt", $text, $utf8)
    if ($process -and -not $process.HasExited) {
        try { Stop-TestServer } catch { }
    }
    try { Save-DepthEvidence $Name } catch { }
}

function Start-DepthWorld {
    Start-TestServer 'first'
    Rcon 'forceload add 64 64 240 160' | Out-Null
    Rcon 'time set day' | Out-Null
    Rcon 'gamerule doDaylightCycle false' | Out-Null
}
