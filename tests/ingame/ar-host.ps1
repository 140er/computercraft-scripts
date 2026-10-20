function Get-ArRemotePath([string]$Path) {
    $root = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($Path)
    if (!$full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) {
        throw "AR test file is outside its disposable root: $Path"
    }
    return $full.Substring($root.Length).Replace('\','/')
}
function Read-ArText([string]$Path) {
    if ($script:arBoxId) { return Get-GatebText $script:arBoxId (Get-ArRemotePath $Path) }
    if (Test-Path -LiteralPath $Path) { return [IO.File]::ReadAllText($Path) }
    return $null
}
function Write-ArText([string]$Path,[string]$Text) {
    $relative = Get-ArRemotePath $Path
    if ($script:arBoxId) { Set-GatebText $script:arBoxId $relative $Text }
    else {
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
        [IO.File]::WriteAllText($Path,$Text,$utf8)
    }
}
function Copy-ArFile([string]$From,[string]$To) {
    Write-ArText $To ([IO.File]::ReadAllText($From).Replace("`r`n","`n"))
}
function Save-ArFile([string]$From,[string]$To) {
    $text = Read-ArText $From
    if ($null -ne $text) { [IO.File]::WriteAllText($To,$text,$utf8) }
}
function Test-ArServer {
    if ($script:arBoxId) { return $script:arBoxRunning }
    return $script:arProcess -and !$script:arProcess.HasExited
}
function Copy-ArRole([int]$Id,[string]$Role) {
    $files=@(& 'C:\Tools\lua52\lua52.exe' "$PSScriptRoot\ar-role-files.lua" "$source\bundle-manifest.lua" $Role)
    if ($LASTEXITCODE -ne 0) { throw "Cannot resolve the native $Role file list." }
    foreach ($file in $files) {
        if ($file -notmatch '^[\w-]+\.lua$') { throw 'Invalid native role file.' }
        Copy-ArFile "$source\$file" "$TestRoot\world\computercraft\computer\$Id\$file"
    }
}
function Copy-ArCache {
    if ($SpaceLimit -gt 1000000) {
        $files=@(Get-ChildItem "$source\*.lua" | ForEach-Object Name)
    } else {
        $files=@(& 'C:\Tools\lua52\lua52.exe' "$PSScriptRoot\ar-role-files.lua" "$source\bundle-manifest.lua" server miner store)
        if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the native cache file list.' }
    }
    foreach ($file in $files) {
        Copy-ArFile "$source\$file" "$TestRoot\world\computercraft\computer\0\server-code\$file"
    }
}
