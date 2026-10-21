$script:H3Utf8 = New-Object Text.UTF8Encoding($false)
function New-H3Disks {
    param([string]$Source, [string]$Computers, [string]$Runtime, [string]$HttpBase,
        [int]$Seconds = 7200, [int]$SpaceLimit = 1000000, [int]$SeedBatches = 4,
        [double]$IntervalSeconds = 2, [string]$QueueConfig = '')
    if ($HttpBase -notmatch '^http://(127\.0\.0\.1|localhost):\d+$') {
        throw 'HTTP fixture must use loopback and an explicit port.'
    }
    foreach ($id in 0..5) {
        $disk = Join-Path $Computers $id
        New-Item -ItemType Directory -Force -Path $disk | Out-Null
        foreach ($file in Get-ChildItem -LiteralPath $Source -Filter '*.lua') {
            if ($id -eq 0 -and $file.Name -eq 'buddy.lua') { continue }
            [IO.File]::WriteAllText("$disk\$($file.Name)", [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n"), $script:H3Utf8)
        }
        Copy-Item -LiteralPath "$Source\tests\h3-driver.lua", "$Source\tests\h3-runtime.lua", "$Source\tests\sandbox\turtle.lua" -Destination $disk
        $config = '{seconds=' + $Seconds + ',spaceLimit=' + $SpaceLimit + ',seedBatches=' + $SeedBatches + ',intervalSeconds=' + $IntervalSeconds.ToString([Globalization.CultureInfo]::InvariantCulture) + ',sampleSeconds=60,timeoutSeconds=240,retrySeconds=30,httpDelaySeconds=6,httpBase="' + $HttpBase + '",secret="test-secret-123456",poses={{dim="minecraft:overworld",x=-6,y=65,z=0},{dim="minecraft:overworld",x=-2,y=65,z=0},{dim="minecraft:overworld",x=2,y=65,z=0},{dim="minecraft:overworld",x=6,y=65,z=0}}}'
        [IO.File]::WriteAllText("$disk\h3.cfg", $config, $script:H3Utf8)
        $ssot = '{controllers={["1"]="test-secret-123456",["2"]="test-secret-123456",["3"]="test-secret-123456",["4"]="test-secret-123456",["5"]="test-secret-123456"},maxChunks=64,leaseMs=30000,' + $QueueConfig + '}'
        [IO.File]::WriteAllText("$disk\ssot.cfg", $ssot, $script:H3Utf8)
        [IO.File]::WriteAllText("$disk\startup.lua", "shell.run('h3-driver.lua', '$Runtime')", $script:H3Utf8)
        $bytes = (Get-ChildItem -LiteralPath $disk -File | Measure-Object Length -Sum).Sum
        if ($bytes -gt $SpaceLimit - 1800000) { throw "H3 disk $id has insufficient room for state and soak logs. Used $bytes." }
    }
}
function Start-H3Http {
    param([string]$Source, [string]$Output, [int]$Port, [string]$Bind = '127.0.0.1')
    $python = 'C:\Tools\python\cpython-3.12.15-windows-x86_64-none\python.exe'
    $arguments = @(('"' + "$Source\tests\h3-http.py" + '"'), '--root', ('"' + $Source + '"'),
        '--log', ('"' + "$Output\http.jsonl" + '"'), '--port', $Port, '--bind', $Bind,
        '--ready-file', ('"' + "$Output\http-ready.json" + '"'))
    $process = Start-Process -FilePath $python -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$Output\http-stdout.log" -RedirectStandardError "$Output\http-stderr.log"
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    do {
        if ($process.HasExited) { throw "HTTP fixture exited. See $Output\http-stderr.log." }
        if (Test-Path -LiteralPath "$Output\http-ready.json") {
            $status = [IO.File]::ReadAllText("$Output\http-ready.json") | ConvertFrom-Json
            if ($status.port -eq $Port) { return $process }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    Stop-Process -Id $process.Id -Force
    throw 'HTTP fixture did not start.'
}
function Test-H3Results {
    param([string]$Computers, [string]$Output, [switch]$RequireFullSoak)
    $failures = @()
    $reports = @()
    foreach ($id in 0..5) {
        $path = "$Computers\$id\sandbox-result.json"
        if (!(Test-Path -LiteralPath $path)) { $failures += "Missing computer $id result."; continue }
        $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $reports += $report
        if (!$report.ok) { $failures += "Computer $id failed. $($report.errors -join '; ')" }
        if ($report.capacity -ne 1000000 -or $report.free -lt 8192) { $failures += "Computer $id exceeded the disk budget." }
    }
    $summary = $null
    $path = "$Computers\5\h3-summary.json"
    if (Test-Path -LiteralPath $path) {
        $summary = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if (!$summary.ok -or $summary.revision -ne $summary.mutations -or $summary.turtles -ne 4) { $failures += 'H3 mutation accounting failed.' }
        if ($RequireFullSoak -and !$summary.fullSoak) { $failures += 'The required two-hour soak did not run.' }
        $httpRows = @([IO.File]::ReadAllLines("$Output\http.jsonl") | ForEach-Object { $_ | ConvertFrom-Json })
        $token = $summary.batches.http.window.token
        $started = @($httpRows | Where-Object { $_.event -eq 'start' -and $_.token -eq $token })
        $ended = @($httpRows | Where-Object { $_.event -eq 'end' -and $_.token -eq $token })
        if ($started.Count -ne 1 -or $ended.Count -ne 1 -or ($ended[0].atMs - $started[0].atMs) -lt 5900) {
            $failures += 'The HTTP fixture did not record the delayed request.'
        }
    } else { $failures += 'Missing H3 summary.' }
    $result = [ordered]@{ ok = $failures.Count -eq 0; scenario = 'h3'; fullSoak = [bool]($summary -and $summary.fullSoak)
        gateEligible = [bool]($failures.Count -eq 0 -and $summary -and $summary.fullSoak); errors = @($failures); runtime = $summary }
    [IO.File]::WriteAllText("$Output\h3-results.json", ($result | ConvertTo-Json -Depth 40), $script:H3Utf8)
    if ($failures.Count) { throw ($failures -join "`n") }
    Write-Output "H3 runtime checks passed. Full soak $($result.fullSoak). Gate eligible $($result.gateEligible)."
}
