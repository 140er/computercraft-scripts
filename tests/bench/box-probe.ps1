function Invoke-P0Probe {
    param(
        [string]$RunId, [int]$Computer, [string]$Name, [string]$Probe,
        [hashtable]$Arguments = @{}, [string]$Output, [int]$TimeoutSec = 120
    )
    $body = @{id=$Name; probe=$Probe; args=$Arguments} | ConvertTo-Json -Depth 10 -Compress
    Set-GatebText $RunId "world/computercraft/computer/$Computer/command.json" $body
    $uploaded = Get-GatebText $RunId "world/computercraft/computer/$Computer/command.json"
    if ($uploaded -cne $body) { throw 'Probe command upload did not round trip.' }
    Set-GatebText $RunId "world/computercraft/computer/$Computer/command.ready" 'ready'
    $text = Wait-GatebFile $RunId "world/computercraft/computer/$Computer/results/$Name.json" $TimeoutSec
    [IO.File]::WriteAllText("$Output\$Name.json", $text)
    $result = $text | ConvertFrom-Json
    Write-Host "$Name ok=$($result.ok) elapsedMs=$($result.elapsedMs)"
    return $result
}
