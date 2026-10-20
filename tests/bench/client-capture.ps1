. C:\Work\gemini-input\gateb\gateb.ps1
. "$PSScriptRoot\box-probe.ps1"
$runId = [IO.File]::ReadAllText("$TestRoot\p0-run-id.txt").Trim()
$frames = @()
function P0-Rcon([string[]]$Commands) {
    Invoke-GatebRcon $runId $Commands -Log "$Output\capture-rcon.txt"
}
function P0-Frame([string]$Name) {
    P0-Rcon @('title SSOTProof actionbar {"text":"P0 '+$Name+'","color":"white"}') | Out-Null
    Start-Sleep -Seconds 1
    $path = Join-Path $Output "$Name.png"
    Save-Frame $path
    $script:frames += [pscustomobject]@{path=$path; at=[DateTime]::UtcNow}
}
function P0-Probe([int]$Computer,[string]$Name,[string]$Operation,[hashtable]$Arguments=@{}) {
    Invoke-P0Probe -RunId $runId -Computer $Computer -Name $Name -Probe $Operation -Arguments $Arguments -Output $Output
}
P0-Frame 'room'
foreach ($case in @(
    @{name='anchor';tp='4.25 -58 0.75 0 0'},
    @{name='yaw-west-down';tp='4.25 -58 0.75 90 30'},
    @{name='yaw-east-up';tp='4.25 -58 0.75 -90 -30'},
    @{name='negative-fraction';tp='-2.25 -59 -2.75 180 0'},
    @{name='range-1024';tp='1024.25 -58 0.75 0 0'}
)) {
    P0-Rcon @('gamemode creative SSOTProof', "tp SSOTProof $($case.tp)") | Out-Null
    Start-Sleep -Seconds 2
    P0-Rcon @('data get entity SSOTProof Pos','data get entity SSOTProof Rotation') | Out-Null
    P0-Probe 0 "detector-$($case.name)" 'detector' | Out-Null
    P0-Frame "detector-$($case.name)"
}
P0-Rcon @('execute in minecraft:the_nether run tp SSOTProof 512.25 66 0.75 0 0') | Out-Null
P0-Probe 0 'detector-crossdim' 'detector' | Out-Null
P0-Frame 'detector-crossdim'
P0-Rcon @('execute in minecraft:overworld run tp SSOTProof 2 -59 8 180 0') | Out-Null
$cases = @(
    @{id=0;name='storage'}, @{id=1;name='storage'}, @{id=2;name='storage'},
    @{id=0;name='astar-2048'}, @{id=0;name='astar-4096'},
    @{id=0;name='blake3-keyed-1024'}, @{id=0;name='blake3-keyed-8192'}, @{id=0;name='blake3-keyed-37888'},
    @{id=0;name='sha256-section-963'}, @{id=0;name='sha256-section-12288'}, @{id=0;name='sha256-section-37888'},
    @{id=0;name='x25519-keygen'}, @{id=0;name='x25519-exchange'}, @{id=0;name='ed25519-sign'},
    @{id=0;name='ed25519-verify'}, @{id=0;name='ed25519-reject'},
    @{id=0;name='ed25519-sign-8192'}, @{id=0;name='ed25519-verify-8192'},
    @{id=0;name='randomness-supplied-seed'}, @{id=0;name='randomness-vm-timing'},
    @{id=0;name='randomness-krist-http'}, @{id=0;name='randomness-crypto-peripheral'},
    @{id=1;name='fuel-normal'}, @{id=6;name='fuel-charging'}, @{id=6;name='fuel-without-charger'},
    @{id=0;name='clock-frozen-1000'}, @{id=0;name='clock-jump-6000'}, @{id=0;name='clock-running-500'},
    @{id=4;name='ender-received'}, @{id=4;name='normal-received'}, @{id=4;name='ender-crossdim-received'},
    @{id=2;name='analog-input-0'}, @{id=2;name='analog-input-1'}, @{id=2;name='analog-input-7'}, @{id=2;name='analog-input-15'},
    @{id=5;name='boot'}
)
foreach ($upgrade in @('automata','netherite_end_automata','starbound_end_automata','creative_end_automata','chunk_vial')) {
    $cases += @{id=3;name="fuel-$upgrade"}
}
foreach ($case in $cases) {
    $text = Get-GatebText $runId "world/computercraft/computer/$($case.id)/results/$($case.name).json"
    if (!$text) { throw "Missing measurement for capture $($case.id)/$($case.name)" }
    $value = $text | ConvertFrom-Json
    P0-Probe 0 "capture-$($case.id)-$($case.name)" 'display' @{value=$value} | Out-Null
    P0-Frame "$($case.id)-$($case.name)"
}
P0-Rcon @(
    'item replace entity SSOTProof armor.head with cc_ar:ar_goggles[minecraft:custom_data={x:0.0d,y:-59.0d,z:-1.0d,version:-1L,label:"P0"}]',
    'tp SSOTProof 4 -59 7 180 0',
    'fill 1 -59 -2 7 -55 -2 minecraft:stone'
) | Out-Null
P0-Probe 0 'ar-wall' 'ar' | Out-Null
Start-Sleep -Seconds 3
P0-Frame 'ar-wall'
P0-Rcon @('fill 1 -59 -2 7 -55 -2 minecraft:air') | Out-Null
P0-Probe 0 'ar-open' 'ar' | Out-Null
Start-Sleep -Seconds 3
P0-Frame 'ar-open'
$encoder = 'C:\Work\gemini-input\p2\test-tools\ffmpeg-8.1.2\verified\ffmpeg-8.1.2-essentials_build\bin\ffmpeg.exe'
P0-Rcon @(
    'tp SSOTProof 24 -54 8 180 25',
    'setblock 25 -59 0 superbwarfare:charging_station',
    'item replace block 25 -59 0 container.0 with minecraft:coal_block 64'
) | Out-Null
$frames = @()
Set-GatebText $runId 'world/computercraft/computer/6/command.json' '{"id":"fuel-video","probe":"fuel","args":{"pause":1}}'
Set-GatebText $runId 'world/computercraft/computer/6/command.ready' 'ready'
for ($index = 0; $index -lt 16; $index++) {
    $path = Join-Path $Output ('video-{0:d3}.png' -f $index)
    $at = [DateTime]::UtcNow
    Save-Frame $path
    $frames += [pscustomobject]@{path=$path;at=$at}
    Start-Sleep -Milliseconds 250
}
$videoResult = Wait-GatebFile $runId 'world/computercraft/computer/6/results/fuel-video.json' 90
[IO.File]::WriteAllText("$Output\fuel-video.json", $videoResult)
if (($videoResult | ConvertFrom-Json).value.moves -ne 10) { throw 'The recorded turtle did not complete ten moves.' }
$list = @()
for ($index = 0; $index -lt $frames.Count; $index++) {
    $frame = $frames[$index]
    $duration = if ($index + 1 -lt $frames.Count) { ($frames[$index+1].at - $frame.at).TotalSeconds } else { 1 }
    $list += "file '$($frame.path.Replace('\','/'))'"
    $list += 'duration ' + $duration.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
}
$list += "file '$($frames[-1].path.Replace('\','/'))'"
[IO.File]::WriteAllLines("$Output\frames.txt", $list, [Text.UTF8Encoding]::new($false))
& $encoder -y -loglevel error -f concat -safe 0 -i "$Output\frames.txt" -c:v libx264 -preset ultrafast -crf 22 -pix_fmt yuv420p "$Output\p0-probes.mp4" 2> "$Output\encoder.log"
if ($LASTEXITCODE) { throw 'P0 capture video encoding failed.' }
'Real F2 frames of ten physical moves beside a powered charging station. Video frame durations retain capture timing.' | Set-Content "$Output\visual.txt"
