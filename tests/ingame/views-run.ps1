param([string]$Base='C:\mc-cc-test\base',
    [string]$Battery='C:\Work\gemini-input\p2\turtlebattery-0.3.0.jar',
    [string]$Output='C:\Work\gemini-input\p2\evidence\pr5\gateB',
    [string]$TestRoot='', [int]$Timeout=600,[switch]$Client)
$ErrorActionPreference='Stop'
if ($Output -eq 'C:\Work\gemini-input\p2\evidence\pr1\gateB') { $Output='C:\Work\gemini-input\p2\evidence\pr5\gateB' }
if (!$TestRoot) { $TestRoot='C:\Work\mc-ssot-pr5-'+[guid]::NewGuid().ToString('N').Substring(0,8) }
$TestRoot=[IO.Path]::GetFullPath($TestRoot)
if (!$TestRoot.StartsWith('C:\Work\mc-ssot-pr5-')) { throw 'Views requires a fresh mc-ssot-pr5 test root.' }
. "$PSScriptRoot\rcon.ps1"
$source=(Resolve-Path "$PSScriptRoot\..\..").Path
$utf8=New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $Output | Out-Null
& "$PSScriptRoot\run.ps1" -Scenario views -PrepareOnly -Base $Base -Battery $Battery -Output $Output -TestRoot $TestRoot
$tom=Get-ChildItem 'C:\mc-cc-test\jars\cc' -Filter 'toms-peripherals-*.jar' -ErrorAction SilentlyContinue | Select-Object -First 1
if (!$tom) { $tom=Get-ChildItem "$Base\mods" -Filter 'toms-peripherals-*.jar' -ErrorAction SilentlyContinue | Select-Object -First 1 }
if (!$tom) { throw 'Tom Peripherals jar is required for the secondary backend gate.' }
Copy-Item -LiteralPath $tom.FullName -Destination "$TestRoot\mods"
Get-ChildItem "$TestRoot\mods" | Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash) $([IO.Path]::GetFileName($_.Path))" } | Set-Content "$Output\jar-sha256.txt"
$properties=Get-Content "$TestRoot\server.properties"
$port=[int](($properties | Where-Object {$_ -like 'server-port=*'}).Substring(12))
$rconPort=[int](($properties | Where-Object {$_ -like 'rcon.port=*'}).Substring(10))
$secret=($properties | Where-Object {$_ -like 'rcon.password=*'}).Substring(14)
foreach ($id in @(0,1,2,3,4,6,7,8,9)) {
    $disk="$TestRoot\world\computercraft\computer\$id"
    New-Item -ItemType Directory -Force -Path $disk | Out-Null
    Get-ChildItem "$source\*.lua" | Copy-Item -Destination $disk
    Copy-Item "$source\tests\views-runtime.lua" $disk
    Copy-Item "$PSScriptRoot\views-gpu-checks.lua" $disk
    [IO.File]::WriteAllText("$disk\ssot.cfg",'{controllers={["1"]="test-secret-123456",["2"]="test-secret-123456",["3"]="test-secret-123456",["4"]="test-secret-123456",["6"]="test-secret-123456",["7"]="test-secret-123456",["8"]="test-secret-123456"},leaseMs=30000,maxChunks=8}',$utf8)
    [IO.File]::WriteAllText("$disk\startup.lua",'while not peripheral.find("modem") do sleep(0.2) end; shell.run("views-runtime.lua","minecraft")',$utf8)
}
$sourceProof=foreach ($file in Get-ChildItem "$source\*.lua") {
    $expected=(Get-FileHash $file.FullName -Algorithm SHA256).Hash
    foreach ($id in @(0,1,2,3,4,6,7,8,9)) {
        $actual=(Get-FileHash "$TestRoot\world\computercraft\computer\$id\$($file.Name)" -Algorithm SHA256).Hash
        if ($actual -ne $expected) { throw "Copied source differs for computer $id file $($file.Name)." }
        [pscustomobject]@{computer=$id;file=$file.Name;sha256=$actual}
    }
}
$sourceProof | ConvertTo-Json | Set-Content "$Output\source-sha256.json"
$process=$null
$lock='C:\Work\gemini-input\p2\gateB.lock'
$locked=$false
function Rcon([string]$Command) {
    $answer=Invoke-TestRcon $rconPort $secret $Command
    "$([DateTime]::UtcNow.ToString('o')) > $Command`n$answer" | Add-Content "$Output\rcon.txt"
    $answer
}
function Wait-ViewsFile([string]$Path) {
    $end=[DateTime]::UtcNow.AddSeconds($Timeout)
    do {
        if (Test-Path -LiteralPath $Path) { return }
        if ($process.HasExited) { throw 'Views server exited.' }
        foreach ($request in Get-ChildItem "$TestRoot\world\computercraft\computer\0" -Filter 'restart-request-*.json') {
            $restart=Get-Content $request.FullName -Raw | ConvertFrom-Json
            if ($restart.id -notin @(1,2,3)) { throw 'Invalid test turtle reboot request.' }
            $turtleDisk="$TestRoot\world\computercraft\computer\$($restart.id)"
            $saved="$Output\recovery-$($restart.id)-$([DateTime]::UtcNow.Ticks)"
            New-Item -ItemType Directory -Path $saved | Out-Null
            Copy-Item "$turtleDisk\nav.state", "$turtleDisk\ssot.counter" $saved
            Rcon "computercraft shutdown $($restart.id)" | Out-Null
            Start-Sleep -Seconds 1
            Move-Item -LiteralPath $request.FullName -Destination "$saved\request.json"
            Rcon "computercraft turn-on $($restart.id)" | Out-Null
        }
        $fail=Get-ChildItem "$TestRoot\world\computercraft\computer" -Recurse -Filter sandbox-result.json |
            ForEach-Object {Get-Content $_.FullName -Raw | ConvertFrom-Json} | Where-Object {!$_.ok}
        if ($fail) { throw ($fail.errors -join '; ') }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $end)
    throw "Timeout waiting for $Path"
}
function Start-ViewsServer([string]$Phase) {
    foreach ($checkPort in @($port,$rconPort)) {
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$checkPort)
        try { $listener.Start() } finally { $listener.Stop() }
    }
    $script:process=Start-Process 'C:\mc-cc-test\jdk\jdk-21.0.12.1+1\bin\java.exe' -WorkingDirectory $TestRoot -WindowStyle Hidden -PassThru -ArgumentList @('-Xms1G','-Xmx3G',"-Dssot.test.root=$TestRoot",'@libraries/net/neoforged/neoforge/21.1.259/win_args.txt','nogui') -RedirectStandardOutput "$TestRoot\stdout-$Phase.log" -RedirectStandardError "$TestRoot\stderr-$Phase.log"
    [IO.File]::WriteAllText("$Output\server.pid",[string]$process.Id)
    $end=[DateTime]::UtcNow.AddSeconds($Timeout)
    do {
        if ($process.HasExited) { throw 'Views server failed to boot.' }
        try { if ((Rcon 'list') -match 'players online') { return } } catch {}
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $end)
    throw 'Views server boot timeout.'
}
function Stop-ViewsServer {
    if ($process -and !$process.HasExited) {
        try { Rcon 'stop' | Out-Null } catch {}
        if (!$process.WaitForExit(45000)) { Stop-Process -Id $process.Id -Force; $process.WaitForExit() }
    }
}
try {
    $waitStart=[DateTime]::UtcNow
    while (!$locked) {
        try {
            New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
            $locked=$true
            [IO.File]::WriteAllText("$lock\owner.txt",'PR5')
        } catch {
            if ([DateTime]::UtcNow-$waitStart -gt [TimeSpan]::FromHours(3)) { throw 'Gate B lock wait exceeded three hours.' }
            Write-Output 'PR5 waiting for Gate B lock.'
            Start-Sleep -Seconds 60
        }
    }
    do {
        $others=@(Get-CimInstance Win32_Process -Filter "Name='java.exe'" | Where-Object {
            $candidate=$_
            if ($candidate.CommandLine -match 'C:[/\\]Work[/\\]mc-ssot-') {
                $candidate.CommandLine -notlike "*$TestRoot*"
            } elseif ($candidate.CommandLine -match 'neoforge.+win_args.+nogui') {
                $properties=& 'C:\mc-cc-test\jdk\jdk-21.0.12.1+1\bin\jcmd.exe' $candidate.ProcessId VM.system_properties 2>$null
                $candidateDirectory=($properties | Where-Object { $_ -like 'user.dir=*' } | Select-Object -First 1)
                if ($candidateDirectory) {
                    $candidateDirectory=$candidateDirectory.Substring(9).Replace('\:',':').Replace('\\','\').Replace('/','\')
                    $candidateDirectory.StartsWith('C:\Work\mc-ssot-',[StringComparison]::OrdinalIgnoreCase)
                } else { $false }
            }
        })
        $free=[double](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory*1024
        if (!$others.Count -and $free -ge 5GB) { break }
        if ([DateTime]::UtcNow-$waitStart -gt [TimeSpan]::FromHours(3)) { throw 'Gate B resource wait exceeded three hours.' }
        Write-Output 'PR5 waiting for other test servers and 5 GB free RAM.'
        Start-Sleep -Seconds 60
    } while ($true)
    Start-ViewsServer 'first'
    foreach ($command in @('forceload add -16 -16 31 31','fill -12 64 -12 24 64 14 minecraft:stone',
        'fill -12 65 -12 24 72 14 minecraft:air','time set day','weather clear',
        'fill -2 66 4 2 66 4 minecraft:iron_ore',
        'setblock -5 65 0 minecraft:chest','setblock 5 65 0 minecraft:chest',
        'setblock -4 65 -4 computercraft:computer_advanced{ComputerId:0}',
        'setblock -4 66 -4 computercraft:wireless_modem_advanced[facing=down]',
        'setblock 4 65 -4 computercraft:computer_advanced{ComputerId:4}',
        'setblock 4 66 -4 computercraft:wireless_modem_advanced[facing=down]')) { Rcon $command | Out-Null }
    for ($id=1;$id -le 3;$id++) {
        $z=($id-2)*3
        Rcon "setblock -2 65 $z computercraft:turtle_advanced[facing=east]{ComputerId:$id,Fuel:10000,RightUpgrade:`"computercraft:wireless_modem_advanced`"}" | Out-Null
    }
    $hosts=@(@(-6,65,-6),@(6,65,-6),@(-6,65,6),@(-6,71,-6))
    for ($i=0;$i -lt $hosts.Count;$i++) {
        $p=$hosts[$i];$gpsId=$i+10
        Rcon "setblock $($p[0]) $($p[1]) $($p[2]) computercraft:computer_advanced{ComputerId:$gpsId}" | Out-Null
        Rcon "setblock $($p[0]) $($p[1]+1) $($p[2]) computercraft:wireless_modem_normal[facing=down]" | Out-Null
    }
    foreach ($id in @(6,7,8)) {
        $x=($id-6)*7
        Rcon "setblock $x 65 8 computercraft:computer_advanced{ComputerId:$id}" | Out-Null
        Rcon "setblock $x 66 8 computercraft:wireless_modem_advanced[facing=down]" | Out-Null
    }
    Rcon 'setblock 1 65 8 directgpu:gpu_block' | Out-Null
    Rcon 'setblock 0 65 9 computercraft:monitor_advanced[facing=south]' | Out-Null
    Rcon 'setblock 8 65 8 directgpu:gpu_block' | Out-Null
    Rcon 'fill 6 65 9 8 66 9 computercraft:monitor_advanced[facing=south]' | Out-Null
    Rcon 'fill 13 65 9 15 66 9 computercraft:monitor_normal[facing=south]' | Out-Null
    foreach ($position in @('-1 65 8','-2 65 8','-3 65 8','-3 65 9',
        '6 65 8','5 65 8','4 65 8','4 65 9','4 65 10','4 65 11')) {
        Rcon "setblock $position computercraft:wired_modem_full[peripheral=true]" | Out-Null
    }
    Rcon 'setblock -3 65 10 computercraft:monitor_advanced[facing=south]' | Out-Null
    Rcon 'setblock 4 65 12 computercraft:monitor_advanced[facing=south]' | Out-Null
    Rcon 'setblock 20 65 8 computercraft:computer_advanced{ComputerId:9}' | Out-Null
    Rcon 'setblock 20 66 8 computercraft:wireless_modem_advanced[facing=down]' | Out-Null
    Rcon 'setblock 21 65 8 toms_peripherals:gpu' | Out-Null
    Rcon 'setblock 22 65 8 toms_peripherals:monitor' | Out-Null
    Rcon 'computercraft turn-on 10 11 12 13 0' | Out-Null
    Start-Sleep -Seconds 3
    Rcon 'computercraft turn-on 1 2 3 4 6 7 8 9' | Out-Null
    Wait-ViewsFile "$TestRoot\world\computercraft\computer\4\views-ready.json"
    foreach ($id in @(1,2,3,6,7,8,9)) { Wait-ViewsFile "$TestRoot\world\computercraft\computer\$id\sandbox-result.json" }
    Rcon 'tick query' | Set-Content "$Output\tick-before-client.txt"
    if ($Client) {
        & "$PSScriptRoot\views-network.ps1" -Action Start -ServerPid $process.Id -TestRoot $TestRoot -OutputDirectory "$Output\network"
        try {
            & "$PSScriptRoot\client.ps1" -TestRoot $TestRoot -Port $port -RconPort $rconPort -Output $Output -View views -Timeout $Timeout
        } finally {
            & "$PSScriptRoot\views-network.ps1" -Action Stop -ServerPid $process.Id -TestRoot $TestRoot -OutputDirectory "$Output\network"
        }
    } else { throw 'Views Gate B requires -Client and the four real framebuffer screenshots.' }
    Stop-ViewsServer
    foreach ($id in @(0,1,2,3,4,6,7,8,9)) {
        $marker="$TestRoot\world\computercraft\computer\$id\sandbox-result.json"
        if (Test-Path $marker) { Move-Item -LiteralPath $marker -Destination ($marker+'.before-restart') }
    }
    Start-ViewsServer 'restart'
    Rcon 'computercraft turn-on 0 10 11 12 13 1 2 3 4 6 7 8 9' | Out-Null
    Wait-ViewsFile "$TestRoot\world\computercraft\computer\4\views-restarted.json"
    Rcon 'setblock 8 66 9 minecraft:air' | Out-Null
    Start-Sleep -Seconds 2
    Rcon 'setblock 8 66 9 computercraft:monitor_advanced[facing=south]' | Out-Null
    [IO.File]::WriteAllText("$TestRoot\world\computercraft\computer\7\rebuild-request",'require a new production display')
    Wait-ViewsFile "$TestRoot\world\computercraft\computer\7\views-rebuilt.json"
    Rcon 'tick query' | Set-Content "$Output\tick-after-rebuild.txt"
    foreach ($id in @(0,1,2,3,4,6,7,8,9)) {
        Wait-ViewsFile "$TestRoot\world\computercraft\computer\$id\sandbox-result.json"
    }
    foreach ($name in @('directgpu-single.png','directgpu-wall.png','hub-pro-ingame.png','warehouse-normal-ingame.png')) {
        if (!(Test-Path "$Output\$name")) { throw "Missing real client screenshot $name." }
    }
    $click=Get-Content "$TestRoot\world\computercraft\computer\6\client-click-result.json" -Raw | ConvertFrom-Json
    if (!$click.ok) { throw 'Real client target click did not move the production turtle.' }
    $network=Get-Content "$Output\network\views-network-summary.json" -Raw | ConvertFrom-Json
    if (!$network.measured) { throw 'JFR did not emit measurable network writes. Bandwidth gate is unverified.' }
    foreach ($id in @(6,7)) {
        $selection=Get-Content "$TestRoot\world\computercraft\computer\$id\directgpu-selection.json" -Raw | ConvertFrom-Json
        if (!$selection.ok) { throw "Computer $id did not verify adjacent and wired monitor selection." }
    }
    [IO.File]::WriteAllText("$Output\verdict.txt",'PASS')
} catch {
    [IO.File]::WriteAllText("$Output\verdict.txt","FAIL`n$($_.Exception.Message)")
    throw
} finally {
    Stop-ViewsServer
    $pidPath="$TestRoot\client\process.id"
    if (Test-Path $pidPath) {
        $ownedId=[int]([IO.File]::ReadAllText($pidPath))
        $owned=Get-CimInstance Win32_Process -Filter "ProcessId=$ownedId" -ErrorAction SilentlyContinue
        if ($owned -and $owned.CommandLine.Contains($TestRoot.Replace('\','/'))) {
            Stop-Process -Id $ownedId -Force
            Wait-Process -Id $ownedId -ErrorAction SilentlyContinue
        }
    }
    if ($locked) { Remove-Item -LiteralPath "$lock\owner.txt"; Remove-Item -LiteralPath $lock }
    if (Test-Path "$TestRoot\logs\latest.log") { Copy-Item "$TestRoot\logs\latest.log" "$Output\latest.log" -Force }
    Copy-Item "$TestRoot\world\computercraft\computer" "$Output\computers" -Recurse -Force
}
