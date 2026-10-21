$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\role-closure.ps1"
$utf8 = New-Object Text.UTF8Encoding($false)
$root = Join-Path ([IO.Path]::GetTempPath()) 'role-closure-check'
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Path @(
    "$root\tests\ingame",
    "$root\lib\stubs"
) | Out-Null
$manifest = @'
return {
  ["roles"]={
    ["server"]={
      ["entry"]="server.lua",
      ["files"]={
        [1]="server.lua",
        [2]="ar-planner.lua",
        [3]="wh2-layout.lua",
        [4]="lib/stubs/a1_chat.lua",
        [5]="lib/stubs/a1_planner_core.lua",
        [6]="lib/stubs/layout_dep.lua"
      }
    }
  }
}
'@
[IO.File]::WriteAllText("$root\bundle-manifest.lua", $manifest.Replace("`r`n","`n"), $utf8)
[IO.File]::WriteAllText("$root\tests\ingame\server.lua", "loadfile(`"server.lua`")`n", $utf8)
[IO.File]::WriteAllText("$root\server.lua", "dofile(`"ar-planner.lua`")`ndofile(`"wh2-layout.lua`")`n", $utf8)
[IO.File]::WriteAllText("$root\ar-planner.lua", "local stub, err = loadModule(`"lib/stubs/a1_planner_core.lua`")`nlocal loaded, err = loadModule(`"lib/stubs/a1_chat.lua`")`n", $utf8)
[IO.File]::WriteAllText("$root\wh2-layout.lua", "local ok, stub = pcall(dofile, `"lib/stubs/layout_dep.lua`")`n", $utf8)
foreach ($stub in @('a1_chat.lua','a1_planner_core.lua','layout_dep.lua')) {
    [IO.File]::WriteAllText("$root\lib\stubs\$stub", "return {}`n", $utf8)
}
$entry = "$root\tests\ingame\server.lua"
$rows = @(Get-GateRoleFiles -Source $root -Entry @($entry))
$have = @{}
foreach ($row in $rows) { $have[$row.DiskName] = $true }
$want = @(
    'server.lua',
    'ar-planner.lua',
    'wh2-layout.lua',
    'lib/stubs/a1_chat.lua',
    'lib/stubs/a1_planner_core.lua',
    'lib/stubs/layout_dep.lua',
    'test-server.lua'
)
$missing = @($want | Where-Object { -not $have.ContainsKey($_) })
$extra = @($have.Keys | Where-Object { $want -notcontains $_ } | Sort-Object)
if ($missing.Count -gt 0) { throw "Server role copy left out $($missing -join ', ')" }
if ($extra.Count -gt 0) { throw "Server role copy added $($extra -join ', ')" }
Write-Output 'PASS server role copy matches the manifest, including the three stubs'
