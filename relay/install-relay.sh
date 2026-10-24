#!/usr/bin/env bash
# Install the LiwaLink relay on an Ubuntu/Debian server:
#   frps (tunnel server) + liwalink-auth (per-restaurant tokens) + Caddy (public HTTPS)
#
#   sudo ./install-relay.sh --domain link.example.com --email ops@example.com
#
# Safe to re-run: it upgrades binaries and configs and keeps the CA, the
# dashboard password and the restaurant registry.
set -euo pipefail

FRP_VERSION="0.71.1"
DOMAIN=""
EMAIL=""

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root (sudo)"
[[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "--domain is required, e.g. link.example.com"
[[ "$EMAIL" =~ ^[^[:space:]|@]+@[^[:space:]|@]+$ ]] || die "--email is required (Let's Encrypt account contact)"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64|arm64) ;; *) die "unsupported architecture $ARCH" ;; esac

if ss -Hltnp 'sport = :443' | grep -qv caddy; then
  die "something other than Caddy already listens on port 443; the relay needs ports 80 and 443"
fi

echo "==> Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q curl ca-certificates openssl python3 gnupg debian-keyring debian-archive-keyring apt-transport-https
if ! command -v caddy >/dev/null; then
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    > /etc/apt/sources.list.d/caddy-stable.list
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q
  apt-get install -y -q caddy
fi

echo "==> Installing frps $FRP_VERSION"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tarball="frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"
base="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}"
curl -fsSL -o "$tmp/$tarball" "$base/$tarball"
curl -fsSL -o "$tmp/sums.txt" "$base/frp_sha256_checksums.txt"
(cd "$tmp" && grep " ${tarball}\$" sums.txt | sha256sum -c --quiet -) || die "frp checksum mismatch"
tar -xzf "$tmp/$tarball" -C "$tmp"
install -m 0755 "$tmp/frp_${FRP_VERSION}_linux_${ARCH}/frps" /usr/local/bin/frps

echo "==> Creating user and directories"
id liwalink >/dev/null 2>&1 || useradd --system --home-dir /var/lib/liwalink --shell /usr/sbin/nologin liwalink
install -d -m 0755 /etc/liwalink /etc/liwalink/public /opt/liwalink
install -d -m 0750 -o root -g liwalink /etc/liwalink/tls
install -d -m 0750 -o liwalink -g liwalink /var/lib/liwalink

echo "==> Tunnel TLS certificates"
"$HERE/gen-relay-cert.sh" "$DOMAIN" /etc/liwalink/tls
chmod 600 /etc/liwalink/tls/ca.key
chgrp liwalink /etc/liwalink/tls/relay.key && chmod 640 /etc/liwalink/tls/relay.key
install -m 0644 /etc/liwalink/tls/ca.crt /etc/liwalink/public/ca.crt

echo "==> Auth service and admin command"
install -m 0755 "$HERE/liwalink-auth.py" /opt/liwalink/liwalink-auth.py
cat > /etc/liwalink/relay.env <<EOF
LIWALINK_DOMAIN=$DOMAIN
LIWALINK_REGISTRY=/var/lib/liwalink/restaurants.json
EOF
cat > /usr/local/bin/liwalink-admin <<'EOF'
#!/bin/sh
# Manage restaurants on this relay, e.g.:  sudo liwalink-admin add rest-1234 --name "Pizza Place"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
. /etc/liwalink/relay.env
exec runuser -u liwalink -- /usr/bin/python3 /opt/liwalink/liwalink-auth.py \
  --registry "$LIWALINK_REGISTRY" --domain "$LIWALINK_DOMAIN" "$@"
EOF
chmod 0755 /usr/local/bin/liwalink-admin

echo "==> frps config"
pwfile=/etc/liwalink/dashboard-password
[[ -f "$pwfile" ]] || (umask 077; openssl rand -hex 16 > "$pwfile")
sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__CONFIG_DIR__|/etc/liwalink|g" \
  -e "s|__DASHBOARD_PASSWORD__|$(cat "$pwfile")|g" \
  "$HERE/frps.toml" > /etc/liwalink/frps.toml
chgrp liwalink /etc/liwalink/frps.toml && chmod 640 /etc/liwalink/frps.toml
runuser -u liwalink -- /usr/local/bin/frps verify -c /etc/liwalink/frps.toml

echo "==> Caddy config"
if [[ -f /etc/caddy/Caddyfile ]] && ! grep -q "LiwaLink relay" /etc/caddy/Caddyfile; then
  cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%Y%m%d%H%M%S)"
fi
sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__CONFIG_DIR__|/etc/liwalink|g" -e "s|__EMAIL__|$EMAIL|g" \
  "$HERE/Caddyfile" > /etc/caddy/Caddyfile
caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile >/dev/null

echo "==> Starting services"
install -m 0644 "$HERE/systemd/liwalink-auth.service" "$HERE/systemd/liwalink-relay.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable liwalink-auth.service liwalink-relay.service
systemctl restart liwalink-auth.service liwalink-relay.service
systemctl reload caddy || systemctl restart caddy

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  echo "==> Opening firewall ports 80, 443, 7000"
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow 7000/tcp >/dev/null
fi

cat <<EOF

LiwaLink relay is installed.

1. DNS: point both of these A records at this server's public IP:
     $DOMAIN
     *.$DOMAIN
   Also open TCP 80, 443 and 7000 in your cloud provider's firewall, if it has one.

2. Add a restaurant (prints its token and the agent install command):
     sudo liwalink-admin add rest-1234 --name "Pizza Place"

3. Check it:
     systemctl status liwalink-relay liwalink-auth caddy
     journalctl -u liwalink-auth -f      # login and proxy decisions
   Dashboard: ssh -L 7500:127.0.0.1:7500 <this-server>, then http://127.0.0.1:7500
   (user admin, password in $pwfile)
EOF
