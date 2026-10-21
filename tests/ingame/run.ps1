param(
    [ValidateSet('ssot','nav','mining','warehouse','ar','views','room','craft','wizard','dropoff','devmode','faults','disk1mb','events','fuzz','update','soak')][string]$Scenario = 'ssot',
    [string]$Base = 'C:\mc-cc-test\base',
    [string]$Battery = 'C:\Work\gemini-input\p2\turtlebattery-0.3.0.jar',
    [string]$Output = 'C:\Work\gemini-input\p2\evidence\pr1\gateB',
    [string]$TestRoot = '',
    [int]$Timeout = 600,
    [ValidateSet('Auto','Box','Local')][string]$HostKind = 'Auto',
    [int]$SpaceLimit = 4000000,
    [switch]$PrepareOnly,
    [switch]$Client,
    [switch]$ResumeProbes,
    [switch]$Fleet,
    [switch]$Prepared
)
$ErrorActionPreference = 'Stop'
if ($Scenario -eq 'ar') {
    & "$PSScriptRoot\ar.ps1" -Base $Base -Battery $Battery -Output $Output -TestRoot $TestRoot -Timeout $Timeout -HostKind $HostKind -SpaceLimit $SpaceLimit -PrepareOnly:$PrepareOnly -Client:$Client
    return
}
if ($Scenario -eq 'views' -and !$PrepareOnly) {
    & "$PSScriptRoot\views-run.ps1" -Base $Base -Battery $Battery -Output $Output -TestRoot $TestRoot -Timeout $Timeout -Client:$Client
    return
}
if ($Scenario -in @('nav','mining','warehouse')) { [Diagnostics.Process]::GetCurrentProcess().PriorityClass='High' }
. "$PSScriptRoot\rcon.ps1"
$source = (Resolve-Path "$PSScriptRoot\..\..").Path
$utf8 = New-Object Text.UTF8Encoding($false)
$prefix = if ($Scenario -eq 'views') { 'C:\Work\mc-ssot-pr5-' } elseif ($Fleet) { 'C:\Work\mc-wh2-fleet-' } else { 'C:\Work\mc-ssot-pr1-' }
if (!$TestRoot) { $TestRoot = $prefix + [guid]::NewGuid().ToString('N').Substring(0, 8) }
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (!$TestRoot.StartsWith($prefix)) { throw "TestRoot must be a dedicated $prefix directory." }
if ($ResumeProbes -and ($Scenario -ne 'warehouse' -or !(Test-Path "$TestRoot\server.properties"))) { throw 'Probe resume requires an existing warehouse test world.' }
if (!$ResumeProbes -and !$Prepared) {
if (Test-Path "$TestRoot\server.properties") { throw 'Use a fresh test directory.' }
New-Item -ItemType Directory -Force -Path $TestRoot, $Output, "$TestRoot\mods", "$TestRoot\config", "$TestRoot\world\serverconfig" | Out-Null
New-Item -ItemType Junction -Path "$TestRoot\libraries" -Target "$Base\libraries" | Out-Null
$patterns = @('cc-tweaked-1.21.1-forge-1.120.2.jar','classicperipherals-neoforge-1.21.1-0.6.5.jar',
    'AdvancedPeripherals-*.jar','turtlematic-*.jar','cc_ar-*.jar','directgpu-*.jar','kotlinforforge-*.jar',
    'superbwarfare-*.jar','turtlematicfix-*.jar','recipe_index-*.jar','*tweakium*.jar','*broccolium*.jar','*peripheralium*.jar')
foreach ($pattern in $patterns) {
    Get-ChildItem "$Base\mods" -Filter $pattern | Copy-Item -Destination "$TestRoot\mods"
}
Copy-Item -LiteralPath $Battery -Destination "$TestRoot\mods\turtlebattery-0.3.0.jar"
Copy-Item 'C:\Work\gemini-input\p2\classicperipherals.toml' "$TestRoot\config\classicperipherals.toml"
. "$PSScriptRoot\disk-limit.ps1"
$diskLimit = $script:GateComputerSpaceLimit
foreach ($file in @('computercraft-server.toml')) {
    $config = [regex]::Replace([IO.File]::ReadAllText("$Base\config\$file"), 'computer_space_limit\s*=\s*\d+', "computer_space_limit = $diskLimit")
    $limits = @([regex]::Matches($config, 'computer_space_limit\s*=\s*(\d+)') | ForEach-Object { $_.Groups[1].Value })
    if ($limits.Count -lt 1 -or @($limits | Where-Object { $_ -ne "$diskLimit" }).Count -gt 0) {
        throw "computer_space_limit in $file did not become $diskLimit."
    }
    [IO.File]::WriteAllText("$TestRoot\config\$file", $config, $utf8)
    [IO.File]::WriteAllText("$TestRoot\world\serverconfig\$file", $config, $utf8)
}
function Get-FreePort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $port
}
$port = Get-FreePort
$rconPort = Get-FreePort
while ($rconPort -eq $port) { $rconPort = Get-FreePort }
$password = [guid]::NewGuid().ToString('N')
$properties = @('level-name=world','online-mode=false',"server-port=$port",'server-ip=127.0.0.1',
    'spawn-protection=0','view-distance=3','simulation-distance=3','enable-rcon=true',"rcon.port=$rconPort",
    "rcon.password=$password",'gamemode=creative','difficulty=peaceful','allow-flight=true','max-tick-time=-1',
    'level-type=minecraft:flat','generate-structures=false','motd=Disposable SSOT PR 1 test')
[IO.File]::WriteAllLines("$TestRoot\server.properties", $properties, $utf8)
[IO.File]::WriteAllText("$TestRoot\eula.txt", 'eula=true', $utf8)
. "$PSScriptRoot\role-closure.ps1"
$computerIds=if($Scenario -eq 'mining'){@(0,1,2,3,4,6)}else{@(0,1,2,3,4)}
if($Scenario -eq 'warehouse'){$computerIds+=21}
foreach ($id in $computerIds) {
    $disk = "$TestRoot\world\computercraft\computer\$id"
    New-Item -ItemType Directory -Force -Path $disk | Out-Null
    if (-not $Fleet -and $Scenario -in @('ssot','nav','mining','warehouse')) {
        Write-GateRoleFiles -Disk $disk -Source $source -Entry (Get-GateEntries $source $Scenario $id) -Utf8 $utf8 | Out-Null
    } else {
        $fleetFiles=@('server.lua','hub.lua','miner.lua','update.lua','fleetview.lua','atomic.lua','ssot.lua','ssot-client.lua',
            'nav.lua','mine-tasks.lua','mining.lua','warehouse-tasks.lua','warehouse.lua','store.lua','ssot-auth.lua','sha2.lua','ssot-queue.lua')
        foreach ($file in (Get-ChildItem "$source\*.lua" | Where-Object { -not $Fleet -or $_.Name -in $fleetFiles -or $_.Name -like 'wh2-*.lua' })) {
            [IO.File]::WriteAllText("$disk\$($file.Name)", [IO.File]::ReadAllText($file.FullName).Replace("`r`n","`n"), $utf8)
        }
        Copy-Item "$source\tests\ssot-runtime.lua", "$source\tests\gate-disk.lua", "$PSScriptRoot\nav-probe.lua", "$source\tests\mining-runtime.lua", "$source\tests\mining-fixture.lua", "$source\tests\warehouse-runtime.lua", "$source\tests\warehouse-fixture.lua" $disk
        Copy-Item "$PSScriptRoot\server.lua" "$disk\test-server.lua"
    }
    [IO.File]::WriteAllText("$disk\ssot.cfg", '{controllers={["1"]="test-secret-123456",["2"]="test-secret-123456",["3"]="test-secret-123456",["4"]="test-secret-123456"},leaseMs=30000,maxChunks=8}', $utf8)
    $startup = if ($id -eq 0) { 'shell.run("test-server.lua")' } else {
        'peripheral.find("modem", rednet.open); shell.run("ssot-runtime.lua", "minecraft", "' + $Scenario + '", "' + $diskLimit + '")'
    }
    if ($Scenario -eq 'warehouse') { $startup = $startup.Replace('ssot-runtime.lua','warehouse-runtime.lua') }
    if ($Scenario -eq 'warehouse' -and $id -eq 21) {
        Copy-Item "$PSScriptRoot\loader-guardian.lua" "$disk\loader-guardian.lua"
        $startup='shell.run("loader-guardian.lua")'
    }
    if ($Scenario -eq 'mining') { $startup = $startup.Replace('ssot-runtime.lua','mining-runtime.lua') }
    if ($Scenario -eq 'mining' -and $id -eq 6) {
        $startup = 'http=nil; parallel.waitForAny(function() shell.run("hub.lua") end,function() sleep(10); local h=assert(fs.open("sandbox-result.json","w")); h.write(textutils.serializeJSON({ok=true,booted=true,errors={},lines={"production hub running during mining"}})); h.close(); while true do sleep(1) end end)'
    }
    if ($Scenario -eq 'nav' -and $id -eq 3) { $startup = 'if fs.exists("nav-probe") then shell.run("nav-probe.lua") else ' + $startup + ' end' }
    $startup = 'while fs.exists("boot-hold") do sleep(0.1) end; while not peripheral.find("modem") do sleep(0.1) end; ' + $startup
    [IO.File]::WriteAllText("$disk\startup.lua", $startup, $utf8)
}
$hosts = @(@(-6,65,-6),@(6,65,-6),@(-6,65,6),@(-6,71,-6))
for ($index = 0; $index -lt $hosts.Count; $index++) {
    $disk = "$TestRoot\world\computercraft\computer\$($index + 10)"
    New-Item -ItemType Directory -Force -Path $disk | Out-Null
    $point = $hosts[$index]
    [IO.File]::WriteAllText("$disk\startup.lua", "while not peripheral.find('modem') do sleep(0.1) end; sleep(0); local h=fs.open('gps-host-ready','w'); h.write('ready'); h.close(); shell.run('gps', 'host', '$($point[0])', '$($point[1])', '$($point[2])')", $utf8)
}
Get-ChildItem "$TestRoot\mods" | Get-FileHash -Algorithm SHA256 | ForEach-Object { "$($_.Hash) $([IO.Path]::GetFileName($_.Path))" } | Set-Content "$Output\jar-sha256.txt"
[IO.File]::WriteAllText("$Output\test-location.txt", "$TestRoot`nlocalhost:$port`nRCON localhost:$rconPort`n", $utf8)
} else {
    $properties=Get-Content "$TestRoot\server.properties" -Raw | ConvertFrom-StringData
    if($properties['server-ip'] -ne '127.0.0.1' -or $properties['online-mode'] -ne 'false'){throw 'Resume requires a loopback offline test server.'}
    $port=[int]$properties['server-port']; $rconPort=[int]$properties['rcon.port']; $password=$properties['rcon.password']
    $manifest=@(Get-ChildItem "$TestRoot\mods" | Get-FileHash -Algorithm SHA256 | ForEach-Object { "$($_.Hash) $([IO.Path]::GetFileName($_.Path))" })
    if(Compare-Object $manifest @(Get-Content "$Output\jar-sha256.txt")){throw 'The probe world mod set changed.'}
    if ($ResumeProbes) {
    & "$PSScriptRoot\verify-warehouse.ps1" -Computers "$TestRoot\world\computercraft\computer" -Output $Output
    $archive="$Output\before-resume-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $archive | Out-Null
    Get-ChildItem $Output -File | Copy-Item -Destination $archive
    $probe="$TestRoot\world\computercraft\computer\20"
    Copy-Item $probe "$archive\probe" -Recurse
    Get-ChildItem $probe -File | Where-Object {$_.Name -match '^(charge-.*\.json|.*-ready\.json|unload-heartbeat\.json|.*-go)$'} | Remove-Item
    Copy-Item "$PSScriptRoot\charge-probe.lua" "$probe\startup.lua" -Force
    Write-Output 'Resuming hardware probes after validating the completed warehouse world and unchanged production files.'
    }
}
Write-Output "Test directory $TestRoot. Minecraft localhost:$port."
if ($PrepareOnly) { return }
$java = 'C:\mc-cc-test\jdk\jdk-21.0.12.1+1\bin\java.exe'
$script:process = $null
function Start-TestServer([string]$Label) {
    if ($Fleet) {
        $fleetOwnerPath='C:\Work\gemini-input\p2\gateB.lock\owner.txt'
        if (!(Test-Path -LiteralPath $fleetOwnerPath) -or [IO.File]::ReadAllText($fleetOwnerPath) -ne 'fleet') {
            throw 'Fleet must hold the Gate B lock before starting Java.'
        }
        if ((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory*1KB -lt 5GB) {
            throw 'Fleet needs at least 5 GB free RAM before starting Java.'
        }
        foreach ($fleetPort in @($port,$rconPort)) {
            $fleetListener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$fleetPort)
            try { $fleetListener.Start() } finally { $fleetListener.Stop() }
        }
    }
    $script:process = Start-Process -FilePath $java -WorkingDirectory $TestRoot -WindowStyle Hidden -PassThru -ArgumentList @('-Xms1G','-Xmx3G','@libraries/net/neoforged/neoforge/21.1.259/win_args.txt','nogui') -RedirectStandardOutput "$TestRoot\stdout-$Label.log" -RedirectStandardError "$TestRoot\stderr-$Label.log"
    if ($Fleet) { Add-Content -LiteralPath "$Output\owned-java-pids.txt" -Value $script:process.Id }
    $script:process.PriorityClass = if ($Scenario -in @('nav','mining','warehouse')) { 'High' } else { 'AboveNormal' }
    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    do {
        if ($script:process.HasExited) { throw "Minecraft exited during $Label boot. See $TestRoot." }
        try { $pong = Invoke-TestRcon $rconPort $password 'list'; if ($pong -match 'players online') { return } } catch { }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Minecraft boot timeout.'
}
function Rcon([string]$Command) {
    $response = Invoke-TestRcon $rconPort $password $Command
    $record=$utf8.GetBytes("$([DateTime]::UtcNow.ToString('o')) > $Command`n$response`n")
    $stream=[IO.File]::Open("$Output\rcon.txt",[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    try {$stream.Write($record,0,$record.Length)} finally {$stream.Dispose()}
    $response
}
function Stop-TestServer {
    if ($script:process -and !$script:process.HasExited) {
        Rcon 'stop' | Out-Null
        if (!$script:process.WaitForExit(60000)) { Stop-Process -Id $script:process.Id -Force; throw 'Test server did not stop cleanly.' }
    }
}
function Wait-File([string]$Path) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    do {
        $mazeDisk="$TestRoot\world\computercraft\computer\3"
        if ($Scenario -eq 'nav' -and (Test-Path "$mazeDisk\nav-fixture-ready.json") -and !(Test-Path "$mazeDisk\nav-fixture-installed")) {
            foreach ($command in @('setblock 1 67 0 minecraft:glass','setblock 3 67 0 minecraft:glass',
                'setblock 2 67 -1 minecraft:glass','setblock 2 67 1 minecraft:glass','setblock 2 67 0 minecraft:water')) { Rcon $command | Out-Null }
            [IO.File]::WriteAllText("$mazeDisk\nav-fixture-installed", 'ready', $utf8)
        }
        if ($Scenario -eq 'nav' -and (Test-Path "$mazeDisk\nav-fluid-ready.json") -and !(Test-Path "$mazeDisk\nav-fluid-cleared")) {
            Rcon 'setblock 2 67 0 minecraft:air' | Out-Null
            [IO.File]::WriteAllText("$mazeDisk\nav-fluid-cleared", 'ready', $utf8)
        }
        if ($Scenario -eq 'nav' -and (Test-Path "$mazeDisk\nav-gravel.json") -and !(Test-Path "$mazeDisk\nav-gravel.continue")) {
            Rcon 'fill 4 67 1 4 68 1 minecraft:gravel' | Out-Null
            [IO.File]::WriteAllText("$mazeDisk\nav-gravel.continue", 'ready', $utf8)
        }
        if ($Scenario -eq 'nav' -and (Test-Path "$mazeDisk\nav-gravel-clear.json") -and !(Test-Path "$mazeDisk\nav-gravel-clear.continue")) {
            Rcon 'fill 4 67 1 4 68 1 minecraft:air' | Out-Null
            [IO.File]::WriteAllText("$mazeDisk\nav-gravel-clear.continue", 'ready', $utf8)
        }
        if (Test-Path -LiteralPath $Path) { return }
        if ($script:process.HasExited) { throw 'Minecraft exited during scenario.' }
        $failures = Get-ChildItem "$TestRoot\world\computercraft\computer" -Recurse -Filter sandbox-result.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { !$_.ok }
        if ($failures) { throw ($failures.errors -join '; ') }
        if (Test-Path "$TestRoot\world\computercraft\computer\3\nav-environment-failure.json") {
            throw ([IO.File]::ReadAllText("$TestRoot\world\computercraft\computer\3\nav-environment-failure.json"))
        }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Scenario timeout waiting for $Path."
}
if ($Scenario -in @('room','craft','wizard','dropoff','devmode','faults','disk1mb','events','fuzz','update','soak')) {
    & "$PSScriptRoot\$Scenario.ps1"
    return
}
if ($Scenario -eq 'warehouse') { & "$PSScriptRoot\warehouse.ps1"; return }
if ($Scenario -eq 'mining') {
    & "$PSScriptRoot\mining.ps1"
    return
}
try {
    Start-TestServer 'first'
    foreach ($command in @('forceload add -16 -16 16 16','fill -5 64 -5 5 64 5 minecraft:stone',
        'fill -5 65 -5 5 68 5 minecraft:air','fill -3 65 -3 3 67 3 minecraft:stone',
        'fill -3 65 0 3 66 0 minecraft:air','fill 0 65 -3 0 66 3 minecraft:air','fill 2 66 1 4 66 1 minecraft:air',
        'setblock 3 66 0 minecraft:chest','setblock 2 66 -1 minecraft:bedrock','setblock -1 65 0 minecraft:stone','setblock -4 65 -4 computercraft:computer_advanced{ComputerId:0}',
        'setblock -4 66 -4 computercraft:wireless_modem_advanced[facing=down]',
        'setblock 4 65 -4 computercraft:computer_advanced{ComputerId:4}',
        'setblock 4 66 -4 computercraft:wireless_modem_advanced[facing=down]',
        'setblock -2 65 0 computercraft:turtle_advanced[facing=east]{ComputerId:1,Fuel:10000,LeftUpgrade:"minecraft:diamond_pickaxe",RightUpgrade:"computercraft:wireless_modem_advanced"}',
        'setblock 0 65 -2 computercraft:turtle_advanced[facing=south]{ComputerId:2,Fuel:10000,RightUpgrade:"computercraft:wireless_modem_advanced"}',
        'setblock 2 65 0 computercraft:turtle_advanced[facing=west]{ComputerId:3,Fuel:10000,LeftUpgrade:"minecraft:diamond_pickaxe",RightUpgrade:"computercraft:wireless_modem_advanced"}',
        'computercraft turn-on 0')) { Rcon $command | Out-Null }
    for ($index = 0; $index -lt $hosts.Count; $index++) {
        $point = $hosts[$index]
        Rcon "setblock $($point[0]) $($point[1]) $($point[2]) computercraft:computer_advanced{ComputerId:$($index + 10)}" | Out-Null
        Rcon "setblock $($point[0]) $($point[1] + 1) $($point[2]) computercraft:wireless_modem_normal[facing=down]" | Out-Null
    }
    Rcon 'computercraft turn-on 10 11 12 13' | Out-Null
    Rcon 'computercraft turn-on 1 2 3 4' | Out-Null
    Wait-File "$TestRoot\world\computercraft\computer\4\restart-ready.json"
    Get-Process -Id $script:process.Id | Select-Object Id,CPU,WorkingSet64,PeakWorkingSet64 | ConvertTo-Json | Set-Content "$Output\java-process.json"
    & 'C:\mc-cc-test\jdk\jdk-21.0.12.1+1\bin\jcmd.exe' $script:process.Id GC.heap_info | Set-Content "$Output\java-heap.txt"
    Copy-Item "$TestRoot\logs\latest.log" "$Output\before-restart.log"
    foreach ($pos in @('-2 66 0','0 66 -2','2 66 0')) { Rcon "data get block $pos" | Out-Null }
    foreach ($command in @('setblock 4 66 -4 minecraft:air','setblock 4 65 -4 minecraft:air',
        'execute in minecraft:the_nether run forceload add 496 -16 528 16',
        'execute in minecraft:the_nether run fill 510 64 -2 514 68 2 minecraft:bedrock',
        'execute in minecraft:the_nether run fill 511 65 -1 513 67 1 minecraft:air',
        'execute in minecraft:the_nether run setblock 512 65 0 computercraft:computer_advanced{ComputerId:4}',
        'execute in minecraft:the_nether run setblock 512 66 0 computercraft:wireless_modem_advanced[facing=down]')) { Rcon $command | Out-Null }
    Stop-TestServer
    foreach ($id in 0..4) { [IO.File]::WriteAllText("$TestRoot\world\computercraft\computer\$id\boot-hold", 'waiting for GPS hosts', $utf8) }
    Start-TestServer 'restart'
    Rcon 'computercraft shutdown 10 11 12 13' | Out-Null
    Start-Sleep -Seconds 1
    Rcon 'computercraft turn-on 10 11 12 13' | Out-Null
    Start-Sleep -Seconds 2
    foreach ($id in 0..4) { Remove-Item -LiteralPath "$TestRoot\world\computercraft\computer\$id\boot-hold" }
    Rcon 'computercraft turn-on 0 1 2 3' | Out-Null
    Rcon 'execute in minecraft:the_nether run computercraft turn-on 4' | Out-Null
    Wait-File "$TestRoot\world\computercraft\computer\4\sandbox-result.json"
    foreach ($id in 0..4) {
        Wait-File "$TestRoot\world\computercraft\computer\$id\sandbox-result.json"
        $result = Get-Content "$TestRoot\world\computercraft\computer\$id\sandbox-result.json" -Raw | ConvertFrom-Json
        if (!$result.ok) { throw "Computer $id failed." }
    }
    $controller = "$TestRoot\world\computercraft\computer\4"
    $loaded = Rcon 'execute in minecraft:the_nether if loaded 512 65 0 run data get block 512 65 0'
    if ($loaded -notmatch 'ComputerId:\s*4(?=[,}\s])') { throw 'Cannot verify the loaded controller chunk.' }
    Rcon 'execute in minecraft:the_nether run computercraft shutdown 4' | Out-Null
    Rcon 'execute in minecraft:the_nether run setblock 512 66 0 minecraft:air' | Out-Null
    Rcon 'execute in minecraft:the_nether run forceload remove 496 -16 528 16' | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    do {
        Start-Sleep -Seconds 2
        $loaded = Rcon 'execute in minecraft:the_nether if loaded 512 65 0 run data get block 512 65 0'
    } while ($loaded -match 'ComputerId:' -and [DateTime]::UtcNow -lt $deadline)
    if ($loaded -match 'ComputerId:') { throw 'Controller chunk did not unload.' }
    $root = "$TestRoot\world\computercraft\computer\0".Replace('\','/')
    $helper = [IO.Path]::GetFullPath("$PSScriptRoot\read-ssot.lua").Replace('\','/')
    $check = "local control = dofile([[$helper]])([[$root]]); assert(control and control.poses[4]); print('Offline occupied cell retained')"
    $lua52 = 'C:\Tools\lua52\lua52.exe'
    if (!(Test-Path -LiteralPath $lua52)) { $lua52 = (Get-Command lua5.2 -ErrorAction Stop).Source }
    & $lua52 -e $check | Set-Content "$Output\offline-occupancy.txt"
    if ($LASTEXITCODE -ne 0) { throw 'Offline occupancy was lost.' }
    Move-Item -LiteralPath "$controller\sandbox-result.json" -Destination "$controller\before-unload.json" -Force
    foreach ($dimension in @('minecraft:the_nether','minecraft:overworld')) {
        $mode = if ($dimension -eq 'minecraft:the_nether') { 'ordinary-nether' } else { 'ordinary-overworld' }
        [IO.File]::WriteAllText("$controller\transport-probe", $mode, $utf8)
        foreach ($command in @(
            "execute in minecraft:the_nether run setblock 512 66 0 minecraft:air",
            "execute in minecraft:the_nether run setblock 512 65 0 minecraft:air",
            "execute in minecraft:the_nether run forceload add 496 -16 528 16",
            "execute in minecraft:overworld run forceload add 496 -16 528 16",
            "execute in minecraft:overworld run setblock 512 66 0 minecraft:air",
            "execute in minecraft:overworld run setblock 512 65 0 minecraft:air",
            "execute in $dimension run setblock 512 64 0 minecraft:bedrock",
            "execute in $dimension run setblock 512 65 0 computercraft:computer_advanced{ComputerId:4}",
            "execute in $dimension run setblock 512 66 0 computercraft:wireless_modem_normal[facing=down]",
            "execute in $dimension run computercraft turn-on 4")) { Rcon $command | Out-Null }
        Wait-File "$controller\transport-$mode.json"
        Copy-Item "$controller\transport-$mode.json" "$Output\transport-$mode.json" -Force
    }
    foreach ($command in @('execute in minecraft:overworld run setblock 512 66 0 minecraft:air',
        'execute in minecraft:overworld run setblock 512 65 0 minecraft:air',
        'execute in minecraft:the_nether run setblock 512 66 0 minecraft:air',
        'execute in minecraft:the_nether run setblock 512 65 0 minecraft:air')) { Rcon $command | Out-Null }
    Remove-Item -LiteralPath "$controller\transport-probe"
    foreach ($command in @('execute in minecraft:the_nether run setblock 512 65 0 computercraft:computer_advanced{ComputerId:4}',
        'execute in minecraft:the_nether run setblock 512 66 0 computercraft:wireless_modem_advanced[facing=down]',
        'execute in minecraft:the_nether run computercraft turn-on 4')) { Rcon $command | Out-Null }
    Wait-File "$controller\sandbox-result.json"
    if ($Scenario -eq 'nav') {
        $probe="$TestRoot\world\computercraft\computer\3"
        Rcon 'computercraft shutdown 3 10 11 12 13' | Out-Null
        [IO.File]::WriteAllText("$probe\nav-probe", 'gps', $utf8)
        Rcon 'computercraft turn-on 3' | Out-Null
        Wait-File "$probe\nav-gps-failed.json"
        Rcon 'computercraft turn-on 10 11 12 13' | Out-Null
        Start-Sleep -Seconds 2
        [IO.File]::WriteAllText("$probe\nav-gps-failed.continue", 'ready', $utf8)
        Wait-File "$probe\nav-gps-restored.json"
        Rcon 'computercraft shutdown 1 2' | Out-Null
        Rcon 'data remove block -2 66 0 RightUpgrade' | Out-Null
        Rcon 'data remove block 0 66 -2 RightUpgrade' | Out-Null
        Rcon 'forceload remove 0 -16 31 31' | Out-Null
        Rcon 'computercraft shutdown 3' | Out-Null
        Rcon 'clone 2 66 0 2 66 0 3 66 2 replace move' | Out-Null
        Rcon 'item replace block 3 66 2 container.0 with computercraft:wireless_modem_normal 1' | Out-Null
        [IO.File]::WriteAllText("$probe\nav-probe", 'relocate', $utf8)
        Rcon 'computercraft turn-on 3' | Out-Null
        Wait-File "$probe\nav-loader-disabled.json"
        Rcon 'gamerule spawnChunkRadius 0' | Out-Null
        Rcon 'setworldspawn -1000 64 -1000' | Out-Null
        Rcon 'forceload remove 32 0 47 15' | Out-Null
        $deadline=[DateTime]::UtcNow.AddSeconds(90)
        do {
            $loaded=Rcon 'execute if loaded 32 66 4 run data get block 31 66 4'
            if ($loaded -notmatch 'ComputerId:') { break }
            Start-Sleep -Seconds 2
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($loaded -match 'ComputerId:') { throw 'Loader-disabled target chunk stayed loaded.' }
        [IO.File]::WriteAllText("$probe\nav-loader-disabled.continue", 'ready', $utf8)
        Start-Sleep -Seconds 3
        $boundary=Rcon 'data get block 31 66 4'
        if ($boundary -notmatch 'ComputerId:\s*3(?=[,}\s])') { throw 'Disabled loader did not preserve the boundary pose.' }
        $root="$TestRoot\world\computercraft\computer\0".Replace('\','/')
        $helper=[IO.Path]::GetFullPath("$PSScriptRoot\read-ssot.lua").Replace('\','/')
        $check="local control = dofile([[$helper]])([[$root]]); local p=assert(control and control.poses[3]); assert(p.x==31 and p.y==66 and p.z==4); print('Offline boundary occupancy retained')"
        $lua52 = 'C:\Tools\lua52\lua52.exe'
        if (!(Test-Path -LiteralPath $lua52)) { $lua52 = (Get-Command lua5.2 -ErrorAction Stop).Source }
        & $lua52 -e $check | Set-Content "$Output\disabled-occupancy.txt"
        if ($LASTEXITCODE -ne 0) { throw 'Offline boundary occupancy was lost.' }
        Copy-Item "$TestRoot\logs\latest.log" "$Output\before-loader-restart.log"
        Stop-TestServer
        [IO.File]::WriteAllText("$probe\nav-probe", 'resume', $utf8)
        [IO.File]::WriteAllText("$probe\boot-hold", 'waiting for GPS', $utf8)
        Start-TestServer 'loader-resume'
        Rcon 'forceload add 16 0 31 15' | Out-Null
        Rcon 'computercraft shutdown 10 11 12 13' | Out-Null
        Rcon 'computercraft turn-on 10 11 12 13' | Out-Null
        Start-Sleep -Seconds 2
        Remove-Item -LiteralPath "$probe\boot-hold"
        Rcon 'computercraft turn-on 3' | Out-Null
        Wait-File "$probe\nav-loader-enabled.json"
        Rcon 'forceload remove 16 0 31 15' | Out-Null
        Start-Sleep -Seconds 3
        Rcon 'execute if loaded 32 66 4 run data get block 31 66 4' | Out-Null
        [IO.File]::WriteAllText("$probe\nav-loader-enabled.continue", 'ready', $utf8)
        Wait-File "$probe\nav-boundary-load.json"
        Rcon 'forceload add 32 0 47 15' | Out-Null
        [IO.File]::WriteAllText("$probe\nav-boundary-load.continue", 'ready', $utf8)
        Wait-File "$probe\nav-environment-result.json"
    }
    $expected = @{ '-2 66 0' = 1; '0 66 -2' = 2; '2 66 0' = 3 }
    foreach ($pos in $expected.Keys) {
        $block = Rcon "data get block $pos"
        if ($block -notmatch ('ComputerId:\s*' + $expected[$pos] + '(?=[,}\s])')) { throw "Wrong turtle at $pos." }
    }
    $nether = Rcon 'execute in minecraft:the_nether run data get block 512 65 0'
    if ($nether -notmatch 'ComputerId:\s*4(?=[,}\s])') { throw 'Nether controller is missing.' }
    & "$PSScriptRoot\verify-results.ps1" -Computers "$TestRoot\world\computercraft\computer" -Output $Output -Title $(if ($Scenario -eq 'nav') { 'Navigation PR 2' } else { 'SSOT PR 1' })
    if ($Client) {
        try { & "$PSScriptRoot\client.ps1" -TestRoot $TestRoot -Port $port -RconPort $rconPort -Output $Output } catch {
            "Visual evidence missing. Client attempt failed. $($_.Exception.Message)" | Set-Content "$Output\visual-missing.txt"
        }
    }
    Write-Output 'Gate B SSOT PASS'
    [IO.File]::WriteAllText("$Output\verdict.txt", 'PASS', $utf8)
} catch {
    [IO.File]::WriteAllText("$Output\verdict.txt", "FAIL`n$($_.Exception.Message)", $utf8)
    throw
} finally {
    try { Stop-TestServer } catch { Write-Warning $_ }
    if (Test-Path "$TestRoot\logs\latest.log") { Copy-Item "$TestRoot\logs\latest.log" "$Output\latest.log" -Force }
    Copy-Item "$TestRoot\world\computercraft\computer" "$Output\computers" -Recurse -Force
}
