param([string]$TestRoot, [int]$Port, [int]$RconPort, [string]$Output, [int]$Timeout = 240, [switch]$OnDesktop, [string]$View="crossing", [string]$ShotName="ssot-crossing.png")
$ErrorActionPreference = 'Stop'
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
$arguments = Get-Content 'C:\mc-run1\args.txt' -Raw
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
$arguments = [regex]::Replace($arguments, '(?m)(^|\s)--(?:server|port)\s+(?:"[^"]*"|\S+)', '$1')
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
    $camera = if ($View -eq 'warehouse') { @('gamemode spectator SSOTProof','tp SSOTProof 6 76 16 180 40','time set day','weather clear') } elseif ($View -eq 'mining') { @('gamemode spectator SSOTProof','tp SSOTProof 6 73 10 180 55','time set day','weather clear') } else { @('gamemode spectator SSOTProof','fill -3 67 -3 3 67 3 minecraft:air','tp SSOTProof 5 71 8 148 32','time set day','weather clear') }
    foreach ($command in $camera) {
        Invoke-TestRcon $RconPort $secret $command | Out-Null
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
    function Save-Frame([string]$Target) {
    $scan = [SSOTCapture]::MapVirtualKey(0x71,0)
    $keyData = [int64](1 -bor ($scan -shl 16))
    $captureAt = [DateTime]::UtcNow
    [SSOTCapture]::PostMessage($process.MainWindowHandle, 0x100, [IntPtr]0x71, [IntPtr]$keyData) | Out-Null
    [SSOTCapture]::PostMessage($process.MainWindowHandle, 0x101, [IntPtr]0x71, [IntPtr]($keyData -bor 3221225472)) | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $shot = Get-ChildItem "$client\screenshots" -Filter '*.png' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -ge $captureAt } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($shot) {
            $ready=$false
            try {
                $bytes=[IO.File]::ReadAllBytes($shot.FullName)
                if($bytes.Length -ge 12) {
                    $tail=[BitConverter]::ToString($bytes, $bytes.Length-12)
                    $ready=$tail -eq '00-00-00-00-49-45-4E-44-AE-42-60-82'
                }
            } catch { }
            if($ready){break}
            $shot=$null
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    if (!$shot) { throw 'F2 did not produce a Minecraft framebuffer PNG.' }
    Copy-Item $shot.FullName $Target -Force
    }
    Save-Frame "$Output\$ShotName"
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
            Save-Frame (Join-Path $frames ('{0:d4}.png' -f $index))
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
} finally {
    $env:GALLIUM_DRIVER = $previousDriver
    if ($process -and !$process.HasExited) { Stop-Process -Id $process.Id -Force }
    foreach ($file in @('logs\latest.log','stderr.log')) {
        if (Test-Path "$client\$file") { Copy-Item "$client\$file" "$Output\client-$([IO.Path]::GetFileName($file))" -Force }
    }
}
