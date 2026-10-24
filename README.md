# LiwaLink

A self-hosted replacement for ngrok. It lets your remote apps reach each restaurant's local system through your own server.

```
Remote app ──HTTPS──► Relay server (yours)  ◄══ tunnel (TLS, outbound) ══  Agent on restaurant PC ──► local API
                      rest-1234.link.example.com                            (Windows service)          127.0.0.1:5000
```

Each restaurant machine runs a small **agent** ([frpc](https://github.com/fatedier/frp)). The agent dials *out* to your **relay**, so the restaurant needs no open ports, no fixed IP and no router setup. Apps then use a permanent URL per restaurant: `https://<restaurant-id>.link.example.com`.

## What's here

| Path | What it is |
|---|---|
| `relay/install-relay.sh` | One-shot installer for the relay server (Ubuntu/Debian) |
| `relay/frps.toml` | Tunnel server config (frps) |
| `relay/Caddyfile` | Public HTTPS: per-restaurant certificates, forwards to frps |
| `relay/liwalink-auth.py` | Per-restaurant tokens, the rules for what an agent may publish, and the admin CLI |
| `relay/gen-relay-cert.sh` | Creates the private CA that agents use to verify the relay |
| `relay/systemd/` | Services: `liwalink-relay` (frps) and `liwalink-auth` |
| `agent/frpc.toml.template` | Agent config. Both installers fill it in. |
| `agent/install-agent.ps1` | Installs the agent as a Windows service ("LiwaLink Agent") |
| `agent/install-agent.sh` | Same, as a systemd service, for Linux restaurant machines |
| `test/e2e-local.sh` | End-to-end test of the whole chain on one machine |

## 1. Set up the relay (once)

You need an Ubuntu 22.04/24.04 (or Debian 12) server with a public IP, and a domain you control. These examples use `link.example.com`.

1. **DNS first.** Create two A records pointing at the server: `link.example.com` and `*.link.example.com`.
2. **Firewall.** Allow inbound TCP 80, 443 and 7000 in your cloud provider's firewall. The script opens them in `ufw` if `ufw` is active.
3. Copy the `relay/` folder to the server and run:

   ```bash
   sudo ./install-relay.sh --domain link.example.com --email ops@example.com
   ```

The script installs frps, Caddy and the auth service, creates the tunnel CA, and starts everything. Re-running it upgrades in place and keeps the CA, the dashboard password and the restaurants.

## 2. Add a restaurant

```bash
sudo liwalink-admin add rest-1234 --name "Pizza Place"
```

This prints the restaurant's URL, its token (shown once) and the exact command for installing the agent. Other commands:

```bash
sudo liwalink-admin list
sudo liwalink-admin rotate rest-1234   # new token, e.g. if a machine is replaced
sudo liwalink-admin remove rest-1234   # revoke (customer leaves, stops paying...)
```

Restaurant IDs become subdomains, so use lowercase letters, digits and dashes.

## 3. Install the agent at the restaurant

Copy the `agent/` folder to the restaurant machine. `install-agent.*` and `frpc.toml.template` must stay together.

**Windows** (PowerShell as Administrator):

```powershell
powershell -ExecutionPolicy Bypass -File .\install-agent.ps1 -RestaurantId rest-1234 -Token <token> -Server link.example.com -LocalPort 5000
```

**Linux:**

```bash
sudo ./install-agent.sh --id rest-1234 --token <token> --server link.example.com --local-port 5000
```

`-LocalPort` / `--local-port` is the port your restaurant API listens on. If the API runs on another machine in the restaurant's LAN, also pass `-LocalHost` / `--local-host`.

The installer downloads frpc (checksum verified) and gets the relay's CA from `https://link.example.com/ca.crt`. It then registers a service that starts with the machine and restarts on failure, and waits until the tunnel is up. Running it again upgrades in place. Uninstall with `-Uninstall` / `--uninstall`.

Agent logs:
- Windows: `C:\ProgramData\LiwaLink\logs\LiwaLinkAgent.out.log`
- Linux: `journalctl -u liwalink-agent`

## 4. Point your apps at it

Replace the ngrok URL in your apps with `https://rest-1234.link.example.com`. Requests go to the restaurant's API unchanged, with the path, headers and body intact. WebSockets work too.

## Security model

- **Each restaurant has its own token.** frps asks `liwalink-auth` before every login, so a leaked token affects one restaurant and can be revoked on its own.
- **A restaurant can only publish its own subdomain, and only over HTTP.** An agent can't take another restaurant's URL, and it can't open a raw TCP port. That rules out exposing a database port, even by accident. Put only the API behind the tunnel, and keep the API's own authentication.
- **Agents verify the relay.** The tunnel uses TLS, and the certificate is signed by a private CA created on your relay. Without this, frpc would accept any server's certificate, and a fake relay could collect tokens.
- **Certificates are issued only for real restaurants.** Caddy gets a Let's Encrypt certificate the first time a restaurant's URL is used, and only after `liwalink-auth` confirms the restaurant exists.
- **Admin surfaces stay local.** The frps dashboard and the auth service listen on `127.0.0.1` only. To open the dashboard, run `ssh -L 7500:127.0.0.1:7500 <relay>`, then browse to `http://127.0.0.1:7500`. The user is `admin`, and the password is in `/etc/liwalink/dashboard-password`.

## Operating it

- **Status:** `systemctl status liwalink-relay liwalink-auth caddy`
- **Login and proxy decisions:** `journalctl -u liwalink-auth -f`
- **Revoking:** `remove` stops new logins right away. An agent that is already connected stays up until it reconnects. Run `sudo systemctl restart liwalink-relay` to drop all agents at once; legitimate ones reconnect within seconds.
- **Upgrading frp:** update `FRP_VERSION` in the installers. Upgrade the relay first, then the agents. frp guarantees compatibility across nine minor versions.

## Testing locally

```bash
./test/e2e-local.sh                      # downloads frp, needs python3, openssl, curl
CADDY=/path/to/caddy ./test/e2e-local.sh # also tests the HTTPS layer
```

The test starts the auth service, frps, a fake restaurant API and several agents, using the real config templates. It checks that:
- A valid agent is reachable.
- A wrong token, a stolen subdomain, a TCP port and a fake relay are all refused.
- Certificates are issued only for registered restaurants.

## Known limitations / next steps

- **Windows Defender may flag `frpc.exe`** as a "HackTool", because frp is also used by attackers. If Defender quarantines it, the install fails or the service won't start. The proper fix is to build frpc from source and sign it with your company's code-signing certificate. You can also submit the file to Microsoft as a false positive.
- **Port 7000 outbound.** Some locked-down networks only allow 443. If that becomes a problem, frp can tunnel over WebSocket/TLS on 443 through Caddy (`transport.protocol = "wss"`).
- **Let's Encrypt rate limits.** New certificates are limited per domain (currently 50 a week). For a large rollout, switch to a single wildcard certificate (`*.link.example.com`). That needs Caddy's DNS-challenge plugin for your DNS provider.
- **One relay is a single point of failure.** Add monitoring, for example on `https://link.example.com/`. A second relay can come later.
- **The registry is a JSON file** at `/var/lib/liwalink/restaurants.json`. `liwalink-auth.py` is small, so it's easy to point at your own customer database instead.
- **Packaging.** For production, wrap the Windows agent in your existing installer, or an MSI, rather than a PowerShell script.
