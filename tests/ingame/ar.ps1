param(
    [string]$Base = 'C:\mc-cc-test\base',
    [string]$Battery = 'C:\Work\gemini-input\p2\turtlebattery-0.3.0.jar',
    [string]$Output = 'C:\Work\gemini-input\p2\evidence\pr6\gateB',
    [string]$TestRoot = '',
    [int]$Timeout = 600,
    [switch]$PrepareOnly,
    [switch]$Client
)
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='AboveNormal'
. "$PSScriptRoot\rcon.ps1"
$source = (Resolve-Path "$PSScriptRoot\..\..").Path
$utf8 = New-Object Text.UTF8Encoding($false)
if (!$TestRoot) { $TestRoot = 'C:\Work\mc-ssot-pr6-' + [guid]::NewGuid().ToString('N').Substring(0,8) }
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if ($TestRoot -notmatch '^C:\\Work\\mc-ssot-pr6-[a-zA-Z0-9-]+$') { throw 'Use a fresh PR 6 test root.' }
if (Test-Path "$TestRoot\server.properties") { throw 'The test root already contains a server.' }
if ($Output -eq 'C:\Work\gemini-input\p2\evidence\pr1\gateB') { $Output = 'C:\Work\gemini-input\p2\evidence\pr6\gateB' }
New-Item -ItemType Directory -Force -Path $TestRoot,$Output,"$TestRoot\mods","$TestRoot\config","$TestRoot\world\serverconfig" | Out-Null
New-Item -ItemType Junction -Path "$TestRoot\libraries" -Target "$Base\libraries" | Out-Null
foreach ($pattern in @('cc-tweaked-1.21.1-forge-1.120.2.jar','classicperipherals-neoforge-1.21.1-0.6.5.jar',
    'AdvancedPeripherals-*.jar','turtlematic-*.jar','cc_ar-*.jar','directgpu-*.jar','kotlinforforge-*.jar')) {
    $jars = @(Get-ChildItem "$Base\mods" -Filter $pattern)
    if ($jars.Count -ne 1) { throw "Expected one installed jar matching $pattern." }
    Copy-Item -LiteralPath $jars[0].FullName -Destination "$TestRoot\mods"
}
foreach ($pattern in @('*tweakium*.jar','*broccolium*.jar','*peripheralium*.jar')) {
    Get-ChildItem "$Base\mods" -Filter $pattern | Copy-Item -Destination "$TestRoot\mods"
}
Copy-Item -LiteralPath $Battery -Destination "$TestRoot\mods\turtlebattery-0.3.0.jar"
Copy-Item 'C:\Work\gemini-input\p2\classicperipherals.toml' "$TestRoot\config\classicperipherals.toml"
$cc = [IO.File]::ReadAllText("$Base\config\computercraft-server.toml").Replace('computer_space_limit = 1000000','computer_space_limit = 4000000')
foreach ($folder in @('config','world\serverconfig')) { [IO.File]::WriteAllText("$TestRoot\$folder\computercraft-server.toml",$cc,$utf8) }
function Get-FreePort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $listener.Start()
    $selected = $listener.LocalEndpoint.Port
    $listener.Stop()
    return $selected
}
$port = Get-FreePort
do { $rconPort = Get-FreePort } while ($rconPort -eq $port)
$secret = [guid]::NewGuid().ToString('N')
[IO.File]::WriteAllLines("$TestRoot\server.properties",@('level-name=world','online-mode=false',"server-port=$port",
    'server-ip=127.0.0.1','spawn-protection=0','view-distance=3','simulation-distance=3','enable-rcon=true',
    "rcon.port=$rconPort","rcon.password=$secret",'gamemode=creative','difficulty=peaceful','allow-flight=true',
    'max-tick-time=-1','level-type=minecraft:flat',
    'generator-settings={"layers":[{"block":"minecraft:bedrock","height":1},{"block":"minecraft:dirt","height":2},{"block":"minecraft:grass_block","height":1}],"biome":"minecraft:plains"}',
    'generate-structures=false','motd=Disposable SSOT PR 6 test'),$utf8)
[IO.File]::WriteAllText("$TestRoot\eula.txt",'eula=true',$utf8)
foreach ($id in 0..4) {
    $disk = "$TestRoot\world\computercraft\computer\$id"
    New-Item -ItemType Directory -Force -Path $disk | Out-Null
    foreach ($file in Get-ChildItem "$source\*.lua") {
        [IO.File]::WriteAllText("$disk\$($file.Name)",[IO.File]::ReadAllText($file.FullName).Replace("`r`n","`n"),$utf8)
    }
    Copy-Item "$PSScriptRoot\ar-probe.lua" "$disk\ar-probe.lua"
    [IO.File]::WriteAllText("$disk\startup.lua",'shell.run("ar-probe.lua")',$utf8)
}
Get-ChildItem "$TestRoot\mods" | Get-FileHash -Algorithm SHA256 | ForEach-Object {
    "$($_.Hash) $([IO.Path]::GetFileName($_.Path))"
} | Set-Content "$Output\jar-sha256.txt"
Get-ChildItem "$source\*.lua" | Get-FileHash -Algorithm SHA256 | ForEach-Object {
    "$($_.Hash) $([IO.Path]::GetFileName($_.Path))"
} | Set-Content "$Output\source-sha256.txt"
[IO.File]::WriteAllText("$Output\test-location.txt","$TestRoot`nlocalhost:$port`nRCON localhost:$rconPort`n",$utf8)
Copy-Item "$TestRoot\config\*.toml" $Output
if ($PrepareOnly) { Write-Output "Prepared $TestRoot"; return }
$lock = 'C:\Work\gemini-input\p2\gateB.lock'
$ownedLock = $false
$script:arProcess = $null
$result = @{ ok=$false; scenario='ar'; native=$false; visual=$false; errors=@(); root=$TestRoot
    missing=@('Production server/hub ownership failover with actual shared controller',
        'Production chat recall and charging routes on real turtles',
        'All-role installation and storage regression with PR 4 and PR 5 integrations') }
function Rcon([string]$Command) {
    $answer = Invoke-TestRcon $rconPort $secret $Command
    $entry="$([DateTime]::UtcNow.ToString('o')) > $Command`n$answer`n"
    for ($attempt=0; $attempt -lt 50; $attempt++) {
        try {
            [IO.File]::AppendAllText("$Output\rcon.txt",$entry,$utf8)
            break
        } catch [IO.IOException] {
            if ($attempt -eq 49) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
    return $answer
}
function Wait-ArResources {
    do {
        $others = @(Get-CimInstance Win32_Process -Filter "name='java.exe'" | Where-Object {
            if ($_.CommandLine -match 'C:[\\/]+Work[\\/]+mc-ssot-') { return $true }
            if ($_.CommandLine -notmatch '@libraries/.*nogui') { return $false }
            $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ParentProcessId)"
            $protected = $parent -and $parent.CreationDate -le $_.CreationDate -and
                $parent.CommandLine -match 'C:[\\/]+mc-run1[\\/]+srv-out\.txt'
            if ($protected) {
                "Leave protected server PID $($_.ProcessId) untouched. Its parent redirects to C:\mc-run1\srv-out.txt." |
                    Add-Content "$Output\protected-process.txt"
            }
            return !$protected
        })
        $freeGB = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
        if ($others.Count -eq 0 -and $freeGB -ge 5) { return }
        "Waiting for test servers or memory. Other servers=$($others.Count), free GB=$freeGB" | Add-Content "$Output\resource-wait.txt"
        Start-Sleep -Seconds 60
        if ([DateTime]::UtcNow -gt $waitUntil) { throw 'Waited three hours for free test resources.' }
    } while ($true)
}
function Start-ArServer([string]$Label) {
    Wait-ArResources
    foreach ($candidate in @($port,$rconPort)) {
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$candidate)
        try { $listener.Start() } finally { $listener.Stop() }
    }
    $script:arProcess = Start-Process 'C:\mc-cc-test\jdk\jdk-21.0.12.1+1\bin\java.exe' -WorkingDirectory $TestRoot -WindowStyle Hidden -PassThru -ArgumentList @(
        '-Xms512M','-Xmx3G',"@$TestRoot\libraries\net\neoforged\neoforge\21.1.259\win_args.txt",'nogui'
    ) -RedirectStandardOutput "$TestRoot\stdout-$Label.log" -RedirectStandardError "$TestRoot\stderr-$Label.log"
    $script:arProcess.PriorityClass='AboveNormal'
    "$($script:arProcess.Id) $($script:arProcess.PriorityClass)" | Add-Content "$Output\owned-server-priorities.txt"
    $script:arProcess.Id | Add-Content "$Output\owned-server-pids.txt"
    $script:arProcess.Id | Set-Content "$TestRoot\server.pid"
    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    do {
        if ($script:arProcess.HasExited) { throw "Server exited during $Label." }
        try { if ((Invoke-TestRcon $rconPort $secret 'list') -match 'players online') { return } } catch {}
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Server boot timeout.'
}
function Stop-ArServer {
    if ($script:arProcess -and !$script:arProcess.HasExited) {
        try { Rcon 'stop' | Out-Null } catch {}
        if (!$script:arProcess.WaitForExit(60000)) { Stop-Process -Id $script:arProcess.Id -Force }
        $script:arProcess.WaitForExit()
    }
}
function Wait-Result([int]$Id,[string]$Name) {
    $path = "$TestRoot\world\computercraft\computer\$Id\$Name"
    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    do {
        if (Test-Path $path) {
            $value = $null
            try { $value = Get-Content $path -Raw | ConvertFrom-Json } catch {}
            if ($value) {
                if (!$value.ok) { throw "Computer $Id failed $Name. $($value.error)" }
                Copy-Item $path "$Output\$Id-$Name" -Force
                return
            }
        }
        if ($script:arProcess.HasExited) { throw 'Server exited during AR probe.' }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Computer $Id timed out waiting for $Name."
}
try {
    $waitUntil = [DateTime]::UtcNow.AddHours(3)
    do {
        try {
            New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
            $ownedLock = $true
            'PR 6' | Set-Content "$lock\owner.txt"
        } catch {
            if (!(Test-Path $lock)) { throw }
            Write-Output 'Waiting for Gate B lock.'
            Start-Sleep -Seconds 60
        }
        if ([DateTime]::UtcNow -gt $waitUntil) { throw 'Waited three hours for Gate B lock.' }
    } while (!$ownedLock)
    Start-ArServer 'initial'
    foreach ($command in @('gamerule doDaylightCycle false','time set day','weather clear',
        'forceload add -16 -16 16 16','fill -10 64 -10 10 64 10 minecraft:stone',
        'fill -10 65 -10 10 74 10 minecraft:air',
        'setblock 0 66 0 computercraft:computer_advanced{ComputerId:0}',
        'setblock 0 67 0 computercraft:wireless_modem_advanced[facing=down]',
        'setblock 1 66 0 cc_ar:ar_controller',
        'setblock -1 66 0 advancedperipherals:chat_box',
        'setblock 2 66 0 computercraft:computer_advanced{ComputerId:4}',
        'setblock 2 67 0 computercraft:wireless_modem_advanced[facing=down]',
        'setblock 4 65 -3 computercraft:turtle_advanced[facing=south]{ComputerId:1,Fuel:10000,LeftUpgrade:"computercraft:wireless_modem_advanced"}',
        'setblock 6 65 -3 computercraft:turtle_advanced[facing=south]{ComputerId:2,Fuel:100,LeftUpgrade:"computercraft:wireless_modem_advanced"}',
        'setblock 8 65 -3 computercraft:turtle_advanced[facing=south]{ComputerId:3,Fuel:10000,LeftUpgrade:"computercraft:wireless_modem_advanced"}',
        'setblock 5 65 -4 minecraft:diamond_ore','setblock 7 65 -4 minecraft:deepslate_iron_ore',
        'fill 3 65 0 9 68 0 minecraft:stone','computercraft turn-on 0 1 2 3 4')) {
        Rcon $command | Out-Null
    }
    foreach ($id in 0..4) { Wait-Result $id 'ar-native.json' }
    Copy-Item "$TestRoot\logs\latest.log" "$Output\before-restart.log"
    $result.nativeRendering = $true
    if ($Client) {
        try {
            & "$PSScriptRoot\client.ps1" -TestRoot $TestRoot -Port $port -RconPort $rconPort -Output $Output -View ar -ShotName ar-hud.png -Timeout $Timeout
        } catch { $result.errors += $_.Exception.Message }
        $result.visual = (Test-Path "$Output\ar-hud.png") -and (Test-Path "$Output\ar-xray.png")
    }
    Stop-ArServer
    Start-ArServer 'restart'
    Rcon 'computercraft turn-on 0 1 2 3 4' | Out-Null
    $result.native = $true
    foreach ($id in 0..4) {
        try { Wait-Result $id 'ar-restart.json' }
        catch { $result.native=$false; $result.errors += $_.Exception.Message }
    }
    if (!$result.native) { $result.missing += 'Native restart recovery' }
    . "$PSScriptRoot\ar-owner.ps1"
    $result.owner = $true
    $result.missing = @($result.missing | Where-Object { $_ -notlike 'Production server/hub ownership*' })
    if (!$result.visual) { $result.missing += 'Real linked-goggles HUD and x-ray screenshots' }
    if ($result.missing.Count) { throw ('Native renderer fixture passed, but required gate coverage remains. ' + ($result.missing -join '; ')) }
    $result.ok = $true
} catch {
    $result.errors += $_.Exception.Message
    Write-Output "Gate B AR failed. $($_.Exception.Message)"
} finally {
    Stop-ArServer
    if (Test-Path "$TestRoot\client\process.id") {
        $clientId = [int](Get-Content "$TestRoot\client\process.id")
        $owned = Get-CimInstance Win32_Process -Filter "ProcessId=$clientId" -ErrorAction SilentlyContinue
        if ($owned -and $owned.CommandLine.Contains($TestRoot.Replace('\','/'))) {
            Stop-Process -Id $clientId -Force
            Wait-Process -Id $clientId -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path "$TestRoot\logs\latest.log") { Copy-Item "$TestRoot\logs\latest.log" "$Output\latest.log" -Force }
    Get-ChildItem "$TestRoot\world\computercraft\computer" -Recurse -Filter 'ar-*.json' | ForEach-Object {
        Copy-Item $_.FullName "$Output\$($_.Directory.Name)-$($_.Name)" -Force
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content "$Output\result.json"
    if ($ownedLock) { Remove-Item -LiteralPath "$lock\owner.txt"; Remove-Item -LiteralPath $lock }
}
if (!$result.ok) { throw "Gate B AR failed. See $Output\result.json." }
