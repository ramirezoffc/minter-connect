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
  Forget the saved server settings and ask again.

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

# Is the tunnel already listening? Used to avoid stacking duplicates.
function Test-TunnelUp {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return [bool]$conn
}

function Get-TunnelProcesses {
    Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match "${Port}:127\.0\.0\.1:${Port}" }
}

function Stop-Tunnel {
    $procs = @(Get-TunnelProcesses)
    if (-not $procs.Count) { Write-Host 'No tunnel is running.'; return }
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Ok "Tunnel closed ($($procs.Count) process(es))."
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    try { return Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json } catch { return $null }
}

function Save-Config {
    param([string]$ServerHost, [string]$User)
    if (-not (Test-Path -LiteralPath $ConfigDir)) {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    }
    [pscustomobject]@{ host = $ServerHost; user = $User; port = $Port } |
        ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding utf8
}

function Request-Config {
    Write-Host ''
    Write-Host 'First run — where does MINTER live?' -ForegroundColor White
    Write-Host 'The installer printed both values at the end.' -ForegroundColor DarkGray
    Write-Host ''
    do {
        $h = (Read-Host '  Server address (IP or hostname)').Trim()
    } while (-not $h)
    $u = (Read-Host '  SSH user [root]').Trim()
    if (-not $u) { $u = 'root' }
    Save-Config -ServerHost $h -User $u
    return Read-Config
}

# Create a key once, then push the public half to the server. That single
# password prompt is the only one for the life of the machine.
function Initialize-SshKey {
    param([string]$ServerHost, [string]$User, [string]$Ssh)

    if (-not (Test-Path -LiteralPath $KeyPath)) {
        Write-Step 'Creating an SSH key'
        $sshDir = Split-Path -Parent $KeyPath
        if (-not (Test-Path -LiteralPath $sshDir)) {
            New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
        }
        & (Get-KeygenExe) -t ed25519 -f $KeyPath -N '""' -C "minter-connect" | Out-Null
        if (-not (Test-Path -LiteralPath $KeyPath)) { throw 'ssh-keygen did not produce a key.' }
        Write-Ok "key created: $KeyPath"
    }

    # Already trusted? Then there is nothing to install.
    & $Ssh -i $KeyPath -o BatchMode=yes -o ConnectTimeout=10 `
        -o StrictHostKeyChecking=accept-new "$User@$ServerHost" 'true' 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Ok 'key already accepted by the server'; return }

    Write-Step 'Installing the key on the server'
    Write-Host '  You will be asked for the server password ONCE.' -ForegroundColor DarkGray
    Write-Host '  After this the connection is passwordless.' -ForegroundColor DarkGray
    Write-Host ''

    $pub = (Get-Content -Raw "$KeyPath.pub").Trim()
    # Quoted heredoc-free one-liner: appends only if absent, fixes permissions.
    $remote = "install -d -m 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys"
    & $Ssh -o StrictHostKeyChecking=accept-new "$User@$ServerHost" $remote
    if ($LASTEXITCODE -ne 0) { throw "Could not install the key (ssh exit $LASTEXITCODE)." }

    & $Ssh -i $KeyPath -o BatchMode=yes -o ConnectTimeout=10 "$User@$ServerHost" 'true' 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Key was copied but the server still refuses it.' }
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
        '-L', "127.0.0.1:${Port}:127.0.0.1:${Port}",
        "$User@$ServerHost"
    )
    Start-Process -FilePath $Ssh -ArgumentList $sshArgs -WindowStyle Hidden | Out-Null

    foreach ($i in 1..20) {
        Start-Sleep -Milliseconds 500
        if (Test-TunnelUp) { Write-Ok "listening on 127.0.0.1:$Port"; return }
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

    throw @"
The tunnel did not come up.

The SSH connection worked, so this is most likely the service being down.
Check it:
  ssh -i "$KeyPath" $User@$ServerHost "systemctl status minter-vps"
"@
}

# ── main ─────────────────────────────────────────────────────────────────────

if ($Stop) { Stop-Tunnel; return }

Write-Host ''
Write-Host '  MINTER connect' -ForegroundColor White
Write-Host '  ──────────────' -ForegroundColor DarkGray

$ssh = Get-SshExe

if ($Reset -and (Test-Path -LiteralPath $ConfigPath)) {
    Remove-Item -Force -LiteralPath $ConfigPath
    Write-Ok 'saved settings cleared'
}

$cfg = Read-Config
if (-not $cfg) { $cfg = Request-Config }
$serverHost = [string]$cfg.host
$user       = [string]$cfg.user

Write-Host ''
Write-Host "  server: $user@$serverHost" -ForegroundColor DarkGray
Write-Host ''

if (Test-TunnelUp) {
    Write-Ok 'tunnel already open — reusing it'
} else {
    Initialize-SshKey -ServerHost $serverHost -User $user -Ssh $ssh
    Start-Tunnel      -ServerHost $serverHost -User $user -Ssh $ssh
}

Write-Step 'Checking the GUI responds'
try {
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 10
    if ($resp.StatusCode -ne 200) { throw "noVNC returned HTTP $($resp.StatusCode)" }
    Write-Ok 'noVNC is up'
} catch {
    Write-Warn "Tunnel is open but noVNC did not answer: $($_.Exception.Message)"
    Write-Warn "The service may still be starting. Check: ssh $user@$serverHost 'systemctl status minter-vps'"
}

Start-Process $Url
Write-Host ''
Write-Host '  Browser opened. Leave this tunnel running while you work.' -ForegroundColor Green
Write-Host "  Close it with:  .\connect.ps1 -Stop" -ForegroundColor DarkGray
Write-Host ''
