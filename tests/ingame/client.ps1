param([string]$TestRoot, [int]$Port, [int]$RconPort, [string]$Output, [int]$Timeout = 240, [switch]$OnDesktop, [string]$View="crossing", [string]$ShotName="ssot-crossing.png")
$ErrorActionPreference = 'Stop'
if ($View -eq 'ar') { [Diagnostics.Process]::GetCurrentProcess().PriorityClass='AboveNormal' }
if (!$OnDesktop -and (Get-Process -Id $PID).SessionId -eq 0) {
    $desktopUser = (Get-CimInstance Win32_ComputerSystem).UserName
    if (!$desktopUser) { throw 'No logged-in Windows desktop is available for the offline client.' }
    $status = "$TestRoot\client-status.txt"
    if (Test-Path -LiteralPath $status) { Remove-Item -LiteralPath $status }
    $launcher = "$TestRoot\client-on-desktop.ps1"
    $quote = { param($value) "'" + $value.Replace("'", "''") + "'" }
    $command = '& ' + (& $quote $PSCommandPath) + ' -OnDesktop -TestRoot ' + (& $quote $TestRoot) +
        ' -Port ' + $Port + ' -RconPort ' + $RconPort + ' -Output ' + (& $quote $Output) + ' -Timeout ' + $Timeout + ' -View ' + (& $quote $View) + ' -ShotName ' + (& $quote $ShotName)
    $body = "try { $command; [IO.File]::WriteAllText($(& $quote $status), 'PASS') } catch { [IO.File]::WriteAllText($(& $quote $status), 'FAIL' + [Environment]::NewLine + `$_.Exception.Message) }"
    [IO.File]::WriteAllText($launcher, $body)
    $name = 'SSOT-pr1-' + [guid]::NewGuid().ToString('N')
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$launcher`""
    $principal = New-ScheduledTaskPrincipal -UserId $desktopUser -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal | Out-Null
    try {
        Start-ScheduledTask -TaskName $name
        $deadline = [DateTime]::UtcNow.AddSeconds($Timeout + 90)
        do {
            if (Test-Path -LiteralPath $status) { break }
            Start-Sleep -Seconds 1
        } while ([DateTime]::UtcNow -lt $deadline)
        if (!(Test-Path -LiteralPath $status)) { throw 'Interactive desktop client timed out.' }
        $result = [IO.File]::ReadAllText($status)
        if ($result -ne 'PASS') { throw $result }
    } finally {
        Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        if (Test-Path "$TestRoot\client\process.id") {
            $clientId = [int]([IO.File]::ReadAllText("$TestRoot\client\process.id"))
            $owned = Get-CimInstance Win32_Process -Filter "ProcessId=$clientId" -ErrorAction SilentlyContinue
            if ($owned -and $owned.CommandLine.Contains($TestRoot.Replace('\','/'))) { Stop-Process -Id $clientId -Force }
        }
    }
    return
}
. "$PSScriptRoot\rcon.ps1"
$client = Join-Path $TestRoot 'client'
New-Item -ItemType Directory -Force -Path $client, "$client\mods", "$client\config" | Out-Null
Copy-Item "$TestRoot\mods\*.jar" "$client\mods"
Copy-Item "$TestRoot\config\classicperipherals.toml" "$client\config"
Copy-Item "$PSScriptRoot\fml.toml" "$client\config\fml.toml"
if ($View -eq 'ar') {
    $fml=[IO.File]::ReadAllText("$client\config\fml.toml").Replace('earlyWindowControl = true','earlyWindowControl = false')
    [IO.File]::WriteAllText("$client\config\fml.toml",$fml,[Text.UTF8Encoding]::new($false))
}
$argumentPath=if ($View -eq 'ar') { 'C:\mc-client\args.txt' } else { 'C:\mc-run1\args.txt' }
$arguments = Get-Content $argumentPath -Raw
function Set-ClientArgument([string]$Name, [string]$Value) {
    $option = [regex]::Escape($Name)
    $pattern = '(?m)(^|\s)(?:"' + $option + '"|' + $option + ')\s+(?:"[^"]*"|\S+)'
    $replacement = '$1"' + $Name + '" "' + $Value + '"'
    if ([regex]::IsMatch($script:arguments, $pattern)) {
        $script:arguments = [regex]::Replace($script:arguments, $pattern, $replacement)
    } else { $script:arguments += "`n$Name `"$Value`"" }
}
foreach ($pair in @(@('--username','SSOTProof'),@('--uuid','6be1a840c0e83ed4bbdd8b3de8594333'),
    @('--accessToken','0'),@('--clientId','00000000-0000-0000-0000-000000000000'),@('--xuid','0'),@('--userType','legacy'),
    @('--gameDir',$client.Replace('\','/')),@('--quickPlayMultiplayer',"127.0.0.1:$Port"),
    @('--width','1280'),@('--height','720'))) { Set-ClientArgument $pair[0] $pair[1] }
$arguments = [regex]::Replace($arguments, '"?-Xmx[^"\s]+"?', '"-Xmx2G"')
$arguments = [regex]::Replace($arguments, '"?-Xms[^"\s]+"?', '"-Xms512M"')
$arguments = [regex]::Replace($arguments, '(?m)(^|\s)"?--(?:server|port)"?\s+(?:"[^"]*"|\S+)', '$1')
if ($arguments.Contains('100.91.208.60')) { throw 'Client arguments still contain a forbidden server address.' }
foreach ($name in @('--username','--uuid','--accessToken','--gameDir','--quickPlayMultiplayer')) {
    if ([regex]::Matches($arguments,[regex]::Escape($name)).Count -ne 1) { throw "Client has duplicate $name options." }
}
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText("$client\client.args", $arguments, $utf8)
[IO.File]::WriteAllLines("$client\options.txt", @('renderDistance:3','simulationDistance:5','maxFps:30',
    'enableVsync:false','fullscreen:false','guiScale:2','tutorialStep:none','pauseOnLostFocus:false'), $utf8)
$properties = Get-Content "$TestRoot\server.properties"
$secret = ($properties | Where-Object { $_ -like 'rcon.password=*' }).Substring(14)
$previousDriver = $env:GALLIUM_DRIVER
$env:GALLIUM_DRIVER = 'llvmpipe'
$process = $null
try {
    $process = Start-Process 'C:\mc-client\jdk\bin\java.exe' -ArgumentList "@$($client.Replace('\','/'))/client.args" -WorkingDirectory $client -WindowStyle Hidden -PassThru -RedirectStandardOutput "$client\stdout.log" -RedirectStandardError "$client\stderr.log"
    $process.PriorityClass = 'AboveNormal'
    [IO.File]::WriteAllText("$client\process.id", [string]$process.Id)
    $deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    do {
        if ($process.HasExited) { throw "Offline client exited with code $($process.ExitCode)." }
        if ((Test-Path "$client\logs\latest.log") -and
            (Select-String -LiteralPath "$client\logs\latest.log" -Pattern 'Failed to locate a primary monitor' -Quiet)) {
            throw 'GLFW cannot locate a primary monitor in this VM session; NeoForge stops before opening Minecraft.'
        }
        $players = Invoke-TestRcon $RconPort $secret 'list'
        if ($players -match 'SSOTProof') { break }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($players -notmatch 'SSOTProof') { throw 'Offline client did not join within the timeout.' }
    $camera = if ($View -eq 'ar') {
        @('gamemode creative SSOTProof',
          'item replace entity SSOTProof armor.head with cc_ar:ar_goggles[cc_ar:ar_goggles_data={x:1.0d,y:66.0d,z:0.0d,turtleId:-1,version:0L,label:"PR 6"}]',
          'tp SSOTProof 6 70 6 180 35','time set day','weather clear')
    } elseif ($View -eq 'mining') { @('gamemode spectator SSOTProof','tp SSOTProof 6 73 10 180 55','time set day','weather clear') } else { @('gamemode spectator SSOTProof','fill -3 67 -3 3 67 3 minecraft:air','tp SSOTProof 5 71 8 148 32','time set day','weather clear') }
    foreach ($command in $camera) {
        $reply = Invoke-TestRcon $RconPort $secret $command
        if ($View -eq 'ar') { "$command`n$reply" | Add-Content "$Output\client-ar-rcon.txt" }
    }
    Start-Sleep -Seconds 5
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SSOTCapture {
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr key, IntPtr value);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint key, uint mode);
}
'@
    $process.Refresh()
    if (!$process.MainWindowHandle) { throw 'Offline client has no screenshot window.' }
    function Send-ClientKey([int]$Key) {
        $scanCode = [SSOTCapture]::MapVirtualKey($Key,0)
        $bits = [int64](1 -bor ($scanCode -shl 16))
        [SSOTCapture]::PostMessage($process.MainWindowHandle,0x100,[IntPtr]$Key,[IntPtr]$bits) | Out-Null
        [SSOTCapture]::PostMessage($process.MainWindowHandle,0x101,[IntPtr]$Key,[IntPtr]($bits -bor 3221225472)) | Out-Null
    }
    function Send-ClientChat([string]$Text) {
        Send-ClientKey 0x54
        Start-Sleep -Milliseconds 500
        foreach ($character in $Text.ToCharArray()) {
            [SSOTCapture]::PostMessage($process.MainWindowHandle,0x102,[IntPtr][int]$character,[IntPtr]1) | Out-Null
        }
        Start-Sleep -Milliseconds 300
        Send-ClientKey 0x0D
        Start-Sleep -Seconds 2
    }
    function Wait-ChatRecord([string]$Path,[scriptblock]$Ready) {
        $until=[DateTime]::UtcNow.AddSeconds(90)
        do {
            $value=$null
            try { $value=Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
            if ($value -and (& $Ready $value)) { return $value }
            if ($process.HasExited) { throw 'The test client exited while waiting for AP chat.' }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $until)
        throw "Timed out waiting for an actual AP chat record in $Path."
    }
    $chatFailure=$null
    if ($View -eq 'ar') {
        try {
        $disk = "$TestRoot\world\computercraft\computer\0"
        Send-ClientChat '!pro'
        $denied=Wait-ChatRecord "$disk\ar-chat-events.json" { param($v) @($v.events).Count -ge 1 }
        if (@($denied.actions | Where-Object { $_.action }).Count) { throw 'Unenrolled chat executed an action.' }
        [IO.File]::WriteAllText("$disk\ar-enroll-test-player",'Explicit enrollment for disposable offline test player only.')
        $sent=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Send-ClientChat '$pro'
        $reply=Wait-ChatRecord "$disk\ar-chat-reply.json" { param($v) $v.time -ge $sent }
        if ($reply.text -notmatch 'confirm\s+([A-Za-z0-9-]+)') { throw "No confirmation token in AP reply. $($reply.text)" }
        $token = $Matches[1]
        Send-ClientChat ('$confirm '+$token)
        Send-ClientChat ('$confirm '+$token)
        $replayed=Wait-ChatRecord "$disk\ar-chat-events.json" { param($v) @($v.events).Count -ge 4 }
        if (@($replayed.actions | Where-Object { $_.action }).Count -ne 1) { throw 'Hidden confirmation or replay rejection failed.' }
        $sent=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Send-ClientChat '!pro'
        $reply=Wait-ChatRecord "$disk\ar-chat-reply.json" { param($v) $v.time -ge $sent }
        if ($reply.text -notmatch 'confirm\s+([A-Za-z0-9-]+)') { throw 'No public confirmation token.' }
        Send-ClientChat ('!confirm '+$Matches[1])
        $events=Wait-ChatRecord "$disk\ar-chat-events.json" { param($v) @($v.events).Count -ge 6 }
        if (@($events.actions).Count -ne 2) { throw 'Unauthorized or replayed chat action was accepted, or confirmation failed.' }
        if (!(@($events.events | Where-Object { $_.hidden -eq $true }).Count) -or
            !(@($events.events | Where-Object { $_.hidden -eq $false }).Count)) { throw 'Missing actual AP hidden/public events.' }
        Copy-Item "$disk\ar-chat-events.json" "$Output\real-ap-chat.json" -Force
        } catch {
            $chatFailure=$_.Exception.Message
            $chatFailure | Set-Content "$Output\chat-failure.txt"
        }
        $inventory=Invoke-TestRcon $RconPort $secret 'data get entity SSOTProof Inventory'
        $inventory | Set-Content "$Output\goggles-inventory.txt"
        if ($inventory -notmatch 'cc_ar:ar_goggles_data') { throw 'Linked goggles component is missing from the test player.' }
        Start-Sleep -Seconds 5
    }
    $scan = [SSOTCapture]::MapVirtualKey(0x71,0)
    $keyData = [int64](1 -bor ($scan -shl 16))
    $captureAt = [DateTime]::UtcNow
    [SSOTCapture]::PostMessage($process.MainWindowHandle, 0x100, [IntPtr]0x71, [IntPtr]$keyData) | Out-Null
    [SSOTCapture]::PostMessage($process.MainWindowHandle, 0x101, [IntPtr]0x71, [IntPtr]($keyData -bor 3221225472)) | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $shot = Get-ChildItem "$client\screenshots" -Filter '*.png' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -ge $captureAt } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($shot) { break }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    if (!$shot) { throw 'F2 did not produce a Minecraft framebuffer PNG.' }
    Copy-Item $shot.FullName "$Output\$ShotName" -Force
    if ($View -eq 'ar') {
        Invoke-TestRcon $RconPort $secret 'tp SSOTProof 6 65 5 180 0' | Out-Null
        Start-Sleep -Seconds 5
        $captureAt = [DateTime]::UtcNow
        Send-ClientKey 0x71
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            $shot = Get-ChildItem "$client\screenshots" -Filter '*.png' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTimeUtc -ge $captureAt } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($shot) { break }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)
        if (!$shot) { throw 'F2 did not produce the behind-wall goggles PNG.' }
        Copy-Item $shot.FullName "$Output\ar-xray.png" -Force
    }
    'Offline client framebuffer captured with F2.' | Set-Content "$Output\visual.txt"
    if ($chatFailure) { throw "Real AP chat validation failed. $chatFailure" }
} finally {
    $env:GALLIUM_DRIVER = $previousDriver
    if ($process -and !$process.HasExited) { Stop-Process -Id $process.Id -Force }
    foreach ($file in @('logs\latest.log','stderr.log')) {
        if (Test-Path "$client\$file") { Copy-Item "$client\$file" "$Output\client-$([IO.Path]::GetFileName($file))" -Force }
    }
}
