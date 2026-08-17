# MINTER Connect

Connects a Windows computer to the [MINTER](https://github.com/ramirezoffc/minter-rr)
GUI running on a Linux VPS. The connection uses the OpenSSH client included with
Windows and opens MINTER through a private localhost tunnel.

## Quick Start

Install MINTER on the VPS first:

```bash
curl -fsSL https://raw.githubusercontent.com/ramirezoffc/minter-rr/main/deploy/linux/install.sh | sudo bash
```

Then on the Windows computer:

1. Download this repository with **Code → Download ZIP**.
2. Extract the complete ZIP to a normal folder.
3. Double-click `connect.cmd`.
4. Enter the VPS IP address or hostname.
5. Enter the SSH user printed by the VPS installer. Press Enter to use `root`.
6. On the first connection, enter the VPS password directly into `ssh.exe`.
7. Wait for the browser to open MINTER.

The first successful connection creates a local Ed25519 key and installs only
its public half on the VPS. The VPS password is not requested again.

## Later connections

Double-click `connect.cmd`. The saved server, SSH key and tunnel are reused, and
the browser opens after MINTER noVNC answers successfully.

Use the other launchers when needed:

| Launcher | Action |
|---|---|
| `connect.cmd` | Connect and open MINTER |
| `stop.cmd` | Close only the MINTER Connect SSH tunnel |
| `reset.cmd` | Close the tunnel and forget the saved server |

`reset.cmd` does not delete the SSH private key, remove the public key from the
VPS, or modify `known_hosts`. Run `connect.cmd` afterwards to enter a server
again.

## Requirements

- Windows 10 or Windows 11.
- The built-in Windows OpenSSH Client.
- A browser.
- SSH access to the VPS, normally on port 22.

No administrator rights or third-party Windows runtime is required. The CMD
launchers apply `ExecutionPolicy Bypass` only to their own PowerShell process;
they do not change the machine or user execution policy.

If OpenSSH Client is unavailable, open:

```text
Settings → System → Optional features → Add an optional feature
```

and install **OpenSSH Client**.

## Saved files

Server settings:

```text
%APPDATA%\minter\connect.json
```

The config stores only:

```text
host
user
```

The noVNC tunnel port is fixed at `3021`; it is not a configurable SSH port.

SSH key pair:

```text
%USERPROFILE%\.ssh\minter_vps_ed25519
%USERPROFILE%\.ssh\minter_vps_ed25519.pub
```

If the `.pub` file is missing, MINTER Connect restores it from the existing
private key. An invalid private key is never deleted automatically; the
connector stops with a recovery message instead.

## Troubleshooting

### OpenSSH Client unavailable

Install the Windows optional feature described above. Both `ssh.exe` and
`ssh-keygen.exe` are required.

### Connection timeout or wrong server

Check that:

- the VPS is running;
- its IP/hostname is correct;
- SSH port 22 is reachable;
- the SSH username is correct.

Run `reset.cmd` to clear a stale or incorrect saved host/user, then run
`connect.cmd` again.

### Local port 3021 is occupied

Run `stop.cmd` first. It stops only an SSH process matching the MINTER Connect
key and forwarding parameters. If the error remains, another application owns
port `3021`; close that application before connecting. The connector will not
kill an unrelated process.

### noVNC is unavailable

The browser is opened only after noVNC returns a successful HTTP response. On
the VPS, check:

```bash
systemctl status minter-vps
```

Restart only when no mint is running:

```bash
sudo systemctl restart minter-vps
```

A restart locks the vault again, so its password must be entered in MINTER.

### SSH key issue

If the private key exists but is invalid, MINTER Connect leaves it untouched.
Back it up or rename it manually before creating a replacement. A new key must
be installed with the VPS password again.

### Server refuses the tunnel

A hardened SSH server can set `AllowTcpForwarding no`. Enable TCP forwarding in
the server SSH policy and reload `sshd`, then retry.

## Security

- The VPS password is entered directly into `ssh.exe`. MINTER Connect does not
  read, save or log it.
- The private SSH key remains on the Windows computer. Only the validated public
  Ed25519 key is sent to `authorized_keys` on the VPS.
- The key has no passphrase so later launches need no input. Anyone with access
  to the Windows user account may therefore be able to access the VPS.
- SSH uses `StrictHostKeyChecking=accept-new`. This is trust on first use (TOFU):
  the first unknown VPS host key is accepted automatically, while later host-key
  changes are rejected. Verify the VPS address before entering its password.
- noVNC remains bound to `127.0.0.1:3021` on the VPS and Windows computer. It is
  carried inside SSH and is not exposed publicly.
- Never publish port `3021` through a public firewall rule or reverse proxy.

## How the connection is routed

```text
Windows browser
    ↓
127.0.0.1:3021
    ↓ encrypted SSH tunnel
VPS 127.0.0.1:3021
    ↓
noVNC → MINTER
```

## Licence

MIT OR Apache-2.0, matching MINTER.
