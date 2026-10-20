param([string]$TestRoot, [int]$Port, [int]$RconPort, [string]$Output, [int]$Timeout = 240, [switch]$OnDesktop, [string]$View="crossing", [string]$ShotName="ssot-crossing.png")
$ErrorActionPreference = 'Stop'
$arView=$View -like 'ar*'
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
. "$PSScriptRoot\ar-host.ps1"
$script:arBoxId=$null
if (Test-Path "$TestRoot\box-run-id.txt") {
    . 'C:\Work\gemini-input\gateb\gateb.ps1'
    $script:arBoxId=[IO.File]::ReadAllText("$TestRoot\box-run-id.txt").Trim()
}
$client = Join-Path $TestRoot 'client'
New-Item -ItemType Directory -Force -Path $client, "$client\mods", "$client\config" | Out-Null
Copy-Item "$TestRoot\mods\*.jar" "$client\mods"
Copy-Item "$TestRoot\config\classicperipherals.toml" "$client\config"
Copy-Item "$PSScriptRoot\fml.toml" "$client\config\fml.toml"
if ($arView) {
    $fml=[IO.File]::ReadAllText("$client\config\fml.toml").Replace('earlyWindowControl = true','earlyWindowControl = false')
    [IO.File]::WriteAllText("$client\config\fml.toml",$fml,[Text.UTF8Encoding]::new($false))
}
$argumentPath=if ($arView) { 'C:\mc-client\args.txt' } else { 'C:\mc-run1\args.txt' }
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
$recording = $null
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
    $camera = if ($arView) {
        @('gamemode creative SSOTProof',
          'item replace entity SSOTProof armor.head with cc_ar:ar_goggles[cc_ar:ar_goggles_data={x:1.0d,y:66.0d,z:0.0d,turtleId:-1,version:0L,label:"PR 6"}]',
          'tp SSOTProof 6 70 6 180 35','time set day','weather clear')
    } elseif ($View -eq 'warehouse') { @('gamemode spectator SSOTProof','tp SSOTProof 6 76 16 180 40','time set day','weather clear') } elseif ($View -eq 'mining') { @('gamemode spectator SSOTProof','tp SSOTProof 6 73 10 180 55','time set day','weather clear') } else { @('gamemode spectator SSOTProof','fill -3 67 -3 3 67 3 minecraft:air','tp SSOTProof 5 71 8 148 32','time set day','weather clear') }
    if ($arView -and $View -ne 'ar' -and (Test-Path "$TestRoot\capture-camera.json")) {
        $camera += @([IO.File]::ReadAllText("$TestRoot\capture-camera.json") | ConvertFrom-Json)
    }
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
    if ($View -in @('ar-production','ar-recall','ar-recharge')) {
        $encoder='C:\Work\gemini-input\p2\test-tools\ffmpeg-8.1.2\verified\ffmpeg-8.1.2-essentials_build\bin\ffmpeg.exe'
        if (!(Test-Path -LiteralPath $encoder)) { throw 'The verified FFmpeg executable is missing.' }
        $filter="gfxcapture=hwnd=$($process.MainWindowHandle.ToInt64()):max_framerate=15:capture_cursor=0"
        $recording=Start-Process -FilePath $encoder -WindowStyle Hidden -PassThru -ArgumentList @(
            '-y','-hide_banner','-loglevel','warning','-f','lavfi','-i',$filter,
            '-vf','hwdownload,format=bgra,format=yuv420p','-t','35','-c:v','libx264',
            '-preset','ultrafast','-crf','22',"`"$Output\$View.mp4`""
        ) -RedirectStandardOutput "$Output\video-stdout.log" -RedirectStandardError "$Output\video-stderr.log"
        "Native Minecraft window $($process.MainWindowHandle.ToInt64()), process $($process.Id), gfxcapture, 15 fps, 35 seconds." |
            Set-Content "$Output\video-source.txt"
    }
    function Send-ClientKey([int]$Key) {
        $scanCode = [SSOTCapture]::MapVirtualKey($Key,0)
        $bits = [int64](1 -bor ($scanCode -shl 16))
        [SSOTCapture]::PostMessage($process.MainWindowHandle,0x100,[IntPtr]$Key,[IntPtr]$bits) | Out-Null
        [SSOTCapture]::PostMessage($process.MainWindowHandle,0x101,[IntPtr]$Key,[IntPtr]($bits -bor 3221225472)) | Out-Null
    }
    function Capture-ClientScreenshot([string]$Name) {
        $captureAt=[DateTime]::UtcNow
        Send-ClientKey 0x71
        $deadline=$captureAt.AddSeconds(90)
        do {
            $shot=Get-ChildItem "$client\screenshots" -Filter '*.png' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTimeUtc -ge $captureAt } |
                Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            $bytes=$null
            if ($shot) {
                try { $bytes=[IO.File]::ReadAllBytes($shot.FullName) } catch {}
            }
            if ($bytes -and $bytes.Length -ge 20 -and
                [BitConverter]::ToString($bytes,0,8) -eq '89-50-4E-47-0D-0A-1A-0A' -and
                [BitConverter]::ToString($bytes,$bytes.Length-12,12) -eq '00-00-00-00-49-45-4E-44-AE-42-60-82') {
                [IO.File]::WriteAllBytes("$Output\$Name",$bytes)
                "$Name <- $($shot.FullName) ($($bytes.Length) bytes, PNG signature and IEND verified)" |
                    Add-Content "$Output\screenshot-sources.txt"
                return
            }
            if ($process.HasExited) { throw "Client exited before a complete PNG was saved for $Name." }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)
        throw "F2 did not finish a PNG with a valid signature and IEND for $Name."
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
            try { $value=Read-ArText $Path | ConvertFrom-Json } catch {}
            if ($value -and (& $Ready $value)) { return $value }
            if ($process.HasExited) { throw 'The test client exited while waiting for AP chat.' }
            Start-Sleep -Milliseconds 250
        } while ([DateTime]::UtcNow -lt $until)
        throw "Timed out waiting for an actual AP chat record in $Path."
    }
    $chatFailure=$null
    if ($View -in @('ar-recharge','ar-recall')) {
        $command=if ($View -eq 'ar-recharge') { '!recharge' } else { '!hub' }
        $before=Read-ArText "$TestRoot\world\computercraft\computer\0\ar-depth.json" | ConvertFrom-Json
        if (!$before.time) { throw 'Production server did not publish a chat observation timestamp.' }
        $sent=[long]$before.time
        Send-ClientChat $command
        $server=Wait-ChatRecord "$TestRoot\world\computercraft\computer\0\ar-depth.json" {
            param($v) @($v.replies | Where-Object { $_.at -gt $sent -and $_.name -eq 'SSOTProof' -and $_.text -match '[$!]confirm\s+([A-Za-z0-9-]+)' }).Count -gt 0
        }
        $reply=@($server.replies | Where-Object { $_.at -gt $sent -and $_.name -eq 'SSOTProof' -and $_.text -match '[$!]confirm\s+([A-Za-z0-9-]+)' })[-1]
        if ($reply.text -notmatch '[$!]confirm\s+([A-Za-z0-9-]+)') { throw 'Production chat returned no confirmation token.' }
        $token=$Matches[1]
        Send-ClientChat ('!confirm '+$token)
        $confirmed=Wait-ChatRecord "$TestRoot\world\computercraft\computer\0\ar-depth.json" {
            param($v)
            $chat=@($v.chat | Where-Object { $_.at -gt $sent -and $_.name -eq 'SSOTProof' })
            $expected=if ($View -eq 'ar-recharge') {'Recharge queued'} else {'Recall queued'}
            return @($chat | Where-Object { $_.message -eq $command }).Count -gt 0 -and
                @($chat | Where-Object { $_.message -eq ('!confirm '+$token) }).Count -gt 0 -and
                @($v.replies | Where-Object { $_.at -ge $reply.at -and $_.name -eq 'SSOTProof' -and $_.text -like "$expected*" }).Count -gt 0
        }
        $confirmed | ConvertTo-Json -Depth 40 | Set-Content "$Output\production-chat.json"
    }
    if ($View -eq 'ar') {
        try {
        $disk = "$TestRoot\world\computercraft\computer\0"
        Send-ClientChat '!pro'
        $denied=Wait-ChatRecord "$disk\ar-chat-events.json" { param($v) @($v.events).Count -ge 1 }
        if (@($denied.actions | Where-Object { $_.action }).Count) { throw 'Unenrolled chat executed an action.' }
        Write-ArText "$disk\ar-enroll-test-player" 'Explicit enrollment for disposable offline test player only.'
        $sent=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Send-ClientChat '$pro'
        $reply=Wait-ChatRecord "$disk\ar-chat-reply.json" { param($v) $v.time -ge $sent }
        if ($reply.text -notmatch '[$!]confirm\s+([A-Za-z0-9-]+)') { throw "No confirmation token in AP reply. $($reply.text)" }
        $token = $Matches[1]
        Send-ClientChat ('$confirm '+$token)
        Send-ClientChat ('$confirm '+$token)
        $replayed=Wait-ChatRecord "$disk\ar-chat-events.json" { param($v) @($v.events).Count -ge 4 }
        if (@($replayed.actions | Where-Object { $_.action }).Count -ne 1) { throw 'Hidden confirmation or replay rejection failed.' }
        $sent=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Send-ClientChat '!pro'
        $reply=Wait-ChatRecord "$disk\ar-chat-reply.json" { param($v) $v.time -ge $sent }
        if ($reply.text -notmatch '[$!]confirm\s+([A-Za-z0-9-]+)') { throw 'No public confirmation token.' }
        Send-ClientChat ('!confirm '+$Matches[1])
        $events=Wait-ChatRecord "$disk\ar-chat-events.json" { param($v) @($v.events).Count -ge 6 }
        if (@($events.actions).Count -ne 2) { throw 'Unauthorized or replayed chat action was accepted, or confirmation failed.' }
        if (!(@($events.events | Where-Object { $_.hidden -eq $true }).Count) -or
            !(@($events.events | Where-Object { $_.hidden -eq $false }).Count)) { throw 'Missing actual AP hidden/public events.' }
        Save-ArFile "$disk\ar-chat-events.json" "$Output\real-ap-chat.json"
        } catch {
            $chatFailure=$_.Exception.Message
            $chatFailure | Set-Content "$Output\chat-failure.txt"
        }
        $inventory=Invoke-TestRcon $RconPort $secret 'data get entity SSOTProof Inventory'
        $inventory | Set-Content "$Output\goggles-inventory.txt"
        if ($inventory -notmatch 'cc_ar:ar_goggles_data') { throw 'Linked goggles component is missing from the test player.' }
        Start-Sleep -Seconds 5
    }
    Capture-ClientScreenshot $ShotName
    if ($View -in @('ar-production','ar-recall','ar-recharge')) {
        $inventory=Invoke-TestRcon $RconPort $secret 'data get entity SSOTProof Inventory'
        $inventory | Set-Content "$Output\production-goggles-inventory.txt"
        if ($inventory -notmatch 'cc_ar:ar_goggles_data') { throw 'Production capture has no linked goggles.' }
        if (!$recording.WaitForExit(60000)) { throw 'Native video recorder exceeded its deadline.' }
        if ($recording.ExitCode -ne 0 -or !(Test-Path "$Output\$View.mp4")) {
            throw 'Native video recording failed. Inspect video-stderr.log.'
        }
    }
    if ($View -eq 'ar') {
        Invoke-TestRcon $RconPort $secret 'tp SSOTProof 6 65 5 180 0' | Out-Null
        Start-Sleep -Seconds 5
        Capture-ClientScreenshot 'ar-xray.png'
        $command='fill 3 65 0 9 68 0 minecraft:air'
        $reply=Invoke-TestRcon $RconPort $secret $command
        "$command`n$reply" | Add-Content "$Output\client-ar-rcon.txt"
        Start-Sleep -Seconds 5
        Capture-ClientScreenshot 'ar-geometry.png'
    }
    if($View -eq 'warehouse') {
        $encoder=$env:SSOT_FFMPEG
        if(!$encoder){$encoder='C:\Work\gemini-input\p2\test-tools\ffmpeg-8.1.2\verified\ffmpeg-8.1.2-essentials_build\bin\ffmpeg.exe'}
        if(!$encoder -or !(Test-Path $encoder)){throw 'Set SSOT_FFMPEG to a local FFmpeg executable for the recharge clip.'}
        $frames="$Output\recharge-frames"
        New-Item -ItemType Directory -Force -Path $frames | Out-Null
        function Capture-Rcon([string]$Command) {
            $r=Invoke-TestRcon $RconPort $secret $Command
            [IO.File]::AppendAllText("$Output\capture-rcon.txt","$([DateTime]::UtcNow.ToString('o')) > $Command`n$r`n")
            $r
        }
        Capture-Rcon 'computercraft shutdown 20' | Out-Null
        foreach($position in @('39 65 32','48 65 32')){Capture-Rcon "setblock $position minecraft:air" | Out-Null}
        $probe="$TestRoot\world\computercraft\computer\20"
        [IO.File]::WriteAllText("$probe\probe-mode",'capture',$utf8)
        if(Test-Path "$probe\capture-go"){Remove-Item -LiteralPath "$probe\capture-go"}
        foreach($command in @('forceload add 32 32 63 47','fill 39 64 31 49 64 34 minecraft:stone_bricks','setblock 40 65 32 superbwarfare:charging_station',
            'item replace block 40 65 32 container.0 with minecraft:coal_block 64',
            'setblock 47 65 32 computercraft:turtle_advanced[facing=east]{ComputerId:20,Fuel:100,RightUpgrade:"computercraft:wireless_modem_advanced"}',
            'tp SSOTProof 44 71 42 180 35','computercraft turn-on 20')){Capture-Rcon $command | Out-Null}
        Start-Sleep -Seconds 3
        $times=@()
        for($index=0;$index -lt 20;$index++) {
            $times += [DateTime]::UtcNow
            Capture-ClientScreenshot ('recharge-frames/{0:d4}.png' -f $index)
            if($index -eq 0){[IO.File]::WriteAllText("$probe\capture-go",'ready',$utf8)}
            Start-Sleep -Milliseconds 250
        }
        if(!(Test-Path "$probe\charge-capture.json")){throw 'The recorded recharge probe did not finish.'}
        $record=Get-Content "$probe\charge-capture.json" -Raw | ConvertFrom-Json
        if($record.after -le $record.before){throw 'The recorded turtle did not recharge.'}
        Copy-Item "$probe\charge-capture.json" "$Output\charge-capture.json"
        Capture-Rcon 'data get block 48 65 32' | Out-Null
        $list=@()
        for($index=0;$index -lt $times.Count;$index++) {
            $path=(Join-Path $frames ('{0:d4}.png' -f $index)).Replace('\','/')
            $duration=if($index -lt $times.Count-1){($times[$index+1]-$times[$index]).TotalSeconds}else{1}
            $list+="file '$path'"
            $list+='duration '+$duration.ToString('0.000',[Globalization.CultureInfo]::InvariantCulture)
        }
        $list+= "file '$path'"
        [IO.File]::WriteAllLines("$frames\frames.txt",$list,$utf8)
        & $encoder -y -loglevel error -f concat -safe 0 -i "$frames\frames.txt" -fps_mode vfr -c:v libx264 -preset ultrafast -crf 22 -pix_fmt yuv420p "$Output\recharge.mp4" 2> "$Output\encoder.log"
        if($LASTEXITCODE -ne 0){throw 'Recharge video encoding failed.'}
        & $encoder -version | Select-Object -First 1 | Set-Content "$Output\encoder-version.txt"
    }
    'Offline client framebuffer captured with F2.' | Set-Content "$Output\visual.txt"
    if ($chatFailure) { throw "Real AP chat validation failed. $chatFailure" }
} finally {
    $env:GALLIUM_DRIVER = $previousDriver
    if ($process -and !$process.HasExited) { Stop-Process -Id $process.Id -Force }
    if ($recording -and !$recording.HasExited) { Stop-Process -Id $recording.Id -Force }
    foreach ($file in @('logs\latest.log','stderr.log')) {
        if (Test-Path "$client\$file") { Copy-Item "$client\$file" "$Output\client-$([IO.Path]::GetFileName($file))" -Force }
    }
}
