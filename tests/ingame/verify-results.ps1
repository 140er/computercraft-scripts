param([string]$Computers, [string]$Output)
$ErrorActionPreference = 'Stop'
$controller = Get-Content "$Computers\4\sandbox-result.json" -Raw | ConvertFrom-Json
$statePath = [IO.Path]::GetFullPath("$Computers\0\ssot.state").Replace('\','/')
$check = "local f=assert(io.open([[$statePath]])); local s=assert(load('return '..f:read('*a'),'state','t',{}))().value; f:close(); assert(s.rev==$($controller.revision)); assert(next(s.moves)==nil); local c=assert(s.chunks['test:lab|-2|4|0']); assert(c.rev==s.rev and s.names[c.cells[1]]=='minecraft:stone'); print('Latest scan revision and empty reservation set survived restart')"
$durable = & 'C:\Tools\lua52\lua52.exe' -e $check
if ($LASTEXITCODE -ne 0) { throw 'Latest durable map or reservation cleanup is incorrect.' }
New-Item -ItemType Directory -Force -Path $Output | Out-Null
$durable | Set-Content "$Output\durable-state.txt"
$positions = @{ 1 = '-2,65,0'; 2 = '0,65,-2'; 3 = '2,65,0' }
$events = @()
foreach ($id in 1..3) {
    $result = Get-Content "$Computers\$id\sandbox-result.json" -Raw | ConvertFrom-Json
    if (!$result.ok -or @($result.timeline).Count -lt 5) { throw "Turtle $id has no complete successful trajectory." }
    foreach ($point in $result.timeline) {
        $events += [pscustomobject]@{ id = $id; at = $point.at; x = $point.x; y = $point.y; z = $point.z; method = $point.method }
    }
}
$axes = @{}
foreach ($point in $events | Sort-Object at,id) {
    $from = @($positions[$point.id].Split(',') | ForEach-Object { [int]$_ })
    $delta = @(($point.x - $from[0]), ($point.y - $from[1]), ($point.z - $from[2]))
    if (([Math]::Abs($delta[0]) + [Math]::Abs($delta[1]) + [Math]::Abs($delta[2])) -ne 1) { throw 'A recorded move was not adjacent.' }
    $axes[$delta -join ','] = $true
    $to = "$($point.x),$($point.y),$($point.z)"
    foreach ($other in 1..3) {
        if ($other -ne $point.id -and $positions[$other] -eq $to) { throw 'The recorded trajectories overlap in an occupied cell.' }
    }
    $positions[$point.id] = $to
}
if ($axes.Count -ne 6) { throw 'The trajectories did not exercise all six displacement directions.' }
if ($positions[1] -ne '-2,66,0' -or $positions[2] -ne '0,66,-2' -or $positions[3] -ne '2,66,0') { throw 'Unexpected final turtle positions.' }
New-Item -ItemType Directory -Force -Path $Output | Out-Null
$events | Sort-Object at,id | Export-Csv "$Output\positions.csv" -NoTypeInformation
@{ ok = $true; turtles = 3; moves = $events.Count; directions = $axes.Count; collisions = 0 } | ConvertTo-Json | Set-Content "$Output\trajectory-verdict.json"
Add-Type -AssemblyName System.Drawing
$bitmap = New-Object Drawing.Bitmap 1200,720
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$graphics.Clear([Drawing.Color]::White)
$font = New-Object Drawing.Font 'Consolas',14
$heading = New-Object Drawing.Font 'Consolas',19
$black = [Drawing.Brushes]::Black
$graphics.DrawString('SSOT PR 1 | Server-recorded turtle positions', $heading, $black, 24, 20)
$graphics.DrawString('This diagram is not a Minecraft client screenshot.', $font, $black, 24, 58)
$colors = @([Drawing.Color]::RoyalBlue,[Drawing.Color]::ForestGreen,[Drawing.Color]::DarkOrange)
for ($id = 1; $id -le 3; $id++) {
    $row = 130 + ($id - 1) * 175
    $brush = New-Object Drawing.SolidBrush $colors[$id - 1]
    $pen = New-Object Drawing.Pen $colors[$id - 1],3
    $graphics.DrawString("Turtle $id", $heading, $brush, 24, $row)
    $points = @($events | Where-Object { $_.id -eq $id } | Sort-Object at)
    $step = [Math]::Min(140, 1000 / [Math]::Max(1,$points.Count - 1))
    for ($i = 0; $i -lt $points.Count; $i++) {
        $x = 50 + $i * $step
        $y = $row + 60
        if ($i -gt 0) { $graphics.DrawLine($pen,[single]($x - $step),[single]$y,[single]$x,[single]$y) }
        $graphics.FillEllipse($brush,[single]($x-5),[single]($y-5),10,10)
        $point = $points[$i]
        $graphics.DrawString("$($point.x),$($point.y),$($point.z)", $font, $black, [single]($x-24), [single]($y+15))
    }
    $pen.Dispose()
    $brush.Dispose()
}
$graphics.DrawString('All steps are adjacent. All six directions ran. No occupied cells overlapped.', $font, $black, 24, 680)
$bitmap.Save("$Output\position-timeline.png",[Drawing.Imaging.ImageFormat]::Png)
$heading.Dispose()
$font.Dispose()
$graphics.Dispose()
$bitmap.Dispose()
