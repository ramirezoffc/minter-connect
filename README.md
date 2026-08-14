# minter-connect

Opens the [MINTER](https://github.com/MaxBetov-pdd/Minter-rs-v2) GUI running on
your VPS, from a Windows machine. One script, no administrator rights, nothing
to install.

## Why a connector at all

MINTER runs on the server, not on your laptop — that is the point of putting it
on a VPS: low latency to the chain and it keeps minting while your laptop
sleeps. Its interface is a browser desktop (noVNC) that the server binds to
**localhost only**.

That is deliberate. The noVNC layer is guarded by a classic VNC password, and
classic VNC auth uses only the **first 8 characters**. That is not something to
put in front of a wallet GUI on the open Internet.

So the GUI is reached through an SSH tunnel: a port on your laptop that
forwards into an already-authenticated SSH connection.

```
  your laptop                                 your VPS
  ───────────                                 ────────
  browser
     │
     ▼
  127.0.0.1:3021 ──┐
                   │  ssh -L  (encrypted)
                   └──────────────────────► 127.0.0.1:3021
                                                 │
                                            noVNC → MINTER
```

`127.0.0.1` on the left is your laptop. `127.0.0.1` on the right is the server,
reached because SSH is already connected there. Nothing is exposed publicly at
either end.

## Use it

1. Install MINTER on the server first — it prints the address and user you need:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/MaxBetov-pdd/Minter-rs-v2/main/deploy/linux/install.sh | sudo bash
   ```

2. Download this repository (green **Code** button → *Download ZIP*), unzip it.

3. Right-click `connect.ps1` → **Run with PowerShell**.

If Windows blocks the script, open PowerShell in that folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\connect.ps1
```

### First run

```
  Server address (IP or hostname): 203.0.113.45
  SSH user [root]: minter

==> Creating an SSH key
  [ok] key created
==> Installing the key on the server
  You will be asked for the server password ONCE.
  minter@203.0.113.45's password: ********
  [ok] key installed — no more passwords
==> Opening the tunnel
  [ok] listening on 127.0.0.1:3021
  [ok] noVNC is up

  Browser opened. Leave this tunnel running while you work.
```

### Every run after that

Double-click. The browser opens in about two seconds. Nothing to type.

## Options

| Command | What it does |
|---|---|
| `.\connect.ps1` | connect (reuses the tunnel if it is already open) |
| `.\connect.ps1 -Stop` | close the tunnel |
| `.\connect.ps1 -Reset` | forget the saved server and ask again |

Settings live in `%APPDATA%\minter\connect.json`. The SSH key is
`%USERPROFILE%\.ssh\minter_vps_ed25519` — it is generated locally and never
leaves your machine except for its public half.

## Requirements

Windows 10 or 11. The built-in OpenSSH client is used; if it has been removed,
turn it back on under *Settings → System → Optional features → Add →
OpenSSH Client*.

## Troubleshooting

**"No SSH client found"** — install the OpenSSH Client optional feature above.

**Asks for a password every time** — the key was not accepted. Run
`.\connect.ps1 -Reset` and check that the user you enter is the one that owns
`~/.ssh/authorized_keys` on the server.

**Tunnel opens but the page does not load** — the service may be down. Check it:

```powershell
ssh -i $env:USERPROFILE\.ssh\minter_vps_ed25519 USER@SERVER "systemctl status minter-vps"
```

**Black screen in noVNC** — the virtual display died. Restart the service, but
only when no mint is running:

```powershell
ssh USER@SERVER "sudo systemctl restart minter-vps"
```

A restart clears the unlocked vault from memory, so you will have to enter the
vault password again.

## Security

- The forwarded port binds to `127.0.0.1` on your laptop — other devices on
  your network cannot reach it.
- The SSH key is created without a passphrase so the script can run unattended.
  Anyone with access to your Windows user account can therefore reach the
  server; treat the laptop accordingly.
- Never publish port 3021 through a reverse proxy without real authentication
  in front of it.

## Will a firewall block this?

No, and nothing needs opening on either side.

**On the server** the only port reachable from the Internet is **22** — and it
already is, otherwise you could not have installed anything. noVNC listens on
`127.0.0.1:3021`, which no firewall filters because the traffic never leaves
the machine.

**On Windows** the forwarded port is bound to `127.0.0.1` too. Windows does not
apply firewall rules to loopback traffic, so there is no prompt, no rule to add
and no administrator rights needed. The outbound SSH connection is allowed by
the default outbound policy.

The one real blocker is a hardened server with `AllowTcpForwarding no` in its
sshd config — rare, but it makes tunnels impossible. The script detects that
case and tells you the exact command to fix it.

## Licence

MIT OR Apache-2.0, matching the main project.

