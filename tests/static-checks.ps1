$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$connectorPath = Join-Path $root 'connect.ps1'
$readmePath = Join-Path $root 'README.md'

function Assert-Contains {
    param([string]$Text, [string]$Expected, [string]$Message)

    if ($Text.IndexOf($Expected, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw $Message
    }
}

function Assert-NotContains {
    param([string]$Text, [string]$Unexpected, [string]$Message)

    if ($Text.IndexOf($Unexpected, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw $Message
    }
}

$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $connectorPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    $details = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
    throw "connect.ps1 has parser errors: $details"
}

$source = Get-Content -Raw -LiteralPath $connectorPath
Assert-NotContains $source 'Invoke-Expression' 'connect.ps1 must not use Invoke-Expression.'
Assert-NotContains $source 'StrictHostKeyChecking=no' 'Host-key checking must never be disabled.'
Assert-Contains $source 'StrictHostKeyChecking=accept-new' 'TOFU accept-new behavior is missing.'
Assert-Contains $source '127.0.0.1:${Port}:127.0.0.1:${Port}' 'Loopback forwarding invariant is missing.'
Assert-Contains $source 'OwningProcess' 'Tunnel ownership must use the listener PID.'
Assert-Contains $source 'ExitOnForwardFailure=yes' 'SSH forward failures must remain fatal.'
Assert-Contains $source '[pscustomobject]@{ host = $ServerHost; user = $User }' `
    'New config must store only host and user.'

$noVncIndex = $source.LastIndexOf('Test-NoVnc', [System.StringComparison]::Ordinal)
$saveIndex = $source.LastIndexOf(
    'Save-Config -ServerHost $serverHost -User $user',
    [System.StringComparison]::Ordinal
)
$browserIndex = $source.LastIndexOf('Start-Process $Url', [System.StringComparison]::Ordinal)
if ($noVncIndex -lt 0 -or $saveIndex -le $noVncIndex -or $browserIndex -le $saveIndex) {
    throw 'Expected order is noVNC success, config save, then browser launch.'
}

$launchers = @(
    @{ Name = 'connect.cmd'; Flag = $null },
    @{ Name = 'stop.cmd'; Flag = '-Stop' },
    @{ Name = 'reset.cmd'; Flag = '-Reset' }
)
foreach ($launcher in $launchers) {
    $path = Join-Path $root $launcher.Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing launcher: $($launcher.Name)"
    }
    $cmd = Get-Content -Raw -LiteralPath $path
    Assert-Contains $cmd 'powershell.exe' "$($launcher.Name) must call Windows PowerShell."
    Assert-Contains $cmd '-NoProfile' "$($launcher.Name) must isolate the user profile."
    Assert-Contains $cmd '-ExecutionPolicy Bypass' `
        "$($launcher.Name) must use only a process-scoped execution-policy override."
    Assert-Contains $cmd '"%~dp0connect.ps1"' `
        "$($launcher.Name) must resolve connect.ps1 relative to itself."
    if ($launcher.Flag) {
        Assert-Contains $cmd $launcher.Flag "$($launcher.Name) is missing $($launcher.Flag)."
    } else {
        Assert-NotContains $cmd '-Stop' 'connect.cmd must not stop the tunnel.'
        Assert-NotContains $cmd '-Reset' 'connect.cmd must not reset settings.'
    }
}

$readme = Get-Content -Raw -LiteralPath $readmePath
Assert-NotContains $readme 'MaxBetov-pdd' 'README still points users at the upstream repositories.'
Assert-Contains $readme 'ramirezoffc/minter-rr' 'README does not point at the user MINTER fork.'

Write-Host 'PASS: Windows connector syntax and static invariants'
