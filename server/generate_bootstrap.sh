#!/bin/sh
set -eu

target=${TARGET_DIR:-/etc/kimi-gateway}
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
install -d -m 755 "$target"
pass=$(openssl rand -hex 24)

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$build/ca.key.pem" >/dev/null 2>&1
openssl req -new -x509 -key "$build/ca.key.pem" -sha256 -days 3650 \
  -subj '/CN=Agent Remote Bootstrap CA' \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -out "$build/ca.crt.pem"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$build/client.key.pem" >/dev/null 2>&1
openssl req -new -key "$build/client.key.pem" \
  -subj '/CN=Agent Remote Bootstrap Client' \
  -out "$build/client.csr.pem"
printf '%s\n' \
  'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature' \
  'extendedKeyUsage=clientAuth' > "$build/client.ext"
openssl x509 -req -in "$build/client.csr.pem" \
  -CA "$build/ca.crt.pem" -CAkey "$build/ca.key.pem" -CAcreateserial \
  -sha256 -days 3650 -extfile "$build/client.ext" \
  -out "$build/client.crt.pem" >/dev/null 2>&1

openssl pkcs12 -export \
  -inkey "$build/client.key.pem" \
  -in "$build/client.crt.pem" \
  -certfile "$build/ca.crt.pem" \
  -name 'Agent Remote enrollment bootstrap' \
  -passout "pass:$pass" \
  -out "$build/bootstrap-client.p12"

fp=$(openssl x509 -in "$build/client.crt.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
install -o root -g root -m 600 "$build/ca.key.pem" "$target/bootstrap-ca.key.pem"
install -o root -g root -m 644 "$build/ca.crt.pem" "$target/bootstrap-ca.crt.pem"
install -o root -g root -m 600 "$build/client.key.pem" "$target/bootstrap-client.key.pem"
install -o root -g root -m 644 "$build/client.crt.pem" "$target/bootstrap-client.crt.pem"
install -o root -g root -m 600 "$build/bootstrap-client.p12" "$target/bootstrap-client.p12"
printf '%s\n' "$pass" > "$target/bootstrap-password"
printf '%s\n' "$fp" > "$target/bootstrap-fingerprint"
chmod 600 "$target/bootstrap-password"
chmod 644 "$target/bootstrap-fingerprint"
printf 'P12_PASSWORD=%s\nFINGERPRINT=%s\n' "$pass" "$fp"
