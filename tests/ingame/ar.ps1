param(
    [string]$Base = 'C:\mc-cc-test\base',
    [string]$Battery = 'C:\Work\gemini-input\p2\turtlebattery-0.3.0.jar',
    [string]$Output = 'C:\Work\gemini-input\p2\evidence\pr6\gateB',
    [string]$TestRoot = '',
    [int]$Timeout = 600,
    [ValidateSet('Auto','Box','Local')][string]$HostKind = 'Auto',
    [int]$SpaceLimit = 1000000,
    [switch]$PrepareOnly,
    [switch]$Client
)
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='AboveNormal'
. "$PSScriptRoot\rcon.ps1"
. 'C:\Work\gemini-input\gateb\gateb.ps1'
. "$PSScriptRoot\ar-host.ps1"
$script:arBoxId = $null
$script:arBoxRunning = $false
$script:arBoxStarted = $false
$arTestOwnerName='SSOTProof'
$arTestOwnerUUID='b853395f-3060-3b1f-bbe1-d4aa2249261f'
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
    'AdvancedPeripherals-*.jar','turtlematic-*.jar','cc_ar-*.jar','directgpu-*.jar','kotlinforforge-*.jar',
    'superbwarfare-*.jar','curios-*.jar')) {
    $jars = @(Get-ChildItem "$Base\mods" -Filter $pattern)
    if ($jars.Count -ne 1) { throw "Expected one installed jar matching $pattern." }
    Copy-Item -LiteralPath $jars[0].FullName -Destination "$TestRoot\mods"
}
foreach ($pattern in @('*tweakium*.jar','*broccolium*.jar','*peripheralium*.jar')) {
    Get-ChildItem "$Base\mods" -Filter $pattern | Copy-Item -Destination "$TestRoot\mods"
}
Copy-Item -LiteralPath $Battery -Destination "$TestRoot\mods\turtlebattery-0.3.0.jar"
foreach ($jar in @(
    'e67929626fafce1d4e05a6d9dde332749a3f89378b18e124df5b507ea099de3a-turtlematicfix-1.0.0.jar',
    'efbf56d8c43d16a41421329a5ed9afc81451227619062925d6e277969452431c-recipe_index-0.1.0.jar')) {
    $cached="C:\Work\gemini-input\gateb\mods-cache\$jar"
    if ((Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash -ne $jar.Substring(0,64)) {
        throw "Disposable jar checksum mismatch: $jar"
    }
    Copy-Item -LiteralPath $cached -Destination "$TestRoot\mods\$($jar.Substring(65))"
}
foreach ($name in @('superbwarfare-common.toml','superbwarfare-server.toml','turtlematic.toml')) {
    Copy-Item -LiteralPath "$Base\config\$name" -Destination "$TestRoot\config"
}
Copy-Item -LiteralPath "$Base\config\superbwarfare-server.toml" -Destination "$TestRoot\world\serverconfig"
Copy-Item 'C:\Work\gemini-input\p2\classicperipherals.toml' "$TestRoot\config\classicperipherals.toml"
$cc = [regex]::Replace([IO.File]::ReadAllText("$Base\config\computercraft-server.toml"),
    'computer_space_limit = \d+', "computer_space_limit = $SpaceLimit")
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
$checkoutSource=$source
$source=Join-Path $TestRoot 'source'
New-Item -ItemType Directory -Path $source | Out-Null
foreach ($file in Get-ChildItem "$checkoutSource\*.lua") {
    [IO.File]::WriteAllText("$source\$($file.Name)",[IO.File]::ReadAllText($file.FullName).Replace("`r`n","`n"),$utf8)
}
$arDriverRoot=Join-Path $Output 'driver-source'
New-Item -ItemType Directory -Force -Path $arDriverRoot | Out-Null
Get-ChildItem $PSScriptRoot -File | Where-Object { $_.Extension -in @('.lua','.ps1','.py','.toml') } |
    Copy-Item -Destination $arDriverRoot
Copy-Item -LiteralPath "$checkoutSource\tests\fixtures" -Destination "$arDriverRoot\fixtures" -Recurse
. "$arDriverRoot\ar-host.ps1"
foreach ($id in 0..4) {
    $disk = "$TestRoot\world\computercraft\computer\$id"
    New-Item -ItemType Directory -Force -Path $disk | Out-Null
    $role=if ($id -eq 0) { 'server' } elseif ($id -eq 4) { 'hub' } else { 'miner' }
    Copy-ArRole $id $role
    Copy-Item "$arDriverRoot\ar-probe.lua" "$disk\ar-probe.lua"
    [IO.File]::WriteAllText("$disk\ar-test-config.json",("{`"spaceLimit`":$SpaceLimit}"),$utf8)
    [IO.File]::WriteAllText("$disk\startup.lua",'shell.run("ar-probe.lua")',$utf8)
}
Copy-ArCache
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
        'Production mining, recall and recharge depth checks',
        'Native cached installation of every role')
    limits=@(
        'cc_ar 0.2.1 depth-tests 3D lines and text, so through-wall outlines are not available.',
        'cc_ar 0.2.1 exposes no wearer identity or goggles-removal event.')
    deferred=@('PR 5 view roles await the pushed PR 5 fix round',
        'Ed25519 manifest signing awaits H1H2') }
function Rcon([string]$Command) {
    if ($script:arBoxId) { return Invoke-GatebRcon $script:arBoxId @($Command) -Log "$Output\rcon.txt" }
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
    if ($script:arBoxId) {
        do {
            try {
                Start-GatebRun $script:arBoxId -TimeoutSec $Timeout | Out-Null
                $script:arBoxRunning = $true
                $script:arBoxStarted = $true
                return
            } catch {
                if ($_.Exception.Message -notmatch '\b409\b') { throw }
                if ([DateTime]::UtcNow -gt $waitUntil) { throw 'Box capacity remained full for three hours.' }
                "$([DateTime]::UtcNow.ToString('o')) Box capacity is full." | Add-Content "$Output\resource-wait.txt"
                if (!$script:arBoxStarted -and $HostKind -eq 'Auto' -and !(Test-Path $lock)) {
                    $freeGB=(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB
                    $others=@(Get-CimInstance Win32_Process -Filter "name='java.exe'" |
                        Where-Object { $_.CommandLine -match 'C:[\\/]+Work[\\/]+mc-ssot-' })
                    if ($freeGB -ge 5 -and $others.Count -eq 0) {
                        try {
                            New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
                            $script:ownedLock=$true
                            'PR 6' | Set-Content "$lock\owner.txt"
                        } catch {}
                        if ($script:ownedLock) {
                            Remove-GatebRun $script:arBoxId | Out-Null
                            $script:arBoxId=$null
                            Remove-Item -LiteralPath "$TestRoot\box-run-id.txt"
                            [IO.File]::WriteAllText("$Output\test-location.txt","$TestRoot`nlocalhost:$port`nRCON localhost:$rconPort`n",$utf8)
                            Get-ChildItem "$TestRoot\mods" | Get-FileHash -Algorithm SHA256 | ForEach-Object {
                                "$($_.Hash) $([IO.Path]::GetFileName($_.Path))"
                            } | Set-Content "$Output\jar-sha256.txt"
                            break
                        }
                    }
                }
                Start-Sleep -Seconds 60
                Start-Sleep -Seconds 60
            }
        } while ($true)
    }
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
    if ($script:arBoxId) {
        if ($script:arBoxRunning) { Stop-GatebRun $script:arBoxId | Out-Null }
        $script:arBoxRunning = $false
        return
    }
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
        $text = Read-ArText $path
        if ($text) {
            $value = $null
            try { $value = $text | ConvertFrom-Json } catch {}
            if ($value) {
                if (!$value.ok) { throw "Computer $Id failed $Name. $($value.error)" }
                [IO.File]::WriteAllText("$Output\$Id-$Name",$text,$utf8)
                return
            }
        }
        if (!(Test-ArServer)) { throw 'Server exited during AR probe.' }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Computer $Id timed out waiting for $Name."
}
function Invoke-ArCapture([string]$View) {
    if (!$Client) { throw 'The native capture phase requires -Client.' }
    $clientLocked=$false
    $captureOutput=Join-Path $Output ('capture-'+$View+'-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $captureOutput | Out-Null
    try {
        Enter-GatebClientLock 'PR 6 AR capture'
        $clientLocked=$true
        $clientPort,$clientRconPort=$port,$rconPort
        if ($script:arBoxId) {
            $local=Connect-GatebLocal $script:arBoxId $TestRoot
            $clientPort,$clientRconPort=$local.Port,$local.RconPort
        }
        if ($arCaptureCamera) {
            $camera=@("tp SSOTProof $($arCaptureCamera.x) $($arCaptureCamera.y) $($arCaptureCamera.z) $($arCaptureCamera.yaw) $($arCaptureCamera.pitch)")
            [IO.File]::WriteAllText("$TestRoot\capture-camera.json",($camera | ConvertTo-Json),$utf8)
        }
        $shot=if ($View -eq 'ar') { 'ar-hud.png' } else { "$View.png" }
        & "$arDriverRoot\client.ps1" -TestRoot $TestRoot -Port $clientPort -RconPort $clientRconPort `
            -Output $captureOutput -View $View -ShotName $shot -Timeout $Timeout
    } finally {
        if ($script:arBoxId) { Disconnect-GatebLocal $TestRoot }
        if ($clientLocked) { Exit-GatebClientLock }
        Get-ChildItem $captureOutput -File | Where-Object { $_.Extension -in @('.png','.mp4') -or $_.Name -eq 'real-ap-chat.json' } |
            Copy-Item -Destination $Output -Force
    }
}
function New-ArBox {
    $box = New-GatebRun -Name 'ssot-pr6' -XmxMb 3072 -SpaceLimit $SpaceLimit
    $script:arBoxId = $box.id
    [IO.File]::WriteAllText("$TestRoot\box-run-id.txt",$box.id,$utf8)
    [IO.File]::WriteAllText("$Output\test-location.txt",
        "box run $($box.id) at 100.78.96.94:$($box.game_port) (disposable, not live)`n",$utf8)
    Send-GatebDir $box.id "$TestRoot\world\computercraft" 'world'
    [IO.File]::WriteAllText("$Output\jar-sha256.txt",(Get-GatebText $box.id 'jar-sha256.txt'),$utf8)
}
try {
    $waitUntil = [DateTime]::UtcNow.AddHours(3)
    if ($HostKind -eq 'Box' -or ($HostKind -eq 'Auto' -and (Test-Path $lock))) {
        New-ArBox
    }
    do {
        if ($script:arBoxId) { break }
        try {
            New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
            $ownedLock = $true
            'PR 6' | Set-Content "$lock\owner.txt"
        } catch {
            if (!(Test-Path $lock)) { throw }
            if ($HostKind -eq 'Auto') { New-ArBox; break }
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
    Save-ArFile "$TestRoot\logs\latest.log" "$Output\before-restart.log"
    $result.nativeRendering = $true
    if ($Client) {
        try {
            Invoke-ArCapture 'ar'
        } catch { $result.errors += $_.Exception.Message }
        $result.visual = Test-Path "$Output\ar-hud.png"
        $result.wallComparison = Test-Path "$Output\ar-xray.png"
        if (!$result.wallComparison) { $result.missing += 'Wall comparison screenshot' }
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
    try {
        . "$arDriverRoot\ar-owner.ps1"
        $result.owner = $true
        $result.missing = @($result.missing | Where-Object { $_ -notlike 'Production server/hub ownership*' })
    } catch { $result.errors += $_.Exception.Message }
    try {
        . "$arDriverRoot\ar-depth.ps1"
        $result.depth = $true
        $result.missing = @($result.missing | Where-Object { $_ -ne 'Production mining, recall and recharge depth checks' })
    } catch { $result.errors += $_.Exception.Message }
    try {
        . "$arDriverRoot\ar-install.ps1"
        $result.installation = $true
        $result.missing = @($result.missing | Where-Object { $_ -ne 'Native cached installation of every role' })
    } catch { $result.errors += $_.Exception.Message }
    if (!$result.visual) { $result.missing += 'Real linked-goggles HUD screenshot' }
    if ($result.missing.Count) { throw ('Required gate coverage remains. ' + ($result.missing -join '; ')) }
    if ($result.errors.Count) { throw 'One or more native checks failed.' }
    $result.ok = $true
} catch {
    $result.errors += $_.Exception.Message
    Write-Output "Gate B AR failed. $($_.Exception.Message)"
} finally {
    try { Stop-ArServer } catch { $result.errors += "Server cleanup: $($_.Exception.Message)" }
    if (Test-Path "$TestRoot\client\process.id") {
        $clientId = [int](Get-Content "$TestRoot\client\process.id")
        $owned = Get-CimInstance Win32_Process -Filter "ProcessId=$clientId" -ErrorAction SilentlyContinue
        if ($owned -and $owned.CommandLine.Contains($TestRoot.Replace('\','/'))) {
            Stop-Process -Id $clientId -Force
            Wait-Process -Id $clientId -ErrorAction SilentlyContinue
        }
    }
    if ($script:arBoxId) {
        $downloaded=$false
        for ($attempt=0; $attempt -lt 3 -and !$downloaded; $attempt++) {
            try {
                Save-GatebDir $script:arBoxId 'logs' $Output
                Save-GatebDir $script:arBoxId 'world/computercraft/computer' $Output
                [IO.File]::WriteAllText("$Output\box-rcon.txt",(Get-GatebText $script:arBoxId 'rcon.txt'),$utf8)
                $downloaded=$true
            } catch {
                $result.errors += "Evidence download attempt $($attempt+1): $($_.Exception.Message)"
                Start-Sleep -Seconds 5
            }
        }
        if ($downloaded) {
            try { Remove-GatebRun $script:arBoxId | Out-Null }
            catch { $result.errors += "Box cleanup: $($_.Exception.Message)" }
        } else {
            $result.errors += "Stopped box run $script:arBoxId retained until its evidence can be downloaded."
        }
    } elseif (Test-Path "$TestRoot\logs\latest.log") { Copy-Item "$TestRoot\logs\latest.log" "$Output\latest.log" -Force }
    Get-ChildItem "$TestRoot\world\computercraft\computer" -Recurse -Filter 'ar-*.json' | ForEach-Object {
        Copy-Item $_.FullName "$Output\$($_.Directory.Name)-$($_.Name)" -Force
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content "$Output\result.json"
    if ($ownedLock) { Remove-Item -LiteralPath "$lock\owner.txt"; Remove-Item -LiteralPath $lock }
}
if (!$result.ok) { throw "Gate B AR failed. See $Output\result.json." }
