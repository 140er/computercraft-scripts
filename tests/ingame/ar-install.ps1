$installDisk=Join-Path $TestRoot 'world\computercraft\computer\4'
$installRoot=[IO.Path]::GetFullPath($TestRoot)
if ($installRoot -notmatch '^C:\\Work\\mc-ssot-pr6-[a-zA-Z0-9-]+$') { throw 'Installer phase requires the owned PR 6 test root.' }
if (!$script:arProcess -or $script:arProcess.HasExited) { throw 'Installer phase requires the owned test server to be running.' }
Rcon 'computercraft shutdown 4' | Out-Null
Start-Sleep -Seconds 2
$installStartup=Join-Path $installDisk 'startup.lua'
$installSavedStartup=[IO.File]::ReadAllText($installStartup)
$installResultPath=Join-Path $installDisk 'ar-install-result.json'
if (Test-Path $installResultPath) { throw 'Installer result already exists. Preserve it and use a fresh test root.' }
Copy-Item "$PSScriptRoot\ar-install-probe.lua" "$installDisk\ar-install-probe.lua"
[IO.File]::WriteAllText($installStartup,'shell.run("ar-install-probe.lua")',$utf8)
try {
    Rcon 'computercraft turn-on 4' | Out-Null
    $installUntil=[DateTime]::UtcNow.AddSeconds([Math]::Max($Timeout,1800))
    $installResult=$null
    do {
        if ($script:arProcess.HasExited) { throw 'Owned server exited during native installer checks.' }
        if (Test-Path $installResultPath) {
            $installResult=$null
            try { $installResult=Get-Content $installResultPath -Raw | ConvertFrom-Json } catch {}
            if ($installResult -and $installResult.error) { throw "Native installer failed. $($installResult.error)" }
            if ($installResult -and $installResult.ok) {
                Copy-Item $installResultPath "$Output\native-install-result.json"
                break
            }
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $installUntil)
    if (!$installResult -or !$installResult.ok) { throw 'Native installer probe timed out.' }
} finally {
    Rcon 'computercraft shutdown 4' | Out-Null
    Start-Sleep -Seconds 2
    [IO.File]::WriteAllText($installStartup,$installSavedStartup,$utf8)
    if (Test-Path $installResultPath) { Copy-Item $installResultPath "$Output\native-install-result.json" -Force }
}
