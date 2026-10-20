param([Parameter(Mandatory)][string]$Computers, [int[]]$Ids = @(0,1,2))
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path "$PSScriptRoot\..\..").Path
foreach ($id in $Ids) {
    $disk = Join-Path $Computers ([string]$id)
    New-Item -ItemType Directory -Force -Path $disk | Out-Null
    Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.lua' | Copy-Item -Destination $disk
    Copy-Item -LiteralPath "$PSScriptRoot\vendor" -Destination $disk -Recurse -Force
    foreach ($name in @('nav.lua','atomic.lua','ssot.lua','mine-tasks.lua','warehouse-tasks.lua')) {
        Copy-Item -LiteralPath "$source\$name" -Destination $disk
    }
}
