<#
.SYNOPSIS
  Opens the MINTER GUI running on your VPS, from Windows.

.DESCRIPTION
  MINTER runs on a headless server; its browser desktop (noVNC) listens on the
  server's loopback only, so it cannot be reached from the Internet. This script
  builds an SSH tunnel — a local port on this laptop that forwards into the
  already-authenticated SSH connection — and opens the browser at it.

  First run asks for the server address and sets up a key so you never type a
  password again. Later runs are a double-click.

  No administrator rights. Nothing is exposed to the network: the forwarded port
  is bound to 127.0.0.1 on this machine only.

.PARAMETER Reset
  Close the connector tunnel, forget the saved server settings and exit.

.PARAMETER Stop
  Close the tunnel and exit.

.EXAMPLE
  .\connect.ps1
#>
[CmdletBinding()]
param(
    [switch]$Reset,
    [switch]$Stop
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Port       = 3021
$ConfigDir  = Join-Path $env:APPDATA 'minter'
$ConfigPath = Join-Path $ConfigDir 'connect.json'
$KeyPath    = Join-Path $env:USERPROFILE '.ssh\minter_vps_ed25519'
$Url        = "http://127.0.0.1:$Port/vnc.html?autoconnect=1&resize=scale"
$ForwardSpec = "127.0.0.1:${Port}:127.0.0.1:${Port}"

function Write-Step { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "  [ok] $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "  [!] $Text" -ForegroundColor Yellow }

function Get-SshExe {
    $builtin = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
    if (Test-Path -LiteralPath $builtin -PathType Leaf) { return $builtin }
    $cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw @'
No SSH client found.

Windows 10/11 ship one, but it can be switched off. Turn it on with:
  Settings -> System -> Optional features -> Add -> "OpenSSH Client"
'@
}

function Get-KeygenExe {
    $builtin = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
    if (Test-Path -LiteralPath $builtin -PathType Leaf) { return $builtin }
    $cmd = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'ssh-keygen.exe not found (install the OpenSSH Client optional feature).'
}

function Assert-ValidServerHost {
    param([string]$ServerHost)

    if ([string]::IsNullOrWhiteSpace($ServerHost)) {
        throw 'Server address is required.'
    }
    if ($ServerHost.Length -gt 253 -or $ServerHost -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw 'Server address must be an IPv4 address or DNS hostname, not an SSH option.'
    }
}

function Assert-ValidSshUser {
    param([string]$User)

    if ([string]::IsNullOrWhiteSpace($User)) { throw 'SSH user is required.' }
    if ($User.Length -gt 64 -or $User -notmatch '^[A-Za-z_][A-Za-z0-9._-]*$') {
        throw 'SSH user contains unsupported characters.'
    }
}

function ConvertTo-ValidatedConfig {
    param([object]$Config)

    if ($null -eq $Config) { throw 'Saved settings are empty.' }
    $hostProperty = $Config.PSObject.Properties['host']
    $userProperty = $Config.PSObject.Properties['user']
    if ($null -eq $hostProperty -or $hostProperty.Value -isnot [string]) {
        throw 'Saved server address is missing or has the wrong type.'
    }
    if ($null -eq $userProperty -or $userProperty.Value -isnot [string]) {
        throw 'Saved SSH user is missing or has the wrong type.'
    }

    $serverHost = $hostProperty.Value.Trim()
    $user = $userProperty.Value.Trim()
    Assert-ValidServerHost -ServerHost $serverHost
    Assert-ValidSshUser -User $user

    # Older connector versions wrote the fixed noVNC port into the config but
    # never actually read it. Accept only the historical value, then omit it on
    # the next successful save so the fixed-port semantics are unambiguous.
    $portProperty = $Config.PSObject.Properties['port']
    if ($null -ne $portProperty) {
        $legacyPort = $portProperty.Value
        if (-not (($legacyPort -is [int]) -or ($legacyPort -is [long])) -or
            [long]$legacyPort -ne $Port) {
            throw "Saved port is invalid. MINTER Connect uses the fixed noVNC port $Port."
        }
    }

    return [pscustomobject]@{ host = $serverHost; user = $user }
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $null }
    try {
        $raw = Get-Content -Raw -LiteralPath $ConfigPath
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Saved settings file is empty.' }
        $parsed = $raw | ConvertFrom-Json
        return (ConvertTo-ValidatedConfig -Config $parsed)
    } catch {
        Write-Warn 'Saved settings are invalid and will not be used.'
        Write-Host "      $($_.Exception.Message)" -ForegroundColor DarkGray
        Write-Host '      Enter the server details again, or run reset.cmd later.' -ForegroundColor DarkGray
        return $null
    }
}

function Save-Config {
    param([string]$ServerHost, [string]$User)

    Assert-ValidServerHost -ServerHost $ServerHost
    Assert-ValidSshUser -User $User
    if (-not (Test-Path -LiteralPath $ConfigDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    }
    [pscustomobject]@{ host = $ServerHost; user = $User } |
        ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding utf8
}

function Request-Config {
    Write-Host ''
    Write-Host 'First run — where does MINTER live?' -ForegroundColor White
    Write-Host 'The installer printed both values at the end.' -ForegroundColor DarkGray
    Write-Host ''

    while ($true) {
        $serverHost = (Read-Host '  Server address (IP or hostname)').Trim()
        try {
            Assert-ValidServerHost -ServerHost $serverHost
            break
        } catch {
            Write-Warn $_.Exception.Message
        }
    }

    while ($true) {
        $user = (Read-Host '  SSH user [root]').Trim()
        if (-not $user) { $user = 'root' }
        try {
            Assert-ValidSshUser -User $user
            break
        } catch {
            Write-Warn $_.Exception.Message
        }
    }

    return [pscustomobject]@{ host = $serverHost; user = $user }
}

# Start-Process joins ArgumentList values into a single Windows command line.
# Quote each value with the standard CommandLineToArgvW rules so profile paths
# containing spaces or Unicode remain one ssh.exe argument.
function ConvertTo-ProcessArgument {
    param([AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object System.Text.StringBuilder
    $null = $builder.Append([char]34)
    $slashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $slashCount++
            continue
        }
        if ($character -eq [char]34) {
            if ($slashCount -gt 0) { $null = $builder.Append([char]92, $slashCount * 2) }
            $null = $builder.Append([char]92)
            $null = $builder.Append([char]34)
            $slashCount = 0
            continue
        }
        if ($slashCount -gt 0) { $null = $builder.Append([char]92, $slashCount) }
        $null = $builder.Append($character)
        $slashCount = 0
    }
    if ($slashCount -gt 0) { $null = $builder.Append([char]92, $slashCount * 2) }
    $null = $builder.Append([char]34)
    return $builder.ToString()
}

function Test-TextContains {
    param([string]$Text, [string]$Expected)

    return $Text.IndexOf($Expected, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-ConnectorProcess {
    param([object]$Process, [string]$Target)

    $commandLine = [string]$Process.CommandLine
    if (-not $commandLine) { return $false }
    $required = @(
        $ForwardSpec,
        $KeyPath,
        'BatchMode=yes',
        'ExitOnForwardFailure=yes',
        'ServerAliveInterval=20',
        'ServerAliveCountMax=3'
    )
    foreach ($value in $required) {
        if (-not (Test-TextContains -Text $commandLine -Expected $value)) { return $false }
    }
    if ($Target -and -not (Test-TextContains -Text $commandLine -Expected $Target)) {
        return $false
    }
    return $true
}

function Get-ConnectorTunnelProcesses {
    param([string]$Target)

    Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { Test-ConnectorProcess -Process $_ -Target $Target }
}

function Get-PortListeners {
    @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Test-ProcessOwnsTunnelListener {
    param([int]$ProcessId)

    $listeners = @(Get-PortListeners |
        Where-Object { $_.OwningProcess -eq $ProcessId -and $_.LocalAddress -eq '127.0.0.1' })
    return $listeners.Count -gt 0
}

function Get-ReusableTunnelProcess {
    param([string]$Target)

    $connectorProcesses = @(Get-ConnectorTunnelProcesses)
    $matchingProcesses = @($connectorProcesses |
        Where-Object { Test-ConnectorProcess -Process $_ -Target $Target })
    $activeMatches = @($matchingProcesses |
        Where-Object { Test-ProcessOwnsTunnelListener -ProcessId $_.ProcessId })
    if ($activeMatches.Count -gt 0) { return $activeMatches[0] }

    if ($connectorProcesses.Count -gt 0) {
        throw @"
A MINTER Connect SSH process exists but does not own the expected tunnel for
these server settings. Run stop.cmd, then try connect.cmd again.
"@
    }

    $listeners = @(Get-PortListeners)
    if ($listeners.Count -gt 0) {
        $owners = ($listeners | Select-Object -ExpandProperty OwningProcess -Unique) -join ', '
        throw @"
Local port $Port is already used by another process (PID: $owners).
MINTER Connect did not stop or reuse that process. Close the application using
the port, then try connect.cmd again.
"@
    }
    return $null
}

function Stop-Tunnel {
    $processes = @(Get-ConnectorTunnelProcesses)
    if (-not $processes.Count) {
        Write-Host 'No MINTER Connect tunnel is running.'
        return
    }

    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 250
    $remaining = @(Get-ConnectorTunnelProcesses)
    if ($remaining.Count -gt 0) { throw 'Could not stop the MINTER Connect SSH tunnel.' }
    Write-Ok "Tunnel closed ($($processes.Count) process(es))."
}

function Assert-ConnectorPublicKey {
    param([string]$PublicKey)

    $parts = @($PublicKey.Trim() -split '\s+')
    if ($parts.Count -ne 3 -or $parts[0] -ne 'ssh-ed25519' -or $parts[2] -ne 'minter-connect') {
        throw 'The connector public key is not a single expected ssh-ed25519 key.'
    }
    try {
        $decoded = [Convert]::FromBase64String($parts[1])
    } catch {
        throw 'The connector public key contains invalid base64 data.'
    }
    if ($decoded.Length -ne 51) { throw 'The connector public key has an invalid Ed25519 payload.' }
    return "$($parts[0]) $($parts[1]) $($parts[2])"
}

function Get-DerivedConnectorPublicKey {
    param([string]$Keygen)

    $derivedOutput = @(& $Keygen -y -f $KeyPath 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $derivedOutput.Count) {
        throw @"
The existing MINTER Connect private key is invalid or cannot be read. It was not
deleted. Move or repair the key manually, then run connect.cmd again.
"@
    }
    return (Assert-ConnectorPublicKey `
        -PublicKey "$(($derivedOutput -join '').Trim()) minter-connect")
}

function Ensure-ConnectorKeyPair {
    param([string]$Keygen)

    $publicPath = "$KeyPath.pub"
    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
        Write-Step 'Creating an SSH key'
        $sshDir = Split-Path -Parent $KeyPath
        if (-not (Test-Path -LiteralPath $sshDir -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
        }
        $keygenArgs = @('-q', '-t', 'ed25519', '-f', $KeyPath, '-N', '', '-C', 'minter-connect')
        $keygenArguments = ($keygenArgs |
            ForEach-Object { ConvertTo-ProcessArgument -Value $_ }) -join ' '
        $keygenProcess = Start-Process -FilePath $Keygen -ArgumentList $keygenArguments `
            -NoNewWindow -Wait -PassThru
        if ($keygenProcess.ExitCode -ne 0 -or
            -not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
            throw 'ssh-keygen could not create the MINTER Connect key pair.'
        }
        Write-Ok 'SSH key created locally'
    }

    $derived = Get-DerivedConnectorPublicKey -Keygen $Keygen
    if (-not (Test-Path -LiteralPath $publicPath -PathType Leaf)) {
        $derived | Set-Content -LiteralPath $publicPath -Encoding ascii
        Write-Ok 'missing public key restored from the private key'
        return $derived
    }

    $saved = Assert-ConnectorPublicKey -PublicKey (Get-Content -Raw -LiteralPath $publicPath)
    if (($saved -split '\s+')[1] -ne ($derived -split '\s+')[1]) {
        throw 'The connector public key does not match the existing private key.'
    }
    return $saved
}

# Push only the validated public half to the server. The password prompt belongs
# to ssh.exe; this script never receives or stores the VPS password.
function Initialize-SshKey {
    param(
        [string]$ServerHost,
        [string]$User,
        [string]$Ssh,
        [string]$PublicKey
    )

    & $Ssh -i $KeyPath -o BatchMode=yes -o ConnectTimeout=10 `
        -o StrictHostKeyChecking=accept-new "$User@$ServerHost" 'true' 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'key already accepted by the server'
        return
    }

    Write-Step 'Installing the key on the server'
    Write-Host '  You will be asked for the server password ONCE.' -ForegroundColor DarkGray
    Write-Host '  After this the connection is passwordless.' -ForegroundColor DarkGray
    Write-Host ''

    # PublicKey is restricted above to one Ed25519 line with a fixed comment, so
    # it cannot inject shell syntax into this remote command.
    $remote = "install -d -m 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && (grep -qxF '$PublicKey' ~/.ssh/authorized_keys || printf '%s\n' '$PublicKey' >> ~/.ssh/authorized_keys)"
    & $Ssh -o StrictHostKeyChecking=accept-new "$User@$ServerHost" $remote
    if ($LASTEXITCODE -ne 0) { throw "Could not install the public key (ssh exit $LASTEXITCODE)." }

    & $Ssh -i $KeyPath -o BatchMode=yes -o ConnectTimeout=10 "$User@$ServerHost" 'true' 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'The public key was copied, but the server still refuses it.' }
    Write-Ok 'key installed — no more passwords'
}

function Start-Tunnel {
    param([string]$ServerHost, [string]$User, [string]$Ssh)

    Write-Step 'Opening the tunnel'
    $sshArgs = @(
        '-N', '-T',
        '-i', $KeyPath,
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10',
        '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ServerAliveInterval=20',
        '-o', 'ServerAliveCountMax=3',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-L', $ForwardSpec,
        "$User@$ServerHost"
    )
    $processArguments = ($sshArgs |
        ForEach-Object { ConvertTo-ProcessArgument -Value $_ }) -join ' '
    $process = Start-Process -FilePath $Ssh -ArgumentList $processArguments `
        -WindowStyle Hidden -PassThru

    foreach ($i in 1..20) {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) { break }
        if (Test-ProcessOwnsTunnelListener -ProcessId $process.Id) {
            Write-Ok "listening on 127.0.0.1:$Port"
            return $process
        }
    }

    $exitedEarly = $process.HasExited
    if (-not $exitedEarly) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }

    # Neither firewall can be at fault here: the listener is on loopback, which
    # Windows does not filter, and the outbound SSH connection already
    # succeeded. By far the most common real cause is a hardened server with
    # port forwarding switched off, which otherwise fails silently.
    $forwarding = & $Ssh -i $KeyPath -o BatchMode=yes -o ConnectTimeout=10 `
        "$User@$ServerHost" 'sshd -T 2>/dev/null | grep -i allowtcpforwarding || echo unknown' 2>$null
    if ($forwarding -match 'allowtcpforwarding\s+no') {
        throw @"
The server refuses port forwarding.

Its sshd has 'AllowTcpForwarding no', so the tunnel cannot be built. Fix it on
the server:

  sudo sed -i 's/^AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config
  sudo systemctl reload ssh

then run this script again.
"@
    }

    if ($exitedEarly) {
        throw 'The SSH tunnel process exited before it could bind the local port.'
    }

    throw @"
The tunnel did not come up.

The SSH connection worked, so this is most likely the service being down.
Check the VPS service:
  systemctl status minter-vps
"@
}

function Test-NoVnc {
    Write-Step 'Checking the GUI responds'
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 10
        if ($response.StatusCode -ne 200) {
            throw "noVNC returned HTTP $($response.StatusCode)."
        }
    } catch {
        throw @"
The SSH tunnel is open, but MINTER noVNC did not answer.
Technical detail: $($_.Exception.Message)

Check the VPS service with:
  systemctl status minter-vps
"@
    }
    Write-Ok 'noVNC is up'
}

# ── main ─────────────────────────────────────────────────────────────────────

function Invoke-MinterConnect {
    if ($Stop) {
        Stop-Tunnel
        return
    }

    if ($Reset) {
        Stop-Tunnel
        if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
            Remove-Item -Force -LiteralPath $ConfigPath
            Write-Ok 'saved settings cleared'
        } else {
            Write-Host 'Saved settings are already clear.'
        }
        Write-Host 'Run connect.cmd to enter a server again.' -ForegroundColor DarkGray
        return
    }

    Write-Host ''
    Write-Host '  MINTER connect' -ForegroundColor White
    Write-Host '  ──────────────' -ForegroundColor DarkGray

    $ssh = Get-SshExe
    $config = Read-Config
    if (-not $config) { $config = Request-Config }
    $serverHost = [string]$config.host
    $user = [string]$config.user
    $target = "$user@$serverHost"

    Write-Host ''
    Write-Host "  server: $target" -ForegroundColor DarkGray
    Write-Host ''

    $tunnelProcess = Get-ReusableTunnelProcess -Target $target
    $startedHere = $false
    if ($tunnelProcess) {
        Write-Ok 'connector tunnel already open — reusing it'
    } else {
        $keygen = Get-KeygenExe
        $publicKey = Ensure-ConnectorKeyPair -Keygen $keygen
        Initialize-SshKey -ServerHost $serverHost -User $user -Ssh $ssh `
            -PublicKey $publicKey
        $tunnelProcess = Start-Tunnel -ServerHost $serverHost -User $user -Ssh $ssh
        $startedHere = $true
    }

    try {
        Test-NoVnc
    } catch {
        if ($startedHere -and $tunnelProcess) {
            Stop-Process -Id $tunnelProcess.Id -Force -ErrorAction SilentlyContinue
        }
        throw
    }

    # Persist only settings that completed key setup, forwarding and noVNC.
    Save-Config -ServerHost $serverHost -User $user
    Start-Process $Url | Out-Null
    Write-Host ''
    Write-Host '  Browser opened. Leave this tunnel running while you work.' -ForegroundColor Green
    Write-Host '  Close it with stop.cmd.' -ForegroundColor DarkGray
    Write-Host ''
}

try {
    Invoke-MinterConnect
} catch {
    Write-Host ''
    Write-Host 'MINTER Connect failed.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'Reason:' -ForegroundColor White
    Write-Host "  $($_.Exception.Message.Trim())" -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Check:' -ForegroundColor White
    Write-Host '  - the VPS is running and the address is correct'
    Write-Host '  - SSH is reachable and the username is correct'
    Write-Host "  - local port $Port is free, or run stop.cmd first"
    Write-Host '  - MINTER is running: systemctl status minter-vps'
    Write-Host ''
    exit 1
}
