$script:GatebComputerAt = @{}

function Register-GatebComputerPlace([string]$Command) {
}

function Invoke-LoadedTurnOn {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][scriptblock]$Send,
        [int]$WaitSec = 30
    )
    & $Send $Command
}
