#!/usr/bin/env bash
# Install the LiwaLink agent (frpc) as a systemd service on a Linux restaurant machine.
#
#   sudo ./install-agent.sh --id rest-1234 --token <token> --server link.example.com [--local-port 5000]
#   sudo ./install-agent.sh --uninstall
#
# Options:
#   --server-port N     relay tunnel port (default 7000)
#   --local-host H      where the restaurant API listens (default 127.0.0.1)
#   --local-port N      restaurant API port (default 5000)
#   --ca-cert FILE      relay CA certificate (default: download https://<server>/ca.crt)
# The token can also be passed as LIWALINK_TOKEN to keep it out of shell history.
set -euo pipefail

FRP_VERSION="0.71.1"
SERVICE=liwalink-agent
INSTALL_DIR=/opt/liwalink-agent
CONFIG_DIR=/etc/liwalink-agent

ID=""
TOKEN="${LIWALINK_TOKEN:-}"
SERVER=""
SERVER_PORT=7000
LOCAL_HOST=127.0.0.1
LOCAL_PORT=5000
CA_CERT=""
UNINSTALL=0

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) ID="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --server) SERVER="${2:-}"; shift 2 ;;
    --server-port) SERVER_PORT="${2:-}"; shift 2 ;;
    --local-host) LOCAL_HOST="${2:-}"; shift 2 ;;
    --local-port) LOCAL_PORT="${2:-}"; shift 2 ;;
    --ca-cert) CA_CERT="${2:-}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root (sudo)"

if [[ $UNINSTALL -eq 1 ]]; then
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE.service"
  systemctl daemon-reload
  rm -rf "$INSTALL_DIR" "$CONFIG_DIR"
  userdel "$SERVICE" 2>/dev/null || true
  echo "LiwaLink agent removed."
  exit 0
fi

# Everything below ends up in a config file, so only allow plain characters.
[[ "$ID" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "--id is required (lowercase letters, digits, dashes)"
[[ "$TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] || die "--token is required"
[[ "$SERVER" =~ ^[A-Za-z0-9.-]+$ ]] || die "--server is required, e.g. link.example.com"
[[ "$SERVER_PORT" =~ ^[0-9]+$ && "$LOCAL_PORT" =~ ^[0-9]+$ ]] || die "ports must be numbers"
[[ "$LOCAL_HOST" =~ ^[A-Za-z0-9.:-]+$ ]] || die "invalid --local-host"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$HERE/frpc.toml.template"
[[ -f "$TEMPLATE" ]] || die "frpc.toml.template must be next to this script"

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l|armv6l) ARCH=arm ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> Downloading frpc $FRP_VERSION ($ARCH)"
tarball="frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"
base="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}"
curl -fsSL -o "$tmp/$tarball" "$base/$tarball"
curl -fsSL -o "$tmp/sums.txt" "$base/frp_sha256_checksums.txt"
(cd "$tmp" && grep " ${tarball}\$" sums.txt | sha256sum -c --quiet -) || die "frp checksum mismatch"
tar -xzf "$tmp/$tarball" -C "$tmp"

echo "==> Installing"
systemctl stop "$SERVICE" 2>/dev/null || true
id "$SERVICE" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE"
install -d -m 0755 "$INSTALL_DIR"
install -d -m 0750 -o root -g "$SERVICE" "$CONFIG_DIR"
install -m 0755 "$tmp/frp_${FRP_VERSION}_linux_${ARCH}/frpc" "$INSTALL_DIR/frpc"

if [[ -n "$CA_CERT" ]]; then
  install -m 0644 "$CA_CERT" "$CONFIG_DIR/ca.crt"
else
  curl -fsSL -o "$tmp/ca.crt" "https://$SERVER/ca.crt" || die "could not download https://$SERVER/ca.crt (pass --ca-cert)"
  install -m 0644 "$tmp/ca.crt" "$CONFIG_DIR/ca.crt"
fi

sed -e "s|__SERVER__|$SERVER|g" \
    -e "s|__SERVER_PORT__|$SERVER_PORT|g" \
    -e "s|__RESTAURANT_ID__|$ID|g" \
    -e "s|__TOKEN__|$TOKEN|g" \
    -e "s|__CA_FILE__|$CONFIG_DIR/ca.crt|g" \
    -e "s|__LOCAL_HOST__|$LOCAL_HOST|g" \
    -e "s|__LOCAL_PORT__|$LOCAL_PORT|g" \
    "$TEMPLATE" > "$tmp/frpc.toml"
install -m 0640 -o root -g "$SERVICE" "$tmp/frpc.toml" "$CONFIG_DIR/frpc.toml"
"$INSTALL_DIR/frpc" verify -c "$CONFIG_DIR/frpc.toml" >/dev/null

cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=LiwaLink agent (tunnel to $SERVER)
After=network-online.target
Wants=network-online.target

[Service]
User=$SERVICE
Group=$SERVICE
ExecStart=$INSTALL_DIR/frpc -c $CONFIG_DIR/frpc.toml
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
since="$(date '+%Y-%m-%d %H:%M:%S')"
systemctl restart "$SERVICE"

echo "==> Waiting for the tunnel"
for _ in $(seq 1 15); do
  logs="$(journalctl -u "$SERVICE" --since "$since" --no-pager -o cat 2>/dev/null || true)"
  if grep -q "start proxy success" <<<"$logs"; then
    echo "Connected. Remote apps can now use https://$ID.$SERVER"
    exit 0
  fi
  sleep 1
done
echo "The service is installed but has not connected yet. Recent log:" >&2
journalctl -u "$SERVICE" --since "$since" --no-pager -o cat | tail -n 20 >&2
exit 1
