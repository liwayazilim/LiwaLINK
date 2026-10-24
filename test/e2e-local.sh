#!/usr/bin/env bash
# End-to-end test of the relay and agent on one machine (macOS or Linux, no root).
#
#   ./test/e2e-local.sh
#
# Starts liwalink-auth, frps, a fake restaurant API and several agents, all from
# the real config templates (with test ports), then checks what gets through.
#
#   FRP_DIR=/path/with/frps-and-frpc   skip the frp download
#   CADDY=/path/to/caddy               also test the public HTTPS layer
#   E2E_KEEP_LOGS=1                    keep the logs even when everything passes
#   RELAY_CERT_CMD="pwsh -NoProfile -File relay/gen-relay-cert.ps1"
#                                      test the Windows certificate generator instead
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRP_VERSION=0.71.1
DOMAIN=link.test
AUTH_PORT=19000 FRPS_PORT=17000 VHOST_PORT=18080 DASH_PORT=17500 API_PORT=15000
CADDY_HTTP_PORT=18081 CADDY_HTTPS_PORT=18443

W="$(mktemp -d)"
PIDS=()
FAILED=0
KEEP_LOGS=1
cleanup() {
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  if [[ $KEEP_LOGS -eq 1 ]]; then echo "Logs kept in $W"; else rm -rf "$W"; fi
}
trap cleanup EXIT

pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; FAILED=1; }

# start <name> <command...>: run in the background, output to $W/<name>.log
start() {
  local name=$1; shift
  "$@" >"$W/$name.log" 2>&1 &
  LAST_PID=$!
  PIDS+=("$LAST_PID")
}

stop_last() { kill "$LAST_PID" 2>/dev/null || true; wait "$LAST_PID" 2>/dev/null || true; }

# wait_for <file> <text> [seconds]
wait_for() {
  local i
  for ((i = 0; i < ${3:-10} * 10; i++)); do
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

expect_log() {  # expect_log <description> <name> <text>
  if wait_for "$W/$2.log" "$3"; then pass "$1"; else fail "$1"; tail -n 15 "$W/$2.log" | sed 's/^/        | /'; fi
}

expect_eq() {  # expect_eq <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# render <template> <output> <find> <replace> [<find> <replace>...]
# Literal replacements, applied in order; fails if a <find> is missing so the
# test notices when the templates change.
render() {
  python3 - "$@" <<'EOF'
import sys
src, dst, *pairs = sys.argv[1:]
text = open(src).read()
for find, replace in zip(pairs[::2], pairs[1::2]):
    if find not in text:
        sys.exit(f"render: {find!r} not found in {src}")
    text = text.replace(find, replace)
open(dst, "w").write(text)
EOF
}

auth() { python3 "$ROOT/relay/liwalink-auth.py" --registry "$W/restaurants.json" --domain "$DOMAIN" "$@"; }

# --- frp binaries ---------------------------------------------------------------
if [[ -z "${FRP_DIR:-}" ]]; then
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) arch="$(uname -m)" ;; esac
  name="frp_${FRP_VERSION}_${os}_${arch}"
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/liwalink-e2e"
  if [[ ! -x "$cache/$name/frps" ]]; then
    echo "Downloading $name"
    mkdir -p "$cache"
    base="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}"
    curl -fsSL -o "$cache/$name.tar.gz" "$base/$name.tar.gz"
    curl -fsSL -o "$cache/sums.txt" "$base/frp_sha256_checksums.txt"
    (cd "$cache" && grep " $name.tar.gz\$" sums.txt | shasum -a 256 -c --quiet -)
    tar -xzf "$cache/$name.tar.gz" -C "$cache"
  fi
  FRP_DIR="$cache/$name"
fi

echo "Setting up in $W"

# --- relay ----------------------------------------------------------------------
if [[ -n "${RELAY_CERT_CMD:-}" ]]; then
  read -r -a gen_cert <<<"$RELAY_CERT_CMD"
else
  gen_cert=("$ROOT/relay/gen-relay-cert.sh")
fi
"${gen_cert[@]}" "$DOMAIN" "$W/tls" >"$W/gen-cert.log" 2>&1 || { cat "$W/gen-cert.log"; exit 1; }
"${gen_cert[@]}" impostor.test "$W/other-ca" >>"$W/gen-cert.log" 2>&1 || { cat "$W/gen-cert.log"; exit 1; }
mkdir -p "$W/public" && cp "$W/tls/ca.crt" "$W/public/ca.crt"

TOKEN_1234="$(auth add rest-1234 --name "Pizza Place" | awk '/Token:/ {print $2}')"
TOKEN_5678="$(auth add rest-5678 | awk '/Token:/ {print $2}')"
[[ -n "$TOKEN_1234" && -n "$TOKEN_5678" ]] || { echo "could not add restaurants"; exit 1; }

# Not via the auth() function: a backgrounded function runs in a subshell, and
# killing that would leave the Python process behind.
start auth python3 "$ROOT/relay/liwalink-auth.py" --registry "$W/restaurants.json" --domain "$DOMAIN" \
  serve --listen "127.0.0.1:$AUTH_PORT"
wait_for "$W/auth.log" "listening on" || { cat "$W/auth.log"; exit 1; }

render "$ROOT/relay/frps.toml" "$W/frps.toml" \
  __DOMAIN__ "$DOMAIN" \
  __DASHBOARD_PASSWORD__ test \
  'bindPort = 7000' "bindPort = $FRPS_PORT" \
  'vhostHTTPPort = 8080' "vhostHTTPPort = $VHOST_PORT" \
  'webServer.port = 7500' "webServer.port = $DASH_PORT" \
  '127.0.0.1:9000' "127.0.0.1:$AUTH_PORT" \
  __CONFIG_DIR__ "$W"
"$FRP_DIR/frps" verify -c "$W/frps.toml" >/dev/null
start frps "$FRP_DIR/frps" -c "$W/frps.toml"
wait_for "$W/frps.log" "frps started successfully" || { cat "$W/frps.log"; exit 1; }

# --- fake restaurant API ----------------------------------------------------------
mkdir -p "$W/api" && echo '{"restaurant":"rest-1234","menu":["pizza"]}' > "$W/api/menu.json"
start api python3 -m http.server "$API_PORT" --bind 127.0.0.1 --directory "$W/api"

# agent <name> <restaurant-id> <token> <ca-file> [<find> <replace>...]
# Renders the real agent template; the relay is reached at 127.0.0.1 while the
# certificate is still checked against the name link.test.
agent() {
  local name=$1 id=$2 token=$3 ca=$4; shift 4
  render "$ROOT/agent/frpc.toml.template" "$W/$name.toml" \
    'serverAddr = "__SERVER__"' 'serverAddr = "127.0.0.1"' \
    __SERVER_PORT__ "$FRPS_PORT" \
    __SERVER__ "$DOMAIN" \
    __RESTAURANT_ID__ "$id" \
    __TOKEN__ "$token" \
    __CA_FILE__ "$ca" \
    __LOCAL_HOST__ 127.0.0.1 \
    __LOCAL_PORT__ "$API_PORT" \
    "$@"
  "$FRP_DIR/frpc" verify -c "$W/$name.toml" >/dev/null
  start "$name" "$FRP_DIR/frpc" -c "$W/$name.toml"
}

echo "Agents that must be refused:"
agent bad-token rest-1234 "wrong-token" "$W/tls/ca.crt"
expect_log "wrong token is refused at login" bad-token "invalid restaurant id or token"
stop_last

agent hijack rest-5678 "$TOKEN_5678" "$W/tls/ca.crt" 'subdomain = "rest-5678"' 'subdomain = "rest-1234"'
expect_log "restaurant cannot take another restaurant's subdomain" hijack "may only use subdomain rest-5678"
stop_last

agent tcp rest-5678 "$TOKEN_5678" "$W/tls/ca.crt" 'type = "http"' 'type = "tcp"' 'subdomain = "rest-5678"' 'remotePort = 15432'
expect_log "raw TCP port (e.g. a database) is refused" tcp "only http proxies are allowed"
stop_last

agent impostor rest-5678 "$TOKEN_5678" "$W/other-ca/ca.crt"
# Depending on timing frpc reports the rejected certificate as an x509 error or
# just "session shutdown", so check that it keeps failing and never logs in.
wait_for "$W/impostor.log" "connect to server error" || true
sleep 2
if grep -q "connect to server error" "$W/impostor.log" && ! grep -q "login to server success" "$W/impostor.log"; then
  pass "agent refuses a relay whose certificate is not from our CA"
else
  fail "agent refuses a relay whose certificate is not from our CA"
  tail -n 15 "$W/impostor.log" | sed 's/^/        | /'
fi
stop_last

echo "Real agent:"
agent good rest-1234 "$TOKEN_1234" "$W/tls/ca.crt"
expect_log "rest-1234 connects and publishes its API" good "start proxy success"
body="$(curl -s -H "Host: rest-1234.$DOMAIN" "http://127.0.0.1:$VHOST_PORT/menu.json")"
expect_eq "request to rest-1234.$DOMAIN reaches the restaurant API" '{"restaurant":"rest-1234","menu":["pizza"]}' "$body"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: rest-9999.$DOMAIN" "http://127.0.0.1:$VHOST_PORT/menu.json")"
expect_eq "unknown restaurant gets 404" 404 "$code"

echo "Certificate checks (Caddy ask endpoint):"
ask() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$AUTH_PORT/caddy/ask?domain=$1"; }
expect_eq "certificate allowed for rest-1234.$DOMAIN" 200 "$(ask "rest-1234.$DOMAIN")"
expect_eq "certificate allowed for $DOMAIN itself" 200 "$(ask "$DOMAIN")"
expect_eq "certificate refused for unregistered rest-9999.$DOMAIN" 403 "$(ask "rest-9999.$DOMAIN")"
expect_eq "certificate refused for other domains" 403 "$(ask "rest-1234.$DOMAIN.evil.com")"
auth remove rest-5678 >/dev/null
expect_eq "removing a restaurant takes effect without restart" 403 "$(ask "rest-5678.$DOMAIN")"

# --- optional: public HTTPS through Caddy ------------------------------------------
if [[ -n "${CADDY:-}" ]]; then
  echo "Public HTTPS through Caddy (local test CA instead of Let's Encrypt):"
  render "$ROOT/relay/Caddyfile" "$W/Caddyfile" \
    'email __EMAIL__' "local_certs
	skip_install_trust
	admin off
	http_port $CADDY_HTTP_PORT
	https_port $CADDY_HTTPS_PORT
	storage file_system $W/caddy-data" \
    '127.0.0.1:9000' "127.0.0.1:$AUTH_PORT" \
    '127.0.0.1:8080' "127.0.0.1:$VHOST_PORT" \
    __CONFIG_DIR__ "$W" \
    __DOMAIN__ "$DOMAIN"
  start caddy "$CADDY" run --adapter caddyfile --config "$W/Caddyfile"
  for _ in $(seq 1 50); do
    curl -sk -o /dev/null --resolve "$DOMAIN:$CADDY_HTTPS_PORT:127.0.0.1" "https://$DOMAIN:$CADDY_HTTPS_PORT/" && break
    sleep 0.2
  done
  https() { curl -sk --resolve "$1:$CADDY_HTTPS_PORT:127.0.0.1" "https://$1:$CADDY_HTTPS_PORT$2"; }
  expect_eq "https://rest-1234.$DOMAIN reaches the restaurant API" \
    '{"restaurant":"rest-1234","menu":["pizza"]}' "$(https "rest-1234.$DOMAIN" /menu.json)"
  if https "rest-9999.$DOMAIN" /menu.json >/dev/null 2>&1; then
    fail "no certificate is issued for an unregistered restaurant"
  else
    pass "no certificate is issued for an unregistered restaurant"
  fi
  expect_eq "agents can download the CA from https://$DOMAIN/ca.crt" \
    "$(cat "$W/tls/ca.crt")" "$(https "$DOMAIN" /ca.crt)"
fi

echo
if [[ $FAILED -eq 0 ]]; then
  echo "All checks passed."
  KEEP_LOGS="${E2E_KEEP_LOGS:-0}"
else
  echo "Some checks failed."
  exit 1
fi
