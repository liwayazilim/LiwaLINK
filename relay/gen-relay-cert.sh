#!/usr/bin/env bash
# Create the LiwaLink tunnel CA (once) and issue the relay's TLS certificate.
#
#   ./gen-relay-cert.sh <relay-domain> <output-dir>
#
# Output: ca.key ca.crt relay.key relay.crt
# An existing CA is reused, so re-running only re-issues relay.crt and
# installed agents keep working. ca.crt is public; ca.key never leaves the relay.
set -euo pipefail

domain="${1:?usage: gen-relay-cert.sh <relay-domain> <output-dir>}"
out="${2:?usage: gen-relay-cert.sh <relay-domain> <output-dir>}"
days=3650

umask 077
mkdir -p "$out"
cd "$out"

if [[ ! -f ca.key ]]; then
  cat > ca.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = LiwaLink Relay CA
[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
  openssl ecparam -name prime256v1 -genkey -noout -out ca.key
  openssl req -x509 -new -key ca.key -sha256 -days "$days" \
    -config ca.cnf -extensions v3_ca -out ca.crt
  rm ca.cnf
  echo "Created CA: $out/ca.crt"
fi

cat > relay.cnf <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $domain
[ext]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:$domain
EOF
openssl ecparam -name prime256v1 -genkey -noout -out relay.key
openssl req -new -key relay.key -config relay.cnf -out relay.csr
openssl x509 -req -in relay.csr -CA ca.crt -CAkey ca.key \
  -set_serial "0x$(openssl rand -hex 16)" -days "$days" -sha256 \
  -extfile relay.cnf -extensions ext -out relay.crt
rm relay.cnf relay.csr
chmod 644 ca.crt relay.crt
echo "Issued relay certificate for $domain: $out/relay.crt"
